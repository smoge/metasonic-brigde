module MetaSonic.App.Survey
  ( printFusionSummary
  , runFusionSurvey
  , surveyShapeProbes
  , surveyEnsembleCorpus
    -- * Phase 6.A.3 corpus survey
  , CorpusGraphSummary (..)
  , surveyCorpusGraph
  , SinkShape (..)
  , shapeHasKernel
  , renderShape
  , renderProducer
    -- * Phase 7.B capability tooling
  , KindTally
  , shapeMemberKinds
  , shapeCapabilities
  , renderCapAbbr
    -- * Phase 7.F profitability gate plumbing (for snapshot)
  , GateShapeRow (..)
  , aggregateGateShapes
  , gateInputFor
  ) where

import           Data.Either               (partitionEithers)
import           Data.List                 (intercalate, isPrefixOf, nub, sort,
                                             sortOn)
import qualified Data.Map.Strict           as M
import           Foreign.C.Types           (CInt)
import           System.Exit               (die)
import           Text.Printf               (printf)

import           MetaSonic.App.Demos
import           MetaSonic.Authoring.Report (AuthoringReport (..),
                                             ReportedControl (..))
import qualified MetaSonic.App.FusionCostLab as FCL
import           MetaSonic.App.FusionCostLab (costLabGateIndex,
                                              costLabGateIndexFor,
                                              costLabShapeIndex)
import           MetaSonic.App.FusionCostModel
                                             (GateMeasurement (..),
                                              ShapeKey,
                                              ShapeSummary (..),
                                              Variant (..),
                                              measuredWinThreshold,
                                              shapeKeyOf, variantName)
import           MetaSonic.App.ProfitabilityGate (GateCounts (..),
                                                  GateInput (..),
                                                  GateRow (..),
                                                  evaluateGate,
                                                  summarizeGate,
                                                  verdictReason,
                                                  verdictTag)
import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Planner   (FusionCandidate (..),
                                             GainAmountMode (..),
                                             RejectionReason (..),
                                             Verdict (..), isAccepted,
                                             isRejected, planRuntimeGraph,
                                             selectedFusionCandidates)
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Types            (KindCapability (..),
                                             NodeIndex (..), NodeKind (..),
                                             PortConsumptionRate (..),
                                             PortIndex (..), Rate (..),
                                             kindCapabilities, kindTag)

printFusionSummary :: String -> RuntimeGraph -> IO ()
printFusionSummary label rg = do
  let nodes        = length (rgNodes rg)
      elidedN      = length (filter rnElided (rgNodes rg))
      fusedN       = length [() | n <- rgNodes rg, RFused _ <- rnInputs n]
      fusedRegions = [r | r <- rgRuntimeRegions rg, rrKernel r /= RNodeLoop]
      buses        = sort $ nub
        [ truncate v :: Int
        | n <- rgNodes rg
        , rnKind n == KOut || rnKind n == KBusOut
        , v : _ <- [rnControls n]
        , v >= 0
        ]
      kindOf = (`lookup` [(rnIndex n, rnKind n) | n <- rgNodes rg])
  putStrLn $ "  [Fusion " <> label <> "] nodes=" <> show nodes
          <> " elided=" <> show elidedN
          <> " fused-inputs=" <> show fusedN
          <> " region-kernels=" <> show (length fusedRegions)
          <> " buses=" <> show buses
  mapM_ (printRegionLine kindOf) fusedRegions

-- One indented detail line per claimed §4.B region.
printRegionLine
  :: (NodeIndex -> Maybe NodeKind) -> RuntimeRegion -> IO ()
printRegionLine kindOf r = do
  let RegionIndex ri = rrIndex r
      members        = rrNodes r
      kinds          = [show k | ix <- members, Just k <- [kindOf ix]]
      rangeShown     = case members of
        []       -> "[]"
        [NodeIndex i] -> "[" <> show i <> "]"
        (NodeIndex i : _) ->
          let NodeIndex j = last members
          in "[" <> show i <> ".." <> show j <> "]"
  putStrLn $ "    region " <> show ri
          <> ": " <> show (rrKernel r)
          <> " " <> rangeShown
          <> " kinds=[" <> intercalate "," kinds <> "]"

--------------------------------------------------------------------------------
-- §4.B / §4.C fusion-coverage survey (--fusion-survey)
--------------------------------------------------------------------------------

-- Canonical sink-terminal shape the survey scans for in dense
-- 'RuntimeNode' order. The opportunity scan reports one row per
-- (shape, found, claimed) triple so we can read off both what the
-- current kernel set catches and what a future kernel would have
-- caught — i.e. shapes whose §4.B preconditions hold but whose
-- chain wasn't claimed by any region kernel today.
data SinkShape
  = SinkOscGain     !NodeKind   -- producer → Gain → sink
  | SinkOscLpfGain  !NodeKind   -- producer → LPF → Gain → sink
  | SinkBusInLpfGain            -- BusIn → LPF → Gain → sink
                                -- (return tail of a send-return)
  | SinkAddLpfGain              -- Add   → LPF → Gain → sink
                                -- (post-mix filtered tail; no
                                -- producer constraint on Add's
                                -- inputs, only the LPF/Gain/sink
                                -- portion is matched)
  deriving (Eq, Show)

-- The full enumeration of shapes the survey reports on. Listed in
-- a deliberate display order: 3-node oscillator-rooted sinks first
-- (the strongest fusion class per notes/2026-05-08-e-fusion-strategy.md), then
-- 4-node oscillator-rooted sinks, then BusIn-rooted return tails,
-- then Add-rooted post-mix tails. Producer kinds within the
-- oscillator groups follow 'sinkProducerKinds'. Iterating this
-- list (rather than keying a Map by SinkShape) avoids needing
-- 'Ord NodeKind' and gives stable column order.
allKnownShapes :: [SinkShape]
allKnownShapes =
  [SinkOscGain    k | k <- sinkProducerKinds]
  <> [SinkOscLpfGain k | k <- sinkProducerKinds]
  <> [SinkBusInLpfGain]
  <> [SinkAddLpfGain]

-- Producer kinds the survey treats as "oscillator-like" sources.
-- Restricted to the kinds that already exist in the DSL and that
-- a §4.B kernel could plausibly absorb; multi-input nodes (Add,
-- Gain) and stateful processors (Env, LPF, Smooth) are outside
-- this set.
sinkProducerKinds :: [NodeKind]
sinkProducerKinds = [KSinOsc, KSawOsc, KTriOsc, KPulseOsc, KNoiseGen]

renderProducer :: NodeKind -> String
renderProducer KSinOsc   = "Sin"
renderProducer KSawOsc   = "Saw"
renderProducer KTriOsc   = "Tri"
renderProducer KPulseOsc = "Pulse"
renderProducer KNoiseGen = "Noise"
renderProducer k         = show k

renderShape :: SinkShape -> String
renderShape (SinkOscGain k)    = renderProducer k <> " → Gain → sink"
renderShape (SinkOscLpfGain k) = renderProducer k <> " → LPF → Gain → sink"
renderShape SinkBusInLpfGain   = "BusIn → LPF → Gain → sink"
renderShape SinkAddLpfGain     = "Add → LPF → Gain → sink"

-- §7.B: the node sequence implied by a 'SinkShape'. Derived from the
-- shape's constructor without re-scanning a 'RuntimeGraph'. The sink
-- is represented as 'KOut' for capability derivation; both 'KOut'
-- and 'KBusOut' carry the same 'kindCapabilities', so concrete chains
-- that end in either work the same way.
shapeMemberKinds :: SinkShape -> [NodeKind]
shapeMemberKinds (SinkOscGain    k) = [k,                KGain, KOut]
shapeMemberKinds (SinkOscLpfGain k) = [k,        KLPF,   KGain, KOut]
shapeMemberKinds SinkBusInLpfGain   = [KBusIn,   KLPF,   KGain, KOut]
shapeMemberKinds SinkAddLpfGain     = [KAdd,     KLPF,   KGain, KOut]

-- §7.B: the union of 'KindCapability' flags carried by the chain
-- members of a 'SinkShape'. Returned in 'KindCapability' Enum order
-- for deterministic display.
shapeCapabilities :: SinkShape -> [KindCapability]
shapeCapabilities s =
  let kinds = shapeMemberKinds s
  in [ c
     | c <- [minBound .. maxBound :: KindCapability]
     , any (\k -> c `elem` kindCapabilities k) kinds
     ]

-- Two-character abbreviation for use in compact survey columns.
renderCapAbbr :: KindCapability -> String
renderCapAbbr CapStatelessOp    = "SL"
renderCapAbbr CapStatefulOp     = "St"
renderCapAbbr CapSinkTerminal   = "Sk"
renderCapAbbr CapResourceAccess = "RA"
renderCapAbbr CapLatencyBearing = "LB"
renderCapAbbr CapHardBarrier    = "HB"

-- Whether the §4.B kernel set currently has a kernel that would
-- claim this shape (independent of whether the kernel
-- preconditions hold on any specific instance).
shapeHasKernel :: SinkShape -> Bool
shapeHasKernel (SinkOscGain    KSinOsc)   = True   -- RSinGainOut
shapeHasKernel (SinkOscGain    KSawOsc)   = True   -- RSawGainOut
shapeHasKernel (SinkOscGain    KNoiseGen) = True   -- RNoiseGainOut
shapeHasKernel (SinkOscLpfGain KSawOsc)   = True   -- RSawLpfGainOut
shapeHasKernel (SinkOscLpfGain KNoiseGen) = True   -- RNoiseLpfGainOut
shapeHasKernel SinkBusInLpfGain           = True   -- RBusInLpfGainOut
shapeHasKernel _                          = False

-- Sink-terminal classifier: matches NodeKind.{Out,BusOut} on the
-- C++ side / 'isSinkTerminal' on the Haskell matcher side.
isSinkKind :: NodeKind -> Bool
isSinkKind k = k == KOut || k == KBusOut

-- Mirror the §4.B 'signalSourceIs' / 'isScalarGain' precondition
-- helpers — kept inline rather than imported because the matcher
-- helpers in 'MetaSonic.Bridge.Compile' aren't exported (they
-- shouldn't leak into the public API).
signalSourceIsRT :: NodeIndex -> RuntimeNode -> Bool
signalSourceIsRT srcIx node = case rnInputs node of
  RFrom s (PortIndex 0) : _ -> s == srcIx
  _                         -> False

isScalarGainRT :: RuntimeNode -> Bool
isScalarGainRT node = case rnInputs node of
  [RFrom _ _, RConst _] -> True
  _                     -> False

windows3 :: [a] -> [(a, a, a)]
windows3 (a : b : c : rest) = (a, b, c) : windows3 (b : c : rest)
windows3 _                  = []

windows4 :: [a] -> [(a, a, a, a)]
windows4 (a : b : c : d : rest) = (a, b, c, d) : windows4 (b : c : d : rest)
windows4 _                      = []

