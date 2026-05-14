{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.FusionCostModel
-- Description : Shared Phase 7 fusion cost-model vocabulary.
--
-- This module owns the small data model shared by the fusion survey,
-- snapshot checks, profitability gate, and cost lab. It deliberately
-- excludes benchmark collection, graph-family generation, and table
-- rendering; those stay in the app modules that perform those jobs.
module MetaSonic.App.FusionCostModel
  ( Variant (..)
  , variantName
  , ShapeKey (..)
  , ShapeSummary (..)
  , GateMeasurement (..)
  , measuredWinThreshold
  , shapeKeyOf
  ) where

import           MetaSonic.Bridge.Planner (FusionCandidate (..))

-- | Which runtime path a cost-model row measures.
data Variant
  = VarNodeLoop
    -- ^ The stripped baseline. Compiled through the normal runtime
    -- compiler, then every region-kernel tag is forced back to
    -- 'RNodeLoop' before loading.
  | VarRegionKernel
    -- ^ Hand-written region kernels — the current default. Uses
    -- 'compileRuntimeGraph' and 'loadRuntimeGraph' as production
    -- demos do.
  | VarRFused
    -- ^ Scalar-affine RFused rewrite layered on top of region
    -- kernels via 'compileRuntimeGraphFused' /
    -- 'loadRuntimeGraphFused'. The fused regions live alongside
    -- the kernels, so this variant is "kernels + RFused", not
    -- "RFused alone."
  | VarGenerated
    -- ^ §7.D generated fusion program, sample-major executor.
    -- Compiles to a stripped 'RuntimeGraph' (every region
    -- 'ExecNodeLoop'), runs the planner, then patches in a
    -- generated 'FusionProgram' for the first generatable
    -- selected candidate.
  | VarGeneratedBlock
    -- ^ §7.H generated fusion program, block-major executor.
    -- Identical compile-time pipeline and identical emitted
    -- 'FusionProgram' as 'VarGenerated'; only the per-region
    -- 'RegionExec' selector differs ('ExecGeneratedBlock' rather
    -- than 'ExecGenerated'), so the C++ side dispatches through
    -- 'process_fusion_program_block' instead of the sample-major
    -- 'process_fusion_program'. Exists for direct A/B
    -- measurement; a future slice may collapse the variants
    -- once the dispatch-model decision is made.
  | VarGeneratedSuper
    -- ^ §7.I generated fusion program, super-mode executor.
    -- Identical compile-time pipeline and identical emitted
    -- 'FusionProgram' as 'VarGenerated' and 'VarGeneratedBlock';
    -- only the per-region 'RegionExec' selector differs
    -- ('ExecGeneratedSuper'). The C++ side recognizes 'GainOut'
    -- and 'AddGainOut' fused shapes as a single per-sample loop
    -- and falls through to 'process_fusion_program_block' on
    -- everything else. Exists for direct A/B/C measurement
    -- across the three generated executors.
  deriving stock (Eq, Show, Bounded, Enum)

variantName :: Variant -> String
variantName VarNodeLoop       = "node-loop"
variantName VarRegionKernel   = "region-kernel"
variantName VarRFused         = "rfused"
variantName VarGenerated      = "generated"
variantName VarGeneratedBlock = "generated-block"
variantName VarGeneratedSuper = "generated-super"

-- | Compact key for joining selected planner candidates to measured
-- cost-lab rows. 'skKinds' is the 'fromEnum'-encoded
-- 'fcMemberKinds' sequence. 'skGainAmountModes' is the v1 feature
-- axis: one encoded gain-amount mode per 'KGain' member, in member
-- order, so scalar-gain and dynamic-gain chains do not share
-- measurement evidence.
data ShapeKey = ShapeKey
  { skKinds           :: ![Int]
  , skGainAmountModes :: ![Int]
  } deriving stock (Eq, Ord, Show)

-- | Per-shape measurement summary keyed by 'shapeKeyOf'.
--
-- 'ssSpeedup' is @ssBaselineNs / ssFastestNs@. Callers compare it
-- to 'measuredWinThreshold' before treating the row as a measured win.
data ShapeSummary = ShapeSummary
  { ssSpeedup        :: !Double
  , ssFastestVariant :: !Variant
  , ssBaselineNs     :: !Double
  , ssFastestNs      :: !Double
  } deriving stock (Eq, Show)

-- | Per-shape cost-lab measurement view tailored for the read-only
-- profitability gate. Carries the facts the gate needs to decide a
-- verdict:
--
--   * 'gmGeneratorError' -- decline/error bucket for the generated row.
--   * 'gmGeneratedExact' -- whether generated matched 'RNodeLoop'.
--   * 'gmGeneratedSpeedup' -- generated speedup vs node-loop.
--   * 'gmBestPeerSpeedup' -- best measured region-kernel/RFused peer.
data GateMeasurement = GateMeasurement
  { gmGeneratorError   :: !(Maybe String)
  , gmGeneratedExact   :: !Bool
  , gmGeneratedSpeedup :: !(Maybe Double)
  , gmBestPeerSpeedup  :: !(Maybe Double)
  } deriving stock (Eq, Show)

-- | Minimum speedup before diagnostic cost-model joins call a row a
-- measured win. Tiny >1.0 movements are benchmark noise for this
-- tool; keeping them in measured-loss prevents the gate from flapping.
measuredWinThreshold :: Double
measuredWinThreshold = 1.05

-- | Encode a selected planner candidate as an order-preserving key
-- usable in a 'Data.Map' (since 'NodeKind' lacks 'Ord' but has
-- 'Enum').
shapeKeyOf :: FusionCandidate -> ShapeKey
shapeKeyOf c = ShapeKey
  { skKinds           = map fromEnum (fcMemberKinds c)
  , skGainAmountModes = map fromEnum (fcGainAmountModes c)
  }
