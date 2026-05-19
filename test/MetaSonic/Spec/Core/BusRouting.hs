-- | Tests for source-level bus routing and the E_r edges
-- 'validateAndSort' derives from 'BusWrite' / 'BusRead' annotations.
-- 'BusOut' (and 'Out', which shares the bus-write kernel) must
-- precede any same-bus 'BusIn'; same-bus cycles are rejected; and
-- 'BusInDelayed' contributes no E_r edge, so feedback graphs
-- (writer-after-reader across a block boundary) still sort.
module MetaSonic.Spec.Core.BusRouting
  ( busRoutingCoreTests
  ) where

import qualified Data.Map.Strict           as M
import           Data.List                 (isPrefixOf)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Validate
import           MetaSonic.Types

busRoutingCoreTests :: TestTree
busRoutingCoreTests =
  testGroup "Bus routing (BusIn/BusOut and E_r edges)"
    [ testCase "validateAndSort orders BusOut before BusIn on the same bus" $ do
        -- Structurally there is no edge between the BusOut and the
        -- BusIn — only the bus number connects them. The E_r edge
        -- derived from BusWrite/BusRead must force the writer first.
        let g = runSynth $ do
              o <- sinOsc 440.0 0.0
              busOut 5 o
              t <- busIn 5
              out 0 t
        case validateAndSort g of
          Left err  -> assertFailure $ "validateAndSort failed: " <> err
          Right ord ->
            let nodes = sgNodes g
                posOf nid = head [ i | (i, k) <- zip [0..] ord, k == nid ]
                busOutPos = head
                  [ posOf nid
                  | (nid, ns) <- M.toList nodes
                  , case nsUgen ns of BusOut{} -> True; _ -> False ]
                busInPos = head
                  [ posOf nid
                  | (nid, ns) <- M.toList nodes
                  , case nsUgen ns of BusIn{} -> True; _ -> False ]
            in assertBool
                 ("BusOut at " <> show busOutPos
                  <> " must precede BusIn at " <> show busInPos)
                 ((busOutPos :: Int) < busInPos)

    , testCase "validateAndSort orders Out before BusIn on the same bus" $ do
        -- Out and BusOut share a runtime kernel and the same bus pool,
        -- so an Out n must induce the same E_r writer→reader ordering
        -- against a BusIn n that a BusOut n does. Earlier versions made
        -- Out 'Pure', a latent bug exposed once cross-template bus
        -- routing made Out and BusOut's disagreement visible.
        let g = runSynth $ do
              o <- sinOsc 440.0 0.0
              out 0 o
              t <- busIn 0
              busOut 9 t
        case validateAndSort g of
          Left err  -> assertFailure $ "validateAndSort failed: " <> err
          Right ord ->
            let nodes  = sgNodes g
                posOf nid = head [ i | (i, k) <- zip [0..] ord, k == nid ]
                outPos = head
                  [ posOf nid
                  | (nid, ns) <- M.toList nodes
                  , case nsUgen ns of Out{} -> True; _ -> False ]
                busInPos = head
                  [ posOf nid
                  | (nid, ns) <- M.toList nodes
                  , case nsUgen ns of BusIn{} -> True; _ -> False ]
            in assertBool
                 ("Out at " <> show outPos
                  <> " must precede BusIn at " <> show busInPos)
                 ((outPos :: Int) < busInPos)

    , testCase "validateAndSort rejects a BusOut→BusIn cycle on the same bus" $ do
        -- A node both writes and reads bus 5: BusIn 5 feeds a Gain
        -- whose output is written back via BusOut 5. Structurally
        -- this is acyclic (BusIn has no input, BusOut has one input),
        -- but the E_r edge BusOut→BusIn closes the loop.
        let g = runSynth $ do
              t <- busIn 5
              amped <- gain t 0.9
              busOut 5 amped
              out 0 t
        case validateAndSort g of
          Right _   -> assertFailure
            "expected validateAndSort to reject a same-bus E_r cycle"
          Left err  ->
            assertBool ("expected 'Cycle' in error, got: " <> err)
                       ("Cycle" `isPrefixOf` err)

    , testCase "different buses are independent (no spurious edges)" $ do
        -- BusOut 5 and BusIn 6 must not be ordered: they touch
        -- different buses. This catches a regression where busEdges
        -- ignored the bus-number guard.
        let g = runSynth $ do
              o <- sinOsc 440.0 0.0
              busOut 5 o
              _ <- busIn 6  -- never written, but should still validate
              out 0 o
        case validateAndSort g of
          Left err -> assertFailure $ "validateAndSort failed: " <> err
          Right _  -> pure ()

    , testCase "busInDelayed contributes no E_r edge (busEdges ignores it)" $ do
        -- A graph with BusOut 5 and BusInDelayed 5 (no live BusIn)
        -- must produce zero E_r edges. If busEdges ever started
        -- pairing BusReadDelayed with BusWrite, feedback graphs
        -- would stop scheduling — this test pins the asymmetry.
        let g = runSynth $ do
              o   <- sinOsc 440.0 0.0
              busOut 5 o
              _   <- busInDelayed 5
              out 0 o
        busEdges g @?= []

    , testCase "feedback graph through busInDelayed topologically sorts" $ do
        -- This is the smoke test for the whole Phase 2 design: a
        -- graph whose only "cycle" closes through BusInDelayed must
        -- be accepted by the scheduler. Replacing busInDelayed with
        -- busIn would (correctly) close an E_r cycle and be
        -- rejected — see "rejects a BusOut→BusIn cycle on the same
        -- bus" above.
        let g = runSynth $ do
              tap <- busInDelayed 5
              o   <- sinOsc 220.0 0.0
              mix <- add o tap
              amp <- gain mix 0.5
              busOut 5 amp
              out 0 amp
        case validateAndSort g of
          Left err -> assertFailure $
            "feedback graph through busInDelayed should sort, got: " <> err
          Right _  -> pure ()
    ]
