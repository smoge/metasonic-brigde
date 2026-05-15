-- |
-- Module      : MetaSonic.App.ManifestReloadCli
-- Description : Testable helpers for manifest reload diagnostic CLI modes.
--
-- The executable still owns command-line parsing and process exit
-- behavior. This module keeps the manifest stopped-audio smoke's
-- file/plan/reload/render path callable from tests without spawning the
-- built executable.

module MetaSonic.App.ManifestReloadCli
  ( ManifestReloadCliIssue (..)
  , ManifestStoppedAudioReloadSmokeResult (..)
  , decodeManifestReloadDocBytes
  , readManifestReloadDocFile
  , planManifestReloadForDemo
  , manifestReloadHostStrategyNames
  , parseManifestReloadHostStrategy
  , renderManifestReloadHostStrategy
  , runManifestStoppedAudioReloadSmokeFile
  , runManifestStoppedAudioReloadSmokeWithDoc
  , runManifestStoppedAudioReloadSmokeWithCatalog
  , runManifestHostStrategyReloadSmokeFile
  , runManifestHostStrategyReloadSmokeWithDoc
  , runManifestHostStrategyReloadSmokeWithCatalog
  , runManifestHostStrategyReloadSmokeWithListenerConfig
  , runManifestHostStrategyReloadSmokeResultWithListenerConfig
  , renderManifestReloadCliIssue
  , renderManifestStoppedAudioReloadSmoke
  ) where

import           Control.Exception                (IOException, finally, try)
import           Control.Monad                    (void)
import           Data.Bifunctor                   (first)
import           Data.IORef                       (IORef, modifyIORef',
                                                   newIORef, readIORef)
import           Data.List                        (find)
import qualified Data.ByteString.Lazy.Char8       as BL
import qualified Data.Map.Strict                  as M
import qualified Data.Text                        as T

import           MetaSonic.App.Demos              (Demo (..), demoTable,
                                                   demoManifestReloadCatalog)
import           MetaSonic.App.ManifestReloadBinding
                                                  (ManifestUIVoiceSelection (..),
                                                   muitControls,
                                                   muitDemoKey,
                                                   muitVoiceSelection,
                                                   muvsDefaultVoice)
