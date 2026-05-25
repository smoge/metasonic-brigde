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
  , ManifestSupervisedStoppedAudioReloadSmokeResult (..)
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
  , runManifestSupervisedStoppedAudioReloadSmokeWithListenerConfig
  , renderManifestSupervisedStoppedAudioReloadSmoke
  , renderManifestReloadCliIssue
  , renderManifestStoppedAudioReloadSmoke
    -- * Operator-facing typed renderers for strategy outcomes
    -- and reload-event payloads. Shared by every manifest-reload
    -- CLI surface so the @strategy result:@ line and the
    -- @reload events:@ block speak the same vocabulary.
  , renderStrategyRan
  , renderStrategyFailure
  , renderStrategyOutcome
  , renderHostPreservingIssueTag
  , renderHostStoppedAudioIssueTag
  , renderHostIssueTag
  , renderReloadHostStackOpenIssueTag
  , renderPreservingHostStackIssueTag
  , renderStoppedAudioHostStackIssueTag
  , renderTryPreservingInWindowIssueTag
  , renderTryPreservingHostStackIssueTag
  , renderSmokeReloadEvent
  ) where

import           Control.Exception                (IOException, finally, mask,
                                                   try)
import           Control.Monad                    (void)
import           Data.Bifunctor                   (first)
import           Data.IORef                       (IORef, modifyIORef',
                                                   newIORef, readIORef)
import           Data.List                        (find, intercalate)
import qualified Data.ByteString.Lazy.Char8       as BL
import qualified Data.Map.Strict                  as M
import qualified Data.Text                        as T
import           Data.Word                        (Word8)

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
import           MetaSonic.App.ManifestReloadAudioEvent
                                                  (noManifestReloadAudioEvents)
import           MetaSonic.App.ManifestReloadEvent
                                                  (ManifestReloadEvent (..))
import           MetaSonic.App.ManifestReloadHostStack
                                                  (RealReloadHostStackInputs (..),
                                                   ReloadHostStack (..),
                                                   StoppedAudioHostStackIssue (..),
                                                   ReloadHostStackOpenIssue (..),
                                                   SupervisedStoppedAudioReloadResult (..),
                                                   mkStoppedAudioHostStackFactory,
                                                   realStoppedAudioHostStackOps)
import           MetaSonic.App.ManifestReloadPreservingHostStack
                                                  (PreservingHostStackIssue (..))
import           MetaSonic.App.ManifestReloadTryPreservingHostStack
                                                  (TryPreservingHostStackIssue (..),
                                                   TryPreservingInWindowIssue (..))
import           MetaSonic.App.ManifestReloadSupervisor
                                                  (SupervisedReloadOutcome (..),
                                                   reloadSupervised)
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                                  (HostStackFactory (..),
                                                   withHostStackSupervisorAdapter)
import           MetaSonic.App.ManifestReloadHost
                                                  (ManifestReloadHostConfig (..),
                                                   ManifestReloadHostIssue (..),
                                                   ManifestReloadHostStrategy (..),
                                                   ManifestReloadHostStrategyIssue (..),
                                                   ManifestReloadHostStrategyRan (..),
                                                   reloadManifestHostWithStrategyWithEvents)
import           MetaSonic.App.ManifestReloadOrchestration
                                                  (HostPreservingReloadIssue (..),
                                                   HostStoppedAudioReloadIssue (..))
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
import           MetaSonic.Authoring.Manifest     (AuthoringManifest (..),
                                                   AuthoringManifestDoc (..),
                                                   ManifestBus (..),
                                                   ManifestControl (..),
                                                   ManifestTemplate (..),
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
                                                   defaultSessionFanInServiceHooks,
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
  | MrciSupervisedPartialCleanupFailed !ManifestReloadCliIssue !T.Text
    -- ^ The supervised stopped-audio path's initial open hit a
    -- terminal failure AND the helper's rollback (which closes
    -- the partially-opened service / ingress / audio) itself
    -- failed. The first field is the primary cause translated
    -- into this same CLI issue type (never itself another
    -- 'MrciSupervisedPartialCleanupFailed' — the recursion is
    -- bounded by construction in 'mapSupervisedOpenIssue'). The
    -- second field is the textual rollback diagnostic emitted
    -- by 'RhsoiPartialCleanupFailed'. The operator should see
    -- both: the primary cause explains why open failed, and
    -- the cleanup diagnostic explains why the host stack is
    -- in an unknown state. Keeping this as its own variant
    -- (instead of collapsing back to the primary) preserves
    -- the manual-cleanup-may-be-required signal that the
    -- 'RhsoiPartialCleanupFailed' constructor was designed to
    -- carry.
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
    , mshsReloadEvents    :: ![ManifestReloadEvent
                                (ManifestReloadHostIssue
                                  ManifestOSCIngressOpsIssue)]
      -- ^ Operator timeline emitted by
      -- 'reloadManifestHostWithStrategyWithEvents'. Captured by the
      -- smoke's @mrhcOnEvent@ hook in arrival order; the renderer
      -- presents this as the @reload events:@ block.
    } deriving (Show)


