{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeApplications   #-}

-- | Fake-IO tests for the stopped-audio HostStackFactory.
--
-- Exercises 'mkStoppedAudioHostStackFactory' composed with
-- 'withHostStackSupervisorAdapter' + 'reloadSupervised'. The
-- @sahsoOpen@ / @sahsoClose@ / @sahsoInWindowReload@ slots are
-- fully fake — no SessionFanInService, no audio FFI, no ingress
-- manager — so the tests can inject the specific
-- 'HostStoppedAudioReloadIssue' variants the supervisor design
-- note named (@HsariReloadFailedNoOwner@,
-- @HsariAudioRestartFailed@, @HsariListenerRestartFailed@)
-- without staging real session-layer state.
--
-- The 'sahsConfig' field on the test fakes is left as a deferred
-- @error@ placeholder; tests verify by inspection that
-- @sahsoInWindowReload@ never forces it (the in-window slot is
-- overridden in every test) and the supervisor adapter never
-- forces it either (it only passes the @stack@ value around,
-- never inspecting its config).
--
-- 'realStoppedAudioInWindowReload' is the production wiring for
-- the in-window slot — it drives
-- 'orchestrateHostStoppedAudioReloadWithEvents' with
-- @hsaroPreparePlan = const (pure (Right requested))@ so the
-- supervisor's plan is the source of truth at the seam, and
-- re-projects both @mrhcOldIngressTarget@ and
-- @mrhcNewIngressTarget@ from the supplied @(fallback,
-- requested)@ plans so target selection cannot drift across a
-- long reload sequence.
--
-- The factory-composition tests below override
-- @sahsoInWindowReload@ with a fake so they can pin specific
-- 'HostStoppedAudioReloadIssue' variants without staging real
-- session-layer state. The separate 'realInWindowReloadTests'
-- group exercises 'realStoppedAudioInWindowReload' directly
-- end-to-end: it opens a real (empty-graph) 'SessionFanInService'
-- via 'realStoppedAudioHostStackOps' and asserts the supplied
-- plan is installed even though the helper passes empty
-- doc / catalog through 'manifestReloadHostOps' — proof that the
-- @hsaroPreparePlan@ override is the only thing keeping
-- planning from being re-derived from drifted inputs.
--
-- See notes/2026-05-14-k-host-reload-supervisor.md \xa7219 slice 4.
module MetaSonic.Spec.AppManifestReloadHostStack
  ( appManifestReloadHostStackTests
  ) where

import           Control.Concurrent      (forkIO)
import           Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar,
                                          takeMVar)
import           Control.Exception       (ErrorCall (..), SomeException,
                                          fromException, throwIO, throwTo,
                                          try)
import           Control.Monad           (void)
import qualified Data.Map.Strict         as M
import           Data.IORef              (IORef, modifyIORef', newIORef,
                                          readIORef)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestReloadHost
                                         (ManifestReloadHostConfig)
import           MetaSonic.App.ManifestReloadHost.Types
                                         (ManifestReloadHostIssue (..))
import           MetaSonic.App.ManifestReloadHostStack
                                         (RealStoppedAudioHostStackInputs (..),
                                          StoppedAudioHostStack (..),
                                          StoppedAudioHostStackIssue (..),
                                          StoppedAudioHostStackOpenIssue (..),
                                          StoppedAudioHostStackOps (..),
                                          SupervisedStoppedAudioReloadResult (..),
                                          mkStoppedAudioHostStackFactory,
                                          realStoppedAudioHostStackOps,
                                          realStoppedAudioInWindowReload,
                                          runSupervisedStoppedAudioReload)
import           MetaSonic.App.ManifestReloadIngress
                                         (ManifestReloadIngressOps (..))
import           MetaSonic.App.ManifestReloadIngressTarget
                                         (ManifestReloadIngressTarget,
                                          ManifestReloadIngressTargetPolicy (..))
import           MetaSonic.App.ManifestReloadBinding
                                         (ManifestUIVoiceSelection (..))
import           MetaSonic.App.ManifestReloadOrchestration.Types
                                         (HostStoppedAudioReloadIssue (..))
import           MetaSonic.App.ManifestReloadSupervisor
                                         (InWindowReloadOutcome (..),
                                          SupervisedReloadOutcome (..),
                                          reloadSupervised)
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                         (withHostStackSupervisorAdapter)
import           MetaSonic.Bridge.Templates (TemplateGraph (..))
import           MetaSonic.Pattern              (SwapLabel (..), VoiceKey (..))
import           MetaSonic.Session.Arbitration  (ArbitrationPolicy (..))
import           MetaSonic.Session.FanIn (SessionFanInAudioFFI (..),
                                          SessionFanInAudioIssue (..),
                                          SessionFanInAudioOptions (..))
import           MetaSonic.Session.FanInService
                                         (defaultSessionFanInServiceHooks,
                                          defaultSessionFanInServiceOptions)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.Owner (defaultSessionOwnerOptions)
import           MetaSonic.Session.RTGraphAdapter
                                         (defaultRTGraphAdapterOptions)


