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
  , -- * Lifecycle
    withRTGraph
  , -- * Loading a compiled graph
    loadRuntimeGraph
  , -- * Realtime audio lifecycle
    startAudio
  , waitAudioStarted
  , stopAudio
  , -- * Low-level (re-exported for tests / experimentation)
    c_rt_graph_process
  , c_rt_graph_start_audio
  , c_rt_graph_wait_started
  , c_rt_graph_stop_audio
  ) where

import           Control.Exception        (bracket)
import           Control.Monad            (forM_)
import           Foreign
import           Foreign.C.Types

import           MetaSonic.Bridge.Compile (RuntimeGraph (..), RuntimeInput (..),
                                           RuntimeNode (..))
import           MetaSonic.Types

{- Note [FFI boundary design]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
On the Haskell side, the graph is a rich, typed, annotated
structure with symbolic identities, rate tags, effect
annotations, and region membership. On the C++ side, it is a
flat array of execution units with dense index references.

This module translates between those two worlds through a
small C ABI defined in rt_graph.h:

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

The integer-based wire format (node kinds as ints, indices as
ints, controls as floats) is deliberately simple: it avoids
any C++ types in the ABI, ensuring that the boundary is
portable and trivially serializable.

Graph loading is expected to succeed by construction. If the
Haskell compiler produces a valid RuntimeGraph, no bad-index
or unknown-kind paths should fire in the runtime. Realtime
startup is different: opening an audio device can fail for
reasons outside compilation (no device, unsupported channel
count, backend error), so the audio lifecycle calls return
status codes.

See Note [Dense lowering] in MetaSonic.Compile for what
guarantees the runtime indices are valid.
-}

{- Note [Why ccall, not capi]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
These imports use ccall, not capi.

That is intentional. The C++ side exports plain C ABI symbols
from rt_graph.h via extern "C". There is no varargs API, no
macro indirection, and no need to route through a C wrapper
header. capi would work too, but it would not buy us anything
for this ABI.

The important distinction for this module is not ccall vs
capi. It is unsafe vs safe, described below.
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

A subtle but important consequence of the new realtime path is
that rt_graph_clear and rt_graph_destroy are no longer
obviously "cheap": the C++ runtime is allowed to stop an
active PortAudio stream inside them before clearing or freeing
state. That makes safe the correct default on the Haskell
side.

Note that safe does NOT mean "wait until the audio callback is
ready". Readiness is a separate protocol step handled by
rt_graph_wait_started. The audio callback itself remains fully
inside C++; it does not call back into Haskell.
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

The two-pass structure is necessary because rt_graph_connect
requires both the source and destination nodes to already
exist in the C++ graph. Since nodes are added in execution
order (source before destination, guaranteed by
Note [Execution order invariant] in MetaSonic.IR), pass 1
ensures all endpoints exist before pass 2 wires them.

RConst inputs do not generate connect calls. Their values are
already set as control defaults in pass 1.

One more consequence of the realtime engine: loadRuntimeGraph
begins with rt_graph_clear, and rt_graph_clear is allowed to
stop a currently running audio stream. So hot reloading is a
"stop, clear, rebuild" operation from the runtime's point of
view. If the caller wants audio again after reloading, it must
call startAudio once loading completes.
-}

-- | Opaque handle to the C++ runtime graph. The Haskell side
-- never inspects its contents.
--
-- See Note [FFI boundary design].
data RTGraph

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
  c_rt_graph_set_control :: Ptr RTGraph -> CInt -> CInt -> CFloat -> IO ()

foreign import ccall unsafe "rt_graph_connect"
  c_rt_graph_connect :: Ptr RTGraph -> CInt -> CInt -> CInt -> CInt -> IO ()

foreign import ccall unsafe "rt_graph_process"
  c_rt_graph_process :: Ptr RTGraph -> CInt -> IO ()

foreign import ccall safe "rt_graph_start_audio"
  c_rt_graph_start_audio :: Ptr RTGraph -> CInt -> CInt -> IO CInt

foreign import ccall safe "rt_graph_wait_started"
  c_rt_graph_wait_started :: Ptr RTGraph -> CInt -> IO CInt

foreign import ccall safe "rt_graph_stop_audio"
  c_rt_graph_stop_audio :: Ptr RTGraph -> IO ()

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
withRTGraph :: Int -> Int -> (Ptr RTGraph -> IO a) -> IO a
withRTGraph capacity maxFrames =
  bracket
    (c_rt_graph_create (fromIntegral capacity) (fromIntegral maxFrames))
    c_rt_graph_destroy

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

-- | Transfer a compiled 'RuntimeGraph' to the C++ runtime.
-- Clears any existing graph state first, then adds nodes and
-- wires connections.
--
-- Clearing first gives the runtime a chance to stop any live
-- audio stream associated with the old graph before loading
-- the new one.
--
-- See Note [Two-pass loading].
-- See Note [FFI boundary design].
loadRuntimeGraph :: Ptr RTGraph -> RuntimeGraph -> IO ()
loadRuntimeGraph g rg = do
  c_rt_graph_clear g
  -- Pass 1: add nodes and set control values.
  -- See Note [Two-pass loading].
  mapM_ addNode (rgNodes rg)
  -- Pass 2: wire connections (all nodes now exist).
  mapM_ wireNode (rgNodes rg)
  where
    addNode :: RuntimeNode -> IO ()
    addNode node = do
      c_rt_graph_add_node g
        (cNodeIndex (rnIndex node))
        (kindTag    (rnKind  node))
      forM_ (zip [0 ..] (rnControls node)) $ \(i, v) ->
        c_rt_graph_set_control g
          (cNodeIndex    (rnIndex node))
          (cControlIndex (ControlIndex i))
          (CFloat v)

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
