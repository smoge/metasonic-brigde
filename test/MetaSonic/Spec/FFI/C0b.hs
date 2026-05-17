-- | Phase 4.E.2.C0b per-block global schedule tests.
--
-- The runtime rebuilds a global schedule at the top of every
-- 'rt_graph_process' call: a flat list of (template_id,
-- instance_slot, step_index) entries in canonical
--   template ascending → instance slot ascending → step ascending
-- order, filtered to instances whose state is Active or Releasing.
-- These tests pin the shape the C0c serial executor consumes when
-- its test switch is enabled. Cross-resolution to per-step kind /
-- ordinal data goes through the C0a accessors; the divergent-layer
-- case proves a non-contiguous free layer survives all the way out
-- to a global-schedule consumer.
--
-- Extracted from "MetaSonic.Spec.FFI" as the fifth slice of the
-- megafile split. Shared helpers ('compileBoth',
-- 'readGlobalSchedule', 'expectedGlobalRG', 'expectedGlobalTG',
-- 'sendReturnLiveTG', 'envPluckGraph') stay in the parent module.
module MetaSonic.Spec.FFI.C0b (c0bGlobalScheduleTests) where

import           Control.Monad            (forM)
import           Data.List                (nub, sort)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile (compileRuntimeGraph, rgNodes)
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR      (lowerGraph)
import           MetaSonic.Bridge.Templates (tgTemplates, tplGraph)

import           MetaSonic.Spec.Core      (chainGraph, divergentLayerGraph,
                                           simpleGraph)
import           MetaSonic.Spec.FFI       (compileBoth, envPluckGraph,
                                           expectedGlobalRG, expectedGlobalTG,
                                           readGlobalSchedule,
                                           sendReturnLiveTG)