-- | Result of one supervised StoppedAudioOnly reload smoke. Used
-- when the @StoppedAudioOnly@ strategy is dispatched through the
-- supervised lifecycle (factory + adapter + 'reloadSupervised')
-- rather than the direct 'reloadManifestHostWithStrategy' path.
--
-- The CLI inlines the supervised lifecycle in
-- 'runManifestSupervisedStoppedAudioReloadSmokeWithListenerConfig'
-- below instead of calling the library entry
-- 'runSupervisedStoppedAudioReload' so it can read the
-- pre-reload ingress snapshot off the original initial stack
-- /inside the adapter callback/ — between the adapter installing
-- its bracket and 'reloadSupervised' running, so the snapshot
-- read is covered by the adapter's @finally closeOps@. The
-- closed-over 'initialStack' value is the same one the adapter
-- is holding in its IORef pre-reload; reading its ingress
-- manager there reflects the still-bound listener. The two
-- paths use the same factory + adapter + supervisor primitives
-- and share the same 'mask' + 'restore' exception-safety shape.
--
-- The narrow 'SupervisedStoppedAudioReloadResult' preserves the
-- supervisor's rebuild causes through the outcome rather than
-- collapsing them into the 'ManifestReloadHostStrategyIssue'
-- shape.
data ManifestSupervisedStoppedAudioReloadSmokeResult =
  ManifestSupervisedStoppedAudioReloadSmokeResult
    { mssarsInitialEntry      :: !MR.ManifestReloadCatalogEntry
      -- ^ Catalog entry the supervisor opened the initial stack
      -- against (its plan is the @fallback@ at reload entry).
    , mssarsFallbackPlan      :: !MR.ManifestReloadPlan
    , mssarsPlan              :: !MR.ManifestReloadPlan
      -- ^ The @requested@ plan the supervisor attempted to
      -- install.
    , mssarsOutcome
        :: !(SupervisedStoppedAudioReloadResult
              ManifestOSCIngressOpsIssue)
    , mssarsPreIngressSnapshot
        :: !(ManifestReloadIngressSnapshot
              ManifestReloadIngressTarget
              ManifestOSCIngressHandle)
      -- ^ Pre-reload ingress snapshot read from the original
      -- initial stack inside the adapter callback, before
      -- 'reloadSupervised' runs. Lets the renderer report the
      -- bound OSC port without exposing the active stack
      -- through the adapter contract.
    , mssarsAudioEvents       :: ![ManifestHostStrategySmokeAudioEvent]
    , mssarsReloadEvents      :: ![ManifestReloadEvent
                                    (ManifestReloadHostIssue
                                      ManifestOSCIngressOpsIssue)]
      -- ^ Orchestrator events captured via the inputs'
      -- @rrhsiOnEvent@ sink. Note: this list does NOT include
      -- the @strategy started@ / @strategy succeeded@ frame
      -- events that the direct 'reloadManifestHostWithStrategy'
      -- path emits, because the supervised path does not run
      -- that strategy wrapper. The renderer synthesizes
      -- equivalent wrapper lines around this list so operator
      -- output stays uniform across direct and supervised
      -- paths.
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
    listenerCfg strategy doc catalog demo = case strategy of
  StoppedAudioOnly ->
    -- §219 slice 4 routing: StoppedAudioOnly goes through the
    -- supervisor + factory now (hardware-confirmed once on
    -- 2026-05-20; see the runbook). Preserving and
    -- TryPreservingThenStoppedAudio stay on the direct path
    -- below; their migration is its own slice and opens
    -- against the evidence bar in
    -- notes/2026-05-20-a-supervised-route-tier3-decision.md.
    fmap renderManifestSupervisedStoppedAudioReloadSmoke
      <$> runManifestSupervisedStoppedAudioReloadSmokeWithListenerConfig
            listenerCfg
            doc
            catalog
            demo
  _ ->
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
      reloadEvents <- newIORef []
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
            , mrhcOnEvent =
                appendSmokeReloadEvent reloadEvents
            , mrhcOnRetired =
                -- Phase 8h step 3e v1 slice 4: the smoke CLI does
                -- not consume retired-set side-channels (the
                -- operator-facing 'retired bindings:' block already
                -- renders from the event payload).
                \_ -> pure ()
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
            reloadManifestHostWithStrategyWithEvents
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
          capturedReloadEvents <- readIORef reloadEvents
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
            , mshsReloadEvents =
                capturedReloadEvents
            })


