-- | Tests for Phase 4.D rate metadata exposed on the runtime graph:
-- '§4.D.1' carries each IR node's propagated 'irRate' to the
-- corresponding 'rnRate' (and to the per-region 'rrRate'), so the
-- '--fusion-survey' rate distribution is sound; '§4.D.2' adds the
-- per-kind / per-port 'portInfo' table classifying every audio
-- input as 'PortSampleAccurate', 'PortBlockLatched', 'PortInitOnly',
-- or 'PortIgnored', and pins the headline survey aggregates
-- 'sampleRateOpportunityProducers' and 'edgeRateBuckets'.
module MetaSonic.Spec.Core.RateMetadata
  ( rateMetadataTests
  ) where

import qualified Data.Map.Strict           as M
import           Data.List                 (isInfixOf)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Types

rateMetadataTests :: TestTree
rateMetadataTests = testGroup "Phase 4.D: rate metadata"
  [ rnRateTests
  , portInfoTests
  ]

------------------------------------------------------------
-- §4.D.1: rnRate carries IR-propagated rate
------------------------------------------------------------

rnRateTests :: TestTree
rnRateTests =
  testGroup "Phase 4.D.1: rnRate carries IR-propagated rate"
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

------------------------------------------------------------
-- §4.D.2: portInfo metadata
------------------------------------------------------------

portInfoTests :: TestTree
portInfoTests =
  testGroup "Phase 4.D.2: portInfo metadata"
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
