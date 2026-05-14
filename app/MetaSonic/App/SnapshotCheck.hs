-- |
-- Module      : MetaSonic.App.SnapshotCheck
-- Description : Read-only invariants for survey and cost-lab tooling.
--
-- This is a lightweight gate for the Phase 7 tooling surface. It
-- deliberately checks structural invariants over the current survey
-- corpus and fusion cost lab instead of comparing full textual output:
-- row counts, compile success, equivalence, feature columns, latency
-- coverage, and known sink-shape signals.

module MetaSonic.App.SnapshotCheck
  ( runSnapshotCheck
  ) where

import           Control.Monad                 (forM_)
import           Data.List                     (intercalate, nub, sort)
import           System.Exit                   (die)

import qualified Data.Map.Strict               as M
import qualified MetaSonic.App.FusionCostLab   as FCL
import           MetaSonic.App.FusionCostLab   (EquivalenceStatus (..),
                                                FusionCaseFeatures (..),
                                                FusionSuperKind (..),
                                                GraphFamily (..),
                                                LabRow (..),
                                                collectFusionCostLabRows,
                                                costLabGateIndex,
                                                costLabGateIndexFor,
                                                costLabShapeIndex,
                                                familyName,
                                                generatedSuperKindIndex)
import           MetaSonic.App.FusionCostModel (GateMeasurement,
                                                ShapeKey,
                                                ShapeSummary (..),
                                                Variant (..),
                                                measuredWinThreshold,
                                                shapeKeyOf)
import           MetaSonic.App.ProfitabilityGate (GateCounts (..),
                                                  GateRow (..),
                                                  evaluateGate,
                                                  summarizeGate)
import           MetaSonic.App.Survey          (CorpusGraphSummary (..),
                                                GateShapeRow (..),
                                                KindTally,
                                                SinkShape (..),
                                                aggregateGateShapes,
                                                gateInputFor, renderShape,
                                                shapeHasKernel,
                                                surveyCorpusGraph,
                                                surveyEnsembleCorpus,
                                                surveyShapeProbes)
import           MetaSonic.Bridge.Compile      (DeclaredNodeLatency (..))
import           MetaSonic.Bridge.Planner      (FusionCandidate (..),
                                                RejectionReason (..),
                                                Verdict (..), isAccepted,
                                                isRejected,
                                                selectedFusionCandidates)
import           MetaSonic.Types               (KindCapability (..),
                                                NodeKind (..),
                                                kindCapabilities)

data SnapshotCheck = SnapshotCheck
  { scLabel  :: !String
  , scPassed :: !Bool
  , scDetail :: !String
  } deriving (Eq, Show)

data SurveySnapshots = SurveySnapshots
  { ssShapeRows    :: ![(String, Either String CorpusGraphSummary)]
  , ssEnsembleRows :: ![(String, Either String CorpusGraphSummary)]
  } deriving (Eq, Show)

runSnapshotCheck :: IO ()
runSnapshotCheck = do
  costRows <- collectFusionCostLabRows FCL.defaultOptions
  let survey   = collectSurveySnapshots
      shapeIdx = costLabShapeIndex costRows
      gateIdx  = costLabGateIndex  costRows
      checks =  costLabChecks costRows
             <> surveyChecks survey
             <> capabilityChecks survey
             <> plannerChecks survey
             <> costModelJoinChecks shapeIdx survey
             <> profitabilityGateChecks gateIdx survey
             <> gateByExecutorChecks costRows survey

  putStrLn "Phase 7 survey/cost-lab snapshot checks"
  putStrLn ""
  forM_ checks printCheck

  let failures = [c | c <- checks, not (scPassed c)]
  putStrLn ""
  if null failures
    then putStrLn $
      "All snapshot checks passed (" <> show (length checks) <> ")."
    else die $
      show (length failures) <> " snapshot check(s) failed."

collectSurveySnapshots :: SurveySnapshots
collectSurveySnapshots = SurveySnapshots
  { ssShapeRows =
      [ (name, surveyCorpusGraph ("snapshot:" <> name) Nothing graph)
      | (name, graph) <- surveyShapeProbes
      ]
  , ssEnsembleRows =
      [ (ensembleName <> "/" <> templateName,
         surveyCorpusGraph
           ("snapshot:" <> ensembleName)
           (Just templateName)
           graph)
      | (ensembleName, templates) <- surveyEnsembleCorpus
      , (templateName, graph)     <- templates
      ]
  }