-- | Supervised counterpart of
-- 'runManifestHostStrategyReloadSmokeResultWithListenerConfig'
-- for the @StoppedAudioOnly@ strategy. Opens the initial stack
-- via 'realStoppedAudioHostStackOps' against the initial entry's
-- plan (the supervisor's @fallback@), reads the pre-reload
-- ingress snapshot off the original initial stack inside the
-- adapter callback before 'reloadSupervised' runs (so the
-- renderer can still report @oscPort=N@), runs
-- 'reloadSupervised' against @(fallback, requested)@, and lets
-- the adapter close whichever stack is active on exit.
runManifestSupervisedStoppedAudioReloadSmokeWithListenerConfig
  :: ListenerConfig
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> Demo
  -> IO (Either
          ManifestReloadCliIssue
          ManifestSupervisedStoppedAudioReloadSmokeResult)
runManifestSupervisedStoppedAudioReloadSmokeWithListenerConfig
    listenerCfg doc catalog demo =
  case planManifestReloadForDemo doc catalog demo of
    Left issue ->
      pure (Left issue)
    Right requestedPlan ->
      case selectStoppedAudioReloadInitialEntry demo catalog of
        Left issue ->
          pure (Left issue)
        Right initialEntry ->
          case planManifestReloadForCatalogEntry initialEntry of
            Left issue ->
              pure (Left issue)
            Right fallbackPlan ->
              runSupervisedSmoke
                listenerCfg
                initialEntry
                fallbackPlan
                requestedPlan
  where
    runSupervisedSmoke lcfg initialEntry fallbackPlan requestedPlan =
      -- Outer 'mask' closes the async-exception window between
      -- 'hsfOpenStack' returning @Right initialStack@ and
      -- 'withHostStackSupervisorAdapter' installing its bracket.
      -- 'restore' is used around the blocking pieces so the
      -- caller's masking state is preserved inside them.
      -- 'readManifestReloadIngressManager' and 'reloadSupervised'
      -- both run /inside/ the adapter callback under 'restore', so
      -- the adapter's @finally closeOps@ covers them — a throw
      -- (sync or async) during the pre-snapshot read or during
      -- the supervised reload will not leak the active stack.
      mask $ \restore -> do
        audioEventsRef  <- newIORef []
        reloadEventsRef <- newIORef []
        let audioFFI = manifestHostStrategySmokeAudioFFI audioEventsRef
            buildIngressOps host =
              manifestOSCIngressOps
                defaultManifestOSCListenerHooks
                defaultOSCProducerOptions
                host
                lcfg
            inputs = RealReloadHostStackInputs
              { rrhsiBuildIngressOps =
                  buildIngressOps
              , rrhsiIngressTargetPolicy =
                  manifestHostStrategySmokeIngressTargetPolicy
              , rrhsiAudioFFI =
                  audioFFI
              , rrhsiAudioOptions =
                  manifestHostStrategySmokeAudioOptions
              , rrhsiOwnerOptions =
                  defaultSessionOwnerOptions
              , rrhsiServiceOptions =
                  defaultSessionFanInServiceOptions
              , rrhsiServiceHooks =
                  defaultSessionFanInServiceHooks
              , rrhsiOnEvent =
                  appendSmokeReloadEvent reloadEventsRef
              , rrhsiOnAudioEvent =
                  noManifestReloadAudioEvents
              , rrhsiOnRetired =
                  \_ -> pure ()
              }
            ops = realStoppedAudioHostStackOps inputs
            factory = mkStoppedAudioHostStackFactory ops
        openResult <- restore (hsfOpenStack factory fallbackPlan)
        case openResult of
          Left issue ->
            pure (Left (mapSupervisedOpenIssue issue))
          Right initialStack -> do
            -- Both the pre-reload ingress snapshot read AND the
            -- supervised reload happen inside the adapter
            -- callback under 'restore' so the adapter's
            -- finally protects them. The closed-over
            -- 'initialStack' is the same value the adapter is
            -- holding in its IORef before any rebuild; reading
            -- its ingress manager pre-reload is safe.
            (preSnapshot, outcome) <-
              withHostStackSupervisorAdapter factory initialStack $
                \supOps -> restore $ do
                  pre <- readManifestReloadIngressManager
                    (mrhcIngressManager (rhsConfig initialStack))
                  out <- reloadSupervised supOps fallbackPlan requestedPlan
                  pure (pre, out)
            audioEvents <- readIORef audioEventsRef
            reloadEvents <- readIORef reloadEventsRef
            let supResult = case outcome of
                  SupervisedReloadCommitted ->
                    SsasrrCommitted
                  SupervisedReloadRequestRejected _ ->
                    -- Unreachable: stopped-audio cannot produce
                    -- 'InWindowReloadRejectedLiveFallback' (see
                    -- 'sahsoInWindowReload' Haddock + the matching
                    -- error in 'runSupervisedStoppedAudioReload').
                    -- The preserving migration that introduces a
                    -- producer for this variant must also grow a
                    -- proper 'SupervisedStoppedAudioReloadResult'
                    -- constructor and the CLI rendering for it.
                    error
                      "manifestSupervisedStoppedAudioReloadSmoke: \
                      \stopped-audio path produced \
                      \SupervisedReloadRequestRejected — contract \
                      \violation."
                  SupervisedReloadRejectedRecovered e ->
                    SsasrrRebuildRecovered e
                  SupervisedReloadEscalated e1 e2 ->
                    SsasrrEscalated e1 e2
            pure $ Right ManifestSupervisedStoppedAudioReloadSmokeResult
              { mssarsInitialEntry       = initialEntry
              , mssarsFallbackPlan       = fallbackPlan
              , mssarsPlan               = requestedPlan
              , mssarsOutcome            = supResult
              , mssarsPreIngressSnapshot = preSnapshot
              , mssarsAudioEvents        = audioEvents
              , mssarsReloadEvents       = reloadEvents
              }


-- | Translate a 'StoppedAudioHostStackIssue' returned by the
-- initial 'hsfOpenStack' call into a 'ManifestReloadCliIssue'
-- the CLI surface already understands.
--
-- 'RhsoiPartialCleanupFailed' is preserved as its own
-- 'MrciSupervisedPartialCleanupFailed' variant, NOT folded back
-- into the primary cause. That constructor exists specifically
-- to signal that the helper's rollback failed and the host
-- stack is in an unknown state; collapsing it to just the
-- primary cause would hide the manual-cleanup-may-be-required
-- condition from the operator. The recursion through
-- 'mapOpenIssue' is bounded: by construction in
-- 'RhsoiPartialCleanupFailed' the primary is never itself
-- another partial-cleanup, so depth is at most one.
--
-- 'SahsiInWindow' is unreachable here (no in-window has run
-- yet); we surface it as a catch-all if it ever shows up to
-- avoid silent pattern-match failure.
mapSupervisedOpenIssue
  :: StoppedAudioHostStackIssue ManifestOSCIngressOpsIssue
  -> ManifestReloadCliIssue
mapSupervisedOpenIssue (SahsiOpen openIssue) =
  mapOpenIssue openIssue
mapSupervisedOpenIssue (SahsiInWindow _) =
  MrciCatalogFailed
    "supervised stopped-audio reload: unexpected in-window issue \
    \during initial open (supervisor contract violation)"


-- | Inner helper for 'mapSupervisedOpenIssue'. Kept as a
-- separate function so the 'RhsoiPartialCleanupFailed'
-- recursion is local and doesn't have to re-establish the
-- 'SahsiOpen' wrapper at each step.
mapOpenIssue
  :: ReloadHostStackOpenIssue ManifestOSCIngressOpsIssue
  -> ManifestReloadCliIssue
mapOpenIssue openIssue = case openIssue of
  RhsoiServiceSetupFailed e ->
    MrciHostStrategySetupFailed e
  RhsoiAudioStartFailed e ->
    MrciHostStrategyAudioStartFailed e
  RhsoiIngressOpenFailed e ->
    MrciOSCIngressOpenFailed e
  RhsoiIngressTargetProjectionFailed e ->
    MrciIngressTargetFailed e
  RhsoiPartialCleanupFailed primary diag ->
    MrciSupervisedPartialCleanupFailed (mapOpenIssue primary) diag


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
      "Manifest reload planning failed: " <> renderManifestReloadIssue err
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
    MrciSupervisedPartialCleanupFailed primary diag ->
      -- Surface BOTH the primary cause and the cleanup
      -- diagnostic. The cleanup-failed signal means the host
      -- stack is in an unknown state; collapsing to just the
      -- primary cause would hide that the operator may need to
      -- manually clean up before retrying.
      renderManifestReloadCliIssue primary
      <> "\n  Note: the helper's rollback after the failure above \
         \also failed: "
      <> T.unpack diag
      <> "\n  The host stack may be in an unknown state. \
         \Restart the host before retrying."

renderManifestReloadIssue :: MR.ManifestReloadIssue -> String
renderManifestReloadIssue issue =
  case issue of
    MR.MriManifestMismatch key requested catalog ->
      unlines $
        [ "manifest for demo '" <> key
          <> "' does not match the compiled authoring catalog."
        , "  The external manifest is validated as a catalog snapshot;"
        , "  JSON-only edits do not remap the built-in demo."
        , "  Regenerate with --authoring-manifest " <> key
          <> ", or update the demo source and regenerate."
        , "  differences:"
        ]
        <> manifestDifferenceLines requested catalog
    _ ->
      show issue

manifestDifferenceLines
  :: AuthoringManifest
  -> AuthoringManifest
  -> [String]
manifestDifferenceLines requested catalog =
  case diffs of
    [] -> ["    - manifests differ, but no simple field diff was found"]
    _  -> diffs
  where
    diffs =
      showDiff "demo key" show (mfDemoKey requested) (mfDemoKey catalog)
      <> showListDiff
           "templates"
           renderManifestTemplate
           (mfTemplates requested)
           (mfTemplates catalog)
      <> showListDiff
           "buses"
           renderManifestBus
           (mfBuses requested)
           (mfBuses catalog)
      <> controlDifferenceLines
           (mfControls requested)
           (mfControls catalog)

showDiff :: Eq a => String -> (a -> String) -> a -> a -> [String]
showDiff label render requested catalog
  | requested == catalog = []
  | otherwise =
      [ "    - " <> label
        <> ": manifest=" <> render requested
        <> " catalog=" <> render catalog
      ]

showListDiff :: Eq a => String -> (a -> String) -> [a] -> [a] -> [String]
showListDiff label render requested catalog
  | requested == catalog = []
  | otherwise =
      [ "    - " <> label
        <> ": manifest=" <> renderList render requested
        <> " catalog=" <> renderList render catalog
      ]

controlDifferenceLines
  :: [ManifestControl]
  -> [ManifestControl]
  -> [String]
controlDifferenceLines requested catalog
  | requested == catalog = []
  | null diffs =
      [ "    - control order: manifest="
        <> renderList mcName requested
        <> " catalog="
        <> renderList mcName catalog
      ]
  | otherwise = diffs
  where
    names =
      map mcName requested
      <> [ mcName c | c <- catalog, mcName c `notElem` map mcName requested ]
    diffs = concatMap diffControl names

    diffControl name =
      case (findControl name requested, findControl name catalog) of
        (Just a, Just b) ->
          showDiff ("control " <> name <> " default")
            show (mcDefault a) (mcDefault b)
          <> showDiff ("control " <> name <> " rangeMin")
            show (mcRangeMin a) (mcRangeMin b)
          <> showDiff ("control " <> name <> " rangeMax")
            show (mcRangeMax a) (mcRangeMax b)
          <> showDiff ("control " <> name <> " smoothingHz")
            show (mcSmoothingHz a) (mcSmoothingHz b)
          <> showDiff ("control " <> name <> " cc")
            renderMaybeCC (mcCC a) (mcCC b)
          <> showDiff ("control " <> name <> " key")
            show (mcKey a) (mcKey b)
          <> showDiff ("control " <> name <> " slot")
            show (mcSlot a) (mcSlot b)
        (Just a, Nothing) ->
          [ "    - control " <> name
            <> ": present in manifest only ("
            <> renderControlSummary a
            <> ")"
          ]
        (Nothing, Just b) ->
          [ "    - control " <> name
            <> ": present in catalog only ("
            <> renderControlSummary b
            <> ")"
          ]
        (Nothing, Nothing) ->
          []

findControl :: String -> [ManifestControl] -> Maybe ManifestControl
findControl name = find ((== name) . mcName)

renderManifestTemplate :: ManifestTemplate -> String
renderManifestTemplate template =
  mtName template <> ":" <> mtRole template

renderManifestBus :: ManifestBus -> String
renderManifestBus bus =
  mbName bus <> ":" <> show (mbIndex bus)

renderControlSummary :: ManifestControl -> String
renderControlSummary control =
  "cc=" <> renderMaybeCC (mcCC control)
  <> ", key=" <> show (mcKey control)
  <> ", slot=" <> show (mcSlot control)

renderMaybeCC :: Maybe Word8 -> String
renderMaybeCC Nothing   = "none"
renderMaybeCC (Just cc) = show cc

renderList :: (a -> String) -> [a] -> String
renderList render xs =
  "[" <> intercalate ", " (map render xs) <> "]"

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
       , "  audio lifecycle: not exercised (planner-only smoke path)"
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
       , "  reload events:"
       ]
    <> renderSmokeReloadEvents (mshsReloadEvents smoke)
    <> [ "  fake audio events:" ]
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