c0bGlobalScheduleTests :: TestTree
c0bGlobalScheduleTests =
  testGroup "Phase 4.E.2.C0b: per-block global schedule"
    [ -- Default state has no schedule_steps anywhere, so the
      -- global schedule must be empty even after a process tick.
      -- This pins the "no metadata, no schedule" fallback for the
      -- legacy single-template build path.
      testCase "fresh handle: empty global schedule" $
        withRTGraph 4 256 $ \handle -> do
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          actual @?= []

    , -- The single auto-spawned instance produces one entry per
      -- step in canonical (0, 0, step) order.
      testCase "single instance, single template" $ do
        (rg, _) <- compileBoth "chain" chainGraph
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          actual @?= expectedGlobalRG rg [0]

    , -- Spawning more instances of the same template appends slots
      -- to the canonical order: slot 0 → slot 1 → slot 2, with the
      -- full step list interleaved per slot.
      testCase "multiple instances preserve slot order" $ do
        (rg, _) <- compileBoth "chain" chainGraph
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          _ <- c_rt_graph_template_instance_add handle 0
          _ <- c_rt_graph_template_instance_add handle 0
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          actual @?= expectedGlobalRG rg [0, 1, 2]

    , -- 'instance_remove' transitions the slot to Available, which
      -- the build skips. Verify the middle slot disappears while
      -- slots 0 and 2 remain in canonical order.
      testCase "Available slot is skipped" $ do
        (rg, _) <- compileBoth "chain" chainGraph
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          extra1 <- c_rt_graph_template_instance_add handle 0
          _      <- c_rt_graph_template_instance_add handle 0
          c_rt_graph_instance_remove handle extra1
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          actual @?= expectedGlobalRG rg [0, 2]

    , -- A graph with an Env node: 'instance_release' transitions
      -- to Releasing rather than Available, so the slot must
      -- still appear in the global schedule until §2.E's silence
      -- detector promotes it to Available many blocks later.
      -- envPluckGraph's release time (0.1s ≈ 19 blocks at
      -- 256/48000s) is comfortably longer than the one block this
      -- test runs, and the gain is non-trivial so block_sink_peak
      -- starts well above the silence threshold.
      testCase "Releasing slot stays in schedule" $ do
        (rg, _) <- compileBoth "envPluck" envPluckGraph
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          c_rt_graph_process handle 256   -- warm up
          c_rt_graph_instance_release handle 0
          status <- c_rt_graph_instance_status handle 0
          status @?= instanceStatusReleasing
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          actual @?= expectedGlobalRG rg [0]

    , -- For a multi-template graph the outer ordering is
      -- template_id ascending; only after every entry of template
      -- 0 has been emitted does any entry of template 1 appear.
      -- 'sendReturnLiveTG' has two templates with one instance
      -- each (auto-spawned by 'loadTemplateGraph').
      testCase "multi-template: template before instance order" $ do
        let tg = sendReturnLiveTG
            totalNodes = sum (map (length . rgNodes . tplGraph)
                                  (tgTemplates tg))
        withRTGraph totalNodes 256 $ \handle -> do
          loadTemplateGraph handle tg
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          let perTpl = [ (i, [i])
                       | i <- [0 .. length (tgTemplates tg) - 1]
                       ]
          actual @?= expectedGlobalTG tg perTpl
          -- Stronger ordering check: every template-0 entry must
          -- precede every template-1 entry in the flat list.
          let tids   = map (\(t, _, _) -> t) actual
              afterT = dropWhile (== 0) tids
          all (== 1) afterT @?= True

    , -- Stronger regression for the canonical-order contract: the
      -- previous case's slot indices coincide with template_id
      -- (template 0 → slot 0, template 1 → slot 1), so it doesn't
      -- prove that template order /dominates/ slot order. Spawn an
      -- extra template-0 instance after the auto-spawned pair,
      -- which the pool places at slot 2 (first growth past the
      -- occupied 0,1). Slot order is now interleaved across
      -- templates (template 0 owns slots 0, 2; template 1 owns
      -- slot 1) but the global schedule must still group all
      -- template-0 entries before any template-1 entry.
      testCase "multi-template: template order dominates slot order" $ do
        let tg = sendReturnLiveTG
            totalNodes = sum (map (length . rgNodes . tplGraph)
                                  (tgTemplates tg))
        withRTGraph (totalNodes + 16) 256 $ \handle -> do
          loadTemplateGraph handle tg
          extraSlot <- c_rt_graph_template_instance_add handle 0
          extraSlot @?= 2  -- pool grew past the auto-spawned 0,1
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          actual @?= expectedGlobalTG tg
            [ (0, [0, 2])  -- template 0 owns slot 0 (auto) and slot 2 (extra)
            , (1, [1])     -- template 1 owns slot 1 (auto)
            ]
          -- Pin the dominance directly: the flat tid sequence must
          -- be a non-decreasing run, so a slot-1 entry can never
          -- appear between two slot-0 entries.
          let tids = map (\(t, _, _) -> t) actual
          tids @?= sort tids
          -- And the slot interleaving must actually be present in
          -- this test's data (otherwise we're not exercising the
          -- "template order dominates" path).
          let tidSlots = nub [(t, s) | (t, s, _) <- actual]
          tidSlots @?= [(0, 0), (0, 2), (1, 1)]

    , -- Non-contiguous free-layer ordinals must survive into the
      -- global schedule. This test resolves each entry's
      -- (template, step) through the C0a accessors and pins the
      -- divergent layer's ordinals at [0, 2] (not [0, 1]).
      testCase "non-contiguous layer ordinals survive" $ do
        rg <- case lowerGraph divergentLayerGraph
                >>= compileRuntimeGraph of
          Right rg' -> pure rg'
          Left err  -> assertFailure
                         ("c0b divergent compile: " <> err)
                       >> error "unreachable"
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          c_rt_graph_process handle 256
          entries <- readGlobalSchedule handle
          -- Resolve every entry's step back to its ordinal list.
          ordinalsPerEntry <-
            forM entries $ \(tid, _slot, step) -> do
              n <- c_rt_graph_test_template_schedule_step_item_count
                     handle (fromIntegral tid)
                     (fromIntegral step)
              forM [0 .. fromIntegral n - 1] $ \j ->
                c_rt_graph_test_template_schedule_step_region
                  handle (fromIntegral tid)
                  (fromIntegral step) j
          let toInts = map fromIntegral
              -- Split entries by step_index; instance 0 only.
              steps  = nub (map (\(_, _, p) -> p) entries)
              perStep =
                [ ( s
                  , [ ords
                    | ((_, _, p), ords) <- zip entries
                                              (map toInts
                                                   ordinalsPerEntry)
                    , p == s
                    ]
                  )
                | s <- steps
                ]
          -- Pin the divergent shape: step 0 = [0, 2], step 1 = [1],
          -- step 2 = [3] (the barrier sink). The entries for the
          -- single instance present each step exactly once.
          map snd perStep @?=
            [ [[0, 2]]
            , [[1]]
            , [[3]]
            ]

    , -- Reload through a Haskell loader calls c_rt_graph_clear
      -- internally, which drops the prior block's global schedule
      -- snapshot. After the second load the global schedule must
      -- reflect only the new graph's shape.
      testCase "reload clears prior global schedule" $ do
        (rgChain,  _) <- compileBoth "chain"  chainGraph
        (rgSimple, _) <- compileBoth "simple" simpleGraph
        let totalNodes = max (length (rgNodes rgChain))
                             (length (rgNodes rgSimple))
        withRTGraph totalNodes 256 $ \handle -> do
          loadRuntimeGraph handle rgChain
          c_rt_graph_process handle 256
          firstCount <- c_rt_graph_test_global_schedule_entry_count
                          handle
          assertBool "expected non-empty schedule after first load"
                     (firstCount > 0)
          loadRuntimeGraph handle rgSimple
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          actual @?= expectedGlobalRG rgSimple [0]
    ]