costLabChecks :: [LabRow] -> [SnapshotCheck]
costLabChecks rows =
  [ check "cost-lab row counts are stable by family"
      (familyCounts == expectedFamilyCounts)
      ("expected=" <> renderCounts expectedFamilyCounts
       <> "; actual=" <> renderCounts familyCounts
       <> "; rows=" <> show (length rows)
       <> "/" <> show expectedRowCount)

  , check "cost-lab covers the expected families"
      (familyNames == expectedFamilyNames)
      ("expected=" <> intercalate "," expectedFamilyNames
       <> "; actual=" <> intercalate "," familyNames)

  , check "cost-lab non-generated variants compile and measure"
      (all rowMeasured nonGeneratedRows)
      ("unmeasured=" <> show (length [() | r <- nonGeneratedRows, not (rowMeasured r)]))

  , check "cost-lab non-generated variants remain bit-equivalent"
      (all ((== EqExact) . lrEquivalence) nonGeneratedRows)
      ("non-exact=" <> show (length [() | r <- nonGeneratedRows, lrEquivalence r /= EqExact]))

  -- §7.D step 8: the generated variant has a narrow generator
  -- today (only @[KGain, KOut]@ / @[KGain, KBusOut]@ shapes). Rows
  -- the generator can emit a program for must measure and stay
  -- bit-equivalent with the node-loop baseline; rows whose
  -- selected candidate falls outside the generator's shape set
  -- record an error and are honest "unchecked" entries.
  , check "cost-lab generated variant: emitted programs stay bit-equivalent"
      (all ((== EqExact) . lrEquivalence) generatedEmittedRows)
      ("non-exact=" <> show
        (length [() | r <- generatedEmittedRows
                    , lrEquivalence r /= EqExact]))

  , check "cost-lab generated variant: measured row count is stable"
      (length generatedEmittedRows == expectedGeneratedRows)
      ("expected=" <> show expectedGeneratedRows
       <> "; actual=" <> show (length generatedEmittedRows))

  -- §7.E step 5: pin the generator's coverage explicitly. The
  -- considered count is just the cost-lab corpus size (one
  -- generated row per member); the unsupported count tracks how
  -- many of those the generator declined. Both are deterministic
  -- and bench-noise-free, unlike the win/loss split, so they
  -- belong in the snapshot.
  , check "cost-lab generated variant: considered count is stable"
      (length generatedRows == expectedGeneratedConsidered)
      ("expected=" <> show expectedGeneratedConsidered
       <> "; actual=" <> show (length generatedRows))

  , check "cost-lab generated variant: unsupported count is stable"
      (generatedUnsupportedCount == expectedGeneratedUnsupported)
      ("expected=" <> show expectedGeneratedUnsupported
       <> "; actual=" <> show generatedUnsupportedCount)

  -- §7.G step 6: family-scoped pins on 'generated-tail-sweep'.
  -- The synthetic family is generator-supported by construction;
  -- if any member ever fails to emit, fails equivalence, or
  -- joins the unsupported bucket, the regression should fail
  -- snapshot immediately rather than rely on the global counts
  -- surviving alongside corpus growth elsewhere.
  , check "generated-tail-sweep: every member emitted"
      (tailSweepEmitted == expectedTailSweepEmitted)
      ("expected=" <> show expectedTailSweepEmitted
       <> "; actual=" <> show tailSweepEmitted)

  , check "generated-tail-sweep: every emitted row stays bit-exact"
      (tailSweepNonExact == 0)
      ("non-exact=" <> show tailSweepNonExact)

  , check "generated-tail-sweep: no unsupported rows"
      (tailSweepUnsupported == 0)
      ("unsupported=" <> show tailSweepUnsupported)

  -- §7.H step 6: block-major executor pins. Block-major shares
  -- emitted programs with sample-major (same generator, same
  -- FusionProgram), so the considered / emitted / unsupported
  -- counts mirror the sample-major numbers by construction. The
  -- pins exist so a regression — e.g. the loader silently failing
  -- to route a block-major region through the new C ABI entry —
  -- fails snapshot rather than disappearing into a per-variant
  -- speedup table.
  , check "cost-lab generated-block variant: considered count is stable"
      (length generatedBlockRows == expectedGeneratedConsidered)
      ("expected=" <> show expectedGeneratedConsidered
       <> "; actual=" <> show (length generatedBlockRows))

  , check "cost-lab generated-block variant: emitted count is stable"
      (length generatedBlockEmittedRows == expectedGeneratedRows)
      ("expected=" <> show expectedGeneratedRows
       <> "; actual=" <> show (length generatedBlockEmittedRows))

  , check "cost-lab generated-block variant: unsupported count is stable"
      (generatedBlockUnsupportedCount == expectedGeneratedUnsupported)
      ("expected=" <> show expectedGeneratedUnsupported
       <> "; actual=" <> show generatedBlockUnsupportedCount)

  , check "cost-lab generated-block variant: emitted rows stay bit-exact"
      (all ((== EqExact) . lrEquivalence) generatedBlockEmittedRows)
      ("non-exact=" <> show
        (length [() | r <- generatedBlockEmittedRows
                    , lrEquivalence r /= EqExact]))

  -- generated-tail-sweep family-scoped pins under the block-major
  -- executor. Mirror the sample-major family pins so the
  -- synthetic corpus's integrity is locked under both executors.
  , check "generated-tail-sweep: every block-major member emitted"
      (tailSweepBlockEmitted == expectedTailSweepEmitted)
      ("expected=" <> show expectedTailSweepEmitted
       <> "; actual=" <> show tailSweepBlockEmitted)

  , check "generated-tail-sweep: every block-major emitted row stays bit-exact"
      (tailSweepBlockNonExact == 0)
      ("non-exact=" <> show tailSweepBlockNonExact)

  , check "generated-tail-sweep: owned tail lengths stay stable"
      (FCL.generatedTailSweepOwnedLengths == expectedTailSweepOwnedLengths)
      ("expected=" <> show expectedTailSweepOwnedLengths
       <> "; actual=" <> show FCL.generatedTailSweepOwnedLengths)

  -- §7.I step 6: super-mode pins. Like block-major, super-mode
  -- shares emitted programs with sample-major (same generator,
  -- same FusionProgram), so the considered / emitted /
  -- unsupported counts mirror the sample-major numbers. The new
  -- pin is the recognized / fallback split: classification is
  -- structural so the counts are deterministic across runs and
  -- moves only when either the generator widens or the
  -- recognizer set grows.
  , check "cost-lab generated-super variant: considered count is stable"
      (length generatedSuperRows == expectedGeneratedConsidered)
      ("expected=" <> show expectedGeneratedConsidered
       <> "; actual=" <> show (length generatedSuperRows))

  , check "cost-lab generated-super variant: emitted count is stable"
      (length generatedSuperEmittedRows == expectedGeneratedRows)
      ("expected=" <> show expectedGeneratedRows
       <> "; actual=" <> show (length generatedSuperEmittedRows))

  , check "cost-lab generated-super variant: unsupported count is stable"
      (generatedSuperUnsupportedCount == expectedGeneratedUnsupported)
      ("expected=" <> show expectedGeneratedUnsupported
       <> "; actual=" <> show generatedSuperUnsupportedCount)

  , check "cost-lab generated-super variant: emitted rows stay bit-exact"
      (all ((== EqExact) . lrEquivalence) generatedSuperEmittedRows)
      ("non-exact=" <> show
        (length [() | r <- generatedSuperEmittedRows
                    , lrEquivalence r /= EqExact]))

  , check "cost-lab generated-super recognized count is stable"
      (superRecognizedCount == expectedSuperRecognized)
      ("expected=" <> show expectedSuperRecognized
       <> "; actual=" <> show superRecognizedCount)

  , check "cost-lab generated-super fallback count is stable"
      (superFallbackCount == expectedSuperFallback)
      ("expected=" <> show expectedSuperFallback
       <> "; actual=" <> show superFallbackCount)

  , check "cost-lab generated-super recognized-by-shape counts are stable"
      (superKindCounts == expectedSuperKindCounts)
      ("expected=" <> show expectedSuperKindCounts
       <> "; actual=" <> show superKindCounts)

  , check "generated-tail-sweep: every super-mode member emitted"
      (tailSweepSuperEmitted == expectedTailSweepEmitted)
      ("expected=" <> show expectedTailSweepEmitted
       <> "; actual=" <> show tailSweepSuperEmitted)

  , check "generated-tail-sweep: every super-mode emitted row stays bit-exact"
      (tailSweepSuperNonExact == 0)
      ("non-exact=" <> show tailSweepSuperNonExact)

  , check "cost-lab corpus carries declared latency coverage"
      corpusLatency
      ("max-latency=" <> show maxLatency)

  , check "cost-lab fanout row stays a kernel near-miss"
      fanoutNearMiss
      ("fanout-node-loop=" <> maybe "missing" show (featuresFor "sin-fanout-two-out" VarNodeLoop)
       <> "; fanout-region=" <> maybe "missing" show (featuresFor "sin-fanout-two-out" VarRegionKernel))

  , check "cost-lab return tail records bus footprint"
      returnTailFootprint
      ("return-tail=" <> maybe "missing" show (featuresFor "send-busout-return" VarNodeLoop))
  ]
  where
    familyNames = sort (nub (map (familyName . lrFamily) rows))
    familyCounts =
      [ (fam, length [() | r <- rows, familyName (lrFamily r) == fam])
      | fam <- familyNames
      ]

    -- Variant fan-out is now 6 (node-loop, region-kernel, rfused,
    -- generated, generated-block, generated-super). Bumping
    -- per-family row counts 5x -> 6x; the underlying member
    -- counts per family are unchanged.
    expectedFamilyCounts =
      [ ("add-chain",             24)
      , ("corpus",                42)
      , ("dynamic-gain",          18)
      , ("fanout",                 6)
      , ("generated-tail-sweep",  36)
      , ("return-tail",            6)
      , ("sink-chain",            36)
      ]

    expectedRowCount =
      sum (map snd expectedFamilyCounts)

    expectedFamilyNames =
      map fst expectedFamilyCounts

    renderCounts xs =
      intercalate "," [fam <> ":" <> show n | (fam, n) <- xs]

    rowMeasured r =
      lrError r == Nothing
        && lrFeatures r /= Nothing
        && lrNsPerSample r /= Nothing

    -- §7.D step 8 / §7.H step 3 / §7.I step 6: split the row set
    -- so no generated variant's partial-generator state (a real
    -- "no shape implemented yet" signal) trips the non-generated
    -- checks. The three generated variants — VarGenerated
    -- (sample-major), VarGeneratedBlock (block-major), and
    -- VarGeneratedSuper (super-mode) — share the same emit-or-
    -- decline behavior because they consume the same emitted
    -- program.
    nonGeneratedRows =
      [ r | r <- rows
          , lrVariant r /= VarGenerated
          , lrVariant r /= VarGeneratedBlock
          , lrVariant r /= VarGeneratedSuper
      ]
    generatedRows =
      [r | r <- rows, lrVariant r == VarGenerated]
    generatedBlockRows =
      [r | r <- rows, lrVariant r == VarGeneratedBlock]
    generatedEmittedRows =
      [r | r <- generatedRows, lrError r == Nothing]
    -- Pinned: the number of cost-lab members whose maximal
    -- selected candidate the current generator handles. Bump this
    -- intentionally when the generator widens to more shapes.
    --
    -- Phase 7.E step 3: generator now accepts any candidate whose
    -- last two members are @[KGain, KOut]@ or @[KGain, KBusOut]@,
    -- emitting the tail as the owned suffix and leaving the prefix
    -- as node-loop work. This pulls in every existing chain that
    -- happens to end in that pair, not just the length-2 cases.
    --
    -- Phase 7.G step 3: the generator walks any stateless compute
    -- tail (@KGain@ / @KAdd@) ending in a sink, so @KAdd -> KOut@
    -- shapes now emit as well. Cost-lab rows move from
    -- unsupported to emitted accordingly.
    --
    -- Phase 7.G step 4: the synthetic 'generated-tail-sweep'
    -- family contributes six more generator-supported members,
    -- pushing emitted 20 -> 26 and considered 22 -> 28.
    -- unsupported stays at 2.
    expectedGeneratedRows = 26

    -- §7.E step 5: pin the considered / unsupported split too.
    -- considered = one generated row per cost-lab member; it moves
    -- only when the cost-lab corpus changes. unsupported = members
    -- whose maximal selected candidate the generator declines;
    -- it moves only when the generator's shape coverage changes.
    -- Neither flaps with bench noise.
    expectedGeneratedConsidered  = 28
    expectedGeneratedUnsupported = 2

    generatedUnsupportedCount =
      length [() | r <- generatedRows, lrError r /= Nothing]

    -- §7.H block-major mirrors of the sample-major helpers
    -- above. Same emitted programs flow through both executors,
    -- so the structural counts should match the sample-major
    -- side; the pins exist to catch loader / FFI regressions.
    generatedBlockEmittedRows =
      [r | r <- generatedBlockRows, lrError r == Nothing]
    generatedBlockUnsupportedCount =
      length [() | r <- generatedBlockRows, lrError r /= Nothing]

    -- §7.G family-scoped helpers. Every member of
    -- 'generated-tail-sweep' is generator-supported by
    -- construction, so each of these counts is structural.
    tailSweepGenerated =
      [ r | r <- generatedRows
          , familyName (lrFamily r) == "generated-tail-sweep" ]
    tailSweepEmitted =
      length [() | r <- tailSweepGenerated, lrError r == Nothing]
    tailSweepUnsupported =
      length [() | r <- tailSweepGenerated, lrError r /= Nothing]
    tailSweepNonExact =
      length [() | r <- tailSweepGenerated
                 , lrError r == Nothing
                 , lrEquivalence r /= EqExact ]
    expectedTailSweepEmitted = 6
    expectedTailSweepOwnedLengths = [2, 3, 3, 5, 8, 16]

    -- §7.H block-major family-scoped helpers.
    tailSweepBlockGenerated =
      [ r | r <- generatedBlockRows
          , familyName (lrFamily r) == "generated-tail-sweep" ]
    tailSweepBlockEmitted =
      length [() | r <- tailSweepBlockGenerated, lrError r == Nothing]
    tailSweepBlockNonExact =
      length [() | r <- tailSweepBlockGenerated
                 , lrError r == Nothing
                 , lrEquivalence r /= EqExact ]

    -- §7.I super-mode helpers. The super executor shares emitted
    -- programs with the other generated variants, so the
    -- considered / emitted / unsupported counts mirror them by
    -- construction. The new piece is the recognized / fallback
    -- split, which is structural and pinned below.
    generatedSuperRows =
      [r | r <- rows, lrVariant r == VarGeneratedSuper]
    generatedSuperEmittedRows =
      [r | r <- generatedSuperRows, lrError r == Nothing]
    generatedSuperUnsupportedCount =
      length [() | r <- generatedSuperRows, lrError r /= Nothing]

    -- Look up an emitted super-mode row's recognizer
    -- classification by re-using the structural index built once
    -- in 'FusionCostLab.generatedSuperKindIndex'. The map covers
    -- every cost-lab member; rows whose graph the generator
    -- declines just don't appear under VarGeneratedSuper either,
    -- so the lookup miss case is unreachable in practice.
    superKindOf r =
      M.lookup (familyName (lrFamily r), lrMember r) generatedSuperKindIndex

    superRecognizedCount =
      length [ () | r <- generatedSuperEmittedRows
                  , Just k <- [superKindOf r]
                  , k /= FusionSuperNotRecognized ]
    superFallbackCount =
      length [ () | r <- generatedSuperEmittedRows
                  , Just FusionSuperNotRecognized <- [superKindOf r] ]

    superKindCounts :: [(String, Int)]
    superKindCounts =
      [ ("AddGainOut", countKind FusionSuperAddGainOut)
      , ("GainOut",    countKind FusionSuperGainOut)
      , ("fallback",   countKind FusionSuperNotRecognized)
      ]
      where
        countKind kind = length
          [ () | r <- generatedSuperEmittedRows
               , Just k <- [superKindOf r]
               , k == kind ]

    -- §7.I super-mode family-scoped helpers.
    tailSweepSuperGenerated =
      [ r | r <- generatedSuperRows
          , familyName (lrFamily r) == "generated-tail-sweep" ]
    tailSweepSuperEmitted =
      length [() | r <- tailSweepSuperGenerated, lrError r == Nothing]
    tailSweepSuperNonExact =
      length [() | r <- tailSweepSuperGenerated
                 , lrError r == Nothing
                 , lrEquivalence r /= EqExact ]

    -- Pinned super-mode classification counts. Derived from the
    -- diagnostic output the first run reported: 17 GainOut + 1
    -- AddGainOut recognized, 8 fallback (= 26 emitted - 18
    -- recognized). All structural; will shift only when the
    -- generator widens or the recognizer set grows.
    expectedSuperRecognized = 18
    expectedSuperFallback   = 8
    expectedSuperKindCounts :: [(String, Int)]
    expectedSuperKindCounts =
      [ ("AddGainOut",  1)
      , ("GainOut",    17)
      , ("fallback",    8)
      ]

    corpusFeatures =
      [ f
      | r <- rows
      , lrFamily r == FamilyCorpus
      , Just f <- [lrFeatures r]
      ]

    maxLatency =
      maximumOrZero (map fcfMaxLatency corpusFeatures)

    corpusLatency =
      any (\f -> fcfLatencyNodes f > 0 && fcfMaxLatency f >= 1024)
          corpusFeatures

    fanoutNearMiss =
      case featuresFor "sin-fanout-two-out" VarRegionKernel of
        Just f ->
          fcfFanoutNodes f > 0
            && fcfMaxConsumerCount f >= 2
            && fcfKernelClaims f == 0
        Nothing -> False

    returnTailFootprint =
      case featuresFor "send-busout-return" VarNodeLoop of
        Just f -> fcfBusWrites f >= 2 && fcfBusReads f >= 1
        Nothing -> False

    featuresFor member variant =
      case [f | r <- rows
              , lrMember r == member
              , lrVariant r == variant
              , Just f <- [lrFeatures r]
           ] of
        (f : _) -> Just f
        []      -> Nothing

