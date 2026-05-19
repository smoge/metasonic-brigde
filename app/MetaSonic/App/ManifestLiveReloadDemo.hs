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
import           Control.Monad                  (forM, forM_, unless, void)
import           Data.IORef                     (modifyIORef', newIORef,
                                                 readIORef)
import qualified Data.Map.Strict                as M
import qualified Data.Set                       as S
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
                                                (ManifestUIVoiceSelection (..),
                                                 muitControls,
                                                 muitDemoKey,
                                                 muitVoiceSelection)
import           MetaSonic.App.ManifestReloadMIDIBinding
                                                (mmitControls)
import           MetaSonic.App.ManifestReloadCli
                                                (planManifestReloadForDemo,
                                                 readManifestReloadDocFile,
                                                 renderManifestReloadCliIssue,
                                                 renderManifestReloadHostStrategy,
                                                 renderSmokeReloadEvent,
                                                 renderStrategyOutcome)
import           MetaSonic.App.ManifestReloadEvent
                                                (ManifestReloadEvent)
import           MetaSonic.App.ManifestReloadHost
                                                (ManifestReloadHostConfig (..),
                                                 ManifestReloadHostIssue,
                                                 ManifestReloadHostStrategy,
                                                 reloadManifestHostWithStrategyWithEvents)
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
             initialVoices <- autoStartTemplates "initial" service oldPlan
             warnIfMissingVoices service initialVoices
             printServiceSnapshot "initial fan-in" service
             printIngressSnapshot ingressManager
             printAddressableSurface service oldTarget
             putStrLn ""
             putStrLn "  Audio is running. Send OSC to the initial surface,"
             putStrLn "  then press Enter to reload."
             void getLine

             reloadEvents <- newIORef []
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
                   , mrhcOnEvent =
                       \ev ->
                         modifyIORef' reloadEvents (<> [ev])
                   }
             outcome <-
               reloadManifestHostWithStrategyWithEvents
                 liveReloadProducer
                 strategy
                 config
                 doc
                 catalog
                 (requestFor newDemo)
             capturedEvents <- readIORef reloadEvents
             putStrLn ""
             putStrLn $ "  strategy outcome: " <> renderStrategyOutcome outcome
             putStrLn "  reload events:"
             mapM_ putStrLn (renderLiveReloadEvents capturedEvents)
             afterReload <- readSessionFanInService service
             postReloadVoices <- case outcome of
               Right _
                 | M.null (ssVoices (sfisOwnerState afterReload)) ->
                     autoStartTemplates "post-reload" service newPlan
               _ ->
                 pure []
             warnIfMissingVoices service postReloadVoices
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

-- | Pick an OSC-safe voice key for an auto-spawned template.
--
-- The OSC dispatch layer caps voice keys at 16 bytes (see
-- 'isOscSafeIdentifier'); the previous "auto-<name>" scheme rejected
-- as 'DiIdentifierProfile' for template names longer than 11
-- characters (e.g. "auto-named-control" is 18 bytes). Policy:
--
--   * Template literally named "fx" keeps "fx" as its voice key
--     (already a valid identifier and operator-meaningful).
--   * Everything else gets "v<index>" where index counts non-"fx"
--     templates in declaration order.
--
-- Both shapes satisfy 'isOscSafeIdentifier' for any input.
autoVoiceKeyPolicy :: String -> Int -> VoiceKey
autoVoiceKeyPolicy name nonFxIndex
  | name == "fx" = VoiceKey "fx"
  | otherwise    = VoiceKey ("v" <> show nonFxIndex)

-- | Pair every template with the voice key it will be auto-spawned
-- under. Preserves declaration order so the policy's "v<index>" tracks
-- the operator-visible ordering in the addressable surface print.
assignAutoVoiceKeys :: [Template] -> [(Template, VoiceKey)]
assignAutoVoiceKeys = go 0
  where
    go _   []     = []
    go idx (t:ts)
      | tplName t == "fx" =
          (t, autoVoiceKeyPolicy (tplName t) idx) : go idx ts
      | otherwise =
          (t, autoVoiceKeyPolicy (tplName t) idx) : go (idx + 1) ts

-- | Enqueue one 'CmdVoiceOn' per template using the OSC-safe key
-- policy from 'autoVoiceKeyPolicy', and return the keys the caller
-- should wait for and surface. The wait is no longer inline so callers
-- can decide between 'waitForVoices' and proceeding immediately.
autoStartTemplates
  :: String
  -> SessionFanInService
  -> MR.ManifestReloadPlan
  -> IO [VoiceKey]
