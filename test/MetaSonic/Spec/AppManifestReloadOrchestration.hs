-- | Fake-IO tests for the host stopped-audio manifest reload window.
--
-- The tests pin the ordering and failure states from
-- notes/2026-05-14-j-host-stopped-audio-manifest-reload-orchestration.md
-- without touching PortAudio or concrete listener brackets.

module MetaSonic.Spec.AppManifestReloadOrchestration where

import           Data.IORef                                  (IORef,
                                                              modifyIORef',
                                                              newIORef,
                                                              readIORef)
import           Data.List                                   (elemIndex)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestReloadIngress
import           MetaSonic.App.ManifestReloadOrchestration


data FakeFailure
  = FakePlanRejected
  | FakeQuiesceRejected
  | FakeDrainRejected
  | FakeDrainStopped
  | FakeStopOldAudioFailed
  | FakeQueueNotEmpty
  | FakeOwnerSetupFailed
  | FakeAudioRestartFailed
  | FakeListenerRestartFailed
  | FakeOldAudioRestartFailed
  | FakeResumeOldIngressFailed
  deriving (Eq, Show)

data FakeOwner
  = FakeOldOwner
  | FakeNewOwner
  | FakeNoOwner
  deriving (Eq, Show)

data FakeState = FakeState
  { fsOwner         :: !FakeOwner
  , fsAudioRunning  :: !Bool
  , fsIngressOpen   :: !Bool
  , fsQueueDepth    :: !Int
  , fsFinalizerSend :: !Bool
  , fsResumeFails   :: !Bool
  , fsFailureMode   :: !(Maybe FakeFailureMode)
  , fsTrace         :: ![FakeEvent]
  } deriving (Eq, Show)

data FakeFailureMode
  = FailPlan
  | FailQuiesce
  | FailDrain
  | FailDrainTerminal
  | FailStopOldAudio
  | FailReloadQueueNotEmpty
  | FailReloadOwnerSetup
  | FailRestartOldAudio
  | FailStartNewAudio
  | FailReopenIngress
  deriving (Eq, Show)

data FakeEvent
  = PreparePlan !String
  | CloseIngress
  | DrainLive !Int
  | StopOldAudio
  | ReloadStopped !String
  | RestartOldAudio
  | ResumeOldIngress
  | StartNewAudio
  | ReopenIngress
  | StopNewAudio
  deriving (Eq, Show)

data FakeIngressTarget
  = FakeOldIngressTarget
  | FakeNewIngressTarget
  deriving (Eq, Show)

data FakeIngressHandle = FakeIngressHandle
  { fihId     :: !Int
  , fihTarget :: !FakeIngressTarget
  } deriving (Eq, Show)

data FakeIngressEvent
  = FakeIngressClosed !FakeIngressHandle
  | FakeIngressCloseFailed !FakeIngressHandle
  | FakeIngressOpened !FakeIngressHandle
  | FakeIngressOpenFailed !FakeIngressTarget
  deriving (Eq, Show)

data FakeIngressState = FakeIngressState
  { fisNextHandle :: !Int
  , fisFailOpen   :: !(Maybe FakeIngressTarget)
  , fisFailClose  :: !(Maybe Int)
  , fisEvents     :: ![FakeIngressEvent]
  } deriving (Eq, Show)


