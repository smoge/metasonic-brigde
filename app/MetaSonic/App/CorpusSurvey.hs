-- |
-- Module      : MetaSonic.App.CorpusSurvey
-- Description : Phase 6.A.3 — Pattern corpus layer-(b) survey.
--
-- A descriptive reporting subcommand (@--corpus-survey@) that
-- runs the five pattern corpus rows through the existing
-- 'MetaSonic.App.Survey' analysis pipeline and prints a focused
-- report: per-row kernel coverage, corpus-wide kernel totals,
-- claimed / missed sink shapes, and §4.D edge-rate opportunity
-- contribution.
--
-- The point is to answer the "layer (b)" questions from the
-- Phase 6.A.1 design note: does the pattern corpus produce shapes
-- the existing surveys already recognize, and does its presence
-- move parked rows in the §4 ranked tables?

module MetaSonic.App.CorpusSurvey
  ( runCorpusSurvey
  ) where

import           Data.List                 (intercalate)
import qualified Data.Map.Strict           as M

import           MetaSonic.App.Survey      (CorpusGraphSummary (..),
                                             renderShape,
                                             shapeHasKernel,
                                             surveyCorpusGraph)
import           MetaSonic.Bridge.Compile  (RegionKernel)
import qualified MetaSonic.Pattern.Corpus  as Corpus

------------------------------------------------------------
-- Corpus catalog
------------------------------------------------------------

-- | A flat (row, template, summary) record used as the iteration
-- unit through the survey output sections.
data FlatRow = FlatRow
  { frRow      :: !String
  , frTemplate :: !String
  , frSummary  :: !CorpusGraphSummary
  }

------------------------------------------------------------
-- Top-level entry
------------------------------------------------------------

runCorpusSurvey :: IO ()
runCorpusSurvey = do
  let allResults =
        [ (rowName, tn, surveyCorpusGraph rowName (Just tn) g)
        | (rowName, templates) <-
            [ ("drone-with-vibrato",   Corpus.droneVibratoTemplates)
            , ("arpeggio-send-return", Corpus.arpeggioSendReturnTemplates)
            , ("polyphonic-stab",      Corpus.polyphonicStabTemplates)
            , ("hot-swap-edit",        Corpus.hotSwapEditTemplates)
            , ("layered-ensemble",     Corpus.layeredEnsembleTemplates)
            ]
        , (tn, g) <- templates
        ]
      flatRows =
        [ FlatRow rn tn s | (rn, tn, Right s) <- allResults ]
      errs =
        [ rn <> "/" <> tn <> ": " <> err
        | (rn, tn, Left err) <- allResults
        ]

  putStrLn "Phase 6.A.3 — Pattern corpus layer-(b) survey"
  putStrLn ""

  case errs of
    [] -> pure ()
    _  -> do
      putStrLn "─── Compile failures ───"
      mapM_ (putStrLn . ("  " <>)) errs
      putStrLn ""

  printKernelCoverage flatRows
  putStrLn ""
  printKernelTotals flatRows
  putStrLn ""
  printShapeContributions flatRows
  putStrLn ""
  printOpportunities flatRows
  putStrLn ""
  putStrLn "Done."

------------------------------------------------------------
-- Per-(row, template) §4.B kernel coverage table
------------------------------------------------------------

printKernelCoverage :: [FlatRow] -> IO ()
printKernelCoverage rows = do
  putStrLn "─── §4.B kernel coverage per (row, template) ───"
  putStrLn (fmt header)
  mapM_ (putStrLn . fmt . renderOne) rows
  where
    header = ["row", "template", "nodes", "regs", "§4.B-regs", "kernels"]
    widths = [22, 10, 6, 5, 10, 36]
    pad w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '
    fmt cells = intercalate "  " (zipWith pad widths cells)
    renderOne r =
      [ frRow r
      , frTemplate r
      , show (csNodes        (frSummary r))
      , show (csRegions      (frSummary r))
      , show (csFusedRegions (frSummary r))
      , kernelTallyText (csKernels (frSummary r))
      ]