-- Walk a 'RuntimeGraph' in dense order, collecting each contiguous
-- sub-sequence whose §4.B preconditions hold. Each result carries
-- whether the chain ended up in a single non-RNodeLoop region —
-- i.e. whether some kernel actually claimed it.
scanSinkShapes :: RuntimeGraph -> [(SinkShape, Bool)]
scanSinkShapes rt =
     concatMap check3    (windows3 (rgNodes rt))
  ++ concatMap check4    (windows4 (rgNodes rt))
  ++ concatMap check4Bus (windows4 (rgNodes rt))
  ++ concatMap check4Add (windows4 (rgNodes rt))
  where
    fusedRegions = [r | r <- rgRuntimeRegions rt, rrKernel r /= RNodeLoop]
    inSameFusedRegion ixs =
      any (\r -> all (`elem` rrNodes r) ixs) fusedRegions

    check3 (a, b, c)
      | rnKind a `elem` sinkProducerKinds
      , rnKind b == KGain
      , isSinkKind (rnKind c)
      , rnConsumerCount a == 1
      , rnConsumerCount b == 1
      , signalSourceIsRT (rnIndex a) b
      , signalSourceIsRT (rnIndex b) c
      , isScalarGainRT b
      , not (rnElided a) && not (rnElided b) && not (rnElided c)
      = [( SinkOscGain (rnKind a)
         , inSameFusedRegion [rnIndex a, rnIndex b, rnIndex c] )]
      | otherwise = []

    check4 (a, b, c, d)
      | rnKind a `elem` sinkProducerKinds
      , rnKind b == KLPF
      , rnKind c == KGain
      , isSinkKind (rnKind d)
      , rnConsumerCount a == 1
      , rnConsumerCount b == 1
      , rnConsumerCount c == 1
      , signalSourceIsRT (rnIndex a) b
      , signalSourceIsRT (rnIndex b) c
      , signalSourceIsRT (rnIndex c) d
      , isScalarGainRT c
      , not (rnElided a) && not (rnElided b)
                         && not (rnElided c) && not (rnElided d)
      = [( SinkOscLpfGain (rnKind a)
         , inSameFusedRegion
             [rnIndex a, rnIndex b, rnIndex c, rnIndex d] )]
      | otherwise = []

    -- BusIn-rooted return tail: BusIn → LPF → Gain → sink. Same
    -- preconditions as 'check4' for the LPF/Gain/sink portion;
    -- producer constraint changes from 'sinkProducerKinds' to a
    -- direct KBusIn check (BusIn isn't an "oscillator-like" source,
    -- it's a bus reader). No kernel claims this shape today —
    -- 'shapeHasKernel SinkBusInLpfGain = False' — so the row tracks
    -- a future-kernel candidate.
    check4Bus (a, b, c, d)
      | rnKind a == KBusIn
      , rnKind b == KLPF
      , rnKind c == KGain
      , isSinkKind (rnKind d)
      , rnConsumerCount a == 1
      , rnConsumerCount b == 1
      , rnConsumerCount c == 1
      , signalSourceIsRT (rnIndex a) b
      , signalSourceIsRT (rnIndex b) c
      , signalSourceIsRT (rnIndex c) d
      , isScalarGainRT c
      , not (rnElided a) && not (rnElided b)
                         && not (rnElided c) && not (rnElided d)
      = [( SinkBusInLpfGain
         , inSameFusedRegion
             [rnIndex a, rnIndex b, rnIndex c, rnIndex d] )]
      | otherwise = []

    -- Add-rooted post-mix tail: Add → LPF → Gain → sink. Same
    -- preconditions as 'check4Bus' for the LPF/Gain/sink portion;
    -- producer constraint becomes a direct KAdd check. Add's own
    -- inputs are unconstrained — the kernel-decision question
    -- this row answers is "is post-mix filtered tail a recurring
    -- shape", which is independent of how the mix was built. No
    -- kernel claims this shape today; 'shapeHasKernel
    -- SinkAddLpfGain = False'.
    check4Add (a, b, c, d)
      | rnKind a == KAdd
      , rnKind b == KLPF
      , rnKind c == KGain
      , isSinkKind (rnKind d)
      , rnConsumerCount a == 1
      , rnConsumerCount b == 1
      , rnConsumerCount c == 1
      , signalSourceIsRT (rnIndex a) b
      , signalSourceIsRT (rnIndex b) c
      , signalSourceIsRT (rnIndex c) d
      , isScalarGainRT c
      , not (rnElided a) && not (rnElided b)
                         && not (rnElided c) && not (rnElided d)
      = [( SinkAddLpfGain
         , inSameFusedRegion
             [rnIndex a, rnIndex b, rnIndex c, rnIndex d] )]
      | otherwise = []

-- §4.D.1 read-only descriptive aggregate. Counts of each
-- propagated node output rate ('rnRate') across a runtime graph.
-- The four fields cover the full 'Rate' lattice; their sum equals
-- the total node count for the graph.
--
-- This is a /node output rate/ histogram, not a per-input
-- consumption-policy classification. A 'KGain' fed by an
-- oscillator counts as 'rdSample' here even when its amount input
-- is a scalar 'CompileRate' constant; the per-input latch view
-- (whether the runtime samples a control once per block or per
-- sample) is a separate concern, deferred to a later §4.D slice.
data RateDistribution = RateDistribution
  { rdCompile :: !Int
    -- ^ Nodes with @rnRate = CompileRate@.
  , rdInit    :: !Int
    -- ^ Nodes with @rnRate = InitRate@.
  , rdBlock   :: !Int
    -- ^ Nodes with @rnRate = BlockRate@.
  , rdSample  :: !Int
    -- ^ Nodes with @rnRate = SampleRate@.
  } deriving (Eq, Show)

emptyRateDistribution :: RateDistribution
emptyRateDistribution = RateDistribution 0 0 0 0

-- | Compose two distributions by per-bucket addition. Used to
-- aggregate per-row counts into the survey-wide footer.
addRateDistribution :: RateDistribution -> RateDistribution -> RateDistribution
addRateDistribution a b = RateDistribution
  { rdCompile = rdCompile a + rdCompile b
  , rdInit    = rdInit    a + rdInit    b
  , rdBlock   = rdBlock   a + rdBlock   b
  , rdSample  = rdSample  a + rdSample  b
  }

-- | Total nodes counted (equals the graph's node count for a
-- 'rateDistribution' result).
rateDistributionTotal :: RateDistribution -> Int
rateDistributionTotal d =
  rdCompile d + rdInit d + rdBlock d + rdSample d

-- | Walk a 'RuntimeGraph' and bin each node by 'rnRate'. Elided
-- nodes are counted: they remain in 'rgNodes' with a stable
-- 'NodeIndex', and the rate they carry from IR lowering is what
-- the descriptive view reports.
rateDistribution :: RuntimeGraph -> RateDistribution
rateDistribution rt =
  foldr bump emptyRateDistribution (rgNodes rt)
  where
    bump n d = case rnRate n of
      CompileRate -> d { rdCompile = rdCompile d + 1 }
      InitRate    -> d { rdInit    = rdInit    d + 1 }
      BlockRate   -> d { rdBlock   = rdBlock   d + 1 }
      SampleRate  -> d { rdSample  = rdSample  d + 1 }

-- §4.E.C1d descriptive region-layer shape. This is intentionally a
-- corpus survey, not a runtime policy: it asks whether compiled
-- graphs contain per-template FreeLayer steps with multiple regions.
-- C1c dispatches whole global schedule entries and cannot split one
-- entry into these regions. Direct C1d candidates are sink-free
-- layers with width >= 2; reduction C1d candidates are sink-bearing
-- layers with width >= 2. The latter remain test-only per the
-- turn-on decision.
data RegionLayerStats = RegionLayerStats
  { rlsFreeBands          :: !Int
  , rlsSinkFreeBands      :: !Int
  , rlsSinkBands          :: !Int
  , rlsMaxSinkFreeWidth   :: !Int
  , rlsMaxSinkWidth       :: !Int
  , rlsMaxBandWork        :: !Int
  , rlsDirectCandidates   :: !Int
  , rlsReductionCandidates:: !Int
  } deriving (Eq, Show)

emptyRegionLayerStats :: RegionLayerStats
emptyRegionLayerStats = RegionLayerStats 0 0 0 0 0 0 0 0

addRegionLayerStats :: RegionLayerStats -> RegionLayerStats -> RegionLayerStats
addRegionLayerStats a b = RegionLayerStats
  { rlsFreeBands           = rlsFreeBands           a + rlsFreeBands           b
  , rlsSinkFreeBands       = rlsSinkFreeBands       a + rlsSinkFreeBands       b
  , rlsSinkBands           = rlsSinkBands           a + rlsSinkBands           b
  , rlsMaxSinkFreeWidth    = max (rlsMaxSinkFreeWidth a)
                                  (rlsMaxSinkFreeWidth b)
  , rlsMaxSinkWidth        = max (rlsMaxSinkWidth a)
                                  (rlsMaxSinkWidth b)
  , rlsMaxBandWork         = max (rlsMaxBandWork a)
                                  (rlsMaxBandWork b)
  , rlsDirectCandidates    = rlsDirectCandidates    a + rlsDirectCandidates    b
  , rlsReductionCandidates = rlsReductionCandidates a + rlsReductionCandidates b
  }

regionLayerStats :: RuntimeGraph -> Either String RegionLayerStats
regionLayerStats rt = do
  steps <- layeredRegionSchedule rt
  let byIx = M.fromList [(rrIndex r, r) | r <- rgRuntimeRegions rt]
      layerRegions fl =
        traverse
          (\ix -> case M.lookup ix byIx of
             Just r  -> Right r
             Nothing -> Left $
               "regionLayerStats: layered schedule referenced unknown "
               <> "region " <> show ix)
          (flRegions fl)
      rowFor layer =
        let width   = length layer
            hasSink = any (not . null . bfWrites . rfBuses . rrFootprint) layer
            work    = sum (map (length . rrNodes) layer)
        in if hasSink
             then emptyRegionLayerStats
               { rlsFreeBands           = 1
               , rlsSinkBands           = 1
               , rlsMaxSinkWidth        = width
               , rlsMaxBandWork         = work
               , rlsReductionCandidates = if width >= 2 then 1 else 0
               }
             else emptyRegionLayerStats
               { rlsFreeBands         = 1
               , rlsSinkFreeBands     = 1
               , rlsMaxSinkFreeWidth  = width
               , rlsMaxBandWork       = work
               , rlsDirectCandidates  = if width >= 2 then 1 else 0
               }
  layers <- traverse layerRegions
    [ fl | ScheduleFreeLayer fl <- steps ]
  pure (foldr (addRegionLayerStats . rowFor) emptyRegionLayerStats layers)

-- Per-template summary row.
data SurveyRow = SurveyRow
  { srDemo         :: !String
  , srTemplate     :: !(Maybe String)
  , srNodes        :: !Int
  , srRegions      :: !Int
  , srFusedRegions :: !Int
  , srClaimedNodes :: !Int
  , srKernels      :: ![(RegionKernel, Int)]
  , srElided       :: !Int
  , srRFused       :: !Int
  , srShapes       :: ![(SinkShape, Bool)]
  , srSchedStats   :: !RegionScheduleStats
    -- ^ §4.E.2c parallel-readiness counts. Read-only; surfaces in
    -- the schedule-width section of '--fusion-survey'.
  , srRegionLayer  :: !RegionLayerStats
    -- ^ §4.E.C1d corpus region-layer shape summary. Read-only;
    -- surfaces in the corpus FreeLayer-width section of
    -- '--fusion-survey'.
  , srRateDist     :: !RateDistribution
    -- ^ §4.D.1 rate distribution. Counts of each propagated node
    -- output rate ('rnRate') across this row's runtime nodes.
    -- Read-only descriptive metadata; the C++ runtime does not
    -- consume it, and the survey reports it without changing
    -- compilation or execution behavior.
  , srEdgeBuckets  :: !(M.Map EdgeRateKey EdgeRateBucket)
    -- ^ §4.D.2 edge-rate buckets. One entry per
    -- @(sourceRate, destPolicy)@ pair that has at least one
    -- 'RFrom' edge in this row's /unfused/ runtime graph. Used by
    -- 'printEdgeRateDistribution' for the descriptive bucket
    -- table.
  , srOppProducers :: ![NodeKind]
    -- ^ §4.D.2 headline opportunity: 'NodeKind' of every
    -- 'SampleRate' producer in this row whose every active audio-
    -- input consumer port is non-sample-accurate. Per-graph: a
    -- producer feeding both 'PortSampleAccurate' /and/
    -- 'PortBlockLatched' ports does /not/ qualify (it must remain
    -- sample-rate to serve its sample-accurate consumer). Stored
    -- as a flat list rather than a count so cross-row
    -- aggregation can also report distinct-kind diversity.
  , srDeclaredLatency :: ![DeclaredNodeLatency]
    -- ^ §6.D descriptive latency footprint. Nodes whose kind
    -- declares inherent steady-state latency.
  , srLatencySkews :: ![LatencySkew]
    -- ^ §6.D diagnostic for uncompensated parallel paths: nodes
    -- with dynamic inputs arriving at different cumulative
    -- latencies. Read-only; no scheduler pass consumes this yet.
  , srKindTally    :: !KindTally
    -- ^ §7.B per-kind node counts. Read-only descriptive metadata;
    -- printed in the kind capability footprint section. Sorted by
    -- 'NodeKind' Enum order; kinds with zero occurrences are
    -- dropped.
  , srPlannerVerdicts :: ![Verdict]
    -- ^ §7.C survey-only fusion planner output. One 'Verdict' per
    -- candidate; consumers aggregate per-reason rejection counts
    -- and matched-shape acceptance counts. Read-only; the planner
    -- does not influence runtime behavior.
  } deriving (Eq, Show)

-- | Per-row tally of 'NodeKind' → count of nodes carrying that kind.
-- Kept as an Enum-ordered assoc list because 'NodeKind' has no 'Ord'
-- instance. Zero-count kinds are dropped so a per-kind table doesn't
-- show 22 rows for every graph.
type KindTally = [(NodeKind, Int)]

kindTallyOf :: RuntimeGraph -> KindTally
kindTallyOf rt =
  [ (k, n)
  | k <- [minBound .. maxBound :: NodeKind]
  , let n = length [() | node <- rgNodes rt, rnKind node == k]
  , n > 0
  ]

emptyKindTally :: KindTally
emptyKindTally = []

mergeKindTallies :: KindTally -> KindTally -> KindTally
mergeKindTallies a b =
  [ (k, n)
  | k <- [minBound .. maxBound :: NodeKind]
  , let n = countOf k a + countOf k b
  , n > 0
  ]
  where
    countOf k = maybe 0 id . lookup k

-- Build a SurveyRow from /two/ compiled 'RuntimeGraph's of the
-- same source 'SynthGraph':
--
--   * 'rt'    — produced by 'compileRuntimeGraph'. This already
--               contains §4.B's region kernel selection (because
--               'selectRegionKernels' runs unconditionally inside
--               compileRuntimeGraph), but no §4.C elision. The
--               §4.B counts and the sink-shape scan run against
--               this graph.
--   * 'rtF'   — produced by 'compileRuntimeGraphFused' (the same
--               'rt' with §4.C single-input rewrites layered on
--               top). The §4.C 'elided' and 'RFused' counts come
--               from this graph.
--
-- Running the shape scan against 'rt' rather than 'rtF' is
-- load-bearing: §4.C elides scalar gains in chains §4.B didn't
-- claim (the same chains the survey is trying to flag as
-- "missed kernel opportunities"), and elided gains fail the
-- shape predicate. Scanning 'rtF' would silently zero out
-- exactly the rows the survey exists to surface.
surveyRuntimeGraph
  :: String
  -> Maybe String
  -> RuntimeGraph
  -> RuntimeGraph
  -> RegionScheduleStats
  -> RegionLayerStats
  -> SurveyRow
surveyRuntimeGraph d t rt rtF stats workerStats =
  let allRegions  = rgRuntimeRegions rt
      fused       = [r | r <- allRegions, rrKernel r /= RNodeLoop]
      -- Enumerate kernel kinds via Bounded/Enum rather than keying
      -- a Map by RegionKernel (which has no Ord instance), and
      -- drop empty rows. Stable display order = constructor order.
      kernelTally = [ (k, n)
                    | k <- [minBound .. maxBound :: RegionKernel]
                    , k /= RNodeLoop
                    , let n = length (filter ((== k) . rrKernel) fused)
                    , n > 0
                    ]
  in SurveyRow
       { srDemo         = d
       , srTemplate     = t
       , srNodes        = length (rgNodes rt)
       , srRegions      = length allRegions
       , srFusedRegions = length fused
       , srClaimedNodes = sum (map (length . rrNodes) fused)
       , srKernels      = kernelTally
       , srElided       = length (filter rnElided (rgNodes rtF))
       , srRFused       = length [() | n <- rgNodes rtF, RFused _ <- rnInputs n]
       , srShapes       = scanSinkShapes rt
       , srSchedStats   = stats
       , srRegionLayer  = workerStats
       , srRateDist     = rateDistribution rt
       , srEdgeBuckets  = edgeRateBuckets rt
         -- §4.D.2: read from the unfused graph deliberately. The
         -- §4.C fused view replaces 'RFrom' with 'RFused' for
         -- elided producers, which would silently drop the very
         -- edges the survey is meant to count.
       , srOppProducers = sampleRateOpportunityProducers rt
       , srDeclaredLatency = declaredLatencyFootprint rt
       , srLatencySkews    = inputLatencySkews rt
       , srKindTally       = kindTallyOf rt
       , srPlannerVerdicts = planRuntimeGraph rt
       }

-- | Compile a 'SynthGraph' for the survey. Returns 'Left' with a
-- caller-friendly @"demo=…[ template=…]: <err>"@ message on
-- compile failure so the survey driver can surface it instead of
-- silently dropping the row. Coverage totals are misleading if a
-- targeted graph just disappears.
surveySynthGraph
  :: String -> Maybe String -> SynthGraph -> Either String SurveyRow
surveySynthGraph d t g = do
  let stamp err = surveyTag d t <> ": " <> err
  rt    <- either (Left . stamp) Right (lowerGraph g >>= compileRuntimeGraph)
  rtF   <- either (Left . stamp) Right (lowerGraph g >>= compileRuntimeGraphFused)
  stats <- either (Left . stamp) Right (regionScheduleStats rt)
  workerStats <- either (Left . stamp) Right (regionLayerStats rt)
  Right (surveyRuntimeGraph d t rt rtF stats workerStats)

-- | A short human label used in error messages.
surveyTag :: String -> Maybe String -> String
surveyTag d Nothing  = "demo=" <> d
surveyTag d (Just t) = "demo=" <> d <> " template=" <> t

-- | Phase 6.A.3: the corpus-relevant slice of 'SurveyRow'. The
-- full row carries scheduling, rate, and edge-rate metadata that
-- the corpus survey does not consume; exposing the slim shape
-- keeps the public surface minimal.
data CorpusGraphSummary = CorpusGraphSummary
  { csNodes        :: !Int
  , csRegions      :: !Int
  , csFusedRegions :: !Int
  , csKernels      :: ![(RegionKernel, Int)]
  , csShapes       :: ![(SinkShape, Bool)]
  , csOppProducers :: ![NodeKind]
  , csDeclaredLatency :: ![DeclaredNodeLatency]
  , csLatencySkews :: ![LatencySkew]
  , csKindTally    :: !KindTally
    -- ^ §7.B per-kind node count. Carried through 'CorpusGraphSummary'
    -- so '--snapshot-check' can aggregate the corpus's
    -- capability footprint without re-compiling each graph.
  , csPlannerVerdicts :: ![Verdict]
    -- ^ §7.C planner verdicts. Carried through so
    -- '--snapshot-check' can pin per-reason rejection counts and
    -- per-matched-shape acceptance counts without re-running the
    -- planner.
  } deriving (Eq, Show)

-- | Phase 6.A.3 corpus-survey entry: compile a 'SynthGraph' and
-- project the result to the corpus-relevant fields. Reuses
-- 'surveySynthGraph' so the §4.B / §4.D logic stays single-source.
surveyCorpusGraph
  :: String -> Maybe String -> SynthGraph -> Either String CorpusGraphSummary
surveyCorpusGraph d t g = do
  row <- surveySynthGraph d t g
  Right CorpusGraphSummary
    { csNodes        = srNodes row
    , csRegions      = srRegions row
    , csFusedRegions = srFusedRegions row
    , csKernels      = srKernels row
    , csShapes       = srShapes row
    , csOppProducers = srOppProducers row
    , csDeclaredLatency = srDeclaredLatency row
    , csLatencySkews    = srLatencySkews row
    , csKindTally       = srKindTally row
    , csPlannerVerdicts = srPlannerVerdicts row
    }

-- | Compile every (demo, template) pair, returning one
-- 'Either String SurveyRow' per pair so the driver can split
-- successes from failures.
surveyDemo :: Demo -> [Either String SurveyRow]
surveyDemo demo = case demoBody demo of
  SingleGraph g ->
    [surveySynthGraph (demoKey demo) Nothing g]
  MultiTemplate tpls ->
    [ surveySynthGraph (demoKey demo) (Just name) g | (name, g) <- tpls ]
  MidiPoly _ build ->
    let (_b, g, _cc) = runSynthCCs build
    in [surveySynthGraph (demoKey demo) Nothing g]

-- | One row of the §4.E.2c cross-template width table. Pairs an
-- ensemble label with the 'TemplateScheduleStats' that
-- 'compileTemplateGraph' + 'templateScheduleStats' produced.
data EnsembleScheduleRow = EnsembleScheduleRow
  { esLabel :: !String
  , esStats :: !TemplateScheduleStats
  } deriving (Eq, Show)

