-- | Phase 4.E.2.C0a layer-aware loader metadata tests.
--
-- C0a is a metadata-only ABI slice: every loader ships
-- 'layeredRegionSchedule' across the FFI as a sequence of
-- (kind, [region_ordinals]) pairs over the template's registered
-- region vector. Each step's ordinal list is materialised on the C
-- side via MetaDef::schedule_step_regions, so a non-contiguous free
-- layer like {0, 2} stays {0, 2}. Execution is unchanged —
-- process_instance still iterates regions in registration order —
-- but the runtime now stores the layered view so C0b can build a
-- per-block global schedule from it. These tests pin the projection:
-- every loader's output equals 'expectedScheduleStepItems' applied
-- to the corresponding 'layeredRegionSchedule', and stale step /
-- item queries return -1.
--
-- Extracted from "MetaSonic.Spec.FFI" as the sixth and final slice
-- of the phase-tree split. The four C0a-local helpers
-- ('expectedScheduleStepItems', 'readScheduleSteps',
-- 'assertLoaderShipsScheduleRG', 'assertLoaderShipsScheduleTG') were
-- only used by these tests and travel here too; the broader
-- 'compileBoth' / 't9CorpusGraphs' / 't9CorpusTemplates' still come
-- from the parent module.
module MetaSonic.Spec.FFI.C0a (c0aLoaderMetadataTests) where

import           Control.Monad              (forM, forM_, when)
import           Data.List                  (sort)

import           Foreign.C.Types            (CInt)
import           Foreign.Ptr                (Ptr)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile   (FreeLayer (..), RuntimeGraph,
                                             RuntimeRegion (..),
                                             ScheduleStep (..),
                                             compileRuntimeGraph,
                                             layeredRegionSchedule,
                                             regionSchedule, rgNodes,
                                             scheduledRuntimeRegions)
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR        (lowerGraph)
import           MetaSonic.Bridge.Templates (TemplateGraph, tgTemplates,
                                             tplGraph, tplName)

import           MetaSonic.Spec.Core        (chainGraph, divergentLayerGraph,
                                             simpleGraph)
import           MetaSonic.Spec.FFI         (compileBoth, t9CorpusGraphs,
                                             t9CorpusTemplates)


-- | Mirror of 'scheduleStepItems' in @MetaSonic.Bridge.FFI@. The
-- tag encoding (0 = Barrier, 1 = FreeLayer) matches the C-side
-- 'ScheduleStepKind'. The duplication is deliberate: this helper
-- pins the contract the FFI helper must implement, so a future
-- divergence shows up as a test failure rather than silently
-- corrupting metadata. Returns @Left@ if any rrIndex in the
-- schedule is missing from @scheduled@ — by construction that
-- shouldn't happen, but a hard test failure beats a silent
-- mismapping.
expectedScheduleStepItems
  :: [RuntimeRegion]
  -> [ScheduleStep]
  -> Either String [(Int, [Int])]
expectedScheduleStepItems scheduled = traverse step
  where
    pairs = zip [0 :: Int ..] scheduled
    ordinal ix =
      case [i | (i, r) <- pairs, rrIndex r == ix] of
        (n : _) -> Right n
        []      -> Left $
          "expectedScheduleStepItems: rrIndex " <> show ix
          <> " not in scheduledRuntimeRegions"
    step (ScheduleBarrier ix)   = do
      o <- ordinal ix
      pure (0, [o])
    step (ScheduleFreeLayer fl) = do
      os <- traverse ordinal (flRegions fl)
      pure (1, os)

-- | Read every schedule step the runtime currently has for one
-- template, projected back to the same (kind, [ordinals]) shape
-- 'expectedScheduleStepItems' produces. Per-item ordinals are
-- resolved through MetaDef::schedule_step_regions, so a layer
-- with non-contiguous ordinals (e.g. {0, 2}) stays {0, 2}.
readScheduleSteps :: Ptr RTGraph -> Int -> IO [(Int, [Int])]
readScheduleSteps handle tid = do
  cnt <- c_rt_graph_test_template_schedule_step_count handle
           (fromIntegral tid)
  forM [0 .. fromIntegral cnt - 1] $ \i -> do
    k    <- c_rt_graph_test_template_schedule_step_kind handle
              (fromIntegral tid) i
    iCnt <- c_rt_graph_test_template_schedule_step_item_count
              handle (fromIntegral tid) i
    ords <- forM [0 .. fromIntegral iCnt - 1] $ \j ->
      c_rt_graph_test_template_schedule_step_region handle
        (fromIntegral tid) i j
    pure (fromIntegral k, map fromIntegral ords)

assertLoaderShipsScheduleRG
  :: String
  -> (Ptr RTGraph -> RuntimeGraph -> IO ())
  -> RuntimeGraph
  -> Assertion