appManifestReloadOrchestrationTests :: TestTree
appManifestReloadOrchestrationTests =
  testGroup "App manifest reload orchestration"
  [ testCase "plan failure leaves old audio and ingress running" $ do
      (ops, ref) <- mkFakeOps initialFakeState
        { fsFailureMode = Just FailPlan
        }
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      state <- readIORef ref
      outcome @?= Left (HsariPlanRejected FakePlanRejected)
      fsOwner state @?= FakeOldOwner
      fsAudioRunning state @?= True
      fsIngressOpen state @?= True
      fsTrace state @?= [PreparePlan requestedPlan]

  , testCase "quiesce failure aborts before stop-audio" $ do
      (ops, ref) <- mkFakeOps initialFakeState
        { fsFailureMode = Just FailQuiesce
        }
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      state <- readIORef ref
      outcome @?= Left (HsariQuiesceRejected FakeQuiesceRejected)
      fsOwner state @?= FakeOldOwner
      fsAudioRunning state @?= True
      fsIngressOpen state @?= True
      StopOldAudio `elem` fsTrace state @?= False
      fsTrace state @?=
        [ PreparePlan requestedPlan
        , CloseIngress
        , ResumeOldIngress
        ]

  , testCase "quiesce failure reports resume failure if old ingress cannot reopen" $ do
      (ops, ref) <- mkFakeOps initialFakeState
        { fsFailureMode = Just FailQuiesce
        , fsResumeFails = True
        }
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      state <- readIORef ref
      outcome @?=
        Left
          (HsariQuiesceRejectedResumeFailed
            FakeQuiesceRejected
            FakeResumeOldIngressFailed)
      fsOwner state @?= FakeOldOwner
      fsAudioRunning state @?= True
      fsIngressOpen state @?= False
      StopOldAudio `elem` fsTrace state @?= False

  , testCase "drain failure aborts before stop-audio and reopens ingress" $ do
      (ops, ref) <- mkFakeOps initialFakeState
        { fsFailureMode = Just FailDrain
        }
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      state <- readIORef ref
      outcome @?= Left (HsariDrainRejected FakeDrainRejected)
      fsOwner state @?= FakeOldOwner
      fsAudioRunning state @?= True
      fsIngressOpen state @?= True
      StopOldAudio `elem` fsTrace state @?= False
      fsTrace state @?=
        [ PreparePlan requestedPlan
        , CloseIngress
        , DrainLive 0
        , ResumeOldIngress
        ]

  , testCase "drain failure reports resume failure and leaves ingress closed" $ do
      (ops, ref) <- mkFakeOps initialFakeState
        { fsFailureMode = Just FailDrain
        , fsResumeFails = True
        }
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      state <- readIORef ref
      outcome @?=
        Left
          (HsariDrainRejectedResumeFailed
            FakeDrainRejected
            FakeResumeOldIngressFailed)
      fsOwner state @?= FakeOldOwner
      fsAudioRunning state @?= True
      fsIngressOpen state @?= False
      StopOldAudio `elem` fsTrace state @?= False

  , testCase "terminal drain failure does not resume ingress" $ do
      (ops, ref) <- mkFakeOps initialFakeState
        { fsFailureMode = Just FailDrainTerminal
        }
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      state <- readIORef ref
      outcome @?= Left (HsariDrainFailedTerminal FakeDrainStopped)
      fsOwner state @?= FakeOldOwner
      fsAudioRunning state @?= True
      fsIngressOpen state @?= False
      StopOldAudio `elem` fsTrace state @?= False
      ResumeOldIngress `elem` fsTrace state @?= False
      fsTrace state @?=
        [ PreparePlan requestedPlan
        , CloseIngress
        , DrainLive 0
        ]

  , testCase "stop-old-audio failure aborts before owner reload" $ do
      (ops, ref) <- mkFakeOps initialFakeState
        { fsFailureMode = Just FailStopOldAudio
        }
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      state <- readIORef ref
      outcome @?= Left (HsariStopOldAudioFailed FakeStopOldAudioFailed)
      fsOwner state @?= FakeOldOwner
      fsAudioRunning state @?= True
      fsIngressOpen state @?= False
      ReloadStopped preparedPlan `elem` fsTrace state @?= False

  , testCase "listener finalizer commands drain before stop-audio" $ do
      (ops, ref) <- mkFakeOps initialFakeState
        { fsFinalizerSend = True
        }
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      state <- readIORef ref
      outcome @?= Right ()
      assertBefore (fsTrace state) (DrainLive 1) StopOldAudio
      fsQueueDepth state @?= 0

  , testCase "successful path runs the stopped-audio sequence in order" $ do
      (ops, ref) <- mkFakeOps initialFakeState
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      state <- readIORef ref
      outcome @?= Right ()
      fsOwner state @?= FakeNewOwner
      fsAudioRunning state @?= True
      fsIngressOpen state @?= True
      fsTrace state @?=
        [ PreparePlan requestedPlan
        , CloseIngress
        , DrainLive 0
        , StopOldAudio
        , ReloadStopped preparedPlan
        , StartNewAudio
        , ReopenIngress
        ]

  , testCase "queue-not-empty reload rejection restarts old audio" $ do
      (ops, ref) <- mkFakeOps initialFakeState
        { fsFailureMode = Just FailReloadQueueNotEmpty
        }
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      state <- readIORef ref
      outcome @?=
        Left (HsariReloadRejectedOldOwnerRestarted FakeQueueNotEmpty)
      fsOwner state @?= FakeOldOwner
      fsAudioRunning state @?= True
      fsIngressOpen state @?= True
      fsTrace state @?=
        [ PreparePlan requestedPlan
        , CloseIngress
        , DrainLive 0
        , StopOldAudio
        , ReloadStopped preparedPlan
        , RestartOldAudio
        , ResumeOldIngress
        ]

  , testCase "queue-not-empty old-owner recovery reports resume failure" $ do
      (ops, ref) <- mkFakeOps initialFakeState
        { fsFailureMode = Just FailReloadQueueNotEmpty
        , fsResumeFails = True
        }
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      state <- readIORef ref
      outcome @?=
        Left
          (HsariReloadRejectedOldOwnerResumeFailed
            FakeQueueNotEmpty
            FakeResumeOldIngressFailed)
      fsOwner state @?= FakeOldOwner
      fsAudioRunning state @?= True
      fsIngressOpen state @?= False
      fsTrace state @?=
        [ PreparePlan requestedPlan
        , CloseIngress
        , DrainLive 0
        , StopOldAudio
        , ReloadStopped preparedPlan
        , RestartOldAudio
        , ResumeOldIngress
        ]

  , testCase "old audio restart failure preserves both causes" $ do
      (ops, ref) <- mkFakeOps initialFakeState
        { fsFailureMode = Just FailRestartOldAudio
        }
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      state <- readIORef ref
      outcome @?=
        Left
          (HsariReloadRejectedOldOwnerRestartFailed
            FakeQueueNotEmpty
            FakeOldAudioRestartFailed)
      fsOwner state @?= FakeOldOwner
      fsAudioRunning state @?= False
      fsIngressOpen state @?= False

  , testCase "owner setup failure leaves no owner and audio stopped" $ do
      (ops, ref) <- mkFakeOps initialFakeState
        { fsFailureMode = Just FailReloadOwnerSetup
        }
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      state <- readIORef ref
      outcome @?= Left (HsariReloadFailedNoOwner FakeOwnerSetupFailed)
      fsOwner state @?= FakeNoOwner
      fsAudioRunning state @?= False
      fsIngressOpen state @?= False

  , testCase "audio restart failure leaves new owner installed and ingress closed" $ do
      (ops, ref) <- mkFakeOps initialFakeState
        { fsFailureMode = Just FailStartNewAudio
        }
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      state <- readIORef ref
      outcome @?= Left (HsariAudioRestartFailed FakeAudioRestartFailed)
      fsOwner state @?= FakeNewOwner
      fsAudioRunning state @?= False
      fsIngressOpen state @?= False

  , testCase "listener reopen failure stops new audio and keeps ingress closed" $ do
      (ops, ref) <- mkFakeOps initialFakeState
        { fsFailureMode = Just FailReopenIngress
        }
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      state <- readIORef ref
      outcome @?=
        Left (HsariListenerRestartFailed FakeListenerRestartFailed)
      fsOwner state @?= FakeNewOwner
      fsAudioRunning state @?= False
      fsIngressOpen state @?= False
      fsTrace state @?=
        [ PreparePlan requestedPlan
        , CloseIngress
        , DrainLive 0
        , StopOldAudio
        , ReloadStopped preparedPlan
        , StartNewAudio
        , ReopenIngress
        , StopNewAudio
        ]

  , testCase
      "ingress manager wiring closes old ingress and opens new on success" $ do
      (ops0, hostRef) <- mkFakeOps initialFakeState
      (manager, ingressRef) <-
        mkFakeIngressManager hostRef initialFakeIngressState
      let ops =
            wireManifestReloadIngress
              manager
              FakeOldIngressTarget
              FakeNewIngressTarget
              ops0
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      hostState <- readIORef hostRef
      ingressSnapshot <- readManifestReloadIngressManager manager
      ingressEvents <- fisEvents <$> readIORef ingressRef
      outcome @?= Right ()
      ingressSnapshot @?=
        MrisOpen
          FakeNewIngressTarget
          (FakeIngressHandle 1 FakeNewIngressTarget)
      ingressEvents @?=
        [ FakeIngressClosed initialFakeIngressHandle
        , FakeIngressOpened (FakeIngressHandle 1 FakeNewIngressTarget)
        ]
      fsTrace hostState @?=
        [ PreparePlan requestedPlan
        , CloseIngress
        , DrainLive 0
        , StopOldAudio
        , ReloadStopped preparedPlan
        , StartNewAudio
        , ReopenIngress
        ]

  , testCase
      "ingress manager wiring keeps old ingress open when close fails" $ do
      (ops0, hostRef) <- mkFakeOps initialFakeState
      (manager, ingressRef) <-
        mkFakeIngressManager hostRef initialFakeIngressState
          { fisFailClose = Just (fihId initialFakeIngressHandle)
          }
      let ops =
            wireManifestReloadIngress
              manager
              FakeOldIngressTarget
              FakeNewIngressTarget
              ops0
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      hostState <- readIORef hostRef
      ingressSnapshot <- readManifestReloadIngressManager manager
      ingressEvents <- fisEvents <$> readIORef ingressRef
      outcome @?= Left (HsariQuiesceRejected FakeQuiesceRejected)
      fsIngressOpen hostState @?= True
      ingressSnapshot @?= MrisOpen FakeOldIngressTarget initialFakeIngressHandle
      ingressEvents @?= [FakeIngressCloseFailed initialFakeIngressHandle]
      fsTrace hostState @?=
        [ PreparePlan requestedPlan
        , CloseIngress
        ]

  , testCase
      "ingress manager wiring resumes old ingress on retryable reload" $ do
      (ops0, hostRef) <- mkFakeOps initialFakeState
        { fsFailureMode = Just FailReloadQueueNotEmpty
        }
      (manager, ingressRef) <-
        mkFakeIngressManager hostRef initialFakeIngressState
      let ops =
            wireManifestReloadIngress
              manager
              FakeOldIngressTarget
              FakeNewIngressTarget
              ops0
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      hostState <- readIORef hostRef
      ingressSnapshot <- readManifestReloadIngressManager manager
      ingressEvents <- fisEvents <$> readIORef ingressRef
      outcome @?=
        Left (HsariReloadRejectedOldOwnerRestarted FakeQueueNotEmpty)
      ingressSnapshot @?=
        MrisOpen
          FakeOldIngressTarget
          (FakeIngressHandle 1 FakeOldIngressTarget)
      ingressEvents @?=
        [ FakeIngressClosed initialFakeIngressHandle
        , FakeIngressOpened (FakeIngressHandle 1 FakeOldIngressTarget)
        ]
      fsTrace hostState @?=
        [ PreparePlan requestedPlan
        , CloseIngress
        , DrainLive 0
        , StopOldAudio
        , ReloadStopped preparedPlan
        , RestartOldAudio
        , ResumeOldIngress
        ]

  , testCase
      "ingress manager wiring leaves manager closed when new open fails" $ do
      (ops0, hostRef) <- mkFakeOps initialFakeState
      (manager, ingressRef) <-
        mkFakeIngressManager hostRef initialFakeIngressState
          { fisFailOpen = Just FakeNewIngressTarget
          }
      let ops =
            wireManifestReloadIngress
              manager
              FakeOldIngressTarget
              FakeNewIngressTarget
              ops0
      outcome <- orchestrateHostStoppedAudioReload ops requestedPlan
      hostState <- readIORef hostRef
      ingressSnapshot <- readManifestReloadIngressManager manager
      ingressEvents <- fisEvents <$> readIORef ingressRef
      outcome @?= Left (HsariListenerRestartFailed FakeListenerRestartFailed)
      ingressSnapshot @?= MrisClosed
      ingressEvents @?=
        [ FakeIngressClosed initialFakeIngressHandle
        , FakeIngressOpenFailed FakeNewIngressTarget
        ]
      fsAudioRunning hostState @?= False
      fsTrace hostState @?=
        [ PreparePlan requestedPlan
        , CloseIngress
        , DrainLive 0
        , StopOldAudio
        , ReloadStopped preparedPlan
        , StartNewAudio
        , ReopenIngress
        , StopNewAudio
        ]
  ]


