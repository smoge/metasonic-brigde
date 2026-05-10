{-# LANGUAGE BangPatterns #-}

-- | Phase 5.3.C1 — Haskell-driven micro-bench of the hot-swap helper
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
-- 5.3.C2 will layer repetition / statistics on top; this slice keeps
-- one prepare+publish per row so the reported counters and the audio
-- thread's install pass are unambiguously paired.
module MetaSonic.App.SwapBench
  ( runSwapBench
  ) where

import           Control.Monad              (replicateM_, (>=>))
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
      }
  | TemplateRow
      { srName     :: !String
      , srLoader   :: !String
      , srOldTG    :: !TemplateGraph
      , srNewTG    :: !TemplateGraph
      , srFused    :: !Bool
      , srCapacity :: !BuilderCapacity
      , srSetup    :: !RowSetup
      }

data SwapRowResult = SwapRowResult
  { rrName             :: !String
  , rrLoader           :: !String
  , rrCapacity         :: !Int
  , rrPublished        :: !Bool
  , rrBlocksToInstall  :: !(Maybe Int)
  , rrPreparePublishNs :: !Word64
  , rrCollectNs        :: !Word64
  , rrStats            :: !(Maybe SwapMigrationStats)
  }

runSwapBench :: IO ()
runSwapBench = do
  rows <- buildRows
  printHeader (length rows)
  mapM_ (runSwapRow >=> printResult) rows

buildRows :: IO [SwapRow]
buildRows = do
  unchanged    <- mkRuntimeRow "unchanged"      False untaggedSinOscGraph NoSetup
  taggedOsc    <- mkRuntimeRow "tagged-osc"     False (taggedSinOscGraph "voice") NoSetup
  taggedFlt    <- mkRuntimeRow "tagged-biquad"  False taggedLpfGraph NoSetup
  -- envOutGraph + release puts the auto-spawned slot into Releasing
  -- so the lifecycle-copy path sees a non-Active slot to migrate.
  -- Releasing an Env-less graph is equivalent to instance_remove and
  -- would defeat the row.
  lifecycle    <- mkRuntimeRow "lifecycle-only" False envOutGraph
                    (ReleaseDefaultThenWarm 4)
  fused        <- mkRuntimeRow "fused"          True  (taggedSinOscGraph "voice") NoSetup
  template     <- mkTemplateRow "template"      False twoVoiceTemplates NoSetup
  pure [unchanged, taggedOsc, taggedFlt, lifecycle, fused, template]

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
  :: String -> Bool -> SynthGraph -> RowSetup -> IO SwapRow
mkRuntimeRow name fused graph setup = do
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
    }

mkTemplateRow
  :: String -> Bool -> [(String, SynthGraph)] -> RowSetup -> IO SwapRow
mkTemplateRow name fused templates setup = do
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
    }

compileOrFail :: Either String a -> IO a
compileOrFail = either (fail . ("swap-bench compile error: " <>)) pure

runSwapRow :: SwapRow -> IO SwapRowResult
runSwapRow row =
  withRTGraph (srCapacity row) kSwapBenchFrames $ \handle -> do
    loadOldWorld handle row
    applySetup handle (srSetup row)

    beforeGen <- c_rt_graph_test_swap_generation handle

    !t0 <- getMonotonicTimeNSec
    published <- publishNew handle row
    !t1 <- getMonotonicTimeNSec
    let preparePublishNs = t1 - t0

    if not published
      then pure (failedPublishResult row preparePublishNs)
      else do
        blocks <- driveUntilInstall handle beforeGen
        case blocks of
          Nothing ->
            pure (timedOutInstallResult row preparePublishNs)
          Just n -> do
            !t2 <- getMonotonicTimeNSec
            stats <- collectRetiredSwapStats handle
            !t3 <- getMonotonicTimeNSec
            pure SwapRowResult
              { rrName             = srName row
              , rrLoader           = srLoader row
              , rrCapacity         = srCapacity row
              , rrPublished        = True
              , rrBlocksToInstall  = Just n
              , rrPreparePublishNs = preparePublishNs
              , rrCollectNs        = t3 - t2
              , rrStats            = stats
              }

failedPublishResult :: SwapRow -> Word64 -> SwapRowResult
failedPublishResult row preparePublishNs = SwapRowResult
  { rrName             = srName row
  , rrLoader           = srLoader row
  , rrCapacity         = srCapacity row
  , rrPublished        = False
  , rrBlocksToInstall  = Nothing
  , rrPreparePublishNs = preparePublishNs
  , rrCollectNs        = 0
  , rrStats            = Nothing
  }

timedOutInstallResult :: SwapRow -> Word64 -> SwapRowResult
timedOutInstallResult row preparePublishNs = SwapRowResult
  { rrName             = srName row
  , rrLoader           = srLoader row
  , rrCapacity         = srCapacity row
  , rrPublished        = True
  , rrBlocksToInstall  = Nothing
  , rrPreparePublishNs = preparePublishNs
  , rrCollectNs        = 0
  , rrStats            = Nothing
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
          <> ", rows=" <> show nRows
  putStrLn "# note: blocks_to_install is the number of process blocks \
           \driven after publish until the install-generation counter \
           \advances; under the offline driver one block is the \
           \expected value."
  putStrLn "# note: counter columns show '-' when no swap was \
           \collected (publish rejected or install budget exceeded)."
  putStrLn $ "# columns: row,loader,capacity,publish,blocks_to_install,"
          <> "prepare_publish_ns,collect_ns,committed,skipped,"
          <> "instance_copies,state_copies,lifecycle_copies"

printResult :: SwapRowResult -> IO ()
printResult r = do
  let publishStr = if rrPublished r then "published" else "rejected"
      blocksStr  = maybe "-" show (rrBlocksToInstall r)
      countStr f = case rrStats r of
        Just s  -> show (f s)
        Nothing -> "-"
  printf "%s,%s,%d,%s,%s,%d,%d,%s,%s,%s,%s,%s\n"
    (rrName r)
    (rrLoader r)
    (rrCapacity r)
    publishStr
    blocksStr
    (rrPreparePublishNs r)
    (rrCollectNs r)
    (countStr smsCommittedCount)
    (countStr smsSkippedCount)
    (countStr smsInstanceCopyCount)
    (countStr smsStateCopyCount)
    (countStr smsLifecycleCopyCount)
