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

  , -- Phase 4.E.1 + 4.E.1b: per-region BusFootprint metadata plus
    -- the dependency views consumed by future scheduling work.
    -- 'regionBusPrecedence' is the bus-only edge subgraph;
    -- 'regionStructuralPrecedence' is the cross-region port edges
    -- introduced by 'selectRegionKernels' splits;
    -- 'regionDependencies' is the union — the actual "must
    -- precede" relation. No runtime behavior change in either
    -- slice — 'compileRuntimeGraph' still produces regions in the
    -- same topologically valid order; the tests pin the metadata
    -- only. See Note [Region dependency contract] in
    -- 'MetaSonic.Bridge.Compile' for why both edge classes
    -- matter.
    testGroup "Phase 4.E.1: per-region BusFootprint and dependencies"
      [ -- Single-region baseline: a sin → gain → out chain claims
        -- 'RSinGainOut' as one region. Footprint writes only the
        -- sink bus; no reads of any kind. Both views are empty
        -- for this region (no other region exists, no port edges
        -- to cross, no read sets to intersect against).
        testCase "single-region chain: footprint writes {0}, no reads, empty deps" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              case rgRuntimeRegions rg of
                [r] -> do
                  bfWrites       (rfBuses (rrFootprint r)) @?= S.singleton 0
                  bfReads        (rfBuses (rrFootprint r)) @?= S.empty
                  bfDelayedReads (rfBuses (rrFootprint r)) @?= S.empty
                  regionDependencies rg @?=
                    M.singleton (rrIndex r) S.empty
                rs -> assertFailure $
                  "expected exactly one region, got " <> show (length rs)

      , -- Internal send/return: a sin → busOut 5 producer chain
        -- followed by a busIn 5 → lpf → gain → out 0 consumer
        -- chain. §4.B's longest-match priority claims the consumer
        -- chain as 'RBusInLpfGainOut' and 'selectRegionKernels'
        -- splits the source region into a producer 'RNodeLoop'
        -- region (sin + busOut) and a consumer kernel region.
        --
        -- The footprints must reflect the split: producer writes
        -- bus 5; consumer reads bus 5 and writes bus 0. The
        -- consumer's dependency on the producer is /bus-borne/
        -- here — there's no port edge crossing the region
        -- boundary (the consumer's first node is BusIn, which has
        -- no audio inputs). 'regionBusPrecedence' must capture
        -- the edge; 'regionDependencies' must agree.
        testCase "internal send/return: consumer region depends on producer (bus edge)" $ do
          let g = runSynth $ do
                s <- sinOsc 220.0 0.0
                busOut 5 s
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              -- Identify the two regions by their kernel tags:
              -- producer is RNodeLoop (sin + busOut not a §4.B
              -- shape), consumer is RBusInLpfGainOut.
              let producers = [r | r <- rgRuntimeRegions rg
                                 , rrKernel r == RNodeLoop]
                  consumers = [r | r <- rgRuntimeRegions rg
                                 , rrKernel r == RBusInLpfGainOut]
              case (producers, consumers) of
                ([p], [c]) -> do
                  bfWrites       (rfBuses (rrFootprint p)) @?= S.singleton 5
                  bfReads        (rfBuses (rrFootprint p)) @?= S.empty
                  bfWrites       (rfBuses (rrFootprint c)) @?= S.singleton 0
                  bfReads        (rfBuses (rrFootprint c)) @?= S.singleton 5
                  bfDelayedReads (rfBuses (rrFootprint c)) @?= S.empty

                  let busPrec = regionBusPrecedence rg
                      structPrec = regionStructuralPrecedence rg
                      deps = regionDependencies rg
                  -- Bus edge present.
                  M.findWithDefault S.empty (rrIndex c) busPrec
                    @?= S.singleton (rrIndex p)
                  -- BusIn has no audio inputs, so no port edge
                  -- crosses from producer to consumer.
                  M.findWithDefault S.empty (rrIndex c) structPrec
                    @?= S.empty
                  -- Union (the headline view) carries the bus edge.
                  M.findWithDefault S.empty (rrIndex c) deps
                    @?= S.singleton (rrIndex p)
                  M.findWithDefault S.empty (rrIndex p) deps
                    @?= S.empty
                _ -> assertFailure $
                  "expected one RNodeLoop producer + one RBusInLpfGainOut "
                  <> "consumer, got "
                  <> show (length producers) <> " + "
                  <> show (length consumers)

      , -- §4.E.1b regression: kernel-split structural edges.
        -- @saw → lpf → gain → add → out@ is the canonical case
        -- 'regionBusPrecedence' alone would miss. 'RSawLpfGain'
        -- (buffer-terminal) claims @[Saw, LPF, Gain]@; the
        -- trailing @[Add, Out]@ stays 'RNodeLoop'. The trailing
        -- region reads the materialized gain output through a
        -- port edge (Add's signal input is RFrom Gain). No bus
        -- is involved, so 'regionBusPrecedence' is empty — but
        -- the trailing region absolutely cannot run before
        -- 'RSawLpfGain', and a parallel scheduler that consumed
        -- only the bus view would happily race them.
        --
        -- This is the load-bearing pin for
        -- 'regionStructuralPrecedence' / 'regionDependencies'.
        -- See Note [Region dependency contract].
        testCase "kernel-split chain: structural port edge across region boundary" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)        -- non-sink consumer of Gain;
                                              -- blocks RSawLpfGainOut
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions = rgRuntimeRegions rg
                  bufs    = [r | r <- regions, rrKernel r == RSawLpfGain]
                  tails   = [r | r <- regions, rrKernel r == RNodeLoop]
              case (bufs, tails) of
                ([buf], [tail_]) -> do
                  -- Footprints: producer writes nothing (gain
                  -- materializes a buffer, not a bus); consumer
                  -- writes bus 0 via Out, reads no bus.
                  bfWrites       (rfBuses (rrFootprint buf))   @?= S.empty
                  bfReads        (rfBuses (rrFootprint buf))   @?= S.empty
                  bfWrites       (rfBuses (rrFootprint tail_)) @?= S.singleton 0
                  bfReads        (rfBuses (rrFootprint tail_)) @?= S.empty

                  -- Bus view alone misses the dependency (no bus
                  -- writes / reads intersect).
                  let busPrec = regionBusPrecedence rg
                  M.findWithDefault S.empty (rrIndex tail_) busPrec
                    @?= S.empty

                  -- Structural view catches it: Add (in tail
                  -- region) has RFrom pointing into the buffer
                  -- region.
                  let structPrec = regionStructuralPrecedence rg
                  M.findWithDefault S.empty (rrIndex tail_) structPrec
                    @?= S.singleton (rrIndex buf)

                  -- Headline: the union carries the structural
                  -- edge. Anyone consulting 'regionDependencies'
                  -- sees the dependency that 'regionBusPrecedence'
                  -- alone would miss.
                  let deps = regionDependencies rg
                  M.findWithDefault S.empty (rrIndex tail_) deps
                    @?= S.singleton (rrIndex buf)
                  M.findWithDefault S.empty (rrIndex buf) deps
                    @?= S.empty
                _ -> assertFailure $
                  "expected one RSawLpfGain region + one RNodeLoop tail, got "
                  <> show (length bufs) <> " + " <> show (length tails)

      , -- BusInDelayed must NOT induce precedence. The graph has
        -- a producer chain that writes bus 5 (claimed as
        -- 'RSinGainOut' via BusOut) and a delayed-reader chain
        -- (busInDelayed 5 → gain → out) that reads bus 5
        -- /delayed/ rather than live. The producer region's
        -- footprint has writes={5}; the reader region's footprint
        -- has delayedReads={5} and writes={0}. Both
        -- 'regionBusPrecedence' (delayed reads excluded by rule)
        -- and 'regionStructuralPrecedence' (BusInDelayed has no
        -- audio inputs, so no port edge) report no edge — and
        -- therefore 'regionDependencies' must be empty.
        testCase "BusInDelayed reader does not induce a dependency edge" $ do
          let g = runSynth $ do
                s1 <- sinOsc 220.0 0.0
                g1 <- gain s1 (Param 0.3)
                busOut 5 g1                        -- producer: §4.B claims RSinGainOut via BusOut
                d  <- busInDelayed 5
                g2 <- gain d (Param 0.4)
                out 0 g2                           -- reader: 3-node, no §4.B kernel for KBusInDelayed
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions   = rgRuntimeRegions rg
                  producers = [r | r <- regions, rrKernel r == RSinGainOut]
                  readers   = [r | r <- regions, rrKernel r == RNodeLoop]
              case (producers, readers) of
                ([p], [r]) -> do
                  bfWrites       (rfBuses (rrFootprint p)) @?= S.singleton 5
                  bfReads        (rfBuses (rrFootprint p)) @?= S.empty
                  bfDelayedReads (rfBuses (rrFootprint p)) @?= S.empty

                  bfWrites       (rfBuses (rrFootprint r)) @?= S.singleton 0
                  bfReads        (rfBuses (rrFootprint r)) @?= S.empty
                  bfDelayedReads (rfBuses (rrFootprint r)) @?= S.singleton 5

                  -- Headline assertion: no edge in any view.
                  let busPrec    = regionBusPrecedence rg
                      structPrec = regionStructuralPrecedence rg
                      deps       = regionDependencies rg
                  M.findWithDefault S.empty (rrIndex r) busPrec    @?= S.empty
                  M.findWithDefault S.empty (rrIndex r) structPrec @?= S.empty
                  M.findWithDefault S.empty (rrIndex r) deps       @?= S.empty
                  M.findWithDefault S.empty (rrIndex p) deps       @?= S.empty
                _ -> assertFailure $
                  "expected one RSinGainOut producer + one RNodeLoop "
                  <> "reader, got "
                  <> show (length producers) <> " + "
                  <> show (length readers)

      , -- Independent regions must have disjoint footprints and no
        -- precedence edges between them. Two parallel sin → gain
        -- → out chains writing different sink buses both claim
        -- 'RSinGainOut' but neither reads any bus and neither
        -- consumes the other's output — so every dependency view
        -- is empty everywhere.
        testCase "independent regions have disjoint footprints + no deps" $ do
          let g = runSynth $ do
                s1 <- sinOsc 220.0 0.0
                a1 <- gain s1 (Param 0.4)
                out 0 a1
                s2 <- sinOsc 440.0 0.0
                a2 <- gain s2 (Param 0.4)
                out 1 a2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions = rgRuntimeRegions rg
              length [r | r <- regions, rrKernel r == RSinGainOut] @?= 2
              -- Each kernel region writes exactly one bus; the
              -- two written buses are disjoint.
              let writes = [bfWrites (rfBuses (rrFootprint r)) | r <- regions]
              S.unions writes @?= S.fromList [0, 1]
              -- Every dependency view is empty for every region.
              let deps = regionDependencies rg
              all (S.null . snd) (M.toList deps) @?= True

      , -- Multi-template send/return: each template compiles to
        -- its own RuntimeGraph through 'compileTemplateGraph',
        -- and the per-region BusFootprint must be populated
        -- through that pipeline (not just through the
        -- single-graph 'compileRuntimeGraph' direct path).
        --
        -- The voice template's region claims RSinGainOut via
        -- BusOut and writes bus 5; the fx template's region
        -- claims RBusInLpfGainOut and reads bus 5 / writes bus 0.
        -- Intra-template dependencies are empty within each
        -- (single-region per template; cross-template ordering is
        -- handled by 'compileTemplateGraph', not by the
        -- per-region view).
        testCase "multi-template send/return: per-region footprints survive compileTemplateGraph" $ do
          let voice = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                busOut 5 a
              fx = runSynth $ do
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.6)
                out 0 a

          tg <- case compileTemplateGraph
                       [("voice", voice), ("fx", fx)] of
            Right t  -> pure t
            Left err -> assertFailure err >> error "unreachable"

          let voiceTpl = head [t | t <- tgTemplates tg, tplName t == "voice"]
              fxTpl    = head [t | t <- tgTemplates tg, tplName t == "fx"]
              voiceRg  = tplGraph voiceTpl
              fxRg     = tplGraph fxTpl

          -- Voice side: one region claiming RSinGainOut, footprint
          -- writes bus 5.
          case rgRuntimeRegions voiceRg of
            [r] -> do
              rrKernel r @?= RSinGainOut
              bfWrites (rfBuses (rrFootprint r)) @?= S.singleton 5
              bfReads  (rfBuses (rrFootprint r)) @?= S.empty
              regionDependencies voiceRg
                @?= M.singleton (rrIndex r) S.empty
            rs -> assertFailure $
              "voice template: expected one region, got "
              <> show (length rs)

          -- Fx side: one region claiming RBusInLpfGainOut,
          -- footprint reads bus 5 and writes bus 0.
          case rgRuntimeRegions fxRg of
            [r] -> do
              rrKernel r @?= RBusInLpfGainOut
              bfWrites (rfBuses (rrFootprint r)) @?= S.singleton 0
              bfReads  (rfBuses (rrFootprint r)) @?= S.singleton 5
              regionDependencies fxRg
                @?= M.singleton (rrIndex r) S.empty
            rs -> assertFailure $
              "fx template: expected one region, got "
              <> show (length rs)

      , -- §4.E.1c barrier predicate at the NodeKind level. The
        -- three live-bus kinds (KBusIn / KOut / KBusOut) each
        -- carry a runtime-redirectable bus index in
        -- 'rnControls[0]', so any region containing them is a
        -- scheduler barrier. KBusInDelayed is excluded — its
        -- read is from the previous block's snapshot, which is
        -- deterministic regardless of intra-block scheduling
        -- order.
        --
        -- This pins the kind-level contract directly so the
        -- graph-level tests below can rely on it for shape-
        -- specific cases without re-arguing the policy.
        testCase "isLiveBusKind: exhaustively {KBusIn, KOut, KBusOut}; everything else no" $ do
          -- Enumerate every 'NodeKind' so the assertion proves the
          -- exact membership of the live-bus set, not just spot-
          -- checks. A new kind added to 'Types.hs' that is
          -- accidentally classified as live-bus (or accidentally
          -- excluded from it) fails this test the next time the
          -- suite runs.
          --
          -- 'NodeKind' has no 'Ord', so the comparison is on lists
          -- in declaration ('Enum') order rather than sets.
          let live = [k | k <- [minBound .. maxBound :: NodeKind]
                        , isLiveBusKind k]
          -- Expected list is also in declaration order, which
          -- happens to match the enum: KOut < KBusOut < KBusIn.
          live @?= [KOut, KBusOut, KBusIn]

      , -- A simple sin → gain → out chain has KOut in its
        -- single region, so 'regionHasLiveBus' must say True —
        -- the region is a barrier. (Effectively every chain
        -- ending in Out / BusOut is a barrier under the policy.)
        testCase "regionHasLiveBus: chain with KOut is a barrier" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              case rgRuntimeRegions rg of
                [r] -> regionHasLiveBus rg r @?= True
                rs -> assertFailure $
                  "expected exactly one region, got " <> show (length rs)

      , -- §4.E.1c × kernel-split: in the canonical
        -- @saw → lpf → gain → add → out@ split, the
        -- 'RSawLpfGain' buffer region has /no/ live-bus node and
        -- is therefore /not/ a barrier — its dependency is
        -- structural (the trailing region reads its gain output
        -- via a port edge, see the §4.E.1b test above), but the
        -- region itself can in principle be moved by a
        -- non-barrier-aware scheduler so long as it precedes the
        -- consumer. The trailing 'RNodeLoop' region carrying
        -- @[Add, Out]@ /is/ a barrier (via KOut) and stays in
        -- compile-decreed order regardless of dependency
        -- analysis.
        --
        -- Pins the discrimination: barrier-ness tracks live-bus
        -- membership only, not dependency-graph reach.
        testCase "regionHasLiveBus: kernel-split — buffer region not a barrier, sink region is" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions = rgRuntimeRegions rg
                  bufs    = [r | r <- regions, rrKernel r == RSawLpfGain]
                  tails   = [r | r <- regions, rrKernel r == RNodeLoop]
              case (bufs, tails) of
                ([buf], [tail_]) -> do
                  regionHasLiveBus rg buf   @?= False
                  regionHasLiveBus rg tail_ @?= True
                _ -> assertFailure $
                  "expected one RSawLpfGain region + one RNodeLoop "
                  <> "tail, got " <> show (length bufs)
                  <> " + " <> show (length tails)

      , -- Internal send/return: both regions contain live-bus
        -- nodes (producer has KBusOut, consumer has KBusIn and
        -- KOut), so both are barriers. The dependency between
        -- them ('regionBusPrecedence' edge) is incidental for the
        -- barrier predicate — barrier-ness is per-region,
        -- independent of whether there's an inter-region edge.
        testCase "regionHasLiveBus: send/return — both regions are barriers" $ do
          let g = runSynth $ do
                s <- sinOsc 220.0 0.0
                busOut 5 s
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions = rgRuntimeRegions rg
              all (regionHasLiveBus rg) regions @?= True
      ]

  , -- Phase 4.E.2a: pure single-thread region scheduler planner.
    -- 'regionSchedule' encodes the contract a future scheduler
    -- consumes — barrier regions (live-bus) execute in
    -- compile-decreed 'rrIndex' order; non-barrier regions are
    -- topologically scheduled within each barrier-delimited
    -- segment using 'regionDependencies' with 'rrIndex' as the
    -- stable tie-breaker. No runtime change in this slice.
    --
    -- Today's 'compileRuntimeGraph' produces a topologically
    -- valid 'rrIndex' sequence, so 'regionSchedule' returns
    -- 'rrIndex' order verbatim. The tests pin /that property/
    -- across the relevant graph shapes, so a future change that
    -- accidentally introduces a real reorder is caught here
    -- before §4.E.2b lands and starts depending on the contract
    -- for actual concurrency.
    testGroup "Phase 4.E.2a: regionSchedule planner"
      [ -- Single-region baseline: only one region, schedule must
        -- be its singleton index.
        testCase "single-region chain: schedule is [0]" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> regionSchedule rg @?= Right [RegionIndex 0]

      , -- Internal send/return: producer (KBusOut) and consumer
        -- (RBusInLpfGainOut, contains KBusIn + KOut) are both
        -- barriers, anchored at their compile-decreed positions.
        -- Schedule equals 'rrIndex' order; segmentByBarrier sees
        -- two singleton barrier slots and no free segment.
        testCase "send/return barriers: both regions barriers, schedule = rrIndex order" $ do
          let g = runSynth $ do
                s <- sinOsc 220.0 0.0
                busOut 5 s
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions  = rgRuntimeRegions rg
                  segments = segmentByBarrier rg
              -- Both regions are barriers under §4.E.1c.
              all (regionHasLiveBus rg) regions @?= True
              length segments @?= 2
              -- Both segments are 'Barrier' (no free runs between
              -- them). Pattern match inline rather than using a
              -- helper to keep the assertion self-explanatory.
              let isBarrier seg = case seg of
                    Barrier _ -> True
                    _         -> False
              all isBarrier segments @?= True
              regionSchedule rg @?= Right (map rrIndex regions)

      , -- Kernel-split structural-edge case: 'RSawLpfGain'
        -- buffer region (no live-bus, free) precedes the
        -- trailing 'RNodeLoop' tail (KOut, barrier). The
        -- structural cross-region edge (Add reads Gain across
        -- the region boundary) is part of 'regionDependencies',
        -- but the planner doesn't need to reorder anything —
        -- 'rrIndex' order is already topologically valid.
        --
        -- Pins: a free region preceding a barrier ends up in a
        -- one-element free segment, then the barrier. The barrier
        -- doesn't get folded into the free segment.
        testCase "kernel-split: free buffer region precedes barrier tail" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions = rgRuntimeRegions rg
                  bufs    = [r | r <- regions, rrKernel r == RSawLpfGain]
                  tails   = [r | r <- regions, rrKernel r == RNodeLoop]
              case (bufs, tails) of
                ([buf], [tail_]) -> do
                  -- Free region is not a barrier, tail is.
                  regionHasLiveBus rg buf   @?= False
                  regionHasLiveBus rg tail_ @?= True
                  -- segmentByBarrier emits free segment, then
                  -- barrier — same number of slices as regions
                  -- since the free segment carries one region.
                  segmentByBarrier rg @?= [ FreeSegment [buf]
                                          , Barrier tail_
                                          ]
                  -- Schedule equals rrIndex order.
                  regionSchedule rg @?= Right [rrIndex buf, rrIndex tail_]
                _ -> assertFailure $
                  "expected one RSawLpfGain region + one RNodeLoop "
                  <> "tail, got " <> show (length bufs)
                  <> " + " <> show (length tails)

      , -- BusInDelayed reader: the delayed read does not
        -- contribute to 'regionDependencies' (and so doesn't
        -- create a precedence edge between producer and reader).
        -- Both regions in this graph contain live-bus nodes
        -- (producer has KBusOut; reader has KOut), so both are
        -- barriers and the schedule is 'rrIndex' order. Pins
        -- that delayed-only readers don't somehow short-circuit
        -- the barrier classification.
        testCase "BusInDelayed: schedule is rrIndex order, both barriers" $ do
          let g = runSynth $ do
                s1 <- sinOsc 220.0 0.0
                g1 <- gain s1 (Param 0.3)
                busOut 5 g1
                d  <- busInDelayed 5
                g2 <- gain d (Param 0.4)
                out 0 g2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions = rgRuntimeRegions rg
              all (regionHasLiveBus rg) regions @?= True
              regionSchedule rg @?= Right (map rrIndex regions)

      , -- Independent non-barrier reordering: a graph with /two/
        -- 'RSawLpfGain' free regions adjacent in 'rrIndex' order,
        -- both feeding the same trailing 'RNodeLoop' barrier
        -- (Add + Out). The free regions land in a single free
        -- segment; the planner topologically sorts them with
        -- stable 'rrIndex' tie-breaking. Since the two free
        -- regions are independent (neither depends on the
        -- other), the stable rrIndex order is the natural
        -- output.
        --
        -- This is the headline test for stable-rrIndex
        -- reordering: the segment has more than one non-barrier
        -- region, the topo-sort actually has a choice, and the
        -- choice is the rrIndex order.
        testCase "independent free regions: stable rrIndex order in single segment" $ do
          let g = runSynth $ do
                s1 <- sawOsc 110.0 0.0
                f1 <- lpf s1 (Param 800.0)  (Param 4.0)
                g1 <- gain f1 (Param 0.4)
                s2 <- sawOsc 220.0 0.0
                f2 <- lpf s2 (Param 1200.0) (Param 4.0)
                g2 <- gain f2 (Param 0.4)
                summed <- add g1 g2
                out 0 summed
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions = rgRuntimeRegions rg
                  buffers = [r | r <- regions, rrKernel r == RSawLpfGain]
                  tails   = [r | r <- regions, rrKernel r == RNodeLoop]
              case (buffers, tails) of
                ([b1, b2], [tail_]) -> do
                  -- Both buffer regions are free; the tail is a
                  -- barrier (KOut).
                  regionHasLiveBus rg b1    @?= False
                  regionHasLiveBus rg b2    @?= False
                  regionHasLiveBus rg tail_ @?= True
                  -- The free segment groups both buffer regions;
                  -- the barrier follows.
                  segmentByBarrier rg
                    @?= [ FreeSegment [b1, b2], Barrier tail_ ]
                  -- Schedule emits both free regions in rrIndex
                  -- order, then the barrier.
                  regionSchedule rg
                    @?= Right [ rrIndex b1, rrIndex b2, rrIndex tail_ ]
                _ -> assertFailure $
                  "expected two RSawLpfGain regions + one RNodeLoop "
                  <> "tail, got "
                  <> show (length buffers) <> " + "
                  <> show (length tails)

      , -- Multi-template send/return: each template's 'RuntimeGraph'
        -- carries its own one-region schedule. The voice template
        -- is a barrier (RSinGainOut via BusOut), the fx template is
        -- a barrier (RBusInLpfGainOut). Pins that the planner runs
        -- correctly through 'compileTemplateGraph' as well as the
        -- single-graph 'compileRuntimeGraph' direct path.
        testCase "multi-template: per-template schedule = [0] for each one-region template" $ do
          let voice = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                busOut 5 a
              fx = runSynth $ do
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.6)
                out 0 a

          tg <- case compileTemplateGraph
                       [("voice", voice), ("fx", fx)] of
            Right t  -> pure t
            Left err -> assertFailure err >> error "unreachable"

          let voiceTpl = head [t | t <- tgTemplates tg, tplName t == "voice"]
              fxTpl    = head [t | t <- tgTemplates tg, tplName t == "fx"]

          regionSchedule (tplGraph voiceTpl) @?= Right [RegionIndex 0]
          regionSchedule (tplGraph fxTpl)    @?= Right [RegionIndex 0]

      , -- Fail-loud planner, list-order contract:
        -- 'rgRuntimeRegions' must be dense ascending by 'rrIndex'
        -- from 0. 'segmentByBarrier' walks the list in /list/
        -- order and 'topoSortStable' uses list order as the
        -- stable tie-breaker, so the documented "barriers stay in
        -- rrIndex order, free regions tie-break by rrIndex"
        -- contract only holds when the list /is/ rrIndex order.
        --
        -- Reversing the kernel-split region list produces a
        -- non-ascending sequence; the planner must reject it
        -- before scheduling.
        testCase "rejects non-ascending rgRuntimeRegions order" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let bad = rg { rgRuntimeRegions =
                               reverse (rgRuntimeRegions rg) }
              case regionSchedule bad of
                Left msg ->
                  assertBool
                    ("expected mention of dense ascending in: "
                     <> msg)
                    ("dense" `isInfixOf` msg)
                Right ixs ->
                  assertFailure $
                    "regionSchedule should have rejected the "
                    <> "reversed graph; got " <> show ixs

      , -- Fail-loud planner, duplicate-index variant: hand-build
        -- a 'rgRuntimeRegions' with the same 'rrIndex' twice.
        -- This exercises the dense-ascending check on a malformed
        -- list that's not just a reversal — duplicates and gaps
        -- should also be rejected.
        testCase "rejects duplicate rrIndex in rgRuntimeRegions" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> case rgRuntimeRegions rg of
              [r] -> do
                let bad = rg { rgRuntimeRegions = [r, r] }
                case regionSchedule bad of
                  Left msg ->
                    assertBool
                      ("expected dense-ascending diagnostic in: "
                       <> msg)
                      ("dense" `isInfixOf` msg)
                  Right ixs ->
                    assertFailure $
                      "regionSchedule should have rejected the "
                      <> "duplicate-index graph; got " <> show ixs
              rs -> assertFailure $
                "expected a single region, got "
                <> show (length rs)
      ]

  , -- Phase 4.E.2b: loaders register regions through the schedule.
    --
    -- These tests pin the loader-side contract — the four loaders
    -- ('loadRuntimeGraph', 'loadRuntimeGraphFused', 'loadTemplateGraph',
    -- 'loadTemplateGraphFused') each register regions on the C++
    -- side via 'scheduledRuntimeRegions', not the raw 'rgRuntimeRegions'
    -- list. Today the planner is the identity over 'rrIndex' order on
    -- well-formed compile output, so the two are equal: equality here
    -- /is/ the bit-equivalence claim. A future change that breaks
    -- the planner identity (or the dense-ascending invariant) is
    -- caught by 'regionSchedule' before any C++ mutation, not by
    -- silent reorder at the runtime.
    --
    -- We don't compare against rendered audio because the existing
    -- render-equivalence suite (loadTemplateGraph: cross-template
    -- send/return, BusOut/BusIn round-trip, etc.) already covers
    -- end-to-end equivalence; these tests pin the precise loader
    -- contract.
    testGroup "Phase 4.E.2b: loaders consume scheduledRuntimeRegions"
      [ -- Single-template, unfused: same input as 'loadRuntimeGraph'
        -- exercises end-to-end. Confirm scheduled order matches
        -- rgRuntimeRegions order (planner identity property).
        testCase "loadRuntimeGraph: scheduled order = rgRuntimeRegions" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> case scheduledRuntimeRegions rg of
              Left err -> assertFailure $
                "scheduledRuntimeRegions failed: " <> err
              Right scheduled ->
                map rrIndex scheduled @?= map rrIndex (rgRuntimeRegions rg)

      , -- Single-template, fused: same input shape as the canonical
        -- fused-render tests; confirm scheduled order matches.
        testCase "loadRuntimeGraphFused: scheduled order = rgRuntimeRegions" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                b <- add a (Param 0.0)
                out 0 b
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> case scheduledRuntimeRegions rg of
              Left err -> assertFailure $
                "scheduledRuntimeRegions failed: " <> err
              Right scheduled ->
                map rrIndex scheduled @?= map rrIndex (rgRuntimeRegions rg)

      , -- Multi-template, unfused: per-template schedule equals
        -- per-template rgRuntimeRegions order.
        testCase "loadTemplateGraph: per-template scheduled order = rgRuntimeRegions" $ do
          let voice = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                busOut 5 a
              fx = runSynth $ do
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.6)
                out 0 a
          case compileTemplateGraph [("voice", voice), ("fx", fx)] of
            Left err -> assertFailure err
            Right tg ->
              -- For every template, scheduled order matches raw.
              mapM_ (\tpl ->
                case scheduledRuntimeRegions (tplGraph tpl) of
                  Left err -> assertFailure $
                    "template " <> show (tplName tpl)
                    <> ": scheduledRuntimeRegions failed: " <> err
                  Right scheduled ->
                    map rrIndex scheduled @?=
                      map rrIndex (rgRuntimeRegions (tplGraph tpl)))
                (tgTemplates tg)

      , -- Multi-template, fused: same as above but through the
        -- fused compile path so rg may carry RFused / rnElided.
        testCase "loadTemplateGraphFused: per-template scheduled order = rgRuntimeRegions" $ do
          let voice = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                busOut 5 a
              fx = runSynth $ do
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.6)
                b <- add a (Param 0.0)
                out 0 b
          case compileTemplateGraphFused
                  [("voice", voice), ("fx", fx)] of
            Left err -> assertFailure err
            Right tg ->
              mapM_ (\tpl ->
                case scheduledRuntimeRegions (tplGraph tpl) of
                  Left err -> assertFailure $
                    "template " <> show (tplName tpl)
                    <> ": scheduledRuntimeRegions failed: " <> err
                  Right scheduled ->
                    map rrIndex scheduled @?=
                      map rrIndex (rgRuntimeRegions (tplGraph tpl)))
                (tgTemplates tg)

      , -- §4.E.2b loader-preservation contract: a failed schedule
        -- must not disturb the currently loaded graph. Compute the
        -- schedule first, fail before 'c_rt_graph_clear', leave
        -- the previous graph fully renderable.
        --
        -- Procedure: load a good graph, snapshot bus 0 after one
        -- block. Construct a malformed graph (reverse the region
        -- list — trips the dense-ascending check). 'try' to load
        -- it; expect 'Left'. Render another block on the same
        -- handle and confirm it is non-silent and at a similar
        -- peak level. (We can't compare sample-for-sample because
        -- the oscillator phase has advanced; the right invariant
        -- is "same audible signal, just one block later".)
        testCase "loadRuntimeGraph: failed schedule preserves previous graph" $ do
          let nframes, sizeOfFloat :: Int
              nframes     = 256
              sizeOfFloat = 4
              -- Two-region graph: an 'RSawLpfGain' buffer feeds an
              -- 'RNodeLoop' tail. Reversing 'rgRuntimeRegions'
              -- produces a non-ascending list that the planner
              -- must reject.
              good = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)
                out 0 b
          rt <- case lowerGraph good >>= compileRuntimeGraph of
            Right r  -> pure r
            Left err -> assertFailure err >> error "unreachable"
          -- Sanity: the chosen graph has at least two regions, so
          -- the reversal is observable.
          assertBool
            "expected good graph to have at least two regions"
            (length (rgRuntimeRegions rt) >= 2)
          let bad = rt { rgRuntimeRegions =
                           reverse (rgRuntimeRegions rt) }
          withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
            loadRuntimeGraph handle rt
            c_rt_graph_process handle (fromIntegral nframes)
            before <-
              allocaBytes (nframes * sizeOfFloat) $ \buf -> do
                _ <- c_rt_graph_read_bus handle 0
                       (fromIntegral nframes) (castPtr buf)
                cs <- peekArray nframes (buf :: PtrCFloat)
                pure (map (\(CFloat x) -> x) cs)

            -- Attempt the bad load; must fail before clear.
            let attempt :: IO (Either IOError ())
                attempt = try $ loadRuntimeGraph handle bad
            result <- attempt
            case result of
              Right () ->
                assertFailure $
                  "loadRuntimeGraph should have rejected the "
                  <> "malformed graph"
              Left e ->
                assertBool
                  ("expected dense-ordering diagnostic in: "
                   <> show e)
                  ("dense" `isInfixOf` show e)

            -- The previously loaded graph must still produce the
            -- same audio. Render another block and compare.
            c_rt_graph_process handle (fromIntegral nframes)
            after <-
              allocaBytes (nframes * sizeOfFloat) $ \buf -> do
                _ <- c_rt_graph_read_bus handle 0
                       (fromIntegral nframes) (castPtr buf)
                cs <- peekArray nframes (buf :: PtrCFloat)
                pure (map (\(CFloat x) -> x) cs)

            -- 'before' is block 0 and 'after' is block 1 of the
            -- /same/ continuous oscillator. Pinning that both
            -- blocks render non-silent audio at a similar level
            -- shows the graph survived the failed load — a
            -- half-cleared state would produce silence or
            -- diverge in level. We don't compare sample-for-sample
            -- because the oscillator phase advances between
            -- blocks (which is the correct behavior).
            let peakBefore = maximum (map abs before)
                peakAfter  = maximum (map abs after)
            assertBool ("peak before > 0, got " <> show peakBefore)
                       (peakBefore > 0.05)
            assertBool ("peak after > 0, got " <> show peakAfter)
                       (peakAfter > 0.05)
            assertBool
              ("peaks should be in same ballpark; before="
               <> show peakBefore <> " after=" <> show peakAfter)
              (abs (peakBefore - peakAfter) < 0.5 * peakBefore)
      ]

  , -- Phase 4.E.2c (parallel-readiness survey): descriptive
    -- 'regionScheduleStats' counts. Read-only summary used by
    -- '--fusion-survey' to answer "do graphs have wide non-barrier
    -- work?" before any worker-pool design lands.
    testGroup "Phase 4.E.2c: regionScheduleStats descriptive counts"
      [ -- Single-region all-barrier graph: one barrier, no free.
        testCase "single-region (sin -> out): 1 barrier, 0 free, max widths 0" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> case regionScheduleStats rg of
              Left err -> assertFailure $ "stats failed: " <> err
              Right s ->
                s @?= RegionScheduleStats
                  { rssTotal               = 1
                  , rssBarriers            = 1
                  , rssFree                = 0
                  , rssFreeSegments        = 0
                  , rssMaxFreeSegmentWidth = 0
                  , rssMaxFreeLayerWidth   = 0
                  , rssSharedWriteHazards  = 0
                  , rssMaxRunnableLayerWidth
                                           = 0
                  , rssMaxReductionLayerWidth
                                           = 0
                  }

      , -- Kernel-split: free buffer + barrier tail.
        testCase "saw -> lpf -> gain -> add -> out: 1 free + 1 barrier, max widths 1" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> case regionScheduleStats rg of
              Left err -> assertFailure $ "stats failed: " <> err
              Right s ->
                s @?= RegionScheduleStats
                  { rssTotal               = 2
                  , rssBarriers            = 1
                  , rssFree                = 1
                  , rssFreeSegments        = 1
                  , rssMaxFreeSegmentWidth = 1
                  , rssMaxFreeLayerWidth   = 1
                  , rssSharedWriteHazards  = 0
                  , rssMaxRunnableLayerWidth
                                           = 1
                  , rssMaxReductionLayerWidth
                                           = 0
                  }

      , -- Headline parallelism case: two independent free buffers
        -- in one segment. Width = 2 at both segment and layer
        -- level (regions are independent → one layer of size 2).
        testCase "two independent buffers + shared tail: free width 2 at layer 0" $ do
          let g = runSynth $ do
                s1 <- sawOsc 110.0 0.0
                f1 <- lpf s1 (Param 800.0)  (Param 4.0)
                g1 <- gain f1 (Param 0.4)
                s2 <- sawOsc 220.0 0.0
                f2 <- lpf s2 (Param 1200.0) (Param 4.0)
                g2 <- gain f2 (Param 0.4)
                summed <- add g1 g2
                out 0 summed
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              case regionScheduleStats rg of
                Left err -> assertFailure $ "stats failed: " <> err
                Right s ->
                  s @?= RegionScheduleStats
                    { rssTotal               = 3
                    , rssBarriers            = 1
                    , rssFree                = 2
                    , rssFreeSegments        = 1
                    , rssMaxFreeSegmentWidth = 2
                    , rssMaxFreeLayerWidth   = 2
                    , rssSharedWriteHazards  = 0
                    , rssMaxRunnableLayerWidth
                                             = 2
                    , rssMaxReductionLayerWidth
                                             = 0
                    }
              layeredRegionSchedule rg @?=
                Right
                  [ ScheduleFreeLayer FreeLayer
                      { flRegions = [RegionIndex 0, RegionIndex 1]
                      , flSharedWriteHazards = []
                      }
                  , ScheduleBarrier (RegionIndex 2)
                  ]

      , -- Aggregation: empty + s = s, and (a + b) sums counts and
        -- maxes widths.
        testCase "addScheduleStats: counts add, widths max" $ do
          let a = RegionScheduleStats 3 1 2 1 2 2 0 2 0
              b = RegionScheduleStats 5 4 1 1 1 1 1 1 1
          addScheduleStats emptyScheduleStats a @?= a
          addScheduleStats a emptyScheduleStats @?= a
          addScheduleStats a b @?=
            RegionScheduleStats
              { rssTotal               = 8
              , rssBarriers            = 5
              , rssFree                = 3
              , rssFreeSegments        = 2
              , rssMaxFreeSegmentWidth = 2
              , rssMaxFreeLayerWidth   = 2
              , rssSharedWriteHazards  = 1
              , rssMaxRunnableLayerWidth
                                       = 2
              , rssMaxReductionLayerWidth
                                       = 1
              }

      , -- Cross-template width: a chain ensemble (voice → fx via
        -- shared bus) has 'tssMaxTemplateLayerWidth' = 1, even
        -- though the per-template aggregate sums two regions.
        testCase "templateScheduleStats: chain ensemble has layer width 1" $ do
          let voice = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                busOut 5 a
              fx = runSynth $ do
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.6)
                out 0 a
          case compileTemplateGraph [("voice", voice), ("fx", fx)] of
            Left err -> assertFailure err
            Right tg -> case templateScheduleStats tg of
              Left err -> assertFailure $ "stats failed: " <> err
              Right s -> do
                tssTemplateCount         s @?= 2
                tssMaxTemplateLayerWidth s @?= 1
                tssSharedWriteHazards    s @?= 0
                tssMaxTemplateRunnableWidth s @?= 1
                tssMaxTemplateReductionWidth s @?= 0
                rssTotal    (tssAggregate s) @?= 2
                rssBarriers (tssAggregate s) @?= 2

      , -- Two independent voices writing different buses have no
        -- precedence on each other and no shared-write hazard, so
        -- the full layer-0 width is runnable without reduction.
        testCase "templateScheduleStats: disjoint writers are runnable width 2" $ do
          let left = runSynth $ do
                s <- sawOsc 110.0 0.0
                a <- gain s (Param 0.3)
                out 0 a
              right = runSynth $ do
                s <- sawOsc 220.0 0.0
                a <- gain s (Param 0.3)
                out 1 a
          case compileTemplateGraph [("left", left), ("right", right)] of
            Left err -> assertFailure err
            Right tg -> case templateScheduleStats tg of
              Left err -> assertFailure $ "stats failed: " <> err
              Right s -> do
                tssTemplateCount              s @?= 2
                tssMaxTemplateLayerWidth      s @?= 2
                tssSharedWriteHazards         s @?= 0
                tssMaxTemplateRunnableWidth   s @?= 2
                tssMaxTemplateReductionWidth  s @?= 0

      , -- Two independent voices feeding one fx: voices have no
        -- precedence on each other (both write the same bus,
        -- neither reads from the other), so layer 0 = {voice-l,
        -- voice-r}, layer 1 = {fx}. Max template precedence
        -- width = 2. Because the two voices also share bus 7,
        -- the full layer is reduction-needed width, not runnable
        -- width.
        testCase "templateScheduleStats: two voices + one fx → layer width 2" $ do
          let voiceL = runSynth $ do
                s <- sawOsc 110.0 0.0
                a <- gain s (Param 0.3)
                busOut 7 a
              voiceR = runSynth $ do
                s <- sawOsc 220.0 0.0
                a <- gain s (Param 0.3)
                busOut 7 a
              fx = runSynth $ do
                r <- busIn 7
                f <- lpf r (Param 1200.0) (Param 0.7)
                a <- gain f (Param 0.6)
                out 0 a
          case compileTemplateGraph
                  [ ("voice-l", voiceL)
                  , ("voice-r", voiceR)
                  , ("fx",      fx)
                  ] of
            Left err -> assertFailure err
            Right tg -> case templateScheduleStats tg of
              Left err -> assertFailure $ "stats failed: " <> err
              Right s -> do
                tssTemplateCount              s @?= 3
                tssMaxTemplateLayerWidth      s @?= 2
                tssSharedWriteHazards         s @?= 1
                tssMaxTemplateRunnableWidth   s @?= 1
                tssMaxTemplateReductionWidth  s @?= 2
      ]

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