mkFakeOps
  :: FakeState
  -> IO ( HostStoppedAudioReloadOps String String FakeFailure
        , IORef FakeState
        )
mkFakeOps state0 = do
  ref <- newIORef state0
  let ops = HostStoppedAudioReloadOps
        { hsaroPreparePlan =
            preparePlan ref
        , hsaroQuiesceIngress =
            quiesceIngress ref
        , hsaroDrainLive =
            drainLive ref
        , hsaroStopOldAudio =
            stopOldAudio ref
        , hsaroReloadStopped =
            reloadStopped ref
        , hsaroRestartOldAudio =
            restartOldAudio ref
        , hsaroResumeOldIngress =
            resumeOldIngress ref
        , hsaroStartNewAudio =
            startNewAudio ref
        , hsaroReopenIngress =
            reopenIngress ref
        , hsaroStopNewAudio =
            stopNewAudio ref
        }
  pure (ops, ref)

initialFakeState :: FakeState
initialFakeState = FakeState
  { fsOwner = FakeOldOwner
  , fsAudioRunning = True
  , fsIngressOpen = True
  , fsQueueDepth = 0
  , fsFinalizerSend = False
  , fsResumeFails = False
  , fsFailureMode = Nothing
  , fsTrace = []
  }

requestedPlan, preparedPlan :: String
requestedPlan = "requested"
preparedPlan = "prepared:requested"

