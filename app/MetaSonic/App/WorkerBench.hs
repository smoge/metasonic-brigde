{-# LANGUAGE BangPatterns #-}

module MetaSonic.App.WorkerBench
  ( runWorkerBench
  ) where

import           Control.Exception          (evaluate)
import           Control.Monad              (forM, forM_, replicateM, when)
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
      { bcName     :: !String
      , bcLoader   :: !String
      , bcRuntime  :: !RuntimeGraph
      }
  | TemplateCase
      { bcName     :: !String
      , bcLoader   :: !String
      , bcTemplate :: !TemplateGraph
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
  } deriving (Eq, Show)

kWorkerBenchFrames :: Int
kWorkerBenchFrames = 256

kWorkerBenchWarmupBlocks :: Int
kWorkerBenchWarmupBlocks = 8

kWorkerBenchBlocks :: Int
kWorkerBenchBlocks = 32

-- Median-of-three is enough for the current negative decision
-- because the counter summary says no Haskell-loaded row enters
-- worker dispatch. Increase this before using the bench to justify
-- a positive/default-on policy.
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
  putStrLn "# note: ns_per_block includes equal output-bus readback in every mode; speedup ratios are the intended signal."
  putStrLn "# columns: case,loader,mode,ns_per_block,ns_per_sample,parallel_bands,parallel_entries,serialized_sink_bands,speedup"
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
      printf "%s,%s,%s,%.2f,%.2f,%d,%d,%d,%.2fx\n"
        (bcName c')
        (bcLoader c')
        (bmName mode)
        (brNsPerBlock result)
        (brNsPerSample result)
        (brParallelBands result)
        (brParallelEntries result)
        (brSerializedSinkBands result)
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
  putStrLn $ "# summary: cases=" <> show (length cases)
          <> ", rows=" <> show (length rows)
          <> ", worker_rows=" <> show (length workerRows)
          <> ", worker_rows_with_parallel="
          <> show (length [() | (_, _, r, _) <- workerRows
                              , brParallelBands r > 0])
          <> ", parallel_bands="
          <> show (sum [brParallelBands r | (_, _, r, _) <- rows])
          <> ", parallel_entries="
          <> show (sum [brParallelEntries r | (_, _, r, _) <- rows])
          <> ", serialized_sink_bands="
          <> show (sum [brSerializedSinkBands r | (_, _, r, _) <- rows])
          <> ", best_worker_speedup=" <> printf "%.2fx" bestWorker
          <> ", best_parallel_worker_speedup="
          <> printf "%.2fx" bestParallelWorker

workerBenchCases :: [Demo] -> Either String [BenchCase]
workerBenchCases demos = do
  demoCases <- concat <$> traverse demoCasesFor demos
  shapeCases <-
    traverse
      (\(name, graph) -> runtimeCase ("corpus:" <> name) graph)
      surveyShapeProbes
  ensembleCases <-
    traverse
      (\(name, templates) ->
          templateCase ("corpus:" <> name) templates)
      surveyEnsembleCorpus
  pure (demoCases <> shapeCases <> ensembleCases)

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
runtimeCase name graph = do
  rg <- lowerGraph graph >>= compileRuntimeGraph
  pure RuntimeCase
    { bcName    = name
    , bcLoader  = "loadRuntimeGraph"
    , bcRuntime = rg
    }

templateCase :: String -> [(String, SynthGraph)] -> Either String BenchCase
templateCase name templates = do
  tg <- compileTemplateGraph templates
  pure TemplateCase
    { bcName     = name
    , bcLoader   = "loadTemplateGraph"
    , bcTemplate = tg
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

    let nsPerBlock = fromIntegral (end - start)
                   / fromIntegral kWorkerBenchBlocks
        nsPerSample = nsPerBlock / fromIntegral kWorkerBenchFrames
    pure BenchResult
      { brNsPerBlock          = nsPerBlock
      , brNsPerSample         = nsPerSample
      , brParallelBands       = bands
      , brParallelEntries     = entries
      , brSerializedSinkBands = serialized
      }

loadCase :: Ptr RTGraph -> BenchCase -> IO ()
loadCase handle RuntimeCase{bcRuntime = rg} =
  loadRuntimeGraph handle rg
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
  in sort (nub (0 : mapMaybe idxOf (filter touchesBus (rgNodes rt))))

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
