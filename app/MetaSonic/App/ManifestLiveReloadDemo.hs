-- |
-- Module      : MetaSonic.App.ManifestLiveReloadDemo
-- Description : Experimental audible manifest reload demo.
--
-- This is the first opt-in audible consumer of the manifest reload
-- host strategy selector. It starts audio from one authored demo,
-- opens manifest-aware OSC ingress, waits for the operator to press
-- Enter, then reloads to another authored demo through
-- 'reloadManifestHostWithStrategy'.
--
-- The normal demo path is deliberately unchanged. This helper is for
-- integration friction: making the planner, service, audio lifecycle,
-- OSC ingress manager, and strategy selector run together under a real
-- audio stream without claiming that manifest reload is now the default
-- live path.

module MetaSonic.App.ManifestLiveReloadDemo
  ( runManifestLiveReloadDemo
  ) where

import           Control.Concurrent             (threadDelay)
import           Control.Exception              (finally)
import           Control.Monad                  (forM_, void, when)
import qualified Data.Map.Strict                as M
import qualified Data.Text                      as T
import           System.Exit                    (die)
import           System.IO                      (hFlush, stdout)
import           System.Timeout                 (timeout)

import           MetaSonic.App.Demos            (Demo (..), demoTable,
                                                 demoManifestReloadCatalog)
import           MetaSonic.App.ManifestOSCIngressOps
                                                (ManifestOSCIngressHandle (..),
                                                 ManifestOSCIngressOpsIssue,
                                                 manifestOSCIngressOps)
import           MetaSonic.App.ManifestOSCListener
                                                (ManifestOSCListenerHooks (..),
                                                 ManifestOSCListenerIssue (..),
                                                 ListenerConfig,
                                                 ListenerInfo (..),
                                                 defaultManifestOSCListenerHooks)
import           MetaSonic.App.ManifestReloadBinding
                                                (ManifestUIVoiceSelection (..))
import           MetaSonic.App.ManifestReloadCli
                                                (planManifestReloadForDemo,
                                                 readManifestReloadDocFile,
                                                 renderManifestReloadCliIssue,
                                                 renderManifestReloadHostStrategy)
import           MetaSonic.App.ManifestReloadHost
                                                (ManifestReloadHostConfig (..),
                                                 ManifestReloadHostIssue,
                                                 ManifestReloadHostStrategy,
                                                 ManifestReloadHostStrategyIssue,
                                                 ManifestReloadHostStrategyRan,
                                                 reloadManifestHostWithStrategy)
import           MetaSonic.App.ManifestReloadIngress
                                                (ManifestReloadIngressManager,
                                                 ManifestReloadIngressOps (..),
                                                 ManifestReloadIngressSnapshot (..),
                                                 closeManifestReloadIngress,
                                                 newManifestReloadIngressManager,
                                                 readManifestReloadIngressManager)
