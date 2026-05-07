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
  , RuntimeNode (..)
  , RuntimeRegion (..)
  , RuntimeGraph (..)
  , RegionIndex (..)
  , NodeOutputUse (..)
  , -- * Compilation
    compileRuntimeGraph
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

Currently, dense lowering operates at node granularity: each
NodeIR becomes one RuntimeNode. When kernel fusion is
implemented, the granularity will change — a fused region will
become a single runtime unit, and the NodeIndex space will
index regions (or fused kernels) rather than individual nodes.
The runtime should not need to know whether a unit arose from
one primitive, a fused chain, a vector loop, or a cached shared
region. The current node-level lowering is a special case of
this principle where every region contains exactly one node.

See Note [Dense runtime representation] for the types involved.
-}

{- Note [Dense runtime representation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
RuntimeInput, RuntimeNode, and RuntimeGraph are the final
Haskell-side representation before the FFI boundary.

A RuntimeNode carries:

  rnIndex      — dense position in the array; execution order
                 equals storage order equals this index
  rnOriginalID — the symbolic NodeID from which this node was
                 compiled; retained only for diagnostics, never
                 used by the runtime
  rnKind       — dispatches to the correct C++ process function
  rnInputs     — dense input references; each RFrom points to
                 a node earlier in the array (guaranteed by
                 topological ordering)
  rnControls   — default control values, sent to C++ at load time

A RuntimeInput is either:

  RFrom NodeIndex PortIndex — read from the dense array
  RConst Double             — compile-time constant (was a
                              Literal in the IR)

After fusion, a RuntimeNode (or its successor type) may
correspond to an entire fused region rather than a single
source node. The runtime does not distinguish the two cases.
-}

-- | A runtime input reference: either a dense index into the
-- node array, or a compile-time constant.
--
-- See Note [Dense runtime representation].
data RuntimeInput
  = RFrom  !NodeIndex !PortIndex
    -- ^ Read from node at this dense index, this port.
  | RConst !Double
    -- ^ Compile-time constant (was a 'Literal' in the IR).
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
    -- ^ Number of direct 'FromNode' consumers across 'rgNodes'.
    -- 'RegionLocal' is a *gate* for fusion (no cross-region
    -- escape), not a *license* — destructive single-edge fusion
    -- additionally needs to know there is exactly one consumer.
    -- Step C's first-pass predicate is therefore
    --
    -- > rnOutputUse == RegionLocal && rnConsumerCount == 1
    --
    -- Fan-out cases ('rnConsumerCount > 1') stay correct as
    -- 'RegionLocal' but are ineligible for narrow single-edge
    -- rewriting; whole-region fusion can pick them up later.
    -- See Note [Output-use classification].
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

-- | One execution region in the runtime graph: a contiguous block
-- of nodes (in execution order) that 'formRegions' grouped together.
--
-- See Note [Runtime regions overlay].
data RuntimeRegion = RuntimeRegion
  { rrIndex :: !RegionIndex
    -- ^ Dense position of this region in 'rgRuntimeRegions'.
  , rrRate  :: !Rate
    -- ^ Region execution rate (the join of member rates; see
    -- Note [Region rate compatibility]).
  , rrNodes :: ![NodeIndex]
    -- ^ Member nodes in execution order. Currently always contiguous
    -- (greedy 'formRegions' invariant), but the type does not encode
    -- that.
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

  pure $! RuntimeGraph rtNodes rtRegions

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
        { rrIndex = RegionIndex i
        , rrRate  = regRate region
        , rrNodes = members
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
