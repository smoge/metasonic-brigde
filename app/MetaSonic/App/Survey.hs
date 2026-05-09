module MetaSonic.App.Survey
  ( printFusionSummary
  , runFusionSurvey
  , surveyShapeProbes
  , surveyEnsembleCorpus
  ) where

import           Data.Either               (partitionEithers)
import           Data.List                 (intercalate, isPrefixOf, nub, sort,
                                             sortOn)
import qualified Data.Map.Strict           as M
import           System.Exit               (die)

import           MetaSonic.App.Demos
import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Types            (NodeIndex (..), NodeKind (..),
                                             PortConsumptionRate (..),
                                             PortIndex (..), Rate (..))

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
-- (the strongest fusion class per notes/fusion-strategy.md), then
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
data WorkerBandStats = WorkerBandStats
  { wbsFreeBands          :: !Int
  , wbsSinkFreeBands      :: !Int
  , wbsSinkBands          :: !Int
  , wbsMaxSinkFreeWidth   :: !Int
  , wbsMaxSinkWidth       :: !Int
  , wbsMaxBandWork        :: !Int
  , wbsDirectCandidates   :: !Int
  , wbsReductionCandidates:: !Int
  } deriving (Eq, Show)

emptyWorkerBandStats :: WorkerBandStats
emptyWorkerBandStats = WorkerBandStats 0 0 0 0 0 0 0 0

addWorkerBandStats :: WorkerBandStats -> WorkerBandStats -> WorkerBandStats
addWorkerBandStats a b = WorkerBandStats
  { wbsFreeBands           = wbsFreeBands           a + wbsFreeBands           b
  , wbsSinkFreeBands       = wbsSinkFreeBands       a + wbsSinkFreeBands       b
  , wbsSinkBands           = wbsSinkBands           a + wbsSinkBands           b
  , wbsMaxSinkFreeWidth    = max (wbsMaxSinkFreeWidth a)
                                  (wbsMaxSinkFreeWidth b)
  , wbsMaxSinkWidth        = max (wbsMaxSinkWidth a)
                                  (wbsMaxSinkWidth b)
  , wbsMaxBandWork         = max (wbsMaxBandWork a)
                                  (wbsMaxBandWork b)
  , wbsDirectCandidates    = wbsDirectCandidates    a + wbsDirectCandidates    b
  , wbsReductionCandidates = wbsReductionCandidates a + wbsReductionCandidates b
  }

workerBandStats :: RuntimeGraph -> Either String WorkerBandStats
workerBandStats rt = do
  steps <- layeredRegionSchedule rt
  let byIx = M.fromList [(rrIndex r, r) | r <- rgRuntimeRegions rt]
      layerRegions fl =
        traverse
          (\ix -> case M.lookup ix byIx of
             Just r  -> Right r
             Nothing -> Left $
               "workerBandStats: layered schedule referenced unknown "
               <> "region " <> show ix)
          (flRegions fl)
      rowFor layer =
        let width   = length layer
            hasSink = any (not . null . bfWrites . rrFootprint) layer
            work    = sum (map (length . rrNodes) layer)
        in if hasSink
             then emptyWorkerBandStats
               { wbsFreeBands           = 1
               , wbsSinkBands           = 1
               , wbsMaxSinkWidth        = width
               , wbsMaxBandWork         = work
               , wbsReductionCandidates = if width >= 2 then 1 else 0
               }
             else emptyWorkerBandStats
               { wbsFreeBands         = 1
               , wbsSinkFreeBands     = 1
               , wbsMaxSinkFreeWidth  = width
               , wbsMaxBandWork       = work
               , wbsDirectCandidates  = if width >= 2 then 1 else 0
               }
  layers <- traverse layerRegions
    [ fl | ScheduleFreeLayer fl <- steps ]
  pure (foldr (addWorkerBandStats . rowFor) emptyWorkerBandStats layers)

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
  , srWorkerBands  :: !WorkerBandStats
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
  } deriving (Eq, Show)

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
  -> WorkerBandStats
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
       , srWorkerBands  = workerStats
       , srRateDist     = rateDistribution rt
       , srEdgeBuckets  = edgeRateBuckets rt
         -- §4.D.2: read from the unfused graph deliberately. The
         -- §4.C fused view replaces 'RFrom' with 'RFused' for
         -- elided producers, which would silently drop the very
         -- edges the survey is meant to count.
       , srOppProducers = sampleRateOpportunityProducers rt
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
  workerStats <- either (Left . stamp) Right (workerBandStats rt)
  Right (surveyRuntimeGraph d t rt rtF stats workerStats)

