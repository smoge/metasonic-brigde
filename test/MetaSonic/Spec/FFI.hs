{-# LANGUAGE LambdaCase #-}

-- | End-to-end FFI, render-equivalence, and runtime schedule tests.
module MetaSonic.Spec.FFI where

import           Data.List                 (nub, sort)
import           Control.Monad             (forM, forM_, when)
import           Data.Maybe                (mapMaybe)
import           Foreign.C.Types           (CFloat (..), CInt)
import           Foreign.Marshal.Alloc     (allocaBytes)
import           Foreign.Marshal.Array     (peekArray)
import           Foreign.Ptr               (Ptr, castPtr)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Types
import           MetaSonic.Spec.CoreShared

crossCuttingTests :: TestTree
crossCuttingTests = testGroup "End-to-end FFI"
  [ testCase "SinOsc(440) round-trips through FFI to audible sin samples" $ do
      let nframes :: Int
          nframes  = 256
          sampleRate :: Double
          sampleRate = 48000.0
          tau :: Double
          tau = 2.0 * pi

          graph = runSynth $ do
            o <- sinOsc 440.0 0.0
            out 0 o

      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          wrote <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                       (castPtr buf)
          fromIntegral wrote @?= nframes
          cs <- peekArray nframes (buf :: PtrCFloat)
          let samples = map (\(CFloat x) -> x) cs

          let peak = maximum (map abs samples)
          assertBool ("peak ≈ 1, got " <> show peak)
                     (abs (peak - 1.0) < 0.05)
          assertBool ("sample 0 ≈ 0, got " <> show (head samples))
                     (abs (head samples) < 0.02)

          mapM_ (checkAt sampleRate tau samples) [25, 50, 100, 200]

  , testCase "Gain(SinOsc, 0.5) round-trips with halved peak" $ do
      let nframes = 256
          graph = runSynth $ do
            o <- sinOsc 440.0 0.0
            g <- gain o 0.5
            out 0 g

      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          let peak = maximum (map (\(CFloat x) -> abs x) cs)
          assertBool ("expected peak ≈ 0.5, got " <> show peak)
                     (abs (peak - 0.5) < 0.05)

  , testCase "Env(gate=1, A=0.5ms, D=2ms, S=0.5, R=10ms) attacks then decays to sustain" $ do
      -- 1024 frames at 48 kHz ≈ 21 ms. With A=0.5ms + D=2ms the envelope
      -- should reach near-1 in attack and settle near 0.5 in sustain
      -- before the block ends. Gate held high via Param 1.0.
      let nframes = 1024
          graph = runSynth $ do
            e <- env (Param 1.0) (Param 0.0005) (Param 0.002) (Param 0.5) (Param 0.01)
            out 0 e

      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          let samples = map (\(CFloat x) -> x) cs
              peak    = maximum samples
              tailAvg = sum (drop 900 samples) / fromIntegral (nframes - 900)
          assertBool ("attack peak should reach near 1, got " <> show peak)
                     (peak > 0.9)
          assertBool ("sustain tail should sit near 0.5, got avg " <> show tailAvg)
                     (abs (tailAvg - 0.5) < 0.1)

  , testCase "rendering 2×N frames matches one 2N block (state continuity across blocks)" $ do
      -- Two consecutive blocks of N frames must produce the same samples
      -- as a single 2N-frame render. This pins the runtime's per-block
      -- state continuity (oscillator phase, LPF state, future bus
      -- snapshots) end-to-end. It is the precondition for any work that
      -- extends across-block semantics — Phase 2's BusInDelayed in
      -- particular — so a regression here would invalidate that work
      -- before it starts.
      --
      -- The graph mixes a SinOsc (phase state), an LPF (filter state)
      -- and a BusOut/BusIn round-trip (bus pool state). If any of
      -- those were reset at block boundaries, the two halves wouldn't
      -- splice cleanly into the single block.
      let nhalf     = 128
          nfull     = 2 * nhalf
          maxFrames = nfull
          graph     = runSynth $ do
            o      <- sinOsc 440.0 0.0
            busOut 5 o
            tap    <- busIn 5
            filt   <- lpf tap 800.0 0.7
            out 0 filt
      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      let renderN handle n = allocaBytes (n * sizeOfFloat) $ \buf -> do
            c_rt_graph_process handle (fromIntegral n)
            _  <- c_rt_graph_read_bus handle 0 (fromIntegral n) (castPtr buf)
            cs <- peekArray n (buf :: PtrCFloat)
            pure (map (\(CFloat x) -> x) cs)

      full <- withRTGraph (length (rgNodes rt)) maxFrames $ \handle -> do
        loadRuntimeGraph handle rt
        renderN handle nfull

      halves <- withRTGraph (length (rgNodes rt)) maxFrames $ \handle -> do
        loadRuntimeGraph handle rt
        h1 <- renderN handle nhalf
        h2 <- renderN handle nhalf
        pure (h1 ++ h2)

      length full @?= nfull
      length halves @?= nfull
      let maxDiff = maximum (zipWith (\a b -> abs (a - b)) full halves)
      assertBool
        ("expected bit-equivalent samples, max diff = " <> show maxDiff)
        (maxDiff < 1e-5)

  ]
  where
    sizeOfFloat = 4 :: Int

    checkAt sr tau samples i = do
      let n        = fromIntegral i :: Double
          t        = n / sr
          expected = sin (tau * 440.0 * t)
          actual   = realToFrac (samples !! i) :: Double
      assertBool
        ("sample " <> show i <> " expected " <> show expected
         <> ", got " <> show actual)
        (abs (actual - expected) < 0.05)

-- | Force every region in a 'RuntimeGraph' back to 'RNodeLoop'.
-- 'compileRuntimeGraph' runs 'selectRegionKernels' unconditionally,
-- so the "unfused" output of 'compileRuntimeGraph' already carries
-- §4.B kernel tags. Without stripping them, an equivalence test
-- that renders @compileRuntimeGraph@ vs @compileRuntimeGraphFused@
-- would dispatch /both/ sides through 'process_region_*', and a
-- broken kernel implementation could pass by matching itself.
-- Stripping the baseline gives an honest comparison: the baseline
-- takes the per-node dispatch path while the fused side exercises
-- whichever kernels and rewrites §4.B / §4.C selected.
stripRegionKernels :: RuntimeGraph -> RuntimeGraph
stripRegionKernels rg = rg
  { rgRuntimeRegions =
      map (\r -> r { rrExec = ExecNodeLoop }) (rgRuntimeRegions rg)
  }

------------------------------------------------------------
-- T-9: direct ≡ reduction equivalence (Phase §4.E.2.B3)
------------------------------------------------------------
--
-- The headline gate from notes/2026-05-08-b-deterministic-bus-reduction-design.md.
-- For every shape in t9CorpusGraphs / t9CorpusTemplates, render N
-- blocks in direct mode and N blocks in reduction-capture mode
-- (which folds slots back into output_buses on every sink-producing
-- step) and assert byte-identical bus 0 samples per block. Coverage:
--
--   * Single-template, unfused loader  (loadRuntimeGraph)
--   * Single-template, fused   loader  (loadRuntimeGraphFused)
--   * Multi-template send/return live  (loadTemplateGraph / Fused)
--   * Multi-template send/return delayed (BusInDelayed via the
--     block-end swap)
--   * Multi-template 3-stage chain (transitive cross-template flow)
--
-- Per-block exact equality (==) is the gate; any IEEE drift fails.
-- The corpus mirrors the pure-render shapes from app/Main.hs's
-- demoTable and adds the cross-template cases compileTemplateGraph
-- exercises; together they cover every kernel that holds a
-- SinkAccumulator or routes through process_out today.

-- Demos that exist in app/Main.hs but not in 'demoGraphs' above.
-- Mirrored here so the T-9 corpus matches the runtime audio path.
noiseGraph :: SynthGraph
noiseGraph = runSynth $ do
  n <- noiseGen
  g <- gain n 0.15
  out 0 g

filteredSawGraph :: SynthGraph
filteredSawGraph = runSynth $ do
  osc <- sawOsc 110.0 0.0
  f   <- lpf osc 1200.0 1.5
  g   <- gain f 0.6
  out 0 g

detunedSawGraph :: SynthGraph
detunedSawGraph = runSynth $ do
  osc1 <- sawOsc 220.0 0.0
  osc2 <- sawOsc 220.5 0.5     -- phase offset avoids cancellation
  g1   <- gain osc1 0.3
  g2   <- gain osc2 0.3
  out 0 g1
  out 0 g2                     -- two writers on bus 0; reduction mode
                               -- must keep them in distinct slots and
                               -- fold in canonical order.

envPluckGraph :: SynthGraph
envPluckGraph = runSynth $ do
  e     <- env 1.0 0.005 0.2 0.0 0.1
  tone  <- sinOsc 220.0 0.0
  amped <- gain tone e
  scale <- gain amped 0.5
  out 0 scale

intermodGraph :: SynthGraph
intermodGraph = runSynth $ do
  lfo1   <- triOsc 0.7 0.0
  lfo1s  <- gain lfo1 0.35
  width  <- add  lfo1s 0.5
  lfo2   <- sinOsc 0.3 0.0
  lfo2s  <- gain lfo2 800.0
  cutoff <- add  lfo2s 1200.0
  voice  <- pulseOsc 220.0 0.0 width
  filt   <- bpf voice cutoff 4.0
  master <- gain filt 0.4
  out 0 master

t9CorpusGraphs :: [(String, SynthGraph)]
t9CorpusGraphs = demoGraphs ++
  [ ("noise",        noiseGraph)
  , ("filtered-saw", filteredSawGraph)
  , ("detuned-saw",  detunedSawGraph)
  , ("env-pluck",    envPluckGraph)
  , ("intermod",     intermodGraph)
  ]

-- Multi-template corpus: the canonical send/return shapes the
-- compileTemplateGraph tests already exercise in their precedence
-- form. T-9 runs them through loadTemplateGraph / loadTemplateGraphFused
-- under both modes and asserts bit-identical output.
sendReturnLiveTG :: TemplateGraph
sendReturnLiveTG =
  let producer = runSynth $ do
        o <- sinOsc 440.0 0.0
        busOut 5 o
      consumer = runSynth $ do
        t <- busIn 5
        out 0 t
  in case compileTemplateGraph
            [("producer", producer), ("consumer", consumer)] of
       Right tg  -> tg
       Left  err -> error ("sendReturnLiveTG: " <> err)

sendReturnDelayedTG :: TemplateGraph
sendReturnDelayedTG =
  let producer = runSynth $ do
        o <- sawOsc 220.0 0.0
        g <- gain o 0.5
        busOut 6 g
      consumer = runSynth $ do
        t <- busInDelayed 6
        out 0 t
  in case compileTemplateGraph
            [("producer", producer), ("consumer", consumer)] of
       Right tg  -> tg
       Left  err -> error ("sendReturnDelayedTG: " <> err)

threeTemplateChainTG :: TemplateGraph
threeTemplateChainTG =
  let a = runSynth $ do
        o <- sinOsc 330.0 0.0
        busOut 5 o
      b = runSynth $ do
        s <- busIn 5
        g <- gain s 0.5
        busOut 7 g
      c = runSynth $ do
        t <- busIn 7
        out 0 t
  in case compileTemplateGraph [("a", a), ("b", b), ("c", c)] of
       Right tg  -> tg
       Left  err -> error ("threeTemplateChainTG: " <> err)

t9CorpusTemplates :: [(String, TemplateGraph)]
t9CorpusTemplates =
  [ ("send-return-live",    sendReturnLiveTG)
  , ("send-return-delayed", sendReturnDelayedTG)
  , ("three-template-chain", threeTemplateChainTG)
  ]

-- Render @blocks@ blocks of @nframes@ frames each, returning a
-- list of (bus, samples) pairs per block — one pair per bus in the
-- supplied bus list, in the same order. Optionally enables
-- reduction-capture mode for the whole render. The capture switch
-- flips the runtime to fold slot contributions back into
-- output_buses on every sink step, but the externally visible bus
-- values must remain byte-identical to the direct path on every
-- relevant bus — that's what T-9 verifies.
renderBlocksRG :: (Ptr RTGraph -> RuntimeGraph -> IO ())
               -> RuntimeGraph
               -> Bool   -- reduction-capture on?
               -> Int    -- nframes per block
               -> Int    -- block count
               -> [Int]  -- buses to read each block
               -> IO [[(Int, [Float])]]
renderBlocksRG loader rt reduction nframes blocks buses =
  renderBlocksRGWithFlags loader rt reduction False nframes blocks buses

renderBlocksRGWithFlags :: (Ptr RTGraph -> RuntimeGraph -> IO ())
                        -> RuntimeGraph
                        -> Bool   -- reduction-capture on?
                        -> Bool   -- schedule executor on?
                        -> Int
                        -> Int
                        -> [Int]
                        -> IO [[(Int, [Float])]]
renderBlocksRGWithFlags loader rt reduction scheduleExec nframes blocks buses =
  renderBlocksRGWithWorkerPool
    loader rt reduction scheduleExec 0 nframes blocks buses

renderBlocksRGWithWorkerPool :: (Ptr RTGraph -> RuntimeGraph -> IO ())
                             -> RuntimeGraph
                             -> Bool   -- reduction-capture on?
                             -> Bool   -- schedule executor on?
                             -> Int    -- logical worker-pool size
                             -> Int
                             -> Int
                             -> [Int]
                             -> IO [[(Int, [Float])]]
renderBlocksRGWithWorkerPool
    loader rt reduction scheduleExec workerPool nframes blocks buses =
  withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
    loader handle rt
    when (workerPool > 0) $
      c_rt_graph_test_set_worker_pool_size handle (fromIntegral workerPool)
    when reduction $
      c_rt_graph_test_set_reduction_capture handle 1
    when scheduleExec $
      c_rt_graph_test_set_global_schedule_execution handle 1
    forM [1 .. blocks] $ \_ -> processAndReadBuses handle nframes buses

renderBlocksTG :: (Ptr RTGraph -> TemplateGraph -> IO ())
               -> TemplateGraph
               -> Bool
               -> Int
               -> Int
               -> [Int]
               -> IO [[(Int, [Float])]]
renderBlocksTG loader tg reduction nframes blocks buses =
  renderBlocksTGWithFlags loader tg reduction False nframes blocks buses

renderBlocksTGWithFlags :: (Ptr RTGraph -> TemplateGraph -> IO ())
                        -> TemplateGraph
                        -> Bool
                        -> Bool
                        -> Int
                        -> Int
                        -> [Int]
                        -> IO [[(Int, [Float])]]
renderBlocksTGWithFlags loader tg reduction scheduleExec nframes blocks buses =
  renderBlocksTGWithWorkerPool
    loader tg reduction scheduleExec 0 nframes blocks buses

renderBlocksTGWithWorkerPool :: (Ptr RTGraph -> TemplateGraph -> IO ())
                             -> TemplateGraph
                             -> Bool   -- reduction-capture on?
                             -> Bool   -- schedule executor on?
                             -> Int    -- logical worker-pool size
                             -> Int
                             -> Int
                             -> [Int]
                             -> IO [[(Int, [Float])]]
renderBlocksTGWithWorkerPool
    loader tg reduction scheduleExec workerPool nframes blocks buses =
  let totalNodes = sum (map (length . rgNodes . tplGraph)
                            (tgTemplates tg))
  in withRTGraph totalNodes nframes $ \handle -> do
       loader handle tg
       when (workerPool > 0) $
         c_rt_graph_test_set_worker_pool_size handle (fromIntegral workerPool)
       when reduction $
         c_rt_graph_test_set_reduction_capture handle 1
       when scheduleExec $
         c_rt_graph_test_set_global_schedule_execution handle 1
       forM [1 .. blocks] $ \_ -> processAndReadBuses handle nframes buses

-- Process one block, then read every bus in the supplied list.
-- Asserts c_rt_graph_read_bus returns exactly nframes for each bus
-- so a short read (ABI bug, missing bus) is caught here rather than
-- silently producing zeros that happen to compare equal.
processAndReadBuses
  :: Ptr RTGraph -> Int -> [Int] -> IO [(Int, [Float])]
processAndReadBuses handle nframes buses = do
  c_rt_graph_process handle (fromIntegral nframes)
  forM buses $ \b -> do
    vs <- readBus handle b nframes
    pure (b, vs)

readBus :: Ptr RTGraph -> Int -> Int -> IO [Float]
readBus handle bus nframes =
  allocaBytes (nframes * sizeOfFloatT9) $ \buf -> do
    n <- c_rt_graph_read_bus handle (fromIntegral bus)
                             (fromIntegral nframes) (castPtr buf)
    fromIntegral n @?= nframes
    cs <- peekArray nframes (buf :: PtrCFloat)
    pure (map (\(CFloat x) -> x) cs)
  where
    sizeOfFloatT9 = 4

-- Buses the graph reads from or writes to, derived from per-node
-- kinds: KOut / KBusOut write, KBusIn / KBusInDelayed read. The bus
-- index lives in rnControls[0] for all four kinds (see
-- ugenView in Bridge/Source.hs). Bus 0 is always included so the
-- master out-bus is checked even on graphs that only touch private
-- buses; the result is sorted and deduplicated. Negative indices
-- are dropped to match the loader's busIndexOf, so randomized or
-- malformed inputs cannot ask the runtime to read a bus it never
-- registers.
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
        []      -> Nothing
      buses = mapMaybe idxOf (filter touchesBus (rgNodes rt))
  in sort (nub (0 : buses))

relevantBusesTG :: TemplateGraph -> [Int]
relevantBusesTG tg =
  sort (nub (concatMap (relevantBuses . tplGraph) (tgTemplates tg)))

-- Direct-vs-reduction equivalence assertion. Renders the same graph
-- through the same loader twice — once direct, once with reduction
-- capture — and requires every block to be byte-identical on every
-- relevant bus.
assertDirectEqualsReductionRG
  :: String
  -> (Ptr RTGraph -> RuntimeGraph -> IO ())
  -> RuntimeGraph
  -> Int   -- nframes per block
  -> Int   -- block count
  -> Assertion
assertDirectEqualsReductionRG label loader rt nframes blocks = do
  let buses = relevantBuses rt
  d <- renderBlocksRG loader rt False nframes blocks buses
  r <- renderBlocksRG loader rt True  nframes blocks buses
  assertBlocksEqual label d r

assertDirectEqualsReductionTG
  :: String
  -> (Ptr RTGraph -> TemplateGraph -> IO ())
  -> TemplateGraph
  -> Int
  -> Int
  -> Assertion
assertDirectEqualsReductionTG label loader tg nframes blocks = do
  let buses = relevantBusesTG tg
  d <- renderBlocksTG loader tg False nframes blocks buses
  r <- renderBlocksTG loader tg True  nframes blocks buses
  assertBlocksEqual label d r

assertDirectEqualsScheduleRG
  :: String
  -> (Ptr RTGraph -> RuntimeGraph -> IO ())
  -> RuntimeGraph
  -> Int
  -> Int
  -> Assertion
assertDirectEqualsScheduleRG label loader rt nframes blocks = do
  let buses = relevantBuses rt
  legacy <- renderBlocksRGWithFlags loader rt False False nframes blocks buses
  sched  <- renderBlocksRGWithFlags loader rt False True  nframes blocks buses
  assertBlocksEqual (label <> ": legacy/schedule") legacy sched

assertDirectEqualsScheduleTG
  :: String
  -> (Ptr RTGraph -> TemplateGraph -> IO ())
  -> TemplateGraph
  -> Int
  -> Int
  -> Assertion
assertDirectEqualsScheduleTG label loader tg nframes blocks = do
  let buses = relevantBusesTG tg
  legacy <- renderBlocksTGWithFlags loader tg False False nframes blocks buses
  sched  <- renderBlocksTGWithFlags loader tg False True  nframes blocks buses
  assertBlocksEqual (label <> ": legacy/schedule") legacy sched

assertScheduleDirectEqualsReductionRG
  :: String
  -> (Ptr RTGraph -> RuntimeGraph -> IO ())
  -> RuntimeGraph
  -> Int
  -> Int
  -> Assertion
assertScheduleDirectEqualsReductionRG label loader rt nframes blocks = do
  let buses = relevantBuses rt
  d <- renderBlocksRGWithFlags loader rt False True nframes blocks buses
  r <- renderBlocksRGWithFlags loader rt True  True nframes blocks buses
  assertBlocksEqual (label <> ": schedule direct/reduction") d r

assertScheduleDirectEqualsReductionTG
  :: String
  -> (Ptr RTGraph -> TemplateGraph -> IO ())
  -> TemplateGraph
  -> Int
  -> Int
  -> Assertion
assertScheduleDirectEqualsReductionTG label loader tg nframes blocks = do
  let buses = relevantBusesTG tg
  d <- renderBlocksTGWithFlags loader tg False True nframes blocks buses
  r <- renderBlocksTGWithFlags loader tg True  True nframes blocks buses
  assertBlocksEqual (label <> ": schedule direct/reduction") d r

assertSchedulePoolDirectEqualsReductionRG
  :: String
  -> (Ptr RTGraph -> RuntimeGraph -> IO ())
  -> RuntimeGraph
  -> Int
  -> Int
  -> Int
  -> Assertion
assertSchedulePoolDirectEqualsReductionRG
    label loader rt workerPool nframes blocks = do
  let buses = relevantBuses rt
  d <- renderBlocksRGWithWorkerPool
         loader rt False True workerPool nframes blocks buses
  r <- renderBlocksRGWithWorkerPool
         loader rt True  True workerPool nframes blocks buses
  assertBlocksEqual
    (label <> ": schedule pool direct/reduction") d r

assertSchedulePoolDirectEqualsReductionTG
  :: String
  -> (Ptr RTGraph -> TemplateGraph -> IO ())
  -> TemplateGraph
  -> Int
  -> Int
  -> Int
  -> Assertion
assertSchedulePoolDirectEqualsReductionTG
    label loader tg workerPool nframes blocks = do
  let buses = relevantBusesTG tg
  d <- renderBlocksTGWithWorkerPool
         loader tg False True workerPool nframes blocks buses
  r <- renderBlocksTGWithWorkerPool
         loader tg True  True workerPool nframes blocks buses
  assertBlocksEqual
    (label <> ": schedule pool direct/reduction") d r

assertDirectEqualsSchedulePoolRG
  :: String
  -> (Ptr RTGraph -> RuntimeGraph -> IO ())
  -> RuntimeGraph
  -> Int
  -> Int
  -> Int
  -> Assertion
assertDirectEqualsSchedulePoolRG label loader rt workerPool nframes blocks = do
  let buses = relevantBuses rt
  legacy <- renderBlocksRGWithWorkerPool
              loader rt False False 0 nframes blocks buses
  sched  <- renderBlocksRGWithWorkerPool
              loader rt False True workerPool nframes blocks buses
  assertBlocksEqual (label <> ": legacy/schedule-pool") legacy sched

-- Per-block, per-bus exact-equality check. Reports the first
-- divergent (block, bus, frame) so a failure points straight at the
-- kernel that broke the contract.
assertBlocksEqual
  :: String
  -> [[(Int, [Float])]]
  -> [[(Int, [Float])]]
  -> Assertion
assertBlocksEqual label direct reduced = do
  length direct @?= length reduced
  forM_ (zip3 [0 :: Int ..] direct reduced) $ \(b, db, rb) -> do
    map fst db @?= map fst rb
    forM_ (zip db rb) $ \((busIdx, dvs), (_, rvs)) ->
      forM_ (zip3 [0 :: Int ..] dvs rvs) $ \(fi, dv, rv) ->
        when (dv /= rv) $
          assertFailure $
            label <> ": direct/reduction diverge at block " <> show b
            <> ", bus " <> show busIdx
            <> ", frame " <> show fi
            <> ": direct=" <> show dv <> " reduced=" <> show rv

-- Compile a SynthGraph through both lowering paths so a single test
-- can route the same source through unfused and fused loaders. The
-- error path on either compile is a hard test failure — these are
-- demo shapes that all compile cleanly.
compileBoth
  :: String -> SynthGraph -> IO (RuntimeGraph, RuntimeGraph)
compileBoth name g = do
  rtUn <- case lowerGraph g >>= compileRuntimeGraph of
    Right r  -> pure r
    Left err -> assertFailure
                  (name <> ": compileRuntimeGraph failed: " <> err)
                >> error "unreachable"
  rtF  <- case lowerGraph g >>= compileRuntimeGraphFused of
    Right r  -> pure r
    Left err -> assertFailure
                  (name <> ": compileRuntimeGraphFused failed: " <> err)
                >> error "unreachable"
  pure (rtUn, rtF)

-- T-9 direct ≡ reduction tests now live in "MetaSonic.Spec.FFI.T9".
-- Phase 4.E.2.C0a layer-aware loader metadata tests, plus the four
-- C0a-only helpers ('expectedScheduleStepItems', 'readScheduleSteps',
-- 'assertLoaderShipsScheduleRG', 'assertLoaderShipsScheduleTG'), now
-- live in "MetaSonic.Spec.FFI.C0a".

------------------------------------------------------------
-- Phase 4.E.2.C0b: per-block global schedule
------------------------------------------------------------
--
-- The runtime rebuilds a global schedule at the top of every
-- 'rt_graph_process' call: a flat list of
-- (template_id, instance_slot, step_index) entries in canonical
--   template ascending → instance slot ascending → step ascending
-- order, filtered to instances whose state is Active or
-- Releasing. These tests pin the shape the C0c serial executor
-- consumes when its test switch is enabled. Cross-resolution to
-- per-step kind / ordinal data goes through the C0a accessors;
-- the divergent-layer case proves a non-contiguous free layer
-- survives all the way out to a global-schedule consumer.

-- | Read every entry of the global schedule as a list of
-- (template_id, instance_slot, step_index) triples.
readGlobalSchedule :: Ptr RTGraph -> IO [(Int, Int, Int)]
readGlobalSchedule h = do
  cnt <- c_rt_graph_test_global_schedule_entry_count h
  forM [0 .. fromIntegral cnt - 1] $ \i -> do
    t <- c_rt_graph_test_global_schedule_entry_template h i
    s <- c_rt_graph_test_global_schedule_entry_instance h i
    p <- c_rt_graph_test_global_schedule_entry_step      h i
    pure (fromIntegral t, fromIntegral s, fromIntegral p)

-- | Read every C0d global-schedule band as
-- (kind, first_entry, entry_count), where kind is 0 = Barrier and
-- 1 = Free.
readGlobalScheduleBands :: Ptr RTGraph -> IO [(Int, Int, Int)]
readGlobalScheduleBands h = do
  cnt <- c_rt_graph_test_global_schedule_band_count h
  forM [0 .. fromIntegral cnt - 1] $ \i -> do
    k <- c_rt_graph_test_global_schedule_band_kind h i
    f <- c_rt_graph_test_global_schedule_band_first_entry h i
    n <- c_rt_graph_test_global_schedule_band_entry_count h i
    pure (fromIntegral k, fromIntegral f, fromIntegral n)

-- | Assert the C0d band vector is a conservative, contiguous
-- partition of the C0b entry vector. Barrier bands must be singleton
-- barrier steps. Free bands must contain only FreeLayer steps and
-- cannot contain two entries for the same instance slot.
assertGlobalScheduleBandsWellFormed :: String -> Ptr RTGraph -> Assertion
assertGlobalScheduleBandsWellFormed label h = do
  entries <- readGlobalSchedule h
  bands   <- readGlobalScheduleBands h

  let ranges =
        concat
          [ [first .. first + count - 1]
          | (_kind, first, count) <- bands
          ]
      expectedRange = [0 .. length entries - 1]
  ranges @?= expectedRange

  forM_ (zip [0 :: Int ..] bands) $ \(bandIndex, (kind, first, count)) -> do
    assertBool
      (label <> ": band " <> show bandIndex <> " has non-positive count")
      (count > 0)
    assertBool
      (label <> ": band " <> show bandIndex <> " starts out of range")
      (first >= 0 && first + count <= length entries)
    let slice = take count (drop first entries)
    stepKinds <- forM slice $ \(tid, _slot, step) ->
      c_rt_graph_test_template_schedule_step_kind h
        (fromIntegral tid) (fromIntegral step)
    case kind of
      0 -> do
        count @?= 1
        stepKinds @?= [0]
      1 -> do
        stepKinds @?= replicate count 1
        let slots = [slot | (_tid, slot, _step) <- slice]
        slots @?= nub slots
      _ -> assertFailure
             (label <> ": unexpected band kind " <> show kind)

  let over = fromIntegral (length bands) :: CInt
  badKind <- c_rt_graph_test_global_schedule_band_kind h over
  badFirst <- c_rt_graph_test_global_schedule_band_first_entry h over
  badCount <- c_rt_graph_test_global_schedule_band_entry_count h over
  badKind @?= -1
  badFirst @?= -1
  badCount @?= -1

-- | Pure expectation for a single-template graph: emit
-- (0, slot, step) triples for every (slot in @slots@, step in
-- the layered schedule), in slot-then-step order. Steps come from
-- 'layeredRegionSchedule' to make the test contract obvious;
-- assertion failure here would indicate either a planner or
-- loader regression.
expectedGlobalRG :: RuntimeGraph -> [Int] -> [(Int, Int, Int)]
expectedGlobalRG rg slots =
  let stepCount = case layeredRegionSchedule rg of
        Right ss -> length ss
        Left _   -> 0
  in [ (0, slot, step)
     | slot <- slots
     , step <- [0 .. stepCount - 1]
     ]

-- | Multi-template counterpart: emit per-template entries in
-- registration order, then per-instance-slot, then per-step. The
-- caller supplies the live slot list per template_id so this
-- helper does not need to know about the runtime instance pool.
expectedGlobalTG
  :: TemplateGraph -> [(Int, [Int])] -> [(Int, Int, Int)]
expectedGlobalTG tg perTpl =
  let tplCount = zip [0 :: Int ..] (tgTemplates tg)
      stepCountFor i = case lookup i tplCount of
        Just t -> case layeredRegionSchedule (tplGraph t) of
          Right ss -> length ss
          Left _   -> 0
        Nothing -> 0
  in [ (tid, slot, step)
     | (tid, slots) <- perTpl
     , slot <- slots
     , step <- [0 .. stepCountFor tid - 1]
     ]

-- The following phase test trees have been extracted from this module
-- as the megafile split progresses; the helpers above ('compileBoth',
-- 't9CorpusGraphs', 'readGlobalSchedule', etc.) stay here and are
-- imported by each submodule:
--
--   * MetaSonic.Spec.FFI.C0b — Phase 4.E.2.C0b per-block global schedule
--   * MetaSonic.Spec.FFI.C0c — Phase 4.E.2.C0c/C1a banded serial executor
--   * MetaSonic.Spec.FFI.C0d — Phase 4.E.2.C0d global-schedule runnable bands
--   * MetaSonic.Spec.FFI.C1c — Phase 4.E.2.C1c-c worker-schedule equivalence
--   * MetaSonic.Spec.FFI.T9  — T-9 direct ≡ reduction

------------------------------------------------------------
-- Session Prep A: command/event vocabulary
--
-- These tests pin only the structural adapter from the existing
-- pattern producer vocabulary into the future session vocabulary.
-- No command execution, queue writes, or runtime ownership is implied.
------------------------------------------------------------
