{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : Spec
-- Description : Structural and end-to-end tests for the MetaSonic compiler pipeline
--
-- Three layers of coverage:
--
--   * Unit tests on the demo graphs from Main, asserting that
--     validateAndSort, lowerGraph, and compileRuntimeGraph all
--     succeed and produce well-formed output, plus edge-graph
--     and dependency-extraction units.
--
--   * QuickCheck properties on randomly generated, well-formed
--     SynthGraphs, asserting compile-pass invariants
--     (dense indices, topological order, bijection between source
--     and runtime nodes, kind preservation, determinism, and
--     region-formation structure).
--
--   * Cross-cutting end-to-end tests that build a graph in
--     Haskell, push it through the full pipeline + FFI, render
--     a block via 'c_rt_graph_process', and assert on the audio
--     samples coming out of 'c_rt_graph_read_bus'. This is the
--     only layer that exercises FFI marshaling end-to-end.

module Main (main) where

import qualified Data.Map.Strict           as M
import qualified Data.Set                  as S
import           Data.List                 (isPrefixOf, nub, sort, sortBy)
import           Data.Ord                  (comparing)
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
                                            loadRuntimeGraph,
                                            withRTGraph)
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Validate
import           MetaSonic.Types

main :: IO ()
main = defaultMain $ testGroup "MetaSonic"
  [ unitTests
  , properties
  , crossCuttingTests
  ]

------------------------------------------------------------
-- Sample graphs (mirrors of the demos in app/Main.hs)
------------------------------------------------------------

simpleGraph :: SynthGraph
simpleGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  out 0 osc

chainGraph :: SynthGraph
chainGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  g   <- gain osc 0.5
  out 0 g

fanOutGraph :: SynthGraph
fanOutGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  g1  <- gain osc 0.3
  g2  <- gain osc 0.7
  out 0 g1
  out 1 g2

sawGraph :: SynthGraph
sawGraph = runSynth $ do
  osc <- sawOsc 440.0 0.0
  g   <- gain osc 0.4
  out 0 g

noiseLpfGraph :: SynthGraph
noiseLpfGraph = runSynth $ do
  n <- noiseGen
  f <- lpf n 800.0 0.7
  g <- gain f 0.4
  out 0 g

ringModGraph :: SynthGraph
ringModGraph = runSynth $ do
  carrier   <- sinOsc 440.0 0.0
  modulator <- sinOsc 7.0 0.0
  ring      <- gain carrier modulator
  amped     <- gain ring 0.3
  out 0 amped

fmGraph :: SynthGraph
fmGraph = runSynth $ do
  lfo       <- sinOsc 5.0 0.0
  deviation <- gain lfo 30.0
  freq      <- add 440.0 deviation
  carrier   <- sinOsc freq 0.0
  amped     <- gain carrier 0.3
  out 0 amped

demoGraphs :: [(String, SynthGraph)]
demoGraphs =
  [ ("simple",    simpleGraph)
  , ("chain",     chainGraph)
  , ("fanout",    fanOutGraph)
  , ("saw",       sawGraph)
  , ("noise-lpf", noiseLpfGraph)
  , ("ringmod",   ringModGraph)
  , ("fm",        fmGraph)
  ]

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

  , testGroup "dependencies (Source-level UGen → [NodeID])"
      [ testCase "all-Param UGen has no dependencies" $ do
          dependencies (SinOsc (Param 440) (Param 0)) @?= []
          dependencies (LPF (Param 0) (Param 800) (Param 0.7)) @?= []
          dependencies (Gain (Param 0) (Param 0.5)) @?= []
          dependencies (Add (Param 1) (Param 2)) @?= []
          dependencies NoiseGen @?= []
          dependencies (Out 0 (Param 0)) @?= []

      , testCase "single-Audio input contributes one dependency" $
          dependencies (Gain (Audio (NodeID 7) (PortIndex 0)) (Param 0.5))
            @?= [NodeID 7]

      , testCase "two-Audio inputs contribute both, in argument order" $
          dependencies
            (Gain (Audio (NodeID 1) (PortIndex 0))
                  (Audio (NodeID 2) (PortIndex 0)))
            @?= [NodeID 1, NodeID 2]

      , testCase "mixed Audio/Param: only Audio contributes" $
          dependencies
            (Add (Param 440)
                 (Audio (NodeID 99) (PortIndex 0)))
            @?= [NodeID 99]

      , testCase "LPF with audio sig + param controls: only sig" $
          dependencies
            (LPF (Audio (NodeID 3) (PortIndex 0))
                 (Param 800)
                 (Param 0.7))
            @?= [NodeID 3]

      , testCase "Out wraps its source dependency" $
          dependencies (Out 0 (Audio (NodeID 42) (PortIndex 0)))
            @?= [NodeID 42]
      ]

  , testCase "kindTag is injective" $
      let ks = [minBound .. maxBound :: NodeKind]
          ts = map kindTag ks
      in assertEqual
           "two NodeKinds share a kindTag — C++ dispatch will collide"
           (length ks)
           (length (nub ts))
  ]

