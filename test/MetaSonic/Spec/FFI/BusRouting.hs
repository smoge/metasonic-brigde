-- | End-to-end FFI tests for the bus routing and time-shift primitives
-- the runtime exposes: BusOut/BusIn (same-cycle), BusInDelayed
-- (one-block snapshot), delayL (sample-accurate ring buffer), smooth
-- (seeded dynamic_smoother), and the idle Env(gate=0) silence
-- baseline.
--
-- Each case pins one corner of the routing contract:
--
--   * BusOut → BusIn round-trip preserves the signal — locks E_r
--     ordering (BusOut runs before BusIn within the same cycle) and
--     the unified-pool model.
--   * Out + BusOut writing to the same bus number sum, confirming
--     bus 0 (hardware out) and bus 0 (BusOut destination) share one
--     accumulator.
--   * Two BusIn readers on the same bus see the same value, pinning
--     fan-out semantics.
--   * BusInDelayed reads zero on the first block and bit-identically
--     replays the previous block's BusOut output on the second —
--     the full Phase 2 BusInDelayed path through the FFI.
--   * delayL produces a silence-then-signal transition near
--     time*sps, proving the q::delay buffer is configured at load.
--   * smooth seeds its IIR state to the Param target so the first
--     block emits the target value, not a ramp from zero.
--   * Env(gate=0) idles silent — a sanity floor on the envelope's
--     gate semantics.
--
-- Extracted from "MetaSonic.Spec.FFI" as the eighth slice of the
-- megafile split; the first cut into 'crossCuttingTests' itself
-- that does not depend on shared parent helpers (the cases only use
-- public 'MetaSonic.Bridge.*' entry points plus 'PtrCFloat' from
-- "MetaSonic.Spec.Core"). The 'sizeOfFloat' local binding mirrors
-- the parent's where-clause attached to 'crossCuttingTests'.
module MetaSonic.Spec.FFI.BusRouting (busRoutingTests) where

import           Foreign.C.Types          (CFloat (..))
import           Foreign.Marshal.Alloc    (allocaBytes)
import           Foreign.Marshal.Array    (peekArray)
import           Foreign.Ptr              (castPtr)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile (compileRuntimeGraph, rgNodes)
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR      (lowerGraph)
import           MetaSonic.Bridge.Source

import           MetaSonic.Spec.Core      (PtrCFloat)