preparePlan
  :: IORef FakeState
  -> String
  -> IO (Either FakeFailure String)
preparePlan ref request = do
  appendTrace ref (PreparePlan request)
  mode <- fsFailureMode <$> readIORef ref
  pure $ case mode of
    Just FailPlan ->
      Left FakePlanRejected
    _ ->
      Right ("prepared:" <> request)

quiesceIngress :: IORef FakeState -> IO (Either FakeFailure ())
quiesceIngress ref = do
  appendTrace ref CloseIngress
  mode <- fsFailureMode <$> readIORef ref
  case mode of
    Just FailQuiesce -> do
      modifyIORef' ref $ \state -> state { fsIngressOpen = False }
      pure (Left FakeQuiesceRejected)
    _ -> do
      modifyIORef' ref $ \state ->
        state
          { fsIngressOpen =
              False
          , fsQueueDepth =
              fsQueueDepth state + if fsFinalizerSend state then 1 else 0
          }
      pure (Right ())

drainLive
  :: IORef FakeState
  -> IO (Either (HostStoppedAudioDrainFailure FakeFailure) ())
drainLive ref = do
  state <- readIORef ref
  appendTrace ref (DrainLive (fsQueueDepth state))
  mode <- fsFailureMode <$> readIORef ref
  case mode of
    Just FailDrain ->
      pure (Left (HsadfRetryable FakeDrainRejected))
    Just FailDrainTerminal ->
      pure (Left (HsadfTerminal FakeDrainStopped))
    _ -> do
      modifyIORef' ref $ \state' -> state' { fsQueueDepth = 0 }
      pure (Right ())