-- | Compile a list of named graphs into a 'TemplateGraph' and
-- compute its 'TemplateScheduleStats'. Forwards diagnostics from
-- 'compileTemplateGraph' / 'templateScheduleStats' so the survey
-- driver can split successes from failures.
surveyEnsemble
  :: String -> [(String, SynthGraph)] -> Either String EnsembleScheduleRow
surveyEnsemble label tpls = do
  let stamp err = "ensemble=" <> label <> ": " <> err
  tg <- either (Left . stamp) Right (compileTemplateGraph tpls)
  ts <- either (Left . stamp) Right (templateScheduleStats tg)
  Right (EnsembleScheduleRow label ts)

-- | Multi-template demos contribute one ensemble row each;
-- single-graph and MIDI-poly demos don't (they have no
-- cross-template precedence DAG to measure).
surveyDemoEnsembles :: Demo -> [Either String EnsembleScheduleRow]
surveyDemoEnsembles demo = case demoBody demo of
  MultiTemplate tpls -> [surveyEnsemble (demoKey demo) tpls]
  _                  -> []

-- | Every entry in 'surveyEnsembleCorpus' becomes one ensemble row
-- under the @corpus:<name>@ key.
surveyEnsembleCorpusScheduleRows :: [Either String EnsembleScheduleRow]
surveyEnsembleCorpusScheduleRows =
  [ surveyEnsemble ("corpus:" <> ensembleName) tpls
  | (ensembleName, tpls) <- surveyEnsembleCorpus
  ]

-- Note [Survey corpus design]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- 'surveyShapeProbes' is a small, fixed set of survey-only single
-- graphs that exists to give --fusion-survey realistic patch shapes
-- without polluting the playable demo list. Demos answer "what
-- plays"; the shape-probe corpus answers "what kernel shape did
-- this graph produce, and which §4.B kernel (if any) claimed it".
--
-- The corpus is grouped by intent:
--
--   * shape/… — single chains and multi-branch graphs that probe
--               which kernel topology a graph produced. Includes
--               both positive cases (existing kernel should claim)
--               and missed-opportunity cases (no kernel today;
--               feeds the future-kernel decision in step 5 of the
--               corpus-driven roadmap).
--   * mod/…   — modulation-heavy probes. Audio-rate signals on
--               control inputs (osc.freq, gain.amount, lpf.cutoff).
--               Some should still claim (matcher narrow enough to
--               ignore the modulation), some intentionally must
--               not (e.g., audio-rate gain amount — scalar-gain
--               gating is intentional).
--   * neg/…   — structural and strategic negatives that must not
--               claim. Multi-consumer producers, non-sink terminals,
--               stateful producers (Env, Smooth, Delay) excluded
--               from §4.B candidacy by the strategy note.
--
-- Intent is encoded in inline comments per graph; the survey reports
-- counts only. If a comment and the survey output disagree, that's a
-- signal to investigate (matcher drift, strategy update, or stale
-- comment) — not to fix the comment without thought.
--
-- These graphs are not run as audio. They flow only through
-- --fusion-survey via 'surveyShapeProbeRows'.
--
-- Multi-template ensembles (cross-template send / return topology)
-- live in 'surveyEnsembleCorpus'; see Note [Template corpus] below
-- for why they're a separate list rather than a sum-typed body.
surveyShapeProbes :: [(String, SynthGraph)]
surveyShapeProbes =
  -- ── shape/: kernel-shape probes (single chains) ───────────────
  [ ( "shape/spectral-freeze-tail"
    , runSynth $ do
        -- §6.D follow-up: surface KSpectralFreeze in the
        -- fusion-survey corpus so the declared-latency view
        -- has something to render. Same passthrough wiring
        -- the slice-1 / slice-2 tests use — a sine into
        -- the spectral kind, freeze flag held at 0, output
        -- to bus 0. The latency footprint reports
        -- KSpectralFreeze @ 1024 samples; no skew (only
        -- one dynamic input).
        s <- sinOsc 220.0 0.0
        f <- spectralFreeze s (Param 0.0)
        out 0 f )                            -- §6.D latency footprint
  , ( "shape/sin-gain-out"
    , runSynth $ do
        s <- sinOsc 220.0 0.0
        a <- gain s 0.4
        out 0 a )                            -- expect: RSinGainOut

  , ( "shape/saw-gain-out"
    , runSynth $ do
        s <- sawOsc 110.0 0.0
        a <- gain s 0.3
        out 0 a )                            -- expect: RSawGainOut

  , ( "shape/noise-gain-out"
    , runSynth $ do
        n <- noiseGen
        a <- gain n 0.2
        out 0 a )                            -- expect: RNoiseGainOut

  , ( "shape/noise-gain-busout"
    , runSynth $ do
        -- BusOut counterpart of shape/noise-gain-out. Same shape
        -- via BusOut sink rather than Out — confirms that producer-
        -- gain claims survive sink-terminal variation.
        n <- noiseGen
        a <- gain n 0.25
        busOut 0 a )                         -- expect: RNoiseGainOut via BusOut

  , ( "shape/saw-lpf-gain-out"
    , runSynth $ do
        s <- sawOsc 110.0 0.0
        f <- lpf s 1200.0 0.7
        a <- gain f 0.4
        out 0 a )                            -- expect: RSawLpfGainOut

  , ( "shape/tri-lpf-gain-out"
    , runSynth $ do
        -- Triangle producer; no kernel today. Probes whether the
        -- tri-rooted filtered tail is a recurring family before any
        -- tri-specific kernel is considered.
        t <- triOsc 220.0 0.0
        f <- lpf t 1200.0 0.7
        a <- gain f 0.3
        out 0 a )                            -- missed opportunity: tri-rooted filtered tail

  , ( "shape/pulse-lpf-gain-busout"
    , runSynth $ do
        -- Pulse producer (square at width=0.5) into LPF tail
        -- terminating at BusOut. No kernel today.
        p <- pulseOsc 110.0 0.0 0.5
        f <- lpf p 1200.0 0.7
        a <- gain f 0.3
        busOut 0 a )                         -- missed opportunity: pulse-rooted filtered tail via BusOut

  , ( "shape/noise-lpf-gain-out"
    , runSynth $ do
        n <- noiseGen
        f <- lpf n 800.0 0.7
        a <- gain f 0.3
        out 0 a )                            -- missed opportunity: Noise→LPF→Gain→Out (RNoiseLpfGainOut candidate)

  , ( "shape/noise-lpf-gain-busout"
    , runSynth $ do
        -- BusOut counterpart of shape/noise-lpf-gain-out. Adds a
        -- second instance of the same shape against the still-
        -- missing kernel; tests whether the recurring shape is
        -- robust to sink-terminal variation, not just hand-authored
        -- against KOut.
        n <- noiseGen
        f <- lpf n 1200.0 0.6
        a <- gain f 0.25
        busOut 0 a )                         -- missed opportunity: same shape via BusOut

  , ( "shape/busin-lpf-gain-out"
    , runSynth $ do
        -- BusIn-rooted return tail terminating at Out. Bus 3 has no
        -- writer in this single-graph corpus, so the BusIn reads
        -- silence at runtime — this entry exercises the matcher on
        -- the shape, /not/ a complete send/return topology. Real
        -- cross-template send/return ensembles live in
        -- 'surveyEnsembleCorpus'.
        r <- busIn 3
        f <- lpf r 1500.0 0.7
        a <- gain f 0.7
        out 0 a )                            -- claims RBusInLpfGainOut (Out variant)

  , ( "shape/busin-lpf-gain-busout"
    , runSynth $ do
        -- BusOut counterpart of shape/busin-lpf-gain-out. Same
        -- BusIn-silence-at-runtime caveat applies.
        r <- busIn 3
        f <- lpf r 2000.0 0.6
        a <- gain f 0.7
        busOut 0 a )                         -- claims RBusInLpfGainOut (BusOut variant)

  , ( "shape/add-saw-noise-lpf-gain-out"
    , runSynth $ do
        -- Mixed-producer probe: saw + noise summed via Add, then
        -- filtered/scaled/sunk. Same "filtered tail" shape as the
        -- saw/noise-rooted variants, but with an Add node ahead of
        -- the LPF, so producer-specific kernels can't claim it.
        -- Exploratory probe only: the current opportunity scanner
        -- ('scanSinkShapes') recognizes SinkOscLpfGain and
        -- SinkBusInLpfGain but has no SinkAddLpfGain row, so this
        -- shape is not classified by the formal candidate gate.
        -- A missed-shape table will only surface this row through
        -- per-graph §4.B coverage, not through the structured
        -- shape census, until the classifier grows an Add-rooted
        -- entry. Useful for asking "does post-mix filtered tail
        -- recur in the corpus?" — kernel decisions still need an
        -- explicit classifier extension.
        s <- sawOsc 110.0 0.0
        n <- noiseGen
        m <- add s n
        f <- lpf m 1200.0 0.7
        a <- gain f 0.25
        out 0 a )                            -- missed opportunity: Add-rooted filtered tail

  -- ── shape/: multi-branch single graphs ────────────────────────
  , ( "shape/three-detuned-saws-summed"
    , runSynth $ do
        -- Each branch is independent; the runtime sums onto bus 0.
        s1 <- sawOsc 110.0 0.0; a1 <- gain s1 0.2; out 0 a1
        s2 <- sawOsc 110.5 0.0; a2 <- gain s2 0.2; out 0 a2
        s3 <- sawOsc 109.5 0.0; a3 <- gain s3 0.2; out 0 a3 )
                                             -- expect: 3 × RSawGainOut

  , ( "shape/additive-sin-saw-noise"
    , runSynth $ do
        s <- sinOsc 220.0 0.0; a1 <- gain s 0.3; out 0 a1
        w <- sawOsc 110.0 0.0; a2 <- gain w 0.3; out 0 a2
        n <- noiseGen;         a3 <- gain n 0.1; out 0 a3 )
                                             -- expect: RSinGainOut + RSawGainOut + RNoiseGainOut

  , ( "shape/single-graph-send-return"
    , runSynth $ do
        -- Voice writes to bus 7; return reads, filters, scales.
        -- Self-contained single graph; the cross-template variant
        -- lives in 'surveyEnsembleCorpus' (ens/two-voices-one-fx
        -- and friends).
        s <- sawOsc 110.0 0.0
        a <- gain s 0.4
        busOut 7 a                           -- voice: RSawGainOut via BusOut sink
        r <- busIn 7
        f <- lpf r 1500.0 0.7
        b <- gain f 0.8
        out 0 b )                            -- return tail: RBusInLpfGainOut

  , ( "shape/single-graph-send-return-two-tails"
    , runSynth $ do
        -- Single voice, two independent filtered return paths
        -- reading the same bus. Each return tail is its own
        -- BusIn→LPF→Gain→sink, so this contributes /two/ rows to
        -- the BusIn-rooted opportunity scan. Self-contained variant
        -- of a stereo/parallel-FX shape.
        s <- sawOsc 110.0 0.0
        a <- gain s 0.4
        busOut 7 a                           -- voice: RSawGainOut via BusOut sink

        r1 <- busIn 7
        f1 <- lpf r1 800.0 0.7
        b1 <- gain f1 0.6
        out 0 b1                             -- return tail 1: RBusInLpfGainOut

        r2 <- busIn 7
        f2 <- lpf r2 2400.0 0.7
        b2 <- gain f2 0.6
        out 1 b2 )                           -- return tail 2: RBusInLpfGainOut

  -- ── mod/: modulation-heavy probes ─────────────────────────────
  , ( "mod/lfo-osc-freq-sin-gain-out"
    , runSynth $ do
        -- LFO feeds the carrier's freq input. The matcher only
        -- inspects port 0 (signal flow) of Gain, so this is
        -- expected to /still/ claim RSinGainOut — useful "control
        -- modulation does not necessarily block fusion" probe.
        lfo <- sinOsc 4.0 0.0
        s   <- sinOsc lfo 0.0
        a   <- gain s 0.3
        out 0 a )                            -- expect: RSinGainOut still fires

  , ( "mod/lfo-lpf-cutoff-saw-lpf-gain-out"
    , runSynth $ do
        -- LFO drives the LPF cutoff. The biquad treats cutoff as
        -- block-rate (zipper artifacts on audio-rate sweeps; see
        -- the note on 'lpf' in Bridge/Source.hs). The current
        -- matcher inspects port 0 (signal flow) of LPF, not the
        -- cutoff input, so this is expected to /still/ claim
        -- RSawLpfGainOut — verified in --fusion-survey output.
        -- Useful negative control: confirms non-Param cutoff does
        -- not block this kernel. If a future change adds an
        -- LPF-control gate to the kernel match, this row stops
        -- claiming.
        lfo <- sinOsc 4.0 0.0
        s   <- sawOsc 110.0 0.0
        f   <- lpf s lfo 0.7
        a   <- gain f 0.4
        out 0 a )                            -- expect: RSawLpfGainOut still fires

  , ( "mod/audio-rate-gain-control"
    , runSynth $ do
        -- Gain amount is an audio-rate signal (LFO), not a Param;
        -- isScalarGain blocks the match. Strategy: scalar-gain
        -- gating is intentional — this should remain a miss.
        s   <- sinOsc 220.0 0.0
        lfo <- sinOsc 4.0   0.0
        a   <- gain s lfo
        out 0 a )                            -- unclaimed: gain control not Param

  , ( "mod/audio-rate-gain-control-filtered"
    , runSynth $ do
        -- 4-node counterpart of mod/audio-rate-gain-control:
        -- audio-rate signal feeds the gain's amount in a
        -- producer→LPF→Gain→sink chain. isScalarGain must block
        -- the match exactly as it does in the 3-node case.
        n   <- noiseGen
        f   <- lpf n 1000.0 0.7
        lfo <- sinOsc 4.0 0.0
        a   <- gain f lfo
        out 0 a )                            -- unclaimed: gain control not Param

  -- ── mod/: §4.D.2 edge-rate survey shaping (not kernel evidence) ─
  --
  -- These four entries exist to populate the §4.D.2 edge-rate
  -- buckets with realistic modulation patterns. They are not meant
  -- to drive kernel decisions — Tri/Pulse/Add-style §4.B kernel
  -- additions are gated on the missed-shape table, which is a
  -- different signal. The point here is to shape the input-
  -- consumption survey: how often does a sample-rate producer
  -- land at a block-latched (LPF freq/q) or init-only port?

  , ( "mod/env-cutoff-noise-lpf-gain-out"
    , runSynth $ do
        -- Filter envelope sweep: an Env's gate-driven output is
        -- treated as a sample-rate producer by 'propagateRates'
        -- (KEnv floor is SampleRate), but the LPF reads its cutoff
        -- only at sample 0 of each block. The Env→LPF.freq edge is
        -- the textbook §4.D.2 SampleRate→PortBlockLatched bucket
        -- entry. Per-block work cost: nframes of Env state
        -- advance for one cutoff value the runtime actually
        -- consumes — exactly the discrepancy the survey is
        -- designed to surface.
        e <- env (Param 1.0) 0.005 0.05 0.7 0.5
        n <- noiseGen
        f <- lpf n e (Param 4.0)
        a <- gain f (Param 0.4)
        out 0 a )

  , ( "mod/smooth-cutoff-saw-lpf-gain-out"
    , runSynth $ do
        -- Smooth-driven cutoff sweep. 'smooth' takes a base
        -- frequency and a target value; its output is sample-rate
        -- (KSmooth floor) but, like the env case, the LPF only
        -- reads cutoff at sample 0. Same SampleRate→PortBlockLatched
        -- shape as the env probe but driven by a different
        -- producer kind, so the survey can tell whether the
        -- block-latched-cutoff opportunity comes from one
        -- producer family or several.
        c <- smooth 30.0 1200.0
        s <- sawOsc 110.0 0.0
        f <- lpf s c (Param 4.0)
        a <- gain f (Param 0.4)
        out 0 a )

  , ( "mod/tremolo-gain-biased-lfo"
    , runSynth $ do
        -- Realistic tremolo: a bipolar LFO, biased and scaled into
        -- the [0, 1] range, modulating Gain.amount. Gain.amount is
        -- /sample-accurate/ when wired (PortSampleAccurate per
        -- §4.D.2), so this produces a SampleRate→SampleRate edge
        -- regardless of how block-latched-looking the patch shape
        -- feels. The contrast with the cutoff cases above pins
        -- the per-port-policy distinction the survey measures:
        -- "modulation by an LFO" doesn't imply "block-latched
        -- consumption" — that's a destination property.
        lfo    <- sinOsc 5.0 0.0
        scaled <- gain  lfo (Param 0.4)        -- ±0.4 around 0
        depth  <- add   scaled (Param 0.5)     -- bias into [0.1, 0.9]
        s      <- sawOsc 110.0 0.0
        a      <- gain s depth
        out 0 a )

  , ( "mod/pwm-lfo-into-pulsewidth"
    , runSynth $ do
        -- Pulse-width modulation: an LFO drives a pulse osc's
        -- width input. PulseOsc.width is sample-accurate when
        -- wired (PortSampleAccurate), so this is another
        -- SampleRate→SampleRate edge — useful as a paired
        -- counter-example to the env/smooth → LPF.freq cases.
        -- Width = bipolar LFO biased into [0.1, 0.9]; same biasing
        -- pattern as the tremolo probe so the modulation chain is
        -- musically realistic.
        lfo    <- sinOsc 0.7 0.0
        scaled <- gain  lfo (Param 0.4)
        wmod   <- add   scaled (Param 0.5)
        p      <- pulseOsc 110.0 0.0 wmod
        a      <- gain p (Param 0.3)
        out 0 a )

  -- ── sched/: §4.E.C1d region-layer probes ─────────────────────
  , ( "sched/free-only-parallel-compute"
    , runSynth $ do
        -- Two independent buffer-terminal compute chains and no
        -- sink. Region-kernel selection keeps each Saw→LPF→Gain
        -- chain as a separate sink-free region; the layered
        -- schedule can put them in the same FreeLayer. This is a
        -- Haskell-loaded counterpart to the C1c free-compute bench:
        -- direct mode can dispatch it without deterministic bus
        -- reduction, provided there are multiple live instances to
        -- make the runtime global band multi-entry.
        s1 <- sawOsc 110.0 0.0
        f1 <- lpf s1 (Param 800.0)  (Param 4.0)
        _  <- gain f1 (Param 0.4)

        s2 <- sawOsc 220.0 0.0
        f2 <- lpf s2 (Param 1200.0) (Param 4.0)
        _  <- gain f2 (Param 0.3)
        pure () )

  , ( "sched/parallel-compute-before-master"
    , runSynth $ do
        -- Real output-bearing target shape for corpus evolution:
        -- two independent sink-free compute regions are ready
        -- before a later master sink barrier. One branch feeds a
        -- dependent follow-up filter, the other is independent, so
        -- the layered schedule has a width-2 FreeLayer before the
        -- final Add→Out path. This proves the corpus can now expose
        -- the shape "independent compute before a later barrier",
        -- even though C1c's current runtime dispatch unit is still
        -- a global schedule entry rather than each region inside one
        -- FreeLayer step.
        s1 <- sawOsc 110.0 0.0
        f1 <- lpf s1 (Param 800.0)  (Param 4.0)
        g1 <- gain f1 (Param 0.4)

        f2 <- lpf g1 (Param 1500.0) (Param 4.0)
        g2 <- gain f2 (Param 0.4)

        s3 <- sawOsc 220.0 0.0
        f3 <- lpf s3 (Param 1000.0) (Param 4.0)
        g3 <- gain f3 (Param 0.4)

        summed <- add g2 g3
        out 0 summed )

  , ( "sched/poly-voices-master-fx"
    , runSynth $ do
        -- Less synthetic C1d target: three independent synth voices
        -- do their oscillator/filter/gain work before a shared
        -- master filter/sink. Each voice is an ordinary
        -- Saw→LPF→Gain chain; the shared master tail is the
        -- barrier. This is the single-graph counterpart of
        -- "polyphonic voices into one master FX" from ROADMAP.md.
        v1s <- sawOsc 110.0 0.0
        v1f <- lpf v1s (Param 700.0)  (Param 4.0)
        v1  <- gain v1f (Param 0.24)

        v2s <- sawOsc 165.0 0.0
        v2f <- lpf v2s (Param 1100.0) (Param 4.0)
        v2  <- gain v2f (Param 0.20)

        v3s <- sawOsc 220.0 0.0
        v3f <- lpf v3s (Param 1600.0) (Param 4.0)
        v3  <- gain v3f (Param 0.16)

        m12 <- add v1 v2
        mix <- add m12 v3
        mf  <- lpf mix (Param 1800.0) (Param 0.8)
        ma  <- gain mf (Param 0.6)
        out 0 ma )

  , ( "sched/parallel-fx-rack-master"
    , runSynth $ do
        -- Less synthetic C1d target: independent pre-master
        -- processing lanes that resemble a compact parallel FX
        -- rack. Each lane has real DSP work before the shared
        -- master mix; the useful question is whether C1d should
        -- split one FreeLayer step into region work units, because
        -- C1c's global-entry dispatch cannot see inside this layer.
        lowS <- sawOsc 82.5 0.0
        lowF <- lpf lowS (Param 450.0) (Param 3.0)
        low  <- gain lowF (Param 0.30)

        midS <- sawOsc 165.0 0.2
        midF <- lpf midS (Param 1400.0) (Param 2.5)
        mid  <- gain midF (Param 0.22)

        hiS  <- sawOsc 330.0 0.4
        hiF  <- lpf hiS (Param 2600.0) (Param 1.5)
        hi   <- gain hiF (Param 0.14)

        lm   <- add low mid
        mix  <- add lm hi
        bus  <- gain mix (Param 0.7)
        out 0 bus )

  -- ── neg/: structural negatives ────────────────────────────────
  , ( "neg/shared-producer-two-gains"
    , runSynth $ do
        s  <- sawOsc 110.0 0.0
        a1 <- gain s 0.3; out 0 a1
        a2 <- gain s 0.2; out 1 a2 )
                                             -- unclaimed: producer has multiple consumers

  , ( "neg/gain-feeds-two-sinks"
    , runSynth $ do
        s <- sawOsc 110.0 0.0
        a <- gain s 0.3
        out    0 a
        busOut 7 a )
                                             -- unclaimed: gain has multiple consumers

  , ( "neg/shared-lpf-feeds-two-gains"
    , runSynth $ do
        -- Filtered-tail counterpart of neg/shared-producer-two-
        -- gains: one LPF feeds two parallel Gain→Out chains. The
        -- LPF's multi-consumer count must block the 4-node match
        -- on both chains. If a future change relaxes the single-
        -- consumer precondition for the filter node, this row
        -- starts firing.
        n  <- noiseGen
        f  <- lpf n 1000.0 0.7
        a1 <- gain f 0.3; out 0 a1
        a2 <- gain f 0.2; out 1 a2 )
                                             -- unclaimed: LPF multi-consumer blocks classification

  , ( "neg/non-sink-terminal"
    , runSynth $ do
        -- Sin→Gain doesn't end at a sink kernel: another node (Add)
        -- sits between the gain and Out. Sink-terminal matchers
        -- must not claim the sin→gain pair because its terminal is
        -- Add, not Out/BusOut. Exercises the strategy exclusion
        -- "non-sink terminal".
        s <- sinOsc 220.0 0.0
        a <- gain s 0.4
        n <- noiseGen
        b <- gain n 0.1
        m <- add a b
        out 0 m )                            -- unclaimed: gain feeds Add, not sink

  -- ── neg/: stateful producers (strategy exclusions) ────────────
  , ( "neg/env-gain-out"
    , runSynth $ do
        e <- env (Param 1.0) 0.0005 0.002 1.0 0.002
        a <- gain e 0.4
        out 0 a )                            -- unclaimed: Env excluded by strategy

  , ( "neg/smooth-gain-out"
    , runSynth $ do
        v <- smooth 50.0 0.5
        a <- gain v 0.4
        out 0 a )                            -- unclaimed: Smooth excluded

  , ( "neg/delay-gain-out"
    , runSynth $ do
        s <- sinOsc 220.0 0.0
        d <- delayL 0.1 s 0.02
        a <- gain d 0.4
        out 0 a )                            -- unclaimed: Delay stateful, excluded
  ]

