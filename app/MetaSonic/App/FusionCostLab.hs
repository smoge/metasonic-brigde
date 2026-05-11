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
  ) where

import           Control.Monad              (forM, forM_, replicateM_)
import           Data.List                  (intercalate, sort)
import qualified Data.Set                   as S
import           Foreign                    (allocaArray, castPtr, peekArray)
import           Foreign.C.Types            (CFloat (..))
import           Foreign.Ptr                (Ptr)
import           GHC.Clock                  (getMonotonicTimeNSec)
import           Text.Printf                (printf)

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR        (lowerGraph)
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
  deriving stock (Eq, Show, Bounded, Enum)

familyName :: GraphFamily -> String
familyName FamilySinkChain  = "sink-chain"
familyName FamilyReturnTail = "return-tail"
familyName FamilyFanout     = "fanout"
familyName FamilyCorpus     = "corpus"

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
      map (\r -> r { rrKernel = RNodeLoop }) (rgRuntimeRegions rg)
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
  rows <- concat <$> mapM runFamily (fcoFamilies opts)
  case fcoFormat opts of
    FormatJSONL   -> mapM_ (putStrLn . rowToJSONL) rows
    FormatSummary -> renderSummary rows

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
