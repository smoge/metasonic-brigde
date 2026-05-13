-- |
-- Module      : MetaSonic.Session.Report
-- Description : Read-only session lifecycle reports.
--
-- This module provides producer-facing snapshots for the session
-- layer. It reads facts the runtime already exposes through
-- diagnostics counters and static metadata; it does not allocate
-- buffers, load plugins, install graphs, or mutate runtime state.
--
-- See [notes/2026-05-12-session-prep-a-contract.md].

module MetaSonic.Session.Report
  ( BufferLifecycleReport (..)
  , PluginLifecycleReport (..)
  , SessionLifecycleReport (..)
  , readBufferLifecycleReport
  , readPluginLifecycleReport
  , readSessionLifecycleReport
  ) where

import           Data.Word                (Word64)
import           Foreign.C.Types          (CLLong)
import           Foreign.Ptr              (Ptr)

import           MetaSonic.Bridge.FFI     (PluginRegistryEntry, RTGraph,
                                           c_rt_graph_test_buffer_invalid_read_count,
                                           c_rt_graph_test_buffer_invalid_write_count,
                                           c_rt_graph_test_buffer_read_count,
                                           c_rt_graph_test_buffer_write_count,
                                           c_rt_graph_test_invalid_plugin_call_count,
                                           c_rt_graph_test_plugin_call_count,
                                           pluginRegistryEntries)


-- | Buffer counters visible to a session owner. This is a snapshot,
-- not a buffer-slot inventory and not an allocation API.
data BufferLifecycleReport = BufferLifecycleReport
  { blrReadCount         :: !Word64
  , blrInvalidReadCount  :: !Word64
  , blrWriteCount        :: !Word64
  , blrInvalidWriteCount :: !Word64
  } deriving (Eq, Show)

-- | Static plugin metadata and dispatch counters visible to a session
-- owner. This is read-only registry/counter data; runtime nodes still
-- use integer plugin ids.
data PluginLifecycleReport = PluginLifecycleReport
  { plrRegistered       :: ![PluginRegistryEntry]
  , plrCallCount        :: !Word64
  , plrInvalidCallCount :: !Word64
  } deriving (Eq, Show)

-- | One read-only lifecycle snapshot across the resource surfaces
-- Session Prep A exposes.
data SessionLifecycleReport = SessionLifecycleReport
  { slrBuffers :: !BufferLifecycleReport
  , slrPlugins :: !PluginLifecycleReport
  } deriving (Eq, Show)

-- | Read buffer diagnostics counters from an existing runtime handle.
readBufferLifecycleReport :: Ptr RTGraph -> IO BufferLifecycleReport
readBufferLifecycleReport rt = do
  readCountRaw <- c_rt_graph_test_buffer_read_count rt
  invalidReads <- c_rt_graph_test_buffer_invalid_read_count rt
  writeCountRaw <- c_rt_graph_test_buffer_write_count rt
  invalidWrites <- c_rt_graph_test_buffer_invalid_write_count rt
  pure BufferLifecycleReport
    { blrReadCount         = counterWord64 readCountRaw
    , blrInvalidReadCount  = counterWord64 invalidReads
    , blrWriteCount        = counterWord64 writeCountRaw
    , blrInvalidWriteCount = counterWord64 invalidWrites
    }

-- | Read static plugin registry metadata and dispatch counters.
readPluginLifecycleReport :: Ptr RTGraph -> IO PluginLifecycleReport
readPluginLifecycleReport rt = do
  registered <- pluginRegistryEntries
  calls      <- c_rt_graph_test_plugin_call_count rt
  invalid    <- c_rt_graph_test_invalid_plugin_call_count rt
  pure PluginLifecycleReport
    { plrRegistered       = registered
    , plrCallCount        = counterWord64 calls
    , plrInvalidCallCount = counterWord64 invalid
    }

-- | Read every v1 session lifecycle report surface.
readSessionLifecycleReport :: Ptr RTGraph -> IO SessionLifecycleReport
readSessionLifecycleReport rt = do
  buffers <- readBufferLifecycleReport rt
  plugins <- readPluginLifecycleReport rt
  pure SessionLifecycleReport
    { slrBuffers = buffers
    , slrPlugins = plugins
    }

counterWord64 :: CLLong -> Word64
counterWord64 n
  | n <= 0    = 0
  | otherwise = fromIntegral n
