{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : MetaSonic.App.SessionMidiArbitrationSmoke
-- Description : Scripted smoke runner for MIDI session arbitration.
--
-- This is a non-device manual probe for the explicit session-layer MIDI
-- arbitration path:
--
-- @
-- scripted MIDIListenerSource -> Session.MIDIListener -> Session.MIDIProducer -> FanInService
-- @
--
-- It deliberately does not open PortMIDI devices, bind a network socket,
-- or start realtime audio. The event script (note-on, CC, all-notes-off
-- fence) is fully in-process and the assertions exit non-zero on any
-- counter mismatch.

module MetaSonic.App.SessionMidiArbitrationSmoke
  ( runSessionMidiArbitrationSmoke
  ) where

import           Control.Concurrent              (threadDelay)
import           Control.Concurrent.MVar         (MVar, newEmptyMVar, putMVar,
                                                  takeMVar)
import           Control.Monad                   (unless, when)
import           Data.IORef                      (modifyIORef', newIORef,
                                                  readIORef, writeIORef)
import qualified Data.Map.Strict                 as M
import           Data.Text                       (pack)
import           Data.Word                       (Word8)
import           System.Exit                     (die)
import           System.IO                       (hFlush, hPutStrLn, stderr,
                                                  stdout)
import           System.Timeout                  (timeout)

import           MetaSonic.Bridge.Source         (MigrationKey (..),
                                                  SynthGraph, gain, lpf, out,
                                                  runSynth, sinOsc, tagged)
import           MetaSonic.Bridge.Templates      (compileTemplateGraph)
import           MetaSonic.Pattern               (ControlTag (..),
                                                  TemplateName (..))
import           MetaSonic.Session.Arbitration   (ArbitrationPolicy (..),
                                                  ControlArbitrationTarget (..),
                                                  claimControlTarget,
                                                  emptyTargetClaimTable)
import           MetaSonic.Session.ArbitrationGateway
                                                 (defaultSessionArbitrationGatewayOptions,
                                                  sagoInitialPolicy)
import           MetaSonic.Session.FanIn         (sfidrDrain,
                                                  sfidrQueueDepth,
                                                  sfisQueueDepth)
import           MetaSonic.Session.FanInService  (SessionFanInServiceHooks (..),
                                                  SessionFanInServiceIssue (..),
                                                  defaultSessionFanInServiceHooks,
                                                  defaultSessionFanInServiceOptions,
                                                  readSessionFanInService,
                                                  sfsoArbitrationGatewayOptions,
                                                  withSessionFanInServiceHooks)
import qualified MetaSonic.Session.MIDIListener  as MIDIS
import           MetaSonic.Session.MIDIProducer  (MIDIChannelFilter (..),
                                                  MIDIControlMapping (..),
                                                  MIDIProducerArbitratedEnqueueResult (..),
                                                  MIDIProducerCommandBatch (..),
                                                  MIDIProducerEvent (..),
                                                  MIDIProducerOptions (..),
                                                  defaultMIDIProducerOptions,
                                                  initialMIDIProducerState,
                                                  midiVoiceKey)
import           MetaSonic.Session.Queue         (ProducerId (..),
                                                  ProducerKind (..),
                                                  sdrItems, sdrStopped)


-- | Run a scripted, non-device smoke over the arbitrated MIDI listener
-- stack. The script is note-on, CC, all-notes-off; the CC target is
-- pre-claimed by 'ProducerPattern' so the fence-triggered flush is
-- denied by policy. Exits non-zero on any assertion mismatch.
runSessionMidiArbitrationSmoke :: IO ()
runSessionMidiArbitrationSmoke = do
  graph <- case compileTemplateGraph [(templateNameStr, sessionMidiSmokeGraph)] of
    Right tg -> pure tg
    Left err -> die $ "Session MIDI arbitration smoke graph failed: " <> err

  let vkey       = midiVoiceKey midiChannel midiNote
      controlTag = ControlTag (MigrationKey "lpf") 0
      target     = ControlArbitrationTarget vkey controlTag
      claimant   =
        ProducerId ProducerPattern (pack "session-midi-smoke-claim")
      serviceOpts = defaultSessionFanInServiceOptions
        { sfsoArbitrationGatewayOptions =
            Just defaultSessionArbitrationGatewayOptions
              { sagoInitialPolicy =
                  TargetClaim
                    (claimControlTarget target claimant emptyTargetClaimTable)
              }
        }
      midiOpts = defaultMIDIProducerOptions
        { mpoProducerName  = pack "session-midi-smoke"
        , mpoTemplateName  = TemplateName templateNameStr
        , mpoCCMappings    =
            M.singleton ccController MIDIControlMapping
              { mcmTarget = controlTag
              , mcmMin    = 0.0
              , mcmMax    = 1.0
              }
        , mpoChannelFilter = MIDIChannelOmni
        }
      listenerOpts =
        MIDIS.defaultSessionMIDIListenerOptions
          { MIDIS.smloTimedControlFlushUsec = Nothing
          }

  putStrLn "Session MIDI arbitration smoke."
  putStrLn ""
  putStrLn "  path: scripted source -> Session.MIDIListener -> FanInService"
  putStrLn "  graph: tagged lpf voice template"
  putStrLn $
    "  policy: TargetClaim " <> show target <> " claimed by "
    <> show claimant
  putStrLn $
    "  script: note-on(ch=" <> show midiChannel
    <> ",note=" <> show midiNote
    <> "), CC(cc=" <> show ccController <> ",val=127), all-notes-off"
  putStrLn ""
  hFlush stdout

  events           <- newEmptyMVar
  producerResults  <- newEmptyMVar
  producerEvents   <- newIORef (0 :: Int)
  listenerIssues   <- newIORef (0 :: Int)
  listenerArbitration <- newIORef (0 :: Int)
  fenceDrops       <- newIORef (0 :: Int)
  serviceIssues    <- newIORef (0 :: Int)
  serviceArbitration <- newIORef (0 :: Int)
  drainedItems     <- newIORef (0 :: Int)
  -- The bracket teardown performs an EOF flush of pending controls.
  -- For this smoke the pending CC is still policy-denied at that
  -- point, so without silencing the teardown would fire a second
  -- pair of rejections after the body has already snapshotted
  -- counters, making the transcript disagree with the printed
  -- summary.
  silenced         <- newIORef False
  let ifLive io = do
        quiet <- readIORef silenced
        unless quiet io

  let source = MIDIS.MIDIListenerSource (takeMVar events)
      serviceHooks =
        defaultSessionFanInServiceHooks
          { sfshOnDrain = \drained -> ifLive $ do
              let n = length (sdrItems (sfidrDrain drained))
              modifyIORef' drainedItems (+ n)
              when (n > 0) $
                putStrLn $
                  "  drain: items=" <> show n
                  <> " queue_depth=" <> show (sfidrQueueDepth drained)
                  <> " stopped=" <> show (sdrStopped (sfidrDrain drained))
          , sfshOnIssue = \issue -> ifLive $ case issue of
              SfsiiArbitrationRejected arbIssue -> do
                modifyIORef' serviceArbitration (+ 1)
                hPutStrLn stderr $
                  "  service arbitration rejected: " <> show arbIssue
              other -> do
                modifyIORef' serviceIssues (+ 1)
                hPutStrLn stderr ("  service issue: " <> show other)
          }
      listenerHooks =
        MIDIS.defaultSessionMIDIArbitratedListenerHooks
          { MIDIS.smlahOnProducerResult = \result -> ifLive $ do
              modifyIORef' producerEvents (+ 1)
              putStrLn ("  producer: " <> summarizeProducerResult result)
              putMVar producerResults result
          , MIDIS.smlahOnIssue = \issue -> ifLive $ case issue of
              MIDIS.SmliArbitrationRejected arbIssue -> do
                modifyIORef' listenerArbitration (+ 1)
                hPutStrLn stderr $
                  "  listener arbitration rejected: " <> show arbIssue
              MIDIS.SmliFenceDroppedForFlushFailure event n -> do
                modifyIORef' fenceDrops (+ 1)
                hPutStrLn stderr $
                  "  listener fence dropped: event=" <> show event
                  <> " rejected_flush_count=" <> show n
              other -> do
                modifyIORef' listenerIssues (+ 1)
                hPutStrLn stderr ("  listener issue: " <> show other)
          }

  result <-
    withSessionFanInServiceHooks serviceHooks graph serviceOpts $ \service ->
      MIDIS.withArbitratedSessionMIDIListenerHooksAndOptions
        listenerHooks
        listenerOpts
        midiOpts
        initialMIDIProducerState
        source
        service
        $ \listener -> do
            scriptedEvent events producerResults
              (MIDIProducerNoteOn midiChannel midiNote 100)
            scriptedEvent events producerResults
              (MIDIProducerControlChange midiChannel ccController 127)
            scriptedEvent events producerResults
              (MIDIProducerAllNotesOff Nothing)
            -- Issue hooks for the fence event fire after the producer
            -- result returns; let them settle before reading counters.
            waitForIssuesToSettle
            stats     <- MIDIS.readSessionMIDIListenerCoalescingStats listener
            snapshot  <- readSessionFanInService service
            observed  <- readIORef producerEvents
            lIssues   <- readIORef listenerIssues
            lArb      <- readIORef listenerArbitration
            fDrops    <- readIORef fenceDrops
            sIssues   <- readIORef serviceIssues
            sArb      <- readIORef serviceArbitration
            drained   <- readIORef drainedItems
            writeIORef silenced True
            pure ( observed, lIssues, lArb, fDrops
                 , sIssues, sArb, drained, stats, snapshot
                 )

  case result of
    Left issue ->
      dieAfterFlush $
        "Session fan-in service setup failed: " <> show issue
    Right ( observed, lIssues, lArb, fDrops
          , sIssues, sArb, drained, stats, snapshot
          ) -> do
      putStrLn ""
      putStrLn $
        "  observed_events=" <> show observed
        <> " listener_issues=" <> show lIssues
        <> " listener_arbitration_rejections=" <> show lArb
        <> " listener_fence_drops=" <> show fDrops
        <> " service_issues=" <> show sIssues
        <> " service_arbitration_rejections=" <> show sArb
        <> " drained_items=" <> show drained
      putStrLn $
        "  pending_count=" <> show (MIDIS.smlcsPendingCount stats)
        <> " barrier_flush_count=" <> show (MIDIS.smlcsBarrierFlushCount stats)
        <> " flushed_count=" <> show (MIDIS.smlcsFlushedCount stats)
      putStrLn $
        "  queue_depth=" <> show (sfisQueueDepth snapshot)
      putStrLn $
        "  arbitration_counter_match=" <> show (lArb == sArb)

      assertEq "observed_events"                  observed 3
      assertEq "listener_arbitration_rejections"  lArb     1
      assertEq "service_arbitration_rejections"   sArb     1
      assertEq "listener_fence_drops"             fDrops   1
      assertEq "pending_count" (MIDIS.smlcsPendingCount stats) 1
      assertEq "listener_issues_other_than_known" lIssues  0
      assertEq "service_issues_other_than_known"  sIssues  0
      putStrLn "Session MIDI arbitration smoke complete."

scriptedEvent
  :: MVar (Maybe MIDIProducerEvent)
  -> MVar MIDIProducerArbitratedEnqueueResult
  -> MIDIProducerEvent
  -> IO ()
scriptedEvent events producerResults event = do
  putMVar events (Just event)
  mResult <- timeout 2000000 (takeMVar producerResults)
  case mResult of
    Just _ ->
      pure ()
    Nothing ->
      dieAfterFlush $
        "Timed out waiting for producer result after " <> show event

-- | The arbitrated listener fires 'leoOnProducerResult' before
-- 'leoOnIssue' inside the worker thread, so by the time 'scriptedEvent'
-- returns the issue hooks for that event may still be in flight on the
-- worker. A small grace window lets them complete before counters are
-- read.
waitForIssuesToSettle :: IO ()
waitForIssuesToSettle = threadDelay 50000

sessionMidiSmokeGraph :: SynthGraph
sessionMidiSmokeGraph = runSynth $ do
  osc  <- sinOsc 220.0 0.0
  filt <- tagged "lpf" (lpf osc 800.0 0.8)
  amp  <- gain filt 0.25
  out 0 amp

templateNameStr :: String
templateNameStr = "voice"

midiChannel :: Word8
midiChannel = 0

midiNote :: Word8
midiNote = 60

ccController :: Word8
ccController = 7

summarizeProducerResult :: MIDIProducerArbitratedEnqueueResult -> String
summarizeProducerResult = \case
  MIDIProducerArbitratedRejected issue _ ->
    "decode_rejected " <> show issue
  MIDIProducerArbitratedEnqueueAttempted batch outcomes ->
    "enqueue_attempted commands=" <> show (mpcbCommands batch)
    <> " outcomes=" <> show outcomes

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq label actual expected =
  when (actual /= expected) $
    dieAfterFlush $
      "Smoke assertion failed: " <> label
      <> " expected " <> show expected
      <> ", got " <> show actual

dieAfterFlush :: String -> IO ()
dieAfterFlush msg = do
  hFlush stdout
  hFlush stderr
  die msg