-- | Renderer for the supervised StoppedAudioOnly smoke. The output
-- shape stays close to 'renderManifestHostStrategyReloadSmoke' so
-- the operator-facing header / strategy / ingress / audio /
-- reload-events blocks read the same way across direct and
-- supervised dispatches.
--
-- The supervised path does not run 'reloadManifestHostWithStrategy',
-- so the @strategy started@ / @strategy succeeded@ wrapper events
-- that the direct render emits are not in
-- 'mssarsReloadEvents'. The renderer synthesizes them here so
-- operator output stays uniform — the genuine orchestrator
-- events (e.g. @stopped-audio phase started/committed@) still
-- come from the captured list, sandwiched between the synthetic
-- frame events.
--
-- Pre-reload graph / post-reload graph snapshot lines are
-- intentionally omitted: the supervisor adapter does not expose
-- the active stack to the supervised callback by design, so the
-- post-reload SessionFanInService snapshot is not reachable
-- without breaking the encapsulation. The pre-reload ingress
-- snapshot IS read (off the original initial stack inside the
-- adapter callback, before reload/rebuild) and rendered, so
-- @oscPort=N@ stays visible
-- for tests that pin the real-UDP-bind path.
renderManifestSupervisedStoppedAudioReloadSmoke
  :: ManifestSupervisedStoppedAudioReloadSmokeResult
  -> String