surveyChecks :: SurveySnapshots -> [SnapshotCheck]
surveyChecks snapshots =
  [ check "survey shape probes compile"
      (null shapeErrs)
      (compileDetail shapeErrs)

  , check "survey ensemble corpus compiles"
      (null ensembleErrs)
      (compileDetail ensembleErrs)

  , check "survey corpus size stays non-trivial"
      (length (ssShapeRows snapshots) >= 20
       && length (ssEnsembleRows snapshots) >= 20)
      ("shape-rows=" <> show (length (ssShapeRows snapshots))
       <> "; ensemble-template-rows=" <> show (length (ssEnsembleRows snapshots)))

  , check "survey spectral-freeze latency stays visible"
      spectralLatency
      (shapeSummary "shape/spectral-freeze-tail")

  , check "survey BusIn return-tail shape stays claimed"
      busInReturnClaim
      (shapeSummary "shape/busin-lpf-gain-out")

  , check "survey missed no-kernel shapes remain visible"
      (not (null missedNoKernel))
      ("missed-shapes=" <> show (length (nub (map fst missedNoKernel)))
       <> "; sources=" <> show (length (nub (map snd missedNoKernel)))
       <> "; examples=" <> missedExamples)
  ]
  where
    allRows = ssShapeRows snapshots <> ssEnsembleRows snapshots
    shapeErrs = compileFailures (ssShapeRows snapshots)
    ensembleErrs = compileFailures (ssEnsembleRows snapshots)

    spectralLatency =
      case lookup "shape/spectral-freeze-tail" (ssShapeRows snapshots) of
        Just (Right row) ->
          any isSpectralFreezeLatency (csDeclaredLatency row)
        _ -> False

    isSpectralFreezeLatency d =
      dnlKind d == KSpectralFreeze && dnlLatency d >= 1024

    busInReturnClaim =
      case lookup "shape/busin-lpf-gain-out" (ssShapeRows snapshots) of
        Just (Right row) ->
          (SinkBusInLpfGain, True) `elem` csShapes row
        _ -> False

    missedNoKernel =
      [ (shape, label)
      | (label, Right row) <- allRows
      , (shape, False) <- csShapes row
      , not (shapeHasKernel shape)
      ]

    missedExamples =
      intercalate ", "
        (take 3 [renderShape shape <> "@" <> label
                | (shape, label) <- missedNoKernel])

    shapeSummary name =
      case lookup name (ssShapeRows snapshots) of
        Just (Right row) ->
          "shapes=" <>
            intercalate ", "
              [ renderShape shape <> ":" <> if claimed then "claimed" else "missed"
              | (shape, claimed) <- csShapes row
              ]
          <> "; latency=" <> show (csDeclaredLatency row)
        Just (Left err) -> err
        Nothing         -> "missing"