assertLoaderShipsScheduleRG label loader rg = do
  scheduled <- case scheduledRuntimeRegions rg of
    Right rs -> pure rs
    Left err -> assertFailure
                  (label <> ": scheduledRuntimeRegions: " <> err)
                >> error "unreachable"
  steps <- case layeredRegionSchedule rg of
    Right ss -> pure ss
    Left err -> assertFailure
                  (label <> ": layeredRegionSchedule: " <> err)
                >> error "unreachable"
  expected <- case expectedScheduleStepItems scheduled steps of
    Right xs -> pure xs
    Left err -> assertFailure (label <> ": " <> err)
                >> error "unreachable"
  withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
    loader handle rg
    actual <- readScheduleSteps handle 0
    actual @?= expected
    -- Out-of-range step queries return -1 even when the schedule
    -- itself is non-empty: catches a future change that swallows
    -- the bounds check on the tail.
    let stepCount = fromIntegral (length expected) :: CInt
    badKind <- c_rt_graph_test_template_schedule_step_kind handle 0
                 stepCount
    badKind @?= -1
    -- Out-of-range item queries on the last valid step also return
    -- -1 (item bounds, not just step bounds).
    when (not (null expected)) $ do
      let lastStep = fromIntegral (length expected - 1) :: CInt
          itemOver = fromIntegral
                       (length (snd (last expected))) :: CInt
      badItem <- c_rt_graph_test_template_schedule_step_region
                   handle 0 lastStep itemOver
      badItem @?= -1

assertLoaderShipsScheduleTG
  :: String
  -> (Ptr RTGraph -> TemplateGraph -> IO ())
  -> TemplateGraph
  -> Assertion
assertLoaderShipsScheduleTG label loader tg = do
  expectedPerTpl <-
    forM (zip [0 ..] (tgTemplates tg)) $ \(i, tpl) -> do
      let rg = tplGraph tpl
      scheduled <- case scheduledRuntimeRegions rg of
        Right rs -> pure rs
        Left err -> assertFailure
          (label <> ": template " <> show (tplName tpl)
           <> ": " <> err)
          >> error "unreachable"
      steps <- case layeredRegionSchedule rg of
        Right ss -> pure ss
        Left err -> assertFailure
          (label <> ": template " <> show (tplName tpl)
           <> ": " <> err)
          >> error "unreachable"
      expected <- case expectedScheduleStepItems scheduled steps of
        Right xs -> pure xs
        Left err -> assertFailure
          (label <> ": template " <> show (tplName tpl)
           <> ": " <> err)
          >> error "unreachable"
      pure (i :: Int, expected)
  let totalNodes = sum (map (length . rgNodes . tplGraph)
                            (tgTemplates tg))
  withRTGraph totalNodes 256 $ \handle -> do
    loader handle tg
    forM_ expectedPerTpl $ \(tid, expected) -> do
      actual <- readScheduleSteps handle tid
      actual @?= expected


