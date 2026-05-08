{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- |
-- Module      : MetaSonic.Compile
-- Description : Region formation and dense lowering
--
-- This module performs the final two compilation stages:
--
--   1. Region formation: partition the annotated IR into
--      execution regions — maximal subgraphs that share a
--      compatible rate and can be scheduled as units.
--      See Note [Region formation].
--
--   2. Dense lowering: replace every symbolic 'NodeID' with
--      a contiguous 'NodeIndex', producing a representation
--      that the C++ runtime can traverse without maps, hashing,
--      or symbolic lookup.
--      See Note [Dense lowering].

module MetaSonic.Bridge.Compile
  ( -- * Runtime representation
    RuntimeInput (..)
  , FusedInput (..)
  , ScaleRef (..)
  , AffineStep (..)
  , RuntimeNode (..)
  , RuntimeRegion (..)
  , RegionKernel (..)
  , kernelTag
  , RuntimeGraph (..)
  , RegionIndex (..)
  , NodeOutputUse (..)
  , -- * Compilation
    compileRuntimeGraph
  , compileRuntimeGraphUnfused
  , compileRuntimeGraphFused
  , fuseRuntimeGraph
  , selectRegionKernels
  , resolveNodeIndex
  , -- * Region formation
    RegionID (..)
  , Region (..)
  , RegionGraph (..)
  , formRegions
  ) where

import           Control.DeepSeq     (NFData)
import qualified Data.Map.Strict     as M
import qualified Data.Set            as S
import           Foreign.C.Types     (CInt)
import           GHC.Generics        (Generic)

import           MetaSonic.Bridge.IR
import           MetaSonic.Types

{- Note [Region formation]
~~~~~~~~~~~~~~~~~~~~~~~~~~
A region is a maximal subgraph or semantic term cluster such that:

  (1) all members share a compatible rate and staging regime
  (2) resource hazards internal to the region are ordered and
      analyzable
  (3) fusion yields a net benefit under a cost model
  (4) recursive or delay-carrying state is locally representable
  (5) the region can be lowered to scalar code, vector code, or
      a sequential loop nest

The current implementation satisfies (1) and partially (2). It is
a greedy linear scan: walk the toposorted IR and extend the current
region as long as the next node has the same rate and all its
dependencies are either inside the current region or in already-
completed regions. When any condition breaks, the region is closed
and a new one begins.

Conditions (3)–(5) require a cost model, state analysis, and code
generation strategy that are part of the future architecture.

See Note [Region rate compatibility] for the rate-matching rule.
See Note [Why greedy extension is correct but not optimal] for
the limitations of the greedy strategy.
See Note [Region DAG as scheduling target] for how the region
graph relates to parallel scheduling.
-}

{- Note [Region rate compatibility]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A node can extend the current region only if its rate is
*compatible* with the region's rate. This is condition (1) from
the region formation criteria:

  "All members share a compatible rate and staging regime"

Two rates are compatible iff they are equal or at least one of
them is 'CompileRate'. The region's stored 'regRate' is the join
('max') of its members' rates, so a 'CompileRate' node absorbed
into a 'SampleRate' region does not lower the region's execution
rate; it is simply scheduled inside the faster region (its value
is statically known and trivially sample-and-held).

Members of a single region therefore no longer all share an
identical 'irRate'. The post-condition is the weaker invariant
that every member's rate is compatible with 'regRate' — see
'propRegionRateCompatible' in Spec.hs.

A future relaxation could also admit 'BlockRate' into 'SampleRate'
regions, but that needs an explicit sample-and-hold boundary in
the runtime and is deferred until a kind actually produces
'BlockRate' (none does today).

Rate assignment is computed by 'MetaSonic.Bridge.IR.propagateRates'
before this pass runs: each node's 'irRate' is the join of its
kind's floor rate and the rates of its inputs. So a 'Gain' fed by
two 'Param' literals receives 'irRate = CompileRate' and joins a
neighbouring 'SampleRate' region (or starts its own pure-constant
region if there is no faster neighbour); the same 'Gain' fed by a
'SinOsc' receives 'irRate = SampleRate' and joins a sample-rate
region. This is what makes region formation non-degenerate —
pre-propagation every node was unconditionally SampleRate, so the
entire graph formed one region.

See Note [Rate inference vs rate propagation] in
"MetaSonic.Bridge.IR".
-}

{- Note [Why greedy extension is correct but not optimal]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The greedy algorithm always extends the current region when rate
and dependency conditions hold. This produces correct regions (no
rate mismatch, no dependency violation) but does not consider:

  - Cost model: a large region may defeat vectorization
  - State complexity: stateful nodes (filters, delay lines)
    create loop-carried dependencies that constrain SIMD
  - Scheduling flexibility: fewer, larger regions reduce the
    parallelism available to a region-level scheduler

Faust's vector code generator shows that splitting can be
as valuable as fusion. A future cost-model-guided pass would
operate on the RegionGraph produced here, splitting or merging
regions based on estimated benefit.
-}

{- Note [Region DAG as scheduling target]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The correct future target is a region DAG, not a node DAG.

Let R = {r₁, …, rₘ} be the set of execution regions obtained
by formRegions after annotation and dependency analysis. Then
compilation produces a DAG H = (R, D) whose edges include
structural, resource, and temporal dependencies — precisely the
regDeps :: Set RegionID field of each Region.

A region scheduler can then produce dependency levels or
readiness queues. This is related to Faust's construction of
a directed graph of computation loops and its topological
ordering, but extended with resource semantics and low-latency
constraints.

SuperNova's paper explicitly notes that fine-grained graphs are not
feasibly scheduled by assigning each graph node to the scheduler
individually; sequential scheduling is efficient precisely
because one can iterate over a linearized graph. MetaSonic
adopts the same assumption: parallelism must be expressed at
the level of regions rather than individual UGens. A future
parallel scheduler would dispatch regions (not individual nodes)
to worker threads, amortizing scheduling overhead over the nodes
within each region.
-}

-- | A region identifier, analogous to 'NodeIndex' but at the
-- region level. In a future parallel scheduler, the ready
-- queue would contain 'RegionID's, not 'NodeIndex'es.
--
-- See Note [Region DAG as scheduling target].
newtype RegionID = RegionID Int
  deriving stock   (Eq, Ord, Show, Generic)
  deriving newtype (NFData)

-- | An execution region: a maximal group of nodes that share
-- a rate and can be scheduled as a single unit.
--
-- See Note [Region formation].
data Region = Region
  { regID      :: !RegionID
  , regRate    :: !Rate
  , regEffects :: ![Eff]
    -- ^ Union of member effects. Used by future effect
    -- analysis to determine inter-region ordering constraints.
    -- If a region has only 'Pure' effects and no data
    -- dependencies on another region, the two regions can
    -- execute in parallel.
  , regNodes   :: ![NodeID]
    -- ^ Member nodes in execution order within the region.
  , regDeps    :: !(S.Set RegionID)
    -- ^ Regions that must complete before this region can
    -- execute. These are the edges in the region DAG.
    -- See Note [Region DAG as scheduling target].
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | The region graph: regions in execution order, plus an
-- ownership map from nodes to regions.
--
-- See Note [Region DAG as scheduling target].
data RegionGraph = RegionGraph
  { rgRegions :: ![Region]
    -- ^ Regions in execution order.
  , rgNodeMap :: !(M.Map NodeID RegionID)
    -- ^ Ownership map: which region contains each node.
    -- Used to compute inter-region edges when a node in
    -- one region depends on a node in another.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Two rates may share a region iff they are equal or at
-- least one is 'CompileRate'. See Note [Region rate compatibility].
compatibleRate :: Rate -> Rate -> Bool
compatibleRate a b = a == b || a == CompileRate || b == CompileRate

-- | Greedy region formation over a list of 'NodeIR' in
-- execution order.
--
-- See Note [Region formation].
-- See Note [Region rate compatibility].
-- See Note [Why greedy extension is correct but not optimal].
formRegions :: [NodeIR] -> RegionGraph
formRegions [] = RegionGraph [] M.empty
formRegions nodes =
  let (regions, nodeOwner) = go 0 [] M.empty S.empty Nothing nodes
  in  RegionGraph (reverse regions) nodeOwner
  where
    -- Collect the set of NodeIDs that a given node depends on.
    nodeDeps :: NodeIR -> S.Set NodeID
    nodeDeps n = S.fromList [ nid | FromNode nid _ <- irInputs n ]

    -- State threaded through the scan:
    --   nextID   : counter for generating fresh RegionIDs
    --   acc      : completed regions (in reverse order)
    --   owner    : NodeID → RegionID for completed regions
    --   curNodes : set of NodeIDs in the current open region
    --   open     : the open region's state, or Nothing

    go :: Int
       -> [Region]
       -> M.Map NodeID RegionID
       -> S.Set NodeID
       -> Maybe (RegionID, Rate, [Eff], [NodeID], S.Set RegionID)
       -> [NodeIR]
       -> ([Region], M.Map NodeID RegionID)

    -- Base case: no more nodes. Close any open region.
    go _nextID acc owner _curNodes Nothing [] =
      (acc, owner)
    go _nextID acc owner _curNodes (Just (rid, rate, effs, members, deps)) [] =
      let !region = Region rid rate effs (reverse members) deps
      in  (region : acc, owner)

    -- Recursive case: process the next node.
    go nextID acc owner curNodes openRegion (n : rest) =
      let nid   = irNodeID n
          nRate = irRate n
          nEffs = irEffects n
          nDeps = nodeDeps n

          -- Dependencies outside the current open region.
          externalDeps = nDeps `S.difference` curNodes

          -- Which completed regions own those external deps?
          externalRegions = S.fromList
            [ r | dep <- S.toList externalDeps
                , Just r <- [M.lookup dep owner]
            ]

          -- Can this node extend the current open region?
          -- See Note [Region rate compatibility].
          canExtend = case openRegion of
            Nothing -> False
            Just (_, curRate, _, _, _) ->
              compatibleRate curRate nRate
              && all (\d -> M.member d owner || S.member d curNodes)
                     (S.toList nDeps)

      in if canExtend
         then
           -- Extend the current open region with this node.
           case openRegion of
             Just (rid, curRate, curEffs, members, curDeps) ->
               let !newOwner    = M.insert nid rid owner
                   !newCurNodes = S.insert nid curNodes
                   -- Region rate is the join of its members'
                   -- rates: a CompileRate node absorbed into a
                   -- SampleRate region keeps the region at
                   -- SampleRate. See Note [Region rate compatibility].
                   !newRate     = max curRate nRate
               in go nextID acc newOwner newCurNodes
                    (Just ( rid
                          , newRate
                          , nEffs ++ curEffs
                          , nid : members
                          , curDeps `S.union` externalRegions
                          ))
                    rest
             Nothing -> error "canExtend True with no open region"
         else
           -- Close the current open region (if any) and
           -- start a new one for this node.
           let (!closedAcc, !closedOwner, !closedNextID) =
                 case openRegion of
                   Nothing -> (acc, owner, nextID)
                   Just (rid, rate, effs, members, deps) ->
                     let !region = Region rid rate effs (reverse members) deps
                     in  (region : acc, owner, nextID)

               !newRID      = RegionID closedNextID
               !newOwner    = M.insert nid newRID closedOwner
               !newCurNodes = S.singleton nid
               !newDeps     = S.fromList
                   [ r | dep <- S.toList nDeps
                       , Just r <- [M.lookup dep closedOwner]
                   ]
           in go (closedNextID + 1) closedAcc newOwner newCurNodes
                 (Just (newRID, nRate, nEffs, [nid], newDeps))
                 rest

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
    -- runtime evaluates in place of materialising the elided
    -- producer's output buffer. See 'FusedInput'.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

{- Note [Fused inputs]
~~~~~~~~~~~~~~~~~~~~~~
'FusedInput' carries the transform that an elided producer would
have applied if it were materialising its output buffer.

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
-- of the region in one tight per-sample loop without materialising
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
-- 1 = SawLpfGain, 2 = SinGainOut, 3 = SawLpfGainOut. Keep
-- 'kernelTag' in lockstep with the C++ 'RegionKernel' enum in
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
  deriving stock    (Eq, Show, Generic, Bounded, Enum)
  deriving anyclass (NFData)

-- | C ABI tag for 'RegionKernel'. Mirrors the integer values the
-- C++ side dispatches on in @rt_graph.cpp@'s @RegionKernel@ enum.
-- A property test pins this against the C++ side via the
-- @rt_graph_region_kernel_supported@ entry; do not change either
-- value in isolation.
kernelTag :: RegionKernel -> CInt
kernelTag RNodeLoop      = 0
kernelTag RSawLpfGain    = 1
kernelTag RSinGainOut    = 2
kernelTag RSawLpfGainOut = 3

-- | Number of contiguous member nodes a fused kernel claims when
-- it matches. 'RNodeLoop' has no fixed arity — a NodeLoop region
-- carries however many nodes 'formRegions' grouped — so calling
-- 'kernelArity' on it returns 0 as a safe placeholder. Real
-- callers ('findKernelMatch' and the C++ dispatch guards) only
-- ever ask about successfully-matched fused kernels, so the
-- 'RNodeLoop' branch is never exercised in production paths.
kernelArity :: RegionKernel -> Int
kernelArity RSawLpfGain    = 3
kernelArity RSinGainOut    = 3
kernelArity RSawLpfGainOut = 4
kernelArity RNodeLoop      = 0

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
  , rrKernel :: !RegionKernel
    -- ^ Region kernel selector. 'RNodeLoop' on every region produced
    -- by 'formRegions'; 'selectRegionKernels' may upgrade some
    -- regions to a fused kernel after splitting the region to
    -- contain only the matched members. See 'RegionKernel'.
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
  { rgNodes          :: ![RuntimeNode]
  , rgRuntimeRegions :: ![RuntimeRegion]
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Look up the dense 'NodeIndex' that a given symbolic 'NodeID'
-- compiled to. Returns 'Nothing' if the 'NodeID' isn't present in
-- the graph (e.g. a stray ID from a different graph, or one that
-- was elided by a future fusion pass).
--
-- The intended use is post-compile binding: the source DSL
-- accumulates symbolic 'NodeID's; the runtime ABI takes dense
-- 'NodeIndex'es; this resolver bridges the two so MIDI/CC/observability
-- code can target a specific compiled node.
resolveNodeIndex :: RuntimeGraph -> NodeID -> Maybe NodeIndex
resolveNodeIndex rg nid =
  rnIndex <$> lookupNode (rgNodes rg)
  where
    lookupNode []                       = Nothing
    lookupNode (n:ns)
      | rnOriginalID n == nid           = Just n
      | otherwise                       = lookupNode ns

-- | Compile a 'GraphIR' into a dense 'RuntimeGraph'.
--
-- Fails if any symbolic reference cannot be resolved to a
-- dense index (which would indicate a bug in earlier passes,
-- since validation already checked referential integrity).
--
-- See Note [Dense lowering].
compileRuntimeGraph :: GraphIR -> Either String RuntimeGraph
compileRuntimeGraph ir = do
  let !irNodes = giNodes ir

      -- Build the decisive map: NodeID → NodeIndex.
      -- The index is the node's position in execution order.
      !indexMap = M.fromList
        [ (irNodeID n, NodeIndex i)
        | (i, n) <- zip [0..] irNodes
        ]

  -- Region overlay: form regions from the IR, then translate the
  -- per-region NodeID membership into the dense NodeIndex space.
  -- See Note [Runtime regions overlay].
  rtRegions <- mapM (compileRegion indexMap)
                    (zip [0..] (rgRegions (formRegions irNodes)))

  -- Output-use classification (Step B-Light): for each NodeIndex, look
  -- up the region it belongs to, then check whether every consumer
  -- lives in that same region. Sinks ('KOut'/'KBusOut') skip the check
  -- entirely and land in 'NoOutput'.
  -- See Note [Output-use classification].
  let !nodeRegion = M.fromList
        [ (ix, rrIndex r)
        | r <- rtRegions, ix <- rrNodes r
        ]

      -- Consumer map built from the (still-symbolic) IR inputs:
      -- for each consumer node, every 'FromNode src _' contributes a
      -- (src, consumer) edge. We translate via indexMap to NodeIndex
      -- so the keys and values live in the same dense space as
      -- 'nodeRegion'.
      !consumerMap = M.fromListWith (++)
        [ (srcIx, [consumerIx])
        | n <- irNodes
        , let consumerIx = indexMap M.! irNodeID n
        , FromNode srcID _ <- irInputs n
        , Just srcIx <- [M.lookup srcID indexMap]
        ]

      classify :: NodeIndex -> NodeKind -> NodeOutputUse
      classify _   KOut    = NoOutput
      classify _   KBusOut = NoOutput
      classify ix _        =
        let myRegion = M.lookup ix nodeRegion
            consumers = M.findWithDefault [] ix consumerMap
            allLocal  = all (\c -> M.lookup c nodeRegion == myRegion) consumers
        in if allLocal then RegionLocal else RegionEscapes

      consumerCount :: NodeIndex -> Int
      consumerCount ix = length (M.findWithDefault [] ix consumerMap)

  rtNodes <- mapM (compileNode indexMap classify consumerCount) (zip [0..] irNodes)

  -- §4.B region kernel selection runs as the last step of compile,
  -- before any §4.C-style elision pass. Tagging happens here so
  -- 'fuseRuntimeGraph' (which §4.C's 'compileRuntimeGraphFused'
  -- runs next) can skip nodes that have already been claimed by a
  -- fused region kernel — otherwise §4.C would elide a Gain that
  -- the region kernel still expects to address by control slot.
  -- See Note [Region kernel selection].
  pure $! selectRegionKernels (RuntimeGraph rtNodes rtRegions)

  where
    compileNode
      :: M.Map NodeID NodeIndex
      -> (NodeIndex -> NodeKind -> NodeOutputUse)
      -> (NodeIndex -> Int)
      -> (Int, NodeIR)
      -> Either String RuntimeNode
    compileNode indexMap classify consumerCount (i, node) = do
      inputs <- mapM (compileInput indexMap) (irInputs node)
      let !ix   = NodeIndex i
          !kind = irKind node
      pure $! RuntimeNode
        { rnIndex         = ix
        , rnOriginalID    = irNodeID node
        , rnKind          = kind
        , rnInputs        = inputs
        , rnControls      = irControls node
        , rnOutputUse     = classify ix kind
        , rnConsumerCount = consumerCount ix
        , rnElided        = False
          -- compileRuntimeGraph never elides; only fuseRuntimeGraph
          -- (Step C) flips this to True for nodes absorbed by a
          -- fused consumer input. See Note [Fused inputs].
        }

    -- Rewrite a symbolic InputConn to a dense RuntimeInput.
    -- See Note [Dense lowering].
    compileInput
      :: M.Map NodeID NodeIndex
      -> InputConn
      -> Either String RuntimeInput
    compileInput _ (Literal x) = Right (RConst x)
    compileInput indexMap (FromNode src port) =
      case M.lookup src indexMap of
        Nothing -> Left $ "Missing runtime index for " ++ show src
        Just ix -> Right (RFrom ix port)

    -- Translate a compile-time 'Region' into a dense 'RuntimeRegion'.
    -- The 'regNodes' field is a list of symbolic 'NodeID's; we look
    -- each up in the same NodeID → NodeIndex map used by node lowering.
    -- A miss is the same kind of internal-bug case as in 'compileInput'.
    -- See Note [Runtime regions overlay].
    compileRegion
      :: M.Map NodeID NodeIndex
      -> (Int, Region)
      -> Either String RuntimeRegion
    compileRegion indexMap (i, region) = do
      members <- mapM (lookupNodeIndex indexMap) (regNodes region)
      pure $! RuntimeRegion
        { rrIndex  = RegionIndex i
        , rrRate   = regRate region
        , rrNodes  = members
        , rrKernel = RNodeLoop
          -- Default for every region produced by 'formRegions'.
          -- 'selectRegionKernels' may upgrade some regions to a
          -- fused kernel after splitting, before the final
          -- 'RuntimeGraph' is returned.
        }

    lookupNodeIndex
      :: M.Map NodeID NodeIndex
      -> NodeID
      -> Either String NodeIndex
    lookupNodeIndex indexMap nid =
      case M.lookup nid indexMap of
        Nothing -> Left $ "Missing runtime index for region member "
                       ++ show nid
        Just ix -> Right ix

-- | Alias for 'compileRuntimeGraph'. Provided so callers can opt
-- explicitly into the unfused path (today's default behaviour) and
-- be paired with 'compileRuntimeGraphFused' at the call site.
compileRuntimeGraphUnfused :: GraphIR -> Either String RuntimeGraph
compileRuntimeGraphUnfused = compileRuntimeGraph

-- | Compile then run the Step-C single-edge fusion rewrite.
-- Equivalent to @'fuseRuntimeGraph' '<$>' 'compileRuntimeGraph'@.
-- Existing audio loaders use the unfused path; tests and future
-- fused-aware loaders call this entry point explicitly.
compileRuntimeGraphFused :: GraphIR -> Either String RuntimeGraph
compileRuntimeGraphFused = fmap fuseRuntimeGraph . compileRuntimeGraph

{- Note [Region kernel selection]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'formRegions' is greedy on rate compatibility, so a chain like
@SawOsc → LPF → Gain → Out@ lands as a single region (all four
inferred 'SampleRate'). A shape detector for a fused kernel can
therefore not match a whole region; it has to find a contiguous
/subsequence/ inside one.

'selectRegionKernels' walks each region produced by
'compileRuntimeGraph', searches for the leftmost match of any
recognized shape, and on a hit /splits/ the region into up to
three pieces:

  * prefix  ('RNodeLoop')    — nodes before the match (skipped if empty)
  * middle  (matched kernel) — exactly the matched shape, with
                               'kernelArity'-many members
  * suffix  ('RNodeLoop')    — nodes after the match (recursively
                               scanned for further matches)

Match arity is /not/ implicit: 'findKernelMatch' returns a
'KernelMatch' descriptor that carries 'kmLength' = 'kernelArity'
'kmKernel'. Adding a kernel of any arity is a matter of extending
'kernelArity' and the dispatch in 'findKernelMatch' — the
splitter consumes whatever length the descriptor reports.

Currently three kernel shapes are recognized. The sink-terminal
kernels accept either 'KOut' or 'KBusOut' at the terminal slot;
both dispatch to the same per-node kernel ('process_out' on the
C++ side) and read their bus index from @rnControls[0]@, so the
fused kernel body absorbs them identically. See 'isSinkTerminal'.

  * 'RSawLpfGain' — 3-node buffer-terminal:
    @[KSawOsc, KLPF, KGain]@. The gain's output buffer is
    materialized because some external consumer reads it
    (typically a separate sink in the trailing 'RNodeLoop'
    region, or an 'Add' / 'KGain' / 'BusIn' in a downstream
    chain).
  * 'RSinGainOut' — 3-node sink-terminal:
    @[KSinOsc, KGain, /sink/]@ where /sink/ is 'KOut' or
    'KBusOut'. The sink is /inside/ the kernel; bus accumulation
    and §2.E sink-peak tracking happen inside the fused per-
    sample loop. No buffer is materialized.
  * 'RSawLpfGainOut' — 4-node sink-terminal:
    @[KSawOsc, KLPF, KGain, /sink/]@. Combines saw + LPF + gain
    processing with the inline bus accumulation and sink-peak
    tracking; like 'RSinGainOut' it materializes no intermediate
    buffer and accepts either sink kind at the terminal slot.

/Longest-match priority/. At each candidate offset
'findKernelMatch' tries shapes longest-first: for example, on
@[SawOsc, LPF, Gain, Out]@ the 4-node 'RSawLpfGainOut' wins over
the 3-node 'RSawLpfGain' prefix that would otherwise leave the
'Out' stranded in a trailing 'RNodeLoop' region. The 3-node
kernel still fires whenever the longer shape's preconditions
fail — notably when the gain has multiple consumers, or its
single consumer is something other than a sink terminal (e.g. an
'Add' or another 'Gain' on a downstream chain). See the
corresponding @matches*@ predicates and the "fallback" tests in
'Spec.hs'.

The runtime sees a clean "kernel tag per region" model and
dispatches accordingly. RegionIndex is renumbered after the
split so consumers downstream see contiguous indices.

Match preconditions, common to every fused kernel (3-node and
4-node alike):

  1. The contiguous member nodes have the kernel-specific kinds
     in the kernel-specific order, and exactly 'kernelArity'
     members are consumed.
  2. None of the matched members is 'rnElided' (defensive —
     should always hold pre-fusion).
  3. 'rnConsumerCount' is exactly 1 for every /non-terminal/
     member, and each of those single consumers /is/ the next
     node in the chain. This is the "single-use internal edges"
     rule rolled together with "no external escape from the
     intermediate buffers": the chain is the only reader of
     those buffers, so the fused kernel can keep their per-
     sample value in registers without materializing it. For
     buffer-terminal kernels ('RSawLpfGain') the terminal node's
     consumer count is unconstrained — its output /is/
     materialized. For sink-terminal kernels the terminal is a
     sink ('rnConsumerCount == 0' by construction).
  4. The Gain in the chain has scalar shape
     @[RFrom _ _, RConst _]@ — signal port wired from the
     previous member, gain port unwired (constant control).
     Audio-modulated gain stays on 'RNodeLoop' just like §4.C's
     scalar Gain fusion stays off audio-rate Gains.
  5. Where the kernel /absorbs/ the Gain's output (any sink-
     terminal shape, currently 'RSinGainOut' and
     'RSawLpfGainOut'), the Gain itself must additionally have
     'rnConsumerCount == 1' — otherwise an external consumer
     also reads the gain's buffer and the sink-terminal kernel
     must not absorb it. Longest-match falls through to the
     buffer-terminal 'RSawLpfGain' in that case.

For sink-terminal kernels there is no extra precondition on the
terminal sink ('KOut' or 'KBusOut'): it has no audio output, and
its bus index lives in 'rnControls', not 'rnInputs'.

Step-§4.B fusion claims its members /before/ §4.C runs, so
'fuseRuntimeGraph' must skip nodes that are members of a
non-'RNodeLoop' region — otherwise §4.C would elide a Gain that
the region kernel still expects to address by control slot. The
candidate predicate in 'fuseRuntimeGraph' enforces that gate.
-}

-- | §4.B: scan every region for fused-kernel shape matches and
-- split / re-tag accordingly. The selector recurses over the suffix
-- after each match, so a single original 'RNodeLoop' region that
-- contains @N@ independent eligible chains is reduced to its full
-- maximal non-overlapping selection in one compile pass — not @N@
-- accidental re-runs.
--
-- Idempotent: a second pass is a no-op because regions already
-- tagged with a non-'RNodeLoop' kernel are returned unchanged, and
-- any 'RNodeLoop' region produced by an earlier pass is exactly the
-- pre/post slice that already failed to match.
--
-- See Note [Region kernel selection].
selectRegionKernels :: RuntimeGraph -> RuntimeGraph
selectRegionKernels rg =
  let nodeMap :: M.Map NodeIndex RuntimeNode
      nodeMap = M.fromList [(rnIndex n, n) | n <- rgNodes rg]

      -- Drop empty parts; stamp rrIndex with a placeholder
      -- (renumbered after splat) and inherit rrRate from the
      -- enclosing original region.
      placeholder = RegionIndex (-1)
      mkPart rate ks ker
        | null ks   = []
        | otherwise =
            [ RuntimeRegion
                { rrIndex  = placeholder
                , rrRate   = rate
                , rrNodes  = ks
                , rrKernel = ker
                }
            ]

      split :: RuntimeRegion -> [RuntimeRegion]
      split r
        | rrKernel r /= RNodeLoop = [r]
        | otherwise =
            case findKernelMatch nodeMap (rrNodes r) of
              Nothing -> [r]
              Just KernelMatch{ kmOffset = off, kmLength = len, kmKernel = kern } ->
                let members      = rrNodes r
                    (pre, restA) = splitAt off members
                    (mid, post)  = splitAt len restA
                    rate         = rrRate r
                    -- The prefix cannot itself contain an earlier
                    -- match (findKernelMatch returns the leftmost
                    -- offset across all shapes), so it stays
                    -- RNodeLoop without further inspection. The
                    -- suffix may contain another independent chain
                    -- of any recognised shape — recurse on a
                    -- synthetic RNodeLoop region carrying the same
                    -- rate so the selector reaches its own fixed
                    -- point in one pass.
                    postRegion =
                      RuntimeRegion
                        { rrIndex  = placeholder
                        , rrRate   = rate
                        , rrNodes  = post
                        , rrKernel = RNodeLoop
                        }
                in  mkPart rate pre RNodeLoop
                 ++ mkPart rate mid kern
                 ++ (if null post then [] else split postRegion)

      splat = concatMap split (rgRuntimeRegions rg)

      renumbered = zipWith setIx [0..] splat
        where setIx i r = r { rrIndex = RegionIndex i }
  in rg { rgRuntimeRegions = renumbered }

-- | Result of a successful kernel-shape lookup in
-- 'findKernelMatch'. Carrying the matched length explicitly makes
-- the selector independent of any single hardcoded arity (the
-- 3-node-only era) and lets the descriptor grow with new shapes
-- ('RSawLpfGainOut' is the first 4-node entry) without further
-- changes to 'selectRegionKernels'.
data KernelMatch = KernelMatch
  { kmOffset :: !Int            -- ^ Member offset of the match.
  , kmLength :: !Int            -- ^ Number of consumed members; equals 'kernelArity'.
  , kmKernel :: !RegionKernel   -- ^ Tag the matched region carries.
  }
  deriving stock (Eq, Show)

-- | Look for the leftmost match of any recognised kernel shape in
-- a region's member list.
--
-- /Longest-match priority/ at each offset: a 4-node match beats a
-- 3-node match starting at the same position, so a chain
-- @[KSawOsc, KLPF, KGain, KOut]@ is claimed by 'RSawLpfGainOut' as
-- a whole rather than getting its prefix cherry-picked by
-- 'RSawLpfGain'. Without this, the existing 3-node kernel would
-- always win on a 4-node chain (the prefix matches), the
-- terminating 'Out' would land in a trailing 'RNodeLoop' region,
-- and the buffer-vs-sink protocol distinction the kernels are
-- meant to expose would be invisible.
--
-- Shapes are listed longest-first; ties (same length, distinct
-- predicates) fall through in declaration order, but every
-- existing shape is mutually exclusive at the leading-kind level
-- ('KSawOsc' vs 'KSinOsc') so ordering only matters when a future
-- shape collides on prefix.
findKernelMatch
  :: M.Map NodeIndex RuntimeNode
  -> [NodeIndex]
  -> Maybe KernelMatch
findKernelMatch nodes = go 0
  where
    -- Try each candidate at the current offset, longest first; if
    -- none match, advance by one and retry.
    go !i ixs = case (matchHere ixs, ixs) of
      (Just km, _)  -> Just km { kmOffset = i }
      (Nothing, _ : rest) -> go (i + 1) rest
      (Nothing, [])       -> Nothing

    matchHere ixs = case ixs of
      a : b : c : d : _
        | matchesSawLpfGainOut nodes a b c d ->
            Just (mkMatch RSawLpfGainOut)
      _ -> match3 ixs

    match3 ixs = case ixs of
      a : b : c : _
        | matchesSawLpfGain nodes a b c -> Just (mkMatch RSawLpfGain)
        | matchesSinGainOut nodes a b c -> Just (mkMatch RSinGainOut)
      _ -> Nothing

    -- 'kmOffset = -1' is a placeholder; 'go' fills in the real
    -- offset once the match is hoisted to the top level.
    mkMatch k = KernelMatch
      { kmOffset = -1
      , kmLength = kernelArity k
      , kmKernel = k
      }

matchesSawLpfGain
  :: M.Map NodeIndex RuntimeNode
  -> NodeIndex -> NodeIndex -> NodeIndex
  -> Bool
matchesSawLpfGain nodes sawIx lpfIx gainIx =
  case (M.lookup sawIx nodes, M.lookup lpfIx nodes, M.lookup gainIx nodes) of
    (Just saw, Just lpf, Just gain) ->
      rnKind saw == KSawOsc
        && rnKind lpf == KLPF
        && rnKind gain == KGain
        && not (rnElided saw)
        && not (rnElided lpf)
        && not (rnElided gain)
        && rnConsumerCount saw == 1
        && rnConsumerCount lpf == 1
        && signalSourceIs sawIx lpf
        && signalSourceIs lpfIx gain
        && isScalarGain gain
    _ -> False

-- | The sink-terminal shape: KSinOsc → KGain → /sink/ with the same
-- single-use internal-edge / scalar-gain rules as 'matchesSawLpfGain'.
-- The terminal sink can be either 'KOut' or 'KBusOut' — both
-- dispatch to the same per-node kernel ('process_out' on the C++
-- side) and read their bus index from 'rnControls[0]', so the
-- kernel body absorbs them identically. The terminal node has
-- 'rnConsumerCount == 0' by construction (sinks have no
-- downstream readers), so the only constraint on it is that the
-- gain feeds it through port 0.
matchesSinGainOut
  :: M.Map NodeIndex RuntimeNode
  -> NodeIndex -> NodeIndex -> NodeIndex
  -> Bool
matchesSinGainOut nodes sinIx gainIx outIx =
  case (M.lookup sinIx nodes, M.lookup gainIx nodes, M.lookup outIx nodes) of
    (Just sin_, Just gain, Just out_) ->
      rnKind sin_ == KSinOsc
        && rnKind gain == KGain
        && isSinkTerminal (rnKind out_)
        && not (rnElided sin_)
        && not (rnElided gain)
        && not (rnElided out_)
        && rnConsumerCount sin_  == 1
        && rnConsumerCount gain == 1
        && signalSourceIs sinIx gain
        && signalSourceIs gainIx out_
        && isScalarGain gain
    _ -> False

-- | The 4-node sink-terminal shape: KSawOsc → KLPF → KGain → /sink/.
-- Combines the buffer-terminal saw/lpf/gain processing of
-- 'matchesSawLpfGain' with the sink-terminal absorption of
-- 'matchesSinGainOut'. The terminal can be either 'KOut' or
-- 'KBusOut' — same reasoning as 'matchesSinGainOut': both
-- dispatch to 'process_out' on the C++ side and the kernel body
-- absorbs them identically. Adds an explicit
-- @rnConsumerCount gain == 1@ requirement on top of the 3-node
-- buffer-terminal kernel: when that holds, the gain's output
-- buffer is unread by anything outside the chain and the kernel
-- is free to inline the bus accumulation. When it doesn't,
-- longest-match falls through to 'matchesSawLpfGain' (which
-- materializes the gain's buffer for external readers).
matchesSawLpfGainOut
  :: M.Map NodeIndex RuntimeNode
  -> NodeIndex -> NodeIndex -> NodeIndex -> NodeIndex
  -> Bool
matchesSawLpfGainOut nodes sawIx lpfIx gainIx outIx =
  case ( M.lookup sawIx nodes
       , M.lookup lpfIx nodes
       , M.lookup gainIx nodes
       , M.lookup outIx nodes ) of
    (Just saw, Just lpf, Just gain, Just out_) ->
      rnKind saw  == KSawOsc
        && rnKind lpf  == KLPF
        && rnKind gain == KGain
        && isSinkTerminal (rnKind out_)
        && not (rnElided saw)
        && not (rnElided lpf)
        && not (rnElided gain)
        && not (rnElided out_)
        && rnConsumerCount saw  == 1
        && rnConsumerCount lpf  == 1
        && rnConsumerCount gain == 1
        && signalSourceIs sawIx  lpf
        && signalSourceIs lpfIx  gain
        && signalSourceIs gainIx out_
        && isScalarGain gain
    _ -> False

-- | Sink-terminal classifier. Both 'KOut' and 'KBusOut' dispatch to
-- the same per-node kernel ('process_out' on the C++ side) and read
-- their bus index from @rnControls[0]@, so the §4.B sink-terminal
-- kernels accept either as the absorbed terminal. The kernel body
-- is bus-kind-agnostic: the difference between 'KOut' and 'KBusOut'
-- lives at the source level (final hardware output vs intermediate
-- audio bus) and the audio callback routes them identically once
-- they land in the shared bus pool. See @Note [Bus model]@ near the
-- @NodeKind@ enum in @rt_graph.cpp@.
isSinkTerminal :: NodeKind -> Bool
isSinkTerminal KOut    = True
isSinkTerminal KBusOut = True
isSinkTerminal _       = False

-- | Shared between every 'matches*' kernel predicate: the
-- principal audio input of @node@ — port 0 — must be wired to
-- @srcIx@'s principal output port (also port 0). Used to confirm
-- the chain's internal edge is the only producer-side connection
-- to the next member.
--
-- Both port indices are pinned to 0. Today every UGen has a
-- single output port, so wiring through any other source port
-- can't arise from the public DSL; encoding the constraint
-- explicitly hardens the matcher against a future multi-output
-- node that could otherwise sneak through with @RFrom s
-- (PortIndex 1)@ on the same source.
signalSourceIs :: NodeIndex -> RuntimeNode -> Bool
signalSourceIs srcIx node = case rnInputs node of
  RFrom s (PortIndex 0) : _ -> s == srcIx
  _                         -> False

-- | Shared between every 'matches*' kernel predicate that names a
-- gain step: the gain has an audio source on port 0 and a
-- constant control on port 1. Audio-modulated gains (RFrom on
-- port 1) block kernel selection so per-sample arithmetic stays
-- bit-equal to the unfused chain.
isScalarGain :: RuntimeNode -> Bool
isScalarGain node = case rnInputs node of
  [RFrom _ _, RConst _] -> True
  _                     -> False

{- Note [Scalar affine fusion]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The Step-C fusion pass elides scalar 'KGain' and 'KAdd' nodes whose
entire role is to multiply or bias a single-consumer signal by a
control-rate scalar. After fusion, a non-candidate consumer reads
the upstream producer directly through an 'RFused' input that
applies the chain of operations inline.

A node @g@ is a /candidate/ iff all of the following hold:

  1. @rnOutputUse g == RegionLocal@ — its output never escapes the
     region (Step B-Light).
  2. @rnConsumerCount g == 1@ — a single 'FromNode' reader, so
     destructive single-edge rewriting cannot orphan a sibling
     consumer.
  3. @not (rnElided g)@ — not already elided by a prior pass.
  4. The kind-specific shape:

     * 'KGain' with @rnInputs == [RFrom _ _, RConst _]@ — signal on
       port 0, scalar gain on port 1. Audio-modulated gains
       (@[RFrom, RFrom]@) stay dispatched.
     * 'KAdd' with @rnInputs == [RFrom _ _, RConst _]@ — signal on
       port 0, bias from control slot 1.
     * 'KAdd' with @rnInputs == [RConst _, RFrom _ _]@ — bias from
       control slot 0, signal on port 1. Audio-rate Add
       (@[RFrom, RFrom]@) stays dispatched.

Chain extension. The rewrite is driven from /non-candidate/
consumers: for each input @RFrom srcIx _@ whose @srcIx@ is a
candidate, walk upstream through candidates and collect them into a
chain @[Sn, …, S1]@ stopping at the first non-candidate source. The
walked candidates are marked 'rnElided'; the consumer's input
becomes 'RFused' carrying the upstream source and the chain in
source-to-sink order @[S1, …, Sn]@. Each chain element is tagged as
either 'AffScale' (from a Gain) or 'AffBias' (from an Add).

Variant selection. A pure-scale chain (every step is 'AffScale')
emits 'FScaleFrom' (length 1) or 'FScaleChainFrom' (length ≥ 2),
preserving the IR shape that single-edge tests already pin. A chain
that contains at least one 'AffBias' step emits 'FAffineFrom'
regardless of length — including a single elided Add. Mixed Gain /
Add chains in either order compose end-to-end through one
'FAffineFrom' on the eventual non-candidate sink.

Driving the rewrite from non-candidate consumers means a candidate
whose own consumer is /also/ a candidate is never the rewriting
site — the chain is collected once, by the eventual non-candidate
sink. This is how the algorithm avoids both double-fusion and
recursion on already-fused inputs.

Termination. Each candidate's 'rnConsumerCount' is exactly 1, so a
chain has a unique sink. The graph is a DAG, so the upstream walk
cannot loop. The walk terminates at the first non-candidate
'rnIndex' encountered — typically the producer of the original
signal (e.g., a 'KSinOsc'), but it can also be an audio-modulated
Gain or audio-rate Add whose shape gate excludes it.

Identity preservation. Every elided node remains in 'rgNodes' with
'rnElided = True', preserving its 'NodeIndex'. Direct
'rt_graph_instance_set_control' / realtime control writes to the
elided node continue to land on @inst.nodes[node].controls[slot]@;
the runtime reads each scale or bias live at fused-input evaluation
time, exactly as the kernel's controls-fallback branch does. No
control-addressable identity disappears, including for nodes in
the middle of a chain.

Float-rounding identity. The fused resolver applies steps in
source-to-sink order, casting each control to 'float' before the
operation, mirroring chained 'process_gain' / 'process_add' kernels
exactly. Scales are /not/ pre-multiplied and biases are /not/
pre-summed (float arithmetic is non-associative), so chained-fused
output is bit-identical to chained-unfused output.

Counter-state. 'rnConsumerCount' and 'rnOutputUse' are not
recomputed by the rewrite. They reflect the post-compile state,
not the post-fusion state. A future fusion pass that needs updated
counts must rebuild them.
-}

-- | Step C: scalar Gain / Add fusion with chain extension. Walks
-- 'rgNodes', identifies candidate Gains and Adds, and for each
-- non-candidate consumer rewrites @RFrom srcIx _@ inputs into
-- 'RFused' values that absorb the upstream candidate chain. All
-- candidates in a fused chain are marked elided; their 'NodeIndex'
-- and controls remain addressable.
--
-- Idempotent: a second call is a no-op because previously-elided
-- nodes fail the candidate predicate ('rnElided' check) and the
-- consumer inputs already carry 'RFused' values that the rewrite
-- ignores.
--
-- See Note [Scalar affine fusion].
fuseRuntimeGraph :: RuntimeGraph -> RuntimeGraph
fuseRuntimeGraph rg =
  let nodes = rgNodes rg

      -- §4.B: nodes that are members of a non-'RNodeLoop' region
      -- have been claimed by a fused region kernel and must be
      -- left alone here. Eliding them via §4.C would invalidate
      -- the region kernel's per-sample loop (it expects the saw,
      -- lpf, and gain nodes to all stay live and addressable).
      regionFused :: S.Set NodeIndex
      regionFused = S.fromList
        [ ix
        | r  <- rgRuntimeRegions rg
        , rrKernel r /= RNodeLoop
        , ix <- rrNodes r
        ]

      -- For a candidate node, classify its incoming signal port and
      -- the affine step it contributes. Returns 'Nothing' for any
      -- node that doesn't match a candidate shape (including
      -- audio-modulated Gain, audio-rate Add, and non-Gain non-Add
      -- nodes). Pulled out of the candidate predicate so the chain
      -- walker can reuse the same dispatch.
      candidateView
        :: RuntimeNode
        -> Maybe (NodeIndex, PortIndex, AffineStep)
      candidateView n
        | rnElided n                      = Nothing
        | rnOutputUse n /= RegionLocal    = Nothing
        | rnConsumerCount n /= 1          = Nothing
        | rnIndex n `S.member` regionFused = Nothing
        | otherwise = case (rnKind n, rnInputs n) of
            (KGain, [RFrom s p, RConst _]) ->
              Just (s, p, AffScale (rnIndex n) (ControlIndex 0))
            (KAdd,  [RFrom s p, RConst _]) ->
              Just (s, p, AffBias  (rnIndex n) (ControlIndex 1))
            (KAdd,  [RConst _, RFrom s p]) ->
              Just (s, p, AffBias  (rnIndex n) (ControlIndex 0))
            _ -> Nothing

      candById :: M.Map NodeIndex (NodeIndex, PortIndex, AffineStep)
      candById = M.fromList
        [ (rnIndex n, view)
        | n <- nodes
        , Just view <- [candidateView n]
        ]

      -- Walk upstream from a candidate node. Returns:
      --   * terminal source node + port (the first non-candidate
      --     producer reached)
      --   * the list of elided node indices (chain members, any
      --     order — only used as a set)
      --   * the chain of AffineStep in source-to-sink order
      --     (first element is the upstream-most candidate)
      walkChain
        :: NodeIndex
        -> (NodeIndex, PortIndex, [NodeIndex], [AffineStep])
      walkChain ix =
        let (src, srcPort, here) = candById M.! ix  -- safe: caller checked
        in case M.lookup src candById of
             Nothing ->
               -- Source is non-candidate: chain ends here.
               (src, srcPort, [ix], [here])
             Just _  ->
               -- Source is itself a candidate: extend upstream and
               -- append the local step so source-to-sink order is
               -- preserved (upstream comes first).
               let (term, termPort, elided, stepsUp) = walkChain src
               in (term, termPort, ix : elided, stepsUp ++ [here])

      -- Try to fuse a single consumer-side input. Returns the
      -- (possibly rewritten) input plus any node indices that
      -- should be marked elided as a result.
      tryFuseInput :: RuntimeInput -> (RuntimeInput, [NodeIndex])
      tryFuseInput inp = case inp of
        RFrom srcIx _port
          | M.member srcIx candById ->
              let (src, srcPort, elidedIxs, steps) = walkChain srcIx
                  -- Pure-scale chains stay on the existing
                  -- FScaleFrom / FScaleChainFrom variants so
                  -- single-edge / pure-chain tests pin the older
                  -- shape unchanged. Anything with a bias step
                  -- (single Add, pure-bias chain, mixed) goes
                  -- into FAffineFrom.
                  fused = case asScalesOnly steps of
                    Just [ScaleRef g0 c0] ->
                      FScaleFrom src srcPort g0 c0
                    Just sr@(_:_:_) ->
                      FScaleChainFrom src srcPort sr
                    _ ->
                      FAffineFrom src srcPort steps
              in (RFused fused, elidedIxs)
        _ -> (inp, [])

      -- If every step is an AffScale, return them as ScaleRefs;
      -- otherwise Nothing.
      asScalesOnly :: [AffineStep] -> Maybe [ScaleRef]
      asScalesOnly = traverse stepToScale
        where
          stepToScale (AffScale n c) = Just (ScaleRef n c)
          stepToScale (AffBias  _ _) = Nothing

      -- Process one node. Candidates are left alone here — they
      -- become elided once a downstream non-candidate consumer
      -- walks them. Non-candidates have each input considered for
      -- chain fusion.
      processNode n
        | M.member (rnIndex n) candById = (n, [])
        | otherwise =
            let pairs   = map tryFuseInput (rnInputs n)
                inputs' = map fst pairs
                elided  = concatMap snd pairs
            in (n { rnInputs = inputs' }, elided)

      processed = map processNode nodes
      newNodes  = map fst processed
      elidedSet = S.fromList (concatMap snd processed)

      finalize n
        | rnIndex n `S.member` elidedSet = n { rnElided = True }
        | otherwise                      = n
  in rg { rgNodes = map finalize newNodes }