renderManifestSupervisedStoppedAudioReloadSmoke smoke =
  unlines $
    [ "Manifest host strategy reload smoke"
    , "  strategy: stopped-audio-only"
    , "  initial demo: " <> MR.mrcDemoKey initialEntry
    , "  target demo: " <> MR.mrlpDemoKey plan
    , "  swap label: " <> swapLabelText (MR.mrlpSwapLabel plan)
    , "  fake audio lifecycle: yes (no PortAudio device opened)"
    , "  strategy result: " <> supervisedOutcomeText outcome
    , "  ingress: " <> renderSmokeIngressSnapshot preSnapshot
    , "  reload events:"
    ]
    <> [ "    - strategy started: stopped-audio-only" ]
    <> renderSmokeReloadEvents (mssarsReloadEvents smoke)
    <> [ "    - " <> supervisedStrategyEventText outcome ]
    <> [ "  fake audio events:" ]
    <> renderSmokeAudioEvents (mssarsAudioEvents smoke)
  where
    initialEntry = mssarsInitialEntry smoke
    plan         = mssarsPlan smoke
    preSnapshot  = mssarsPreIngressSnapshot smoke
    outcome      = mssarsOutcome smoke

    -- Strategy-result line text. The 'committed' branch
    -- intentionally matches the direct path's wording so
    -- existing assertContains "success: stopped-audio installed"
    -- assertions stay green; the supervised-specific
    -- 'recovered' / 'escalated' branches are new prose.
    supervisedOutcomeText o = case o of
      SsasrrCommitted ->
        "success: stopped-audio installed"
      SsasrrRebuildRecovered cause ->
        "recovered: in-window failed ("
        <> renderSupervisedHostStackIssue cause
        <> "); rebuild from fallback succeeded"
      SsasrrEscalated inWindow rebuild ->
        "escalated: in-window failed ("
        <> renderSupervisedHostStackIssue inWindow
        <> "); rebuild also failed ("
        <> renderSupervisedHostStackIssue rebuild
        <> ")"

    -- Synthetic strategy-frame closer event. Mirrors the
    -- direct path's @strategy succeeded:@ / @strategy failed:@
    -- prose so operator timelines read uniformly.
    supervisedStrategyEventText o = case o of
      SsasrrCommitted ->
        "strategy succeeded: stopped-audio installed"
      SsasrrRebuildRecovered _ ->
        "strategy recovered: stopped-audio rebuilt from fallback"
      SsasrrEscalated _ _ ->
        "strategy failed: stopped-audio escalated"


