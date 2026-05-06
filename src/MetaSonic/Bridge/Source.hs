{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}

-- |
-- Module      : MetaSonic.Source
-- Description : Source-level graph construction DSL
--
-- The user-facing language for building synthesis graphs.
-- This module is entirely surface syntax — it records the
-- user's intent without computing what the graph means.
--
-- See Note [Surface syntax vs semantic syntax] for how this
-- module relates to the deeper compilation passes.
--
-- See Note [Builder monad design] for why graph construction
-- uses strict State rather than a free monad.

module MetaSonic.Bridge.Source
  ( -- * Source-level types
    Connection (..)
  , UGen (..)
  , NodeSpec (..)
  , SynthGraph (..)
  , emptyGraph
  , -- * Builder monad
    SynthM
  , runSynth
  , -- * DSL combinators (constant inputs)
    sinOsc
  , sawOsc
  , noiseGen
  , out
  , gain
  , lpf
  , -- * DSL combinators (modulatable inputs)
    --
    -- $modulation
    audio
  , sinOsc'
  , sawOsc'
  , gain'
  , lpf'
  , -- * Dependency extraction
    dependencies
  ) where

import           Control.DeepSeq            (NFData)
import           Control.Monad              (void)
import           Control.Monad.State.Strict
import qualified Data.Map.Strict            as M
import           GHC.Generics               (Generic)

import           MetaSonic.Types

