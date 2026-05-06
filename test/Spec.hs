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

  , testGroup "Bus routing (BusIn/BusOut and E_r edges)"
      [ testCase "validateAndSort orders BusOut before BusIn on the same bus" $ do
          -- Structurally there is no edge between the BusOut and the
          -- BusIn — only the bus number connects them. The E_r edge
          -- derived from BusWrite/BusRead must force the writer first.
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                busOut 5 o
                t <- busIn 5
                out 0 t
          case validateAndSort g of
            Left err  -> assertFailure $ "validateAndSort failed: " <> err
            Right ord ->
              let nodes = sgNodes g
                  posOf nid = head [ i | (i, k) <- zip [0..] ord, k == nid ]
                  busOutPos = head
                    [ posOf nid
                    | (nid, ns) <- M.toList nodes
                    , case nsUgen ns of BusOut{} -> True; _ -> False ]
                  busInPos = head
                    [ posOf nid
                    | (nid, ns) <- M.toList nodes
                    , case nsUgen ns of BusIn{} -> True; _ -> False ]
              in assertBool
                   ("BusOut at " <> show busOutPos
                    <> " must precede BusIn at " <> show busInPos)
                   (busOutPos < busInPos)

      , testCase "validateAndSort rejects a BusOut→BusIn cycle on the same bus" $ do
          -- A node both writes and reads bus 5: BusIn 5 feeds a Gain
          -- whose output is written back via BusOut 5. Structurally
          -- this is acyclic (BusIn has no input, BusOut has one input),
          -- but the E_r edge BusOut→BusIn closes the loop.
          let g = runSynth $ do
                t <- busIn 5
                amped <- gain t 0.9
                busOut 5 amped
                out 0 t
          case validateAndSort g of
            Right _   -> assertFailure
              "expected validateAndSort to reject a same-bus E_r cycle"
            Left err  ->
              assertBool ("expected 'Cycle' in error, got: " <> err)
                         ("Cycle" `isPrefixOf` err)

      , testCase "different buses are independent (no spurious edges)" $ do
          -- BusOut 5 and BusIn 6 must not be ordered: they touch
          -- different buses. This catches a regression where busEdges
          -- ignored the bus-number guard.
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                busOut 5 o
                _ <- busIn 6  -- never written, but should still validate
                out 0 o
          case validateAndSort g of
            Left err -> assertFailure $ "validateAndSort failed: " <> err
            Right _  -> pure ()

      , testCase "busInDelayed contributes no E_r edge (busEdges ignores it)" $ do
          -- A graph with BusOut 5 and BusInDelayed 5 (no live BusIn)
          -- must produce zero E_r edges. If busEdges ever started
          -- pairing BusReadDelayed with BusWrite, feedback graphs
          -- would stop scheduling — this test pins the asymmetry.
          let g = runSynth $ do
                o   <- sinOsc 440.0 0.0
                busOut 5 o
                _   <- busInDelayed 5
                out 0 o
          busEdges g @?= []

      , testCase "feedback graph through busInDelayed topologically sorts" $ do
          -- This is the smoke test for the whole Phase 2 design: a
          -- graph whose only "cycle" closes through BusInDelayed must
          -- be accepted by the scheduler. Replacing busInDelayed with
          -- busIn would (correctly) close an E_r cycle and be
          -- rejected — see "rejects a BusOut→BusIn cycle on the same
          -- bus" above.
          let g = runSynth $ do
                tap <- busInDelayed 5
                o   <- sinOsc 220.0 0.0
                mix <- add o tap
                amp <- gain mix 0.5
                busOut 5 amp
                out 0 amp
          case validateAndSort g of
            Left err -> assertFailure $
              "feedback graph through busInDelayed should sort, got: " <> err
            Right _  -> pure ()
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
  SinOsc{}        -> KSinOsc
  SawOsc{}        -> KSawOsc
  NoiseGen        -> KNoiseGen
  LPF{}           -> KLPF
  Gain{}          -> KGain
  Add{}           -> KAdd
  Env{}           -> KEnv
  Out{}           -> KOut
  BusOut{}        -> KBusOut
  BusIn{}         -> KBusIn
  BusInDelayed{}  -> KBusInDelayed

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

  , QC.testProperty "every BusOut precedes every same-bus BusIn in the schedule" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propBusOrdering
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

  , testCase "rendering 2×N frames matches one 2N block (state continuity across blocks)" $ do
      -- Two consecutive blocks of N frames must produce the same samples
      -- as a single 2N-frame render. This pins the runtime's per-block
      -- state continuity (oscillator phase, LPF state, future bus
      -- snapshots) end-to-end. It is the precondition for any work that
      -- extends across-block semantics — Phase 2's BusInDelayed in
      -- particular — so a regression here would invalidate that work
      -- before it starts.
      --
      -- The graph mixes a SinOsc (phase state), an LPF (filter state)
      -- and a BusOut/BusIn round-trip (bus pool state). If any of
      -- those were reset at block boundaries, the two halves wouldn't
      -- splice cleanly into the single block.
      let nhalf     = 128
          nfull     = 2 * nhalf
          maxFrames = nfull
          graph     = runSynth $ do
            o      <- sinOsc 440.0 0.0
            busOut 5 o
            tap    <- busIn 5
            filt   <- lpf tap 800.0 0.7
            out 0 filt
      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      let renderN handle n = allocaBytes (n * sizeOfFloat) $ \buf -> do
            c_rt_graph_process handle (fromIntegral n)
            _  <- c_rt_graph_read_bus handle 0 (fromIntegral n) (castPtr buf)
            cs <- peekArray n (buf :: PtrCFloat)
            pure (map (\(CFloat x) -> x) cs)

      full <- withRTGraph (length (rgNodes rt)) maxFrames $ \handle -> do
        loadRuntimeGraph handle rt
        renderN handle nfull

      halves <- withRTGraph (length (rgNodes rt)) maxFrames $ \handle -> do
        loadRuntimeGraph handle rt
        h1 <- renderN handle nhalf
        h2 <- renderN handle nhalf
        pure (h1 ++ h2)

      length full @?= nfull
      length halves @?= nfull
      let maxDiff = maximum (zipWith (\a b -> abs (a - b)) full halves)
      assertBool
        ("expected bit-equivalent samples, max diff = " <> show maxDiff)
        (maxDiff < 1e-5)

  , testCase "BusOut → BusIn round-trip preserves the SinOsc signal" $ do
      -- A SinOsc writes to bus 5 via BusOut; a BusIn reads bus 5; that
      -- read is gain-attenuated and sent to hardware bus 0. We then
      -- read bus 0 and check we hear the original sine, halved.
      --
      -- This exercises:
      --   * E_r ordering: BusOut(5) must execute before BusIn(5).
      --   * Same-cycle semantics: BusIn sees the live, accumulated value.
      --   * Bus pool unification: bus 5 lives in the same pool as bus 0.
      let nframes = 256
          graph = runSynth $ do
            o      <- sinOsc 440.0 0.0
            busOut 5 o
            tap    <- busIn 5
            scaled <- gain tap 0.5
            out 0 scaled

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
          -- Original SinOsc has peak 1.0, gain 0.5 halves it. If E_r
          -- ordering broke and BusIn ran before BusOut, the bus would
          -- still be zero and the peak would be ~0.
          assertBool ("expected peak ≈ 0.5 from BusOut→BusIn round-trip, got " <> show peak)
                     (abs (peak - 0.5) < 0.05)

  , testCase "Out and BusOut writing to the same bus sum (unified pool)" $ do
      -- Pins the unified-pool model: a bus written by Out and a bus
      -- written by BusOut targeting the same bus number share the
      -- same memory and accumulate together. If the runtime ever
      -- regressed to two pools, this test would catch it.
      --
      -- SinOsc → Out 0 (peak ≈ 1) AND SinOsc' → BusOut 0 (peak ≈ 1)
      -- on the same bus number. The bus pool is unified, so the read
      -- of bus 0 should see the sum (peak ≈ 2).
      let nframes = 256
          graph = runSynth $ do
            o1 <- sinOsc 440.0 0.0
            o2 <- sinOsc 440.0 0.0
            out 0 o1
            busOut 0 o2

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
          let peak = maximum (map (\(CFloat x) -> x) cs)
          assertBool
            ("expected Out + BusOut to sum to peak ≈ 2 on shared bus 0, got "
              <> show peak)
            (peak > 1.5 && peak < 2.1)

  , testCase "two BusIn readers on the same bus see the same value (fan-out)" $ do
      -- BusIn 5 read by two consumers; both should see the live value.
      -- We feed each into a Gain (one ×0.3, one ×0.7) and route both
      -- to the hardware via separate Out channels, then check that
      -- the reads were *of the same source* by recovering their sum
      -- on bus 0 — peak should be (0.3 + 0.7) × 1 = 1.0.
      let nframes = 256
          graph = runSynth $ do
            o      <- sinOsc 440.0 0.0
            busOut 5 o
            tap1   <- busIn 5
            tap2   <- busIn 5
            g1     <- gain tap1 0.3
            g2     <- gain tap2 0.7
            out 0 g1
            out 0 g2  -- accumulates onto bus 0 with g1

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
          assertBool
            ("expected (0.3 + 0.7) × SinOsc peak ≈ 1.0, got " <> show peak)
            (abs (peak - 1.0) < 0.05)

  , testCase "BusInDelayed: one-block delay end-to-end through the FFI" $ do
      -- The Haskell-side counterpart to the C++ "BusInDelayed reads
      -- the previous block's BusOut contents" test. Renders two
      -- consecutive blocks of the same graph and asserts:
      --
      --   * On block 1, BusInDelayed reads zero (no previous block),
      --     so Out(0) is silence.
      --   * On block 2, BusInDelayed reads what BusOut wrote during
      --     block 1, so Out(0) on block 2 is bit-identical to bus 5
      --     on block 1.
      --
      -- This pins the entire Phase 2 path: the C++ swap, the
      -- BusReadDelayed effect being excluded from E_r, the schedule
      -- placing BusInDelayed wherever it falls, the FFI marshalling
      -- of KBusInDelayed, and the runtime kernel reading from
      -- output_buses_prev.
      let nframes = 128
          maxFrames = nframes
          graph = runSynth $ do
            o   <- sinOsc 440.0 0.0
            busOut 5 o
            tap <- busInDelayed 5
            out 0 tap
      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      let readBus handle bus n = allocaBytes (n * sizeOfFloat) $ \buf -> do
            _  <- c_rt_graph_read_bus handle (fromIntegral bus)
                                      (fromIntegral n) (castPtr buf)
            cs <- peekArray n (buf :: PtrCFloat)
            pure (map (\(CFloat x) -> x) cs)

      withRTGraph (length (rgNodes rt)) maxFrames $ \handle -> do
        loadRuntimeGraph handle rt

        -- Block 1.
        c_rt_graph_process handle (fromIntegral nframes)
        block1Out  <- readBus handle 0 nframes
        block1Bus5 <- readBus handle 5 nframes

        let peak1 = maximum (map abs block1Out)
        assertBool
          ("block 1 should be silence (snapshot is zero), got peak " <> show peak1)
          (peak1 < 1e-5)
        let peakBus5 = maximum (map abs block1Bus5)
        assertBool
          ("block 1's BusOut should still write a real sine to bus 5, got peak "
            <> show peakBus5)
          (peakBus5 > 0.9)

        -- Block 2.
        c_rt_graph_process handle (fromIntegral nframes)
        block2Out <- readBus handle 0 nframes

        let maxDiff = maximum (zipWith (\a b -> abs (a - b)) block1Bus5 block2Out)
        assertBool
          ("block 2's BusInDelayed must reproduce block 1's bus 5; max diff = "
            <> show maxDiff)
          (maxDiff < 1e-5)

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
  | OBusOut         Int Int    -- bus, audio source-index
  | OBusIn          Int        -- bus
  | OBusInDelayed   Int        -- bus (feedback-safe reader)
  | OOut            Int Int    -- channel, source-index
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
  , OBusOut       <$> choose (0, 3) <*> nonNegInt
  , OBusIn        <$> choose (0, 3)
  , OBusInDelayed <$> choose (0, 3)
  , OOut          <$> choose (0, 1) <*> nonNegInt
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

{- Note [Generator avoids E_r cycles]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'OBusOut' / 'OBusIn' Ops can interact through bus numbers, so the
generator could in principle build a graph where 'BusIn n' is
structurally upstream of a later 'BusOut n', closing a cycle through the
E_r edge that the scheduler adds. 'validateAndSort' would then reject
the graph and 'propValidates' would fail — *not* a real bug, just
generator noise.

The interpreter avoids this by tracking the set of bus numbers already
"poisoned" by a 'BusIn' op. A later 'OBusOut n' on a poisoned bus is
silently skipped. With this discipline, no generated graph contains an
E_r cycle by construction, so all existing properties extend cleanly to
graphs with bus routing.

'OBusInDelayed' is *deliberately* not in this poisoning set. A
'BusInDelayed n' carries 'BusReadDelayed n' rather than 'BusRead n',
which the scheduler ignores when deriving E_r — so a downstream
'OBusOut n' on the same bus closes a feedback path that crosses the
block boundary, not a within-block cycle. The generator is therefore
free to emit feedback patterns ('OBusInDelayed bus' followed by
'OBusOut bus') and 'propValidates' must accept them. This is the QC
counterpart of the dedicated unit test "feedback graph through
busInDelayed topologically sorts".
-}

interpret :: [Op] -> SynthM ()
interpret = go [] S.empty
  where
    go :: [Connection] -> S.Set Int -> [Op] -> SynthM ()
    go _ _ [] = pure ()

    go xs r (OSinOsc f p : rest) = do
      c <- sinOsc (Param f) (Param p)
      go (xs <> [c]) r rest

    go xs r (OSinOscMod i p : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let freq = xs !! (i `mod` length xs)
          c <- sinOsc freq (Param p)
          go (xs <> [c]) r rest

    go xs r (OSawOsc f p : rest) = do
      c <- sawOsc (Param f) (Param p)
      go (xs <> [c]) r rest

    go xs r (ONoise : rest) = do
      c <- noiseGen
      go (xs <> [c]) r rest

    go xs r (OGain i a : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- gain src (Param a)
          go (xs <> [c]) r rest

    go xs r (OGainMod i j : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let m = length xs
              s = xs !! (i `mod` m)
              a = xs !! (j `mod` m)
          c <- gain s a
          go (xs <> [c]) r rest

    go xs r (OLPF i f q : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- lpf src (Param f) (Param q)
          go (xs <> [c]) r rest

    go xs r (OAdd b i : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- add (Param b) src
          go (xs <> [c]) r rest

    go xs r (OAddMod i j : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let m = length xs
              a = xs !! (i `mod` m)
              b = xs !! (j `mod` m)
          c <- add a b
          go (xs <> [c]) r rest

    go xs r (OEnv i ea ed es er : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let gate = xs !! (i `mod` length xs)
          c <- env gate (Param ea) (Param ed) (Param es) (Param er)
          go (xs <> [c]) r rest

    go xs r (OBusOut bus i : rest)
      | null xs            = go xs r rest
      | bus `S.member` r   = go xs r rest  -- skip to avoid an E_r cycle
      | otherwise          = do
          let src = xs !! (i `mod` length xs)
          busOut bus src
          go xs r rest

    go xs r (OBusIn bus : rest) = do
      c <- busIn bus
      go (xs <> [c]) (S.insert bus r) rest

    -- Feedback-safe reader: contributes no E_r edge, so no bus
    -- needs to be poisoned. A later 'OBusOut bus' on the same
    -- bus is allowed and closes a (cross-block) feedback path
    -- that the scheduler accepts. See Note [Generator avoids E_r
    -- cycles] for why this is the deliberate distinction.
    go xs r (OBusInDelayed bus : rest) = do
      c <- busInDelayed bus
      go (xs <> [c]) r rest

    go xs r (OOut ch i : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          out ch src
          go xs r rest
