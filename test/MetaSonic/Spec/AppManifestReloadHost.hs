-- | Deterministic tests for host-facing manifest reload commands.

module MetaSonic.Spec.AppManifestReloadHost where

import           Control.Concurrent                  (MVar, newEmptyMVar,
                                                      putMVar, takeMVar)
import qualified Data.Map.Strict                    as M
import           Data.IORef                         (IORef, modifyIORef',
                                                     newIORef, readIORef)
import           System.Timeout                     (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.Demos
import           MetaSonic.App.ManifestReloadEvent
import           MetaSonic.App.ManifestReloadHost
import           MetaSonic.App.ManifestReloadIngress
import           MetaSonic.App.ManifestReloadOrchestration
import           MetaSonic.Authoring.Manifest
import           MetaSonic.Bridge.Source          (MigrationKey (..),
                                                   SynthGraph)
import           MetaSonic.Bridge.Templates        (Template (..),
                                                    TemplateGraph (..),
                                                    compileTemplateGraph)
import           MetaSonic.Pattern                  (ControlTag (..),
                                                     Pattern (..),
                                                     SwapLabel (..),
                                                     TemplateName (..),
                                                     VoiceKey (..))
import           MetaSonic.Pattern.Corpus           (hotSwapEdit,
                                                     hotSwapEditAfterTemplates)
import           MetaSonic.Session.AdapterIssue     (SessionAdapterSetupIssue (..))
import           MetaSonic.Session.Command          (SessionCommand (..))
import           MetaSonic.Session.FanIn
import           MetaSonic.Session.FanInService
import qualified MetaSonic.Session.ManifestReload   as MR
import           MetaSonic.Session.ManifestReload.Runtime
                                                    (ManifestPreservingHotSwapReport (..))
import           MetaSonic.Session.Owner            (SessionOwnerDivergence (..),
                                                     SessionOwnerStatus (..),
                                                     SessionOwnerStepResult (..),
                                                     defaultSessionOwnerOptions)
import           MetaSonic.Session.Queue            (ProducerId,
                                                     ProducerKind (..),
                                                     QueuedSessionCommand (..),
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

  , testCase "preserving reload keeps audio running and reopens fresh ingress" $
      withPreservingHostFixture initialTestIngressState $ \fixture -> do
        started <- startFixtureAudio fixture
        started @?= Right ()
        startPreservingVoice fixture
        outcome <- reloadPreservingFixture fixture (hfRequest fixture)
        snapshot <- readSessionFanInService (hfService fixture)
        ingressSnapshot <-
          readManifestReloadIngressManager (hfIngressManager fixture)
        postEnq <-
          enqueueSessionFanInServiceCommand
            postReloadProducer
            preservingPostReloadCommand
            (hfService fixture)
        events <- readIORef (hfEvents fixture)
        outcome @?= Right ()
        ssGraph (sfisOwnerState snapshot) @?=
          MR.mrcTemplateGraph (hfNewEntry fixture)
        assertBool
          "expected active voice to survive preserving reload"
          (M.member preservingVoiceKey (ssVoices (sfisOwnerState snapshot)))
        sfisQueueDepth snapshot @?= 0
        sfisAudioRunning snapshot @?= True
        ingressSnapshot @?= MrisOpen NewTarget (TestHandle 1 NewTarget)
        assertFanInEnqueued postEnq
        events @?=
          [ AudioStart 2 (-1)
          , AudioReady 100
          , IngressClosed initialHandle
          , IngressOpened (TestHandle 1 NewTarget)
          ]

  , testCase "preserving reload rejection resumes old ingress without stopping audio" $
      withHostFixture initialTestIngressState $ \fixture -> do
        started <- startFixtureAudio fixture
        started @?= Right ()
        outcome <- reloadPreservingFixture fixture (hfRequest fixture)
        snapshot <- readSessionFanInService (hfService fixture)
        ingressSnapshot <-
          readManifestReloadIngressManager (hfIngressManager fixture)
        events <- readIORef (hfEvents fixture)
        case outcome of
          Left (HpariReloadRejected (MrhiPreservingReloadRejected report)) ->
            assertPreservingRuntimeRejected report
          other ->
            assertFailure
              ("expected preserving reload rejection, got: " <> show other)
        ssGraph (sfisOwnerState snapshot) @?=
          MR.mrcTemplateGraph (hfOldEntry fixture)
        sfisAudioRunning snapshot @?= True
        ingressSnapshot @?= MrisOpen OldTarget (TestHandle 1 OldTarget)
        events @?=
          [ AudioStart 2 (-1)
          , AudioReady 100
          , IngressClosed initialHandle
          , IngressOpened (TestHandle 1 OldTarget)
          ]

  , testCase "preserving fresh ingress failure leaves new graph live" $
      withPreservingHostFixture
        initialTestIngressState
          { tisFailOpen = Just NewTarget
          }
        $ \fixture -> do
            started <- startFixtureAudio fixture
            started @?= Right ()
            startPreservingVoice fixture
            outcome <- reloadPreservingFixture fixture (hfRequest fixture)
            snapshot <- readSessionFanInService (hfService fixture)
            ingressSnapshot <-
              readManifestReloadIngressManager (hfIngressManager fixture)
            postEnq <-
              enqueueSessionFanInServiceCommand
                postReloadProducer
                preservingPostReloadCommand
                (hfService fixture)
            assertFanInEnqueued postEnq
            mPostDrain <- timeout 1000000 (takeMVar (hfDrains fixture))
            postSnapshot <- readSessionFanInService (hfService fixture)
            events <- readIORef (hfEvents fixture)
            outcome @?=
              Left
                (HpariIngressRestartFailed
                  (MrhiIngress (TestOpenFailed NewTarget)))
            ssGraph (sfisOwnerState snapshot) @?=
              MR.mrcTemplateGraph (hfNewEntry fixture)
            assertBool
              "expected active voice to survive preserving reload"
              (M.member preservingVoiceKey (ssVoices (sfisOwnerState snapshot)))
            sfisQueueDepth snapshot @?= 0
            sfisAudioRunning snapshot @?= True
            ingressSnapshot @?= MrisClosed
            case mPostDrain of
              Just drained -> do
                sdrStopped (sfidrDrain drained) @?= Nothing
                sfidrQueueDepth drained @?= 0
              Nothing ->
                assertFailure
                  "timed out waiting for post-failure service drain"
            sfisQueueDepth postSnapshot @?= 0
            events @?=
              [ AudioStart 2 (-1)
              , AudioReady 100
              , IngressClosed initialHandle
              , IngressOpenFailed NewTarget
              ]

  , testCase "preserving terminal service drain failure does not reopen old ingress" $
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
        outcome <- reloadPreservingFixture fixture (hfRequest fixture)
        snapshot <- readSessionFanInService (hfService fixture)
        ingressSnapshot <-
          readManifestReloadIngressManager (hfIngressManager fixture)
        events <- readIORef (hfEvents fixture)
        case outcome of
          Left (HpariDrainFailedTerminal (MrhiDrainStopped stopped)) ->
            assertTerminalDrain setupIssue divergedReason queued stopped
          other ->
            assertFailure
              ("expected terminal preserving host drain failure, got: "
               <> show other)
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

  , testCase "strategy stopped-audio-only runs stopped-audio reload" $
      withHostFixture initialTestIngressState $ \fixture -> do
        started <- startFixtureAudio fixture
        started @?= Right ()
        outcome <-
          reloadStrategyFixture
            StoppedAudioOnly
            fixture
            (hfRequest fixture)
        snapshot <- readSessionFanInService (hfService fixture)
        ingressSnapshot <-
          readManifestReloadIngressManager (hfIngressManager fixture)
        events <- readIORef (hfEvents fixture)
        outcome @?= Right MrhsrStoppedAudio
        ssGraph (sfisOwnerState snapshot) @?=
          MR.mrcTemplateGraph (hfNewEntry fixture)
        sfisAudioRunning snapshot @?= True
        ingressSnapshot @?= MrisOpen NewTarget (TestHandle 1 NewTarget)
        events @?=
          [ AudioStart 2 (-1)
          , AudioReady 100
          , IngressClosed initialHandle
          , AudioStop
          , AudioStart 2 (-1)
          , AudioReady 100
          , IngressOpened (TestHandle 1 NewTarget)
          ]

  , testCase "strategy require-preserving rejects without stopped-audio fallback" $
      withHostFixture initialTestIngressState $ \fixture -> do
        started <- startFixtureAudio fixture
        started @?= Right ()
        outcome <-
          reloadStrategyFixture
            RequirePreserving
            fixture
            (hfRequest fixture)
        snapshot <- readSessionFanInService (hfService fixture)
        ingressSnapshot <-
          readManifestReloadIngressManager (hfIngressManager fixture)
        events <- readIORef (hfEvents fixture)
        case outcome of
          Left
            (MrhsiPreservingFailed
              issue@(HpariReloadRejected (MrhiPreservingReloadRejected report))) -> do
                assertPreservingRuntimeRejected report
                issue @?= HpariReloadRejected (MrhiPreservingReloadRejected report)
          other ->
            assertFailure
              ("expected require-preserving rejection, got: " <> show other)
        ssGraph (sfisOwnerState snapshot) @?=
          MR.mrcTemplateGraph (hfOldEntry fixture)
        sfisAudioRunning snapshot @?= True
        ingressSnapshot @?= MrisOpen OldTarget (TestHandle 1 OldTarget)
        events @?=
          [ AudioStart 2 (-1)
          , AudioReady 100
          , IngressClosed initialHandle
          , IngressOpened (TestHandle 1 OldTarget)
          ]

  , testCase "strategy try-preserving falls back to stopped-audio after retryable rejection" $
      withHostFixture initialTestIngressState $ \fixture -> do
        started <- startFixtureAudio fixture
        started @?= Right ()
        outcome <-
          reloadStrategyFixture
            TryPreservingThenStoppedAudio
            fixture
            (hfRequest fixture)
        snapshot <- readSessionFanInService (hfService fixture)
        ingressSnapshot <-
          readManifestReloadIngressManager (hfIngressManager fixture)
        events <- readIORef (hfEvents fixture)
        case outcome of
          Right
            (MrhsrStoppedAudioAfterPreservingRejected
              (HpariReloadRejected (MrhiPreservingReloadRejected report))) ->
                assertPreservingRuntimeRejected report
          other ->
            assertFailure
              ("expected preserving-to-stopped fallback success, got: "
               <> show other)
        ssGraph (sfisOwnerState snapshot) @?=
          MR.mrcTemplateGraph (hfNewEntry fixture)
        sfisAudioRunning snapshot @?= True
        ingressSnapshot @?= MrisOpen NewTarget (TestHandle 2 NewTarget)
        events @?=
          [ AudioStart 2 (-1)
          , AudioReady 100
          , IngressClosed initialHandle
          , IngressOpened (TestHandle 1 OldTarget)
          , IngressClosed (TestHandle 1 OldTarget)
          , AudioStop
          , AudioStart 2 (-1)
          , AudioReady 100
          , IngressOpened (TestHandle 2 NewTarget)
          ]

  , testCase "strategy try-preserving preserves stopped-audio failure cause after fallback" $
      withHostFixture
        initialTestIngressState
          { tisFailOpen = Just NewTarget
          }
        $ \fixture -> do
            started <- startFixtureAudio fixture
            started @?= Right ()
            outcome <-
              reloadStrategyFixture
                TryPreservingThenStoppedAudio
                fixture
                (hfRequest fixture)
            snapshot <- readSessionFanInService (hfService fixture)
            ingressSnapshot <-
              readManifestReloadIngressManager (hfIngressManager fixture)
            events <- readIORef (hfEvents fixture)
            case outcome of
              Left
                (MrhsiFallbackStoppedAudioFailed
                  (HpariReloadRejected
                    (MrhiPreservingReloadRejected report))
                  (HsariListenerRestartFailed
                    (MrhiIngress (TestOpenFailed NewTarget)))) ->
                      assertPreservingRuntimeRejected report
              other ->
                assertFailure
                  ("expected fallback listener failure with both causes, got: "
                   <> show other)
            ssGraph (sfisOwnerState snapshot) @?=
              MR.mrcTemplateGraph (hfNewEntry fixture)
            sfisAudioRunning snapshot @?= False
            ingressSnapshot @?= MrisClosed
            events @?=
              [ AudioStart 2 (-1)
              , AudioReady 100
              , IngressClosed initialHandle
              , IngressOpened (TestHandle 1 OldTarget)
              , IngressClosed (TestHandle 1 OldTarget)
              , AudioStop
              , AudioStart 2 (-1)
              , AudioReady 100
              , IngressOpenFailed NewTarget
              , AudioStop
              ]

  , testCase "strategy try-preserving does not fall back after preserving installs graph" $
      withPreservingHostFixture
        initialTestIngressState
          { tisFailOpen = Just NewTarget
          }
        $ \fixture -> do
            started <- startFixtureAudio fixture
            started @?= Right ()
            startPreservingVoice fixture
            outcome <-
              reloadStrategyFixture
                TryPreservingThenStoppedAudio
                fixture
                (hfRequest fixture)
            snapshot <- readSessionFanInService (hfService fixture)
            ingressSnapshot <-
              readManifestReloadIngressManager (hfIngressManager fixture)
            events <- readIORef (hfEvents fixture)
            outcome @?=
              Left
                (MrhsiPreservingFailed
                  (HpariIngressRestartFailed
                    (MrhiIngress (TestOpenFailed NewTarget))))
            ssGraph (sfisOwnerState snapshot) @?=
              MR.mrcTemplateGraph (hfNewEntry fixture)
            assertBool
              "expected active voice to survive preserving reload"
              (M.member preservingVoiceKey (ssVoices (sfisOwnerState snapshot)))
            sfisAudioRunning snapshot @?= True
            ingressSnapshot @?= MrisClosed
            events @?=
              [ AudioStart 2 (-1)
              , AudioReady 100
              , IngressClosed initialHandle
              , IngressOpenFailed NewTarget
              ]

  , testCase "strategy fallback gate allows only plain preserving reload rejection" $ do
      let allowed =
            HpariReloadRejected strategyProbeIssue
          rejected =
            [ HpariPlanRejected strategyProbeIssue
            , HpariQuiesceRejected strategyProbeIssue
            , HpariQuiesceRejectedResumeFailed
                strategyProbeIssue
                strategyProbeIssue
            , HpariDrainRejected strategyProbeIssue
            , HpariDrainRejectedResumeFailed
                strategyProbeIssue
                strategyProbeIssue
            , HpariDrainFailedTerminal strategyProbeIssue
            , HpariReloadRejectedResumeFailed
                strategyProbeIssue
                strategyProbeIssue
            , HpariReloadFailedTerminal strategyProbeIssue
            , HpariIngressRestartFailed strategyProbeIssue
            ]
      preservingAllowsStoppedAudioFallback allowed @?= True
      map preservingAllowsStoppedAudioFallback rejected @?=
        replicate (length rejected) False
  ]

withHostFixture
  :: TestIngressState
  -> (HostFixture -> IO a)
  -> IO a
withHostFixture ingressState action = do
  catalog <- catalogOrFail demoTable
  oldEntry <- entryOrFail "named-control" catalog
  newEntry <- entryOrFail "send-return" catalog
  withHostFixtureEntries
    ingressState
    catalog
    oldEntry
    newEntry
    (AuthoringManifestDoc manifestSchemaVersion [MR.mrcManifest newEntry])
    MR.ManifestReloadRequest
      { MR.mrrDemoKey =
          "send-return"
      , MR.mrrSwapLabel =
          SwapLabel "host-command"
      , MR.mrrResourcePolicy =
          MR.defaultManifestResourcePolicy
      }
    action

withPreservingHostFixture
  :: TestIngressState
  -> (HostFixture -> IO a)
  -> IO a
withPreservingHostFixture ingressState action = do
  let oldEntry = preservingOldEntry
      newEntry = preservingNewEntry
      catalog = [newEntry]
  withHostFixtureEntries
    ingressState
    catalog
    oldEntry
    newEntry
    (AuthoringManifestDoc manifestSchemaVersion [MR.mrcManifest newEntry])
    MR.ManifestReloadRequest
      { MR.mrrDemoKey =
          "hot-swap-after"
      , MR.mrrSwapLabel =
          SwapLabel "host-preserving"
      , MR.mrrResourcePolicy =
          MR.defaultManifestResourcePolicy
      }
    action

withHostFixtureEntries
  :: TestIngressState
  -> [MR.ManifestReloadCatalogEntry]
  -> MR.ManifestReloadCatalogEntry
  -> MR.ManifestReloadCatalogEntry
  -> AuthoringManifestDoc
  -> MR.ManifestReloadRequest
  -> (HostFixture -> IO a)
  -> IO a
withHostFixtureEntries ingressState catalog oldEntry newEntry doc request action = do
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
                doc
            , hfRequest =
                request
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

reloadPreservingFixture
  :: HostFixture
  -> MR.ManifestReloadRequest
  -> IO (Either
          (HostPreservingReloadIssue
            (ManifestReloadHostIssue TestIngressIssue))
          ())
reloadPreservingFixture fixture =
  reloadManifestPreservingHost
    preservingReloadProducer
    (fixtureConfig fixture)
    (hfDoc fixture)
    (hfCatalog fixture)

reloadStrategyFixture
  :: ManifestReloadHostStrategy
  -> HostFixture
  -> MR.ManifestReloadRequest
  -> IO (Either
          (ManifestReloadHostStrategyIssue
            (ManifestReloadHostIssue TestIngressIssue))
          (ManifestReloadHostStrategyRan
            (ManifestReloadHostIssue TestIngressIssue)))
reloadStrategyFixture strategy fixture =
  reloadManifestHostWithStrategy
    preservingReloadProducer
    strategy
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
  , mrhcOnEvent =
      noManifestReloadEvents
  , mrhcOnRetired =
      \_ -> pure ()
  }

