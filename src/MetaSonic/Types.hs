{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}

{- Note [Pipeline reading order]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Read the MetaSonic modules in pipeline order

  Types → Source → Validate → IR → Compile → FFI

MetaSonic.Types
  It defines every type name that appears in the other modules:
  NodeID, NodeIndex, Rate, Eff, NodeKind.

MetaSonic.Bridge.Source
  This is where graphs are written.

MetaSonic.Validate
  The gate between construction and compilation.

MetaSonic.Bridge.IR
  First compilation pass. This is where the source vocabulary (UGen, Connection)
  is stripped and replaced with the compiler's vocabulary (NodeIR, InputConn)
  plus semantic annotations (Rate, Eff). lowerGraph ties together validation,
  sorting, lowering, and rate checking in one function. This is the module where
  the argument about surface syntax vs semantic syntax becomes concrete.

MetaSonic.Bridge.Compile
  Read formRegions (region formation), then compileRuntimeGraph (the decisive
  NodeID → NodeIndex transformation). The Region and RegionGraph types are where
  scheduling logic lives. See Note [Region formation] and Note [Dense lowering]
  in MetaSonic.Compile.

MetaSonic.Bridge.FFI
  loadRuntimeGraph is the marshaling function that walks the
  dense RuntimeGraph and emits FFI calls. After reading this,
  you know exactly what crosses to C++ and in what form.


-}

-- |
-- Module      : MetaSonic.Types
-- Description : Shared vocabulary for the compilation pipeline
--
-- This module defines the types that every stage of the pipeline
-- shares.

module MetaSonic.Types
  ( -- * Symbolic identifiers (only during compilation)
    NodeID (..)
  , -- * Runtime identifiers
    NodeIndex (..)
  , PortIndex (..)
  , ControlIndex (..)
  , -- * Node classification
    NodeKind (..)
  , kindTag
  , -- * Per-kind metadata
    KindSpec (..)
  , kindSpec
  , -- * Rate discipline
    Rate (..)
  , -- * Per-input-port consumption policy (§4.D.2)
    PortConsumptionRate (..)
  , PortInfo (..)
  , portInfo
  , -- * Resource effects
    Eff (..)
  ) where

import           Control.DeepSeq (NFData)
import           Foreign.C.Types (CInt)
import           GHC.Generics    (Generic)

{- Note [Shared vocabulary design]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The types in this module reflect three principles:

1. Nominal identity matters.
   A NodeID is not a NodeIndex, even though both wrap Int.
   The Haskell type system enforces the distinction between
   symbolic identifiers (which exist only during compilation)
   and dense runtime positions (which survive into the C++
   runtime). Collapsing them would allow the kind of symbolic-
   runtime confusion that MetaSonic exists to prevent.

2. Semantic annotations are compilation artifacts.
   The Rate and Eff types exist because time and resource
   access are part of the compilation problem, not runtime
   concerns. Faust's semantic typing dimensions — signal
   nature, interval, computation time, speed,
   parallelizability — motivate a richer typed IR in which
   these distinctions become explicit. MetaSonic extends
   Faust's list with resource effects, which become essential
   for correct parallel scheduling.

3. The vocabulary is shared, but the flow is one-directional.
   Types defined here are imported by every module from Source
   through FFI, but information flows strictly forward through
   the pipeline. No downstream module writes back into an
   upstream representation. This is the module-level
   expression of the staged architecture.
-}

{- Note [Symbolic vs dense identifiers]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
NodeID, NodeIndex, PortIndex, and ControlIndex are represented
as distinct newtypes, preserving nominal distinctions between
otherwise integer-like identifiers.

Symbolic identifiers (NodeID) exist on the Haskell side only.
A NodeID names a node in the source graph; it is meaningful
during construction, validation, and ordering. It does not
survive into the runtime.

The decisive transformation in the compiler
(compileRuntimeGraph in MetaSonic.Compile) replaces every
NodeID with a dense NodeIndex, after which symbolic identity
is erased. See Note [Dense lowering] in MetaSonic.Compile.

Dense identifiers (NodeIndex, PortIndex, ControlIndex) cross
the FFI boundary. On the C++ side, the same nominal
distinctions are maintained (NodeIndex, PortIndex,
ControlIndex are separate structs in rt_graph.cpp), ensuring
that the Haskell compiler and the C++ runtime agree on what
each integer means — by convention, not by a shared type
definition, but the convention is enforced by identical
newtype/struct discipline on both sides.
-}