-- | Type instantiation used throughout the fakes. The
-- 'ingressIssue' parameter is 'String'; the 'target' and
-- 'handle' parameters are '()' — none of them are inspected by
-- the supervisor adapter or by the fake slots, so simple
-- placeholders are enough.
type TestStack = StoppedAudioHostStack () String ()


-- | Trace of factory calls observed by the test fakes. The plan
-- argument is recorded so tests can assert which plan triggered
-- which call.
data StackCall
  = OpenCalled        !String  -- ^ requested plan's demo key
  | CloseCalled
  | InWindowCalled    !String  -- ^ requested plan's demo key
  deriving stock (Eq, Show)


-- | Inject canned behavior for each slot. Tests fill these to
-- pick specific failure paths.
data FakeStackPlan = FakeStackPlan
  { fspOpenBehavior
      :: !(MR.ManifestReloadPlan
            -> IO (Either (StoppedAudioHostStackOpenIssue String) ()))
  , fspInWindowBehavior
      :: !(MR.ManifestReloadPlan
            -> IO (InWindowReloadOutcome
                    (HostStoppedAudioReloadIssue
                      (ManifestReloadHostIssue String))))
  }


-- | Build a fake 'StoppedAudioHostStackOps' that records every
-- call to a shared trace. The open slot, on Right, mints a stack
-- whose 'sahsConfig' is a deferred 'error' (never forced by the
-- supervisor adapter or the fake in-window slot). The plan that
-- triggered each call is captured in the trace via its demo key
-- so tests can assert which plan drove which slot — the stack
-- itself carries no plan field; plan ownership lives at the
-- supervisor's caller.
mkFakeOps
  :: IORef [StackCall]
  -> FakeStackPlan
  -> StoppedAudioHostStackOps () String ()
mkFakeOps traceRef plans = StoppedAudioHostStackOps
  { sahsoOpen = \plan -> do
      record (OpenCalled (MR.mrlpDemoKey plan))
      result <- fspOpenBehavior plans plan
      case result of
        Left e   -> pure (Left e)
        Right () -> pure (Right stubStack)
  , sahsoClose = \_stack -> record CloseCalled
  , sahsoInWindowReload = \_stack _fallback plan -> do
      record (InWindowCalled (MR.mrlpDemoKey plan))
      fspInWindowBehavior plans plan
  }
  where
    record c = modifyIORef' traceRef (++ [c])


-- | Deferred-config stub stack. The supervisor adapter passes the
-- value around without inspecting it; the fake @sahsoInWindowReload@
-- never forces the config field; so the placeholder never blows up.
stubStack :: TestStack
stubStack = StoppedAudioHostStack
  { sahsConfig =
      error
        "test placeholder: sahsConfig is intentionally undefined; \
        \fakes override sahsoInWindowReload so the config is never read"
  }


-- | Build a minimal 'ManifestReloadPlan'. Tests vary the demo key
-- so the trace shows which plan drove each call.
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

openFailsAudioStart :: MR.ManifestReloadPlan -> IO (Either (StoppedAudioHostStackOpenIssue String) ())
openFailsAudioStart _ =
  pure (Left (SahsoiAudioStartFailed (SfaiStartFailed (-1))))


-- | Convenient in-window behaviors keyed to specific named
-- failure variants the supervisor design note pins (§238).
--
-- All failure helpers produce 'InWindowReloadTerminal'. Stopped-audio
-- by construction never produces 'InWindowReloadRejectedLiveFallback'
-- (see the Haddock on 'sahsoInWindowReload'); preserving /
-- try-preserving fixtures live in their own helpers when they land.
type FakeInWindowOutcome =
  InWindowReloadOutcome
    (HostStoppedAudioReloadIssue (ManifestReloadHostIssue String))

inWindowOk :: MR.ManifestReloadPlan -> IO FakeInWindowOutcome
inWindowOk _ = pure InWindowReloadCommitted

inWindowOwnerSetupFailed :: MR.ManifestReloadPlan -> IO FakeInWindowOutcome
inWindowOwnerSetupFailed _ =
  pure (InWindowReloadTerminal (HsariReloadFailedNoOwner (MrhiIngress "owner-setup")))

inWindowAudioRestartFailed :: MR.ManifestReloadPlan -> IO FakeInWindowOutcome
inWindowAudioRestartFailed _ =
  pure (InWindowReloadTerminal (HsariAudioRestartFailed (MrhiAudio (SfaiStartFailed (-1)))))

inWindowListenerRestartFailed :: MR.ManifestReloadPlan -> IO FakeInWindowOutcome
inWindowListenerRestartFailed _ =
  pure (InWindowReloadTerminal (HsariListenerRestartFailed (MrhiIngress "listener-restart")))


appManifestReloadHostStackTests :: TestTree
appManifestReloadHostStackTests =
  testGroup "App manifest reload host stack"
  [ factoryCompositionTests
  , realProductionHelperTests
  , realInWindowReloadTests
  , runSupervisedStoppedAudioReloadTests
  ]


