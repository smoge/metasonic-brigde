-- | Aggregator for the core compiler test surface. Owns the
-- @unitTests@ tree (demo-graph mini-groups, scattered fixtures, the
-- C ABI tag agreement groups, and the @Edge graphs@ group) plus
-- thirteen extracted cohort modules. The QuickCheck property tree
-- lives in "MetaSonic.Spec.Core.Properties" and is imported by
-- "test/Spec.hs" directly.
module MetaSonic.Spec.Core where

import qualified Data.Map.Strict           as M
import           Data.List                 (isPrefixOf, nub, sort)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI      (c_rt_graph_kind_supported,
                                            c_rt_graph_region_kernel_supported)
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source   (sgNodes)
import           MetaSonic.Bridge.Validate
import           MetaSonic.Types

import           MetaSonic.Spec.Core.BusRouting (busRoutingCoreTests)
import           MetaSonic.Spec.Core.CCBuilder (ccBuilderTests)
import           MetaSonic.Spec.Core.Dependencies (dependenciesTests)
import           MetaSonic.Spec.Core.FusionAlgebra (fusionAlgebraTests)
import           MetaSonic.Spec.Core.MigrationKeys (migrationKeyTests)
import           MetaSonic.Spec.Core.NodeIndex (nodeIndexResolutionTests)
import           MetaSonic.Spec.Core.RateMetadata (rateMetadataTests)
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

  , rateMetadataTests

  , testCase "kindTag is injective" $
      let ks = [minBound .. maxBound :: NodeKind]
          ts = map kindTag ks
      in assertEqual
           "two NodeKinds share a kindTag — C++ dispatch will collide"
           (length ks)
           (length (nub ts))
  ]
