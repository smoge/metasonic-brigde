-- |
-- Module      : MetaSonic.App.CorpusSurvey
-- Description : Phase 6.A.3 — Pattern corpus layer-(b) survey.
--
-- A descriptive reporting subcommand (@--corpus-survey@) that
-- runs the pattern corpus rows through the existing
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
import           System.Exit               (die)

import           MetaSonic.App.Survey      (CorpusGraphSummary (..),
                                             renderShape,
                                             shapeHasKernel,
                                             surveyCorpusGraph)
import           MetaSonic.Bridge.Compile  (RegionKernel)
import           MetaSonic.Bridge.Source   (SynthGraph)
import qualified MetaSonic.Pattern.Corpus  as Corpus

------------------------------------------------------------
-- Corpus catalog
------------------------------------------------------------

-- | One corpus row: an initial template list plus any swap-target
-- template lists referenced by 'PEHotSwap' events in the row's
-- event stream.
--
-- 'cceSwapTargets' is the list of @(SwapLabel, templateList)@
-- pairs the row's events install via 'PEHotSwap'. Including swap
-- targets in the survey means future drift in a swap payload's
-- shape shows up here, not silently in the next bug report.
data CorpusCatalogEntry = CorpusCatalogEntry
  { cceRow         :: !String
  , cceInitial     :: ![(String, SynthGraph)]
  , cceSwapTargets :: ![(String, [(String, SynthGraph)])]
  }

corpusCatalog :: [CorpusCatalogEntry]
corpusCatalog =
  [ CorpusCatalogEntry "drone-with-vibrato"
      Corpus.droneVibratoTemplates       []
  , CorpusCatalogEntry "arpeggio-send-return"
      Corpus.arpeggioSendReturnTemplates []
  , CorpusCatalogEntry "polyphonic-stab"
      Corpus.polyphonicStabTemplates     []
  , CorpusCatalogEntry "hot-swap-edit"
      Corpus.hotSwapEditTemplates
      [("edit-cutoff", Corpus.hotSwapEditAfterTemplates)]
  , CorpusCatalogEntry "layered-ensemble"
      Corpus.layeredEnsembleTemplates    []
  , CorpusCatalogEntry "spectral-freeze-pad"
      Corpus.spectralFreezePadTemplates   []
  ]

-- | A single survey iteration unit. The 'fpVariant' field labels
-- initial templates ('Nothing') and swap-target templates ('Just
-- swapLabel') distinctly so the report does not collapse them.
data FlatPick = FlatPick
  { fpRow      :: !String
  , fpTemplate :: !String
  , fpVariant  :: !(Maybe String)
  , fpGraph    :: !SynthGraph
  }

flattenCatalog :: CorpusCatalogEntry -> [FlatPick]
flattenCatalog e =
     [ FlatPick (cceRow e) tn Nothing g
     | (tn, g) <- cceInitial e
     ]
  ++ [ FlatPick (cceRow e) tn (Just swapLabel) g
     | (swapLabel, templates) <- cceSwapTargets e
     , (tn, g) <- templates
     ]

displayTemplate :: FlatPick -> String
displayTemplate p = case fpVariant p of
  Nothing  -> fpTemplate p
  Just lbl -> fpTemplate p <> " (swap:" <> lbl <> ")"

-- | A flat (row, template-display, summary) record used as the
-- iteration unit through the print sections.
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
  let picks      = concatMap flattenCatalog corpusCatalog
      allResults =
        [ ( fpRow p, displayTemplate p
          , surveyCorpusGraph (fpRow p) (Just (displayTemplate p)) (fpGraph p)
          )
        | p <- picks
        ]
      flatRows =
        [ FlatRow rn tn s | (rn, tn, Right s) <- allResults ]
      errs =
        [ rn <> "/" <> tn <> ": " <> err
        | (rn, tn, Left err) <- allResults
        ]

  putStrLn "Phase 6.A.3 — Pattern corpus layer-(b) survey"
  putStrLn ""

  printKernelCoverage flatRows
  putStrLn ""
  printKernelTotals flatRows
  putStrLn ""
  printShapeContributions flatRows
  putStrLn ""
  printOpportunities flatRows
  putStrLn ""

  -- Mirror '--fusion-survey's precedent: print successful sections
  -- first, then surface failures, then exit non-zero so a partial
  -- baseline does not look valid to scripts / CI.
  case errs of
    [] -> putStrLn "Done."
    _  -> do
      putStrLn "─── Compile failures ───"
      mapM_ (putStrLn . ("  " <>)) errs
      putStrLn ""
      die $ "Done with " <> show (length errs)
          <> " compile failure(s); the report above excludes them."

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
