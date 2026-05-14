{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Bridge.Buffer
-- Description : §6.C.3a/3b producer-side mono buffer pool wrapper.
--
-- Thin IO wrapper around 'MetaSonic.Bridge.FFI''s buffer pool entry
-- points. The pure 'Buffer' identity newtype lives in
-- 'MetaSonic.Types' so the 'Source' DSL can carry it without
-- introducing an import cycle ('Source' is upstream of 'FFI', so
-- 'Source -> Buffer -> FFI -> Source' would close one); this module
-- imports both 'FFI' (for the C ABI) and 'Types' (for the
-- 'Buffer' newtype) and sits downstream of both.
--
-- v1 contract (§6.C.3a/b):
--
-- * Fixed-cap pool of 64 mono float32 buffers, keyed off the
--   'RTGraph' handle so allocations survive 'rt_graph_clear'
--   and the prepare_swap / publish_swap cycle (§6.C.3b slice 1).
-- * Two API tiers:
--
--     * Stopped-audio fast path: 'allocBuffer', 'loadBuffer',
--       'clearBuffer'. Cheap, but unsafe to call while audio is
--       running (the audio thread may still be reading the slot
--       through a captured @samples.data()@ pointer).
--     * Live-safe lifecycle: 'retireBuffer' /
--       'collectRetiredBuffer' (§6.C.3b slice 2). Retire flips
--       the slot to the invalid-read path on the next block
--       without touching samples; collect releases the slot for
--       reuse once the audio thread has crossed a block
--       boundary (i.e. no captured pointer can survive).
--
-- * Errors surface as 'BufferIssue' via 'Control.Exception.throwIO'.
--
-- See 'MetaSonic.Bridge.Source.playBufMono' for the consumer-side
-- UGen and 'notes/2026-05-10-k-phase-6c2-buffer-io-contract.md' for
-- the read-path contract; lifetime work is in
-- 'notes/2026-05-11-a-phase-6c3b-lifetime-design.md'.

module MetaSonic.Bridge.Buffer
  ( -- * Allocation / load / clear (stopped-audio fast path)
    allocBuffer
  , loadBuffer
  , clearBuffer
    -- * Live-safe retire / collect (§6.C.3b slice 2)
  , retireBuffer
  , collectRetiredBuffer
    -- * Errors
  , BufferIssue (..)
  ) where

import           Control.DeepSeq         (NFData)
import           Control.Exception       (Exception, throwIO)
import           Foreign.C.Types         (CFloat (..), CInt)
import           Foreign.Marshal.Array   (withArrayLen)
import           Foreign.Ptr             (Ptr)
import           GHC.Generics            (Generic)

import           MetaSonic.Bridge.FFI    (RTGraph, c_rt_graph_buffer_alloc,
                                          c_rt_graph_buffer_clear,
                                          c_rt_graph_buffer_collect_retired,
                                          c_rt_graph_buffer_load_f32,
                                          c_rt_graph_buffer_retire)
import           MetaSonic.Types         (Buffer (..))

-- | Producer-side failure mode for the §6.C.3a buffer pool ABI.
-- Mirrors the issue patterns in 'MetaSonic.OSC.Dispatch' /
-- 'MetaSonic.Bridge.Templates': structured, machine-readable, with
-- a derived 'Exception' instance so the wrappers can use
-- 'throwIO' (matching how 'loadTemplateGraph' surfaces FFI
-- failures).
data BufferIssue
  = BiPoolFull
    -- ^ 'rt_graph_buffer_alloc' returned -1 because the pool is at
    -- capacity (64 buffers allocated).
  | BiInvalidFrameCount !Int
    -- ^ 'allocBuffer' rejected the requested frame count before
    -- crossing the FFI: either negative or larger than 'maxBound ::
    -- CInt'. Holds the rejected value. This is a wrapper-side check
    -- so the underlying C ABI never has to decide what a negative or
    -- overflowed @int@ means.
  | BiUnknownBufferId !Int
    -- ^ 'rt_graph_buffer_load_f32' or 'rt_graph_buffer_clear'
    -- returned -1 because the given buffer ID is out of range or
    -- has not been allocated.
  | BiFrameCountExceedsBuffer !Int
    -- ^ 'rt_graph_buffer_load_f32' returned -2 because the
    -- requested frame count exceeds the buffer's allocated frame
    -- count. Field: requested. (The buffer's capacity is not
    -- exposed across the FFI in 6.C.3a; report only what the
    -- producer asked for to avoid lying about a value we can't
    -- read.)
  | BiNotRetired !Int
    -- ^ 'collectRetiredBuffer' returned -1 because the slot is
    -- not currently in the @Retired@ state — the producer
    -- called 'collectRetiredBuffer' without a preceding
    -- 'retireBuffer'. Holds the offending buffer id.
  | BiCollectStillLive !Int
    -- ^ 'collectRetiredBuffer' returned -2 because the audio
    -- thread has not crossed a block boundary since the matching
    -- 'retireBuffer'. The producer must drive at least one more
    -- 'MetaSonic.Bridge.FFI.c_rt_graph_process' (or wait for one
    -- audio callback) before retrying. Holds the buffer id.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData, Exception)

