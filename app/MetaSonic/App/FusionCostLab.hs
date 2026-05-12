{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.FusionCostLab
-- Description : Phase 7.A fusion cost lab — first slice
--
-- The fusion cost lab is offline tooling that builds a small bank of
-- parametric and corpus-derived graph families, compiles each family
-- member through three runtime variants (stripped node-loop baseline,
-- hand-written region kernels, RFused), measures per-sample timing
-- for each variant, and emits one machine-readable row per (family,
-- member, variant) tuple.
--
-- The deliberate scope of slice 1:
--
--   * Four deterministic families. Three are closed-form generated
--     families ('FamilySinkChain', 'FamilyReturnTail',
--     'FamilyFanout'); one is a small real-corpus slice
--     ('FamilyCorpus') pulled from demos and pattern rows.
--
--   * Feature extraction reads compiler facts off the produced
--     'RuntimeGraph' — node/region count, fused-kernel mix, RFused
--     inputs, resource-footprint counts, declared-latency counts, and
--     consumer/fanout shape — without re-deriving them from source
--     syntax.
--
--   * Equivalence is the cheap version: render N blocks per variant,
--     read every bus written by a KOut / KBusOut node, compare
--     bit-exact. Anything that doesn't match short-circuits to
--     'EqMismatch' and the row's timing is reported but flagged.
--     NoiseGen-rooted families are excluded for now — separate
--     handles produce divergent PRNG streams (design note §6 calls
--     this out as the v1 carve-out).
--
--   * The benchmark loop is intentionally smaller than
--     'MetaSonic.App.WorkerBench': warmup, then a fixed block count
--     timed end-to-end with median-of-three repeats. The cost model
--     this feeds (slice 4+) cares about relative ordering between
--     variants, not absolute throughput.
--
--   * Output is JSONL by default (one row per line, no external
--     dependency); '--summary' produces a per-family table that
--     translates rows back into the explainable-recommendation form
--     the cost model will eventually emit.
--
-- Out of slice 1: generated-fusion variant (the runtime doesn't have
-- one yet; the column slot is reserved but never populated), CSV
-- output, parametric size sweeps beyond a fixed small set,
-- multi-instance / multi-template benchmarks, and the
-- profitability-recommendation labels themselves — slice 1 prints
-- speedups so a human can read them; slice 4+ turns them into
-- /Fuse/ // /DoNotFuse/ // /NeedsBenchmark/ decisions.
--
-- See [notes/2026-05-11-phase-7a-fusion-cost-lab-design.md].

module MetaSonic.App.FusionCostLab
  ( -- * CLI entry point
    runFusionCostLab
  , collectFusionCostLabRows
  , FusionCostLabOptions (..)
  , defaultOptions
  , OutputFormat (..)

    -- * Lab data
  , GraphFamily (..)
  , familyName
  , familyMembers
  , LabRow (..)
  , Variant (..)
  , variantName
  , FusionCaseFeatures (..)
  , extractFeatures
  , EquivalenceStatus (..)
    -- * Shape-keyed cost-model index (§7.C cost-model join)
  , ShapeKey (..)
  , ShapeSummary (..)
  , measuredWinThreshold
  , costLabShapeIndex
  , shapeKeyOf
  ) where

import           Control.Monad              (forM, forM_, replicateM_)
import           Data.List                  (intercalate, sort, sortOn)
import qualified Data.Map.Strict            as M
import qualified Data.Set                   as S
import           Foreign                    (allocaArray, castPtr, peekArray)
import           Foreign.C.Types            (CFloat (..))
import           Foreign.Ptr                (Ptr)
import           GHC.Clock                  (getMonotonicTimeNSec)
import           Text.Printf                (printf)

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR        (lowerGraph)
import           MetaSonic.Bridge.Planner   (FusionCandidate (..),
                                             planRuntimeGraph,
                                             selectedFusionCandidates)
import           MetaSonic.Bridge.Source
import qualified MetaSonic.App.Demos        as Demos
import qualified MetaSonic.Pattern.Corpus   as Corpus

import           MetaSonic.Types            (NodeKind (..), kindLatency)


------------------------------------------------------------
-- Families
------------------------------------------------------------

-- | One generator family. Each constructor names a deterministic
-- shape class plus the small parameter set that varies inside it.
-- Slice 1 keeps families closed-form; slice 2 may add fuzz members
-- behind a separate flag.
data GraphFamily
  = FamilySinkChain
    -- ^ Sink-terminal chains the §4.B kernel set claims:
    -- @SinOsc → Gain → Out@, @Saw → LPF → Gain → Out@,
    -- @Saw → Gain → Out@, @BusIn → LPF → Gain → Out@.
    -- These are the rows the cost lab most wants to bracket —
    -- they are the shapes where /generated/ fusion will first
    -- have to prove itself against a hand-written kernel.
  | FamilyReturnTail
    -- ^ Send/return shapes with a BusOut source feeding a
    -- BusIn-rooted tail. The bus is allocated and read in the
    -- same graph for simplicity (cross-template returns are a
    -- multi-graph extension).
  | FamilyFanout
    -- ^ Intentional kernel-miss shape: a single source feeds two
    -- downstream gain branches, both reaching separate outs.
    -- The §4.B sink-terminal kernels require @consumerCount == 1@
    -- on the gain, so this row must fall back to 'RNodeLoop' on
    -- every variant. It bounds the lab's expected speedup at 1.0×
    -- and acts as a regression target if a future kernel relaxes
    -- the single-consumer gate.
  | FamilyCorpus
    -- ^ A small real-corpus slice from demos and Phase 6.A pattern
    -- rows. These rows keep the lab connected to musical shapes while
    -- still using single 'SynthGraph' members, so the current
    -- equivalence harness can compare variants directly.
  | FamilyAddChain
    -- ^ Isolated Add-tail shapes flagged as 'needs-benchmark' by the
    -- §7.C cost-model join. Each member places an 'Add' chain at the
    -- source position of an accepted candidate by forcing the
    -- upstream oscillator to fanout, so the planner selects the
    -- 'KAdd'-rooted candidate as the maximal accepted shape. Covers
    -- @KAdd → KOut@, @KAdd → KLPF → KGain → KOut@, and the two
    -- recurring nested-Add variants. The fanout adds a constant Sin
    -- overhead across every variant; relative speedups stay
    -- comparable between variants.
  | FamilyDynamicGain
    -- ^ Dynamic-gain shapes flagged as 'needs-benchmark' after the
    -- §7.C 'KGain.amount' feature axis split scalar-gain measurements
    -- away from audio-rate-modulated ones. Members wire a slow
    -- 'SinOsc' modulator into 'KGain.amount' so the gain's
    -- 'rnInputs' include 'RFrom' on the amount slot (not 'RConst').
    -- Covers @KGain → KOut gain=dynamic@,
    -- @KSawOsc → KGain → KOut gain=dynamic@, and
    -- @KSinOsc → KGain → KGain → KOut gain=dynamic,const@. Dynamic
    -- gain is the cleanest bridge into 7.D because it exercises the
    -- tiny-executor primitives (input read, multiply, sink write)
    -- without adding stateful lifecycle questions.
  deriving stock (Eq, Show, Bounded, Enum)

familyName :: GraphFamily -> String
familyName FamilySinkChain   = "sink-chain"
familyName FamilyReturnTail  = "return-tail"
familyName FamilyFanout      = "fanout"
familyName FamilyCorpus      = "corpus"
familyName FamilyAddChain    = "add-chain"
familyName FamilyDynamicGain = "dynamic-gain"

-- | One member of a family. The string label is the row's stable
-- identity in JSONL output — keep it short and shell-grep-friendly.
data FamilyMember = FamilyMember !String !SynthGraph

familyMembers :: GraphFamily -> [FamilyMember]
familyMembers FamilySinkChain =
  [ FamilyMember "sin-gain-out"          sinkSinGainOut
  , FamilyMember "saw-gain-out"          sinkSawGainOut
  , FamilyMember "saw-lpf-gain-out"      sinkSawLpfGainOut
  , FamilyMember "busin-lpf-gain-out"    sinkBusInLpfGainOut
  ]
familyMembers FamilyReturnTail =
  [ FamilyMember "send-busout-return" returnSendReceive
  ]
familyMembers FamilyFanout =
  [ FamilyMember "sin-fanout-two-out"  fanoutTwoOut
  ]
familyMembers FamilyCorpus =
     [ FamilyMember "demo/chain"        Demos.chainGraph
     , FamilyMember "demo/fm"           Demos.fmGraph
     , FamilyMember "demo/ringmod"      Demos.ringModGraph
     , FamilyMember "demo/saw-lpf"      Demos.filteredSawGraph
     ]
  ++ templateMembers "pattern/drone-vibrato" Corpus.droneVibratoTemplates
  ++ templateMembers "pattern/hotswap-initial" Corpus.hotSwapEditTemplates
  ++ templateMembers "pattern/spectral-freeze" Corpus.spectralFreezePadTemplates
familyMembers FamilyAddChain =
  [ FamilyMember "add-out"                 addChainAddOut
  , FamilyMember "add-lpf-gain-out"        addChainAddLpfGainOut
  , FamilyMember "nested-add-gain-out"     addChainNestedGainOut
  , FamilyMember "nested-add-lpf-gain-out" addChainNestedLpfGainOut
  ]
familyMembers FamilyDynamicGain =
  [ FamilyMember "gain-dyn-out"         dynGainOut
  , FamilyMember "saw-gain-dyn-out"     dynGainSawOut
  , FamilyMember "sin-gain-dyn-gain-const-out" dynGainNestedOut
  ]

templateMembers :: String -> [(String, SynthGraph)] -> [FamilyMember]
templateMembers prefix entries =
  [ FamilyMember (prefix <> "/" <> name) graph
  | (name, graph) <- entries
  ]

------------------------------------------------------------
-- Family graph builders (closed-form, deterministic)
------------------------------------------------------------
--
-- The frequencies / cutoffs / gains below are arbitrary but fixed
-- so equivalence checks compare like for like across variants.

sinkSinGainOut :: SynthGraph
sinkSinGainOut = runSynth $ do
  osc <- sinOsc 440.0 0.0
  g   <- gain osc 0.5
  out 0 g

sinkSawGainOut :: SynthGraph
sinkSawGainOut = runSynth $ do
  osc <- sawOsc 220.0 0.0
  g   <- gain osc 0.4
  out 0 g

sinkSawLpfGainOut :: SynthGraph
sinkSawLpfGainOut = runSynth $ do
  osc <- sawOsc 220.0 0.0
  f   <- lpf osc 1200.0 0.7
  g   <- gain f 0.5
  out 0 g

sinkBusInLpfGainOut :: SynthGraph
sinkBusInLpfGainOut = runSynth $ do
  -- Drive bus 8 with a saw, then read it back through the canonical
  -- send/return tail. Both halves live in the same graph so the
  -- single-graph render path can verify equivalence without
  -- multi-template orchestration.
  s   <- sawOsc 220.0 0.0
  g0  <- gain s 0.3
  busOut 8 g0
  bi  <- busIn 8
  f   <- lpf bi 1500.0 0.7
  g   <- gain f 0.5
  out 0 g

returnSendReceive :: SynthGraph
returnSendReceive = runSynth $ do
  src <- sinOsc 330.0 0.0
  gs  <- gain src 0.25
  busOut 4 gs
  bi  <- busIn 4
  g   <- gain bi 0.75
  out 0 g

fanoutTwoOut :: SynthGraph
fanoutTwoOut = runSynth $ do
  osc <- sinOsc 440.0 0.0
  -- Two consumers of the same osc connection. The §4.B kernel set
  -- requires single-use internal edges, so neither sink-terminal
  -- region nor a fused 3-node kernel can claim either branch.
  g0  <- gain osc 0.3
  g1  <- gain osc 0.4
  out 0 g0
  out 1 g1

------------------------------------------------------------
-- §7.C Add-chain family
------------------------------------------------------------
--
-- Each member places its Add-tail at the source position of an
-- accepted candidate. The pattern is the same across all four:
-- a 'SinOsc' drives the Add-rooted chain to bring the chain up to
-- 'SampleRate', and is also wired to a secondary 'Out' so the
-- planner rejects the Sin-rooted candidate via fanout escape. The
-- Add-rooted chain remains the maximal selected candidate.
--
-- The Sin overhead is constant across all three variants, so the
-- per-variant ratio still reflects the Add-tail's cost. Param
-- inputs on Add live with the candidate's stateless body; they do
-- not change the rate because the wired Sin already lifts Add to
-- 'SampleRate'.

addChainAddOut :: SynthGraph
addChainAddOut = runSynth $ do
  osc <- sinOsc 440.0 0.0
  s   <- add osc (Param 0.3)
  out 0 s
  out 1 osc

addChainAddLpfGainOut :: SynthGraph
addChainAddLpfGainOut = runSynth $ do
  osc <- sinOsc 440.0 0.0
  s   <- add osc (Param 0.3)
  f   <- lpf s 1200.0 0.7
  g   <- gain f 0.5
  out 0 g
  out 1 osc

addChainNestedGainOut :: SynthGraph
addChainNestedGainOut = runSynth $ do
  osc <- sinOsc 440.0 0.0
  s1  <- add osc (Param 0.1)
  s2  <- add s1  (Param 0.2)
  g   <- gain s2 0.5
  out 0 g
  out 1 osc

addChainNestedLpfGainOut :: SynthGraph
addChainNestedLpfGainOut = runSynth $ do
  osc <- sinOsc 440.0 0.0
  s1  <- add osc (Param 0.1)
  s2  <- add s1  (Param 0.2)
  f   <- lpf s2 1200.0 0.7
  g   <- gain f 0.5
  out 0 g
  out 1 osc

------------------------------------------------------------
-- §7.C dynamic-gain family
------------------------------------------------------------
--
-- Each member wires a slow 'SinOsc' (1 Hz) into the gain's amount
-- input so the gain lowers to 'RFrom' on that slot rather than
-- 'RConst'. The modulator is declared before the signal source so
-- it lands earlier in dense order — that keeps the
-- amount-modulator out of the maximal accepted candidate (it lives
-- at a true-interior 'KSinOsc' position, which the planner rejects
-- as stateful-not-on-allow-list).
--
-- The 'dynGainOut' member also needs a fanout on the signal so the
-- 2-length 'KGain → KOut' candidate is the maximal selected one
-- (the 3-length 'src → gain → out' candidate gets rejected on the
-- src fanout). The other two members get a long-enough accepted
-- chain that fanout is unnecessary.

dynGainOut :: SynthGraph
dynGainOut = runSynth $ do
  amt <- sinOsc 1.0 0.0     -- modulator declared first
  src <- sinOsc 440.0 0.0
  y   <- gain src amt
  out 0 y
  out 1 src                  -- forces src fanout to truncate the candidate

dynGainSawOut :: SynthGraph
dynGainSawOut = runSynth $ do
  amt <- sinOsc 1.0 0.0
  saw <- sawOsc 220.0 0.0
  y   <- gain saw amt
  out 0 y

dynGainNestedOut :: SynthGraph
dynGainNestedOut = runSynth $ do
  amt <- sinOsc 1.0 0.0
  src <- sinOsc 440.0 0.0
  y1  <- gain src amt           -- gain 1: dynamic amount
  y2  <- gain y1 (Param 0.5)    -- gain 2: const amount
  out 0 y2

------------------------------------------------------------
-- Variants and features
------------------------------------------------------------

-- | Which runtime path we want measured for this row. The
-- generated-fusion column does not exist yet; if a future slice
-- adds it, append a 'VarGenerated' constructor here, do not
-- repurpose the existing ones.
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
  deriving stock (Eq, Show, Bounded, Enum)

variantName :: Variant -> String
variantName VarNodeLoop     = "node-loop"
variantName VarRegionKernel = "region-kernel"
variantName VarRFused       = "rfused"

-- | The compiler facts we record per graph. The row schema stays
-- deliberately small enough to inspect in JSONL, but it now includes
-- the compiler facts the next cost-model pass needs: resource
-- footprint, declared latency, and consumer-count shape.
data FusionCaseFeatures = FusionCaseFeatures
  { fcfNodeCount        :: !Int
  , fcfRegionCount      :: !Int
  , fcfKernelClaims     :: !Int
    -- ^ How many regions resolved to a non-NodeLoop kernel.
  , fcfRFusedCount      :: !Int
    -- ^ How many regions report 'RFused' membership.
  , fcfSinkCount        :: !Int
    -- ^ Count of 'KOut' / 'KBusOut' nodes — proxy for the
    -- sink-terminal opportunity surface §4.D scans for.
  , fcfBusWrites        :: !Int
  , fcfBusReads         :: !Int
  , fcfBusDelayedReads  :: !Int
  , fcfBufferReads      :: !Int
  , fcfBufferWrites     :: !Int
  , fcfLatencyNodes     :: !Int
  , fcfMaxLatency       :: !Int
  , fcfFanoutNodes      :: !Int
  , fcfMaxConsumerCount :: !Int
  } deriving (Eq, Show)

extractFeatures :: RuntimeGraph -> FusionCaseFeatures
extractFeatures rg =
  let nodes      = rgNodes rg
      regions    = rgRuntimeRegions rg
      kernels    = length [ r | r <- regions, rrKernel r /= RNodeLoop ]
      rfused     = length [ () | n <- nodes
                               , any isRFused (rnInputs n) ]
      sinks      = length [ () | n <- nodes
                               , rnKind n == KOut || rnKind n == KBusOut ]
      resources  = foldr mergeResource emptyResourceFootprint
                         (map rrFootprint regions)
      busFp      = rfBuses resources
      bufFp      = rfBuffers resources
      latencies  = [ lat | n <- nodes, Just lat <- [kindLatency (rnKind n)] ]
      consumers  = map rnConsumerCount nodes
      fanouts    = length [ () | n <- nodes, rnConsumerCount n > 1 ]
  in FusionCaseFeatures
       { fcfNodeCount        = length nodes
       , fcfRegionCount      = length regions
       , fcfKernelClaims     = kernels
       , fcfRFusedCount      = rfused
       , fcfSinkCount        = sinks
       , fcfBusWrites        = S.size (bfWrites busFp)
       , fcfBusReads         = S.size (bfReads busFp)
       , fcfBusDelayedReads  = S.size (bfDelayedReads busFp)
       , fcfBufferReads      = S.size (bfBufReads bufFp)
       , fcfBufferWrites     = S.size (bfBufWrites bufFp)
       , fcfLatencyNodes     = length latencies
       , fcfMaxLatency       = maximumOrZero latencies
       , fcfFanoutNodes      = fanouts
       , fcfMaxConsumerCount = maximumOrZero consumers
       }
  where
    isRFused (RFused _) = True
    isRFused _          = False

    maximumOrZero [] = 0
    maximumOrZero xs = maximum xs

    mergeResource a b =
      ResourceFootprint
        { rfBuses   = mergeBus (rfBuses a) (rfBuses b)
        , rfBuffers = mergeBuffer (rfBuffers a) (rfBuffers b)
        }

    mergeBus a b =
      BusFootprint
        { bfWrites       = bfWrites a       `S.union` bfWrites b
        , bfReads        = bfReads a        `S.union` bfReads b
        , bfDelayedReads = bfDelayedReads a `S.union` bfDelayedReads b
        }

    mergeBuffer a b =
      BufferFootprint
        { bfBufWrites       = bfBufWrites a       `S.union` bfBufWrites b
        , bfBufReads        = bfBufReads a        `S.union` bfBufReads b
        , bfBufDelayedReads = bfBufDelayedReads a `S.union` bfBufDelayedReads b
        }

------------------------------------------------------------
-- Compile / load plumbing for variants
------------------------------------------------------------

-- | Compile a 'SynthGraph' to a 'RuntimeGraph' for the named
-- variant. 'Left' on any compile error — the caller surfaces it
-- as a 'LabRow' with no timing.
compileForVariant :: Variant -> SynthGraph -> Either String RuntimeGraph
compileForVariant variant graph = do
  ir <- lowerGraph graph
  case variant of
    VarNodeLoop     -> stripRegionKernels <$> compileRuntimeGraphUnfused ir
    VarRegionKernel -> compileRuntimeGraph        ir
    VarRFused       -> compileRuntimeGraphFused   ir

loadForVariant :: Variant -> Ptr RTGraph -> RuntimeGraph -> IO ()
loadForVariant VarNodeLoop     rt rg = loadRuntimeGraph      rt rg
loadForVariant VarRegionKernel rt rg = loadRuntimeGraph      rt rg
loadForVariant VarRFused       rt rg = loadRuntimeGraphFused rt rg

stripRegionKernels :: RuntimeGraph -> RuntimeGraph
stripRegionKernels rg = rg
  { rgRuntimeRegions =
      map (\r -> r { rrExec = ExecNodeLoop }) (rgRuntimeRegions rg)
  }

writtenOutputBuses :: RuntimeGraph -> [Int]
writtenOutputBuses rg =
  dedupeSorted . sort . concatMap nodeBuses $ rgNodes rg
  where
    nodeBuses n
      | rnKind n == KOut || rnKind n == KBusOut =
          case rnControls n of
            (raw : _) ->
              let bus = round raw :: Int
              in [bus | isFinite raw && bus >= 0]
            [] -> []
      | otherwise = []

    dedupeSorted [] = []
    dedupeSorted (x : xs) = x : dedupeSorted (dropWhile (== x) xs)

    isFinite x = not (isNaN x || isInfinite x)

------------------------------------------------------------
-- Bench harness
------------------------------------------------------------

kBlockFrames :: Int
kBlockFrames = 256

kWarmupBlocks :: Int
kWarmupBlocks = 4

kTimedBlocks :: Int
kTimedBlocks = 16

kRepeats :: Int
kRepeats = 3

-- | Render one variant, return median ns/sample plus a diagnostic
-- checksum (sum of bus-0 samples across the timed blocks). The
-- checksum is not a substitute for a sample-level comparison; an
-- 'EqExact' result only follows a separate per-sample compare.
data BenchOutcome = BenchOutcome
  { boMedianNsPerSample :: !Double
  , boChecksum          :: !Double
  } deriving (Eq, Show)

benchVariant
  :: BuilderCapacity
  -> RuntimeGraph
  -> Variant
  -> IO BenchOutcome
benchVariant cap rg variant = do
  -- Median of 'kRepeats' separately-loaded handles. Reloading per
  -- repeat is conservative — it kills any across-repeat warm-cache
  -- bias — at the cost of being slower than WorkerBench's reuse-
  -- handle approach. Slice 1 prefers conservative.
  results <- forM [1 .. kRepeats] $ \_ ->
    withRTGraph cap kBlockFrames $ \rt -> do
      loadForVariant variant rt rg
      replicateM_ kWarmupBlocks (c_rt_graph_process rt (fromIntegral kBlockFrames))
      !t0 <- getMonotonicTimeNSec
      !checksum <- runTimedBlocks rt
      !t1 <- getMonotonicTimeNSec
      let !nsTotal     = fromIntegral (t1 - t0) :: Double
          !sampleCount = fromIntegral (kTimedBlocks * kBlockFrames) :: Double
          !nsPerSample = nsTotal / sampleCount
      pure (nsPerSample, checksum)
  let nsValues = sort (map fst results)
      median   = nsValues !! (length nsValues `div` 2)
      checksum = case results of
        ((_, c) : _) -> c
        []           -> 0.0
  pure BenchOutcome
    { boMedianNsPerSample = median
    , boChecksum          = checksum
    }

runTimedBlocks :: Ptr RTGraph -> IO Double
runTimedBlocks rt = go kTimedBlocks 0.0
  where
    go 0 !acc = pure acc
    go n !acc = do
      c_rt_graph_process rt (fromIntegral kBlockFrames)
      s <- readBusSum rt 0
      go (n - 1) (acc + s)

readBusSum :: Ptr RTGraph -> Int -> IO Double
readBusSum rt bus =
  allocaArray kBlockFrames $ \buf -> do
    _ <- c_rt_graph_read_bus rt (fromIntegral bus)
                                (fromIntegral kBlockFrames)
                                (castPtr buf)
    samples <- peekArray kBlockFrames (buf :: Ptr CFloat)
    let !s = sum [realToFrac x | CFloat x <- samples]
    pure s

------------------------------------------------------------
-- Equivalence
------------------------------------------------------------

data EquivalenceStatus
  = EqExact
    -- ^ Variant output is bit-identical to the node-loop baseline.
  | EqMismatch !Int !Double
    -- ^ Variants disagreed. Carries the index of the first
    -- mismatching sample and the absolute difference there for
    -- diagnostics.
  | EqUnchecked
    -- ^ Equivalence skipped — typically because the baseline
    -- itself failed to compile or render.
  deriving (Eq, Show)

eqStatusString :: EquivalenceStatus -> String
eqStatusString EqExact            = "exact"
eqStatusString (EqMismatch _ _)   = "mismatch"
eqStatusString EqUnchecked        = "unchecked"

-- | Render one variant for 'kTimedBlocks' blocks and return the
-- concatenated samples for each observed output bus. Used by the
-- equivalence check; separate from 'benchVariant' so equivalence
-- doesn't pay the median-of-three cost.
renderBuses :: [Int] -> BuilderCapacity -> RuntimeGraph -> Variant -> IO [Float]
renderBuses buses cap rg variant =
  withRTGraph cap kBlockFrames $ \rt -> do
    loadForVariant variant rt rg
    replicateM_ kWarmupBlocks (c_rt_graph_process rt (fromIntegral kBlockFrames))
    blocks <- forM [1 .. kTimedBlocks] $ \_ -> do
      c_rt_graph_process rt (fromIntegral kBlockFrames)
      concat <$> mapM (readBusSamples rt) buses
    pure (concat blocks)
  where
    readBusSamples rt bus =
      allocaArray kBlockFrames $ \buf -> do
        _ <- c_rt_graph_read_bus rt (fromIntegral bus)
                                 (fromIntegral kBlockFrames)
                                 (castPtr buf)
        samples <- peekArray kBlockFrames (buf :: Ptr CFloat)
        pure [ realToFrac x | CFloat x <- samples ]

checkEquivalence :: [Float] -> [Float] -> EquivalenceStatus
checkEquivalence base variant = go 0 base variant
  where
    go _ [] [] = EqExact
    go _ [] _  = EqMismatch (length base) 0.0
    go _ _ []  = EqMismatch (length variant) 0.0
    go !i (x : xs) (y : ys)
      | x == y    = go (i + 1) xs ys
      | otherwise = EqMismatch i (realToFrac (abs (x - y)))

------------------------------------------------------------
-- Rows
------------------------------------------------------------

-- | One JSONL row's worth of measurements. Aggregating happens at
-- print time so a downstream consumer can ingest the rows in any
-- order.
data LabRow = LabRow
  { lrFamily        :: !GraphFamily
  , lrMember        :: !String
  , lrVariant       :: !Variant
  , lrFeatures      :: !(Maybe FusionCaseFeatures)
    -- ^ Nothing when the variant failed to compile.
  , lrNsPerSample   :: !(Maybe Double)
  , lrSpeedupVsBase :: !(Maybe Double)
    -- ^ Filled in for non-baseline variants once the baseline
    -- timing for the same (family, member) is known.
  , lrEquivalence   :: !EquivalenceStatus
  , lrError         :: !(Maybe String)
  } deriving (Eq, Show)

------------------------------------------------------------
-- Lab runner
------------------------------------------------------------

data OutputFormat
  = FormatJSONL
  | FormatSummary
  deriving (Eq, Show)

data FusionCostLabOptions = FusionCostLabOptions
  { fcoFormat   :: !OutputFormat
  , fcoFamilies :: ![GraphFamily]
  } deriving (Eq, Show)

defaultOptions :: FusionCostLabOptions
defaultOptions = FusionCostLabOptions
  { fcoFormat   = FormatJSONL
  , fcoFamilies = [minBound .. maxBound]
  }

runFusionCostLab :: FusionCostLabOptions -> IO ()
runFusionCostLab opts = do
  rows <- collectFusionCostLabRows opts
  case fcoFormat opts of
    FormatJSONL   -> mapM_ (putStrLn . rowToJSONL) rows
    FormatSummary -> renderSummary rows

collectFusionCostLabRows :: FusionCostLabOptions -> IO [LabRow]
collectFusionCostLabRows opts =
  concat <$> mapM runFamily (fcoFamilies opts)

------------------------------------------------------------
-- §7.C cost-model join: shape-keyed cost-lab index
------------------------------------------------------------

-- | Compact key for joining selected candidates to cost-lab rows.
-- 'skKinds' is the 'fromEnum'-encoded 'fcMemberKinds' sequence.
-- 'skGainAmountModes' is the tiny v1 feature axis: one encoded
-- 'GainAmountMode' per 'KGain' member, in member order. This keeps
-- scalar-gain and dynamic-gain chains from sharing measurements.
data ShapeKey = ShapeKey
  { skKinds           :: ![Int]
  , skGainAmountModes :: ![Int]
  } deriving (Eq, Ord, Show)

-- | Per-shape measurement summary keyed by 'shapeKeyOf'. Built once
-- from a @[LabRow]@ corpus by 'costLabShapeIndex' and consumed by the
-- survey to classify selected planner candidates.
--
-- 'ssSpeedup' is @ssBaselineNs / ssFastestNs@. The survey compares it
-- to 'measuredWinThreshold' before calling the row a measured win.
data ShapeSummary = ShapeSummary
  { ssSpeedup        :: !Double
  , ssFastestVariant :: !Variant
  , ssBaselineNs     :: !Double
  , ssFastestNs      :: !Double
  } deriving (Eq, Show)

-- | Minimum speedup before the diagnostic join calls a row a measured
-- win. Tiny >1.0 movements are benchmark noise for this tool; keeping
-- them in measured-loss prevents the 7.D gate from flapping.
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

-- | Build a map from candidate shape key to the best measured
-- speedup. For each cost-lab family member, the function
-- re-compiles the member's 'SynthGraph', runs the planner, and
-- maps each selected candidate's shape key to a 'ShapeSummary'
-- derived from the row's measured ns/sample.
--
-- Pre-conditions for a member to contribute:
--
--   * The 'VarNodeLoop' row has a non-Nothing 'lrNsPerSample'.
--   * At least one non-baseline row ('VarRegionKernel' or
--     'VarRFused') has a non-Nothing 'lrNsPerSample'.
--
-- Members that fail equivalence or compile checks contribute
-- nothing; the corresponding shape remains @needs-benchmark@ from
-- the survey's perspective.
--
-- When two members contribute the same shape key with different
-- speedups, the entry with the larger 'ssSpeedup' wins. This
-- favors the measurement most likely to make a shape look
-- @measured-win@; the join intentionally surfaces the strongest
-- evidence for a shape, not the average.
costLabShapeIndex :: [LabRow] -> M.Map ShapeKey ShapeSummary
costLabShapeIndex rows =
  M.fromListWith preferFaster $ concat
    [ [(k, summ) | k <- shapeKeysOf graph]
    | (fam, name, graph) <- familyGraphs
    , Just summ <- [memberSummary fam name]
    ]
  where
    familyGraphs =
      [ (fam, name, graph)
      | fam <- [minBound .. maxBound :: GraphFamily]
      , FamilyMember name graph <- familyMembers fam
      ]

    memberSummary :: GraphFamily -> String -> Maybe ShapeSummary
    memberSummary fam name =
      let memberRows =
            [ r
            | r <- rows
            , lrFamily r  == fam
            , lrMember r  == name
            , lrError r   == Nothing
            , lrEquivalence r == EqExact
            ]
          baseline =
            [ ns
            | r <- memberRows
            , lrVariant r == VarNodeLoop
            , Just ns <- [lrNsPerSample r]
            ]
          nonBaseline =
            [ (lrVariant r, ns)
            | r <- memberRows
            , lrVariant r /= VarNodeLoop
            , Just ns <- [lrNsPerSample r]
            ]
      in case (baseline, sortOn snd nonBaseline) of
           (bns : _, (variant, fns) : _) ->
             Just ShapeSummary
               { ssSpeedup        = bns / fns
               , ssFastestVariant = variant
               , ssBaselineNs     = bns
               , ssFastestNs      = fns
               }
           _ -> Nothing

    shapeKeysOf graph =
      case lowerGraph graph >>= compileRuntimeGraph of
        Right rg ->
          [ shapeKeyOf c
          | c <- selectedFusionCandidates (planRuntimeGraph rg)
          ]
        Left _ -> []

    preferFaster a b
      | ssSpeedup a >= ssSpeedup b = a
      | otherwise                   = b

runFamily :: GraphFamily -> IO [LabRow]
runFamily fam = concat <$> mapM (runMember fam) (familyMembers fam)

runMember :: GraphFamily -> FamilyMember -> IO [LabRow]
runMember fam (FamilyMember label graph) = do
  -- Compile every variant once up front. Compile failure is
  -- recorded as a row with no timing, never aborts the lab run.
  let variants = [VarNodeLoop, VarRegionKernel, VarRFused]
      compiled =
        [ (v, compileForVariant v graph) | v <- variants ]

  -- Baseline timing first; equivalence and speedup hang off it.
  let baselineCompiled = lookup VarNodeLoop compiled
  case baselineCompiled of
    Just (Right baselineRg) -> do
      baselineOutcome <- benchVariant (graphCapacity baselineRg) baselineRg VarNodeLoop
      let buses = writtenOutputBuses baselineRg
      baselineSamples <- renderBuses buses (graphCapacity baselineRg) baselineRg VarNodeLoop
      let baselineRow = LabRow
            { lrFamily        = fam
            , lrMember        = label
            , lrVariant       = VarNodeLoop
            , lrFeatures      = Just (extractFeatures baselineRg)
            , lrNsPerSample   = Just (boMedianNsPerSample baselineOutcome)
            , lrSpeedupVsBase = Just 1.0
            , lrEquivalence   = EqExact
            , lrError         = Nothing
            }
      otherRows <- forM (filter ((/= VarNodeLoop) . fst) compiled) $ \(v, ev) ->
        case ev of
          Left err -> pure LabRow
            { lrFamily        = fam
            , lrMember        = label
            , lrVariant       = v
            , lrFeatures      = Nothing
            , lrNsPerSample   = Nothing
            , lrSpeedupVsBase = Nothing
            , lrEquivalence   = EqUnchecked
            , lrError         = Just err
            }
          Right rg -> do
            outcome <- benchVariant (graphCapacity rg) rg v
            samples <- renderBuses buses (graphCapacity rg) rg v
            let !speed = boMedianNsPerSample baselineOutcome
                       / boMedianNsPerSample outcome
                !eq    = checkEquivalence baselineSamples samples
            pure LabRow
              { lrFamily        = fam
              , lrMember        = label
              , lrVariant       = v
              , lrFeatures      = Just (extractFeatures rg)
              , lrNsPerSample   = Just (boMedianNsPerSample outcome)
              , lrSpeedupVsBase = Just speed
              , lrEquivalence   = eq
              , lrError         = Nothing
              }
      pure (baselineRow : otherRows)

    Just (Left err) ->
      -- Baseline failed to compile: surface the error on every
      -- variant row so the JSONL stream still has the expected
      -- one-row-per-variant shape.
      pure
        [ LabRow
            { lrFamily        = fam
            , lrMember        = label
            , lrVariant       = v
            , lrFeatures      = Nothing
            , lrNsPerSample   = Nothing
            , lrSpeedupVsBase = Nothing
            , lrEquivalence   = EqUnchecked
            , lrError         = Just err
            }
        | v <- variants
        ]

    Nothing -> pure []  -- unreachable: variants list always contains VarNodeLoop

graphCapacity :: RuntimeGraph -> BuilderCapacity
graphCapacity rg = max 1 (length (rgNodes rg))

------------------------------------------------------------
-- Output
------------------------------------------------------------

-- | Hand-rolled JSONL writer. We deliberately do not pull in
-- Aeson here: the row schema is small, fixed, and the cost of an
-- extra dependency just for a debugging tool is not worth it.
-- Field ordering is stable — downstream consumers may rely on it.
rowToJSONL :: LabRow -> String
rowToJSONL r =
  "{"
  <> intercalate ","
       [ kv "family"   (jsString (familyName (lrFamily r)))
       , kv "member"   (jsString (lrMember r))
       , kv "variant"  (jsString (variantName (lrVariant r)))
       , kv "ns_per_sample" (maybe "null" jsDouble (lrNsPerSample r))
       , kv "speedup"  (maybe "null" jsDouble (lrSpeedupVsBase r))
       , kv "equivalence" (jsString (eqStatusString (lrEquivalence r)))
       , kv "features" (maybe "null" featuresJSON (lrFeatures r))
       , kv "error"    (maybe "null" jsString (lrError r))
       ]
  <> "}"
  where
    kv k v = "\"" <> k <> "\":" <> v

featuresJSON :: FusionCaseFeatures -> String
featuresJSON f =
  "{"
  <> intercalate ","
       [ "\"nodes\":"           <> show (fcfNodeCount f)
       , "\"regions\":"         <> show (fcfRegionCount f)
       , "\"kernel_claims\":"   <> show (fcfKernelClaims f)
       , "\"rfused_consumers\":"<> show (fcfRFusedCount f)
       , "\"sinks\":"           <> show (fcfSinkCount f)
       , "\"bus_writes\":"      <> show (fcfBusWrites f)
       , "\"bus_reads\":"       <> show (fcfBusReads f)
       , "\"bus_delayed_reads\":" <> show (fcfBusDelayedReads f)
       , "\"buffer_reads\":"    <> show (fcfBufferReads f)
       , "\"buffer_writes\":"   <> show (fcfBufferWrites f)
       , "\"latency_nodes\":"   <> show (fcfLatencyNodes f)
       , "\"max_latency\":"     <> show (fcfMaxLatency f)
       , "\"fanout_nodes\":"    <> show (fcfFanoutNodes f)
       , "\"max_consumers\":"   <> show (fcfMaxConsumerCount f)
       ]
  <> "}"

jsString :: String -> String
jsString s = "\"" <> concatMap esc s <> "\""
  where
    esc '"'  = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc c    = [c]

jsDouble :: Double -> String
jsDouble = printf "%.3f"

------------------------------------------------------------
-- Summary mode
------------------------------------------------------------

-- | Per-family table with the median speedup over each
-- non-baseline variant. Intended to be read directly; if you
-- need machine consumption, use the JSONL output instead.
renderSummary :: [LabRow] -> IO ()
renderSummary rows = do
  putStrLn "family/member/variant    ns/sample   speedup   equiv     features"
  putStrLn "------------------------------------------------------------------"
  forM_ rows $ \r ->
    printf "%-25s %10s  %7s   %-9s %s\n"
      (familyName (lrFamily r) <> "/" <> lrMember r
         <> "/" <> variantName (lrVariant r))
      (maybe "n/a" (printf "%.3f") (lrNsPerSample r))
      (maybe "n/a" (printf "%.2fx") (lrSpeedupVsBase r))
      (eqStatusString (lrEquivalence r))
      (maybe "" featuresSummary (lrFeatures r))
  putStrLn ""
  putStrLn $ "Total rows: " <> show (length rows)
  where
    featuresSummary f =
      "nodes=" <> show (fcfNodeCount f)
      <> " regions=" <> show (fcfRegionCount f)
      <> " kernels=" <> show (fcfKernelClaims f)
      <> " rfused=" <> show (fcfRFusedCount f)
      <> " fanout=" <> show (fcfFanoutNodes f)
      <> " maxc=" <> show (fcfMaxConsumerCount f)
      <> " busW/R=" <> show (fcfBusWrites f)
      <> "/" <> show (fcfBusReads f)
      <> " bufW/R=" <> show (fcfBufferWrites f)
      <> "/" <> show (fcfBufferReads f)
      <> " lat=" <> show (fcfMaxLatency f)