busRoutingTests :: TestTree
busRoutingTests = testGroup "End-to-end FFI: bus routing primitives"
  [ testCase "BusOut → BusIn round-trip preserves the SinOsc signal" $ do
      -- A SinOsc writes to bus 5 via BusOut; a BusIn reads bus 5; that
      -- read is gain-attenuated and sent to hardware bus 0. We then
      -- read bus 0 and check we hear the original sine, halved.
      --
      -- This exercises:
      --   * E_r ordering: BusOut(5) must execute before BusIn(5).
      --   * Same-cycle semantics: BusIn sees the live, accumulated value.
      --   * Bus pool unification: bus 5 lives in the same pool as bus 0.
      let nframes = 256
          graph = runSynth $ do
            o      <- sinOsc 440.0 0.0
            busOut 5 o
            tap    <- busIn 5
            scaled <- gain tap 0.5
            out 0 scaled

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
          -- Original SinOsc has peak 1.0, gain 0.5 halves it. If E_r
          -- ordering broke and BusIn ran before BusOut, the bus would
          -- still be zero and the peak would be ~0.
          assertBool ("expected peak ≈ 0.5 from BusOut→BusIn round-trip, got " <> show peak)
                     (abs (peak - 0.5) < 0.05)

  , testCase "Out and BusOut writing to the same bus sum (unified pool)" $ do
      -- Pins the unified-pool model: a bus written by Out and a bus
      -- written by BusOut targeting the same bus number share the
      -- same memory and accumulate together. If the runtime ever
      -- regressed to two pools, this test would catch it.
      --
      -- SinOsc → Out 0 (peak ≈ 1) AND SinOsc' → BusOut 0 (peak ≈ 1)
      -- on the same bus number. The bus pool is unified, so the read
      -- of bus 0 should see the sum (peak ≈ 2).
      let nframes = 256
          graph = runSynth $ do
            o1 <- sinOsc 440.0 0.0
            o2 <- sinOsc 440.0 0.0
            out 0 o1
            busOut 0 o2

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
          let peak = maximum (map (\(CFloat x) -> x) cs)
          assertBool
            ("expected Out + BusOut to sum to peak ≈ 2 on shared bus 0, got "
              <> show peak)
            (peak > 1.5 && peak < 2.1)

  , testCase "two BusIn readers on the same bus see the same value (fan-out)" $ do
      -- BusIn 5 read by two consumers; both should see the live value.
      -- We feed each into a Gain (one ×0.3, one ×0.7) and route both
      -- to the hardware via separate Out channels, then check that
      -- the reads were *of the same source* by recovering their sum
      -- on bus 0 — peak should be (0.3 + 0.7) × 1 = 1.0.
      let nframes = 256
          graph = runSynth $ do
            o      <- sinOsc 440.0 0.0
            busOut 5 o
            tap1   <- busIn 5
            tap2   <- busIn 5
            g1     <- gain tap1 0.3
            g2     <- gain tap2 0.7
            out 0 g1
            out 0 g2  -- accumulates onto bus 0 with g1

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
          assertBool
            ("expected (0.3 + 0.7) × SinOsc peak ≈ 1.0, got " <> show peak)
            (abs (peak - 1.0) < 0.05)

  , testCase "BusInDelayed: one-block delay end-to-end through the FFI" $ do
      -- The Haskell-side counterpart to the C++ "BusInDelayed reads
      -- the previous block's BusOut contents" test. Renders two
      -- consecutive blocks of the same graph and asserts:
      --
      --   * On block 1, BusInDelayed reads zero (no previous block),
      --     so Out(0) is silence.
      --   * On block 2, BusInDelayed reads what BusOut wrote during
      --     block 1, so Out(0) on block 2 is bit-identical to bus 5
      --     on block 1.
      --
      -- This pins the entire Phase 2 path: the C++ swap, the
      -- BusReadDelayed effect being excluded from E_r, the schedule
      -- placing BusInDelayed wherever it falls, the FFI marshalling
      -- of KBusInDelayed, and the runtime kernel reading from
      -- output_buses_prev.
      let nframes = 128
          maxFrames = nframes
          graph = runSynth $ do
            o   <- sinOsc 440.0 0.0
            busOut 5 o
            tap <- busInDelayed 5
            out 0 tap
      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      let readBus handle bus n = allocaBytes (n * sizeOfFloat) $ \buf -> do
            _  <- c_rt_graph_read_bus handle (fromIntegral bus)
                                      (fromIntegral n) (castPtr buf)
            cs <- peekArray n (buf :: PtrCFloat)
            pure (map (\(CFloat x) -> x) cs)

      withRTGraph (length (rgNodes rt)) maxFrames $ \handle -> do
        loadRuntimeGraph handle rt

        -- Block 1.
        c_rt_graph_process handle (fromIntegral nframes)
        block1Out  <- readBus handle 0 nframes
        block1Bus5 <- readBus handle 5 nframes

        let peak1 = maximum (map abs block1Out)
        assertBool
          ("block 1 should be silence (snapshot is zero), got peak " <> show peak1)
          (peak1 < 1e-5)
        let peakBus5 = maximum (map abs block1Bus5)
        assertBool
          ("block 1's BusOut should still write a real sine to bus 5, got peak "
            <> show peakBus5)
          (peakBus5 > 0.9)

        -- Block 2.
        c_rt_graph_process handle (fromIntegral nframes)
        block2Out <- readBus handle 0 nframes

        let maxDiff = maximum (zipWith (\a b -> abs (a - b)) block1Bus5 block2Out)
        assertBool
          ("block 2's BusInDelayed must reproduce block 1's bus 5; max diff = "
            <> show maxDiff)
          (maxDiff < 1e-5)

  , testCase "delayL: 5ms delay shifts a SinOsc output by ~240 samples" $ do
      -- Render one block of a SinOsc → delayL 0.01 (max) ~ 0.005 (time)
      -- → Out chain. The kernel's q::delay maps time*sps to a
      -- fractional read index that produces (time*sps + 1) samples of
      -- effective delay. At sps=48000, 5ms ≈ 240 samples.
      --
      -- The first ~240 output samples should be silence (the buffer
      -- still holds zeros). After that, the SinOsc output appears.
      -- We allow ±2 samples of slop and only assert that:
      --
      --   * a clear silence-then-signal transition exists
      --   * the transition lands within 240 ± 5 samples
      --   * post-transition the peak resembles a sine (≈ 1.0)
      --
      -- This is the FFI-level proof that the delay UGen survives
      -- marshalling, configures the q::delay buffer at load, and
      -- produces correct output across the boundary.
      let nframes = 1024
          sps :: Double
          sps = 48000.0
          delaySec = 0.005
          expectedDelay = round (delaySec * sps) :: Int   -- 240
          graph = runSynth $ do
            o <- sinOsc 440.0 0.0
            d <- delayL 0.01 o (Param delaySec)
            out 0 d
      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _  <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                    (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          let samples = map (\(CFloat x) -> x) cs

              -- Locate the silence→signal transition point.
              isSilent x = abs x < 0.05
              transition = length (takeWhile isSilent samples)

          assertBool
            ("expected silence-then-signal transition near sample "
              <> show expectedDelay <> ", got transition at " <> show transition)
            (abs (transition - expectedDelay) <= 5)

          -- Post-transition the SinOsc shape should be intact (peak ~1).
          let postDelay = drop (transition + 20) samples
              peakPost  = maximum (map abs postDelay)
          assertBool
            ("expected post-delay peak ≈ 1.0, got " <> show peakPost)
            (abs (peakPost - 1.0) < 0.05)

  , testCase "smooth: Param target seeds the smoother to steady state" $ do
      -- End-to-end FFI proof for Phase 3.3c. Smooth wraps
      -- q::dynamic_smoother and seeds its IIR state to the first
      -- input sample on the first process call, so a fresh graph
      -- with a constant Param target should emit that target value
      -- across the entire first block — no "ramp from zero" attack.
      let nframes = 256
          target  = 0.5 :: Float
          graph   = runSynth $ do
            s <- smooth 20.0 (Param (realToFrac target))
            out 0 s

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
              maxDev  = maximum (map (\x -> abs (x - target)) samples)
          assertBool
            ("smooth seeded steady-state should hold target " <> show target
              <> " across the whole block, got max deviation " <> show maxDev)
            (maxDev < 1e-4)

  , testCase "Env(gate=0) idle stays silent" $ do
      let nframes = 256
          graph = runSynth $ do
            e <- env (Param 0.0) (Param 0.01) (Param 0.05) (Param 0.5) (Param 0.1)
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
          let peak = maximum (map (\(CFloat x) -> abs x) cs)
          assertBool ("idle envelope should be silent, got peak " <> show peak)
                     (peak < 1e-6)
  ]
  where
    sizeOfFloat = 4 :: Int
