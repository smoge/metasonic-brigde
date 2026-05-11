-- |
-- Module      : MetaSonic.Bridge.Compile.Dependencies
-- Description : Per-region bus footprints + region dependency views
--               + the §4.E.1c live-bus barrier predicate.
--
-- §4.E.1 / §4.E.1b / §4.E.1c metadata. Provides:
--
--   * 'runtimeNodeFootprint' — the kind+control-derived footprint of
--     one node.
--   * 'regionFootprint' / 'attachRegionFootprints' — the aggregated
--     footprint per region; the latter decorates an existing
--     'RuntimeGraph' produced by 'selectRegionKernels'.
--   * 'inputSourceIndex' / 'fusedInputSource' — uniform source-of-
--     input projections covering 'RFrom' and the three 'FusedInput'
--     shapes.
--   * 'regionBusPrecedence' — bus-only edge subgraph (diagnostics).
--   * 'regionResourcePrecedence' — bus + buffer union (§6.C.4).
--   * 'regionStructuralPrecedence' — cross-region port-edge subgraph.
  --   * 'regionDependencies' — the union view consumed by scheduler
  --     planning and metadata generation.
--   * 'isLiveBusKind' / 'regionHasLiveBus' — barrier predicate
--     under the §4.E.1c policy.
--
-- See Note [Region dependency contract] and Note [Region barrier policy]
-- below for the contracts these views encode.
--
-- Re-exported by 'MetaSonic.Bridge.Compile' for the public surface.
module MetaSonic.Bridge.Compile.Dependencies
  ( -- * Footprints
    runtimeNodeFootprint
  , regionFootprint
  , runtimeNodeResourceFootprint
  , regionResourceFootprint
  , attachRegionFootprints
    -- * Source-of-input projections
  , inputSourceIndex
  , fusedInputSource
    -- * Dependency views
  , regionBusPrecedence
  , regionResourcePrecedence
  , regionStructuralPrecedence
  , regionDependencies
    -- * Barrier predicate (§4.E.1c)
  , isLiveBusKind
  , regionHasLiveBus
  ) where

import qualified Data.Map.Strict as M
import qualified Data.Set        as S

import           MetaSonic.Bridge.Compile.Types
import           MetaSonic.Types

-- | Bus footprint of one runtime node, derived from its kind plus the
-- bus index in 'rnControls[0]'. Returns 'emptyFootprint' for non-bus
-- kinds. Negative, NaN, or infinite bus indices are silently dropped
-- (they correspond to the runtime's silence-on- invalid-bus contract
-- — a phantom dependency on bus -1 would be noise in the precedence
-- view, not signal).
runtimeNodeFootprint :: RuntimeNode -> BusFootprint
runtimeNodeFootprint n = case (rnKind n, rnControls n) of
  (KOut,          v : _) | Just b <- finitePositive v ->
    emptyFootprint { bfWrites       = S.singleton b }
  (KBusOut,       v : _) | Just b <- finitePositive v ->
    emptyFootprint { bfWrites       = S.singleton b }
  (KBusIn,        v : _) | Just b <- finitePositive v ->
    emptyFootprint { bfReads        = S.singleton b }
  (KBusInDelayed, v : _) | Just b <- finitePositive v ->
    emptyFootprint { bfDelayedReads = S.singleton b }
  _ -> emptyFootprint
  where
    finitePositive :: Double -> Maybe Int
    finitePositive v
      | isNaN v || isInfinite v || v < 0 = Nothing
      | otherwise                         = Just (truncate v)

-- | Aggregate the 'BusFootprint' of every node in a region's
-- member list. The set-union semantics of 'BusFootprint' make the
-- fold order-independent.
regionFootprint
  :: M.Map NodeIndex RuntimeNode
  -> [NodeIndex]
  -> BusFootprint
regionFootprint nodes = foldr step emptyFootprint
  where
    step ix acc = case M.lookup ix nodes of
      Nothing -> acc
      Just n  -> mergeBusFootprint (runtimeNodeFootprint n) acc

