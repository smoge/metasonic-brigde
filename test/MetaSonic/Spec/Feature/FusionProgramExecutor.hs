-- | Phase 7.D executor: bit-exact equivalence with RNodeLoop.
--
-- Each case hand-authors a 'FusionProgram' that mirrors a small
-- 'SynthGraph' fragment, swaps the region's 'rrExec' to
-- 'ExecGenerated', renders against the canonical
-- 'ExecNodeLoop'-stripped baseline, and asserts bit-identical
-- output on bus 0. The final case pins the load-time
-- validation contract: a program with a read-before-write data
-- dependency must fail to install and leave the previous graph
-- audible.
module MetaSonic.Spec.Feature.FusionProgramExecutor
  ( fusionProgramExecutorTests
  ) where

import           Control.Exception         (try)
import           Data.List                 (isInfixOf)
import           Foreign.C.Types           (CFloat (..))
import           Foreign.Marshal.Alloc     (allocaBytes)
import           Foreign.Marshal.Array     (peekArray)
import           Foreign.Ptr               (Ptr, castPtr)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.Compile.FusionProgram
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR       (lowerGraph)
import           MetaSonic.Bridge.Source
import           MetaSonic.Types

------------------------------------------------------------
-- §7.D executor: bit-exact equivalence with RNodeLoop
------------------------------------------------------------

