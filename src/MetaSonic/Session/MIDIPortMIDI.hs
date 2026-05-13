{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.MIDIPortMIDI
-- Description : PortMIDI/Q source for session MIDI listener.
--
-- This module adapts Q / PortMIDI input into the decoded-event source
-- consumed by 'MetaSonic.Session.MIDIListener'. It owns only a small
-- polling handle; the session listener owns the worker thread and the
-- MIDI producer owns note/CC translation policy.
--
-- The source decodes MIDI 1.0 note-on, note-off, and control-change
-- messages. Other messages are consumed and ignored. Pitch bend,
-- aftertouch, MIDI clock, channel masks, and all-notes-off policy stay
-- out of scope for this v1 source.

module MetaSonic.Session.MIDIPortMIDI
  ( PortMIDISourceOptions (..)
  , defaultPortMIDISourceOptions
  , PortMIDISource
  , openPortMIDISource
  , closePortMIDISource
  , withPortMIDISource
  , portMIDISourceHasDevice
  , pollPortMIDISourceEvent
  , portMIDIListenerSource
  ) where

import           Control.Concurrent             (threadDelay)
import           Control.DeepSeq                (NFData)
import           Control.Exception              (bracket)
import           Data.Word                      (Word8)
import           Foreign.C.Types                (CInt (..))
import           Foreign.Marshal.Alloc          (alloca)
import           Foreign.Ptr                    (Ptr, nullPtr)
import           Foreign.Storable               (peek)
import           GHC.Generics                   (Generic)

import           MetaSonic.Session.MIDIListener (MIDIListenerSource (..))
import           MetaSonic.Session.MIDIProducer (MIDIProducerEvent (..))


data PortMIDISourceOptions = PortMIDISourceOptions
  { pmsoDeviceId      :: !(Maybe Int)
    -- ^ PortMIDI device id. 'Nothing' selects Q's canonical default
    -- device id 0.
  , pmsoPollDelayUsec :: !Int
    -- ^ Sleep duration after a no-event poll when used as a
    -- 'MIDIListenerSource'.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

defaultPortMIDISourceOptions :: PortMIDISourceOptions
defaultPortMIDISourceOptions = PortMIDISourceOptions
  { pmsoDeviceId      = Nothing
  , pmsoPollDelayUsec = 1000
  }

data CPortMIDISource

newtype PortMIDISource = PortMIDISource (Ptr CPortMIDISource)

-- | Open a PortMIDI/Q polling source.
--
-- A valid handle can still report 'False' from
-- 'portMIDISourceHasDevice' when no matching input-capable device is
-- present. This keeps no-MIDI hosts closeable and lets callers decide
-- whether an idle source is acceptable.
openPortMIDISource
  :: PortMIDISourceOptions
  -> IO (Maybe PortMIDISource)
openPortMIDISource opts = do
  h <- c_rt_session_midi_source_open
        (fromIntegral (maybe (-1) id (pmsoDeviceId opts)))
  pure $! if h == nullPtr
             then Nothing
             else Just (PortMIDISource h)

-- | Close a PortMIDI/Q source handle. After return the handle is
-- invalid.
closePortMIDISource :: PortMIDISource -> IO ()
closePortMIDISource (PortMIDISource h) =
  c_rt_session_midi_source_close h

withPortMIDISource
  :: PortMIDISourceOptions
  -> (Maybe PortMIDISource -> IO a)
  -> IO a
withPortMIDISource opts =
  bracket (openPortMIDISource opts) (mapM_ closePortMIDISource)

portMIDISourceHasDevice :: PortMIDISource -> IO Bool
portMIDISourceHasDevice (PortMIDISource h) =
  (== 1) <$> c_rt_session_midi_source_has_device h

-- | Poll once for a supported decoded MIDI event.
--
-- 'Nothing' means no supported event is currently available. It does
-- not mean source EOF.
pollPortMIDISourceEvent :: PortMIDISource -> IO (Maybe MIDIProducerEvent)
pollPortMIDISourceEvent (PortMIDISource h) =
  alloca $ \channelPtr ->
    alloca $ \data1Ptr ->
      alloca $ \data2Ptr -> do
        kind <- c_rt_session_midi_source_poll h
                  channelPtr
                  data1Ptr
                  data2Ptr
        if kind <= 0
          then pure Nothing
          else do
            ch <- fromCDataByte <$> peek channelPtr
            d1 <- fromCDataByte <$> peek data1Ptr
            d2 <- fromCDataByte <$> peek data2Ptr
            pure (fromEventKind kind ch d1 d2)

-- | Convert a polling PortMIDI handle into the blocking source shape
-- used by 'MetaSonic.Session.MIDIListener'.
--
-- This source does not emit EOF by itself; no-event polls sleep and
-- retry until a decoded event arrives. Listener bracket teardown
-- interrupts the sleeping worker with 'killThread'.
portMIDIListenerSource
  :: PortMIDISourceOptions
  -> PortMIDISource
  -> MIDIListenerSource
portMIDIListenerSource opts source =
  MIDIListenerSource loop
  where
    loop = do
      mEvent <- pollPortMIDISourceEvent source
      case mEvent of
        Just event ->
          pure (Just event)
        Nothing -> do
          threadDelay (max 1 (pmsoPollDelayUsec opts))
          loop

fromEventKind :: CInt -> Word8 -> Word8 -> Word8 -> Maybe MIDIProducerEvent
fromEventKind kind ch d1 d2
  | kind == rtSessionMIDIEventNoteOn =
      Just (MIDIProducerNoteOn ch d1 d2)
  | kind == rtSessionMIDIEventNoteOff =
      Just (MIDIProducerNoteOff ch d1 d2)
  | kind == rtSessionMIDIEventControlChange =
      Just (MIDIProducerControlChange ch d1 d2)
  | otherwise =
      Nothing

fromCDataByte :: CInt -> Word8
fromCDataByte =
  fromIntegral

rtSessionMIDIEventNoteOn :: CInt
rtSessionMIDIEventNoteOn =
  1

rtSessionMIDIEventNoteOff :: CInt
rtSessionMIDIEventNoteOff =
  2

rtSessionMIDIEventControlChange :: CInt
rtSessionMIDIEventControlChange =
  3

foreign import ccall safe "rt_session_midi_source_open"
  c_rt_session_midi_source_open :: CInt -> IO (Ptr CPortMIDISource)

foreign import ccall safe "rt_session_midi_source_close"
  c_rt_session_midi_source_close :: Ptr CPortMIDISource -> IO ()

foreign import ccall unsafe "rt_session_midi_source_has_device"
  c_rt_session_midi_source_has_device :: Ptr CPortMIDISource -> IO CInt

foreign import ccall unsafe "rt_session_midi_source_poll"
  c_rt_session_midi_source_poll
    :: Ptr CPortMIDISource
    -> Ptr CInt
    -> Ptr CInt
    -> Ptr CInt
    -> IO CInt
