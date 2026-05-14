{-# LANGUAGE LambdaCase #-}

-- | Session MIDI producer, decoded listener, and PortMIDI source tests.
module MetaSonic.Spec.SessionMIDI where

import qualified Data.Map.Strict           as M
import qualified Data.Set                  as S
import qualified Data.Text                 as T
import           Control.Concurrent        (MVar, newEmptyMVar, putMVar,
                                            takeMVar, threadDelay)
import           Control.Monad             (forM, forM_)
import           Data.IORef                (newIORef, readIORef, writeIORef)
import           Data.Maybe                (mapMaybe)
import           Data.Word                 (Word16, Word8)
import           System.Timeout            (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source   (MigrationKey(..))
import           MetaSonic.Pattern
import           MetaSonic.Pattern.Corpus
import           MetaSonic.Session.Command
import           MetaSonic.Session.FanIn
import           MetaSonic.Session.FanInService
import           MetaSonic.Session.MIDIProducer
import qualified MetaSonic.Session.MIDIListener as MIDIS
import qualified MetaSonic.Session.MIDIPortMIDI as MIDIPM
import           MetaSonic.Session.Owner
import           MetaSonic.Session.Queue
import           MetaSonic.Session.State
import           MetaSonic.Session.Step
import           MetaSonic.Spec.SessionShared

fanInQueuedOrFail
  :: SessionFanInEnqueueResult
  -> IO QueuedSessionCommand
fanInQueuedOrFail result =
  case sfierResult result of
    SessionEnqueued queued ->
      pure queued
    other ->
      assertFailure ("expected fan-in enqueue success, got: " <> show other)

------------------------------------------------------------
-- Session MIDI producer adapter
--
-- This adapter is Haskell-only and consumes already-decoded MIDI
-- events. Live PortMIDI device ownership remains in the existing
-- Bridge.MidiDemo path.
------------------------------------------------------------

sessionMIDIProducerTests :: TestTree
sessionMIDIProducerTests =
  testGroup "Session MIDI producer adapter"
  [ testCase "note-on translates to voice start with configured controls" $ do
      let opts = testMIDIProducerOptions
          event = MIDIProducerNoteOn 0 69 64
      case decodeMIDISessionCommands opts initialMIDIProducerState event of
        Left issue ->
          assertFailure ("expected MIDI note-on translation, got: "
                         <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdVoiceOn
                (TemplateName "drone")
                (VoiceKey "m0-69")
                [ (midiFreqTag, 440.0)
                , (midiGateTag, 1.0)
                , (midiVelocityTag, 64.0 / 127.0)
                ]
            ]
          mpsActiveNotes (mpcbState batch)
            @?= M.singleton (0, 69) (VoiceKey "m0-69")

  , testCase "note-on velocity zero is treated as note-off" $ do
      let active =
            testMIDIProducerState $
              M.singleton (2, 60) (VoiceKey "m2-60")
          event = MIDIProducerNoteOn 2 60 0
      decodeMIDISessionCommands testMIDIProducerOptions active event
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = [CmdVoiceOff (VoiceKey "m2-60")]
              , mpcbState = initialMIDIProducerState
              }

  , testCase "duplicate and stale notes are rejected before enqueue" $ do
      let opts = testMIDIProducerOptions
          active =
            testMIDIProducerState $
              M.singleton (0, 69) (VoiceKey "m0-69")
      decodeMIDISessionCommands opts active (MIDIProducerNoteOn 0 69 127)
        @?= Left (MpiNoteAlreadyActive 0 69)
      decodeMIDISessionCommands opts initialMIDIProducerState
                                  (MIDIProducerNoteOff 0 69 0)
        @?= Left (MpiNoteNotActive 0 69)

  , testCase "CC maps to deterministic control writes for active notes" $ do
      let active =
            testMIDIProducerState $
              M.fromList
                [ ((0, 72), VoiceKey "m0-72")
                , ((0, 60), VoiceKey "m0-60")
                ]
          event = MIDIProducerControlChange 0 7 64
          expectedValue = 64.0 / 127.0
      case decodeMIDISessionCommands testMIDIProducerOptions active event of
        Left issue ->
          assertFailure ("expected MIDI CC translation, got: " <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdControlWrite (VoiceKey "m0-60") midiLevelTag expectedValue
            , CmdControlWrite (VoiceKey "m0-72") midiLevelTag expectedValue
            ]
          mpcbState batch @?= active

  , testCase "pitch-bend maps to channel-active frequency writes" $ do
      let active =
            testMIDIProducerState $
              M.fromList
                [ ((0, 72), VoiceKey "m0-72")
                , ((1, 67), VoiceKey "m1-67")
                , ((0, 60), VoiceKey "m0-60")
                ]
          value = 16383
          bentState = active { mpsPitchBends = M.singleton 0 value }
          expected note =
            midiNoteFrequency note
              * (2.0 ** ((((fromIntegral value - 8192.0) / 8192.0) * 2.0)
                          / 12.0))
      case decodeMIDISessionCommands
             testMIDIProducerOptions
             active
             (MIDIProducerPitchBend 0 value) of
        Left issue ->
          assertFailure ("expected MIDI pitch-bend translation, got: "
                         <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdControlWrite (VoiceKey "m0-60") midiFreqTag (expected 60)
            , CmdControlWrite (VoiceKey "m0-72") midiFreqTag (expected 72)
            ]
          mpcbState batch @?= bentState
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerPitchBend 0 8192)
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = []
              , mpcbState = initialMIDIProducerState
              }

  , testCase "pitch-bend state applies to later note-on" $ do
      let value = 16383
          bentState =
            initialMIDIProducerState
              { mpsPitchBends = M.singleton 0 value
              }
          expectedFreq note =
            midiNoteFrequency note
              * (2.0 ** ((((fromIntegral value - 8192.0) / 8192.0) * 2.0)
                          / 12.0))
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerPitchBend 0 value)
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = []
              , mpcbState = bentState
              }
      case decodeMIDISessionCommands
             testMIDIProducerOptions
             bentState
             (MIDIProducerNoteOn 0 60 64) of
        Left issue ->
          assertFailure ("expected bent MIDI note-on, got: " <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdVoiceOn
                (TemplateName "drone")
                (VoiceKey "m0-60")
                [ (midiFreqTag, expectedFreq 60)
                , (midiGateTag, 1.0)
                , (midiVelocityTag, 64.0 / 127.0)
                ]
            ]
          mpcbState batch @?=
            bentState
              { mpsActiveNotes = M.singleton (0, 60) (VoiceKey "m0-60")
              }
      decodeMIDISessionCommands
        testMIDIProducerOptions
        bentState
        (MIDIProducerPitchBend 0 8192)
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = []
              , mpcbState = initialMIDIProducerState
              }

  , testCase "sustain pedal defers note-off until pedal release" $ do
      let active =
            testMIDIProducerState $
              M.fromList
                [ ((0, 60), VoiceKey "m0-60")
                , ((1, 65), VoiceKey "m1-65")
                ]
          downState =
            active { mpsSustainedChannels = S.singleton 0 }
          deferredState =
            downState
              { mpsDeferredNoteOffs =
                  M.singleton (0, 60) (VoiceKey "m0-60")
              }
          releasedState =
            testMIDIProducerState $
              M.singleton (1, 65) (VoiceKey "m1-65")
      decodeMIDISessionCommands
        testMIDIProducerOptions
        active
        (MIDIProducerControlChange 0 64 127)
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = []
              , mpcbState = downState
              }
      decodeMIDISessionCommands
        testMIDIProducerOptions
        downState
        (MIDIProducerNoteOff 0 60 64)
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = []
              , mpcbState = deferredState
              }
      decodeMIDISessionCommands
        testMIDIProducerOptions
        deferredState
        (MIDIProducerControlChange 0 64 0)
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = [CmdVoiceOff (VoiceKey "m0-60")]
              , mpcbState = releasedState
              }

  , testCase "sustained note can be retriggered after deferred note-off" $ do
      let deferredState =
            (testMIDIProducerState $
               M.singleton (0, 60) (VoiceKey "m0-60"))
              { mpsSustainedChannels = S.singleton 0
              , mpsDeferredNoteOffs =
                  M.singleton (0, 60) (VoiceKey "m0-60")
              }
          retriggeredState =
            (testMIDIProducerState $
               M.singleton (0, 60) (VoiceKey "m0-60"))
              { mpsSustainedChannels = S.singleton 0
              }
      case decodeMIDISessionCommands
             testMIDIProducerOptions
             deferredState
             (MIDIProducerNoteOn 0 60 64) of
        Left issue ->
          assertFailure ("expected sustained retrigger, got: " <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdVoiceOff (VoiceKey "m0-60")
            , CmdVoiceOn
                (TemplateName "drone")
                (VoiceKey "m0-60")
                [ (midiFreqTag, midiNoteFrequency 60)
                , (midiGateTag, 1.0)
                , (midiVelocityTag, 64.0 / 127.0)
                ]
            ]
          mpcbState batch @?= retriggeredState

  , testCase "channel filter admits allow-listed channels" $ do
      let opts = testMIDIProducerOptions
            { mpoChannelFilter = MIDIChannelAllowList (S.singleton 2)
            }
          emptyOpts = testMIDIProducerOptions
            { mpoChannelFilter = MIDIChannelAllowList S.empty
            }
          active =
            testMIDIProducerState $
              M.singleton (0, 69) (VoiceKey "m0-69")
      decodeMIDISessionCommands
        emptyOpts
        initialMIDIProducerState
        (MIDIProducerNoteOn 0 69 64)
        @?= Left (MpiChannelFiltered 0)
      decodeMIDISessionCommands
        opts
        initialMIDIProducerState
        (MIDIProducerNoteOn 0 69 64)
        @?= Left (MpiChannelFiltered 0)
      decodeMIDISessionCommands
        opts
        initialMIDIProducerState
        (MIDIProducerControlChange 0 7 64)
        @?= Left (MpiChannelFiltered 0)
      decodeMIDISessionCommands
        opts
        initialMIDIProducerState
        (MIDIProducerControlChange 0 64 127)
        @?= Left (MpiChannelFiltered 0)
      decodeMIDISessionCommands
        opts
        initialMIDIProducerState
        (MIDIProducerPitchBend 0 8192)
        @?= Left (MpiChannelFiltered 0)
      decodeMIDISessionCommands
        opts
        active
        (MIDIProducerAllNotesOff (Just 0))
        @?= Left (MpiChannelFiltered 0)
      case decodeMIDISessionCommands
             opts
             initialMIDIProducerState
             (MIDIProducerNoteOn 2 60 64) of
        Left issue ->
          assertFailure ("expected allow-listed MIDI note, got: "
                         <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdVoiceOn
                (TemplateName "drone")
                (VoiceKey "m2-60")
                [ (midiFreqTag, midiNoteFrequency 60)
                , (midiGateTag, 1.0)
                , (midiVelocityTag, 64.0 / 127.0)
                ]
            ]
          mpsActiveNotes (mpcbState batch)
            @?= M.singleton (2, 60) (VoiceKey "m2-60")
      decodeMIDISessionCommands opts active (MIDIProducerAllNotesOff Nothing)
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = [CmdVoiceOff (VoiceKey "m0-69")]
              , mpcbState = initialMIDIProducerState
              }

  , testCase "all-notes-off emits deterministic voice stops and clears state" $ do
      let active =
            (testMIDIProducerState $
               M.fromList
                 [ ((1, 65), VoiceKey "m1-65")
                 , ((0, 72), VoiceKey "m0-72")
                 , ((0, 60), VoiceKey "m0-60")
                 ])
              { mpsSustainedChannels = S.fromList [0, 1]
              , mpsDeferredNoteOffs = M.fromList
                  [ ((1, 65), VoiceKey "m1-65")
                  , ((0, 60), VoiceKey "m0-60")
                  ]
              }
      case decodeMIDISessionCommands
             testMIDIProducerOptions
             active
             (MIDIProducerAllNotesOff Nothing) of
        Left issue ->
          assertFailure ("expected all-notes-off translation, got: "
                         <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdVoiceOff (VoiceKey "m0-60")
            , CmdVoiceOff (VoiceKey "m0-72")
            , CmdVoiceOff (VoiceKey "m1-65")
            ]
          mpcbState batch @?= initialMIDIProducerState

  , testCase "channel all-notes-off keeps other active and sustained channels" $ do
      let active =
            (testMIDIProducerState $
               M.fromList
                 [ ((1, 65), VoiceKey "m1-65")
                 , ((0, 72), VoiceKey "m0-72")
                 , ((0, 60), VoiceKey "m0-60")
                 ])
              { mpsSustainedChannels = S.fromList [0, 1]
              , mpsDeferredNoteOffs = M.fromList
                  [ ((1, 65), VoiceKey "m1-65")
                  , ((0, 60), VoiceKey "m0-60")
                  ]
              }
          expectedState =
            (testMIDIProducerState $
               M.singleton (1, 65) (VoiceKey "m1-65"))
              { mpsSustainedChannels = S.singleton 1
              , mpsDeferredNoteOffs =
                  M.singleton (1, 65) (VoiceKey "m1-65")
              }
      case decodeMIDISessionCommands
             testMIDIProducerOptions
             active
             (MIDIProducerAllNotesOff (Just 0)) of
        Left issue ->
          assertFailure ("expected channel all-notes-off translation, got: "
                         <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdVoiceOff (VoiceKey "m0-60")
            , CmdVoiceOff (VoiceKey "m0-72")
            ]
          mpcbState batch @?= expectedState

  , testCase "invalid data bytes and unmapped controls reject explicitly" $ do
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerNoteOn 16 60 1)
        @?= Left (MpiInvalidChannel 16)
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerNoteOn 0 128 1)
        @?= Left (MpiInvalidDataByte (T.pack "note") 128)
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerControlChange 0 74 64)
        @?= Left (MpiUnmappedControl 74)
      decodeMIDISessionCommands
        defaultMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerPitchBend 0 8192)
        @?= Left MpiUnmappedPitchBend
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerPitchBend 16 8192)
        @?= Left (MpiInvalidChannel 16)
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerPitchBend 0 16384)
        @?= Left (MpiInvalidPitchBendValue 16384)
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerAllNotesOff (Just 16))
        @?= Left (MpiInvalidChannel 16)

  , testCase "successful enqueue advances MIDI state under ProducerMIDI" $ do
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  defaultSessionFanInOptions
                  $ \host -> do
                    enq <- enqueueMIDIProducerEvent
                             testMIDIProducerOptions
                             initialMIDIProducerState
                             (MIDIProducerNoteOn 0 69 127)
                             host
                    snapshot <- readSessionFanInHost host
                    pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (MIDIProducerEnqueueAttempted batch [enq], snapshot) -> do
          mpsActiveNotes (mpcbState batch)
            @?= M.singleton (0, 69) (VoiceKey "m0-69")
          queued <- fanInQueuedOrFail enq
          producerKind (qscProducer queued) @?= ProducerMIDI
          mpcbCommands batch @?= [qscCommand queued]
          sfierQueueDepth enq @?= 1
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected MIDI enqueue attempt, got: "
                         <> show other)

  , testCase "filtered channel rejects before enqueue" $ do
      let opts = testMIDIProducerOptions
            { mpoChannelFilter = MIDIChannelAllowList (S.singleton 1)
            }
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  defaultSessionFanInOptions
                  $ \host -> do
                    rejected <- enqueueMIDIProducerEvent
                                  opts
                                  initialMIDIProducerState
                                  (MIDIProducerNoteOn 0 69 127)
                                  host
                    snapshot <- readSessionFanInHost host
                    pure (rejected, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (MIDIProducerRejected issue st, snapshot) -> do
          issue @?= MpiChannelFiltered 0
          st @?= initialMIDIProducerState
          sfisQueueDepth snapshot @?= 0
        Right other ->
          assertFailure ("expected filtered MIDI rejection, got: "
                         <> show other)

  , testCase "queue-full does not advance note state" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  opts
                  $ \host -> do
                    _prefill <-
                      enqueueSessionFanInCommand
                        (testProducer ProducerTest "prefill")
                        prefill
                        host
                    enqueueMIDIProducerEvent
                      testMIDIProducerOptions
                      initialMIDIProducerState
                      (MIDIProducerNoteOn 0 69 127)
                      host
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (MIDIProducerEnqueueAttempted batch [enq]) -> do
          mpcbState batch @?= initialMIDIProducerState
          case mpcbCommands batch of
            [command] ->
              sfierResult enq
                @?= SessionEnqueueRejected
                      (midiProducerId testMIDIProducerOptions)
                      command
                      (SeiQueueFull 1)
            other ->
              assertFailure ("expected one MIDI command, got: " <> show other)
        Right other ->
          assertFailure ("expected queue-full MIDI enqueue, got: "
                         <> show other)

  , testCase "queue-full does not advance all-notes-off state" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          active =
            testMIDIProducerState $
              M.singleton (0, 69) (VoiceKey "m0-69")
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  opts
                  $ \host -> do
                    _prefill <-
                      enqueueSessionFanInCommand
                        (testProducer ProducerTest "prefill")
                        prefill
                        host
                    enqueueMIDIProducerEvent
                      testMIDIProducerOptions
                      active
                      (MIDIProducerAllNotesOff Nothing)
                      host
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (MIDIProducerEnqueueAttempted batch [enq]) -> do
          mpcbState batch @?= active
          mpcbCommands batch @?= [CmdVoiceOff (VoiceKey "m0-69")]
          sfierResult enq
            @?= SessionEnqueueRejected
                  (midiProducerId testMIDIProducerOptions)
                  (CmdVoiceOff (VoiceKey "m0-69"))
                  (SeiQueueFull 1)
        Right other ->
          assertFailure ("expected queue-full all-notes-off enqueue, got: "
                         <> show other)

  , testCase "queue-full does not advance sustain release state" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          active =
            (testMIDIProducerState $
               M.singleton (0, 69) (VoiceKey "m0-69"))
              { mpsSustainedChannels = S.singleton 0
              , mpsDeferredNoteOffs =
                  M.singleton (0, 69) (VoiceKey "m0-69")
              }
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  opts
                  $ \host -> do
                    _prefill <-
                      enqueueSessionFanInCommand
                        (testProducer ProducerTest "prefill")
                        prefill
                        host
                    enqueueMIDIProducerEvent
                      testMIDIProducerOptions
                      active
                      (MIDIProducerControlChange 0 64 0)
                      host
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (MIDIProducerEnqueueAttempted batch [enq]) -> do
          mpcbState batch @?= active
          mpcbCommands batch @?= [CmdVoiceOff (VoiceKey "m0-69")]
          sfierResult enq
            @?= SessionEnqueueRejected
                  (midiProducerId testMIDIProducerOptions)
                  (CmdVoiceOff (VoiceKey "m0-69"))
                  (SeiQueueFull 1)
        Right other ->
          assertFailure ("expected queue-full sustain release, got: "
                         <> show other)

  , testCase "partial all-notes-off enqueue failure keeps producer state" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 3
            }
          active =
            testMIDIProducerState $
              M.fromList
                [ ((1, 65), VoiceKey "m1-65")
                , ((0, 72), VoiceKey "m0-72")
                , ((0, 60), VoiceKey "m0-60")
                ]
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  opts
                  $ \host -> do
                    _prefill <-
                      enqueueSessionFanInCommand
                        (testProducer ProducerTest "prefill")
                        prefill
                        host
                    enq <- enqueueMIDIProducerEvent
                             testMIDIProducerOptions
                             active
                             (MIDIProducerAllNotesOff Nothing)
                             host
                    snapshot <- readSessionFanInHost host
                    pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (MIDIProducerEnqueueAttempted batch [enq0, enq1, enq2],
               snapshot) -> do
          mpcbState batch @?= active
          mpcbCommands batch @?=
            [ CmdVoiceOff (VoiceKey "m0-60")
            , CmdVoiceOff (VoiceKey "m0-72")
            , CmdVoiceOff (VoiceKey "m1-65")
            ]
          q0 <- fanInQueuedOrFail enq0
          q1 <- fanInQueuedOrFail enq1
          qscCommand q0 @?= CmdVoiceOff (VoiceKey "m0-60")
          qscCommand q1 @?= CmdVoiceOff (VoiceKey "m0-72")
          sfierResult enq2
            @?= SessionEnqueueRejected
                  (midiProducerId testMIDIProducerOptions)
                  (CmdVoiceOff (VoiceKey "m1-65"))
                  (SeiQueueFull 3)
          sfisQueueDepth snapshot @?= 3
        Right other ->
          assertFailure
            ("expected partial all-notes-off enqueue failure, got: "
             <> show other)

  , testCase "pressure probe: high-rate pitch-bend fills strict FIFO queue" $ do
      let queueCapacity = 128
          activeNotes =
            M.fromList
              [ ((0, note), midiVoiceKey 0 note)
              | note <- [48..63]
              ]
          initialState =
            testMIDIProducerState activeNotes
          -- Keep every value non-center so mpsPitchBends stays populated.
          pitchValues =
            [9000..9008]
          -- The final 9008 event rolls back when all of its writes reject.
          acceptedState =
            initialState { mpsPitchBends = M.singleton 0 9007 }
          opts =
            defaultSessionFanInOptions
              { sfioQueueOptions = SessionQueueOptions queueCapacity
              }
          resultState = \case
            MIDIProducerRejected _ st ->
              st
            MIDIProducerEnqueueAttempted batch _ ->
              mpcbState batch
          resultEnqueues = \case
            MIDIProducerRejected {} ->
              []
            MIDIProducerEnqueueAttempted _ enqueues ->
              enqueues
          resultBatch = \case
            MIDIProducerRejected {} ->
              Nothing
            MIDIProducerEnqueueAttempted batch _ ->
              Just batch
          isControlWrite cmd = case cmd of
            CmdControlWrite _ _ _ ->
              True
            _ ->
              False
          enqueuePressure st [] _host =
            pure (st, [])
          enqueuePressure st (value : values) host = do
            enq <- enqueueMIDIProducerEvent
                     testMIDIProducerOptions
                     st
                     (MIDIProducerPitchBend 0 value)
                     host
            (stFinal, rest) <- enqueuePressure (resultState enq) values host
            pure (stFinal, enq : rest)
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          opts
          $ \host -> do
              -- This is a fan-in pressure probe; queue saturation happens
              -- before owner drain, so the active-note seed is producer-side.
              (finalState, pressureResults) <-
                enqueuePressure initialState pitchValues host
              snapshotBeforeDrain <- readSessionFanInHost host
              drained <- drainSessionFanInHost host
              snapshotAfterDrain <- readSessionFanInHost host
              pure
                ( finalState
                , pressureResults
                , snapshotBeforeDrain
                , drained
                , snapshotAfterDrain
                )
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right ( finalState
              , pressureResults
              , snapshotBeforeDrain
              , drained
              , snapshotAfterDrain
              ) -> do
          let batches =
                mapMaybe resultBatch pressureResults
              enqueueResults =
                concatMap resultEnqueues pressureResults
              enqueued =
                [ queued
                | SessionFanInEnqueueResult
                    { sfierResult = SessionEnqueued queued } <- enqueueResults
                ]
              rejectedIssues =
                [ issue
                | SessionFanInEnqueueResult
                    { sfierResult =
                        SessionEnqueueRejected _ _ issue
                    } <- enqueueResults
                ]
              drainedItems =
                sdrItems (sfidrDrain drained)
          length batches @?= length pitchValues
          map (length . mpcbCommands) batches
            @?= replicate (length pitchValues) 16
          length enqueueResults @?= 144
          length enqueued @?= queueCapacity
          rejectedIssues @?= replicate 16 (SeiQueueFull queueCapacity)
          map sfierQueueDepth (take queueCapacity enqueueResults)
            @?= [1..queueCapacity]
          map sfierQueueDepth (drop queueCapacity enqueueResults)
            @?= replicate 16 queueCapacity
          finalState @?= acceptedState
          sfisQueueDepth snapshotBeforeDrain @?= queueCapacity
          assertBool
            "expected only control writes to enter the pressure queue"
            (all (isControlWrite . qscCommand) enqueued)
          map sdiQueued drainedItems @?= enqueued
          length drainedItems @?= queueCapacity
          sdrRemaining (sfidrDrain drained) @?= 0
          sdrStopped (sfidrDrain drained) @?= Nothing
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshotAfterDrain @?= 0

  , testCase "service host wakes worker for MIDI note-on" $ do
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueMIDIProducerEvent
                       testMIDIPlayableOptions
                       initialMIDIProducerState
                       (MIDIProducerNoteOn 0 69 100)
                       (sessionFanInServiceHost service)
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (MIDIProducerEnqueueAttempted _ [enq], Just drained, snapshot) -> do
          queued <- fanInQueuedOrFail enq
          map sdiQueued (sdrItems (sfidrDrain drained)) @?= [queued]
          case map sdiResult (sdrItems (sfidrDrain drained)) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure
                ("expected MIDI note-on to commit through service, got: "
                 <> show other)
          sfisQueueDepth snapshot @?= 0
          assertBool
            "expected MIDI voice after service drain"
            (M.member (VoiceKey "m0-69") (ssVoices (sfisOwnerState snapshot)))
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for MIDI service drain"
        Right other ->
          assertFailure ("expected MIDI service enqueue, got: " <> show other)
  ]