-- | Compile every entry in 'surveyShapeProbes', stamping each row's demo
-- key with a "corpus:" prefix so the unified survey table makes the
-- source obvious. Errors are surfaced the same way as for demos.
surveyShapeProbeRows :: [Either String SurveyRow]
surveyShapeProbeRows =
  [ surveySynthGraph ("corpus:" <> name) Nothing g
  | (name, g) <- surveyShapeProbes
  ]

-- Note [Template corpus]
-- ~~~~~~~~~~~~~~~~~~~~~~
-- 'surveyEnsembleCorpus' is the multi-template counterpart of
-- 'surveyShapeProbes'. Each entry is a named ensemble of (template-name,
-- SynthGraph) pairs that mirrors how a real cross-template send /
-- return ensemble compiles: voice templates write to a shared bus,
-- fx templates read from it. This is the topology that BusIn-rooted
-- chains naturally arise from in practice.
--
-- Why a separate list rather than wrapping 'surveyShapeProbes' in a
-- sum-type body: keeping single-graph and multi-template entries
-- in two parallel lists means existing 'surveyShapeProbes' entries
-- stay untouched, and the survey driver concatenates rows from
-- both. The trade-off is one extra type signature; the upside is
-- zero churn on the 20 single-graph entries.
--
-- Per-row keying: each template inside an ensemble produces one
-- 'SurveyRow' with demo = "corpus:<ensemble-name>" and template =
-- Just <template-name>. That mirrors how the existing send-return
-- demo already shows up in the per-row table (one row per
-- template, sharing a demo key).
--
-- Like 'surveyShapeProbes', these graphs are not run as audio. Each
-- template is compiled as a standalone 'SynthGraph' for the
-- survey, so a voice template's BusOut writes to "nowhere" and an
-- fx template's BusIn reads silence. That's the same trick
-- 'surveyDemo' uses for the playable send-return demo — the
-- matcher only inspects per-template structure, not cross-template
-- runtime values.
surveyEnsembleCorpus :: [(String, [(String, SynthGraph)])]
surveyEnsembleCorpus =
  -- Direct-out ensembles stress sink kernels in each template.
  -- Bus-send ensembles stress shared-bus dataflow and template
  -- precedence DAG width; their cross-template width is the
  -- template precedence width reported by templateScheduleStats
  -- in the §4.E.2c survey section.
  [ ( "ens/two-voices-one-fx"
    , [ ( "voice-low"
        , runSynth $ do
            s <- sawOsc 110.0 0.0
            a <- gain s 0.3
            busOut 7 a )                     -- claims RSawGainOut via BusOut

      , ( "voice-high"
        , runSynth $ do
            s <- sawOsc 220.0 0.0
            a <- gain s 0.3
            busOut 7 a )                     -- claims RSawGainOut via BusOut

      , ( "fx"
        , runSynth $ do
            r <- busIn 7
            f <- lpf r 1200.0 0.7
            a <- gain f 0.6
            out 0 a )                        -- BusIn→LPF→Gain→sink candidate
      ]
    )

  , ( "ens/four-voices-one-fx"
    , -- Scaled-up two-voices-one-fx. Four independent voice
      -- templates write to bus 7; one fx template reads. Tests
      -- whether template precedence width grows with voice count
      -- (expected: width 4 at layer 0, then fx at layer 1) and
      -- whether the §4.B per-template kernel claims hold up across
      -- a larger ensemble.
      [ ( "voice-1"
        , runSynth $ do
            s <- sawOsc 110.0 0.0
            a <- gain s 0.25
            busOut 7 a )                     -- claims RSawGainOut via BusOut
      , ( "voice-2"
        , runSynth $ do
            s <- sawOsc 165.0 0.0
            a <- gain s 0.25
            busOut 7 a )                     -- claims RSawGainOut via BusOut
      , ( "voice-3"
        , runSynth $ do
            s <- sawOsc 220.0 0.0
            a <- gain s 0.25
            busOut 7 a )                     -- claims RSawGainOut via BusOut
      , ( "voice-4"
        , runSynth $ do
            s <- sawOsc 277.0 0.0
            a <- gain s 0.25
            busOut 7 a )                     -- claims RSawGainOut via BusOut
      , ( "fx"
        , runSynth $ do
            r <- busIn 7
            f <- lpf r 1200.0 0.7
            a <- gain f 0.5
            out 0 a )                        -- BusIn→LPF→Gain→sink candidate
      ]
    )

  , ( "ens/one-voice-two-parallel-fx"
    , [ ( "voice"
        , runSynth $ do
            s <- sawOsc 110.0 0.0
            a <- gain s 0.4
            busOut 7 a )                     -- claims RSawGainOut via BusOut

      , ( "fx-low"
        , runSynth $ do
            r <- busIn 7
            f <- lpf r 800.0 0.7
            a <- gain f 0.6
            out 0 a )                        -- BusIn→LPF→Gain→sink candidate

      , ( "fx-high"
        , runSynth $ do
            r <- busIn 7
            f <- lpf r 2400.0 0.7
            a <- gain f 0.6
            out 1 a )                        -- BusIn→LPF→Gain→sink candidate
      ]
    )

  , ( "ens/stereo-send-return"
    , [ ( "voice-l"
        , runSynth $ do
            s <- sawOsc 110.0 0.0
            a <- gain s 0.3
            busOut 7 a )                     -- claims RSawGainOut via BusOut

      , ( "voice-r"
        , runSynth $ do
            s <- sawOsc 110.5 0.0
            a <- gain s 0.3
            busOut 8 a )                     -- claims RSawGainOut via BusOut

      , ( "fx-l"
        , runSynth $ do
            r <- busIn 7
            f <- lpf r 1200.0 0.7
            a <- gain f 0.6
            out 0 a )                        -- BusIn→LPF→Gain→sink candidate

      , ( "fx-r"
        , runSynth $ do
            r <- busIn 8
            f <- lpf r 1200.0 0.7
            a <- gain f 0.6
            out 1 a )                        -- BusIn→LPF→Gain→sink candidate
      ]
    )

  , -- Three independent voice templates writing direct to Out
    -- (no fx, no internal-bus dataflow). Stresses sink-kernel
    -- claims in every template. Template precedence DAG has no
    -- edges (no template reads what another writes), so
    -- precedence width = template count = 3. /Caveat for any
    -- future parallel runtime/: voice-sin and voice-saw both
    -- write @out 0@; that is a shared write target, just at the
    -- hardware-output bus rather than an internal bus. Same-layer
    -- sink writes still need either serialization or per-worker
    -- accumulation with deterministic reduction. The "no live-
    -- read precedence between same-layer templates" fact is what
    -- the precedence-DAG width measures; the "no shared write
    -- target" property does not hold here.
    ( "ens/layered-direct-outs"
    ,
      [ ( "voice-sin"
        , runSynth $ do
            s <- sinOsc 220.0 0.0
            a <- gain s 0.3
            out 0 a )                        -- claims RSinGainOut
      , ( "voice-saw"
        , runSynth $ do
            s <- sawOsc 110.0 0.0
            a <- gain s 0.3
            out 0 a )                        -- claims RSawGainOut
      , ( "voice-noise"
        , runSynth $ do
            n <- noiseGen
            a <- gain n 0.1
            out 1 a )                        -- claims RNoiseGainOut
      ]
    )

  , -- Three voice/return pairs on three distinct internal buses
    -- (7, 8, 9). No template depends on another's bus, so each
    -- pair is its own precedence chain (voice→fx) and the three
    -- pairs sit at the same precedence layer. Stresses parallel
    -- bus-write/bus-read fan-out across independent internal-bus
    -- targets — a clean counterpoint to ens/four-voices-one-fx,
    -- where four voices /share/ bus 7. /Caveat for any future
    -- parallel runtime/: fx-a and fx-b both write @out 0@, so
    -- the shared-write-target problem is not absent from this
    -- ensemble — it just shows up at the hardware-output bus
    -- rather than an internal bus. Same-layer sink writes still
    -- need serialization or per-worker accumulation with
    -- deterministic reduction; the precedence DAG only proves
    -- the absence of /live-read/ precedence between same-layer
    -- templates.
    ( "ens/layered-bus-sends"
    ,
      [ ( "voice-a"
        , runSynth $ do
            s <- sawOsc 110.0 0.0
            a <- gain s 0.3
            busOut 7 a )                     -- claims RSawGainOut via BusOut
      , ( "voice-b"
        , runSynth $ do
            s <- sawOsc 165.0 0.0
            a <- gain s 0.3
            busOut 8 a )                     -- claims RSawGainOut via BusOut
      , ( "voice-c"
        , runSynth $ do
            s <- sawOsc 220.0 0.0
            a <- gain s 0.3
            busOut 9 a )                     -- claims RSawGainOut via BusOut
      , ( "fx-a"
        , runSynth $ do
            r <- busIn 7
            f <- lpf r 800.0 0.7
            a <- gain f 0.5
            out 0 a )                        -- BusIn→LPF→Gain→sink candidate
      , ( "fx-b"
        , runSynth $ do
            r <- busIn 8
            f <- lpf r 1500.0 0.7
            a <- gain f 0.5
            out 0 a )                        -- BusIn→LPF→Gain→sink candidate
      , ( "fx-c"
        , runSynth $ do
            r <- busIn 9
            f <- lpf r 2400.0 0.7
            a <- gain f 0.5
            out 1 a )                        -- BusIn→LPF→Gain→sink candidate
      ]
    )

  , ( "ens/voice-noise-return"
    , -- Voice on bus 7, plus a noise-rooted parallel layer
      -- writing direct to Out. Two independent template chains —
      -- the voice→fx pair has internal precedence; the noise
      -- layer has none. Useful "non-fx ambient layer next to a
      -- send/return" probe.
      [ ( "voice"
        , runSynth $ do
            s <- sawOsc 110.0 0.0
            a <- gain s 0.4
            busOut 7 a )                     -- claims RSawGainOut via BusOut
      , ( "voice-fx"
        , runSynth $ do
            r <- busIn 7
            f <- lpf r 1200.0 0.7
            a <- gain f 0.6
            out 0 a )                        -- BusIn→LPF→Gain→sink candidate
      , ( "noise-layer"
        , runSynth $ do
            n <- noiseGen
            f <- lpf n 600.0 0.7
            a <- gain f 0.1
            out 1 a )                        -- missed opportunity: Noise→LPF→Gain→sink
      ]
    )
  ]