fusionProgramExecutorTests :: TestTree
fusionProgramExecutorTests =
  testGroup "Phase 7.D: tiny executor bit-exact equivalence"
  [ testCase "generated [Gain, Out] reading Sin's output matches RNodeLoop" $ do
      -- Baseline: Sin → Gain(0.5) → Out, compiled normally then
      -- stripped to ExecNodeLoop on every region. This is the
      -- reference timeline.
      --
      -- Generated variant: same nodes, but the region overlay is
      -- split into:
      --   * Region 0 = [Sin]       ExecNodeLoop
      --   * Region 1 = [Gain, Out] ExecGenerated (FusionProgramId 0)
      -- The hand-authored program reads Sin's output buffer per
      -- sample, multiplies by 0.5, and writes to bus 0.
      --
      -- Both runs share node identity (Sin sits at NodeIndex 0 in
      -- both worlds; phase init is the same), so the per-sample
      -- output should be bit-identical on bus 0.
      let nframes = 64
          srcGraph = runSynth $ do
            osc <- sinOsc 440.0 0.0
            gn  <- gain osc 0.5
            out 0 gn

      baseRG <- case lowerGraph srcGraph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      -- Sanity: the compiler produced the expected dense order.
      length (rgNodes baseRG) @?= 3
      let sinIdx  = NodeIndex 0
          gainIdx = NodeIndex 1
          outIdx  = NodeIndex 2
      map rnIndex (rgNodes baseRG) @?= [sinIdx, gainIdx, outIdx]

      let baseline = baseRG
            { rgRuntimeRegions =
                [ r { rrExec = ExecNodeLoop }
                | r <- rgRuntimeRegions baseRG
                ]
            }

          prog = FusionProgram
            { fpOps =
                [ OpMul (ScratchIndex 0)
                    (SrcInput sinIdx (PortIndex 0))
                    (SrcConst 0.5)
                , OpSinkWrite 0
                    (SrcScratch (ScratchIndex 0))
                    SinkAccumulate
                ]
            , fpScratchSlots = 1
            }
          sinRegion = RuntimeRegion
            { rrIndex     = RegionIndex 0
            , rrRate      = SampleRate
            , rrNodes     = [sinIdx]
            , rrExec      = ExecNodeLoop
            , rrFootprint = emptyResourceFootprint
            }
          genRegion = RuntimeRegion
            { rrIndex     = RegionIndex 1
            , rrRate      = SampleRate
            , rrNodes     = [gainIdx, outIdx]
            , rrExec      = ExecGenerated (FusionProgramId 0)
            , rrFootprint = emptyResourceFootprint
            }
          generated = baseRG
            { rgRuntimeRegions = [sinRegion, genRegion]
            , rgFusionPrograms = [prog]
            }

          cap = length (rgNodes baseRG)
          render rg = withRTGraph cap nframes $ \rt -> do
            loadRuntimeGraph rt rg
            c_rt_graph_process rt (fromIntegral nframes)
            allocaBytes (nframes * 4) $ \bp -> do
              _ <- c_rt_graph_read_bus rt 0
                     (fromIntegral nframes) (castPtr bp)
              peekArray nframes (bp :: Ptr CFloat)

      baseSamples <- render baseline
      genSamples  <- render generated

      let peak = maximum (map (\(CFloat x) -> abs x) baseSamples)
      assertBool
        ("baseline output should be non-silent; peak=" <> show peak)
        (peak > 0.0)

      -- Verification target for §7.D step 7.
      genSamples @?= baseSamples

  , testCase "generated [Gain, Gain, Out] mirrors the multi-scratch tail" $ do
      -- Phase 7.G step 3: the generalized generator owns a
      -- contiguous KGain/KAdd tail, mapping each non-sink node
      -- to one scratch slot. This test hand-authors the program
      -- the generator would emit for Sin → Gain → Gain → Out
      -- (prefix [Sin] node-loop, owned tail [Gain, Gain, Out])
      -- and verifies bit-exact equivalence with the stripped
      -- node-loop baseline.
      let nframes = 64
          srcGraph = runSynth $ do
            osc <- sinOsc 440.0 0.0
            g1  <- gain osc 0.5
            g2  <- gain g1  0.7
            out 0 g2

      baseRG <- case lowerGraph srcGraph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      length (rgNodes baseRG) @?= 4
      let sinIdx   = NodeIndex 0
          gain1Ix  = NodeIndex 1
          gain2Ix  = NodeIndex 2
          outIdx   = NodeIndex 3
      map rnIndex (rgNodes baseRG) @?= [sinIdx, gain1Ix, gain2Ix, outIdx]

      let baseline = baseRG
            { rgRuntimeRegions =
                [ r { rrExec = ExecNodeLoop }
                | r <- rgRuntimeRegions baseRG
                ]
            }

          prog = FusionProgram
            { fpOps =
                [ OpMul (ScratchIndex 0)
                    (SrcInput sinIdx (PortIndex 0))
                    (SrcConst 0.5)
                , OpMul (ScratchIndex 1)
                    (SrcScratch (ScratchIndex 0))
                    (SrcConst 0.7)
                , OpSinkWrite 0
                    (SrcScratch (ScratchIndex 1))
                    SinkAccumulate
                ]
            , fpScratchSlots = 2
            }
          sinRegion = RuntimeRegion
            { rrIndex     = RegionIndex 0
            , rrRate      = SampleRate
            , rrNodes     = [sinIdx]
            , rrExec      = ExecNodeLoop
            , rrFootprint = emptyResourceFootprint
            }
          genRegion = RuntimeRegion
            { rrIndex     = RegionIndex 1
            , rrRate      = SampleRate
            , rrNodes     = [gain1Ix, gain2Ix, outIdx]
            , rrExec      = ExecGenerated (FusionProgramId 0)
            , rrFootprint = emptyResourceFootprint
            }
          generated = baseRG
            { rgRuntimeRegions = [sinRegion, genRegion]
            , rgFusionPrograms = [prog]
            }
          cap = length (rgNodes baseRG)
          render rg = withRTGraph cap nframes $ \rt -> do
            loadRuntimeGraph rt rg
            c_rt_graph_process rt (fromIntegral nframes)
            allocaBytes (nframes * 4) $ \bp -> do
              _ <- c_rt_graph_read_bus rt 0
                     (fromIntegral nframes) (castPtr bp)
              peekArray nframes (bp :: Ptr CFloat)

      baseSamples <- render baseline
      genSamples  <- render generated
      let peak = maximum (map (\(CFloat x) -> abs x) baseSamples)
      assertBool ("baseline non-silent; peak=" <> show peak) (peak > 0.0)
      genSamples @?= baseSamples

  , testCase "generated [Add, Gain, Out] reads two prefix outputs" $ do
      -- Phase 7.G step 3: KAdd op tests the SrcInput→SrcInput
      -- path where the owned tail's first op consumes two
      -- external (prefix) signals rather than a single one. The
      -- second op then chains into KGain via SrcScratch.
      let nframes = 64
          srcGraph = runSynth $ do
            a <- sinOsc 330.0 0.0
            b <- sinOsc 440.0 0.0
            s <- add a b
            g <- gain s 0.5
            out 0 g

      baseRG <- case lowerGraph srcGraph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      length (rgNodes baseRG) @?= 5
      let sinA = NodeIndex 0
          sinB = NodeIndex 1
          addI = NodeIndex 2
          gainI = NodeIndex 3
          outI = NodeIndex 4
      map rnIndex (rgNodes baseRG) @?= [sinA, sinB, addI, gainI, outI]

      let baseline = baseRG
            { rgRuntimeRegions =
                [ r { rrExec = ExecNodeLoop }
                | r <- rgRuntimeRegions baseRG
                ]
            }

          prog = FusionProgram
            { fpOps =
                [ OpAdd (ScratchIndex 0)
                    (SrcInput sinA (PortIndex 0))
                    (SrcInput sinB (PortIndex 0))
                , OpMul (ScratchIndex 1)
                    (SrcScratch (ScratchIndex 0))
                    (SrcConst 0.5)
                , OpSinkWrite 0
                    (SrcScratch (ScratchIndex 1))
                    SinkAccumulate
                ]
            , fpScratchSlots = 2
            }
          prefRegion = RuntimeRegion
            { rrIndex     = RegionIndex 0
            , rrRate      = SampleRate
            , rrNodes     = [sinA, sinB]
            , rrExec      = ExecNodeLoop
            , rrFootprint = emptyResourceFootprint
            }
          genRegion = RuntimeRegion
            { rrIndex     = RegionIndex 1
            , rrRate      = SampleRate
            , rrNodes     = [addI, gainI, outI]
            , rrExec      = ExecGenerated (FusionProgramId 0)
            , rrFootprint = emptyResourceFootprint
            }
          generated = baseRG
            { rgRuntimeRegions = [prefRegion, genRegion]
            , rgFusionPrograms = [prog]
            }
          cap = length (rgNodes baseRG)
          render rg = withRTGraph cap nframes $ \rt -> do
            loadRuntimeGraph rt rg
            c_rt_graph_process rt (fromIntegral nframes)
            allocaBytes (nframes * 4) $ \bp -> do
              _ <- c_rt_graph_read_bus rt 0
                     (fromIntegral nframes) (castPtr bp)
              peekArray nframes (bp :: Ptr CFloat)

      baseSamples <- render baseline
      genSamples  <- render generated
      let peak = maximum (map (\(CFloat x) -> abs x) baseSamples)
      assertBool ("baseline non-silent; peak=" <> show peak) (peak > 0.0)
      genSamples @?= baseSamples

  , testCase "generated [Add, Add, Gain, Out] chains three scratch slots" $ do
      -- Phase 7.G step 3: deepest tail this slice's op set can
      -- express. The second OpAdd consumes the first OpAdd's
      -- scratch slot, exercising scratch-to-scratch dataflow.
      let nframes = 64
          srcGraph = runSynth $ do
            a <- sinOsc 220.0 0.0
            b <- sinOsc 330.0 0.0
            c <- sinOsc 440.0 0.0
            s1 <- add a b
            s2 <- add s1 c
            g  <- gain s2 0.5
            out 0 g

      baseRG <- case lowerGraph srcGraph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      length (rgNodes baseRG) @?= 7
      let sin1 = NodeIndex 0
          sin2 = NodeIndex 1
          sin3 = NodeIndex 2
          add1 = NodeIndex 3
          add2 = NodeIndex 4
          gainI = NodeIndex 5
          outI = NodeIndex 6
      map rnIndex (rgNodes baseRG)
        @?= [sin1, sin2, sin3, add1, add2, gainI, outI]

      let baseline = baseRG
            { rgRuntimeRegions =
                [ r { rrExec = ExecNodeLoop }
                | r <- rgRuntimeRegions baseRG
                ]
            }

          prog = FusionProgram
            { fpOps =
                [ OpAdd (ScratchIndex 0)
                    (SrcInput sin1 (PortIndex 0))
                    (SrcInput sin2 (PortIndex 0))
                , OpAdd (ScratchIndex 1)
                    (SrcScratch (ScratchIndex 0))
                    (SrcInput sin3 (PortIndex 0))
                , OpMul (ScratchIndex 2)
                    (SrcScratch (ScratchIndex 1))
                    (SrcConst 0.5)
                , OpSinkWrite 0
                    (SrcScratch (ScratchIndex 2))
                    SinkAccumulate
                ]
            , fpScratchSlots = 3
            }
          prefRegion = RuntimeRegion
            { rrIndex     = RegionIndex 0
            , rrRate      = SampleRate
            , rrNodes     = [sin1, sin2, sin3]
            , rrExec      = ExecNodeLoop
            , rrFootprint = emptyResourceFootprint
            }
          genRegion = RuntimeRegion
            { rrIndex     = RegionIndex 1
            , rrRate      = SampleRate
            , rrNodes     = [add1, add2, gainI, outI]
            , rrExec      = ExecGenerated (FusionProgramId 0)
            , rrFootprint = emptyResourceFootprint
            }
          generated = baseRG
            { rgRuntimeRegions = [prefRegion, genRegion]
            , rgFusionPrograms = [prog]
            }
          cap = length (rgNodes baseRG)
          render rg = withRTGraph cap nframes $ \rt -> do
            loadRuntimeGraph rt rg
            c_rt_graph_process rt (fromIntegral nframes)
            allocaBytes (nframes * 4) $ \bp -> do
              _ <- c_rt_graph_read_bus rt 0
                     (fromIntegral nframes) (castPtr bp)
              peekArray nframes (bp :: Ptr CFloat)

      baseSamples <- render baseline
      genSamples  <- render generated
      let peak = maximum (map (\(CFloat x) -> abs x) baseSamples)
      assertBool ("baseline non-silent; peak=" <> show peak) (peak > 0.0)
      genSamples @?= baseSamples

  , testCase "invalid generated program fails before clearing previous graph" $ do
      let nframes = 64
          srcGraph = runSynth $ do
            osc <- sinOsc 220.0 0.0
            gn  <- gain osc 0.4
            out 0 gn

      baseRG <- case lowerGraph srcGraph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      let badProgram = FusionProgram
            { fpOps =
                [ OpLoadConst (ScratchIndex 0) 1.0
                , OpSinkWrite 0
                    (SrcScratch (ScratchIndex 0))
                    SinkAccumulate
                ]
            , fpScratchSlots = 65
            }
          badRG = baseRG { rgFusionPrograms = [badProgram] }
          renderPeak rt = do
            c_rt_graph_process rt (fromIntegral nframes)
            samples <- allocaBytes (nframes * 4) $ \bp -> do
              _ <- c_rt_graph_read_bus rt 0
                     (fromIntegral nframes) (castPtr bp)
              peekArray nframes (bp :: Ptr CFloat)
            pure (maximum (map (\(CFloat x) -> abs x) samples))

      withRTGraph (length (rgNodes baseRG)) nframes $ \rt -> do
        loadRuntimeGraph rt baseRG
        before <- renderPeak rt
        assertBool
          ("expected pre-failure graph to render, peak=" <> show before)
          (before > 0.0)

        let attempt :: IO (Either IOError ())
            attempt = try $ loadRuntimeGraph rt badRG
        result <- attempt
        case result of
          Right () ->
            assertFailure "expected generated-program validation to fail"
          Left e ->
            assertBool
              ("expected generated scratch diagnostic in: " <> show e)
              ("scratch slots" `isInfixOf` show e)

        afterPeak <- renderPeak rt
        assertBool
          ("expected previous graph to survive failed load, peak="
           <> show afterPeak)
          (afterPeak > 0.0)
  ]