factoryCompositionTests :: TestTree
factoryCompositionTests =
  testGroup "Stopped-audio factory composition (fake-IO slots)"
  [ testCase
      "successful in-window reload commits without rebuild"
      $ do
      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior = openOk
            , fspInWindowBehavior = inWindowOk
            }
          factory = mkStoppedAudioHostStackFactory ops
      outcome <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB
      trace <- readIORef traceRef

      outcome @?= SupervisedReloadCommitted
      -- One in-window call against the requested plan, then the
      -- bracket's-finally close on exit. No open call: the
      -- initial stack was supplied by the test fixture; the
      -- supervisor never rebuilt.
      trace @?=
        [ InWindowCalled (MR.mrlpDemoKey planB)
        , CloseCalled
        ]

  , testCase
      "owner-setup failure rebuilds from the captured fallback"
      $ do
      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior = openOk
            , fspInWindowBehavior = inWindowOwnerSetupFailed
            }
          factory = mkStoppedAudioHostStackFactory ops
      outcome <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB
      trace <- readIORef traceRef

      -- The owner-setup failure surfaces through SahsiInWindow
      -- wrapping HsariReloadFailedNoOwner. The rebuild path
      -- opens against planA (the fallback), succeeds, and the
      -- bracket's finally closes the new stack.
      outcome @?=
        SupervisedReloadRejectedRecovered
          (SahsiInWindow
            (HsariReloadFailedNoOwner
              (MrhiIngress "owner-setup")))
      trace @?=
        [ InWindowCalled (MR.mrlpDemoKey planB)
        , CloseCalled
        , OpenCalled    (MR.mrlpDemoKey planA)
        , CloseCalled
        ]

  , testCase
      "audio-restart failure rebuilds from the captured fallback"
      $ do
      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior = openOk
            , fspInWindowBehavior = inWindowAudioRestartFailed
            }
          factory = mkStoppedAudioHostStackFactory ops
      outcome <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB
      trace <- readIORef traceRef

      outcome @?=
        SupervisedReloadRejectedRecovered
          (SahsiInWindow
            (HsariAudioRestartFailed
              (MrhiAudio (SfaiStartFailed (-1)))))
      trace @?=
        [ InWindowCalled (MR.mrlpDemoKey planB)
        , CloseCalled
        , OpenCalled    (MR.mrlpDemoKey planA)
        , CloseCalled
        ]

  , testCase
      "listener/ingress-restart failure rebuilds from the captured fallback"
      $ do
      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior = openOk
            , fspInWindowBehavior = inWindowListenerRestartFailed
            }
          factory = mkStoppedAudioHostStackFactory ops
      outcome <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB
      trace <- readIORef traceRef

      outcome @?=
        SupervisedReloadRejectedRecovered
          (SahsiInWindow
            (HsariListenerRestartFailed
              (MrhiIngress "listener-restart")))
      trace @?=
        [ InWindowCalled (MR.mrlpDemoKey planB)
        , CloseCalled
        , OpenCalled    (MR.mrlpDemoKey planA)
        , CloseCalled
        ]

  , testCase
      "rebuild also fails: SupervisedReloadEscalated with both causes"
      $ do
      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior = openFailsAudioStart
            , fspInWindowBehavior = inWindowOwnerSetupFailed
            }
          factory = mkStoppedAudioHostStackFactory ops
      outcome <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB
      trace <- readIORef traceRef

      outcome @?=
        SupervisedReloadEscalated
          (SahsiInWindow
            (HsariReloadFailedNoOwner
              (MrhiIngress "owner-setup")))
          (SahsiOpen
            (SahsoiAudioStartFailed (SfaiStartFailed (-1))))
      -- Trace: in-window, then close of the initial stack, then
      -- the open call that failed (no second close because there
      -- is no live stack at exit).
      trace @?=
        [ InWindowCalled (MR.mrlpDemoKey planB)
        , CloseCalled
        , OpenCalled    (MR.mrlpDemoKey planA)
        ]

  , testCase
      "no overlapping stacks: close-before-open is the only transition shape"
      $ do
      -- Belt-and-suspenders: across the full recovery sequence,
      -- the trace must never show two consecutive OpenCalled
      -- entries without a CloseCalled between them. The
      -- supervisor's rebuild path always closes before opening;
      -- the bracket's finally always closes any active stack on
      -- exit. Mathematically: in any prefix of the trace, the
      -- count of OpenCalled minus the count of CloseCalled is
      -- never > 1 (the initial stack is implicit).
      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior = openOk
            , fspInWindowBehavior = inWindowOwnerSetupFailed
            }
          factory = mkStoppedAudioHostStackFactory ops
      _ <-
        withHostStackSupervisorAdapter factory stubStack $ \supOps ->
          reloadSupervised supOps planA planB
      trace <- readIORef traceRef

      let -- The initial stack is implicit: openCount starts at 1.
          activeAfter prefix =
            (1 + length [() | OpenCalled _ <- prefix])
              - length [() | CloseCalled <- prefix]
          prefixes = scanl (\acc c -> acc ++ [c]) [] trace
          actives = map activeAfter (drop 1 prefixes)
      -- Every prefix has at most one active stack.
      all (<= 1) actives @?= True
      -- And at least zero (no double-close in the middle).
      all (>= 0) actives @?= True

  , testCase
      "async throwTo during in-window closes the active stack before propagating"
      $ do
      -- Live racing against the §238 #9 invariant, this time
      -- with the production-shaped HostStackFactory. The
      -- supervisor's onException wrapper around sahsoInWindowReload
      -- runs the adapter's sopsCloseStack, which in turn calls
      -- the factory's sahsoClose. The trace must show CloseCalled
      -- before the exception escapes.
      readyToBlock  <- newEmptyMVar :: IO (MVar ())
      mayReturn     <- newEmptyMVar :: IO (MVar ())
      workerDone    <- newEmptyMVar :: IO (MVar (Either SomeException ()))
      traceRef      <- newIORef []

      let recordCall c = modifyIORef' traceRef (++ [c])
          fakeOps = StoppedAudioHostStackOps
            { sahsoOpen = \plan -> do
                recordCall (OpenCalled (MR.mrlpDemoKey plan))
                pure (Right stubStack)
            , sahsoClose = \_stack -> recordCall CloseCalled
            , sahsoInWindowReload = \_stack _fallback plan -> do
                recordCall (InWindowCalled (MR.mrlpDemoKey plan))
                putMVar readyToBlock ()
                takeMVar mayReturn
                pure InWindowReloadCommitted
            }
          factory = mkStoppedAudioHostStackFactory fakeOps

      workerTid <- forkIO $ do
        result <-
          try
            (withHostStackSupervisorAdapter factory stubStack $ \supOps ->
                void (reloadSupervised supOps planA planB))
        putMVar workerDone result

      takeMVar readyToBlock
      throwTo workerTid (ErrorCall "in-window-window-interrupt")
      _ <- forkIO (putMVar mayReturn ())

      result <- takeMVar workerDone
      trace  <- readIORef traceRef

      case result :: Either SomeException () of
        Left e ->
          case fromException e of
            Just (ErrorCall msg) ->
              msg @?= "in-window-window-interrupt"
            Nothing ->
              assertFailure ("unexpected exception type: " <> show e)
        Right () ->
          assertFailure "expected the async exception to propagate"

      -- The initial stack was the only live stack; the exception
      -- forced the supervisor's onException close to run, then
      -- the bracket's finally observed an empty ref and no-op'd.
      -- One CloseCalled total.
      let closes = [() | CloseCalled <- trace]
      length closes @?= 1
      -- No rebuild open ran (recovery path was preempted by the
      -- exception before sopsOpenStack was reached).
      [p | OpenCalled p <- trace] @?= []

  , testCase
      "A->B->C->D! factory-layer: failure from C falls back to C, never to B or A"
      $ do
      -- Re-pins the supervisor's §238 #2 "no remembered history"
      -- invariant at the production-shaped factory layer. The
      -- stack value carries no plan field (see the
      -- 'StoppedAudioHostStack' Haddock); plan ownership is the
      -- caller's. The caller threads currentPlan -> fallback
      -- forward on each successful reload. After A->B->C both
      -- commit, a failed C->D must rebuild from C (the plan
      -- the caller is tracking as current), not from B (one
      -- step back) or A (two steps back).
      --
      -- If a future refactor reintroduces a stack-level current-
      -- plan field that lags behind, this test catches the
      -- regression at the factory layer where it would actually
      -- surface in production wiring.
      let planC = mkPlan "third"
          planD = mkPlan "fourth"
          inWindowFailsOnD plan
            | MR.mrlpDemoKey plan == MR.mrlpDemoKey planD =
                pure (InWindowReloadTerminal (HsariReloadFailedNoOwner (MrhiIngress "d-failed")))
            | otherwise = pure InWindowReloadCommitted

      traceRef <- newIORef []
      let ops = mkFakeOps traceRef FakeStackPlan
            { fspOpenBehavior = openOk
            , fspInWindowBehavior = inWindowFailsOnD
            }
          factory = mkStoppedAudioHostStackFactory ops

      withHostStackSupervisorAdapter factory stubStack $ \supOps -> do
        -- A -> B commits.
        outcomeAB <- reloadSupervised supOps planA planB
        outcomeAB @?= SupervisedReloadCommitted

        -- B -> C commits. The caller threads currentPlan forward;
        -- the factory accumulates no per-stack history.
        outcomeBC <- reloadSupervised supOps planB planC
        outcomeBC @?= SupervisedReloadCommitted

        -- C -> D fails. The caller-supplied fallback is planC.
        -- Rebuild must target planC.
        outcomeCD <- reloadSupervised supOps planC planD
        outcomeCD @?=
          SupervisedReloadRejectedRecovered
            (SahsiInWindow
              (HsariReloadFailedNoOwner (MrhiIngress "d-failed")))

      trace <- readIORef traceRef
      let openedKeys = [k | OpenCalled k <- trace]
      -- The only OpenCalled in the whole sequence is from the
      -- C->D! rebuild, and it must target C — not B (one step
      -- back) and not A (two steps back).
      openedKeys @?= [MR.mrlpDemoKey planC]
      MR.mrlpDemoKey planA `notElem` openedKeys @?= True
      MR.mrlpDemoKey planB `notElem` openedKeys @?= True
  ]