import           MetaSonic.App.ManifestReloadIngressTarget
                                                  (ManifestReloadIngressTarget (..),
                                                   ManifestReloadIngressTargetPolicy (..),
                                                   manifestReloadIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadMIDIBinding
                                                  (ManifestMIDIProjectionIssue,
                                                   mmitControls)
import           MetaSonic.App.ManifestReloadOSCBinding
                                                  (motControls)
import           MetaSonic.App.ManifestReloadHost
                                                  (ManifestReloadHostConfig (..),
                                                   ManifestReloadHostIssue,
                                                   ManifestReloadHostStrategy (..),
                                                   ManifestReloadHostStrategyIssue,
                                                   ManifestReloadHostStrategyRan,
                                                   reloadManifestHostWithStrategy)
import           MetaSonic.App.ManifestOSCIngressOps
                                                  (ManifestOSCIngressHandle (..),
                                                   ManifestOSCIngressOpsIssue,
                                                   manifestOSCIngressOps)
import           MetaSonic.App.ManifestOSCListener
                                                  (ListenerConfig,
                                                   ListenerInfo (..),
                                                   defaultListenerConfig,
                                                   defaultManifestOSCListenerHooks)
import           MetaSonic.App.ManifestReloadIngress
                                                  (ManifestReloadIngressOps (..),
                                                   ManifestReloadIngressSnapshot (..),
                                                   closeManifestReloadIngress,
                                                   newManifestReloadIngressManager,
                                                   readManifestReloadIngressManager)
import           MetaSonic.Authoring.Manifest     (AuthoringManifestDoc (..),
                                                   decodeManifestDoc,
                                                   manifestSchemaVersion)
import           MetaSonic.Bridge.Compile         (RuntimeGraph (..))
import           MetaSonic.Bridge.Source          (unMigrationKey)
import           MetaSonic.Bridge.Templates       (Template (..),
                                                   TemplateGraph (..))
import           MetaSonic.Pattern                (ControlTag (..),
                                                   SwapLabel (..),
                                                   TemplateName (..),
                                                   VoiceKey (..))
import           MetaSonic.Session.Command        (SessionCommand (..))
import           MetaSonic.Session.FanIn          (SessionFanInAudioFFI (..),
                                                   SessionFanInAudioIssue,
                                                   SessionFanInAudioOptions (..),
                                                   SessionFanInReloadIssue,
                                                   SessionFanInSetupIssue,
                                                   SessionFanInSnapshot (..),
                                                   defaultSessionFanInOptions,
                                                   readSessionFanInHost,
                                                   startSessionFanInHostAudioWith,
                                                   withSessionFanInHost)
import           MetaSonic.Session.FanInService   (SessionFanInServiceSetupIssue,
                                                   defaultSessionFanInServiceOptions,
                                                   readSessionFanInService,
                                                   sessionFanInServiceHost,
                                                   withSessionFanInService)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.ManifestReload.Runtime
                                                  (ManifestStoppedAudioReloadReport (..),
                                                   reloadManifestSessionStoppedAudio)
import           MetaSonic.Session.OSCProducer    (defaultOSCProducerOptions)
import           MetaSonic.Session.Owner          (defaultSessionOwnerOptions)
import           MetaSonic.Session.Queue          (ProducerId (..),
                                                   ProducerKind (..))
import           MetaSonic.Session.RTGraphAdapter (RTGraphAdapterOptions (..))
import           MetaSonic.Session.State          (SessionState (..))


data ManifestReloadCliIssue
  = MrciReadManifestFileFailed !FilePath !String
  | MrciDecodeManifestFileFailed !FilePath !String
  | MrciCatalogFailed !String
  | MrciPlanningFailed !MR.ManifestReloadIssue
  | MrciNoCatalogEntry !String
  | MrciHostSetupFailed !SessionFanInSetupIssue
  | MrciStoppedAudioReloadFailed !SessionFanInReloadIssue
  | MrciHostStrategySetupFailed !SessionFanInServiceSetupIssue
  | MrciHostStrategyAudioStartFailed !SessionFanInAudioIssue
  | MrciIngressTargetFailed !ManifestMIDIProjectionIssue
  | MrciOSCIngressOpenFailed !ManifestOSCIngressOpsIssue
  deriving (Eq, Show)

data ManifestStoppedAudioReloadSmokeResult =
  ManifestStoppedAudioReloadSmokeResult
    { msarsInitialEntry :: !MR.ManifestReloadCatalogEntry
    , msarsPlan         :: !MR.ManifestReloadPlan
    , msarsBefore       :: !SessionFanInSnapshot
    , msarsReport       :: !ManifestStoppedAudioReloadReport
    , msarsAfter        :: !SessionFanInSnapshot
    } deriving (Eq, Show)

data ManifestHostStrategyReloadSmokeResult =
  ManifestHostStrategyReloadSmokeResult
    { mshsInitialEntry    :: !MR.ManifestReloadCatalogEntry
    , mshsStrategy        :: !ManifestReloadHostStrategy
    , mshsPlan            :: !MR.ManifestReloadPlan
    , mshsBefore          :: !SessionFanInSnapshot
    , mshsOutcome         :: !(Either
                                (ManifestReloadHostStrategyIssue
                                  (ManifestReloadHostIssue
                                    ManifestOSCIngressOpsIssue))
                                (ManifestReloadHostStrategyRan
                                  (ManifestReloadHostIssue
                                    ManifestOSCIngressOpsIssue)))
    , mshsAfter           :: !SessionFanInSnapshot
    , mshsIngressSnapshot :: !(ManifestReloadIngressSnapshot
                                ManifestReloadIngressTarget
                                ManifestOSCIngressHandle)
    , mshsAudioEvents     :: ![ManifestHostStrategySmokeAudioEvent]
    } deriving (Show)

data ManifestHostStrategySmokeAudioEvent
  = MhssaStart !Int !Int
  | MhssaReady !Int
  | MhssaStop
  deriving (Eq, Show)

decodeManifestReloadDocBytes
  :: FilePath
  -> BL.ByteString
  -> Either ManifestReloadCliIssue AuthoringManifestDoc
decodeManifestReloadDocBytes path bytes =
  first (MrciDecodeManifestFileFailed path) (decodeManifestDoc bytes)

readManifestReloadDocFile
  :: FilePath
  -> IO (Either ManifestReloadCliIssue AuthoringManifestDoc)
readManifestReloadDocFile path = do
  readResult <- try (BL.readFile path)
  pure $ case (readResult :: Either IOException BL.ByteString) of
    Left err ->
      Left (MrciReadManifestFileFailed path (show err))
    Right bytes ->
      decodeManifestReloadDocBytes path bytes

planManifestReloadForDemo
  :: AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> Demo
  -> Either ManifestReloadCliIssue MR.ManifestReloadPlan
planManifestReloadForDemo doc catalog demo =
  first MrciPlanningFailed $
    MR.planManifestReload doc catalog (manifestReloadRequestForDemo demo)

manifestReloadHostStrategyNames :: [String]
manifestReloadHostStrategyNames =
  [ "require-preserving"
  , "try-preserving"
  , "stopped-audio-only"
  ]

parseManifestReloadHostStrategy :: String -> Maybe ManifestReloadHostStrategy
parseManifestReloadHostStrategy raw =
  case raw of
    "require-preserving" ->
      Just RequirePreserving
    "try-preserving" ->
      Just TryPreservingThenStoppedAudio
    "try-preserving-then-stopped-audio" ->
      Just TryPreservingThenStoppedAudio
    "stopped-audio-only" ->
      Just StoppedAudioOnly
    "stopped-audio" ->
      Just StoppedAudioOnly
    _ ->
      Nothing

renderManifestReloadHostStrategy :: ManifestReloadHostStrategy -> String
renderManifestReloadHostStrategy strategy =
  case strategy of
    RequirePreserving ->
      "require-preserving"
    TryPreservingThenStoppedAudio ->
      "try-preserving"
    StoppedAudioOnly ->
      "stopped-audio-only"

runManifestStoppedAudioReloadSmokeFile
  :: FilePath
  -> Demo
  -> IO (Either ManifestReloadCliIssue String)
runManifestStoppedAudioReloadSmokeFile path demo = do
  docResult <- readManifestReloadDocFile path
  case docResult of
    Left issue ->
      pure (Left issue)
    Right doc -> do
      smokeResult <- runManifestStoppedAudioReloadSmokeWithDoc doc demo
      pure (renderManifestStoppedAudioReloadSmoke <$> smokeResult)

runManifestStoppedAudioReloadSmokeWithDoc
  :: AuthoringManifestDoc
  -> Demo
  -> IO (Either ManifestReloadCliIssue ManifestStoppedAudioReloadSmokeResult)
runManifestStoppedAudioReloadSmokeWithDoc doc demo =
  case demoManifestReloadCatalog demoTable of
    Left err ->
      pure (Left (MrciCatalogFailed err))
    Right catalog ->
      runManifestStoppedAudioReloadSmokeWithCatalog doc catalog demo

runManifestStoppedAudioReloadSmokeWithCatalog
  :: AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> Demo
  -> IO (Either ManifestReloadCliIssue ManifestStoppedAudioReloadSmokeResult)
runManifestStoppedAudioReloadSmokeWithCatalog doc catalog demo =
  case planManifestReloadForDemo doc catalog demo of
    Left issue ->
      pure (Left issue)
    Right plan ->
      case selectStoppedAudioReloadInitialEntry demo catalog of
        Left issue ->
          pure (Left issue)
        Right initialEntry -> do
          result <-
            withSessionFanInHost
              (MR.mrcTemplateGraph initialEntry)
              defaultSessionFanInOptions
              $ \host -> do
                  before <- readSessionFanInHost host
                  reload <-
                    reloadManifestSessionStoppedAudio
                      host
                      defaultSessionOwnerOptions
                      plan
                  snapshotAfter <- readSessionFanInHost host
                  pure (before, reload, snapshotAfter)
          pure $ case result of
            Left issue ->
              Left (MrciHostSetupFailed issue)
            Right (_, Left issue, _) ->
              Left (MrciStoppedAudioReloadFailed issue)
            Right (before, Right report, snapshotAfter) ->
              Right ManifestStoppedAudioReloadSmokeResult
                { msarsInitialEntry = initialEntry
                , msarsPlan         = plan
                , msarsBefore       = before
                , msarsReport       = report
                , msarsAfter        = snapshotAfter
                }

runManifestHostStrategyReloadSmokeFile
  :: ManifestReloadHostStrategy
  -> FilePath
  -> Demo
  -> IO (Either ManifestReloadCliIssue String)
runManifestHostStrategyReloadSmokeFile strategy path demo = do
  docResult <- readManifestReloadDocFile path
  case docResult of
    Left issue ->
      pure (Left issue)
    Right doc -> do
      runManifestHostStrategyReloadSmokeWithDoc strategy doc demo

runManifestHostStrategyReloadSmokeWithDoc
  :: ManifestReloadHostStrategy
  -> AuthoringManifestDoc
  -> Demo
  -> IO (Either ManifestReloadCliIssue String)
runManifestHostStrategyReloadSmokeWithDoc strategy doc demo =
  case demoManifestReloadCatalog demoTable of
    Left err ->
      pure (Left (MrciCatalogFailed err))
    Right catalog ->
      runManifestHostStrategyReloadSmokeWithCatalog strategy doc catalog demo

runManifestHostStrategyReloadSmokeWithCatalog
  :: ManifestReloadHostStrategy
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> Demo
  -> IO (Either ManifestReloadCliIssue String)
runManifestHostStrategyReloadSmokeWithCatalog =
  runManifestHostStrategyReloadSmokeWithListenerConfig
    (defaultListenerConfig 0)

-- | Same as 'runManifestHostStrategyReloadSmokeWithCatalog', but
-- accepts an explicit 'ListenerConfig' for the device-backed OSC
-- ingress. Tests use this to force a bind conflict and observe the
-- initial-open failure path.
runManifestHostStrategyReloadSmokeWithListenerConfig
  :: ListenerConfig
  -> ManifestReloadHostStrategy
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> Demo
  -> IO (Either ManifestReloadCliIssue String)
runManifestHostStrategyReloadSmokeWithListenerConfig
    listenerCfg strategy doc catalog demo =
  fmap renderManifestHostStrategyReloadSmoke
    <$> runManifestHostStrategyReloadSmokeResultWithListenerConfig
          listenerCfg
          strategy
          doc
          catalog
          demo

runManifestHostStrategyReloadSmokeResultWithCatalog
  :: ManifestReloadHostStrategy
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> Demo
  -> IO (Either ManifestReloadCliIssue ManifestHostStrategyReloadSmokeResult)
runManifestHostStrategyReloadSmokeResultWithCatalog =
  runManifestHostStrategyReloadSmokeResultWithListenerConfig
    (defaultListenerConfig 0)

-- | Same as 'runManifestHostStrategyReloadSmokeResultWithCatalog', but
-- accepts an explicit 'ListenerConfig'.
runManifestHostStrategyReloadSmokeResultWithListenerConfig
  :: ListenerConfig
  -> ManifestReloadHostStrategy
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> Demo
  -> IO (Either ManifestReloadCliIssue ManifestHostStrategyReloadSmokeResult)
runManifestHostStrategyReloadSmokeResultWithListenerConfig
    listenerCfg strategy doc catalog demo =
  case planManifestReloadForDemo doc catalog demo of
    Left issue ->
      pure (Left issue)
    Right plan ->
      case selectStoppedAudioReloadInitialEntry demo catalog of
        Left issue ->
          pure (Left issue)
        Right initialEntry ->
          case planManifestReloadForCatalogEntry initialEntry of
            Left issue ->
              pure (Left issue)
            Right initialPlan ->
              case manifestReloadIngressTargetFromPlan
                     manifestHostStrategySmokeIngressTargetPolicy
                     initialPlan of
                Left issue ->
                  pure (Left (MrciIngressTargetFailed issue))
                Right oldTarget ->
                  case manifestReloadIngressTargetFromPlan
                         manifestHostStrategySmokeIngressTargetPolicy
                         plan of
                    Left issue ->
                      pure (Left (MrciIngressTargetFailed issue))
                    Right newTarget ->
                      runSmoke plan initialEntry oldTarget newTarget
  where
    runSmoke targetPlan initialEntry oldTarget newTarget = do
      result <-
        withSessionFanInService
          (MR.mrcTemplateGraph initialEntry)
          defaultSessionFanInServiceOptions
          $ \service -> do
              let ops =
                    manifestOSCIngressOps
                      defaultManifestOSCListenerHooks
                      defaultOSCProducerOptions
                      (sessionFanInServiceHost service)
                      listenerCfg
              -- Real initial open: binds a UDP socket against the OSC
              -- projection of the old target. Bind failure surfaces as
              -- a CLI-level Left without falling back silently.
              initialOpened <- mrioOpenIngress ops oldTarget
              case initialOpened of
                Left issue ->
                  pure (Left (MrciOSCIngressOpenFailed issue))
                Right initialHandle ->
                  runSmokeWithIngress
                    ops
                    initialHandle
                    targetPlan
                    initialEntry
                    oldTarget
                    newTarget
                    service
      pure $ case result of
        Left issue ->
          Left (MrciHostStrategySetupFailed issue)
        Right (Left issue) ->
          Left issue
        Right (Right ok) ->
          Right ok

    runSmokeWithIngress ops initialHandle targetPlan initialEntry
        oldTarget newTarget service = do
      events <- newIORef []
      ingressManager <-
        newManifestReloadIngressManager ops oldTarget initialHandle
      -- The diagnostic snapshot is captured before close so the smoke
      -- result reflects the post-reload state. The close releases the
      -- real UDP socket + listener thread held by the manager's
      -- current handle so callers don't leak a port across runs;
      -- subsequent reads of the snapshot's bound port still work
      -- because 'ListenerInfo' is plain data.
      runSmokeWithIngressBody
        events ingressManager targetPlan initialEntry
        oldTarget newTarget service
        `finally` void (closeManifestReloadIngress ingressManager)

    runSmokeWithIngressBody events ingressManager targetPlan
        initialEntry oldTarget newTarget service = do
      let audioFFI =
            manifestHostStrategySmokeAudioFFI events
          config = ManifestReloadHostConfig
            { mrhcService =
                service
            , mrhcIngressManager =
                ingressManager
            , mrhcOldIngressTarget =
                oldTarget
            , mrhcNewIngressTarget =
                newTarget
            , mrhcAudioFFI =
                audioFFI
            , mrhcAudioOptions =
                manifestHostStrategySmokeAudioOptions
            , mrhcOwnerOptions =
                defaultSessionOwnerOptions
            }
      audioStarted <-
        startSessionFanInHostAudioWith
          audioFFI
          (sessionFanInServiceHost service)
          manifestHostStrategySmokeAudioOptions
      case audioStarted of
        Left issue ->
          pure (Left (MrciHostStrategyAudioStartFailed issue))
        Right () -> do
          before <- readSessionFanInService service
          outcome <-
            reloadManifestHostWithStrategy
              manifestHostStrategySmokeProducer
              strategy
              config
              doc
              catalog
              (manifestReloadRequestForDemo demo)
          after <- readSessionFanInService service
          ingressSnapshot <-
            readManifestReloadIngressManager ingressManager
          audioEvents <- readIORef events
          pure (Right ManifestHostStrategyReloadSmokeResult
            { mshsInitialEntry =
                initialEntry
            , mshsStrategy =
                strategy
            , mshsPlan =
                targetPlan
            , mshsBefore =
                before
            , mshsOutcome =
                outcome
            , mshsAfter =
                after
            , mshsIngressSnapshot =
                ingressSnapshot
            , mshsAudioEvents =
                audioEvents
            })

renderManifestReloadCliIssue :: ManifestReloadCliIssue -> String
renderManifestReloadCliIssue issue =
  case issue of
    MrciReadManifestFileFailed path err ->
      "Failed to read manifest file '" <> path <> "': " <> err
    MrciDecodeManifestFileFailed path err ->
      "Failed to decode manifest file '" <> path <> "': " <> err
    MrciCatalogFailed err ->
      err
    MrciPlanningFailed err ->
      "Manifest reload planning failed: " <> show err
    MrciNoCatalogEntry key ->
      "Internal error: no catalog entry for planned demo " <> key
    MrciHostSetupFailed err ->
      "Manifest stopped-audio reload smoke host setup failed: "
      <> show err
    MrciStoppedAudioReloadFailed err ->
      "Manifest stopped-audio reload smoke failed: " <> show err
    MrciHostStrategySetupFailed err ->
      "Manifest host strategy reload smoke setup failed: " <> show err
    MrciHostStrategyAudioStartFailed err ->
      "Manifest host strategy reload smoke fake audio start failed: "
      <> show err
    MrciIngressTargetFailed err ->
      "Manifest reload smoke ingress target projection failed: "
      <> show err
    MrciOSCIngressOpenFailed err ->
      "Manifest reload smoke OSC ingress open failed: " <> show err

renderManifestStoppedAudioReloadSmoke
  :: ManifestStoppedAudioReloadSmokeResult
  -> String
renderManifestStoppedAudioReloadSmoke smoke =
  unlines $
    [ "Manifest stopped-audio reload smoke"
    , "  initial demo: " <> MR.mrcDemoKey initialEntry
    , "  target demo: " <> MR.mrlpDemoKey plan
    , "  swap label: " <> swapLabelText (MR.mrlpSwapLabel plan)
    ]
    <> renderManifestReloadTemplates (MR.mrlpTemplateGraph plan)
    <> renderManifestReloadResources (MR.mrlpAdapterOptions plan)
    <> renderManifestReloadControls (MR.mrlpControlSurface plan)
    <> [ "  arbitration policy: "
         <> show (MR.mrlpArbitrationPolicy plan)
       , "  pre-reload fan-in:"
       , "    queue depth: " <> show (sfisQueueDepth before)
       , "    owner status: " <> show (sfisOwnerStatus before)
       , "    reload status: " <> show (sfisReloadStatus before)
       , "    initial graph installed: "
         <> if ssGraph (sfisOwnerState before)
               == MR.mrcTemplateGraph initialEntry
              then "yes"
              else "no"
       , "  post-reload fan-in:"
       , "    queue depth: " <> show (sfisQueueDepth snapshotAfter)
       , "    owner status: " <> show (sfisOwnerStatus snapshotAfter)
       , "    reload status: " <> show (sfisReloadStatus snapshotAfter)
       , "    graph installed: "
         <> if ssGraph (sfisOwnerState snapshotAfter)
               == MR.mrlpTemplateGraph plan
              then "yes"
              else "no"
       , "    active voices: "
         <> show (M.size (ssVoices (sfisOwnerState snapshotAfter)))
       , "  report demo: " <> msarrDemoKey report
       , "  report swap label: " <> swapLabelText (msarrSwapLabel report)
       , "  report owner status: " <> show (msarrOwnerStatus report)
       , "  report graph installed: "
         <> if ssGraph (msarrOwnerState report) == MR.mrlpTemplateGraph plan
              then "yes"
              else "no"
       , "  listener/producer restart required: "
         <> if msarrListenersMustRestart report then "yes" else "no"
       , "  audio started: no"
       , "  audio stopped by helper: no"
       , "  listener restart executed: no"
       , renderManifestReloadCommand (MR.manifestReloadCommand plan)
       ]
  where
    initialEntry =
      msarsInitialEntry smoke
    plan =
      msarsPlan smoke
    before =
      msarsBefore smoke
    report =
      msarsReport smoke
    snapshotAfter =
      msarsAfter smoke

renderManifestHostStrategyReloadSmoke
  :: ManifestHostStrategyReloadSmokeResult
  -> String
renderManifestHostStrategyReloadSmoke smoke =
  unlines $
    [ "Manifest host strategy reload smoke"
    , "  strategy: "
      <> renderManifestReloadHostStrategy (mshsStrategy smoke)
    , "  initial demo: " <> MR.mrcDemoKey initialEntry
    , "  target demo: " <> MR.mrlpDemoKey plan
    , "  swap label: " <> swapLabelText (MR.mrlpSwapLabel plan)
    , "  fake audio lifecycle: yes (no PortAudio device opened)"
    ]
    <> renderManifestReloadTemplates (MR.mrlpTemplateGraph plan)
    <> renderManifestReloadResources (MR.mrlpAdapterOptions plan)
    <> renderManifestReloadControls (MR.mrlpControlSurface plan)
    <> [ "  arbitration policy: "
         <> show (MR.mrlpArbitrationPolicy plan)
       , "  pre-reload fan-in:"
       , "    queue depth: " <> show (sfisQueueDepth before)
       , "    owner status: " <> show (sfisOwnerStatus before)
       , "    reload status: " <> show (sfisReloadStatus before)
       , "    audio running: "
         <> if sfisAudioRunning before then "yes" else "no"
       , "    initial graph installed: "
         <> if ssGraph (sfisOwnerState before)
               == MR.mrcTemplateGraph initialEntry
              then "yes"
              else "no"
       , "  strategy result: " <> renderStrategyOutcome (mshsOutcome smoke)
       , "  post-reload fan-in:"
       , "    queue depth: " <> show (sfisQueueDepth afterSnapshot)
       , "    owner status: " <> show (sfisOwnerStatus afterSnapshot)
       , "    reload status: " <> show (sfisReloadStatus afterSnapshot)
       , "    audio running: "
         <> if sfisAudioRunning afterSnapshot then "yes" else "no"
       , "    graph installed: "
         <> if ssGraph (sfisOwnerState afterSnapshot)
               == MR.mrlpTemplateGraph plan
              then "yes"
              else "no"
       , "    active voices: "
         <> show (M.size (ssVoices (sfisOwnerState afterSnapshot)))
       , "  ingress: "
         <> renderSmokeIngressSnapshot (mshsIngressSnapshot smoke)
       , "  fake audio events:"
       ]
    <> renderSmokeAudioEvents (mshsAudioEvents smoke)
    <> [ renderManifestReloadStrategyCommand (MR.manifestReloadCommand plan) ]
  where
    initialEntry =
      mshsInitialEntry smoke
    plan =
      mshsPlan smoke
    before =
      mshsBefore smoke
    afterSnapshot =
      mshsAfter smoke

renderStrategyOutcome
  :: Either
       (ManifestReloadHostStrategyIssue
         (ManifestReloadHostIssue ManifestOSCIngressOpsIssue))
       (ManifestReloadHostStrategyRan
         (ManifestReloadHostIssue ManifestOSCIngressOpsIssue))
  -> String
renderStrategyOutcome outcome =
  case outcome of
    Left issue ->
      "failed: " <> show issue
    Right ran ->
      "success: " <> show ran

renderSmokeIngressSnapshot
  :: ManifestReloadIngressSnapshot
       ManifestReloadIngressTarget
       ManifestOSCIngressHandle
  -> String
renderSmokeIngressSnapshot snapshot =
  case snapshot of
    MrisClosed ->
      "closed"
    MrisOpen target handle ->
      "open demo="
      <> muitDemoKey (mitUI target)
      <> " ui-controls="
      <> show (length (muitControls (mitUI target)))
      <> " osc-controls="
      <> show (length (motControls (mitOSC target)))
      <> " midi-cc="
      <> show (length (mmitControls (mitMIDI target)))
      <> " defaultVoice="
      <> voiceKeyText
           (muvsDefaultVoice (muitVoiceSelection (mitUI target)))
      <> " oscPort="
      <> show (liBoundPort (moihInfo handle))

renderSmokeAudioEvents :: [ManifestHostStrategySmokeAudioEvent] -> [String]
renderSmokeAudioEvents events =
  case events of
    [] ->
      ["    (none)"]
    _ ->
      map renderEvent events
  where
    renderEvent event =
      case event of
        MhssaStart channels deviceID ->
          "    - start channels="
          <> show channels
          <> " device="
          <> show deviceID
        MhssaReady timeoutMs ->
          "    - ready timeoutMs=" <> show timeoutMs
        MhssaStop ->
          "    - stop"

renderManifestReloadStrategyCommand :: SessionCommand -> String
renderManifestReloadStrategyCommand command =
  case command of
    CmdHotSwap label graph ->
      "  selector command projection: CmdHotSwap "
      <> swapLabelText label
      <> " templates="
      <> show (length (tgTemplates graph))
      <> " (selector-controlled)"
    CmdHotSwapPreservingOnly label graph ->
      "  selector command projection: CmdHotSwapPreservingOnly "
      <> swapLabelText label
      <> " templates="
      <> show (length (tgTemplates graph))
      <> " (selector-controlled)"
    _ ->
      "  selector command projection: "
      <> show command
      <> " (selector-controlled)"

selectStoppedAudioReloadInitialEntry
  :: Demo
  -> [MR.ManifestReloadCatalogEntry]
  -> Either ManifestReloadCliIssue MR.ManifestReloadCatalogEntry
selectStoppedAudioReloadInitialEntry demo catalog =
  case find ((/= demoKey demo) . MR.mrcDemoKey) catalog of
    Just entry ->
      Right entry
    Nothing ->
      case find ((== demoKey demo) . MR.mrcDemoKey) catalog of
        Just entry ->
          Right entry
        Nothing ->
          Left (MrciNoCatalogEntry (demoKey demo))

planManifestReloadForCatalogEntry
  :: MR.ManifestReloadCatalogEntry
  -> Either ManifestReloadCliIssue MR.ManifestReloadPlan
planManifestReloadForCatalogEntry entry =
  -- Smoke-only convenience: production old ingress should come from
  -- the host's prior bring-up or previous reload state. The CLI smoke
  -- has only catalog entries, so it builds the same pure projection
  -- shape from the selected initial entry.
  first MrciPlanningFailed $
    MR.planManifestReload
      (AuthoringManifestDoc manifestSchemaVersion [MR.mrcManifest entry])
      [entry]
      MR.ManifestReloadRequest
        { MR.mrrDemoKey =
            MR.mrcDemoKey entry
        , MR.mrrSwapLabel =
            SwapLabel ("manifest:" <> MR.mrcDemoKey entry)
        , MR.mrrResourcePolicy =
            MR.defaultManifestResourcePolicy
        }

manifestReloadRequestForDemo :: Demo -> MR.ManifestReloadRequest
manifestReloadRequestForDemo demo =
  MR.ManifestReloadRequest
    { MR.mrrDemoKey =
        demoKey demo
    , MR.mrrSwapLabel =
        SwapLabel ("manifest:" <> demoKey demo)
    , MR.mrrResourcePolicy =
        MR.defaultManifestResourcePolicy
    }

manifestHostStrategySmokeProducer :: ProducerId
manifestHostStrategySmokeProducer =
  ProducerId ProducerUI (T.pack "manifest-host-strategy-smoke")

manifestHostStrategySmokeVoiceSelection :: ManifestUIVoiceSelection
manifestHostStrategySmokeVoiceSelection = ManifestUIVoiceSelection
  { muvsFocusedVoice =
      Nothing
  , muvsDefaultVoice =
      VoiceKey "v0"
  }

manifestHostStrategySmokeAudioOptions :: SessionFanInAudioOptions
manifestHostStrategySmokeAudioOptions = SessionFanInAudioOptions
  { sfiaoOutputChannels = 2
  , sfiaoDeviceID       = -1
  , sfiaoReadyTimeoutMs = 100
  }

manifestHostStrategySmokeAudioFFI
  :: IORef [ManifestHostStrategySmokeAudioEvent]
  -> SessionFanInAudioFFI
manifestHostStrategySmokeAudioFFI events = SessionFanInAudioFFI
  { saffiStartAudio =
      \_rt outputChannels deviceID -> do
        appendSmokeAudioEvent events (MhssaStart outputChannels deviceID)
        pure 0
  , saffiWaitAudioStarted =
      \_rt timeoutMs -> do
        appendSmokeAudioEvent events (MhssaReady timeoutMs)
        pure True
  , saffiStopAudio =
      \_rt ->
        appendSmokeAudioEvent events MhssaStop
  }

appendSmokeAudioEvent
  :: IORef [ManifestHostStrategySmokeAudioEvent]
  -> ManifestHostStrategySmokeAudioEvent
  -> IO ()
appendSmokeAudioEvent ref event =
  modifyIORef' ref (<> [event])

manifestHostStrategySmokeIngressTargetPolicy
  :: ManifestReloadIngressTargetPolicy
manifestHostStrategySmokeIngressTargetPolicy =
  ManifestReloadIngressTargetPolicy
    { mritpUIVoiceSelection =
        manifestHostStrategySmokeVoiceSelection
    , mritpUIRetainedValues =
        M.empty
    , mritpMIDIDefaultVoice =
        muvsDefaultVoice manifestHostStrategySmokeVoiceSelection
    }

renderManifestReloadTemplates :: TemplateGraph -> [String]
renderManifestReloadTemplates graph =
  [ "  template graph:"
  , "    templates: " <> show (length (tgTemplates graph))
  ]
  <> map renderTemplate (tgTemplates graph)
  where
    renderTemplate tpl =
      "    - "
      <> tplName tpl
      <> " nodes="
      <> show (runtimeNodeCount (tplGraph tpl))

runtimeNodeCount :: RuntimeGraph -> Int
runtimeNodeCount =
  length . rgNodes

renderManifestReloadResources :: RTGraphAdapterOptions -> [String]
renderManifestReloadResources opts =
  [ "  resource policy projection:"
  , "    default polyphony: " <> show (raoDefaultPolyphony opts)
  , "    hot-swap install timeout ms: "
    <> show (raoHotSwapInstallTimeoutMs opts)
  , "    per-template polyphony:"
  ]
  <> case M.toList (raoPerTemplatePolyphony opts) of
       [] ->
         ["      (none)"]
       rows ->
         map renderTemplatePolyphony rows
  where
    renderTemplatePolyphony (TemplateName name, polyphony) =
      "      - " <> name <> ": " <> show polyphony

renderManifestReloadControls :: [MR.ManifestControlSurface] -> [String]
renderManifestReloadControls controls =
  "  control surface:"
  : case controls of
      [] ->
        ["    (none)"]
      _ ->
        map renderControl controls
  where
    renderControl control =
      "    - "
      <> MR.mcsDisplayName control
      <> ": tag="
      <> controlTagText (MR.mcsControlTag control)
      <> " default="
      <> show (MR.mcsDefault control)
      <> " range=["
      <> show (MR.mcsRangeMin control)
      <> ", "
      <> show (MR.mcsRangeMax control)
      <> "] smoothingHz="
      <> show (MR.mcsSmoothingHz control)
      <> " cc="
      <> maybe "none" show (MR.mcsCC control)

renderManifestReloadCommand :: SessionCommand -> String
renderManifestReloadCommand command =
  case command of
    CmdHotSwap label graph ->
      "  command projection: CmdHotSwap "
      <> swapLabelText label
      <> " templates="
      <> show (length (tgTemplates graph))
      <> " (not executed)"
    CmdHotSwapPreservingOnly label graph ->
      "  command projection: CmdHotSwapPreservingOnly "
      <> swapLabelText label
      <> " templates="
      <> show (length (tgTemplates graph))
      <> " (not executed)"
    _ ->
      "  command projection: "
      <> show command
      <> " (not executed)"

swapLabelText :: SwapLabel -> String
swapLabelText =
  unSwapLabel

controlTagText :: ControlTag -> String
controlTagText (ControlTag key slot) =
  unMigrationKey key <> "/" <> show slot

voiceKeyText :: VoiceKey -> String
voiceKeyText =
  unVoiceKey
