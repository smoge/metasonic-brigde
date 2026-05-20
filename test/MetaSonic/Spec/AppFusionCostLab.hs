-- | Tests for app-level latency feature extraction in
-- 'MetaSonic.App.FusionCostLab.extractFeatures'.
--
-- §6.E v2 site 5a (notes/2026-05-19-d-phase-6e4-second-static-plugin-contract.md):
-- the latency-row migration to 'nodeDeclaredLatency' has to land
-- in 'FusionCostLab.extractFeatures' so the cost-lab feature row
-- (@fcfLatencyNodes@ / @fcfMaxLatency@) sees per-instance plugin
-- latency the same way 'declaredLatencyFootprint' does. Without
-- the migration, a one-tap-delay plugin is visible to the survey
-- but invisible to the cost-lab feature row — exactly the
-- regression this test pins.
module MetaSonic.Spec.AppFusionCostLab
  ( appFusionCostLabTests
  ) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.FusionCostLab    (FusionCaseFeatures (..),
                                                 extractFeatures)
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates     (compileTemplateGraph,
                                                 tgTemplates, tplGraph)

appFusionCostLabTests :: TestTree
appFusionCostLabTests =
  testGroup "Phase 6.E v2 site 5a: FusionCostLab.extractFeatures latency row"
  [ testCase "fcfLatencyNodes / fcfMaxLatency count one-tap-delay" $ do
      let g = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sinOsc 220.0 0.0
            y <- staticPlugin oneTapDelayPlugin a b
            out 0 y
      tg <- case compileTemplateGraph [("g", g)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let feats = concatMap (\t -> [extractFeatures (tplGraph t)])
                            (tgTemplates tg)
      fcfLatencyNodes <$> feats @?= [1]
      fcfMaxLatency   <$> feats @?= [1]

  , testCase "fcfLatencyNodes / fcfMaxLatency are zero on an Identity-only graph" $ do
      let g = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sinOsc 220.0 0.0
            y <- staticPlugin identityPlugin a b
            out 0 y
      tg <- case compileTemplateGraph [("g", g)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let feats = concatMap (\t -> [extractFeatures (tplGraph t)])
                            (tgTemplates tg)
      fcfLatencyNodes <$> feats @?= [0]
      fcfMaxLatency   <$> feats @?= [0]
  ]