testMIDIProducerState :: M.Map (Word8, Word8) VoiceKey -> MIDIProducerState
testMIDIProducerState active =
  initialMIDIProducerState { mpsActiveNotes = active }

testMIDIProducerOptions :: MIDIProducerOptions
testMIDIProducerOptions = defaultMIDIProducerOptions
  { mpoTemplateName =
      TemplateName "drone"
  , mpoFrequencyControl =
      Just midiFreqTag
  , mpoGateControl =
      Just midiGateTag
  , mpoVelocityControl =
      Just midiVelocityTag
  , mpoCCMappings =
      M.singleton 7 MIDIControlMapping
        { mcmTarget = midiLevelTag
        , mcmMin    = 0.0
        , mcmMax    = 1.0
        }
  , mpoPitchBendMapping =
      Just MIDIPitchBendMapping
        { mpbmTarget    = midiFreqTag
        , mpbmSemitones = 2.0
        }
  }

testMIDIPlayableOptions :: MIDIProducerOptions
testMIDIPlayableOptions = testMIDIProducerOptions
  -- Keep service/listener composition tests focused on voice lifecycle:
  -- droneVibrato does not expose the synthetic freq/gate/velocity tags.
  { mpoFrequencyControl = Nothing
  , mpoGateControl      = Nothing
  , mpoVelocityControl  = Nothing
  }