-- | Compact textual tag for a supervised host-stack issue.
-- Both halves of the supervisor's outcome (in-window cause /
-- rebuild cause) flow through this so the renderer's
-- @recovered:@ / @escalated:@ lines name which step broke
-- without dumping the full structured payload.
renderSupervisedHostStackIssue
  :: StoppedAudioHostStackIssue ManifestOSCIngressOpsIssue
  -> String
renderSupervisedHostStackIssue issue = case issue of
  SahsiInWindow _ ->
    "in-window orchestrator"
  SahsiOpen (RhsoiServiceSetupFailed _) ->
    "service setup"
  SahsiOpen (RhsoiAudioStartFailed _) ->
    "audio start"
  SahsiOpen (RhsoiIngressOpenFailed _) ->
    "ingress open"
  SahsiOpen (RhsoiIngressTargetProjectionFailed _) ->
    "ingress target projection"
  SahsiOpen (RhsoiPartialCleanupFailed _ _) ->
    "partial cleanup"


-- | Shared typed renderer for a successful strategy outcome. Used
-- by both the @--manifest-host-reload-smoke@ @strategy result:@
-- line and the @reload events:@ block's @strategy succeeded:@
-- line. Polymorphic in @issue@ so output-regression tests can
-- pass a stand-in payload without fabricating real reload state.
renderStrategyRan :: ManifestReloadHostStrategyRan issue -> String
renderStrategyRan ran = case ran of
  MrhsrPreserving ->
    "preserving installed (audio kept, voices preserved)"
  MrhsrStoppedAudio ->
    "stopped-audio installed (audio restarted with new owner)"
  MrhsrStoppedAudioAfterPreservingRejected prevIssue ->
    "preserving rejected ("
    <> renderHostPreservingIssueTag prevIssue
    <> "), stopped-audio fallback installed"

-- | Shared typed renderer for a failed strategy outcome. Same role
-- as 'renderStrategyRan' on the failure branch.
renderStrategyFailure :: ManifestReloadHostStrategyIssue issue -> String
renderStrategyFailure failure = case failure of
  MrhsiPreservingFailed prev ->
    "preserving: " <> renderHostPreservingIssueTag prev
  MrhsiStoppedAudioFailed stopped ->
    "stopped-audio: " <> renderHostStoppedAudioIssueTag stopped
  MrhsiFallbackStoppedAudioFailed prev stopped ->
    "preserving (" <> renderHostPreservingIssueTag prev
    <> "); stopped-audio fallback ("
    <> renderHostStoppedAudioIssueTag stopped <> ")"

-- | Short kebab-case tag classifying which phase of a preserving
-- reload failed. The carried @issue@ payloads are intentionally
-- elided — the tag identifies the failure shape; the structured
-- value is still in scope via the orchestrator's 'Either' for
-- programmatic consumers.
renderHostPreservingIssueTag :: HostPreservingReloadIssue issue -> String
renderHostPreservingIssueTag issue = case issue of
  HpariPlanRejected{}                ->
    "plan-rejected"
  HpariQuiesceRejected{}             ->
    "quiesce-rejected"
  HpariQuiesceRejectedResumeFailed{} ->
    "quiesce-rejected; resume-failed"
  HpariDrainRejected{}               ->
    "drain-rejected"
  HpariDrainRejectedResumeFailed{}   ->
    "drain-rejected; resume-failed"
  HpariDrainFailedTerminal{}         ->
    "drain-failed (terminal)"
  HpariReloadRejected{}              ->
    -- This constructor is the retryable old-owner-still-installed
    -- shape, not specifically a graph-shape incompatibility.
    -- mapPreservingReloadReport (ManifestReloadHost.hs) collapses
    -- SessionEnqueueRejected through HprfReloadEnqueueRejected and
    -- StepRuntimeFailed / StepRejected through
    -- HprfOldOwnerStillInstalled — both funnel here. The
    -- enqueue-rejected case is named separately on the event
    -- timeline via MrePreservingReloadEnqueueRejected.
    "reload-rejected (old owner still installed)"
  HpariReloadRejectedResumeFailed{}  ->
    "reload-rejected; resume-failed"
  HpariReloadFailedTerminal{}        ->
    "reload-failed (terminal)"
  HpariIngressRestartFailed{}        ->
    "ingress-restart-failed"

-- | Short kebab-case tag classifying which phase of a stopped-audio
-- reload failed. Same elision rationale as
-- 'renderHostPreservingIssueTag'.
renderHostStoppedAudioIssueTag :: HostStoppedAudioReloadIssue issue -> String
renderHostStoppedAudioIssueTag issue = case issue of
  HsariPlanRejected{}                        ->
    "plan-rejected"
  HsariQuiesceRejected{}                     ->
    "quiesce-rejected"
  HsariQuiesceRejectedResumeFailed{}         ->
    "quiesce-rejected; resume-failed"
  HsariDrainRejected{}                       ->
    "drain-rejected"
  HsariDrainRejectedResumeFailed{}           ->
    "drain-rejected; resume-failed"
  HsariDrainFailedTerminal{}                 ->
    "drain-failed (terminal)"
  HsariStopOldAudioFailed{}                  ->
    "stop-old-audio-failed"
  HsariReloadRejectedOldOwnerRestarted{}     ->
    "reload-rejected (old owner restarted)"
  HsariReloadRejectedOldOwnerRestartFailed{} ->
    "reload-rejected (old owner restart-failed)"
  HsariReloadRejectedOldOwnerResumeFailed{}  ->
    "reload-rejected (old owner resume-failed)"
  HsariReloadFailedNoOwner{}                 ->
    "reload-failed (no owner)"
  HsariAudioRestartFailed{}                  ->
    "audio-restart-failed"
  HsariListenerRestartFailed{}               ->
    "listener-restart-failed"

