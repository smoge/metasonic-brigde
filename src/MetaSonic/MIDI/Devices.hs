{-# LANGUAGE ForeignFunctionInterface #-}

-- |
-- Module      : MetaSonic.MIDI.Devices
-- Description : Shared Q / PortMIDI device enumeration.
--
-- This module is the neutral Haskell wrapper for the current
-- Q / PortMIDI device table. It is used by both the legacy live MIDI
-- demo wrapper and the session MIDI smoke path so device enumeration
-- does not depend on either runtime policy.

module MetaSonic.MIDI.Devices
  ( MidiDeviceInfo (..)
  , midiDeviceList
  ) where

import           Foreign.C.String       (peekCString)
import           Foreign.C.Types        (CChar, CInt (..))
import           Foreign.Marshal.Array  (allocaArray, peekArray)
import           Foreign.Ptr            (Ptr, castPtr, nullPtr, plusPtr)
import           Foreign.Storable       (Storable (..))

-- | One row from the current PortMIDI device table. Device ids are
-- the values accepted by MIDI-backed commands such as @midi-poly@,
-- @--midi-device@, and @--session-midi-smoke@.
data MidiDeviceInfo = MidiDeviceInfo
  { midiDeviceId      :: !Int
  , midiDeviceName    :: !String
  , midiDeviceInputs  :: !Int
  , midiDeviceOutputs :: !Int
  } deriving (Eq, Show)

data CMidiDeviceInfo = CMidiDeviceInfo
  { cMidiDeviceId      :: !CInt
  , cMidiDeviceInputs  :: !CInt
  , cMidiDeviceOutputs :: !CInt
  , cMidiDeviceName    :: !String
  }

-- The C struct is defined in tinysynth/midi_demo.h as:
--
--   int id;
--   int num_inputs;
--   int num_outputs;
--   char name[256];
--
-- On the supported C++ ABI this is 268 bytes with 4-byte alignment.
instance Storable CMidiDeviceInfo where
  sizeOf    _ = 268
  alignment _ = 4
  peek p = do
    devId   <- peekByteOff p 0
    inputs  <- peekByteOff p 4
    outputs <- peekByteOff p 8
    name    <- peekCString (castPtr (p `plusPtr` 12) :: Ptr CChar)
    pure CMidiDeviceInfo
      { cMidiDeviceId      = devId
      , cMidiDeviceInputs  = inputs
      , cMidiDeviceOutputs = outputs
      , cMidiDeviceName    = name
      }
  poke _ _ =
    error "CMidiDeviceInfo is read-only on the Haskell side"

midiDeviceList :: IO (Either String [MidiDeviceInfo])
midiDeviceList = do
  n0 <- c_rt_midi_device_list nullPtr 0
  if n0 < 0
    then pure (Left "MIDI device enumeration failed")
    else if n0 == 0
      then pure (Right [])
      else allocaArray (fromIntegral n0) $ \p -> do
        n1 <- c_rt_midi_device_list p n0
        if n1 < 0
          then pure (Left "MIDI device enumeration failed")
          else do
            rows <- peekArray (fromIntegral (min n0 n1)) p
            pure (Right (map fromCMidiDeviceInfo rows))
  where
    fromCMidiDeviceInfo :: CMidiDeviceInfo -> MidiDeviceInfo
    fromCMidiDeviceInfo c = MidiDeviceInfo
      { midiDeviceId      = fromIntegral (cMidiDeviceId c)
      , midiDeviceName    = cMidiDeviceName c
      , midiDeviceInputs  = fromIntegral (cMidiDeviceInputs c)
      , midiDeviceOutputs = fromIntegral (cMidiDeviceOutputs c)
      }

foreign import ccall safe "rt_midi_device_list"
  c_rt_midi_device_list :: Ptr CMidiDeviceInfo -> CInt -> IO CInt