import           MetaSonic.App.ManifestReloadIngressTarget
                                                (ManifestReloadIngressTarget (..),
                                                 ManifestReloadIngressTargetPolicy (..),
                                                 manifestReloadIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadOSCBinding
                                                (ManifestOSCControlBinding (..),
                                                 ManifestOSCIngressTarget (..),
                                                 motControls,
                                                 renderManifestOSCAddressPattern)
import           MetaSonic.Authoring.Manifest   (AuthoringManifestDoc)
import           MetaSonic.Bridge.Templates     (Template (..),
                                                 TemplateGraph (..))
import           MetaSonic.Bridge.Source        (MigrationKey (..))
import           MetaSonic.Pattern              (ControlTag (..),
                                                 SwapLabel (..),
                                                 TemplateName (..),
                                                 VoiceKey (..))
import           MetaSonic.Session.Command      (SessionCommand (..))
import           MetaSonic.Session.FanIn        (SessionFanInAudioOptions (..),
                                                 SessionFanInEnqueueResult (..),
                                                 SessionFanInSnapshot (..),
                                                 SessionFanInHost,
                                                 defaultSessionFanInAudioFFI,
                                                 startSessionFanInHostAudioWith,
                                                 stopSessionFanInHostAudioWith)
import           MetaSonic.Session.FanInService (SessionFanInService,
                                                 defaultSessionFanInServiceOptions,
                                                 enqueueSessionFanInServiceCommand,
                                                 readSessionFanInService,
                                                 sessionFanInServiceHost,
                                                 withSessionFanInService)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.OSCProducer  (OSCProducerEnqueueResult (..),
                                                 defaultOSCProducerOptions)
import           MetaSonic.Session.Owner        (defaultSessionOwnerOptions)
import           MetaSonic.Session.Queue        (ProducerId (..),
                                                 ProducerKind (..),
                                                 QueuedSessionCommand (..),
                                                 SessionEnqueueResult (..))
import           MetaSonic.Session.State        (SessionState (..))


-- | Run an experimental audible manifest reload demo.
--
-- The command starts from @oldDemo@, then reloads to @newDemo@ when the
-- operator presses Enter. OSC ingress is bound through the supplied
-- listener config. The helper auto-starts one instance per template so
-- authored demos are audible without a separate MIDI/UI voice source.
runManifestLiveReloadDemo
  :: ManifestReloadHostStrategy
  -> FilePath
  -> Demo
  -> Demo
  -> ListenerConfig
  -> IO ()
runManifestLiveReloadDemo strategy manifestPath oldDemo newDemo listenerCfg = do
  doc <- readManifestDocOrDie manifestPath
  catalog <- either die pure (demoManifestReloadCatalog demoTable)
  oldPlan <- planOrDie doc catalog oldDemo
  newPlan <- planOrDie doc catalog newDemo
  oldTarget <- targetOrDie oldPlan
  newTarget <- targetOrDie newPlan

  putStrLn "Manifest live reload demo (experimental)."
  putStrLn ""
  putStrLn $ "  manifest path: " <> manifestPath
  putStrLn $ "  strategy: " <> renderManifestReloadHostStrategy strategy
  putStrLn $ "  initial demo: " <> demoKey oldDemo
  putStrLn $ "  target demo: " <> demoKey newDemo
  putStrLn "  normal demo path: unchanged"
  putStrLn "  ingress: manifest-aware OSC only"
  putStrLn ""
  renderOSCControls "initial OSC surface" oldTarget
  renderOSCControls "target OSC surface" newTarget
  putStrLn ""
  putStrLn "  This path starts real audio and runs the manifest host"
  putStrLn "  strategy selector. It is still opt-in and experimental."
  putStrLn ""
  hFlush stdout

  result <-
    withSessionFanInService
      (MR.mrlpTemplateGraph oldPlan)
      defaultSessionFanInServiceOptions
      $ \service -> runWithService
          doc catalog oldPlan newPlan oldTarget newTarget service
  case result of
    Left issue ->
      die ("Manifest live reload demo setup failed: " <> show issue)
    Right () ->
      pure ()
  where
    runWithService doc catalog oldPlan newPlan oldTarget newTarget service = do
      let host = sessionFanInServiceHost service
          listenerHooks =
            liveOSCListenerHooks
          ops =
            manifestOSCIngressOps
              listenerHooks
              defaultOSCProducerOptions
              host
              listenerCfg
      opened <- mrioOpenIngress ops oldTarget
      case opened of
        Left issue ->
          die ("Initial OSC ingress open failed: " <> show issue)
        Right initialHandle -> do
          ingressManager <-
            newManifestReloadIngressManager ops oldTarget initialHandle
          let cleanup = do
                void (closeManifestReloadIngress ingressManager)
                void (stopSessionFanInHostAudioWith
                        defaultSessionFanInAudioFFI
                        host)
          (do
             startAudioOrDie host
             autoStartTemplates "initial" service oldPlan
             printServiceSnapshot "initial fan-in" service
             printIngressSnapshot ingressManager
             printAddressableSurface service oldTarget
             putStrLn ""
             putStrLn "  Audio is running. Send OSC to the initial surface,"
             putStrLn "  then press Enter to reload."
             void getLine

             let config = ManifestReloadHostConfig
                   { mrhcService =
                       service
                   , mrhcIngressManager =
                       ingressManager
                   , mrhcOldIngressTarget =
                       oldTarget
                   , mrhcNewIngressTarget =
                       newTarget
                   , mrhcAudioFFI =
                       defaultSessionFanInAudioFFI
                   , mrhcAudioOptions =
                       liveAudioOptions
                   , mrhcOwnerOptions =
                       defaultSessionOwnerOptions
                   }
             outcome <-
               reloadManifestHostWithStrategy
                 liveReloadProducer
                 strategy
                 config
                 doc
                 catalog
                 (requestFor newDemo)
             putStrLn ""
             putStrLn $ "  strategy outcome: " <> renderOutcome outcome
             afterReload <- readSessionFanInService service
             case outcome of
               Right _
                 | M.null (ssVoices (sfisOwnerState afterReload)) ->
                     autoStartTemplates "post-reload" service newPlan
               _ ->
                 pure ()
             printServiceSnapshot "post-reload fan-in" service
             -- The strategy's failure paths can leave ingress in
             -- different states (closed, resumed on the old target, or
             -- open on the new target) so the snapshot is the source
             -- of truth for what the operator can actually address —
             -- the strategy 'outcome' alone is not enough.
             ingressSnapshot <-
               readManifestReloadIngressManager ingressManager
             putStrLn $
               "  OSC ingress: " <> renderIngressSnapshot ingressSnapshot
             case ingressSnapshot of
               MrisOpen liveTarget _ -> do
                 printAddressableSurface service liveTarget
                 putStrLn ""
                 putStrLn $
                   "  Send OSC to the surface for demo="
                   <> motDemoKey (mitOSC liveTarget)
                   <> ", then press Enter"
                 putStrLn "  to stop audio and close ingress."
               MrisClosed -> do
                 putStrLn
                   "  addressable OSC surface: (none — ingress is closed)"
                 putStrLn ""
                 putStrLn
                   "  Ingress is closed; OSC packets cannot be routed."
                 putStrLn "  Press Enter to stop audio."
             void getLine)
            `finally` cleanup

readManifestDocOrDie :: FilePath -> IO AuthoringManifestDoc
readManifestDocOrDie path = do
  result <- readManifestReloadDocFile path
  case result of
    Left issue ->
      die (renderManifestReloadCliIssue issue)
    Right doc ->
      pure doc

planOrDie
  :: AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> Demo
  -> IO MR.ManifestReloadPlan
planOrDie doc catalog demo =
  case planManifestReloadForDemo doc catalog demo of
    Left issue ->
      die (renderManifestReloadCliIssue issue)
    Right plan ->
      pure plan

targetOrDie :: MR.ManifestReloadPlan -> IO ManifestReloadIngressTarget
targetOrDie plan =
  case manifestReloadIngressTargetFromPlan liveIngressTargetPolicy plan of
    Left issue ->
      die ("Manifest live reload ingress target projection failed: "
           <> show issue)
    Right target ->
      pure target

requestFor :: Demo -> MR.ManifestReloadRequest
requestFor demo = MR.ManifestReloadRequest
  { MR.mrrDemoKey =
      demoKey demo
  , MR.mrrSwapLabel =
      SwapLabel (demoKey demo)
  , MR.mrrResourcePolicy =
      MR.defaultManifestResourcePolicy
  }

startAudioOrDie
  :: SessionFanInHost
  -> IO ()
startAudioOrDie host = do
  started <-
    startSessionFanInHostAudioWith
      defaultSessionFanInAudioFFI
      host
      liveAudioOptions
  case started of
    Left issue ->
      die ("Manifest live reload audio start failed: " <> show issue)
    Right () ->
      pure ()

autoStartTemplates
  :: String
  -> SessionFanInService
  -> MR.ManifestReloadPlan
  -> IO ()
autoStartTemplates label service plan = do
  let templates = tgTemplates (MR.mrlpTemplateGraph plan)
  case templates of
    [] ->
      putStrLn $ "  " <> label <> ": no templates to auto-start."
    _ -> do
      putStrLn $
        "  " <> label <> ": auto-starting one instance per template..."
      forM_ templates $ \tpl -> do
        let name = tplName tpl
            voice = VoiceKey ("auto-" <> name)
            cmd = CmdVoiceOn (TemplateName name) voice []
        enq <- enqueueSessionFanInServiceCommand
                 liveReloadProducer
                 cmd
                 service
        putStrLn $
          "    " <> name <> " -> " <> renderEnqueue enq
      ready <- waitForAnyVoice service
      when (not ready) $
        putStrLn "    warning: no active voice observed after auto-start."

waitForAnyVoice :: SessionFanInService -> IO Bool
waitForAnyVoice service =
  maybe False id <$> timeout 1000000 loop
  where
    loop = do
      snapshot <- readSessionFanInService service
      if M.null (ssVoices (sfisOwnerState snapshot))
        then threadDelay 10000 >> loop
        else pure True

printServiceSnapshot :: String -> SessionFanInService -> IO ()
printServiceSnapshot label service = do
  snapshot <- readSessionFanInService service
  putStrLn $ "  " <> label <> ":"
  putStrLn $ "    audio running: "
          <> if sfisAudioRunning snapshot then "yes" else "no"
  putStrLn $ "    queue depth: " <> show (sfisQueueDepth snapshot)
  putStrLn $ "    owner status: " <> show (sfisOwnerStatus snapshot)
  putStrLn $ "    reload status: " <> show (sfisReloadStatus snapshot)
  putStrLn $ "    active voices: "
          <> show (M.size (ssVoices (sfisOwnerState snapshot)))

printIngressSnapshot
  :: ManifestReloadIngressManager
       ManifestReloadIngressTarget
       ManifestOSCIngressOpsIssue
       ManifestOSCIngressHandle
  -> IO ()
printIngressSnapshot manager = do
  snapshot <- readManifestReloadIngressManager manager
  putStrLn $ "  OSC ingress: " <> renderIngressSnapshot snapshot

renderIngressSnapshot
  :: ManifestReloadIngressSnapshot
       ManifestReloadIngressTarget
       ManifestOSCIngressHandle
  -> String
renderIngressSnapshot snapshot =
  case snapshot of
    MrisClosed ->
      "closed"
    MrisOpen target handle ->
      "open demo="
      <> motDemoKey (mitOSC target)
      <> " osc-controls="
      <> show (length (motControls (mitOSC target)))
      <> " oscPort="
      <> show (liBoundPort (moihInfo handle))

renderOSCControls :: String -> ManifestReloadIngressTarget -> IO ()
renderOSCControls label target = do
  putStrLn $ "  " <> label <> ":"
  case motControls (mitOSC target) of
    [] ->
      putStrLn "    (no OSC controls)"
    controls ->
      forM_ controls renderOne
  where
    renderOne binding =
      putStrLn $
        "    " <> renderManifestOSCAddressPattern (mocbControlTag binding)
        <> "  name=\"" <> mocbDisplayName binding <> "\""

-- | Print the concrete OSC addresses the operator can send packets to
-- right now. The address surface is voices × bound CC controls — the
-- 'renderOSCControls' table above prints the pattern with a literal
-- @\<voice\>@ placeholder; this resolves the placeholder against the
-- voices that are actually live in 'ssVoices'. Empty voice set means
-- OSC writes will route nowhere; the operator should know.
printAddressableSurface
  :: SessionFanInService
  -> ManifestReloadIngressTarget
  -> IO ()
printAddressableSurface service target = do
  snapshot <- readSessionFanInService service
  let voices = M.keys (ssVoices (sfisOwnerState snapshot))
      bindings = motControls (mitOSC target)
  case (voices, bindings) of
    ([], _) ->
      putStrLn
        "  addressable OSC surface: (no active voices, OSC writes route nowhere)"
    (_, []) ->
      putStrLn
        "  addressable OSC surface: (manifest binds no OSC controls)"
    _ -> do
      putStrLn "  addressable OSC surface:"
      forM_ voices $ \voice ->
        forM_ bindings $ \binding ->
          putStrLn $
            "    " <> renderConcreteOSCAddress voice (mocbControlTag binding)
            <> "  (name=\"" <> mocbDisplayName binding <> "\")"

renderConcreteOSCAddress :: VoiceKey -> ControlTag -> String
renderConcreteOSCAddress voice (ControlTag (MigrationKey key) slot) =
  "/" <> unVoiceKey voice <> "/" <> key <> "/" <> show slot

renderEnqueue :: SessionFanInEnqueueResult -> String
renderEnqueue result =
  case sfierResult result of
    SessionEnqueued queued ->
      "enqueued " <> show (qscCommand queued)
    SessionEnqueueRejected _producer cmd issue ->
      "rejected " <> show cmd <> " issue=" <> show issue

renderOutcome
  :: Either
       (ManifestReloadHostStrategyIssue
          (ManifestReloadHostIssue ManifestOSCIngressOpsIssue))
       (ManifestReloadHostStrategyRan
          (ManifestReloadHostIssue ManifestOSCIngressOpsIssue))
  -> String
renderOutcome outcome =
  case outcome of
    Left issue ->
      "failed: " <> show issue
    Right ran ->
      "success: " <> show ran

liveOSCListenerHooks :: ManifestOSCListenerHooks
liveOSCListenerHooks = defaultManifestOSCListenerHooks
  { molhOnAccepted =
      \accepted -> putStrLn ("  " <> renderOSCAccept accepted)
  , molhOnIssue =
      \issue -> putStrLn ("  " <> renderOSCIssue issue)
  }

renderOSCAccept :: OSCProducerEnqueueResult -> String
renderOSCAccept result = case result of
  OSCProducerDecodeRejected issue ->
    "osc reject (decode): " <> show issue
  OSCProducerEnqueueAttempted cmd enqueue ->
    case sfierResult enqueue of
      SessionEnqueued _ ->
        "osc accept: " <> renderCommand cmd
      SessionEnqueueRejected _producer _cmd issue ->
        "osc enqueue-reject: " <> renderCommand cmd
        <> " issue=" <> show issue

renderOSCIssue :: ManifestOSCListenerIssue -> String
renderOSCIssue issue = case issue of
  MoliParseFailure msg ->
    "osc reject (parse): " <> msg
  MoliManifestIssue manifestIssue ->
    "osc reject (manifest): " <> show manifestIssue
  MoliEnqueueRejected cmd queueIssue ->
    "osc enqueue-reject: " <> renderCommand cmd
    <> " issue=" <> show queueIssue

renderCommand :: SessionCommand -> String
renderCommand cmd = case cmd of
  CmdControlWrite voice tag value ->
    "CmdControlWrite voice=" <> unVoiceKey voice
    <> " tag=" <> show tag
    <> " value=" <> show value
  CmdVoiceOn (TemplateName name) voice _args ->
    "CmdVoiceOn template=" <> name <> " voice=" <> unVoiceKey voice
  _ ->
    show cmd

liveIngressTargetPolicy :: ManifestReloadIngressTargetPolicy
liveIngressTargetPolicy = ManifestReloadIngressTargetPolicy
  { mritpUIVoiceSelection =
      ManifestUIVoiceSelection
        { muvsFocusedVoice =
            Nothing
        , muvsDefaultVoice =
            VoiceKey "v0"
        }
  , mritpUIRetainedValues =
      M.empty
  , mritpMIDIDefaultVoice =
      VoiceKey "fx"
  }

liveReloadProducer :: ProducerId
liveReloadProducer =
  ProducerId ProducerUI (T.pack "manifest-live-reload-demo")

liveAudioOptions :: SessionFanInAudioOptions
liveAudioOptions = SessionFanInAudioOptions
  { sfiaoOutputChannels =
      2
  , sfiaoDeviceID =
      -1
  , sfiaoReadyTimeoutMs =
      1000
  }
