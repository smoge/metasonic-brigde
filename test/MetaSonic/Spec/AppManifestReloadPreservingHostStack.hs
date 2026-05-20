{-# LANGUAGE DerivingStrategies #-}

-- | Fake-IO tests for the preserving HostStackFactory + policy
-- pinning for 'classifyPreservingOutcome'.
--
-- Two test groups:
--
--   * 'classifyPreservingOutcomePolicyTests' exercises every one
--     of the 10 'HostPreservingReloadIssue' constructors against
--     'classifyPreservingOutcome', pinning the supervisor's
--     classification policy as a table. Any future change to the
--     policy must update these tests; a silent edit to the
--     classifier would fail loudly here.
--
--   * 'factoryCompositionTests' composes
--     'mkPreservingHostStackFactory' with
--     'withHostStackSupervisorAdapter' + 'reloadSupervised' under
--     fake @pahsoOpen@ / @pahsoClose@ / @pahsoInWindowReload@
--     slots. Pins the supervisor's four branches for the
--     preserving lane: 'Committed' / 'RequestRejected' /
--     'RejectedRecovered' / 'Escalated' map onto the right close /
--     open sequences. Includes the A→B→C→D! regression mirroring
--     the stopped-audio factory-layer guard.
--
-- The 'sahsConfig' field on the test fakes is left as a deferred
-- @error@ placeholder; tests verify by inspection that
-- @pahsoInWindowReload@ never forces it (the in-window slot is
-- overridden in every test). The 'realPreservingInWindowReload'
-- production wiring is not exercised here — its plan-native +
-- target-fresh contract is identical in shape to
-- 'realStoppedAudioInWindowReload's and is proven structurally by
-- the existing stopped-audio direct-integration test.
module MetaSonic.Spec.AppManifestReloadPreservingHostStack
  ( appManifestReloadPreservingHostStackTests
  ) where

import qualified Data.Map.Strict   as M
import           Data.IORef        (IORef, modifyIORef', newIORef, readIORef)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestReloadHost.Types
                                   (ManifestReloadHostIssue (..))
import           MetaSonic.App.ManifestReloadHostStack
                                   (StoppedAudioHostStack (..),
                                    StoppedAudioHostStackOpenIssue (..))
import           MetaSonic.App.ManifestReloadOrchestration.Types
                                   (HostPreservingReloadIssue (..))
import           MetaSonic.App.ManifestReloadPreservingHostStack
                                   (PreservingHostStackIssue (..),
                                    PreservingHostStackOps (..),
                                    classifyPreservingOutcome,
                                    mkPreservingHostStackFactory)
import           MetaSonic.App.ManifestReloadSupervisor
                                   (InWindowReloadOutcome (..),
                                    SupervisedReloadOutcome (..),
                                    reloadSupervised)
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                   (withHostStackSupervisorAdapter)
import           MetaSonic.Bridge.Templates (TemplateGraph (..))
import           MetaSonic.Pattern        (SwapLabel (..))
import           MetaSonic.Session.Arbitration (ArbitrationPolicy (..))
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.RTGraphAdapter
                                   (defaultRTGraphAdapterOptions)


-- | Type instantiation. 'ingressIssue' = 'String'; 'target' = '()'
-- and 'handle' = '()' since none of the fakes inspect them.
type TestStack = StoppedAudioHostStack () String ()

-- | The matching factory issue type for the test stack.
type TestFactoryIssue = PreservingHostStackIssue String

-- | The matching in-window outcome type for the test stack.
type TestInWindowOutcome =
  InWindowReloadOutcome
    (HostPreservingReloadIssue (ManifestReloadHostIssue String))


-- | Trace of factory calls observed by the test fakes. The plan
-- argument is recorded as its demo key so tests can assert which
-- plan triggered which call.
data StackCall
  = OpenCalled        !String
  | CloseCalled
  | InWindowCalled    !String
  deriving stock (Eq, Show)


-- | Inject canned behavior for each slot. Open failures are not
-- the focus of this lane (rebuild-on-terminal is structurally
-- identical to the stopped-audio harness's coverage); preserving's
-- value-add is the in-window classification, so the in-window
-- behavior is the variable knob.
data FakeStackPlan = FakeStackPlan
  { fspOpenBehavior
      :: !(MR.ManifestReloadPlan
            -> IO (Either (StoppedAudioHostStackOpenIssue String) ()))
  , fspInWindowBehavior
      :: !(MR.ManifestReloadPlan -> IO TestInWindowOutcome)
  }


-- | Build a fake 'PreservingHostStackOps' that records every call.
-- The open slot, on Right, mints the same deferred-config stub
-- stack the in-window fakes never inspect; the supervisor adapter
-- only passes the stack value through, so the deferred field is
-- safe.
mkFakeOps
  :: IORef [StackCall]
  -> FakeStackPlan
  -> PreservingHostStackOps () String ()
mkFakeOps traceRef plans = PreservingHostStackOps
  { pahsoOpen = \plan -> do
      record (OpenCalled (MR.mrlpDemoKey plan))
      result <- fspOpenBehavior plans plan
      case result of
        Left e   -> pure (Left e)
        Right () -> pure (Right stubStack)
  , pahsoClose = \_stack -> record CloseCalled
  , pahsoInWindowReload = \_stack _fallback plan -> do
      record (InWindowCalled (MR.mrlpDemoKey plan))
      fspInWindowBehavior plans plan
  }
  where
    record c = modifyIORef' traceRef (++ [c])


-- | Deferred-config stub stack. The supervisor adapter passes the
-- value around without inspecting it; the fake @pahsoInWindowReload@
-- never forces the config field; so the placeholder never blows up.
stubStack :: TestStack
stubStack = StoppedAudioHostStack
  { sahsConfig =
      error
        "test placeholder: sahsConfig is intentionally undefined; \
        \fakes override pahsoInWindowReload so the config is never read"
  }


-- | Construct a plan with a recognizable demo key. Mirrors the
-- stopped-audio harness's 'mkPlan' so traces look the same.
mkPlan :: String -> MR.ManifestReloadPlan
mkPlan demoKey = MR.ManifestReloadPlan
  { MR.mrlpDemoKey           = demoKey
  , MR.mrlpSwapLabel         = SwapLabel demoKey
  , MR.mrlpTemplateGraph     = TemplateGraph [] M.empty
  , MR.mrlpAdapterOptions    = defaultRTGraphAdapterOptions
  , MR.mrlpControlSurface    = []
  , MR.mrlpArbitrationPolicy = FifoOnly
  }


planA, planB :: MR.ManifestReloadPlan
planA = mkPlan "fallback"
planB = mkPlan "requested"


-- | Convenient open behaviors.
openOk :: MR.ManifestReloadPlan -> IO (Either (StoppedAudioHostStackOpenIssue String) ())
openOk _ = pure (Right ())


-- | Convenient in-window outcomes keyed to specific classified
-- variants. Each one returns a real 'HostPreservingReloadIssue'
-- payload so the supervisor's outcome carries the right cause.
inWindowCommitted :: MR.ManifestReloadPlan -> IO TestInWindowOutcome
inWindowCommitted _ = pure InWindowReloadCommitted


inWindowPlanRejected :: MR.ManifestReloadPlan -> IO TestInWindowOutcome
inWindowPlanRejected _ =
  pure $ classifyPreservingOutcome (HpariPlanRejected (MrhiIngress "plan-rejected"))


inWindowReloadRejected :: MR.ManifestReloadPlan -> IO TestInWindowOutcome
inWindowReloadRejected _ =
  pure $ classifyPreservingOutcome (HpariReloadRejected (MrhiIngress "preserving-rejected"))


inWindowReloadFailedTerminal :: MR.ManifestReloadPlan -> IO TestInWindowOutcome
inWindowReloadFailedTerminal _ =
  pure $ classifyPreservingOutcome (HpariReloadFailedTerminal (MrhiIngress "reload-terminal"))


appManifestReloadPreservingHostStackTests :: TestTree
appManifestReloadPreservingHostStackTests =
  testGroup "App manifest reload preserving host stack"
  [ classifyPreservingOutcomePolicyTests
  , factoryCompositionTests
  ]


-- | One testCase per 'HostPreservingReloadIssue' constructor.
-- Pinning the policy as an exhaustive table guarantees that
-- editing 'classifyPreservingOutcome' silently in the future
-- breaks the suite at the exact constructor whose classification
-- changed.
classifyPreservingOutcomePolicyTests :: TestTree
classifyPreservingOutcomePolicyTests =
  testGroup "classifyPreservingOutcome policy (10 constructors)"
  -- RejectedLiveFallback: the four "resume-ok" variants. Stack is
  -- still safely serving the fallback plan; supervisor short-
  -- circuits without close/open.
  [ rlf "HpariPlanRejected"
      (HpariPlanRejected fakeIssue)
  , rlf "HpariQuiesceRejected"
      (HpariQuiesceRejected fakeIssue)
  , rlf "HpariDrainRejected"
      (HpariDrainRejected fakeIssue)
  , rlf "HpariReloadRejected"
      (HpariReloadRejected fakeIssue)

  -- Terminal: resume-failed + outright-terminal + ingress-restart
  -- variants. Supervisor closes the stack and rebuilds from the
  -- captured fallback plan.
  , term "HpariQuiesceRejectedResumeFailed"
      (HpariQuiesceRejectedResumeFailed fakeIssue fakeIssue)
  , term "HpariDrainRejectedResumeFailed"
      (HpariDrainRejectedResumeFailed fakeIssue fakeIssue)
  , term "HpariReloadRejectedResumeFailed"
      (HpariReloadRejectedResumeFailed fakeIssue fakeIssue)
  , term "HpariDrainFailedTerminal"
      (HpariDrainFailedTerminal fakeIssue)
  , term "HpariReloadFailedTerminal"
      (HpariReloadFailedTerminal fakeIssue)
  , term "HpariIngressRestartFailed"
      (HpariIngressRestartFailed fakeIssue)
  ]
  where
    fakeIssue :: ManifestReloadHostIssue String
    fakeIssue = MrhiIngress "policy-pinning-fake"

    rlf name issue =
      testCase (name <> " -> RejectedLiveFallback") $
        classifyPreservingOutcome issue
          @?= InWindowReloadRejectedLiveFallback issue

    term name issue =
      testCase (name <> " -> Terminal") $
        classifyPreservingOutcome issue
          @?= InWindowReloadTerminal issue


factoryCompositionTests :: TestTree
factoryCompositionTests =
  testGroup "Preserving factory composition (fake-IO slots)"
  [ testCase
      "successful in-window reload commits without rebuild"
      $ do
      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior = openOk
            , fspInWindowBehavior = inWindowCommitted
            }
          factory = mkPreservingHostStackFactory ops
      outcome <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB
      trace <- readIORef traceRef

      outcome @?= SupervisedReloadCommitted
      -- One in-window call against the requested plan, then the
      -- bracket's-finally close on exit. No open: initial stack
      -- was supplied by the test fixture; supervisor did not
      -- rebuild.
      trace @?=
        [ InWindowCalled (MR.mrlpDemoKey planB)
        , CloseCalled
        ]

  , testCase
      "HpariPlanRejected short-circuits as RequestRejected: no close, no open"
      $ do
      -- The classifyPreservingOutcome policy says PlanRejected ->
      -- RejectedLiveFallback. The supervisor must therefore return
      -- SupervisedReloadRequestRejected without invoking
      -- sopsCloseStack or sopsOpenStack. The bracket's finally
      -- still closes the initial stack on exit.
      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior = openOk
            , fspInWindowBehavior = inWindowPlanRejected
            }
          factory = mkPreservingHostStackFactory ops
      outcome <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB
      trace <- readIORef traceRef

      outcome @?=
        SupervisedReloadRequestRejected
          (PahsiInWindow (HpariPlanRejected (MrhiIngress "plan-rejected")))
      trace @?=
        [ InWindowCalled (MR.mrlpDemoKey planB)
        , CloseCalled
        ]
      [() | OpenCalled _ <- trace] @?= []

  , testCase
      "HpariReloadRejected short-circuits as RequestRejected: no close, no open"
      $ do
      -- The canonical "preserving command rejected, old owner still
      -- installed, old ingress resumed" case. This is the variant
      -- preservingAllowsStoppedAudioFallback also blesses in the
      -- direct path. Under the supervisor, the stack is still live
      -- and serving the fallback plan, so no rebuild.
      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior = openOk
            , fspInWindowBehavior = inWindowReloadRejected
            }
          factory = mkPreservingHostStackFactory ops
      outcome <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB
      trace <- readIORef traceRef

      outcome @?=
        SupervisedReloadRequestRejected
          (PahsiInWindow (HpariReloadRejected (MrhiIngress "preserving-rejected")))
      trace @?=
        [ InWindowCalled (MR.mrlpDemoKey planB)
        , CloseCalled
        ]
      [() | OpenCalled _ <- trace] @?= []

  , testCase
      "HpariReloadFailedTerminal rebuilds from the captured fallback"
      $ do
      -- Representative Terminal case. classifyPreservingOutcome
      -- maps HpariReloadFailedTerminal -> InWindowReloadTerminal;
      -- the supervisor closes the stack and rebuilds from planA.
      -- The bracket's finally closes the rebuilt stack on exit.
      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior = openOk
            , fspInWindowBehavior = inWindowReloadFailedTerminal
            }
          factory = mkPreservingHostStackFactory ops
      outcome <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB
      trace <- readIORef traceRef

      outcome @?=
        SupervisedReloadRejectedRecovered
          (PahsiInWindow (HpariReloadFailedTerminal (MrhiIngress "reload-terminal")))
      trace @?=
        [ InWindowCalled (MR.mrlpDemoKey planB)
        , CloseCalled
        , OpenCalled    (MR.mrlpDemoKey planA)
        , CloseCalled
        ]

  , testCase
      "Terminal + rebuild also fails: SupervisedReloadEscalated with both causes"
      $ do
      -- Both halves fail. The supervisor escalates with the
      -- in-window cause AND the rebuild cause preserved through
      -- PahsiInWindow / PahsiOpen respectively.
      traceRef <- newIORef []
      let -- Use a separate import to construct the open issue
          -- without leaking the symbol through the preserving
          -- module; the test file already imports
          -- StoppedAudioHostStackOpenIssue.
          openFails _plan = pure $ Left $
            -- Pick a recognizable variant so the assertion is
            -- specific.
            stoppedAudioOpenIssueFakeForTest
          ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior = openFails
            , fspInWindowBehavior = inWindowReloadFailedTerminal
            }
          factory = mkPreservingHostStackFactory ops
      outcome <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB
      trace <- readIORef traceRef

      outcome @?=
        SupervisedReloadEscalated
          (PahsiInWindow (HpariReloadFailedTerminal (MrhiIngress "reload-terminal")))
          (PahsiOpen stoppedAudioOpenIssueFakeForTest)
      -- Trace: in-window, then close of the original stack, then
      -- a failed open that minted no new stack. No second close
      -- because there is no live stack at exit.
      trace @?=
        [ InWindowCalled (MR.mrlpDemoKey planB)
        , CloseCalled
        , OpenCalled    (MR.mrlpDemoKey planA)
        ]

  , testCase
      "A->B->C->D! factory-layer: failure from C falls back to C, never to B or A"
      $ do
      -- §238 #2 "no remembered history" regression at the
      -- preserving factory layer. The stack carries no plan field
      -- (it's a thin newtype around config); plan ownership lives
      -- at the supervisor's caller. After A->B->C both commit, a
      -- failed C->D must rebuild from C (the plan the caller is
      -- tracking as current), not from B (one step back) or A
      -- (two steps back).
      let planC = mkPlan "third"
          planD = mkPlan "fourth"
          inWindowFailsOnD plan
            | MR.mrlpDemoKey plan == MR.mrlpDemoKey planD =
                pure $ classifyPreservingOutcome
                  (HpariReloadFailedTerminal (MrhiIngress "d-failed"))
            | otherwise = pure InWindowReloadCommitted

      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior = openOk
            , fspInWindowBehavior = inWindowFailsOnD
            }
          factory = mkPreservingHostStackFactory ops

      withHostStackSupervisorAdapter factory stubStack $ \supOps -> do
        -- A -> B commits.
        outcomeAB <- reloadSupervised supOps planA planB
        outcomeAB @?= SupervisedReloadCommitted

        -- B -> C commits. The caller threads currentPlan forward;
        -- the factory accumulates no per-stack history.
        outcomeBC <- reloadSupervised supOps planB planC
        outcomeBC @?= SupervisedReloadCommitted

        -- C -> D fails terminally. The caller-supplied fallback
        -- is planC. Rebuild must target planC.
        outcomeCD <- reloadSupervised supOps planC planD
        outcomeCD @?=
          SupervisedReloadRejectedRecovered
            (PahsiInWindow
              (HpariReloadFailedTerminal (MrhiIngress "d-failed")))

      trace <- readIORef traceRef
      let openedDemos = [k | OpenCalled k <- trace]
      openedDemos @?= [MR.mrlpDemoKey planC]
      MR.mrlpDemoKey planA `notElem` openedDemos @?= True
      MR.mrlpDemoKey planB `notElem` openedDemos @?= True
  ]


-- | A recognizable 'StoppedAudioHostStackOpenIssue' value for
-- pinning Escalated outcomes. The specific variant doesn't matter
-- to the supervisor's branching; only that the test assertion can
-- name the same one back.
stoppedAudioOpenIssueFakeForTest :: StoppedAudioHostStackOpenIssue String
stoppedAudioOpenIssueFakeForTest =
  SahsoiIngressOpenFailed "rebuild-broke"