-- | Set-union of two 'BusFootprint's. Used by 'regionFootprint'
-- and (via composition) by 'regionResourceFootprint'.
mergeBusFootprint :: BusFootprint -> BusFootprint -> BusFootprint
mergeBusFootprint a b = BusFootprint
  { bfWrites       = bfWrites       a `S.union` bfWrites       b
  , bfReads        = bfReads        a `S.union` bfReads        b
  , bfDelayedReads = bfDelayedReads a `S.union` bfDelayedReads b
  }

-- | §6.C.4: resource footprint of one runtime node — the bus
-- footprint from 'runtimeNodeFootprint' plus a buffer footprint
-- derived from the kind + 'rnControls[0]' (the buffer ID slot,
-- where applicable). 'KPlayBufMono' contributes a 'BufRead' on
-- its buffer id; 'KRecordBufMono' contributes a 'BufWrite'.
runtimeNodeResourceFootprint :: RuntimeNode -> ResourceFootprint
runtimeNodeResourceFootprint n =
  ResourceFootprint
    { rfBuses   = runtimeNodeFootprint n
    , rfBuffers = case (rnKind n, rnControls n) of
        (KPlayBufMono,   v : _) | Just b <- finiteBufferId v ->
          emptyBufferFootprint { bfBufReads  = S.singleton b }
        (KRecordBufMono, v : _) | Just b <- finiteBufferId v ->
          emptyBufferFootprint { bfBufWrites = S.singleton b }
        _ -> emptyBufferFootprint
    }
  where
    finiteBufferId :: Double -> Maybe Int
    finiteBufferId v
      | isNaN v || isInfinite v || v < 0 = Nothing
      | otherwise                         = Just (truncate v)

-- | §6.C.4: aggregate 'ResourceFootprint' over a region's member
-- list. Bus half matches 'regionFootprint' exactly; buffer half
-- unions the per-node 'rfBuffers'.
regionResourceFootprint
  :: M.Map NodeIndex RuntimeNode
  -> [NodeIndex]
  -> ResourceFootprint
regionResourceFootprint nodes = foldr step emptyResourceFootprint
  where
    step ix acc = case M.lookup ix nodes of
      Nothing -> acc
      Just n  -> mergeResource (runtimeNodeResourceFootprint n) acc
    mergeResource a b = ResourceFootprint
      { rfBuses   = mergeFootprint (rfBuses a) (rfBuses b)
      , rfBuffers = mergeBuf       (rfBuffers a) (rfBuffers b)
      }
    mergeBuf a b = BufferFootprint
      { bfBufWrites       = bfBufWrites       a `S.union` bfBufWrites       b
      , bfBufReads        = bfBufReads        a `S.union` bfBufReads        b
      , bfBufDelayedReads = bfBufDelayedReads a `S.union` bfBufDelayedReads b
      }

    mergeFootprint a b = BusFootprint
      { bfWrites       = bfWrites       a `S.union` bfWrites       b
      , bfReads        = bfReads        a `S.union` bfReads        b
      , bfDelayedReads = bfDelayedReads a `S.union` bfDelayedReads b
      }

-- | Decorate every region in a 'RuntimeGraph' with its
-- 'BusFootprint'. Run as the final step of 'compileRuntimeGraph' so
-- the footprints reflect the post-'selectRegionKernels' member lists;
-- running earlier would leave stale aggregations on regions that
-- 'selectRegionKernels' subsequently split.
attachRegionFootprints :: RuntimeGraph -> RuntimeGraph
attachRegionFootprints rg =
  let nodeMap = M.fromList [(rnIndex n, n) | n <- rgNodes rg]
      decorated =
        [ r { rrFootprint = regionResourceFootprint nodeMap (rrNodes r) }
        | r <- rgRuntimeRegions rg
        ]
  in rg { rgRuntimeRegions = decorated }

