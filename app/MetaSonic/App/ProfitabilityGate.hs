{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.ProfitabilityGate
-- Description : Phase 7.F read-only profitability gate.
--
-- The gate is a verdict function over the existing cost-model join.
-- Given a planner-selected candidate, the generator's coverage of
-- it, and the cost-lab measurements for matching variants, the gate
-- classifies the row as one of six verdicts in a fixed priority
-- order. The verdicts surface in @--fusion-survey@ as a
-- /Phase 7.F generated profitability gate/ section.
--
-- Strictly read-only in this slice: no runtime path consumes the
-- verdicts. The point is to formalize the safety rule so the
-- existence of @ExecGenerated@ is not mistaken for readiness.
--
-- See [notes/2026-05-12-phase-7f-profitability-gate.md] for the
-- decision artifact and rule motivation.
module MetaSonic.App.ProfitabilityGate
  ( -- * Verdicts
    GateVerdict (..)
  , PreferExistingReason (..)
  , NeedsBenchmarkReason (..)
  , verdictTag
  , verdictReason
    -- * Per-shape inputs and rows
  , GateInput (..)
  , GateRow (..)
  , evaluateGate
    -- * Summary
  , GateCounts (..)
  , emptyGateCounts
  , summarizeGate
  ) where

import           MetaSonic.App.FusionCostModel (measuredWinThreshold)

-- | The six terminal verdicts. The constructors are exported but
-- callers should usually go through 'evaluateGate' so the
-- priority order stays fixed.
data GateVerdict
  = PreferGenerated
    -- ^ Generated execution is the best path the gate measured:
    -- bit-exact, not §4.B-covered, faster than node-loop, faster
    -- than every measured non-generated peer.
  | PreferExisting !PreferExistingReason
    -- ^ Generated is exact but is not better than what already
    -- ships. 'PreferExistingReason' carries the comparison the
    -- gate used to make the call.
  | NeedsBenchmark !NeedsBenchmarkReason
    -- ^ The gate cannot reach a profitability decision from the
    -- evidence on hand. The reason payload distinguishes the
    -- three concrete gaps (no generated row, no peer row,
    -- neither measured). The tally tag in 'verdictTag' stays
    -- @\"needs-benchmark\"@ — the sub-split is for diagnostics
    -- and snapshot reason-aware pins, not for the headline
    -- counts.
  | Unsupported !String
    -- ^ Generator declined to emit a program for this candidate.
    -- The 'String' is the decline-reason bucket from the cost-lab
    -- diagnostic ("not implemented yet", etc.).
  | NonExact
    -- ^ Generated program emitted but its output diverged from
    -- 'RNodeLoop'. Hard correctness no even if the measured
    -- speedup were favorable.
  | CoveredByHandKernel
    -- ^ Candidate's @fcMatchedShape@ is @Just _@: a §4.B
    -- hand-written kernel already claims this shape. v1 of the
    -- gate is audit-only on §4.B shapes; hand-written kernels are
    -- not automatically replaced.
  deriving stock (Eq, Show)

-- | Why generated lost to an existing path in 'PreferExisting'.
data PreferExistingReason
  = SlowerThanNodeLoop !Double
    -- ^ Generated measured below 'measuredWinThreshold' against
    -- the node-loop baseline. Carries the generated speedup.
  | SlowerThanBestPeer !Double !Double
    -- ^ Generated beat node-loop but lost to the best measured
    -- non-generated peer (region-kernel / RFused). Carries
    -- @(generatedSpeedup, bestPeerSpeedup)@.
  deriving stock (Eq, Show)

-- | Which evidence gap left the gate at 'NeedsBenchmark'.
-- Splitting the verdict keeps the per-shape diagnostic
-- actionable without splitting the tally (a 'NeedsBenchmark' of
-- any flavor still counts as a single gate row).
data NeedsBenchmarkReason
  = NoGenerated
    -- ^ No 'VarGenerated' speedup recorded for this shape: the
    -- generator declined a different sibling, the cost lab
    -- timed only a sibling-suffix, or the shape is not present
    -- in the cost-lab corpus at all. Resolution: corpus growth
    -- or generator widening.
  | NoPeer
    -- ^ 'VarGenerated' measured and beat the win threshold, but
    -- no exact 'VarRegionKernel' / 'VarRFused' speedup is
    -- available to compare against. The gate cannot promote to
    -- 'PreferGenerated' without that comparison.
  | NoMeasurement
    -- ^ Neither generated nor peer measurements exist for this
    -- shape. The cost lab has nothing to say.
  deriving stock (Eq, Show)

-- | All facts the gate needs about one (shape, member) row.
--
-- Built upstream by joining planner candidates to the cost-lab
-- row index. The constructor is intentionally a record so the
-- field meanings stay self-documenting at every call site.
data GateInput = GateInput
  { giShapeLabel       :: !String
    -- ^ Display label for the shape; conventionally
    -- @\"family/member\"@ when the cost-lab is the source, or a
    -- survey row label for survey-driven inputs.
  , giHasHandKernel    :: !Bool
    -- ^ True iff @fcMatchedShape@ on the originating candidate
    -- was @Just _@.
  , giGeneratorError   :: !(Maybe String)
    -- ^ Cost-lab diagnostic bucket for the generated row's
    -- failure, when the generator declined or the row failed to
    -- compile / time. @Nothing@ means the generator emitted a
    -- program and the row produced a timing.
  , giGeneratedExact   :: !Bool
    -- ^ True iff the emitted generated program's output matched
    -- 'RNodeLoop' bit-for-bit. Only meaningful when
    -- 'giGeneratorError' is 'Nothing'.
  , giGeneratedSpeedup :: !(Maybe Double)
    -- ^ Generated speedup relative to the node-loop baseline.
    -- 'Nothing' if not measured.
  , giBestPeerSpeedup  :: !(Maybe Double)
    -- ^ Best measured speedup among non-generated, non-node-loop
    -- variants for the same row (typically @max@ of region-kernel
    -- and RFused). 'Nothing' if no peer measured.
  } deriving stock (Eq, Show)

-- | A 'GateInput' with its decided verdict. Carrying the input
-- forward keeps the verdict explainable at print / pin time
-- without re-running the rules.
data GateRow = GateRow
  { grInput   :: !GateInput
  , grVerdict :: !GateVerdict
  } deriving stock (Eq, Show)

-- | Apply the six rules in priority order. The first matching
-- rule wins; rules below it do not run.
--
-- Order is intentional and matches
-- [notes/2026-05-12-phase-7f-profitability-gate.md]:
--
--   1. 'Unsupported'    — generator declined.
--   2. 'NonExact'       — correctness divergence (hard no).
--   3. 'CoveredByHandKernel' — §4.B audit-only in v1.
--   4. 'NeedsBenchmark' — no measurement to decide on.
--   5. 'PreferExisting' — generated lost to baseline or peer.
--   6. 'PreferGenerated' — only path that says \"turn it on\".
evaluateGate :: GateInput -> GateVerdict
evaluateGate gi
  | Just err <- giGeneratorError gi
                                    = Unsupported err
  | not (giGeneratedExact gi)       = NonExact
  | giHasHandKernel gi              = CoveredByHandKernel
  | otherwise =
      case (giGeneratedSpeedup gi, giBestPeerSpeedup gi) of
        (Nothing, Nothing) -> NeedsBenchmark NoMeasurement
        (Nothing, Just _)  -> NeedsBenchmark NoGenerated
        (Just gen, mpeer)
          | gen < measuredWinThreshold ->
              PreferExisting (SlowerThanNodeLoop gen)
          | otherwise -> case mpeer of
              Nothing  -> NeedsBenchmark NoPeer
              Just peer
                | gen >= peer -> PreferGenerated
                | otherwise   -> PreferExisting (SlowerThanBestPeer gen peer)

-- | One-word constructor tag suitable for tally headers and
-- snapshot diagnostics. Keeps printing code from carrying the
-- ADT shape around.
verdictTag :: GateVerdict -> String
verdictTag PreferGenerated       = "prefer-generated"
verdictTag (PreferExisting _)    = "prefer-existing"
verdictTag (NeedsBenchmark _)    = "needs-benchmark"
verdictTag (Unsupported _)       = "unsupported"
verdictTag NonExact              = "non-exact"
verdictTag CoveredByHandKernel   = "covered-by-hand-kernel"

-- | Human-readable suffix explaining the verdict's evidence.
-- Empty for terminal-only verdicts; non-empty for the variants
-- that carry a reason payload.
verdictReason :: GateVerdict -> String
verdictReason PreferGenerated     = ""
verdictReason NonExact            = ""
verdictReason CoveredByHandKernel = ""
verdictReason (Unsupported s)     = s
verdictReason (PreferExisting r)  = case r of
  SlowerThanNodeLoop gen ->
    "generated " <> showSpeedup gen <> " < node-loop"
  SlowerThanBestPeer gen peer ->
    "generated " <> showSpeedup gen
      <> " < peer " <> showSpeedup peer
verdictReason (NeedsBenchmark r) = case r of
  NoGenerated   -> "no generated measurement"
  NoPeer        -> "no peer measurement"
  NoMeasurement -> "no measurement at all"

showSpeedup :: Double -> String
showSpeedup x =
  let scaled = fromIntegral (round (x * 100) :: Int) / 100 :: Double
  in show scaled <> "x"

-- | Tally of verdicts over a set of 'GateRow' values. Counts are
-- the snapshot-friendly signals: deterministic, bench-noise-free,
-- and easy to pin.
data GateCounts = GateCounts
  { gcTotal               :: !Int
  , gcPreferGenerated     :: !Int
  , gcPreferExisting      :: !Int
  , gcNeedsBenchmark      :: !Int
  , gcUnsupported         :: !Int
  , gcNonExact            :: !Int
  , gcCoveredByHandKernel :: !Int
  } deriving stock (Eq, Show)

emptyGateCounts :: GateCounts
emptyGateCounts = GateCounts 0 0 0 0 0 0 0

summarizeGate :: [GateRow] -> GateCounts
summarizeGate = foldr step emptyGateCounts
  where
    step row !acc =
      let acc' = acc { gcTotal = gcTotal acc + 1 }
      in case grVerdict row of
           PreferGenerated     ->
             acc' { gcPreferGenerated = gcPreferGenerated acc' + 1 }
           PreferExisting _    ->
             acc' { gcPreferExisting = gcPreferExisting acc' + 1 }
           NeedsBenchmark _    ->
             acc' { gcNeedsBenchmark = gcNeedsBenchmark acc' + 1 }
           Unsupported _       ->
             acc' { gcUnsupported = gcUnsupported acc' + 1 }
           NonExact            ->
             acc' { gcNonExact = gcNonExact acc' + 1 }
           CoveredByHandKernel ->
             acc' { gcCoveredByHandKernel = gcCoveredByHandKernel acc' + 1 }