stopOldAudio :: IORef FakeState -> IO (Either FakeFailure ())
stopOldAudio ref = do
  appendTrace ref StopOldAudio
  mode <- fsFailureMode <$> readIORef ref
  case mode of
    Just FailStopOldAudio ->
      pure (Left FakeStopOldAudioFailed)
    _ -> do
      modifyIORef' ref $ \state -> state { fsAudioRunning = False }
      pure (Right ())

reloadStopped
  :: IORef FakeState
  -> String
  -> IO (Either (HostStoppedAudioReloadFailure FakeFailure) ())
reloadStopped ref plan = do
  appendTrace ref (ReloadStopped plan)
  mode <- fsFailureMode <$> readIORef ref
  case mode of
    Just FailReloadQueueNotEmpty ->
      pure (Left (HsarfOldOwnerStillInstalled FakeQueueNotEmpty))
    Just FailRestartOldAudio ->
      pure (Left (HsarfOldOwnerStillInstalled FakeQueueNotEmpty))
    Just FailReloadOwnerSetup -> do
      modifyIORef' ref $ \state -> state { fsOwner = FakeNoOwner }
      pure (Left (HsarfNoOwner FakeOwnerSetupFailed))
    _ -> do
      modifyIORef' ref $ \state -> state { fsOwner = FakeNewOwner }
      pure (Right ())