startFixtureAudio
  :: HostFixture
  -> IO (Either SessionFanInAudioIssue ())
startFixtureAudio fixture =
  startSessionFanInHostAudioWith
    (audioFFI (hfEvents fixture))
    (sessionFanInServiceHost (hfService fixture))
    audioOptions

startPreservingVoice :: HostFixture -> IO ()
startPreservingVoice fixture = do
  enqueued <-
    enqueueSessionFanInServiceCommand
      preservingVoiceProducer
      preservingVoiceOnCommand
      (hfService fixture)
  assertFanInEnqueued enqueued
  mDrain <- timeout 1000000 (takeMVar (hfDrains fixture))
  case mDrain of
    Nothing ->
      assertFailure "timed out waiting for preserving voice-start drain"
    Just drained -> do
      sdrStopped (sfidrDrain drained) @?= Nothing
      sfidrQueueDepth drained @?= 0
      case sdrItems (sfidrDrain drained) of
        [ SessionDrainItem
            _
            (SessionOwnerStep (StepCommitted state Nothing))
          ] ->
            assertBool
              "expected preserving fixture voice to start"
              (M.member preservingVoiceKey (ssVoices state))
        other ->
          assertFailure
            ("expected preserving voice-start commit, got: " <> show other)

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
  , saffiStopAudioFade =
      \_rt _fadeMs ->
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

