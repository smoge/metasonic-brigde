{-# LANGUAGE LambdaCase #-}

-- | Authoring, planner, static-plugin, and fusion-program feature tests.
module MetaSonic.Spec.Feature where

import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Map.Strict           as M
import qualified Data.Set                  as S
import           Data.List                 (isInfixOf, sort)
import           Control.Exception         (try)
import           Control.Monad             (forM_)
import           Data.Maybe                (isJust, listToMaybe)
import           Data.Word                 (Word8)
import           Foreign.C.Types           (CFloat (..))
import           Foreign.Marshal.Alloc     (allocaBytes)
import           Foreign.Marshal.Array     (peekArray)
import           Foreign.Ptr               (castPtr)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.Compile.FusionProgram
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Planner
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import qualified MetaSonic.OSC.Dispatch    as OSC
import qualified MetaSonic.OSC.Wire        as OSC
import qualified MetaSonic.Authoring       as Auth
import           MetaSonic.Authoring.Manifest
import           MetaSonic.Authoring.Report
import           MetaSonic.Types
import           MetaSonic.Spec.Core

import qualified Data.ByteString.Char8     as OBSC

------------------------------------------------------------
-- §7.D scaffold: FusionProgram data-model invariants
------------------------------------------------------------

fusionProgramScaffoldTests :: TestTree
fusionProgramScaffoldTests =
  testGroup "Phase 7.D: FusionProgram data-model scaffold"
  [ testCase "emptyFusionProgram has no ops and no scratch" $ do
      fpOps          emptyFusionProgram @?= []
      fpScratchSlots emptyFusionProgram @?= 0
      programOpCount emptyFusionProgram @?= 0

  , testCase "programOpCount counts ops in declaration order" $ do
      let prog = FusionProgram
            { fpOps =
                [ OpLoadConst (ScratchIndex 0) 0.5
                , OpLoadInput (ScratchIndex 1)
                    (NodeIndex 7) (PortIndex 0)
                , OpMul (ScratchIndex 2)
                    (SrcScratch (ScratchIndex 0))
                    (SrcScratch (ScratchIndex 1))
                , OpSinkWrite 0
                    (SrcScratch (ScratchIndex 2))
                    SinkAccumulate
                ]
            , fpScratchSlots = 3
            }
      programOpCount prog @?= 4
      fpScratchSlots prog @?= 3

  , testCase "SinkPolicy enumerates both writer modes" $
      [minBound .. maxBound] @?= [SinkOverwrite, SinkAccumulate]

  , testCase "FusionSource constructors compare structurally" $ do
      SrcConst   0.5                            @?= SrcConst 0.5
      SrcInput   (NodeIndex 1) (PortIndex 0)    @?= SrcInput   (NodeIndex 1) (PortIndex 0)
      SrcControl (NodeIndex 1) (ControlIndex 0) @?= SrcControl (NodeIndex 1) (ControlIndex 0)
      SrcScratch (ScratchIndex 2)               @?= SrcScratch (ScratchIndex 2)
      assertBool "distinct sources are not equal"
        (SrcConst 0.5 /= SrcScratch (ScratchIndex 0))

  , testCase "execKernel collapses RNodeLoop into ExecNodeLoop" $ do
      execKernel RNodeLoop       @?= ExecNodeLoop
      execKernel RSinGainOut     @?= ExecKernel RSinGainOut
      execKernel RSawLpfGainOut  @?= ExecKernel RSawLpfGainOut

  , testCase "rrKernel projects RegionExec back to RegionKernel" $ do
      let region exec = RuntimeRegion
            { rrIndex     = RegionIndex 0
            , rrRate      = SampleRate
            , rrNodes     = []
            , rrExec      = exec
            , rrFootprint = emptyResourceFootprint
            }
      rrKernel (region ExecNodeLoop)                       @?= RNodeLoop
      rrKernel (region (ExecKernel RSinGainOut))           @?= RSinGainOut
      -- Generated regions project to RNodeLoop through the legacy
      -- lens; readers that need to distinguish must pattern-match
      -- on 'rrExec' directly.
      rrKernel (region (ExecGenerated (FusionProgramId 0))) @?= RNodeLoop

  , testCase "RuntimeGraph carries an empty FusionProgram table by default" $
      rgFusionPrograms (RuntimeGraph [] [] []) @?= []
  ]

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
              peekArray nframes (bp :: PtrCFloat)

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
              peekArray nframes (bp :: PtrCFloat)

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
              peekArray nframes (bp :: PtrCFloat)

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
              peekArray nframes (bp :: PtrCFloat)

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
              peekArray nframes (bp :: PtrCFloat)
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

------------------------------------------------------------
-- §7.H block-major executor: bit-exact equivalence with RNodeLoop
------------------------------------------------------------
--
-- The block-major executor consumes the same emitted
-- 'FusionProgram' the sample-major executor does, so these
-- tests hand-author the same program shapes as the 7.D /
-- 7.G suite but flip the region's 'rrExec' to
-- 'ExecGeneratedBlock'. Bit-exact match against the stripped
-- node-loop baseline is the verification target: the C++
-- @process_fusion_program_block@ has to produce the same
-- arithmetic sequence as the sample-major path even though its
-- loop nest is inverted.

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
              peekArray nframes (bp :: PtrCFloat)

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
              peekArray nframes (bp :: PtrCFloat)

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
              peekArray nframes (bp :: PtrCFloat)

      baseSamples <- render baseline
      genSamples  <- render generated
      let peak = maximum (map (\(CFloat x) -> abs x) baseSamples)
      assertBool ("baseline non-silent; peak=" <> show peak) (peak > 0.0)
      genSamples @?= baseSamples
  ]