restartOldAudio :: IORef FakeState -> IO (Either FakeFailure ())
restartOldAudio ref = do
  appendTrace ref RestartOldAudio
  mode <- fsFailureMode <$> readIORef ref
  case mode of
    Just FailRestartOldAudio ->
      pure (Left FakeOldAudioRestartFailed)
    _ -> do
      modifyIORef' ref $ \state -> state { fsAudioRunning = True }
      pure (Right ())

resumeOldIngress :: IORef FakeState -> IO (Either FakeFailure ())
resumeOldIngress ref = do
  appendTrace ref ResumeOldIngress
  shouldFail <- fsResumeFails <$> readIORef ref
  if shouldFail
    then pure (Left FakeResumeOldIngressFailed)
    else do
      modifyIORef' ref $ \state -> state { fsIngressOpen = True }
      pure (Right ())

startNewAudio :: IORef FakeState -> IO (Either FakeFailure ())
startNewAudio ref = do
  appendTrace ref StartNewAudio
  mode <- fsFailureMode <$> readIORef ref
  case mode of
    Just FailStartNewAudio ->
      pure (Left FakeAudioRestartFailed)
    _ -> do
      modifyIORef' ref $ \state -> state { fsAudioRunning = True }
      pure (Right ())

reopenIngress :: IORef FakeState -> IO (Either FakeFailure ())
reopenIngress ref = do
  appendTrace ref ReopenIngress
  mode <- fsFailureMode <$> readIORef ref
  case mode of
    Just FailReopenIngress ->
      pure (Left FakeListenerRestartFailed)
    _ -> do
      modifyIORef' ref $ \state -> state { fsIngressOpen = True }
      pure (Right ())

stopNewAudio :: IORef FakeState -> IO ()
stopNewAudio ref = do
  appendTrace ref StopNewAudio
  modifyIORef' ref $ \state -> state { fsAudioRunning = False }

mkFakeIngressManager
  :: IORef FakeState
  -> FakeIngressState
  -> IO ( ManifestReloadIngressManager
            FakeIngressTarget
            FakeFailure
            FakeIngressHandle
        , IORef FakeIngressState
        )