-- | Allocate a mono float32 buffer of @frames@ samples. Returns
-- the producer-side 'Buffer' handle on success. Throws
-- 'BiInvalidFrameCount' if @frames@ is negative or larger than
-- 'maxBound :: CInt' (so the wrapper never silently truncates),
-- or 'BiPoolFull' if the runtime's pool is at capacity.
--
-- Construction-only: must be called before
-- 'MetaSonic.Bridge.FFI.startAudio'. The underlying storage is
-- zero-initialised; load samples in with 'loadBuffer'.
allocBuffer :: Ptr RTGraph -> Int -> IO Buffer
allocBuffer rt frames
  | frames < 0
    = throwIO (BiInvalidFrameCount frames)
  | fromIntegral frames > (fromIntegral (maxBound :: CInt) :: Integer)
    = throwIO (BiInvalidFrameCount frames)
  | otherwise = do
      rc <- c_rt_graph_buffer_alloc rt (fromIntegral frames)
      if rc < 0
        then throwIO BiPoolFull
        else pure (Buffer (fromIntegral rc))

-- | Copy a list of float samples into an allocated buffer,
-- starting at frame 0. Throws 'BiUnknownBufferId' if the buffer
-- has not been allocated (or was cleared), or
-- 'BiFrameCountExceedsBuffer' if the list length exceeds the
-- buffer's capacity.
--
-- The wrapper marshals @[Float]@ on the fly via
-- 'Foreign.Marshal.Array.withArrayLen'. v1 callers use 256 –
-- a-few-thousand-sample tables; the list-traversal cost is
-- irrelevant. Switching to 'ForeignPtr Float' or a 'Vector Float'
-- is a one-line change here if a large-sample consumer ever
-- appears.
loadBuffer :: Ptr RTGraph -> Buffer -> [Float] -> IO ()
loadBuffer rt (Buffer bid) samples =
  withArrayLen (map CFloat samples) $ \len ptr -> do
    rc <- c_rt_graph_buffer_load_f32 rt
            (fromIntegral bid)
            ptr
            (fromIntegral len)
    case fromIntegral rc :: Int of
      n  | n == len  -> pure ()
         | n == -1   -> throwIO (BiUnknownBufferId bid)
         | n == -2   -> throwIO (BiFrameCountExceedsBuffer len)
         | otherwise -> throwIO (BiUnknownBufferId bid)

-- | Stopped-audio fast path: flip an allocated buffer back to
-- the @Unallocated@ state. The underlying sample storage's
-- capacity is preserved for reuse on the next 'allocBuffer'.
--
-- UNSAFE to call while audio is running — the audio thread may
-- still be holding a @samples.data()@ pointer captured at the
-- top of the current block. For the live-safe path, use
-- 'retireBuffer' (which flips the slot to @Retired@ without
-- touching samples) followed by 'collectRetiredBuffer' once
-- the audio thread has crossed a block boundary.
--
-- Refuses to clear a slot that is currently @Retired@: callers
-- must drive the slot through 'collectRetiredBuffer' first.
-- Both error paths raise 'BiUnknownBufferId' with the offending
-- buffer id (the C ABI does not distinguish "out of range",
-- "already unallocated", and "currently retired" — they all
-- mean "not currently Allocated", which the wrapper exposes as
-- the same exception).
clearBuffer :: Ptr RTGraph -> Buffer -> IO ()
clearBuffer rt (Buffer bid) = do
  rc <- c_rt_graph_buffer_clear rt (fromIntegral bid)
  if rc /= 0
    then throwIO (BiUnknownBufferId bid)
    else pure ()

-- | §6.C.3b slice 2 live-safe drop. Flip an allocated buffer to
-- the @Retired@ state. From the next block onward, every
-- PlayBufMono kernel that resolved this buffer id sees state ==
-- @Retired@ through an acquire-load and takes the invalid-read
-- path (emit zero, tick @buffer_invalid_read_count@). The
-- slot's sample storage is /not/ touched — the audio thread may
-- still be holding a @samples.data()@ pointer captured before
-- the retire, and that pointer must remain valid until the
-- block completes.
--
-- A retired slot stays retired until 'collectRetiredBuffer'
-- succeeds; 'allocBuffer' will not reuse the slot in the
-- meantime. Throws 'BiUnknownBufferId' if the buffer id is out
-- of range or the slot is not currently @Allocated@.
--
-- Single-producer: 'retireBuffer' and 'collectRetiredBuffer'
-- form an SPSC pair. Concurrent calls from multiple threads
-- would race on the slot's generation-snapshot field.
retireBuffer :: Ptr RTGraph -> Buffer -> IO ()
retireBuffer rt (Buffer bid) = do
  rc <- c_rt_graph_buffer_retire rt (fromIntegral bid)
  if rc /= 0
    then throwIO (BiUnknownBufferId bid)
    else pure ()

-- | §6.C.3b slice 2 live-safe reap. If the audio thread has
-- crossed at least one block boundary since the matching
-- 'retireBuffer' (so no captured @samples.data()@ pointer can
-- survive), transition the slot back to @Unallocated@; storage
-- capacity is preserved for the next 'allocBuffer'.
--
-- Throws 'BiNotRetired' if the slot is not currently
-- @Retired@ (i.e. there's no matching 'retireBuffer' to
-- collect). Throws 'BiCollectStillLive' if the slot IS
-- @Retired@ but the audio thread has not advanced a block
-- since: the producer should drive at least one more
-- 'MetaSonic.Bridge.FFI.c_rt_graph_process' (or wait for one
-- audio callback) and retry.
collectRetiredBuffer :: Ptr RTGraph -> Buffer -> IO ()
collectRetiredBuffer rt (Buffer bid) = do
  rc <- c_rt_graph_buffer_collect_retired rt (fromIntegral bid)
  case fromIntegral rc :: Int of
    0  -> pure ()
    -1 -> throwIO (BiNotRetired bid)
    -2 -> throwIO (BiCollectStillLive bid)
    _  -> throwIO (BiNotRetired bid)