------------------------------------------------------------
-- §7.I super-mode executor: bit-exact equivalence with RNodeLoop
------------------------------------------------------------
--
-- The super-mode executor consumes the same emitted
-- 'FusionProgram' the other generated executors do, so these
-- tests hand-author the same shapes as the 7.D / 7.G / 7.H
-- suites but flip 'rrExec' to 'ExecGeneratedSuper'. Two
-- programs match the v1 recognizer set (GainOut and
-- AddGainOut) and exercise the fast path; one longer tail
-- exercises the fallback to the block-major executor. Bit-
-- exact match against the stripped node-loop baseline pins
-- both paths.

fusionProgramSuperExecutorTests :: TestTree
fusionProgramSuperExecutorTests =
  testGroup "Phase 7.I: super-mode executor bit-exact equivalence"
  [ testCase "super-mode [Gain, Out] is recognized and mirrors RNodeLoop" $ do
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
            , rrExec      = ExecGeneratedSuper (FusionProgramId 0)
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
              peekArray nframes (bp :: PtrCFloat)

      baseSamples <- render baseline
      genSamples  <- render generated
      let peak = maximum (map (\(CFloat x) -> abs x) baseSamples)
      assertBool ("baseline non-silent; peak=" <> show peak) (peak > 0.0)
      genSamples @?= baseSamples

      -- Confirm the recognizer tags the program as GainOut (kind 1).
      kind <- withRTGraph cap nframes $ \rt -> do
        loadRuntimeGraph rt generated
        c_rt_graph_test_fusion_program_super_kind rt 0 0
      kind @?= 1

  , testCase "super-mode [Add, Gain, Out] is recognized and mirrors RNodeLoop" $ do
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
      let sinA  = NodeIndex 0
          sinB  = NodeIndex 1
          addI  = NodeIndex 2
          gainI = NodeIndex 3
          outI  = NodeIndex 4

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
            , rrExec      = ExecGeneratedSuper (FusionProgramId 0)
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
              peekArray nframes (bp :: PtrCFloat)

      baseSamples <- render baseline
      genSamples  <- render generated
      let peak = maximum (map (\(CFloat x) -> abs x) baseSamples)
      assertBool ("baseline non-silent; peak=" <> show peak) (peak > 0.0)
      genSamples @?= baseSamples

      -- Confirm the recognizer tags the program as AddGainOut (kind 2).
      kind <- withRTGraph cap nframes $ \rt -> do
        loadRuntimeGraph rt generated
        c_rt_graph_test_fusion_program_super_kind rt 0 0
      kind @?= 2

  , testCase "super-mode length-5 tail falls back to block-major bit-exact" $ do
      -- Mirrors the 'tail-5-mixed' generated-tail-sweep member.
      -- The program has 5 ops and 4 scratch slots, which matches
      -- neither GainOut nor AddGainOut; super-mode falls through
      -- to process_fusion_program_block. The bit-exact check pins
      -- that fallback path.
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
            , rrExec      = ExecGeneratedSuper (FusionProgramId 0)
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
              peekArray nframes (bp :: PtrCFloat)

      baseSamples <- render baseline
      genSamples  <- render generated
      let peak = maximum (map (\(CFloat x) -> abs x) baseSamples)
      assertBool ("baseline non-silent; peak=" <> show peak) (peak > 0.0)
      genSamples @?= baseSamples

      -- Confirm the recognizer tags the program as NotRecognized (kind 0).
      kind <- withRTGraph cap nframes $ \rt -> do
        loadRuntimeGraph rt generated
        c_rt_graph_test_fusion_program_super_kind rt 0 0
      kind @?= 0

  , testCase "super-mode rejects AddGainOut-shaped program with scratch operand on mul.src2" $ do
      -- Regression pin for the tightened recognizer (Phase 7.I
      -- follow-up): a 3-op program that *matches the op kinds and
      -- scratch indices of AddGainOut* but whose mul.src2 reads
      -- SrcScratch[0] (the add result, instead of an external
      -- gain operand) must NOT be recognized. Under the previous
      -- loose recognizer the super executor would have extracted
      -- mul.src2 inline, hit read_source's SrcScratch=0 fallback,
      -- and silently computed (a+b)*0 = 0 instead of the correct
      -- (a+b)*(a+b). With the operand-source guard, the recognizer
      -- returns NotRecognized and super-mode falls through to
      -- block-major, preserving the correct output.
      let nframes = 64
          srcGraph = runSynth $ do
            a <- sinOsc 330.0 0.0
            b <- sinOsc 440.0 0.0
            out 0 a
            out 0 b

      baseRG <- case lowerGraph srcGraph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      length (rgNodes baseRG) @?= 4
      let sinA = NodeIndex 0
          sinB = NodeIndex 1
          outA = NodeIndex 2
          outB = NodeIndex 3

      -- The program: scratch[0] = sinA + sinB; scratch[1] =
      -- scratch[0] * scratch[0]; sink 0 <- scratch[1]. Under
      -- block-major this is (a+b)^2. The loose recognizer would
      -- have matched AddGainOut, but the new check on mul.src2
      -- rejects it.
      let prog = FusionProgram
            { fpOps =
                [ OpAdd (ScratchIndex 0)
                    (SrcInput sinA (PortIndex 0))
                    (SrcInput sinB (PortIndex 0))
                , OpMul (ScratchIndex 1)
                    (SrcScratch (ScratchIndex 0))
                    (SrcScratch (ScratchIndex 0))
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
          -- Discard the source graph's Out nodes; we drive bus 0
          -- entirely from the generated region so the comparison
          -- has a clean reference.
          dropOutsRegion = RuntimeRegion
            { rrIndex     = RegionIndex 2
            , rrRate      = SampleRate
            , rrNodes     = [outA, outB]
            , rrExec      = ExecNodeLoop
            , rrFootprint = emptyResourceFootprint
            }
          -- block-major reference: same program, ExecGeneratedBlock.
          blockRegion = RuntimeRegion
            { rrIndex     = RegionIndex 1
            , rrRate      = SampleRate
            , rrNodes     = []
            , rrExec      = ExecGeneratedBlock (FusionProgramId 0)
            , rrFootprint = emptyResourceFootprint
            }
          -- super-mode (now-tightened) variant: identical program,
          -- routed through ExecGeneratedSuper. Must fall back to
          -- block-major and produce identical output.
          superRegion = RuntimeRegion
            { rrIndex     = RegionIndex 1
            , rrRate      = SampleRate
            , rrNodes     = []
            , rrExec      = ExecGeneratedSuper (FusionProgramId 0)
            , rrFootprint = emptyResourceFootprint
            }
          blockRG = baseRG
            { rgRuntimeRegions = [prefRegion, blockRegion, dropOutsRegion]
            , rgFusionPrograms = [prog]
            }
          superRG = baseRG
            { rgRuntimeRegions = [prefRegion, superRegion, dropOutsRegion]
            , rgFusionPrograms = [prog]
            }
          cap = length (rgNodes baseRG)
          render rg = withRTGraph cap nframes $ \rt -> do
            loadRuntimeGraph rt rg
            c_rt_graph_process rt (fromIntegral nframes)
            allocaBytes (nframes * 4) $ \bp -> do
              _ <- c_rt_graph_read_bus rt 0
                     (fromIntegral nframes) (castPtr bp)
              peekArray nframes (bp :: PtrCFloat)

      blockSamples <- render blockRG
      superSamples <- render superRG
      let peak = maximum (map (\(CFloat x) -> abs x) blockSamples)
      assertBool ("block-major reference non-silent; peak=" <> show peak)
                 (peak > 0.0)
      superSamples @?= blockSamples

      -- The recognizer must classify this program as
      -- NotRecognized (kind 0). If it returns 2 (AddGainOut), the
      -- guard regressed and the next bit-exact failure will be
      -- elsewhere.
      kind <- withRTGraph cap nframes $ \rt -> do
        loadRuntimeGraph rt superRG
        c_rt_graph_test_fusion_program_super_kind rt 0 0
      kind @?= 0
      -- Note: the symmetric GainOut-shape regression isn't a
      -- reachable test today. The only way a 2-op GainOut shape
      -- could carry a SrcScratch operand is to read scratch[0]
      -- before op 0 writes it, and the FFI loader's
      -- read-before-write dataflow check rejects such programs
      -- at load time. The C++ and Haskell recognizers still
      -- check the operand source for code-symmetry and as
      -- defense in depth against a future loader change.
  ]

-- | Tally a 'SynthGraph' by 'NodeKind' for shape-pinning tests.
-- 'NodeKind' has no 'Ord' instance, so the tally is a sorted-by-show
-- assoc list — equality is by value, not order.
