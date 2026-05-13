{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : MetaSonic.App.SessionMidiSmoke
-- Description : Manual smoke runner for the session MIDI ingress path.
--
-- This is a repeatable manual probe for the session-layer MIDI path:
-- Q / PortMIDI source -> decoded MIDI listener -> MIDI producer ->
-- fan-in service -> session owner. It deliberately does not start
-- realtime audio; the old @midi-poly@ demo remains the audible live
-- MIDI path.

module MetaSonic.App.SessionMidiSmoke
  ( runSessionMidiSmoke
  ) where

import           Control.Concurrent             (threadDelay)
import           Control.Monad                  (unless, when)
import           Data.List                      (find)
import qualified Data.Map.Strict                as M
import           Data.IORef                     (newIORef, modifyIORef',
                                                 readIORef)
import           Data.Text                      (pack)
import           System.Exit                    (die)
import           System.IO                      (hFlush, hPutStrLn, stderr,
                                                 stdout)

import           MetaSonic.Bridge.Source        (MigrationKey (..),
                                                 SynthGraph, env,
                                                 gain, out, runSynth, sinOsc,
                                                 tagged)
import           MetaSonic.Bridge.Templates     (compileTemplateGraph)
import           MetaSonic.Bridge.MidiDemo      (MidiDeviceInfo (..),
                                                 midiDeviceList)
import           MetaSonic.Pattern              (ControlTag (..),
                                                 TemplateName (..))
import           MetaSonic.Session.FanIn        (sfidrDrain,
                                                 sfidrQueueDepth,
                                                 sfierResult,
                                                 sfisQueueDepth)
import           MetaSonic.Session.FanInService (SessionFanInServiceHooks (..),
                                                 defaultSessionFanInServiceHooks,
                                                 defaultSessionFanInServiceOptions,
                                                 readSessionFanInService,
                                                 sessionFanInServiceHost,
                                                 withSessionFanInServiceHooks)
import qualified MetaSonic.Session.MIDIListener as MIDIS
import           MetaSonic.Session.MIDIProducer (MIDIControlMapping (..),
                                                 MIDIProducerEnqueueResult (..),
                                                 MIDIProducerOptions (..),
                                                 defaultMIDIProducerOptions,
                                                 initialMIDIProducerState,
                                                 mpcbCommands,
                                                 mpsActiveNotes)
import qualified MetaSonic.Session.MIDIPortMIDI as MIDIPM
import           MetaSonic.Session.Queue        (sdrItems, sdrStopped)

data SmokeMIDIDevice = SmokeMIDIDevice
  { smdDeviceId :: !Int
  , smdLabel    :: !String
  } deriving (Eq, Show)

-- | Run a bounded manual smoke test over the session MIDI ingress
-- stack. The command exits non-zero when no input device opens or
-- when no supported note/CC events are observed in the smoke window.
runSessionMidiSmoke :: Maybe Int -> Int -> IO ()
runSessionMidiSmoke midiDevice seconds = do
  graph <- case compileTemplateGraph [("voice", sessionMidiSmokeGraph)] of
    Right tg  -> pure tg
    Left err  -> die $ "Session MIDI smoke graph failed to compile: " <> err

  selectedDevice <- resolveSmokeMIDIDevice midiDevice

  let sourceOpts = MIDIPM.defaultPortMIDISourceOptions
        { MIDIPM.pmsoDeviceId = Just (smdDeviceId selectedDevice)
        }

  putStrLn "Session MIDI smoke."
  putStrLn ""
  putStrLn "  path: PortMIDI/Q -> Session.MIDIListener -> FanInService"
  putStrLn "  graph: tagged carrier/envelope/velocity/level voice template"
  putStrLn $ "  device: " <> smdLabel selectedDevice
  putStrLn $ "  window: " <> show seconds <> " second(s)"
  putStrLn ""
  hFlush stdout

  MIDIPM.withPortMIDISource sourceOpts $ \case
    Nothing ->
      die "Failed to allocate PortMIDI session source."
    Just source -> do
      hasDevice <- MIDIPM.portMIDISourceHasDevice source
      unless hasDevice $
        dieAfterFlush
          ("No input-capable MIDI device opened. Use --midi-list and "
           <> "--midi-device N to select a real input.")

      producerEvents <- newIORef (0 :: Int)
      listenerIssues <- newIORef (0 :: Int)
      drainedItems   <- newIORef (0 :: Int)

      let serviceHooks =
            defaultSessionFanInServiceHooks
              { sfshOnDrain = \drained -> do
                  let n = length (sdrItems (sfidrDrain drained))
                  modifyIORef' drainedItems (+ n)
                  when (n > 0) $
                    putStrLn $
                      "  drain: items=" <> show n
                      <> " queue_depth=" <> show (sfidrQueueDepth drained)
                      <> " stopped=" <> show (sdrStopped (sfidrDrain drained))
              , sfshOnIssue = \issue ->
                  hPutStrLn stderr ("  service issue: " <> show issue)
              }

          listenerHooks =
            MIDIS.defaultSessionMIDIListenerHooks
              { MIDIS.smlhOnProducerResult = \result -> do
                  modifyIORef' producerEvents (+ 1)
                  putStrLn ("  producer: " <> summarizeProducerResult result)
              , MIDIS.smlhOnIssue = \issue -> do
                  modifyIORef' listenerIssues (+ 1)
                  hPutStrLn stderr ("  listener issue: " <> show issue)
              }

      result <-
        withSessionFanInServiceHooks
          serviceHooks
          graph
          defaultSessionFanInServiceOptions
          $ \service ->
              MIDIS.withSessionMIDIListenerHooks
                listenerHooks
                sessionMidiSmokeProducerOptions
                initialMIDIProducerState
                (MIDIPM.portMIDIListenerSource sourceOpts source)
                (sessionFanInServiceHost service)
                $ \listener -> do
                    putStrLn "  Send note-on, note-off, and CC 7 now."
                    threadDelay (seconds * 1000000)
                    -- Let the wake-on-enqueue drain worker report a
                    -- final event that landed at the end of the
                    -- smoke window.
                    threadDelay 50000
                    listenerState <- MIDIS.readSessionMIDIListenerState listener
                    snapshot <- readSessionFanInService service
                    observed <- readIORef producerEvents
                    issues <- readIORef listenerIssues
                    drained <- readIORef drainedItems
                    pure (observed, issues, drained, listenerState, snapshot)

      case result of
        Left issue ->
          dieAfterFlush $
            "Session fan-in service setup failed: " <> show issue
        Right (observed, issues, drained, listenerState, snapshot) -> do
          putStrLn ""
          putStrLn $
            "  observed_events=" <> show observed
            <> " listener_issues=" <> show issues
            <> " drained_items=" <> show drained
          putStrLn $
            "  active_midi_notes="
            <> show (M.size (mpsActiveNotes listenerState))
            <> " queue_depth=" <> show (sfisQueueDepth snapshot)
          when (observed == 0) $
            dieAfterFlush
              "No supported MIDI note/CC events observed during smoke window."
          when (drained == 0) $
            dieAfterFlush
              "No session commands drained during smoke window."
          putStrLn "Session MIDI smoke complete."

resolveSmokeMIDIDevice :: Maybe Int -> IO SmokeMIDIDevice
resolveSmokeMIDIDevice (Just devId) =
  pure SmokeMIDIDevice
    { smdDeviceId = devId
    , smdLabel    = show devId <> " (explicit)"
    }
resolveSmokeMIDIDevice Nothing = do
  result <- midiDeviceList
  case result of
    Left err ->
      die $
        err <> ". Use --midi-list and --midi-device N to select a real input."
    Right devices ->
      case find ((> 0) . midiDeviceInputs) devices of
        Nothing ->
          die $
            "No input-capable MIDI device reported by Q / PortMIDI. "
            <> "Use --midi-list to inspect the device table."
        Just dev ->
          pure SmokeMIDIDevice
            { smdDeviceId = midiDeviceId dev
            , smdLabel =
                "auto id=" <> show (midiDeviceId dev)
                <> " name=\"" <> midiDeviceName dev <> "\""
            }

sessionMidiSmokeGraph :: SynthGraph
sessionMidiSmokeGraph = runSynth $ do
  osc    <- tagged "carrier"  (sinOsc 220.0 0.0)
  envSig <- tagged "envelope" (env 0.0 0.005 0.1 0.5 0.1)
  shaped <- gain osc envSig
  vel    <- tagged "velocity" (gain shaped 0.0)
  level  <- tagged "level"    (gain vel 0.3)
  out 0 level

sessionMidiSmokeProducerOptions :: MIDIProducerOptions
sessionMidiSmokeProducerOptions =
  defaultMIDIProducerOptions
    { mpoProducerName =
        pack "session-midi-smoke"
    , mpoTemplateName =
        TemplateName "voice"
    , mpoFrequencyControl =
        Just (ControlTag (MigrationKey "carrier") 0)
    , mpoGateControl =
        Just (ControlTag (MigrationKey "envelope") 0)
    , mpoVelocityControl =
        Just (ControlTag (MigrationKey "velocity") 0)
    , mpoCCMappings =
        M.singleton 7 MIDIControlMapping
          { mcmTarget = ControlTag (MigrationKey "level") 0
          , mcmMin    = 0.0
          , mcmMax    = 1.0
          }
    }

summarizeProducerResult :: MIDIProducerEnqueueResult -> String
summarizeProducerResult result = case result of
  MIDIProducerRejected issue _ ->
    "rejected " <> show issue
  MIDIProducerEnqueueAttempted batch enqueues ->
    "commands=" <> show (length (mpcbCommands batch))
    <> " enqueues=" <> show (map sfierResult enqueues)

dieAfterFlush :: String -> IO a
dieAfterFlush msg =
  hFlush stdout >> die msg
