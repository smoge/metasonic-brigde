{-# LANGUAGE DerivingStrategies #-}

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
-- @hsaroPreparePlan = const (pure (Right plan))@ so the
-- supervisor's plan is the source of truth at the seam. This
-- helper is **not** directly exercised by the tests in this
-- module: every test overrides @sahsoInWindowReload@ with a
-- fake to pin specific failure variants without staging a real
-- 'SessionFanInService'. The next slice (real strategy wiring)
-- owes an integration test that fails if
-- 'realStoppedAudioInWindowReload' ever re-enters catalog / doc
-- planning instead of taking the plan-native short-circuit
-- (i.e., that a forced doc/catalog/policy drift does not
-- influence which plan gets installed).
--
-- See notes/2026-05-14-k-host-reload-supervisor.md \xa7219 slice 4.
module MetaSonic.Spec.AppManifestReloadHostStack
  ( appManifestReloadHostStackTests
  ) where

import           Control.Concurrent      (forkIO)
import           Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar,
                                          takeMVar)
import           Control.Exception       (ErrorCall (..), SomeException,
                                          fromException, throwTo, try)
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
                                          mkStoppedAudioHostStackFactory,
                                          realStoppedAudioHostStackOps,
                                          realStoppedAudioInWindowReload)
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
                                         (SupervisedReloadOutcome (..),
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
            -> IO (Either
                    (HostStoppedAudioReloadIssue
                      (ManifestReloadHostIssue String))
                    ()))
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
  , sahsoInWindowReload = \_stack plan -> do
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
inWindowOk :: MR.ManifestReloadPlan -> IO (Either (HostStoppedAudioReloadIssue (ManifestReloadHostIssue String)) ())
inWindowOk _ = pure (Right ())

inWindowOwnerSetupFailed :: MR.ManifestReloadPlan -> IO (Either (HostStoppedAudioReloadIssue (ManifestReloadHostIssue String)) ())
inWindowOwnerSetupFailed _ =
  pure (Left (HsariReloadFailedNoOwner (MrhiIngress "owner-setup")))

inWindowAudioRestartFailed :: MR.ManifestReloadPlan -> IO (Either (HostStoppedAudioReloadIssue (ManifestReloadHostIssue String)) ())
inWindowAudioRestartFailed _ =
  pure (Left (HsariAudioRestartFailed (MrhiAudio (SfaiStartFailed (-1)))))

inWindowListenerRestartFailed :: MR.ManifestReloadPlan -> IO (Either (HostStoppedAudioReloadIssue (ManifestReloadHostIssue String)) ())
inWindowListenerRestartFailed _ =
  pure (Left (HsariListenerRestartFailed (MrhiIngress "listener-restart")))


appManifestReloadHostStackTests :: TestTree
appManifestReloadHostStackTests =
  testGroup "App manifest reload host stack"
  [ factoryCompositionTests
  , realProductionHelperTests
  , realInWindowReloadTests
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
            , sahsoInWindowReload = \_stack plan -> do
                recordCall (InWindowCalled (MR.mrlpDemoKey plan))
                putMVar readyToBlock ()
                takeMVar mayReturn
                pure (Right ())
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
                pure (Left (HsariReloadFailedNoOwner (MrhiIngress "d-failed")))
            | otherwise = pure (Right ())

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
      "successful open returns Right and close is a no-op on the stack"
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
  { rsahsiIngressOps          = ingressOps
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
          let newPlan = mkPlan "after-reload"
          reloadResult <- realStoppedAudioInWindowReload stack newPlan
          sahsoClose ops stack
          case reloadResult of
            Right () ->
              -- Successful reload proves the override took effect:
              -- with empty doc/catalog and no override, planning
              -- would have failed before this point.
              pure ()
            Left (HsariReloadFailedNoOwner (MrhiPlanning _)) ->
              assertFailure
                "realStoppedAudioInWindowReload re-derived plan \
                \from doc/catalog (observed MrhiPlanning); the \
                \plan-native override is broken or bypassed"
            Left other ->
              assertFailure
                ("expected Right (), got an unrelated downstream Left: "
                  <> show other)
  ]
