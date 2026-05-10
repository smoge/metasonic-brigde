{-# LANGUAGE BangPatterns #-}

-- | Phase 5.3.C — Haskell-driven micro-bench of the hot-swap helper
-- path. No C++ is added by this slice; it exercises the existing
-- 'hotSwap*' / 'collectRetiredSwapStats' surface against a small fixed
-- corpus and prints a CSV-shaped row per case.
--
-- The bench is offline (no audio thread): the producer thread *is* the
-- caller of 'c_rt_graph_process', so install happens synchronously on
-- the next process call after publish. 'blocks_to_install' is therefore
-- expected to be 1 in the happy path; a higher value or a budget
-- timeout is a regression signal.
--
-- 5.3.C2 layers per-row repetition on top: each row runs
-- 'kSwapBenchRepeats' times in a fresh 'withRTGraph' handle so prior
-- runs cannot leak state into a later run's lifecycle slot or pending
-- swap. Timing is summarised as min / median / max in nanoseconds; the
-- migration counters and 'blocks_to_install' are required to be stable
-- across runs and to match each row's expected signature; the bench
-- fails loudly if either property is lost, because counters are still
-- the primary path-proof signal.
module MetaSonic.App.SwapBench
  ( runSwapBench
  ) where

import           Control.Monad              (replicateM, replicateM_, (>=>))
import           Data.List                  (sort)
import           Data.Word                  (Word64)
import           Foreign.C.Types            (CInt)
import           Foreign.Ptr                (Ptr)
import           GHC.Clock                  (getMonotonicTimeNSec)
import           Text.Printf                (printf)

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR        (lowerGraph)
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates

kSwapBenchFrames :: MaxFrames
kSwapBenchFrames = 256

-- Generous upper bound on process blocks driven after publish before
-- declaring "did not install in time." One block is the expected case
-- under the offline driver; a higher value here means the helper / C
-- runtime regressed.
kSwapBenchInstallBudget :: Int
kSwapBenchInstallBudget = 64

-- Padding added to a graph-derived node count when picking the
-- builder capacity. Matches the test-side convention so bench rows
-- size offline builders the same way the existing FFI suite does.
kSwapBenchCapacityPad :: Int
kSwapBenchCapacityPad = 4

-- Per-row repetition count. Odd so the median is the middle element
-- without averaging. 11 is large enough to expose the cold-vs-warm
-- spread (visible as min ≪ max) while keeping wall-clock overhead
-- well under a second across the corpus.
kSwapBenchRepeats :: Int
kSwapBenchRepeats = 11

data RowSetup
  = NoSetup
  | ReleaseDefaultThenWarm !Int
    -- ^ Release auto-spawned instance 0, then run N warm process
    -- blocks so the Releasing slot accumulates silence-window state
    -- before publish. Used by the lifecycle-only row.
  deriving (Eq, Show)

data SwapRow
  = RuntimeRow
      { srName     :: !String
      , srLoader   :: !String
      , srOldRG    :: !RuntimeGraph
      , srNewRG    :: !RuntimeGraph
      , srFused    :: !Bool
      , srCapacity :: !BuilderCapacity
      , srSetup    :: !RowSetup
      , srExpectedBlocks :: !Int
      , srExpectedStats  :: !SwapMigrationStats
      }
  | TemplateRow
      { srName     :: !String
      , srLoader   :: !String
      , srOldTG    :: !TemplateGraph
      , srNewTG    :: !TemplateGraph
      , srFused    :: !Bool
      , srCapacity :: !BuilderCapacity
      , srSetup    :: !RowSetup
      , srExpectedBlocks :: !Int
      , srExpectedStats  :: !SwapMigrationStats
      }

-- One per-run measurement. Aggregated into 'SwapRowSummary' before
-- printing. Successful runs have 'srPublished' True and an install
-- block index plus migration stats.
data SwapRowSample = SwapRowSample
  { ssPublished        :: !Bool
  , ssBlocksToInstall  :: !(Maybe Int)
  , ssPreparePublishNs :: !Word64
  , ssCollectNs        :: !Word64
  , ssStats            :: !(Maybe SwapMigrationStats)
  } deriving (Eq, Show)

data TimingSummary = TimingSummary
  { tsMin    :: !Word64
  , tsMedian :: !Word64
  , tsMax    :: !Word64
  } deriving (Eq, Show)

data SwapRowSummary = SwapRowSummary
  { rsName              :: !String
  , rsLoader            :: !String
  , rsCapacity          :: !Int
  , rsRuns              :: !Int
  , rsPublished         :: !Bool
  , rsBlocksMedian      :: !(Maybe Int)
  , rsPreparePublishNs  :: !TimingSummary
  , rsCollectNs         :: !TimingSummary
  , rsStats             :: !(Maybe SwapMigrationStats)
  }

runSwapBench :: IO ()
runSwapBench = do
  rows <- buildRows
  printHeader (length rows)
  mapM_ (runSwapRow >=> printResult) rows

buildRows :: IO [SwapRow]
buildRows = do
  unchanged    <- mkRuntimeRow "unchanged"      False untaggedSinOscGraph NoSetup
                    (expectedStats 0 2 0 0 1)
  taggedOsc    <- mkRuntimeRow "tagged-osc"     False (taggedSinOscGraph "voice") NoSetup
                    (expectedStats 1 1 1 1 1)
  taggedFlt    <- mkRuntimeRow "tagged-biquad"  False taggedLpfGraph NoSetup
                    (expectedStats 1 2 1 1 1)
  -- envOutGraph + release puts the auto-spawned slot into Releasing
  -- so the lifecycle-copy path sees a non-Active slot to migrate.
  -- Releasing an Env-less graph is equivalent to instance_remove and
  -- would defeat the row.
  lifecycle    <- mkRuntimeRow "lifecycle-only" False envOutGraph
                    (ReleaseDefaultThenWarm 4)
                    (expectedStats 0 2 0 0 1)
  fused        <- mkRuntimeRow "fused"          True  (taggedSinOscGraph "voice") NoSetup
                    (expectedStats 1 1 1 1 1)
  template     <- mkTemplateRow "template"      False twoVoiceTemplates NoSetup
                    (expectedStats 0 4 0 0 2)
  pure [unchanged, taggedOsc, taggedFlt, lifecycle, fused, template]

expectedStats :: Int -> Int -> Int -> Int -> Int -> SwapMigrationStats
expectedStats committed skipped instances states lifecycles =
  SwapMigrationStats
    { smsCommittedCount     = committed
    , smsSkippedCount       = skipped
    , smsInstanceCopyCount  = instances
    , smsStateCopyCount     = states
    , smsLifecycleCopyCount = lifecycles
    }

untaggedSinOscGraph :: SynthGraph
untaggedSinOscGraph = runSynth $ do
  o <- sinOsc 220.0 0.0
  out 0 o

taggedSinOscGraph :: String -> SynthGraph
taggedSinOscGraph key = runSynth $ do
  o <- tagged key (sinOsc 220.0 0.0)
  out 0 o

taggedLpfGraph :: SynthGraph
taggedLpfGraph = runSynth $ do
  src <- sinOsc 220.0 0.0
  filt <- tagged "filt" (lpf src (Param 800.0) (Param 0.7))
  out 0 filt

-- Env-driven graph used by the lifecycle-only row. Initial gate=0 +
-- short A/D/R rates mirror the C++ Releasing-lifecycle test: after
-- 'instance_release' the slot transitions to Releasing and the
-- lifecycle-copy path has a real non-Active slot to migrate.
envOutGraph :: SynthGraph
envOutGraph = runSynth $ do
  e <- env (Param 0.0) (Param 0.0005) (Param 0.001) (Param 0.0) (Param 0.001)
  out 0 e

twoVoiceTemplates :: [(String, SynthGraph)]
twoVoiceTemplates =
  [ ( "a"
    , runSynth $ do
        o <- sinOsc 220.0 0.0
        out 0 o
    )
  , ( "b"
    , runSynth $ do
        o <- sinOsc 660.0 0.0
        out 1 o
    )
  ]

mkRuntimeRow
  :: String -> Bool -> SynthGraph -> RowSetup -> SwapMigrationStats -> IO SwapRow
mkRuntimeRow name fused graph setup expected = do
  let loader = if fused then "loadRuntimeGraphFused" else "loadRuntimeGraph"
      compileFn = if fused then compileRuntimeGraphFused else compileRuntimeGraph
  rg <- compileOrFail (lowerGraph graph >>= compileFn)
  let cap = length (rgNodes rg) + kSwapBenchCapacityPad
  pure RuntimeRow
    { srName     = name
    , srLoader   = loader
    , srOldRG    = rg
    , srNewRG    = rg
    , srFused    = fused
    , srCapacity = cap
    , srSetup    = setup
    , srExpectedBlocks = 1
    , srExpectedStats  = expected
    }

mkTemplateRow
  :: String -> Bool -> [(String, SynthGraph)] -> RowSetup -> SwapMigrationStats
  -> IO SwapRow
mkTemplateRow name fused templates setup expected = do
  let loader = if fused then "loadTemplateGraphFused" else "loadTemplateGraph"
      compileFn =
        if fused then compileTemplateGraphFused else compileTemplateGraph
  tg <- compileOrFail (compileFn templates)
  let cap =
        sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
        + kSwapBenchCapacityPad
  pure TemplateRow
    { srName     = name
    , srLoader   = loader
    , srOldTG    = tg
    , srNewTG    = tg
    , srFused    = fused
    , srCapacity = cap
    , srSetup    = setup
    , srExpectedBlocks = 1
    , srExpectedStats  = expected
    }

compileOrFail :: Either String a -> IO a
compileOrFail = either (fail . ("swap-bench compile error: " <>)) pure

-- Run the row 'kSwapBenchRepeats' times with a fresh handle each time,
-- aggregate the timing samples, and assert that the path-proof signal
-- (counters + blocks_to_install) is stable and matches the row's
-- expected signature.
runSwapRow :: SwapRow -> IO SwapRowSummary
runSwapRow row = do
  samples <- replicateM kSwapBenchRepeats (runSwapRowOnce row)
  case samples of
    [] -> fail "swap-bench: kSwapBenchRepeats must be > 0"
    (first : _) -> do
      assertSamplesStable row samples
      assertSampleExpected row first
      let preps    = map ssPreparePublishNs samples
          collects = map ssCollectNs        samples
      pure SwapRowSummary
        { rsName             = srName row
        , rsLoader           = srLoader row
        , rsCapacity         = srCapacity row
        , rsRuns             = length samples
        , rsPublished        = ssPublished first
        , rsBlocksMedian     = ssBlocksToInstall first
        , rsPreparePublishNs = summarize preps
        , rsCollectNs        = summarize collects
        , rsStats            = ssStats first
        }

-- Bench correctness contract: for a fixed row, every run must publish,
-- install on the same block index, and produce identical migration
-- counters. If any of those drift across runs, that is a regression
-- signal in either the helper path or the bench setup, and we abort
-- rather than silently averaging it away.
assertSamplesStable :: SwapRow -> [SwapRowSample] -> IO ()
assertSamplesStable row samples = do
  let publishes = map ssPublished samples
      blocks    = map ssBlocksToInstall samples
      stats     = map ssStats samples
      ctx       = "row=" <> srName row
  case allEqual publishes of
    Nothing -> pure ()
    Just (a, b) ->
      fail $ "swap-bench: publish result drift in " <> ctx
          <> ": saw " <> show a <> " then " <> show b
  case allEqual blocks of
    Nothing -> pure ()
    Just (a, b) ->
      fail $ "swap-bench: blocks_to_install drift in " <> ctx
          <> ": saw " <> show a <> " then " <> show b
  case allEqual stats of
    Nothing -> pure ()
    Just (a, b) ->
      fail $ "swap-bench: migration counter drift in " <> ctx
          <> ": saw " <> show a <> " then " <> show b

-- Stability alone is not enough: a helper regression could produce the
-- same wrong counter set on every repeat. Each fixed row therefore
-- carries the expected install block and migration signature.
assertSampleExpected :: SwapRow -> SwapRowSample -> IO ()
assertSampleExpected row sample =
  case (ssPublished sample, ssBlocksToInstall sample, ssStats sample) of
    (True, Just blocks, Just stats)
      | blocks == srExpectedBlocks row && stats == srExpectedStats row ->
          pure ()
      | otherwise ->
          fail $ "swap-bench: unexpected path-proof signal in row="
              <> srName row
              <> ": expected blocks="
              <> show (srExpectedBlocks row)
              <> ", stats="
              <> show (srExpectedStats row)
              <> "; saw blocks="
              <> show blocks
              <> ", stats="
              <> show stats
    (published, blocks, stats) ->
      fail $ "swap-bench: row=" <> srName row
          <> " did not complete the expected publish/install/collect path: "
          <> "published=" <> show published
          <> ", blocks=" <> show blocks
          <> ", stats=" <> show stats

-- Returns 'Nothing' when every element is equal, or 'Just (a, b)' for
-- the first pair that disagrees.
allEqual :: Eq a => [a] -> Maybe (a, a)
allEqual []         = Nothing
allEqual (x : rest) = go rest
  where
    go []                   = Nothing
    go (y : ys) | y == x    = go ys
                | otherwise = Just (x, y)

summarize :: [Word64] -> TimingSummary
summarize [] = TimingSummary 0 0 0
summarize xs =
  let sorted = sort xs
      n      = length sorted
      lo     = firstOr 0 sorted
      mid    = firstOr 0 (drop (n `div` 2) sorted)
      hi     = lastOr 0 sorted
  in TimingSummary
       { tsMin    = lo
       , tsMedian = mid
       , tsMax    = hi
       }

firstOr :: a -> [a] -> a
firstOr fallback []      = fallback
firstOr _        (x : _) = x

lastOr :: a -> [a] -> a
lastOr fallback []       = fallback
lastOr _        (x : xs) = go x xs
  where
    go !latest []       = latest
    go _       (y : ys) = go y ys

runSwapRowOnce :: SwapRow -> IO SwapRowSample
runSwapRowOnce row =
  withRTGraph (srCapacity row) kSwapBenchFrames $ \handle -> do
    loadOldWorld handle row
    applySetup handle (srSetup row)

    beforeGen <- c_rt_graph_test_swap_generation handle

    !t0 <- getMonotonicTimeNSec
    published <- publishNew handle row
    !t1 <- getMonotonicTimeNSec
    let preparePublishNs = t1 - t0

    if not published
      then pure SwapRowSample
        { ssPublished        = False
        , ssBlocksToInstall  = Nothing
        , ssPreparePublishNs = preparePublishNs
        , ssCollectNs        = 0
        , ssStats            = Nothing
        }
      else do
        blocks <- driveUntilInstall handle beforeGen
        case blocks of
          Nothing -> pure SwapRowSample
            { ssPublished        = True
            , ssBlocksToInstall  = Nothing
            , ssPreparePublishNs = preparePublishNs
            , ssCollectNs        = 0
            , ssStats            = Nothing
            }
          Just n -> do
            !t2 <- getMonotonicTimeNSec
            stats <- collectRetiredSwapStats handle
            !t3 <- getMonotonicTimeNSec
            pure SwapRowSample
              { ssPublished        = True
              , ssBlocksToInstall  = Just n
              , ssPreparePublishNs = preparePublishNs
              , ssCollectNs        = t3 - t2
              , ssStats            = stats
              }

loadOldWorld :: Ptr RTGraph -> SwapRow -> IO ()
loadOldWorld handle RuntimeRow{srOldRG = rg, srFused = fused}
  | fused     = loadRuntimeGraphFused handle rg
  | otherwise = loadRuntimeGraph handle rg
loadOldWorld handle TemplateRow{srOldTG = tg, srFused = fused}
  | fused     = loadTemplateGraphFused handle tg
  | otherwise = loadTemplateGraph handle tg

applySetup :: Ptr RTGraph -> RowSetup -> IO ()
applySetup _ NoSetup = pure ()
applySetup handle (ReleaseDefaultThenWarm n) = do
  c_rt_graph_instance_release handle 0
  replicateM_ n (c_rt_graph_process handle (fromIntegral kSwapBenchFrames))

publishNew :: Ptr RTGraph -> SwapRow -> IO Bool
publishNew handle row@RuntimeRow{} =
  let helper =
        if srFused row
          then hotSwapRuntimeGraphFused
          else hotSwapRuntimeGraph
  in helper handle (srCapacity row) kSwapBenchFrames (srNewRG row)
publishNew handle row@TemplateRow{} =
  let helper =
        if srFused row
          then hotSwapTemplateGraphFused
          else hotSwapTemplateGraph
  in helper handle (srCapacity row) kSwapBenchFrames (srNewTG row)

-- Drive process blocks until the install-generation counter exceeds
-- the pre-publish snapshot. Returns the block index on which install
-- was observed (1 in the happy offline case) or 'Nothing' if the
-- budget was exhausted.
driveUntilInstall :: Ptr RTGraph -> CInt -> IO (Maybe Int)
driveUntilInstall handle beforeGen = go 1
  where
    go !n
      | n > kSwapBenchInstallBudget = pure Nothing
      | otherwise = do
          c_rt_graph_process handle (fromIntegral kSwapBenchFrames)
          gen <- c_rt_graph_test_swap_generation handle
          if gen > beforeGen
            then pure (Just n)
            else go (n + 1)

printHeader :: Int -> IO ()
printHeader nRows = do
  putStrLn "# metasonic swap bench: hot-swap helper micro-benchmark"
  putStrLn $ "# frames=" <> show kSwapBenchFrames
          <> ", install_budget=" <> show kSwapBenchInstallBudget
          <> ", capacity_pad=" <> show kSwapBenchCapacityPad
          <> ", repeats=" <> show kSwapBenchRepeats
          <> ", rows=" <> show nRows
  putStrLn "# note: each row runs 'repeats' times in a fresh \
           \withRTGraph handle so prior runs cannot leak lifecycle \
           \state or pending swaps into the next run."
  putStrLn "# note: counters and blocks_to_install must be stable \
           \across runs and match the row's expected signature (the \
           \path-proof signal); the bench aborts if either property \
           \is lost. Timing is reported as min / median / max over \
           \'repeats'."
  putStrLn $ "# columns: row,loader,capacity,publish,runs,"
          <> "blocks_to_install_median,prepare_publish_min_ns,"
          <> "prepare_publish_median_ns,prepare_publish_max_ns,"
          <> "collect_median_ns,committed,skipped,instance_copies,"
          <> "state_copies,lifecycle_copies"

printResult :: SwapRowSummary -> IO ()
printResult r = do
  let publishStr = if rsPublished r then "published" else "rejected"
      blocksStr  = maybe "-" show (rsBlocksMedian r)
      countStr f = case rsStats r of
        Just s  -> show (f s)
        Nothing -> "-"
      prep       = rsPreparePublishNs r
      collectMed = tsMedian (rsCollectNs r)
  printf "%s,%s,%d,%s,%d,%s,%d,%d,%d,%d,%s,%s,%s,%s,%s\n"
    (rsName r)
    (rsLoader r)
    (rsCapacity r)
    publishStr
    (rsRuns r)
    blocksStr
    (tsMin prep)
    (tsMedian prep)
    (tsMax prep)
    collectMed
    (countStr smsCommittedCount)
    (countStr smsSkippedCount)
    (countStr smsInstanceCopyCount)
    (countStr smsStateCopyCount)
    (countStr smsLifecycleCopyCount)