-- §7.B capability invariants on the snapshot corpus. The snapshot
-- corpus is fixed; if a capability count moves, either the corpus
-- grew, or 'kindCapabilities' was edited, or a new 'NodeKind' landed
-- without a row. All three deserve an explicit acknowledgement, so
-- the expected counts are pinned and treated as a snapshot.
capabilityChecks :: SurveySnapshots -> [SnapshotCheck]
capabilityChecks snapshots =
  [ check "corpus capability counts are stable"
      (perCap == expectedCap)
      ("expected=" <> renderCapCounts expectedCap
       <> "; actual=" <> renderCapCounts perCap)

  , check "corpus contains no CapHardBarrier nodes"
      (lookupCap CapHardBarrier perCap == 0)
      ("hard-barrier=" <> show (lookupCap CapHardBarrier perCap))

  , check "corpus CapLatencyBearing nodes match KSpectralFreeze count"
      (lookupCap CapLatencyBearing perCap == spectralFreezeNodes)
      ("latency-bearing=" <> show (lookupCap CapLatencyBearing perCap)
       <> "; spectral-freeze=" <> show spectralFreezeNodes)
  ]
  where
    allRows = ssShapeRows snapshots <> ssEnsembleRows snapshots
    aggTally :: KindTally
    aggTally =
      foldr mergeTallies []
            [ csKindTally row | (_, Right row) <- allRows ]

    perCap =
      [ (cap, nodesWithCap cap aggTally)
      | cap <- [minBound .. maxBound :: KindCapability]
      ]

    spectralFreezeNodes =
      maybe 0 id (lookup KSpectralFreeze aggTally)

    -- Pinned counts from the current snapshot corpus. Bump these
    -- intentionally when the corpus changes (or when a kind's
    -- capability row is edited); a silent shift means one of the
    -- two tables drifted.
    expectedCap =
      [ (CapStatelessOp,    107)
      , (CapStatefulOp,     112)
      , (CapSinkTerminal,    72)
      , (CapResourceAccess,  87)
      , (CapLatencyBearing,   1)
      , (CapHardBarrier,      0)
      ]