preservingReloadProducer :: ProducerId
preservingReloadProducer =
  testProducer ProducerUI "manifest-preserving"

preservingVoiceProducer :: ProducerId
preservingVoiceProducer =
  testProducer ProducerPattern "pattern"

postReloadCommand :: SessionCommand
postReloadCommand =
  CmdVoiceOn (TemplateName "voice") (VoiceKey "post") []

preservingPostReloadCommand :: SessionCommand
preservingPostReloadCommand =
  CmdVoiceOn (TemplateName "drone") (VoiceKey "post") []

preservingVoiceKey :: VoiceKey
preservingVoiceKey =
  VoiceKey "v0"

preservingVoiceOnCommand :: SessionCommand
preservingVoiceOnCommand =
  CmdVoiceOn
    (TemplateName "drone")
    preservingVoiceKey
    [(ControlTag (MigrationKey "lpf") 0, 1500.0)]

strategyProbeIssue :: ManifestReloadHostIssue TestIngressIssue
strategyProbeIssue =
  MrhiPlanning (MR.MriUnknownManifestDemo "probe")

preservingOldEntry :: MR.ManifestReloadCatalogEntry
preservingOldEntry = MR.ManifestReloadCatalogEntry
  { MR.mrcDemoKey =
      "hot-swap-before"
  , MR.mrcManifest =
      preservingManifest "hot-swap-before"
  , MR.mrcTemplateGraph =
      patternTemplates hotSwapEdit
  }

