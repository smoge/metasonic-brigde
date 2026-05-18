-- | Phase 7.D: FusionProgram data-model scaffold tests.
--
-- Pure data-model coverage: empty-program invariants, op-count and
-- scratch-slot accounting, the 'SinkPolicy' / 'FusionSource'
-- enumerations, and how 'execKernel' / 'rrKernel' bridge the
-- legacy 'RegionKernel' tag with the new 'RuntimeRegionExec' shape.
-- No rendering; the executor/block/super-mode bit-exact cohorts
-- live in their own modules.
module MetaSonic.Spec.Feature.FusionProgramScaffold
  ( fusionProgramScaffoldTests
  ) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.Compile.FusionProgram
import           MetaSonic.Types

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