mergeTallies :: KindTally -> KindTally -> KindTally
mergeTallies a b =
  [ (k, n)
  | k <- [minBound .. maxBound :: NodeKind]
  , let n = countOf k a + countOf k b
  , n > 0
  ]
  where
    countOf k = maybe 0 id . lookup k

nodesWithCap :: KindCapability -> KindTally -> Int
nodesWithCap cap tally =
  sum [n | (k, n) <- tally, cap `elem` kindCapabilities k]

lookupCap :: KindCapability -> [(KindCapability, Int)] -> Int
lookupCap c = maybe 0 id . lookup c

renderCapCounts :: [(KindCapability, Int)] -> String
renderCapCounts xs =
  intercalate "," [show c <> "=" <> show n | (c, n) <- xs]

-- §7.C planner verdict invariants on the snapshot corpus.
-- Pinned counts are intentionally specific: candidate/accepted/
-- rejected totals, selected accepted totals, and per-rejection-
-- reason counts. Drift means
-- either the corpus changed, a planner rule changed, or
-- 'kindCapabilities' moved a kind to a different bucket. All three
-- deserve an explicit acknowledgement, so the counts are pinned
-- and treated as a snapshot.
plannerChecks :: SurveySnapshots -> [SnapshotCheck]
plannerChecks snapshots =
  [ check "planner total candidate count is stable"
      (totalCandidates == expectedTotal)
      ("expected=" <> show expectedTotal
       <> "; actual=" <> show totalCandidates)

  , check "planner accepted/rejected split is stable"
      (acceptedCount == expectedAccepted
        && rejectedCount == expectedRejected)
      ("expected accepted=" <> show expectedAccepted
       <> " rejected=" <> show expectedRejected
       <> "; actual accepted=" <> show acceptedCount
       <> " rejected=" <> show rejectedCount)

  , check "planner selected accepted count is stable"
      (selectedCount == expectedSelected)
      ("expected=" <> show expectedSelected
       <> "; actual=" <> show selectedCount)

  , check "planner selected generated-eligible count is stable"
      (selectedNoMatchCount == expectedSelectedNoMatch)
      ("expected=" <> show expectedSelectedNoMatch
       <> "; actual=" <> show selectedNoMatchCount)

  , check "planner per-rejection-reason counts are stable"
      (rejectionCounts == expectedRejectionCounts)
      ("expected=" <> renderReasonCounts expectedRejectionCounts
       <> "; actual=" <> renderReasonCounts rejectionCounts)

  , check "planner accepts at least one §4.B-matched candidate"
      (matchedCount > 0)
      ("matched=" <> show matchedCount)
  ]
  where
    allRows = ssShapeRows snapshots <> ssEnsembleRows snapshots
    verdicts =
      [ v
      | (_, Right row) <- allRows
      , v <- csPlannerVerdicts row
      ]

    totalCandidates = length verdicts
    acceptedCount   = length (filter isAccepted verdicts)
    rejectedCount   = length (filter isRejected verdicts)
    selectedCands   =
      concat
        [ selectedFusionCandidates (csPlannerVerdicts row)
        | (_, Right row) <- allRows
        ]
    selectedCount   = length selectedCands
    selectedNoMatchCount =
      length [() | c <- selectedCands, fcMatchedShape c == Nothing]
    matchedCount    =
      length [ ()
             | Accepted c <- verdicts
             , Just _ <- [fcMatchedShape c]
             ]

    rejectionCounts :: [(String, Int)]
    rejectionCounts =
      let reasons = [r | Rejected _ r <- verdicts]
          tags    = map reasonTagName reasons
      in [ (tag, length (filter (== tag) tags))
         | tag <- expectedReasonOrder
         , tag `elem` tags
         ]

    -- Pinned snapshot. Bump these intentionally when a planner
    -- rule or the corpus changes; a silent shift means the
    -- planner output drifted.
    expectedTotal      = 193
    expectedAccepted   = 158
    expectedRejected   = 35
    expectedSelected   = 69
    expectedSelectedNoMatch = 18
    expectedRejectionCounts :: [(String, Int)]
    expectedRejectionCounts =
      [ ("ReasonStatefulInterior", 13)
      , ("ReasonFanoutEscape",     13)
      , ("ReasonResourceMidChain",  2)
      , ("ReasonLatencyMidChain",   2)
      , ("ReasonNonAdjacentDataflow", 5)
      ]

    -- Display order for rejection reasons; matches
    -- 'printRejectionSummary' in 'MetaSonic.App.Survey'.
    expectedReasonOrder =
      [ "ReasonStatefulInterior"
      , "ReasonFanoutEscape"
      , "ReasonResourceMidChain"
      , "ReasonLatencyMidChain"
      , "ReasonNonAdjacentDataflow"
      , "ReasonHardBarrier"
      , "ReasonTooShort"
      , "ReasonNoTerminalSink"
      , "ReasonCrossesRegion"
      ]