-- | Compile every (ensemble, template) pair in
-- 'surveyEnsembleCorpus' into a 'SurveyRow', stamping the demo key
-- with "corpus:" and the ensemble name, and putting the template
-- name in the template column. One row per template; ensembles are
-- not summarized — the per-template granularity is what makes
-- BusIn-rooted return tails legible.
surveyEnsembleCorpusRows :: [Either String SurveyRow]
surveyEnsembleCorpusRows =
  [ surveySynthGraph ("corpus:" <> ensembleName) (Just templateName) g
  | (ensembleName, templates) <- surveyEnsembleCorpus
  , (templateName, g)         <- templates
  ]

-- Top-level entry for the --fusion-survey mode. Produces the
-- per-template summary, a sink-terminal opportunity table, and
-- aggregate totals. Compile failures are surfaced explicitly:
-- they're not counted in the totals (because we have no graph to
-- count) but they /are/ reported in a dedicated banner so a
-- failed-but-targeted graph doesn't silently lower aggregate
-- coverage. Exits with status 1 if any survey row failed, since
-- the resulting numbers are by definition incomplete.
--
-- The corpus ('surveyShapeProbes' + 'surveyEnsembleCorpus' — fixed sets
-- of survey-only graphs designed to exercise §4.B kernel coverage on
-- realistic patches) is always included regardless of demo
-- targeting. Corpus rows exist for coverage measurement, not
-- playback, and stripping them when the user names a specific demo
-- would defeat their purpose. Template-corpus ensembles contribute
-- one row per template and roll up into the corpus subtotal.
runFusionSurvey :: [Demo] -> IO ()
runFusionSurvey demos = do
  let demoResults              = concatMap surveyDemo demos
      corpusResults            =
        surveyShapeProbeRows <> surveyEnsembleCorpusRows
      (demoErrs,   demoRows)   = partitionEithers demoResults
      (corpusErrs, corpusRows) = partitionEithers corpusResults
      allRows                  = demoRows <> corpusRows

      ensembleResults          =
        concatMap surveyDemoEnsembles demos
        <> surveyEnsembleCorpusScheduleRows
      (ensembleErrs, ensembleRows) = partitionEithers ensembleResults

      allErrs                  =
        demoErrs <> corpusErrs <> ensembleErrs
  putStrLn ""
  printSurveyTable allRows
  putStrLn ""
  printOpportunityScan allRows
  putStrLn ""
  printScheduleWidth allRows
  putStrLn ""
  printCorpusRegionLayerWidth allRows
  putStrLn ""
  printEnsembleScheduleWidth ensembleRows
  putStrLn ""
  printRateDistribution allRows
  putStrLn ""
  printEdgeRateDistribution allRows
  putStrLn ""
  printDeclaredLatency allRows
  putStrLn ""
  printCapabilityFootprint allRows
  putStrLn ""
  printPlannerVerdicts allRows
  putStrLn ""
  costLabRows <- FCL.collectFusionCostLabRows FCL.defaultOptions
  let shapeIdx = costLabShapeIndex costLabRows
      gateIdx  = costLabGateIndex  costLabRows
  printCostModelJoin shapeIdx allRows
  putStrLn ""
  printProfitabilityGate gateIdx allRows
  putStrLn ""
  printProfitabilityGateByExecutor costLabRows allRows
  putStrLn ""
  printSurveyTotals demoRows corpusRows
  putStrLn ""
  printAuthoringSurvey demos
  case allErrs of
    [] -> putStrLn "Done."
    es -> do
      putStrLn "─── Survey failures ───"
      mapM_ (\e -> putStrLn ("  " <> e)) es
      putStrLn ""
      die $ "Done with " <> show (length es)
          <> " compile failure(s); coverage totals above exclude them."

-- Per-template table.
printSurveyTable :: [SurveyRow] -> IO ()
printSurveyTable rows = do
  putStrLn "─── Per-template fusion summary ───"
  putStrLn $ formatSurveyRow
    [ "demo", "template", "nodes", "regs"
    , "§4.B-regs", "§4.B-cov", "§4.C-elide", "§4.C-RFused", "kernels"
    ]
  mapM_ (putStrLn . formatSurveyRow . renderSurveyRow) rows

renderSurveyRow :: SurveyRow -> [String]
renderSurveyRow r =
  [ srDemo r
  , maybe "" id (srTemplate r)
  , show (srNodes r)
  , show (srRegions r)
  , show (srFusedRegions r)
  , covPct (srClaimedNodes r) (srNodes r)
  , show (srElided r)
  , show (srRFused r)
  , kernelTallyText (srKernels r)
  ]

covPct :: Int -> Int -> String
covPct _ 0 = "—"
covPct c n = show ((c * 100) `div` n) <> "%"

kernelTallyText :: [(RegionKernel, Int)] -> String
kernelTallyText [] = "—"
kernelTallyText xs =
  intercalate ", " [show k <> "×" <> show n | (k, n) <- xs]

formatSurveyRow :: [String] -> String
formatSurveyRow cols =
  intercalate "  " (zipWith pad surveyColumnWidths cols)
  where
    pad w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

-- Column 1 is wide enough to fit the longest 'corpus:*' key in
-- 'surveyShapeProbes' (~38 chars) plus a couple of characters of slack.
-- If a future corpus entry needs a longer name, bump the first
-- entry rather than letting the row shove later columns right.
surveyColumnWidths :: [Int]
surveyColumnWidths = [42, 14, 5, 5, 9, 8, 10, 11, 30]

-- Ranked sink-terminal opportunity scan. For each 'SinkShape' in
-- 'allKnownShapes', the survey reports:
--
--   found     total occurrences across all surveyed graphs
--   claimed   occurrences where the chain landed in a §4.B fused region
--   missed    found − claimed
--   sources   number of distinct demo / corpus / ensemble entries
--             ('srDemo') that contained at least one instance. Multi-
--             template ensembles count as /one/ source even if several
--             templates contribute the same shape — three misses from
--             one synthetic graph is weaker signal than three misses
--             from three independent patch families (per the candidate
--             gate in notes/2026-05-08-e-fusion-strategy.md).
--   status    'covered' (kernel exists), 'candidate' (no kernel; gate
--             passed: missed ≥ 3 ∧ sources ≥ 3), or 'no-signal' (no
--             kernel; gate not yet met).
--   next      the action implied by the status. 'already-covered',
--             'benchmark' (start kernel evaluation), 'grow-corpus'
--             (need more independent shape sources before deciding),
--             or 'investigate' (kernel exists but didn't claim — a
--             §4.B precondition surprise that warrants a look).
--
-- Rows are ordered candidate → no-signal → covered, then by missed
-- desc, then by sources desc, then by 'allKnownShapes' display index.
-- Rows with @found = 0@ are dropped /unless/ a kernel exists, so the
-- existing kernel set always shows up even when nothing exercises it.
printOpportunityScan :: [SurveyRow] -> IO ()
printOpportunityScan rows = do
  putStrLn "─── Ranked missed-shape table ───"
  putStrLn $ formatScanRow
    [ "shape", "found", "claimed", "missed", "sources"
    , "status", "next", "chain-caps"
    ]
  mapM_ (putStrLn . formatScanRow) (scanRows rows)
  where
    formatScanRow cols =
      intercalate "  " (zipWith padCell scanColumnWidths cols)
    padCell w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

scanColumnWidths :: [Int]
scanColumnWidths = [32, 6, 8, 7, 8, 10, 16, 18]

-- 'ScanStat' is the per-shape aggregate that drives the ranked
-- table. Built once and reused for the row, the gate evaluation,
-- and the sort key, so sort order and rendered status can never
-- disagree.
data ScanStat = ScanStat
  { scShape   :: !SinkShape
  , scFound   :: !Int
  , scClaimed :: !Int
  , scMissed  :: !Int
  , scSources :: !Int
  } deriving (Eq, Show)

scanStats :: [SurveyRow] -> [ScanStat]
scanStats rows =
  [ ScanStat
      { scShape   = sh
      , scFound   = length matching
      , scClaimed = length [c | (c, _) <- matching, c]
      , scMissed  = length [c | (c, _) <- matching, not c]
      , scSources = length (nub [demo | (_, demo) <- matching])
      }
  | sh <- allKnownShapes
  , let matching =
          [ (claimed, srDemo r)
          | r <- rows
          , (s, claimed) <- srShapes r
          , s == sh
          ]
  ]

-- Status: 'covered' is purely a kernel-existence statement; the
-- candidate gate from notes/2026-05-08-e-fusion-strategy.md applies only when
-- no kernel claims the shape. 'no-signal' covers both "shape never
-- appeared" (kept in the table only when a kernel exists) and
-- "shape appeared but the gate didn't pass yet".
scanStatus :: ScanStat -> String
scanStatus st
  | shapeHasKernel (scShape st)                      = "covered"
  | scMissed st >= 3 && scSources st >= 3            = "candidate"
  | otherwise                                        = "no-signal"

-- Next action is mostly a dispatch on status, with one exception:
-- 'covered' rows whose kernel didn't claim every instance get
-- 'investigate', because that means a §4.B precondition slipped
-- past the scanner's preconditions on at least one chain.
scanNext :: ScanStat -> String
scanNext st = case scanStatus st of
  "covered"
    | scMissed st > 0 -> "investigate"
    | otherwise       -> "already-covered"
  "candidate"         -> "benchmark"
  _                   -> "grow-corpus"

scanRows :: [SurveyRow] -> [[String]]
scanRows rows =
  [ [ renderShape (scShape st)
    , show (scFound   st)
    , show (scClaimed st)
    , show (scMissed  st)
    , show (scSources st)
    , scanStatus st
    , scanNext   st
    , intercalate "," (map renderCapAbbr (shapeCapabilities (scShape st)))
    ]
  | st <- sortRanked
            [ st
            | st <- scanStats rows
            , scFound st > 0 || shapeHasKernel (scShape st)
            ]
  ]
  where
    statusRank st = case scanStatus st of
      "candidate" -> 0
      "no-signal" -> 1
      _           -> 2  -- "covered"
    -- Display index from 'allKnownShapes' so ties resolve to the
    -- documented family order (3-node oscs, 4-node oscs, BusIn,
    -- Add).
    displayIx sh = case lookup sh (zip allKnownShapes [0 :: Int ..]) of
      Just i  -> i
      Nothing -> length allKnownShapes
    sortRanked =
      sortOn $ \st ->
        ( statusRank st
        , negate (scMissed  st)
        , negate (scSources st)
        , displayIx (scShape st)
        )

-- §4.E.2c parallel-readiness section. One row per surveyed graph,
-- plus a footer with aggregate counts and the maximum free-segment
-- and free-layer widths across the whole survey.
--
--   total : total runtime regions in the graph
--   B     : barrier regions (live-bus — KOut / KBusOut / KBusIn)
--   F     : free regions (non-barrier; admit topological reorder)
--   segs  : number of maximal free runs between barriers
--   maxSW : widest free segment, in regions
--   maxLW : widest topological /layer/ within any free segment.
--           This is the realistic parallel-work upper bound: a
--           pure chain has layer width 1 even when the segment
--           is wide, so a graph with @maxLW = 1@ everywhere has
--           no parallelism a worker pool could exploit.
--   runW  : widest full free layer with no shared-write hazards;
--           this is runnable without deterministic reduction.
--   redW  : widest full free layer with at least one shared-write
--           hazard; this is width that would need deterministic
--           reduction or serialization.
--   haz   : count of same-layer same-bus write hazards.
--
-- The headline numbers for "is a worker pool worth building yet"
-- are the survey-wide @max(runW)@ and @max(redW)@ in the footer.
-- The former is directly runnable under the current shared-bus
-- model; the latter is potential parallel width gated on a future
-- deterministic reduction policy.
printScheduleWidth :: [SurveyRow] -> IO ()
printScheduleWidth rows = do
  putStrLn "─── Schedule width (§4.E.2c parallel-readiness) ───"
  putStrLn $ formatScheduleRow
    [ "demo", "template"
    , "total", "B", "F", "segs", "maxSW", "maxLW"
    , "runW", "redW", "haz"
    ]
  mapM_ (putStrLn . formatScheduleRow . renderScheduleRow) rows
  putStrLn ""
  -- Footer: total counts via 'addScheduleStats' (sums counts,
  -- maxes widths) so the maxSW / maxLW columns show the widest
  -- single opportunity anywhere in the survey.
  let agg = foldr addScheduleStats emptyScheduleStats
              (map srSchedStats rows)
  putStrLn $ "  totals: "
          <> "graphs="    <> show (length rows)
          <> "  total="   <> show (rssTotal               agg)
          <> "  B="       <> show (rssBarriers            agg)
          <> "  F="       <> show (rssFree                agg)
          <> "  segs="    <> show (rssFreeSegments        agg)
          <> "  maxSW="   <> show (rssMaxFreeSegmentWidth agg)
          <> "  maxLW="   <> show (rssMaxFreeLayerWidth   agg)
          <> "  runW="    <> show (rssMaxRunnableLayerWidth agg)
          <> "  redW="    <> show (rssMaxReductionLayerWidth agg)
          <> "  haz="     <> show (rssSharedWriteHazards  agg)

renderScheduleRow :: SurveyRow -> [String]
renderScheduleRow r =
  let s = srSchedStats r
  in [ srDemo r
     , maybe "" id (srTemplate r)
     , show (rssTotal               s)
     , show (rssBarriers            s)
     , show (rssFree                s)
     , show (rssFreeSegments        s)
     , show (rssMaxFreeSegmentWidth s)
     , show (rssMaxFreeLayerWidth   s)
     , show (rssMaxRunnableLayerWidth s)
     , show (rssMaxReductionLayerWidth s)
     , show (rssSharedWriteHazards  s)
     ]

-- Mirrors 'surveyColumnWidths' in shape but narrower — the
-- schedule columns are all small integers.
scheduleColumnWidths :: [Int]
scheduleColumnWidths = [42, 14, 6, 4, 4, 5, 6, 6, 5, 5, 4]

