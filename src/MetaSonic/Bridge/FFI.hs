-- |
-- Module      : MetaSonic.FFI
-- Description : Transfer compiled graphs to the C++ runtime and manage realtime audio
--
-- The border crossing between the Haskell compiler and the
-- C++ runtime. Only dense, fully compiled structure crosses
-- this boundary.
--
-- See Note [FFI boundary design] for the protocol.
-- See Note [Two-pass loading] for why loadRuntimeGraph uses
-- separate add and wire passes.
-- See Note [Realtime audio lifecycle] for how q_io / PortAudio
-- startup is exposed on the Haskell side.

module MetaSonic.Bridge.FFI
  ( -- * Opaque handle
    RTGraph
  , RTGraphSwap
  , BuilderCapacity
  , MaxFrames
  , TimeoutMs
  , SwapGeneration
  , SwapMigrationStats (..)
  , HotSwapWaitResult (..)
  , -- * Lifecycle
    withRTGraph
  , c_rt_graph_capacity
  , c_rt_graph_max_frames
  , c_rt_graph_audio_running
  , -- * Loading a compiled graph (single-template, legacy)
    loadRuntimeGraph
  , loadRuntimeGraphFused
  , -- * Loading a compiled template graph (multi-template, §2.D.3)
    loadTemplateGraph
  , loadTemplateGraphWithAutoSpawns
  , loadTemplateGraphFused
  , -- * Phase 5.3 hot-swap producer helpers
    hotSwapRuntimeGraph
  , hotSwapRuntimeGraphFused
  , hotSwapTemplateGraph
  , hotSwapTemplateGraphFused
  , collectRetiredSwapStats
  , readSwapGeneration
  , waitForSwapGeneration
  , hotSwapRuntimeGraphAndWait
  , hotSwapRuntimeGraphFusedAndWait
  , hotSwapTemplateGraphAndWait
  , hotSwapTemplateGraphFusedAndWait
  , -- * Realtime audio lifecycle
    startAudio
  , waitAudioStarted
  , stopAudio
  , -- * Introspection
    PluginRegistryEntry (..)
  , pluginRegistryEntries
  , c_rt_graph_plugin_count
  , c_rt_graph_plugin_find
  , c_rt_graph_plugin_name
  , c_rt_graph_plugin_audio_in_count
  , c_rt_graph_plugin_audio_out_count
  , c_rt_graph_plugin_latency_samples
  , c_rt_graph_plugin_state_size_bytes
  , -- * Kind/kernel support probes
    c_rt_graph_kind_supported
  , c_rt_graph_region_kernel_supported
  , -- * §4.E.2.B test surface (off by default; tests opt in)
    c_rt_graph_test_set_reduction_capture
  , -- * §4.E.2.C0c schedule-executor test switch
    c_rt_graph_test_set_global_schedule_execution
  , -- * §4.E.2.C1 worker-pool test surface
    c_rt_graph_test_set_worker_pool_size
  , c_rt_graph_test_worker_pool_size
  , c_rt_graph_test_worker_thread_count
  , c_rt_graph_test_last_parallel_band_count
  , c_rt_graph_test_last_parallel_entry_count
  , c_rt_graph_test_last_serialized_free_band_count
  , c_rt_graph_test_last_c1d_parallel_entry_count
  , c_rt_graph_test_last_c1d_parallel_region_item_count
  , -- * §7.I super-mode classifier (test-only introspection)
    c_rt_graph_test_fusion_program_super_kind
  , -- * §4.E.2.C0a layered-schedule metadata (test-only introspection)
    c_rt_graph_test_template_schedule_step_count
  , c_rt_graph_test_template_schedule_step_kind
  , c_rt_graph_test_template_schedule_step_item_count
  , c_rt_graph_test_template_schedule_step_region
  , -- * §4.E.2.C0b global block schedule (test-only introspection)
    c_rt_graph_test_global_schedule_entry_count
  , c_rt_graph_test_global_schedule_entry_template
  , c_rt_graph_test_global_schedule_entry_instance
  , c_rt_graph_test_global_schedule_entry_step
  , -- * §4.E.2.C0d global schedule bands (test-only introspection)
    c_rt_graph_test_global_schedule_band_count
  , c_rt_graph_test_global_schedule_band_kind
  , c_rt_graph_test_global_schedule_band_first_entry
  , c_rt_graph_test_global_schedule_band_entry_count
  , -- * Low-level (re-exported for tests / experimentation)
    c_rt_graph_process
  , c_rt_graph_read_bus
  , c_rt_graph_clear
  , c_rt_graph_start_audio
  , c_rt_graph_wait_started
  , c_rt_graph_stop_audio
  , -- * Phase 5.1/5.2 low-level hot-swap ABI
    c_rt_graph_prepare_swap
  , c_rt_graph_prepare_swap_from_graph
  , c_rt_graph_cancel_swap
  , c_rt_graph_publish_swap
  , c_rt_graph_collect_retired_swap
  , c_rt_graph_test_swap_generation
  , c_rt_graph_test_swap_pending
  , c_rt_graph_test_swap_retired_pending
  , c_rt_graph_swap_migration_committed_count
  , c_rt_graph_swap_migration_skipped_count
  , c_rt_graph_swap_migration_instance_copy_count
  , c_rt_graph_swap_migration_state_copy_count
  , c_rt_graph_swap_migration_lifecycle_copy_count
  , -- * Multi-template low-level (re-exported for tests)
    c_rt_graph_template_add
  , c_rt_graph_template_count
  , c_rt_graph_template_set_polyphony
  , c_rt_graph_template_add_node
  , c_rt_graph_ensure_bus
  , c_rt_graph_template_set_default
  , c_rt_graph_template_set_node_migration_key
  , c_rt_graph_template_set_identity
  , c_rt_graph_template_connect
  , c_rt_graph_template_add_region
  , c_rt_graph_template_add_schedule_step
  , c_rt_graph_template_set_node_elided
  , c_rt_graph_template_connect_fused_scale_input
  , c_rt_graph_template_connect_fused_scale_chain_input
  , c_rt_graph_template_connect_fused_affine_input
  , c_rt_graph_template_instance_add
  , c_rt_graph_instance_remove
  , c_rt_graph_instance_release
  , c_rt_graph_instance_status
  , c_rt_graph_instance_count
  , c_rt_graph_instance_alive
  , c_rt_graph_instance_set_control
  , -- * A.2 realtime control queue ABI (single-producer; safe while audio runs)
    c_rt_graph_realtime_reserve
  , c_rt_graph_realtime_cancel
  , c_rt_graph_realtime_activate
  , c_rt_graph_realtime_release
  , c_rt_graph_realtime_remove
  , c_rt_graph_realtime_set_control
  , -- * §6.C.3a buffer pool ABI
    c_rt_graph_buffer_alloc
  , c_rt_graph_buffer_load_f32
  , c_rt_graph_buffer_clear
  , -- * §6.C.3b slice 2 live-safe retire / collect
    c_rt_graph_buffer_retire
  , c_rt_graph_buffer_collect_retired
  , c_rt_graph_test_buffer_read_count
  , c_rt_graph_test_buffer_invalid_read_count
  , -- * §6.C.4 follow-up writer counters
    c_rt_graph_test_buffer_write_count
  , c_rt_graph_test_buffer_invalid_write_count
  , -- * §6.D spectral counters
    c_rt_graph_test_spectral_analysis_count
  , c_rt_graph_test_spectral_resynthesis_count
  , -- * §6.E plugin dispatch counters
    c_rt_graph_test_plugin_call_count
  , c_rt_graph_test_invalid_plugin_call_count
  , -- * §2.E lifecycle status values (mirroring rt_graph.h's InstanceStatus)
    instanceStatusLive
  , instanceStatusReleasing
  ) where

import           Control.Concurrent        (threadDelay)
import           Control.Exception          (bracket)
import qualified Control.Monad              as M (void)
import           Control.Monad              (forM, forM_, unless, when)
import qualified Data.Set                  as S
import           Foreign
import           Foreign.C.String          (CString, peekCString, withCAStringLen)
import           Foreign.C.Types
import           System.Timeout             (timeout)

import           MetaSonic.Bridge.Compile   (AffineStep (..),
                                             FreeLayer (..),
                                             FusedInput (..),
                                             RegionExec (..),
                                             RegionKernel (..),
                                             RuntimeGraph (..),
                                             RuntimeInput (..),
                                             RuntimeNode (..),
                                             RuntimeRegion (..),
                                             ScaleRef (..),
                                             ScheduleStep (..),
                                             kernelTag,
                                             layeredRegionSchedule,
                                             rrKernel,
                                             scheduledRuntimeRegions)
import           MetaSonic.Bridge.Compile.FusionProgram
                                            (FusionOp (..),
                                             FusionProgram (..),
                                             FusionProgramId (..),
                                             FusionSource (..),
                                             ScratchIndex (..))
import           MetaSonic.Bridge.Source    (MigrationKey (..),
                                             migrationKeyUtf8Bytes)
import           MetaSonic.Bridge.Templates (BufferFootprint (..),
                                             ResourceFootprint (..),
                                             Template (..),
                                             TemplateGraph (..))
import           MetaSonic.Types


{- Note [FFI boundary design]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
On the Haskell side, the graph is a rich, typed, annotated structure
with symbolic identities, rate tags, effect annotations, and region
membership. On the C++ side, it is a flat array of execution units
with dense index references.

This module translates between those two worlds through a small C ABI
defined in rt_graph.h:

  rt_graph_create       — allocate a runtime graph handle
  rt_graph_destroy      — free all owned resources
  rt_graph_clear        — reset for reloading
  rt_graph_add_node     — register a node at a dense index
  rt_graph_set_control  — set a control value
  rt_graph_connect      — wire one output port to one input
  rt_graph_process      — execute one offline audio block
  rt_graph_start_audio  — open q_io / PortAudio output
  rt_graph_wait_started — wait until the callback has run
  rt_graph_stop_audio   — stop realtime audio

The protocol is:

  1. rt_graph_create(capacity, max_frames)
  2. rt_graph_clear(g)
  3. For each node in execution order:
     a. rt_graph_add_node(g, index, kind)
     b. rt_graph_set_control(g, index, slot, value)
  4. For each connection:
     rt_graph_connect(g, src, src_port, dst, dst_port)
  5. Either:
     a. Repeat: rt_graph_process(g, nframes)
        for offline / test rendering, or
     b. rt_graph_start_audio(g, output_channels, device_id)
        rt_graph_wait_started(g, timeout_ms)
        ... let the C++ callback drive the engine ...
        rt_graph_stop_audio(g)
  6. rt_graph_destroy(g)

Steps 2–4 are performed by loadRuntimeGraph.
Step 5a is used by tests, diagnostics, and offline checking.
Step 5b is the realtime path for q_io / PortAudio output.
Steps 1 and 6 are managed by withRTGraph via bracket.

The integer-based wire format (node kinds as ints, indices as ints,
controls as doubles) is deliberately simple: it avoids any C++ types
in the ABI, ensuring that the boundary is portable and trivially
serializable.

Graph loading is expected to succeed by construction. If the Haskell
compiler produces a valid RuntimeGraph, no bad-index or unknown-kind
paths should fire in the runtime. Realtime startup is different:
opening an audio device can fail for reasons outside compilation (no
device, unsupported channel count, backend error), so the audio
lifecycle calls return status codes.

See Note [Dense lowering] in MetaSonic.Compile for what
guarantees the runtime indices are valid.
-}


{- Note [Why ccall, not capi]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
These imports use ccall, not capi.

That is intentional. The C++ side exports plain C ABI symbols from
rt_graph.h via extern "C". There is no varargs API, no macro
indirection, and no need to route through a C wrapper header. capi
would work too, but it would not buy us anything for this ABI.

The important distinction for this module is not ccall vs capi. It is
unsafe vs safe, described below.
-}

{- Note [Mixed foreign call safety]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
This module intentionally mixes unsafe and safe foreign
imports.

Use unsafe when the C++ function is short-lived, synchronous,
and does not block:

  * rt_graph_create
  * rt_graph_add_node
  * rt_graph_set_control
  * rt_graph_connect
  * rt_graph_process

These calls are either graph-loading setup work or tight DSP
entry points. In particular, rt_graph_process is expected to
be called at audio-block frequency in tests and offline
rendering, so avoiding safe-call overhead is worthwhile.

Use safe when the C++ function may block, may wait for the
operating system or audio backend, or may need to tear down a
live stream:

  * rt_graph_destroy
  * rt_graph_clear
  * rt_graph_start_audio
  * rt_graph_wait_started
  * rt_graph_stop_audio
  * rt_graph_prepare_swap_from_graph
  * rt_graph_cancel_swap

A subtle but important consequence of the new realtime path is that
rt_graph_clear and rt_graph_destroy are no longer obviously "cheap":
the C++ runtime is allowed to stop an active PortAudio stream inside
them before clearing or freeing state. That makes safe the correct
default on the Haskell side.

Note that safe does NOT mean "wait until the audio callback is ready".
Readiness is a separate protocol step handled by
rt_graph_wait_started. The audio callback itself remains fully inside
C++; it does not call back into Haskell.
-}

{- Note [Two-pass loading]
~~~~~~~~~~~~~~~~~~~~~~~~~~
loadRuntimeGraph proceeds in two passes:

  Pass 1 — add nodes:
    Register each RuntimeNode at its dense index with the
    correct kind tag (via rt_graph_add_node) and set each
    control to its default value (via rt_graph_set_control).

  Pass 2 — wire connections:
    For each RFrom input on each node, emit a rt_graph_connect
    call linking the source output port to the destination
    input port.

The two-pass structure is necessary because rt_graph_connect requires
both the source and destination nodes to already exist in the C++
graph. Since nodes are added in execution order (source before
destination, guaranteed by Note [Execution order invariant] in
MetaSonic.IR), pass 1 ensures all endpoints exist before pass 2 wires
them.

RConst inputs do not generate connect calls. Their values are already
set as control defaults in pass 1.

One more consequence of the realtime engine: loadRuntimeGraph begins
with rt_graph_clear, and rt_graph_clear is allowed to stop a currently
running audio stream. So loadRuntimeGraph is a "stop, clear, rebuild"
operation from the runtime's point of view. Callers that need the
block-boundary hot-swap protocol should use the Phase 5.3 helper
family (hotSwapRuntimeGraph, hotSwapTemplateGraph, and fused
siblings), which builds a separate offline world and publishes it
through rt_graph_prepare_swap_from_graph / rt_graph_publish_swap.
-}

-- | Opaque handle to the C++ runtime graph. The Haskell side never
-- inspects its contents.
--
-- See Note [FFI boundary design].
data RTGraph

-- | Opaque handle to a prepared or retired C++ runtime world swap.
-- The Haskell side never inspects it directly; public helpers either
-- publish it or collect/cancel it through the C ABI.
data RTGraphSwap

-- | Advisory pre-allocation capacity passed to 'withRTGraph'.
--
-- This is a type alias, not a safety boundary. It labels the public
-- hot-swap helper surface while keeping the C ABI and existing call
-- sites simple. Promote to a newtype if producer-side misuse becomes
-- a real problem.
type BuilderCapacity = Int

-- | Maximum frame count accepted by 'c_rt_graph_process'.
-- Shared by 'withRTGraph' and hot-swap helpers; not 5.3-only.
type MaxFrames = Int

-- | Producer-side wait timeout in milliseconds. Negative waits
-- indefinitely; zero performs one non-blocking poll.
type TimeoutMs = Int

-- | Haskell-side install-generation value. The raw C ABI counter is
-- 'CInt'; helper wrappers convert at the FFI boundary so callers do
-- not have to traffic in C integer widths.
type SwapGeneration = Int

-- | Phase 5.2 migration counters observed on a collected swap just
-- before the Haskell helper disposes it. Counts are representative of
-- the audio-thread install that consumed the swap.
data SwapMigrationStats = SwapMigrationStats
  { smsCommittedCount      :: !Int
  , smsSkippedCount        :: !Int
  , smsInstanceCopyCount   :: !Int
  , smsStateCopyCount      :: !Int
  , smsLifecycleCopyCount  :: !Int
  } deriving (Eq, Show)

-- | Result of the 5.3.B publish + wait + collect helpers.
data HotSwapWaitResult
  = HotSwapPublishRejected
    -- ^ Publish failed; the helper cancelled the prepared swap.
  | HotSwapInstallTimedOut
    -- ^ Publish succeeded, but generation did not advance in time.
  | HotSwapInstalled !SwapMigrationStats
    -- ^ The swap installed and the retired world was collected.
  | HotSwapInstalledButRetiredMissing
    -- ^ Defensive for future multi-collector code. Under the v1
    -- single-producer/single-collector model this should not occur.
  deriving (Eq, Show)

-- | One row from the build-linked static plugin registry.
--
-- This is read-only producer-side metadata. Runtime nodes still
-- receive only the integer plugin id; the audio thread never resolves
-- names through the registry.
data PluginRegistryEntry = PluginRegistryEntry
  { pluginEntryId             :: !Int
  , pluginEntryName           :: !String
  , pluginEntryAudioInputs    :: !Int
  , pluginEntryAudioOutputs   :: !Int
  , pluginEntryLatencySamples :: !Int
  , pluginEntryStateBytes     :: !Int
  } deriving (Eq, Show)

-- Foreign imports.
-- See Note [Why ccall, not capi].
-- See Note [Mixed foreign call safety].

foreign import ccall unsafe "rt_graph_create"
  c_rt_graph_create :: CInt -> CInt -> IO (Ptr RTGraph)

foreign import ccall safe "rt_graph_destroy"
  c_rt_graph_destroy :: Ptr RTGraph -> IO ()

foreign import ccall safe "rt_graph_clear"
  c_rt_graph_clear :: Ptr RTGraph -> IO ()

foreign import ccall unsafe "rt_graph_add_node"
  c_rt_graph_add_node :: Ptr RTGraph -> CInt -> CInt -> IO ()

foreign import ccall unsafe "rt_graph_set_control"
  c_rt_graph_set_control :: Ptr RTGraph -> CInt -> CInt -> CDouble -> IO ()

-- | Grow the shared Server bus pool to cover @bus_index@.
-- Construction-only, must run before audio starts. The Haskell
-- loaders ('loadRuntimeGraph', 'loadTemplateGraph') call this for
-- every bus-using node before configuring controls.
foreign import ccall unsafe "rt_graph_ensure_bus"
  c_rt_graph_ensure_bus :: Ptr RTGraph -> CInt -> IO ()

-- | If @node@ is a bus-using kind (Out / BusOut / BusIn / BusInDelayed),
-- return the bus index taken from control 0. Otherwise 'Nothing'.
-- Used by the loaders to size the bus pool before any control writes.
busIndexOf :: RuntimeNode -> Maybe Int
busIndexOf node
  | kindUsesBus (rnKind node)
  , (v : _) <- rnControls node
  , v >= 0
  = Just (truncate v)
  | otherwise
  = Nothing
  where
    kindUsesBus KOut          = True
    kindUsesBus KBusOut       = True
    kindUsesBus KBusIn        = True
    kindUsesBus KBusInDelayed = True
    kindUsesBus _             = False

setMigrationKeyForNode :: Ptr RTGraph -> CInt -> RuntimeNode -> IO ()
setMigrationKeyForNode g cTid node =
  case rnMigrationKey node of
    Nothing -> pure ()
    Just migrationKey@(MigrationKey key) ->
      withCAStringLen (migrationKeyUtf8Bytes migrationKey) $ \(ptr, len) -> do
        ok <- c_rt_graph_template_set_node_migration_key
          g cTid
          (cNodeIndex (rnIndex node))
          ptr
          (fromIntegral len)
        when (ok == 0) $
          fail $
            "rt_graph_template_set_node_migration_key rejected key "
            <> show key <> " for node " <> show (rnIndex node)

-- | Phase 5.4.B helper. Encode a template name as the byte token used
-- by 'c_rt_graph_template_set_identity'. Empty names opt out of the
-- runtime precondition. Non-empty names must satisfy the runtime's
-- fixed-width identity contract.
--
-- This validation is deliberately separated from the C setter so
-- 'loadTemplateGraph' and 'loadTemplateGraphFused' can run it before
-- 'c_rt_graph_clear'. A bad template identity must fail without
-- disturbing the currently loaded graph.
templateIdentityBytesFromName :: String -> String -> IO (Maybe String)
templateIdentityBytesFromName loaderName name
  | null name = pure Nothing
  | otherwise = do
      let bytes = migrationKeyUtf8Bytes (MigrationKey name)
          n    = length bytes
      when (n > 16) $
        fail $
          loaderName <> ": template name " <> show name
          <> " encodes to " <> show n
          <> " bytes; rt_graph_template_set_identity rejects > 16."
      when (any (== '\NUL') bytes) $
        fail $
          loaderName <> ": template name " <> show name
          <> " contains a NUL byte after UTF-8 encoding; "
          <> "rt_graph_template_set_identity rejects NUL."
      pure (Just bytes)

-- | Ship a prevalidated Phase 5.4.B template identity token through
-- the C ABI. The token is validated before clearing the target graph;
-- this setter step only reports unexpected ABI rejection.
setTemplateIdentityBytes
  :: Ptr RTGraph -> CInt -> String -> Maybe String -> IO ()
setTemplateIdentityBytes _ _ _ Nothing = pure ()
setTemplateIdentityBytes g cTid name (Just bytes) =
  withCAStringLen bytes $ \(ptr, len) -> do
    ok <- c_rt_graph_template_set_identity
      g cTid ptr (fromIntegral len)
    when (ok == 0) $
      fail $
        "rt_graph_template_set_identity rejected "
        <> show name <> " for template " <> show cTid

-- | §6.C.5: buffer-writer templates must be monophonic. The §6.C.4
-- check already rejects two templates writing the same buffer, but
-- the runtime polyphony cap (default 8) would otherwise let a single
-- writer template spawn N live instances, all frozen to the same
-- buffer id at instance reset. Slot order would then decide the
-- per-block winner — exactly the implicit observable ordering §6.C.4
-- declined to pin. Clamping cap=1 closes that gap; lifting it is a
-- §6.C.5+ feature gated on a real mixdown/ordering primitive.
--
-- The C++ runtime also enforces the same invariant on the public
-- C ABI (see Note [§6.C.5 single-writer-single-instance invariant]
-- in rt_graph.cpp): rt_graph_template_add_node clamps the cap when
-- a writer kind is added, and rt_graph_template_set_polyphony
-- refuses to raise it past 1 once a writer is present. The Haskell
-- clamp is the *declarative* expression of the rule at the compiler
-- boundary; the runtime backstop catches any direct-ABI caller that
-- never goes through these loaders.
--
-- Non-writer templates are left at their default cap.
clampWriterPolyphony :: Ptr RTGraph -> CInt -> Template -> IO ()
clampWriterPolyphony g cTid tpl =
  unless (S.null (bfBufWrites (rfBuffers (tplFootprint tpl)))) $
    c_rt_graph_template_set_polyphony g cTid 1

-- | §6.C.5 follow-up: 'clampWriterPolyphony' for single-template
-- loaders, which never build a 'Template' / 'ResourceFootprint' and
-- only have a 'RuntimeGraph' in hand. Same rule, different access
-- path: look at the dense node list directly. Today
-- 'KRecordBufMono' is the only buffer writer; the helper is
-- centralised so adding another writer kind is one edit.
clampWriterPolyphonyRG :: Ptr RTGraph -> CInt -> RuntimeGraph -> IO ()
clampWriterPolyphonyRG g cTid rg =
  when (any (\n -> rnKind n == KRecordBufMono) (rgNodes rg)) $
    c_rt_graph_template_set_polyphony g cTid 1

foreign import ccall unsafe "rt_graph_connect"
  c_rt_graph_connect :: Ptr RTGraph -> CInt -> CInt -> CInt -> CInt -> IO ()

foreign import ccall unsafe "rt_graph_process"
  c_rt_graph_process :: Ptr RTGraph -> CInt -> IO ()

foreign import ccall unsafe "rt_graph_capacity"
  c_rt_graph_capacity :: Ptr RTGraph -> IO CInt

foreign import ccall unsafe "rt_graph_max_frames"
  c_rt_graph_max_frames :: Ptr RTGraph -> IO CInt

foreign import ccall unsafe "rt_graph_audio_running"
  c_rt_graph_audio_running :: Ptr RTGraph -> IO CInt

foreign import ccall safe "rt_graph_start_audio"
  c_rt_graph_start_audio :: Ptr RTGraph -> CInt -> CInt -> IO CInt

foreign import ccall safe "rt_graph_wait_started"
  c_rt_graph_wait_started :: Ptr RTGraph -> CInt -> IO CInt

foreign import ccall safe "rt_graph_stop_audio"
  c_rt_graph_stop_audio :: Ptr RTGraph -> IO ()

-- | Allocate an empty next-world swap for the target. Low-level ABI:
-- callers own the returned pointer until cancel or successful publish.
foreign import ccall safe "rt_graph_prepare_swap"
  c_rt_graph_prepare_swap :: Ptr RTGraph -> IO (Ptr RTGraphSwap)

-- | Move an offline builder graph's swappable world into a prepared
-- swap for the target. Potentially walks graph metadata and allocates
-- the migration plan, so this import is safe.
foreign import ccall safe "rt_graph_prepare_swap_from_graph"
  c_rt_graph_prepare_swap_from_graph
    :: Ptr RTGraph -> Ptr RTGraph -> IO (Ptr RTGraphSwap)

-- | Dispose an unpublished or collected swap off-audio.
foreign import ccall safe "rt_graph_cancel_swap"
  c_rt_graph_cancel_swap :: Ptr RTGraph -> Ptr RTGraphSwap -> IO ()

-- | Publish a prepared swap to be installed at the next block
-- boundary. Returns 1 on success, 0 if the target already has a swap
-- pending/installing/retired.
foreign import ccall unsafe "rt_graph_publish_swap"
  c_rt_graph_publish_swap :: Ptr RTGraph -> Ptr RTGraphSwap -> IO CInt

-- | Collect an installed retired swap, if any. Returned pointer must
-- be disposed with c_rt_graph_cancel_swap.
foreign import ccall unsafe "rt_graph_collect_retired_swap"
  c_rt_graph_collect_retired_swap :: Ptr RTGraph -> IO (Ptr RTGraphSwap)

foreign import ccall unsafe "rt_graph_swap_generation"
  c_rt_graph_swap_generation :: Ptr RTGraph -> IO CInt

foreign import ccall unsafe "rt_graph_test_swap_generation"
  c_rt_graph_test_swap_generation :: Ptr RTGraph -> IO CInt

foreign import ccall unsafe "rt_graph_test_swap_pending"
  c_rt_graph_test_swap_pending :: Ptr RTGraph -> IO CInt

foreign import ccall unsafe "rt_graph_test_swap_retired_pending"
  c_rt_graph_test_swap_retired_pending :: Ptr RTGraph -> IO CInt

foreign import ccall unsafe "rt_graph_swap_migration_committed_count"
  c_rt_graph_swap_migration_committed_count :: Ptr RTGraphSwap -> IO CInt

foreign import ccall unsafe "rt_graph_swap_migration_skipped_count"
  c_rt_graph_swap_migration_skipped_count :: Ptr RTGraphSwap -> IO CInt

foreign import ccall unsafe "rt_graph_swap_migration_instance_copy_count"
  c_rt_graph_swap_migration_instance_copy_count :: Ptr RTGraphSwap -> IO CInt

foreign import ccall unsafe "rt_graph_swap_migration_state_copy_count"
  c_rt_graph_swap_migration_state_copy_count :: Ptr RTGraphSwap -> IO CInt

foreign import ccall unsafe "rt_graph_swap_migration_lifecycle_copy_count"
  c_rt_graph_swap_migration_lifecycle_copy_count :: Ptr RTGraphSwap -> IO CInt

-- | Pure switch dispatch on the C++ side: no allocation, no blocking,
-- no graph state needed. 'unsafe' is correct.
foreign import ccall unsafe "rt_graph_kind_supported"
  c_rt_graph_kind_supported :: CInt -> IO CInt

-- | Static plugin registry size. Pure read-only metadata, but IO
-- because the registry is owned by the linked C++ runtime.
foreign import ccall unsafe "rt_graph_plugin_count"
  c_rt_graph_plugin_count :: IO CInt

-- | Static plugin name lookup. Returns -1 on null / unknown names.
foreign import ccall unsafe "rt_graph_plugin_find"
  c_rt_graph_plugin_find :: CString -> IO CInt

foreign import ccall unsafe "rt_graph_plugin_name"
  c_rt_graph_plugin_name :: CInt -> IO CString

foreign import ccall unsafe "rt_graph_plugin_audio_in_count"
  c_rt_graph_plugin_audio_in_count :: CInt -> IO CInt

foreign import ccall unsafe "rt_graph_plugin_audio_out_count"
  c_rt_graph_plugin_audio_out_count :: CInt -> IO CInt

foreign import ccall unsafe "rt_graph_plugin_latency_samples"
  c_rt_graph_plugin_latency_samples :: CInt -> IO CInt

foreign import ccall unsafe "rt_graph_plugin_state_size_bytes"
  c_rt_graph_plugin_state_size_bytes :: CInt -> IO CInt

-- | §4.E.2.B test surface: toggle reduction-capture mode for the next
-- 'c_rt_graph_process' call. When non-zero, sink writes route into
-- per-writer-slot contribution buffers and the per-step fold copies
-- them back into the live output buses at deterministic joins;
-- output is bit-identical to the default direct path. When zero
-- (default), behaviour is unchanged. Test-only — not for use in
-- normal rendering or live audio paths.
foreign import ccall unsafe "rt_graph_test_set_reduction_capture"
  c_rt_graph_test_set_reduction_capture :: Ptr RTGraph -> CInt -> IO ()

-- | §4.E.2.C0c test surface: toggle the serial executor that consumes
-- the per-block global schedule. When non-zero, metadata-bearing
-- graphs execute by walking the C0b schedule; graphs with any live
-- template lacking schedule metadata fall back to the legacy executor
-- for the whole block. Test-only — not for normal rendering or live
-- audio paths.
foreign import ccall unsafe "rt_graph_test_set_global_schedule_execution"
  c_rt_graph_test_set_global_schedule_execution
    :: Ptr RTGraph -> CInt -> IO ()

-- | §4.E.2.C1 test surface: configure the RTGraph-owned worker pool.
-- Values <= 1 keep the schedule executor purely serial; values > 1
-- create @worker_count - 1@ background workers.
-- Construction- test-only: call while audio is stopped.
foreign import ccall unsafe "rt_graph_test_set_worker_pool_size"
  c_rt_graph_test_set_worker_pool_size :: Ptr RTGraph -> CInt -> IO ()

-- | §4.E.2.C1 test surface: logical worker lane count currently
-- configured on the graph-owned worker pool.
foreign import ccall unsafe "rt_graph_test_worker_pool_size"
  c_rt_graph_test_worker_pool_size :: Ptr RTGraph -> IO CInt

-- | §4.E.2.C1 test surface: number of background threads currently
-- owned by the graph's worker pool.
foreign import ccall unsafe "rt_graph_test_worker_thread_count"
  c_rt_graph_test_worker_thread_count :: Ptr RTGraph -> IO CInt

-- | §4.E.2.C1c-b test counters from the most recent process block:
-- number of Free bands dispatched through workers.
foreign import ccall unsafe "rt_graph_test_last_parallel_band_count"
  c_rt_graph_test_last_parallel_band_count :: Ptr RTGraph -> IO CInt

-- | §4.E.2.C1c-b test counters from the most recent process block:
-- total global-schedule entries claimed by the worker-dispatch path.
foreign import ccall unsafe "rt_graph_test_last_parallel_entry_count"
  c_rt_graph_test_last_parallel_entry_count :: Ptr RTGraph -> IO CInt

-- | §4.E.2.C1c-b test counters from the most recent process block:
-- multi-entry Free bands deliberately kept serial because they contain
-- sink writers while reduction mode is off.
foreign import ccall unsafe "rt_graph_test_last_serialized_free_band_count"
  c_rt_graph_test_last_serialized_free_band_count :: Ptr RTGraph -> IO CInt

-- | §4.E.2.C1d-c test counter from the most recent process block:
-- number of multi-region sink-free FreeLayer entries dispatched
-- through the worker pool at region-item granularity inside
-- 'process_schedule_band_serial'. The C1c band-level worker path and
-- the C1d-b serial path both bypass this counter, so non-zero values
-- prove region-item dispatch was the path actually exercised.
foreign import ccall unsafe "rt_graph_test_last_c1d_parallel_entry_count"
  c_rt_graph_test_last_c1d_parallel_entry_count :: Ptr RTGraph -> IO CInt

-- | §4.E.2.C1d-c test counter from the most recent process block:
-- total region items handed to the worker pool by C1d-c parallel
-- entry dispatch. Counts items as queued (eligibility-validated),
-- not as executed; defensive in-worker skips would not occur under a
-- well-formed schedule.
foreign import ccall unsafe "rt_graph_test_last_c1d_parallel_region_item_count"
  c_rt_graph_test_last_c1d_parallel_region_item_count
    :: Ptr RTGraph -> IO CInt

-- | §4.E.2.C0a test surface: number of schedule steps registered
-- for the named template. Returns 0 on null g or unknown
-- template_id. Loaders are expected to ship one step per Haskell
-- ScheduleStep, so this should equal
-- @length (layeredRegionSchedule rg)@ for any well-formed
-- template.
foreign import ccall unsafe "rt_graph_test_template_schedule_step_count"
  c_rt_graph_test_template_schedule_step_count
    :: Ptr RTGraph -> CInt -> IO CInt

-- | §4.E.2.C0a test surface: ScheduleStepKind tag of a registered
-- step. Returns 0 = Barrier, 1 = FreeLayer, or -1 on null g or
-- out-of-range indices. Pinned by Haskell-side metadata-equivalence
-- tests against 'layeredRegionSchedule'.
foreign import ccall unsafe "rt_graph_test_template_schedule_step_kind"
  c_rt_graph_test_template_schedule_step_kind
    :: Ptr RTGraph -> CInt -> CInt -> IO CInt

-- | §4.E.2.C0a test surface: number of regions covered by a
-- registered step. Returns -1 on null g or out-of-range indices.
foreign import ccall unsafe "rt_graph_test_template_schedule_step_item_count"
  c_rt_graph_test_template_schedule_step_item_count
    :: Ptr RTGraph -> CInt -> CInt -> IO CInt

-- | §4.E.2.C0a test surface: scheduled-region ordinal at
-- @item_index@ within a registered step. Resolved through
-- MetaDef::schedule_step_regions. Returns -1 on null g, out-of-
-- range template_id / step_index / item_index, or a backing-vector
-- underrun (only possible if a future change corrupts the
-- storage; the C ABI's add entry validates step shapes up-front).
foreign import ccall unsafe "rt_graph_test_template_schedule_step_region"
  c_rt_graph_test_template_schedule_step_region
    :: Ptr RTGraph -> CInt -> CInt -> CInt -> IO CInt

-- | §4.E.2.C0b test surface: number of entries in the per-block
-- global schedule built by the most recent 'c_rt_graph_process' call.
-- Returns 0 if no block has run yet or g is null. The vector is
-- rebuilt every block from the post-drain instance- state snapshot in
-- canonical (template, instance_slot, step) ascending order.
foreign import ccall unsafe "rt_graph_test_global_schedule_entry_count"
  c_rt_graph_test_global_schedule_entry_count
    :: Ptr RTGraph -> IO CInt

-- | §4.E.2.C0b test surface: template_id of the @entry_index@-th
-- global-schedule entry. Returns -1 on null g or out-of-range
-- entry_index.
foreign import ccall unsafe "rt_graph_test_global_schedule_entry_template"
  c_rt_graph_test_global_schedule_entry_template
    :: Ptr RTGraph -> CInt -> IO CInt

-- | §4.E.2.C0b test surface: instance_slot of the @entry_index@-th
-- global-schedule entry (an index into the flat instance pool).
-- Returns -1 on null g or out-of-range entry_index.
foreign import ccall unsafe "rt_graph_test_global_schedule_entry_instance"
  c_rt_graph_test_global_schedule_entry_instance
    :: Ptr RTGraph -> CInt -> IO CInt

-- | §4.E.2.C0b test surface: step_index of the @entry_index@-th
-- global-schedule entry (into the template's schedule_steps). Returns
-- -1 on null g or out-of-range entry_index.
foreign import ccall unsafe "rt_graph_test_global_schedule_entry_step"
  c_rt_graph_test_global_schedule_entry_step
    :: Ptr RTGraph -> CInt -> IO CInt

-- | §4.E.2.C0d test surface: number of runnable bands derived from
-- the most recent C0b global schedule. Bands are contiguous slices of
-- global-schedule entries: 0 = Barrier singleton, 1 = conservative
-- Free dispatch candidate. Returns 0 before any process call or on
-- null g.
foreign import ccall unsafe "rt_graph_test_global_schedule_band_count"
  c_rt_graph_test_global_schedule_band_count
    :: Ptr RTGraph -> IO CInt

-- | §4.E.2.C0d test surface: band kind tag (0 = Barrier, 1 = Free).
-- Returns -1 on null g or out-of-range band index.
foreign import ccall unsafe "rt_graph_test_global_schedule_band_kind"
  c_rt_graph_test_global_schedule_band_kind
    :: Ptr RTGraph -> CInt -> IO CInt

-- | §4.E.2.C0d test surface: first global-schedule entry covered by
-- the band. Returns -1 on null g or out-of-range band index.
foreign import ccall unsafe "rt_graph_test_global_schedule_band_first_entry"
  c_rt_graph_test_global_schedule_band_first_entry
    :: Ptr RTGraph -> CInt -> IO CInt

-- | §4.E.2.C0d test surface: number of global-schedule entries
-- covered by the band. Returns -1 on null g or out-of-range band
-- index.
foreign import ccall unsafe "rt_graph_test_global_schedule_band_entry_count"
  c_rt_graph_test_global_schedule_band_entry_count
    :: Ptr RTGraph -> CInt -> IO CInt

-- | Copy nframes samples from one output bus into the caller's buffer.
-- Returns the number of samples written; 0 on bad arguments. Used by
-- the offline test path; production code reads buses via the realtime
-- callback.
foreign import ccall unsafe "rt_graph_read_bus"
  c_rt_graph_read_bus :: Ptr RTGraph -> CInt -> CInt -> Ptr CFloat -> IO CInt

-- ----------------------------------------------------------------
-- Multi-template ABI bindings (§2.D.3)
-- ----------------------------------------------------------------
--
-- Mirror of the C ABI in tinysynth/rt_graph.h. All graph-loading
-- entries are 'unsafe' for the same reason as their single-template
-- counterparts above (synchronous, non-blocking, called only during
-- load). See Note [Mixed foreign call safety].

-- | Register a fresh empty MetaDef and return its dense template_id.
-- Registration order is execution order — process_graph iterates
-- templates in this order, and the Haskell side
-- (compileTemplateGraph) picks registration order to match the
-- topological sort over template precedence.
foreign import ccall unsafe "rt_graph_template_add"
  c_rt_graph_template_add :: Ptr RTGraph -> IO CInt

-- | Number of templates currently registered.
foreign import ccall unsafe "rt_graph_template_count"
  c_rt_graph_template_count :: Ptr RTGraph -> IO CInt

-- | Set the per-template polyphony cap (max simultaneously-live
-- instances of this template). Construction-only;
-- 'c_rt_graph_template_instance_add' returns -1 once the cap is
-- reached. Default per template is 8. Values <= 0 are clamped to 1 by
-- the runtime; invalid template_id is a silent no-op.
--
-- See Note [Pool model] in @rt_graph.cpp@ for how the cap interacts
-- with the pre-allocated GraphInstance pool.
foreign import ccall unsafe "rt_graph_template_set_polyphony"
  c_rt_graph_template_set_polyphony :: Ptr RTGraph -> CInt -> CInt -> IO ()

-- | Add a node to the named template's MetaDef. Walks every live
-- instance of that template to install per-instance state at the same
-- index. Other templates' instances are not touched.
foreign import ccall unsafe "rt_graph_template_add_node"
  c_rt_graph_template_add_node
    :: Ptr RTGraph -> CInt -> CInt -> CInt -> IO ()

-- | Set one entry of a template's spec.default_controls. Future
-- instances inherit the value; existing instances are not mutated.
-- This is the "spec default" setter used by 'loadTemplateGraph';
-- callers wanting to update a live instance use
-- 'c_rt_graph_instance_set_control' instead.
foreign import ccall unsafe "rt_graph_template_set_default"
  c_rt_graph_template_set_default
    :: Ptr RTGraph -> CInt -> CInt -> CInt -> CDouble -> IO ()

foreign import ccall unsafe "rt_graph_template_set_node_migration_key"
  c_rt_graph_template_set_node_migration_key
    :: Ptr RTGraph -> CInt -> CInt -> CString -> CInt -> IO CInt

foreign import ccall unsafe "rt_graph_template_set_identity"
  c_rt_graph_template_set_identity
    :: Ptr RTGraph -> CInt -> CString -> CInt -> IO CInt

-- | Connect ports within a single template. Cross-template signal
-- flow goes through the shared bus pool, not direct port wiring; this
-- entry does not validate that constraint.
foreign import ccall unsafe "rt_graph_template_connect"
  c_rt_graph_template_connect
    :: Ptr RTGraph -> CInt -> CInt -> CInt -> CInt -> CInt -> IO ()

-- | Add one execution region to the named template's MetaDef.
-- @rate@ is the int form of the Haskell 'Rate' lattice
-- (@fromEnum :: Rate -> Int@); the runtime stores it but does not
-- currently make decisions on it. @firstNode@ and @nodeCount@ name
-- a contiguous run within the template's node array. See
-- @rt_graph.h@'s @rt_graph_template_add_region@ doc and
-- Note [Region fallback] in @rt_graph.cpp@.
foreign import ccall unsafe "rt_graph_template_add_region"
  c_rt_graph_template_add_region
    :: Ptr RTGraph -> CInt -> CInt -> CInt -> CInt -> IO ()

-- | Phase 4.B: kernel-aware region registration. The default-kernel
-- path goes through 'c_rt_graph_template_add_region'; this entry
-- is for fused-kernel regions where the Haskell side has tagged a
-- specific shape ('RegionKernel'). The integer kernel_kind matches
-- 'kernelTag' in @MetaSonic.Bridge.Compile@.
foreign import ccall unsafe "rt_graph_template_add_region_kernel"
  c_rt_graph_template_add_region_kernel
    :: Ptr RTGraph -> CInt
    -> CInt        -- ^ kernel_kind
    -> CInt -> CInt -> CInt
    -> IO ()

-- | Phase 4.B introspection: 'rt_graph_region_kernel_supported'
-- returns 1 when the runtime knows how to dispatch a region tagged
-- with the given integer kernel kind, 0 otherwise. Used to
-- machine-check the 'kernelTag' agreement between Haskell and C++.
foreign import ccall unsafe "rt_graph_region_kernel_supported"
  c_rt_graph_region_kernel_supported :: CInt -> IO CInt

-- | Phase 7.D: allocate a generated fusion program in a template.
-- Returns the new program id (>= 0) usable in subsequent program-
-- op and region-generated calls; returns -1 on invalid template
-- or negative scratch_slots.
foreign import ccall unsafe "rt_graph_template_add_fusion_program"
  c_rt_graph_template_add_fusion_program
    :: Ptr RTGraph -> CInt -> CInt -> IO CInt

-- | Phase 7.D: append an OpLoadConst op to a program.
foreign import ccall unsafe "rt_graph_template_program_load_const"
  c_rt_graph_template_program_load_const
    :: Ptr RTGraph -> CInt -> CInt
    -> CInt -> CDouble
    -> IO ()

-- | Phase 7.D: append an OpLoadInput op.
foreign import ccall unsafe "rt_graph_template_program_load_input"
  c_rt_graph_template_program_load_input
    :: Ptr RTGraph -> CInt -> CInt
    -> CInt -> CInt -> CInt
    -> IO ()

-- | Phase 7.D: append an OpAdd op. The two sources are encoded as
-- @(tag, const_value, idx_a, idx_b)@ tuples, mirroring the C side's
-- decoder.
foreign import ccall unsafe "rt_graph_template_program_add"
  c_rt_graph_template_program_add
    :: Ptr RTGraph -> CInt -> CInt
    -> CInt
    -> CInt -> CDouble -> CInt -> CInt
    -> CInt -> CDouble -> CInt -> CInt
    -> IO ()

-- | Phase 7.D: append an OpMul op. Same source encoding as
-- 'c_rt_graph_template_program_add'.
foreign import ccall unsafe "rt_graph_template_program_mul"
  c_rt_graph_template_program_mul
    :: Ptr RTGraph -> CInt -> CInt
    -> CInt
    -> CInt -> CDouble -> CInt -> CInt
    -> CInt -> CDouble -> CInt -> CInt
    -> IO ()

-- | Phase 7.D: append an OpSinkWrite op. @sink_policy@ matches
-- the Haskell 'SinkPolicy' Enum (0 = reserved overwrite,
-- 1 = accumulate). The v1 interpreter accepts both tags but routes
-- both through the existing sink contribution path.
foreign import ccall unsafe "rt_graph_template_program_sink_write"
  c_rt_graph_template_program_sink_write
    :: Ptr RTGraph -> CInt -> CInt
    -> CInt
    -> CInt -> CDouble -> CInt -> CInt
    -> CInt
    -> IO ()

-- | Phase 7.D: register a region that dispatches through a
-- generated fusion program. Mirrors 'c_rt_graph_template_add_region'
-- /  '..._kernel' but takes a program id instead of a kernel tag.
foreign import ccall unsafe "rt_graph_template_add_region_generated"
  c_rt_graph_template_add_region_generated
    :: Ptr RTGraph -> CInt
    -> CInt -> CInt -> CInt
    -> CInt
    -> IO ()

-- | Phase 7.H: register a generated region that dispatches
-- through the block-major C++ executor instead of the
-- sample-major one. Wire-compatible with
-- 'c_rt_graph_template_add_region_generated'; the C++ side sets
-- @RegionSpec::generated_executor = 1@ before pushing the spec.
foreign import ccall unsafe "rt_graph_template_add_region_generated_block"
  c_rt_graph_template_add_region_generated_block
    :: Ptr RTGraph -> CInt
    -> CInt -> CInt -> CInt
    -> CInt
    -> IO ()

-- | Phase 7.I: register a generated region that dispatches
-- through the super-mode C++ executor, which recognizes a small
-- set of fused shapes as a single per-sample C++ loop and falls
-- back to the block-major executor on unrecognized programs.
-- Wire-compatible with 'c_rt_graph_template_add_region_generated';
-- the C++ side sets @RegionSpec::generated_executor = 2@ before
-- pushing the spec.
foreign import ccall unsafe "rt_graph_template_add_region_generated_super"
  c_rt_graph_template_add_region_generated_super
    :: Ptr RTGraph -> CInt
    -> CInt -> CInt -> CInt
    -> CInt
    -> IO ()

-- | Phase 7.D test surface: count of generated programs in a
-- template, or -1 on invalid template_id.
foreign import ccall unsafe "rt_graph_test_template_fusion_program_count"
  c_rt_graph_test_template_fusion_program_count
    :: Ptr RTGraph -> CInt -> IO CInt

-- | Phase 7.D test surface: count of ops in a program.
foreign import ccall unsafe "rt_graph_test_template_fusion_program_op_count"
  c_rt_graph_test_template_fusion_program_op_count
    :: Ptr RTGraph -> CInt -> CInt -> IO CInt

-- | Phase 7.D test surface: scratch_slots a program was created
-- with.
foreign import ccall unsafe "rt_graph_test_template_fusion_program_scratch_slots"
  c_rt_graph_test_template_fusion_program_scratch_slots
    :: Ptr RTGraph -> CInt -> CInt -> IO CInt

-- | Phase 7.D test surface: generated program id attached to a
-- region, or -1 if the region uses kernel dispatch.
foreign import ccall unsafe "rt_graph_test_template_region_generated_program"
  c_rt_graph_test_template_region_generated_program
    :: Ptr RTGraph -> CInt -> CInt -> IO CInt

-- | Phase 7.I test surface: structural classification of a
-- registered fusion program against the super-mode recognizer
-- set. Returns:
--
--   0 = NotRecognized (super-mode would fall through to block-major)
--   1 = GainOut
--   2 = AddGainOut
--  -1 = invalid template_id or program_id
foreign import ccall unsafe "rt_graph_test_fusion_program_super_kind"
  c_rt_graph_test_fusion_program_super_kind
    :: Ptr RTGraph -> CInt -> CInt -> IO CInt

-- | §4.E.2.C0a: append one descriptive layered-schedule step to the
-- named template, layering an interpretation on top of the regions
-- registered via 'c_rt_graph_template_add_region'. The integer
-- @kind@ matches the Haskell 'ScheduleStepKind' tags (0 = Barrier,
-- 1 = FreeLayer). The third / fourth arguments form an array slice:
-- @item_count@ ints starting at @region_ordinals@, each one a
-- scheduled-region ordinal in @[0, region_count)@. The indirect
-- shape is required because a 'FreeLayer' can carry non-contiguous
-- ordinals — see 'rt_graph_template_add_schedule_step' in
-- @rt_graph.h@.
foreign import ccall unsafe "rt_graph_template_add_schedule_step"
  c_rt_graph_template_add_schedule_step
    :: Ptr RTGraph -> CInt
    -> CInt        -- ^ ScheduleStepKind tag
    -> CInt        -- ^ item_count
    -> Ptr CInt    -- ^ region_ordinals
    -> IO ()

-- | Mark a node in the named template as elided. The node's kernel
-- is skipped during dispatch but its 'NodeIndex' and controls remain
-- addressable. See 'rt_graph_template_set_node_elided' in
-- @rt_graph.h@.
foreign import ccall unsafe "rt_graph_template_set_node_elided"
  c_rt_graph_template_set_node_elided
    :: Ptr RTGraph -> CInt -> CInt -> IO ()

-- | Wire one input port through a fused scaled-source form. The
-- runtime materializes the value as
-- @src[i] * float(scale_node.controls[scale_control_index])@ into a
-- per-instance scratch slot at resolve time. See
-- 'rt_graph_template_connect_fused_scale_input' in @rt_graph.h@.
foreign import ccall unsafe "rt_graph_template_connect_fused_scale_input"
  c_rt_graph_template_connect_fused_scale_input
    :: Ptr RTGraph -> CInt
    -> CInt -> CInt
    -> CInt -> CInt
    -> CInt -> CInt
    -> IO ()

-- | Wire one input port through a chained fused scaled-source form.
-- The runtime materializes @scratch[i] = src[i]@, then folds in each
-- @float(scale_nodes[k].controls[scale_controls[k]])@ in
-- source-to-sink order. One scratch slot per fused input regardless
-- of chain length. See
-- 'rt_graph_template_connect_fused_scale_chain_input' in @rt_graph.h@.
foreign import ccall unsafe "rt_graph_template_connect_fused_scale_chain_input"
  c_rt_graph_template_connect_fused_scale_chain_input
    :: Ptr RTGraph -> CInt
    -> CInt -> CInt
    -> CInt -> CInt
    -> CInt
    -> Ptr CInt
    -> Ptr CInt
    -> IO ()

-- | Wire one input port through an affine chain (mixed Gain × scale
-- and Add + bias steps). The runtime applies each step in
-- source-to-sink order, casting controls to 'float' once per step.
-- See 'rt_graph_template_connect_fused_affine_input' in
-- @rt_graph.h@.
foreign import ccall unsafe "rt_graph_template_connect_fused_affine_input"
  c_rt_graph_template_connect_fused_affine_input
    :: Ptr RTGraph -> CInt
    -> CInt -> CInt
    -> CInt -> CInt
    -> CInt
    -> Ptr CInt
    -> Ptr CInt
    -> Ptr CInt
    -> IO ()

-- | Spawn a fresh instance of the named template. Returns globally-
-- unique instance_id (>= 0) or -1 on failure.
foreign import ccall unsafe "rt_graph_template_instance_add"
  c_rt_graph_template_instance_add :: Ptr RTGraph -> CInt -> IO CInt

-- ----------------------------------------------------------------
-- Multi-instance ABI bindings (§2.B carry-overs, re-exported)
-- ----------------------------------------------------------------

foreign import ccall unsafe "rt_graph_instance_remove"
  c_rt_graph_instance_remove :: Ptr RTGraph -> CInt -> IO ()

-- | Request graceful tear-down of an instance. Sets the gate of
-- every Env node to 0 and lets the runtime auto-free the slot once
-- the instance contributes silence for a small window. If the
-- instance has no Env node, equivalent to 'c_rt_graph_instance_remove'.
-- See Note [§2.E: release-then-free instance lifecycle] in
-- @rt_graph.cpp@.
foreign import ccall unsafe "rt_graph_instance_release"
  c_rt_graph_instance_release :: Ptr RTGraph -> CInt -> IO ()

-- | Returns the lifecycle status of an instance:
--
--   * @0@ ('instanceStatusLive')      — default; sustaining
--   * @1@ ('instanceStatusReleasing') — release requested, awaiting silence
--   * @-1@                            — dead slot, out of range, or null graph
foreign import ccall unsafe "rt_graph_instance_status"
  c_rt_graph_instance_status :: Ptr RTGraph -> CInt -> IO CInt

-- | C ABI value for 'InstanceStatus::Live'. Mirrors the integer
-- assignment in @rt_graph.cpp@; the values are part of the C ABI and
-- must not change. Pinned in Haskell so test code does not need to
-- pattern-match on bare integer literals.
instanceStatusLive :: CInt
instanceStatusLive = 0

-- | C ABI value for 'InstanceStatus::Releasing'.
instanceStatusReleasing :: CInt
instanceStatusReleasing = 1

foreign import ccall unsafe "rt_graph_instance_count"
  c_rt_graph_instance_count :: Ptr RTGraph -> IO CInt

foreign import ccall unsafe "rt_graph_instance_alive"
  c_rt_graph_instance_alive :: Ptr RTGraph -> CInt -> IO CInt

foreign import ccall unsafe "rt_graph_instance_set_control"
  c_rt_graph_instance_set_control
    :: Ptr RTGraph -> CInt -> CInt -> CInt -> CDouble -> IO ()

-- ----------------------------------------------------------------
-- A.2 realtime ABI bindings
--
-- Single-producer contract: only one Haskell thread (typically the
-- voice allocator's input handler) may call this group. Concurrent
-- calls from multiple threads will corrupt the SPSC queue. See
-- Note [A.2: realtime control queue] in @rt_graph.cpp@.
-- ----------------------------------------------------------------

-- | Reserve and prepare a slot for the named template. Returns
-- @slot_id >= 0@ on success, @-1@ on any failure (null graph,
-- invalid template_id, polyphony cap reached, no Available slot
-- in the pool to recycle). Realtime reserve never grows the pool;
-- callers must pre-warm it during construction.
foreign import ccall unsafe "rt_graph_realtime_reserve"
  c_rt_graph_realtime_reserve :: Ptr RTGraph -> CInt -> IO CInt

-- | Cancel a reservation, returning the slot to Available without
-- ever publishing it. Silent no-op if the slot isn't Reserved.
foreign import ccall unsafe "rt_graph_realtime_cancel"
  c_rt_graph_realtime_cancel :: Ptr RTGraph -> CInt -> IO ()

-- | Enqueue Activate(slot_id) for the audio thread to publish at
-- the next block boundary. Returns 1 on success, 0 if the queue
-- is full — on full queue, the producer should
-- 'c_rt_graph_realtime_cancel' the slot.
foreign import ccall unsafe "rt_graph_realtime_activate"
  c_rt_graph_realtime_activate :: Ptr RTGraph -> CInt -> IO CInt

-- | Enqueue Release(slot_id). Returns 1 on success, 0 if full.
foreign import ccall unsafe "rt_graph_realtime_release"
  c_rt_graph_realtime_release :: Ptr RTGraph -> CInt -> IO CInt

-- | Enqueue Remove(slot_id). Returns 1 on success, 0 if full.
foreign import ccall unsafe "rt_graph_realtime_remove"
  c_rt_graph_realtime_remove :: Ptr RTGraph -> CInt -> IO CInt

-- | Enqueue SetControl. Returns 1 on success, 0 if full.
foreign import ccall unsafe "rt_graph_realtime_set_control"
  c_rt_graph_realtime_set_control
    :: Ptr RTGraph -> CInt -> CInt -> CInt -> CDouble -> IO CInt

-- §6.C.3a buffer pool ABI. None of these are safe to call while
-- audio is running — load may reallocate, clear drops the
-- allocated bit out from under a live read. §6.C.3b adds the
-- live-safe retire/collect pair.
foreign import ccall unsafe "rt_graph_buffer_alloc"
  c_rt_graph_buffer_alloc
    :: Ptr RTGraph -> CInt -> IO CInt

foreign import ccall unsafe "rt_graph_buffer_load_f32"
  c_rt_graph_buffer_load_f32
    :: Ptr RTGraph -> CInt -> Ptr CFloat -> CInt -> IO CInt

foreign import ccall unsafe "rt_graph_buffer_clear"
  c_rt_graph_buffer_clear
    :: Ptr RTGraph -> CInt -> IO CInt

-- §6.C.3b slice 2 live-safe retire / collect. Single-producer
-- SPSC contract: only one Haskell thread (typically the same
-- thread that called allocBuffer in the first place) may call
-- this pair. Concurrent calls from multiple threads would race
-- on the slot's retire_generation_snapshot field.
foreign import ccall unsafe "rt_graph_buffer_retire"
  c_rt_graph_buffer_retire
    :: Ptr RTGraph -> CInt -> IO CInt

foreign import ccall unsafe "rt_graph_buffer_collect_retired"
  c_rt_graph_buffer_collect_retired
    :: Ptr RTGraph -> CInt -> IO CInt

foreign import ccall unsafe "rt_graph_test_buffer_read_count"
  c_rt_graph_test_buffer_read_count
    :: Ptr RTGraph -> IO CLLong

foreign import ccall unsafe "rt_graph_test_buffer_invalid_read_count"
  c_rt_graph_test_buffer_invalid_read_count
    :: Ptr RTGraph -> IO CLLong

foreign import ccall unsafe "rt_graph_test_buffer_write_count"
  c_rt_graph_test_buffer_write_count
    :: Ptr RTGraph -> IO CLLong

foreign import ccall unsafe "rt_graph_test_buffer_invalid_write_count"
  c_rt_graph_test_buffer_invalid_write_count
    :: Ptr RTGraph -> IO CLLong

foreign import ccall unsafe "rt_graph_test_spectral_analysis_count"
  c_rt_graph_test_spectral_analysis_count
    :: Ptr RTGraph -> IO CLLong

foreign import ccall unsafe "rt_graph_test_spectral_resynthesis_count"
  c_rt_graph_test_spectral_resynthesis_count
    :: Ptr RTGraph -> IO CLLong

foreign import ccall unsafe "rt_graph_test_plugin_call_count"
  c_rt_graph_test_plugin_call_count
    :: Ptr RTGraph -> IO CLLong

foreign import ccall unsafe "rt_graph_test_invalid_plugin_call_count"
  c_rt_graph_test_invalid_plugin_call_count
    :: Ptr RTGraph -> IO CLLong

-- (c_rt_graph_instance_read_bus was removed in the post-§2.E ABI
-- cleanup. The C entry was a thin liveness-gated alias for
-- rt_graph_read_bus; under §2.C the bus pool is server-global, so
-- the instance gate didn't reflect any real per-instance scope.
-- Use c_rt_graph_read_bus and, if you need a liveness check, gate
-- the call yourself with c_rt_graph_instance_alive or
-- c_rt_graph_instance_status.)

-- | Snapshot the build-linked static plugin registry into Haskell
-- values suitable for reporting and contract tests.
pluginRegistryEntries :: IO [PluginRegistryEntry]
pluginRegistryEntries = do
  n <- c_rt_graph_plugin_count
  forM [0 .. fromIntegral n - 1] $ \i -> do
    cName <- c_rt_graph_plugin_name (fromIntegral i)
    name <- if cName == nullPtr
              then pure "<invalid>"
              else peekCString cName
    inCount <- c_rt_graph_plugin_audio_in_count (fromIntegral i)
    outCount <- c_rt_graph_plugin_audio_out_count (fromIntegral i)
    latency <- c_rt_graph_plugin_latency_samples (fromIntegral i)
    stateBytes <- c_rt_graph_plugin_state_size_bytes (fromIntegral i)
    pure PluginRegistryEntry
      { pluginEntryId             = i
      , pluginEntryName           = name
      , pluginEntryAudioInputs    = fromIntegral inCount
      , pluginEntryAudioOutputs   = fromIntegral outCount
      , pluginEntryLatencySamples = fromIntegral latency
      , pluginEntryStateBytes     = fromIntegral stateBytes
      }

-- | Allocate a C++ runtime graph, run an action with it, and
-- guarantee cleanup via bracket.
--
-- The @capacity@ parameter is an advisory hint for vector
-- pre-allocation; @maxFrames@ is the maximum block size
-- accepted by @rt_graph_process@.
--
-- The finalizer uses the safe import of @rt_graph_destroy@,
-- because destroying the graph may need to stop a live audio
-- stream before releasing runtime memory.
--
-- See Note [FFI boundary design].
withRTGraph :: BuilderCapacity -> MaxFrames -> (Ptr RTGraph -> IO a) -> IO a
withRTGraph capacity maxFrames =
  bracket
    (c_rt_graph_create (fromIntegral capacity) (fromIntegral maxFrames))
    c_rt_graph_destroy

{- Note [Phase 5.3 hot-swap helpers]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The low-level Phase 5.1 ABI deliberately exposes the full ownership
protocol: build an offline graph, prepare a swap, publish it, wait for
the audio thread to install it, collect the retired swap, then dispose
it. That is the right C contract, but it is too easy for Haskell
callers to leak a rejected swap or forget the retire-slot collection.

The 5.3 helpers below keep the same semantics while packaging the
producer boilerplate:

  * hotSwap* builds the next world in a temporary RTGraph by reusing
    the existing loaders. The target graph is not cleared and audio is
    not stopped.
  * A successful publish transfers ownership of the swap to the C++
    runtime and returns True. A failed publish cancels the prepared
    swap before returning False.
  * collectRetiredSwapStats is the reap point after an audio block has
    installed the swap. It snapshots the Phase 5.2 counters, disposes
    the retired swap, and returns Nothing when no retired swap exists.
  * waitForSwapGeneration and the hotSwap*AndWait family add the
    producer-side "publish, wait for install, collect, then resume
    realtime commands" protocol. They poll the install-generation
    counter rather than blocking inside C++.

The helper @capacity@ argument is the same advisory pre-allocation
hint accepted by 'withRTGraph'. It is deliberately explicit: graph
shape is not an instance-capacity contract, and producers should size
the offline builder using the same policy they used for the live
target.
The exported 'BuilderCapacity', 'MaxFrames', 'TimeoutMs', and
'SwapGeneration' aliases label the adjacent integer roles in the API
without changing the C ABI. If callers start mixing these up in real
producer code, promote them to newtypes.
SwapGeneration stays Haskell-facing Int by design; the raw C counter is
CInt and is converted once at the FFI edge by 'readSwapGeneration'.

The waited helpers assume the v1 producer model: one hot-swap producer
and one collector per target. They capture @swap_generation@ before
publish and then wait for it to advance, so a concurrent producer could
make the wait observe and collect the other producer's swap. The
@HotSwapInstalledButRetiredMissing@ result is defensive for future
multi-collector code; under the single-producer/single-collector model
it should not occur.

The 5.3.A hotSwap* helpers do not block waiting for installation.
Offline callers drive one rt_graph_process block; realtime callers let
the audio callback advance and poll collection from the producer side.
The 5.3.B hotSwap*AndWait helpers do wait, with a caller-supplied
timeout in milliseconds.
-}

hotSwapWith
  :: (Ptr RTGraph -> a -> IO ())
  -> BuilderCapacity
  -> MaxFrames
  -> Ptr RTGraph
  -> a
  -> IO Bool
hotSwapWith loader capacity maxFrames target payload = do
  maybeSwap <- prepareSwapWith loader capacity maxFrames target payload
  case maybeSwap of
    Nothing -> pure False
    Just swap -> do
      ok <- c_rt_graph_publish_swap target swap
      if ok == 0
        then c_rt_graph_cancel_swap target swap >> pure False
        else pure True

prepareSwapWith
  :: (Ptr RTGraph -> a -> IO ())
  -> BuilderCapacity
  -> MaxFrames
  -> Ptr RTGraph
  -> a
  -> IO (Maybe (Ptr RTGraphSwap))
prepareSwapWith loader capacity maxFrames target payload =
  withRTGraph capacity maxFrames $ \builder -> do
    loader builder payload
    swap <- c_rt_graph_prepare_swap_from_graph target builder
    if swap == nullPtr
      then pure Nothing
      else pure (Just swap)

-- | Build @rg@ in an offline runtime graph and publish it as the
-- target's next world. Returns 'True' when publish succeeds. On
-- 'False', no swap remains owned by the caller.
--
-- @capacity@ is the advisory builder capacity passed to
-- 'withRTGraph'; callers should use the same sizing policy as the live
-- target rather than relying on node count as an implicit proxy.
--
-- The caller must later call 'collectRetiredSwapStats' after a block
-- boundary has installed the swap; otherwise the C++ one-deep retire
-- slot remains occupied and the next publish will fail.
hotSwapRuntimeGraph
  :: Ptr RTGraph -> BuilderCapacity -> MaxFrames -> RuntimeGraph -> IO Bool
hotSwapRuntimeGraph target capacity maxFrames rg =
  hotSwapWith loadRuntimeGraph capacity maxFrames target rg

-- | Fused-aware sibling of 'hotSwapRuntimeGraph'.
hotSwapRuntimeGraphFused
  :: Ptr RTGraph -> BuilderCapacity -> MaxFrames -> RuntimeGraph -> IO Bool
hotSwapRuntimeGraphFused target capacity maxFrames rg =
  hotSwapWith loadRuntimeGraphFused capacity maxFrames target rg

-- | Multi-template sibling of 'hotSwapRuntimeGraph'.
hotSwapTemplateGraph
  :: Ptr RTGraph -> BuilderCapacity -> MaxFrames -> TemplateGraph -> IO Bool
hotSwapTemplateGraph target capacity maxFrames tg =
  hotSwapWith loadTemplateGraph capacity maxFrames target tg

-- | Fused-aware multi-template sibling of 'hotSwapTemplateGraph'.
hotSwapTemplateGraphFused
  :: Ptr RTGraph -> BuilderCapacity -> MaxFrames -> TemplateGraph -> IO Bool
hotSwapTemplateGraphFused target capacity maxFrames tg =
  hotSwapWith loadTemplateGraphFused capacity maxFrames target tg

-- | Collect and dispose one retired swap, returning the migration
-- counters recorded by the install that consumed it. Returns
-- 'Nothing' when no installed swap is waiting to be collected.
collectRetiredSwapStats :: Ptr RTGraph -> IO (Maybe SwapMigrationStats)
collectRetiredSwapStats target = do
  swap <- c_rt_graph_collect_retired_swap target
  if swap == nullPtr
    then pure Nothing
    else do
      -- The collected swap has already passed through the audio
      -- thread's retired slot. Install is complete and these counters
      -- are frozen before the producer can observe the pointer.
      committed <- c_rt_graph_swap_migration_committed_count swap
      skipped <- c_rt_graph_swap_migration_skipped_count swap
      instances <- c_rt_graph_swap_migration_instance_copy_count swap
      states <- c_rt_graph_swap_migration_state_copy_count swap
      lifecycles <- c_rt_graph_swap_migration_lifecycle_copy_count swap
      c_rt_graph_cancel_swap target swap
      pure $ Just SwapMigrationStats
        { smsCommittedCount = fromIntegral committed
        , smsSkippedCount = fromIntegral skipped
        , smsInstanceCopyCount = fromIntegral instances
        , smsStateCopyCount = fromIntegral states
        , smsLifecycleCopyCount = fromIntegral lifecycles
        }

-- | Read the production install-generation counter.
--
-- This is the stable Haskell surface used by live hot-swap producers.
-- The adjacent @c_rt_graph_test_swap_generation@ binding remains
-- exported for older low-level tests that assert the same counter
-- directly.
readSwapGeneration :: Ptr RTGraph -> IO SwapGeneration
readSwapGeneration target =
  fromIntegral <$> c_rt_graph_swap_generation target

-- | Poll until the target's swap generation is greater than
-- @priorGeneration@. A negative timeout waits indefinitely; zero
-- performs a single non-blocking poll; positive values are
-- milliseconds. Returns 'False' on timeout.
waitForSwapGeneration :: Ptr RTGraph -> SwapGeneration -> TimeoutMs -> IO Bool
waitForSwapGeneration target priorGeneration timeoutMs = do
  let installed = (> priorGeneration)
      poll = do
        gen <- readSwapGeneration target
        if installed gen
          then pure True
          else threadDelay 1000 >> poll
  first <- readSwapGeneration target
  if installed first
    then pure True
    else if timeoutMs == 0
      then pure False
      else if timeoutMs < 0
        then poll
        else do
          result <- timeout (timeoutMs * 1000) poll
          pure (maybe False id result)

hotSwapAndWaitWith
  :: (Ptr RTGraph -> BuilderCapacity -> MaxFrames -> a -> IO Bool)
  -> Ptr RTGraph
  -> BuilderCapacity
  -> MaxFrames
  -> TimeoutMs
  -> a
  -> IO HotSwapWaitResult
hotSwapAndWaitWith publish target capacity maxFrames timeoutMs payload = do
  before <- readSwapGeneration target
  published <- publish target capacity maxFrames payload
  if not published
    then pure HotSwapPublishRejected
    else do
      installed <- waitForSwapGeneration target before timeoutMs
      if not installed
        then pure HotSwapInstallTimedOut
        else do
          stats <- collectRetiredSwapStats target
          pure $ case stats of
            Just s  -> HotSwapInstalled s
            Nothing -> HotSwapInstalledButRetiredMissing

-- | Publish a single-template next world, wait until the audio thread
-- installs it, collect migration stats, and dispose the retired old
-- world. The timeout is in milliseconds; negative waits indefinitely.
hotSwapRuntimeGraphAndWait
  :: Ptr RTGraph -> BuilderCapacity -> MaxFrames -> TimeoutMs -> RuntimeGraph
  -> IO HotSwapWaitResult
hotSwapRuntimeGraphAndWait =
  hotSwapAndWaitWith hotSwapRuntimeGraph

-- | Fused-aware sibling of 'hotSwapRuntimeGraphAndWait'.
hotSwapRuntimeGraphFusedAndWait
  :: Ptr RTGraph -> BuilderCapacity -> MaxFrames -> TimeoutMs -> RuntimeGraph
  -> IO HotSwapWaitResult
hotSwapRuntimeGraphFusedAndWait =
  hotSwapAndWaitWith hotSwapRuntimeGraphFused

-- | Multi-template sibling of 'hotSwapRuntimeGraphAndWait'.
hotSwapTemplateGraphAndWait
  :: Ptr RTGraph -> BuilderCapacity -> MaxFrames -> TimeoutMs -> TemplateGraph
  -> IO HotSwapWaitResult
hotSwapTemplateGraphAndWait =
  hotSwapAndWaitWith hotSwapTemplateGraph

-- | Fused-aware multi-template sibling of 'hotSwapTemplateGraphAndWait'.
hotSwapTemplateGraphFusedAndWait
  :: Ptr RTGraph -> BuilderCapacity -> MaxFrames -> TimeoutMs -> TemplateGraph
  -> IO HotSwapWaitResult
hotSwapTemplateGraphFusedAndWait =
  hotSwapAndWaitWith hotSwapTemplateGraphFused

{- Note [Marshaling newtypes to C]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
cNodeIndex, cPortIndex, and cControlIndex convert Haskell
newtypes to CInt for the FFI. The conversions are all
fromIntegral on Int → CInt, which is safe for the index
ranges we operate in (graph sizes are far below 2^31).

These helpers exist to keep the loadRuntimeGraph code
readable and to ensure that the nominal distinction between
NodeIndex, PortIndex, and ControlIndex is maintained up to
the FFI call site. Without them, it would be easy to
accidentally pass a NodeIndex where a PortIndex is expected,
since both unwrap to Int.

See Note [Symbolic vs dense identifiers] in MetaSonic.Types.
-}

cNodeIndex :: NodeIndex -> CInt
cNodeIndex (NodeIndex x) = fromIntegral x

cPortIndex :: PortIndex -> CInt
cPortIndex (PortIndex x) = fromIntegral x

cControlIndex :: ControlIndex -> CInt
cControlIndex (ControlIndex x) = fromIntegral x

-- | §4.E.2.C0a: project a 'layeredRegionSchedule' result onto a
-- list of @(kind, [ordinals])@ pairs, where the ordinals are
-- positions in the supplied @scheduled@ list (=
-- 'scheduledRuntimeRegions'), which is the order the loader
-- registers regions in. Each step's ordinal list can be
-- non-contiguous in linear schedule order: 'goLayers' partitions
-- all currently-ready regions into one layer, so a free segment
-- with rrIndex 0, rrIndex 1 (depends on 0), rrIndex 2 (independent)
-- yields layers @[{0, 2}, {1}]@. Encoding such a layer as a
-- contiguous range @[first, first+2)@ would silently rewrite it to
-- @{0, 1}@, miscategorising rrIndex 1 once C0b consumes the
-- metadata.
--
-- 'rrIndex' values that are not in @scheduled@ trigger 'error': by
-- construction every 'flRegions' / 'ScheduleBarrier' index is a
-- member of 'rgRuntimeRegions' (the planner validates the same
-- input), so this is a structural-invariant violation, not a user
-- error.
--
-- The kind encoding mirrors the C-side 'ScheduleStepKind' tags:
--   0 = Barrier, 1 = FreeLayer.
scheduleStepItems
  :: [RuntimeRegion] -> [ScheduleStep] -> [(CInt, [CInt])]
scheduleStepItems scheduled = map step
  where
    pairs = zip [0 :: Int ..] scheduled
    ordinal ix =
      case [i | (i, r) <- pairs, rrIndex r == ix] of
        (n : _) -> fromIntegral n
        []      -> error $
          "scheduleStepItems: rrIndex " <> show ix
          <> " not in scheduledRuntimeRegions"
    step (ScheduleBarrier ix)    = (0, [ordinal ix])
    step (ScheduleFreeLayer fl)  = (1, map ordinal (flRegions fl))

-- | §4.E.2.C0a: ship a 'layeredRegionSchedule' across the FFI as
-- one 'c_rt_graph_template_add_schedule_step' call per step. Must
-- run after the per-region registration pass for the same template
-- so the runtime can range-check each ordinal against the
-- registered region vector. The @scheduled@ argument must be the
-- same list the region pass used (= 'scheduledRuntimeRegions') so
-- ordinals here match the runtime's region vector positions.
addScheduleStepsTo
  :: Ptr RTGraph -> CInt
  -> [RuntimeRegion] -> [ScheduleStep] -> IO ()
addScheduleStepsTo g cTid scheduled steps =
  forM_ (scheduleStepItems scheduled steps) $ \(cKind, ords) ->
    withArray ords $ \pOrds ->
      c_rt_graph_template_add_schedule_step g cTid cKind
        (fromIntegral (length ords)) pOrds

-- | Send one 'RuntimeRegion' across the FFI as a contiguous range.
-- Currently the greedy 'formRegions' pass produces only contiguous
-- regions; this helper flattens 'rrNodes' to (first_node, node_count)
-- on that assumption. An empty 'rrNodes' is a silent no-op (the
-- runtime would clamp it anyway).
--
-- 'rrRate' marshals via 'fromEnum' to match the Haskell 'Rate'
-- lattice ordering — see Note [Rate discipline] in MetaSonic.Types.
-- The runtime stores the int but does not currently key behavior
-- on it.
addRegionTo :: Ptr RTGraph -> CInt -> RuntimeRegion -> IO ()
addRegionTo g cTid r =
  case rrNodes r of
    []                 -> pure ()
    (NodeIndex h : _)  ->
      let cRate  = fromIntegral (fromEnum (rrRate r))
          cFirst = fromIntegral h
          cCount = fromIntegral (length (rrNodes r))
      in case rrExec r of
           ExecNodeLoop ->
             -- Default behavior: existing entry, identical wire
             -- format to pre-§4.B graphs.
             c_rt_graph_template_add_region g cTid
               cRate cFirst cCount
           ExecKernel kernel ->
             -- §4.B: fused-kernel region. The kernel tag tells the
             -- runtime which hand-written kernel to dispatch
             -- instead of iterating member nodes. See
             -- 'kernelTag' / 'RegionKernel' in
             -- "MetaSonic.Bridge.Compile" for the integer
             -- encoding the C side dispatches on.
             c_rt_graph_template_add_region_kernel g cTid
               (kernelTag kernel)
               cRate cFirst cCount
           ExecGenerated (FusionProgramId pid) ->
             -- §7.D: generated fusion program. The program must
             -- already exist in the template's program table
             -- (pushed by 'loadFusionProgramsTo' before this
             -- region is registered).
             c_rt_graph_template_add_region_generated g cTid
               cRate cFirst cCount
               (fromIntegral pid)
           ExecGeneratedBlock (FusionProgramId pid) ->
             -- §7.H: same FusionProgram, block-major executor.
             -- The Haskell-side validator already cleared the
             -- program-id reference; the C ABI mirror just sets
             -- RegionSpec::generated_executor to 1.
             c_rt_graph_template_add_region_generated_block g cTid
               cRate cFirst cCount
               (fromIntegral pid)
           ExecGeneratedSuper (FusionProgramId pid) ->
             -- §7.I: same FusionProgram, super-mode executor.
             -- Recognizes a small set of fused shapes and falls
             -- back to the block-major executor otherwise. The
             -- Haskell-side validator already cleared the
             -- program-id reference; the C ABI mirror just sets
             -- RegionSpec::generated_executor to 2.
             c_rt_graph_template_add_region_generated_super g cTid
               cRate cFirst cCount
               (fromIntegral pid)

maxGeneratedScratchSlots :: Int
maxGeneratedScratchSlots = 64

-- | Validate generated-fusion program tables before any loader calls
-- 'c_rt_graph_clear'. The C++ runtime still range-checks direct ABI
-- callers, but Haskell loaders should fail loudly and preserve the
-- previously loaded graph when a generated table is malformed.
validateGeneratedPrograms :: RuntimeGraph -> Either String ()
validateGeneratedPrograms rg = do
  forM_ (zip [0 :: Int ..] (rgFusionPrograms rg)) $
    \(pid, prog) -> validateFusionProgram rg pid prog
  forM_ (rgRuntimeRegions rg) validateRegionProgramRef
  where
    programCount = length (rgFusionPrograms rg)

    validateRegionProgramRef region =
      case rrExec region of
        ExecGenerated      (FusionProgramId pid) -> checkPid region pid
        ExecGeneratedBlock (FusionProgramId pid) -> checkPid region pid
        ExecGeneratedSuper (FusionProgramId pid) -> checkPid region pid
        _ -> Right ()

    checkPid region pid
      | pid < 0 =
          reject $
            "region " <> show (rrIndex region)
            <> " references negative FusionProgramId "
            <> show pid
      | pid >= programCount =
          reject $
            "region " <> show (rrIndex region)
            <> " references FusionProgramId " <> show pid
            <> ", but table has " <> show programCount
            <> " programs"
      | otherwise = Right ()

validateFusionProgram
  :: RuntimeGraph -> Int -> FusionProgram -> Either String ()
validateFusionProgram rg pid prog = do
  when (slotCount < 0) $
    reject $
      "program " <> show pid
      <> " declares negative scratch slot count "
      <> show slotCount
  when (slotCount > maxGeneratedScratchSlots) $
    reject $
      "program " <> show pid
      <> " declares " <> show slotCount
      <> " scratch slots; max is "
      <> show maxGeneratedScratchSlots
  when (null (fpOps prog)) $
    reject $
      "program " <> show pid
      <> " has no ops"
  go S.empty (zip [0 :: Int ..] (fpOps prog))
  where
    slotCount = fpScratchSlots prog

    go _ [] = Right ()
    go written ((opIx, op) : rest) = do
      written' <- validateFusionOp written opIx op
      go written' rest

    validateFusionOp written opIx op =
      case op of
        OpLoadConst dst _ -> writeScratch written opIx dst
        OpLoadInput dst node port -> do
          validateNodeOutputRef pid opIx node port
          writeScratch written opIx dst
        OpAdd dst src1 src2 -> do
          validateSource written opIx src1
          validateSource written opIx src2
          writeScratch written opIx dst
        OpMul dst src1 src2 -> do
          validateSource written opIx src1
          validateSource written opIx src2
          writeScratch written opIx dst
        OpSinkWrite bus src _ -> do
          when (bus < 0) $
            reject $
              opPrefix pid opIx
              <> "writes negative bus index "
              <> show bus
          validateSource written opIx src
          Right written

    writeScratch written opIx (ScratchIndex dst) = do
      validateScratchIndex pid opIx "writes scratch" dst
      Right (S.insert dst written)

    validateSource written opIx src =
      case src of
        SrcConst _ -> Right ()
        SrcInput node port ->
          validateNodeOutputRef pid opIx node port
        SrcControl node control ->
          validateControlRef pid opIx node control
        SrcScratch (ScratchIndex ix) -> do
          validateScratchIndex pid opIx "reads scratch" ix
          unless (S.member ix written) $
            reject $
              opPrefix pid opIx
              <> "reads scratch " <> show ix
              <> " before it is written"

    validateNodeOutputRef p opIx node (PortIndex port) = do
      _ <- lookupRuntimeNode p opIx node
      when (port < 0) $
        reject $
          opPrefix p opIx
          <> "reads negative output port "
          <> show port

    validateControlRef p opIx node (ControlIndex control) = do
      rtNode <- lookupRuntimeNode p opIx node
      when (control < 0 || control >= length (rnControls rtNode)) $
        reject $
          opPrefix p opIx
          <> "reads control " <> show control
          <> " on " <> show node
          <> ", but node has "
          <> show (length (rnControls rtNode))
          <> " controls"

    lookupRuntimeNode p opIx node =
      case [rtNode | rtNode <- rgNodes rg, rnIndex rtNode == node] of
        rtNode : _ -> Right rtNode
        [] ->
          reject $
            opPrefix p opIx
            <> "references unknown node "
            <> show node

    validateScratchIndex p opIx role ix =
      when (ix < 0 || ix >= slotCount) $
        reject $
          opPrefix p opIx
          <> role <> " " <> show ix
          <> if slotCount <= 0
               then " outside declared scratch slots (none)"
               else " outside declared scratch slot range 0.."
                    <> show (slotCount - 1)

opPrefix :: Int -> Int -> String
opPrefix pid opIx =
  "program " <> show pid <> ", op " <> show opIx <> ": "

reject :: String -> Either String a
reject msg = Left ("generated fusion validation: " <> msg)

-- | Phase 7.D: push one template's generated-fusion programs into
-- the C runtime. Programs must be pushed /before/ any region that
-- references one by 'FusionProgramId' is registered (regions look
-- up their program at construction time and otherwise silent-no-op).
--
-- The programs are pushed in list order so 'FusionProgramId 0' on
-- the Haskell side corresponds to the first call's return; we
-- verify against that and 'fail' on a divergence rather than
-- silently shipping a misindexed table.
loadFusionProgramsTo
  :: Ptr RTGraph -> CInt -> [FusionProgram] -> IO ()
loadFusionProgramsTo g cTid programs =
  forM_ (zip [0 :: Int ..] programs) $ \(expectedId, prog) -> do
    actualId <-
      c_rt_graph_template_add_fusion_program g cTid
        (fromIntegral (fpScratchSlots prog))
    when (fromIntegral actualId /= expectedId) $
      fail $ "loadFusionProgramsTo: program id divergence: "
          <> "expected " <> show expectedId
          <> ", got " <> show actualId
    forM_ (fpOps prog) $ \op ->
      appendFusionOp g cTid actualId op

-- | Append one 'FusionOp' to a program. Marshals to the
-- per-op-kind C entry; 'FusionSource' operands are encoded as
-- @(tag, const_value, idx_a, idx_b)@ tuples mirroring the C
-- side's decoder.
appendFusionOp :: Ptr RTGraph -> CInt -> CInt -> FusionOp -> IO ()
appendFusionOp g cTid cPid op = case op of
  OpLoadConst (ScratchIndex dst) value ->
    c_rt_graph_template_program_load_const g cTid cPid
      (fromIntegral dst) (CDouble value)
  OpLoadInput (ScratchIndex dst) node port ->
    c_rt_graph_template_program_load_input g cTid cPid
      (fromIntegral dst) (cNodeIndex node) (cPortIndex port)
  OpAdd (ScratchIndex dst) src1 src2 ->
    let (t1, c1, a1, b1) = encodeFusionSource src1
        (t2, c2, a2, b2) = encodeFusionSource src2
    in c_rt_graph_template_program_add g cTid cPid
         (fromIntegral dst)
         t1 c1 a1 b1
         t2 c2 a2 b2
  OpMul (ScratchIndex dst) src1 src2 ->
    let (t1, c1, a1, b1) = encodeFusionSource src1
        (t2, c2, a2, b2) = encodeFusionSource src2
    in c_rt_graph_template_program_mul g cTid cPid
         (fromIntegral dst)
         t1 c1 a1 b1
         t2 c2 a2 b2
  OpSinkWrite bus src policy ->
    let (t, k, a, b) = encodeFusionSource src
    in c_rt_graph_template_program_sink_write g cTid cPid
         (fromIntegral bus)
         t k a b
         (fromIntegral (fromEnum policy))

-- | Encode a 'FusionSource' as a four-tuple @(tag, const_value,
-- idx_a, idx_b)@. Unused fields are zero. Tags mirror the
-- Haskell 'FusionSource' constructor order and the C decoder in
-- @rt_graph.cpp@.
encodeFusionSource :: FusionSource -> (CInt, CDouble, CInt, CInt)
encodeFusionSource s = case s of
  SrcConst v ->
    (0, CDouble v, 0, 0)
  SrcInput node port ->
    (1, 0, cNodeIndex node, cPortIndex port)
  SrcControl node ctrl ->
    (2, 0, cNodeIndex node, cControlIndex ctrl)
  SrcScratch (ScratchIndex i) ->
    (3, 0, fromIntegral i, 0)

-- | Cross the fused-input ABI for one consumer port. Dispatches
-- between the single-scale and chain entry points so the loaders
-- only have to recognize 'RFused' once. The chain entry point
-- claims one scratch slot regardless of length, so emitting the
-- chain form for length-1 chains would be correct but wasteful;
-- the compiler emits 'FScaleFrom' for length-1 to avoid the array
-- marshalling and to preserve bit-equivalence with the original
-- single-edge wiring.
wireFusedScale
  :: Ptr RTGraph -> CInt
  -> CInt -> CInt
  -> FusedInput
  -> IO ()
wireFusedScale g cTid dstNode dstPort fused = case fused of
  FScaleFrom srcN srcP scaleN scaleC ->
    c_rt_graph_template_connect_fused_scale_input g cTid
      dstNode dstPort
      (cNodeIndex srcN)
      (cPortIndex srcP)
      (cNodeIndex scaleN)
      (cControlIndex scaleC)
  FScaleChainFrom srcN srcP scales ->
    let nodes = [cNodeIndex n | ScaleRef n _ <- scales]
        ctls  = [cControlIndex c | ScaleRef _ c <- scales]
        n     = fromIntegral (length scales)
    in withArray nodes $ \pNodes ->
       withArray ctls  $ \pCtls  ->
         c_rt_graph_template_connect_fused_scale_chain_input g cTid
           dstNode dstPort
           (cNodeIndex srcN)
           (cPortIndex srcP)
           n pNodes pCtls
  FAffineFrom srcN srcP steps ->
    -- ABI tag values mirror FusedAffineStep::Kind in rt_graph.cpp:
    -- 0 = Scale, 1 = Bias. Three parallel arrays, all CInt.
    let kinds = [stepKind s    | s <- steps]
        nodes = [cNodeIndex (stepNode s)    | s <- steps]
        ctls  = [cControlIndex (stepCtl s)  | s <- steps]
        n     = fromIntegral (length steps)
    in withArray kinds $ \pKinds ->
       withArray nodes $ \pNodes ->
       withArray ctls  $ \pCtls  ->
         c_rt_graph_template_connect_fused_affine_input g cTid
           dstNode dstPort
           (cNodeIndex srcN)
           (cPortIndex srcP)
           n pKinds pNodes pCtls
  where
    stepKind (AffScale _ _) = 0 :: CInt
    stepKind (AffBias  _ _) = 1
    stepNode (AffScale n _) = n
    stepNode (AffBias  n _) = n
    stepCtl  (AffScale _ c) = c
    stepCtl  (AffBias  _ c) = c

-- | Transfer a compiled 'RuntimeGraph' to the C++ runtime.
-- Validates the region schedule first, then clears any existing
-- graph state, adds nodes, wires connections, and registers
-- regions in scheduled execution order.
--
-- Schedule validation runs /before/ 'c_rt_graph_clear', so a
-- malformed graph (cycle in 'regionDependencies', non-ascending
-- 'rgRuntimeRegions', etc.) raises 'fail' without disturbing the
-- currently loaded graph. Clearing first thereafter gives the
-- runtime a chance to stop any live audio stream associated
-- with the old graph before loading the new one.
--
-- See Note [Two-pass loading].
-- See Note [FFI boundary design].
loadRuntimeGraph :: Ptr RTGraph -> RuntimeGraph -> IO ()
loadRuntimeGraph g rg = do
  -- §4.E.2b: route the region overlay through 'regionSchedule'.
  -- Compute the schedule /before/ touching the C++ handle so a
  -- broken regionDependencies / region-list invariant cannot
  -- leave the runtime in a half-cleared state.
  scheduled <- case scheduledRuntimeRegions rg of
    Right rs -> pure rs
    Left err -> fail $ "loadRuntimeGraph: " <> err
  -- §4.E.2.C0a: also derive the layered schedule up-front so the
  -- pre-clear validation gate covers the metadata path. Both calls
  -- run 'regionSchedule' internally, so a Left here is impossible
  -- after the previous bind succeeded; the case is left in for
  -- coverage rather than for live failure.
  steps <- case layeredRegionSchedule rg of
    Right ss -> pure ss
    Left err -> fail $ "loadRuntimeGraph: " <> err
  case validateGeneratedPrograms rg of
    Right ()  -> pure ()
    Left err  -> fail $ "loadRuntimeGraph: " <> err
  c_rt_graph_clear g
  -- §6.C.5: writer templates are monophonic at the loader boundary.
  -- The Haskell clamp is declarative; the runtime in rt_graph.cpp
  -- holds the same invariant against direct-C-ABI callers.
  clampWriterPolyphonyRG g 0 rg
  -- Pass 0: size the shared bus pool to cover every bus this graph
  -- references. Construction-only; must run before audio starts.
  -- See Note [Explicit bus-pool sizing] in rt_graph.cpp.
  mapM_ ensureBusForNode (rgNodes rg)
  -- Pass 1: add nodes and set control values.
  -- See Note [Two-pass loading].
  mapM_ addNode (rgNodes rg)
  -- Pass 2: wire connections (all nodes now exist).
  mapM_ wireNode (rgNodes rg)
  -- Pass 2.5 (§7.D): push the generated-fusion program table so
  -- regions referencing 'FusionProgramId' can resolve at
  -- registration time. Empty for every graph 'compileRuntimeGraph'
  -- produces today; the equivalence test loads programs into a
  -- hand-built 'RuntimeGraph'.
  loadFusionProgramsTo g 0 (rgFusionPrograms rg)
  -- Pass 3: register the region overlay on template 0 in
  -- /scheduled/ order (today this is identical to rrIndex order;
  -- the planner is the identity when 'compileRuntimeGraph'
  -- produces a topologically valid rrIndex sequence). The C++
  -- side iterates regions in process_instance in registration
  -- order. See Note [Region fallback] in rt_graph.cpp.
  mapM_ (addRegion 0) scheduled
  -- Pass 4 (§4.E.2.C0a): ship the layered-schedule view as
  -- per-step ordinal lists over the same scheduled order. Default
  -- execution ignores it; the C0c test executor consumes it when
  -- explicitly enabled. Must run after the region pass so the
  -- runtime can range-check each ordinal.
  addScheduleStepsTo g 0 scheduled steps
  where
    addNode :: RuntimeNode -> IO ()
    addNode node = do
      c_rt_graph_add_node g
        (cNodeIndex (rnIndex node))
        (kindTag    (rnKind  node))
      setMigrationKeyForNode g 0 node
      forM_ (zip [0 ..] (rnControls node)) $ \(i, v) ->
        c_rt_graph_set_control g
          (cNodeIndex    (rnIndex node))
          (cControlIndex (ControlIndex i))
          (CDouble v)

    ensureBusForNode :: RuntimeNode -> IO ()
    ensureBusForNode node =
      case busIndexOf node of
        Just bus -> c_rt_graph_ensure_bus g (fromIntegral bus)
        Nothing  -> pure ()

    wireNode :: RuntimeNode -> IO ()
    wireNode node =
      forM_ (zip [0 ..] (rnInputs node)) $ \(i, inp) ->
        case inp of
          RFrom src srcPort ->
            c_rt_graph_connect g
              (cNodeIndex src)
              (cPortIndex srcPort)
              (cNodeIndex (rnIndex node))
              (cPortIndex (PortIndex i))
          RConst _ ->
            pure ()
          RFused _ ->
            -- 'fuseRuntimeGraph' is the only source of RFused. The
            -- unfused single-template loader rejects it explicitly:
            -- silently dropping the fused input would leave the
            -- consumer's port unwired, miswiring the runtime graph
            -- in a way that produces wrong audio with no obvious
            -- failure. Use 'loadRuntimeGraphFused' for fused graphs.
            fail "loadRuntimeGraph: RFused input requires the fused \
                 \loader; use loadRuntimeGraphFused or pass an \
                 \unfused RuntimeGraph."

    addRegion :: CInt -> RuntimeRegion -> IO ()
    addRegion = addRegionTo g

{- Note [loadRuntimeGraphFused protocol]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Fused sibling of 'loadRuntimeGraph'. Accepts both fused and unfused
'RuntimeGraph' values; on a graph that contains no 'RFused'
inputs and no 'rnElided' nodes, the wire-level effect is identical
to 'loadRuntimeGraph'. On a fused graph it additionally:

  Pass 2b — for every 'RFused' input, dispatches to the matching
            fused-* connect ABI entry: single-scale, scale chain, or
            affine (mixed scale + bias). Must follow Pass 2 (regular
            wires) so the override lands on a fully-wired spec, and
            must precede the region pass so the FusedAffineRef is in
            place before any later instance spawn allocates scratch.
  Pass 2c — emits 'rt_graph_template_set_node_elided' for every
            elided node. Order vs. 2b doesn't matter — the dispatch
            skip and the resolver redirection are independent —
            but doing it last keeps the audit trail
            "wire everything, then mark nodes that get skipped."

The single-template auto-spawn ('rt_graph_clear' creates instance 0)
runs before any of these passes. The fused-connect helper grows
that pre-existing instance's 'fused_scratch' in lockstep, so by the
time the audio callback can fire, every live instance has the
right slot count.
-}

-- | Fused-aware single-template loader. Equivalent to
-- 'loadRuntimeGraph' on graphs from 'compileRuntimeGraph' (no
-- 'RFused' / no 'rnElided'); on graphs from
-- 'compileRuntimeGraphFused' it additionally wires fused inputs
-- (single-scale, scale chain, or affine) and marks elided nodes
-- via the dedicated ABI entries.
--
-- See Note [loadRuntimeGraphFused protocol].
loadRuntimeGraphFused :: Ptr RTGraph -> RuntimeGraph -> IO ()
loadRuntimeGraphFused g rg = do
  -- §4.E.2b: same scheduled-regions pre-validation as the unfused
  -- loader. Compute before touching the C++ handle.
  scheduled <- case scheduledRuntimeRegions rg of
    Right rs -> pure rs
    Left err -> fail $ "loadRuntimeGraphFused: " <> err
  steps <- case layeredRegionSchedule rg of
    Right ss -> pure ss
    Left err -> fail $ "loadRuntimeGraphFused: " <> err
  case validateGeneratedPrograms rg of
    Right ()  -> pure ()
    Left err  -> fail $ "loadRuntimeGraphFused: " <> err
  c_rt_graph_clear g
  -- §6.C.5: same writer-monophonic clamp as the unfused loader.
  clampWriterPolyphonyRG g 0 rg
  mapM_ ensureBusForNode (rgNodes rg)
  mapM_ addNode (rgNodes rg)
  -- Pass 2: regular RFrom wiring. RFused / RConst are no-ops here;
  -- the fused inputs land in pass 2b instead of failing.
  mapM_ wireNode (rgNodes rg)
  -- Pass 2b: register fused-input overrides. Each RFused input
  -- becomes one fused-* connect call on template 0; the constructor
  -- of the carried 'FusedInput' selects the matching ABI entry
  -- (single-scale, scale chain, or affine). See 'wireFusedScale'.
  mapM_ wireFusedNode (rgNodes rg)
  -- Pass 2c: mark elided nodes so dispatch skips them. Must run
  -- after fused inputs are registered (the resolver redirects via
  -- the fused override regardless of the elided bit, but a node
  -- left elided without a fused override on every consumer would
  -- still be skipped and produce silence).
  mapM_ markElided (rgNodes rg)
  -- Pass 2d (§7.D): push the generated-fusion program table. Same
  -- contract as the unfused loader: empty for every graph produced
  -- by 'compileRuntimeGraph' / 'fuseRuntimeGraph'; the equivalence
  -- test loads programs into a hand-built 'RuntimeGraph'.
  loadFusionProgramsTo g 0 (rgFusionPrograms rg)
  -- Pass 3: region overlay in scheduled order (same contract as
  -- the unfused loader).
  mapM_ (addRegionTo g 0) scheduled
  -- Pass 4 (§4.E.2.C0a): same metadata pass as the unfused loader.
  addScheduleStepsTo g 0 scheduled steps
  where
    addNode :: RuntimeNode -> IO ()
    addNode node = do
      c_rt_graph_add_node g
        (cNodeIndex (rnIndex node))
        (kindTag    (rnKind  node))
      setMigrationKeyForNode g 0 node
      forM_ (zip [0 ..] (rnControls node)) $ \(i, v) ->
        c_rt_graph_set_control g
          (cNodeIndex    (rnIndex node))
          (cControlIndex (ControlIndex i))
          (CDouble v)

    ensureBusForNode :: RuntimeNode -> IO ()
    ensureBusForNode node =
      case busIndexOf node of
        Just bus -> c_rt_graph_ensure_bus g (fromIntegral bus)
        Nothing  -> pure ()

    wireNode :: RuntimeNode -> IO ()
    wireNode node =
      forM_ (zip [0 ..] (rnInputs node)) $ \(i, inp) ->
        case inp of
          RFrom src srcPort ->
            c_rt_graph_connect g
              (cNodeIndex src)
              (cPortIndex srcPort)
              (cNodeIndex (rnIndex node))
              (cPortIndex (PortIndex i))
          RConst _ -> pure ()
          RFused _ -> pure ()  -- handled in wireFusedNode

    wireFusedNode :: RuntimeNode -> IO ()
    wireFusedNode node =
      forM_ (zip [0 ..] (rnInputs node)) $ \(i, inp) ->
        case inp of
          RFused fused ->
            wireFusedScale g 0
              (cNodeIndex (rnIndex node))
              (cPortIndex (PortIndex i))
              fused
          _ -> pure ()

    markElided :: RuntimeNode -> IO ()
    markElided node =
      when (rnElided node) $
        c_rt_graph_template_set_node_elided g 0
          (cNodeIndex (rnIndex node))

{- Note [loadTemplateGraph protocol]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The multi-template counterpart of 'loadRuntimeGraph'. The protocol is:

  1. rt_graph_clear(g) — resets to template 0 (empty MetaDef) +
     instance 0 (empty GraphInstance of template 0). The auto-
     created instance 0 is the legacy single-template world; we
     remove it immediately because the multi-template flow spawns
     fresh instances per template explicitly.

  2. For each template in 'tgTemplates' (which is already in
     execution order — that's compileTemplateGraph's job):

     a. The first template uses the auto-created template_id 0;
        subsequent templates call rt_graph_template_add to allocate
        a new template_id. By construction, the C-side template_id
        equals the position in tgTemplates.

     b. Two passes per template, mirroring loadRuntimeGraph:
        - Pass 1: rt_graph_template_add_node + per-control
          rt_graph_template_set_default (so future instances inherit
          the user-supplied defaults, not just kind defaults).
        - Pass 2: rt_graph_template_connect for each RFrom input.

     c. rt_graph_template_instance_add to spawn one instance of the
        template. This makes the typical "one voice per template"
        case work without callers having to spawn instances
        manually. For polyphony, callers spawn additional instances
        after loading.

The C-side template_id (registration order) equals the Haskell-side
position in tgTemplates. The 'tplID' field on the Haskell side is
the *input* position (set by compileTemplateGraph for diagnostics)
and may differ from the execution-order position; this function
always uses the execution-order position when crossing the FFI.

Per Note [Mixed foreign call safety], the c_rt_graph_clear call is
'safe' because it can stop a live audio stream; the per-template
add/connect/set/instance calls are 'unsafe' (graph-loading work,
synchronous, non-blocking).
-}

-- | Transfer a compiled 'TemplateGraph' to the C++ runtime.
-- Validates the per-template region schedule and template identity
-- token for every template /before/ clearing, then registers each
-- template in execution order, populates its nodes and wiring, and
-- spawns one instance per template. A malformed schedule or invalid
-- identity on /any/ template raises 'fail' before 'c_rt_graph_clear'
-- so the currently loaded graph is preserved.
--
-- See Note [loadTemplateGraph protocol].
loadTemplateGraph :: Ptr RTGraph -> TemplateGraph -> IO ()
loadTemplateGraph g tg =
  M.void (loadTemplateGraphWithAutoSpawns g tg)

-- | Instrumented sibling of 'loadTemplateGraph'. The load protocol is
-- identical, but the function returns the exact slot ids produced by
-- the loader-created auto-spawns. Rows are @(template_id, slot_id)@.
-- Session-mode installers use this to remove those slots without
-- assuming any slot-id formula.
loadTemplateGraphWithAutoSpawns :: Ptr RTGraph -> TemplateGraph -> IO [(Int, Int)]
loadTemplateGraphWithAutoSpawns g tg = do
  -- §4.E.2b / §4.E.2.C0a / §5.4.B: compute the scheduled region list,
  -- layered schedule, and template identity token for every template
  -- /before/ touching the C++ handle. If any template's metadata is
  -- malformed we fail fast and leave the existing graph alone.
  scheduledByTpl <- traverse scheduleOrFail (tgTemplates tg)
  c_rt_graph_clear g
  -- The clear left an auto-created instance 0 for legacy callers.
  -- Multi-template loading spawns its own instances per template
  -- below, so remove it first to start with a clean slate.
  c_rt_graph_instance_remove g 0
  forM (zip [0 ..] scheduledByTpl) $
    \(i, (tpl, identityBytes, scheduled, steps)) -> do
    cTid <- if i == (0 :: Int)
              then pure 0           -- auto-created template 0
              else c_rt_graph_template_add g
    -- Phase 5.4.B: ship the template name as the runtime's identity
    -- token so swap prepare can reject reorders that would migrate
    -- live state across semantically-different templates.
    setTemplateIdentityBytes g cTid (tplName tpl) identityBytes
    -- §6.C.5: clamp polyphony to 1 for buffer-writer templates so the
    -- §6.C.4 cross-template uniqueness check is not bypassed at
    -- runtime by spawning a second live instance of the same writer
    -- against the same frozen buffer id.
    clampWriterPolyphony g cTid tpl
    populateTemplate cTid (tplGraph tpl) scheduled steps
    -- Spawn one instance per template so the typical single-voice
    -- ensemble case works without explicit instance spawning. For
    -- polyphony, callers spawn additional instances afterwards via
    -- c_rt_graph_template_instance_add.
    slot <- c_rt_graph_template_instance_add g cTid
    pure (fromIntegral cTid, fromIntegral slot)
  where
    scheduleOrFail
      :: Template
      -> IO (Template, Maybe String, [RuntimeRegion], [ScheduleStep])
    scheduleOrFail tpl = do
      let rg = tplGraph tpl
      identityBytes <- templateIdentityBytesFromName
        "loadTemplateGraph" (tplName tpl)
      rs <- case scheduledRuntimeRegions rg of
        Right rs  -> pure rs
        Left err  -> fail $
          "loadTemplateGraph: template "
          <> show (tplName tpl) <> ": " <> err
      ss <- case layeredRegionSchedule rg of
        Right ss  -> pure ss
        Left err  -> fail $
          "loadTemplateGraph: template "
          <> show (tplName tpl) <> ": " <> err
      case validateGeneratedPrograms rg of
        Right () -> pure ()
        Left err -> fail $
          "loadTemplateGraph: template "
          <> show (tplName tpl) <> ": " <> err
      pure (tpl, identityBytes, rs, ss)

    populateTemplate
      :: CInt -> RuntimeGraph
      -> [RuntimeRegion] -> [ScheduleStep]
      -> IO ()
    populateTemplate cTid rg scheduled steps = do
      -- Pass 0: ensure every referenced bus exists on the shared
      -- pool before any control write. Construction-only; same
      -- contract as in loadRuntimeGraph. See Note [Explicit
      -- bus-pool sizing] in rt_graph.cpp.
      forM_ (rgNodes rg) $ \node ->
        case busIndexOf node of
          Just bus -> c_rt_graph_ensure_bus g (fromIntegral bus)
          Nothing  -> pure ()
      -- Pass 1: nodes + per-spec control defaults.
      forM_ (rgNodes rg) $ \node -> do
        c_rt_graph_template_add_node g cTid
          (cNodeIndex (rnIndex node))
          (kindTag    (rnKind  node))
        setMigrationKeyForNode g cTid node
        forM_ (zip [0 ..] (rnControls node)) $ \(ci, v) ->
          c_rt_graph_template_set_default g cTid
            (cNodeIndex    (rnIndex node))
            (cControlIndex (ControlIndex ci))
            (CDouble v)
      -- Pass 2: wire connections (all nodes now exist).
      forM_ (rgNodes rg) $ \node ->
        forM_ (zip [0 ..] (rnInputs node)) $ \(i, inp) ->
          case inp of
            RFrom src srcPort ->
              c_rt_graph_template_connect g cTid
                (cNodeIndex src)
                (cPortIndex srcPort)
                (cNodeIndex (rnIndex node))
                (cPortIndex (PortIndex i))
            RConst _ ->
              pure ()
            RFused _ ->
              -- See the matching note in 'loadRuntimeGraph': fail
              -- fast rather than miswire. Use 'loadTemplateGraphFused'
              -- to ship fused inputs across the FFI.
              fail "loadTemplateGraph: RFused input requires the \
                   \fused loader; use loadTemplateGraphFused or \
                   \pass an unfused TemplateGraph."
      -- Pass 2.5 (§7.D): generated-fusion program table for this
      -- template. Same contract as the single-template loader.
      loadFusionProgramsTo g cTid (rgFusionPrograms rg)
      -- Pass 3: register the region overlay in scheduled order
      -- (today identical to rrIndex order; see the matching note
      -- in 'loadRuntimeGraph'). See Note [Region fallback] in
      -- rt_graph.cpp.
      mapM_ (addRegionTo g cTid) scheduled
      -- Pass 4 (§4.E.2.C0a): layered-schedule metadata. Default
      -- execution ignores it; the C0c test executor consumes it
      -- when explicitly enabled.
      addScheduleStepsTo g cTid scheduled steps

-- | Fused-aware multi-template loader. Sibling of 'loadTemplateGraph'
-- that handles 'RFused' inputs and 'rnElided' nodes via the fused-*
-- connect ABI entries. Each template's
-- per-spec passes run in the same order as 'loadRuntimeGraphFused':
--
--   1. ensure-bus
--   2. add-node + set-default
--   3. wire RFrom connections
--   3b. wire RFused inputs (template-aware; dispatches to the
--       matching single-scale, scale-chain, or affine ABI entry)
--   3c. mark elided nodes
--   4. region overlay
--
-- The per-template instance spawn happens after all of these so
-- 'make_instance' picks up the spec's full @fused_input_count@ and
-- allocates scratch in one shot. See
-- Note [loadRuntimeGraphFused protocol] for the rationale on order.
loadTemplateGraphFused :: Ptr RTGraph -> TemplateGraph -> IO ()
loadTemplateGraphFused g tg = do
  -- §4.E.2b / §4.E.2.C0a / §5.4.B: pre-validate every
  -- template's schedule and identity, then derive its layered view;
  -- same fail-fast contract as 'loadTemplateGraph'.
  scheduledByTpl <- traverse scheduleOrFail (tgTemplates tg)
  c_rt_graph_clear g
  c_rt_graph_instance_remove g 0
  forM_ (zip [0 ..] scheduledByTpl) $
    \(i, (tpl, identityBytes, scheduled, steps)) -> do
    cTid <- if i == (0 :: Int)
              then pure 0
              else c_rt_graph_template_add g
    -- Phase 5.4.B: same identity wiring as the non-fused loader so
    -- fused and unfused multi-template paths reject reorders the
    -- same way.
    setTemplateIdentityBytes g cTid (tplName tpl) identityBytes
    -- §6.C.5: same writer-monophonic clamp as the non-fused loader.
    clampWriterPolyphony g cTid tpl
    populateTemplate cTid (tplGraph tpl) scheduled steps
    M.void $ c_rt_graph_template_instance_add g cTid
  where
    scheduleOrFail
      :: Template
      -> IO (Template, Maybe String, [RuntimeRegion], [ScheduleStep])
    scheduleOrFail tpl = do
      let rg = tplGraph tpl
      identityBytes <- templateIdentityBytesFromName
        "loadTemplateGraphFused" (tplName tpl)
      rs <- case scheduledRuntimeRegions rg of
        Right rs  -> pure rs
        Left err  -> fail $
          "loadTemplateGraphFused: template "
          <> show (tplName tpl) <> ": " <> err
      ss <- case layeredRegionSchedule rg of
        Right ss  -> pure ss
        Left err  -> fail $
          "loadTemplateGraphFused: template "
          <> show (tplName tpl) <> ": " <> err
      case validateGeneratedPrograms rg of
        Right () -> pure ()
        Left err -> fail $
          "loadTemplateGraphFused: template "
          <> show (tplName tpl) <> ": " <> err
      pure (tpl, identityBytes, rs, ss)

    populateTemplate
      :: CInt -> RuntimeGraph
      -> [RuntimeRegion] -> [ScheduleStep]
      -> IO ()
    populateTemplate cTid rg scheduled steps = do
      forM_ (rgNodes rg) $ \node ->
        case busIndexOf node of
          Just bus -> c_rt_graph_ensure_bus g (fromIntegral bus)
          Nothing  -> pure ()
      forM_ (rgNodes rg) $ \node -> do
        c_rt_graph_template_add_node g cTid
          (cNodeIndex (rnIndex node))
          (kindTag    (rnKind  node))
        setMigrationKeyForNode g cTid node
        forM_ (zip [0 ..] (rnControls node)) $ \(ci, v) ->
          c_rt_graph_template_set_default g cTid
            (cNodeIndex    (rnIndex node))
            (cControlIndex (ControlIndex ci))
            (CDouble v)
      forM_ (rgNodes rg) $ \node ->
        forM_ (zip [0 ..] (rnInputs node)) $ \(i, inp) ->
          case inp of
            RFrom src srcPort ->
              c_rt_graph_template_connect g cTid
                (cNodeIndex src)
                (cPortIndex srcPort)
                (cNodeIndex (rnIndex node))
                (cPortIndex (PortIndex i))
            RConst _ -> pure ()
            RFused _ -> pure ()  -- handled in the fused-input pass
      forM_ (rgNodes rg) $ \node ->
        forM_ (zip [0 ..] (rnInputs node)) $ \(i, inp) ->
          case inp of
            RFused fused ->
              wireFusedScale g cTid
                (cNodeIndex (rnIndex node))
                (cPortIndex (PortIndex i))
                fused
            _ -> pure ()
      forM_ (rgNodes rg) $ \node ->
        when (rnElided node) $
          c_rt_graph_template_set_node_elided g cTid
            (cNodeIndex (rnIndex node))
      -- Pass 2d (§7.D): generated-fusion program table for this
      -- template. Same contract as the single-template loaders.
      loadFusionProgramsTo g cTid (rgFusionPrograms rg)
      mapM_ (addRegionTo g cTid) scheduled
      -- Pass 4 (§4.E.2.C0a): layered-schedule metadata.
      addScheduleStepsTo g cTid scheduled steps

{- Note [Realtime audio lifecycle]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The realtime engine lives entirely on the C++ side.

The Haskell protocol is:

  1. Load the graph with loadRuntimeGraph.
  2. Call startAudio.
  3. Optionally call waitAudioStarted to confirm that the
     q_io / PortAudio callback has executed at least once.
  4. Let the callback drive DSP.
  5. Call stopAudio when finished.

Why expose waitAudioStarted separately instead of treating
startAudio as "ready"?

Because opening the stream and receiving the first callback
are related but distinct events. The runtime can start the
backend successfully and still need one callback cycle before
it is truly producing sound. The C++ side tracks that state
with an internal readiness flag set by the audio callback.
Haskell observes it only through rt_graph_wait_started.

This design keeps the realtime thread free of Haskell calls,
locks, and other surprises. The callback stays inside C++,
which is where realtime code belongs.
-}

-- | Start realtime audio output for a loaded runtime graph.
--
-- @outputChannels <= 0@ asks the runtime to infer the channel
-- count from the configured Out buses, with a minimum of 1.
--
-- @deviceID < 0@ asks the runtime to choose a default output
-- device (or the first compatible device if the default is not
-- usable).
--
-- Returns 0 on success and a negative error code on failure.
startAudio :: Ptr RTGraph -> Int -> Int -> IO Int
startAudio g outputChannels deviceID =
  fromIntegral <$> c_rt_graph_start_audio
    g
    (fromIntegral outputChannels)
    (fromIntegral deviceID)

-- | Wait until the realtime audio callback has run at least
-- once.
--
-- Returns 'True' once the engine is actually pulling audio.
-- Returns 'False' on timeout or if the runtime reports an
-- error.
--
-- A negative timeout requests an indefinite wait.
waitAudioStarted :: Ptr RTGraph -> Int -> IO Bool
waitAudioStarted g timeoutMs =
  (== 0) <$> c_rt_graph_wait_started g (fromIntegral timeoutMs)

-- | Stop realtime audio output if it is running.
--
-- This is idempotent from the Haskell caller's point of view:
-- calling it on an already stopped graph is harmless.
stopAudio :: Ptr RTGraph -> IO ()
stopAudio = c_rt_graph_stop_audio
