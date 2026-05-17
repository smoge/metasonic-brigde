-- | End-to-end FFI tests for the multi-template loader and the
-- §2.E instance-lifecycle surface.
--
-- These cases exercise 'loadTemplateGraph' (and its fused sibling)
-- end-to-end: a 'TemplateGraph' compiled by 'compileTemplateGraph'
-- crosses the FFI, the C-side @process_graph@ runs templates in
-- registration order with one auto-spawned instance per template,
-- and bus reads confirm per-template independence and
-- cross-template routing through the shared bus pool.
--
-- Coverage:
--
--   * Single-template ensemble (both unfused and fused loaders)
--     renders bit-identically to the legacy single-graph path.
--   * A multi-template ensemble registers /N/ templates with /N/
--     live instances, each on its own output bus.
--   * The cross-template send/return chain claims
--     'RBusInLpfGainOut' on the kernel side and stays
--     bit-equivalent to a 'stripRegionKernels' baseline.
--   * Cross-template ordering: 'compileTemplateGraph' re-orders
--     producer before consumer based on bus dataflow regardless of
--     the input list order.
--   * Post-load instance spawn inherits the spec defaults written
--     by @rt_graph_template_set_default@ during loading.
--   * §2.E release-then-free: status flips Live → Releasing on
--     release, the slot auto-frees after the envelope tail decays
--     below the silence threshold (status → -1, alive → 0).
--   * Phase 4.B 'RSinGainOut' kernel × §2.E silence gate:
--     'block_sink_peak' must reflect the kernel's actual output,
--     so a silent kernel lets the voice free and an audible kernel
--     pins it Live indefinitely.
--
-- Extracted from "MetaSonic.Spec.FFI" as the ninth slice of the
-- megafile split. The cases depend on the public
-- 'MetaSonic.Bridge.*' surface plus 'stripRegionKernels' from the
-- parent module and 'PtrCFloat' from "MetaSonic.Spec.Core".
-- 'sizeOfFloat' mirrors the parent's where-clause pattern.
module MetaSonic.Spec.FFI.TemplateLifecycle (templateLifecycleTests) where

import           Foreign.C.Types          (CFloat (..))
import           Foreign.Marshal.Alloc    (allocaBytes)
import           Foreign.Marshal.Array    (peekArray)
import           Foreign.Ptr              (castPtr)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile (RegionKernel (..),
                                           RuntimeInput (RFused),
                                           compileRuntimeGraph,
                                           compileRuntimeGraphFused,
                                           rgNodes, rgRuntimeRegions,
                                           rnElided, rnInputs, rrKernel)
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR      (lowerGraph)
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates (compileTemplateGraph,
                                             compileTemplateGraphFused,
                                             tgTemplates, tplGraph, tplName)

import           MetaSonic.Spec.Core      (PtrCFloat)
import           MetaSonic.Spec.FFI       (stripRegionKernels)


templateLifecycleTests :: TestTree
templateLifecycleTests = testGroup "End-to-end FFI: template ensemble and lifecycle"
  [ testCase "loadTemplateGraph: single-template ensemble runs identically to loadRuntimeGraph" $ do
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