{- Note [Region dependency contract]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The scheduler planner (§4.E.2 onwards) needs the /full/ region
dependency graph: which regions must execute before which others.

That graph has two independent edge sources:

  * Resource dataflow ('regionResourcePrecedence', §6.C.4): A
    precedes B iff A's resource writes intersect B's resource
    live-reads, on EITHER buses or buffers. Bus and buffer ids
    live in disjoint namespaces, so the two intersections are
    checked separately. Delayed reads do not contribute,
    matching the intra-graph E_r rule and the inter-template
    precedence rule. ('regionBusPrecedence' is the bus-only
    sibling — kept for diagnostics that want to see the bus
    subgraph alone.)

  * Structural cross-region ports ('regionStructuralPrecedence'):
    A precedes B iff some node in B has a 'RuntimeInput' whose
    source ('RFrom' or the 'fiSourceNode' / 'fcSourceNode' /
    'faSourceNode' field of 'RFused') lives in A. This is the
    edge class kernel-splitting introduces — e.g.
    @saw → lpf → gain → add → out@ splits into an 'RSawLpfGain'
    region plus a trailing 'RNodeLoop' region containing
    @[Add, Out]@. The trailing region reads the gain's
    materialized output buffer (a port edge), but no bus is
    involved, so 'regionResourcePrecedence' would say there is
    no edge. Treating resource precedence alone as the dependency graph
    would let a parallel scheduler run the two regions
    concurrently, which is wrong.

'regionDependencies' is the @M.unionWith S.union@ of the two views.
Use it for any "what must run before this region" question; the
narrower views are exposed only for diagnostics and testability.

The dual naming is deliberate. The bus view answers a question ('how
does this region depend on the bus pool?') that has its own diagnostic
value. Hiding it behind the combined view would make it harder to
answer "is this dependency a bus dependency or a port dependency?"
when debugging schedules.

Static-vs-dynamic bus controls — resolved by §4.E.1c.
'BusFootprint' is built from each node's compile-time
'rnControls[0]'. 'rt_graph_instance_set_control' can change a
'KBusIn' / 'KOut' / 'KBusOut' bus index at runtime, so the
static dependency graph stops being valid once a bus index is
redirected.

§4.E.1c picks the barrier-path policy: regions containing any
live-bus node ('KBusIn' / 'KOut' / 'KBusOut') are barriers and
must execute in compile-decreed order, regardless of what
'regionDependencies' would otherwise allow. Non-barrier regions
are scheduled freely subject to 'regionDependencies', with
'rrIndex' order as the tie-breaker. See Note [Region barrier
policy] for the predicate ('regionHasLiveBus'), the rationale,
and the alternatives that were rejected.

This means 'regionDependencies' is the /correctness/ contract
for non-barrier regions. The scheduler combines it with
'regionHasLiveBus' to decide what can move; nothing about
'regionDependencies' itself depends on the policy.
-}

-- | Source 'NodeIndex' of a 'RuntimeInput', if any.
-- 'RConst' has no source; 'RFrom' carries it directly; 'RFused'
-- carries it inside the 'FusedInput' constructor. Used by the
-- structural-precedence view to walk cross-region port edges.
inputSourceIndex :: RuntimeInput -> Maybe NodeIndex
inputSourceIndex (RConst _)    = Nothing
inputSourceIndex (RFrom ix _)  = Just ix
inputSourceIndex (RFused fi)   = Just (fusedInputSource fi)

-- | The non-elided producer 'NodeIndex' that ultimately feeds a
-- 'FusedInput'. The dispatching field name differs across
-- constructors — keep this helper in sync with 'FusedInput'.
fusedInputSource :: FusedInput -> NodeIndex
fusedInputSource FScaleFrom{ fiSourceNode = ix }      = ix
fusedInputSource FScaleChainFrom{ fcSourceNode = ix } = ix
fusedInputSource FAffineFrom{ faSourceNode = ix }     = ix

-- | Bus-dataflow region precedence: for each region, the set of
-- regions whose live writes the given region reads via a 'KBusIn'. A
-- precedes B iff @bfWrites(A) ∩ bfReads(B) ≠ ∅@. Delayed reads do not
-- contribute, matching the intra-graph E_r rule and the
-- inter-template precedence rule.
--
-- This is /not/ the full region dependency graph — see
-- 'regionDependencies' and Note [Region dependency contract]. Use
-- this only when you specifically want the bus-edge subgraph for
-- diagnostics; otherwise 'regionDependencies' is the right starting
-- point for any "must precede" question.
regionBusPrecedence :: RuntimeGraph -> M.Map RegionIndex (S.Set RegionIndex)
regionBusPrecedence rg = M.fromList
  [ (rrIndex r, S.fromList
      [ rrIndex other
      | other <- regions
      , rrIndex other /= rrIndex r
        -- Bus-only edges: the name says so and a few diagnostic
        -- tests rely on that. The bus + buffer union lives in
        -- 'regionResourcePrecedence' below; 'regionDependencies'
        -- consumes that one to get full edge coverage.
      , not (S.null
              (bfWrites (rfBuses (rrFootprint other))
                `S.intersection`
               bfReads  (rfBuses (rrFootprint r))))
      ])
  | r <- regions
  ]
  where
    regions = rgRuntimeRegions rg

-- | Structural cross-region precedence: for each region, the set of
-- regions that produce a 'NodeIndex' that this region's nodes read
-- through a 'RuntimeInput'. Captures the port-edge dependencies that
-- 'selectRegionKernels' splits introduce when a kernel-claimed
-- prefix's terminal output is consumed by a node in the trailing
-- 'RNodeLoop' region (the canonical example being @saw → lpf → gain →
-- add → out@: the trailing @[Add, Out]@ region reads the materialized
-- gain output of the @[Saw, LPF, Gain]@ region — no bus involved).
--
-- Self-loops are filtered out (a node-input that points to a node in
-- the same region is intra-region, not a precedence edge). Every
-- region appears in the result, even if its dependency set is empty,
-- so consumers can iterate keys without 'M.findWithDefault' churn.
regionStructuralPrecedence
  :: RuntimeGraph -> M.Map RegionIndex (S.Set RegionIndex)
regionStructuralPrecedence rg =
  let regions      = rgRuntimeRegions rg
      regionOfNode = M.fromList
        [ (ix, rrIndex r)
        | r  <- regions
        , ix <- rrNodes r
        ]
      nodeMap = M.fromList [(rnIndex n, n) | n <- rgNodes rg]

      -- For one consumer region, the set of producer regions it
      -- structurally depends on. Walk every member node's inputs;
      -- resolve each input's source 'NodeIndex' to its region;
      -- discard edges that stay inside the same region.
      depsFor consumer = S.fromList
        [ producerIx
        | consumerIx <- rrNodes consumer
        , Just node  <- [M.lookup consumerIx nodeMap]
        , inp        <- rnInputs node
        , Just src   <- [inputSourceIndex inp]
        , Just producerIx <- [M.lookup src regionOfNode]
        , producerIx /= rrIndex consumer
        ]
  in M.fromList [(rrIndex r, depsFor r) | r <- regions]

-- | §6.C.4: bus + buffer resource precedence at the region scope.
-- A precedes B iff A writes some resource (bus or buffer) that B
-- reads live. Bus and buffer ids live in disjoint namespaces, so
-- the two intersections are checked separately and never collide.
--
-- The bus-only sibling 'regionBusPrecedence' is kept for
-- diagnostic callers that want to see the bus-edge subgraph alone;
-- 'regionDependencies' goes through this function so the full
-- "must precede" view picks up writer kinds as soon as one
-- lands (today: zero writer kinds, so the buffer half is empty
-- on every corpus).
regionResourcePrecedence :: RuntimeGraph -> M.Map RegionIndex (S.Set RegionIndex)
regionResourcePrecedence rg = M.fromList
  [ (rrIndex r, S.fromList
      [ rrIndex other
      | other <- regions
      , rrIndex other /= rrIndex r
      , let aFP = rrFootprint other
            bFP = rrFootprint r
      , not (S.null
              (bfWrites (rfBuses aFP) `S.intersection`
               bfReads  (rfBuses bFP)))
        || not (S.null
              (bfBufWrites (rfBuffers aFP) `S.intersection`
               bfBufReads  (rfBuffers bFP)))
      ])
  | r <- regions
  ]
  where
    regions = rgRuntimeRegions rg

-- | Full region dependency graph: the union of resource-dataflow
-- (bus + buffer) and structural-port edges. This is the view the
-- scheduler planner (§4.E.2) consumes for any "must precede"
-- decision. See Note [Region dependency contract] for why both
-- edge classes matter, and Note [Region barrier policy] for how
-- a scheduler combines this with 'regionHasLiveBus' to handle
-- dynamic bus controls safely.
regionDependencies :: RuntimeGraph -> M.Map RegionIndex (S.Set RegionIndex)
regionDependencies rg =
  M.unionWith S.union
    (regionResourcePrecedence rg)
    (regionStructuralPrecedence rg)

{- Note [Region barrier policy]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The §4.E.1b dependency-contract note flagged that 'BusFootprint' is
built from compile-time 'rnControls[0]' and that
'rt_graph_instance_set_control' can change a 'KBusIn' / 'KOut' /
'KBusOut' bus index at runtime. The static dependency graph is
therefore only valid for as long as bus controls hold their
compile-time values.

§4.E.1c decision: dynamic-bus regions are /barriers/.

A region is a barrier iff 'regionHasLiveBus' holds — i.e. it contains
at least one 'KBusIn', 'KOut', or 'KBusOut' node. 'KBusInDelayed' is
excluded for the same reason it's excluded from precedence: the read
is deterministic across blocks regardless of where it sits in the
schedule, so a delayed-read node neither constrains nor depends on
intra-block ordering.

The scheduler contract (consumed by §4.E.2 onwards):

  1. Barrier regions execute in their compile-decreed order ('rrIndex'
     order). They are not reordered, not parallelized across thread
     boundaries, and not merged with other regions. A bus-redirect on
     any node inside them changes where the live signal flows but
     cannot move the region itself.

  2. Non-barrier regions are scheduled freely subject to
     'regionDependencies', with stable 'rrIndex' order as the
     tie-breaker.

  3. Bit-equivalence with the current single-thread executor must hold
     under any schedule the policy permits; the scheduler is the one
     component that has to prove this.

Why not the other two policy options:

  * Static bus controls (reject set_control on bus slots) would break
    existing tests that intentionally cover live bus-index redirects,
    including the §4.B 'set_control on RBusInLpfGainOut covers
    busin.bus + …' coverage test. That's a real behavior surface, not
    an artifact.

  * Scheduler rebuild on bus-control changes is operationally much
    larger than it sounds — per-instance redirects would require
    recomputing the dependency graph on the audio thread before the
    next block, with all the realtime-safety constraints that implies.
    Defer until there's evidence the cheaper barrier-path policy isn't
    enough.

Static-bus annotations (an opt-in API marking specific bus controls as
immutable) are a viable later relaxation: regions whose every bus
index is annotated static lose their barrier status and become freely
schedulable. Add when measured parallelism gain justifies the API
surface.
-}

-- | Whether a 'NodeKind' represents a /live-bus/ node — one whose
-- bus-index control ('rnControls[0]') can be redirected at runtime
-- via 'rt_graph_instance_set_control', and whose bus access
-- participates in same-block ordering. 'KBusIn' / 'KOut' / 'KBusOut'
-- qualify; 'KBusInDelayed' does not (its read is from the previous
-- block's snapshot, deterministic regardless of intra-block
-- scheduling order — see 'process_busin_delayed' in @rt_graph.cpp@).
isLiveBusKind :: NodeKind -> Bool
isLiveBusKind KBusIn  = True
isLiveBusKind KOut    = True
isLiveBusKind KBusOut = True
isLiveBusKind _       = False

-- | Whether a region contains any live-bus node. Under the §4.E.1c
-- scheduler policy (see Note [Region barrier policy]) this is the
-- predicate identifying /barrier regions/ that must execute in
-- compile-decreed order regardless of what 'regionDependencies' would
-- otherwise allow.
--
-- Defined on kinds (not on 'rrFootprint') so an invalid bus index in
-- 'rnControls[0]' — silently excluded from the footprint by
-- 'runtimeNodeFootprint's sanitization — still marks its region as a
-- barrier. The point of the predicate is that the node's bus control
-- /could/ be redirected at runtime, whether or not the current value
-- is sane.
regionHasLiveBus :: RuntimeGraph -> RuntimeRegion -> Bool
regionHasLiveBus rg r =
  let nodeMap = M.fromList [(rnIndex n, n) | n <- rgNodes rg]
      memberIsLiveBus ix = case M.lookup ix nodeMap of
        Just n  -> isLiveBusKind (rnKind n)
        Nothing -> False
  in any memberIsLiveBus (rrNodes r)