reasonTagName :: RejectionReason -> String
reasonTagName r = case r of
  ReasonHardBarrier{}      -> "ReasonHardBarrier"
  ReasonLatencyMidChain{}  -> "ReasonLatencyMidChain"
  ReasonResourceMidChain{} -> "ReasonResourceMidChain"
  ReasonStatefulInterior{} -> "ReasonStatefulInterior"
  ReasonFanoutEscape{}     -> "ReasonFanoutEscape"
  ReasonNonAdjacentDataflow{} -> "ReasonNonAdjacentDataflow"
  ReasonTooShort{}         -> "ReasonTooShort"
  ReasonNoTerminalSink     -> "ReasonNoTerminalSink"
  ReasonCrossesRegion{}    -> "ReasonCrossesRegion"

renderReasonCounts :: [(String, Int)] -> String
renderReasonCounts xs =
  intercalate "," [tag <> "=" <> show n | (tag, n) <- xs]

-- §7.C cost-model join invariants on the snapshot corpus. Counts
-- The three pinned signals are stable across bench-noise:
--
--   * covered count — purely structural (§4.B kernel match).
--   * total measured count (win + loss) — every cost-lab row that
--     compiled, equivalence-checked, and timed contributes,
--     regardless of which side of 'measuredWinThreshold' its
--     speedup lands on.
--   * needs-benchmark count — the Phase 7.D gate signal: shapes
--     the cost lab has no measurement for at all.
--
-- The win/loss split is intentionally NOT pinned: shapes whose
-- speedup hovers near 'measuredWinThreshold' (1.05×) flap across
-- runs, and locking the split here would force the snapshot to
-- chase noise. The total measurement count is what tells us
-- "the cost lab has evidence" regardless of which side the speedup
-- lands on.
costModelJoinChecks :: M.Map ShapeKey ShapeSummary
                    -> SurveySnapshots -> [SnapshotCheck]
