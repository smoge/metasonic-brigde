{-# LANGUAGE LambdaCase #-}

-- | Graph fixtures, generators, shared helpers, and core compiler properties.
module MetaSonic.Spec.Core where

import qualified Data.Map.Strict           as M
import qualified Data.Set                  as S
import           Data.List                 (isInfixOf, isPrefixOf, nub, sort,
                                            sortBy)
import           Control.Exception         (try)
import           Data.Maybe                (mapMaybe)
import           Data.Ord                  (comparing)
import           Data.Word                 (Word8)
import           Foreign.C.Types           (CFloat (..))
import           Foreign.Marshal.Alloc     (allocaBytes)
import           Foreign.Marshal.Array     (peekArray)
import           Foreign.Ptr               (Ptr, castPtr)

import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck     as QC

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI      (c_rt_graph_kind_supported,
                                            c_rt_graph_process,
                                            c_rt_graph_read_bus,
                                            c_rt_graph_region_kernel_supported,
                                            loadRuntimeGraph,
                                            withRTGraph)
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Bridge.Validate
import           MetaSonic.Types

import           MetaSonic.Spec.Core.BusRouting (busRoutingCoreTests)
import           MetaSonic.Spec.Core.CCBuilder (ccBuilderTests)
import           MetaSonic.Spec.Core.Dependencies (dependenciesTests)
import           MetaSonic.Spec.Core.FusionAlgebra (fusionAlgebraTests)
import           MetaSonic.Spec.Core.MigrationKeys (migrationKeyTests)
import           MetaSonic.Spec.Core.NodeIndex (nodeIndexResolutionTests)
import           MetaSonic.Spec.Core.RatePropagation (ratePropagationTests)
import           MetaSonic.Spec.Core.RegionScheduling (regionSchedulingTests)
import           MetaSonic.Spec.Core.SelectRegionKernels (selectRegionKernelsTests)
import           MetaSonic.Spec.Core.TemplateGraph (templateGraphTests)
import           MetaSonic.Spec.CoreShared

------------------------------------------------------------
-- Unit tests
------------------------------------------------------------

unitTests :: TestTree
unitTests = testGroup "Unit tests"
  [ testGroup "validateAndSort succeeds on demo graphs"
      [ testCase name $ case validateAndSort g of
          Right _  -> pure ()
          Left err -> assertFailure $ "validateAndSort failed: " <> err
      | (name, g) <- demoGraphs
      ]

  , testGroup "lowerGraph preserves node count on demo graphs"
      [ testCase name $ case lowerGraph g of
          Left err -> assertFailure $ "lowerGraph failed: " <> err
          Right ir -> length (giNodes ir) @?= M.size (sgNodes g)
      | (name, g) <- demoGraphs
      ]

  , testGroup "compileRuntimeGraph produces dense indices on demo graphs"
      [ testCase name $ case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure err
          Right rt -> assertDenseIndices rt
      | (name, g) <- demoGraphs
      ]

  , testGroup "every RFrom references an earlier index on demo graphs"
      [ testCase name $ case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure err
          Right rt -> assertTopoOrder rt
      | (name, g) <- demoGraphs
      ]

  , nodeIndexResolutionTests

  , migrationKeyTests

  , ccBuilderTests

  , testCase "checkDependencies rejects missing references" $
      case checkDependencies missingDepGraph of
        Right () ->
          assertFailure "expected checkDependencies to reject missing dep"
        Left err ->
          assertBool ("expected 'Missing' in error, got: " <> err)
                    ("Missing" `isPrefixOf` err)

  , testCase "validateAndSort rejects cycles" $
      case validateAndSort cycleGraph of
        Right _ ->
          assertFailure "expected validateAndSort to reject cycle"
        Left err ->
          assertBool ("expected 'Cycle' in error, got: " <> err)
                    ("Cycle" `isPrefixOf` err)

  , testCase "ringmod: a gain node has both inputs wired as RFrom" $
      case lowerGraph ringModGraph >>= compileRuntimeGraph of
        Left err -> assertFailure err
        Right rt ->
          let hasTwoAudioInputs n =
                rnKind n == KGain
                && length [() | RFrom _ _ <- rnInputs n] == 2
          in assertBool
               "expected a Gain node with two RFrom inputs in ringmod"
               (any hasTwoAudioInputs (rgNodes rt))

  , testCase "fm: a SinOsc has its frequency port wired as RFrom" $
      case lowerGraph fmGraph >>= compileRuntimeGraph of
        Left err -> assertFailure err
        Right rt ->
          let hasModulatedFreq n = case (rnKind n, rnInputs n) of
                (KSinOsc, RFrom _ _ : _) -> True
                _                        -> False
          in assertBool
               "expected a SinOsc with RFrom on port 0 in fm graph"
               (any hasModulatedFreq (rgNodes rt))

  , testCase "fm: contains an Add node biasing freq off zero" $
      case lowerGraph fmGraph >>= compileRuntimeGraph of
        Left err -> assertFailure err
        Right rt ->
          let isVibratoBias n = case (rnKind n, rnControls n, rnInputs n) of
                (KAdd, 440.0 : _, _ : RFrom _ _ : _) -> True
                _                                    -> False
          in assertBool
               "expected an Add node with bias=440.0 and modulated port 1"
               (any isVibratoBias (rgNodes rt))

  , -- Contract test: every Haskell NodeKind must map to a kindTag
    -- that the C++ runtime recognizes via kind_from_tag. Adding a
    -- constructor to NodeKind without updating rt_graph.cpp will fail
    -- here. Enum/Bounded on NodeKind ensures new constructors are
    -- automatically covered.
    testGroup "C ABI agrees on every NodeKind tag"
      [ testCase (show k) $ do
          ok <- c_rt_graph_kind_supported (kindTag k)
          assertBool
            ("rt_graph_kind_supported(" <> show (kindTag k) <> ") "
              <> "returned 0 for " <> show k <> " — C++ kind_from_tag "
              <> "is missing this case")
            (ok == 1)
      | k <- [minBound .. maxBound :: NodeKind]
      ]

  , -- Phase 4.B: every Haskell RegionKernel must round-trip through
    -- the C ABI introspection entry. Mirrors the kindTag agreement
    -- test for node kinds. If RegionKernel grows a new constructor
    -- without the matching C++ enum entry, this test catches the
    -- drift before any region kernel lands silently.
    testGroup "C ABI agrees on every RegionKernel tag"
      [ testCase (show k) $ do
          ok <- c_rt_graph_region_kernel_supported (kernelTag k)
          assertBool
            ("rt_graph_region_kernel_supported(" <> show (kernelTag k)
              <> ") returned 0 for " <> show k
              <> " — C++ region_kernel_from_tag is missing this case")
            (ok == 1)
      | k <- [minBound .. maxBound :: RegionKernel]
      ]

  , testGroup "Edge graphs"
      [ testCase "empty graph: validateAndSort succeeds with no nodes" $
          case validateAndSort emptyGraph_ of
            Right []  -> pure ()
            Right ns  -> assertFailure $ "expected [], got " <> show (length ns) <> " nodes"
            Left  err -> assertFailure $ "validateAndSort failed: " <> err

      , testCase "empty graph: lowerGraph yields 0 IR nodes" $
          case lowerGraph emptyGraph_ of
            Right ir -> length (giNodes ir) @?= 0
            Left err -> assertFailure $ "lowerGraph failed: " <> err

      , testCase "empty graph: compileRuntimeGraph yields 0 runtime nodes" $
          case lowerGraph emptyGraph_ >>= compileRuntimeGraph of
            Right rt -> length (rgNodes rt) @?= 0
            Left err -> assertFailure $ "compile failed: " <> err

      , testCase "single Out with Param source compiles and has 1 node" $
          case lowerGraph silentOutGraph >>= compileRuntimeGraph of
            Right rt -> do
              length (rgNodes rt) @?= 1
              case rgNodes rt of
                [n] -> rnKind n @?= KOut
                _   -> assertFailure "expected one node"
            Left err -> assertFailure err

      , testCase "disconnected subgraphs: both Outs survive lowering" $
          case lowerGraph disconnectedGraph >>= compileRuntimeGraph of
            Right rt -> do
              let outs = [ n | n <- rgNodes rt, rnKind n == KOut ]
              length outs @?= 2
              let chans = sort (map (head . rnControls) outs)
              chans @?= [0.0, 1.0]
            Left err -> assertFailure err
      ]

  , dependenciesTests

  , busRoutingCoreTests

  , templateGraphTests

  , ratePropagationTests

  , fusionAlgebraTests

  , selectRegionKernelsTests

  , regionSchedulingTests

  , testGroup "Phase 4.D.1: rnRate carries IR-propagated rate"
      [ -- The runtime graph must preserve every IR node's
        -- propagated 'irRate' on the corresponding 'rnRate'. This
        -- is the load-bearing pin for §4.D.1: the descriptive
        -- view's whole job is to keep IR rate inference
        -- observable through the runtime boundary, so any drift
        -- between the two would silently break the survey's
        -- distribution counts and make rate-shaped optimization
        -- decisions unsound.
        testCase "rnRate matches irRate for every node (mixed osc + transform)" $ do
          let g = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                out 0 a
          ir <- case lowerGraph g of
            Right x  -> pure x
            Left err -> assertFailure ("lowerGraph failed: " <> err)
                          >> error "unreachable"
          rt <- case compileRuntimeGraph ir of
            Right x  -> pure x
            Left err -> assertFailure ("compile failed: " <> err)
                          >> error "unreachable"
          let irByID =
                M.fromList [(irNodeID n, irRate n) | n <- giNodes ir]
              checkOne n = case M.lookup (rnOriginalID n) irByID of
                Just r ->
                  assertEqual ("rnRate vs irRate for " <> show (rnIndex n))
                              r (rnRate n)
                Nothing ->
                  assertFailure $ "missing IR rate for "
                               <> show (rnOriginalID n)
          mapM_ checkOne (rgNodes rt)

      , -- Pure-literal subgraph: 'KOut' has a 'CompileRate' kind
        -- floor, its only input is a 'Literal' (also 'CompileRate'),
        -- and propagation joins to 'CompileRate'. This is the
        -- "stays low where possible" pin — any future regression
        -- that always lifts to 'SampleRate' would fire it.
        testCase "constant-only graph (out (Param 0.0)) stays at CompileRate" $ do
          let g = runSynth (out 0 (Param 0.0))
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let rates = map rnRate (rgNodes rt)
              assertBool ("expected all CompileRate, got " <> show rates)
                         (all (== CompileRate) rates)

      , -- Oscillator chain: the 'KSinOsc' floor is 'SampleRate',
        -- and propagation lifts every downstream node to match.
        -- This is the dual of the constant-only test: when an
        -- audio producer is in the graph, the join must reach
        -- every reachable consumer.
        testCase "oscillator chain lifts every downstream node to SampleRate" $ do
          let g = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let kindRates =
                    [(rnKind n, rnRate n) | n <- rgNodes rt]
              assertEqual "kind/rate pairs"
                [(KSinOsc, SampleRate)
                ,(KGain,   SampleRate)
                ,(KOut,    SampleRate)
                ]
                kindRates

      , -- Region rate consistency: for every region produced by
        -- 'compileRuntimeGraph', the region's 'rrRate' must equal
        -- the max of its members' 'rnRate'. 'formRegions' already
        -- computes 'regRate' as the join over members at the IR
        -- level; this test pins that the runtime's per-node and
        -- per-region rate views stay in agreement after lowering,
        -- so the descriptive survey can't end up reporting a
        -- region rate that no member node actually claims.
        testCase "every rrRate equals max of member rnRates" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let nodeMap =
                    M.fromList [(rnIndex n, rnRate n) | n <- rgNodes rt]
                  memberRate ix =
                    M.findWithDefault CompileRate ix nodeMap
              sequence_
                [ assertEqual
                    ("region " <> show (rrIndex r) <> " rrRate vs join")
                    (maximum (CompileRate : map memberRate (rrNodes r)))
                    (rrRate r)
                | r <- rgRuntimeRegions rt
                ]

      , -- Bucket-count integrity: a per-rate histogram of all
        -- runtime nodes must sum to the node count exactly. The
        -- survey footer divides 'rdSample' by this total to
        -- compute @S%@; if the bucket counts and the node count
        -- could ever disagree (double-counting, missing rate
        -- value, off-by-one), the headline percentage would be
        -- wrong. Walking 'rgNodes' once and binning by 'rnRate'
        -- here mirrors what 'rateDistribution' does in the survey
        -- driver.
        testCase "rate-bucket counts sum to total node count" $ do
          let g = runSynth $ do
                s1 <- sinOsc 220.0 0.0; a1 <- gain s1 (Param 0.3); out 0 a1
                s2 <- sawOsc 110.0 0.0; a2 <- gain s2 (Param 0.3); out 1 a2
                n  <- noiseGen;         a3 <- gain n  (Param 0.1); out 0 a3
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let nodes = rgNodes rt
                  total = length nodes
                  countAt r = length (filter ((== r) . rnRate) nodes)
                  c = countAt CompileRate
                  i = countAt InitRate
                  b = countAt BlockRate
                  s = countAt SampleRate
              assertEqual "bucket sum vs total" total (c + i + b + s)
              -- Sanity: this graph is osc/noise dominated, so
              -- every node must end up at SampleRate.
              assertEqual "all nodes SampleRate on osc-only graph"
                          total s
      ]

  , testGroup "Phase 4.D.2: portInfo metadata"
      [ -- Totality: for every 'NodeKind', 'portInfo' must return
        -- 'Just' on every port in @[0 .. ksAudioArity - 1]@ and
        -- 'Nothing' on the next index past that range. This is the
        -- drift guard between 'kindSpec' (which the §4.B / §4.D
        -- code paths already trust) and the new per-port table.
        -- Without it, adding an audio input to a 'UGen' constructor
        -- could leave 'portInfo' stale and silently drop edges
        -- from the §4.D.2 edge-rate survey.
        testCase "portInfo is total over the declared audio-input range" $
          sequence_
            [ do
                let arity = ksAudioArity (kindSpec k)
                sequence_
                  [ assertBool
                      (show k <> " port " <> show i
                       <> " should have a PortInfo entry")
                      (case portInfo k (PortIndex i) of
                         Just _  -> True
                         Nothing -> False)
                  | i <- [0 .. arity - 1]
                  ]
                assertEqual
                  (show k <> " port " <> show arity
                   <> " (one past the declared arity) must be Nothing")
                  Nothing
                  (portInfo k (PortIndex arity))
            | k <- [minBound .. maxBound :: NodeKind]
            ]

      , -- Pin the load-bearing classifications. These three
        -- entries are the survey's whole reason to exist:
        --   * Filter freq / q are block-latched (sample 0 only).
        --   * Oscillator phase is init-only (never resolved per
        --     block).
        --   * Gain.amount is sample-accurate (counter-example for
        --     the handoff-doc claim that "scalar gain amount is a
        --     block-latch opportunity" — it is not, when wired).
        -- Any drift in these specific rows would invalidate the
        -- §4.D.2 opportunity number directly, so they're pinned
        -- by name rather than by enumeration.
        testCase "filter freq/q are PortBlockLatched, named freq/q" $ do
          portInfo KLPF (PortIndex 1)
            @?= Just (PortInfo PortBlockLatched "freq")
          portInfo KLPF (PortIndex 2)
            @?= Just (PortInfo PortBlockLatched "q")
          portInfo KHPF (PortIndex 1)
            @?= Just (PortInfo PortBlockLatched "freq")
          portInfo KBPF (PortIndex 2)
            @?= Just (PortInfo PortBlockLatched "q")
          portInfo KNotch (PortIndex 1)
            @?= Just (PortInfo PortBlockLatched "freq")

      , -- Phase ports are 'PortIgnored', not 'PortInitOnly': the
        -- C++ kernels never resolve port 1 in the audio loop, so a
        -- wired 'RFrom' source is silently dropped (the kernel
        -- takes the initial phase from 'rnControls[1]' at
        -- construction). This distinction matters for the
        -- §4.D.2 opportunity count — 'PortIgnored' edges are
        -- excluded because there is no consumption to demote.
        testCase "oscillator phase ports are PortIgnored, named phase" $ do
          portInfo KSinOsc   (PortIndex 1)
            @?= Just (PortInfo PortIgnored "phase")
          portInfo KSawOsc   (PortIndex 1)
            @?= Just (PortInfo PortIgnored "phase")
          portInfo KTriOsc   (PortIndex 1)
            @?= Just (PortInfo PortIgnored "phase")
          portInfo KPulseOsc (PortIndex 1)
            @?= Just (PortInfo PortIgnored "phase")

      , testCase "Gain.amount is PortSampleAccurate (not block-latched)" $ do
          portInfo KGain (PortIndex 1)
            @?= Just (PortInfo PortSampleAccurate "amount")
          -- Spot-check sibling sample-accurate rows so a future
          -- change that flips Gain.amount accidentally also
          -- flips at least one of these.
          portInfo KPulseOsc (PortIndex 2)
            @?= Just (PortInfo PortSampleAccurate "width")
          portInfo KDelay   (PortIndex 1)
            @?= Just (PortInfo PortSampleAccurate "time")
          portInfo KSmooth  (PortIndex 0)
            @?= Just (PortInfo PortSampleAccurate "target")

      , testCase "kinds with no audio inputs return Nothing on every port" $
          sequence_
            [ assertEqual
                (show k <> " port 0 should be Nothing")
                Nothing
                (portInfo k (PortIndex 0))
            | k <- [KNoiseGen, KBusIn, KBusInDelayed]
            ]

      , -- Producer-grouped headline (§4.D.2 'opportunity' count).
        -- An LFO that feeds /both/ LPF.freq (PortBlockLatched) and
        -- Gain.amount (PortSampleAccurate) is /not/ an opportunity:
        -- it must remain sample-rate to serve its sample-accurate
        -- consumer, even though one of its edges lands in a
        -- block-latched bucket. Counting edges instead of producers
        -- would over-report this case — 1 producer node would show
        -- as 2 opportunity edges.
        testCase "sampleRateOpportunityProducers: shared LFO is NOT an opportunity" $ do
          let g = runSynth $ do
                lfo <- sinOsc 4.0 0.0
                s   <- sawOsc 110.0 0.0
                f   <- lpf s lfo (Param 4.0)   -- LFO → lpf.freq (block-latched)
                a   <- gain f lfo              -- LFO → gain.amount (sample-acc.)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let ops = sampleRateOpportunityProducers rt
              assertBool
                ("LFO with mixed-policy consumers must not be flagged "
                 <> "as an opportunity, got: " <> show ops)
                (KSinOsc `notElem` ops)

      , -- Counter-pin to the shared-LFO test: a sample-rate
        -- producer whose /every/ active consumer is non-sample-
        -- accurate (here, an LFO feeding only LPF.freq) does
        -- qualify as an opportunity.
        testCase "sampleRateOpportunityProducers: LFO → LPF.freq alone IS an opportunity" $ do
          let g = runSynth $ do
                lfo <- sinOsc 4.0 0.0
                s   <- sawOsc 110.0 0.0
                f   <- lpf s lfo (Param 4.0)
                a   <- gain f (Param 0.4)      -- gain.amount is constant
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let ops = sampleRateOpportunityProducers rt
              assertBool
                ("LFO with only block-latched consumer must be "
                 <> "flagged, got: " <> show ops)
                (KSinOsc `elem` ops)

      , -- Phase-port edges must not inflate the opportunity count.
        -- An LFO wired to the phase port of a sin oscillator is
        -- silently dropped by the runtime (PortIgnored), so the
        -- LFO has /no/ active consumers in this graph and is not
        -- an opportunity — even though "the LFO has only non-
        -- sample-accurate consumers" looks superficially true.
        testCase "sampleRateOpportunityProducers: PortIgnored consumers don't qualify" $ do
          let g = runSynth $ do
                lfo <- sinOsc 4.0 0.0
                s   <- sinOsc 220.0 lfo        -- LFO → sin.phase (PortIgnored)
                a   <- gain s (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let ops = sampleRateOpportunityProducers rt
              -- The LFO has only an ignored consumer (sin.phase);
              -- the carrier sin has only sample-accurate consumers
              -- (gain.sig); neither qualifies.
              assertEqual
                ("expected no opportunity producers in "
                 <> "phase-mod-only graph, got: " <> show ops)
                [] ops

      , -- Integration of 'edgeRateBuckets' with 'portInfo'. An
        -- Env-driven LPF cutoff is the canonical §4.D.2
        -- opportunity edge: the 'KEnv' source has 'rnRate =
        -- SampleRate' (kind floor), and 'KLPF' port 1 has
        -- consumption policy 'PortBlockLatched'. The bucket lookup
        -- must produce exactly one such edge with the expected
        -- producer kind and example string. Catches drift where a
        -- future change to either the kind floors, 'propagateRates',
        -- the unfused-graph contract of 'compileRuntimeGraph', or
        -- the 'portInfo' table would silently re-classify the edge.
        testCase "edgeRateBuckets: Env → LPF.freq lands in (SampleRate, PortBlockLatched)" $ do
          let g = runSynth $ do
                e <- env (Param 1.0) 0.005 0.05 0.7 0.5
                n <- noiseGen
                f <- lpf n e (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let buckets = edgeRateBuckets rt
                  key     = (SampleRate, PortBlockLatched)
              case M.lookup key buckets of
                Nothing ->
                  assertFailure $
                    "expected a bucket at " <> show key
                    <> ", got " <> show (M.keys buckets)
                Just b -> do
                  -- Exactly one Env → LPF.freq edge.
                  erbEdgeCount b @?= 1
                  -- Producer kind = Env.
                  KEnv `elem` erbProducerKinds b @?= True
                  -- Example string ends with the LPF.freq
                  -- destination so survey output is legible.
                  case erbExample b of
                    Just s ->
                      assertBool
                        ("example should mention LPF.freq, got: " <> s)
                        ("KLPF.freq" `isInfixOf` s)
                    Nothing ->
                      assertFailure "bucket missing example"
      ]

  , testCase "kindTag is injective" $
      let ks = [minBound .. maxBound :: NodeKind]
          ts = map kindTag ks
      in assertEqual
           "two NodeKinds share a kindTag — C++ dispatch will collide"
           (length ks)
           (length (nub ts))
  ]

------------------------------------------------------------
-- Property tests
------------------------------------------------------------

properties :: TestTree
properties = testGroup "Properties"
  [ QC.testProperty "compileRuntimeGraph: indices are [0..n-1]" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propDenseIndices

  , QC.testProperty "compileRuntimeGraph: every RFrom is in [0, n) and earlier" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propTopoOrder

  , QC.testProperty "lowerGraph preserves node count" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propPreservesCount

  , QC.testProperty "validateAndSort succeeds on well-formed graphs" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propValidates

  , QC.testProperty "ugenView arities match kindSpec for every UGen" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propUgenViewMatchesSpec

  , QC.testProperty "compileRuntimeGraph is deterministic" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propDeterministic

  , QC.testProperty "every source NodeID appears once as rnOriginalID" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propBijection

  , QC.testProperty "kind multiset preserved from source to runtime" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propKindCounts

  , QC.testProperty "Out-spec count preserved as KOut node count" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propOutCount

  , QC.testProperty "dependencies of every UGen point at existing nodes" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propDepsExist

  , QC.testProperty "regions partition the IR nodes" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionPartition

  , QC.testProperty "rgNodeMap and regNodes agree" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionNodeMapConsistent

  , QC.testProperty "region IDs are unique" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionIDsUnique

  , QC.testProperty "region deps refer only to existing regions, no self-edges" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionDepsWellFormed

  , QC.testProperty "every region's rate is compatible with its member nodes" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionRateCompatible

  , QC.testProperty "RuntimeGraph region overlay round-trips formRegions" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRuntimeRegionsRoundTrip

  , QC.testProperty "RuntimeGraph regions partition node indices contiguously" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRuntimeRegionsContiguous

  , QC.testProperty "rnOutputUse classification matches consumer-region membership" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propOutputUseConsistent

  , QC.testProperty "rnConsumerCount matches direct FromNode references" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propConsumerCountConsistent

  , QC.testProperty "every BusOut precedes every same-bus BusIn in the schedule" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propBusOrdering

  , -- Rate propagation: see Note [Rate inference vs rate propagation]
    -- in "MetaSonic.Bridge.IR" for the algorithm. These properties pin
    -- the three structural invariants of the lift:
    --
    --   1. each node's rate is at least its kind's floor
    --   2. each node's rate is at least every input's rate
    --   3. running the lift twice is the same as running it once
    --
    -- (1) is the kind-floor guarantee. (2) is the join law of the
    -- lattice — the whole point of propagation. (3) is idempotence:
    -- the lift reaches a fixed point in one pass.
    QC.testProperty "every node's irRate ≥ kind floor (post-propagation)" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRateAtLeastFloor

  , QC.testProperty "every node's irRate ≥ max of its inputs' rates" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRateAtLeastInputs

  , QC.testProperty "propagateRates is idempotent on lowered IR" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propPropagationIdempotent

  , QC.testProperty "propagateRates preserves all fields except irRate" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propPropagationStructural
  ]

propDenseIndices :: SynthGraph -> Property
propDenseIndices g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    let n   = length (rgNodes rt)
        idx = [ i | RuntimeNode { rnIndex = NodeIndex i } <- rgNodes rt ]
    in idx === [0 .. n - 1]

propTopoOrder :: SynthGraph -> Property
propTopoOrder g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    let n = length (rgNodes rt)
    in conjoin
         [ counterexample ("node " <> show (rnIndex node)) $
             all (refsEarlier n (rnIndex node)) (rnInputs node)
         | node <- rgNodes rt
         ]
  where
    refsEarlier n (NodeIndex dst) (RFrom (NodeIndex src) _) =
      src >= 0 && src < dst && src < n
    refsEarlier _ _               (RConst _)                = True

propPreservesCount :: SynthGraph -> Property
propPreservesCount g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> length (giNodes ir) === M.size (sgNodes g)

propValidates :: SynthGraph -> Property
propValidates g = case validateAndSort g of
  Left err -> counterexample ("validateAndSort failed: " <> err) False
  Right _  -> property True

-- | Drift guard for the per-kind metadata: for every UGen in a
-- generated graph, the arities reported by @ugenView@ must match
-- the @kindSpec@ table.
propUgenViewMatchesSpec :: SynthGraph -> Property
propUgenViewMatchesSpec g = conjoin
  [ counterexample (show u) $
         length (uvInputs   v) === ksAudioArity   ks
    .&&. length (uvControls v) === ksControlArity ks
  | ns <- M.elems (sgNodes g)
  , let u  = nsUgen ns
        v  = ugenView u
        ks = kindSpec (uvKind v)
  ]

-- | Compiling the same graph twice must produce identical RuntimeGraphs.
propDeterministic :: SynthGraph -> Property
propDeterministic g =
  let r1 = lowerGraph g >>= compileRuntimeGraph
      r2 = lowerGraph g >>= compileRuntimeGraph
  in r1 === r2

-- | Every source NodeID appears exactly once as rnOriginalID.
propBijection :: SynthGraph -> Property
propBijection g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    sort (map rnOriginalID (rgNodes rt)) === sort (M.keys (sgNodes g))

-- | The multiset of NodeKinds is preserved from source to runtime.
propKindCounts :: SynthGraph -> Property
propKindCounts g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    let byTag    = sortBy (comparing kindTag)
        srcKinds = byTag (map (ugenKind . nsUgen) (M.elems (sgNodes g)))
        rtKinds  = byTag (map rnKind (rgNodes rt))
    in srcKinds === rtKinds

-- | Number of Out specs in the source equals number of KOut nodes in
-- the runtime.
propOutCount :: SynthGraph -> Property
propOutCount g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    let srcOuts = length [ () | NodeSpec { nsUgen = Out{} } <- M.elems (sgNodes g) ]
        rtOuts  = length [ () | n <- rgNodes rt, rnKind n == KOut ]
    in srcOuts === rtOuts

-- | Every NodeID returned by 'dependencies' on a node in the graph
-- must be a node-key in that graph.
propDepsExist :: SynthGraph -> Property
propDepsExist g =
  let nodes = sgNodes g
      keys  = M.keysSet nodes
      bad   = [ (nid, dep)
              | (nid, spec) <- M.toList nodes
              , dep <- dependencies (nsUgen spec)
              , dep `S.notMember` keys
              ]
  in counterexample ("dangling deps: " <> show bad) (null bad)

------------------------------------------------------------
-- Region-formation invariants
------------------------------------------------------------

-- | Every IR node appears in exactly one region.
propRegionPartition :: SynthGraph -> Property
propRegionPartition g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg          = formRegions (giNodes ir)
        regionIDs   = concatMap regNodes (rgRegions rg)
        irNodeIDs   = map irNodeID (giNodes ir)
    in conjoin
         [ counterexample "region members are not unique" $
             length regionIDs === length (nub regionIDs)
         , counterexample "region members ≠ IR nodes" $
             sort regionIDs === sort irNodeIDs
         ]

-- | rgNodeMap matches regNodes membership both ways.
propRegionNodeMapConsistent :: SynthGraph -> Property
propRegionNodeMapConsistent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg = formRegions (giNodes ir)
        forwardOK =
          [ M.lookup nid (rgNodeMap rg) == Just (regID r)
          | r <- rgRegions rg, nid <- regNodes r
          ]
        reverseOK =
          [ nid `elem` regNodes r
          | (nid, rid) <- M.toList (rgNodeMap rg)
          , Just r <- [findRegion rid (rgRegions rg)]
          ]
    in conjoin
         [ counterexample "regNodes → rgNodeMap mismatch" $
             property (and forwardOK)
         , counterexample "rgNodeMap → regNodes mismatch" $
             property (and reverseOK)
         ]
  where
    findRegion rid = lookup rid . map (\r -> (regID r, r))

-- | Region IDs are unique within a RegionGraph.
propRegionIDsUnique :: SynthGraph -> Property
propRegionIDsUnique g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rids = map regID (rgRegions (formRegions (giNodes ir)))
    in length rids === length (nub rids)

-- | Region deps refer only to existing region IDs, and never to a
-- region's own ID.
propRegionDepsWellFormed :: SynthGraph -> Property
propRegionDepsWellFormed g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg     = formRegions (giNodes ir)
        allIDs = S.fromList (map regID (rgRegions rg))
    in conjoin
         [ counterexample (show (regID r) <> " has bad deps: " <> show (regDeps r)) $
             property $
               regDeps r `S.isSubsetOf` allIDs
               && regID r `S.notMember` regDeps r
         | r <- rgRegions rg
         ]

-- | Every same-bus (BusWrite n, BusRead n) pair must have the writer
-- precede the reader in the topological order. This is the property
-- version of the unit tests in @Bus routing (BusIn/BusOut and E_r
-- edges)@: it asserts that 'effectiveDeps' actually puts every
-- writer before every reader, on every randomly generated graph.
--
-- Cycles in E_s ∪ E_r show up as a 'Left' from 'validateAndSort' and
-- are skipped (the cycle-rejection unit test covers those).
propBusOrdering :: SynthGraph -> Property
propBusOrdering g = case validateAndSort g of
  Left _    -> property True
  Right ord ->
    let posOf   = M.fromList (zip ord [(0 :: Int) ..])
        nodes   = M.toList (sgNodes g)
        writers = [ (nid, n) | (nid, ns) <- nodes
                             , BusWrite n <- inferEff (nsUgen ns) ]
        readers = [ (nid, n) | (nid, ns) <- nodes
                             , BusRead  n <- inferEff (nsUgen ns) ]
        bad =
          [ (w, r, n)
          | (w, bw) <- writers
          , (r, br) <- readers
          , bw == br
          , let n  = bw
                pw = posOf M.! w
                pr = posOf M.! r
          , pw >= pr
          ]
    in counterexample ("bad bus orderings: " <> show bad) (null bad)

-- | Every node's propagated rate must be at least its kind's floor.
-- This is the trivial half of the join: a kind floor is one of the
-- arguments of 'max', so the result is always ≥ the floor.
propRateAtLeastFloor :: SynthGraph -> Property
propRateAtLeastFloor g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> conjoin
    [ counterexample
        ("node " <> show (irNodeID n) <> " of kind " <> show (irKind n)
          <> ": irRate " <> show (irRate n)
          <> " < floor " <> show floor_)
        (irRate n >= floor_)
    | n <- giNodes ir
    , let floor_ = ksRate (kindSpec (irKind n))
    ]

-- | Every node's propagated rate must be at least the maximum rate of
-- its inputs (FromNode inputs contribute the source node's rate;
-- Literal inputs contribute CompileRate). This is the load-bearing
-- half of the join: it's the property that makes
-- 'MetaSonic.Bridge.IR.checkRateEdges' vacuous post-propagation.
propRateAtLeastInputs :: SynthGraph -> Property
propRateAtLeastInputs g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rateMap = M.fromList [ (irNodeID n, irRate n) | n <- giNodes ir ]
    in conjoin
         [ counterexample
             ("node " <> show (irNodeID n)
               <> ": irRate " <> show (irRate n)
               <> " < input rate " <> show inRate
               <> " (input " <> show inp <> ")")
             (irRate n >= inRate)
         | n   <- giNodes ir
         , inp <- irInputs n
         , let inRate = case inp of
                 FromNode src _ -> M.findWithDefault CompileRate src rateMap
                 Literal _      -> CompileRate
         ]

-- | Propagation reaches a fixed point in one pass. Running it twice
-- on a lowered IR must yield the same IR as running it once. This is
-- a defensive correctness check: a non-idempotent join would mean
-- some node's rate is changing on the second pass, which can only
-- happen if the first pass missed a join somewhere.
propPropagationIdempotent :: SynthGraph -> Property
propPropagationIdempotent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> propagateRates ir === ir

-- | Propagation only touches 'irRate'. NodeID, kind, inputs,
-- controls, and effects must be byte-identical before and after.
-- A regression here would mean the lift is mutating something it
-- shouldn't — and any of those fields drifting would break
-- downstream lowering, FFI marshalling, or scheduling.
propPropagationStructural :: SynthGraph -> Property
propPropagationStructural g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let lifted = propagateRates ir
        same field name =
          counterexample ("propagation changed " <> name) $
            map field (giNodes ir) === map field (giNodes lifted)
    in conjoin
         [ same irNodeID   "irNodeID"
         , same irKind     "irKind"
         , same irInputs   "irInputs"
         , same irControls "irControls"
         , same irEffects  "irEffects"
         ]

-- | Region rate is consistent with its members'. After CompileRate
-- absorption (see Note [Region rate compatibility] in
-- MetaSonic.Bridge.Compile), member rates may differ from 'regRate':
-- a CompileRate helper folded into a SampleRate region keeps its own
-- 'irRate = CompileRate' while the region's 'regRate' stays SampleRate.
-- Two invariants together replace the old "all equal" check:
--
--   1. Every member rate is compatible with 'regRate', i.e. either
--      equal to it or 'CompileRate'.
--   2. 'regRate' is the maximum of member rates, so at least one
--      member's rate equals 'regRate' (the dominant one that drove
--      the join).
propRegionRateCompatible :: SynthGraph -> Property
propRegionRateCompatible g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg     = formRegions (giNodes ir)
        nodes  = giNodes ir
        rateOf nid = irRate <$> findNode nid nodes
        memberRates r = [ mr | nid <- regNodes r, Just mr <- [rateOf nid] ]
        compatible rr mr = mr == rr || mr == CompileRate
    in conjoin
         [ conjoin
             [ counterexample
                 (show (regID r) <> ": member " <> show nid
                    <> " has rate " <> show (rateOf nid)
                    <> " not compatible with regRate " <> show (regRate r))
                 $ property $ maybe False (compatible (regRate r)) (rateOf nid)
             | nid <- regNodes r
             ] .&&.
             counterexample
               (show (regID r) <> ": regRate " <> show (regRate r)
                  <> " is not max of member rates " <> show (memberRates r))
               (property $ regRate r == maximum (regRate r : memberRates r)
                          && regRate r `elem` memberRates r)
         | r <- rgRegions rg
         ]
  where
    findNode nid = lookup nid . map (\n -> (irNodeID n, n))

-- | Step A round-trip property: the runtime region overlay produced
-- by 'compileRuntimeGraph' starts from 'formRegions (giNodes ir)'
-- and may then be split by 'selectRegionKernels'. The final runtime
-- regions must therefore be a rate-preserving refinement of the raw
-- formRegions output, with the same per-region NodeID-to-NodeIndex
-- membership when adjacent refined regions are concatenated.
propRuntimeRegionsRoundTrip :: SynthGraph -> Property
propRuntimeRegionsRoundTrip g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let compileRegions = rgRegions (formRegions (giNodes ir))
          runtime        = rgRuntimeRegions rg
          indexMap = M.fromList
            [ (rnOriginalID n, rnIndex n) | n <- rgNodes rg ]
          translate nid = M.lookup nid indexMap
          expected =
            [ (regRate cr, mapMaybe translate (regNodes cr))
            | cr <- compileRegions
            ]
      in case checkRuntimeRegionRefinement expected runtime of
           Right () -> property True
           Left msg -> counterexample msg False

checkRuntimeRegionRefinement
  :: [(Rate, [NodeIndex])]
  -> [RuntimeRegion]
  -> Either String ()
checkRuntimeRegionRefinement [] [] = Right ()
checkRuntimeRegionRefinement [] extra =
  Left $ "unexpected extra runtime regions: " <> show (map rrIndex extra)
checkRuntimeRegionRefinement ((rate, expectedNodes) : rest) runtime =
  let (chunk, remaining) = takeRuntimeChunk (length expectedNodes) runtime
      actualNodes = concatMap rrNodes chunk
      rates = map rrRate chunk
  in if null chunk
       then Left $ "missing runtime regions for expected nodes " <> show expectedNodes
       else if actualNodes /= expectedNodes
         then Left $
           "runtime region refinement changed members: expected "
           <> show expectedNodes <> ", got " <> show actualNodes
         else if any (/= rate) rates
           then Left $
             "runtime region refinement changed rate for "
             <> show expectedNodes <> ": expected " <> show rate
             <> ", got " <> show rates
           else checkRuntimeRegionRefinement rest remaining

takeRuntimeChunk
  :: Int
  -> [RuntimeRegion]
  -> ([RuntimeRegion], [RuntimeRegion])
takeRuntimeChunk targetLen = go [] 0
  where
    go acc _ [] = (reverse acc, [])
    go acc len rest@(r : rs)
      | len >= targetLen = (reverse acc, rest)
      | otherwise =
          go (r : acc) (len + length (rrNodes r)) rs

-- | Step A structural invariant: every 'RuntimeRegion' covers a
-- contiguous run of 'NodeIndex' values, regions concatenate in order
-- to exactly @[0 .. length (rgNodes rg) - 1]@, and no node is in
-- two regions. This locks the contiguity contract the C++ side
-- relies on (RegionSpec carries first_node + node_count).
propRuntimeRegionsContiguous :: SynthGraph -> Property
propRuntimeRegionsContiguous g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let runtime    = rgRuntimeRegions rg
          unwrap (NodeIndex i) = i
          flat       = concatMap (map unwrap . rrNodes) runtime
          totalNodes = length (rgNodes rg)
          eachContiguous =
            [ counterexample (show (rrIndex r) <> ": members are not contiguous: " <> show ixs) $
                property $
                  let ixs = map unwrap (rrNodes r)
                  in not (null ixs)
                       && ixs == [head ixs .. head ixs + length ixs - 1]
            | r <- runtime
            , let ixs = map unwrap (rrNodes r)
            ]
      in conjoin
           [ counterexample "regions do not concatenate to [0 .. n-1]" $
               flat === [0 .. totalNodes - 1]
           , conjoin eachContiguous
           ]

-- | Step B-Light: 'rnOutputUse' must agree with the actual consumer /
-- region structure. Three invariants:
--
--   1. 'NoOutput' iff the node's kind is a sink ('KOut' / 'KBusOut').
--   2. 'RegionLocal' iff the node has output AND every consumer is in
--      the same region (vacuously true when there are no consumers).
--   3. 'RegionEscapes' iff the node has output AND at least one
--      consumer is in a different region.
--
-- See Note [Output-use classification] in MetaSonic.Bridge.Compile.
propOutputUseConsistent :: SynthGraph -> Property
propOutputUseConsistent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let nodeRegion = M.fromList
            [ (ix, rrIndex r)
            | r <- rgRuntimeRegions rg, ix <- rrNodes r
            ]
          consumersOf ix =
            [ rnIndex c
            | c <- rgNodes rg
            , RFrom src _ <- rnInputs c
            , src == ix
            ]
          isSink k = k == KOut || k == KBusOut
          expected n
            | isSink (rnKind n) = NoOutput
            | otherwise =
                let myReg = M.lookup (rnIndex n) nodeRegion
                    cs    = consumersOf (rnIndex n)
                    same  = all (\c -> M.lookup c nodeRegion == myReg) cs
                in if same then RegionLocal else RegionEscapes
      in conjoin
           [ counterexample
               (show (rnIndex n) <> " (" <> show (rnKind n)
                  <> "): rnOutputUse = " <> show (rnOutputUse n)
                  <> ", expected " <> show (expected n))
               (rnOutputUse n === expected n)
           | n <- rgNodes rg
           ]

-- | 'rnConsumerCount' equals the number of direct 'FromNode'
-- references to this node across 'rgNodes'. The crisp Step-C
-- single-edge fusion predicate (rnOutputUse == RegionLocal &&
-- rnConsumerCount == 1) only works if this count is honest.
propConsumerCountConsistent :: SynthGraph -> Property
propConsumerCountConsistent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let countFor ix =
            length
              [ ()
              | c <- rgNodes rg
              , RFrom src _ <- rnInputs c
              , src == ix
              ]
      in conjoin
           [ counterexample
               (show (rnIndex n) <> ": rnConsumerCount = "
                  <> show (rnConsumerCount n)
                  <> ", direct count = " <> show (countFor (rnIndex n)))
               (rnConsumerCount n === countFor (rnIndex n))
           | n <- rgNodes rg
           ]