autoStartTemplates label service plan = do
  let templates = tgTemplates (MR.mrlpTemplateGraph plan)
  case templates of
    [] -> do
      putStrLn $ "  " <> label <> ": no templates to auto-start."
      pure []
    _ -> do
      putStrLn $
        "  " <> label <> ": auto-starting one instance per template..."
      forM (assignAutoVoiceKeys templates) $ \(tpl, voice) -> do
        let name = tplName tpl
            cmd = CmdVoiceOn (TemplateName name) voice []
        enq <- enqueueSessionFanInServiceCommand
                 liveReloadProducer
                 cmd
                 service
        putStrLn $
          "    " <> name <> " -> " <> renderEnqueue enq
        pure voice

-- | Wait (up to 1s) for every named key to appear in 'ssVoices'.
-- Returns True if all keys arrived, False on timeout. Replaces the
-- old 'waitForAnyVoice' which could not distinguish "the voice I
-- auto-spawned arrived" from "some other voice exists" — the
-- downstream surface printer needs the specific keys to be live
-- before snapshotting.
waitForVoices :: [VoiceKey] -> SessionFanInService -> IO Bool
waitForVoices []   _       = pure True
waitForVoices want service =
  maybe False id <$> timeout 1000000 loop
  where
    wantSet = S.fromList want
    loop = do
      snapshot <- readSessionFanInService service
      let have = M.keysSet (ssVoices (sfisOwnerState snapshot))
      if wantSet `S.isSubsetOf` have
        then pure True
        else threadDelay 10000 >> loop

-- | Wait for the supplied auto-spawned voice keys and emit a single
-- warning line if any failed to arrive in time. The list is the
-- caller-tracked truth (from 'autoStartTemplates'), not 'ssVoices' —
-- so the warning names exactly which keys didn't show up.
warnIfMissingVoices :: SessionFanInService -> [VoiceKey] -> IO ()
warnIfMissingVoices _       []   = pure ()
warnIfMissingVoices service want = do
  ready <- waitForVoices want service
  unless ready $ do
    snapshot <- readSessionFanInService service
    let have    = M.keysSet (ssVoices (sfisOwnerState snapshot))
        missing = [ k | k <- want, not (S.member k have) ]
    putStrLn $
      "    warning: auto-started voices did not all arrive in time; missing="
      <> show (map unVoiceKey missing)

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
  putStrLn $ "  ingress: " <> renderIngressSnapshot snapshot

-- | Mirrors @renderSmokeIngressSnapshot@ in
-- 'MetaSonic.App.ManifestReloadCli' so the host-reload-smoke and
-- the live-reload-demo report the combined ingress projection in
-- the same shape (UI / OSC / MIDI counts + defaultVoice + bound
-- OSC port). The underlying 'ManifestReloadIngressTarget' carries
-- all three slices regardless of which CLI is reading it.
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
      <> muitDemoKey (mitUI target)
      <> " ui-controls="
      <> show (length (muitControls (mitUI target)))
      <> " osc-controls="
      <> show (length (motControls (mitOSC target)))
      <> " midi-cc="
      <> show (length (mmitControls (mitMIDI target)))
      <> " defaultVoice="
      <> unVoiceKey
           (muvsDefaultVoice (muitVoiceSelection (mitUI target)))
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
-- voices that are actually live in 'ssVoices'.
--
-- Empty voice set is rare in practice because the caller is expected
-- to have just run 'warnIfMissingVoices' against the keys returned by
-- 'autoStartTemplates'. If it still happens, surface a true statement
-- — writes are still accepted at the manifest layer, but they have no
-- audible target until a voice is live for them to drive.
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
        "  addressable OSC surface: (no live voices; manifest writes are accepted but have no audible target)"
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

-- | Render the per-run reload-event timeline as a compact bullet
-- list, mirroring the @--manifest-host-reload-smoke@ surface so
-- operators read the same vocabulary in both CLIs.
renderLiveReloadEvents
  :: [ManifestReloadEvent
        (ManifestReloadHostIssue ManifestOSCIngressOpsIssue)]
  -> [String]
renderLiveReloadEvents events =
  case events of
    [] ->
      ["    (none)"]
    _ ->
      map renderSmokeReloadEvent events

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