costModelJoinChecks shapeIdx snapshots =
  [ check "cost-model join covered count is stable"
      (lookupClass "covered" classCounts == expectedCovered)
      ("expected covered=" <> show expectedCovered
       <> "; actual=" <> show (lookupClass "covered" classCounts))

  , check "cost-model join total measured count is stable"
      (measuredTotal == expectedMeasured)
      ("expected measured=" <> show expectedMeasured
       <> "; actual measured-win+measured-loss=" <> show measuredTotal
       <> " (win=" <> show (lookupClass "measured-win" classCounts)
       <> " loss=" <> show (lookupClass "measured-loss" classCounts)
       <> ")")

  , check "cost-model join needs-benchmark count is stable"
      (lookupClass "needs-benchmark" classCounts == expectedNeedsBenchmark)
      ("expected needs-benchmark=" <> show expectedNeedsBenchmark
       <> "; actual=" <> show (lookupClass "needs-benchmark" classCounts))

  , check "cost-model join total matches selected-candidate count"
      (sumClasses classCounts == selectedCount)
      ("class-sum=" <> show (sumClasses classCounts)
       <> "; selected=" <> show selectedCount)
  ]
  where
    allRows = ssShapeRows snapshots <> ssEnsembleRows snapshots

    -- One (shapeKey, matchedShape) pair per selected candidate
    -- occurrence — same granularity as the survey table count.
    candidates =
      [ (shapeKeyOf c, fcMatchedShape c)
      | (_, Right row) <- allRows
      , c <- selectedFusionCandidates (csPlannerVerdicts row)
      ]

    selectedCount = length candidates

    classifyEntry (_, Just _) = "covered"
    classifyEntry (key, Nothing) =
      case M.lookup key shapeIdx of
        Just summ
          | ssSpeedup summ >= measuredWinThreshold -> "measured-win"
          | otherwise                              -> "measured-loss"
        Nothing                  -> "needs-benchmark"

    classCounts :: [(String, Int)]
    classCounts =
      [ (cls, length (filter ((== cls) . classifyEntry) candidates))
      | cls <- classOrder
      ]

    measuredTotal =
      lookupClass "measured-win" classCounts
        + lookupClass "measured-loss" classCounts

    lookupClass cls = maybe 0 id . lookup cls

    sumClasses = sum . map snd

    classOrder =
      [ "covered"
      , "measured-win"
      , "measured-loss"
      , "needs-benchmark"
      ]

    -- Pinned snapshot. Bump these intentionally when the cost-lab
    -- corpus changes, a planner rule changes, or the snapshot
    -- corpus changes; a silent shift means the join drifted.
    --
    -- Phase 7.E step 3: pulse-gain-out and tri-lpf-gain-out joined
    -- the cost-lab corpus, so the two survey shapes
    -- ([KPulseOsc,KGain,KOut], [KTriOsc,KLPF,KGain,KOut]) that
    -- were previously needs-benchmark now have measurements.
    expectedCovered        = 51
    expectedMeasured       = 14
    expectedNeedsBenchmark = 4

-- §7.F profitability-gate invariants. The gate is a verdict
-- function over the cost-model join; the pinned signals here are
-- deliberately the deterministic, bench-noise-free ones:
--
--   * total gate rows — structural, moves only with corpus or
--     planner-rule changes.
--   * needs-benchmark / unsupported / non-exact /
--     covered-by-hand-kernel counts — all structural; move with
--     corpus, generator coverage, §4.B kernel coverage, or
--     correctness regressions respectively.
--   * occurrence count — structural; proves the per-shape
--     aggregation still accounts for every graph-local selected
--     candidate.
--
-- prefer-generated / prefer-existing are intentionally NOT pinned:
-- rows hovering near 'measuredWinThreshold' (1.05x) flap between
-- them under bench noise, and locking that split would force
-- snapshot to chase noise. The same discipline already shields
-- the 7.D/7.E pins.
profitabilityGateChecks
  :: M.Map ShapeKey GateMeasurement -> SurveySnapshots -> [SnapshotCheck]
profitabilityGateChecks gateIdx snapshots =
  [ check "gate total row count is stable"
      (gcTotal counts == expectedTotal)
      ("expected=" <> show expectedTotal
       <> "; actual=" <> show (gcTotal counts))

  , check "gate non-exact stays 0 (correctness invariant)"
      (gcNonExact counts == 0)
      ("expected=0; actual=" <> show (gcNonExact counts))

  , check "gate unsupported count is stable"
      (gcUnsupported counts == expectedUnsupported)
      ("expected=" <> show expectedUnsupported
       <> "; actual=" <> show (gcUnsupported counts))

  , check "gate needs-benchmark count is stable"
      (gcNeedsBenchmark counts == expectedNeedsBenchmark)
      ("expected=" <> show expectedNeedsBenchmark
       <> "; actual=" <> show (gcNeedsBenchmark counts))

  , check "gate covered-by-hand-kernel count is stable"
      (gcCoveredByHandKernel counts == expectedCovered)
      ("expected=" <> show expectedCovered
       <> "; actual=" <> show (gcCoveredByHandKernel counts))

  , check "gate occurrence count matches selected candidates"
      (selectedOccurrenceCount == selectedCount)
      ("gate-occurrences=" <> show selectedOccurrenceCount
       <> "; selected=" <> show selectedCount)
  ]
  where
    allRows = ssShapeRows snapshots <> ssEnsembleRows snapshots
    verdictGroups =
      [ csPlannerVerdicts row | (_, Right row) <- allRows ]
    selectedCount =
      sum (map (length . selectedFusionCandidates) verdictGroups)
    shapes   = aggregateGateShapes verdictGroups
    gateRows =
      [ GateRow input (evaluateGate input)
      | s <- shapes
      , let input = gateInputFor gateIdx s
      ]
    counts = summarizeGate gateRows
    selectedOccurrenceCount = sum (map gsrCount shapes)

    -- Pinned. Bump intentionally when the survey corpus, planner
    -- rule set, generator coverage, or §4.B kernel coverage
    -- changes. Silent drift = the gate moved without a deliberate
    -- decision.
    --
    -- These numbers are for the smaller snapshot corpus
    -- (ssShapeRows <> ssEnsembleRows), not the wider
    -- --fusion-survey corpus that drives interactive output.
    -- Phase 7.G step 3: the widened generator accepts KAdd-only
    -- compute tails, so KAdd -> KOut and any other Add-rooted
    -- shape now gets a generated measurement. The previous
    -- unsupported KAdd -> KOut row plus one previously-no-gen
    -- needs-benchmark row both have peer measurements available
    -- and lose to them, so they reclassify as prefer-existing.
    -- Net: needs-benchmark drops by 1.
    expectedTotal          = 23
    expectedUnsupported    = 0
    expectedNeedsBenchmark = 9
    expectedCovered        = 10