c0aLoaderMetadataTests :: TestTree
c0aLoaderMetadataTests =
  testGroup "Phase 4.E.2.C0a: layer-aware loader metadata"
    -- Universal invariant: 'layeredRegionSchedule' and
    -- 'regionSchedule' must cover the same /set/ of regions for any
    -- well-formed graph, even though their orderings can differ.
    -- 'goLayers' partitions the ready frontier and emits all ready
    -- regions per layer, while 'topoSortStable' picks one ready
    -- region at a time, so a free segment 0 → 1, 2 (independent)
    -- yields layered = [{0, 2}, {1}] but linear = [0, 1, 2] —
    -- different orderings of the same set. This test pins the
    -- coverage property without overconstraining the order, so a
    -- future corpus graph with non-contiguous layers (see the
    -- divergent-layer regression below) does not fail this test
    -- for the wrong reason.
    [ testGroup "layeredRegionSchedule and regionSchedule cover the same regions"
        [ testCase name $ do
            (rgU, _) <- compileBoth name g
            flatRegions <- case regionSchedule rgU of
              Right rs -> pure rs
              Left err -> assertFailure
                            (name <> ": regionSchedule: " <> err)
                          >> error "unreachable"
            steps <- case layeredRegionSchedule rgU of
              Right ss -> pure ss
              Left err -> assertFailure
                            (name <> ": layeredRegionSchedule: " <> err)
                          >> error "unreachable"
            sort (concatMap stepRegions steps) @?= sort flatRegions
        | (name, g) <- t9CorpusGraphs
        ]

    , testGroup "loadRuntimeGraph ships schedule steps"
        [ testCase name $ do
            (rgU, _) <- compileBoth name g
            assertLoaderShipsScheduleRG name loadRuntimeGraph rgU
        | (name, g) <- t9CorpusGraphs
        ]

    , testGroup "loadRuntimeGraphFused ships schedule steps"
        [ testCase name $ do
            (_, rgF) <- compileBoth name g
            assertLoaderShipsScheduleRG name loadRuntimeGraphFused rgF
        | (name, g) <- t9CorpusGraphs
        ]

    , testGroup "loadTemplateGraph ships schedule steps"
        [ testCase name $
            assertLoaderShipsScheduleTG name loadTemplateGraph tg
        | (name, tg) <- t9CorpusTemplates
        ]

    , testGroup "loadTemplateGraphFused ships schedule steps"
        [ testCase name $
            assertLoaderShipsScheduleTG name loadTemplateGraphFused tg
        | (name, tg) <- t9CorpusTemplates
        ]

    -- Reload on the same handle clears prior schedule metadata: load
    -- a non-trivial graph, then a trivial one, and check the second
    -- load's metadata is exactly what 'layeredRegionSchedule' says
    -- — i.e. the prior schedule is gone, not concatenated.
    , testCase "reload clears prior schedule metadata" $ do
        (rgChain,  _) <- compileBoth "chain"  chainGraph
        (rgSimple, _) <- compileBoth "simple" simpleGraph
        let totalNodes = max (length (rgNodes rgChain))
                             (length (rgNodes rgSimple))
        withRTGraph totalNodes 256 $ \handle -> do
          loadRuntimeGraph handle rgChain
          firstCount <- c_rt_graph_test_template_schedule_step_count
                          handle 0
          assertBool "expected non-zero schedule steps after first load"
                     (firstCount > 0)
          loadRuntimeGraph handle rgSimple
          actual    <- readScheduleSteps handle 0
          scheduled <- case scheduledRuntimeRegions rgSimple of
            Right rs -> pure rs
            Left err -> assertFailure
                          ("simple: scheduledRuntimeRegions: " <> err)
                        >> error "unreachable"
          steps <- case layeredRegionSchedule rgSimple of
            Right ss -> pure ss
            Left err -> assertFailure
                          ("simple: layeredRegionSchedule: " <> err)
                        >> error "unreachable"
          expected <-
            case expectedScheduleStepItems scheduled steps of
              Right xs -> pure xs
              Left err -> assertFailure ("simple: " <> err)
                          >> error "unreachable"
          actual @?= expected

    -- Regression for the contiguous-range encoding bug: the indirect
    -- ABI must preserve a non-contiguous free layer's ordinal set
    -- exactly. The graph is shaped so 'formRegions' yields three
    -- non-barrier regions where region 1 structurally depends on
    -- region 0 (via the cross-region RFrom edge from gain1 into the
    -- second saw chain) and region 2 is independent. 'goLayers'
    -- partitions the ready frontier, so the expected layers are
    -- [{0, 2}, {1}], non-contiguous in regionSchedule order
    -- [0, 1, 2]. A contiguous-range encoding would silently rewrite
    -- layer 0 to {0, 1}, putting a dependent region in the wrong
    -- layer once C0b consumes the metadata. This test pins the
    -- per-item shape end-to-end.
    , testCase "free layer with non-contiguous ordinals" $ do
        rg <- case lowerGraph divergentLayerGraph
                >>= compileRuntimeGraph of
          Right rg' -> pure rg'
          Left err  -> assertFailure
                         ("divergent: compile: " <> err)
                       >> error "unreachable"
        -- First check the planner: the linear schedule and the
        -- layered schedule must diverge in the documented way.
        scheduled <- case scheduledRuntimeRegions rg of
          Right rs -> pure rs
          Left err -> assertFailure
                        ("divergent: scheduledRuntimeRegions: " <> err)
                      >> error "unreachable"
        steps <- case layeredRegionSchedule rg of
          Right ss -> pure ss
          Left err -> assertFailure
                        ("divergent: layeredRegionSchedule: " <> err)
                      >> error "unreachable"
        let regionCount    = length scheduled
            layerSizes     = map (length . stepRegions) steps
        -- Diagnostic guard: the test only proves the regression
        -- if formRegions actually produces a non-contiguous free
        -- layer. If a future change to formRegions /
        -- selectRegionKernels collapses the shape, fail loudly so
        -- the synth graph can be repaired rather than silently
        -- becoming a contiguous-shape test.
        assertBool
          ("expected at least one free layer of size > 1 with a "
           <> "trailing free layer of size 1 (non-contiguous "
           <> "ordinals); got region count " <> show regionCount
           <> ", layer sizes " <> show layerSizes)
          (any (\(a, b) -> a > 1 && b == 1)
               (zip layerSizes (drop 1 layerSizes)))
        expected <-
          case expectedScheduleStepItems scheduled steps of
            Right xs -> pure xs
            Left err -> assertFailure ("divergent: " <> err)
                        >> error "unreachable"
        -- Drive the projection through the FFI to prove the
        -- runtime stores the actual ordinal set, not a contiguous
        -- range. Compare via the per-item readout.
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          actual <- readScheduleSteps handle 0
          actual @?= expected
    ]
  where
    stepRegions (ScheduleBarrier ix)   = [ix]
    stepRegions (ScheduleFreeLayer fl) = flRegions fl
