-- | Tests for node-index resolution across the Connection → NodeID →
-- NodeIndex boundary.
--
-- 'Connection' is the source-level handle returned by builders like
-- 'sinOsc' and 'gain'. After 'lowerGraph' and 'compileRuntimeGraph'
-- have produced a 'RuntimeGraph', each 'NodeID' carried by a
-- 'Connection' resolves to a dense 'NodeIndex' via
-- 'resolveNodeIndex'. These cases pin that round-trip plus the
-- 'Param' and unknown-NodeID edge cases.
module MetaSonic.Spec.Core.NodeIndex
  ( nodeIndexResolutionTests
  ) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Types

nodeIndexResolutionTests :: TestTree
nodeIndexResolutionTests =
  testGroup "node-index resolution: Connection → NodeID → NodeIndex"
    [ testCase "captured Connections resolve to their dense post-compile indices" $
        let (caps, sg) = runSynthWith $ do
              osc  <- sinOsc 440 0
              amp  <- gain osc 0.5
              _    <- out 0 amp
              pure (osc, amp)
            (oscConn, ampConn) = caps
        in case lowerGraph sg >>= compileRuntimeGraph of
             Left err -> assertFailure err
             Right rt -> do
               -- Builder order is sinOsc, gain, out; topological
               -- order matches builder order here, so dense indices
               -- are 0, 1, 2 respectively.
               let resolve c = connectionNodeID c >>= resolveNodeIndex rt
               resolve oscConn @?= Just (NodeIndex 0)
               resolve ampConn @?= Just (NodeIndex 1)

    , testCase "Param connections carry no NodeID" $
        connectionNodeID (Param 0.5) @?= Nothing

    , testCase "resolveNodeIndex returns Nothing for an unknown NodeID" $
        let sg = runSynth $ do
              osc <- sinOsc 440 0
              _   <- out 0 osc
              pure ()
        in case lowerGraph sg >>= compileRuntimeGraph of
             Left err -> assertFailure err
             Right rt -> resolveNodeIndex rt (NodeID 999) @?= Nothing
    ]