kernelTallyText :: [(RegionKernel, Int)] -> String
kernelTallyText [] = "—"
kernelTallyText xs =
  intercalate ", " [show k <> "×" <> show n | (k, n) <- xs]

------------------------------------------------------------
-- Corpus-wide §4.B kernel totals
------------------------------------------------------------

printKernelTotals :: [FlatRow] -> IO ()
printKernelTotals rows = do
  putStrLn "─── §4.B kernel totals across the corpus ───"
  -- Key by 'show' since 'RegionKernel' lacks an 'Ord' instance.
  let totals :: M.Map String Int
      totals = foldr stepRow M.empty rows
      stepRow r m =
        foldr (\(k, n) acc -> M.insertWith (+) (show k) n acc) m
              (csKernels (frSummary r))
  if M.null totals
    then putStrLn "  (no §4.B kernels claimed)"
    else mapM_ (\(kStr, n) -> putStrLn $ "  " <> kStr <> ": " <> show n)
              (M.toList totals)

------------------------------------------------------------
-- Sink-shape claimed / missed contributions
------------------------------------------------------------

printShapeContributions :: [FlatRow] -> IO ()
printShapeContributions rows = do
  putStrLn "─── §4.B sink-shape contributions ───"

  let triples =
        [ (frRow r <> "/" <> frTemplate r, shape, claimed)
        | r <- rows
        , (shape, claimed) <- csShapes (frSummary r)
        ]
      claimedPairs        = [ (tag, s) | (tag, s, True)  <- triples ]
      missedNoKernel      = [ (tag, s) | (tag, s, False) <- triples
                                       , not (shapeHasKernel s)
                            ]
      missedKernelBlocked = [ (tag, s) | (tag, s, False) <- triples
                                       , shapeHasKernel s
                            ]

  putStrLn "  Claimed shapes:"
  printGrouped claimedPairs

  putStrLn ""
  putStrLn "  Missed shapes — no §4.B kernel exists for this shape:"
  printGrouped missedNoKernel

  putStrLn ""
  putStrLn "  Missed shapes — kernel exists but a precondition or"
  putStrLn "  longest-match priority blocked the claim:"
  printGrouped missedKernelBlocked
  where
    printGrouped pairs
      | null pairs = putStrLn "    (none)"
      | otherwise  =
          let grouped =
                M.fromListWith (<>)
                  [ (renderShape s, [tag]) | (tag, s) <- pairs ]
          in mapM_ (\(shape, tags) ->
                     putStrLn $ "    " <> shape
                             <> ": " <> intercalate ", " tags)
                   (M.toList grouped)

------------------------------------------------------------
-- §4.D edge-rate opportunity producers
------------------------------------------------------------

printOpportunities :: [FlatRow] -> IO ()
printOpportunities rows = do
  putStrLn "─── §4.D edge-rate opportunity producers ───"
  putStrLn "  Producers whose every active audio-input consumer port"
  putStrLn "  is non-sample-accurate (block-latched or ignored)."
  -- Key by 'show' since 'NodeKind' lacks an 'Ord' instance.
  let producers =
        [ (frRow r <> "/" <> frTemplate r, kind)
        | r <- rows
        , kind <- csOppProducers (frSummary r)
        ]
      total                  = length producers
      perKind :: M.Map String [String]
      perKind = M.fromListWith (<>)
                  [ (show k, [tag]) | (tag, k) <- producers ]
      distinctKinds          = M.size perKind
  if total == 0
    then putStrLn "  (no §4.D opportunity producers in this corpus)"
    else do
      putStrLn $ "  Corpus contributes " <> show total
              <> " producer node(s) across " <> show distinctKinds
              <> " distinct kind(s);"
      putStrLn   "  the existing surveyed-demo baseline is 4 producers in 4 kinds."
      mapM_ (\(kStr, tags) ->
              putStrLn $ "    " <> kStr <> ": "
                      <> intercalate ", " tags)
            (M.toList perKind)
