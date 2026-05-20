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
-- never inspecting its config). The 'realStoppedAudioInWindowReload'
-- helper that production wiring will use lives in the module
-- under test; its real-session-layer composition is exercised by
-- the next slice (real strategy wiring), not here.
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
                                         (StoppedAudioHostStack (..),
                                          StoppedAudioHostStackIssue (..),
                                          StoppedAudioHostStackOpenIssue (..),
                                          StoppedAudioHostStackOps (..),
                                          mkStoppedAudioHostStackFactory)
import           MetaSonic.App.ManifestReloadOrchestration.Types
                                         (HostStoppedAudioReloadIssue (..))
import           MetaSonic.App.ManifestReloadSupervisor
                                         (SupervisedReloadOutcome (..),
                                          reloadSupervised)
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                         (withHostStackSupervisorAdapter)
import           MetaSonic.Bridge.Templates (TemplateGraph (..))
import           MetaSonic.Pattern              (SwapLabel (..))
import           MetaSonic.Session.Arbitration  (ArbitrationPolicy (..))
import           MetaSonic.Session.FanIn (SessionFanInAudioIssue (..))
import qualified MetaSonic.Session.ManifestReload as MR
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
-- supervisor adapter or the fake in-window slot); the installed
-- plan field is recorded so tests can inspect it if desired.
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
        Right () -> pure (Right (mkStubStack plan))
  , sahsoClose = \_stack -> record CloseCalled
  , sahsoInWindowReload = \_stack plan -> do
      record (InWindowCalled (MR.mrlpDemoKey plan))
      fspInWindowBehavior plans plan
  }
  where
    record c = modifyIORef' traceRef (++ [c])


-- | Stub stack: real 'sahsInstalledPlan', deferred 'sahsConfig'.
mkStubStack :: MR.ManifestReloadPlan -> TestStack
mkStubStack plan = StoppedAudioHostStack
  { sahsConfig =
      error
        "test placeholder: sahsConfig is intentionally undefined; \
        \fakes override sahsoInWindowReload so the config is never read"
  , sahsInstalledPlan = plan
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
  testGroup "App manifest reload host stack (stopped-audio factory)"
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
        withHostStackSupervisorAdapter factory (mkStubStack planA) $ \supOps ->
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
        withHostStackSupervisorAdapter factory (mkStubStack planA) $ \supOps ->
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
        withHostStackSupervisorAdapter factory (mkStubStack planA) $ \supOps ->
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
        withHostStackSupervisorAdapter factory (mkStubStack planA) $ \supOps ->
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
        withHostStackSupervisorAdapter factory (mkStubStack planA) $ \supOps ->
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
        withHostStackSupervisorAdapter factory (mkStubStack planA) $ \supOps ->
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
                pure (Right (mkStubStack plan))
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
            (withHostStackSupervisorAdapter factory (mkStubStack planA) $ \supOps ->
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
  ]
