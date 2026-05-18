-- | End-to-end FFI tests for the §4.B/§4.C fused render paths and
-- the live set_control surface every fused kernel must honor.
--
-- The slice pins three layers of the fused contract:
--
--   * Loader guards. 'loadRuntimeGraph' must reject 'RFused' inputs
--     with the documented error; 'loadRuntimeGraphFused' must
--     successfully load and render a fused graph end-to-end.
--   * Render parity. For every shape in 'fusedEquivalenceCases' and
--     for QuickCheck-generated topology, the fused render must be
--     bit-identical to a 'stripRegionKernels' node-loop baseline on
--     every bus the graph writes. The baseline-stripping step (see
--     'stripRegionKernels' in "MetaSonic.Spec.FFI") prevents the
--     blind spot where both sides dispatch through the same kernel
--     and a broken kernel passes by matching itself.
--   * Control identity. Live @set_control@ on elided / kernel-owned
--     nodes must steer the fused output exactly as it steers the
--     unfused per-node baseline. Covers §4.C single-Gain elision,
--     scalar Gain chains, mixed Gain/Add affine chains, and every
--     control slot of the four §4.B kernels: 'RSinGainOut',
--     'RSawLpfGainOut', 'RBusInLpfGainOut', 'RNoiseLpfGainOut'.
--     Includes a regression for 'RBusInLpfGainOut' state advancement
--     across an invalid-source-bus transition.
--
-- Extracted from "MetaSonic.Spec.FFI" as the tenth slice of the
-- megafile split. The four fused-only helpers — 'fusedEquivalenceCases',
-- 'prop_fusedRenderEqualsUnfused', 'fusedSomehow',
-- 'assertFusedEquivalent' — were used only by the moved cases and
-- travel with the slice. 'stripRegionKernels' stays in the parent
-- (also imported by "MetaSonic.Spec.FFI.TemplateLifecycle"); promoting
-- it to "MetaSonic.Spec.CoreShared" is a separate cleanup decision.
module MetaSonic.Spec.FFI.FusedRender (fusedRenderTests) where

import           Control.Exception        (try)
import           Data.List                (isInfixOf, nub)
import           Foreign.C.Types          (CDouble (..), CFloat (..))
import           Foreign.Marshal.Alloc    (allocaBytes)
import           Foreign.Marshal.Array    (peekArray)
import           Foreign.Ptr              (castPtr)

import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck    as QC

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR      (lowerGraph)
import           MetaSonic.Bridge.Source
import           MetaSonic.Types

import           MetaSonic.Spec.CoreShared      (PtrCFloat,
                                           genFusableRenderableGraph,
                                           shrinkSynthGraph)
import           MetaSonic.Spec.FFI       (stripRegionKernels)


fusedRenderTests :: TestTree
fusedRenderTests = testGroup "End-to-end FFI: fused render parity"
  [ -- Step C (c) guard: feeding a fused graph through the unfused
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
  ]
  where
    sizeOfFloat = 4 :: Int


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
    -- Mirrors the local sizeOfFloat in the testGroup where-clause.
    sizeOfFloat = 4 :: Int
