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
-- Original slice 1 out-of-scope items still parked: CSV output,
-- parametric size sweeps beyond a fixed small set, multi-instance /
-- multi-template benchmarks, and the profitability-recommendation
-- labels themselves. Phase 7.D added the generated-fusion variant as
-- a measured path; the lab still prints speedups so a human can read
-- them before later slices turn rows into /Fuse/ // /DoNotFuse/ //
-- /NeedsBenchmark/ decisions.
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
    -- * Phase 7.F profitability gate index
  , GateMeasurement (..)
  , costLabGateIndex
    -- * Phase 7.G diagnostic helpers
  , generatedTailSweepOwnedLengths
    -- * Phase 7.I super-mode classifier
  , FusionSuperKind (..)
  , classifyFusionSuper
  , generatedSuperKindFor
  , generatedSuperKindIndex
  ) where

import           Control.Monad              (forM, forM_, replicateM_)
import           Data.List                  (intercalate, isInfixOf, sort,
                                             sortOn)
import qualified Data.Map.Strict            as M
import           Data.Maybe                 (catMaybes, isNothing, mapMaybe)
import qualified Data.Set                   as S
import           Foreign                    (allocaArray, castPtr, peekArray)
import           Foreign.C.Types            (CFloat (..))
import           Foreign.Ptr                (Ptr)
import           GHC.Clock                  (getMonotonicTimeNSec)
import           System.IO                  (Handle, hFlush, hPutStrLn, stderr,
                                             stdout)
import           Text.Printf                (printf)

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.Compile.Dependencies
                                            (regionResourceFootprint)
import           MetaSonic.Bridge.Compile.FusionProgram
                                            (FusionOp (..),
                                             FusionProgram (..),
                                             FusionProgramId (..),
                                             FusionSource (..),
                                             ScratchIndex (..),
                                             SinkPolicy (..))
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR        (lowerGraph)
import           MetaSonic.Bridge.Planner   (FusionCandidate (..),
                                             GainAmountMode (..),
                                             planRuntimeGraph,
                                             selectedFusionCandidates)
import           MetaSonic.Bridge.Source
import qualified MetaSonic.App.Demos        as Demos
import qualified MetaSonic.Pattern.Corpus   as Corpus

import           MetaSonic.Types            (NodeIndex, NodeKind (..),
                                             kindLatency)


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
  | FamilyGeneratedTailSweep
    -- ^ Phase 7.G synthetic family. Each member feeds one
    -- @pulseOsc@ prefix (not §4.B-covered) into a contiguous
    -- @KGain@ / @KAdd@ tail of increasing length and terminates
    -- in @KOut@. The point is to bracket the interpreter's
    -- per-op amortization curve: as the owned tail grows, do
    -- generated speedups vs node-loop trend upward? The members
    -- intentionally use a single stateful source so the prefix
    -- cost stays constant; the only thing that changes between
    -- rows is how much arithmetic the generated path owns.
  deriving stock (Eq, Show, Bounded, Enum)

familyName :: GraphFamily -> String
familyName FamilySinkChain   = "sink-chain"
familyName FamilyReturnTail  = "return-tail"
familyName FamilyFanout      = "fanout"
familyName FamilyCorpus      = "corpus"
familyName FamilyAddChain    = "add-chain"
familyName FamilyDynamicGain = "dynamic-gain"
familyName FamilyGeneratedTailSweep = "generated-tail-sweep"

-- | One member of a family. The string label is the row's stable
-- identity in JSONL output — keep it short and shell-grep-friendly.
data FamilyMember = FamilyMember !String !SynthGraph