formatScheduleRow :: [String] -> String
formatScheduleRow cols =
  intercalate "  " (zipWith pad scheduleColumnWidths cols)
  where
    pad w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

-- Corpus-only region-layer shape report. The existing schedule-width
-- table mixes demos and corpus rows; this section is the decision input
-- for C1d follow-up work and therefore keeps the fixed corpus rows
-- isolated from whatever demo subset the user requested.
--
-- Columns:
--   bands    : free-layer count from 'layeredRegionSchedule'
--   sf       : sink-free bands (direct mode can dispatch these)
--   sink     : bands with at least one sink writer
--   maxSfW   : widest sink-free band
--   maxSinkW : widest sink-bearing band
--   maxWork  : max node-count work estimate inside one band
--   dirC1d   : sink-free region layers with width >= 2
--   redC1d   : sink-bearing region layers with width >= 2
--
-- 'dirC1d' / 'redC1d' are not current worker-dispatch counters. They
-- mark shapes a future C1d executor would need to split inside a
-- single global schedule entry. Current C1c worker dispatch is measured
-- by '--worker-bench' counters (`parallel_bands`, `parallel_entries`).
-- 'redC1d' is also not a recommendation to enable reduction-backed
-- worker dispatch; the turn-on decision keeps that path test-only.
printCorpusRegionLayerWidth :: [SurveyRow] -> IO ()
printCorpusRegionLayerWidth rows = do
  let corpusRows = filter (("corpus:" `isPrefixOf`) . srDemo) rows
  putStrLn "─── Corpus FreeLayer-width survey (§4.E.C1d region candidates) ───"
  putStrLn $ formatRegionLayerRow
    [ "corpus", "template", "bands", "sf", "sink"
    , "maxSfW", "maxSinkW", "maxWork", "dirC1d", "redC1d"
    ]
  mapM_ (putStrLn . formatRegionLayerRow . renderRegionLayerRow) corpusRows
  putStrLn ""
  let agg = foldr addRegionLayerStats emptyRegionLayerStats
              (map srRegionLayer corpusRows)
  putStrLn $ "  totals: "
          <> "graphs="  <> show (length corpusRows)
          <> "  bands=" <> show (rlsFreeBands agg)
          <> "  sf="    <> show (rlsSinkFreeBands agg)
          <> "  sink="  <> show (rlsSinkBands agg)
          <> "  maxSfW="   <> show (rlsMaxSinkFreeWidth agg)
          <> "  maxSinkW=" <> show (rlsMaxSinkWidth agg)
          <> "  maxWork="  <> show (rlsMaxBandWork agg)
          <> "  dirC1d="   <> show (rlsDirectCandidates agg)
          <> "  redC1d="   <> show (rlsReductionCandidates agg)

renderRegionLayerRow :: SurveyRow -> [String]
renderRegionLayerRow r =
  let s = srRegionLayer r
  in [ srDemo r
     , maybe "" id (srTemplate r)
     , show (rlsFreeBands s)
     , show (rlsSinkFreeBands s)
     , show (rlsSinkBands s)
     , show (rlsMaxSinkFreeWidth s)
     , show (rlsMaxSinkWidth s)
     , show (rlsMaxBandWork s)
     , show (rlsDirectCandidates s)
     , show (rlsReductionCandidates s)
     ]

regionLayerColumnWidths :: [Int]
regionLayerColumnWidths = [42, 14, 6, 4, 5, 6, 8, 8, 7, 7]

formatRegionLayerRow :: [String] -> String
formatRegionLayerRow cols =
  intercalate "  " (zipWith pad regionLayerColumnWidths cols)
  where
    pad w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

-- §4.E.2c cross-template width section. One row per multi-template
-- ensemble. Single-graph and MIDI-poly demos are excluded — they
-- have no precedence DAG to measure.
--
--   tpls       : number of templates in the ensemble
--   tplLayerW  : max count of templates at any topological layer
--                of 'tgPrecedence' (/template precedence width/).
--                Candidate cross-template surface area: width
--                @>= 2@ means some templates have no precedence
--                dependency on each other in the source graph.
--   tplRunW    : widest full template layer with no shared-write
--                hazards; runnable without deterministic reduction.
--   tplRedW    : widest full template layer with at least one
--                shared-write hazard; needs deterministic reduction
--                or serialization before it can run at full width.
--   tplHaz     : count of same-layer same-bus template write hazards.
--   sumTotal   : sum of 'rssTotal' across templates (all regions
--                in the ensemble)
--   sumF       : sum of 'rssFree' across templates
--   maxLW      : max of 'rssMaxFreeLayerWidth' across templates
--                (intra-template free-layer width, repeated here
--                for at-a-glance comparison with tplLayerW)
--
-- Footer reports survey-wide max @tplLayerW@ / @tplRunW@ /
-- @tplRedW@. A non-zero @tplRedW@ is deliberately descriptive:
-- it marks surface area that needs the separate deterministic bus
-- reduction slice.
printEnsembleScheduleWidth :: [EnsembleScheduleRow] -> IO ()
printEnsembleScheduleWidth rows = do
  putStrLn "─── Cross-template width (§4.E.2c) ───"
  putStrLn $ formatEnsembleRow
    [ "ensemble", "tpls", "tplLayerW", "tplRunW", "tplRedW", "tplHaz"
    , "sumTotal", "sumF", "maxLW"
    ]
  mapM_ (putStrLn . formatEnsembleRow . renderEnsembleRow) rows
  putStrLn ""
  let maxTplLW = maxOr0 (map (tssMaxTemplateLayerWidth     . esStats) rows)
      maxTplRW = maxOr0 (map (tssMaxTemplateRunnableWidth  . esStats) rows)
      maxTplDW = maxOr0 (map (tssMaxTemplateReductionWidth . esStats) rows)
      sumTplHz = sum    (map (tssSharedWriteHazards        . esStats) rows)
      sumTpls  = sum    (map (tssTemplateCount        . esStats) rows)
      aggAll   = foldr addScheduleStats emptyScheduleStats
                       (map (tssAggregate . esStats) rows)
  putStrLn $ "  totals: "
          <> "ensembles="            <> show (length rows)
          <> "  templates="          <> show sumTpls
          <> "  max(tplLayerW)="     <> show maxTplLW
          <> "  max(tplRunW)="       <> show maxTplRW
          <> "  max(tplRedW)="       <> show maxTplDW
          <> "  tplHaz="             <> show sumTplHz
          <> "  total="              <> show (rssTotal               aggAll)
          <> "  F="                  <> show (rssFree                aggAll)
          <> "  max(maxLW)="         <> show (rssMaxFreeLayerWidth   aggAll)
  where
    maxOr0 [] = 0
    maxOr0 xs = maximum xs

renderEnsembleRow :: EnsembleScheduleRow -> [String]
renderEnsembleRow r =
  let s   = esStats r
      agg = tssAggregate s
  in [ esLabel r
     , show (tssTemplateCount         s)
     , show (tssMaxTemplateLayerWidth s)
     , show (tssMaxTemplateRunnableWidth s)
     , show (tssMaxTemplateReductionWidth s)
     , show (tssSharedWriteHazards    s)
     , show (rssTotal               agg)
     , show (rssFree                agg)
     , show (rssMaxFreeLayerWidth   agg)
     ]

ensembleColumnWidths :: [Int]
ensembleColumnWidths = [42, 5, 10, 7, 7, 7, 9, 5, 6]

formatEnsembleRow :: [String] -> String
formatEnsembleRow cols =
  intercalate "  " (zipWith pad ensembleColumnWidths cols)
  where
    pad w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

-- §4.D.1 rate distribution section. One row per surveyed graph,
-- plus a footer with aggregate counts and the survey-wide
-- SampleRate share. This reports the /propagated node output rate/
-- — the rate each runtime node carries after IR-level
-- 'propagateRates' joins each node's kind floor with its inputs.
-- It is /not/ a per-input consumption-policy view: a 'KGain' fed
-- by an oscillator counts as @S@ here even when its amount input
-- is a scalar 'CompileRate' constant. The per-port latch view
-- (whether the runtime samples each control once per block or per
-- sample) is a separate, deferred §4.D slice.
--
-- Columns:
--   C   : nodes at 'CompileRate' (literal-only stateless transforms)
--   I   : nodes at 'InitRate'    (computed once at graph init)
--   B   : nodes at 'BlockRate'   (recomputed once per audio block)
--   S   : nodes at 'SampleRate'  (recomputed every sample)
--   S%  : SampleRate share of the row's nodes, rounded to whole %
--
-- The headline number for "is per-node output rate too coarse to
-- drive optimization yet" is the survey-wide @S%@ in the footer.
-- If it stays near 100%, the node-output-rate view alone won't
-- license block-rate regions, and the next refinement is
-- per-input consumption policy.
printRateDistribution :: [SurveyRow] -> IO ()
printRateDistribution rows = do
  putStrLn "─── Rate distribution (§4.D.1, propagated node output rates) ───"
  putStrLn $ formatRateRow
    [ "demo", "template", "C", "I", "B", "S", "S%" ]
  mapM_ (putStrLn . formatRateRow . renderRateRow) rows
  putStrLn ""
  let agg = foldr addRateDistribution emptyRateDistribution
              (map srRateDist rows)
      total = rateDistributionTotal agg
      sharePct :: Int
      sharePct
        | total == 0 = 0
        | otherwise  = (rdSample agg * 100) `div` total
  putStrLn $ "  totals: "
          <> "graphs="  <> show (length rows)
          <> "  C="     <> show (rdCompile agg)
          <> "  I="     <> show (rdInit    agg)
          <> "  B="     <> show (rdBlock   agg)
          <> "  S="     <> show (rdSample  agg)
          <> "  total=" <> show total
          <> "  S%="    <> show sharePct <> "%"

renderRateRow :: SurveyRow -> [String]
renderRateRow r =
  let d   = srRateDist r
      tot = rateDistributionTotal d
      pct :: Int
      pct
        | tot == 0  = 0
        | otherwise = (rdSample d * 100) `div` tot
  in [ srDemo r
     , maybe "" id (srTemplate r)
     , show (rdCompile d)
     , show (rdInit    d)
     , show (rdBlock   d)
     , show (rdSample  d)
     , show pct <> "%"
     ]

-- Mirrors 'scheduleColumnWidths' in shape; the per-bucket counts
-- are small integers, S% is a 4-character percent.
rateColumnWidths :: [Int]
rateColumnWidths = [42, 14, 4, 4, 4, 4, 5]

formatRateRow :: [String] -> String
formatRateRow cols =
  intercalate "  " (zipWith pad rateColumnWidths cols)
  where
    pad w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

-- §4.D.2 edge-rate distribution. One row per @(sourceRate,
-- destPolicy)@ bucket that has at least one 'RFrom' edge across
-- the survey, plus a footer with the headline opportunity number.
--
-- This is the descriptive complement to §4.D.1: §4.D.1 reported
-- /producer/ output rates and showed the corpus is
-- 100% 'SampleRate' on the per-node view, which by itself doesn't
-- license block-rate regions. §4.D.2 reports the
-- /consumer/-side read policy at each input port, and asks how
-- many sample-rate producer edges land at a destination that
-- only reads at block rate or init time. Those edges are where
-- block-rate execution could save work; the count is the only
-- evidence that should drive a future block-rate execution
-- decision.
--
-- The survey reads the /unfused/ runtime graph (output of
-- 'compileRuntimeGraph'). The §4.C fused view rewrites 'RFrom'
-- producer edges into 'RFused' descriptors when the producer is
-- a single-consumer scalar, which would shrink the edge
-- population the survey is supposed to measure.
--
-- Columns:
--   source-rate         : producer 'rnRate'
--   dest-consumption    : destination port 'PortConsumptionRate'
--   edges               : total 'RFrom' edges in this bucket
--   producer-kinds      : count of distinct 'NodeKind's feeding
--                         the bucket (a kind that fan-outs into
--                         many destinations counts once)
--   example             : @"sourceKind → destKind.portName"@ from
--                         the first edge encountered in source
--                         order
--
-- Headline: producer /nodes/ — not edges — qualifying as
-- opportunities. Computed by 'sampleRateOpportunityProducers'
-- per graph and concatenated across rows: a sample-rate producer
-- counts only when /every/ active audio-input consumer port is
-- non-sample-accurate. A producer feeding both 'PortBlockLatched'
-- and 'PortSampleAccurate' must remain sample-rate to serve the
-- sample-accurate consumer, so it is /not/ an opportunity even
-- though one of its edges lands in a non-sample-accurate bucket.
-- 'PortIgnored' consumers (currently: oscillator phase ports)
-- are filtered out before the check — they represent no
-- consumption to demote.
--
-- If the producer-node count is zero, the consumer-side view
-- doesn't license block-rate regions either; if it is non-
-- trivial, the distinct producer-kind count tells whether the
-- opportunity is concentrated in one producer family or spans
-- several.
printEdgeRateDistribution :: [SurveyRow] -> IO ()
printEdgeRateDistribution rows = do
  putStrLn "─── Edge-rate distribution (§4.D.2, source rnRate × dest port consumption) ───"
  putStrLn $ formatEdgeRateRow
    [ "source-rate", "dest-consumption", "edges"
    , "producer-kinds", "example"
    ]
  let aggMap =
        foldr addEdgeRateBuckets M.empty (map srEdgeBuckets rows)
      orderedKeys =
        [ (sr, pp)
        | sr <- [minBound .. maxBound :: Rate]
        , pp <- [minBound .. maxBound :: PortConsumptionRate]
        ]
      visibleRows =
        [ (sr, pp, b)
        | (sr, pp) <- orderedKeys
        , Just b   <- [M.lookup (sr, pp) aggMap]
        , erbEdgeCount b > 0
        ]
  mapM_ (putStrLn . formatEdgeRateRow . renderEdgeRateRow) visibleRows
  putStrLn ""
  -- The bucket table above shows the per-edge distribution. The
  -- headline opportunity is a /per-producer/ measurement: a
  -- sample-rate producer counts only when /all/ its active
  -- consumer ports are non-sample-accurate. Counting edges would
  -- over-report — a producer feeding both LPF.freq and a
  -- sample-accurate port must remain sample-rate, so it isn't an
  -- opportunity even though one of its edges lands in
  -- 'PortBlockLatched'. 'sampleRateOpportunityProducers' applies
  -- the per-producer rule per graph; we concat across rows.
  let totalEdges     = sum (map erbEdgeCount (M.elems aggMap))
      oppProducers   = concatMap srOppProducers rows
      oppNodeCount   = length oppProducers
      oppKindCount   = length (nub oppProducers)
  putStrLn $ "  totals: "
          <> "edges="    <> show totalEdges
          <> "  buckets=" <> show (length visibleRows)
  putStrLn $ "  opportunity: "
          <> show oppNodeCount  <> " producer node(s) across "
          <> show oppKindCount  <> " distinct kind(s)"
  putStrLn   "  (sample-rate producers whose every active consumer port"
  putStrLn   "   is non-sample-accurate; PortIgnored ports excluded)"

renderEdgeRateRow :: (Rate, PortConsumptionRate, EdgeRateBucket) -> [String]
renderEdgeRateRow (sr, pp, b) =
  [ show sr
  , show pp
  , show (erbEdgeCount b)
  , show (length (erbProducerKinds b))
  , maybe "" id (erbExample b)
  ]

