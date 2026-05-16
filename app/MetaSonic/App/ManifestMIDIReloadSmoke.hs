-- |
-- Module      : MetaSonic.App.ManifestMIDIReloadSmoke
-- Description : Manual device-backed smoke runner for the manifest MIDI
--               ingress path.
--
-- This is the operational counterpart to the CI-safe manifest MIDI
-- tests. It opens a real PortMIDI input through
-- 'manifestPortMIDISourceFactory', starts a 'manifestMIDIIngressOps'
-- adapter against the projected MIDI ingress target of a manifest plan,
-- drains accepted commands through 'SessionFanInService', and reports
-- per-event activity:
--
-- * accepted manifest-bound CC writes (printed as
--   'CmdControlWrite' lines);
-- * manifest-layer rejections for unbound CC numbers and invalid
--   channel / data bytes;
-- * non-CC events the v1 manifest path does not route (note on/off,
--   pitch-bend, all-notes-off, ...).
--
-- This is the only path that exercises the @hasDevice == True@ branch
-- of 'manifestPortMIDISourceFactory'; CI cannot make a real PortMIDI
-- input deterministic. The runner does not start audio, does not run a
-- hot-swap, and does not claim reload semantics — it stops at the
-- ingress projection so the operator can verify the open / route /
-- close path on the host's actual hardware.
--
-- Exits non-zero only when the PortMIDI factory cannot produce an
-- input-capable source. Other paths (no events observed, host-level
-- enqueue rejections) print a summary line but do not fail; the smoke
-- is for visual verification, not for CI gating.

module MetaSonic.App.ManifestMIDIReloadSmoke
  ( runManifestMIDIReloadSmoke
  ) where

import           Control.Concurrent             (threadDelay)
import           Control.Exception              (finally)
import           Control.Monad                  (forM_, when, void)
import           Data.IORef                     (IORef, atomicModifyIORef',
                                                 newIORef, readIORef)
import           Data.List                      (find, sortOn)
import qualified Data.Map.Strict                as M
import           Data.Word                      (Word8)
import           System.Exit                    (die)
import           System.IO                      (hFlush, hPutStrLn, stderr,
                                                 stdout)

import           MetaSonic.App.Demos            (Demo, demoTable,
                                                 demoManifestReloadCatalog)
import           MetaSonic.App.ManifestMIDIIngressOps
                                                (ManifestMIDIIngressOpsHooks (..),
                                                 ManifestMIDIIngressOpsIssue (..),
                                                 defaultManifestMIDIIngressOpsHooks,
                                                 manifestMIDIIngressOps)
import           MetaSonic.App.ManifestMIDIListener
                                                (ManifestMIDIListenerHooks (..),
                                                 ManifestMIDIListenerIssue (..))
import           MetaSonic.App.ManifestMIDIPortMIDI
                                                (ManifestMIDIPortMIDIError (..),
                                                 manifestPortMIDISourceFactory)
import           MetaSonic.App.ManifestReloadBinding
                                                (ManifestUIVoiceSelection (..))
import           MetaSonic.App.ManifestReloadCli
                                                (planManifestReloadForDemo,
                                                 readManifestReloadDocFile,
                                                 renderManifestReloadCliIssue)
import           MetaSonic.App.ManifestReloadIngress
                                                (ManifestReloadIngressOps (..),
                                                 closeManifestReloadIngress,
                                                 newManifestReloadIngressManager)