preservingNewEntry :: MR.ManifestReloadCatalogEntry
preservingNewEntry = MR.ManifestReloadCatalogEntry
  { MR.mrcDemoKey =
      "hot-swap-after"
  , MR.mrcManifest =
      preservingManifest "hot-swap-after"
  , MR.mrcTemplateGraph =
      compileTemplateGraphOrError hotSwapEditAfterTemplates
  }

preservingManifest :: String -> AuthoringManifest
preservingManifest key = AuthoringManifest
  { mfDemoKey =
      key
  , mfTemplates =
      [ManifestTemplate "drone" "voice"]
  , mfBuses =
      []
  , mfControls =
      []
  }

compileTemplateGraphOrError :: [(String, SynthGraph)] -> TemplateGraph
compileTemplateGraphOrError rows =
  case compileTemplateGraph rows of
    Right graph ->
      graph
    Left err ->
      error ("compileTemplateGraph failed: " <> err)

assertFanInEnqueued :: SessionFanInEnqueueResult -> Assertion
assertFanInEnqueued result =
  case sfierResult result of
    SessionEnqueued _queued ->
      pure ()
    other ->
      assertFailure ("expected fan-in enqueue success, got: " <> show other)

assertPreservingRuntimeRejected
  :: ManifestPreservingHotSwapReport
  -> Assertion
assertPreservingRuntimeRejected report = do
  case sfierResult (mphsrEnqueueResult report) of
    SessionEnqueued queued ->
      qscCommand queued @?= mphsrCommand report
    other ->
      assertFailure
        ("expected preserving reload enqueue success, got: " <> show other)
  case mphsrDrainResult report of
    Just SessionFanInDrainResult
      { sfidrDrain =
          SessionDrainResult
            { sdrItems =
                [ SessionDrainItem
                    _
                    (SessionOwnerStep
                      (StepRuntimeFailed SriHotSwapRebuildForbidden))
                ]
            , sdrRemaining =
                0
            , sdrStopped =
                Nothing
            }
      , sfidrQueueDepth =
          0
      } ->
        pure ()
    other ->
      assertFailure
        ("expected preserving runtime rejection report, got: " <> show other)

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