-- | §6.D descriptive latency surface. Aggregates the per-row
-- 'srDeclaredLatency' / 'srLatencySkews' captured by
-- 'compileForSurvey' into a single corpus-wide view.
--
-- Two sub-tables: which 'NodeKind's contribute inherent
-- pipeline latency (and how many node instances of each), and
-- which nodes combine inputs that arrive at different
-- cumulative latencies (uncompensated skew — the diagnostic
-- that would justify a future compensation pass).
--
-- '--corpus-survey' already renders this view per-row in
-- 'MetaSonic.App.CorpusSurvey.printLatencyFootprint';
-- '--fusion-survey' aggregates across the surveyed corpus so
-- the headline number matches the rest of the §6.D follow-up
-- decision evidence.
printDeclaredLatency :: [SurveyRow] -> IO ()
printDeclaredLatency rows = do
  putStrLn "─── Declared-latency footprint (§6.D, kindLatency-bearing nodes) ───"
  let entries =
        [ (srDemo r, srTemplate r, d)
        | r <- rows
        , d <- srDeclaredLatency r
        ]
      -- 'NodeKind' has no 'Ord' instance, so we key the
      -- aggregation by 'kindTag' (a 'CInt') and carry the
      -- original kind in the value tuple for display.
      perKind :: M.Map CInt (NodeKind, Int, Int, String, Maybe String)
      perKind = M.fromListWith mergeKindEntry
        [ ( kindTag (dnlKind d)
          , (dnlKind d, dnlLatency d, 1, demo, tmpl)
          )
        | (demo, tmpl, d) <- entries
        ]
      mergeKindEntry (k, lat, c1, demo1, tmpl1) (_, _, c2, _, _) =
        (k, lat, c1 + c2, demo1, tmpl1)
      skews = [ s | r <- rows, s <- srLatencySkews r ]
  if null entries
    then putStrLn "  (no nodes declare inherent latency in the surveyed graphs)"
    else do
      putStrLn $ formatLatencyRow
        [ "kind", "latency-samples", "nodes", "example"
        ]
      let perKindRows =
            [ formatLatencyRow
                [ show k
                , show lat
                , show count
                , demo <> maybe "" ("/" <>) tmpl
                ]
            | (_tag, (k, lat, count, demo, tmpl))
                <- M.toAscList perKind
            ]
      mapM_ putStrLn perKindRows
      let totalNodes = sum [c | (_, _, c, _, _) <- M.elems perKind]
          totalKinds = M.size perKind
      putStrLn ""
      putStrLn $ "  totals: nodes=" <> show totalNodes
              <> "  kinds=" <> show totalKinds
      putStrLn $ "  uncompensated skew: "
              <> show (length skews) <> " node(s)"
      if null skews
        then putStrLn
          "  (compensation parked per the §6.D follow-up decision)"
        else mapM_
          (\s -> putStrLn $ "    "
                         <> show (lsKind s)
                         <> "@" <> showNodeIndex (lsNode s)
                         <> " min=" <> show (lsMinLatency s)
                         <> " max=" <> show (lsMaxLatency s))
          skews

latencyColumnWidths :: [Int]
latencyColumnWidths = [16, 15, 6, 32]

formatLatencyRow :: [String] -> String
formatLatencyRow cols =
  intercalate "  " (zipWith pad latencyColumnWidths cols)
  where
    pad w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

--------------------------------------------------------------------------------
-- §7.B kind capability footprint
--------------------------------------------------------------------------------

-- Two sub-sections under one header:
--
--   1. Per-capability node counts across every surveyed graph
--      (demos plus the corpus). A node is counted once for each
--      capability its kind carries, so the column totals do not
--      sum to the node count.
--   2. The per-kind matrix: for each 'NodeKind' that appears in
--      any surveyed graph, its total occurrence count and its
--      declared 'kindCapabilities' list.
--
-- The footprint is descriptive only. No planner decision is made
-- from it yet; the section exists so the upcoming Phase 7.C planner
-- has a checked input surface and so corpus capability drift fails
-- loudly in '--snapshot-check'.
printCapabilityFootprint :: [SurveyRow] -> IO ()
printCapabilityFootprint rows = do
  putStrLn "─── Kind capability footprint (§7.B, kindCapabilities) ───"
  let aggTally = foldr mergeKindTallies emptyKindTally
                       (map srKindTally rows)
      caps     = [minBound .. maxBound :: KindCapability]
      perCap   = [(cap, nodesWithCap cap aggTally) | cap <- caps]
  if null aggTally
    then putStrLn "  (no nodes in the surveyed graphs)"
    else do
      putStrLn $ formatCapRow ["capability", "nodes"]
      mapM_ (\(c, n) -> putStrLn $ formatCapRow [show c, show n]) perCap
      putStrLn ""
      putStrLn "  Per-kind capability matrix:"
      mapM_
        (\(k, n) ->
            putStrLn $
              "    " <> padR 18 (show k)
                     <> "n=" <> padR 5 (show n)
                     <> intercalate ", "
                          (map show (kindCapabilities k)))
        aggTally
  where
    nodesWithCap cap tally =
      sum [n | (k, n) <- tally, cap `elem` kindCapabilities k]

    padR w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

capabilityColumnWidths :: [Int]
capabilityColumnWidths = [22, 6]

formatCapRow :: [String] -> String
formatCapRow cols =
  "  " <> intercalate "  " (zipWith pad capabilityColumnWidths cols)
  where
    pad w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

--------------------------------------------------------------------------------
-- §7.C planner verdicts
--------------------------------------------------------------------------------

-- Per-row 'srPlannerVerdicts' is aggregated across every surveyed
-- graph and rendered as two diagnostic sub-sections plus the
-- selected/maximal accepted-candidate surface:
--
--   1. Per-rejection-reason counts plus one example per reason.
--   2. Accepted candidates grouped by their matched §4.B kernel,
--      with a separate "no-§4.B-match" row for generated-eligible
--      candidates.
--
-- The planner over-reports by design: a 4-node sink-terminal chain
-- yields nested 2/3/4-length candidates, all with their own
-- verdicts. Raw counts are printed first for drift diagnostics; the
-- selected view coalesces nested accepted candidates per graph before
-- exposing the generated-eligible count that a future executor should
-- consume.
printPlannerVerdicts :: [SurveyRow] -> IO ()
printPlannerVerdicts rows = do
  putStrLn "─── Phase 7.C planner verdicts ───"
  let verdicts = concatMap srPlannerVerdicts rows
      accs     = filter isAccepted verdicts
      rejs     = filter isRejected verdicts
      selected = concatMap (selectedFusionCandidates . srPlannerVerdicts) rows
  putStrLn $ "  candidates=" <> show (length verdicts)
          <> "  accepted="   <> show (length accs)
          <> "  rejected="   <> show (length rejs)
          <> "  selected-accepted=" <> show (length selected)
  if null verdicts
    then putStrLn "  (no candidates in the surveyed graphs)"
    else do
      putStrLn ""
      printRejectionSummary rejs
      putStrLn ""
      printAcceptedByShape "  Raw accepted candidates by matched shape:" [c | Accepted c <- accs]
      putStrLn ""
      printAcceptedByShape "  Selected accepted candidates by matched shape:" selected

printRejectionSummary :: [Verdict] -> IO ()
printRejectionSummary [] =
  putStrLn "  (no rejections)"
printRejectionSummary rejs = do
  putStrLn "  Top rejection reasons (count desc):"
  let reasons   = [r | Rejected _ r <- rejs]
      tags      = nub (map reasonTag reasons)
      grouped   =
        [ (tag, count, exampleStr)
        | tag <- tags
        , let matching = filter ((== tag) . reasonTag) reasons
              count    = length matching
              exampleStr = case matching of
                (r : _) -> renderReasonExample r
                _       -> "(none)"
        ]
      sorted    = sortOn (\(_, c, _) -> negate c) grouped
  mapM_
    (\(tag, count, ex) ->
        putStrLn $ "    " <> padR 30 tag
                 <> "count=" <> padR 5 (show count)
                 <> "example=" <> ex)
    sorted

reasonTag :: RejectionReason -> String
reasonTag r = case r of
  ReasonHardBarrier{}      -> "ReasonHardBarrier"
  ReasonLatencyMidChain{}  -> "ReasonLatencyMidChain"
  ReasonResourceMidChain{} -> "ReasonResourceMidChain"
  ReasonStatefulInterior{} -> "ReasonStatefulInterior"
  ReasonFanoutEscape{}     -> "ReasonFanoutEscape"
  ReasonNonAdjacentDataflow{} -> "ReasonNonAdjacentDataflow"
  ReasonTooShort{}         -> "ReasonTooShort"
  ReasonNoTerminalSink     -> "ReasonNoTerminalSink"
  ReasonCrossesRegion{}    -> "ReasonCrossesRegion"

renderReasonExample :: RejectionReason -> String
renderReasonExample r = case r of
  ReasonHardBarrier ix k        ->
    "node " <> show (nodeIxInt ix) <> " " <> show k
  ReasonLatencyMidChain ix k l  ->
    "node " <> show (nodeIxInt ix) <> " " <> show k
            <> " (lat=" <> show l <> ")"
  ReasonResourceMidChain ix k   ->
    "node " <> show (nodeIxInt ix) <> " " <> show k
  ReasonStatefulInterior ix k   ->
    "node " <> show (nodeIxInt ix) <> " " <> show k
  ReasonFanoutEscape ix cc      ->
    "node " <> show (nodeIxInt ix) <> " consumers=" <> show cc
  ReasonNonAdjacentDataflow prev next k ->
    "node " <> show (nodeIxInt prev)
      <> " does not feed node " <> show (nodeIxInt next)
      <> " " <> show k
  ReasonTooShort n              -> "len=" <> show n
  ReasonNoTerminalSink          -> "(structural)"
  ReasonCrossesRegion ix        -> "node " <> show (nodeIxInt ix)

nodeIxInt :: NodeIndex -> Int
nodeIxInt (NodeIndex i) = i

printAcceptedByShape :: String -> [FusionCandidate] -> IO ()
printAcceptedByShape header cands = do
  putStrLn header
  let kernels   = nub [k | c <- cands, Just k <- [fcMatchedShape c]]
      perKernel =
        [ (show k, length [c | c <- cands, fcMatchedShape c == Just k])
        | k <- kernels
        ]
      noMatch   = length [() | c <- cands, fcMatchedShape c == Nothing]
      sorted    = sortOn (negate . snd) perKernel
  if null cands
    then putStrLn "    (no accepted candidates)"
    else do
      mapM_
        (\(label, n) ->
            putStrLn $ "    " <> padR 18 label
                     <> "count=" <> show n)
        sorted
      if noMatch > 0
        then putStrLn $ "    " <> padR 18 "no-§4.B-match"
                              <> "count=" <> show noMatch
                              <> "  (generated-eligible)"
        else pure ()

padR :: Int -> String -> String
padR w s
  | length s >= w = s
  | otherwise     = s <> replicate (w - length s) ' '

--------------------------------------------------------------------------------
-- §7.C cost-model join
--------------------------------------------------------------------------------

-- | One row in the §7.C cost-model join table: a unique selected-
-- candidate shape across the survey, its §4.B-match status, total
-- occurrence count, classification, and an optional measured speedup.
--
-- v1 keys on 'fcMemberKinds' plus gain amount mode (see
-- @notes/2026-05-11-r-phase-7c-cost-model-join-decision.md@). Speedup
-- is reported only for 'ClsMeasuredWin' / 'ClsMeasuredLoss'.
data CostModelRow = CostModelRow
  { cmrKey       :: !ShapeKey
  , cmrKinds     :: ![NodeKind]
  , cmrGainModes :: ![GainAmountMode]
  , cmrMatched   :: !(Maybe RegionKernel)
  , cmrCount     :: !Int
  , cmrClass     :: !CostModelClass
  , cmrSpeedup   :: !(Maybe Double)
  } deriving (Eq, Show)

data CostModelClass
  = ClsCovered
  | ClsMeasuredWin
  | ClsMeasuredLoss
  | ClsNeedsBenchmark
  deriving (Eq, Show)

renderCostModelClass :: CostModelClass -> String
renderCostModelClass ClsCovered        = "covered"
renderCostModelClass ClsMeasuredWin    = "measured-win"
renderCostModelClass ClsMeasuredLoss   = "measured-loss"
renderCostModelClass ClsNeedsBenchmark = "needs-benchmark"

-- | Aggregate selected candidates across the survey, group by the
-- cost-model shape key plus matched-shape status, and classify. The
-- shape key includes the ordered member kinds plus the tiny v1 feature
-- axis carried by 'fcGainAmountModes', so scalar-gain and dynamic-gain
-- candidates do not share measurement evidence.
costModelRows
  :: ((ShapeKey, Maybe RegionKernel) -> (CostModelClass, Maybe Double))
  -> [SurveyRow]
  -> [CostModelRow]
costModelRows classify rows =
  let selected = concatMap (selectedFusionCandidates . srPlannerVerdicts) rows
      keys     = nub
                   [ ( shapeKeyOf c
                     , fcMemberKinds c
                     , fcGainAmountModes c
                     , fcMatchedShape c )
                   | c <- selected ]
      counted  =
        [ ((key, kinds, gainModes, mshape), count)
        | (key, kinds, gainModes, mshape) <- keys
        , let count =
                length [ ()
                       | c <- selected
                       , shapeKeyOf c == key
                       , fcMatchedShape c == mshape ]
        ]
      -- Sort: by class ordering (covered → measured-win → ... →
      -- needs-benchmark), then count desc, then chain length asc,
      -- then kinds Enum order.
      withCls =
        [ CostModelRow
            { cmrKey       = key
            , cmrKinds     = kinds
            , cmrGainModes = gainModes
            , cmrMatched   = mshape
            , cmrCount     = count
            , cmrClass     = cls
            , cmrSpeedup   = spd
            }
        | ((key, kinds, gainModes, mshape), count) <- counted
        , let (cls, spd) = classify (key, mshape)
        ]
  in sortOn rowKey withCls
  where
    rowKey r =
      ( classRank (cmrClass r)
      , negate (cmrCount r)
      , length (cmrKinds r)
      , map fromEnum (cmrKinds r)
      , cmrKey r
      )

    classRank ClsCovered        = 0 :: Int
    classRank ClsMeasuredWin    = 1
    classRank ClsMeasuredLoss   = 2
    classRank ClsNeedsBenchmark = 3

-- | Classify a selected-candidate shape against the cost-lab index.
-- §4.B-matched shapes are 'ClsCovered' (the hand-written kernel is
-- the path); generated-eligible shapes look up the cost-lab summary
-- by key and split into measured-win / measured-loss / needs-
-- benchmark.
costModelClassifier
  :: M.Map ShapeKey ShapeSummary
  -> (ShapeKey, Maybe RegionKernel)
  -> (CostModelClass, Maybe Double)
costModelClassifier _ (_, Just _) = (ClsCovered, Nothing)
costModelClassifier idx (key, Nothing) =
  case M.lookup key idx of
    Just summ
      | ssSpeedup summ >= measuredWinThreshold ->
          (ClsMeasuredWin,  Just (ssSpeedup summ))
      | otherwise ->
          (ClsMeasuredLoss, Just (ssSpeedup summ))
    Nothing                  -> (ClsNeedsBenchmark, Nothing)

printCostModelJoin :: M.Map ShapeKey ShapeSummary -> [SurveyRow] -> IO ()
printCostModelJoin idx rows = do
  putStrLn "─── Phase 7.C cost-model join ───"
  let allRows = costModelRows (costModelClassifier idx) rows
      total   = sum (map cmrCount allRows)
      countOf cls =
        sum [ cmrCount r | r <- allRows, cmrClass r == cls ]
  putStrLn $ "  selected=" <> show total
          <> "  covered="  <> show (countOf ClsCovered)
          <> "  measured-win="  <> show (countOf ClsMeasuredWin)
          <> "  measured-loss=" <> show (countOf ClsMeasuredLoss)
          <> "  needs-benchmark=" <> show (countOf ClsNeedsBenchmark)
  if null allRows
    then putStrLn "  (no selected candidates in the surveyed graphs)"
    else do
      putStrLn ""
      putStrLn "  Per-shape table (selected candidates only):"
      putStrLn $ formatCmrRow
        ["kinds", "features", "matched-shape", "class", "count", "speedup"]
      mapM_ (putStrLn . formatCmrRow . renderCmrCells) allRows

renderCmrCells :: CostModelRow -> [String]
renderCmrCells r =
  [ intercalate " → " (map show (cmrKinds r))
  , renderGainFeatures (cmrGainModes r)
  , maybe "—" show (cmrMatched r)
  , renderCostModelClass (cmrClass r)
  , show (cmrCount r)
  , case cmrClass r of
      ClsCovered        -> "n/a"
      _ -> case cmrSpeedup r of
             Just s  -> showSpeedup s
             Nothing -> "—"
  ]

renderGainFeatures :: [GainAmountMode] -> String
renderGainFeatures [] = "—"
renderGainFeatures modes =
  "gain=" <> intercalate "," (map renderGainMode modes)
  where
    renderGainMode GainAmountConst   = "const"
    renderGainMode GainAmountDynamic = "dynamic"
    renderGainMode GainAmountMissing = "missing"

