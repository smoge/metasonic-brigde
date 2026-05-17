-- | Phase 4.E.2.C0c/C1a global-schedule banded serial executor tests.
--
-- C0c promotes the C0b global schedule from observation to an
-- executable serial path, gated by a test-only switch. C1a routes
-- that executor through C0d bands, still serially. This group keeps
-- the worker pool disabled: the schedule executor must render
-- byte-identical output to the legacy nested loop, preserve §2.E
-- release accounting, and keep the B3 reduction-capture equivalence
-- when both switches are enabled. C++-only graphs with no schedule
-- metadata fall back to the legacy executor; that path is covered in
-- the C++ test suite because Haskell loaders always ship schedule
-- metadata.
--
-- Extracted from "MetaSonic.Spec.FFI" as the third slice of the
-- megafile split. Shared helpers ('compileBoth',
-- 'assertDirectEqualsScheduleRG/TG',
-- 'assertScheduleDirectEqualsReductionRG/TG', 't9CorpusGraphs',
-- 't9CorpusTemplates', 'sendReturnLiveTG', 'filteredSawGraph')
-- stay in the parent module.
module MetaSonic.Spec.FFI.C0c (c0cScheduleExecutorTests) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile (compileRuntimeGraph, rgNodes)
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR      (lowerGraph)
import           MetaSonic.Bridge.Source  (env, out, runSynth)

import           MetaSonic.Spec.Core      (chainGraph, divergentLayerGraph)
import           MetaSonic.Spec.FFI       (assertDirectEqualsScheduleRG,
                                           assertDirectEqualsScheduleTG,
                                           assertScheduleDirectEqualsReductionRG,
                                           assertScheduleDirectEqualsReductionTG,
                                           compileBoth, filteredSawGraph,
                                           sendReturnLiveTG, t9CorpusGraphs,
                                           t9CorpusTemplates)


c0cScheduleExecutorTests :: TestTree
c0cScheduleExecutorTests =
  let nframes = 256
      blocks  = 4
  in testGroup "Phase 4.E.2.C0c/C1a: global-schedule banded serial executor"
       [ testGroup "legacy executor equals global schedule"
           [ testCase "single template, unfused" $ do
               (rg, _) <- compileBoth "chain" chainGraph
               assertDirectEqualsScheduleRG
                 "chain" loadRuntimeGraph rg nframes blocks

           , testCase "single template, fused" $ do
               (_, rg) <- compileBoth "filtered-saw" filteredSawGraph
               assertDirectEqualsScheduleRG
                 "filtered-saw" loadRuntimeGraphFused rg nframes blocks

           , testCase "multi-template live send/return" $
               assertDirectEqualsScheduleTG
                 "send-return-live" loadTemplateGraph
                 sendReturnLiveTG nframes blocks

           , testCase "non-contiguous free layer" $ do
               rg <- case lowerGraph divergentLayerGraph
                       >>= compileRuntimeGraph of
                 Right rg' -> pure rg'
                 Left err  -> assertFailure
                                ("c0c divergent compile: " <> err)
                              >> error "unreachable"
               assertDirectEqualsScheduleRG
                 "divergent-layer" loadRuntimeGraph rg nframes blocks
           ]

       , testGroup "T-9 under global schedule"
           [ testGroup "single template, unfused loader"
               [ testCase name $ do
                   (rtUn, _) <- compileBoth name g
                   assertScheduleDirectEqualsReductionRG
                     name loadRuntimeGraph rtUn nframes blocks
               | (name, g) <- t9CorpusGraphs
               ]

           , testGroup "single template, fused loader"
               [ testCase name $ do
                   (_, rtF) <- compileBoth name g
                   assertScheduleDirectEqualsReductionRG
                     name loadRuntimeGraphFused rtF nframes blocks
               | (name, g) <- t9CorpusGraphs
               ]

           , testGroup "multi-template, unfused loader"
               [ testCase name $
                   assertScheduleDirectEqualsReductionTG
                     name loadTemplateGraph tg nframes blocks
               | (name, tg) <- t9CorpusTemplates
               ]

           , testGroup "multi-template, fused loader"
               [ testCase name $
                   assertScheduleDirectEqualsReductionTG
                     name loadTemplateGraphFused tg nframes blocks
               | (name, tg) <- t9CorpusTemplates
               ]
           ]

       , testCase "release-then-free still runs once per instance block" $ do
           let voice = runSynth $ do
                 e <- env 1.0 0.0005 0.002 0.5 0.002
                 out 0 e
               rg = case lowerGraph voice >>= compileRuntimeGraph of
                 Right r  -> r
                 Left err -> error err

           withRTGraph (length (rgNodes rg)) nframes $ \handle -> do
             loadRuntimeGraph handle rg
             c_rt_graph_test_set_global_schedule_execution handle 1

             s0 <- c_rt_graph_instance_status handle 0
             s0 @?= instanceStatusLive

             c_rt_graph_process handle (fromIntegral nframes)
             c_rt_graph_instance_release handle 0
             s1 <- c_rt_graph_instance_status handle 0
             s1 @?= instanceStatusReleasing

             let drain n
                   | n <= 0    = pure False
                   | otherwise = do
                       c_rt_graph_process handle (fromIntegral nframes)
                       alive <- c_rt_graph_instance_alive handle 0
                       if alive == 0 then pure True else drain (n - 1)
             freed <- drain (64 :: Int)
             assertBool
               "scheduled executor should auto-free within 64 blocks"
               freed

             s2 <- c_rt_graph_instance_status handle 0
             s2 @?= (-1)
       ]
