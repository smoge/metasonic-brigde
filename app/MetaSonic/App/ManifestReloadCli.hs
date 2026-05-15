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
  , runManifestStoppedAudioReloadSmokeFile
  , runManifestStoppedAudioReloadSmokeWithDoc
  , runManifestStoppedAudioReloadSmokeWithCatalog
  , renderManifestReloadCliIssue
  , renderManifestStoppedAudioReloadSmoke
  ) where

import           Control.Exception                (IOException, try)
import           Data.Bifunctor                   (first)
import           Data.List                        (find)
import qualified Data.ByteString.Lazy.Char8       as BL
import qualified Data.Map.Strict                  as M

import           MetaSonic.App.Demos              (Demo (..), demoTable,
                                                   demoManifestReloadCatalog)
import           MetaSonic.Authoring.Manifest     (AuthoringManifestDoc,
                                                   decodeManifestDoc)
import           MetaSonic.Bridge.Compile         (RuntimeGraph (..))
import           MetaSonic.Bridge.Source          (unMigrationKey)
import           MetaSonic.Bridge.Templates       (Template (..),
                                                   TemplateGraph (..))
import           MetaSonic.Pattern                (ControlTag (..),
                                                   SwapLabel (..),
                                                   TemplateName (..))
import           MetaSonic.Session.Command        (SessionCommand (..))
import           MetaSonic.Session.FanIn          (SessionFanInReloadIssue,
                                                   SessionFanInSetupIssue,
                                                   SessionFanInSnapshot (..),
                                                   defaultSessionFanInOptions,
                                                   readSessionFanInHost,
                                                   withSessionFanInHost)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.ManifestReload.Runtime
                                                  (ManifestStoppedAudioReloadReport (..),
                                                   reloadManifestSessionStoppedAudio)
import           MetaSonic.Session.Owner          (defaultSessionOwnerOptions)
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
  deriving (Eq, Show)

data ManifestStoppedAudioReloadSmokeResult =
  ManifestStoppedAudioReloadSmokeResult
    { msarsInitialEntry :: !MR.ManifestReloadCatalogEntry
    , msarsPlan         :: !MR.ManifestReloadPlan
    , msarsBefore       :: !SessionFanInSnapshot
    , msarsReport       :: !ManifestStoppedAudioReloadReport
    , msarsAfter        :: !SessionFanInSnapshot
    } deriving (Eq, Show)

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
    MR.planManifestReload doc catalog request
  where
    request = MR.ManifestReloadRequest
      { MR.mrrDemoKey        = demoKey demo
      , MR.mrrSwapLabel      = SwapLabel ("manifest:" <> demoKey demo)
      , MR.mrrResourcePolicy = MR.defaultManifestResourcePolicy
      }

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