familyMembers :: GraphFamily -> [FamilyMember]
familyMembers FamilySinkChain =
  [ FamilyMember "sin-gain-out"          sinkSinGainOut
  , FamilyMember "saw-gain-out"          sinkSawGainOut
  , FamilyMember "saw-lpf-gain-out"      sinkSawLpfGainOut
  , FamilyMember "busin-lpf-gain-out"    sinkBusInLpfGainOut
  , FamilyMember "pulse-gain-out"        sinkPulseGainOut
  , FamilyMember "tri-lpf-gain-out"      sinkTriLpfGainOut
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
familyMembers FamilyGeneratedTailSweep =
  [ FamilyMember "tail-2-gain"        tailSweep2Gain
  , FamilyMember "tail-3-gain-gain"   tailSweep3GainGain
  , FamilyMember "tail-3-add-gain"    tailSweep3AddGain
  , FamilyMember "tail-5-mixed"       tailSweep5Mixed
  , FamilyMember "tail-8-mixed"       tailSweep8Mixed
  , FamilyMember "tail-16-mixed"      tailSweep16Mixed
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

-- | Phase 7.E first source-prefix probe. Pulse oscillator into the
-- canonical @Gain -> Out@ tail. The generator owns only
-- @[KGain, KOut]@; @KPulseOsc@ (stateful source) stays as
-- node-loop work in the host region's pre-slice.
sinkPulseGainOut :: SynthGraph
sinkPulseGainOut = runSynth $ do
  osc <- pulseOsc 110.0 0.0 0.5
  g   <- gain osc 0.4
  out 0 g

-- | Phase 7.E second source-prefix probe. Triangle oscillator
-- through a low-pass into the canonical @Gain -> Out@ tail. The
-- generator owns only @[KGain, KOut]@; @KTriOsc@ and @KLPF@ both
-- stay as node-loop work in the host region's pre-slice, which
-- exercises a multi-node prefix instead of a single-source one.
sinkTriLpfGainOut :: SynthGraph
sinkTriLpfGainOut = runSynth $ do
  osc <- triOsc 220.0 0.0
  f   <- lpf osc 1200.0 0.7
  g   <- gain f 0.4
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
-- §7.G generated-tail-sweep family
------------------------------------------------------------
--
-- Each member feeds one 'pulseOsc' prefix into a stateless
-- compute tail of increasing length. PulseOsc is intentional:
-- 'KPulseOsc → KGain → KOut' is not §4.B-covered, so the
-- planner-selected candidate's matched-shape stays 'Nothing'
-- and the gate cannot short-circuit to 'CoveredByHandKernel'.
-- The owned tail (everything from the first compute node up to
-- and including the sink) is what the generator emits; the
-- single pulseOsc stays in the host region's pre-slice as
-- node-loop work.
--
-- 'add' nodes consume @(prev, Param k)@ so the planner sees a
-- signal-rate input (the prev node) plus a constant on the
-- second slot — same pattern @FamilyAddChain@ uses.

tailSweep2Gain :: SynthGraph
tailSweep2Gain = runSynth $ do
  src <- pulseOsc 110.0 0.0 0.5
  g   <- gain src 0.5
  out 0 g

tailSweep3GainGain :: SynthGraph
tailSweep3GainGain = runSynth $ do
  src <- pulseOsc 110.0 0.0 0.5
  g1  <- gain src 0.5
  g2  <- gain g1  0.7
  out 0 g2

tailSweep3AddGain :: SynthGraph
tailSweep3AddGain = runSynth $ do
  src <- pulseOsc 110.0 0.0 0.5
  s1  <- add src (Param 0.3)
  g1  <- gain s1 0.5
  out 0 g1

tailSweep5Mixed :: SynthGraph
tailSweep5Mixed = runSynth $ do
  src <- pulseOsc 110.0 0.0 0.5
  s1  <- add src (Param 0.1); g1 <- gain s1 0.5
  s2  <- add g1  (Param 0.2); g2 <- gain s2 0.7
  out 0 g2

tailSweep8Mixed :: SynthGraph
tailSweep8Mixed = runSynth $ do
  src <- pulseOsc 110.0 0.0 0.5
  s1  <- add src (Param 0.1); g1 <- gain s1 0.5
  s2  <- add g1  (Param 0.2); g2 <- gain s2 0.6
  s3  <- add g2  (Param 0.3); g3 <- gain s3 0.7
  g4  <- gain g3 0.8
  out 0 g4

tailSweep16Mixed :: SynthGraph
tailSweep16Mixed = runSynth $ do
  src <- pulseOsc 110.0 0.0 0.5
  s1  <- add src (Param 0.1); g1 <- gain s1 0.5
  s2  <- add g1  (Param 0.2); g2 <- gain s2 0.5
  s3  <- add g2  (Param 0.3); g3 <- gain s3 0.5
  s4  <- add g3  (Param 0.4); g4 <- gain s4 0.5
  s5  <- add g4  (Param 0.5); g5 <- gain s5 0.5
  s6  <- add g5  (Param 0.6); g6 <- gain s6 0.5
  s7  <- add g6  (Param 0.7); g7 <- gain s7 0.5
  g8  <- gain g7 0.5
  out 0 g8

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
    VarGenerated    -> do
      baseRG <- stripRegionKernels <$> compileRuntimeGraphUnfused ir
      generateForCostLab baseRG
    VarGeneratedBlock -> do
      baseRG <- stripRegionKernels <$> compileRuntimeGraphUnfused ir
      retargetGeneratedAsBlock <$> generateForCostLab baseRG
    VarGeneratedSuper -> do
      baseRG <- stripRegionKernels <$> compileRuntimeGraphUnfused ir
      retargetGeneratedAsSuper <$> generateForCostLab baseRG

loadForVariant :: Variant -> Ptr RTGraph -> RuntimeGraph -> IO ()
loadForVariant VarNodeLoop       rt rg = loadRuntimeGraph      rt rg
loadForVariant VarRegionKernel   rt rg = loadRuntimeGraph      rt rg
loadForVariant VarRFused         rt rg = loadRuntimeGraphFused rt rg
loadForVariant VarGenerated      rt rg = loadRuntimeGraph      rt rg
loadForVariant VarGeneratedBlock rt rg = loadRuntimeGraph      rt rg
loadForVariant VarGeneratedSuper rt rg = loadRuntimeGraph      rt rg

-- §7.H: take a graph patched for the sample-major generated
-- variant and retarget every 'ExecGenerated' region at the
-- block-major executor. The program data, owned slice, and
-- region split are identical to the sample-major build — only
-- the dispatch selector changes.
retargetGeneratedAsBlock :: RuntimeGraph -> RuntimeGraph
retargetGeneratedAsBlock rg = rg
  { rgRuntimeRegions =
      map flipExec (rgRuntimeRegions rg)
  }
  where
    flipExec r = case rrExec r of
      ExecGenerated pid -> r { rrExec = ExecGeneratedBlock pid }
      _                 -> r

-- §7.I: take a graph patched for the sample-major generated
-- variant and retarget every 'ExecGenerated' region at the
-- super-mode executor. The program data, owned slice, and
-- region split are identical to the sample-major build — only
-- the dispatch selector changes. The C++ side then recognizes
-- 'GainOut' / 'AddGainOut' programs and falls back to the
-- block-major executor for unrecognized ones.
retargetGeneratedAsSuper :: RuntimeGraph -> RuntimeGraph
retargetGeneratedAsSuper rg = rg
  { rgRuntimeRegions =
      map flipExec (rgRuntimeRegions rg)
  }
  where
    flipExec r = case rrExec r of
      ExecGenerated pid -> r { rrExec = ExecGeneratedSuper pid }
      _                 -> r

stripRegionKernels :: RuntimeGraph -> RuntimeGraph
stripRegionKernels rg = rg
  { rgRuntimeRegions =
      map (\r -> r { rrExec = ExecNodeLoop }) (rgRuntimeRegions rg)
  }

------------------------------------------------------------
-- §7.D step 8: generator + region patcher for VarGenerated
------------------------------------------------------------

-- | Wire a 'RuntimeGraph' for the generated cost-lab variant.
-- Picks the first selected planner candidate this slice's
-- generator handles, emits a 'FusionProgram' plus the suffix of
-- the candidate the program owns, and patches the graph so the
-- host region splits into
-- @[pre (NodeLoop), owned-suffix (ExecGenerated), post (NodeLoop)]@.
-- The unowned prefix of the candidate (Phase 7.E: stateful
-- sources, filters) ends up inside @pre@ and continues to run as
-- node-loop. The patched graph runs through 'loadRuntimeGraph'
-- identically to the other variants — the only difference is one
-- region dispatches through the tiny C++ interpreter.
generateForCostLab :: RuntimeGraph -> Either String RuntimeGraph
generateForCostLab rg =
  let verdicts = planRuntimeGraph rg
      eligible =
        [ (c, prog, owned)
        | c <- selectedFusionCandidates verdicts
          -- 'fcMatchedShape == Nothing' = generated-eligible; a
          -- §4.B-covered shape has a hand-written kernel already
          -- and is not the cost-lab's target for the generated
          -- column.
        , isNothing (fcMatchedShape c)
        , Right (prog, owned) <- [generateProgram rg c]
        ]
  in case eligible of
       []                  -> Left "generated: no shape this slice can emit a program for"
       (_, prog, owned) :_ -> patchForGenerated rg owned prog

-- | v1 program generator. Returns both the emitted 'FusionProgram'
-- and the contiguous suffix of @fcMembers@ the program owns. The
-- prefix (@fcMembers@ minus the owned suffix) continues to render
-- as node-loop inside the host region's pre-slice.
--
-- Phase 7.G generalizes the generator from the fixed
-- @[KGain, KOut]@ / @[KGain, KBusOut]@ shape to any maximal
-- trailing run of stateless compute nodes (@KGain@, @KAdd@)
-- followed by a sink (@KOut@ / @KBusOut@). Each owned non-sink
-- node maps to one scratch slot; inputs from owned siblings
-- become 'SrcScratch', other inputs stay 'SrcInput' / 'SrcConst'.
-- The v1 op set ('OpAdd', 'OpMul', 'OpSinkWrite') stays frozen.
generateProgram
  :: RuntimeGraph
  -> FusionCandidate
  -> Either String (FusionProgram, [NodeIndex])
generateProgram rg c =
  case ownedTailOfCandidate c of
    Nothing    -> Left "generated: candidate has no eligible owned tail"
    Just owned -> do
      prog <- emitTailProgram rg owned
      Right (prog, owned)

-- | Return the maximal contiguous suffix of @fcMembers@ that the
-- generator can own under the v1 op set: a sink ('KOut' or
-- 'KBusOut') preceded by a (possibly empty) run of stateless
-- compute nodes ('KGain' / 'KAdd'). Returns 'Nothing' if the
-- candidate has no sink, or if the only owned slice would be
-- the sink alone with no compute (length-1 suffixes are not
-- worth emitting — see 'PreferExisting' path in the gate).
ownedTailOfCandidate :: FusionCandidate -> Maybe [NodeIndex]
ownedTailOfCandidate c =
  case reverse (zip (fcMembers c) (fcMemberKinds c)) of
    ((sinkIx, sinkKind) : rest)
      | sinkKind == KOut || sinkKind == KBusOut ->
          let compute = takeWhile (statelessCompute . snd) rest
          in if null compute
               then Nothing
               else Just (reverse (map fst compute) ++ [sinkIx])
    _ -> Nothing
  where
    statelessCompute KGain = True
    statelessCompute KAdd  = True
    statelessCompute _     = False

-- | Emit a 'FusionProgram' for an owned-tail slice. The last
-- 'NodeIndex' must be the sink; earlier indices are the
-- contiguous compute nodes feeding it. Each compute node gets
-- one scratch slot in emission order; the sink op reads from
-- the slot of whichever owned node feeds it (or directly from
-- 'SrcInput' / 'SrcConst' when the sink's input is external).
emitTailProgram
  :: RuntimeGraph
  -> [NodeIndex]
  -> Either String FusionProgram
emitTailProgram _  []    = Left "generated: empty owned slice"
emitTailProgram rg owned =
  let nonSink = init owned
      sinkIx  = last owned
      slotMap = M.fromList (zip nonSink (map ScratchIndex [0 ..]))
  in do
    computeOps <- mapM (emitComputeOp rg slotMap) nonSink
    sinkOp     <- emitSinkOp rg slotMap sinkIx
    Right FusionProgram
      { fpOps          = computeOps ++ [sinkOp]
      , fpScratchSlots = length nonSink
      }

emitComputeOp
  :: RuntimeGraph
  -> M.Map NodeIndex ScratchIndex
  -> NodeIndex
  -> Either String FusionOp
emitComputeOp rg slotMap nodeIx = do
  node <- lookupRtNode rg nodeIx
  let slot = slotMap M.! nodeIx
  case (rnKind node, rnInputs node) of
    (KGain, [sigIn, amtIn]) -> do
      signal <- inputAsSource slotMap sigIn
      amount <- inputAsSource slotMap amtIn
      Right (OpMul slot signal amount)
    (KGain, _) ->
      Left "generated: gain node has unexpected input arity"
    (KAdd,  [lhsIn, rhsIn]) -> do
      left  <- inputAsSource slotMap lhsIn
      right <- inputAsSource slotMap rhsIn
      Right (OpAdd slot left right)
    (KAdd, _) ->
      Left "generated: add node has unexpected input arity"
    (other, _) ->
      Left ("generated: unsupported kind in owned tail: " <> show other)

emitSinkOp
  :: RuntimeGraph
  -> M.Map NodeIndex ScratchIndex
  -> NodeIndex
  -> Either String FusionOp
emitSinkOp rg slotMap sinkIx = do
  sinkNode <- lookupRtNode rg sinkIx
  bus      <- busFromControls (rnControls sinkNode)
  case rnInputs sinkNode of
    [sigIn] -> do
      signal <- inputAsSource slotMap sigIn
      Right (OpSinkWrite bus signal SinkAccumulate)
    _ -> Left "generated: sink node has unexpected input arity"

lookupRtNode :: RuntimeGraph -> NodeIndex -> Either String RuntimeNode
lookupRtNode rg ix =
  case [n | n <- rgNodes rg, rnIndex n == ix] of
    (n : _) -> Right n
    []      -> Left "generated: dangling NodeIndex in candidate"

-- | Map a 'RuntimeInput' to a 'FusionSource', routing references
-- to owned-tail siblings through their scratch slot and leaving
-- external references as 'SrcInput' / 'SrcConst'.
inputAsSource
  :: M.Map NodeIndex ScratchIndex
  -> RuntimeInput
  -> Either String FusionSource
inputAsSource slotMap (RFrom n p) =
  case M.lookup n slotMap of
    Just s  -> Right (SrcScratch s)
    Nothing -> Right (SrcInput n p)
inputAsSource _ (RConst v) = Right (SrcConst v)
inputAsSource _ (RFused _) =
  Left "generated: RFused inputs not supported"

busFromControls :: [Double] -> Either String Int
busFromControls (b : _) = Right (truncate b)
busFromControls []      = Left "generated: Out has no bus control"

-- | Split the host region around the generator's owned suffix and
-- attach the program. The owned slice must be a contiguous range
-- of the host region's member list (dense-order property the
-- planner enforces for candidates; the suffix inherits it because
-- the candidate itself was contiguous). The unowned prefix of the
-- candidate falls into the @pre@ node-loop slice automatically.
patchForGenerated
  :: RuntimeGraph
  -> [NodeIndex]
  -> FusionProgram
  -> Either String RuntimeGraph
patchForGenerated rg owned prog =
  let regions   = rgRuntimeRegions rg
      hostsCand r = any (`elem` rrNodes r) owned
  in case break hostsCand regions of
       (_, []) -> Left "generated: owned slice's region not found"
       (regsPre, region : regsPost) -> do
         (mPre, candRegion, mPost) <- splitRegion rg region owned
         let split      = catMaybes [mPre, Just candRegion, mPost]
             allRegions = regsPre <> split <> regsPost
             renumbered =
               [ r { rrIndex = RegionIndex i }
               | (i, r) <- zip [0 ..] allRegions
               ]
         Right rg
           { rgRuntimeRegions = renumbered
           , rgFusionPrograms = [prog]
           }

splitRegion
  :: RuntimeGraph
  -> RuntimeRegion
  -> [NodeIndex]
  -> Either String
       ( Maybe RuntimeRegion
       , RuntimeRegion
       , Maybe RuntimeRegion
       )
splitRegion rg region owned =
  let members = rrNodes region
      pre     = takeWhile (`notElem` owned) members
      rest    = drop (length pre) members
      cand    = take (length owned) rest
      post    = drop (length owned) rest
      nodeMap = M.fromList [(rnIndex n, n) | n <- rgNodes rg]
      mkRegion nodes ex = RuntimeRegion
        { rrIndex     = RegionIndex 0  -- renumbered by caller
        , rrRate      = rrRate region
        , rrNodes     = nodes
        , rrExec      = ex
        , rrFootprint = regionResourceFootprint nodeMap nodes
        }
  in if cand /= owned
       then Left "generated: owned slice not contiguous within its region"
       else
         Right
           ( if null pre  then Nothing else Just (mkRegion pre  ExecNodeLoop)
           , mkRegion cand (ExecGenerated (FusionProgramId 0))
           , if null post then Nothing else Just (mkRegion post ExecNodeLoop)
           )

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
    FormatJSONL -> do
      mapM_ (putStrLn . rowToJSONL) rows
      -- Keep machine-readable stdout clean for JSONL consumers.
      hFlush stdout
      renderGeneratedDiagnostics stderr rows
    FormatSummary -> do
      renderSummary rows
      -- Summary mode is human-readable stdout; print diagnostics on
      -- the same stream so captured output stays ordered.
      renderGeneratedDiagnostics stdout rows

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

    preferFaster a b
      | ssSpeedup a >= ssSpeedup b = a
      | otherwise                   = b

-- | Re-compile a cost-lab member graph and list the shape keys
-- the planner would select on its runtime form. Shared between
-- 'costLabShapeIndex' and 'costLabGateIndex'; both keys join
-- cost-lab measurements to selected-candidate shape keys.
shapeKeysOf :: SynthGraph -> [ShapeKey]
shapeKeysOf graph =
  case lowerGraph graph >>= compileRuntimeGraph of
    Right rg ->
      [ shapeKeyOf c
      | c <- selectedFusionCandidates (planRuntimeGraph rg)
      ]
    Left _ -> []

------------------------------------------------------------
-- Phase 7.F profitability-gate index
------------------------------------------------------------

-- | Per-shape cost-lab measurement view tailored for the
-- read-only profitability gate. Carries the four facts the
-- gate's rules need to decide a verdict:
--
--   * 'gmGeneratorError' — decline/error bucket for the
--     @VarGenerated@ row (Just _) or 'Nothing' if the generator
--     emitted a program and the row produced a timing.
--   * 'gmGeneratedExact' — True iff the emitted program matched
--     'RNodeLoop' bit-for-bit. Only meaningful when
--     'gmGeneratorError' is 'Nothing'.
--   * 'gmGeneratedSpeedup' — @VarGenerated@ speedup vs node-loop
--     for the strongest member contributing this shape key.
--   * 'gmBestPeerSpeedup' — best of @VarRegionKernel@ and
--     @VarRFused@ for the same member, so the gate can compare
--     generated against the strongest existing path.
--
-- When two cost-lab members produce the same shape key, the
-- member with the larger generated speedup wins. This mirrors the
-- 'costLabShapeIndex' convention: the index surfaces the
-- strongest evidence for a shape, not the average. The gate then
-- decides whether that strongest evidence is actually good
-- enough.
data GateMeasurement = GateMeasurement
  { gmGeneratorError   :: !(Maybe String)
  , gmGeneratedExact   :: !Bool
  , gmGeneratedSpeedup :: !(Maybe Double)
  , gmBestPeerSpeedup  :: !(Maybe Double)
  } deriving (Eq, Show)

-- | Build a 'ShapeKey' -> 'GateMeasurement' map by re-deriving
-- selected shape keys for each cost-lab member graph (identical
-- machinery to 'costLabShapeIndex') and joining them with that
-- member's per-variant 'LabRow' set.
--
-- The contributing-row predicate is intentionally lax: a member
-- contributes even when its @VarGenerated@ row failed (declined
-- or non-exact). The gate's 'Unsupported' / 'NonExact' verdicts
-- depend on that signal being visible.
--
-- Generated timings attach only to the owned suffix shape the
-- generator actually emitted. Other selected shapes from the same
-- member retain peer measurements, but do not borrow the generated
-- speedup from a sibling/suffix program.
costLabGateIndex :: [LabRow] -> M.Map ShapeKey GateMeasurement
costLabGateIndex rows =
  M.fromListWith preferStrongerGenerated $ concat
    [ memberGateEntries fam name graph
    | (fam, name, graph) <- familyGraphs
    ]
  where
    familyGraphs =
      [ (fam, name, graph)
      | fam <- [minBound .. maxBound :: GraphFamily]
      , FamilyMember name graph <- familyMembers fam
      ]

    memberGateEntries
      :: GraphFamily -> String -> SynthGraph -> [(ShapeKey, GateMeasurement)]
    memberGateEntries fam name graph =
      case memberMeasurement fam name of
        Nothing -> []
        Just gm
          | Just _ <- gmGeneratorError gm ->
              [(k, gm) | k <- shapeKeysOf graph]
          | otherwise ->
              let selectedEntries =
                    [ (k, peerOnlyMeasurement gm)
                    | k <- shapeKeysOf graph
                    ]
                  generatedEntries =
                    [ (k, gm)
                    | Just k <- [generatedOwnedShapeKeyOf graph]
                    ]
              in selectedEntries <> generatedEntries

    memberMeasurement :: GraphFamily -> String -> Maybe GateMeasurement
    memberMeasurement fam name =
      let memberRows =
            [ r | r <- rows, lrFamily r == fam, lrMember r == name ]
          baselineNs =
            listToMaybe
              [ ns
              | r <- memberRows
              , lrVariant r == VarNodeLoop
              , Just ns <- [lrNsPerSample r]
              ]
          generatedRow =
            listToMaybe [ r | r <- memberRows, lrVariant r == VarGenerated ]
          speedupVs base ns = base / ns
          peerSpeedup base =
            case [ s
                 | r <- memberRows
                 , lrVariant r `elem` [VarRegionKernel, VarRFused]
                 , lrError r == Nothing
                 , lrEquivalence r == EqExact
                 , Just ns <- [lrNsPerSample r]
                 , let s = speedupVs base ns
                 ] of
              [] -> Nothing
              xs -> Just (maximum xs)
      in case (baselineNs, generatedRow) of
           (Just base, Just gen) ->
             Just GateMeasurement
               { gmGeneratorError =
                   case lrError gen of
                     Just e  -> Just e
                     Nothing -> Nothing
               , gmGeneratedExact =
                   lrError gen == Nothing
                     && lrEquivalence gen == EqExact
               , gmGeneratedSpeedup =
                   case (lrError gen, lrNsPerSample gen) of
                     (Nothing, Just ns) -> Just (speedupVs base ns)
                     _                  -> Nothing
               , gmBestPeerSpeedup = peerSpeedup base
               }
           _ -> Nothing

    preferStrongerGenerated a b
      | rank a >= rank b = a
      | otherwise        = b
      where
        rank gm = case gmGeneratedSpeedup gm of
          Just s  -> (2 :: Int, s)
          Nothing -> case gmGeneratorError gm of
            Just _  -> (1, 0)
            Nothing -> (0, 0)

    peerOnlyMeasurement gm = GateMeasurement
      { gmGeneratorError   = Nothing
      , gmGeneratedExact   = True
      , gmGeneratedSpeedup = Nothing
      , gmBestPeerSpeedup  = gmBestPeerSpeedup gm
      }

    listToMaybe (x:_) = Just x
    listToMaybe []    = Nothing

-- | Reconstruct the generated variant's chosen owned suffix for a
-- cost-lab member and encode that suffix as a 'ShapeKey'. This
-- mirrors 'generateForCostLab': plan on the stripped node-loop
-- graph, pick the first generator-supported selected candidate,
-- then use the returned owned node slice rather than the whole
-- selected candidate.
generatedOwnedShapeKeyOf :: SynthGraph -> Maybe ShapeKey
generatedOwnedShapeKeyOf graph = do
  rg <- case lowerGraph graph >>= compileRuntimeGraphUnfused of
          Right base -> Just (stripRegionKernels base)
          Left _     -> Nothing
  let eligibleOwned =
        [ owned
        | c <- selectedFusionCandidates (planRuntimeGraph rg)
        , isNothing (fcMatchedShape c)
        , Right (_, owned) <- [generateProgram rg c]
        ]
  case eligibleOwned of
    (owned : _) ->
      case shapeKeyForOwned rg owned of
        Right key -> Just key
        Left _    -> Nothing
    [] -> Nothing

-- | Number of nodes the generator would own on the first
-- eligible candidate inside @graph@ — i.e. the per-sample op
-- count the generated path would execute. Used by the §7.G
-- owned-size diagnostic to bucket cost-lab rows by tail length.
generatedOwnedTailLength :: SynthGraph -> Maybe Int
generatedOwnedTailLength graph = do
  rg <- case lowerGraph graph >>= compileRuntimeGraphUnfused of
          Right base -> Just (stripRegionKernels base)
          Left _     -> Nothing
  let eligibleOwned =
        [ owned
        | c <- selectedFusionCandidates (planRuntimeGraph rg)
        , isNothing (fcMatchedShape c)
        , Right (_, owned) <- [generateProgram rg c]
        ]
  case eligibleOwned of
    (owned : _) -> Just (length owned)
    []          -> Nothing

-- | Structural owned-tail lengths for the synthetic §7.G family.
-- Exported for snapshot only; timing remains intentionally unpinned.
generatedTailSweepOwnedLengths :: [Int]
generatedTailSweepOwnedLengths =
  sort
    [ sz
    | FamilyMember _ graph <- familyMembers FamilyGeneratedTailSweep
    , Just sz <- [generatedOwnedTailLength graph]
    ]

-- | Phase 7.I super-mode recognizer classification. The Haskell
-- side classifier mirrors the C++ 'classify_fusion_super' in
-- @rt_graph.cpp@: pure structural inspection of the op sequence
-- and tagged operands, never an execution. The bit-exact
-- equivalence test pins the two implementations together; the
-- enum below decides recognized vs fallback counts at snapshot
-- time without polling any runtime counter.
data FusionSuperKind
  = FusionSuperNotRecognized
    -- ^ Super-mode would fall through to the block-major executor.
  | FusionSuperGainOut
    -- ^ Two-op program: @OpMul s0 a b ; OpSinkWrite bus (SrcScratch s0)@.
  | FusionSuperAddGainOut
    -- ^ Three-op program: @OpAdd s0 a b ; OpMul s1 (SrcScratch s0) c ;@
    --   @OpSinkWrite bus (SrcScratch s1)@.
  deriving (Eq, Show, Bounded, Enum)

-- | Classify a 'FusionProgram' against the v1 super-mode
-- recognizer set. Programs that don't match any recognized
-- shape return 'FusionSuperNotRecognized'.
classifyFusionSuper :: FusionProgram -> FusionSuperKind
classifyFusionSuper prog = case fpOps prog of
  -- GainOut: [OpMul s0 _ _, OpSinkWrite _ (SrcScratch s0) _]
  [ OpMul (ScratchIndex 0) _ _
   , OpSinkWrite _ (SrcScratch (ScratchIndex 0)) _
   ] | fpScratchSlots prog == 1 -> FusionSuperGainOut

  -- AddGainOut: [OpAdd s0 _ _, OpMul s1 (SrcScratch s0) _,
  --              OpSinkWrite _ (SrcScratch s1) _]
  [ OpAdd (ScratchIndex 0) _ _
   , OpMul (ScratchIndex 1) (SrcScratch (ScratchIndex 0)) _
   , OpSinkWrite _ (SrcScratch (ScratchIndex 1)) _
   ] | fpScratchSlots prog == 2 -> FusionSuperAddGainOut

  _ -> FusionSuperNotRecognized

-- | Classify the generator's first eligible candidate for the
-- given source graph. 'Nothing' for graphs the generator
-- declines (no eligible candidate, compile failure, etc.); the
-- same condition under which 'generatedOwnedTailLength' returns
-- 'Nothing'.
generatedSuperKindFor :: SynthGraph -> Maybe FusionSuperKind
generatedSuperKindFor graph = do
  rg <- case lowerGraph graph >>= compileRuntimeGraphUnfused of
          Right base -> Just (stripRegionKernels base)
          Left _     -> Nothing
  let emitted =
        [ prog
        | c <- selectedFusionCandidates (planRuntimeGraph rg)
        , isNothing (fcMatchedShape c)
        , Right (prog, _owned) <- [generateProgram rg c]
        ]
  case emitted of
    (prog : _) -> Just (classifyFusionSuper prog)
    []         -> Nothing

-- | @(familyName, member) -> FusionSuperKind@ for every
-- cost-lab member whose graph the generator emits a program for.
-- Built once over the full corpus. Used by the cost-lab
-- diagnostics block to print recognized vs fallback counts, and
-- by [SnapshotCheck.hs] to pin those counts structurally.
-- Members the generator declines are absent from the map; that
-- matches the absence of a corresponding super-mode emitted row.
generatedSuperKindIndex :: M.Map (String, String) FusionSuperKind
generatedSuperKindIndex = M.fromList
  [ ((familyName fam, name), kind)
  | fam <- [minBound .. maxBound :: GraphFamily]
  , FamilyMember name graph <- familyMembers fam
  , Just kind <- [generatedSuperKindFor graph]
  ]

shapeKeyForOwned :: RuntimeGraph -> [NodeIndex] -> Either String ShapeKey
shapeKeyForOwned rg owned = do
  nodes <- mapM (lookupRtNode rg) owned
  Right ShapeKey
    { skKinds = map (fromEnum . rnKind) nodes
    , skGainAmountModes =
        [ fromEnum (gateGainAmountMode n)
        | n <- nodes
        , rnKind n == KGain
        ]
    }

gateGainAmountMode :: RuntimeNode -> GainAmountMode
gateGainAmountMode n = case drop 1 (rnInputs n) of
  RConst _ : _ -> GainAmountConst
  _ : _        -> GainAmountDynamic
  []           -> GainAmountMissing

runFamily :: GraphFamily -> IO [LabRow]
runFamily fam = concat <$> mapM (runMember fam) (familyMembers fam)

runMember :: GraphFamily -> FamilyMember -> IO [LabRow]
runMember fam (FamilyMember label graph) = do
  -- Compile every variant once up front. Compile failure is
  -- recorded as a row with no timing, never aborts the lab run.
  let variants =
        [ VarNodeLoop, VarRegionKernel, VarRFused
        , VarGenerated, VarGeneratedBlock, VarGeneratedSuper
        ]
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

------------------------------------------------------------
-- Generated variant diagnostics (Phase 7.E step 4)
------------------------------------------------------------
--
-- A small stderr block summarising how the generated variant
-- did on the current corpus. Diagnostic-only: no planner uses
-- these counts, no profitability gate consumes them. The point
-- is to make "is the generator wider, is it correct, is it ever
-- faster" answerable at a glance instead of by reading the JSONL.
renderGeneratedDiagnostics :: Handle -> [LabRow] -> IO ()
renderGeneratedDiagnostics handle rows = do
  let sampleRows = [r | r <- rows, lrVariant r == VarGenerated]
      blockRows  = [r | r <- rows, lrVariant r == VarGeneratedBlock]
      superRows  = [r | r <- rows, lrVariant r == VarGeneratedSuper]
  if null sampleRows && null blockRows && null superRows
    then pure ()
    else do
      hPutStrLn handle ""
      hPutStrLn handle "=== generated variant diagnostics (Phase 7.E/7.G/7.H/7.I) ==="
      printVariantSummary "sample-major" sampleRows
      printVariantSummary "block-major"  blockRows
      printVariantSummary "super-mode"   superRows
      -- §7.I recognized vs fallback breakdown. The classifier
      -- is structural so the counts are deterministic across
      -- runs; snapshot pins them in [SnapshotCheck.hs].
      printSuperBreakdown superRows
      -- §7.H / §7.I A/B/C owned-size bucket views. All three
      -- generated variants share the same emitted programs, so
      -- each row appears under the same owned-tail-length key.
      -- The compact side-by-side table surfaces both the
      -- block-major crossover and the super-mode delta where
      -- the recognizer fast path kicks in.
      printAbcBuckets
        "  by owned-op count (all emitted rows; medians):"
        sampleRows blockRows superRows
      printAbcBuckets
        "  generated-tail-sweep only (medians):"
        [r | r <- sampleRows, lrFamily r == FamilyGeneratedTailSweep]
        [r | r <- blockRows,  lrFamily r == FamilyGeneratedTailSweep]
        [r | r <- superRows,  lrFamily r == FamilyGeneratedTailSweep]
      hPutStrLn handle "=== end generated diagnostics ==="
      hFlush handle
  where
    unless cond act = if cond then pure () else act

    printVariantSummary :: String -> [LabRow] -> IO ()
    printVariantSummary label generated = unless (null generated) $ do
      let unsupported    = [r | r <- generated, lrError r /= Nothing]
          emitted        = [r | r <- generated, lrError r == Nothing]
          nonExact       = [r | r <- emitted,   lrEquivalence r /= EqExact]
          emittedSpeeds  = mapMaybe lrSpeedupVsBase emitted
          wins           = length [s | s <- emittedSpeeds, s >= measuredWinThreshold]
          loses          = length emittedSpeeds - wins
          declineReasons = tally [errorBucket e | r <- unsupported, Just e <- [lrError r]]
          deltas         = [d | r <- emitted, Just d <- [deltaVsBestNonGenerated rows r]]
          posDeltas      = length [d | d <- deltas, d >= 0]
          negDeltas      = length deltas - posDeltas

      hPutStrLn handle $ "  [" <> label <> "]"
      hPutStrLn handle $ "    considered:  " <> show (length generated)
                      <> "  emitted: "      <> show (length emitted)
                      <> "  unsupported: "  <> show (length unsupported)
      hPutStrLn handle $ "    equivalence: exact=" <> show (length emitted - length nonExact)
                      <> "  non-exact="     <> show (length nonExact)
      unless (null declineReasons) $ do
        hPutStrLn handle "    decline reasons:"
        forM_ declineReasons $ \(reason, n) ->
          hPutStrLn handle $ "      " <> reason <> ": " <> show n
      unless (null emittedSpeeds) $ do
        let (sMin, sMed, sMax) = minMedMax emittedSpeeds
        hPutStrLn handle $ printf
          "    speedup vs node-loop: min=%.2fx  median=%.2fx  max=%.2fx  win(>=%.2fx)=%d  loss=%d"
          sMin sMed sMax measuredWinThreshold wins loses
      unless (null deltas) $ do
        let (dMin, dMed, dMax) = minMedMax deltas
        hPutStrLn handle $ printf
          "    delta vs best non-generated (region-kernel/RFused): rows=%d  min=%+.2fx  median=%+.2fx  max=%+.2fx  variant>=best=%d  variant<best=%d"
          (length deltas) dMin dMed dMax posDeltas negDeltas

    ownedSizeOf :: LabRow -> Maybe Int
    ownedSizeOf r =
      M.lookup (familyName (lrFamily r), lrMember r) ownedSizeIndex

    -- §7.I recognized vs fallback breakdown of super-mode rows.
    -- Classification is structural so the counts are
    -- deterministic across runs.
    printSuperBreakdown :: [LabRow] -> IO ()
    printSuperBreakdown superSrc = do
      let emittedSuper =
            [ r | r <- superSrc, lrError r == Nothing ]
          kindOf r = case M.lookup (familyName (lrFamily r), lrMember r)
                                   generatedSuperKindIndex of
            Just FusionSuperGainOut    -> Just "GainOut"
            Just FusionSuperAddGainOut -> Just "AddGainOut"
            Just FusionSuperNotRecognized -> Just "fallback"
            Nothing                    -> Nothing
          tagged    = mapMaybe kindOf emittedSuper
          counts    = tally tagged
          recognized = length [() | t <- tagged, t /= "fallback"]
          fallback   = length [() | t <- tagged, t == "fallback"]
      unless (null emittedSuper) $ do
        hPutStrLn handle "  [super-mode recognized vs fallback]"
        hPutStrLn handle $
          "    emitted=" <> show (length emittedSuper)
          <> "  recognized=" <> show recognized
          <> "  fallback="   <> show fallback
        unless (null counts) $ do
          hPutStrLn handle "    by shape:"
          forM_ counts $ \(shape, n) ->
            hPutStrLn handle $ "      " <> shape <> ": " <> show n

    -- §7.H/§7.I side-by-side amortization-curve table. Each size
    -- row shows the bucket population (all three variants share
    -- the same emitted programs by construction) and the median
    -- speedup under each executor. A '*' marks rows where
    -- block-major beats sample-major; a '†' marks rows where
    -- super-mode beats block-major.
    printAbcBuckets
      :: String -> [LabRow] -> [LabRow] -> [LabRow] -> IO ()
    printAbcBuckets title sampleSrc blockSrc superSrc = do
      let bucketSizes =
            sort (nubOrd
                   [ s
                   | r <- sampleSrc ++ blockSrc ++ superSrc
                   , Just s <- [ownedSizeOf r]
                   ])
      unless (null bucketSizes) $ do
        hPutStrLn handle title
        forM_ bucketSizes $ \sz ->
          let rowsAtS = [r | r <- sampleSrc, ownedSizeOf r == Just sz]
              rowsAtB = [r | r <- blockSrc,  ownedSizeOf r == Just sz]
              rowsAtU = [r | r <- superSrc,  ownedSizeOf r == Just sz]
              medAt rs = case mapMaybe lrSpeedupVsBase rs of
                           [] -> Nothing
                           xs -> let (_, m, _) = minMedMax xs in Just m
              fmtMed   = maybe "n/a" (printf "%.2fx") :: Maybe Double -> String
              mS = medAt rowsAtS
              mB = medAt rowsAtB
              mU = medAt rowsAtU
              blockMarker = case (mS, mB) of
                (Just s, Just b) | b > s -> " *block>sample"
                _                        -> ""
              superMarker = case (mB, mU) of
                (Just b, Just u) | u > b -> " \x2020super>block"
                _                        -> ""
              rowCount = maximum
                [length rowsAtS, length rowsAtB, length rowsAtU]
          in hPutStrLn handle $ printf
               "    size=%2d  rows=%d  sample=%s  block=%s  super=%s%s%s"
               sz rowCount
               (fmtMed mS) (fmtMed mB) (fmtMed mU)
               (blockMarker :: String) (superMarker :: String)


    -- Built once per call: (familyName, member) -> owned tail
    -- length for the generator's first eligible candidate on the
    -- member's source graph. 'Nothing' for graphs the generator
    -- declines; those rows just don't appear in any bucket.
    -- Keyed by family-name string rather than 'GraphFamily'
    -- because the enum has no 'Ord' instance.
    ownedSizeIndex :: M.Map (String, String) Int
    ownedSizeIndex = M.fromList
      [ ((familyName fam, name), sz)
      | fam <- [minBound .. maxBound :: GraphFamily]
      , FamilyMember name graph <- familyMembers fam
      , Just sz <- [generatedOwnedTailLength graph]
      ]

    tally :: Ord a => [a] -> [(a, Int)]
    tally xs =
      [ (k, length (filter (== k) xs))
      | k <- sort (nubOrd xs)
      ]

    nubOrd :: Ord a => [a] -> [a]
    nubOrd = S.toAscList . S.fromList

    errorBucket s
      | "not implemented yet" `isInfixOf` s     = "not implemented yet"
      | "no shape this slice" `isInfixOf` s     = "no shape this slice can emit"
      | "RFused inputs not supported" `isInfixOf` s = "RFused inputs not supported"
      | "Out has no bus control" `isInfixOf` s  = "Out has no bus control"
      | "unexpected input arity" `isInfixOf` s  = "unexpected input arity"
      | "dangling NodeIndex" `isInfixOf` s      = "dangling NodeIndex"
      | "not contiguous" `isInfixOf` s          = "owned slice not contiguous"
      | "region not found" `isInfixOf` s        = "owned slice's region not found"
      | otherwise                               = s

minMedMax :: [Double] -> (Double, Double, Double)
minMedMax [] = (0, 0, 0)
minMedMax xs =
  case sort xs of
    [] -> (0, 0, 0)
    sorted@(lo : rest) ->
      let n   = length sorted
          mid = n `div` 2
          med
            | odd n     = indexOrZero sorted mid
            | otherwise =
                (indexOrZero sorted (mid - 1) + indexOrZero sorted mid) / 2
      in (lo, med, lastOf lo rest)
  where
    indexOrZero (y : _) 0 = y
    indexOrZero (_ : ys) i
      | i > 0 = indexOrZero ys (i - 1)
    indexOrZero _ _ = 0

    lastOf acc []       = acc
    lastOf _   (y : ys) = lastOf y ys

-- | Speedup delta between the generated row and the better of
-- region-kernel / RFused on the same (family, member). Returns
-- 'Nothing' if generated didn't measure or no non-generated peer
-- exists.
deltaVsBestNonGenerated :: [LabRow] -> LabRow -> Maybe Double
deltaVsBestNonGenerated allRows genRow = do
  genSpeedup <- lrSpeedupVsBase genRow
  let peers =
        [ s
        | r <- allRows
        , lrFamily r == lrFamily genRow
        , lrMember r == lrMember genRow
        , lrVariant r `elem` [VarRegionKernel, VarRFused]
        , Just s <- [lrSpeedupVsBase r]
        ]
  case peers of
    [] -> Nothing
    _  -> Just (genSpeedup - maximum peers)
