{-# LANGUAGE DerivingStrategies #-}

-- | Tests for the try-preserving HostStackFactory + pure cores
-- ('decideTryPreservingNext' and 'composeFallbackOutcome').
--
-- Three groups:
--
--   * 'decideTryPreservingNextTests' walks every
--     'HostPreservingReloadIssue' constructor through both the
--     'InWindowReloadRejectedLiveFallback' and
--     'InWindowReloadTerminal' arms, asserting which branch
--     ('TpnRunFallback' / 'TpnDeclineFallback' / 'TpnTerminal')
--     the pure decision returns. Pinning every constructor as a
--     table catches a silent change to either
--     'classifyPreservingOutcome' or
--     'preservingAllowsStoppedAudioFallback' at the exact row that
--     drifted.
--   * 'composeFallbackOutcomeTests' pins the small mapping from
--     a stopped-audio fallback's 'InWindowReloadOutcome' to the
--     combined try-preserving outcome (Committed / Terminal,
--     with the impossible RejectedLiveFallback branch documented
--     by an 'error').
--   * 'factoryCompositionTests' composes
--     'mkTryPreservingHostStackFactory' with
--     'withHostStackSupervisorAdapter' + 'reloadSupervised' under
--     fake @tpahsoOpen@ / @tpahsoClose@ / @tpahsoInWindowReload@
--     slots, pinning the five supervisor branches end-to-end
--     plus the A→B→C→D! no-remembered-history regression at the
--     try-preserving factory layer.
--
-- The factory tests stub @tpahsoInWindowReload@ directly with
-- pre-canned 'InWindowReloadOutcome' values; the gate decision is
-- already covered by the pure tests, so the factory layer only
-- needs to prove that the supervisor's branches respond to each
-- combined outcome correctly. No real session state is staged.
module MetaSonic.Spec.AppManifestReloadTryPreservingHostStack
  ( appManifestReloadTryPreservingHostStackTests
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
                                   (HostPreservingReloadIssue (..),
                                    HostStoppedAudioReloadIssue (..))
import           MetaSonic.App.ManifestReloadSupervisor
                                   (InWindowReloadOutcome (..),
                                    SupervisedReloadOutcome (..),
                                    reloadSupervised)
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                   (withHostStackSupervisorAdapter)
import           MetaSonic.App.ManifestReloadTryPreservingHostStack
                                   (TryPreservingHostStackIssue (..),
                                    TryPreservingHostStackOps (..),
                                    TryPreservingInWindowIssue (..),
                                    TryPreservingNext (..),
                                    composeFallbackOutcome,
                                    decideTryPreservingNext,
                                    mkTryPreservingHostStackFactory)
import           MetaSonic.Bridge.Templates (TemplateGraph (..))
import           MetaSonic.Pattern        (SwapLabel (..))
import           MetaSonic.Session.Arbitration (ArbitrationPolicy (..))
import           MetaSonic.Session.FanIn  (SessionFanInAudioIssue (..))
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.RTGraphAdapter
                                   (defaultRTGraphAdapterOptions)


-- | Type instantiation: 'ingressIssue' = 'String'; 'target' = '()',
-- 'handle' = '()'.
type TestStack = StoppedAudioHostStack () String ()


-- | Outcome alias matching the try-preserving in-window slot's
-- return type.
type TestInWindowOutcome =
  InWindowReloadOutcome (TryPreservingInWindowIssue String)


-- | Trace of factory calls observed by the test fakes.
data StackCall
  = OpenCalled     !String  -- ^ requested plan's demo key
  | CloseCalled
  | InWindowCalled !String  -- ^ requested plan's demo key
  deriving stock (Eq, Show)


-- | Inject canned behavior for each slot.
data FakeStackPlan = FakeStackPlan
  { fspOpenBehavior
      :: !(MR.ManifestReloadPlan
            -> IO (Either (StoppedAudioHostStackOpenIssue String) ()))
  , fspInWindowBehavior
      :: !(MR.ManifestReloadPlan -> IO TestInWindowOutcome)
  }


mkFakeOps
  :: IORef [StackCall]
  -> FakeStackPlan
  -> TryPreservingHostStackOps () String ()
mkFakeOps traceRef plans = TryPreservingHostStackOps
  { tpahsoOpen = \plan -> do
      record (OpenCalled (MR.mrlpDemoKey plan))
      result <- fspOpenBehavior plans plan
      case result of
        Left e   -> pure (Left e)
        Right () -> pure (Right stubStack)
  , tpahsoClose = \_stack -> record CloseCalled
  , tpahsoInWindowReload = \_stack _fallback plan -> do
      record (InWindowCalled (MR.mrlpDemoKey plan))
      fspInWindowBehavior plans plan
  }
  where
    record c = modifyIORef' traceRef (++ [c])


-- | Deferred-config stub stack. The factory composition tests
-- override 'tpahsoInWindowReload' with a fake, so the config
-- field is never forced.
stubStack :: TestStack
stubStack = StoppedAudioHostStack
  { sahsConfig =
      error
        "test placeholder: sahsConfig is intentionally undefined; \
        \fakes override tpahsoInWindowReload so the config is never read"
  }


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


openOk :: MR.ManifestReloadPlan -> IO (Either (StoppedAudioHostStackOpenIssue String) ())
openOk _ = pure (Right ())


-- | Convenient outcome producers for the factory composition
-- group. Each builds a 'TryPreservingInWindowIssue' payload so
-- the supervisor's outcome carries the right cause.
inWindowCommitted :: MR.ManifestReloadPlan -> IO TestInWindowOutcome
inWindowCommitted _ = pure InWindowReloadCommitted


-- | Simulates "preserving rejected with a fallback-declined
-- cause": the supervisor returns request-rejected, no rebuild.
inWindowPreservingFallbackDeclined :: MR.ManifestReloadPlan -> IO TestInWindowOutcome
inWindowPreservingFallbackDeclined _ =
  pure
    (InWindowReloadRejectedLiveFallback
      (TpiwiPreservingFallbackDeclined
        (HpariPlanRejected (MrhiIngress "plan-rejected"))))


-- | Simulates "preserving terminal": supervisor closes + rebuilds.
inWindowPreservingTerminal :: MR.ManifestReloadPlan -> IO TestInWindowOutcome
inWindowPreservingTerminal _ =
  pure
    (InWindowReloadTerminal
      (TpiwiPreservingTerminal
        (HpariReloadFailedTerminal (MrhiIngress "preserving-terminal"))))


-- | Simulates "preserving rejected + fallback admitted +
-- stopped-audio failed terminally": supervisor closes + rebuilds
-- with both halves carried in the payload.
inWindowFallbackStoppedAudioFailed :: MR.ManifestReloadPlan -> IO TestInWindowOutcome
inWindowFallbackStoppedAudioFailed _ =
  pure
    (InWindowReloadTerminal
      (TpiwiFallbackStoppedAudioFailed
        (HpariReloadRejected (MrhiIngress "preserving-rejected"))
        (HsariReloadFailedNoOwner
          (MrhiAudio (SfaiStartFailed (-1))))))


appManifestReloadTryPreservingHostStackTests :: TestTree
appManifestReloadTryPreservingHostStackTests =
  testGroup "App manifest reload try-preserving host stack"
  [ decideTryPreservingNextTests
  , composeFallbackOutcomeTests
  , factoryCompositionTests
  ]


-- | Pure-core decision table: every 'HostPreservingReloadIssue'
-- constructor, exercised through both the
-- 'InWindowReloadRejectedLiveFallback' arm (where
-- 'classifyPreservingOutcome' would deposit it) and the
-- 'InWindowReloadTerminal' arm (where it would deposit a
-- terminal-classified cause). Catches drift in either
-- 'classifyPreservingOutcome' or
-- 'preservingAllowsStoppedAudioFallback' at the row that changed.
decideTryPreservingNextTests :: TestTree
decideTryPreservingNextTests =
  testGroup "decideTryPreservingNext policy (pure)"
  [ testCase "InWindowReloadCommitted -> TpnCommitted" $
      decideTryPreservingNext InWindowReloadCommitted
        @?= (TpnCommitted :: TryPreservingNext String)

  -- RejectedLiveFallback arm: gate is preservingAllowsStoppedAudioFallback.
  --   * HpariReloadRejected admits fallback (the canonical case).
  --   * The other three resume-ok variants
  --     (HpariPlanRejected, HpariQuiesceRejected, HpariDrainRejected)
  --     decline fallback even though classifyPreservingOutcome
  --     marks them RejectedLiveFallback.
  , decideRLF "HpariReloadRejected -> TpnRunFallback"
      (HpariReloadRejected fakeIssue) TpnRunFallback
  , decideRLF "HpariPlanRejected -> TpnDeclineFallback"
      (HpariPlanRejected fakeIssue) TpnDeclineFallback
  , decideRLF "HpariQuiesceRejected -> TpnDeclineFallback"
      (HpariQuiesceRejected fakeIssue) TpnDeclineFallback
  , decideRLF "HpariDrainRejected -> TpnDeclineFallback"
      (HpariDrainRejected fakeIssue) TpnDeclineFallback

  -- Terminal arm: every variant routes to TpnTerminal,
  -- regardless of preservingAllowsStoppedAudioFallback's view.
  -- A "Terminal" classification has already concluded the stack
  -- is unhealthy; whether a hypothetical resume-ok variant
  -- could have admitted fallback is moot here.
  , decideTerm "HpariQuiesceRejectedResumeFailed -> TpnTerminal"
      (HpariQuiesceRejectedResumeFailed fakeIssue fakeIssue)
  , decideTerm "HpariDrainRejectedResumeFailed -> TpnTerminal"
      (HpariDrainRejectedResumeFailed fakeIssue fakeIssue)
  , decideTerm "HpariReloadRejectedResumeFailed -> TpnTerminal"
      (HpariReloadRejectedResumeFailed fakeIssue fakeIssue)
  , decideTerm "HpariDrainFailedTerminal -> TpnTerminal"
      (HpariDrainFailedTerminal fakeIssue)
  , decideTerm "HpariReloadFailedTerminal -> TpnTerminal"
      (HpariReloadFailedTerminal fakeIssue)
  , decideTerm "HpariIngressRestartFailed -> TpnTerminal"
      (HpariIngressRestartFailed fakeIssue)
  ]
  where
    fakeIssue :: ManifestReloadHostIssue String
    fakeIssue = MrhiIngress "decide-policy-fake"

    decideRLF name issue expected =
      testCase name $
        decideTryPreservingNext
          (InWindowReloadRejectedLiveFallback issue)
            @?= expected issue

    decideTerm name issue =
      testCase name $
        decideTryPreservingNext (InWindowReloadTerminal issue)
          @?= TpnTerminal issue


-- | Pure-core composition table for the stopped-audio fallback
-- outcome. The third arm (RejectedLiveFallback) is an internal
-- contract violation that 'composeFallbackOutcome' surfaces as
-- an 'error'; testing it would require catching that error,
-- which is brittle. The two reachable arms (Committed / Terminal)
-- are the load-bearing ones for the supervisor's outcome.
composeFallbackOutcomeTests :: TestTree
composeFallbackOutcomeTests =
  testGroup "composeFallbackOutcome (pure)"
  [ testCase
      "stopped-audio Committed -> combined Committed (no payload)"
      $ composeFallbackOutcome
          preservingIssue
          InWindowReloadCommitted
        @?= (InWindowReloadCommitted
              :: InWindowReloadOutcome (TryPreservingInWindowIssue String))

  , testCase
      "stopped-audio Terminal -> combined Terminal with both halves"
      $ composeFallbackOutcome
          preservingIssue
          (InWindowReloadTerminal stoppedIssue)
        @?=
          InWindowReloadTerminal
            (TpiwiFallbackStoppedAudioFailed
              preservingIssue
              stoppedIssue)
  ]
  where
    preservingIssue :: HostPreservingReloadIssue (ManifestReloadHostIssue String)
    preservingIssue =
      HpariReloadRejected (MrhiIngress "preserving-trigger")

    stoppedIssue :: HostStoppedAudioReloadIssue (ManifestReloadHostIssue String)
    stoppedIssue =
      HsariReloadFailedNoOwner (MrhiIngress "stopped-audio-cause")


factoryCompositionTests :: TestTree
factoryCompositionTests =
  testGroup "Try-preserving factory composition (fake-IO slots)"
  [ testCase
      "successful in-window reload commits without rebuild"
      $ do
      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior     = openOk
            , fspInWindowBehavior = inWindowCommitted
            }
          factory = mkTryPreservingHostStackFactory ops
      outcome <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB
      trace <- readIORef traceRef

      outcome @?= SupervisedReloadCommitted
      trace @?=
        [ InWindowCalled (MR.mrlpDemoKey planB)
        , CloseCalled
        ]

  , testCase
      "preserving rejected + fallback declined -> RequestRejected, no rebuild"
      $ do
      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior     = openOk
            , fspInWindowBehavior = inWindowPreservingFallbackDeclined
            }
          factory = mkTryPreservingHostStackFactory ops
      outcome <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB
      trace <- readIORef traceRef

      outcome @?=
        SupervisedReloadRequestRejected
          (TpahsiInWindow
            (TpiwiPreservingFallbackDeclined
              (HpariPlanRejected (MrhiIngress "plan-rejected"))))
      trace @?=
        [ InWindowCalled (MR.mrlpDemoKey planB)
        , CloseCalled    -- bracket's-finally close of the initial stack
        ]
      [() | OpenCalled _ <- trace] @?= []

  , testCase
      "preserving terminal rebuilds from the captured fallback"
      $ do
      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior     = openOk
            , fspInWindowBehavior = inWindowPreservingTerminal
            }
          factory = mkTryPreservingHostStackFactory ops
      outcome <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB
      trace <- readIORef traceRef

      outcome @?=
        SupervisedReloadRejectedRecovered
          (TpahsiInWindow
            (TpiwiPreservingTerminal
              (HpariReloadFailedTerminal (MrhiIngress "preserving-terminal"))))
      trace @?=
        [ InWindowCalled (MR.mrlpDemoKey planB)
        , CloseCalled
        , OpenCalled    (MR.mrlpDemoKey planA)
        , CloseCalled
        ]

  , testCase
      "preserving rejected + fallback admitted + stopped-audio failed -> Recovered with both halves"
      $ do
      -- The combined cause carries the preserving rejection that
      -- admitted fallback AND the stopped-audio terminal failure.
      -- The supervisor closes + rebuilds (because the stopped-audio
      -- failure left the stack in unknown state).
      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior     = openOk
            , fspInWindowBehavior = inWindowFallbackStoppedAudioFailed
            }
          factory = mkTryPreservingHostStackFactory ops
      outcome <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB

      outcome @?=
        SupervisedReloadRejectedRecovered
          (TpahsiInWindow
            (TpiwiFallbackStoppedAudioFailed
              (HpariReloadRejected (MrhiIngress "preserving-rejected"))
              (HsariReloadFailedNoOwner
                (MrhiAudio (SfaiStartFailed (-1))))))

  , testCase
      "terminal in-window + rebuild also fails: SupervisedReloadEscalated"
      $ do
      -- Both halves of the supervisor's response fail. The
      -- in-window slot returns Terminal; the rebuild's
      -- tpahsoOpen against the fallback plan also returns Left.
      traceRef <- newIORef []
      let openFails _plan =
            pure (Left (SahsoiIngressOpenFailed "rebuild-broke"))
          ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior     = openFails
            , fspInWindowBehavior = inWindowPreservingTerminal
            }
          factory = mkTryPreservingHostStackFactory ops
      outcome <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB
      trace <- readIORef traceRef

      outcome @?=
        SupervisedReloadEscalated
          (TpahsiInWindow
            (TpiwiPreservingTerminal
              (HpariReloadFailedTerminal (MrhiIngress "preserving-terminal"))))
          (TpahsiOpen (SahsoiIngressOpenFailed "rebuild-broke"))
      trace @?=
        [ InWindowCalled (MR.mrlpDemoKey planB)
        , CloseCalled
        , OpenCalled    (MR.mrlpDemoKey planA)
        ]

  , testCase
      "A->B->C->D! factory-layer: failure from C falls back to C, never to B or A"
      $ do
      -- §238 #2 no-remembered-history regression at the
      -- try-preserving factory layer. Mirrors the stopped-audio
      -- + preserving versions: three reloads (A->B->C commit),
      -- then a failed C->D must rebuild from C (the plan the
      -- caller is tracking as current), not from B or A.
      let planC = mkPlan "third"
          planD = mkPlan "fourth"
          inWindowFailsOnD plan
            | MR.mrlpDemoKey plan == MR.mrlpDemoKey planD =
                pure
                  (InWindowReloadTerminal
                    (TpiwiPreservingTerminal
                      (HpariReloadFailedTerminal (MrhiIngress "d-failed"))))
            | otherwise = pure InWindowReloadCommitted

      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior     = openOk
            , fspInWindowBehavior = inWindowFailsOnD
            }
          factory = mkTryPreservingHostStackFactory ops

      withHostStackSupervisorAdapter factory stubStack $ \supOps -> do
        outcomeAB <- reloadSupervised supOps planA planB
        outcomeAB @?= SupervisedReloadCommitted

        outcomeBC <- reloadSupervised supOps planB planC
        outcomeBC @?= SupervisedReloadCommitted

        outcomeCD <- reloadSupervised supOps planC planD
        outcomeCD @?=
          SupervisedReloadRejectedRecovered
            (TpahsiInWindow
              (TpiwiPreservingTerminal
                (HpariReloadFailedTerminal (MrhiIngress "d-failed"))))

      trace <- readIORef traceRef
      let openedDemos = [k | OpenCalled k <- trace]
      openedDemos @?= [MR.mrlpDemoKey planC]
      MR.mrlpDemoKey planA `notElem` openedDemos @?= True
      MR.mrlpDemoKey planB `notElem` openedDemos @?= True
  ]
