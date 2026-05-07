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
  , RuntimeGraph (..)
  , -- * Compilation
    compileRuntimeGraph
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
A node can extend the current region only if its rate matches
the region's rate. This is condition (1) from the region
formation criteria:

  "All members share a compatible rate and staging regime"

Currently "compatible" means "equal". A future relaxation could
allow CompileRate nodes into any region (since their value is
known statically), or allow BlockRate nodes into SampleRate
regions with automatic sample-and-hold at the region boundary.

Rate assignment itself affects region formation: if inferRate
in MetaSonic.IR unconditionally marks Gain as SampleRate, a
Gain fed by two BlockRate inputs can never be placed in a
block-rate region, even when that would be correct and more
efficient.

See Note [Rate inference vs rate propagation] in MetaSonic.IR.
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
              nRate == curRate
              && all (\d -> M.member d owner || S.member d curNodes)
                     (S.toList nDeps)

      in if canExtend
         then
           -- Extend the current open region with this node.
           case openRegion of
             Just (rid, _curRate, curEffs, members, curDeps) ->
               let !newOwner    = M.insert nid rid owner
                   !newCurNodes = S.insert nid curNodes
               in go nextID acc newOwner newCurNodes
                    (Just ( rid
                          , nRate
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
  RConst Float              — compile-time constant (was a
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
  | RConst !Float
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
  , rnControls   :: ![Float]
    -- ^ Default control values, sent to C++ at load time.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | The fully compiled runtime graph: a list of dense nodes
-- ready to be transferred across the FFI boundary.
--
-- See Note [Dense lowering].
data RuntimeGraph = RuntimeGraph
  { rgNodes :: ![RuntimeNode]
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

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

  rtNodes <- mapM (compileNode indexMap) (zip [0..] irNodes)
  pure $! RuntimeGraph rtNodes

  where
    compileNode
      :: M.Map NodeID NodeIndex
      -> (Int, NodeIR)
      -> Either String RuntimeNode
    compileNode indexMap (i, node) = do
      inputs <- mapM (compileInput indexMap) (irInputs node)
      pure $! RuntimeNode
        { rnIndex      = NodeIndex i
        , rnOriginalID = irNodeID node
        , rnKind       = irKind node
        , rnInputs     = inputs
        , rnControls   = irControls node
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