-- | Short kebab-case tag classifying a bare 'ManifestReloadHostIssue'.
-- Carried by the resume-old-ingress recovery event when an old-ingress
-- reopen attempt fails inside an active phase; sharing this renderer
-- with the Hpari / Hsari tags keeps the reload-events block uniform.
renderHostIssueTag :: Show ingressIssue => ManifestReloadHostIssue ingressIssue -> String
renderHostIssueTag issue = case issue of
  MrhiPlanning{}                  ->
    "planning"
  MrhiIngress{}                   ->
    "ingress"
  MrhiDrainStopped{}              ->
    "drain-stopped"
  MrhiDrainLeftQueued{}           ->
    "drain-left-queued"
  MrhiAudio{}                     ->
    "audio"
  MrhiReload{}                    ->
    "reload"
  MrhiPreservingReloadRejected{}  ->
    "preserving-reload-rejected"
  MrhiPreservingReloadStopped{}   ->
    "preserving-reload-stopped"
  MrhiPreservingReloadUnexpected{} ->
    "preserving-reload-unexpected"

-- | Compact tag for an open-time host-stack failure. Payload-free so
-- the carried 'SessionFanInServiceSetupIssue' /
-- 'SessionFanInAudioIssue' / @ingressIssue@ values (which may
-- recursively carry 'TemplateGraph' or 'RuntimeNode' state) never
-- reach the operator transcript via this path.
--
-- 'RhsoiPartialCleanupFailed' nests an inner primary failure; the
-- rendering recurses on that primary so the operator sees both the
-- partial-cleanup signal and the underlying open failure that
-- triggered it.
renderReloadHostStackOpenIssueTag
  :: ReloadHostStackOpenIssue ingressIssue
  -> String
renderReloadHostStackOpenIssueTag issue = case issue of
  RhsoiServiceSetupFailed{}            -> "service-setup-failed"
  RhsoiAudioStartFailed{}              -> "audio-start-failed"
  RhsoiIngressOpenFailed{}             -> "ingress-open-failed"
  RhsoiIngressTargetProjectionFailed{} -> "ingress-target-projection-failed"
  RhsoiPartialCleanupFailed primary _diag ->
    "partial-cleanup-failed ("
      <> renderReloadHostStackOpenIssueTag primary <> ")"

-- | Compact tag for the supervised-route /require-preserving/ cause
-- carried by 'SupervisedReloadRequestRejected' /
-- 'SupervisedReloadRejectedRecovered' / 'SupervisedReloadEscalated'.
-- Composes 'renderHostPreservingIssueTag' (in-window) and
-- 'renderReloadHostStackOpenIssueTag' (rebuild-open) so the operator
-- transcript never carries the underlying
-- 'ManifestPreservingHotSwapReport' payload.
renderPreservingHostStackIssueTag
  :: PreservingHostStackIssue ingressIssue
  -> String
renderPreservingHostStackIssueTag wrapper = case wrapper of
  PahsiInWindow issue ->
    "in-window: " <> renderHostPreservingIssueTag issue
  PahsiOpen openIssue ->
    "open: " <> renderReloadHostStackOpenIssueTag openIssue

-- | Compact tag for the supervised-route /stopped-audio/ cause.
-- Same shape as 'renderPreservingHostStackIssueTag', but the
-- in-window branch tags through 'renderHostStoppedAudioIssueTag'.
renderStoppedAudioHostStackIssueTag
  :: StoppedAudioHostStackIssue ingressIssue
  -> String
renderStoppedAudioHostStackIssueTag wrapper = case wrapper of
  SahsiInWindow issue ->
    "in-window: " <> renderHostStoppedAudioIssueTag issue
  SahsiOpen openIssue ->
    "open: " <> renderReloadHostStackOpenIssueTag openIssue

-- | Compact tag for the three-way 'TryPreservingInWindowIssue'
-- branch the try-preserving in-window slot returns.
renderTryPreservingInWindowIssueTag
  :: TryPreservingInWindowIssue ingressIssue
  -> String
renderTryPreservingInWindowIssueTag issue = case issue of
  TpiwiPreservingFallbackDeclined prev ->
    "preserving-fallback-declined ("
      <> renderHostPreservingIssueTag prev <> ")"
  TpiwiPreservingTerminal prev ->
    "preserving-terminal ("
      <> renderHostPreservingIssueTag prev <> ")"
  TpiwiFallbackStoppedAudioFailed prev curr ->
    "fallback-stopped-audio-failed (preserving="
      <> renderHostPreservingIssueTag prev
      <> "; stopped-audio="
      <> renderHostStoppedAudioIssueTag curr <> ")"

