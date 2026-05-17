-- | T-9: direct (legacy executor) equals reduction-capture path.
--
-- Drives the t9 corpus through both single-template and multi-template
-- loaders, fused and unfused, asserting that the direct render path
-- equals the reduction-capture render path for every graph. Together
-- with C0c, C0d, and C1c this proves that all four execution paths
-- (legacy / global-schedule / banded / worker-pool) agree bit-for-bit
-- on the same corpus.
--
-- Extracted from "MetaSonic.Spec.FFI" as the fourth slice of the
-- megafile split. Shared helpers ('compileBoth',
-- 'assertDirectEqualsReductionRG/TG', 't9CorpusGraphs',
-- 't9CorpusTemplates') stay in the parent module.
module MetaSonic.Spec.FFI.T9 (t9DirectEqualsReductionTests) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.FFI

import           MetaSonic.Spec.FFI       (assertDirectEqualsReductionRG,
                                           assertDirectEqualsReductionTG,
                                           compileBoth, t9CorpusGraphs,
                                           t9CorpusTemplates)


t9DirectEqualsReductionTests :: TestTree
t9DirectEqualsReductionTests =
  let nframes = 256
      blocks  = 4   -- enough to cover BusInDelayed's prev-pool path
                    -- (block 2 picks up block 1's folded writes via
                    -- the swap; later blocks expose any state-
                    -- continuity drift in oscillators / filters).
  in testGroup "T-9: direct ≡ reduction"
       [ testGroup "single template, unfused loader"
           [ testCase name $ do
               (rtUn, _) <- compileBoth name g
               assertDirectEqualsReductionRG
                 name loadRuntimeGraph rtUn nframes blocks
           | (name, g) <- t9CorpusGraphs
           ]

       , testGroup "single template, fused loader"
           [ testCase name $ do
               (_, rtF) <- compileBoth name g
               assertDirectEqualsReductionRG
                 name loadRuntimeGraphFused rtF nframes blocks
           | (name, g) <- t9CorpusGraphs
           ]

       , testGroup "multi-template, unfused loader"
           [ testCase name $
               assertDirectEqualsReductionTG
                 name loadTemplateGraph tg nframes blocks
           | (name, tg) <- t9CorpusTemplates
           ]

       , testGroup "multi-template, fused loader"
           [ testCase name $
               assertDirectEqualsReductionTG
                 name loadTemplateGraphFused tg nframes blocks
           | (name, tg) <- t9CorpusTemplates
           ]
       ]