-- | Tests that drive 'realStoppedAudioHostStackOps' through its
-- forward open path against a real (empty-graph) SessionFanInService
-- plus fake ingress ops + fake audio FFI. The four cases pin the
-- partial-cleanup contract the production helper added in step 2:
-- successful open, ingress-open failure, audio-start failure with
-- clean rollback, and audio-start failure with ingress-close-also-
-- fails surfacing 'SahsoiPartialCleanupFailed'.
realProductionHelperTests :: TestTree
realProductionHelperTests =
  testGroup "realStoppedAudioHostStackOps partial-cleanup paths"
  [ testCase
      "successful open returns Right; close releases the service and runs one ingress close"
      $ do
      ingressCloseCalls <- newIORef (0 :: Int)
      let inputs = mkProductionInputs
            (fakeIngressOpsOpenOk ingressCloseCalls)
            fakeAudioFFIStartOk
          ops = realStoppedAudioHostStackOps inputs
      result <- sahsoOpen ops (mkPlan "demo-key")
      case result of
        Left issue ->
          assertFailure ("expected Right, got Left: " <> show issue)
        Right stack -> do
          -- Close the live stack to release the SessionFanInService
          -- owner; otherwise the test process leaks an RTGraph.
          sahsoClose ops stack
          -- Close path called close-ingress exactly once during
          -- the forward shutdown.
          closeCount <- readIORef ingressCloseCalls
          closeCount @?= 1

  , testCase
      "ingress-open failure returns Left SahsoiIngressOpenFailed (service rolled back)"
      $ do
      ingressCloseCalls <- newIORef (0 :: Int)
      let inputs = mkProductionInputs
            (fakeIngressOpsOpenFails ingressCloseCalls)
            fakeAudioFFIStartOk
          ops = realStoppedAudioHostStackOps inputs
      result <- sahsoOpen ops (mkPlan "demo-key")
      case result of
        Left (SahsoiIngressOpenFailed "boom") -> do
          -- Ingress never opened, so close-ingress was never called.
          closeCount <- readIORef ingressCloseCalls
          closeCount @?= 0
        Left other ->
          assertFailure
            ("expected Left (SahsoiIngressOpenFailed \"boom\"), got Left: "
              <> show other)
        Right _stack ->
          assertFailure
            "expected Left (SahsoiIngressOpenFailed \"boom\"), got Right"

  , testCase
      "audio-start failure with clean ingress close returns Left SahsoiAudioStartFailed"
      $ do
      ingressCloseCalls <- newIORef (0 :: Int)
      let inputs = mkProductionInputs
            (fakeIngressOpsOpenOk ingressCloseCalls)
            fakeAudioFFIStartFails
          ops = realStoppedAudioHostStackOps inputs
      result <- sahsoOpen ops (mkPlan "demo-key")
      case result of
        Left (SahsoiAudioStartFailed (SfaiStartFailed (-1))) -> do
          -- Rollback closed the ingress manager exactly once.
          closeCount <- readIORef ingressCloseCalls
          closeCount @?= 1
        Left other ->
          assertFailure
            ("expected Left (SahsoiAudioStartFailed (SfaiStartFailed -1)), got Left: "
              <> show other)
        Right _stack ->
          assertFailure
            "expected Left (SahsoiAudioStartFailed (SfaiStartFailed -1)), got Right"

  , testCase
      "audio-start failure with ingress-close-also-fails surfaces SahsoiPartialCleanupFailed"
      $ do
      ingressCloseCalls <- newIORef (0 :: Int)
      let inputs = mkProductionInputs
            (fakeIngressOpsCloseFails ingressCloseCalls)
            fakeAudioFFIStartFails
          ops = realStoppedAudioHostStackOps inputs
      result <- sahsoOpen ops (mkPlan "demo-key")
      case result of
        Left
          (SahsoiPartialCleanupFailed
            (SahsoiAudioStartFailed (SfaiStartFailed (-1)))
            cleanupText) -> do
          -- The cleanup text mentions the ingress-close failure so
          -- the supervisor's escalation payload carries actionable
          -- diagnostics for both layers.
          ("ingress close" `subStr` show cleanupText) @?= True
          closeCount <- readIORef ingressCloseCalls
          closeCount @?= 1
        Left other ->
          assertFailure
            ("expected SahsoiPartialCleanupFailed (SahsoiAudioStartFailed ...), got Left: "
              <> show other)
        Right _stack ->
          assertFailure
            "expected SahsoiPartialCleanupFailed (SahsoiAudioStartFailed ...), got Right"

  , testCase
      "rollback after audio-start failure runs service close even when ingress close throws"
      $ do
      -- Pins the §7d3da25 fix: a throw from closeManifestReloadIngress
      -- during rollback must not skip closeSessionFanInService. The
      -- proof shape is the diagnostic itself — if the function
      -- returns SahsoiPartialCleanupFailed with the "ingress close
      -- threw" tag, then 'rollbackAudioStart' caught the throw via
      -- 'try' and continued running. The 'try @SomeException
      -- (closeSessionFanInService service)' immediately after is the
      -- only code that can produce that return value, so service
      -- close ran. A regression that re-introduces the
      -- "throw-skips-later-cleanup" shape would propagate the
      -- exception instead of returning SahsoiPartialCleanupFailed.
      ingressCloseCalls <- newIORef (0 :: Int)
      let inputs = mkProductionInputs
            (fakeIngressOpsCloseThrows ingressCloseCalls)
            fakeAudioFFIStartFails
          ops = realStoppedAudioHostStackOps inputs
      attempt <- try @SomeException (sahsoOpen ops (mkPlan "demo-key"))
      case attempt of
        Left ex ->
          assertFailure
            ("expected SahsoiPartialCleanupFailed return, but the \
             \ingress-close throw propagated: " <> show ex)
        Right result -> case result of
          Left
            (SahsoiPartialCleanupFailed
              (SahsoiAudioStartFailed (SfaiStartFailed (-1)))
              cleanupText) -> do
            ("ingress close threw" `subStr` show cleanupText) @?= True
            closeCount <- readIORef ingressCloseCalls
            closeCount @?= 1
          Left other ->
            assertFailure
              ("expected SahsoiPartialCleanupFailed wrapping audio-start \
               \with 'ingress close threw' diagnostic, got Left: "
                <> show other)
          Right _stack ->
            assertFailure
              "expected rollback path, got Right (open succeeded)"

  , testCase
      "realClose runs ingress and service close even when audio stop throws"
      $ do
      -- Pins the §7d3da25 fix on the close side: a throw from
      -- stopSessionFanInHostAudioWith must not skip the later
      -- closeManifestReloadIngress / closeSessionFanInService
      -- steps. After realClose runs, the first captured
      -- exception (audio's, by ordering) is re-thrown — the test
      -- catches it and asserts the ingress-close counter
      -- incremented anyway. A regression that short-circuits on
      -- the audio throw would leave the counter at 0.
      ingressCloseCalls <- newIORef (0 :: Int)
      let inputs = mkProductionInputs
            (fakeIngressOpsOpenOk ingressCloseCalls)
            fakeAudioFFIStopThrows
          ops = realStoppedAudioHostStackOps inputs
      openResult <- sahsoOpen ops (mkPlan "demo-key")
      case openResult of
        Left issue ->
          assertFailure ("expected Right open, got Left: " <> show issue)
        Right stack -> do
          closeAttempt <- try @SomeException (sahsoClose ops stack)
          case closeAttempt of
            Right () ->
              assertFailure
                "expected realClose to re-throw the audio-stop \
                \exception once every cleanup step had run"
            Left ex -> case fromException ex :: Maybe ErrorCall of
              Just (ErrorCall msg) ->
                msg @?= "synthetic audio stop crash"
              Nothing ->
                assertFailure
                  ("realClose re-threw an unexpected exception type: "
                    <> show ex)
          closeCount <- readIORef ingressCloseCalls
          closeCount @?= 1
  ]
  where
    subStr needle haystack =
      any (\i -> take (length needle) (drop i haystack) == needle)
        [0 .. length haystack - length needle]


-- | Build a 'RealStoppedAudioHostStackInputs' that pairs a real
-- (empty-graph) SessionFanInService open with caller-supplied
-- fake ingress ops + fake audio FFI. The non-essential dependencies
-- (target policy, owner options, service options/hooks, event sink)
-- are wired to library defaults.
mkProductionInputs
  :: ManifestReloadIngressOps ManifestReloadIngressTarget String ()
  -> SessionFanInAudioFFI
  -> RealStoppedAudioHostStackInputs String ()
mkProductionInputs ingressOps audioFFI = RealStoppedAudioHostStackInputs
  { rsahsiBuildIngressOps     = const ingressOps
  , rsahsiIngressTargetPolicy = testIngressTargetPolicy
  , rsahsiAudioFFI            = audioFFI
  , rsahsiAudioOptions        = testAudioOptions
  , rsahsiOwnerOptions        = defaultSessionOwnerOptions
  , rsahsiServiceOptions      = defaultSessionFanInServiceOptions
  , rsahsiServiceHooks        = defaultSessionFanInServiceHooks
  , rsahsiOnEvent             = \_ -> pure ()
  }


testIngressTargetPolicy :: ManifestReloadIngressTargetPolicy
testIngressTargetPolicy = ManifestReloadIngressTargetPolicy
  { mritpUIVoiceSelection = ManifestUIVoiceSelection
      { muvsFocusedVoice = Nothing
      , muvsDefaultVoice = VoiceKey "v0"
      }
  , mritpUIRetainedValues = M.empty
  , mritpMIDIDefaultVoice = VoiceKey "v0"
  }


-- | Audio options small enough to drive the start-FFI smoke
-- without staging real PortAudio state. The exact numbers don't
-- matter because the fake FFI ignores them.
testAudioOptions :: SessionFanInAudioOptions
testAudioOptions = SessionFanInAudioOptions
  { sfiaoOutputChannels = 2
  , sfiaoDeviceID       = 0
  , sfiaoReadyTimeoutMs = 100
  }


-- | Fake ingress ops where every open / close succeeds. The
-- close-call counter lets tests verify rollback ordering.
fakeIngressOpsOpenOk
  :: IORef Int
  -> ManifestReloadIngressOps ManifestReloadIngressTarget String ()
fakeIngressOpsOpenOk closeCounter = ManifestReloadIngressOps
  { mrioOpenIngress  = \_target -> pure (Right ())
  , mrioCloseIngress = \() -> do
      modifyIORef' closeCounter (+ 1)
      pure (Right ())
  }


-- | Fake ingress ops where 'mrioOpenIngress' returns Left "boom"
-- so 'realOpen' enters the rollback-ingress-open path.
fakeIngressOpsOpenFails
  :: IORef Int
  -> ManifestReloadIngressOps ManifestReloadIngressTarget String ()
fakeIngressOpsOpenFails closeCounter = ManifestReloadIngressOps
  { mrioOpenIngress  = \_target -> pure (Left "boom")
  , mrioCloseIngress = \() -> do
      modifyIORef' closeCounter (+ 1)
      pure (Right ())
  }


-- | Fake ingress ops where 'mrioOpenIngress' succeeds but
-- 'mrioCloseIngress' fails. Pairs with audio-start-fails to
-- exercise the 'SahsoiPartialCleanupFailed' path.
fakeIngressOpsCloseFails
  :: IORef Int
  -> ManifestReloadIngressOps ManifestReloadIngressTarget String ()
fakeIngressOpsCloseFails closeCounter = ManifestReloadIngressOps
  { mrioOpenIngress  = \_target -> pure (Right ())
  , mrioCloseIngress = \() -> do
      modifyIORef' closeCounter (+ 1)
      pure (Left "close-failed")
  }


-- | Fake audio FFI where 'saffiStartAudio' returns 0 (success).
fakeAudioFFIStartOk :: SessionFanInAudioFFI
fakeAudioFFIStartOk = SessionFanInAudioFFI
  { saffiStartAudio       = \_rt _sr _bs -> pure 0
  , saffiWaitAudioStarted = \_rt _to     -> pure True
  , saffiStopAudio        = \_rt         -> pure ()
  }


-- | Fake audio FFI where 'saffiStartAudio' returns -1, which
-- 'startSessionFanInHostAudioWith' translates to
-- 'SfaiStartFailed (-1)'.
fakeAudioFFIStartFails :: SessionFanInAudioFFI
fakeAudioFFIStartFails = SessionFanInAudioFFI
  { saffiStartAudio       = \_rt _sr _bs -> pure (-1)
  , saffiWaitAudioStarted = \_rt _to     -> pure True
  , saffiStopAudio        = \_rt         -> pure ()
  }


-- | Fake audio FFI where start succeeds but stop throws.
-- Used to pin the 'realClose' regression test: when audio stop
-- throws, the later ingress and service close steps must still
-- run.
fakeAudioFFIStopThrows :: SessionFanInAudioFFI
fakeAudioFFIStopThrows = SessionFanInAudioFFI
  { saffiStartAudio       = \_rt _sr _bs -> pure 0
  , saffiWaitAudioStarted = \_rt _to     -> pure True
  , saffiStopAudio        = \_rt         ->
      throwIO (ErrorCall "synthetic audio stop crash")
  }


-- | Tests for 'runSupervisedStoppedAudioReload', the
-- supervised stopped-audio CLI entry point. Pin the three
-- outcome shapes the 'SupervisedStoppedAudioReloadResult'
-- variants encode, plus the initial-open-failure 'Left'
-- shape that surfaces before the supervisor even runs. These
-- exercise the full lifecycle (factory + adapter + supervisor
-- + production helper) end-to-end against a real
-- 'SessionFanInService' plus fake ingress ops + fake audio FFI.
runSupervisedStoppedAudioReloadTests :: TestTree
runSupervisedStoppedAudioReloadTests =
  testGroup "runSupervisedStoppedAudioReload"
  [ testCase
      "successful supervised reload returns SsasrrCommitted"
      $ do
      ingressCloseCalls <- newIORef (0 :: Int)
      let inputs = mkProductionInputs
            (fakeIngressOpsOpenOk ingressCloseCalls)
            fakeAudioFFIStartOk
      result <-
        runSupervisedStoppedAudioReload
          inputs
          (mkPlan "fallback")
          (mkPlan "requested")
      result @?= Right SsasrrCommitted

  , testCase
      "initial open audio-start failure surfaces SahsiOpen Left before the supervisor runs"
      $ do
      ingressCloseCalls <- newIORef (0 :: Int)
      let inputs = mkProductionInputs
            (fakeIngressOpsOpenOk ingressCloseCalls)
            fakeAudioFFIStartFails
      result <-
        runSupervisedStoppedAudioReload
          inputs
          (mkPlan "fallback")
          (mkPlan "requested")
      case result of
        Left
          (SahsiOpen
            (SahsoiAudioStartFailed (SfaiStartFailed (-1)))) ->
          pure ()
        other ->
          assertFailure
            ("expected Left SahsiOpen (SahsoiAudioStartFailed -1), got: "
              <> show other)

  , testCase
      "in-window quiesce failure rebuilds from fallback (SsasrrRebuildRecovered)"
      $ do
      -- mrioCloseIngress returns Left so the orchestrator's
      -- quiesce-ingress step fails the in-window reload. The
      -- supervisor closes the failed stack (whose close swallows
      -- the ingress-close Left via attemptUnit) and rebuilds
      -- from the fallback plan (rebuild opens a fresh ingress
      -- handle, so the close failure isn't exercised). Outcome:
      -- SsasrrRebuildRecovered wrapping the in-window cause as
      -- SahsiInWindow.
      ingressCloseCalls <- newIORef (0 :: Int)
      let inputs = mkProductionInputs
            (fakeIngressOpsCloseFails ingressCloseCalls)
            fakeAudioFFIStartOk
      result <-
        runSupervisedStoppedAudioReload
          inputs
          (mkPlan "fallback")
          (mkPlan "requested")
      case result of
        Right (SsasrrRebuildRecovered (SahsiInWindow _)) ->
          pure ()
        other ->
          assertFailure
            ("expected Right (SsasrrRebuildRecovered (SahsiInWindow _)), got: "
              <> show other)
  ]


-- | Fake ingress ops where 'mrioOpenIngress' succeeds but
-- 'mrioCloseIngress' /throws/ (rather than returning 'Left').
-- Pairs with 'fakeAudioFFIStartFails' to pin the
-- 'rollbackAudioStart' regression test: when the ingress close
-- step throws during rollback, the service close step must still
-- run, and the function must surface 'SahsoiPartialCleanupFailed'
-- (proof that the throw was caught and processing continued).
fakeIngressOpsCloseThrows
  :: IORef Int
  -> ManifestReloadIngressOps ManifestReloadIngressTarget String ()
fakeIngressOpsCloseThrows closeCounter = ManifestReloadIngressOps
  { mrioOpenIngress  = \_target -> pure (Right ())
  , mrioCloseIngress = \() -> do
      modifyIORef' closeCounter (+ 1)
      throwIO (ErrorCall "synthetic ingress close crash")
  }


-- | Direct integration test for 'realStoppedAudioInWindowReload'.
--
-- The helper drives 'orchestrateHostStoppedAudioReloadWithEvents'
-- with @hsaroPreparePlan = const (pure (Right plan))@, and passes
-- intentionally empty doc + empty catalog through
-- 'manifestReloadHostOps'. If the override is ever removed (or
-- accidentally bypassed in a refactor), the default 'preparePlan'
-- would consult the empty doc / catalog and fail with
-- 'MrhiPlanning' because no demo matches the request's
-- 'mrlpDemoKey'. A successful reload against a non-default plan
-- therefore proves the plan-native short-circuit is in effect.
realInWindowReloadTests :: TestTree
realInWindowReloadTests =
  testGroup "realStoppedAudioInWindowReload plan-native short-circuit"
  [ testCase
      "supplied plan is installed despite empty doc/catalog (no MrhiPlanning)"
      $ do
      ingressCloseCalls <- newIORef (0 :: Int)
      let inputs = mkProductionInputs
            (fakeIngressOpsOpenOk ingressCloseCalls)
            fakeAudioFFIStartOk
          ops = realStoppedAudioHostStackOps inputs
      openResult <- sahsoOpen ops (mkPlan "initial")
      case openResult of
        Left issue ->
          assertFailure ("open failed: " <> show issue)
        Right stack -> do
          -- The "after-reload" plan's demo key is distinct from
          -- "initial" so any code path that re-derived a plan
          -- from doc/catalog (which is empty) would fail to find
          -- a matching demo and surface MrhiPlanning.
          let initialPlan = mkPlan "initial"
              newPlan     = mkPlan "after-reload"
          reloadResult <-
            realStoppedAudioInWindowReload
              testIngressTargetPolicy
              stack
              initialPlan
              newPlan
          sahsoClose ops stack
          case reloadResult of
            InWindowReloadCommitted ->
              -- Successful reload proves the override took effect:
              -- with empty doc/catalog and no override, planning
              -- would have failed before this point.
              pure ()
            InWindowReloadTerminal (HsariReloadFailedNoOwner (MrhiPlanning _)) ->
              assertFailure
                "realStoppedAudioInWindowReload re-derived plan \
                \from doc/catalog (observed MrhiPlanning); the \
                \plan-native override is broken or bypassed"
            InWindowReloadTerminal other ->
              assertFailure
                ("expected InWindowReloadCommitted, got an \
                 \unrelated downstream terminal failure: "
                  <> show other)
            InWindowReloadRejectedLiveFallback other ->
              -- Stopped-audio cannot produce this variant by
              -- construction; if the production helper ever does,
              -- that's the regression this branch catches.
              assertFailure
                ("realStoppedAudioInWindowReload produced \
                 \InWindowReloadRejectedLiveFallback, but the \
                 \stopped-audio path cannot return that variant: "
                  <> show other)
  ]