{- Note [Surface syntax vs semantic syntax]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
One can distinguish surface syntax (what the user writes)
from semantic syntax (the compiler's internal account of signal
equations, state transitions, staging boundaries, and resource
constraints).

This module is entirely surface syntax:

  - UGen constructors (SinOsc, Out, Gain) name DSP primitives
  - Connection values (Audio, Param) describe wiring
  - SynthGraph is an unordered map of node specifications
  - No rates, no effects, no execution order

The semantic account begins in MetaSonic.IR, where lowerGraph
strips the DSL vocabulary and annotates each node with Rate
and Eff metadata. A future MetaSonic.Semantic module would go
further, deriving signal expressions by symbolic propagation
(following Faust's strategy) rather than preserving node
granularity.

See Note [Rate discipline] in MetaSonic.Types for the
annotation system that the IR introduces.
-}

{- Note [Connection design]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
A Connection is the atomic unit of wiring in the source graph.
It is either an audio-rate edge from another node's output
port (Audio NodeID PortIndex), or a literal parameter value
(Param Float).

This distinction matters for compilation:

  - A Param is a compile-time constant. It carries no
    dependency, imposes no execution ordering, and will be
    lowered to a control slot in the C++ runtime.

  - An Audio connection creates a data dependency: the source
    node must be computed before the destination node. This
    dependency is extracted by the dependencies function and
    drives topological sorting in MetaSonic.Validate.

Every UGen input is uniformly a Connection, which means the
compiler can extract the dependency graph from UGen structure
alone — no special cases, no implicit wiring.

See Note [Structural vs implicit dependencies] for how this
relates to the effect-dependency system.
-}

{- Note [Structural vs implicit dependencies]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The dependencies function extracts only structural
dependencies — the explicit Audio edges drawn by the user.
Param values are dependency-free.

This is sufficient for topological sorting and for the current
sequential runtime, but it is not sufficient for correct
parallel execution.

Semantically schedulable graph must also include implicit
dependencies derived from resource effects:

  G* = (N, E_s ∪ E_r ∪ E_t)

where E_s are structural edges (what dependencies extracts),
E_r are resource-induced edges, and E_t are temporal or
rate-boundary edges.

Implicit dependencies are computed later, after annotation, in
a future MetaSonic.Effects module using the Eff annotations on
NodeIR. At this level (source syntax), we extract only E_s.

See Note [Resource effects] in MetaSonic.Types.
-}

-- | A connection to a node input: either an audio edge from
-- another node's output, or a literal constant.
--
-- See Note [Connection design].
data Connection
  = Audio !NodeID !PortIndex
    -- ^ An audio-rate edge. Creates a data dependency that
    -- constrains execution order.
  | Param !Float
    -- ^ A literal parameter value. No dependency; known at
    -- graph construction time.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

{- Note [UGen extensibility]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Each UGen constructor defines a DSP primitive. The
constructor's fields are Connections, not raw values — every
input is uniformly either a constant or a dependency.

The current set is still small for simplicity, but it now distinguishes between
two different routing roles that were previously blurred together:

  SinOsc  — oscillator, a signal source
  Gain    — stateless signal transform
  BusOut  — write a signal to an intermediate shared bus
  BusIn   — read a signal from an intermediate shared bus
  Out     — write a signal to a final hardware output channel

This distinction matters architecturally.

BusOut and BusIn model internal routing between subgraphs or synth regions. They
are not final output. Their semantics are tied to shared resources, ordering
constraints, and planned effect-aware scheduling.

Out, by contrast, is reserved for final hardware-facing output. It is the
terminal step, a side-effect-only "sink".

That separation keeps the source language aligned with the intended runtime.

It also prepares the compiler for future effect analysis:

  BusOut bus  — will carry BusWrite bus
  BusIn bus   — will carry BusRead bus
  Out chan    — remains a terminal hardware-output node

Adding a new UGen constructor still requires coordinated
changes across the Haskell and C++ sides.
-}

-- | A unit generator specification.
--
-- 'UGen' is the source-level vocabulary of primitive graph
-- nodes. Each constructor describes one DSP or routing
-- operation before lowering to IR and dense runtime form.
--
-- At this level, the graph is still expressed as primitive
-- nodes and explicit connections. This makes 'UGen' a unit-
-- node DAG representation in the current prototype.
--
-- Later compilation passes may group several source nodes into
-- regions or fused kernels, so the final runtime unit need not
-- correspond one-to-one with a single 'UGen'. Even so, 'UGen'
-- remains the basic source-level notion of a primitive node in
-- the graph. At least in the currect vocabulaty.
--
-- Routing is intentionally split into two layers:
--
--   * 'BusOut' and 'BusIn' are for intermediate shared-bus
--     communication between subgraphs or synth regions.
--
--   * 'Out' is reserved for final output.
--
-- This avoids overloading one constructor with two different
-- meanings and keeps the source DSL closer to the runtime model.
data UGen
  = Out !Int !Connection
    -- ^ Final hardware output: output channel, input signal.
    --
    -- Writes a signal to a hardware-facing output channel.
    -- This is a terminal routing node, conceptually distinct
    -- from shared-bus communication.
  | BusOut !Int !Connection
    -- ^ Shared-bus write: bus index, input signal.
    --
    -- Writes a signal to an intermediate bus that may be read
    -- later by other subgraphs or synth regions.
    --
    -- This is a shared-resource operation and will eventually
    -- carry a 'BusWrite' effect.
  | BusIn !Int
    -- ^ Shared-bus read: bus index.
    --
    -- Reads a signal from an intermediate shared bus and
    -- reintroduces it into the graph as a source node.
  | SinOsc !Connection !Connection
    -- ^ Sine oscillator: frequency, initial phase.
  | SawOsc !Connection !Connection
    -- ^ Bandlimited sawtooth oscillator: frequency, initial phase.
  | NoiseGen
    -- ^ White noise generator. No connections; pure source.
  | LPF !Connection !Connection !Connection
    -- ^ Low-pass filter: signal in, cutoff frequency, Q factor.
  | Gain !Connection !Connection
    -- ^ Multiply: input signal, gain amount.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)


