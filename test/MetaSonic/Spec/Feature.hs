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
