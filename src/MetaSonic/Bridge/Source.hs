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
  , -- * Connection helpers
    audio
  , -- * Uniform UGen view
    UGenView (..)
  , ugenView
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
  | Add !Connection !Connection
    -- ^ Sum two inputs sample-by-sample. Either input may be a
    -- 'Param' constant (acting as a bias) or an 'Audio' edge.
    -- Used to bias a bipolar modulator off zero (turning ring mod
    -- into AM, or through-zero FM into vibrato).
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

-- | Write a signal to a shared intermediate bus. (Currently
-- unused — the runtime side of bus routing is not implemented yet.)
busOut :: Int -> Connection -> SynthM ()
busOut bus src =
  void $ insertNode "busOut" (BusOut bus src)

-- | Read a signal from a shared intermediate bus. (Currently
-- unused — see 'busOut'.)
busIn :: Int -> SynthM Connection
busIn bus = insertNodeC "busIn" (BusIn bus)

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

The 'BusIn' / 'BusOut' constructors are not yet wired through the runtime;
'ugenView' errors on them in the same way 'inferKind' did before. They
remain valid for graph *construction* and for 'dependencies' extraction,
but compilation will reject any graph that contains them until the
shared-bus runtime support lands.
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
-- 'BusIn' / 'BusOut' error here intentionally — they are not yet supported
-- by the runtime. See Note [Uniform UGen view].
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
  Out ch s     -> UGenView KOut      [s]       [fromIntegral ch]
  BusIn _      -> error "ugenView: BusIn not implemented yet"
  BusOut _ _   -> error "ugenView: BusOut not implemented yet"

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
  Add a b     -> deps [a, b]
  Env g _ _ _ _ -> deps [g]
  where
    deps = foldr step []
    step (Audio nid _) acc = nid : acc
    step (Param _)     acc = acc