-- | A symbolic node identifier, meaningful only during
-- compilation. After 'MetaSonic.Compile.compileRuntimeGraph',
-- no 'NodeID' survives into the runtime representation.
newtype NodeID = NodeID Int
  deriving stock   (Eq, Ord, Show, Generic)
  deriving newtype (NFData)

-- | A dense position in the runtime node array. Storage
-- order equals execution order; the runtime iterates
-- sequentially and never reorders.
newtype NodeIndex = NodeIndex Int
  deriving stock   (Eq, Ord, Show, Generic)
  deriving newtype (NFData)

-- | Identifies one output or input port on a node.
newtype PortIndex = PortIndex Int
  deriving stock   (Eq, Ord, Show, Generic)
  deriving newtype (NFData)

-- | Identifies one control slot on a node (e.g., frequency,
-- gain amount). Controls are set at graph load time and may
-- be overridden at block rate by incoming connections.
newtype ControlIndex = ControlIndex Int
  deriving stock   (Eq, Ord, Show, Generic)
  deriving newtype (NFData)

-- | Note: tag 4 was reserved for a generic biquad family but is
-- intentionally unallocated. The Haskell→C++ contract test
-- (see Spec.hs) iterates [minBound..maxBound] via the derived
-- 'Enum'\/'Bounded' instances, so any new constructor added here
-- is automatically asserted against the C++ kind_from_tag dispatch.
data NodeKind
  = KSinOsc
  | KOut
  | KGain
  | KSawOsc
  | KNoiseGen
  | KLPF
  | KAdd
  | KEnv
  | KBusOut
  | KBusIn
  | KBusInDelayed
    -- ^ Read the *previous* block's contents of an audio bus.
    -- Sibling of 'KBusIn' but reads from the frozen prior-block snapshot
    -- in the runtime's double-buffered bus pool, so feedback loops can be
    -- expressed as @BusInDelayed → ... → BusOut@ without closing an E_r
    -- cycle. See Note [Effect-induced edges (E_r)] in
    -- "MetaSonic.Bridge.Validate" for why the schedulable graph drops
    -- 'BusReadDelayed' from E_r, and Note [Bus pool double-buffering] in
    -- @tinysynth/rt_graph.cpp@ for the runtime swap.
  | KDelay
    -- ^ Per-node fractional delay line. Each instance owns its own
    -- circular buffer (sized by a compile-time max delay), so this
    -- introduces no shared resource — its 'Eff' is 'Pure'. Wraps Q's
    -- @q::delay@ (a 'fractional_ring_buffer' with linear interpolation),
    -- so the delay time can be sub-sample and modulated at audio rate.
    -- See Note [Per-node delay state] in @tinysynth/rt_graph.cpp@.
  | KSmooth
    -- ^ Cascaded two-pole self-modulating smoother (wraps Q's
    -- @q::dynamic_smoother@). Audio input port 0 is the value to
    -- smooth; controls @[base_freq_hz, target_default]@ pick the
    -- smoothing speed and the steady-state value when the input port
    -- is unconnected. The headline use is de-zippering block-rate CC
    -- and pitch-bend updates: producer-thread events update
    -- 'controls[1]' (the target) and downstream consumers read the
    -- smoothed sample-by-sample output. See Note
    -- [Per-node smooth state] in @tinysynth/rt_graph.cpp@.
  | KPulseOsc
    -- ^ Bandwidth-limited pulse oscillator (wraps Q's
    -- @q::pulse_osc@). Audio inputs in declared order:
    -- @[freq, phase, width]@. Controls @[freq_default,
    -- phase_default, width_default]@. The width input is the
    -- intermodulation primitive: drive it with an LFO for classic
    -- PWM. Width is in [0, 1] (0.5 = square). Phase is initial-only
    -- (consulted at first sample, like 'KSinOsc' \/ 'KSawOsc').
  | KTriOsc
    -- ^ Bandwidth-limited triangle oscillator (wraps Q's
    -- @q::triangle_osc@). Same input shape as 'KSinOsc' \/ 'KSawOsc':
    -- @[freq, phase]@. The triangle's stateless waveshape pairs
    -- well with FM via the freq input.
  | KHPF
    -- ^ High-pass biquad (wraps Q's @q::highpass@). Same input
    -- shape as 'KLPF': @[signal, cutoff, q]@. cutoff in Hz,
    -- q is the resonance. The filter reads cutoff and q once at
    -- the start of each block, matching 'KLPF'. Put 'KSmooth'
    -- before the cutoff input when MIDI or UI changes should glide
    -- from block to block instead of jumping; true within-block
    -- sweeps would need a sample-accurate filter path.
  | KBPF
    -- ^ Band-pass biquad (wraps Q's @q::bandpass_cpg@, the
    -- constant-peak-gain variant favored for music). Same input
    -- shape as 'KLPF': @[signal, cutoff, q]@. q controls bandwidth
    -- (higher q = narrower band). Cutoff and q are read once per
    -- block, like 'KHPF' and 'KLPF'.
  | KNotch
    -- ^ Notch biquad (wraps Q's @q::notch@). Same input shape as
    -- 'KLPF': @[signal, cutoff, q]@. Useful for hum removal and
    -- spectral notching. Cutoff and q are read once per block, like
    -- the rest of the biquad family.
  deriving stock    (Eq, Show, Generic, Enum, Bounded)
  deriving anyclass (NFData)

{- Note [Per-kind metadata table]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'KindSpec' centralises the *kind-level* facts about each 'NodeKind': ABI tag,
rate, audio/control arities, and label. Adding a new 'NodeKind' is one row
here plus a constructor in 'NodeKind', a constructor in 'UGen', a row in
'ugenView' (Source), and a builder.

The 'ksAudioArity' and 'ksControlArity' fields are cross-checked against
'ugenView' by a property test, so drift between the table and the constructor
shape is caught at test time rather than in the runtime.

Effects are deliberately *not* stored here. 'BusOut n' / 'BusIn n' carry a
bus number in a constructor field, so their 'Eff' annotation
('BusWrite n' / 'BusRead n') depends on per-instance data that the kind-level
table cannot represent. Putting '[Pure]' in a kind-level effects column for
those kinds would be a lie that defeats the scheduling pass — the whole
point of the 'Eff' machinery is that 'BusRead' / 'BusWrite' annotations
drive effect-induced edges in 'MetaSonic.Bridge.Validate'.

The corresponding per-UGen function 'MetaSonic.Bridge.IR.inferEff' is the
single source of truth for effects; it returns '[Pure]' for the kinds where
that is honest and overrides for the kinds whose effects depend on
constructor fields. See Note [Effect-induced edges (E_r)] in
"MetaSonic.Bridge.Validate" for how those annotations drive scheduling.

'ksRate' is interpreted as the kind's *intrinsic minimum* rate — a floor.
The actual rate of a node is the join (max) of this floor and the rates
of its inputs, computed by 'MetaSonic.Bridge.IR.propagateRates' as a
post-pass on the lowered IR. So a 'Gain' (floor 'CompileRate') fed by
two 'Param' literals stays at 'CompileRate'; the same 'Gain' fed by a
'SinOsc' (floor 'SampleRate') is lifted to 'SampleRate' by propagation.
A 'SinOsc' is *always* 'SampleRate' regardless of inputs because its
floor is 'SampleRate' and the join can only raise the rate, never lower
it. See Note [Rate inference vs rate propagation] in
"MetaSonic.Bridge.IR" for the algorithm.

The split between "stateful/producer" floors ('SampleRate') and
"stateless transform" floors ('CompileRate') is what makes region
formation and future block-rate optimization meaningful: a region of
all-'Param' nodes can collapse to a one-time evaluation, while a region
fed by an oscillator necessarily runs sample-by-sample.
-}

-- | Per-kind metadata. Indexed by 'NodeKind' via 'kindSpec'.
data KindSpec = KindSpec
  { ksTag          :: !CInt
    -- ^ ABI tag. Must match the C++ @kind_from_tag@ dispatch.
  , ksRate         :: !Rate
    -- ^ Kind-level *minimum* rate. The actual rate of a node is
    -- @max ksRate (max of input rates)@, computed by
    -- 'MetaSonic.Bridge.IR.propagateRates'. Stateful or sample-producing
    -- kinds set this to 'SampleRate'; stateless transforms and consumers
    -- set it to 'CompileRate' so they inherit from inputs. See
    -- Note [Per-kind metadata table] and Note [Rate inference vs rate
    -- propagation] in "MetaSonic.Bridge.IR".
  , ksAudioArity   :: !Int
    -- ^ Number of @Connection@ inputs the corresponding 'UGen' constructor
    -- carries.
  , ksControlArity :: !Int
    -- ^ Number of control slots the C++ kernel expects, in declared order.
    -- The mapping from inputs to controls is per-kind and is realized by
    -- 'MetaSonic.Bridge.Source.ugenView'; this field exists for cross-check
    -- only.
  , ksLabel        :: !String
    -- ^ Human-readable label used by source-level builders for 'nsName'.
  }

-- | Resolve per-kind metadata.
--
-- Note: tag 4 was reserved for a generic biquad family but is intentionally
-- unallocated. The Haskell→C++ contract test (see Spec.hs) iterates
-- @[minBound..maxBound]@ via the derived 'Enum'\/'Bounded' instances on
-- 'NodeKind', so any new constructor added here is automatically asserted
-- against the C++ @kind_from_tag@ dispatch.
kindSpec :: NodeKind -> KindSpec
kindSpec = \case
  -- Producers / stateful kinds: floor is SampleRate. They generate or
  -- carry sample-rate information that cannot be coarsened without
  -- losing audio.
  --
  --   * Oscillators (SinOsc, SawOsc) run a phase accumulator per sample
  --     so the per-sample lookup yields the right waveform.
  --   * NoiseGen uses a PRNG that produces one value per sample.
  --   * LPF and Env are stateful: a block-rate biquad would alias and
  --     a block-rate envelope would miss gate transitions.
  --   * BusIn / BusInDelayed read sample-rate bus storage; coarsening
  --     them would silently drop samples.
  KSinOsc       -> KindSpec 1  SampleRate  2 2 "sinOsc"
  KSawOsc       -> KindSpec 5  SampleRate  2 2 "sawOsc"
  KNoiseGen     -> KindSpec 6  SampleRate  0 0 "noiseGen"
  KLPF          -> KindSpec 7  SampleRate  3 2 "lpf"
  KEnv          -> KindSpec 9  SampleRate  1 5 "env"
  -- Bus routing: same-cycle BusOut/BusIn and one-block-delayed BusInDelayed.
  -- Effects are per-instance (BusWrite n / BusRead n / BusReadDelayed n)
  -- and live in 'inferEff', not here. The C++ runtime stores all buses
  -- in one double-buffered pool (g.output_buses + g.output_buses_prev);
  -- the audio callback routes [0..N-1] to hardware regardless of which
  -- kind wrote them, so KOut and KBusOut are operationally identical
  -- and KBusIn reads from the live pool while KBusInDelayed reads from
  -- the previous-block snapshot.
  -- See Note [Effect-induced edges (E_r)] in MetaSonic.Bridge.Validate
  -- and Note [Bus pool double-buffering] in tinysynth/rt_graph.cpp.
  KBusIn        -> KindSpec 11 SampleRate  0 1 "busIn"
  KBusInDelayed -> KindSpec 12 SampleRate  0 1 "busInDelayed"
  -- Delay line: per-node fractional ring buffer. Stateful (the
  -- buffer carries per-sample history) so the floor is SampleRate.
  -- 2 audio inputs: signal, delay-time-in-seconds. 2 controls:
  -- [max_delay_seconds, delay_time_default]. The runtime allocates
  -- the buffer lazily at first process() using control 0.
  KDelay        -> KindSpec 13 SampleRate  2 2 "delay"
  -- Smoother: per-node q::dynamic_smoother. 1 audio input (the
  -- value to smooth, often a Param the producer thread updates via
  -- the realtime ABI), 2 controls [base_freq_hz, target_default].
  -- Stateful (the smoother carries low1/low2 history across blocks)
  -- so the floor is SampleRate.
  KSmooth       -> KindSpec 14 SampleRate  1 2 "smooth"
  -- Pulse oscillator: phase accumulator + per-sample width
  -- application via q::pulse_osc. 3 audio inputs (freq, phase,
  -- width), 3 controls [freq_default, phase_default, width_default].
  -- Stateful (the phase iterator carries the integer-phase
  -- accumulator across blocks), so the floor is SampleRate.
  KPulseOsc     -> KindSpec 15 SampleRate  3 3 "pulseOsc"
  -- Triangle oscillator: stateless waveshape over a phase iterator.
  -- Same shape as KSinOsc/KSawOsc. SampleRate floor for the same
  -- reason — the phase accumulator is per-sample.
  KTriOsc       -> KindSpec 16 SampleRate  2 2 "triOsc"
  -- Biquad family: signal_in + cutoff + q. Same shape as KLPF
  -- (3 audio inputs, 2 controls [cutoff, q]). SampleRate floor
  -- because the biquad carries IIR state per sample.
  KHPF          -> KindSpec 17 SampleRate  3 2 "hpf"
  KBPF          -> KindSpec 18 SampleRate  3 2 "bpf"
  KNotch        -> KindSpec 19 SampleRate  3 2 "notch"

  -- Consumers / stateless transforms: floor is CompileRate. They have
  -- no intrinsic rate of their own; 'propagateRates' lifts them to the
  -- maximum rate of their inputs. A Gain with two Param inputs stays
  -- at CompileRate (no-op multiplication of constants); the same Gain
  -- fed by a SinOsc lifts to SampleRate by propagation.
  --
  --   * Gain, Add: stateless arithmetic.
  --   * LPF would also be stateless except for its biquad delay state,
  --     which is why it sits in the stateful group above.
  --   * Out / BusOut: writers don't change the rate of the data they
  --     write; the bus pool just holds whatever rate the writer
  --     contributes (sample-and-hold for slower writers).
  KOut          -> KindSpec 2  CompileRate 1 1 "out"
  KGain         -> KindSpec 3  CompileRate 2 1 "gain"
  KAdd          -> KindSpec 8  CompileRate 2 2 "add"
  KBusOut       -> KindSpec 10 CompileRate 1 1 "busOut"

-- | Must agree with the NodeKind enum and kind_from_tag dispatch in
-- rt_graph.cpp. Verified by a contract test in Spec.hs.
kindTag :: NodeKind -> CInt
kindTag = ksTag . kindSpec

{- Note [Rate discipline]
~~~~~~~~~~~~~~~~~~~~~~~~~
A signal is not merely a stream of numbers. It has a staging
discipline, a rate discipline, and potentially resource effects
and synchronization constraints.

For comparison:
Faust's compiler distinguishes five semantic typing dimensions:
signal nature, interval of values, computation time, speed
(constant, block/UI-rate, or sample-rate), and
parallelizability.

MetaSonic adopts the speed dimension and uses it directly as the Rate type.

The ordering is significant:

  CompileRate < InitRate < BlockRate < SampleRate

A higher-rate node may freely read from a lower-rate node (the
value is simply held constant over the faster time scale —
sample-and-hold). A lower-rate node reading from a higher-rate
node requires explicit downsampling; this is a compilation
error unless a conversion node is inserted.

Rate annotations influence three downstream passes:

  1. Validation — checkRateEdges in MetaSonic.IR rejects edges
     where a lower-rate node reads from a higher-rate node
     without explicit conversion.

  2. Region formation — nodes must share a compatible rate to
     belong to the same region.
     See Note [Region rate compatibility] in MetaSonic.Compile.

  3. Future vectorization — sample-rate regions are candidates
     for SIMD; block-rate regions are not.

Rates start from the kind floor in 'kindSpec', then
'MetaSonic.Bridge.IR.propagateRates' raises each node to the maximum
rate required by its inputs. For example, a 'Gain' fed only by
'CompileRate' values stays 'CompileRate', while the same 'Gain' fed by
a 'SampleRate' oscillator becomes 'SampleRate'.

'MetaSonic.Bridge.Compile.formRegions' merges adjacent nodes whose
propagated rates are *compatible* — equal, or with at least one side
'CompileRate'. A 'CompileRate' helper is therefore folded into the
neighboring faster region rather than forming a separate one (its
value is known statically and is trivially sample-and-held). A region's
'regRate' is the maximum of its members' rates. 'BlockRate' into
'SampleRate' would need an explicit sample-and-hold boundary in the
runtime and is deferred until a kind actually produces 'BlockRate'
(none does today). See Note [Region rate compatibility] in
"MetaSonic.Bridge.Compile".

See Note [Rate inference vs rate propagation] in MetaSonic.IR.
-}

-- | The rate at which a signal is computed.
--
-- See Note [Rate discipline].
data Rate
  = CompileRate   -- ^ Known at compile time (literal constants)
  | InitRate      -- ^ Computed once at graph initialization
  | BlockRate     -- ^ Recomputed once per audio block
  | SampleRate    -- ^ Recomputed every sample
  deriving stock    (Eq, Ord, Show, Generic, Enum, Bounded)
  deriving anyclass (NFData)

{- Note [Per-input-port consumption policy]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'PortConsumptionRate' describes how the C++ runtime samples the
incoming audio buffer at a specific input port of a specific
'NodeKind'. It is /per-port/ and /destination-side/: a separate
axis from 'Rate', which is the /per-node/ /producer-side/ rate
the IR computes via 'propagateRates'.

The two are intentionally distinct:

  * A 'Rate' tells you what the producer node /generates/.
  * A 'PortConsumptionRate' tells you how a destination port
    /reads/ what was generated.

The opportunity question §4.D.2 measures lives at the join: a
'SampleRate' producer wired into a 'PortBlockLatched' or
'PortInitOnly' destination port writes 'nframes' samples that
the consumer will discard. That edge is where block-rate region
optimization could save work.

The metadata is conservative: when in doubt, the table claims
'PortSampleAccurate' so the survey never overstates a block-rate
opportunity that the runtime doesn't actually take. Each non-
sample-accurate classification is pinned by a comment to the
specific runtime kernel that block-latches or init-reads the
port.

This metadata is /descriptive/. Nothing in the runtime consumes
it; it exists so '--fusion-survey' can measure how many edges
in real graphs would benefit from a block-rate execution path
before any such path is implemented.
-}

-- | How the runtime reads a specific input port of a specific
-- 'NodeKind'. See Note [Per-input-port consumption policy].
data PortConsumptionRate
  = PortSampleAccurate
    -- ^ Read once per sample. Per-block work scales with @nframes@.
    -- This is the conservative default: most audio inputs and most
    -- ports that haven't been audited or block-latched on the C++
    -- side fall here.
  | PortBlockLatched
    -- ^ Read only at sample 0 of each block. The destination
    -- discards @nframes - 1@ samples of the source per block.
    -- Currently: the @freq@ and @q@ ports of the biquad family
    -- ('KLPF', 'KHPF', 'KBPF', 'KNotch'). The C++ kernels
    -- explicitly take only @freq_in[0]@ and @q_in[0]@ before
    -- reconfiguring the filter once per block.
  | PortInitOnly
    -- ^ Read only at instance configuration / construction. Never
    -- sampled in the per-block audio loop. Currently no kind has
    -- a port classified this way for 'RFrom' edges — kept as a
    -- distinct policy because "consumed once at init" is
    -- semantically different from "never consumed at all"
    -- ('PortIgnored') and from "consumed at block rate"
    -- ('PortBlockLatched'). A future kind whose runtime kernel
    -- reads an audio-input port exactly once at configure time
    -- would land here.
  | PortIgnored
    -- ^ The runtime silently discards 'RFrom' edges to this port.
    -- Currently: the @phase@ port (port 1) of the oscillator
    -- family ('KSinOsc', 'KSawOsc', 'KTriOsc', 'KPulseOsc').
    -- @process_sinosc@ / @process_sawosc@ / @process_triosc@ /
    -- @process_pulse_osc@ never call 'resolve_input' on port 1
    -- inside the audio loop; the initial phase is taken from
    -- 'rnControls[1]' at instance construction, so a wired
    -- 'RFrom' source is dropped without affecting output.
    --
    -- Excluded from the §4.D.2 opportunity count: an ignored
    -- consumer represents no work the runtime is doing, so
    -- block-rate scheduling can't save anything by demoting the
    -- producer. (Dead-input elimination is a separate
    -- optimization concern.)
  deriving stock    (Eq, Ord, Show, Generic, Enum, Bounded)
  deriving anyclass (NFData)

-- | Bundle a port's consumption rate with a human-readable name
-- so the §4.D.2 survey can produce legible "kind.port" examples
-- without a separate lookup table.
data PortInfo = PortInfo
  { piPolicy :: !PortConsumptionRate
    -- ^ How the runtime reads this port.
  , piName   :: !String
    -- ^ Short port name used in survey output (e.g. @"freq"@,
    -- @"sig"@, @"amount"@). Matches the source-DSL builder
    -- argument name where one exists.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Per-kind, per-port consumption policy. Returns 'Nothing' for
-- ports outside the kind's audio-input range; the audio-input
-- range itself comes from 'kindSpec'\'s 'ksAudioArity' field, so
-- this function is total over the declared port range.
--
-- Cross-checked against 'kindSpec' / 'ugenView' by a property
-- test in @test/Spec.hs@: every kind's declared audio-input
-- count must agree with the highest port index 'portInfo'
-- claims, and every port in @[0 .. ksAudioArity - 1]@ must
-- return 'Just'.
portInfo :: NodeKind -> PortIndex -> Maybe PortInfo
portInfo k (PortIndex i) = case k of
  KSinOsc       -> oscPort i
  KSawOsc       -> oscPort i
  KTriOsc       -> oscPort i
  KPulseOsc     -> case i of
    0 -> Just (PortInfo PortSampleAccurate "freq")
    1 -> Just (PortInfo PortIgnored        "phase")
    2 -> Just (PortInfo PortSampleAccurate "width")
    _ -> Nothing
  KNoiseGen     -> Nothing
  KLPF          -> filterPort i
  KHPF          -> filterPort i
  KBPF          -> filterPort i
  KNotch        -> filterPort i
  KGain         -> case i of
    0 -> Just (PortInfo PortSampleAccurate "sig")
    1 -> Just (PortInfo PortSampleAccurate "amount")
    _ -> Nothing
  KAdd          -> case i of
    0 -> Just (PortInfo PortSampleAccurate "a")
    1 -> Just (PortInfo PortSampleAccurate "b")
    _ -> Nothing
  KEnv          -> case i of
    0 -> Just (PortInfo PortSampleAccurate "gate")
    _ -> Nothing
  KOut          -> case i of
    0 -> Just (PortInfo PortSampleAccurate "sig")
    _ -> Nothing
  KBusOut       -> case i of
    0 -> Just (PortInfo PortSampleAccurate "sig")
    _ -> Nothing
  KBusIn        -> Nothing
  KBusInDelayed -> Nothing
  KDelay        -> case i of
    0 -> Just (PortInfo PortSampleAccurate "sig")
    1 -> Just (PortInfo PortSampleAccurate "time")
    _ -> Nothing
  KSmooth       -> case i of
    0 -> Just (PortInfo PortSampleAccurate "target")
    _ -> Nothing
  where
    -- Oscillator family: port 0 = freq (sample-accurate FM when
    -- wired), port 1 = phase (the initial phase is taken from
    -- 'rnControls[1]' at construction; the kernel never resolves
    -- port 1 in the audio loop, so an 'RFrom' source there is
    -- silently ignored — see 'PortIgnored').
    oscPort 0 = Just (PortInfo PortSampleAccurate "freq")
    oscPort 1 = Just (PortInfo PortIgnored        "phase")
    oscPort _ = Nothing

    -- Biquad family: signal sample-accurate, freq + q
    -- block-latched (read at sample 0, then reconfigure once per
    -- block). The kernel comment in @rt_graph.cpp@'s
    -- @process_lpf@ pins this contract.
    filterPort 0 = Just (PortInfo PortSampleAccurate "sig")
    filterPort 1 = Just (PortInfo PortBlockLatched   "freq")
    filterPort 2 = Just (PortInfo PortBlockLatched   "q")
    filterPort _ = Nothing
-- | The derived 'Enum' instance is part of the C ABI for
-- 'rt_graph_template_add_region': the marshalled int is
-- @fromEnum :: Rate -> Int@, i.e. constructor declaration order
-- (0=CompileRate ... 3=SampleRate). Reordering constructors here
-- would silently break the runtime's RegionSpec.rate field — keep
-- the order in lockstep with Note [Rate discipline] above.

{- Note [Resource effects]
~~~~~~~~~~~~~~~~~~~~~~~~~~
A major lesson from SuperNova is that graph edges alone do not
determine correct parallel execution. If two subgraphs read
and write shared buses or buffers, the linearized order of a
sequential graph may induce a semantic dependency not visible
in the explicit graph structure.

Formally, if G = (N, E_s) is the structural graph, then the
semantically schedulable graph is:

  G* = (N, E_s ∪ E_r ∪ E_t)

where E_s are structural edges (explicit connections), E_r are
resource-induced edges, and E_t are temporal or rate-boundary
edges.

The Eff type captures the resource dimension:

  Pure            — no shared-resource interaction; can be freely
                    reordered or parallelized (subject to data deps)
  BusRead         — reads from a shared bus *in the current block*;
                    induces an ordering constraint with any BusWrite
                    on the same bus (a same-cycle E_r edge)
  BusReadDelayed  — reads from the *previous block's* snapshot of a
                    shared bus; induces *no* E_r edge, because the
                    read targets a different time slice than this
                    block's writes. This is what makes feedback loops
                    schedulable: a cycle that threads through a
                    BusReadDelayed node closes only across blocks,
                    not within one. See Note [Effect-induced edges
                    (E_r)] in "MetaSonic.Bridge.Validate".
  BusWrite        — writes to a shared bus; induces ordering with
                    both BusRead (same bus) and other BusWrite (same
                    bus). Has no relationship with BusReadDelayed:
                    the delayed reader is reading a frozen snapshot
                    that this block's BusWrite cannot mutate.
  BufRead         — reads from a shared buffer
  BufWrite        — writes to a shared buffer

The asymmetry between BusRead and BusReadDelayed is the central
abstraction enabling Phase 2 feedback. In SuperCollider terms,
BusRead corresponds to 'In.ar' and BusReadDelayed corresponds to
'InFeedback.ar'.
-}

-- | Resource effects carried by a node.
--
-- See Note [Resource effects].
data Eff
  = Pure                  -- ^ No shared-resource interaction
  | BusRead         !Int  -- ^ Reads shared bus N's *current*-block contents
  | BusReadDelayed  !Int  -- ^ Reads shared bus N's *previous*-block snapshot
  | BusWrite        !Int  -- ^ Writes to shared bus N
  | BufRead         !Int  -- ^ Reads from shared buffer N
  | BufWrite        !Int  -- ^ Writes to shared buffer N
  deriving stock    (Eq, Ord, Show, Generic)
  deriving anyclass (NFData)
