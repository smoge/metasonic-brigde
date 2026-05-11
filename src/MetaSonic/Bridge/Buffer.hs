{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Bridge.Buffer
-- Description : §6.C.3a producer-side mono buffer pool wrapper.
--
-- Thin IO wrapper around 'MetaSonic.Bridge.FFI''s buffer pool entry
-- points. The pure 'Buffer' identity newtype lives in
-- 'MetaSonic.Types' so the 'Source' DSL can carry it without
-- introducing an import cycle ('Source' is upstream of 'FFI', so
-- 'Source -> Buffer -> FFI -> Source' would close one); this module
-- imports both 'FFI' (for the C ABI) and 'Types' (for the
-- 'Buffer' newtype) and sits downstream of both.
--
-- v1 contract (§6.C.3a):
--
-- * Fixed-cap pool of 64 mono float32 buffers.
-- * Allocate, load, clear. No live-safe free; live retire/collect
--   lands in §6.C.3b.
-- * Errors surface as 'BufferIssue' via 'Control.Exception.throwIO'.
--
-- See 'MetaSonic.Bridge.Source.playBufMono' for the consumer-side
-- UGen and 'notes/2026-05-10-phase-6c2-buffer-io-contract.md' for
-- the full contract.

module MetaSonic.Bridge.Buffer
  ( -- * Allocation / load / clear (producer-side IO)
    allocBuffer
  , loadBuffer
  , clearBuffer
    -- * Errors
  , BufferIssue (..)
  ) where

import           Control.DeepSeq         (NFData)
import           Control.Exception       (Exception, throwIO)
import           Foreign.C.Types         (CFloat (..))
import           Foreign.Marshal.Array   (withArrayLen)
import           Foreign.Ptr             (Ptr)
import           GHC.Generics            (Generic)

import           MetaSonic.Bridge.FFI    (RTGraph, c_rt_graph_buffer_alloc,
                                          c_rt_graph_buffer_clear,
                                          c_rt_graph_buffer_load_f32)
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
  | BiUnknownBufferId !Int
    -- ^ 'rt_graph_buffer_load_f32' or 'rt_graph_buffer_clear'
    -- returned -1 because the given buffer ID is out of range or
    -- has not been allocated.
  | BiFrameCountExceedsBuffer !Int !Int
    -- ^ 'rt_graph_buffer_load_f32' returned -2 because the
    -- requested frame count exceeds the buffer's allocated frame
    -- count. Fields: requested, capacity.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData, Exception)

-- | Allocate a mono float32 buffer of @frames@ samples. Returns
-- the producer-side 'Buffer' handle on success. Throws
-- 'BiPoolFull' if the runtime's pool is at capacity.
--
-- Construction-only: must be called before
-- 'MetaSonic.Bridge.FFI.startAudio'. The underlying storage is
-- zero-initialised; load samples in with 'loadBuffer'.
allocBuffer :: Ptr RTGraph -> Int -> IO Buffer
allocBuffer rt frames = do
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
         | n == -2   -> throwIO (BiFrameCountExceedsBuffer len 0)
         | otherwise -> throwIO (BiUnknownBufferId bid)

-- | Mark a buffer unallocated. The underlying sample storage's
-- capacity is preserved for reuse on the next 'allocBuffer'.
--
-- UNSAFE to call while audio is running — the audio thread may
-- still be reading from this slot. §6.C.3a documents this as a
-- construction / stopped-audio operation; live-safe
-- retire/collect lands in §6.C.3b.
--
-- Throws 'BiUnknownBufferId' if the buffer is out of range or
-- already unallocated.
clearBuffer :: Ptr RTGraph -> Buffer -> IO ()
clearBuffer rt (Buffer bid) = do
  rc <- c_rt_graph_buffer_clear rt (fromIntegral bid)
  if rc /= 0
    then throwIO (BiUnknownBufferId bid)
    else pure ()