-- | Compact tag for the supervised-route /try-preserving/ cause.
-- Same outer shape as the other two routes' renderers; in-window
-- delegates to 'renderTryPreservingInWindowIssueTag'.
renderTryPreservingHostStackIssueTag
  :: TryPreservingHostStackIssue ingressIssue
  -> String
renderTryPreservingHostStackIssueTag wrapper = case wrapper of
  TpahsiInWindow issue ->
    "in-window: " <> renderTryPreservingInWindowIssueTag issue
  TpahsiOpen openIssue ->
    "open: " <> renderReloadHostStackOpenIssueTag openIssue

renderStrategyOutcome
  :: Either
       (ManifestReloadHostStrategyIssue
         (ManifestReloadHostIssue ManifestOSCIngressOpsIssue))
       (ManifestReloadHostStrategyRan
         (ManifestReloadHostIssue ManifestOSCIngressOpsIssue))
  -> String
renderStrategyOutcome outcome =
  -- The outcome carries the same data the reload-events block already
  -- surfaces, plus a deeply-nested 'ManifestPreservingHotSwapReport'
  -- payload on the preserving-rejected path. The typed renderers
  -- ('renderStrategyRan' / 'renderStrategyFailure') trim that to a
  -- single operator-friendly line and share their vocabulary with
  -- the reload-events block below.
  case outcome of
    Left issue ->
      "failed: " <> renderStrategyFailure issue
    Right ran ->
      "success: " <> renderStrategyRan ran

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

-- | Compact operator-facing renderer for the smoke's captured
-- 'ManifestReloadEvent' timeline. Each event becomes one bullet line
-- with a short label, plus the typed kebab-case stage tag of any
-- payload (via 'renderHostPreservingIssueTag' /
-- 'renderHostStoppedAudioIssueTag' / 'renderHostIssueTag' /
-- 'renderStrategyRan' / 'renderStrategyFailure'). The same
-- vocabulary is shared with the @strategy result:@ line and the
-- @--manifest-live-reload-demo@'s timeline so operators read one
-- surface across both CLIs.
renderSmokeReloadEvents
  :: Show ingressIssue
  => [ManifestReloadEvent
        (ManifestReloadHostIssue ingressIssue)]
  -> [String]
renderSmokeReloadEvents events =
  case events of
    [] ->
      ["    (none)"]
    _ ->
      map renderSmokeReloadEvent events

renderSmokeReloadEvent
  :: Show ingressIssue
  => ManifestReloadEvent
       (ManifestReloadHostIssue ingressIssue)
  -> String
renderSmokeReloadEvent event =
  case event of
    MreStrategyStarted strategy ->
      "    - strategy started: "
      <> renderManifestReloadHostStrategy strategy
    MreStrategySucceeded ran ->
      "    - strategy succeeded: " <> renderStrategyRan ran
    MreStrategyFailed issue ->
      "    - strategy failed: " <> renderStrategyFailure issue
    MrePreservingReloadStarted ->
      "    - preserving phase started"
    MrePreservingReloadCommitted _retired ->
      -- Phase 8h step 3e v1: retired-binding payload is plumbed
      -- through but not yet rendered here. The slice-2
      -- 'retired bindings:' block (see
      -- @notes/2026-05-24-b-stale-producer-command-semantics.md@)
      -- is where this list becomes operator-visible.
      "    - preserving phase committed"
    MrePreservingReloadEnqueueRejected issue ->
      "    - preserving reload enqueue rejected: "
      <> renderHostIssueTag issue
    MrePreservingReloadRejected issue ->
      "    - preserving phase rejected: " <> renderHostPreservingIssueTag issue
    MreStoppedAudioReloadStarted ->
      "    - stopped-audio phase started"
    MreStoppedAudioReloadCommitted _retired ->
      -- Phase 8h step 3e v1: payload plumbed through; slice-2
      -- renderer will surface the count / per-binding rows.
      "    - stopped-audio phase committed"
    MreStoppedAudioReloadRejected issue ->
      "    - stopped-audio phase rejected: " <> renderHostStoppedAudioIssueTag issue
    MreResumeOldIngressStarted ->
      "    - resume old ingress: started"
    MreResumeOldIngressSucceeded ->
      "    - resume old ingress: succeeded"
    MreResumeOldIngressFailed issue ->
      "    - resume old ingress: failed (" <> renderHostIssueTag issue <> ")"
    MreFallbackAdmitted issue ->
      "    - fallback admitted: " <> renderHostPreservingIssueTag issue
    MreFallbackDeclined issue ->
      "    - fallback declined: " <> renderHostPreservingIssueTag issue

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
  , saffiStopAudioFade =
      \_rt _fadeMs ->
        appendSmokeAudioEvent events MhssaStop
  }

appendSmokeAudioEvent
  :: IORef [ManifestHostStrategySmokeAudioEvent]
  -> ManifestHostStrategySmokeAudioEvent
  -> IO ()
appendSmokeAudioEvent ref event =
  modifyIORef' ref (<> [event])

appendSmokeReloadEvent
  :: IORef [ManifestReloadEvent
              (ManifestReloadHostIssue ManifestOSCIngressOpsIssue)]
  -> ManifestReloadEvent
       (ManifestReloadHostIssue ManifestOSCIngressOpsIssue)
  -> IO ()
appendSmokeReloadEvent ref event =
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
