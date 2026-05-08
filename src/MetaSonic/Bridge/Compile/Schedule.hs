{-# LANGUAGE DerivingStrategies #-}
-- |
-- Module      : MetaSonic.Bridge.Compile.Schedule
-- Description : §4.E.2a — pure single-thread region scheduler
--               planner. Produces the deterministic execution
--               order a future scheduler should consume.
--
-- This is the planner only; no runtime changes. The C++ executor
-- still walks 'rgRuntimeRegions' in 'rrIndex' order. The function
-- exists as the explicit contract between 'compileRuntimeGraph'
-- and the eventual scheduler ('regionSchedule' encodes the
-- correctness rules a future parallel scheduler must respect):
--
--   1. Live-bus regions are barriers ('regionHasLiveBus' = True).
--      They occupy their compile-decreed 'rrIndex' positions and
--      are never reordered, merged, or parallelized away.
--   2. Non-barrier regions are partitioned into maximal runs
--      between consecutive barriers. Within each run, regions
--      are topologically sorted using 'regionDependencies' with
--      'rrIndex' as the stable tie-breaker.
--   3. The output is the concatenation in barrier-position
--      order: pre-barrier free segment, barrier 1, segment
--      between 1 and 2, barrier 2, …, final free segment.
--
-- Today's output is the identity over 'rrIndex' order because
-- 'compileRuntimeGraph' already produces a topologically valid
-- 'rrIndex' sequence. The function still exists with explicit
-- barrier-and-topo-sort logic so a future change that breaks
-- that invariant is caught here, not in the scheduler.
--
-- Bit-equivalence with the current executor follows from the
-- identity property; the scheduler-side bit-equivalence test
-- (when §4.E.2b lands) will catch any future divergence.
--
-- The planner is /checked/: it rejects ('Left') any of —
--
--   * 'rgRuntimeRegions' that is not dense-ascending by 'rrIndex'
--     from 0 (this is the contract; both 'segmentByBarrier' and
--     'topoSortStable' walk the list in /list/ order and use
--     'rrIndex' as the stable tie-breaker, so the two only agree
--     when the list /is/ already 'rrIndex' order),
--   * cycles in 'regionDependencies' inside a free segment, and
--   * cross-segment edges that point to a not-yet-scheduled
--     region.
--
-- This is the whole point of having a planner before §4.E.2b —
-- silent fallback would let the runtime start trusting a broken
-- contract.
--
-- See Note [Region barrier policy] and Note [Region dependency
-- contract] in 'MetaSonic.Bridge.Compile.Dependencies'.
module MetaSonic.Bridge.Compile.Schedule
  ( regionSchedule
  , scheduledRuntimeRegions
  , Segment (..)
  , segmentByBarrier
  , RegionScheduleStats (..)
  , regionScheduleStats
  , emptyScheduleStats
  , addScheduleStats
  ) where

import           Data.List       (partition)
import qualified Data.Map.Strict as M
import qualified Data.Set        as S

import           MetaSonic.Bridge.Compile.Dependencies
                   ( regionDependencies
                   , regionHasLiveBus
                   )
import           MetaSonic.Bridge.Compile.Types
                   ( RuntimeGraph (..)
                   , RuntimeRegion (..)
                   , RegionIndex (..)
                   )

-- | One slice of the schedule. Either a single 'Barrier' region
-- (a live-bus region pinned at its compile-decreed 'rrIndex'
-- position) or a 'FreeSegment' — a maximal run of non-barrier
-- regions that the scheduler may topologically sort.
--
-- Exported for diagnostic / testability purposes; the scheduler
-- consumes 'regionSchedule' directly.
data Segment
  = Barrier     !RuntimeRegion
  | FreeSegment ![RuntimeRegion]
  deriving stock (Eq, Show)

-- | Walk regions in 'rrIndex' order, partitioning into a list of
-- 'Segment's. The output preserves the original 'rrIndex' order
-- at the segment level: barriers stay where they were, and free
-- segments are the maximal runs of consecutive non-barrier
-- regions between (or before / after) them.
--
-- Empty 'FreeSegment's are never emitted — adjacent barriers
-- produce no segment between them.
segmentByBarrier :: RuntimeGraph -> [Segment]
segmentByBarrier rg = go [] (rgRuntimeRegions rg)
  where
    -- 'acc' accumulates the open free segment in /reverse/ order;
    -- flush it (in correct order) when we hit a barrier or the
    -- end of the input.
    flushAcc :: [RuntimeRegion] -> [Segment]
    flushAcc []  = []
    flushAcc acc = [FreeSegment (reverse acc)]

    go acc []     = flushAcc acc
    go acc (r:rs)
      | regionHasLiveBus rg r =
          flushAcc acc ++ Barrier r : go [] rs
      | otherwise             =
          go (r : acc) rs

-- | Compute the deterministic single-thread region schedule
-- under the §4.E.1c barrier policy. See module-level haddock for
-- the full contract.
--
-- Returns @Right@ with a list of 'RegionIndex' in execution order
-- when the inputs are well-formed. Returns @Left@ with a
-- diagnostic when:
--
--   * 'rgRuntimeRegions' is not dense-ascending by 'rrIndex' from
--     0 (duplicate, missing, or non-ascending),
--   * a free segment contains a dependency cycle, or
--   * any region's dependencies point to a region that has not
--     yet been scheduled by the time that segment runs (a
--     forward cross-segment edge — the dependency points into a
--     later barrier or free segment).
--
-- §4.E.2b will consume @Right@ values directly; the @Left@ paths
-- exist so a future change that breaks the input contract is
-- caught here, not by silent reordering at runtime.
regionSchedule :: RuntimeGraph -> Either String [RegionIndex]
regionSchedule rg = do
  validateRegionOrder (rgRuntimeRegions rg)
  go S.empty (segmentByBarrier rg)
  where
    deps = regionDependencies rg

    go _    []           = Right []
    go done (seg : rest) = do
      ixs <- scheduleSegment deps done seg
      let done' = foldr S.insert done ixs
      (ixs ++) <$> go done' rest

-- | Loader-facing helper: turn a 'RuntimeGraph' into the list of
-- 'RuntimeRegion's in scheduled execution order.
--
-- Implemented as 'regionSchedule' followed by an index-to-region
-- lookup over 'rgRuntimeRegions'. The dense-ascending validation
-- inside 'regionSchedule' guarantees the lookup is total (every
-- 'RegionIndex' the planner emits maps to a region in the input
-- list), so the @Left@ paths surface only planner diagnostics —
-- there is no separate "index out of range" failure mode.
--
-- §4.E.2b loaders use this to register regions on the C++ side in
-- scheduled order rather than raw 'rgRuntimeRegions' list order.
-- The two coincide today (the planner's output is the identity
-- over 'rrIndex' order), so this is a behavior-preserving rewire.
scheduledRuntimeRegions
  :: RuntimeGraph -> Either String [RuntimeRegion]
scheduledRuntimeRegions rg = do
  ixs <- regionSchedule rg
  let byIx = M.fromList
        [ (rrIndex r, r) | r <- rgRuntimeRegions rg ]
  pure [ byIx M.! ix | ix <- ixs ]

-- | The contract is that 'rgRuntimeRegions' is in dense ascending
-- 'rrIndex' order from 0. 'segmentByBarrier' relies on /list/
-- order to position barriers and free segments, and
-- 'topoSortStable' uses /list/ order as the stable tie-breaker
-- inside a free segment — so the two only agree with the
-- documented rrIndex-stable contract when the list /is/ rrIndex
-- order.
--
-- Reject duplicates, gaps, and non-ascending list order with a
-- specific diagnostic so a future bug that produces, say, a
-- region list with a missing index or a swapped pair is caught
-- here.
validateRegionOrder :: [RuntimeRegion] -> Either String ()
validateRegionOrder rs =
  let ixs      = map rrIndex rs
      expected = [RegionIndex i | i <- [0 .. length rs - 1]]
  in if ixs == expected
       then Right ()
       else Left $
         "regionSchedule: rgRuntimeRegions must be dense "
         <> "ascending by rrIndex from 0; got "
         <> show ixs <> ", expected " <> show expected

-- | Schedule one segment.
--
-- 'Barrier' segments emit their single region's index after
-- checking that the barrier's dependencies are all already done
-- (a dependency on a region that hasn't run yet is a forward
-- edge — caller's invariant is broken).
--
-- 'FreeSegment's split each member's dependencies into intra- and
-- cross-segment sets. Cross-segment deps must already be in
-- 'done'; otherwise the planner returns @Left@. Intra-segment
-- deps drive a stable topological sort ('topoSortStable'), which
-- itself returns @Left@ on a cycle.
scheduleSegment
  :: M.Map RegionIndex (S.Set RegionIndex)
  -> S.Set RegionIndex
  -> Segment
  -> Either String [RegionIndex]
scheduleSegment deps done (Barrier r) =
  let ix       = rrIndex r
      depsHere = M.findWithDefault S.empty ix deps
      missing  = depsHere `S.difference` done
  in if S.null missing
       then Right [ix]
       else Left $
         "regionSchedule: barrier region " <> show ix
         <> " depends on un-scheduled region(s) "
         <> show (S.toList missing)
         <> " (forward cross-segment edge in regionDependencies)"
scheduleSegment deps done (FreeSegment members) =
  let memberSet  = S.fromList (map rrIndex members)
      crossErrs  =
        [ (rrIndex r, S.toList missing)
        | r <- members
        , let allDeps   = M.findWithDefault S.empty (rrIndex r) deps
              crossDeps = allDeps `S.difference` memberSet
              missing   = crossDeps `S.difference` done
        , not (S.null missing)
        ]
      intraDeps = M.fromList
        [ (rrIndex r
          , S.intersection
              memberSet
              (M.findWithDefault S.empty (rrIndex r) deps))
        | r <- members
        ]
  in case crossErrs of
       [] -> topoSortStable intraDeps (map rrIndex members)
       _  -> Left $
         "regionSchedule: free-segment region(s) depend on "
         <> "un-scheduled region(s): " <> show crossErrs
         <> " (forward cross-segment edge in regionDependencies)"

-- | Stable topological sort: of all regions whose intra-segment
-- dependencies are already in 'done', emit the lowest-rrIndex
-- one first. This produces 'rrIndex' order whenever the input
-- list is itself a valid topological order — which is the
-- common case today, since 'compileRuntimeGraph' constructs
-- regions in topological 'rrIndex' order.
--
-- The algorithm is a small Kahn's variant: the @ready@ list is
-- the input in 'rrIndex' order, and the inner step picks the
-- first ready region. O(N²) on the segment size, acceptable for
-- the small region counts typical of MetaSonic graphs.
--
-- A cycle inside the segment is reported as @Left@ — by
-- construction (compileRuntimeGraph yields topological 'rrIndex'
-- order) this should never trigger today, but the planner
-- shouldn't silently fall back if a future change introduces one.
topoSortStable
  :: M.Map RegionIndex (S.Set RegionIndex)
  -> [RegionIndex]
  -> Either String [RegionIndex]
topoSortStable intraDeps = go S.empty
  where
    go _    []        = Right []
    go done remaining =
      let depsOf ix = M.findWithDefault S.empty ix intraDeps
          ready ix  = S.null (depsOf ix `S.difference` done)
      in case break ready remaining of
           (skipped, ix : rest) ->
             (ix :) <$> go (S.insert ix done) (skipped ++ rest)
           (_, []) ->
             Left $
               "regionSchedule: cycle in intra-segment "
               <> "regionDependencies among regions "
               <> show remaining

-- | Read-only descriptive view of a 'RuntimeGraph''s schedule —
-- the survey input for the parallel-readiness question "do MetaSonic
-- graphs actually contain wide non-barrier work, or are they
-- sink/barrier dominated?"
--
-- Counts derive from 'segmentByBarrier' + 'regionDependencies' and
-- preserve the §4.E.1c invariants: barriers are immovable; free
-- segments admit topological reordering with 'rrIndex' as the
-- stable tie-breaker.
--
--   * 'rssTotal'           — total runtime regions in the graph.
--   * 'rssBarriers'        — regions classified as live-bus
--                            barriers ('regionHasLiveBus').
--   * 'rssFree'            — non-barrier regions; together with
--                            'rssBarriers' equals 'rssTotal'.
--   * 'rssFreeSegments'    — number of maximal free runs between
--                            barriers (length of 'segmentByBarrier'
--                            minus the barrier count).
--   * 'rssMaxFreeSegmentWidth'
--                          — region count of the widest free
--                            segment. An upper bound on parallel
--                            work if every free region in that
--                            segment were independent.
--   * 'rssMaxFreeLayerWidth'
--                          — widest topological /layer/ within any
--                            free segment, computed as Kahn's
--                            by-layer over intra-segment
--                            dependencies. The realistic
--                            parallelism estimate: layer width is
--                            how many regions could actually run
--                            concurrently. A pure chain has
--                            layer width 1 even if the segment
--                            itself is wide.
--
-- All fields are non-negative; an empty graph yields all zeros
-- ('emptyScheduleStats'). 'addScheduleStats' aggregates across
-- templates by summing the four counts and taking the @max@ of
-- the two width fields, which preserves the "biggest opportunity
-- in this ensemble" reading.
data RegionScheduleStats = RegionScheduleStats
  { rssTotal               :: !Int
  , rssBarriers            :: !Int
  , rssFree                :: !Int
  , rssFreeSegments        :: !Int
  , rssMaxFreeSegmentWidth :: !Int
  , rssMaxFreeLayerWidth   :: !Int
  } deriving (Eq, Show)

-- | The zero stats — the identity for 'addScheduleStats'. Useful
-- as a 'foldr' / 'foldl'' seed when aggregating across templates
-- or when an empty graph is the right answer.
emptyScheduleStats :: RegionScheduleStats
emptyScheduleStats = RegionScheduleStats
  { rssTotal               = 0
  , rssBarriers            = 0
  , rssFree                = 0
  , rssFreeSegments        = 0
  , rssMaxFreeSegmentWidth = 0
  , rssMaxFreeLayerWidth   = 0
  }

-- | Combine two stats records: counts add, widths take the max.
-- This is the natural aggregation for template ensembles —
-- summing the four counts gives total work across templates, and
-- max-of-widths preserves "biggest single opportunity anywhere
-- in the ensemble". Associative; 'emptyScheduleStats' is the
-- identity.
addScheduleStats
  :: RegionScheduleStats -> RegionScheduleStats -> RegionScheduleStats
addScheduleStats a b = RegionScheduleStats
  { rssTotal               = rssTotal a               + rssTotal b
  , rssBarriers            = rssBarriers a            + rssBarriers b
  , rssFree                = rssFree a                + rssFree b
  , rssFreeSegments        = rssFreeSegments a        + rssFreeSegments b
  , rssMaxFreeSegmentWidth =
      max (rssMaxFreeSegmentWidth a) (rssMaxFreeSegmentWidth b)
  , rssMaxFreeLayerWidth   =
      max (rssMaxFreeLayerWidth   a) (rssMaxFreeLayerWidth   b)
  }

-- | Walk a 'RuntimeGraph''s schedule and report the descriptive
-- counts. Read-only — no compile or runtime change. Returns
-- @Left@ only if 'regionSchedule' itself rejects the input
-- (cycle / cross-segment edge / non-dense list); the diagnostic
-- is forwarded verbatim.
--
-- Today's 'compileRuntimeGraph' output never fails this check
-- because the planner is the identity over 'rrIndex' order, so
-- in practice every survey row succeeds.
regionScheduleStats
  :: RuntimeGraph -> Either String RegionScheduleStats
regionScheduleStats rg = do
  -- Forward any planner diagnostic. We only need the side effect
  -- of validation here — the layer widths derive from
  -- 'segmentByBarrier' + 'regionDependencies' directly.
  _ <- regionSchedule rg
  let segments = segmentByBarrier rg
      deps     = regionDependencies rg

      barriers, free :: Int
      barriers = length [() | Barrier _      <- segments]
      free     = sum    [length rs | FreeSegment rs <- segments]

      freeSegs = [rs | FreeSegment rs <- segments]
      maxSegW  = maxOr0 (map length freeSegs)

      layerWidths = concatMap (segmentLayerWidths deps) freeSegs
      maxLayerW   = maxOr0 layerWidths

  pure RegionScheduleStats
    { rssTotal               = length (rgRuntimeRegions rg)
    , rssBarriers            = barriers
    , rssFree                = free
    , rssFreeSegments        = length freeSegs
    , rssMaxFreeSegmentWidth = maxSegW
    , rssMaxFreeLayerWidth   = maxLayerW
    }

-- | Per-layer Kahn's over a free segment's intra-segment
-- dependencies. Each layer is the set of regions whose deps are
-- all already in earlier layers; layer 0 is the segment's roots.
-- Returns one width per layer.
--
-- A degenerate fallback (no region ready in a non-empty
-- @remaining@) emits the rest as one final "layer" so the survey
-- doesn't loop. The schedule planner's own cycle check would have
-- already returned 'Left' before this code runs in
-- 'regionScheduleStats', so this branch is purely defensive.
segmentLayerWidths
  :: M.Map RegionIndex (S.Set RegionIndex)
  -> [RuntimeRegion]
  -> [Int]
segmentLayerWidths deps members =
  let memberSet = S.fromList (map rrIndex members)
      intraDeps = M.fromList
        [ (rrIndex r
          , S.intersection
              memberSet
              (M.findWithDefault S.empty (rrIndex r) deps))
        | r <- members
        ]
  in goLayers S.empty (map rrIndex members) intraDeps

goLayers
  :: S.Set RegionIndex
  -> [RegionIndex]
  -> M.Map RegionIndex (S.Set RegionIndex)
  -> [Int]
goLayers _    []        _    = []
goLayers done remaining deps =
  let depsOf ix = M.findWithDefault S.empty ix deps
      ready ix  = S.null (depsOf ix `S.difference` done)
      (layer, rest) = partition ready remaining
  in if null layer
       then [length remaining]   -- defensive cycle fallback
       else length layer
            : goLayers (foldr S.insert done layer) rest deps

maxOr0 :: [Int] -> Int
maxOr0 [] = 0
maxOr0 xs = maximum xs