midiFreqTag :: ControlTag
midiFreqTag =
  ControlTag (MigrationKey "carrier") 0

midiGateTag :: ControlTag
midiGateTag =
  ControlTag (MigrationKey "envelope") 0

midiVelocityTag :: ControlTag
midiVelocityTag =
  ControlTag (MigrationKey "velocity") 0

midiLevelTag :: ControlTag
midiLevelTag =
  ControlTag (MigrationKey "lpf") 0

------------------------------------------------------------
-- Session MIDI listener adapter
--
-- This is the decoded-event worker above the MIDI producer adapter.
-- It only enqueues into SessionFanInHost; live PortMIDI device
-- ownership remains outside this module.
------------------------------------------------------------

sessionMIDIListenerTests :: TestTree
sessionMIDIListenerTests =
  testGroup "Session MIDI listener adapter"
  [ testCase "bracket cleanup: body return tears down blocked source" $ do
      entered <- newEmptyMVar
      events <- newEmptyMVar
      let source = MIDIS.MIDIListenerSource $ do
            putMVar entered ()
            takeMVar events
      result <- timeout 1000000 $
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListener
                testMIDIProducerOptions
                initialMIDIProducerState
                source
                host
                $ \_listener ->
                    timeout 1000000 (takeMVar entered)
      case result of
        Nothing ->
          assertFailure "MIDI listener teardown hung on blocked source"
        Just (Left issue) ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Just (Right (Just ())) ->
          pure ()
        Just (Right Nothing) ->
          assertFailure "timed out waiting for MIDI source read"

  , testCase "source end-of-input exits worker without changing body result" $ do
      events <- newIORef
        [ Just (MIDIProducerNoteOn 0 69 100)
        , Nothing
        ]
      eofSeen <- newEmptyMVar
      producerResult <- newEmptyMVar
      let source = MIDIS.MIDIListenerSource $ do
            remaining <- readIORef events
            case remaining of
              [] -> do
                putMVar eofSeen ()
                pure Nothing
              next : rest -> do
                writeIORef events rest
                case next of
                  Nothing ->
                    putMVar eofSeen ()
                  Just _ ->
                    pure ()
                pure next
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResult
            , MIDIS.smlhOnIssue          = \_ -> pure ()
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListenerHooks
                hooks
                testMIDIProducerOptions
                initialMIDIProducerState
                source
                host
                $ \listener -> do
                    mResult <- timeout 1000000 (takeMVar producerResult)
                    mEof <- timeout 1000000 (takeMVar eofSeen)
                    state <- MIDIS.readSessionMIDIListenerState listener
                    snapshot <- readSessionFanInHost host
                    pure (mResult, mEof, state, snapshot, 42 :: Int)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted _ [enq]), Just (),
               state, snapshot, value) -> do
          _queued <- fanInQueuedOrFail enq
          mpsActiveNotes state
            @?= M.singleton (0, 69) (VoiceKey "m0-69")
          sfisQueueDepth snapshot @?= 1
          value @?= 42
        Right other ->
          assertFailure ("expected note-on followed by source EOF, got: "
                         <> show other)

  , testCase "producer rejection reports issue and listener continues" $ do
      events <- newEmptyMVar
      issues <- newEmptyMVar
      validResult <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult =
                \case
                  result@MIDIProducerEnqueueAttempted {} ->
                    putMVar validResult result
                  MIDIProducerRejected {} ->
                    pure ()
            , MIDIS.smlhOnIssue =
                putMVar issues
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListenerHooks
                hooks
                testMIDIProducerOptions
                initialMIDIProducerState
                source
                host
                $ \listener -> do
                    putMVar events (Just (MIDIProducerNoteOn 16 60 1))
                    mIssue <- timeout 1000000 (takeMVar issues)
                    putMVar events (Just (MIDIProducerNoteOn 0 69 127))
                    mResult <- timeout 1000000 (takeMVar validResult)
                    state <- MIDIS.readSessionMIDIListenerState listener
                    snapshot <- readSessionFanInHost host
                    pure (mIssue, mResult, state, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just issue, Just (MIDIProducerEnqueueAttempted batch [enq]),
               state, snapshot) -> do
          issue @?= MIDIS.SmliProducerRejected (MpiInvalidChannel 16)
          queued <- fanInQueuedOrFail enq
          mpcbCommands batch @?= [qscCommand queued]
          mpsActiveNotes state
            @?= M.singleton (0, 69) (VoiceKey "m0-69")
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected rejection then valid MIDI enqueue, got: "
                         <> show other)

  , testCase "listener state follows note-on and note-off sequence" $ do
      events <- newEmptyMVar
      producerResults <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue          = \_ -> pure ()
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListenerHooks
                hooks
                testMIDIProducerOptions
                initialMIDIProducerState
                source
                host
                $ \listener -> do
                    putMVar events (Just (MIDIProducerNoteOn 0 69 100))
                    mOn <- timeout 1000000 (takeMVar producerResults)
                    stateAfterOn <- MIDIS.readSessionMIDIListenerState listener
                    putMVar events (Just (MIDIProducerNoteOff 0 69 0))
                    mOff <- timeout 1000000 (takeMVar producerResults)
                    stateAfterOff <- MIDIS.readSessionMIDIListenerState listener
                    snapshot <- readSessionFanInHost host
                    pure (mOn, stateAfterOn, mOff, stateAfterOff, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted _ [onEnq]),
               stateAfterOn,
               Just (MIDIProducerEnqueueAttempted _ [offEnq]),
               stateAfterOff,
               snapshot) -> do
          onQueued <- fanInQueuedOrFail onEnq
          offQueued <- fanInQueuedOrFail offEnq
          qscCommand onQueued
            @?= CmdVoiceOn
                  (TemplateName "drone")
                  (VoiceKey "m0-69")
                  [ (midiFreqTag, 440.0)
                  , (midiGateTag, 1.0)
                  , (midiVelocityTag, 100.0 / 127.0)
                  ]
          qscCommand offQueued @?= CmdVoiceOff (VoiceKey "m0-69")
          mpsActiveNotes stateAfterOn
            @?= M.singleton (0, 69) (VoiceKey "m0-69")
          mpsActiveNotes stateAfterOff @?= M.empty
          sfisQueueDepth snapshot @?= 2
        Right other ->
          assertFailure ("expected note-on/note-off listener results, got: "
                         <> show other)

  , testCase "listener state follows all-notes-off" $ do
      events <- newEmptyMVar
      producerResults <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue          = \_ -> pure ()
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListenerHooks
                hooks
                testMIDIProducerOptions
                initialMIDIProducerState
                source
                host
                $ \listener -> do
                    putMVar events (Just (MIDIProducerNoteOn 0 69 100))
                    mOn <- timeout 1000000 (takeMVar producerResults)
                    putMVar events (Just (MIDIProducerAllNotesOff Nothing))
                    mAllNotesOff <- timeout 1000000
                                      (takeMVar producerResults)
                    stateAfterAllNotesOff <-
                      MIDIS.readSessionMIDIListenerState listener
                    snapshot <- readSessionFanInHost host
                    pure (mOn, mAllNotesOff, stateAfterAllNotesOff, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted _ [onEnq]),
               Just (MIDIProducerEnqueueAttempted offBatch [offEnq]),
               stateAfterAllNotesOff,
               snapshot) -> do
          onQueued <- fanInQueuedOrFail onEnq
          offQueued <- fanInQueuedOrFail offEnq
          qscCommand onQueued
            @?= CmdVoiceOn
                  (TemplateName "drone")
                  (VoiceKey "m0-69")
                  [ (midiFreqTag, 440.0)
                  , (midiGateTag, 1.0)
                  , (midiVelocityTag, 100.0 / 127.0)
                  ]
          mpcbCommands offBatch @?= [CmdVoiceOff (VoiceKey "m0-69")]
          qscCommand offQueued @?= CmdVoiceOff (VoiceKey "m0-69")
          mpsActiveNotes stateAfterAllNotesOff @?= M.empty
          sfisQueueDepth snapshot @?= 2
        Right other ->
          assertFailure
            ("expected note-on/all-notes-off listener results, got: "
             <> show other)

  , testCase "listener coalesces pitch-bend writes until all-notes-off fence" $ do
      let activeNotes =
            M.fromList
              [ ((0, note), midiVoiceKey 0 note)
              | note <- [48..63]
              ]
          initialState =
            testMIDIProducerState activeNotes
          pitchValues =
            [9000..9008] :: [Word16]
          -- Last accepted value after the coalescing window.
          finalValue =
            9008 :: Word16
          listenerOpts =
            MIDIS.defaultSessionMIDIListenerOptions
              { MIDIS.smloTimedControlFlushUsec = Nothing
              }
          expectedFreq note =
            midiNoteFrequency note
              * (2.0 ** ((((fromIntegral finalValue - 8192.0) / 8192.0) * 2.0)
                          / 12.0))
          expectedFlush =
            [ CmdControlWrite (midiVoiceKey 0 note) midiFreqTag
                (expectedFreq note)
            | note <- [48..63]
            ]
          expectedFence =
            [ CmdVoiceOff (midiVoiceKey 0 note)
            | note <- [48..63]
            ]
      events <- newEmptyMVar
      producerResults <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue          = \_ -> pure ()
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListenerHooksAndOptions
                hooks
                listenerOpts
                testMIDIProducerOptions
                initialState
                source
                host
                $ \listener -> do
                    pitchResults <- forM pitchValues $ \value -> do
                      putMVar events (Just (MIDIProducerPitchBend 0 value))
                      timeout 1000000 (takeMVar producerResults)
                    putMVar events (Just (MIDIProducerAllNotesOff Nothing))
                    mFence <- timeout 1000000 (takeMVar producerResults)
                    stats <- MIDIS.readSessionMIDIListenerCoalescingStats
                               listener
                    state <- MIDIS.readSessionMIDIListenerState listener
                    snapshot <- readSessionFanInHost host
                    pure (pitchResults, mFence, stats, state, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (pitchResults,
               Just (MIDIProducerEnqueueAttempted fenceBatch fenceEnqueues),
               stats, state, snapshot) ->
          case sequence pitchResults of
            Nothing ->
              assertFailure "timed out waiting for coalesced pitch-bend events"
            Just results -> do
              forM_ results $ \case
                MIDIProducerEnqueueAttempted batch [] ->
                  length (mpcbCommands batch) @?= 16
                other ->
                  assertFailure
                    ("expected deferred pitch-bend result, got: "
                     <> show other)
              mpcbCommands fenceBatch @?= expectedFlush <> expectedFence
              length fenceEnqueues @?= 32
              map sfierQueueDepth fenceEnqueues @?= [1..32]
              sfisQueueDepth snapshot @?= 32
              mpsActiveNotes state @?= M.empty
              MIDIS.smlcsCoalescedCount stats @?= 128
              MIDIS.smlcsFlushedCount stats @?= 16
              MIDIS.smlcsBarrierFlushCount stats @?= 1
              MIDIS.smlcsPendingCount stats @?= 0
        Right other ->
          assertFailure
            ("expected coalesced pitch-bend flush at all-notes-off fence, got: "
             <> show other)

  , testCase "listener reports dropped fence when coalesced flush is rejected" $ do
      let activeNotes =
            M.fromList
              [ ((0, note), midiVoiceKey 0 note)
              | note <- [48..63]
              ]
          initialState =
            testMIDIProducerState activeNotes
          pitchValue =
            9000 :: Word16
          stateAfterPitch =
            initialState { mpsPitchBends = M.singleton 0 pitchValue }
          fanInOpts =
            defaultSessionFanInOptions
              { sfioQueueOptions = SessionQueueOptions 8
              }
          listenerOpts =
            MIDIS.defaultSessionMIDIListenerOptions
              { MIDIS.smloTimedControlFlushUsec = Nothing
              }
          expectedFreq note =
            midiNoteFrequency note
              * (2.0 ** ((((fromIntegral pitchValue - 8192.0) / 8192.0) * 2.0)
                          / 12.0))
          expectedFlush =
            [ CmdControlWrite (midiVoiceKey 0 note) midiFreqTag
                (expectedFreq note)
            | note <- [48..63]
            ]
      events <- newEmptyMVar
      producerResults <- newEmptyMVar
      fenceIssues <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue =
                \case
                  issue@(MIDIS.SmliFenceDroppedForFlushFailure _ _) ->
                    putMVar fenceIssues issue
                  _ ->
                    pure ()
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          fanInOpts
          $ \host ->
              MIDIS.withSessionMIDIListenerHooksAndOptions
                hooks
                listenerOpts
                testMIDIProducerOptions
                initialState
                source
                host
                $ \listener -> do
                    putMVar events
                      (Just (MIDIProducerPitchBend 0 pitchValue))
                    mPitch <- timeout 1000000 (takeMVar producerResults)
                    putMVar events (Just (MIDIProducerAllNotesOff Nothing))
                    mFence <- timeout 1000000 (takeMVar producerResults)
                    mIssue <- timeout 1000000 (takeMVar fenceIssues)
                    stats <- MIDIS.readSessionMIDIListenerCoalescingStats
                               listener
                    state <- MIDIS.readSessionMIDIListenerState listener
                    snapshot <- readSessionFanInHost host
                    pure (mPitch, mFence, mIssue, stats, state, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted pitchBatch []),
               Just (MIDIProducerEnqueueAttempted fenceBatch fenceEnqueues),
               Just fenceIssue, stats, state, snapshot) -> do
          length (mpcbCommands pitchBatch) @?= 16
          mpcbCommands fenceBatch @?= expectedFlush
          mpcbState fenceBatch @?= stateAfterPitch
          length fenceEnqueues @?= 16
          map sfierQueueDepth fenceEnqueues @?= [1..8] <> replicate 8 8
          let accepted =
                [ queued
                | result' <- map sfierResult fenceEnqueues
                , SessionEnqueued queued <- [result']
                ]
              rejected =
                [ issue'
                | result' <- map sfierResult fenceEnqueues
                , SessionEnqueueRejected _ _ issue' <- [result']
                ]
          map qscCommand accepted @?= take 8 expectedFlush
          rejected @?= replicate 8 (SeiQueueFull 8)
          fenceIssue
            @?= MIDIS.SmliFenceDroppedForFlushFailure
                  (MIDIProducerAllNotesOff Nothing)
                  8
          sfisQueueDepth snapshot @?= 8
          mpsActiveNotes state @?= activeNotes
          mpsPitchBends state @?= M.singleton 0 pitchValue
          MIDIS.smlcsCoalescedCount stats @?= 0
          MIDIS.smlcsFlushedCount stats @?= 8
          MIDIS.smlcsBarrierFlushCount stats @?= 1
          MIDIS.smlcsPendingCount stats @?= 16
        Right other ->
          assertFailure
            ("expected rejected coalesced flush to drop fence visibly, got: "
             <> show other)

  , testCase "listener flushes pending controls during teardown" $ do
      let note =
            60
          activeNotes =
            M.singleton (0, note) (midiVoiceKey 0 note)
          initialState =
            testMIDIProducerState activeNotes
          pitchValue =
            9000 :: Word16
          listenerOpts =
            MIDIS.defaultSessionMIDIListenerOptions
              { MIDIS.smloTimedControlFlushUsec = Nothing
              }
          expectedFreq =
            midiNoteFrequency note
              * (2.0 ** ((((fromIntegral pitchValue - 8192.0) / 8192.0) * 2.0)
                          / 12.0))
          expectedCommand =
            CmdControlWrite (midiVoiceKey 0 note) midiFreqTag expectedFreq
      events <- newEmptyMVar
      producerResults <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue          = \_ -> pure ()
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host -> do
              mPitch <-
                MIDIS.withSessionMIDIListenerHooksAndOptions
                  hooks
                  listenerOpts
                  testMIDIProducerOptions
                  initialState
                  source
                  host
                  $ \_listener -> do
                      putMVar events
                        (Just (MIDIProducerPitchBend 0 pitchValue))
                      timeout 1000000 (takeMVar producerResults)
              drained <- drainSessionFanInHost host
              pure (mPitch, drained)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted batch []), drained) -> do
          mpcbCommands batch @?= [expectedCommand]
          map (qscCommand . sdiQueued) (sdrItems (sfidrDrain drained))
            @?= [expectedCommand]
          sdrStopped (sfidrDrain drained) @?= Nothing
          sfidrQueueDepth drained @?= 0
        Right other ->
          assertFailure
            ("expected deferred pitch-bend flushed at teardown, got: "
             <> show other)

  , testCase "listener timed flush drains pending controls without a fence" $ do
      let note =
            60
          activeNotes =
            M.singleton (0, note) (midiVoiceKey 0 note)
          initialState =
            testMIDIProducerState activeNotes
          pitchValue =
            9000 :: Word16
          listenerOpts =
            MIDIS.defaultSessionMIDIListenerOptions
              { MIDIS.smloTimedControlFlushUsec = Just 1000
              }
          expectedFreq =
            midiNoteFrequency note
              * (2.0 ** ((((fromIntegral pitchValue - 8192.0) / 8192.0) * 2.0)
                          / 12.0))
          expectedCommand =
            CmdControlWrite (midiVoiceKey 0 note) midiFreqTag expectedFreq
      events <- newEmptyMVar
      producerResults <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue          = \_ -> pure ()
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListenerHooksAndOptions
                hooks
                listenerOpts
                testMIDIProducerOptions
                initialState
                source
                host
                $ \listener -> do
                    putMVar events
                      (Just (MIDIProducerPitchBend 0 pitchValue))
                    mPitch <- timeout 1000000 (takeMVar producerResults)
                    (stats, snapshot) <-
                      waitForTimedControlFlush listener host
                    drained <- drainSessionFanInHost host
                    pure (mPitch, stats, snapshot, drained)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted batch []),
               stats, snapshot, drained) -> do
          mpcbCommands batch @?= [expectedCommand]
          sfisQueueDepth snapshot @?= 1
          map (qscCommand . sdiQueued) (sdrItems (sfidrDrain drained))
            @?= [expectedCommand]
          MIDIS.smlcsCoalescedCount stats @?= 0
          MIDIS.smlcsFlushedCount stats @?= 1
          MIDIS.smlcsBarrierFlushCount stats @?= 0
          MIDIS.smlcsPendingCount stats @?= 0
        Right other ->
          assertFailure
            ("expected timed flush of deferred pitch-bend, got: "
             <> show other)

  , testCase "queue-full rejection does not advance listener state" $ do
      let fanInOpts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
      events <- newEmptyMVar
      issues <- newEmptyMVar
      producerResults <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue          = putMVar issues
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          fanInOpts
          $ \host -> do
              _prefill <-
                enqueueSessionFanInCommand
                  (testProducer ProducerTest "prefill")
                  prefill
                  host
              MIDIS.withSessionMIDIListenerHooks
                hooks
                testMIDIProducerOptions
                initialMIDIProducerState
                source
                host
                $ \listener -> do
                    putMVar events (Just (MIDIProducerNoteOn 0 69 127))
                    mResult <- timeout 1000000 (takeMVar producerResults)
                    mIssue <- timeout 1000000 (takeMVar issues)
                    state <- MIDIS.readSessionMIDIListenerState listener
                    pure (mResult, mIssue, state)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted batch [enq]),
               Just issue, state) -> do
          mpcbState batch @?= initialMIDIProducerState
          mpsActiveNotes state @?= M.empty
          case mpcbCommands batch of
            [command] -> do
              sfierResult enq
                @?= SessionEnqueueRejected
                      (midiProducerId testMIDIProducerOptions)
                      command
                      (SeiQueueFull 1)
              issue @?= MIDIS.SmliEnqueueRejected command (SeiQueueFull 1)
            other ->
              assertFailure ("expected one MIDI command, got: " <> show other)
        Right other ->
          assertFailure ("expected queue-full listener result, got: "
                         <> show other)

  , testCase "bracket cleanup kills worker when producer hook blocks" $ do
      events <- newEmptyMVar
      hookEntered <- newEmptyMVar
      neverRelease <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult =
                \_result -> do
                  putMVar hookEntered ()
                  takeMVar neverRelease
            , MIDIS.smlhOnIssue =
                \_ -> pure ()
            }
      result <- timeout 1000000 $
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListenerHooks
                hooks
                testMIDIProducerOptions
                initialMIDIProducerState
                source
                host
                $ \_listener -> do
                    putMVar events (Just (MIDIProducerNoteOn 0 69 100))
                    timeout 1000000 (takeMVar hookEntered)
      case result of
        Nothing ->
          assertFailure "MIDI listener teardown hung while hook was blocked"
        Just (Left issue) ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Just (Right (Just ())) ->
          pure ()
        Just (Right Nothing) ->
          assertFailure "timed out waiting for blocking MIDI hook"

  , testCase "service host wakes worker for listener note-on" $ do
      events <- newEmptyMVar
      producerResults <- newEmptyMVar
      drainedVar <- newEmptyMVar
      let source = midiMVarSource events
          listenerHooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue          = \_ -> pure ()
            }
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service ->
              MIDIS.withSessionMIDIListenerHooks
                listenerHooks
                testMIDIPlayableOptions
                initialMIDIProducerState
                source
                (sessionFanInServiceHost service)
                $ \listener -> do
                    putMVar events (Just (MIDIProducerNoteOn 0 69 100))
                    mProducer <- timeout 1000000 (takeMVar producerResults)
                    mDrain <- timeout 1000000 (takeMVar drainedVar)
                    state <- MIDIS.readSessionMIDIListenerState listener
                    snapshot <- readSessionFanInService service
                    pure (mProducer, mDrain, state, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted _ [enq]),
               Just drained, state, snapshot) -> do
          queued <- fanInQueuedOrFail enq
          map sdiQueued (sdrItems (sfidrDrain drained)) @?= [queued]
          case map sdiResult (sdrItems (sfidrDrain drained)) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure
                ("expected listener note-on to commit through service, got: "
                 <> show other)
          mpsActiveNotes state
            @?= M.singleton (0, 69) (VoiceKey "m0-69")
          sfisQueueDepth snapshot @?= 0
          assertBool
            "expected MIDI listener voice after service drain"
            (M.member (VoiceKey "m0-69") (ssVoices (sfisOwnerState snapshot)))
        Right other ->
          assertFailure ("expected MIDI listener service enqueue, got: "
                         <> show other)
  ]