-- | Source-level UGen → NodeKind. Used by the kind-multiset
-- preservation property.
ugenKind :: UGen -> NodeKind
ugenKind = \case
  SinOsc{}  -> KSinOsc
  SawOsc{}  -> KSawOsc
  NoiseGen  -> KNoiseGen
  LPF{}     -> KLPF
  Gain{}    -> KGain
  Add{}     -> KAdd
  Env{}     -> KEnv
  Out{}     -> KOut
  BusIn{}   -> error "ugenKind: BusIn not implemented yet"
  BusOut{}  -> error "ugenKind: BusOut not implemented yet"

-- The empty graph: no nodes at all.
emptyGraph_ :: SynthGraph
emptyGraph_ = runSynth (pure ())

-- An Out node fed by a constant — no audio source. Useful as a
-- degenerate case that should still compile (the runtime treats
-- unconnected Out as silence).
silentOutGraph :: SynthGraph
silentOutGraph = runSynth $ out 0 (Param 0)

-- Two completely independent subgraphs: SinOsc 440 → Out 0,
-- and SinOsc 660 → Out 1. No shared nodes.
disconnectedGraph :: SynthGraph
disconnectedGraph = runSynth $ do
  o1 <- sinOsc 440.0 0.0
  out 0 o1
  o2 <- sinOsc 660.0 0.0
  out 1 o2

-- A hand-built graph that references a non-existent NodeID. The DSL
-- alone cannot construct one; we use the raw Map constructor.
missingDepGraph :: SynthGraph
missingDepGraph = SynthGraph $ M.singleton (NodeID 0) NodeSpec
  { nsID   = NodeID 0
  , nsName = "out"
  , nsUgen = Out 0 (Audio (NodeID 99) (PortIndex 0))
  }

-- A hand-built graph with a 0 -> 1 -> 0 cycle.
cycleGraph :: SynthGraph
cycleGraph = SynthGraph $ M.fromList
  [ ( NodeID 0
    , NodeSpec (NodeID 0) "gain-a"
        (Gain (Audio (NodeID 1) (PortIndex 0)) (Param 0.5)) )
  , ( NodeID 1
    , NodeSpec (NodeID 1) "gain-b"
        (Gain (Audio (NodeID 0) (PortIndex 0)) (Param 0.5)) )
  ]

assertDenseIndices :: RuntimeGraph -> Assertion
assertDenseIndices rt =
  let n   = length (rgNodes rt)
      idx = [ i | RuntimeNode { rnIndex = NodeIndex i } <- rgNodes rt ]
  in idx @?= [0 .. n - 1]

assertTopoOrder :: RuntimeGraph -> Assertion
assertTopoOrder rt =
  mapM_ checkNode (rgNodes rt)
  where
    checkNode node =
      let NodeIndex here = rnIndex node
      in mapM_ (checkInput here) (rnInputs node)

    checkInput here = \case
      RFrom (NodeIndex src) _ ->
        assertBool
          ("input src=" <> show src <> " is not earlier than dst=" <> show here)
          (src < here)
      RConst _ -> pure ()

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

  , QC.testProperty "every region's rate matches its member nodes" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionRateAgreement
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

-- | Region rate matches its members'. A region with mixed rates would
-- be a broken merge in formRegions.
propRegionRateAgreement :: SynthGraph -> Property
propRegionRateAgreement g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg     = formRegions (giNodes ir)
        nodes  = giNodes ir
        rateOf nid = irRate <$> findNode nid nodes
    in conjoin
         [ counterexample (show (regID r) <> " rate disagreement") $
             property $ all (\nid -> rateOf nid == Just (regRate r)) (regNodes r)
         | r <- rgRegions rg
         ]
  where
    findNode nid = lookup nid . map (\n -> (irNodeID n, n))