import           MetaSonic.App.ManifestReloadIngressTarget
                                                (ManifestReloadIngressTarget (..),
                                                 ManifestReloadIngressTargetPolicy (..),
                                                 manifestReloadIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadMIDIBinding
                                                (ManifestMIDIControlBinding (..),
                                                 ManifestMIDIAddressIssue (..),
                                                 ManifestMIDIIngressTarget (..))
import           MetaSonic.App.ManifestReloadMIDIIngress
                                                (ManifestMIDIIngressIssue (..))
import           MetaSonic.Authoring.Manifest   (AuthoringManifestDoc)
import           MetaSonic.Bridge.Source        (unMigrationKey)
import           MetaSonic.MIDI.Devices         (MidiDeviceInfo (..),
                                                 midiDeviceList)
import           MetaSonic.Pattern              (ControlTag (..),
                                                 VoiceKey (..))
import           MetaSonic.Session.Command      (SessionCommand (..))
import           MetaSonic.Session.FanIn        (SessionFanInDrainResult,
                                                 SessionFanInEnqueueResult (..),
                                                 sfidrDrain,
                                                 sfidrQueueDepth)
import           MetaSonic.Session.FanInService (SessionFanInServiceHooks (..),
                                                 defaultSessionFanInServiceHooks,
                                                 defaultSessionFanInServiceOptions,
                                                 sessionFanInServiceHost,
                                                 withSessionFanInServiceHooks)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.MIDIPortMIDI (PortMIDISourceOptions (..),
                                                 defaultPortMIDISourceOptions)
import           MetaSonic.Session.MIDIProducer (MIDIProducerEvent (..),
                                                 defaultMIDIProducerOptions)
import           MetaSonic.Session.Queue        (QueuedSessionCommand (..),
                                                 SessionEnqueueResult (..),
                                                 sdrItems, sdrStopped)


data SmokeMIDIDeviceChoice = SmokeMIDIDeviceChoice
  { smdcDeviceId :: !Int
  , smdcLabel    :: !String
  }

data SmokeCounters = SmokeCounters
  { scAccepted     :: !(IORef Int)
  , scEnqueueReject :: !(IORef Int)
  , scDrained      :: !(IORef Int)
  , scUnboundCC    :: !(IORef (M.Map Word8 Int))
  , scOtherIngress :: !(IORef (M.Map String Int))
  , scIgnored      :: !(IORef (M.Map String Int))
  }


-- | Run a bounded manual MIDI device smoke against the manifest reload
-- ingress projection of the selected demo.
--
-- The runner exits non-zero only when no input-capable PortMIDI device
-- can be opened. Empty event counters at end-of-window are reported in
-- the summary but are not a failure condition — a host without active
-- MIDI traffic is still a valid open of the manifest MIDI ingress.
runManifestMIDIReloadSmoke
  :: FilePath
  -- ^ Path to an authoring manifest JSON document (same shape the
  -- other @--manifest-*@ smokes accept).
  -> Demo
  -- ^ Selected demo (must have authoring metadata).
  -> Maybe Int
  -- ^ Explicit PortMIDI device id. 'Nothing' auto-picks the first
  -- input-capable device reported by 'midiDeviceList'.
  -> Int
  -- ^ Smoke window in seconds.
  -> IO ()
runManifestMIDIReloadSmoke manifestPath demo midiDevice seconds = do
  doc <- readManifestDocOrDie manifestPath
  catalog <- either die pure (demoManifestReloadCatalog demoTable)
  plan <-
    case planManifestReloadForDemo doc catalog demo of
      Left issue -> die (renderManifestReloadCliIssue issue)
      Right p    -> pure p

  let policy = smokeIngressTargetPolicy
  target <-
    case manifestReloadIngressTargetFromPlan policy plan of
      Left issue ->
        die ("Manifest MIDI smoke ingress target projection failed: "
             <> show issue)
      Right t ->
        pure t

  -- 'manifestReloadIngressTargetFromPlan' projects the combined target;
  -- the smoke only cares about the MIDI projection slice, which is a
  -- pure subset of the same plan.
  let midiTarget = mitMIDI target

  selected <- resolveSmokeDevice midiDevice

  let sourceOpts = defaultPortMIDISourceOptions
        { pmsoDeviceId = Just (smdcDeviceId selected)
        }

  putStrLn "Manifest MIDI device smoke."
  putStrLn ""
  putStrLn $ "  manifest path: " <> manifestPath
  putStrLn $ "  demo: " <> MR.mrlpDemoKey plan
  putStrLn $ "  device: " <> smdcLabel selected
  putStrLn $ "  window: " <> show seconds <> " second(s)"
  putStrLn $ "  default MIDI voice: "
          <> unVoiceKey (mmitDefaultVoice midiTarget)
  putStrLn ""
  renderBoundCCTable midiTarget
  putStrLn ""
  putStrLn "  no reload executed: this smoke exercises the open / decode /"
  putStrLn "  manifest CC routing path only."
  putStrLn ""
  putStrLn "  Send manifest-bound CCs now (and any other MIDI you want to"
  putStrLn "  observe routed through the ingress projection)."
  putStrLn ""
  hFlush stdout

  counters <- newSmokeCounters

  let factory = manifestPortMIDISourceFactory sourceOpts
      listenerHooks = ManifestMIDIListenerHooks
        { mmlhOnAccepted = handleAccepted counters
        , mmlhOnIssue    = handleIssue counters
        }
      adapterHooks = defaultManifestMIDIIngressOpsHooks
        { mmioohOnSourceCloseFailed =
            \issue ->
              hPutStrLn stderr
                ("  source close failure (handle is not revivable): "
                 <> show issue)
        }

  let serviceHooks = defaultSessionFanInServiceHooks
        { sfshOnDrain = handleDrain counters
        , sfshOnIssue = \issue ->
            hPutStrLn stderr ("  service issue: " <> show issue)
        }

  setupResult <-
    withSessionFanInServiceHooks
      serviceHooks
      (MR.mrlpTemplateGraph plan)
      defaultSessionFanInServiceOptions
      $ \service -> do
          let host = sessionFanInServiceHost service
          let ops =
                manifestMIDIIngressOps
                  listenerHooks
                  adapterHooks
                  defaultMIDIProducerOptions
                  host
                  factory
          opened <- mrioOpenIngress ops target
          case opened of
            Left issue ->
              pure (Left issue)
            Right handle -> do
              manager <-
                newManifestReloadIngressManager ops target handle
              (do
                 putStrLn "  ingress: opened. Listening..."
                 hFlush stdout
                 threadDelay (seconds * 1000000))
                `finally` void (closeManifestReloadIngress manager)
              -- Give the wake-on-enqueue worker a short chance to
              -- drain events that arrive at the end of the window.
              threadDelay 50000
              pure (Right ())

  case setupResult of
    Left issue ->
      die ("Manifest MIDI smoke fan-in service setup failed: " <> show issue)
    Right (Left openIssue) ->
      dieOpenFailure (smdcDeviceId selected) openIssue
    Right (Right ()) -> do
      printSummary counters
      putStrLn "Manifest MIDI device smoke complete."


readManifestDocOrDie :: FilePath -> IO AuthoringManifestDoc
readManifestDocOrDie path = do
  result <- readManifestReloadDocFile path
  case result of
    Left issue ->
      die (renderManifestReloadCliIssue issue)
    Right doc ->
      pure doc

resolveSmokeDevice :: Maybe Int -> IO SmokeMIDIDeviceChoice
resolveSmokeDevice (Just devId) =
  pure SmokeMIDIDeviceChoice
    { smdcDeviceId = devId
    , smdcLabel    = show devId <> " (explicit)"
    }
resolveSmokeDevice Nothing = do
  result <- midiDeviceList
  case result of
    Left err ->
      die $ err
        <> ". Use --midi-list and --midi-device N to select a real input."
    Right devices ->
      case find ((> 0) . midiDeviceInputs) devices of
        Nothing ->
          die $
            "No input-capable MIDI device reported by Q / PortMIDI. "
            <> "Use --midi-list to inspect the device table."
        Just dev ->
          pure SmokeMIDIDeviceChoice
            { smdcDeviceId = midiDeviceId dev
            , smdcLabel =
                "auto id=" <> show (midiDeviceId dev)
                <> " name=\"" <> midiDeviceName dev <> "\""
            }

newSmokeCounters :: IO SmokeCounters
newSmokeCounters = SmokeCounters
  <$> newIORef 0
  <*> newIORef 0
  <*> newIORef 0
  <*> newIORef M.empty
  <*> newIORef M.empty
  <*> newIORef M.empty

-- The listener calls 'mmlhOnAccepted' for every projection-validated
-- CC event, then routes 'SessionEnqueueRejected' results through
-- 'mmlhOnIssue (MmliEnqueueRejected ...)' as well. Counting / printing
-- the rejected case here would double-count it; let 'handleIssue' own
-- that path.
handleAccepted :: SmokeCounters -> SessionFanInEnqueueResult -> IO ()
handleAccepted counters result =
  case sfierResult result of
    SessionEnqueued queued -> do
      bumpInt (scAccepted counters)
      putStrLn ("  accept: " <> renderCommand (qscCommand queued))
    SessionEnqueueRejected{} ->
      pure ()

handleIssue :: SmokeCounters -> ManifestMIDIListenerIssue -> IO ()
handleIssue counters issue = case issue of
  MmliIngressIssue (MmiiAddressIssue (MmaiUnknownCC cc)) -> do
    bumpKey (scUnboundCC counters) cc
    putStrLn ("  reject: unbound cc=" <> show cc)
  MmliIngressIssue (MmiiInvalidChannel ch) -> do
    bumpStringKey (scOtherIngress counters) "invalid-channel"
    putStrLn ("  reject: invalid channel byte=" <> show ch)
  MmliIngressIssue (MmiiInvalidDataByte byte) -> do
    bumpStringKey (scOtherIngress counters) "invalid-data-byte"
    putStrLn ("  reject: invalid data byte=" <> show byte)
  MmliIngressIssue (MmiiChannelFiltered ch) -> do
    bumpStringKey (scOtherIngress counters) "channel-filtered"
    putStrLn ("  reject: channel filtered=" <> show ch)
  MmliEnqueueRejected cmd queueIssue -> do
    bumpInt (scEnqueueReject counters)
    putStrLn $
      "  enqueue-reject: command=" <> renderCommand cmd
      <> " issue=" <> show queueIssue
  MmliIgnoredEvent event -> do
    bumpStringKey (scIgnored counters) (eventKind event)
    putStrLn ("  ignored: " <> renderEvent event)

handleDrain :: SmokeCounters -> SessionFanInDrainResult -> IO ()
handleDrain counters drained = do
  let n = length (sdrItems (sfidrDrain drained))
  bumpBy (scDrained counters) n
  when (n > 0) $
    putStrLn $
      "  drain: items=" <> show n
      <> " queue_depth=" <> show (sfidrQueueDepth drained)
      <> " stopped=" <> show (sdrStopped (sfidrDrain drained))

bumpInt :: IORef Int -> IO ()
bumpInt ref =
  atomicModifyIORef' ref (\n -> (n + 1, ()))

bumpBy :: IORef Int -> Int -> IO ()
bumpBy ref k =
  atomicModifyIORef' ref (\n -> (n + k, ()))

bumpKey :: Ord k => IORef (M.Map k Int) -> k -> IO ()
bumpKey ref k =
  atomicModifyIORef' ref (\m -> (M.insertWith (+) k 1 m, ()))

bumpStringKey :: IORef (M.Map String Int) -> String -> IO ()
bumpStringKey = bumpKey

renderCommand :: SessionCommand -> String
renderCommand cmd = case cmd of
  CmdControlWrite voice tag value ->
    "CmdControlWrite voice="
    <> unVoiceKey voice
    <> " tag=" <> renderControlTag tag
    <> " value=" <> show value
  _ ->
    show cmd

renderControlTag :: ControlTag -> String
renderControlTag (ControlTag key slot) =
  unMigrationKey key <> "/" <> show slot

eventKind :: MIDIProducerEvent -> String
eventKind event = case event of
  MIDIProducerNoteOn{}        -> "note-on"
  MIDIProducerNoteOff{}       -> "note-off"
  MIDIProducerControlChange{} -> "control-change"
  MIDIProducerPitchBend{}     -> "pitch-bend"
  MIDIProducerAllNotesOff{}   -> "all-notes-off"

renderEvent :: MIDIProducerEvent -> String
renderEvent event = case event of
  MIDIProducerNoteOn ch n v ->
    "note-on ch=" <> show ch <> " note=" <> show n <> " vel=" <> show v
  MIDIProducerNoteOff ch n v ->
    "note-off ch=" <> show ch <> " note=" <> show n <> " vel=" <> show v
  MIDIProducerControlChange ch cc v ->
    "control-change ch=" <> show ch <> " cc=" <> show cc
    <> " value=" <> show v
  MIDIProducerPitchBend ch value ->
    "pitch-bend ch=" <> show ch <> " value=" <> show value
  MIDIProducerAllNotesOff mch ->
    "all-notes-off ch=" <> maybe "(all)" show mch

renderBoundCCTable :: ManifestMIDIIngressTarget -> IO ()
renderBoundCCTable target = do
  putStrLn "  bound CC table:"
  case mmitControls target of
    [] ->
      putStrLn "    (none — this manifest binds no CCs)"
    bindings ->
      forM_ (sortOn mmcbCC bindings) $ \binding ->
        putStrLn $
          "    - cc=" <> show (mmcbCC binding)
          <> " tag=" <> renderControlTag (mmcbControlTag binding)
          <> " name=\"" <> mmcbDisplayName binding <> "\""
          <> " default=" <> show (mmcbDefault binding)
          <> " range=[" <> show (mmcbRangeMin binding)
          <> ", " <> show (mmcbRangeMax binding) <> "]"

printSummary :: SmokeCounters -> IO ()
printSummary counters = do
  accepted <- readIORef (scAccepted counters)
  enqueueReject <- readIORef (scEnqueueReject counters)
  drained <- readIORef (scDrained counters)
  unbound <- readIORef (scUnboundCC counters)
  other <- readIORef (scOtherIngress counters)
  ignored <- readIORef (scIgnored counters)
  putStrLn ""
  putStrLn "  summary:"
  putStrLn $ "    accepted: " <> show accepted
  putStrLn $ "    drained: " <> show drained
  putStrLn $ "    enqueue-rejected: " <> show enqueueReject
  putStrLn $ "    unbound-cc rejects: " <> show (sumValues unbound)
  forM_ (M.toAscList unbound) $ \(cc, count) ->
    putStrLn $ "      cc=" <> show cc <> " count=" <> show count
  putStrLn $ "    other ingress rejects: " <> show (sumValues other)
  forM_ (M.toAscList other) $ \(kind, count) ->
    putStrLn $ "      " <> kind <> " count=" <> show count
  putStrLn $ "    ignored non-CC events: " <> show (sumValues ignored)
  forM_ (M.toAscList ignored) $ \(kind, count) ->
    putStrLn $ "      " <> kind <> " count=" <> show count

sumValues :: M.Map k Int -> Int
sumValues = sum . M.elems

dieOpenFailure
  :: Int
  -> ManifestMIDIIngressOpsIssue ManifestMIDIPortMIDIError
  -> IO ()
dieOpenFailure devId (MmioiSourceOpenFailed err) = case err of
  MmppNoInputDevice ->
    die $
      "PortMIDI device id=" <> show devId
      <> " is not input-capable. Use --midi-list to inspect the device"
      <> " table and pick a different --midi-device."
  MmppOpenFailed ->
    die $
      "PortMIDI source open failed for device id=" <> show devId
      <> ". The host's PortMIDI subsystem reported an allocation"
      <> " failure; see stderr for any C-level diagnostic and try"
      <> " again with --midi-list to confirm the device is present."

smokeIngressTargetPolicy :: ManifestReloadIngressTargetPolicy
smokeIngressTargetPolicy = ManifestReloadIngressTargetPolicy
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
