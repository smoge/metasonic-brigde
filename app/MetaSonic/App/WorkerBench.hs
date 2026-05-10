{-# LANGUAGE BangPatterns #-}

module MetaSonic.App.WorkerBench
  ( runWorkerBench
  ) where

import           Control.Exception          (evaluate)
import           Control.Monad              (forM, forM_, replicateM,
                                             replicateM_, when)
import           Data.List                  (nub, sort, sortOn)
import           Data.Maybe                 (mapMaybe)
import           Foreign                    (allocaArray, castPtr, peekArray)
import           Foreign.C.Types            (CFloat (..))
import           Foreign.Ptr                (Ptr)
import           GHC.Clock                  (getMonotonicTimeNSec)
import           Text.Printf                (printf)

import           MetaSonic.App.Demos
import           MetaSonic.App.Survey       (surveyEnsembleCorpus,
                                             surveyShapeProbes)
import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR        (lowerGraph)
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Types            (NodeKind (..))

data BenchCase
  = RuntimeCase
      { bcName           :: !String
      , bcLoader         :: !String
      , bcRuntime        :: !RuntimeGraph
      , bcExtraInstances :: !Int
      }
  | TemplateCase
      { bcName           :: !String
      , bcLoader         :: !String
      , bcTemplate       :: !TemplateGraph
      , bcExtraInstances :: !Int
      }

data BenchMode = BenchMode
  { bmName       :: !String
  , bmSchedule   :: !Bool
  , bmReduction  :: !Bool
  , bmWorkerPool :: !Int
  }

data BenchResult = BenchResult
  { brNsPerBlock          :: !Double
  , brNsPerSample         :: !Double
  , brParallelBands       :: !Int
  , brParallelEntries     :: !Int
  , brSerializedSinkBands :: !Int
  , brC1dParallelEntries  :: !Int
  , brC1dParallelItems    :: !Int
  } deriving (Eq, Show)

kWorkerBenchFrames :: Int
kWorkerBenchFrames = 256

kWorkerBenchWarmupBlocks :: Int
kWorkerBenchWarmupBlocks = 8

kWorkerBenchBlocks :: Int
kWorkerBenchBlocks = 32

-- Median-of-three is enough for the current negative/default-off
-- decision because the counter summary is the primary signal. Increase
-- this before using the bench to justify a positive/default-on policy.
kWorkerBenchRepeats :: Int
kWorkerBenchRepeats = 3

kWorkerBenchModes :: [BenchMode]
kWorkerBenchModes =
  -- legacy-direct must remain first: the speedup column is computed
  -- against the first mode's ns/block result for each case.
  [ BenchMode "legacy-direct"       False False 0
  , BenchMode "sched-serial-direct" True  False 1
  , BenchMode "sched-pool3-direct"  True  False 3
  , BenchMode "sched-pool3-reduce"  True  True  3
  ]

runWorkerBench :: [Demo] -> IO ()
runWorkerBench demos = do
  cases <- either fail pure (workerBenchCases demos)
  putStrLn "# metasonic worker bench: Haskell-loaded schedule corpus"
  putStrLn $ "# frames=" <> show kWorkerBenchFrames
          <> ", warmup_blocks=" <> show kWorkerBenchWarmupBlocks
          <> ", blocks=" <> show kWorkerBenchBlocks
          <> ", repeat_runs=" <> show kWorkerBenchRepeats
  putStrLn $ "# note: ns_per_block includes equal output-bus readback "
          <> "in every mode for graphs that touch buses; bus-less "
          <> "compute probes read no buses."
  putStrLn $ "# note: parallel_bands / parallel_entries / "
          <> "serialized_sink_bands / c1d_parallel_entries / "
          <> "c1d_parallel_items are last-processed-block "
          <> "representative counters (the runtime overwrites them "
          <> "every rt_graph_process call); they are not totals over "
          <> "the timed run, and the summary's cumulative counters "
          <> "sum only the last-block snapshot from each row."
  putStrLn $ "# columns: case,loader,mode,ns_per_block,ns_per_sample,"
          <> "parallel_bands,parallel_entries,serialized_sink_bands,"
          <> "c1d_parallel_entries,c1d_parallel_items,speedup"
  rows <- concat <$> forM cases (\c -> do
    results <- forM kWorkerBenchModes $ \mode -> do
      result <- runBenchMode c mode
      pure (mode, result)
    let baseline = case results of
          ((_, firstResult) : _) -> brNsPerBlock firstResult
          []                     -> 0.0
        rendered =
          [ (c, mode, result, if brNsPerBlock result > 0
                                then baseline / brNsPerBlock result
                                else 0.0)
          | (mode, result) <- results
          ]
    forM_ rendered $ \(c', mode, result, speedup) -> do
      printf "%s,%s,%s,%.2f,%.2f,%d,%d,%d,%d,%d,%.2fx\n"
        (bcName c')
        (bcLoader c')
        (bmName mode)
        (brNsPerBlock result)
        (brNsPerSample result)
        (brParallelBands result)
        (brParallelEntries result)
        (brSerializedSinkBands result)
        (brC1dParallelEntries result)
        (brC1dParallelItems result)
        speedup
    pure rendered)
  let workerRows = [row | row@(_, mode, _, _) <- rows, bmWorkerPool mode > 1]
      bestWorker = maximumOr0 [speedup | (_, _, _, speedup) <- workerRows]
      bestParallelWorker =
        maximumOr0
          [ speedup
          | (_, _, result, speedup) <- workerRows
          , brParallelBands result > 0
          ]
      -- Pure C1d-c row predicate: no C1c band-level dispatch in this
      -- block, only region-item dispatch. Mixed rows (parallel_bands
      -- > 0 and c1d_parallel_entries > 0) would attribute a C1c
      -- speedup to C1d-c if filtered on the C1d counter alone.
      -- Today's corpus has no mixed rows; the predicate keeps the
      -- summary honest if one is added later.
      isPureC1dRow result =
        brParallelBands result == 0 && brC1dParallelEntries result > 0
      bestC1dWorker =
        maximumOr0
          [ speedup
          | (_, _, result, speedup) <- workerRows
          , isPureC1dRow result
          ]
  -- The cumulative `parallel_*` and `c1d_parallel_*` totals below sum
  -- last-block snapshots across every row, including any future row
  -- whose representative snapshot has both C1c and C1d-c activity.
  -- Those totals describe overall dispatch *activity*. The
  -- `worker_rows_with_*` counts and the `best_*` speedups instead use
  -- attribution-safe predicates (`brParallelBands > 0` for C1c,
  -- `isPureC1dRow` for C1d-c) so a mixed row never lets a C1c speedup
  -- be reported as a C1d-c win. Today's corpus has no mixed rows;
  -- both views agree numerically. They are intentionally distinct
  -- concepts and the names should be read as such.
  putStrLn $ "# summary: cases=" <> show (length cases)
          <> ", rows=" <> show (length rows)
          <> ", worker_rows=" <> show (length workerRows)
          <> ", worker_rows_with_parallel="
          <> show (length [() | (_, _, r, _) <- workerRows
                              , brParallelBands r > 0])
          <> ", worker_rows_with_c1d_parallel="
          <> show (length [() | (_, _, r, _) <- workerRows
                              , isPureC1dRow r])
          <> ", parallel_bands="
          <> show (sum [brParallelBands r | (_, _, r, _) <- rows])
          <> ", parallel_entries="
          <> show (sum [brParallelEntries r | (_, _, r, _) <- rows])
          <> ", serialized_sink_bands="
          <> show (sum [brSerializedSinkBands r | (_, _, r, _) <- rows])
          <> ", c1d_parallel_entries="
          <> show (sum [brC1dParallelEntries r | (_, _, r, _) <- rows])
          <> ", c1d_parallel_items="
          <> show (sum [brC1dParallelItems r | (_, _, r, _) <- rows])
          <> ", best_worker_speedup=" <> printf "%.2fx" bestWorker
          <> ", best_parallel_worker_speedup="
          <> printf "%.2fx" bestParallelWorker
          <> ", best_c1d_worker_speedup="
          <> printf "%.2fx" bestC1dWorker

workerBenchCases :: [Demo] -> Either String [BenchCase]
workerBenchCases demos = do
  demoCases <- concat <$> traverse demoCasesFor demos
  shapeCases <-
    traverse
      (\(name, graph) ->
          runtimeCaseWithInstances
            ("corpus:" <> name)
            (workerBenchExtraInstances name)
            graph)
      surveyShapeProbes
  ensembleCases <-
    traverse
      (\(name, templates) ->
          templateCase ("corpus:" <> name) templates)
      surveyEnsembleCorpus
  pure (demoCases <> shapeCases <> ensembleCases)

workerBenchExtraInstances :: String -> Int
workerBenchExtraInstances "sched/free-only-parallel-compute" = 2
workerBenchExtraInstances _                                  = 0

demoCasesFor :: Demo -> Either String [BenchCase]
demoCasesFor demo = case demoBody demo of
  SingleGraph graph ->
    (: []) <$> runtimeCase ("demo:" <> demoKey demo) graph
  MultiTemplate templates ->
    (: []) <$> templateCase ("demo:" <> demoKey demo) templates
  MidiPoly _ build ->
    let (_bindings, graph, _ccs) = runSynthCCs build
    in (: []) <$> runtimeCase ("demo:" <> demoKey demo) graph

runtimeCase :: String -> SynthGraph -> Either String BenchCase
runtimeCase name =
  runtimeCaseWithInstances name 0

runtimeCaseWithInstances :: String -> Int -> SynthGraph -> Either String BenchCase
runtimeCaseWithInstances name extra graph = do
  rg <- lowerGraph graph >>= compileRuntimeGraph
  pure RuntimeCase
    { bcName           = name
    , bcLoader         = "loadRuntimeGraph"
    , bcRuntime        = rg
    , bcExtraInstances = max 0 extra
    }

templateCase :: String -> [(String, SynthGraph)] -> Either String BenchCase
templateCase name templates = do
  tg <- compileTemplateGraph templates
  pure TemplateCase
    { bcName           = name
    , bcLoader         = "loadTemplateGraph"
    , bcTemplate       = tg
    , bcExtraInstances = 0
    }

runBenchMode :: BenchCase -> BenchMode -> IO BenchResult
runBenchMode c mode = do
  results <- replicateM kWorkerBenchRepeats (runBenchOnce c mode)
  pure (medianBy brNsPerBlock results)

runBenchOnce :: BenchCase -> BenchMode -> IO BenchResult
runBenchOnce c mode =
  withRTGraph (benchCapacity c) kWorkerBenchFrames $ \handle -> do
    loadCase handle c
    when (bmWorkerPool mode > 0) $
      c_rt_graph_test_set_worker_pool_size
        handle (fromIntegral (bmWorkerPool mode))
    when (bmReduction mode) $
      c_rt_graph_test_set_reduction_capture handle 1
    when (bmSchedule mode) $
      c_rt_graph_test_set_global_schedule_execution handle 1

    let buses = caseBuses c
    _warmupSink <- runBlocks handle kWorkerBenchWarmupBlocks buses
    start <- getMonotonicTimeNSec
    !sink <- runBlocks handle kWorkerBenchBlocks buses
    end <- getMonotonicTimeNSec
    _ <- evaluate sink

    bands <- fromIntegral <$> c_rt_graph_test_last_parallel_band_count handle
    entries <- fromIntegral <$> c_rt_graph_test_last_parallel_entry_count handle
    serialized <- fromIntegral <$>
      c_rt_graph_test_last_serialized_free_band_count handle
    c1dEntries <- fromIntegral <$>
      c_rt_graph_test_last_c1d_parallel_entry_count handle
    c1dItems <- fromIntegral <$>
      c_rt_graph_test_last_c1d_parallel_region_item_count handle

    let nsPerBlock = fromIntegral (end - start)
                   / fromIntegral kWorkerBenchBlocks
        nsPerSample = nsPerBlock / fromIntegral kWorkerBenchFrames
    pure BenchResult
      { brNsPerBlock          = nsPerBlock
      , brNsPerSample         = nsPerSample
      , brParallelBands       = bands
      , brParallelEntries     = entries
      , brSerializedSinkBands = serialized
      , brC1dParallelEntries  = c1dEntries
      , brC1dParallelItems    = c1dItems
      }

loadCase :: Ptr RTGraph -> BenchCase -> IO ()
loadCase handle RuntimeCase{ bcName = name
                           , bcRuntime = rg
                           , bcExtraInstances = extra
                           } = do
  loadRuntimeGraph handle rg
  replicateM_ extra $ do
    slot <- c_rt_graph_template_instance_add handle 0
    when (slot < 0) $
      fail $ "worker bench: failed to add extra instance for " <> name
loadCase handle TemplateCase{bcTemplate = tg} =
  loadTemplateGraph handle tg

benchCapacity :: BenchCase -> Int
benchCapacity RuntimeCase{bcRuntime = rg} =
  max 1 (length (rgNodes rg))
benchCapacity TemplateCase{bcTemplate = tg} =
  max 1 (sum (map (length . rgNodes . tplGraph) (tgTemplates tg)))

caseBuses :: BenchCase -> [Int]
caseBuses RuntimeCase{bcRuntime = rg} =
  relevantBuses rg
caseBuses TemplateCase{bcTemplate = tg} =
  sort (nub (concatMap (relevantBuses . tplGraph) (tgTemplates tg)))

-- Note [relevantBuses duplication]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- This mirrors the T-9 helper in test/Spec.hs. Keeping the copy local
-- avoids broadening the library API for a bench-only concern, but if the
-- runtime bus-kind contract changes, update both places together.
relevantBuses :: RuntimeGraph -> [Int]
relevantBuses rt =
  let touchesBus n = case rnKind n of
        KOut          -> True
        KBusOut       -> True
        KBusIn        -> True
        KBusInDelayed -> True
        _             -> False
      idxOf n = case rnControls n of
        (b : _) ->
          let i = truncate b :: Int
          in if i >= 0 then Just i else Nothing
        [] -> Nothing
      buses = mapMaybe idxOf (filter touchesBus (rgNodes rt))
  in if null buses then [] else sort (nub (0 : buses))

runBlocks :: Ptr RTGraph -> Int -> [Int] -> IO Double
runBlocks handle blocks buses =
  go blocks 0.0
  where
    go 0 !acc = pure acc
    go n !acc = do
      c_rt_graph_process handle (fromIntegral kWorkerBenchFrames)
      blockSum <- sum <$> traverse (readBusSum handle) buses
      go (n - 1) (acc + blockSum)

readBusSum :: Ptr RTGraph -> Int -> IO Double
readBusSum handle bus =
  allocaArray kWorkerBenchFrames $ \buf -> do
    n <- c_rt_graph_read_bus handle (fromIntegral bus)
                             (fromIntegral kWorkerBenchFrames)
                             (castPtr buf)
    when (fromIntegral n /= kWorkerBenchFrames) $
      fail $ "worker bench: short read on bus " <> show bus
          <> ": got " <> show n
          <> ", expected " <> show kWorkerBenchFrames
    samples <- peekArray kWorkerBenchFrames (buf :: Ptr CFloat)
    pure (sum [realToFrac x | CFloat x <- samples])

medianBy :: Ord b => (a -> b) -> [a] -> a
medianBy key xs =
  let sorted = sortOn key xs
  in sorted !! (length sorted `div` 2)

maximumOr0 :: [Double] -> Double
maximumOr0 [] = 0.0
maximumOr0 xs = maximum xs