------------------------------------------------------------
-- Cross-cutting end-to-end tests through the FFI
------------------------------------------------------------
--
-- Builds a SynthGraph via the Haskell DSL, runs the full pipeline
-- (lower → compile → loadRuntimeGraph), renders one block via
-- c_rt_graph_process + c_rt_graph_read_bus, and compares the
-- resulting samples to an analytical expectation. This is the
-- only test layer that exercises the entire FFI marshaling.

crossCuttingTests :: TestTree
crossCuttingTests = testGroup "End-to-end FFI"
  [ testCase "SinOsc(440) round-trips through FFI to audible sin samples" $ do
      let nframes :: Int
          nframes  = 256
          sampleRate :: Double
          sampleRate = 48000.0
          tau :: Double
          tau = 2.0 * pi

          graph = runSynth $ do
            o <- sinOsc 440.0 0.0
            out 0 o

      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          wrote <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                       (castPtr buf)
          fromIntegral wrote @?= nframes
          cs <- peekArray nframes (buf :: PtrCFloat)
          let samples = map (\(CFloat x) -> x) cs

          let peak = maximum (map abs samples)
          assertBool ("peak ≈ 1, got " <> show peak)
                     (abs (peak - 1.0) < 0.05)
          assertBool ("sample 0 ≈ 0, got " <> show (head samples))
                     (abs (head samples) < 0.02)

          mapM_ (checkAt sampleRate tau samples) [25, 50, 100, 200]

  , testCase "Gain(SinOsc, 0.5) round-trips with halved peak" $ do
      let nframes = 256
          graph = runSynth $ do
            o <- sinOsc 440.0 0.0
            g <- gain o 0.5
            out 0 g

      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          let peak = maximum (map (\(CFloat x) -> abs x) cs)
          assertBool ("expected peak ≈ 0.5, got " <> show peak)
                     (abs (peak - 0.5) < 0.05)

  , testCase "Env(gate=1, A=0.5ms, D=2ms, S=0.5, R=10ms) attacks then decays to sustain" $ do
      -- 1024 frames at 48 kHz ≈ 21 ms. With A=0.5ms + D=2ms the envelope
      -- should reach near-1 in attack and settle near 0.5 in sustain
      -- before the block ends. Gate held high via Param 1.0.
      let nframes = 1024
          graph = runSynth $ do
            e <- env (Param 1.0) (Param 0.0005) (Param 0.002) (Param 0.5) (Param 0.01)
            out 0 e

      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          let samples = map (\(CFloat x) -> x) cs
              peak    = maximum samples
              tailAvg = sum (drop 900 samples) / fromIntegral (nframes - 900)
          assertBool ("attack peak should reach near 1, got " <> show peak)
                     (peak > 0.9)
          assertBool ("sustain tail should sit near 0.5, got avg " <> show tailAvg)
                     (abs (tailAvg - 0.5) < 0.1)

  , testCase "Env(gate=0) idle stays silent" $ do
      let nframes = 256
          graph = runSynth $ do
            e <- env (Param 0.0) (Param 0.01) (Param 0.05) (Param 0.5) (Param 0.1)
            out 0 e

      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          let peak = maximum (map (\(CFloat x) -> abs x) cs)
          assertBool ("idle envelope should be silent, got peak " <> show peak)
                     (peak < 1e-6)
  ]
  where
    sizeOfFloat = 4 :: Int

    checkAt sr tau samples i = do
      let n        = fromIntegral i :: Double
          t        = n / sr
          expected = sin (tau * 440.0 * t)
          actual   = realToFrac (samples !! i) :: Double
      assertBool
        ("sample " <> show i <> " expected " <> show expected
         <> ", got " <> show actual)
        (abs (actual - expected) < 0.05)

type PtrCFloat = Ptr CFloat

------------------------------------------------------------
-- Generator: well-formed SynthGraphs
------------------------------------------------------------
--
-- Strategy: generate a list of DSL operations and replay them
-- inside SynthM. Each operation that needs a source node picks
-- an index into the list of NodeIDs allocated so far, modulo
-- the current source-list length. This guarantees referential
-- integrity by construction.
--
-- The "*Mod" variants exercise audio-rate modulation paths
-- (FM, ring-mod, audio bias, audio gate to Env) that the
-- Param-only variants never touch.

data Op
  = OSinOsc    Double Double
  | OSinOscMod Int Double      -- audio-rate freq from source-idx, phase
  | OSawOsc    Double Double
  | ONoise
  | OGain      Int Double      -- audio source-idx, constant gain
  | OGainMod   Int Int         -- audio × audio (ring-mod shape)
  | OLPF       Int Double Double -- source-index, cutoff, q
  | OAdd       Double Int      -- bias × audio source-idx
  | OAddMod    Int Int         -- audio + audio
  | OEnv       Int Double Double Double Double
                               -- gate-source-idx, A, D, S, R
  | OOut       Int Int         -- channel, source-index
  deriving (Eq, Show)

