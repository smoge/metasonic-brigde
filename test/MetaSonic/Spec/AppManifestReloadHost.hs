-- | Deterministic tests for the host-facing stopped-audio manifest
-- reload command.

module MetaSonic.Spec.AppManifestReloadHost where

import           Control.Concurrent                  (MVar, newEmptyMVar,
                                                      putMVar, takeMVar)
import           Data.IORef                         (IORef, modifyIORef',
                                                     newIORef, readIORef)
import           System.Timeout                     (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.Demos
import           MetaSonic.App.ManifestReloadHost
import           MetaSonic.App.ManifestReloadIngress
import           MetaSonic.App.ManifestReloadOrchestration
import           MetaSonic.Authoring.Manifest
import           MetaSonic.Bridge.Templates        (Template (..),
                                                    TemplateGraph (..))
import           MetaSonic.Pattern                  (SwapLabel (..),
                                                     TemplateName (..),
                                                     VoiceKey (..))
import           MetaSonic.Session.AdapterIssue     (SessionAdapterSetupIssue (..))
import           MetaSonic.Session.Command          (SessionCommand (..))
import           MetaSonic.Session.FanIn
import           MetaSonic.Session.FanInService
import qualified MetaSonic.Session.ManifestReload   as MR
import           MetaSonic.Session.Owner            (SessionOwnerDivergence (..),
                                                     SessionOwnerStatus (..),
                                                     SessionOwnerStepResult (..),
                                                     defaultSessionOwnerOptions)
import           MetaSonic.Session.Queue            (ProducerId,
                                                     ProducerKind (..),
                                                     QueuedSessionCommand,
                                                     SessionDrainResult (..),
                                                     SessionDrainItem (..),
                                                     SessionEnqueueIssue (..),
                                                     SessionEnqueueResult (..))
import           MetaSonic.Session.Runtime          (SessionRuntimeIssue (..))
import           MetaSonic.Session.Step             (SessionStepResult (..))
import           MetaSonic.Session.State            (SessionState (..))
import           MetaSonic.Spec.SessionShared       (testProducer)


data TestTarget
  = OldTarget
  | NewTarget
  deriving (Eq, Show)

data TestHandle = TestHandle
  { thId     :: !Int
  , thTarget :: !TestTarget
  } deriving (Eq, Show)

data TestIngressIssue
  = TestOpenFailed !TestTarget
  | TestCloseFailed !TestHandle
  deriving (Eq, Show)

data TestEvent
  = AudioStart !Int !Int
  | AudioReady !Int
  | AudioStop
  | IngressOpened !TestHandle
  | IngressOpenFailed !TestTarget
  | IngressClosed !TestHandle
  | IngressCloseFailed !TestHandle
  deriving (Eq, Show)

data TestIngressState = TestIngressState
  { tisNextHandle :: !Int
  , tisFailOpen   :: !(Maybe TestTarget)
  , tisFailClose  :: !(Maybe Int)
  } deriving (Eq, Show)

data HostFixture = HostFixture
  { hfCatalog        :: ![MR.ManifestReloadCatalogEntry]
  , hfDoc            :: !AuthoringManifestDoc
  , hfRequest        :: !MR.ManifestReloadRequest
  , hfOldEntry       :: !MR.ManifestReloadCatalogEntry
  , hfNewEntry       :: !MR.ManifestReloadCatalogEntry
  , hfService        :: !SessionFanInService
  , hfIngressManager :: !(ManifestReloadIngressManager
                            TestTarget
                            TestIngressIssue
                            TestHandle)
  , hfEvents         :: !(IORef [TestEvent])
  , hfDrains         :: !(MVar SessionFanInDrainResult)
  }

appManifestReloadHostTests :: TestTree
appManifestReloadHostTests =
  testGroup "App manifest reload host command"
  [ testCase "success runs service drain, audio restart, owner reload, and ingress reopen" $
      withHostFixture initialTestIngressState $ \fixture -> do
        started <- startFixtureAudio fixture
        started @?= Right ()
        outcome <- reloadFixture fixture (hfRequest fixture)
        snapshot <- readSessionFanInService (hfService fixture)
        ingressSnapshot <-
          readManifestReloadIngressManager (hfIngressManager fixture)
        postEnq <-
          enqueueSessionFanInServiceCommand
            postReloadProducer
            postReloadCommand
            (hfService fixture)
        assertFanInEnqueued postEnq
        mPostDrain <- timeout 1000000 (takeMVar (hfDrains fixture))
        postSnapshot <- readSessionFanInService (hfService fixture)
        events <- readIORef (hfEvents fixture)
        outcome @?= Right ()
        ssGraph (sfisOwnerState snapshot) @?=
          MR.mrcTemplateGraph (hfNewEntry fixture)
        sfisQueueDepth snapshot @?= 0
        sfisAudioRunning snapshot @?= True
        ingressSnapshot @?= MrisOpen NewTarget (TestHandle 1 NewTarget)
        case mPostDrain of
          Just drained -> do
            sdrStopped (sfidrDrain drained) @?= Nothing
            sfidrQueueDepth drained @?= 0
          Nothing ->
            assertFailure "timed out waiting for post-reload service drain"
        sfisQueueDepth postSnapshot @?= 0
        events @?=
          [ AudioStart 2 (-1)
          , AudioReady 100
          , IngressClosed initialHandle
          , AudioStop
          , AudioStart 2 (-1)
          , AudioReady 100
          , IngressOpened (TestHandle 1 NewTarget)
          ]

  , testCase "plan failure leaves old audio and ingress running" $
      withHostFixture initialTestIngressState $ \fixture -> do
        started <- startFixtureAudio fixture
        started @?= Right ()
        let request = (hfRequest fixture)
              { MR.mrrDemoKey = "missing"
              }
        outcome <- reloadFixture fixture request
        snapshot <- readSessionFanInService (hfService fixture)
        ingressSnapshot <-
          readManifestReloadIngressManager (hfIngressManager fixture)
        events <- readIORef (hfEvents fixture)
        outcome @?=
          Left
            (HsariPlanRejected
              (MrhiPlanning (MR.MriUnknownManifestDemo "missing")))
        ssGraph (sfisOwnerState snapshot) @?=
          MR.mrcTemplateGraph (hfOldEntry fixture)
        sfisAudioRunning snapshot @?= True
        ingressSnapshot @?= MrisOpen OldTarget initialHandle
        events @?=
          [ AudioStart 2 (-1)
          , AudioReady 100
          ]

  , testCase "ingress close failure aborts before stop-audio" $
      withHostFixture
        initialTestIngressState
          { tisFailClose = Just (thId initialHandle)
          }
        $ \fixture -> do
            started <- startFixtureAudio fixture
            started @?= Right ()
            outcome <- reloadFixture fixture (hfRequest fixture)
            snapshot <- readSessionFanInService (hfService fixture)
            ingressSnapshot <-
              readManifestReloadIngressManager (hfIngressManager fixture)
            events <- readIORef (hfEvents fixture)
            outcome @?=
              Left
                (HsariQuiesceRejected
                  (MrhiIngress (TestCloseFailed initialHandle)))
            ssGraph (sfisOwnerState snapshot) @?=
              MR.mrcTemplateGraph (hfOldEntry fixture)
            sfisAudioRunning snapshot @?= True
            ingressSnapshot @?= MrisOpen OldTarget initialHandle
            events @?=
              [ AudioStart 2 (-1)
              , AudioReady 100
              , IngressCloseFailed initialHandle
              ]

  , testCase "new ingress open failure stops new audio and leaves manager closed" $
      withHostFixture
        initialTestIngressState
          { tisFailOpen = Just NewTarget
          }
        $ \fixture -> do
            started <- startFixtureAudio fixture
            started @?= Right ()
            outcome <- reloadFixture fixture (hfRequest fixture)
            snapshot <- readSessionFanInService (hfService fixture)
            ingressSnapshot <-
              readManifestReloadIngressManager (hfIngressManager fixture)
            postRejected <-
              enqueueSessionFanInServiceCommand
                postReloadProducer
                postReloadCommand
                (hfService fixture)
            events <- readIORef (hfEvents fixture)
            outcome @?=
              Left
                (HsariListenerRestartFailed
                  (MrhiIngress (TestOpenFailed NewTarget)))
            ssGraph (sfisOwnerState snapshot) @?=
              MR.mrcTemplateGraph (hfNewEntry fixture)
            sfisAudioRunning snapshot @?= False
            ingressSnapshot @?= MrisClosed
            sfierResult postRejected @?=
              SessionEnqueueRejected
                postReloadProducer
                postReloadCommand
                SeiReloadInProgress
            events @?=
              [ AudioStart 2 (-1)
              , AudioReady 100
              , IngressClosed initialHandle
              , AudioStop
              , AudioStart 2 (-1)
              , AudioReady 100
              , IngressOpenFailed NewTarget
              , AudioStop
              ]

  , testCase "terminal service drain failure does not reopen old ingress" $
      withHostFixture initialTestIngressState $ \fixture -> do
        started <- startFixtureAudio fixture
        started @?= Right ()
        preDrain <- quiesceAndDrainSessionFanInService (hfService fixture)
        sfidrQueueDepth preDrain @?= 0
        let setupIssue =
              SasiDuplicateTemplateName (TemplateName "dup")
            divergedReason =
              SodHotSwapInstallFailed setupIssue
            badGraph =
              duplicateFirstTwoTemplates (MR.mrcTemplateGraph (hfNewEntry fixture))
            badCmd =
              CmdHotSwap (SwapLabel "bad-graph") badGraph
        enq <-
          enqueueSessionFanInCommand
            postReloadProducer
            badCmd
            (sessionFanInServiceHost (hfService fixture))
        queued <- fanInQueuedOrFail enq
        outcome <- reloadFixture fixture (hfRequest fixture)
        snapshot <- readSessionFanInService (hfService fixture)
        ingressSnapshot <-
          readManifestReloadIngressManager (hfIngressManager fixture)
        events <- readIORef (hfEvents fixture)
        case outcome of
          Left (HsariDrainFailedTerminal (MrhiDrainStopped stopped)) ->
            assertTerminalDrain setupIssue divergedReason queued stopped
          other ->
            assertFailure
              ("expected terminal host drain failure, got: " <> show other)
        ssGraph (sfisOwnerState snapshot) @?=
          MR.mrcTemplateGraph (hfOldEntry fixture)
        sfisOwnerStatus snapshot @?= SessionOwnerDiverged divergedReason
        sfisAudioRunning snapshot @?= True
        ingressSnapshot @?= MrisClosed
        events @?=
          [ AudioStart 2 (-1)
          , AudioReady 100
          , IngressClosed initialHandle
          ]
  ]

withHostFixture
  :: TestIngressState
  -> (HostFixture -> IO a)
  -> IO a
withHostFixture ingressState action = do
  catalog <- catalogOrFail demoTable
  oldEntry <- entryOrFail "named-control" catalog
  newEntry <- entryOrFail "send-return" catalog
  events <- newIORef []
  drains <- newEmptyMVar
  ingressRef <- newIORef ingressState
  ingressManager <-
    newManifestReloadIngressManager
      ManifestReloadIngressOps
        { mrioOpenIngress =
            openIngress events ingressRef
        , mrioCloseIngress =
            closeIngress events ingressRef
        }
      OldTarget
      initialHandle
  result <-
    withSessionFanInServiceHooks
      defaultSessionFanInServiceHooks
        { sfshOnDrain =
            putMVar drains
        }
      (MR.mrcTemplateGraph oldEntry)
      defaultSessionFanInServiceOptions
      $ \service ->
          action HostFixture
            { hfCatalog =
                catalog
            , hfDoc =
                AuthoringManifestDoc
                  manifestSchemaVersion
                  [MR.mrcManifest newEntry]
            , hfRequest =
                MR.ManifestReloadRequest
                  { MR.mrrDemoKey =
                      "send-return"
                  , MR.mrrSwapLabel =
                      SwapLabel "host-command"
                  , MR.mrrResourcePolicy =
                      MR.defaultManifestResourcePolicy
                  }
            , hfOldEntry =
                oldEntry
            , hfNewEntry =
                newEntry
            , hfService =
                service
            , hfIngressManager =
                ingressManager
            , hfEvents =
                events
            , hfDrains =
                drains
            }
  case result of
    Left issue ->
      assertFailure ("expected fan-in service, got: " <> show issue)
    Right value ->
      pure value

reloadFixture
  :: HostFixture
  -> MR.ManifestReloadRequest
  -> IO (Either
          (HostStoppedAudioReloadIssue
            (ManifestReloadHostIssue TestIngressIssue))
          ())
reloadFixture fixture =
  reloadManifestStoppedAudioHost
    (fixtureConfig fixture)
    (hfDoc fixture)
    (hfCatalog fixture)

fixtureConfig
  :: HostFixture
  -> ManifestReloadHostConfig TestTarget TestIngressIssue TestHandle
fixtureConfig fixture = ManifestReloadHostConfig
  { mrhcService =
      hfService fixture
  , mrhcIngressManager =
      hfIngressManager fixture
  , mrhcOldIngressTarget =
      OldTarget
  , mrhcNewIngressTarget =
      NewTarget
  , mrhcAudioFFI =
      audioFFI (hfEvents fixture)
  , mrhcAudioOptions =
      audioOptions
  , mrhcOwnerOptions =
      defaultSessionOwnerOptions
  }

startFixtureAudio
  :: HostFixture
  -> IO (Either SessionFanInAudioIssue ())
startFixtureAudio fixture =
  startSessionFanInHostAudioWith
    (audioFFI (hfEvents fixture))
    (sessionFanInServiceHost (hfService fixture))
    audioOptions

audioOptions :: SessionFanInAudioOptions
audioOptions = SessionFanInAudioOptions
  { sfiaoOutputChannels = 2
  , sfiaoDeviceID       = -1
  , sfiaoReadyTimeoutMs = 100
  }

audioFFI :: IORef [TestEvent] -> SessionFanInAudioFFI
audioFFI events = SessionFanInAudioFFI
  { saffiStartAudio =
      \_rt outputChannels deviceID -> do
        appendEvent events (AudioStart outputChannels deviceID)
        pure 0
  , saffiWaitAudioStarted =
      \_rt timeoutMs -> do
        appendEvent events (AudioReady timeoutMs)
        pure True
  , saffiStopAudio =
      \_rt ->
        appendEvent events AudioStop
  }

initialHandle :: TestHandle
initialHandle =
  TestHandle 0 OldTarget

initialTestIngressState :: TestIngressState
initialTestIngressState = TestIngressState
  { tisNextHandle = 1
  , tisFailOpen = Nothing
  , tisFailClose = Nothing
  }

openIngress
  :: IORef [TestEvent]
  -> IORef TestIngressState
  -> TestTarget
  -> IO (Either TestIngressIssue TestHandle)
openIngress events stateRef target = do
  state <- readIORef stateRef
  if tisFailOpen state == Just target
    then do
      appendEvent events (IngressOpenFailed target)
      pure (Left (TestOpenFailed target))
    else do
      let handle = TestHandle (tisNextHandle state) target
      modifyIORef' stateRef $ \state' ->
        state'
          { tisNextHandle =
              tisNextHandle state' + 1
          }
      appendEvent events (IngressOpened handle)
      pure (Right handle)

closeIngress
  :: IORef [TestEvent]
  -> IORef TestIngressState
  -> TestHandle
  -> IO (Either TestIngressIssue ())
closeIngress events stateRef handle = do
  state <- readIORef stateRef
  if tisFailClose state == Just (thId handle)
    then do
      appendEvent events (IngressCloseFailed handle)
      pure (Left (TestCloseFailed handle))
    else do
      appendEvent events (IngressClosed handle)
      pure (Right ())

appendEvent :: IORef [TestEvent] -> TestEvent -> IO ()
appendEvent ref event =
  modifyIORef' ref (<> [event])

postReloadProducer :: ProducerId
postReloadProducer =
  testProducer ProducerUI "post-reload"

postReloadCommand :: SessionCommand
postReloadCommand =
  CmdVoiceOn (TemplateName "voice") (VoiceKey "post") []

assertFanInEnqueued :: SessionFanInEnqueueResult -> Assertion
assertFanInEnqueued result =
  case sfierResult result of
    SessionEnqueued _queued ->
      pure ()
    other ->
      assertFailure ("expected fan-in enqueue success, got: " <> show other)

fanInQueuedOrFail :: SessionFanInEnqueueResult -> IO QueuedSessionCommand
fanInQueuedOrFail result =
  case sfierResult result of
    SessionEnqueued queued ->
      pure queued
    other ->
      assertFailure ("expected fan-in enqueue success, got: " <> show other)

assertTerminalDrain
  :: SessionAdapterSetupIssue
  -> SessionOwnerDivergence
  -> QueuedSessionCommand
  -> SessionFanInDrainResult
  -> Assertion
assertTerminalDrain setupIssue divergedReason queued stopped = do
  sdrItems (sfidrDrain stopped) @?=
    [ SessionDrainItem
        queued
        (SessionOwnerDivergedNow
          (StepRuntimeFailed (SriHotSwapInstallFailed setupIssue))
          divergedReason)
    ]
  sdrRemaining (sfidrDrain stopped) @?= 0
  sdrStopped (sfidrDrain stopped) @?= Just divergedReason
  sfidrQueueDepth stopped @?= 0

duplicateFirstTwoTemplates :: TemplateGraph -> TemplateGraph
duplicateFirstTwoTemplates base =
  case tgTemplates base of
    (a : b : rest) ->
      base
        { tgTemplates =
            a { tplName = "dup" }
            : b { tplName = "dup" }
            : rest
        }
    _ ->
      base

catalogOrFail :: [Demo] -> IO [MR.ManifestReloadCatalogEntry]
catalogOrFail demos =
  case demoManifestReloadCatalog demos of
    Right catalog -> pure catalog
    Left err ->
      assertFailure ("expected app demo catalog, got: " <> err)

entryOrFail
  :: String
  -> [MR.ManifestReloadCatalogEntry]
  -> IO MR.ManifestReloadCatalogEntry
entryOrFail key catalog =
  case [ entry | entry <- catalog, MR.mrcDemoKey entry == key ] of
    [entry] -> pure entry
    []      -> assertFailure ("missing catalog entry: " <> key)
    _       -> assertFailure ("duplicate catalog entry: " <> key)
