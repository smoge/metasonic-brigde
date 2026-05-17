{-# LANGUAGE LambdaCase #-}

-- | End-to-end FFI, render-equivalence, and runtime schedule tests.
module MetaSonic.Spec.FFI where

import           Data.List                 (isInfixOf, nub, sort)
import           Control.Exception         (try)
import           Control.Monad             (forM, forM_, when)
import           Data.Maybe                (mapMaybe)
import           Foreign.C.Types           (CDouble (..), CFloat (..), CInt)
import           Foreign.Marshal.Alloc     (allocaBytes)
import           Foreign.Marshal.Array     (peekArray)
import           Foreign.Ptr               (Ptr, castPtr)

import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck     as QC

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Types
import           MetaSonic.Spec.Core

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

  , -- Step C (c) guard: feeding a fused graph through the unfused
    -- 'loadRuntimeGraph' must fail fast with the documented error,
    -- not miswire silently. This pins the contract until Step C (e)
    -- adds a fused-aware loader.
    testCase "loadRuntimeGraph rejects RFused inputs with the documented error" $ do
      -- 'Env' source: durable §4.C-only fixture (no §4.B kernel
      -- candidate, per notes/2026-05-08-e-fusion-strategy.md). We need §4.C to
      -- actually emit an 'RFused' input for the loader-rejection
      -- check to fire.
      let graph = runSynth $ do
            o <- env (Param 1.0) 0.0005 0.002 1.0 0.002
            a <- gain o (Param 0.5)
            out 0 a
      rt <- case lowerGraph graph >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      -- Sanity: the fused graph really has at least one RFused.
      assertBool "fused compile produced no RFused inputs"
        (not (null [() | n <- rgNodes rt, RFused _ <- rnInputs n]))
      let attempt :: IO (Either IOError ())
          attempt = try $
            withRTGraph (length (rgNodes rt)) 64 $ \handle ->
              loadRuntimeGraph handle rt
      result <- attempt
      case result of
        Right () ->
          assertFailure "expected loadRuntimeGraph to fail on RFused input"
        Left e ->
          assertBool
            ("error message did not mention the fused loader: " <> show e)
            ("RFused input requires the fused loader" `isInfixOf` show e)

  , -- Step C (e) smoke test: 'loadRuntimeGraphFused' loads a graph
    -- containing 'RFused' and 'rnElided' without throwing, and the
    -- audio path produces non-silent output. Bit-identical
    -- equivalence with the unfused render is pinned in Step C (f).
    testCase "loadRuntimeGraphFused: fused graph renders non-silent audio" $ do
      -- 'Env' source: durable §4.C-only fixture. With gate=1 and
      -- sustain=1 the envelope settles at ~1.0 within a few ms
      -- (well under the 256-frame block), so peak after the 0.5
      -- gain is ~0.5 — same expected magnitude the previous saw
      -- fixture targeted, just from a different source.
      let nframes = 256
          graph = runSynth $ do
            o <- env (Param 1.0) 0.0005 0.002 1.0 0.002
            a <- gain o (Param 0.5)
            out 0 a
      rt <- case lowerGraph graph >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      -- Confirm the fused compile produced both signals: an RFused
      -- input on Out and an elided Gain. Without these the test
      -- would not exercise the new loader passes.
      assertBool "fused compile produced no RFused inputs"
        (not (null [() | n <- rgNodes rt, RFused _ <- rnInputs n]))
      assertBool "fused compile elided no nodes"
        (any rnElided (rgNodes rt))

      samples <- withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraphFused handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _  <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                    (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          pure (map (\(CFloat x) -> x) cs)

      let peak = maximum (map abs samples)
      -- Env at sustain=1 × 0.5 gain ⇒ peak ≈ 0.5. Non-silent
      -- confirms the fused-input scratch materialization reached
      -- the consumer and the elided Gain didn't break dispatch.
      assertBool ("expected non-silent fused render, peak = " <> show peak)
                 (peak > 0.4 && peak < 0.6)

  , -- Step C (f): bit-equivalence battery. For every graph in
    -- 'fusedEquivalenceCases' the unfused render (loadRuntimeGraph
    -- + compileRuntimeGraph) must equal the fused render
    -- (loadRuntimeGraphFused + compileRuntimeGraphFused) sample-
    -- for-sample. The fused path takes a different runtime route
    -- — elided dispatch + fused-input resolver (any of single-scale,
    -- scale chain, or affine; selected by the FusedInput
    -- constructor) — but each step's materialization discipline
    -- (cast double→float, multiply or add) is chosen to mirror
    -- process_gain / process_add scalar branches exactly, so
    -- equivalence is bit-strict, not approx.
    --
    -- Each case must actually exercise fusion: the assertion
    -- includes a sanity check that the fused graph produced at
    -- least one RFused input and at least one elided node.
    testGroup "Step C (f): fused render equals unfused render"
      [ testCase name $ assertFusedEquivalent name graph
      | (name, graph) <- fusedEquivalenceCases
      ]

  , -- Property-based fused/unfused render equivalence on random
    -- topology. Same contract as the testGroup above, but the
    -- graph is QuickCheck-generated by 'genFusableRenderableGraph'
    -- (deterministic subset: no NoiseGen, always-renderable bus 7
    -- floor). A coverage gate ensures the generated cases actually
    -- exercise fusion instead of mostly comparing identical unfused
    -- loader paths.
    QC.testProperty "fused render equals unfused render on random graphs" $
      forAllShrink genFusableRenderableGraph shrinkSynthGraph
        prop_fusedRenderEqualsUnfused

  , -- Step C (f): control identity. A live set_control on the
    -- elided Gain node must steer the fused output exactly as it
    -- steers the unfused Gain's kernel. This is the load-bearing
    -- claim that elided nodes remain control-addressable through
    -- the FFI: NodeIndex, control slot, and control values all
    -- survive elision.
    testCase "Step C (f): set_control on elided Gain matches unfused output" $ do
      let nframes = 256
          chain = runSynth $ do
            o <- sinOsc 440.0 0.0
            a <- gain o (Param 0.5)  -- initial scalar gain
            out 0 a
          newGain = 0.7 :: Double

      rtUn <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      -- The elided Gain's NodeIndex must survive identically in
      -- both graphs. compileRuntimeGraphFused preserves rgNodes
      -- ordering (Step C (c)) so the index is the same.
      let gainIdxFromGraph rg =
            case [rnIndex n | n <- rgNodes rg, rnKind n == KGain] of
              [NodeIndex i] -> i
              other -> error $ "expected one Gain, got " <> show other
          gainIxUn = gainIdxFromGraph rtUn
          gainIxF  = gainIdxFromGraph rtF
      gainIxUn @?= gainIxF

      let renderWith loader rt = withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
            loader handle rt
            -- Live control write on the (elided / dispatched) Gain.
            -- In the fused graph the kernel never runs, but
            -- resolve_input reads controls[0] when materializing
            -- the FScaleFrom; in the unfused graph process_gain's
            -- scalar branch reads the same slot. Both should
            -- track newGain identically.
            c_rt_graph_instance_set_control handle 0
              (fromIntegral gainIxUn) 0 (CDouble newGain)
            c_rt_graph_process handle (fromIntegral nframes)
            allocaBytes (nframes * sizeOfFloat) $ \buf -> do
              _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                       (castPtr buf)
              cs <- peekArray nframes (buf :: PtrCFloat)
              pure (map (\(CFloat x) -> x) cs)

      unfusedSamples <- renderWith loadRuntimeGraph      rtUn
      fusedSamples   <- renderWith loadRuntimeGraphFused rtF

      length unfusedSamples @?= length fusedSamples
      assertBool "fused/unfused samples differ after live set_control"
        (unfusedSamples == fusedSamples)
      -- Sanity: the new gain actually took effect — a 440 Hz sine
      -- at 0.7 should peak around 0.7, not at the original 0.5.
      let peak = maximum (map abs unfusedSamples)
      assertBool ("expected peak ≈ 0.7 after set_control, got " <> show peak)
                 (peak > 0.6 && peak < 0.75)

  , -- Chain control identity. With both Gains in a chain elided,
    -- live set_control on every Gain in the chain must steer the
    -- fused output exactly as it steers the unfused chain of
    -- process_gain kernels. The fact that *both* mid-chain Gains
    -- remain control-addressable is the guarantee that
    -- 'rt_graph_template_connect_fused_scale_chain_input' stored
    -- each ScaleRef and the resolver reads each control live —
    -- pre-multiplication or stale caching would either silently
    -- ignore one of the writes or change the output's float-
    -- rounding profile. Done as a separate test from the
    -- single-Gain identity test so a regression in chain handling
    -- doesn't masquerade as the simpler bug.
    testCase "Step C: set_control on every elided Gain in a chain matches unfused output" $ do
      let nframes = 256
          chain = runSynth $ do
            o  <- sinOsc 440.0 0.0
            a1 <- gain o  (Param 0.5)
            a2 <- gain a1 (Param 0.25)
            out 0 a2
          newG1 = 0.7  :: Double
          newG2 = 0.6  :: Double

      rtUn <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      -- Both Gains' NodeIndex must survive identically across
      -- fused/unfused. compileRuntimeGraphFused preserves rgNodes
      -- ordering, so the indices line up.
      let gainIxs rg =
            [ rnIndex n | n <- rgNodes rg, rnKind n == KGain ]
      gainIxs rtUn @?= gainIxs rtF
      case gainIxs rtF of
        [_, _] -> pure ()
        other  -> assertFailure $
          "expected exactly two Gains in chain, got " <> show other
      let [NodeIndex g1, NodeIndex g2] = gainIxs rtF

      -- Sanity: the fused compile actually produced a chain (not
      -- two independent FScaleFroms). If this assertion ever flips
      -- to FScaleFrom, the chain extension regressed.
      assertBool "chain test: expected FScaleChainFrom on Out's input"
        (not (null
          [ ()
          | n <- rgNodes rtF
          , rnKind n == KOut
          , RFused FScaleChainFrom{} <- rnInputs n
          ]))

      let renderWith loader rt = withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
            loader handle rt
            -- Mutate both elided Gain controls. In the unfused
            -- graph each kernel reads its own controls[0]; in the
            -- fused graph the chain resolver reads each ScaleRef's
            -- live control. Both reads must reflect the new values.
            c_rt_graph_instance_set_control handle 0
              (fromIntegral g1) 0 (CDouble newG1)
            c_rt_graph_instance_set_control handle 0
              (fromIntegral g2) 0 (CDouble newG2)
            c_rt_graph_process handle (fromIntegral nframes)
            allocaBytes (nframes * sizeOfFloat) $ \buf -> do
              _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                       (castPtr buf)
              cs <- peekArray nframes (buf :: PtrCFloat)
              pure (map (\(CFloat x) -> x) cs)

      unfusedSamples <- renderWith loadRuntimeGraph      rtUn
      fusedSamples   <- renderWith loadRuntimeGraphFused rtF

      length unfusedSamples @?= length fusedSamples
      assertBool "chain fused/unfused samples differ after live set_control on both Gains"
        (unfusedSamples == fusedSamples)
      -- Sanity: combined gain ≈ 0.7 * 0.6 = 0.42, so peak should
      -- be near that on a 440 Hz sine.
      let peak = maximum (map abs unfusedSamples)
      assertBool ("expected peak ≈ 0.42 after chain set_control, got " <> show peak)
                 (peak > 0.36 && peak < 0.48)

  , -- Phase 4.C.2: control identity on a mixed Gain/Add chain. With
    -- both nodes elided into one FAffineFrom on Out's input, live
    -- set_control on the Gain's scale AND on the Add's bias must
    -- steer the fused output exactly as the unfused chain. This
    -- pins (a) that the affine resolver reads each step's control
    -- live every block and (b) that the bias control slot (1 in
    -- this test) is wired correctly from the Haskell IR through to
    -- the FFI marshalling and the C++ resolver.
    testCase "Phase 4.C.2: set_control on elided Gain and Add in a mixed chain matches unfused" $ do
      let nframes = 256
          chain = runSynth $ do
            o <- sinOsc 440.0 0.0
            a <- gain o (Param 0.5)
            b <- add  a (Param 0.1)
            out 0 b
          newGain = 0.7  :: Double
          newBias = 0.05 :: Double

      rtUn <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      -- Sanity: the fused compile actually emitted FAffineFrom (not
      -- two separate fused inputs). Regression catch if the affine
      -- composition rule ever changes shape.
      assertBool "expected FAffineFrom on Out's input"
        (not (null
          [ ()
          | n <- rgNodes rtF
          , rnKind n == KOut
          , RFused FAffineFrom{} <- rnInputs n
          ]))

      let gainIxOf rg =
            case [rnIndex n | n <- rgNodes rg, rnKind n == KGain] of
              [NodeIndex i] -> i
              other -> error $ "expected one Gain, got " <> show other
          addIxOf rg =
            case [rnIndex n | n <- rgNodes rg, rnKind n == KAdd] of
              [NodeIndex i] -> i
              other -> error $ "expected one Add, got " <> show other
      gainIxOf rtUn @?= gainIxOf rtF
      addIxOf  rtUn @?= addIxOf  rtF
      let gainIx = gainIxOf rtF
          addIx  = addIxOf  rtF

      let renderWith loader rt = withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
            loader handle rt
            -- Mutate the Gain's scale (slot 0) and the Add's bias
            -- (slot 1, since 'add a (Param k)' lowers with the bias
            -- on port 1 → control 1). Both must take effect through
            -- the affine resolver every block.
            c_rt_graph_instance_set_control handle 0
              (fromIntegral gainIx) 0 (CDouble newGain)
            c_rt_graph_instance_set_control handle 0
              (fromIntegral addIx)  1 (CDouble newBias)
            c_rt_graph_process handle (fromIntegral nframes)
            allocaBytes (nframes * sizeOfFloat) $ \buf -> do
              _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                       (castPtr buf)
              cs <- peekArray nframes (buf :: PtrCFloat)
              pure (map (\(CFloat x) -> x) cs)

      unfusedSamples <- renderWith loadRuntimeGraph      rtUn
      fusedSamples   <- renderWith loadRuntimeGraphFused rtF

      length unfusedSamples @?= length fusedSamples
      assertBool "affine fused/unfused samples differ after live set_control on Gain + Add"
        (unfusedSamples == fusedSamples)
      -- Sanity: amplitude oscillates between 0.05 - 0.7 = -0.65 and
      -- 0.05 + 0.7 = 0.75, so the peak magnitude should be ≈ 0.75
      -- (the bias is constant DC, the sine oscillates around it).
      let peak = maximum (map abs unfusedSamples)
      assertBool ("expected peak ≈ 0.75 after set_control on scale+bias, got " <> show peak)
                 (peak > 0.7 && peak < 0.78)

  , -- Phase 4.B kernel control identity. Live 'set_control' on
    -- every control slot the SinGainOut kernel reads — sin.freq,
    -- gain.amount, out.bus — must steer the fused render exactly
    -- as it steers a node-loop baseline. A regression where the
    -- kernel cached any of these once at load time (rather than
    -- reading 'inst.nodes[i].controls[k]' live each block) would
    -- silently ignore later set_control writes; a regression
    -- where the wrong slot was wired would shift the bug from
    -- "ignored" to "applied to the wrong control."
    --
    -- The baseline strips the region-kernel tags so the same
    -- compiled graph dispatches via 'process_sinosc' /
    -- 'process_gain' / 'process_out' instead of the kernel —
    -- without that strip, both sides would dispatch through the
    -- kernel and the test would compare identical paths.
    testCase "Phase 4.B: set_control on kernel freq/gain/bus matches node-loop baseline" $ do
      let nframes = 256
          chain = runSynth $ do
            s <- sinOsc 440.0 0.0
            a <- gain s (Param 0.5)
            out 0 a                       -- initial bus: 0
          newFreq = 330.0 :: Double
          newGain = 0.3   :: Double
          newBus  = 2     :: Int          -- redirect to bus 2

      rtUnRaw <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      -- Sanity: the fused side carries an RSinGainOut region (else
      -- the test isn't testing what it claims).
      assertBool "Phase 4.B: fused compile has no RSinGainOut region"
        (any ((== RSinGainOut) . rrKernel) (rgRuntimeRegions rtF))

      -- Strip kernels on the baseline so its render takes the
      -- per-node dispatch path on the same compiled graph.
      let rtUn = stripRegionKernels rtUnRaw

          ixOf k rg =
            let NodeIndex i = head [rnIndex n | n <- rgNodes rg, rnKind n == k]
            in i
          sinIx  = ixOf KSinOsc rtF
          gainIx = ixOf KGain   rtF
          outIx  = ixOf KOut    rtF

      let sizeOfFloat' = 4 :: Int
          renderBus loader rt readBus =
            withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
              loader handle rt
              -- Grow the bus pool to cover the redirected target.
              -- Post-§2.E ABI: 'rt_graph_instance_set_control' no
              -- longer side-effects bus growth; explicit
              -- 'rt_graph_ensure_bus' is required.
              c_rt_graph_ensure_bus handle (fromIntegral newBus)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral sinIx)  0 (CDouble newFreq)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral gainIx) 0 (CDouble newGain)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral outIx)  0 (CDouble (fromIntegral newBus))
              c_rt_graph_process handle (fromIntegral nframes)
              allocaBytes (nframes * sizeOfFloat') $ \buf -> do
                _ <- c_rt_graph_read_bus handle (fromIntegral readBus)
                                         (fromIntegral nframes) (castPtr buf)
                cs <- peekArray nframes (buf :: PtrCFloat)
                pure (map (\(CFloat x) -> x) cs)

      -- Render the redirected bus on both sides.
      baselineSamples <- renderBus loadRuntimeGraph      rtUn newBus
      fusedSamples    <- renderBus loadRuntimeGraphFused rtF  newBus

      length baselineSamples @?= length fusedSamples
      assertBool
        ("Phase 4.B: kernel set_control divergence on bus " <> show newBus)
        (baselineSamples == fusedSamples)

      -- Sanity: 330 Hz sin at 0.3 gain ⇒ peak ≈ 0.3.
      let peak = maximum (map abs baselineSamples)
      assertBool ("expected peak ≈ 0.3 after set_control, got " <> show peak)
                 (peak > 0.25 && peak < 0.35)

  , -- Phase 4.B 4-node kernel control identity. Mirrors the 3-node
    -- 'RSinGainOut' control-write test but exercises every control
    -- the 'RSawLpfGainOut' kernel reads: saw.freq, lpf.freq (slot
    -- 0), lpf.q (slot 1), gain.amount, and out.bus. The LPF's two
    -- distinct control slots are the new ground here — a
    -- regression where the kernel's block-rate latch read the
    -- wrong slot, or didn't refresh on a Q change, would diverge
    -- from the per-node baseline that runs the unfused
    -- 'process_lpf' kernel.
    --
    -- The baseline strips region kernels so its render takes
    -- per-node dispatch on the same compiled graph; bit-identical
    -- samples on the redirected bus prove every control reaches
    -- the right slot in the right form.
    testCase "Phase 4.B: set_control on RSawLpfGainOut covers saw.freq + lpf.freq/q + gain + bus" $ do
      let nframes = 256
          chain = runSynth $ do
            s <- sawOsc 110.0 0.0
            f <- lpf s (Param 800.0) (Param 4.0)
            a <- gain f (Param 0.4)
            out 0 a                       -- initial bus: 0
          newSawFreq = 220.0  :: Double   -- shift fundamental
          newLpfFreq = 1500.0 :: Double   -- raise cutoff (more harmonics pass)
          newLpfQ    = 6.0    :: Double   -- raise Q
          newGain    = 0.3    :: Double
          newBus     = 2      :: Int      -- redirect to bus 2

      rtUnRaw <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      assertBool "Phase 4.B: fused compile has no RSawLpfGainOut region"
        (any ((== RSawLpfGainOut) . rrKernel) (rgRuntimeRegions rtF))

      let rtUn = stripRegionKernels rtUnRaw

          ixOf k rg =
            let NodeIndex i = head [rnIndex n | n <- rgNodes rg, rnKind n == k]
            in i
          sawIx  = ixOf KSawOsc rtF
          lpfIx  = ixOf KLPF    rtF
          gainIx = ixOf KGain   rtF
          outIx  = ixOf KOut    rtF

      let sizeOfFloat' = 4 :: Int
          renderBus loader rt readBus =
            withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
              loader handle rt
              c_rt_graph_ensure_bus handle (fromIntegral newBus)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral sawIx)  0 (CDouble newSawFreq)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral lpfIx)  0 (CDouble newLpfFreq)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral lpfIx)  1 (CDouble newLpfQ)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral gainIx) 0 (CDouble newGain)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral outIx)  0 (CDouble (fromIntegral newBus))
              c_rt_graph_process handle (fromIntegral nframes)
              allocaBytes (nframes * sizeOfFloat') $ \buf -> do
                _ <- c_rt_graph_read_bus handle (fromIntegral readBus)
                                         (fromIntegral nframes) (castPtr buf)
                cs <- peekArray nframes (buf :: PtrCFloat)
                pure (map (\(CFloat x) -> x) cs)

      baselineSamples <- renderBus loadRuntimeGraph      rtUn newBus
      fusedSamples    <- renderBus loadRuntimeGraphFused rtF  newBus

      length baselineSamples @?= length fusedSamples
      assertBool
        ("Phase 4.B: 4-node kernel set_control divergence on bus " <> show newBus)
        (baselineSamples == fusedSamples)

      -- Sanity: a 220 Hz saw through an LPF cutoff at 1500 Hz with
      -- moderate Q, scaled by 0.3, must produce non-silent output.
      -- Bounds are loose — exact peak depends on filter response —
      -- the goal is just to flag a stuck-zero render.
      let peak = maximum (map abs baselineSamples)
      assertBool ("expected non-silent render on bus " <> show newBus
                  <> ", got peak " <> show peak)
                 (peak > 0.05)

  , -- Phase 4.B: 'RBusInLpfGainOut' control identity. Mirrors the
    -- 'RSawLpfGainOut' set_control test but exercises the controls
    -- specific to the BusIn-rooted shape: busin.bus (slot 0),
    -- lpf.freq (slot 0), lpf.q (slot 1), gain.amount, and
    -- out.bus. Critically, busin.bus is the new ground here: the
    -- kernel reads 'output_buses[busin_bus][i]' inline, so
    -- redirecting the BusIn to a different source bus must steer
    -- the kernel exactly as it steers the per-node 'process_busin'
    -- baseline.
    --
    -- The graph carries /two/ independent voice writers — a 440 Hz
    -- sine on bus 5 (the BusIn's graph default) and a 220 Hz saw
    -- on bus 6 (the redirect target). Setting busin.bus from 5 to
    -- 6 swaps the entire downstream signal: LPF now filters a
    -- saw, gain scales the saw, the sink accumulates the filtered
    -- saw. If the kernel hard-coded the source bus or otherwise
    -- didn't honor live control writes, the baseline would
    -- observe the redirect through 'process_busin' but the fused
    -- path would still read the sine — they'd diverge. Bit-
    -- equivalence on the redirected sink bus pins that the kernel
    -- reads 'busin.controls[0]' fresh on every block.
    testCase "Phase 4.B: set_control on RBusInLpfGainOut covers busin.bus + lpf.freq/q + gain + out.bus" $ do
      let nframes = 256
          chain = runSynth $ do
            o1 <- sinOsc 440.0 0.0
            busOut 5 o1                              -- bus 5: 440 Hz sine (busIn graph default)
            o2 <- sawOsc 220.0 0.0
            busOut 6 o2                              -- bus 6: 220 Hz saw (redirect target)
            r <- busIn 5
            f <- lpf r (Param 800.0) (Param 4.0)
            a <- gain f (Param 0.4)
            out 0 a                                  -- initial sink: bus 0
          newLpfFreq    = 1500.0 :: Double
          newLpfQ       = 6.0    :: Double
          newGain       = 0.3    :: Double
          newSinkBus    = 2      :: Int              -- redirect sink
          newBusInBus   = 6      :: Int              -- redirect to the saw writer

      rtUnRaw <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      assertBool "Phase 4.B: fused compile has no RBusInLpfGainOut region"
        (any ((== RBusInLpfGainOut) . rrKernel) (rgRuntimeRegions rtF))

      let rtUn = stripRegionKernels rtUnRaw

          ixOf k rg =
            let NodeIndex i = head [rnIndex n | n <- rgNodes rg, rnKind n == k]
            in i
          busInIx = ixOf KBusIn rtF
          lpfIx   = ixOf KLPF   rtF
          gainIx  = ixOf KGain  rtF
          outIx   = ixOf KOut   rtF

      let sizeOfFloat' = 4 :: Int
          renderBus loader rt readBus =
            withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
              loader handle rt
              c_rt_graph_ensure_bus handle (fromIntegral newSinkBus)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral busInIx) 0 (CDouble (fromIntegral newBusInBus))
              c_rt_graph_instance_set_control handle 0
                (fromIntegral lpfIx)   0 (CDouble newLpfFreq)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral lpfIx)   1 (CDouble newLpfQ)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral gainIx)  0 (CDouble newGain)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral outIx)   0 (CDouble (fromIntegral newSinkBus))
              c_rt_graph_process handle (fromIntegral nframes)
              allocaBytes (nframes * sizeOfFloat') $ \buf -> do
                _ <- c_rt_graph_read_bus handle (fromIntegral readBus)
                                         (fromIntegral nframes) (castPtr buf)
                cs <- peekArray nframes (buf :: PtrCFloat)
                pure (map (\(CFloat x) -> x) cs)

      baselineSamples <- renderBus loadRuntimeGraph      rtUn newSinkBus
      fusedSamples    <- renderBus loadRuntimeGraphFused rtF  newSinkBus

      length baselineSamples @?= length fusedSamples
      assertBool
        ("Phase 4.B: RBusInLpfGainOut set_control divergence on bus "
         <> show newSinkBus)
        (baselineSamples == fusedSamples)

      -- Sanity: a 440 Hz sine through an LPF at 1500 Hz with
      -- moderate Q, scaled by 0.3, must produce non-silent output
      -- on the redirected bus. Same loose-peak threshold as the
      -- RSawLpfGainOut variant.
      let peak = maximum (map abs baselineSamples)
      assertBool ("expected non-silent render on bus " <> show newSinkBus
                  <> ", got peak " <> show peak)
                 (peak > 0.05)

  , -- Phase 4.B regression: 'RBusInLpfGainOut' state advancement
    -- on an invalid source bus.
    --
    -- Background: the per-node 'process_busin' fills its output
    -- buffer with zeros when 'busin.bus' is invalid, and
    -- 'process_lpf' /still runs/ over those zeros — advancing the
    -- IIR state and emitting the filter's natural decay envelope
    -- if the state was non-zero from a prior valid block. An
    -- early version of 'process_region_busin_lpf_gain_out'
    -- silent-no-op'd the entire block on invalid 'busin.bus',
    -- which froze the LPF state and skipped all 'block_sink_peak'
    -- + sink-accumulation work. The bug surfaces on a subsequent
    -- valid-bus block as a state mismatch: the per-node baseline's
    -- LPF state has settled toward zero, while the buggy fused
    -- side's still holds the prior block's filter history.
    --
    -- This test deliberately walks that exact transition: warm
    -- the LPF on a real signal, switch 'busin.bus' to an invalid
    -- index for one block, switch back to a valid index, and
    -- compare every block's sink output against the stripped
    -- baseline. Bit-equivalence across all four blocks pins that
    -- the kernel's invalid-bus path keeps the LPF advancing.
    testCase "Phase 4.B: RBusInLpfGainOut state advances on invalid source bus" $ do
      let nframes    = 256
          validBus   = 5  :: Int
          invalidBus = -1 :: Int                     -- triggers silent-source path
          chain = runSynth $ do
            o <- sinOsc 220.0 0.0
            busOut validBus o                        -- voice writes the BusIn's source
            r <- busIn validBus
            f <- lpf r (Param 800.0) (Param 6.0)     -- moderate Q: noticeable ringing decay
            a <- gain f (Param 0.6)
            out 0 a

      rtUnRaw <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      assertBool "fused compile lacks RBusInLpfGainOut"
        (any ((== RBusInLpfGainOut) . rrKernel) (rgRuntimeRegions rtF))

      let rtUn    = stripRegionKernels rtUnRaw
          ixOf k rg =
            let NodeIndex i = head [rnIndex n | n <- rgNodes rg, rnKind n == k]
            in i
          busInIx = ixOf KBusIn rtF

      let sizeOfFloat' = 4 :: Int
          -- Render four blocks with control flips between them, and
          -- return the per-block sink bus reads in execution order.
          -- Reading the bus after each block (rather than only at
          -- the end) lets the assertion message show /which/ block
          -- diverged when the test fails — block 3 indicts the
          -- silent-block decay; block 4 indicts the post-transition
          -- state mismatch.
          renderSequence loader rt =
            withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
              loader handle rt
              let processAndRead = do
                    c_rt_graph_process handle (fromIntegral nframes)
                    allocaBytes (nframes * sizeOfFloat') $ \buf -> do
                      _ <- c_rt_graph_read_bus handle 0
                             (fromIntegral nframes) (castPtr buf)
                      cs <- peekArray nframes (buf :: PtrCFloat)
                      pure (map (\(CFloat x) -> x) cs)
              -- Blocks 1+2: valid source bus. LPF state warms up
              -- on the 220 Hz sine.
              b1 <- processAndRead
              b2 <- processAndRead
              -- Switch BusIn to invalid; run block 3.
              c_rt_graph_instance_set_control handle 0
                (fromIntegral busInIx) 0
                (CDouble (fromIntegral invalidBus))
              b3 <- processAndRead
              -- Switch back to valid; run block 4. State mismatch
              -- from block 3 surfaces here as a transient diff.
              c_rt_graph_instance_set_control handle 0
                (fromIntegral busInIx) 0
                (CDouble (fromIntegral validBus))
              b4 <- processAndRead
              pure [b1, b2, b3, b4]

      baselineBlocks <- renderSequence loadRuntimeGraph      rtUn
      fusedBlocks    <- renderSequence loadRuntimeGraphFused rtF

      length baselineBlocks @?= length fusedBlocks
      let labeled = zip3 ([1..] :: [Int]) baselineBlocks fusedBlocks
      sequence_
        [ assertBool
            ("RBusInLpfGainOut: fused diverges from per-node baseline "
             <> "on block " <> show n
             <> " (block 3 indicts silent-bus state freeze; "
             <> "block 4 indicts post-transition state mismatch)")
            (b == f)
        | (n, b, f) <- labeled
        ]

      -- Sanity: blocks 1+2 (warm LPF on a 220 Hz sine through 800 Hz
      -- LPF, scaled by 0.6) must be non-silent — otherwise the
      -- "LPF state actually warmed up" premise of the test fails
      -- and a regression on the silent-bus path would slip past.
      let warmPeak = maximum
            (map abs (concat (take 2 fusedBlocks)))
      assertBool
        ("expected LPF to warm up on the valid bus, peak=" <> show warmPeak)
        (warmPeak > 0.05)

  , -- Phase 4.B: 'RNoiseLpfGainOut' control identity. NoiseGen has
    -- no controls of its own (the PRNG state isn't redirectable by
    -- a set_control write; it's owned by 'NoiseGenState'), so the
    -- live-control surface is just lpf.freq, lpf.q, gain.amount,
    -- and out.bus. Bit-equivalence with the stripped node-loop
    -- baseline pins three things at once:
    --
    --   * the kernel reads each LPF / Gain / Out control fresh on
    --     every block, just like 'process_lpf' / 'process_gain' /
    --     'process_out' do;
    --   * the LPF block-rate freq/q latch matches the per-node
    --     latch under control writes;
    --   * the kernel and per-node paths advance the
    --     'q::white_noise_gen' state at the same rate (one pull
    --     per output sample) — the load-bearing PRNG-cadence
    --     parity.
    testCase "Phase 4.B: set_control on RNoiseLpfGainOut covers lpf.freq/q + gain + out.bus" $ do
      let nframes = 256
          chain = runSynth $ do
            n <- noiseGen
            f <- lpf n (Param 800.0) (Param 4.0)
            a <- gain f (Param 0.4)
            out 0 a
          newLpfFreq = 1500.0 :: Double
          newLpfQ    = 6.0    :: Double
          newGain    = 0.3    :: Double
          newSinkBus = 2      :: Int

      rtUnRaw <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      assertBool "Phase 4.B: fused compile has no RNoiseLpfGainOut region"
        (any ((== RNoiseLpfGainOut) . rrKernel) (rgRuntimeRegions rtF))

      let rtUn = stripRegionKernels rtUnRaw

          ixOf k rg =
            let NodeIndex i = head [rnIndex n | n <- rgNodes rg, rnKind n == k]
            in i
          lpfIx  = ixOf KLPF  rtF
          gainIx = ixOf KGain rtF
          outIx  = ixOf KOut  rtF

      let sizeOfFloat' = 4 :: Int
          renderBus loader rt readBus =
            withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
              loader handle rt
              c_rt_graph_ensure_bus handle (fromIntegral newSinkBus)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral lpfIx)  0 (CDouble newLpfFreq)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral lpfIx)  1 (CDouble newLpfQ)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral gainIx) 0 (CDouble newGain)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral outIx)  0 (CDouble (fromIntegral newSinkBus))
              c_rt_graph_process handle (fromIntegral nframes)
              allocaBytes (nframes * sizeOfFloat') $ \buf -> do
                _ <- c_rt_graph_read_bus handle (fromIntegral readBus)
                                         (fromIntegral nframes) (castPtr buf)
                cs <- peekArray nframes (buf :: PtrCFloat)
                pure (map (\(CFloat x) -> x) cs)

      baselineSamples <- renderBus loadRuntimeGraph      rtUn newSinkBus
      fusedSamples    <- renderBus loadRuntimeGraphFused rtF  newSinkBus

      length baselineSamples @?= length fusedSamples
      assertBool
        ("Phase 4.B: RNoiseLpfGainOut set_control divergence on bus "
         <> show newSinkBus)
        (baselineSamples == fusedSamples)

      -- Sanity: filtered noise scaled by 0.3 through an LPF at
      -- 1500 Hz must produce non-silent output on the redirected
      -- bus. Same loose-peak threshold as the BusIn variant.
      let peak = maximum (map abs baselineSamples)
      assertBool ("expected non-silent render on bus " <> show newSinkBus
                  <> ", got peak " <> show peak)
                 (peak > 0.05)

  -- ----------------------------------------------------------------
  -- Multi-template loading (§2.D.3)
  -- ----------------------------------------------------------------
  --
  -- These tests exercise loadTemplateGraph end-to-end: a
  -- TemplateGraph compiled by compileTemplateGraph is transferred
  -- across the FFI, the C-side process_graph runs templates in
  -- registration order with one auto-spawned instance per template,
  -- and bus reads confirm both per-template independence and
  -- cross-template routing through the shared bus pool.

  , testCase "loadTemplateGraph: single-template ensemble runs identically to loadRuntimeGraph" $ do
      let nframes = 256
          single  = runSynth $ do
            o <- sinOsc 440.0 0.0
            out 0 o

      -- Reference: legacy loadRuntimeGraph path.
      rt <- case lowerGraph single >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      legacyBus <- withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          pure (map (\(CFloat x) -> x) cs)

      -- Multi-template path with a one-template ensemble.
      tg <- case compileTemplateGraph [("solo", single)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      tgBus <- withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadTemplateGraph handle tg
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          pure (map (\(CFloat x) -> x) cs)

      -- Both paths must produce bit-identical samples: the spec
      -- defaults loadTemplateGraph writes via
      -- rt_graph_template_set_default propagate to the auto-spawned
      -- instance, so the resulting RTGraph state is equivalent to
      -- the legacy single-template setup.
      assertBool "single-template ensemble should match legacy load"
                 (legacyBus == tgBus)

  , -- Step C (e) coverage: 'loadTemplateGraphFused' has its own
    -- lifecycle (remove auto-instance, populate per-template, spawn
    -- after fused wiring) distinct from the single-template fused
    -- loader. Pin that a fused single-template ensemble loaded
    -- through the multi-template fused path renders bit-identically
    -- to the same fused graph loaded through the single-template
    -- fused path. This exercises:
    --   * cTid 0 path for the first (and only) template.
    --   * Fused-input wiring before instance spawn — make_instance
    --     picks up the spec's full fused_input_count.
    --   * Elision marking against template id 0.
    testCase "loadTemplateGraphFused: single-template ensemble matches loadRuntimeGraphFused" $ do
      -- 'Env' source: durable §4.C-only fixture. The test
      -- specifically wants §4.C's RFused-on-Out wiring exercised
      -- through the single-template ensemble path, with no
      -- chance of §4.B claiming the chain instead.
      let nframes = 256
          fusedChain = runSynth $ do
            o <- env (Param 1.0) 0.0005 0.002 1.0 0.002
            a <- gain o (Param 0.5)
            out 0 a

      rt <- case lowerGraph fusedChain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      -- Sanity: the fused compile actually produced fused signals
      -- so the test exercises the new loader passes.
      assertBool "fused chain produced no RFused inputs"
        (not (null [() | n <- rgNodes rt, RFused _ <- rnInputs n]))
      assertBool "fused chain elided no nodes"
        (any rnElided (rgNodes rt))

      singleBus <- withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraphFused handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          pure (map (\(CFloat x) -> x) cs)

      tg <- case compileTemplateGraphFused [("solo", fusedChain)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      -- The fused TemplateGraph must actually carry RFused inputs
      -- and elided nodes; otherwise loadTemplateGraphFused's new
      -- passes never run and a regression in them slips past.
      let tgRg = tplGraph (head (tgTemplates tg))
      assertBool "fused TemplateGraph carried no RFused inputs"
        (not (null [() | n <- rgNodes tgRg, RFused _ <- rnInputs n]))
      assertBool "fused TemplateGraph elided no nodes"
        (any rnElided (rgNodes tgRg))

      tgBus <- withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadTemplateGraphFused handle tg
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          pure (map (\(CFloat x) -> x) cs)

      assertBool "fused single-template ensemble should match fused single load"
                 (singleBus == tgBus)

  , testCase "loadTemplateGraph: registers N templates with N instances" $ do
      -- A two-template ensemble. Both produce independent SinOsc
      -- voices on different hardware buses.
      let voiceA = runSynth $ do
            o <- sinOsc 220.0 0.0
            out 0 o
          voiceB = runSynth $ do
            o <- sinOsc 660.0 0.0
            out 1 o

      tg <- case compileTemplateGraph [("a", voiceA), ("b", voiceB)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes = sum (map (length . rgNodes . tplGraph)
                                (tgTemplates tg))

      withRTGraph totalNodes 256 $ \handle -> do
        loadTemplateGraph handle tg

        -- After loading: two templates, two live instances (one per
        -- template). The auto-created instance 0 from rt_graph_clear
        -- was removed by loadTemplateGraph, so instance ids are 0
        -- and 1, both alive.
        nT <- c_rt_graph_template_count handle
        nT @?= 2
        nI <- c_rt_graph_instance_count handle
        nI @?= 2
        a0 <- c_rt_graph_instance_alive handle 0
        a1 <- c_rt_graph_instance_alive handle 1
        a0 @?= 1
        a1 @?= 1

        c_rt_graph_process handle 256
        allocaBytes (256 * sizeOfFloat) $ \buf -> do
          -- Bus 0: voice A's 220 Hz sine.
          _ <- c_rt_graph_read_bus handle 0 256 (castPtr buf)
          cs0 <- peekArray 256 (buf :: PtrCFloat)
          let peak0 = maximum (map (\(CFloat x) -> abs x) cs0)
          assertBool ("bus 0 (voice A) should sing, peak=" <> show peak0)
                     (peak0 > 0.9)

          -- Bus 1: voice B's 660 Hz sine.
          _ <- c_rt_graph_read_bus handle 1 256 (castPtr buf)
          cs1 <- peekArray 256 (buf :: PtrCFloat)
          let peak1 = maximum (map (\(CFloat x) -> abs x) cs1)
          assertBool ("bus 1 (voice B) should sing, peak=" <> show peak1)
                     (peak1 > 0.9)

  , -- Phase 4.B: 'RBusInLpfGainOut' end-to-end through a real
    -- multi-template send/return. The /fx/ template's
    -- @[BusIn, LPF, Gain, Out]@ chain is what the survey's
    -- BusIn-rooted opportunity scan was tracking; this test pins
    -- bit-equivalence between the kernel and the per-node baseline
    -- /through the actual cross-template loader path/, not just a
    -- single-graph approximation.
    --
    -- 'compileTemplateGraph' compiles each template through
    -- 'compileRuntimeGraph' (which runs 'selectRegionKernels'
    -- unconditionally), so the fx template's chain claims
    -- 'RBusInLpfGainOut' on the fused side. The baseline strips
    -- region kernels per template — same TemplateGraph shape, just
    -- per-node dispatch — so the comparison isolates the kernel's
    -- output from any other change.
    testCase "loadTemplateGraph: cross-template send/return claims RBusInLpfGainOut bit-equivalently" $ do
      let nframes = 256
          voice = runSynth $ do
            o <- sinOsc 440.0 0.0
            busOut 5 o                            -- voice template writes bus 5
          fx = runSynth $ do
            r <- busIn 5
            f <- lpf r (Param 1500.0) (Param 4.0)
            a <- gain f (Param 0.6)
            out 0 a                               -- fx-tail kernel sinks to bus 0

      tg <- case compileTemplateGraph [("voice", voice), ("fx", fx)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      -- Sanity: the fx template's chain claims RBusInLpfGainOut.
      -- If this assertion fires, the test isn't testing what it
      -- claims (a future kernel-precondition tightening might have
      -- silently disclaimed the chain).
      let fxTpl = head [t | t <- tgTemplates tg, tplName t == "fx"]
          fxKernels = map rrKernel (rgRuntimeRegions (tplGraph fxTpl))
      assertBool "fx template should carry an RBusInLpfGainOut region"
        (RBusInLpfGainOut `elem` fxKernels)

      -- Stripped TemplateGraph: same shape, kernels forced to
      -- RNodeLoop. Per-node dispatch on the C side; bit-equivalent
      -- baseline by construction.
      let strippedTg = tg
            { tgTemplates =
                [ tpl { tplGraph = stripRegionKernels (tplGraph tpl) }
                | tpl <- tgTemplates tg ]
            }

      let totalNodes = sum (map (length . rgNodes . tplGraph)
                                (tgTemplates tg))
          renderTg label thisTg =
            withRTGraph totalNodes nframes $ \handle -> do
              loadTemplateGraph handle thisTg
              c_rt_graph_process handle (fromIntegral nframes)
              allocaBytes (nframes * sizeOfFloat) $ \buf -> do
                _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                         (castPtr buf)
                cs <- peekArray nframes (buf :: PtrCFloat)
                pure (label, map (\(CFloat x) -> x) cs)

      (_, fusedSamples)    <- renderTg "fused"    tg
      (_, baselineSamples) <- renderTg "baseline" strippedTg

      length fusedSamples @?= length baselineSamples
      assertBool
        ("RBusInLpfGainOut (template path): kernel diverges from "
         <> "per-node baseline on bus 0")
        (fusedSamples == baselineSamples)

      -- Sanity: the fx chain actually processes the voice signal
      -- — we want a non-silent render so any future regression
      -- where the kernel reads zeros (e.g. wrong source bus) shows
      -- up as a peak collapse, not as silently-bit-equivalent
      -- silence.
      let peak = maximum (map abs fusedSamples)
      assertBool ("expected non-silent send/return on bus 0, peak="
                  <> show peak)
                 (peak > 0.05)

  , testCase "loadTemplateGraph: cross-template routing (BusOut → BusIn through shared pool)" $ do
      -- Producer template writes a SinOsc to bus 5; consumer
      -- template reads bus 5 and routes to hardware bus 0. This is
      -- the headline §2.D.3 use case: two MetaDefs, server-global
      -- bus pool, compileTemplateGraph orders producer before
      -- consumer because consumer's read-set intersects producer's
      -- write-set.
      let producer = runSynth $ do
            o <- sinOsc 330.0 0.0
            busOut 5 o
          consumer = runSynth $ do
            t <- busIn 5
            out 0 t

      tg <- case compileTemplateGraph
                   [("consumer", consumer), ("producer", producer)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      -- compileTemplateGraph should have re-ordered: producer
      -- before consumer, regardless of input order.
      map tplName (tgTemplates tg) @?= ["producer", "consumer"]

      let totalNodes = sum (map (length . rgNodes . tplGraph)
                                (tgTemplates tg))

      withRTGraph totalNodes 256 $ \handle -> do
        loadTemplateGraph handle tg
        c_rt_graph_process handle 256

        allocaBytes (256 * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 256 (castPtr buf)
          cs <- peekArray 256 (buf :: PtrCFloat)
          let peak = maximum (map (\(CFloat x) -> abs x) cs)
          assertBool
            ("hardware bus 0 should carry the routed signal, peak="
              <> show peak)
            (peak > 0.9)

  , testCase "loadTemplateGraph: extra instances spawned post-load share the spec defaults" $ do
      -- After loadTemplateGraph spawns the initial instance per
      -- template, the user can call c_rt_graph_template_instance_add
      -- to spawn more instances of the same template. Those new
      -- instances inherit the spec defaults that
      -- rt_graph_template_set_default wrote during loading.
      let voice = runSynth $ do
            o <- sinOsc 440.0 0.0
            out 0 o

      tg <- case compileTemplateGraph [("voice", voice)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes = length (rgNodes (tplGraph (head (tgTemplates tg))))

      withRTGraph totalNodes 256 $ \handle -> do
        loadTemplateGraph handle tg

        -- Spawn a second instance of template 0. Should land at
        -- slot 1 (slot 0 is the auto-spawned one).
        i2 <- c_rt_graph_template_instance_add handle 0
        i2 @?= 1

        -- Reroute the second instance to bus 1 so its contribution
        -- is observable on its own. (Both instances default to
        -- bus 0, so they would otherwise sum.)
        --
        -- Out node is at index 1; control 0 is the bus index.
        c_rt_graph_instance_set_control handle 1 1 0 1.0

        c_rt_graph_process handle 256
        allocaBytes (256 * sizeOfFloat) $ \buf -> do
          -- Bus 0: original instance's 440 Hz sine.
          _ <- c_rt_graph_read_bus handle 0 256 (castPtr buf)
          cs0 <- peekArray 256 (buf :: PtrCFloat)
          let peak0 = maximum (map (\(CFloat x) -> abs x) cs0)
          assertBool ("bus 0 should sing, peak=" <> show peak0)
                     (peak0 > 0.9)

          -- Bus 1: second instance's 440 Hz sine (same spec
          -- default, different output bus).
          _ <- c_rt_graph_read_bus handle 1 256 (castPtr buf)
          cs1 <- peekArray 256 (buf :: PtrCFloat)
          let peak1 = maximum (map (\(CFloat x) -> abs x) cs1)
          assertBool
            ("bus 1 (second instance) should also sing, peak="
              <> show peak1)
            (peak1 > 0.9)

  , testCase "§2.E release-then-free: Live → Releasing → freed slot" $ do
      -- Smoke test for the §2.E lifecycle FFI surface
      -- (c_rt_graph_instance_release, c_rt_graph_instance_status):
      --   1. status is Live after load,
      --   2. flips to Releasing on release(),
      --   3. the slot is auto-freed once the envelope tail decays
      --      below the runtime's silence threshold for a small
      --      window (status -> -1, alive -> 0).
      -- See Note [§2.E: release-then-free instance lifecycle] in
      -- rt_graph.cpp for the design.
      let voice = runSynth $ do
            -- Held gate (1.0), short release so the test runs in
            -- a few dozen blocks rather than seconds.
            e <- env 1.0 0.0005 0.002 0.5 0.002
            out 0 e

      let rg = case lowerGraph voice >>= compileRuntimeGraph of
            Right r  -> r
            Left err -> error err
          totalNodes = length (rgNodes rg)

      withRTGraph totalNodes 256 $ \handle -> do
        loadRuntimeGraph handle rg

        -- Pre-release: the auto-spawned instance 0 is Live.
        s0 <- c_rt_graph_instance_status handle 0
        s0 @?= instanceStatusLive

        -- Render one block so the envelope leaves idle and reaches
        -- sustain. (Releasing an idle envelope is a degenerate case
        -- — q's release() is a no-op when the gate never opened.)
        c_rt_graph_process handle 256

        -- Trigger release. Status flips immediately; slot stays
        -- alive because the tail still has to render.
        c_rt_graph_instance_release handle 0
        s1 <- c_rt_graph_instance_status handle 0
        s1 @?= instanceStatusReleasing
        a1 <- c_rt_graph_instance_alive handle 0
        a1 @?= 1

        -- Drive blocks until the runtime auto-frees the slot. With
        -- R = 2 ms and silence-window = 8 blocks of 256 frames at
        -- 48 kHz, ~64 blocks is a comfortable upper bound.
        let drain n
              | n <= 0    = pure False
              | otherwise = do
                  c_rt_graph_process handle 256
                  alive <- c_rt_graph_instance_alive handle 0
                  if alive == 0 then pure True else drain (n - 1)
        freed <- drain 64
        assertBool "instance should auto-free within 64 blocks" freed

        -- Post-free: status is -1 (dead/invalid).
        s2 <- c_rt_graph_instance_status handle 0
        s2 @?= (-1)

  , -- Phase 4.B sink-terminal kernel × §2.E release lifecycle.
    -- The 'process_region_sin_gain_out' kernel takes over the bus
    -- accumulation /and/ the per-block 'inst.block_sink_peak'
    -- update from 'process_out'. §2.E silence detection reads
    -- block_sink_peak after each instance runs; a kernel that
    -- forgot to update it would either free voices too early
    -- (peak under-reported) or never (peak stuck at the last
    -- value).
    --
    -- Both variants register an RSinGainOut region and an Env on
    -- a separate bus. The Env's release decay drives the §2.E
    -- state machine; the kernel's gain control determines whether
    -- the fused chain contributes to peak.
    --
    --   variantA: gain = 0.0  → kernel writes silence; once Env
    --             tail decays, peak < threshold, voice frees.
    --   variantB: gain = 0.5  → kernel writes |sin|·0.5 ≈ 0.5
    --             every block, /forever/. Even after Env decays,
    --             the kernel's contribution keeps peak above the
    --             silence threshold and the voice never frees.
    --
    -- A bug where the kernel didn't update block_sink_peak at all
    -- would flip variantB to "frees" — caught here.
    testCase "Phase 4.B kernel: sink-peak tracking gates §2.E release-then-free" $ do
      let mkVoice scalarGain = runSynth $ do
            s <- sinOsc 440.0 0.0
            a <- gain s (Param scalarGain)
            out 1 a                      -- kernel chain on bus 1
            e <- env 1.0 0.0005 0.002 0.5 0.002
            out 0 e                       -- env on bus 0

          driveAndDrain g maxBlocks = do
            let rg = case lowerGraph g >>= compileRuntimeGraph of
                  Right r  -> r
                  Left err -> error err
                totalNodes = length (rgNodes rg)
            -- Sanity: §4.B is actually claiming the kernel chain.
            assertBool "voice does not contain RSinGainOut region"
              (any ((== RSinGainOut) . rrKernel) (rgRuntimeRegions rg))
            withRTGraph totalNodes 256 $ \handle -> do
              loadRuntimeGraph handle rg
              -- One block to leave envelope-idle and reach sustain.
              c_rt_graph_process handle 256
              c_rt_graph_instance_release handle 0
              let drain n
                    | n <= 0    = pure False
                    | otherwise = do
                        c_rt_graph_process handle 256
                        alive <- c_rt_graph_instance_alive handle 0
                        if alive == 0 then pure True else drain (n - 1)
              drain maxBlocks

      freedSilent <- driveAndDrain (mkVoice 0.0) 64
      assertBool
        "variantA (silent kernel + Env): voice should auto-free within 64 blocks"
        freedSilent

      freedAudible <- driveAndDrain (mkVoice 0.5) 64
      assertBool
        "variantB (audible kernel + Env): voice must NOT free — kernel keeps sink-peak above threshold"
        (not freedAudible)
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


------------------------------------------------------------
-- Step C (f): fused render equivalence cases + helper
------------------------------------------------------------

-- | Demo-shaped graphs that all contain at least one fusable Gain.
-- 'assertFusedEquivalent' renders each one through the unfused and
-- fused FFI loaders and asserts bit-for-bit sample equality. Cases
-- that don't fuse (no scalar Gain, e.g. NoiseGen-only chains, or
-- audio-modulated gain) are excluded — they would pass trivially
-- because 'fuseRuntimeGraph' is a no-op on them.
fusedEquivalenceCases :: [(String, SynthGraph)]
fusedEquivalenceCases =
  [ ("chain", runSynth $ do
       o <- sinOsc 440.0 0.0
       a <- gain o (Param 0.5)
       out 0 a)

  , ("fanout (two scalar Gains share a SinOsc)", runSynth $ do
       o  <- sinOsc 440.0 0.0
       g1 <- gain o (Param 0.5)
       g2 <- gain o (Param 0.3)
       out 0 g1
       out 1 g2)

  , ("saw → lpf → scalar gain → out", runSynth $ do
       s <- sawOsc 110.0 0.0
       f <- lpf s (Param 800.0) (Param 4.0)
       a <- gain f (Param 0.4)
       out 0 a)

    -- BusOut as sink terminal. The §4.B sink-terminal kernels
    -- ('RSinGainOut' / 'RSawLpfGainOut') accept either KOut or
    -- KBusOut at the terminal slot. Both render paths (kernel
    -- fused vs stripRegionKernels node-loop baseline) read the
    -- bus index from controls[0] and accumulate into the same
    -- bus pool, so bit-equivalence on the resulting bus is the
    -- structural pin that the kernel body really is bus-kind-
    -- agnostic (i.e. that the dispatch guard and the kernel
    -- agree on what "sink" means).
  , ("§4.B sink-terminal via busOut: sin → gain → busOut", runSynth $ do
       o <- sinOsc 440.0 0.0
       a <- gain o (Param 0.5)
       busOut 0 a)

  , ("§4.B sink-terminal via busOut: saw → lpf → gain → busOut", runSynth $ do
       s <- sawOsc 110.0 0.0
       f <- lpf s (Param 800.0) (Param 4.0)
       a <- gain f (Param 0.4)
       busOut 0 a)

    -- 'RSawGainOut' coverage: the saw counterpart of the
    -- 'RSinGainOut' chain case. q::saw with poly-BLEP × scalar
    -- gain → bus accumulation. Bit-identical to the per-node
    -- chain (process_sawosc + process_gain + process_out) by
    -- construction.
  , ("§4.B sink-terminal: saw → gain → out", runSynth $ do
       s <- sawOsc 110.0 0.0
       a <- gain s (Param 0.4)
       out 0 a)

  , ("§4.B sink-terminal via busOut: saw → gain → busOut", runSynth $ do
       s <- sawOsc 110.0 0.0
       a <- gain s (Param 0.4)
       busOut 0 a)

    -- 'RNoiseGainOut' coverage. Different state class than the
    -- oscillator kernels: NoiseGen carries a 'q::white_noise_gen'
    -- xorshift PRNG. The kernel calls 'noise()' once per output
    -- sample — same cadence as 'process_noisegen' — so two
    -- compiles of the same graph see identical PRNG sequences.
    -- 'assertFusedEquivalent' compares against a
    -- 'stripRegionKernels' baseline that drives the same fresh
    -- 'NoiseGenState' through 'process_noisegen', so any drift
    -- in PRNG-advance cadence between the kernel and per-node
    -- paths shows up as a sample-level diff. This is the
    -- load-bearing equivalence pin for the noise kernel.
  , ("§4.B sink-terminal: noise → gain → out", runSynth $ do
       n <- noiseGen
       a <- gain n (Param 0.4)
       out 0 a)

  , ("§4.B sink-terminal via busOut: noise → gain → busOut", runSynth $ do
       n <- noiseGen
       a <- gain n (Param 0.4)
       busOut 0 a)

    -- 'RBusInLpfGainOut' coverage. The first non-oscillator
    -- producer kernel: source is a bus reader, not a generator.
    -- The fused kernel reads 'output_buses[busin_bus][i]' inline
    -- (mirroring 'process_busin's std::copy_n + per-node LPF +
    -- per-node Gain + per-node Out); the stripped baseline runs
    -- those same per-node steps in sequence. Bit-equivalence on
    -- the sink bus pins that the inlined bus read produces the
    -- same float as the materialized 'process_busin' copy would
    -- have, in the same per-sample order.
    --
    -- We pair a BusOut writer with the BusIn reader in the same
    -- graph (bus 5 carries a SinOsc) so the chain processes a
    -- real signal rather than silence from an unwritten bus —
    -- otherwise the test would degenerate into "fused silence ==
    -- baseline silence", which is too weak to catch a per-sample
    -- divergence introduced by a future change.
  , ("§4.B sink-terminal: busIn → lpf → gain → out", runSynth $ do
       o <- sinOsc 440.0 0.0
       busOut 5 o                              -- voice side: bus 5 carries the carrier
       r <- busIn 5
       f <- lpf r (Param 1500.0) (Param 4.0)
       a <- gain f (Param 0.6)
       out 0 a)                                -- fx-tail kernel sinks to bus 0

  , ("§4.B sink-terminal via busOut: busIn → lpf → gain → busOut", runSynth $ do
       o <- sinOsc 440.0 0.0
       busOut 5 o
       r <- busIn 5
       f <- lpf r (Param 1500.0) (Param 4.0)
       a <- gain f (Param 0.6)
       busOut 1 a)                             -- BusOut as absorbed terminal

    -- 'RNoiseLpfGainOut' coverage. PRNG-cadence parity is the
    -- load-bearing invariant: 'process_region_noise_lpf_gain_out'
    -- calls 'noisegen->noise()' exactly once per output sample, in
    -- the same order 'process_noisegen' does, before recentering
    -- and feeding the LPF. The stripped baseline drives the same
    -- fresh 'NoiseGenState' through 'process_noisegen' frame-by-
    -- frame, so any drift in PRNG-advance cadence between fused
    -- and per-node paths shows up as a sample-level diff in the
    -- bus accumulation. This is the equivalence pin that catches
    -- a future change accidentally double-pulling, skipping, or
    -- reordering the PRNG step relative to the LPF transition.
  , ("§4.B sink-terminal: noise → lpf → gain → out", runSynth $ do
       n <- noiseGen
       f <- lpf n (Param 1200.0) (Param 4.0)
       a <- gain f (Param 0.3)
       out 0 a)

  , ("§4.B sink-terminal via busOut: noise → lpf → gain → busOut", runSynth $ do
       n <- noiseGen
       f <- lpf n (Param 1200.0) (Param 4.0)
       a <- gain f (Param 0.3)
       busOut 0 a)                             -- BusOut as absorbed terminal

  , ("ring mod (audio-mod gain stays dispatched, output gain fuses)", runSynth $ do
       c <- sinOsc 440.0 0.0
       m <- sinOsc 73.0  0.0
       r <- gain c m              -- audio-modulated: no fusion (kept dispatched)
       a <- gain r (Param 0.5)    -- scalar: fuses
       out 0 a)

  , ("fm carrier with scalar output gain", runSynth $ do
       lfo <- sinOsc 6.0 0.0
       dev <- gain lfo (Param 8.0)        -- scalar dev gain: fuses into carrier.freq
       car <- sinOsc dev 0.0
       a   <- gain car (Param 0.4)        -- scalar output gain: fuses into Out
       out 0 a)

  -- Chain extension cases. Two and three consecutive scalar Gains
  -- collapse into one fused chain on Out's input. The fused
  -- resolver must apply each scale in source-to-sink order and
  -- cast control to float per step (no pre-multiplication), so
  -- the rendered samples must be bit-identical to the unfused
  -- chain of process_gain kernels.
  , ("scalar Gain chain x2", runSynth $ do
       o  <- sinOsc 440.0 0.0
       a1 <- gain o  (Param 0.5)
       a2 <- gain a1 (Param 0.25)
       out 0 a2)

  , ("scalar Gain chain x3", runSynth $ do
       o  <- sinOsc 440.0 0.0
       a1 <- gain o  (Param 0.5)
       a2 <- gain a1 (Param 0.25)
       a3 <- gain a2 (Param 0.125)
       out 0 a3)

  -- Phase 4.C.2 affine cases. A single Add elides into FAffineFrom
  -- [AffBias _ _]; mixed Gain/Add chains compose end-to-end through
  -- one FAffineFrom on Out's input. The fused resolver applies each
  -- step in source-to-sink order with the same NaN sanitization as
  -- the unfused kernels, so output must be bit-identical.
  , ("scalar Add bias", runSynth $ do
       o <- sinOsc 440.0 0.0
       b <- add o (Param 0.1)
       out 0 b)

  , ("Add (bias on port 0)", runSynth $ do
       o <- sinOsc 440.0 0.0
       b <- add (Param 0.1) o
       out 0 b)

  , ("Gain → Add composition", runSynth $ do
       o <- sinOsc 440.0 0.0
       a <- gain o (Param 0.5)
       b <- add  a (Param 0.1)
       out 0 b)

  , ("Add → Gain composition", runSynth $ do
       o <- sinOsc 440.0 0.0
       b <- add  o (Param 0.1)
       a <- gain b (Param 0.5)
       out 0 a)

  , ("Gain → Add → Gain mixed chain", runSynth $ do
       o  <- sinOsc 440.0 0.0
       a1 <- gain o  (Param 0.5)
       b  <- add  a1 (Param 0.1)
       a2 <- gain b  (Param 0.25)
       out 0 a2)
  ]

-- | QuickCheck property: for any deterministic, renderable graph
-- produced by 'genFusableRenderableGraph', the fused runtime path
-- must render bit-identical samples to a node-loop baseline on
-- every bus the graph writes.
--
-- The point of this property is /not/ to hand-check more topology
-- shapes than the structural unit tests already do; it's to exercise
-- the contract — same dense graph identity, same FFI lifecycle, same
-- C++ resolver — over random topology, including shapes nobody
-- thought to write down. Bit-equivalence (===) is the right
-- comparison: process_gain / process_add scalar branches, the chain
-- resolver, and the affine resolver all use the same NaN-sanitized
-- @float@ casts, so any difference is a bug.
--
-- The baseline side applies 'stripRegionKernels' before render so
-- 'loadRuntimeGraph' takes the per-node dispatch path on every
-- region, even ones §4.B would have claimed. Without the strip,
-- 'compileRuntimeGraph' itself would have already tagged matching
-- regions with kernels and a broken 'process_region_*' could pass
-- by matching itself — same blind spot the named-case helper
-- 'assertFusedEquivalent' avoids.
--
-- 'cover' gates the fraction of cases that actually exercise fusion
-- on the fused path. The predicate mirrors 'assertFusedEquivalent':
-- a graph counts as fused if the fused compile produced any of (a)
-- an 'RFused' input, (b) an 'rnElided' node, or (c) a non-'RNodeLoop'
-- region. Each prong is a distinct fusion mechanism — §4.C single-
-- input rewrites contribute (a) and (b), §4.B region kernels
-- contribute (c). A predicate that only checked rnElided would
-- mis-classify minimal §4.B-only cases (e.g. sin → gain → out, which
-- the 'RSinGainOut' kernel claims before §4.C can elide the gain) as
-- "no fusion," even though they are real fused-kernel-vs-baseline
-- comparisons. This protects the property from degenerating into a
-- sanity check on two equivalent loader paths if the generator
-- later drifts away from fusable shapes. A trivial 'True' is
-- returned for graphs that compile cleanly but write no comparable
-- buses, classified separately.
prop_fusedRenderEqualsUnfused :: SynthGraph -> Property
prop_fusedRenderEqualsUnfused graph =
  case (lowerGraph graph >>= compileRuntimeGraph,
        lowerGraph graph >>= compileRuntimeGraphFused) of
    (Left e,  _      ) -> counterexample ("baseline compile failed: " <> e) False
    (_,       Left e ) -> counterexample ("fused compile failed: "    <> e) False
    (Right rtUn0, Right rtF) ->
      -- Strip region kernels from the baseline so its render takes
      -- the per-node dispatch path; rgNodes/controls are unchanged,
      -- so the bus walk below still sees every Out/BusOut.
      let rtUn  = stripRegionKernels rtUn0
          buses = nub
            [ truncate v
            | n <- rgNodes rtUn
            , rnKind n == KOut || rnKind n == KBusOut
            , v : _ <- [rnControls n]
            , v >= 0
            ] :: [Int]
          triggered = fusedSomehow rtF
       in checkCoverage
        . cover 90 triggered          "fusion triggered"
        . classify (not triggered)    "no fusion (vacuous on fused path)"
        . classify (null buses)       "no comparable bus (vacuous render)"
        $ ioProperty $
          if null buses
            then pure (property True)
            else do
              let nframes = 64
                  sizeOfFloat = 4
                  cap = max 1 (length (rgNodes rtUn))
                  render loader rt =
                    withRTGraph cap nframes $ \handle -> do
                      _ <- loader handle rt
                      c_rt_graph_process handle (fromIntegral nframes)
                      allocaBytes (nframes * sizeOfFloat) $ \buf ->
                        traverse (readBus handle buf) buses
                  readBus handle buf bus = do
                    _ <- c_rt_graph_read_bus handle (fromIntegral bus)
                                             (fromIntegral nframes) (castPtr buf)
                    cs <- peekArray nframes (buf :: PtrCFloat)
                    pure (bus, map (\(CFloat x) -> x) cs)
              baseline <- render loadRuntimeGraph      rtUn
              fused    <- render loadRuntimeGraphFused rtF
              pure $ counterexample ("buses compared: " <> show buses)
                   $ baseline === fused

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

-- | A 'RuntimeGraph' has been touched by some form of fusion if it
-- carries §4.C single-input rewrite artifacts (an 'RFused' input
-- or an 'rnElided' node) or a §4.B region-kernel claim (any
-- region whose 'rrKernel' is not 'RNodeLoop'). Used as the sanity
-- gate by both 'assertFusedEquivalent' and the random
-- 'prop_fusedRenderEqualsUnfused' so a regression in either path
-- (or a generator that drifts toward unfusable shapes) is caught
-- the same way. Centralised so the two call sites cannot drift
-- as more fusion mechanisms land.
fusedSomehow :: RuntimeGraph -> Bool
fusedSomehow rg =
  not (null [() | n <- rgNodes rg, RFused _ <- rnInputs n])
    || any rnElided (rgNodes rg)
    || any ((/= RNodeLoop) . rrKernel) (rgRuntimeRegions rg)

-- | Render @graph@ through a node-loop baseline and the fused
-- loader, asserting their outputs are bit-identical on every bus
-- the graph writes (not only bus 0). Comparing every output bus
-- catches the case where a fanout's second fused branch is
-- miswired but its sibling on bus 0 happens to match. Also
-- verifies that the fused compile actually triggered fusion (≥1
-- RFused input + ≥1 elided node, or a non-RNodeLoop region) so
-- the test isn't degenerate.
--
-- The "node-loop baseline" is the same compiled graph as the fused
-- side, except every region is forced back to 'RNodeLoop' via
-- 'stripRegionKernels' — see that helper for why this matters.
assertFusedEquivalent :: String -> SynthGraph -> Assertion
assertFusedEquivalent name graph = do
  let nframes = 256
  -- Strip kernels from the baseline so 'loadRuntimeGraph' takes the
  -- per-node dispatch path even on regions §4.B would have claimed.
  rtUn <- case lowerGraph graph >>= compileRuntimeGraph of
    Right r  -> pure (stripRegionKernels r)
    Left err -> assertFailure (name <> ": compile (node-loop baseline) failed: " <> err)
                  >> error "unreachable"
  rtF  <- case lowerGraph graph >>= compileRuntimeGraphFused of
    Right r  -> pure r
    Left err -> assertFailure (name <> ": compile (fused) failed: " <> err)
                  >> error "unreachable"

  -- Sanity gate: the fused compile must actually fuse /something/
  -- — see 'fusedSomehow' for the predicate. A graph whose fused
  -- render trivially equals the baseline render because no fusion
  -- fired isn't a useful equivalence case.
  assertBool (name <> ": fused compile triggered no fusion of any kind")
    (fusedSomehow rtF)

  -- Walk the baseline graph to collect every bus index that an Out
  -- or BusOut node writes to. rnControls[0] holds the bus id by
  -- convention (see kindSpec for KOut / KBusOut). Bus indices that
  -- both graphs write to are compared sample-for-sample; if either
  -- side renders silence on a bus the other one drives, the test
  -- fails. Stripping kernels does not change rgNodes or controls,
  -- so walking rtUn here still sees every Out the original graph
  -- declared.
  let busesWritten rg =
        nub
          [ truncate v
          | n <- rgNodes rg
          , rnKind n == KOut || rnKind n == KBusOut
          , v : _ <- [rnControls n]
          , v >= 0
          ]
      buses = busesWritten rtUn
  assertBool (name <> ": graph writes no output buses to compare")
             (not (null buses))

  let render loader rt =
        withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
          loader handle rt
          c_rt_graph_process handle (fromIntegral nframes)
          allocaBytes (nframes * sizeOfFloat) $ \buf ->
            traverse (\bus -> readBus handle bus buf) buses
      readBus handle bus buf = do
        _ <- c_rt_graph_read_bus handle (fromIntegral bus)
                                 (fromIntegral nframes) (castPtr buf)
        cs <- peekArray nframes (buf :: PtrCFloat)
        pure (bus, map (\(CFloat x) -> x) cs)

  baseline <- render loadRuntimeGraph      rtUn
  fused    <- render loadRuntimeGraphFused rtF
  assertBool
    (name <> ": fused render must match node-loop baseline on every bus "
       <> show buses)
    (baseline == fused)
  where
    -- Mirrors the local sizeOfFloat in crossCuttingTests' where-clause.
    sizeOfFloat = 4 :: Int

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