midiMVarSource :: MVar (Maybe MIDIProducerEvent) -> MIDIS.MIDIListenerSource
midiMVarSource events =
  MIDIS.MIDIListenerSource (takeMVar events)

waitForTimedControlFlush
  :: MIDIS.SessionMIDIListener
  -> SessionFanInHost
  -> IO (MIDIS.SessionMIDIListenerCoalescingStats, SessionFanInSnapshot)
waitForTimedControlFlush listener host =
  loop (100 :: Int)
  where
    loop 0 =
      assertFailure "timed out waiting for MIDI listener timed control flush"
    loop n = do
      stats <- MIDIS.readSessionMIDIListenerCoalescingStats listener
      snapshot <- readSessionFanInHost host
      if MIDIS.smlcsPendingCount stats == 0 && sfisQueueDepth snapshot > 0
         then pure (stats, snapshot)
         else do
           threadDelay 1000
           loop (n - 1)

------------------------------------------------------------
-- Session MIDI PortMIDI source
--
-- This is the hardware-backed source boundary for the decoded MIDI
-- listener. Tests use an invalid device id so they stay deterministic
-- on no-controller and headless CI hosts.
------------------------------------------------------------

sessionMIDIPortMIDISourceTests :: TestTree
sessionMIDIPortMIDISourceTests =
  testGroup "Session MIDI PortMIDI source"
  [ testCase "event tags match the C ABI header contract" $
      MIDIPM.portMIDISourceEventKindTags @?= (0, 1, 2, 3, 4)

  , testCase "invalid device opens an idle closeable source" $ do
      result <-
        MIDIPM.withPortMIDISource invalidPortMIDIOptions $ \case
          Nothing ->
            pure (Left "source open returned Nothing")
          Just source -> do
            hasDevice <- MIDIPM.portMIDISourceHasDevice source
            mEvent <- MIDIPM.pollPortMIDISourceEvent source
            pure (Right (hasDevice, mEvent))
      case result of
        Left err ->
          assertFailure err
        Right (hasDevice, mEvent) -> do
          hasDevice @?= False
          mEvent @?= Nothing

  , testCase "idle PortMIDI source composes with MIDI listener teardown" $ do
      result <- timeout 1000000 $
        MIDIPM.withPortMIDISource invalidPortMIDIOptions $ \case
          Nothing ->
            pure (Left "source open returned Nothing")
          Just source ->
            Right <$>
              withSessionFanInHost
                (patternTemplates droneVibrato)
                defaultSessionFanInOptions
                (\host ->
                   MIDIS.withSessionMIDIListener
                     testMIDIProducerOptions
                     initialMIDIProducerState
                     (MIDIPM.portMIDIListenerSource invalidPortMIDIOptions
                                                    source)
                     host
                     $ \_listener -> pure (42 :: Int))
      case result of
        Nothing ->
          assertFailure "PortMIDI listener teardown hung on idle source"
        Just (Left err) ->
          assertFailure err
        Just (Right (Left issue)) ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Just (Right (Right value)) ->
          value @?= 42
  ]

invalidPortMIDIOptions :: MIDIPM.PortMIDISourceOptions
invalidPortMIDIOptions = MIDIPM.defaultPortMIDISourceOptions
  { MIDIPM.pmsoDeviceId      = Just 2147483647
  , MIDIPM.pmsoPollDelayUsec = 1000
  }
