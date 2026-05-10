{-# LANGUAGE ForeignFunctionInterface #-}

-- |
-- Module      : MetaSonic.Bridge.MidiDemo
-- Description : Haskell wrapper around tinysynth/midi_demo.h
--
-- Slice 3 of the end-to-end MIDI demo. The C side
-- (@tinysynth/midi_demo.cpp@) owns the worker thread, the live MIDI
-- input stream, and the producer-thread voice/CC dispatch. This
-- module exposes its open\/close lifecycle and binding manifest to
-- Haskell so a 'MetaSonic.Bridge.Source.SynthGraph' compiled and
-- loaded via 'MetaSonic.Bridge.FFI.loadTemplateGraph' can be played
-- by a real MIDI controller.
--
-- Typical wiring:
--
-- 1. Build a synth template with the source DSL and capture
--    'MetaSonic.Bridge.Source.Connection' values for the per-voice
--    freq\/gate inputs and any CC-bound controls (use 'runSynthWith').
-- 2. Lower + compile via 'lowerGraph' and the template-graph compiler.
-- 3. Load via 'loadTemplateGraph', set polyphony, and pre-warm the
--    pool with @polyphony@ spawn-then-remove cycles.
-- 4. Resolve each captured 'Connection' to a dense 'NodeIndex' via
--    'connectionNodeID' + 'resolveNodeIndex'.
-- 5. Build a 'VoiceMapping' (and any 'CCMapping' \/ 'PitchBendBinding')
--    using those indices.
-- 6. 'withMidiDemo' bracket: opens the MIDI session, runs the body
--    (typically the realtime audio bracket), closes the session.
--
-- Threading: the C side spawns a single producer worker that reads
-- the live MIDI stream and drives 'VoiceAllocator' \/
-- 'MidiVoiceProcessor'. The Haskell side only manages lifecycle,
-- never event dispatch, so there is no Haskell-side thread to
-- coordinate.
module MetaSonic.Bridge.MidiDemo
  ( -- * Opaque handle
    MidiDemo
    -- * Bindings (Haskell-side mirrors of the C structs in midi_demo.h)
  , VoiceMapping (..)
  , CCMapping (..)
  , PitchBendBinding (..)
    -- * Lifecycle
  , openMidiDemo
  , closeMidiDemo
  , withMidiDemo
    -- * Diagnostics (cumulative since open)
  , midiNoteOnCount
  , midiNoteOffCount
  , midiCcCount
  , midiPitchBendCount
  , midiHasDevice
  ) where

import           Control.Exception          (bracket)
import           Data.Word                  (Word16, Word8)
import           Foreign.C.Types            (CInt (..), CFloat (..),
                                             CUChar (..), CUShort (..))
import           Foreign.Marshal.Array      (withArrayLen)
import           Foreign.Marshal.Utils      (with)
import           Foreign.Ptr                (Ptr, nullPtr)
import           Foreign.Storable           (Storable (..))

import           MetaSonic.Bridge.FFI       (RTGraph)
import           MetaSonic.Types            (NodeIndex (..))

-- | Opaque handle to a running MIDI demo session. The pointer target
-- is owned by the C side; do not free it directly — always go through
-- 'closeMidiDemo' (or the 'withMidiDemo' bracket).
newtype MidiDemo = MidiDemo (Ptr CMidiDemo)

-- Phantom for the C-side @rt_midi_demo@ struct; kept abstract.
data CMidiDemo

-- | Routing for note-on events. The voice map callback writes
-- frequency to @(vmFreqNode, vmFreqCtl)@, gate=1.0 to @(vmGateNode,
-- vmGateCtl)@, and velocity to @vmVelocity@ when present. Note-offs
-- go through 'VoiceAllocator' release, which triggers the env's
-- release segment — no separate gate=0 write is needed here.
data VoiceMapping = VoiceMapping
  { vmFreqNode :: !NodeIndex
  , vmFreqCtl  :: !Int
  , vmGateNode :: !NodeIndex
  , vmGateCtl  :: !Int
  , vmVelocity :: !(Maybe (NodeIndex, Int))
  } deriving (Eq, Show)

-- | One CC binding: when @ccNumber@ arrives, every Active /
-- Releasing voice's @(ccNode, ccCtl)@ is set to
-- @ccMin + (cc_value \/ 127) * (ccMax - ccMin)@.
data CCMapping = CCMapping
  { ccNumber :: !Word8
  , ccNode   :: !NodeIndex
  , ccCtl    :: !Int
  , ccMin    :: !Float
  , ccMax    :: !Float
  } deriving (Eq, Show)

-- | Optional pitch-bend binding. Each Active / Releasing voice's
-- @(pbNode, pbCtl)@ is rewritten to
-- @as_frequency(pitch{voice_note}) * 2^(bend * pbSemitones \/ 12)@
-- where @bend@ is the 14-bit MIDI value mapped to [-1, 1].
data PitchBendBinding = PitchBendBinding
  { pbNode      :: !NodeIndex
  , pbCtl       :: !Int
  , pbSemitones :: !Float
  } deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- C-mirror Storable instances. The structs in midi_demo.h use the
-- platform's natural alignment for int / float, which on x86-64 Linux
-- means 4-byte alignment throughout. Each instance is hand-rolled so
-- the size and offsets match the C compiler's layout.
-- ---------------------------------------------------------------------------

data CVoiceMapping = CVoiceMapping
  { cVmFreqNode :: !CInt
  , cVmFreqCtl  :: !CInt
  , cVmGateNode :: !CInt
  , cVmGateCtl  :: !CInt
  , cVmVelNode  :: !CInt
  , cVmVelCtl   :: !CInt
  }

instance Storable CVoiceMapping where
  sizeOf    _ = 24
  alignment _ = 4
  peek p = CVoiceMapping
    <$> peekByteOff p 0
    <*> peekByteOff p 4
    <*> peekByteOff p 8
    <*> peekByteOff p 12
    <*> peekByteOff p 16
    <*> peekByteOff p 20
  poke p (CVoiceMapping a b c d e f) = do
    pokeByteOff p 0  a
    pokeByteOff p 4  b
    pokeByteOff p 8  c
    pokeByteOff p 12 d
    pokeByteOff p 16 e
    pokeByteOff p 20 f

data CCcMapping = CCcMapping
  { cCcNumber :: !CUChar
  , cCcNode   :: !CInt
  , cCcCtl    :: !CInt
  , cCcMin    :: !CFloat
  , cCcMax    :: !CFloat
  }

-- @uint8_t cc_number@ has 3 bytes of padding before @int node_index@
-- so that subsequent ints land on a 4-byte boundary; total size is 20
-- bytes.
instance Storable CCcMapping where
  sizeOf    _ = 20
  alignment _ = 4
  peek p = CCcMapping
    <$> peekByteOff p 0
    <*> peekByteOff p 4
    <*> peekByteOff p 8
    <*> peekByteOff p 12
    <*> peekByteOff p 16
  poke p (CCcMapping cc node ctl mn mx) = do
    pokeByteOff p 0  cc
    pokeByteOff p 4  node
    pokeByteOff p 8  ctl
    pokeByteOff p 12 mn
    pokeByteOff p 16 mx

data CPitchBendBinding = CPitchBendBinding
  { cPbNode      :: !CInt
  , cPbCtl       :: !CInt
  , cPbSemitones :: !CFloat
  }

instance Storable CPitchBendBinding where
  sizeOf    _ = 12
  alignment _ = 4
  peek p = CPitchBendBinding
    <$> peekByteOff p 0
    <*> peekByteOff p 4
    <*> peekByteOff p 8
  poke p (CPitchBendBinding n c r) = do
    pokeByteOff p 0 n
    pokeByteOff p 4 c
    pokeByteOff p 8 r

-- ---------------------------------------------------------------------------
-- Marshalling from Haskell-facing records to C-mirror records.
-- ---------------------------------------------------------------------------

toCVoiceMapping :: VoiceMapping -> CVoiceMapping
toCVoiceMapping vm =
  let (vn, vc) = case vmVelocity vm of
        Nothing       -> (-1, -1)
        Just (n, c)   -> (cni n, fromIntegral c)
  in CVoiceMapping
       { cVmFreqNode = cni (vmFreqNode vm)
       , cVmFreqCtl  = fromIntegral (vmFreqCtl vm)
       , cVmGateNode = cni (vmGateNode vm)
       , cVmGateCtl  = fromIntegral (vmGateCtl vm)
       , cVmVelNode  = vn
       , cVmVelCtl   = vc
       }
  where
    cni (NodeIndex i) = fromIntegral i

toCCcMapping :: CCMapping -> CCcMapping
toCCcMapping m = CCcMapping
  { cCcNumber = fromIntegral (ccNumber m)
  , cCcNode   = let NodeIndex i = ccNode m in fromIntegral i
  , cCcCtl    = fromIntegral (ccCtl m)
  , cCcMin    = realToFrac (ccMin m)
  , cCcMax    = realToFrac (ccMax m)
  }

toCPitchBendBinding :: PitchBendBinding -> CPitchBendBinding
toCPitchBendBinding pb = CPitchBendBinding
  { cPbNode      = let NodeIndex i = pbNode pb in fromIntegral i
  , cPbCtl       = fromIntegral (pbCtl pb)
  , cPbSemitones = realToFrac (pbSemitones pb)
  }

-- ---------------------------------------------------------------------------
-- Foreign imports
-- ---------------------------------------------------------------------------

-- 'safe' (rather than 'unsafe') because rt_midi_demo_open allocates,
-- spawns a worker thread, and probes MIDI devices via Q/PortMIDI —
-- all of which can block briefly on syscalls. 'unsafe' would stall
-- the Haskell scheduler. The trivial counter / has_device accessors
-- below stay 'unsafe' since they're a single atomic load each.
foreign import ccall safe "rt_midi_demo_open"
  c_rt_midi_demo_open
    :: Ptr RTGraph
    -> CInt                         -- template_id
    -> CInt                         -- polyphony
    -> CInt                         -- midi_device_index (-1 = default)
    -> Ptr CVoiceMapping
    -> Ptr CCcMapping -> CInt       -- cc_mappings + count
    -> Ptr CPitchBendBinding        -- pitch_bend (nullPtr → unbound)
    -> CUShort                      -- channel_mask
    -> IO (Ptr CMidiDemo)

-- 'safe' because rt_midi_demo_close joins the worker thread (which
-- may sleep up to ~1 ms before observing the stop flag) and tears
-- down the MIDI input stream.
foreign import ccall safe "rt_midi_demo_close"
  c_rt_midi_demo_close :: Ptr CMidiDemo -> IO ()

foreign import ccall unsafe "rt_midi_demo_note_on_count"
  c_rt_midi_demo_note_on_count :: Ptr CMidiDemo -> IO CInt

foreign import ccall unsafe "rt_midi_demo_note_off_count"
  c_rt_midi_demo_note_off_count :: Ptr CMidiDemo -> IO CInt

foreign import ccall unsafe "rt_midi_demo_cc_count"
  c_rt_midi_demo_cc_count :: Ptr CMidiDemo -> IO CInt

foreign import ccall unsafe "rt_midi_demo_pitch_bend_count"
  c_rt_midi_demo_pitch_bend_count :: Ptr CMidiDemo -> IO CInt

foreign import ccall unsafe "rt_midi_demo_has_device"
  c_rt_midi_demo_has_device :: Ptr CMidiDemo -> IO CInt

-- ---------------------------------------------------------------------------
-- Public lifecycle
-- ---------------------------------------------------------------------------

-- | Open a live MIDI demo session over a loaded 'RTGraph'. Returns
-- 'Nothing' on hard failure (null graph, allocation failure, thread
-- spawn failure). Returns 'Just' even when no MIDI device is present,
-- in that case the worker stays idle and 'midiHasDevice' reports 0.
--
-- The caller retains ownership of the 'Ptr RTGraph' and must keep it
-- valid until 'closeMidiDemo' returns.
openMidiDemo
  :: Ptr RTGraph
  -> Int                     -- ^ template id
  -> Int                     -- ^ polyphony (clamped to >= 1 by the C side)
  -> Maybe Int               -- ^ MIDI device index; 'Nothing' = system default
  -> VoiceMapping
  -> [CCMapping]
  -> Maybe PitchBendBinding
  -> Word16                  -- ^ channel mask (0xFFFF = omni)
  -> IO (Maybe MidiDemo)
openMidiDemo g tid poly devIx vm ccs pb mask =
  with (toCVoiceMapping vm) $ \vmPtr ->
    withArrayLen (map toCCcMapping ccs) $ \nCc ccPtr ->
      withMaybe (toCPitchBendBinding <$> pb) $ \pbPtr -> do
        h <- c_rt_midi_demo_open g
                                  (fromIntegral tid)
                                  (fromIntegral poly)
                                  (maybe (-1) fromIntegral devIx)
                                  vmPtr
                                  ccPtr (fromIntegral nCc)
                                  pbPtr
                                  (fromIntegral mask)
        pure $! if h == nullPtr then Nothing else Just (MidiDemo h)

-- | Close a MIDI demo session: stops the worker thread, joins it,
-- tears down the MIDI input stream, and frees the handle. After
-- return the handle is invalid.
closeMidiDemo :: MidiDemo -> IO ()
closeMidiDemo (MidiDemo h) = c_rt_midi_demo_close h

-- | Bracketed wrapper around 'openMidiDemo' \/ 'closeMidiDemo'. Runs
-- the body with a live session and ensures the session is closed on
-- every exit path (normal return, exception, async cancel). When
-- 'openMidiDemo' returns 'Nothing', the body is invoked with
-- 'Nothing' and no session is created.
withMidiDemo
  :: Ptr RTGraph
  -> Int
  -> Int
  -> Maybe Int
  -> VoiceMapping
  -> [CCMapping]
  -> Maybe PitchBendBinding
  -> Word16
  -> (Maybe MidiDemo -> IO a)
  -> IO a
withMidiDemo g tid poly devIx vm ccs pb mask body =
  bracket
    (openMidiDemo g tid poly devIx vm ccs pb mask)
    (mapM_ closeMidiDemo)
    body

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

midiNoteOnCount :: MidiDemo -> IO Int
midiNoteOnCount (MidiDemo h) = fromIntegral <$> c_rt_midi_demo_note_on_count h

midiNoteOffCount :: MidiDemo -> IO Int
midiNoteOffCount (MidiDemo h) = fromIntegral <$> c_rt_midi_demo_note_off_count h

midiCcCount :: MidiDemo -> IO Int
midiCcCount (MidiDemo h) = fromIntegral <$> c_rt_midi_demo_cc_count h

midiPitchBendCount :: MidiDemo -> IO Int
midiPitchBendCount (MidiDemo h) = fromIntegral <$> c_rt_midi_demo_pitch_bend_count h

-- | True if the underlying @q::midi_input_stream@ opened a real MIDI
-- device. False on no-device boxes and during the very first ms after
-- open before the worker has snapshot the state.
midiHasDevice :: MidiDemo -> IO Bool
midiHasDevice (MidiDemo h) = (== 1) <$> c_rt_midi_demo_has_device h

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

withMaybe :: Storable a => Maybe a -> (Ptr a -> IO b) -> IO b
withMaybe Nothing  k = k nullPtr
withMaybe (Just a) k = with a k
