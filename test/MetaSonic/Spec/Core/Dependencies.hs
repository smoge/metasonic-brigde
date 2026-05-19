-- | Tests for 'dependencies' (Source-level UGen → [NodeID]): pure
-- 'Param' connections contribute none, 'Audio' connections contribute
-- the referenced 'NodeID' in argument order, and mixed
-- audio/parameter signatures only emit dependencies for the audio
-- inputs.
module MetaSonic.Spec.Core.Dependencies
  ( dependenciesTests
  ) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source
import           MetaSonic.Types

dependenciesTests :: TestTree
dependenciesTests =
  testGroup "dependencies (Source-level UGen → [NodeID])"
    [ testCase "all-Param UGen has no dependencies" $ do
        dependencies (SinOsc (Param 440) (Param 0)) @?= []
        dependencies (LPF (Param 0) (Param 800) (Param 0.7)) @?= []
        dependencies (Gain (Param 0) (Param 0.5)) @?= []
        dependencies (Add (Param 1) (Param 2)) @?= []
        dependencies NoiseGen @?= []
        dependencies (Out 0 (Param 0)) @?= []

    , testCase "single-Audio input contributes one dependency" $
        dependencies (Gain (Audio (NodeID 7) (PortIndex 0)) (Param 0.5))
          @?= [NodeID 7]

    , testCase "two-Audio inputs contribute both, in argument order" $
        dependencies
          (Gain (Audio (NodeID 1) (PortIndex 0))
                (Audio (NodeID 2) (PortIndex 0)))
          @?= [NodeID 1, NodeID 2]

    , testCase "mixed Audio/Param: only Audio contributes" $
        dependencies
          (Add (Param 440)
               (Audio (NodeID 99) (PortIndex 0)))
          @?= [NodeID 99]

    , testCase "LPF with audio sig + param controls: only sig" $
        dependencies
          (LPF (Audio (NodeID 3) (PortIndex 0))
               (Param 800)
               (Param 0.7))
          @?= [NodeID 3]

    , testCase "Out wraps its source dependency" $
        dependencies (Out 0 (Audio (NodeID 42) (PortIndex 0)))
          @?= [NodeID 42]
    ]
