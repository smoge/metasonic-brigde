{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.MIDIProducer
-- Description : Haskell-only MIDI event adapter for session fan-in.
--
-- This module defines a narrow, protocol-neutral MIDI producer above
-- 'MetaSonic.Session.FanIn'. It translates decoded MIDI note, CC, and
-- all-notes-off/reset events into symbolic 'SessionCommand's, then
-- submits them as 'ProducerMIDI'.
--
-- It deliberately does not open PortMIDI devices, own a listener
-- thread, define a live clock, arbitrate against OSC beyond the
-- existing FIFO fan-in queue, or repair a diverged owner. The live
-- C++ MIDI demo path remains in "MetaSonic.Bridge.MidiDemo".

module MetaSonic.Session.MIDIProducer
  ( -- * Events
    MIDIProducerEvent (..)
  , midiNoteFrequency

    -- * Mapping
  , MIDIControlMapping (..)
  , MIDIProducerOptions (..)
  , defaultMIDIProducerOptions
  , midiProducerId

    -- * State
  , MIDIProducerState (..)
  , initialMIDIProducerState
  , midiVoiceKey

    -- * Issues
  , MIDIProducerIssue (..)

    -- * Translation
  , MIDIProducerCommandBatch (..)
  , decodeMIDISessionCommands

    -- * Fan-in submission
  , MIDIProducerEnqueueResult (..)
  , enqueueMIDIProducerEvent
  ) where

import           Control.DeepSeq            (NFData)
import qualified Data.Map.Strict            as M
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Word                  (Word8)
import           GHC.Generics               (Generic)

import           MetaSonic.Pattern          (ControlTag, TemplateName (..),
                                             Value, VoiceKey (..))
import           MetaSonic.Session.Command  (SessionCommand (..))
import           MetaSonic.Session.FanIn    (SessionFanInEnqueueResult (..),
                                             SessionFanInHost,
                                             enqueueSessionFanInCommand)
import           MetaSonic.Session.Queue    (ProducerId (..),
                                             ProducerKind (..),
                                             SessionEnqueueResult (..))


-- | Decoded MIDI producer events.
--
-- Channels are zero-based MIDI channels. Note, velocity, controller,
-- and controller values must be MIDI data bytes in @[0, 127]@.
-- For 'MIDIProducerAllNotesOff', 'Nothing' means every active producer
-- note, and 'Just' means only notes currently active on that channel.
data MIDIProducerEvent
  = MIDIProducerNoteOn
      { mpeChannel  :: !Word8
      , mpeNote     :: !Word8
      , mpeVelocity :: !Word8
      }
  | MIDIProducerNoteOff
      { mpeChannel  :: !Word8
      , mpeNote     :: !Word8
      , mpeVelocity :: !Word8
      }
  | MIDIProducerControlChange
      { mpeChannel    :: !Word8
      , mpeController :: !Word8
      , mpeValue      :: !Word8
      }
  | MIDIProducerAllNotesOff
      { mpeAllNotesChannel :: !(Maybe Word8)
      }
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | One MIDI CC mapping into a symbolic session control target.
data MIDIControlMapping = MIDIControlMapping
  { mcmTarget :: !ControlTag
  , mcmMin    :: !Value
  , mcmMax    :: !Value
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Translation options for MIDI note and CC events.
data MIDIProducerOptions = MIDIProducerOptions
  { mpoProducerName     :: !Text
  , mpoTemplateName     :: !TemplateName
  , mpoFrequencyControl :: !(Maybe ControlTag)
  , mpoGateControl      :: !(Maybe ControlTag)
  , mpoVelocityControl  :: !(Maybe ControlTag)
  , mpoCCMappings       :: !(M.Map Word8 MIDIControlMapping)
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Conservative defaults for tests and demos.
defaultMIDIProducerOptions :: MIDIProducerOptions
defaultMIDIProducerOptions = MIDIProducerOptions
  { mpoProducerName     = T.pack "midi"
  , mpoTemplateName     = TemplateName "voice"
  , mpoFrequencyControl = Nothing
  , mpoGateControl      = Nothing
  , mpoVelocityControl  = Nothing
  , mpoCCMappings       = M.empty
  }

-- | Producer identity used for fan-in queue entries.
midiProducerId :: MIDIProducerOptions -> ProducerId
midiProducerId opts =
  ProducerId ProducerMIDI (mpoProducerName opts)

-- | MIDI producer state that is independent of the session owner.
newtype MIDIProducerState = MIDIProducerState
  { mpsActiveNotes :: M.Map (Word8, Word8) VoiceKey
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Initial MIDI producer state.
initialMIDIProducerState :: MIDIProducerState
initialMIDIProducerState = MIDIProducerState
  { mpsActiveNotes = M.empty
  }

-- | Translation or producer-state issue.
data MIDIProducerIssue
  = MpiInvalidChannel !Word8
  | MpiInvalidDataByte !Text !Word8
  | MpiNoteAlreadyActive !Word8 !Word8
  | MpiNoteNotActive !Word8 !Word8
  | MpiUnmappedControl !Word8
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Pure translation result.
data MIDIProducerCommandBatch = MIDIProducerCommandBatch
  { mpcbCommands :: ![SessionCommand]
  , mpcbState    :: !MIDIProducerState
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Result of translating and enqueueing one MIDI event.
data MIDIProducerEnqueueResult
  = MIDIProducerRejected !MIDIProducerIssue !MIDIProducerState
  | MIDIProducerEnqueueAttempted
      !MIDIProducerCommandBatch
      ![SessionFanInEnqueueResult]
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Stable session voice key for a MIDI channel/note pair.
--
-- The generated key is OSC-safe and <= 16 bytes, matching session
-- voice-key validation.
midiVoiceKey :: Word8 -> Word8 -> VoiceKey
midiVoiceKey channel note =
  VoiceKey ("m" <> show channel <> "-" <> show note)

-- | Convert a MIDI note number to equal-tempered frequency in Hz.
midiNoteFrequency :: Word8 -> Value
midiNoteFrequency note =
  440.0 * (2.0 ** ((fromIntegral note - 69.0) / 12.0))

-- | Translate one decoded MIDI event into zero or more session
-- commands plus the next producer state.
decodeMIDISessionCommands
  :: MIDIProducerOptions
  -> MIDIProducerState
  -> MIDIProducerEvent
  -> Either MIDIProducerIssue MIDIProducerCommandBatch
decodeMIDISessionCommands opts st event = do
  validateEvent event
  case event of
    MIDIProducerNoteOn ch note velocity
      | velocity == 0 ->
          noteOff ch note st
      | otherwise ->
          noteOn ch note velocity st
    MIDIProducerNoteOff ch note _velocity ->
      noteOff ch note st
    MIDIProducerControlChange _ch controller value ->
      controlChange controller value st
    MIDIProducerAllNotesOff target ->
      allNotesOff target st
  where
    noteOn ch note velocity (MIDIProducerState active) = do
      let key = (ch, note)
      case M.lookup key active of
        Just _ ->
          Left (MpiNoteAlreadyActive ch note)
        Nothing ->
          let vkey = midiVoiceKey ch note
              controls = noteOnControls note velocity
              st' = MIDIProducerState
                { mpsActiveNotes = M.insert key vkey active
                }
          in Right MIDIProducerCommandBatch
               { mpcbCommands =
                   [CmdVoiceOn (mpoTemplateName opts) vkey controls]
               , mpcbState =
                   st'
               }

    noteOff ch note (MIDIProducerState active) = do
      let key = (ch, note)
      case M.lookup key active of
        Nothing ->
          Left (MpiNoteNotActive ch note)
        Just vkey ->
          let st' = MIDIProducerState
                { mpsActiveNotes = M.delete key active
                }
          in Right MIDIProducerCommandBatch
               { mpcbCommands =
                   [CmdVoiceOff vkey]
               , mpcbState =
                   st'
               }

    controlChange controller value (MIDIProducerState active) =
      case M.lookup controller (mpoCCMappings opts) of
        Nothing ->
          Left (MpiUnmappedControl controller)
        Just mapping ->
          Right MIDIProducerCommandBatch
            { mpcbCommands =
                [ CmdControlWrite vkey (mcmTarget mapping)
                    (scaleControl mapping value)
                | vkey <- M.elems active
                ]
            , mpcbState =
                st
            }

    allNotesOff target (MIDIProducerState active) =
      let (stopped, kept) =
            M.partitionWithKey
              (\(ch, _note) _vkey -> maybe True (== ch) target)
              active
          st' = MIDIProducerState
            { mpsActiveNotes = kept
            }
      in Right MIDIProducerCommandBatch
           { mpcbCommands =
               [ CmdVoiceOff vkey
               | vkey <- M.elems stopped
               ]
           , mpcbState =
               st'
           }

    noteOnControls note velocity =
      concat
        [ maybe [] (\target -> [(target, midiNoteFrequency note)])
            (mpoFrequencyControl opts)
        , maybe [] (\target -> [(target, 1.0)])
            (mpoGateControl opts)
        , maybe [] (\target -> [(target, velocityToUnit velocity)])
            (mpoVelocityControl opts)
        ]

-- | Translate and enqueue one MIDI event through the supplied fan-in host.
--
-- Stateful note-on/note-off bookkeeping advances only if every enqueue
-- attempt succeeds. If the host rejects a generated command, the
-- returned batch carries the original state so callers can retry or
-- surface backpressure without inventing a producer/owner mismatch.
enqueueMIDIProducerEvent
  :: MIDIProducerOptions
  -> MIDIProducerState
  -> MIDIProducerEvent
  -> SessionFanInHost
  -> IO MIDIProducerEnqueueResult
enqueueMIDIProducerEvent opts st event host =
  case decodeMIDISessionCommands opts st event of
    Left issue ->
      pure (MIDIProducerRejected issue st)
    Right batch -> do
      results <- traverse
        (\cmd -> enqueueSessionFanInCommand (midiProducerId opts) cmd host)
        (mpcbCommands batch)
      let finalBatch =
            if all enqueueAccepted results
               then batch
               else batch { mpcbState = st }
      pure (MIDIProducerEnqueueAttempted finalBatch results)

validateEvent :: MIDIProducerEvent -> Either MIDIProducerIssue ()
validateEvent event = case event of
  MIDIProducerNoteOn ch note velocity -> do
    validateChannel ch
    validateDataByte (T.pack "note") note
    validateDataByte (T.pack "velocity") velocity
  MIDIProducerNoteOff ch note velocity -> do
    validateChannel ch
    validateDataByte (T.pack "note") note
    validateDataByte (T.pack "velocity") velocity
  MIDIProducerControlChange ch controller value -> do
    validateChannel ch
    validateDataByte (T.pack "controller") controller
    validateDataByte (T.pack "value") value
  MIDIProducerAllNotesOff Nothing ->
    Right ()
  MIDIProducerAllNotesOff (Just ch) ->
    validateChannel ch

validateChannel :: Word8 -> Either MIDIProducerIssue ()
validateChannel ch
  | ch <= 15 =
      Right ()
  | otherwise =
      Left (MpiInvalidChannel ch)

validateDataByte :: Text -> Word8 -> Either MIDIProducerIssue ()
validateDataByte label value
  | value <= 127 =
      Right ()
  | otherwise =
      Left (MpiInvalidDataByte label value)

velocityToUnit :: Word8 -> Value
velocityToUnit velocity =
  fromIntegral velocity / 127.0

scaleControl :: MIDIControlMapping -> Word8 -> Value
scaleControl mapping value =
  let x = fromIntegral value / 127.0
  in mcmMin mapping + x * (mcmMax mapping - mcmMin mapping)

enqueueAccepted :: SessionFanInEnqueueResult -> Bool
enqueueAccepted result = case sfierResult result of
  SessionEnqueued {} ->
    True
  SessionEnqueueRejected {} ->
    False
