-- | Phase 7.H block-major executor: bit-exact equivalence with RNodeLoop.
--
-- The block-major executor consumes the same emitted
-- 'FusionProgram' the sample-major executor does, so these tests
-- hand-author the same program shapes as the 7.D / 7.G suite but
-- flip the region's 'rrExec' to 'ExecGeneratedBlock'. Bit-exact
-- match against the stripped node-loop baseline pins the C++
-- @process_fusion_program_block@: the same arithmetic sequence as
-- the sample-major path, even though the loop nest is inverted.
module MetaSonic.Spec.Feature.FusionProgramBlockExecutor
  ( fusionProgramBlockExecutorTests
  ) where

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

fusionProgramBlockExecutorTests :: TestTree
fusionProgramBlockExecutorTests =
  testGroup "Phase 7.H: block-major executor bit-exact equivalence"
  [ testCase "block-major [Gain, Out] mirrors RNodeLoop on Sin source" $ do
      let nframes = 64
          srcGraph = runSynth $ do
            osc <- sinOsc 440.0 0.0
            gn  <- gain osc 0.5
            out 0 gn

      baseRG <- case lowerGraph srcGraph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      length (rgNodes baseRG) @?= 3
      let sinIdx  = NodeIndex 0
          gainIdx = NodeIndex 1
          outIdx  = NodeIndex 2

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
            , rrExec      = ExecGeneratedBlock (FusionProgramId 0)
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

  , testCase "block-major [Add, Gain, Out] mirrors RNodeLoop on two Sin sources" $ do
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
            , rrExec      = ExecGeneratedBlock (FusionProgramId 0)
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

  , testCase "block-major length-5 tail-sweep shape stays bit-exact" $ do
      -- Mirrors the 'tail-5-mixed' generated-tail-sweep member:
      -- pulseOsc prefix + [Add, Gain, Add, Gain, Out] owned tail.
      -- Block-major's loop nest is most exercised here — five
      -- scratch slots, each filled by its own per-block sweep,
      -- with scratch-to-scratch dataflow across the chain.
      let nframes = 64
          srcGraph = runSynth $ do
            src <- pulseOsc 110.0 0.0 0.5
            s1  <- add src (Param 0.1); g1 <- gain s1 0.5
            s2  <- add g1  (Param 0.2); g2 <- gain s2 0.7
            out 0 g2

      baseRG <- case lowerGraph srcGraph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      length (rgNodes baseRG) @?= 6
      let pulseIx = NodeIndex 0
          add1Ix  = NodeIndex 1
          gain1Ix = NodeIndex 2
          add2Ix  = NodeIndex 3
          gain2Ix = NodeIndex 4
          outIx   = NodeIndex 5

      let baseline = baseRG
            { rgRuntimeRegions =
                [ r { rrExec = ExecNodeLoop }
                | r <- rgRuntimeRegions baseRG
                ]
            }

          -- The owned tail program: each Add and Gain writes its
          -- own scratch slot; the second Add and Gain consume the
          -- prior slot via SrcScratch. Param-style constants come
          -- through as SrcConst.
          prog = FusionProgram
            { fpOps =
                [ OpAdd (ScratchIndex 0)
                    (SrcInput pulseIx (PortIndex 0))
                    (SrcConst 0.1)
                , OpMul (ScratchIndex 1)
                    (SrcScratch (ScratchIndex 0))
                    (SrcConst 0.5)
                , OpAdd (ScratchIndex 2)
                    (SrcScratch (ScratchIndex 1))
                    (SrcConst 0.2)
                , OpMul (ScratchIndex 3)
                    (SrcScratch (ScratchIndex 2))
                    (SrcConst 0.7)
                , OpSinkWrite 0
                    (SrcScratch (ScratchIndex 3))
                    SinkAccumulate
                ]
            , fpScratchSlots = 4
            }
          prefRegion = RuntimeRegion
            { rrIndex     = RegionIndex 0
            , rrRate      = SampleRate
            , rrNodes     = [pulseIx]
            , rrExec      = ExecNodeLoop
            , rrFootprint = emptyResourceFootprint
            }
          genRegion = RuntimeRegion
            { rrIndex     = RegionIndex 1
            , rrRate      = SampleRate
            , rrNodes     = [add1Ix, gain1Ix, add2Ix, gain2Ix, outIx]
            , rrExec      = ExecGeneratedBlock (FusionProgramId 0)
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
  ]