mkFakeIngressManager hostRef state0 = do
  ingressRef <- newIORef state0
  manager <-
    newManifestReloadIngressManager
      ManifestReloadIngressOps
        { mrioOpenIngress =
            openFakeIngress hostRef ingressRef
        , mrioCloseIngress =
            closeFakeIngress hostRef ingressRef
        }
      FakeOldIngressTarget
      initialFakeIngressHandle
  pure (manager, ingressRef)

initialFakeIngressHandle :: FakeIngressHandle
initialFakeIngressHandle =
  FakeIngressHandle 0 FakeOldIngressTarget

initialFakeIngressState :: FakeIngressState
initialFakeIngressState = FakeIngressState
  { fisNextHandle = 1
  , fisFailOpen = Nothing
  , fisFailClose = Nothing
  , fisEvents = []
  }

openFakeIngress
  :: IORef FakeState
  -> IORef FakeIngressState
  -> FakeIngressTarget
  -> IO (Either FakeFailure FakeIngressHandle)
openFakeIngress hostRef ingressRef target = do
  ingressState <- readIORef ingressRef
  if fisFailOpen ingressState == Just target
    then do
      appendIngressEvent ingressRef (FakeIngressOpenFailed target)
      recordIngressTrace hostRef (openIngressTrace target) False
      pure (Left (openIngressIssue target))
    else do
      let handle =
            FakeIngressHandle (fisNextHandle ingressState) target
      modifyIORef' ingressRef $ \state ->
        state
          { fisNextHandle =
              fisNextHandle state + 1
          , fisEvents =
              fisEvents state <> [FakeIngressOpened handle]
          }
      recordIngressTrace hostRef (openIngressTrace target) True
      pure (Right handle)

closeFakeIngress
  :: IORef FakeState
  -> IORef FakeIngressState
  -> FakeIngressHandle
  -> IO (Either FakeFailure ())
closeFakeIngress hostRef ingressRef handle = do
  ingressState <- readIORef ingressRef
  if fisFailClose ingressState == Just (fihId handle)
    then do
      appendIngressEvent ingressRef (FakeIngressCloseFailed handle)
      recordIngressTrace hostRef CloseIngress True
      pure (Left FakeQuiesceRejected)
    else do
      appendIngressEvent ingressRef (FakeIngressClosed handle)
      recordIngressTrace hostRef CloseIngress False
      pure (Right ())

openIngressTrace :: FakeIngressTarget -> FakeEvent
openIngressTrace target =
  case target of
    FakeOldIngressTarget ->
      ResumeOldIngress
    FakeNewIngressTarget ->
      ReopenIngress

openIngressIssue :: FakeIngressTarget -> FakeFailure
openIngressIssue target =
  case target of
    FakeOldIngressTarget ->
      FakeResumeOldIngressFailed
    FakeNewIngressTarget ->
      FakeListenerRestartFailed

recordIngressTrace :: IORef FakeState -> FakeEvent -> Bool -> IO ()
recordIngressTrace ref event open =
  modifyIORef' ref $ \state ->
    state
      { fsIngressOpen =
          open
      , fsTrace =
          fsTrace state <> [event]
      }

appendIngressEvent
  :: IORef FakeIngressState
  -> FakeIngressEvent
  -> IO ()
appendIngressEvent ref event =
  modifyIORef' ref $ \state ->
    state { fisEvents = fisEvents state <> [event] }

appendTrace :: IORef FakeState -> FakeEvent -> IO ()
appendTrace ref event =
  modifyIORef' ref $ \state ->
    state { fsTrace = fsTrace state <> [event] }

assertBefore :: (Eq a, Show a) => [a] -> a -> a -> Assertion
assertBefore values earlier later =
  case (elemIndex earlier values, elemIndex later values) of
    (Just i, Just j) ->
      assertBool
        (show earlier <> " should appear before " <> show later)
        (i < j)
    _ ->
      assertFailure
        ("expected both " <> show earlier <> " and "
         <> show later <> " in " <> show values)
