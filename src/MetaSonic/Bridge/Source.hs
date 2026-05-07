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
  , runSynthWith
  , -- * DSL combinators
    --
    -- $combinators
    sinOsc
  , sawOsc
  , noiseGen
  , out
  , gain
  , lpf
  , add
  , env
  , busOut
  , busIn
  , busInDelayed
  , delayL
  , smooth
  , -- * Connection helpers
    audio
  , connectionNodeID
  , -- * Uniform UGen view
    UGenView (..)
  , ugenView
  , -- * Per-UGen projections used by lowering and scheduling
    inferKind
  , inferRate
  , inferEff
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
(Param Double).

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
  | Param !Double
    -- ^ A literal parameter value. No dependency; known at
    -- graph construction time.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

{- Note [Num/Fractional Connection]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'fromInteger' and 'fromRational' make 'Connection' a target of numeric
literal defaulting, so the user can write @sinOsc 440.0 0.0@ and have
the literals lower to @Param 440.0@ and @Param 0.0@. Without this,
every literal would need an explicit @Param@ wrapper.

Arithmetic operators are partial: 'Param a + Param b' folds to a single
'Param', but operating on an 'Audio' edge is a compile-time error
because there is no meaningful constant-folding for runtime signals.
The user-facing remedy is to use the 'add' or 'gain' graph nodes
instead, which represent that operation at the runtime level.
-}

instance Num Connection where
  fromInteger n = Param (fromInteger n)

  Param a + Param b = Param (a + b)
  l + r             = audioArithErr "(+)" [l, r]

  Param a * Param b = Param (a * b)
  l * r             = audioArithErr "(*)" [l, r]

  Param a - Param b = Param (a - b)
  l - r             = audioArithErr "(-)" [l, r]

  abs (Param a) = Param (abs a)
  abs c         = audioArithErr "abs" [c]

  signum (Param a) = Param (signum a)
  signum c         = audioArithErr "signum" [c]

  negate (Param a) = Param (negate a)
  negate c         = audioArithErr "negate" [c]

instance Fractional Connection where
  fromRational r = Param (fromRational r)

  Param a / Param b = Param (a / b)
  l / r             = audioArithErr "(/)" [l, r]

audioArithErr :: String -> [Connection] -> a
audioArithErr op _ = error $
  "Num/Fractional Connection: " <> op
  <> " on an audio-rate Connection is undefined at compile time. "
  <> "Use the 'add' or 'gain' graph nodes for runtime arithmetic."

{- Note [UGen extensibility]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Each UGen constructor defines a DSP primitive. The
constructor's fields are Connections, not raw values — every
input is uniformly either a constant or a dependency.

The current set covers signal sources, stateless transforms, an envelope
generator, bus routing, and a delay line:

  SinOsc, SawOsc, NoiseGen   — signal sources
  Gain, LPF, Add             — stateless signal transforms
  Env                        — ADSR envelope generator
  Out                        — write a signal to a hardware output channel
  BusOut                     — write a signal to a shared audio bus
  BusIn                      — read a signal from a shared audio bus
  BusInDelayed               — read the previous block's snapshot of a bus
                               (the feedback primitive)
  Delay                      — per-node fractional delay line (q::delay)

Adding a new UGen constructor requires coordinated changes across:

  - 'NodeKind' constructor + 'kindSpec' row in "MetaSonic.Types"
  - 'UGen' constructor + 'ugenView' row + builder in this module
  - per-instance 'inferEff' case in "MetaSonic.Bridge.IR" if effects
    depend on a constructor field (see 'BusOut' / 'BusIn')
  - C++ enum value, 'configure_node' case, 'process_*' kernel, and
    'process_graph' dispatch case in @rt_graph.cpp@

A property test in @test/Spec.hs@ cross-checks 'kindSpec' against
'ugenView' so the two sources of per-kind shape information cannot drift.
-}

