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
-- See Note [Region barrier policy] and Note [Region dependency
-- contract] in 'MetaSonic.Bridge.Compile.Dependencies'.
module MetaSonic.Bridge.Compile.Schedule
  ( regionSchedule
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
                   , RegionIndex
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
-- Output is a list of 'RegionIndex' in execution order.
regionSchedule :: RuntimeGraph -> [RegionIndex]
regionSchedule rg =
  let deps     = regionDependencies rg
      segments = segmentByBarrier rg
  in concatMap (scheduleSegment deps) segments

-- | Schedule one segment.
--
-- 'Barrier' segments emit their single region's index verbatim;
-- 'FreeSegment's topologically order their members against
-- /intra-segment/ dependencies (the scheduler doesn't need to
-- resort dependencies that point outside the segment — those
-- have already been satisfied by the linear segment-by-segment
-- execution).
scheduleSegment
  :: M.Map RegionIndex (S.Set RegionIndex)
  -> Segment
  -> [RegionIndex]
scheduleSegment _    (Barrier r)            = [rrIndex r]
scheduleSegment deps (FreeSegment members)  =
  let memberSet = S.fromList (map rrIndex members)
      -- Restrict each region's deps to the segment. Cross-segment
      -- edges (to earlier barriers or earlier free segments) are
      -- guaranteed satisfied by the time this segment runs.
      intraDeps = M.fromList
        [ (rrIndex r
          , S.intersection
              memberSet
              (M.findWithDefault S.empty (rrIndex r) deps))
        | r <- members
        ]
  in topoSortStable intraDeps (map rrIndex members)

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
-- Cycle defense: if no region is ready (which would indicate a
-- cycle in 'regionDependencies' — impossible today because
-- 'rrIndex' is a topological order, but the planner shouldn't
-- crash if a future change broke that), the remaining regions
-- are emitted in their input ('rrIndex') order. This is silent
-- degradation, not a correctness fix; a separate test should
-- catch the cycle if it ever arises.
topoSortStable
  :: M.Map RegionIndex (S.Set RegionIndex)
  -> [RegionIndex]
  -> [RegionIndex]
topoSortStable intraDeps = go S.empty
  where
    go _    []        = []
    go done remaining =
      let depsOf ix = M.findWithDefault S.empty ix intraDeps
          ready ix  = S.null (depsOf ix `S.difference` done)
      in case break ready remaining of
           (skipped, ix : rest) ->
             ix : go (S.insert ix done) (skipped ++ rest)
           (_, []) ->
             -- No region is ready; cycle defense (see haddock).
             remaining