genOp :: Gen Op
genOp = oneof
  [ OSinOsc    <$> choose (50, 8000) <*> choose (0.0, 1.0)
  , OSinOscMod <$> nonNegInt         <*> choose (0.0, 1.0)
  , OSawOsc    <$> choose (50, 8000) <*> choose (0.0, 1.0)
  , pure ONoise
  , OGain    <$> nonNegInt <*> choose (0.0, 1.0)
  , OGainMod <$> nonNegInt <*> nonNegInt
  , OLPF     <$> nonNegInt <*> choose (50, 8000) <*> choose (0.1, 4.0)
  , OAdd     <$> choose (-1.0, 1.0) <*> nonNegInt
  , OAddMod  <$> nonNegInt <*> nonNegInt
  , OEnv     <$> nonNegInt
             <*> choose (0.001, 0.1) <*> choose (0.001, 0.5)
             <*> choose (0.0, 1.0)   <*> choose (0.001, 0.5)
  , OOut     <$> choose (0, 1) <*> nonNegInt
  ]
  where
    nonNegInt = choose (0, 100)

genWellFormedGraph :: Gen SynthGraph
genWellFormedGraph = sized $ \sz -> do
  -- Cap the generator at 16 ops for fast iteration; sz=100 by default
  -- but the absolute size doesn't change the invariants we're testing.
  n   <- choose (1, max 1 (min 16 sz))
  ops <- vectorOf n genOp
  pure $ runSynth (interpret (OSinOsc 440 0 : ops))

-- | Drop one leaf node at a time. A node is a 'leaf' if no other
-- node's UGen depends on it. Each shrink produces a strictly smaller
-- graph that is still well-formed (no dangling 'NodeID' references),
-- so QuickCheck reduces a failing 16-op graph to the minimal subset
-- that still triggers the failure.
shrinkSynthGraph :: SynthGraph -> [SynthGraph]
shrinkSynthGraph g =
  [ SynthGraph (M.delete nid nodes)
  | nid <- M.keys nodes
  , isLeaf nid
  ]
  where
    nodes      = sgNodes g
    allDeps    = concatMap (dependencies . nsUgen) (M.elems nodes)
    isLeaf nid = nid `notElem` allDeps

interpret :: [Op] -> SynthM ()
interpret = go []
  where
    go :: [Connection] -> [Op] -> SynthM ()
    go _ [] = pure ()

    go xs (OSinOsc f p : rest) = do
      c <- sinOsc (Param f) (Param p)
      go (xs <> [c]) rest

    go xs (OSinOscMod i p : rest)
      | null xs   = go xs rest
      | otherwise = do
          let freq = xs !! (i `mod` length xs)
          c <- sinOsc freq (Param p)
          go (xs <> [c]) rest

    go xs (OSawOsc f p : rest) = do
      c <- sawOsc (Param f) (Param p)
      go (xs <> [c]) rest

    go xs (ONoise : rest) = do
      c <- noiseGen
      go (xs <> [c]) rest

    go xs (OGain i a : rest)
      | null xs   = go xs rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- gain src (Param a)
          go (xs <> [c]) rest

    go xs (OGainMod i j : rest)
      | null xs   = go xs rest
      | otherwise = do
          let m = length xs
              s = xs !! (i `mod` m)
              a = xs !! (j `mod` m)
          c <- gain s a
          go (xs <> [c]) rest

    go xs (OLPF i f q : rest)
      | null xs   = go xs rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- lpf src (Param f) (Param q)
          go (xs <> [c]) rest

    go xs (OAdd b i : rest)
      | null xs   = go xs rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- add (Param b) src
          go (xs <> [c]) rest

    go xs (OAddMod i j : rest)
      | null xs   = go xs rest
      | otherwise = do
          let m = length xs
              a = xs !! (i `mod` m)
              b = xs !! (j `mod` m)
          c <- add a b
          go (xs <> [c]) rest

    go xs (OEnv i a d s r : rest)
      | null xs   = go xs rest
      | otherwise = do
          let gate = xs !! (i `mod` length xs)
          c <- env gate (Param a) (Param d) (Param s) (Param r)
          go (xs <> [c]) rest

    go xs (OOut ch i : rest)
      | null xs   = go xs rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          out ch src
          go xs rest
