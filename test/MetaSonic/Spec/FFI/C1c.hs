-- | Phase 4.E.2.C1c-c worker-schedule equivalence tests.
--
-- C1c-b added the conservative worker-dispatch path for eligible Free
-- bands. C1c-c keeps the same bit-equivalence discipline as T-9 and
-- C0c, but enables the graph-owned worker pool while the schedule
-- executor is active. The corpus test catches loader/runtime boundary
-- drift; the final small test proves that Haskell-loaded metadata can
-- enter the worker path, not merely run with idle background threads.
--
-- Extracted from "MetaSonic.Spec.FFI" as the first slice of the
-- megafile split. The shared helpers ('compileBoth',
-- 'assertSchedulePoolDirectEqualsReductionRG',
-- 'assertSchedulePoolDirectEqualsReductionTG',
-- 'assertDirectEqualsSchedulePoolRG', 't9CorpusGraphs',
-- 't9CorpusTemplates') stay in the parent module until a later slice
-- moves them to their own helpers module.
module MetaSonic.Spec.FFI.C1c (c1cWorkerScheduleTests) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile (compileRuntimeGraph, rgNodes)
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR      (lowerGraph)
import           MetaSonic.Bridge.Source  (gain, runSynth, sinOsc)

import           MetaSonic.Spec.CoreShared      (chainGraph)
import           MetaSonic.Spec.FFI       (assertDirectEqualsSchedulePoolRG,
                                           assertSchedulePoolDirectEqualsReductionRG,
                                           assertSchedulePoolDirectEqualsReductionTG,
                                           compileBoth, t9CorpusGraphs,
                                           t9CorpusTemplates)


c1cWorkerScheduleTests :: TestTree
c1cWorkerScheduleTests =
  let nframes = 256
      blocks  = 4
      pool    = 3
  in testGroup "Phase 4.E.2.C1c-c: worker-schedule equivalence"
       [ testGroup "T-9 under global schedule + pool_size=3"
           [ testGroup "single template, unfused loader"
               [ testCase name $ do
                   (rtUn, _) <- compileBoth name g
                   assertSchedulePoolDirectEqualsReductionRG
                     name loadRuntimeGraph rtUn pool nframes blocks
               | (name, g) <- t9CorpusGraphs
               ]

           , testGroup "single template, fused loader"
               [ testCase name $ do
                   (_, rtF) <- compileBoth name g
                   assertSchedulePoolDirectEqualsReductionRG
                     name loadRuntimeGraphFused rtF pool nframes blocks
               | (name, g) <- t9CorpusGraphs
               ]

           , testGroup "multi-template, unfused loader"
               [ testCase name $
                   assertSchedulePoolDirectEqualsReductionTG
                     name loadTemplateGraph tg pool nframes blocks
               | (name, tg) <- t9CorpusTemplates
               ]

           , testGroup "multi-template, fused loader"
               [ testCase name $
                   assertSchedulePoolDirectEqualsReductionTG
                     name loadTemplateGraphFused tg pool nframes blocks
               | (name, tg) <- t9CorpusTemplates
               ]
           ]

       , testCase "schedule pool matches legacy on a representative graph" $ do
           (rg, _) <- compileBoth "chain" chainGraph
           assertDirectEqualsSchedulePoolRG
             "chain" loadRuntimeGraph rg pool nframes blocks

       , testCase "Haskell-loaded free-only graph enters worker dispatch" $ do
           let computeOnly = runSynth $ do
                 o <- sinOsc 110.0 0.0
                 _ <- gain o 0.25
                 pure ()
           rg <- case lowerGraph computeOnly >>= compileRuntimeGraph of
             Right r  -> pure r
             Left err -> assertFailure ("c1c compute-only compile: " <> err)
                         >> error "unreachable"

           withRTGraph (length (rgNodes rg)) nframes $ \handle -> do
             loadRuntimeGraph handle rg
             _ <- c_rt_graph_template_instance_add handle 0
             _ <- c_rt_graph_template_instance_add handle 0
             c_rt_graph_test_set_worker_pool_size handle (fromIntegral pool)
             c_rt_graph_test_set_global_schedule_execution handle 1
             c_rt_graph_process handle (fromIntegral nframes)

             bands <- c_rt_graph_test_last_parallel_band_count handle
             entries <- c_rt_graph_test_last_parallel_entry_count handle
             assertBool "expected at least one worker-dispatched band"
                        (bands > 0)
             entries @?= 3
       ]