-- | A node in the source graph: a named UGen at a
-- particular symbolic identity.
data NodeSpec = NodeSpec
  { nsID   :: !NodeID
  , nsName :: !String
    -- ^ Human-readable label (for debugging / printing).
  , nsUgen :: !UGen
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | The source graph: a map from symbolic 'NodeID' to
-- 'NodeSpec'. Order is not yet fixed — that is the job of
-- topological sorting in "MetaSonic.Validate".
--
-- See Note [Topological sort as compilation target] in
-- MetaSonic.Validate.
data SynthGraph = SynthGraph
  { sgNodes :: !(M.Map NodeID NodeSpec)
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

emptyGraph :: SynthGraph
emptyGraph = SynthGraph M.empty

{- Note [Builder monad design]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Graph construction is a compilation activity, not a real-time
activity. The builder monad is a strict State transformer that
allocates fresh NodeIDs and accumulates NodeSpecs into a
SynthGraph.

The choice of strict State (rather than a free monad or a
Writer) is pragmatic:

  - Strict State with BangPatterns ensures the counter and
    graph are fully evaluated at each step. No thunks
    accumulate during the build phase.

  - The monadic interface (do-notation, fresh ID allocation,
    returning NodeID for downstream wiring) is natural for
    graph construction where nodes refer to earlier nodes.

  - The underlying idea is still algebraic: a synthesis graph
    is formed by composing primitives and introducing named
    dependencies between them.

The source DSL can be reformulated as a typed algebra over signal
combinators rather than only as a node-building API. That allows more
static rejection of ill-typed graphs and cleaner elaboration into
semantic IR. Currently, sinOsc, out, and gain each produce a
single primitive node; higher-level combinators (chain,
parallel, mix) would elaborate down to this level.
-}

data SynthState = SynthState
  { ssNextID :: !Int
  , ssGraph  :: !SynthGraph
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | The graph builder monad. Strict 'State' over a counter
-- and accumulating 'SynthGraph'.
--
-- See Note [Builder monad design].
type SynthM a = State SynthState a

-- | Run a graph builder and extract the resulting
-- 'SynthGraph'. The builder's return value is discarded;
-- the graph is the product.
runSynth :: SynthM a -> SynthGraph
runSynth m = ssGraph (execState m (SynthState 0 emptyGraph))

-- | Allocate a fresh 'NodeID'. Strict in the counter to
-- avoid thunk accumulation.
freshNodeID :: SynthM NodeID
freshNodeID = do
  st <- get
  let !n  = ssNextID st
      !n' = n + 1
  put st { ssNextID = n' }
  pure (NodeID n)

-- | Register a node in the graph. Shared implementation
-- behind all DSL combinators.
insertNode :: String -> UGen -> SynthM NodeID
insertNode name ugen = do
  nid <- freshNodeID
  st  <- get
  let !spec  = NodeSpec nid name ugen
      !graph = ssGraph st
      !nodes = M.insert nid spec (sgNodes graph)
  put st { ssGraph = graph { sgNodes = nodes } }
  pure nid

{- Note [DSL combinator design]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Each combinator constructs a single node and returns its
NodeID, which can then be passed as a Connection to downstream
nodes:

  do osc <- sinOsc 440.0 0.0
     g   <- gain osc 0.5
     out 0 g

The returned NodeID is the handle that the caller uses to wire
this node's output into other nodes' inputs. This is the
"named dependency" pattern: every dependency is explicit and
named.

Currently the combinators take raw Floats and produce Param
connections internally. A future typed DSL could distinguish
audio-rate signals from control-rate signals at the type
level, preventing wiring errors statically rather than
catching them in checkRateEdges (MetaSonic.IR).

Higher-level combinators (chain, parallel, mix, templates)
would elaborate down to these primitives, making the
elaboration pass a meaningful transformation rather
than identity.
-}

-- | Create a sine oscillator with a fixed frequency and
-- initial phase.
sinOsc :: Float -> Float -> SynthM NodeID
sinOsc freq phase =
  insertNode "sinOsc" (SinOsc (Param freq) (Param phase))

-- | Create a bandlimited sawtooth oscillator.
sawOsc :: Float -> Float -> SynthM NodeID
sawOsc freq phase =
  insertNode "sawOsc" (SawOsc (Param freq) (Param phase))

-- | Create a white noise generator.
noiseGen :: SynthM NodeID
noiseGen = insertNode "noiseGen" NoiseGen

-- | Create a low-pass filter.
lpf :: NodeID -> Float -> Float -> SynthM NodeID
lpf src freq q =
  insertNode "lpf" (LPF (Audio src (PortIndex 0)) (Param freq) (Param q))

-- | Create a hardware output node.
--
-- Writes a signal to a final output channel intended for the
-- audio device. The @Int@ argument sets the output channel
--
-- This is a terminal node.
out :: Int -> NodeID -> SynthM ()
out channel src =
  void $ insertNode "out" (Out channel (Audio src (PortIndex 0)))


-- | Write a signal to a shared intermediate bus.
--
-- The Int argument selects the bus index. The signal written
-- here may be read later by other subgraphs or synth fragments
-- using 'busIn'.
--
-- Unlike 'out', this does not target the hardware device. It is
-- part of the internal routing.
--
-- This is a terminal node: it introduces a side effect
-- (writing to a bus) but doesn't returns/produce a downstream signal.
busOut :: Int -> NodeID -> SynthM ()
busOut bus src =
  void $ insertNode "busOut" (BusOut bus (Audio src (PortIndex 0)))


-- | Read a signal from a shared intermediate bus.
--
-- The @Int@ argument selects the bus index. The returned
-- 'NodeID' can be used as a signal source for further
-- processing
--
-- This is the dual of 'busOut'. It introduces a signal into
-- the graph without requiring an explicit structural edge,
-- and will carry a 'BusRead' effect.
busIn :: Int -> SynthM NodeID
busIn bus = insertNode "busIn" (BusIn bus)


gain :: NodeID -> Float -> SynthM NodeID
gain src amount =
  insertNode "gain" (Gain (Audio src (PortIndex 0)) (Param amount))

{- $modulation

The primed combinators ('sinOsc'', 'sawOsc'', 'gain'', 'lpf'') accept raw
'Connection' values for every input slot, so any input can be either a
'Param' constant or an 'Audio' edge from another node's output. This is
how one node modulates another at audio rate (FM, AM, ring modulation,
audio-rate filter cutoff).

The unprimed combinators are kept for the common case where every input
is a constant.

>>> -- Ring modulation: carrier * modulator at audio rate
>>> ringModGraph = runSynth $ do
>>>   carrier   <- sinOsc 440.0 0.0
>>>   modulator <- sinOsc 7.0 0.0
>>>   ring      <- gain' (audio carrier) (audio modulator)
>>>   out 0 ring

The 'audio' helper lifts a 'NodeID' to a 'Connection' on output port 0
(the only port any current UGen exposes).
-}

-- | Lift a 'NodeID' to an audio-rate 'Connection' on output port 0.
audio :: NodeID -> Connection
audio n = Audio n (PortIndex 0)

-- | Sine oscillator with explicit 'Connection' inputs. Either input may
-- be a 'Param' constant or an 'Audio' edge from another node, enabling
-- audio-rate frequency modulation (FM) and phase modulation.
sinOsc' :: Connection -> Connection -> SynthM NodeID
sinOsc' freq phase = insertNode "sinOsc" (SinOsc freq phase)

-- | Bandlimited sawtooth with explicit 'Connection' inputs.
sawOsc' :: Connection -> Connection -> SynthM NodeID
sawOsc' freq phase = insertNode "sawOsc" (SawOsc freq phase)

-- | Multiply with explicit 'Connection' inputs. With both inputs as
-- 'Audio' edges this is sample-accurate amplitude modulation (ring
-- modulation when both signals are bipolar).
gain' :: Connection -> Connection -> SynthM NodeID
gain' sig amount = insertNode "gain" (Gain sig amount)

-- | Low-pass filter with explicit 'Connection' inputs. Note: audio-rate
-- modulation of cutoff or Q produces zipper artifacts with the current
-- biquad implementation; treat this as control-rate for now.
lpf' :: Connection -> Connection -> Connection -> SynthM NodeID
lpf' sig freq q = insertNode "lpf" (LPF sig freq q)

-- | Extract explicit structural 'NodeID' dependencies from
-- a 'UGen'.
--
-- Only 'Audio' connections contribute dependencies. 'Param'
-- values are dependency-free.
--
-- Note that 'BusIn' introduces no explicit structural edge at
-- this level: it reads from a shared bus rather than from the
-- output port of another node. Any ordering constraints induced
-- by bus communication must therefore be recovered later from
-- _effect annotations_ rather than from the structural graph
-- alone.
dependencies :: UGen -> [NodeID]
dependencies = \case
  Out _ a     -> deps [a]
  BusOut _ a  -> deps [a]
  BusIn _     -> []
  SinOsc a b  -> deps [a, b]
  SawOsc a b  -> deps [a, b]
  NoiseGen    -> []
  LPF a b c   -> deps [a, b, c]
  Gain a b    -> deps [a, b]
  where
    deps = foldr step []
    step (Audio nid _) acc = nid : acc
    step (Param _)     acc = acc