{- Note [Bus model: SC-style same-cycle audio buses]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'Out', 'BusOut' and 'BusIn' all operate on the same underlying pool of
audio buses. The C++ runtime stores one 'output_buses' vector indexed by
bus number; the audio callback routes 'output_buses[0..output_channels-1]'
to hardware regardless of which UGen wrote to them. So 'Out' is, in the
runtime, just a 'BusOut' to a bus number that happens to be hardware-routed.

  Out 0     ≡  BusOut 0   when bus 0 is a hardware output
  BusOut 5  ≡  Out 5      if you reconfigure bus 5 as a hardware output

We keep 'Out' and 'BusOut' as separate UGen constructors at the source
level for documentation: 'Out' reads as "final output" while 'BusOut' reads
as "intermediate routing". They share the same C++ kernel.

Semantics within a block (mirrors SuperCollider's 'Out.ar' / 'In.ar'):

  - At the start of each block, every bus is zeroed.
  - 'BusOut n' accumulates its input additively into bus n. Multiple
    writers to the same bus sum.
  - 'BusIn n' reads the current contents of bus n.
  - Ordering: 'BusOut n' executes before 'BusIn n' in the same block, so
    'BusIn' always sees the live value. This is enforced by E_r edges
    derived from the 'BusWrite n' / 'BusRead n' effects on the writer/
    reader; the ordering is *not* a runtime convention but a compile-time
    edge in the dependency graph used by topological sort.

Cross-cycle ("delayed") read: 'BusInDelayed n' is the second reader form.
It reads the previous block's snapshot of bus n rather than the live
contents. Concretely:

  - 'BusInDelayed' carries 'BusReadDelayed n' as its effect, *not*
    'BusRead n'. The scheduler's E_r derivation (in
    "MetaSonic.Bridge.Validate") only pairs 'BusWrite' with 'BusRead' —
    it ignores 'BusReadDelayed' — so a 'BusInDelayed n' can sit anywhere
    in the topological order relative to 'BusOut n'.
  - The runtime maintains a double-buffered bus pool: at the start of
    each block it swaps the live and snapshot buffers and zeroes the
    new live buffer. 'BusOut' writes to live; 'BusIn' reads live;
    'BusInDelayed' reads the frozen snapshot of what the *previous*
    block wrote. See Note [Bus pool double-buffering] in
    @tinysynth/rt_graph.cpp@.
  - On the very first block the snapshot is zero (initial state), so a
    first-block 'BusInDelayed' produces silence — same as reading a
    bus that no one ever wrote.

This split lets the user express genuine feedback graphs without
introducing run-time graph rewriting or implicit delays. A graph like
'BusInDelayed n → gain → BusOut n' is valid: the only "cycle" closes
across the block boundary, where the snapshot buffer breaks the loop.
A graph that uses live 'BusIn n' instead of 'BusInDelayed n' inside a
feedback path is rejected by the cycle detector, exactly as before.

In SuperCollider terms, 'BusIn' corresponds to 'In.ar' and 'BusInDelayed'
corresponds to 'InFeedback.ar'.

See Note [Effect-induced edges (E_r)] in "MetaSonic.Bridge.Validate" for
the scheduling pass that derives the BusOut → BusIn edges, Note
[Resource effects] in "MetaSonic.Types" for the underlying 'Eff' type,
and Note [Bus pool double-buffering] in @tinysynth/rt_graph.cpp@ for
the runtime-side ping-pong implementation.
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
-- the graph.
--
-- See Note [Bus model: SC-style same-cycle audio buses] for how
-- 'Out', 'BusOut' and 'BusIn' relate.
data UGen
  = Out !Int !Connection
    -- ^ Hardware output: output channel, input signal.
    --
    -- Operationally identical to 'BusOut' on a bus number that the
    -- audio callback routes to hardware. Kept as a separate
    -- constructor for source-level documentation ("final output"
    -- vs. "intermediate routing"). Carries a 'BusWrite' effect on
    -- its channel number; same-cycle E_r ordering applies.
  | BusOut !Int !Connection
    -- ^ Audio-bus write: bus index, input signal.
    --
    -- Accumulates the input signal additively into the named bus
    -- over the block. Multiple writers to the same bus sum.
    -- Carries 'BusWrite n' as its effect, which produces an E_r
    -- edge to every same-bus 'BusIn' in the topological sort.
  | BusIn !Int
    -- ^ Audio-bus read: bus index.
    --
    -- Reads the current contents of the named bus into its output
    -- port. Carries 'BusRead n', which makes it execute *after*
    -- every 'BusOut' / 'Out' on the same bus in the same block —
    -- so 'BusIn' always sees the live, accumulated value.
  | BusInDelayed !Int
    -- ^ Audio-bus delayed read: bus index. Reads the *previous*
    -- block's accumulated contents of the named bus.
    --
    -- This is the feedback primitive. Carries 'BusReadDelayed n',
    -- which the scheduler does *not* convert into an E_r edge against
    -- same-bus 'BusWrite' — so a 'BusInDelayed n' may legally precede
    -- a 'BusOut n' in the topological order, closing a feedback path
    -- whose only cycle crosses the block boundary. The runtime swaps
    -- the live and snapshot bus buffers at the start of every block,
    -- so the snapshot 'BusInDelayed' reads is always exactly what the
    -- previous block wrote (zero on the very first block).
    --
    -- The delayed read is the SuperCollider 'InFeedback.ar' analogue;
    -- see Note [Bus model: SC-style same-cycle audio buses].
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
  | Add !Connection !Connection
    -- ^ Sum two inputs sample-by-sample. Either input may be a
    -- 'Param' constant (acting as a bias) or an 'Audio' edge.
    -- Used to bias a bipolar modulator off zero (turning ring mod
    -- into AM, or through-zero FM into vibrato).
  | Delay !Double !Connection !Connection
    -- ^ Per-node fractional delay line: max-delay (s, compile-time),
    -- input signal, delay time (s).
    --
    -- The maximum delay time is a compile-time 'Double' (not a
    -- 'Connection') because it determines the size of the per-node
    -- ring buffer the runtime allocates at graph load. Choose it
    -- as the worst-case delay your patch will ever request.
    --
    -- The actual delay time is a 'Connection' and may be a constant
    -- ('Param') or an audio-rate signal. With audio-rate modulation
    -- the read position is interpolated per sample (linear), so
    -- moving the delay time produces smooth pitch shifts via the
    -- usual delay-line tricks (chorus, flanger, vibrato).
    --
    -- Stateful: the buffer carries per-sample history. Effect is
    -- 'Pure' (the buffer is per-instance, not shared); rate is
    -- 'SampleRate' regardless of input rates.
    --
    -- See Note [Per-node delay state] in @tinysynth/rt_graph.cpp@.
  | Env !Connection !Connection !Connection !Connection !Connection
    -- ^ ADSR envelope generator: gate, attack (sec), decay (sec),
    -- sustain (linear 0..1), release (sec).
    --
    -- The gate is a sample-accurate trigger: a rising edge
    -- (0 → > 0.5) starts the attack phase, a falling edge starts
    -- the release phase. A/D/S/R are block-rate constants; A, D, R
    -- are durations in seconds, S is a linear amplitude in [0, 1].
    -- A 'Param' on the gate input acts as a constant gate value:
    -- @env (Param 1) ...@ holds the gate high indefinitely (handy
    -- for one-shot test graphs that never release).
    --
    -- The output is the envelope amplitude in [0, 1] at sample
    -- rate. Multiply with a signal to apply the envelope.
  | Smooth !Double !Connection
    -- ^ Cascaded two-pole self-modulating smoother (Q's
    -- @q::dynamic_smoother@): @smooth base_freq_hz value@. The
    -- first argument is a compile-time smoothing speed in Hz
    -- (smaller = slower / smoother / laggier; ~20 Hz is a typical
    -- sweet spot for control smoothing). The second argument is
    -- the value to
    -- smooth — usually a 'Param' that the producer thread
    -- updates via the realtime ABI when CC or pitch-bend events
    -- arrive, so that block-rate jumps in the target value land
    -- as continuous ramps in the smoothed output.
    --
    -- Stateful: the smoother carries internal IIR history across
    -- blocks. Per-instance state (no shared resource), so 'Eff'
    -- is 'Pure'; rate is 'SampleRate'. See Note [Per-node smooth
    -- state] in @tinysynth/rt_graph.cpp@.
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

-- | Run a graph builder and return both the builder's value and
-- the resulting 'SynthGraph'. Use this when you need to thread
-- captured 'Connection' / 'NodeID' values out of the builder for
-- post-compile binding (e.g. recording which node carries the
-- gain control that a CC will drive).
runSynthWith :: SynthM a -> (a, SynthGraph)
runSynthWith m =
  let (a, st) = runState m (SynthState 0 emptyGraph)
  in (a, ssGraph st)

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

{- $combinators

Every combinator both takes and returns 'Connection'. Numeric literals
become 'Param' connections automatically via 'fromRational' /
'fromInteger', and node-producing combinators return their output as
an 'Audio' Connection, so values chain naturally without explicit
lifting:

>>> -- Ring modulation: carrier * modulator at audio rate
>>> ringModGraph = runSynth $ do
>>>   carrier   <- sinOsc 440.0 0.0
>>>   modulator <- sinOsc 7.0 0.0
>>>   ring      <- gain carrier modulator
>>>   amped     <- gain ring 0.3
>>>   out 0 amped

>>> -- Vibrato via FM: 5 Hz LFO biased by 440 Hz
>>> vibratoGraph = runSynth $ do
>>>   lfo       <- sinOsc 5.0 0.0
>>>   deviation <- gain lfo 30.0
>>>   freq      <- add 440.0 deviation
>>>   carrier   <- sinOsc freq 0.0
>>>   out 0 carrier

The 'NodeID' machinery still exists internally for the source-graph
map, but it is wrapped in @Audio nid 0@ before being returned to the
caller — so the user-facing handle is always 'Connection' and the
distinction between "constant" and "audio-rate" inputs is invisible
to type-check, just like 'Param' vs 'Audio' inside 'Connection'.

The 'audio' helper survives for hand-built graphs that reference a
'NodeID' directly. User code rarely needs it.

A future typed DSL could distinguish audio-rate from control-rate
signals at the type level, preventing wiring errors statically rather
than catching them in @checkRateEdges@. Higher-level combinators
(chain, parallel, mix, templates) would elaborate down to these
primitives, making the elaboration pass a meaningful transformation
rather than identity.
-}

-- | Lift a 'NodeID' to an audio-rate 'Connection' on output port 0.
-- Rarely needed in user code: combinators already return their
-- output as a 'Connection'. Useful for hand-built graphs.
audio :: NodeID -> Connection
audio n = Audio n (PortIndex 0)

-- | Recover the symbolic 'NodeID' that produced an audio-rate
-- 'Connection'. Returns 'Nothing' for 'Param' connections (literal
-- constants own no node).
--
-- This is the bridge between graph construction and post-compile
-- index resolution: combinators return 'Connection', but downstream
-- consumers (CC binding, pitch-bend binding, observability) need a
-- stable symbolic handle they can later look up against a compiled
-- 'RuntimeGraph' via 'MetaSonic.Bridge.Compile.resolveNodeIndex'.
connectionNodeID :: Connection -> Maybe NodeID
connectionNodeID (Audio nid _) = Just nid
connectionNodeID (Param _)     = Nothing

-- Internal helper: register a node and return its output as a
-- 'Connection' on port 0.
insertNodeC :: String -> UGen -> SynthM Connection
insertNodeC name ugen = audio <$> insertNode name ugen

-- | Sine oscillator. Either input may be a numeric literal (which
-- becomes a 'Param' constant) or another node's 'Connection', so
-- this is the FM construction site.
sinOsc :: Connection -> Connection -> SynthM Connection
sinOsc freq phase = insertNodeC "sinOsc" (SinOsc freq phase)

-- | Bandlimited sawtooth. Same input shape as 'sinOsc'.
sawOsc :: Connection -> Connection -> SynthM Connection
sawOsc freq phase = insertNodeC "sawOsc" (SawOsc freq phase)

-- | White noise generator. No inputs.
noiseGen :: SynthM Connection
noiseGen = insertNodeC "noiseGen" NoiseGen

-- | Low-pass filter. Audio-rate modulation of cutoff or Q produces
-- zipper artifacts with the current biquad implementation; treat
-- those inputs as control-rate for now.
lpf :: Connection -> Connection -> Connection -> SynthM Connection
lpf sig freq q = insertNodeC "lpf" (LPF sig freq q)

-- | Multiply two inputs sample-by-sample. With both as audio edges
-- this is ring modulation; with one as a constant it is scaling.
gain :: Connection -> Connection -> SynthM Connection
gain sig amount = insertNodeC "gain" (Gain sig amount)

-- | Sum two inputs sample-by-sample. Used to bias a bipolar modulator
-- off zero (turning ring mod into AM, or through-zero FM into vibrato).
add :: Connection -> Connection -> SynthM Connection
add a b = insertNodeC "add" (Add a b)

-- | ADSR envelope generator: @env gate attack decay sustain release@.
--
-- Gate is sample-accurate: a rising edge starts attack, a falling edge
-- starts release. Attack/decay/release are durations in seconds; sustain
-- is a linear amplitude in [0, 1]. A 'Param' on the gate input acts as a
-- constant gate level (use @Param 1@ for an always-on test envelope).
env
  :: Connection -- ^ gate
  -> Connection -- ^ attack (s)
  -> Connection -- ^ decay (s)
  -> Connection -- ^ sustain (linear 0..1)
  -> Connection -- ^ release (s)
  -> SynthM Connection
env gate a d s r = insertNodeC "env" (Env gate a d s r)

-- | Hardware output: writes a Connection to a hardware output bus.
-- In practice the source is an 'Audio' connection from another
-- node; passing a 'Param' constant would silently produce silence
-- because the runtime does not synthesize from constant-only inputs.
-- Terminal node; produces no downstream signal.
out :: Int -> Connection -> SynthM ()
out channel src =
  void $ insertNode "out" (Out channel src)

-- | Write a signal to a shared audio bus. The bus is part of the
-- runtime's bus pool; the same pool serves hardware-routed buses
-- (used by 'Out'). 'BusOut' carries a 'BusWrite' effect, so any
-- 'BusIn' on the same bus is forced to execute after this node in
-- the same block — see Note [Effect-induced edges (E_r)] in
-- "MetaSonic.Bridge.Validate".
busOut :: Int -> Connection -> SynthM ()
busOut bus src =
  void $ insertNode "busOut" (BusOut bus src)

-- | Read a signal from a shared audio bus. Returns a 'Connection'
-- that downstream nodes can wire to their inputs. Carries a
-- 'BusRead' effect so it executes after every same-bus writer.
busIn :: Int -> SynthM Connection
busIn bus = insertNodeC "busIn" (BusIn bus)

-- | Per-node fractional delay line. Allocates a circular buffer of
-- @ceil (maxDelay * sampleRate)@ floats per instance and reads back
-- with linear interpolation, so sub-sample delay times work. The
-- delay time may be a 'Param' constant or an audio-rate 'Connection'
-- — modulating it at audio rate yields the standard delay-modulation
-- effects (chorus, flanger, vibrato by pitch shift).
--
-- The maximum delay must be known at graph-construction time
-- because it sizes the per-instance buffer; runtime requests for a
-- delay time greater than @maxDelay@ are clamped at the kernel.
-- Choose @maxDelay@ as the worst case your patch will ever need.
--
-- > -- 50 ms slap-back echo
-- > slapback = runSynth $ do
-- >   src   <- sinOsc 440.0 0.0
-- >   d     <- delayL 0.1 src 0.05    -- 50 ms delay, max 100 ms
-- >   mixed <- add src d
-- >   out 0 mixed
--
-- The "L" suffix follows SuperCollider's naming
-- (@DelayN@/@DelayL@/@DelayC@): @delayL@ uses linear interpolation,
-- which is what Q's 'fractional_ring_buffer' provides by default.
-- See Note [Per-node delay state] in @tinysynth/rt_graph.cpp@.
delayL
  :: Double      -- ^ maximum delay time in seconds (compile-time)
  -> Connection  -- ^ input signal
  -> Connection  -- ^ delay time in seconds
  -> SynthM Connection
delayL maxT sig time = insertNodeC "delay" (Delay maxT sig time)

-- | Cascaded two-pole self-modulating smoother (Q's @q::dynamic_smoother@)
-- for de-zippering block-rate control updates.
--
-- The first argument is a compile-time smoothing speed in Hz: smaller
-- values mean a slower / smoother / laggier ramp. ~20 Hz is a typical
-- sweet spot for control smoothing (~50ms time constant). The second
-- argument is the value to smooth — usually a 'Param' that the
-- producer thread updates via the realtime ABI when CC or pitch-bend
-- events arrive, so the smoother turns block-rate jumps in the target
-- value into continuous ramps in its sample-rate output.
--
-- Pathological values are unsafe: the underlying
-- @q::dynamic_smoother@'s @g0@ coefficient is computed from
-- @tan(pi * base_hz / sps)@, which collapses to zero or goes negative
-- at @base <= 0@, returns @NaN@ at non-finite input, and wraps
-- negative once @base@ approaches @sample_rate / 2@. The runtime
-- defensively sanitizes to @[0.001 Hz, 0.49 * sample_rate]@ and
-- substitutes the lower bound for @NaN@\/@Inf@, but you should pick a
-- real, finite, sub-Nyquist smoothing frequency here.
--
-- > out <- runSynth $ do
-- >   target <- pure (Param 0.0)         -- producer-thread updated
-- >   amount <- smooth 20.0 target       -- de-zipper
-- >   sig    <- sinOsc (Param 440.0) (Param 0.0)
-- >   amped  <- gain sig amount
-- >   out 0 amped
--
-- See Note [Per-node smooth state] in @tinysynth/rt_graph.cpp@.
smooth
  :: Double      -- ^ base smoothing frequency in Hz (compile-time)
  -> Connection  -- ^ value to smooth (often a 'Param')
  -> SynthM Connection
smooth baseHz v = insertNodeC "smooth" (Smooth baseHz v)

-- | Read the previous block's accumulated contents of a shared audio
-- bus. The feedback primitive: unlike 'busIn', a 'busInDelayed' creates
-- *no* ordering constraint with a same-bus 'busOut', so a graph that
-- closes a feedback loop through a 'busInDelayed' is well-formed and
-- topologically sortable. The runtime serves the read from a snapshot
-- of the previous block's bus pool (the snapshot is zero on the first
-- block), so the delay is exactly one block.
--
-- Use this for self-referential / feedback patches:
--
-- > feedbackGraph = runSynth $ do
-- >   tap   <- busInDelayed 5    -- previous block's bus 5 (zero on block 0)
-- >   src   <- sinOsc 220.0 0.0
-- >   mixed <- add src tap        -- inject delayed feedback into the path
-- >   amp   <- gain mixed 0.6     -- attenuate to keep the loop stable
-- >   busOut 5 amp                -- this block's bus 5 contents
-- >   out 0 amp                   -- and to hardware
--
-- Carries a 'BusReadDelayed' effect; see Note [Bus model: SC-style
-- same-cycle audio buses] for the same-cycle vs. delayed distinction
-- and Note [Effect-induced edges (E_r)] in "MetaSonic.Bridge.Validate"
-- for why 'BusReadDelayed' deliberately *does not* contribute to E_r.
busInDelayed :: Int -> SynthM Connection
busInDelayed bus = insertNodeC "busInDelayed" (BusInDelayed bus)

{- Note [Uniform UGen view]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
'UGenView' is the canonical projection from a 'UGen' constructor into the
triple @(NodeKind, audio inputs, control defaults)@. Downstream passes that
used to enumerate every constructor (kind inference, input lowering, control
extraction) are derived from this one function.

The typed 'UGen' constructors are preserved — they are the user-facing
surface, statically arity-checked, and remain pattern-matchable. 'ugenView'
is the *only* per-constructor enumeration in the codebase outside the
'kindSpec' table and the builder layer.

A property test cross-checks 'ugenView' against 'kindSpec' so the two
sources of per-kind shape information cannot drift apart.

Effects are *not* covered by this projection — 'inferEff' is a separate
per-UGen function because some kinds ('BusOut', 'BusIn') carry per-instance
effect data (a bus number) that a kind-level table cannot represent. See
Note [Effects are per-UGen, not per-kind] in "MetaSonic.Bridge.IR".
-}

-- | A uniform projection of a 'UGen' into kind plus input and control
-- payload.
--
-- The control list is given explicitly per kind (rather than derived from
-- the inputs), because the C++ kernel layout is per-kind: signal inputs
-- carry no paired control default ('LPF', 'Gain'), while parameter inputs
-- do ('SinOsc', 'Add'), and some kinds carry metadata-only controls with
-- no input pair ('Out' channel).
--
-- See Note [Uniform UGen view].
data UGenView = UGenView
  { uvKind     :: !NodeKind
  , uvInputs   :: ![Connection]
    -- ^ Audio inputs in declared order. Length matches
    -- 'MetaSonic.Types.ksAudioArity'.
  , uvControls :: ![Double]
    -- ^ Control defaults in the C++ kernel's declared order. Length
    -- matches 'MetaSonic.Types.ksControlArity'.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Default value carried by a 'Connection' when used as a control: a
-- 'Param' literal contributes its value, an 'Audio' edge contributes 0.0
-- (the runtime fallback when no audio is connected).
connDefault :: Connection -> Double
connDefault (Param x)   = x
connDefault (Audio _ _) = 0.0

-- | The canonical per-constructor projection.
--
-- Each clause states inputs and control defaults together so the per-kind
-- mapping is visible in one place.
--
-- See Note [Uniform UGen view].
ugenView :: UGen -> UGenView
ugenView = \case
  SinOsc f p   -> UGenView KSinOsc   [f, p]    [connDefault f, connDefault p]
  SawOsc f p   -> UGenView KSawOsc   [f, p]    [connDefault f, connDefault p]
  NoiseGen     -> UGenView KNoiseGen []        []
  LPF s f q    -> UGenView KLPF      [s, f, q] [connDefault f, connDefault q]
  Gain s a     -> UGenView KGain     [s, a]    [connDefault a]
  Add a b      -> UGenView KAdd      [a, b]    [connDefault a, connDefault b]
  Env g a d s r ->
    UGenView KEnv [g] [connDefault g, connDefault a, connDefault d, connDefault s, connDefault r]
  Out ch s          -> UGenView KOut          [s]    [fromIntegral ch]
  BusOut bus s      -> UGenView KBusOut       [s]    [fromIntegral bus]
  BusIn bus         -> UGenView KBusIn        []     [fromIntegral bus]
  BusInDelayed bus  -> UGenView KBusInDelayed []     [fromIntegral bus]
  Delay maxT s t    -> UGenView KDelay        [s, t] [maxT, connDefault t]
  Smooth baseHz v   -> UGenView KSmooth       [v]    [baseHz, connDefault v]

{- Note [Per-UGen projections]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'inferKind', 'inferRate' and 'inferEff' are the source-level projections
used by every downstream pass (lowering in "MetaSonic.Bridge.IR",
scheduling in "MetaSonic.Bridge.Validate"). They live here, in the source
layer, because:

  1. Their input is 'UGen' — the source-level type. They don't need any
     IR-level vocabulary.
  2. Both the IR pass and the scheduler need them, and putting them in IR
     would force a cyclic module dependency
     (Validate would have to import IR which imports Validate).

'inferKind' and 'inferRate' are derived from 'kindSpec' through 'ugenView',
so they're one-liners. 'inferEff' is the odd one out: it has explicit
per-UGen cases for 'BusOut' / 'BusIn' because their effect annotation
('BusWrite n' / 'BusRead n') depends on a constructor field. See Note
[Effects are per-UGen, not per-kind].
-}

-- | Map a UGen constructor to its 'NodeKind' tag.
--
-- See Note [Per-UGen projections].
inferKind :: UGen -> NodeKind
inferKind = uvKind . ugenView

-- | Infer the *kind-level minimum* rate of a UGen — its floor.
--
-- This is only the first half of rate assignment. The actual rate of
-- a node in a compiled graph is computed by
-- 'MetaSonic.Bridge.IR.propagateRates', which lifts each node's rate
-- to the join of its inputs' rates and this floor. So a 'Gain' (floor
-- 'CompileRate') fed by a 'SinOsc' (floor 'SampleRate') ends up with
-- 'irRate = SampleRate' after propagation, even though 'inferRate'
-- alone returns 'CompileRate'.
--
-- Derived from the 'kindSpec' table via 'ugenView'. See Note [Per-kind
-- metadata table] in "MetaSonic.Types" and Note [Rate inference vs rate
-- propagation] in "MetaSonic.Bridge.IR".
inferRate :: UGen -> Rate
inferRate = ksRate . kindSpec . uvKind . ugenView

{- Note [Effects are per-UGen, not per-kind]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'inferEff' is the single source of truth for the effect set of a UGen. It
deliberately does *not* go through 'kindSpec' — see Note [Per-kind metadata
table] in "MetaSonic.Types" for why.

The short version: 'BusOut n' and 'BusIn n' carry a bus number in a
constructor field, so their effects ('BusWrite n' / 'BusRead n') depend on
per-instance data that a kind-level table cannot represent. Putting '[Pure]'
in a kind-level effect column for those kinds would be a lie that defeats
the scheduling pass — the busEdges derivation in
"MetaSonic.Bridge.Validate" walks 'inferEff' looking for 'BusWrite' /
'BusRead' annotations to add E_r edges, and a stale '[Pure]' would silently
return zero edges.

So 'inferEff' lists per-UGen cases for the kinds that need per-instance
overrides, and falls through to '[Pure]' for everything else. It is by
design less compact than 'inferKind' / 'inferRate' / 'lowerInputs' /
'extractControls' (all derived through 'ugenView'); honesty wins over
compactness here.
-}

-- | Infer the effect set of a UGen.
--
-- 'Out' / 'BusOut' / 'BusIn' / 'BusInDelayed' carry per-instance bus numbers,
-- so their effect annotations encode that bus number directly.
--
-- 'Out n' and 'BusOut n' both produce 'BusWrite n'. The two constructors
-- share a runtime kernel and write into the same bus pool (see Note [Bus
-- model: SC-style same-cycle audio buses]); the source-level split is
-- documentation only ("final output" vs. "intermediate routing"). An 'Out n'
-- in the same graph as a 'BusIn n' must therefore induce the same E_r
-- writer→reader ordering as a 'BusOut n' would.
--
-- 'BusInDelayed' produces 'BusReadDelayed' rather than 'BusRead': the
-- 'Validate' layer treats those two as semantically distinct (only
-- 'BusRead' contributes to E_r), so a 'BusInDelayed n' can sit anywhere in
-- the schedule relative to any 'BusWrite n' — which is exactly what enables
-- feedback loops to typecheck.
--
-- See Note [Effects are per-UGen, not per-kind].
-- See Note [Resource effects] in "MetaSonic.Types".
-- See Note [Effect-induced edges (E_r)] in "MetaSonic.Bridge.Validate".
inferEff :: UGen -> [Eff]
inferEff (Out          bus _) = [BusWrite        bus]
inferEff (BusOut       bus _) = [BusWrite        bus]
inferEff (BusIn        bus)   = [BusRead         bus]
inferEff (BusInDelayed bus)   = [BusReadDelayed  bus]
inferEff _                    = [Pure]

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
  Out _ a          -> deps [a]
  BusOut _ a       -> deps [a]
  BusIn _          -> []
  BusInDelayed _   -> []
    -- ^ Like 'BusIn', no structural edge: the bus connection is
    -- expressed through the 'BusReadDelayed' effect, not through an
    -- 'Audio' Connection. Unlike 'BusIn', no E_r edge either; see
    -- Note [Effect-induced edges (E_r)] in "MetaSonic.Bridge.Validate".
  Delay _ s t      -> deps [s, t]
  SinOsc a b       -> deps [a, b]
  SawOsc a b       -> deps [a, b]
  NoiseGen         -> []
  LPF a b c        -> deps [a, b, c]
  Gain a b         -> deps [a, b]
  Add a b          -> deps [a, b]
  Env g _ _ _ _    -> deps [g]
  Smooth _ v       -> deps [v]
  where
    deps = foldr step []
    step (Audio nid _) acc = nid : acc
    step (Param _)     acc = acc
