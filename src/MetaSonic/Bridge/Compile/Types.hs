{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- |
-- Module      : MetaSonic.Bridge.Compile.Types
-- Description : Dense runtime types — RuntimeNode, RuntimeRegion, RuntimeGraph,
-- RegionKernel, BusFootprint, plus the C ABI tag/arity accessors.
--
-- These are the data shapes that cross the Haskell/C++ FFI boundary
-- (modulo Haskell-only metadata like 'rrFootprint' that informs
-- compile-time scheduling decisions but isn't transferred). Keep
-- types in this module pure data — no traversal or analysis logic.
-- That belongs in a sibling module
-- ('MetaSonic.Bridge.Compile.Regions',
--  'MetaSonic.Bridge.Compile.RegionKernels',
--  'MetaSonic.Bridge.Compile.Dependencies',
--  'MetaSonic.Bridge.Compile.Fusion').
--
-- Re-exported by 'MetaSonic.Bridge.Compile' for the public surface.
module MetaSonic.Bridge.Compile.Types
  ( -- * Runtime input shapes
    RuntimeInput (..)
  , ScaleRef (..)
  , AffineStep (..)
  , FusedInput (..)
    -- * Runtime nodes and output classification
  , RuntimeNode (..)
  , NodeOutputUse (..)
    -- * Region overlay
  , RegionIndex (..)
  , RuntimeRegion (..)
  , RuntimeGraph (..)
    -- * Region kernels (C ABI tags)
  , RegionKernel (..)
  , kernelTag
  , kernelArity
    -- * §7.D region execution selector
  , RegionExec (..)
  , execKernel
  , rrKernel
    -- * Bus footprints
  , BusFootprint (..)
  , emptyFootprint
    -- * §6.C.4 resource footprints (bus + buffer)
  , BufferFootprint (..)
  , emptyBufferFootprint
  , ResourceFootprint (..)
  , emptyResourceFootprint
  ) where

import           Control.DeepSeq     (NFData)
import qualified Data.Set            as S
import           Foreign.C.Types     (CInt)
import           GHC.Generics        (Generic)

import           MetaSonic.Bridge.Compile.FusionProgram (FusionProgram,
                                                         FusionProgramId)
import           MetaSonic.Bridge.Source (MigrationKey)
import           MetaSonic.Types

{- Note [Dense lowering]
~~~~~~~~~~~~~~~~~~~~~~~~
The decisive transformation in the MetaSonic pipeline:
NodeID → NodeIndex. After this pass, symbolic identity is
erased.

compileRuntimeGraph builds a mapping from NodeID to NodeIndex
(based on execution order, which is the list order of giNodes),
then rewrites every FromNode reference to use dense indices.

The result is a RuntimeGraph that can be transferred to the
C++ runtime through the FFI. After this point:

  - No Map lookups occur at runtime
  - No symbolic names exist
  - Input references are array offsets
  - The C++ side iterates the dense array in order

This is the property that makes the runtime intentionally
simple: all symbolic reasoning has been discharged before the
FFI boundary.

Dense lowering deliberately preserves node identity: each NodeIR
becomes one RuntimeNode, and the resulting NodeIndex remains the
addressable key for controls, CC mappings, diagnostics, and the C ABI.
Fusion is layered on top of that identity rather than replacing it.
An optimized graph may mark a RuntimeNode as elided and redirect a
consumer through an RFused input, but the elided node stays present so
control writes to its NodeIndex keep their meaning.

See Note [Dense runtime representation] for the types involved.
-}

{- Note [Dense runtime representation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
RuntimeInput, RuntimeNode, and RuntimeGraph are the final
Haskell-side representation before the FFI boundary.

A RuntimeNode carries:

  rnIndex          — dense position in the array; execution order
                     equals storage order equals this index
  rnOriginalID     — the symbolic NodeID from which this node was
                     compiled; retained only for diagnostics, never
                     used by the runtime
  rnKind           — dispatches to the correct C++ process function
  rnInputs         — dense input references; each RFrom points to
                     a node earlier in the array (guaranteed by
                     topological ordering)
  rnControls       — default control values, sent to C++ at load time
  rnMigrationKey   — optional Phase 5.2 state-migration identity,
                     preserved from source through IR and FFI
  rnOutputUse      — Step B-Light analysis: whether this node's output
                     buffer is consumed only within its region
                     ('RegionLocal'), escapes to a different region
                     ('RegionEscapes'), or doesn't exist at all
                     ('NoOutput' for sinks). Pure analysis, never
                     crosses the FFI. See Note [Output-use
                     classification].
  rnConsumerCount  — number of direct 'FromNode' input references to
                     this node across 'rgNodes' (multiplicity, not
                     distinct nodes — @add x x@ counts as 2).
                     Combined with 'rnOutputUse' it forms the
                     Step-C single-edge fusion gate. See Note
                     [Output-use classification].
  rnElided         — Step-C execution flag. The node remains in
                     'rgNodes' and keeps its NodeIndex, but the runtime
                     may skip its kernel because a fused consumer input
                     now performs the same work.

A RuntimeInput is either:

  RFrom NodeIndex PortIndex — read from the dense array
  RConst Double             — compile-time constant (was a
                              Literal in the IR)
  RFused FusedInput          — read through an inline transform that
                              preserves the elided node's control
                              identity

This representation is intentionally conservative: fusion reduces the
number of kernels that execute, not the number of addressable nodes.
That keeps 'rt_graph_instance_set_control', realtime control writes,
and source-to-runtime diagnostics stable across fused and unfused
graphs.
-}

-- | A runtime input reference. The first two variants are produced
-- by 'compileRuntimeGraph' as part of dense lowering. 'RFused' is
-- produced by Step C's 'fuseRuntimeGraph' rewrite to redirect a
-- consumer's input through a transformation that absorbs an elided
-- producer's per-block work.
--
-- See Note [Dense runtime representation] and Note [Fused inputs].
data RuntimeInput
  = RFrom  !NodeIndex !PortIndex
    -- ^ Read from node at this dense index, this port.
  | RConst !Double
    -- ^ Compile-time constant (was a 'Literal' in the IR).
  | RFused !FusedInput
    -- ^ Read from a fused source: an inline transform that the
    -- runtime evaluates in place of materializing the elided
    -- producer's output buffer. See 'FusedInput'.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

{- Note [Fused inputs]
~~~~~~~~~~~~~~~~~~~~~~
'FusedInput' carries the transform that an elided producer would
have applied if it were materializing its output buffer.

Three shipping variants today:

  * 'FScaleFrom' is emitted by single-edge fusion of a scalar
    'Gain':

      before:  src ──▶ Gain(k) ──▶ consumer
                       consumer.input[i] = RFrom gain 0
      after:   src ──▶ [Gain elided] ──▶ consumer
                       consumer.input[i] = RFused (FScaleFrom src srcPort gain 0)

  * 'FScaleChainFrom' is the pure-scale chain extension: a run of two
    or more scalar Gains @G1 → G2 → … → Gn@ feeding a single
    non-candidate consumer collapses to one fused input that walks
    an ordered list of 'ScaleRef' on the same source buffer:

      before:  src ──▶ G1(k1) ──▶ G2(k2) ──▶ consumer
      after:   src ──▶ [G1, G2 elided] ──▶ consumer
                       consumer.input[i] = RFused
                         (FScaleChainFrom src srcPort
                            [ScaleRef g1 0, ScaleRef g2 0])

    The list is in source-to-sink order; the resolver applies each
    scale to the running scratch in that order, so the per-sample
    arithmetic is @((src[i] * float k1) * float k2) * …@ — bit-
    identical to chained 'process_gain' kernels. The scales are
    *not* pre-multiplied (float multiplication is non-associative),
    so each elided Gain's control remains live and observable.

  * 'FAffineFrom' is the heterogeneous form: any chain that contains
    at least one bias step (an elided scalar 'Add') collapses to a
    list of 'AffineStep' carrying both 'AffScale' and 'AffBias'
    entries. Pure-bias single elisions and pure-bias chains use the
    same variant (a pure-scale chain is kept as 'FScaleChainFrom'
    for backward compatibility — the existing tests pin the older
    shape, and changing it would be churn for no semantic gain).

      before:  src ──▶ Gain(k) ──▶ Add(b) ──▶ consumer
      after:   src ──▶ [Gain, Add elided] ──▶ consumer
                       consumer.input[i] = RFused
                         (FAffineFrom src srcPort
                            [AffScale gain 0, AffBias add 1])

    Step list is source-to-sink; the resolver applies each step to
    the running scratch in that order. Per-sample arithmetic is
    @((src[i] * float k) + float b) …@ — bit-identical to the
    unfused chain of 'process_gain' / 'process_add' kernels.

In every case, every elided producer stays in 'rgNodes' with
'rnElided = True' so its 'NodeIndex' remains addressable.
'rt_graph_instance_set_control(node, slot, x)' continues to mutate
the live control; the runtime reads it at consumer-evaluation time,
exactly as the kernel's controls-fallback branch would have.

Equivalence discipline: each kernel's scalar branch casts the
'double' control to 'float' before applying the operation, so the
fused resolver must do the same — once per step, in the order the
chain stores them.
-}

-- | One scale step in a fused 'FScaleChainFrom': a reference to an
-- elided 'KGain' node and the control slot that supplies its scalar
-- gain. Kept as a separate type so the runtime dispatch over a chain
-- iterates one tuple per step and so the structure survives future
-- Gain control-shape changes.
data ScaleRef = ScaleRef
  { srScaleNode    :: !NodeIndex
    -- ^ The elided 'KGain' node whose control supplies the scale.
    --   Preserved for 'set_control' / realtime control writes.
  , srScaleControl :: !ControlIndex
    -- ^ Control slot on the elided Gain (always 0 today).
  }
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | One step in a fused 'FAffineFrom' chain. Each step references
-- an elided producer ('KGain' for 'AffScale', 'KAdd' for 'AffBias')
-- and the control slot that supplies the live scalar. Kept as a
-- tagged sum rather than two parallel arrays so the runtime resolver
-- dispatches per-step on the constructor without a parallel-vector
-- size invariant.
data AffineStep
  = AffScale !NodeIndex !ControlIndex
    -- ^ Multiply the running scratch by @float(node.controls[ctl])@.
  | AffBias  !NodeIndex !ControlIndex
    -- ^ Add @float(node.controls[ctl])@ to the running scratch.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Fused input transforms. One constructor per fusion shape; the
-- runtime dispatches on the constructor and reads the live state
-- of the referenced node (controls etc.) at evaluation time.
data FusedInput
  = FScaleFrom
      { fiSourceNode   :: !NodeIndex
        -- ^ The non-elided producer feeding the fused chain.
      , fiSourcePort   :: !PortIndex
        -- ^ Port on the producer to read.
      , fiScaleNode    :: !NodeIndex
        -- ^ The elided 'KGain' node whose control supplies the scale.
        --   Kept addressable for 'set_control' / realtime control writes.
      , fiScaleControl :: !ControlIndex
        -- ^ Control slot on the elided Gain (always 0 today; declared
        --   explicitly so the structure survives future Gain shape
        --   changes).
      }
  | FScaleChainFrom
      { fcSourceNode :: !NodeIndex
        -- ^ The non-elided producer feeding the fused chain.
      , fcSourcePort :: !PortIndex
        -- ^ Port on the producer to read.
      , fcScales     :: ![ScaleRef]
        -- ^ The chain of elided Gains, in source-to-sink order
        --   (length ≥ 2 by construction; a length-1 chain is emitted
        --   as 'FScaleFrom' instead, so existing single-edge tests are
        --   unaffected). Multiplications are applied in this order
        --   per sample to preserve float rounding identity with the
        --   unfused kernel chain.
      }
  | FAffineFrom
      { faSourceNode :: !NodeIndex
        -- ^ The non-elided producer feeding the fused chain.
      , faSourcePort :: !PortIndex
        -- ^ Port on the producer to read.
      , faSteps      :: ![AffineStep]
        -- ^ The chain of elided producers in source-to-sink order
        --   (length ≥ 1). Emitted whenever the chain contains at
        --   least one 'AffBias' step; pure-scale chains keep using
        --   'FScaleFrom' / 'FScaleChainFrom' for backward
        --   compatibility. Operations are applied in this order
        --   per sample to preserve float rounding identity with the
        --   unfused kernel chain.
      }
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | A single node in the dense runtime representation.
-- After this point, the only identifiers are positional
-- indices; symbolic 'NodeID's are gone.
--
-- See Note [Dense runtime representation].
data RuntimeNode = RuntimeNode
  { rnIndex      :: !NodeIndex
    -- ^ This node's position in the dense array.
    -- Execution order = storage order = this index.
  , rnOriginalID :: !NodeID
    -- ^ The symbolic ID from which this node was compiled.
    -- Not used by the runtime; retained for diagnostics.
  , rnKind       :: !NodeKind
    -- ^ Dispatches to the correct C++ process function.
  , rnInputs     :: ![RuntimeInput]
    -- ^ Dense input references. Each 'RFrom' points to a
    -- node that appears earlier in the array (guaranteed
    -- by topological ordering).
  , rnControls   :: ![Double]
    -- ^ Default control values, sent to C++ at load time.
  , rnMigrationKey :: !(Maybe MigrationKey)
    -- ^ Optional Phase 5.2 state-migration identity. The C++ runtime
    -- stores it on NodeSpec and uses it to build hot-swap migration
    -- plans; untagged nodes opt out.
  , rnOutputUse  :: !NodeOutputUse
    -- ^ How this node's output buffer is consumed across the
    -- region overlay (Step B-Light). Computed by
    -- 'compileRuntimeGraph' from the consumer set after regions
    -- are formed; pure analysis, never crosses the FFI.
    -- See Note [Output-use classification].
  , rnConsumerCount :: !Int
    -- ^ Number of direct 'FromNode' input references to this node
    -- across 'rgNodes'. This is a multiplicity count, not a count
    -- of distinct consumer nodes: @add x x@ contributes 2, since
    -- the producer's stateful kernel must not be re-executed for
    -- the second read. 'RegionLocal' is a *gate* for fusion (no
    -- cross-region escape), not a *license* — destructive single-
    -- edge fusion additionally needs to know there is exactly one
    -- read of the output. Step C's first-pass predicate is
    -- therefore
    --
    -- > rnOutputUse == RegionLocal && rnConsumerCount == 1
    --
    -- Fan-out cases ('rnConsumerCount > 1') stay correct as
    -- 'RegionLocal' but are ineligible for narrow single-edge
    -- rewriting; whole-region fusion can pick them up later.
    -- See Note [Output-use classification].
  , rnElided :: !Bool
    -- ^ Step C: whether the runtime should skip this node's
    -- per-block kernel because its work has been absorbed into a
    -- fused consumer input. Set only by 'fuseRuntimeGraph'; always
    -- 'False' on graphs from 'compileRuntimeGraph'. Elided nodes
    -- remain in 'rgNodes' so that 'NodeIndex' identity, control
    -- defaults, and 'rt_graph_instance_set_control' targeting the
    -- elided node all keep working — the only thing that changes
    -- is that 'process_instance' skips dispatch for the elided
    -- slot. See Note [Fused inputs].
  , rnRate :: !Rate
    -- ^ Propagated output rate from IR lowering. Descriptive
    -- metadata; the C++ runtime does not consume it. Populated
    -- from 'IRNode.irRate' (the join of the kind floor with the
    -- input rates, computed by 'MetaSonic.Bridge.IR.propagateRates')
    -- and preserved across the IR → Runtime boundary so that
    -- '--fusion-survey' and any future descriptive analysis can
    -- ask rate-distribution questions without re-running rate
    -- inference.
    --
    -- This is a per-node /output/ rate, not a per-input
    -- consumption policy. A 'KGain' fed by an oscillator carries
    -- 'SampleRate' here even when its amount input is a scalar
    -- 'CompileRate' constant; the per-input latch classification
    -- (whether the runtime samples a control once per block or
    -- per sample) is a separate concern, deferred to a later
    -- §4.D slice.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

{- Note [Output-use classification]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Step B-Light is an analysis layer that fusion (Step C) will consume.
For each 'RuntimeNode' we classify how its single output buffer is
used downstream:

  * 'NoOutput'      — the kind has no output buffer at all (currently
                      'KOut' and 'KBusOut'; both write directly to
                      'g.server.output_buses' without populating
                      'NodeInstanceState.outputs'). Distinguished from
                      'RegionLocal' / 'RegionEscapes' because there
                      is no buffer to reuse, fuse, or dissolve.

  * 'RegionLocal'   — the kind has an output buffer AND every direct
                      'FromNode' consumer is in the same region. A node
                      with no consumers also lands here (the universal
                      "all in same region" is vacuously true). These
                      are the candidates for scratch-pool reuse and
                      kernel fusion.

  * 'RegionEscapes' — the kind has an output buffer AND at least one
                      direct 'FromNode' consumer is in a different
                      region. Its output must outlive its region's
                      execution; it cannot share scratch with a
                      sibling region's intermediates.

The classification is intentionally per-node, not per-region: fusion
will ask "can I fuse node A into node B" and that requires knowing
A's output discipline and B's input set, not just aggregate counts.

Under the current 'formRegions' (greedy, with the Step-A CompileRate
absorption), almost every realistic graph collapses to a single
region; 'RegionEscapes' is a future-proofing classification that
becomes load-bearing once a kind with a non-SampleRate floor lands,
or once a non-greedy region pass starts splitting. The property test
in Spec.hs cross-checks the classification against the actual region
membership map for whatever regions 'formRegions' produces, so the
analysis stays correct as the region-formation algorithm evolves.

Sinks ('KOut', 'KBusOut') write to the server bus pool, not to a node
output buffer. The Haskell side does not currently track who reads
the bus pool — that is a global, per-block concept handled in C++.
So sinks are 'NoOutput' even though they do produce externally-
visible side effects; "output use" here refers strictly to the node's
NodeInstanceState.outputs slot.
-}

-- | How a 'RuntimeNode'\'s output buffer is consumed.
-- See Note [Output-use classification].
data NodeOutputUse
  = NoOutput
    -- ^ Kind has no per-node output buffer; the kernel writes
    -- elsewhere (currently: directly to 'g.server.output_buses').
  | RegionLocal
    -- ^ Kind has an output buffer and every consumer (if any) is
    -- in the same region as the producer.
  | RegionEscapes
    -- ^ Kind has an output buffer and at least one consumer is in
    -- a different region.
  deriving stock    (Eq, Ord, Show, Generic, Enum, Bounded)
  deriving anyclass (NFData)

-- | A region's dense position in the runtime region array.
-- Distinct from 'RegionID' (the symbolic ID assigned by
-- 'formRegions') so the Haskell-side Region/regID space cannot
-- be confused with the runtime-side ordering that crosses the FFI.
--
-- See Note [Dense lowering] and Note [Runtime regions overlay].
newtype RegionIndex = RegionIndex Int
  deriving stock   (Eq, Ord, Show, Generic)
  deriving newtype (NFData)

{- Note [Runtime regions overlay]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A 'RuntimeRegion' is a structural overlay on top of 'rgNodes': it
names a contiguous range of nodes in execution order that share a
compatible rate (see Note [Region rate compatibility]) and were
grouped by 'formRegions'. Step A of the fusion roadmap simply lifts
this grouping into the FFI / runtime data model — no kernel-level
fusion happens yet, no scratch-buffer reuse, no node elision. The
runtime can still iterate node-by-node inside each region.

NodeIndex remains the addressable identity for every control-write
ABI ('rt_graph_template_set_default', 'rt_graph_realtime_set_control',
CC mappings, etc.). Future fusion passes that elide nodes must
preserve or redirect their control-slot identities; this constraint
is recorded here because it is the obvious thing to forget once
fusion starts removing nodes.

The current greedy 'formRegions' produces contiguous regions, but
'rrNodes' carries an explicit '[NodeIndex]' rather than a
@(start, count)@ pair so a future non-greedy region pass can drop
contiguity without changing the FFI shape. The C++ side stores the
contiguity-flattened @first_node + node_count@ form because today's
regions are guaranteed contiguous; that contract is a precondition
the Haskell side must preserve until the C ABI grows a non-contiguous
form.
-}

-- | Region kernel selector. Tells the runtime which dispatch
-- strategy to use for the region: the default flat per-node loop,
-- or a hand-written fused kernel that processes every member node
-- of the region in one tight per-sample loop without materializing
-- intermediate output buffers.
--
-- The fused-kernel variants are claimed by the post-compile
-- 'selectRegionKernels' pass when a region's exact shape (kind
-- sequence, single-use internal edges, no audio modulation on
-- internal control inputs) qualifies. A region tagged for a fused
-- kernel still keeps every member's 'NodeIndex', controls, and
-- per-instance state alive — the fused kernel /reuses/ those
-- existing slots rather than introducing anonymous state. That's
-- what preserves control-write addressability and external
-- consumer reads of the terminal node's output buffer.
--
-- The integer tag is part of the C ABI: 0 = NodeLoop,
-- 1 = SawLpfGain, 2 = SinGainOut, 3 = SawLpfGainOut,
-- 4 = SawGainOut, 5 = NoiseGainOut, 6 = BusInLpfGainOut.
-- Keep 'kernelTag' in lockstep with the C++ 'RegionKernel' enum in
-- @rt_graph.cpp@.
data RegionKernel
  = RNodeLoop
    -- ^ Default: process each member node individually, in stored
    -- order, via the kind-dispatched per-node kernels. Used when no
    -- fused kernel applies, including the legacy "regions empty"
    -- fallback path.
  | RSawLpfGain
    -- ^ Buffer-terminal kernel. The region is exactly
    -- @[KSawOsc, KLPF, KGain]@ with single-use internal edges
    -- (saw → lpf, lpf → gain), no audio modulation on the gain
    -- port, and no external readers of the saw or lpf intermediate
    -- buffers. The gain's output buffer is materialized; whoever
    -- consumes it (downstream node, sibling region's sink) reads
    -- it from there. The runtime calls one fused per-sample
    -- kernel; saw / lpf / gain per-node kernels are skipped.
    --
    -- Note: when the gain's sole consumer is a sink terminal
    -- ('KOut' or 'KBusOut') and that sink would form a contiguous
    -- suffix, longest-match priority in 'findKernelMatch' picks
    -- the 4-node 'RSawLpfGainOut' instead. This 3-node kernel
    -- still fires when at least one of those gates fails: the
    -- gain has multiple consumers, the gain's sole consumer is a
    -- non-sink (e.g. 'Add', another 'Gain', 'BusIn'), or the sink
    -- is not contiguous with the prefix in the host region.
  | RSinGainOut
    -- ^ Sink-terminal kernel. The region is exactly
    -- @[KSinOsc, KGain, /sink/]@ with single-use internal edges
    -- (sin → gain, gain → /sink/), no audio modulation on the
    -- gain port, and no external readers of the sin or gain
    -- intermediate buffers. The /sink/ is either 'KOut' or
    -- 'KBusOut' — both dispatch to 'process_out' on the C++ side
    -- and read their bus index from @rnControls[0]@. Unlike
    -- 'RSawLpfGain' the terminal node is absorbed by the kernel,
    -- so it accumulates directly into 'g.server.output_buses[bus]'
    -- and updates 'inst.block_sink_peak' for §2.E release-then-
    -- free silence detection — no intermediate buffer is
    -- materialized.
  | RSawLpfGainOut
    -- ^ Sink-terminal kernel for the full 4-node chain
    -- @[KSawOsc, KLPF, KGain, /sink/]@. Combines the saw + LPF +
    -- gain processing of 'RSawLpfGain' with the bus accumulation
    -- and 'inst.block_sink_peak' update of 'RSinGainOut'. The
    -- /sink/ is either 'KOut' or 'KBusOut'. Single-use internal
    -- edges and scalar-gain rules apply, plus an explicit
    -- @rnConsumerCount gain == 1@ requirement (the gain output
    -- must escape only via the absorbed sink; otherwise the
    -- 3-node 'RSawLpfGain' fires and the gain's buffer is
    -- materialized for the external readers).
  | RSawGainOut
    -- ^ Sink-terminal kernel for @[KSawOsc, KGain, /sink/]@:
    -- the saw counterpart of 'RSinGainOut'. Same single-use
    -- internal-edge / scalar-gain / sink-class rules. Added
    -- after the @--fusion-survey@ scan flagged @Saw → Gain →
    -- sink@ as the most-missed shape on the demo set; the
    -- per-sample DSP body is just @q::saw -> *gain_amount@,
    -- exactly the SinGainOut kernel with @q::saw@ in place of
    -- @q::sin@.
  | RNoiseGainOut
    -- ^ Sink-terminal kernel for @[KNoiseGen, KGain, /sink/]@.
    -- Mechanically the noise counterpart of 'RSinGainOut' /
    -- 'RSawGainOut', but covers a different state class: noise
    -- carries a 'q::white_noise_gen' xorshift PRNG instead of
    -- a 'q::phase_iterator'. NoiseGen has no audio inputs and
    -- no controls, so the kernel body is the simplest of the
    -- sink-terminal set — pull one PRNG sample, recenter to
    -- bipolar, multiply by the gain control, accumulate into
    -- the bus. Reuses 'SinkAccumulator' but /not/
    -- 'drive_oscillator' (no freq port to branch on).
  | RBusInLpfGainOut
    -- ^ Sink-terminal kernel for @[KBusIn, KLPF, KGain, /sink/]@.
    -- The first non-oscillator producer in the §4.B family: the
    -- chain's source isn't a generator with phase / PRNG state,
    -- it's a bus reader. Per-sample body: read
    -- 'output_buses[busin_bus][i]' (same value 'process_busin'
    -- would have copied), filter, multiply by the scalar gain,
    -- accumulate into the sink bus. Reuses the LPF freq/q
    -- block-rate latch from 'RSawLpfGainOut' and 'SinkAccumulator'
    -- for the bus + sink-peak side; no 'drive_oscillator' (no
    -- oscillator state).
    --
    -- This is the canonical send-return tail kernel: a voice
    -- template writes a bus, the fx template's
    -- @[BusIn, LPF, Gain, Out]@ chain reads it. Added after the
    -- @--fusion-survey@ scan (with the post-template-corpus
    -- counts in @c206794@..@fd9c8e6@) flagged
    -- @BusIn → LPF → Gain → sink@ as the strongest recurring
    -- missed shape — 9 misses across template ensembles vs. 3
    -- for the noise-rooted alternative.
  | RNoiseLpfGainOut
    -- ^ Sink-terminal kernel for @[KNoiseGen, KLPF, KGain, /sink/]@.
    -- Mechanically the noise counterpart of 'RSawLpfGainOut':
    -- replace the saw oscillator at the head with a 'q::white_noise_gen'
    -- xorshift PRNG, keep the LPF / scalar Gain / SinkAccumulator
    -- pipeline. No 'drive_oscillator' (no phase iterator); no
    -- 'output_buses' read (no bus source); the producer state is
    -- a PRNG whose next sample arrives via @noisegen->noise()@.
    --
    -- Bit-equivalence with the unfused chain rests on PRNG cadence
    -- parity: the kernel must call @noisegen->noise()@ /once per
    -- output sample/, in the same order, with the same recentering
    -- subtract that 'process_noisegen' applies. The
    -- 'fusedEquivalenceCases' suite pins this.
    --
    -- Added after the post-step-2 ranked missed-shape table
    -- crossed the kernel-add gate from
    -- @notes/2026-05-08-fusion-strategy.md@: @missed=4, sources=4@,
    -- producer in the proven sink-terminal family, kernel body
    -- absorbs the sink and avoids materializing NoiseGen / LPF /
    -- Gain output buffers in sequence. Tri / Pulse / Add filtered
    -- tails stay parked — they are single-source signals.
  deriving stock    (Eq, Show, Generic, Bounded, Enum)
  deriving anyclass (NFData)

-- | C ABI tag for 'RegionKernel'. Mirrors the integer values the
-- C++ side dispatches on in @rt_graph.cpp@'s @RegionKernel@ enum.
-- A property test pins this against the C++ side via the
-- @rt_graph_region_kernel_supported@ entry; do not change either
-- value in isolation.
kernelTag :: RegionKernel -> CInt
kernelTag RNodeLoop         = 0
kernelTag RSawLpfGain       = 1
kernelTag RSinGainOut       = 2
kernelTag RSawLpfGainOut    = 3
kernelTag RSawGainOut       = 4
kernelTag RNoiseGainOut     = 5
kernelTag RBusInLpfGainOut  = 6
kernelTag RNoiseLpfGainOut  = 7

-- | Number of contiguous member nodes a fused kernel claims when
-- it matches. 'RNodeLoop' has no fixed arity — a NodeLoop region
-- carries however many nodes 'formRegions' grouped — so calling
-- 'kernelArity' on it returns 0 as a safe placeholder. Real
-- callers ('findKernelMatch' and the C++ dispatch guards) only
-- ever ask about successfully-matched fused kernels, so the
-- 'RNodeLoop' branch is never exercised in production paths.
kernelArity :: RegionKernel -> Int
kernelArity RSawLpfGain       = 3
kernelArity RSinGainOut       = 3
kernelArity RSawLpfGainOut    = 4
kernelArity RSawGainOut       = 3
kernelArity RNoiseGainOut     = 3
kernelArity RBusInLpfGainOut  = 4
kernelArity RNoiseLpfGainOut  = 4
kernelArity RNodeLoop         = 0


{- Note [Region execution selector]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

§7.D widens region dispatch to three cases:

  * 'ExecNodeLoop'    — per-node dispatch, the default.
  * 'ExecKernel'      — a hand-written 'RegionKernel' (existing path).
  * 'ExecGenerated'   — a generated 'FusionProgram', referenced by id
                        into the runtime graph's program table.

The selector is intentionally a sum type rather than a
@'Maybe' 'FusionProgramId'@ field alongside the previous
'rrKernel'. Encoding the three cases structurally prevents a hidden
invariant ("when generated id is 'Just', kernel must be
'RNodeLoop'") that future code could violate.

'rrKernel' survives as a backward-compatible /accessor/ that
projects out the previous enum view: 'ExecKernel' regions return
their kernel; everything else returns 'RNodeLoop'. Code that wants
to tell generated programs apart from node-loop pattern-matches on
'rrExec' directly.

See @notes/2026-05-12-phase-7d-runtime-program-abi.md@.
-}

-- | The dispatch selector for one 'RuntimeRegion'. See
-- Note [Region execution selector].
data RegionExec
  = ExecNodeLoop
  | ExecKernel    !RegionKernel
  | ExecGenerated !FusionProgramId
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Smart constructor: build an 'ExecKernel' from a 'RegionKernel',
-- collapsing 'RNodeLoop' to 'ExecNodeLoop'. Kernel-selection code
-- that produces a @'RegionKernel'@ value and wants to set the
-- region's exec should use this rather than wrap directly.
execKernel :: RegionKernel -> RegionExec
execKernel RNodeLoop = ExecNodeLoop
execKernel k         = ExecKernel k

-- | Backward-compatible accessor: projects 'rrExec' into the
-- previous 'RegionKernel' enum view. 'ExecGenerated' regions read
-- as 'RNodeLoop' through this lens — readers that need to
-- distinguish should pattern-match on 'rrExec' directly.
rrKernel :: RuntimeRegion -> RegionKernel
rrKernel r = case rrExec r of
  ExecNodeLoop    -> RNodeLoop
  ExecKernel k    -> k
  ExecGenerated _ -> RNodeLoop


{- Note [Bus footprints, template- vs region-level]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'BusFootprint' is the bus-level interface a unit of execution
exposes: the bus indices it writes, reads live, and reads delayed.
The same shape applies at three nested scopes:

  * Whole template: aggregate over every node in the template's
    'GraphIR' (used by 'compileTemplateGraph' to derive the
    inter-template precedence DAG).
  * One region: aggregate over the region's member 'RuntimeNode's
    (used by 'regionResourcePrecedence' / 'regionDependencies'
    for intra-template region ordering — §4.E.1 / §4.E.1b — and
    by the bus-only diagnostic sibling 'regionBusPrecedence').
  * One node: trivially derived from 'rnKind' + 'rnControls[0]'.

Reusing the type at every scope keeps the precedence rule
("A precedes B iff bfWrites(A) ∩ bfReads(B) ≠ ∅, delayed reads
do not contribute") identical from intra-region all the way up
to inter-template — the only thing that changes is which set of
nodes the fold covers.

The template-level extractor lives in 'MetaSonic.Bridge.Templates'
because it consumes 'GraphIR' (compile-time IR, not runtime).
The region- and runtime-graph-level extractors live in
'MetaSonic.Bridge.Compile.Dependencies' because they consume
'RuntimeNode' values directly.
-}

-- | Bus-level interface of a unit of execution: bus indices touched,
-- and how. Only 'bfWrites' and 'bfReads' contribute to precedence;
-- 'bfDelayedReads' is recorded for diagnostics but never induces an
-- ordering edge (matching intra-graph E_r and the template-level
-- precedence rule — see 'MetaSonic.Bridge.Templates').
data BusFootprint = BusFootprint
  { bfWrites       :: !(S.Set Int)
    -- ^ Bus indices written by 'KOut' or 'KBusOut' nodes.
  , bfReads        :: !(S.Set Int)
    -- ^ Bus indices read live by 'KBusIn' nodes.
  , bfDelayedReads :: !(S.Set Int)
    -- ^ Bus indices read delayed by 'KBusInDelayed' nodes.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

emptyFootprint :: BusFootprint
emptyFootprint = BusFootprint S.empty S.empty S.empty

{- Note [Resource footprints, §6.C.4]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'BufferFootprint' is the buffer-keyed analogue of 'BusFootprint'.
It carries the buffer indices a unit of execution writes, reads
live, and reads delayed — exactly the same shape, indexed on a
disjoint id space. 'ResourceFootprint' is the pair, the
superset consumed by template- / region-level precedence. The
same rule applies to both namespaces: live reads depend on earlier
writes, while delayed reads deliberately do not add ordering
constraints.

'Template.tplFootprint' and 'RuntimeRegion.rrFootprint' carry
'ResourceFootprint'. The inter-template precedence rule unions bus
and buffer edges, while bus-only graphs stay bit-identical because
'emptyBufferFootprint' is the BufferFootprint identity under union
and 'rfBuses' is a zero-cost projection.

Same-buffer 'BufWrite / BufWrite' is rejected at compile time
in v1 — see the 6.C.4 design note for the rationale and the
6.C.5+ placeholder for lifting it.
-}

-- | Buffer-keyed analogue of 'BusFootprint'. The set semantics
-- and the "delayed reads do not contribute to precedence" rule
-- are identical; only the id space differs. Bus indices and
-- buffer indices live in disjoint namespaces, so unioning the
-- two footprints can never collide.
data BufferFootprint = BufferFootprint
  { bfBufWrites       :: !(S.Set Int)
    -- ^ Buffer indices written by writer kinds (no writer kind
    -- exists in 6.C.3a/b; populated by the 6.C.4+ writer UGen
    -- via 'BufWrite' effects).
  , bfBufReads        :: !(S.Set Int)
    -- ^ Buffer indices read live by 'KPlayBufMono' (and future
    -- read kinds). Currently populated from 'BufRead' effects.
  , bfBufDelayedReads :: !(S.Set Int)
    -- ^ Buffer indices read delayed. Reserved for symmetry
    -- with 'bfDelayedReads'; no consumer in 6.C.4.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

emptyBufferFootprint :: BufferFootprint
emptyBufferFootprint = BufferFootprint S.empty S.empty S.empty

-- | §6.C.4 resource-level interface: the buses and buffers a
-- unit of execution touches. This is what template- and
-- region-level precedence consume once writer UGens exist;
-- bus-only callers can still reach the existing bus surface
-- through 'rfBuses' without touching the new field. See
-- Note [Resource footprints, §6.C.4].
data ResourceFootprint = ResourceFootprint
  { rfBuses   :: !BusFootprint
  , rfBuffers :: !BufferFootprint
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

emptyResourceFootprint :: ResourceFootprint
emptyResourceFootprint = ResourceFootprint emptyFootprint emptyBufferFootprint

-- | One execution region in the runtime graph: a contiguous block
-- of nodes (in execution order) that 'formRegions' grouped together.
--
-- See Note [Runtime regions overlay].
data RuntimeRegion = RuntimeRegion
  { rrIndex  :: !RegionIndex
    -- ^ Dense position of this region in 'rgRuntimeRegions'.
  , rrRate   :: !Rate
    -- ^ Region execution rate (the join of member rates; see
    -- Note [Region rate compatibility]).
  , rrNodes  :: ![NodeIndex]
    -- ^ Member nodes in execution order. Currently always contiguous
    -- (greedy 'formRegions' invariant), but the type does not encode
    -- that.
  , rrExec   :: !RegionExec
    -- ^ Region dispatch selector. 'ExecNodeLoop' on every region
    -- produced by 'formRegions'; 'selectRegionKernels' may upgrade
    -- some regions to 'ExecKernel' after splitting. 'ExecGenerated'
    -- is the §7.D generated-program path; it is not produced by
    -- 'compileRuntimeGraph' today.
    --
    -- See Note [Region execution selector] and the
    -- backward-compatible 'rrKernel' accessor for the previous
    -- 'RegionKernel'-only view.
  , rrFootprint :: !ResourceFootprint
    -- ^ §6.C.4: resource-level interface of this region. The
    -- bus half ('rfBuses') carries the writes / live-reads /
    -- delayed-reads that drove pre-§6.C.4 region precedence;
    -- the buffer half ('rfBuffers') joins the precedence
    -- union via 'regionResourcePrecedence'.
    --
    -- Computed by 'attachRegionFootprints' as the final step
    -- of 'compileRuntimeGraph' so the same field survives
    -- 'selectRegionKernels' splits without going stale.
    -- §4.E.1 / §4.E.1b metadata only — does not change region
    -- execution order today.
    --
    -- Three views consume this field:
    --
    --   * 'regionBusPrecedence' — diagnostics; bus-only.
    --   * 'regionResourcePrecedence' — §6.C.4 bus + buffer
    --     resource union; the precedence rule a future writer
    --     UGen will trip.
    --   * 'regionDependencies' — the scheduler's full view:
    --     'regionResourcePrecedence' unioned with structural
    --     cross-region port edges.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | The fully compiled runtime graph: a list of dense nodes
-- ready to be transferred across the FFI boundary, plus a
-- region overlay for the runtime to use as the unit of execution.
--
-- The 'rgRuntimeRegions' field is named distinctly from
-- 'RegionGraph.rgRegions' (which holds the compile-time 'Region's)
-- because both record types share the @rg@ prefix and the field
-- names would otherwise collide.
--
-- See Note [Dense lowering] and Note [Runtime regions overlay].
data RuntimeGraph = RuntimeGraph
  { rgNodes           :: ![RuntimeNode]
  , rgRuntimeRegions  :: ![RuntimeRegion]
  , rgFusionPrograms  :: ![FusionProgram]
    -- ^ §7.D generated-fusion program table. Empty for every
    -- graph 'compileRuntimeGraph' produces today; populated by
    -- generated cost-lab variants and, later, by planner-driven
    -- emission. Indexed by 'FusionProgramId' through 'ExecGenerated'
    -- references in 'rrExec'.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)