showSpeedup :: Double -> String
showSpeedup s = printf "%.2f×" s

--------------------------------------------------------------------------------
-- Phase 7.F profitability gate (read-only)
--------------------------------------------------------------------------------

-- | A row's worth of facts the gate consumes: the candidate's
-- shape key plus the surface bits we want printed alongside the
-- verdict (kinds, gain-amount features, §4.B match, occurrence
-- count across the survey).
data GateShapeRow = GateShapeRow
  { gsrKey       :: !ShapeKey
  , gsrKinds     :: ![NodeKind]
  , gsrGainModes :: ![GainAmountMode]
  , gsrMatched   :: !(Maybe RegionKernel)
  , gsrCount     :: !Int
  } deriving (Eq, Show)

-- | Print the Phase 7.F generated profitability gate section.
-- Pure consumer of the cost-lab gate index plus the survey's
-- selected candidates. Strictly diagnostic — no caller mutates
-- runtime state from these verdicts.
printProfitabilityGate
  :: M.Map ShapeKey GateMeasurement -> [SurveyRow] -> IO ()
printProfitabilityGate gateIdx rows = do
  putStrLn "─── Phase 7.F generated profitability gate ───"
  let shapes      = aggregateGateShapes (map srPlannerVerdicts rows)
      gateRows    = [ GateRow input (evaluateGate input)
                    | (shape, input) <- map (\s -> (s, gateInputFor gateIdx s)) shapes
                    , let _ = shape  -- keep shape carrier visible for table render
                    ]
      pairs       = zip shapes gateRows
      counts      = summarizeGate gateRows
  putStrLn $ "  total="            <> show (gcTotal counts)
          <> "  prefer-generated=" <> show (gcPreferGenerated counts)
          <> "  prefer-existing="  <> show (gcPreferExisting counts)
          <> "  needs-benchmark="  <> show (gcNeedsBenchmark counts)
          <> "  unsupported="      <> show (gcUnsupported counts)
          <> "  non-exact="        <> show (gcNonExact counts)
          <> "  covered-by-hand-kernel=" <> show (gcCoveredByHandKernel counts)
  putStrLn $ "  signal: prefer-generated=" <> show (gcPreferGenerated counts)
          <> " (read-only; review before any runtime turn-on)"
  if null pairs
    then putStrLn "  (no selected candidates in the surveyed graphs)"
    else do
      putStrLn ""
      putStrLn "  Per-shape verdicts (selected candidates only):"
      putStrLn $ formatGateRow
        [ "kinds", "features", "matched-shape", "count"
        , "verdict", "gen", "peer", "reason"
        ]
      mapM_ (putStrLn . formatGateRow . renderGateCells) (sortGatePairs pairs)

-- | Aggregate selected candidates into 'GateShapeRow' values:
-- one row per unique (shape key, gain features, matched-shape)
-- triple, carrying the survey-wide occurrence count.
--
-- Selection must happen per verdict group. 'NodeIndex' and
-- 'RegionIndex' are graph-local, so flattening verdicts before
-- 'selectedFusionCandidates' would let unrelated candidates from
-- different graphs contain each other by accident.
aggregateGateShapes :: [[Verdict]] -> [GateShapeRow]
aggregateGateShapes verdictGroups =
  let selected = concatMap selectedFusionCandidates verdictGroups
      keys     = nub
                   [ ( shapeKeyOf c
                     , fcMemberKinds c
                     , fcGainAmountModes c
                     , fcMatchedShape c )
                   | c <- selected ]
  in [ GateShapeRow
         { gsrKey       = key
         , gsrKinds     = kinds
         , gsrGainModes = gainModes
         , gsrMatched   = mshape
         , gsrCount     =
             length [ ()
                    | c <- selected
                    , shapeKeyOf c == key
                    , fcMatchedShape c == mshape
                    ]
         }
     | (key, kinds, gainModes, mshape) <- keys ]

-- | Join a survey-aggregated shape row with the cost-lab gate
-- measurement to produce the 'GateInput' the rules consume.
-- Unmeasured shapes set the generated-* fields to the
-- "nothing-observed" default so the rules fall through to
-- 'NeedsBenchmark' (or 'CoveredByHandKernel' when applicable).
gateInputFor :: M.Map ShapeKey GateMeasurement -> GateShapeRow -> GateInput
gateInputFor gateIdx s =
  let label = intercalate " → " (map show (gsrKinds s))
        <> case renderGainFeatures (gsrGainModes s) of
             "—"  -> ""
             feat -> " (" <> feat <> ")"
      gmM = M.lookup (gsrKey s) gateIdx
  in GateInput
       { giShapeLabel       = label
       , giHasHandKernel    = case gsrMatched s of Just _ -> True; _ -> False
       , giGeneratorError   = maybe Nothing gmGeneratorError gmM
       , giGeneratedExact   = maybe True    gmGeneratedExact gmM
       , giGeneratedSpeedup = gmM >>= gmGeneratedSpeedup
       , giBestPeerSpeedup  = gmM >>= gmBestPeerSpeedup
       }

-- | Sort gate output so 'PreferGenerated' rows surface first
-- (they are the actionable ones), then by occurrence count
-- descending, then by kind sequence for stability.
sortGatePairs :: [(GateShapeRow, GateRow)] -> [(GateShapeRow, GateRow)]
sortGatePairs = sortOn $ \(s, r) ->
  ( verdictRank (grVerdict r)
  , negate (gsrCount s)
  , length (gsrKinds s)
  , map fromEnum (gsrKinds s)
  , gsrKey s
  )
  where
    verdictRank v = case verdictTag v of
      "prefer-generated"        -> 0 :: Int
      "prefer-existing"         -> 1
      "needs-benchmark"         -> 2
      "covered-by-hand-kernel"  -> 3
      "unsupported"             -> 4
      "non-exact"               -> 5
      _                         -> 6

renderGateCells :: (GateShapeRow, GateRow) -> [String]
renderGateCells (s, r) =
  let gi = grInput r
      vt = verdictTag (grVerdict r)
      rs = case verdictReason (grVerdict r) of
             ""  -> "—"
             txt -> txt
  in [ intercalate " → " (map show (gsrKinds s))
     , renderGainFeatures (gsrGainModes s)
     , maybe "—" show (gsrMatched s)
     , show (gsrCount s)
     , vt
     , maybe "—" showSpeedup (giGeneratedSpeedup gi)
     , maybe "—" showSpeedup (giBestPeerSpeedup gi)
     , rs
     ]

gateColumnWidths :: [Int]
gateColumnWidths = [40, 14, 18, 6, 22, 8, 8, 40]

formatGateRow :: [String] -> String
formatGateRow cols =
  "  " <> intercalate "  " (zipWith pad gateColumnWidths cols)
  where
    pad w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

-- | Phase 7.J gate-by-executor section. Re-uses 'evaluateGate'
-- verbatim, only the cost-lab gate index feeding 'gateInputFor'
-- changes. Three rows:
--
--   * @sample-major@ — 'VarGenerated', mirrors the canonical
--     7.F gate; included so the row layout is self-explanatory
--     and the snapshot can cross-check it against the existing
--     7.F numbers.
--   * @block-major@   — 'VarGeneratedBlock'.
--   * @super-mode@    — 'VarGeneratedSuper'.
--
-- The shape aggregation ('aggregateGateShapes') is shared
-- across rows — every executor's gate scans the same candidate
-- set, so total counts agree by construction; only the
-- verdict mix differs.
printProfitabilityGateByExecutor
  :: [FCL.LabRow] -> [SurveyRow] -> IO ()
printProfitabilityGateByExecutor costLabRows rows = do
  putStrLn "─── Phase 7.J gate by generated executor ───"
  let shapes = aggregateGateShapes (map srPlannerVerdicts rows)
      countsFor v =
        let idx     = costLabGateIndexFor v costLabRows
            gateRs  =
              [ GateRow input (evaluateGate input)
              | s <- shapes
              , let input = gateInputFor idx s
              ]
        in summarizeGate gateRs
      rowsBy =
        [ (variantName VarGenerated,      countsFor VarGenerated)
        , (variantName VarGeneratedBlock, countsFor VarGeneratedBlock)
        , (variantName VarGeneratedSuper, countsFor VarGeneratedSuper)
        ]
  putStrLn $ formatExecGateRow
    [ "executor", "total", "prefer-gen", "prefer-exist"
    , "needs-bench", "unsupported", "non-exact", "covered-by-hk"
    ]
  mapM_ (putStrLn . formatExecGateRow . renderExecGateCells) rowsBy
  let preferGenByExecutor =
        [ (name, gcPreferGenerated c) | (name, c) <- rowsBy ]
  putStrLn $ "  signal: prefer-generated counts by executor — "
          <> intercalate ", "
               [ name <> "=" <> show n
               | (name, n) <- preferGenByExecutor ]
  putStrLn $ "  (read-only; non-zero on any executor reopens the"
          <> " turn-on question for that path)"

renderExecGateCells :: (String, GateCounts) -> [String]
renderExecGateCells (name, c) =
  [ name
  , show (gcTotal c)
  , show (gcPreferGenerated c)
  , show (gcPreferExisting c)
  , show (gcNeedsBenchmark c)
  , show (gcUnsupported c)
  , show (gcNonExact c)
  , show (gcCoveredByHandKernel c)
  ]

execGateColumnWidths :: [Int]
execGateColumnWidths = [16, 6, 12, 14, 13, 13, 11, 14]

formatExecGateRow :: [String] -> String
formatExecGateRow cols =
  "  " <> intercalate "  " (zipWith pad execGateColumnWidths cols)
  where
    pad w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

costModelColumnWidths :: [Int]
costModelColumnWidths = [40, 18, 18, 16, 6, 8]

formatCmrRow :: [String] -> String
formatCmrRow cols =
  "  " <> intercalate "  " (zipWith pad costModelColumnWidths cols)
  where
    pad w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

showNodeIndex :: NodeIndex -> String
showNodeIndex (NodeIndex i) = show i

edgeRateColumnWidths :: [Int]
edgeRateColumnWidths = [13, 19, 6, 15, 32]

formatEdgeRateRow :: [String] -> String
formatEdgeRateRow cols =
  intercalate "  " (zipWith pad edgeRateColumnWidths cols)
  where
    pad w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

-- Aggregate totals across every surveyed graph, plus a subtotal
-- block that splits demo rows from corpus rows. The split lets the
-- reader read off two questions independently:
--
--   * "What does §4.B coverage look like on the playable demo set?"
--     (demo subtotals)
--   * "What does §4.B coverage look like on the realistic-patch
--     reference corpus?" (corpus subtotals)
--
-- Mixing the two would smear that signal — corpus shapes are picked
-- to stress the matcher, so they typically claim at a higher rate
-- than demos and would inflate the demo-subset coverage number.
-- Phase 8.G: print the authoring-metadata totals across the
-- surveyed demo list, plus a short per-demo row for demos
-- that opt in. Empty bodies emit no block (so demo lists
-- without authoring metadata don't add noise).
printAuthoringSurvey :: [Demo] -> IO ()
printAuthoringSurvey demos =
  case authoringRows of
    [] -> pure ()
    rs -> do
      putStrLn "─── Authoring metadata totals ───"
      putStrLn $ "  demos with authoring metadata : "
              <> show (length rs)
      putStrLn $ "  total named templates         : "
              <> show (sum (map authoringRowTemplates rs))
      putStrLn $ "  total named buses             : "
              <> show (sum (map authoringRowBuses rs))
      putStrLn $ "  total named controls          : "
              <> show (sum (map authoringRowControls rs))
      putStrLn $ "  CC-bound named controls       : "
              <> show (sum (map authoringRowCCControls rs))
      putStrLn ""
      putStrLn "─── Per-demo authoring rows ───"
      mapM_ (putStrLn . formatAuthoringRow) rs
      putStrLn ""
  where
    authoringRows =
      [ AuthoringSurveyRow
          { arsKey       = demoKey d
          , arsReport    = r
          , authoringRowTemplates   = length (arTemplates r)
          , authoringRowBuses       = length (arBuses r)
          , authoringRowControls    = length (arControls r)
          , authoringRowCCControls  =
              length [ () | c <- arControls r
                          , case rcCC c of
                              Just _  -> True
                              Nothing -> False ]
          }
      | d <- demos
      , Just r <- [demoAuthoring d]
      ]

data AuthoringSurveyRow = AuthoringSurveyRow
  { arsKey                 :: !String
  , arsReport              :: !AuthoringReport
  , authoringRowTemplates  :: !Int
  , authoringRowBuses      :: !Int
  , authoringRowControls   :: !Int
  , authoringRowCCControls :: !Int
  }

formatAuthoringRow :: AuthoringSurveyRow -> String
formatAuthoringRow r =
  let pad n s
        | length s >= n = s
        | otherwise     = s <> replicate (n - length s) ' '
  in pad 16 (arsKey r)
     <> "templates="  <> show (authoringRowTemplates r)
     <> "  buses="    <> show (authoringRowBuses r)
     <> "  controls=" <> show (authoringRowControls r)
     <> "  cc-controls=" <> show (authoringRowCCControls r)

printSurveyTotals :: [SurveyRow] -> [SurveyRow] -> IO ()
printSurveyTotals demoRows corpusRows = do
  let allRows = demoRows <> corpusRows
  printTotalsBlock "─── Totals (all surveyed graphs) ───" allRows
  putStrLn ""
  putStrLn "─── Subtotals (demos vs corpus) ───"
  putStrLn $ formatSubtotalLine "demos:"  demoRows
  putStrLn $ formatSubtotalLine "corpus:" corpusRows

-- | Long-form totals block (multi-line). Same labels and shape as
-- before; just lifted to a helper so the all-rows summary and any
-- future per-subset blocks can share it.
printTotalsBlock :: String -> [SurveyRow] -> IO ()
printTotalsBlock header rows = do
  let totalNodes     = sum (map srNodes rows)
      totalClaimed   = sum (map srClaimedNodes rows)
      totalRegions   = sum (map srRegions rows)
      totalFused     = sum (map srFusedRegions rows)
      totalElided    = sum (map srElided rows)
      totalRFused    = sum (map srRFused rows)
      totalShapes    = sum (map (length . srShapes) rows)
      shapesClaimed  =
        sum [length (filter snd (srShapes r)) | r <- rows]
      shapesMissed   = totalShapes - shapesClaimed
  putStrLn header
  putStrLn $ "  Graphs surveyed:           " <> show (length rows)
  putStrLn $ "  Runtime nodes:             " <> show totalNodes
  putStrLn $ "  Regions (all):             " <> show totalRegions
  putStrLn $ "  §4.B fused regions:        " <> show totalFused
  putStrLn $ "  Nodes in fused regions:    "
          <> show totalClaimed <> " / " <> show totalNodes
          <> " (" <> covPct totalClaimed totalNodes <> ")"
  putStrLn $ "  §4.C elided nodes:         " <> show totalElided
  putStrLn $ "  §4.C RFused inputs:        " <> show totalRFused
  putStrLn ""
  putStrLn $ "  Sink-terminal candidate chains:    " <> show totalShapes
  putStrLn $ "    claimed by a §4.B kernel:        " <> show shapesClaimed
  putStrLn $ "    missed (no kernel for the shape, or"
  putStrLn $ "             precondition didn't hold): " <> show shapesMissed

-- | One-line subtotal: "<label>  N graphs, N nodes, N% §4.B coverage,
-- shapes N/N claimed". Numbers align via fixed-width padding so the
-- demo and corpus lines visually compare.
formatSubtotalLine :: String -> [SurveyRow] -> String
formatSubtotalLine label rows =
  let nGraphs  = length rows
      nNodes   = sum (map srNodes rows)
      nClaim   = sum (map srClaimedNodes rows)
      nShape   = sum (map (length . srShapes) rows)
      nShapeOK = sum [length (filter snd (srShapes r)) | r <- rows]
      pad8 s   = s <> replicate (max 0 (8 - length s)) ' '
  in "  " <> pad8 label
        <> "  graphs="  <> show nGraphs
        <> "  nodes="   <> show nNodes
        <> "  §4.B="    <> covPct nClaim nNodes
        <> "  shapes="  <> show nShapeOK <> "/" <> show nShape
