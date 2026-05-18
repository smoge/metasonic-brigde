-- | Phase 4.E.2.C0d global-schedule runnable bands tests.
--
-- C0d derives the banded view that C1a consumes serially and C1c can
-- consume as worker dispatch groups. The conservative v1 rule is
-- intentionally narrow: barriers are singleton serial bands, and a
-- free band contains only FreeLayer entries with at most one step per
-- instance slot. That avoids violating per-instance layer order
-- without shipping the full region dependency graph to the runtime.
--
-- Extracted from "MetaSonic.Spec.FFI" as the second slice of the
-- megafile split. Shared helpers ('compileBoth', 'readGlobalSchedule',
-- 'readGlobalScheduleBands', 'assertGlobalScheduleBandsWellFormed',
-- 'expectedGlobalRG') stay in the parent module.
module MetaSonic.Spec.FFI.C0d (c0dGlobalScheduleBandTests) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile (ScheduleStep (..),
                                           compileRuntimeGraph,
                                           layeredRegionSchedule, rgNodes)
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR      (lowerGraph)
import           MetaSonic.Bridge.Source  (gain, runSynth, sinOsc)

import           MetaSonic.Spec.CoreShared      (chainGraph, divergentLayerGraph,
                                           simpleGraph)
import           MetaSonic.Spec.FFI       (assertGlobalScheduleBandsWellFormed,
                                           compileBoth, expectedGlobalRG,
                                           readGlobalSchedule,
                                           readGlobalScheduleBands)


c0dGlobalScheduleBandTests :: TestTree
c0dGlobalScheduleBandTests =
  testGroup "Phase 4.E.2.C0d: global-schedule runnable bands"
    [ testCase "fresh handle: empty bands" $
        withRTGraph 4 256 $ \handle -> do
          c_rt_graph_process handle 256
          entries <- readGlobalSchedule handle
          bands   <- readGlobalScheduleBands handle
          entries @?= []
          bands   @?= []

    , testCase "bands form a conservative partition" $ do
        (rg, _) <- compileBoth "chain" chainGraph
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          c_rt_graph_process handle 256
          assertGlobalScheduleBandsWellFormed "chain" handle

    , testCase "free-only instances share one band" $ do
        let computeOnly = runSynth $ do
              o <- sinOsc 110.0 0.0
              _ <- gain o 0.25
              pure ()
        rg <- case lowerGraph computeOnly >>= compileRuntimeGraph of
          Right r  -> pure r
          Left err -> assertFailure ("compute-only compile: " <> err)
                      >> error "unreachable"
        steps <- case layeredRegionSchedule rg of
          Right ss -> pure ss
          Left err -> assertFailure
                        ("compute-only layered schedule: " <> err)
                      >> error "unreachable"
        let expectedFreeOnly =
              case steps of
                [ScheduleFreeLayer _] -> True
                _                     -> False
        assertBool
          ("expected compute-only graph to be one free layer, got "
           <> show steps)
          expectedFreeOnly

        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          _ <- c_rt_graph_template_instance_add handle 0
          _ <- c_rt_graph_template_instance_add handle 0
          c_rt_graph_process handle 256
          entries <- readGlobalSchedule handle
          entries @?= expectedGlobalRG rg [0, 1, 2]
          bands <- readGlobalScheduleBands handle
          bands @?= [(1, 0, 3)]
          assertGlobalScheduleBandsWellFormed "compute-only" handle

    , testCase "same-instance free layers split before barrier" $ do
        rg <- case lowerGraph divergentLayerGraph >>= compileRuntimeGraph of
          Right r  -> pure r
          Left err -> assertFailure ("c0d divergent compile: " <> err)
                      >> error "unreachable"
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          c_rt_graph_process handle 256
          entries <- readGlobalSchedule handle
          entries @?= expectedGlobalRG rg [0]
          bands <- readGlobalScheduleBands handle
          bands @?= [(1, 0, 1), (1, 1, 1), (0, 2, 1)]
          assertGlobalScheduleBandsWellFormed "divergent" handle

    , testCase "reload clears prior band snapshot" $ do
        (rgChain,  _) <- compileBoth "chain"  chainGraph
        (rgSimple, _) <- compileBoth "simple" simpleGraph
        let totalNodes = max (length (rgNodes rgChain))
                             (length (rgNodes rgSimple))
        withRTGraph totalNodes 256 $ \handle -> do
          loadRuntimeGraph handle rgChain
          c_rt_graph_process handle 256
          firstCount <- c_rt_graph_test_global_schedule_band_count handle
          assertBool "expected non-empty bands after first load"
                     (firstCount > 0)
          loadRuntimeGraph handle rgSimple
          c_rt_graph_process handle 256
          assertGlobalScheduleBandsWellFormed "simple after reload" handle
    ]
