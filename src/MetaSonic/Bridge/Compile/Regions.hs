{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- |
-- Module      : MetaSonic.Bridge.Compile.Regions
-- Description : IR-level region formation
--
-- Compile-time region machinery: 'RegionID', 'Region', 'RegionGraph',
-- and the greedy 'formRegions' pass that groups a toposorted list of
-- 'NodeIR' into rate-compatible execution regions.
--
-- These types are the /compile-time/ region surface — distinct from
-- 'RuntimeRegion' / 'RuntimeGraph' (the runtime-facing dense overlay)
-- which live in 'MetaSonic.Bridge.Compile.Types'. The runtime overlay
-- is built from this graph via 'compileRegion' in
-- 'MetaSonic.Bridge.Compile'.
--
-- Re-exported by 'MetaSonic.Bridge.Compile' for the public surface.
module MetaSonic.Bridge.Compile.Regions
  ( RegionID (..)
  , Region (..)
  , RegionGraph (..)
  , compatibleRate
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

The current implementation satisfies (1) and partially (2). It is a
greedy linear scan: walk the toposorted IR and extend the current
region as long as the next node has the same rate and all its
dependencies are either inside the current region or in already-
completed regions. When any condition breaks, the region is closed and
a new one begins.

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
neighboring 'SampleRate' region (or starts its own pure-constant
region if there is no faster neighbor); the same 'Gain' fed by a
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
