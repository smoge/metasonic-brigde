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
  ) where

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
