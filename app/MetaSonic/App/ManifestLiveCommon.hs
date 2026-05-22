{-# LANGUAGE LambdaCase         #-}

-- |
-- Module      : MetaSonic.App.ManifestLiveCommon
-- Description : Shared live-config and helper functions for the audible manifest reload CLIs.
--
-- Factored out of "MetaSonic.App.ManifestLiveReloadDemo" so the new
-- "MetaSonic.App.ManifestLiveSession" entrypoint (Phase 8 session-product
-- integration) can reuse the same live audio / OSC ingress configuration
-- and the same operator-facing status / snapshot prints without
-- depending on the diagnostic demo module.
--
-- What lives here:
--
--   * Live config constants: 'liveOSCListenerHooks',
--     'liveIngressTargetPolicy', 'liveReloadProducer',
--     'liveAudioOptions'. Identical across all live-audio entrypoints.
--   * Startup helpers that 'die' on failure: 'readManifestDocOrDie',
--     'planOrDie', 'targetOrDie'. The interactive entrypoints
--     use these only at process start; mid-run failures use the
--     'Either'-returning underlying primitives directly so a bad
--     operator command does not kill the session.
--   * Reload-request builders: 'requestForKey' (primitive),
--     'requestFor' (Demo-shape sugar).
--   * Template auto-start: 'autoStartTemplates',
--     'warnIfMissingVoices'.
--   * Status printing: 'printServiceSnapshot',
--     'printIngressSnapshot', 'printAddressableSurface',
--     'renderIngressSnapshot'.
--   * Reload-event timeline rendering: 'renderLiveReloadEvents'.
--   * OSC control-surface rendering: 'renderOSCControls'.
--
-- What does NOT live here: the direct-path 'startAudioOrDie'
-- (only used by the legacy 'runDirectLiveReloadBody' inside
-- "MetaSonic.App.ManifestLiveReloadDemo"); the demo's hardcoded
-- two-shot OLD\/NEW flow; the session's stdin-command parser.

module MetaSonic.App.ManifestLiveCommon
  ( -- * Live audio + ingress config
    liveOSCListenerHooks
  , liveIngressTargetPolicy
  , liveReloadProducer
  , liveAudioOptions

    -- * Startup helpers (die on failure)
  , readManifestDocOrDie
  , planOrDie
  , targetOrDie

    -- * Reload-request builders
  , requestForKey
  , requestFor

    -- * Template auto-start
  , autoStartTemplates
  , warnIfMissingVoices

    -- * Status printing
  , printServiceSnapshot
  , printIngressSnapshot
  , printAddressableSurface
  , renderIngressSnapshot

    -- * Reload-event timeline
  , renderLiveReloadEvents

    -- * OSC control-surface rendering
  , renderOSCControls
  , renderOSCControlsLine

    -- * OSC listener-event line renderers (pure, testable)
    --
    -- These two helpers are the operator-string contract the
    -- live OSC listener hooks drive against. They are exported
    -- so the test suite can pin the rendered strings — including
    -- the dedup policy encoded by 'renderOSCAcceptLine's 'Maybe'
    -- result — without staging real listener IO or capturing
    -- stdout. 'liveOSCListenerHooks' above already routes through
    -- both: 'molhOnAccepted' uses 'mapM_ ... renderOSCAcceptLine'
    -- so a 'Nothing' return is a no-op, and 'molhOnIssue' renders
    -- the @(reload-window)@ \/ @enqueue-reject@ taxonomy.
    --
    -- See @notes/2026-05-20-d-stale-command-rejection-rendering.md@
    -- for the design rationale and the operator-string taxonomy.
  , renderOSCAcceptLine
  , renderOSCIssueLine

    -- * OSC addressable-surface line renderer (pure, testable)
    --
    -- The startup-time print at 'printAddressableSurface' routes
    -- through this helper so the per-binding rendering can be pinned
    -- as a deterministic operator-string contract without staging
    -- session IO. The same units-confusion that surfaced in the first
    -- operator pass (writing @0.75@ to a cutoff bound in Hz) is what
    -- this surface is meant to preempt: the rendered line now names
    -- the declared default, range, and optional CC binding inline.
  , renderAddressableOSCLine
  ) where

import           Control.Concurrent             (threadDelay)
import           Control.Monad                  (forM, forM_, unless)
import           Data.IORef                     ()
import qualified Data.Map.Strict                as M
import qualified Data.Set                       as S
import qualified Data.Text                      as T
import           System.Exit                    (die)
import           System.Timeout                 (timeout)

import           MetaSonic.App.Demos            (Demo (..))
import           MetaSonic.App.ManifestOSCIngressOps
                                                (ManifestOSCIngressHandle (..),
                                                 ManifestOSCIngressOpsIssue)
import           MetaSonic.App.ManifestOSCListener
                                                (ManifestOSCListenerHooks (..),
                                                 ManifestOSCListenerIssue (..),
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
                                                 renderSmokeReloadEvent)
import           MetaSonic.App.ManifestReloadEvent
                                                (ManifestReloadEvent)
import           MetaSonic.App.ManifestReloadHost
                                                (ManifestReloadHostIssue)
import           MetaSonic.App.ManifestReloadIngress
                                                (ManifestReloadIngressManager,
                                                 ManifestReloadIngressSnapshot (..),
                                                 readManifestReloadIngressManager)
import           MetaSonic.App.ManifestReloadIngressTarget
                                                (ManifestReloadIngressTarget (..),
                                                 ManifestReloadIngressTargetPolicy (..),
                                                 manifestReloadIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadOSCBinding
                                                (ManifestOSCControlBinding (..),
                                                 ManifestOSCIngressTarget (..),
                                                 motControls,
                                                 renderManifestOSCAddressPattern,
                                                 renderManifestOSCAddressTail)
import           MetaSonic.App.ManifestReloadOSCIngress
                                                (ManifestOSCIngressIssue (..))
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
                                                 SessionFanInSnapshot (..))
import           MetaSonic.Session.FanInService (SessionFanInService,
                                                 enqueueSessionFanInServiceCommand,
                                                 readSessionFanInService)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.OSCProducer  (OSCProducerEnqueueResult (..),
                                                 defaultOSCProducerOptions)
import           MetaSonic.Session.Queue        (ProducerId (..),
                                                 ProducerKind (..),
                                                 QueuedSessionCommand (..),
                                                 SessionEnqueueIssue (..),
                                                 SessionEnqueueResult (..))
import           MetaSonic.Session.State        (SessionState (..))


-- | Read an authored manifest doc from disk; 'die' on any failure
-- (file not found, JSON parse error, schema mismatch). For startup
-- use; an interactive replan path that wants to keep the session
-- alive on bad input should call 'readManifestReloadDocFile' directly.
readManifestDocOrDie :: FilePath -> IO AuthoringManifestDoc
readManifestDocOrDie path = do
  result <- readManifestReloadDocFile path
  case result of
    Left issue ->
      die (renderManifestReloadCliIssue issue)
    Right doc ->
      pure doc


-- | Plan a manifest reload for the supplied 'Demo' and 'die' on
-- failure. Startup-only; an interactive replan that needs to reject
-- the operator's command without exiting should call
-- 'planManifestReloadForDemo' directly.
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


-- | Project the ingress target from a plan; 'die' on a projection
-- failure (duplicate MIDI CC mapping in the projection table, etc.).
-- Startup-only.
targetOrDie :: MR.ManifestReloadPlan -> IO ManifestReloadIngressTarget
targetOrDie plan =
  case manifestReloadIngressTargetFromPlan liveIngressTargetPolicy plan of
    Left issue ->
      die ("Manifest live reload ingress target projection failed: "
           <> show issue)
    Right target ->
      pure target


-- | Build a 'ManifestReloadRequest' from a raw demo-key string. The
-- swap label is derived from the same string, matching the demo
-- module's convention. Use this from the interactive path where the
-- operator has typed a key without a 'Demo' value in hand.
requestForKey :: String -> MR.ManifestReloadRequest
requestForKey key = MR.ManifestReloadRequest
  { MR.mrrDemoKey        = key
  , MR.mrrSwapLabel      = SwapLabel key
  , MR.mrrResourcePolicy = MR.defaultManifestResourcePolicy
  }


-- | 'Demo'-shape sugar over 'requestForKey'.
requestFor :: Demo -> MR.ManifestReloadRequest
requestFor demo = requestForKey (demoKey demo)


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


-- | Print a labelled snapshot of the 'SessionFanInService' state
-- (audio running, queue depth, owner / reload status, active voice
-- count). Operators read this to confirm the host is alive.
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


-- | Print a one-line 'ingress: ...' summary of the
-- 'ManifestReloadIngressManager' state.
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
-- 'MetaSonic.App.ManifestReloadCli' so the host-reload-smoke, the
-- live-reload demo, and the live-session shell all report the
-- combined ingress projection in the same shape (UI / OSC / MIDI
-- counts + defaultVoice + bound OSC port).
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


-- | Print the bound OSC control surface (one line per binding)
-- against a given target. Used in the demo preamble (as both
-- @initial OSC surface@ and @target OSC surface@) and in the session
-- shell's status display. Routes per-binding rendering through the
-- pure helper 'renderOSCControlsLine' so the format can be pinned
-- without staging IO.
renderOSCControls :: String -> ManifestReloadIngressTarget -> IO ()
renderOSCControls label target = do
  putStrLn $ "  " <> label <> ":"
  case motControls (mitOSC target) of
    [] ->
      putStrLn "    (no OSC controls)"
    controls ->
      forM_ controls (putStrLn . ("    " <>) . renderOSCControlsLine)


-- | Render one pattern-level OSC control-surface line. Uses the
-- literal @\<voice\>@ placeholder for the voice segment; the
-- per-voice resolution is the job of 'renderAddressableOSCLine'.
--
-- Example renderings:
--
-- @
-- \/\<voice\>\/lpf\/0  (name="cutoff", default=600.0, range=[200.0, 6000.0], cc=74)
-- \/\<voice\>\/cutoff\/1  (name="cutoff", default=1200.0, range=[200.0, 8000.0])
-- @
--
-- The metadata tail is the same 'renderControlBindingMetadata' format
-- the addressable surface uses, so an operator scanning the demo
-- preamble's pattern table and the session's concrete addressable
-- table reads matching unit / range / CC fields on both surfaces.
renderOSCControlsLine :: ManifestOSCControlBinding -> String
renderOSCControlsLine binding =
  renderManifestOSCAddressPattern (mocbControlTag binding)
  <> "  " <> renderControlBindingMetadata binding


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
          putStrLn ("    " <> renderAddressableOSCLine voice binding)


renderConcreteOSCAddress :: VoiceKey -> ControlTag -> String
renderConcreteOSCAddress voice (ControlTag (MigrationKey key) slot) =
  "/" <> unVoiceKey voice <> "/" <> key <> "/" <> show slot


-- | Render one addressable-OSC-surface line for a (voice, binding)
-- pair. The line names the resolved address and surfaces the
-- manifest-declared metadata an operator needs to know the
-- control's units, default, range, and optional MIDI-CC binding.
--
-- Example renderings:
--
-- @
-- \/v0\/lpf\/0  (name="cutoff", default=600.0, range=[200.0, 6000.0], cc=74)
-- \/v0\/cutoff\/1  (name="cutoff", default=1200.0, range=[200.0, 8000.0])
-- @
--
-- The metadata tail is produced by 'renderControlBindingMetadata' so
-- the addressable surface and the pattern-level
-- 'renderOSCControlsLine' share one source of truth.
renderAddressableOSCLine :: VoiceKey -> ManifestOSCControlBinding -> String
renderAddressableOSCLine voice binding =
  renderConcreteOSCAddress voice (mocbControlTag binding)
  <> "  " <> renderControlBindingMetadata binding


-- | The shared @(name=..., default=..., range=[..., ...], cc=...)@
-- metadata tail used by both the pattern-level OSC control-surface
-- table ('renderOSCControlsLine') and the concrete addressable-surface
-- line ('renderAddressableOSCLine'). The trailing @, cc=...@ field is
-- omitted when 'mocbCC' is 'Nothing' — not rendered as @cc=null@ or
-- @cc=@.
--
-- Range bounds and the default render with the same
-- @show :: Double -> String@ format as the @(out-of-range)@ rejection
-- line in 'renderOSCIssueLine', so an operator can copy a value
-- between the addressable surface, the pattern surface, and any
-- rejection diagnostic without unit drift.
renderControlBindingMetadata :: ManifestOSCControlBinding -> String
renderControlBindingMetadata binding =
  "(name=\"" <> mocbDisplayName binding <> "\""
  <> ", default=" <> show (mocbDefault binding)
  <> ", range=[" <> show (mocbRangeMin binding)
  <> ", " <> show (mocbRangeMax binding) <> "]"
  <> ccSuffix
  <> ")"
  where
    ccSuffix = case mocbCC binding of
      Nothing -> ""
      Just cc -> ", cc=" <> show cc


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


-- | The live OSC listener's operator-facing print surface. Both
-- hooks now drive the pure 'renderOSCAcceptLine' \/
-- 'renderOSCIssueLine' helpers defined below: 'molhOnAccepted' only
-- prints when 'renderOSCAcceptLine' returns 'Just' (so an enqueue
-- rejection observed here is a no-op because 'molhOnIssue' owns the
-- rejection line for the same packet), and 'molhOnIssue' renders the
-- new taxonomy that distinguishes 'SeiReloadInProgress' from generic
-- enqueue failures. The previous pair of private renderers that
-- produced two identical "osc enqueue-reject" lines per rejected
-- packet is gone.
liveOSCListenerHooks :: ManifestOSCListenerHooks
liveOSCListenerHooks = defaultManifestOSCListenerHooks
  { molhOnAccepted =
      mapM_ (putStrLn . ("  " <>)) . renderOSCAcceptLine
  , molhOnIssue =
      \issue -> putStrLn ("  " <> renderOSCIssueLine issue)
  }


-- | Render the accepted-side of one OSC listener event into an
-- operator-facing line, or 'Nothing' when the event has no line of
-- its own at this layer.
--
-- The 'Maybe' encodes the dedup policy that the legacy
-- 'renderOSCAccept' / 'renderOSCIssue' pair gets wrong: an enqueue
-- rejection observed through 'molhOnAccepted' returns 'Nothing'
-- here so that 'molhOnIssue' (which fires for the same packet,
-- carrying 'MoliEnqueueRejected') is the single source of the
-- operator-facing line.
--
-- A defensive 'Just' rendering is kept for 'OSCProducerDecodeRejected'
-- because the manifest listener's normal path pre-decodes before the
-- producer call (so the arm should be unreachable today), but a future
-- reorganization of the call chain could expose it. Keeping the
-- defensive line means the operator still sees something instead of
-- silently dropping a packet.
--
-- See @notes/2026-05-20-d-stale-command-rejection-rendering.md@ for
-- the contract this helper anchors.
renderOSCAcceptLine :: OSCProducerEnqueueResult -> Maybe String
renderOSCAcceptLine result = case result of
  OSCProducerDecodeRejected issue ->
    Just ("osc reject (decode): " <> show issue)
  OSCProducerEnqueueAttempted cmd enqueue ->
    case sfierResult enqueue of
      SessionEnqueued _ ->
        Just ("osc accept: " <> renderCommand cmd)
      SessionEnqueueRejected{} ->
        Nothing


-- | Render one 'ManifestOSCListenerIssue' as an operator-facing
-- rejection line, distinguishing the expected-transient reload-
-- window case from generic enqueue failures.
--
-- The taxonomy:
--
-- * 'MoliParseFailure'  → @\"osc reject (parse): ...\"@
-- * 'MoliManifestIssue' → @\"osc reject (manifest): ...\"@
-- * 'MoliEnqueueRejected _ 'SeiReloadInProgress'@ →
--   @\"osc reject (reload-window): <cmd>\"@. No @issue=@ suffix;
--   the @(reload-window)@ label already names the cause.
-- * 'MoliEnqueueRejected _ <other>'@ →
--   @\"osc enqueue-reject: <cmd> issue=<...>\"@. The catch-all,
--   covering 'SeiQueueFull', 'SeiSessionUnavailable', and any
--   future variants.
renderOSCIssueLine :: ManifestOSCListenerIssue -> String
renderOSCIssueLine issue = case issue of
  MoliParseFailure msg ->
    "osc reject (parse): " <> msg
  MoliManifestIssue (MoiiValueOutOfRange tag value lo hi) ->
    "osc reject (out-of-range): tag=" <> renderManifestOSCAddressTail tag
    <> " value=" <> show value
    <> " range=[" <> show lo <> ", " <> show hi <> "]"
  MoliManifestIssue manifestIssue ->
    "osc reject (manifest): " <> show manifestIssue
  MoliEnqueueRejected cmd SeiReloadInProgress ->
    "osc reject (reload-window): " <> renderCommand cmd
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


-- | Producer identity threaded through every live audible
-- entrypoint (demo + session). Using a single identity here keeps
-- arbitration semantics route-stable: a `route flip` from the demo
-- to the session does not silently change which producer-kind
-- enqueued a hot-swap command.
liveReloadProducer :: ProducerId
liveReloadProducer =
  ProducerId ProducerUI (T.pack "manifest-live")


liveAudioOptions :: SessionFanInAudioOptions
liveAudioOptions = SessionFanInAudioOptions
  { sfiaoOutputChannels =
      2
  , sfiaoDeviceID =
      -1
  , sfiaoReadyTimeoutMs =
      1000
  }