-- | A short human label used in error messages.
surveyTag :: String -> Maybe String -> String
surveyTag d Nothing  = "demo=" <> d
surveyTag d (Just t) = "demo=" <> d <> " template=" <> t

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
  [ ( "shape/sin-gain-out"
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
  printCorpusWorkerBandWidth allRows
  putStrLn ""
  printEnsembleScheduleWidth ensembleRows
  putStrLn ""
  printRateDistribution allRows
  putStrLn ""
  printEdgeRateDistribution allRows
  putStrLn ""
  printSurveyTotals demoRows corpusRows
  putStrLn ""
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
--             gate in notes/fusion-strategy.md).
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
    ["shape", "found", "claimed", "missed", "sources", "status", "next"]
  mapM_ (putStrLn . formatScanRow) (scanRows rows)
  where
    formatScanRow cols =
      intercalate "  " (zipWith padCell scanColumnWidths cols)
    padCell w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

scanColumnWidths :: [Int]
scanColumnWidths = [32, 6, 8, 7, 8, 10, 16]

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
-- candidate gate from notes/fusion-strategy.md applies only when
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
printCorpusWorkerBandWidth :: [SurveyRow] -> IO ()
printCorpusWorkerBandWidth rows = do
  let corpusRows = filter (("corpus:" `isPrefixOf`) . srDemo) rows
  putStrLn "─── Corpus FreeLayer-width survey (§4.E.C1d region candidates) ───"
  putStrLn $ formatWorkerBandRow
    [ "corpus", "template", "bands", "sf", "sink"
    , "maxSfW", "maxSinkW", "maxWork", "dirC1d", "redC1d"
    ]
  mapM_ (putStrLn . formatWorkerBandRow . renderWorkerBandRow) corpusRows
  putStrLn ""
  let agg = foldr addWorkerBandStats emptyWorkerBandStats
              (map srWorkerBands corpusRows)
  putStrLn $ "  totals: "
          <> "graphs="  <> show (length corpusRows)
          <> "  bands=" <> show (wbsFreeBands agg)
          <> "  sf="    <> show (wbsSinkFreeBands agg)
          <> "  sink="  <> show (wbsSinkBands agg)
          <> "  maxSfW="   <> show (wbsMaxSinkFreeWidth agg)
          <> "  maxSinkW=" <> show (wbsMaxSinkWidth agg)
          <> "  maxWork="  <> show (wbsMaxBandWork agg)
          <> "  dirC1d="   <> show (wbsDirectCandidates agg)
          <> "  redC1d="   <> show (wbsReductionCandidates agg)

renderWorkerBandRow :: SurveyRow -> [String]
renderWorkerBandRow r =
  let s = srWorkerBands r
  in [ srDemo r
     , maybe "" id (srTemplate r)
     , show (wbsFreeBands s)
     , show (wbsSinkFreeBands s)
     , show (wbsSinkBands s)
     , show (wbsMaxSinkFreeWidth s)
     , show (wbsMaxSinkWidth s)
     , show (wbsMaxBandWork s)
     , show (wbsDirectCandidates s)
     , show (wbsReductionCandidates s)
     ]

workerBandColumnWidths :: [Int]
workerBandColumnWidths = [42, 14, 6, 4, 5, 6, 8, 8, 7, 7]

formatWorkerBandRow :: [String] -> String
formatWorkerBandRow cols =
  intercalate "  " (zipWith pad workerBandColumnWidths cols)
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