-- | Phase 7.J cross-executor gate pins. Computes a gate index
-- per generated executor ('VarGenerated', 'VarGeneratedBlock',
-- 'VarGeneratedSuper'), evaluates the shared rule set against
-- the same selected-candidate aggregation 'profitabilityGateChecks'
-- uses, and pins the structural facts the slice promised the
-- snapshot would now break on.
--
-- 'expectedPreferGenerated' is pinned to the observed snapshot
-- value (one row at the time of writing). The 7.I writeup
-- claimed this would be 0; the snapshot corpus contradicts that
-- and the 7.J entry calls out the discrepancy. Pinning the
-- observed value means future drift in either direction triggers
-- a deliberate decision rather than silently moving.
--
-- Speedup payloads, win/loss splits, and per-bucket medians
-- stay unpinned per the bench-noise discipline.
gateByExecutorChecks :: [LabRow] -> SurveySnapshots -> [SnapshotCheck]
gateByExecutorChecks costRows snapshots =
  [ check "gate-by-executor sample-major prefer-generated count is stable"
      (gcPreferGenerated sampleCounts == expectedPreferGenerated)
      ("expected=" <> show expectedPreferGenerated
       <> "; actual=" <> show (gcPreferGenerated sampleCounts)
       <> samplePreferGenDetail)

  , check "gate-by-executor block-major prefer-generated count is stable"
      (gcPreferGenerated blockCounts == expectedPreferGenerated)
      ("expected=" <> show expectedPreferGenerated
       <> "; actual=" <> show (gcPreferGenerated blockCounts))

  , check "gate-by-executor super-mode prefer-generated count is stable"
      (gcPreferGenerated superCounts == expectedPreferGenerated)
      ("expected=" <> show expectedPreferGenerated
       <> "; actual=" <> show (gcPreferGenerated superCounts))

  , check "gate-by-executor non-exact = 0 across all executors"
      (gcNonExact sampleCounts == 0
        && gcNonExact blockCounts == 0
        && gcNonExact superCounts == 0)
      ("sample=" <> show (gcNonExact sampleCounts)
       <> "; block=" <> show (gcNonExact blockCounts)
       <> "; super=" <> show (gcNonExact superCounts))

  , check "gate-by-executor row totals agree across executors"
      (gcTotal sampleCounts == gcTotal blockCounts
        && gcTotal sampleCounts == gcTotal superCounts)
      ("sample=" <> show (gcTotal sampleCounts)
       <> "; block=" <> show (gcTotal blockCounts)
       <> "; super=" <> show (gcTotal superCounts))

  , check "gate-by-executor prefer-generated agrees across executors"
      (gcPreferGenerated sampleCounts == gcPreferGenerated blockCounts
        && gcPreferGenerated sampleCounts == gcPreferGenerated superCounts)
      ("sample=" <> show (gcPreferGenerated sampleCounts)
       <> "; block=" <> show (gcPreferGenerated blockCounts)
       <> "; super=" <> show (gcPreferGenerated superCounts))
  ]
  where
    allRows = ssShapeRows snapshots <> ssEnsembleRows snapshots
    verdictGroups =
      [ csPlannerVerdicts row | (_, Right row) <- allRows ]
    shapes = aggregateGateShapes verdictGroups
    countsFor v =
      let idx = costLabGateIndexFor v costRows
          gateRows =
            [ GateRow input (evaluateGate input)
            | s <- shapes
            , let input = gateInputFor idx s
            ]
      in summarizeGate gateRows
    sampleCounts = countsFor VarGenerated
    blockCounts  = countsFor VarGeneratedBlock
    superCounts  = countsFor VarGeneratedSuper

    -- Snapshot corpus produces a single non-§4.B-claimed shape
    -- whose generated speedup beats the best non-generated peer
    -- (typically Sin → Gain → Out via a candidate that lost the
    -- §4.B match for structural reasons, falling through to the
    -- generator). 7.I's "no prefer-generated row" claim was
    -- evaluated on the wider --fusion-survey corpus; this pin
    -- records what the structural snapshot actually sees.
    expectedPreferGenerated :: Int
    expectedPreferGenerated = 1

    sampleIdx = costLabGateIndexFor VarGenerated costRows
    samplePreferGenShapes =
      [ s
      | s <- shapes
      , let gi = gateInputFor sampleIdx s
      , gcPreferGenerated (summarizeGate
          [GateRow gi (evaluateGate gi)]) == 1
      ]
    samplePreferGenDetail =
      case samplePreferGenShapes of
        []  -> ""
        rs  -> "; rows=" <>
               intercalate ", "
                 [ intercalate "→" (map show (gsrKinds s))
                 | s <- rs ]

compileFailures :: [(String, Either String a)] -> [String]
compileFailures rows =
  [ label <> ": " <> err
  | (label, Left err) <- rows
  ]

compileDetail :: [String] -> String
compileDetail [] = "ok"
compileDetail xs =
  intercalate "; " (take 3 xs)
  <> if length xs > 3 then "; ..." else ""

check :: String -> Bool -> String -> SnapshotCheck
check = SnapshotCheck

printCheck :: SnapshotCheck -> IO ()
printCheck c =
  putStrLn $
    (if scPassed c then "[pass] " else "[fail] ")
    <> scLabel c
    <> " -- "
    <> scDetail c

maximumOrZero :: [Int] -> Int
maximumOrZero [] = 0
maximumOrZero xs = maximum xs
