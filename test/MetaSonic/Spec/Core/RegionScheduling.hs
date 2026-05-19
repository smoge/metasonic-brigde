{-# LANGUAGE LambdaCase #-}

-- | Tests for Phase 4.E region scheduling: per-region 'BusFootprint'
-- and 'regionDependencies' metadata (4.E.1), the pure
-- 'regionSchedule' / 'layeredRegionSchedule' planner over
-- barrier-segmented region lists (4.E.2a), the loader contract
-- that registers regions through 'scheduledRuntimeRegions' (4.E.2b),
-- and the descriptive 'regionScheduleStats' / 'templateScheduleStats'
-- counts consumed by the parallel-readiness survey (4.E.2c).
--
-- See @Note [Region dependency contract]@ in
-- "MetaSonic.Bridge.Compile" for why both bus and structural
-- precedence are part of the dependency view.
module MetaSonic.Spec.Core.RegionScheduling
  ( regionSchedulingTests
  ) where

import qualified Data.Map.Strict           as M
import qualified Data.Set                  as S
import           Data.List                 (isInfixOf)
import           Control.Exception         (try)
import           Foreign.C.Types           (CFloat (..))
import           Foreign.Marshal.Alloc     (allocaBytes)
import           Foreign.Marshal.Array     (peekArray)
import           Foreign.Ptr               (castPtr)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI      (c_rt_graph_process,
                                            c_rt_graph_read_bus,
                                            loadRuntimeGraph,
                                            withRTGraph)
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Types

import           MetaSonic.Spec.CoreShared (PtrCFloat)

regionSchedulingTests :: TestTree
regionSchedulingTests = testGroup "Phase 4.E: region scheduling"
  [ regionFootprintAndDepsTests
  , regionSchedulePlannerTests
  , regionScheduleLoadersTests
  , regionScheduleStatsTests
  ]

------------------------------------------------------------
-- §4.E.1: per-region BusFootprint and dependencies
------------------------------------------------------------

regionFootprintAndDepsTests :: TestTree
regionFootprintAndDepsTests =
  -- Phase 4.E.1 + 4.E.1b: per-region BusFootprint metadata plus
  -- the dependency views consumed by future scheduling work.
  -- 'regionBusPrecedence' is the bus-only edge subgraph;
  -- 'regionStructuralPrecedence' is the cross-region port edges
  -- introduced by 'selectRegionKernels' splits;
  -- 'regionDependencies' is the union — the actual "must
  -- precede" relation. No runtime behavior change in either
  -- slice — 'compileRuntimeGraph' still produces regions in the
  -- same topologically valid order; the tests pin the metadata
  -- only.
  testGroup "Phase 4.E.1: per-region BusFootprint and dependencies"
    [ testCase "single-region chain: footprint writes {0}, no reads, empty deps" $ do
        let g = runSynth $ do
              s <- sinOsc 440.0 0.0
              a <- gain s (Param 0.5)
              out 0 a
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> do
            case rgRuntimeRegions rg of
              [r] -> do
                bfWrites       (rfBuses (rrFootprint r)) @?= S.singleton 0
                bfReads        (rfBuses (rrFootprint r)) @?= S.empty
                bfDelayedReads (rfBuses (rrFootprint r)) @?= S.empty
                regionDependencies rg @?=
                  M.singleton (rrIndex r) S.empty
              rs -> assertFailure $
                "expected exactly one region, got " <> show (length rs)

    , testCase "internal send/return: consumer region depends on producer (bus edge)" $ do
        let g = runSynth $ do
              s <- sinOsc 220.0 0.0
              busOut 5 s
              r <- busIn 5
              f <- lpf r (Param 800.0) (Param 4.0)
              a <- gain f (Param 0.5)
              out 0 a
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> do
            let producers = [r | r <- rgRuntimeRegions rg
                               , rrKernel r == RNodeLoop]
                consumers = [r | r <- rgRuntimeRegions rg
                               , rrKernel r == RBusInLpfGainOut]
            case (producers, consumers) of
              ([p], [c]) -> do
                bfWrites       (rfBuses (rrFootprint p)) @?= S.singleton 5
                bfReads        (rfBuses (rrFootprint p)) @?= S.empty
                bfWrites       (rfBuses (rrFootprint c)) @?= S.singleton 0
                bfReads        (rfBuses (rrFootprint c)) @?= S.singleton 5
                bfDelayedReads (rfBuses (rrFootprint c)) @?= S.empty

                let busPrec = regionBusPrecedence rg
                    structPrec = regionStructuralPrecedence rg
                    deps = regionDependencies rg
                M.findWithDefault S.empty (rrIndex c) busPrec
                  @?= S.singleton (rrIndex p)
                M.findWithDefault S.empty (rrIndex c) structPrec
                  @?= S.empty
                M.findWithDefault S.empty (rrIndex c) deps
                  @?= S.singleton (rrIndex p)
                M.findWithDefault S.empty (rrIndex p) deps
                  @?= S.empty
              _ -> assertFailure $
                "expected one RNodeLoop producer + one RBusInLpfGainOut "
                <> "consumer, got "
                <> show (length producers) <> " + "
                <> show (length consumers)

    , testCase "kernel-split chain: structural port edge across region boundary" $ do
        let g = runSynth $ do
              s <- sawOsc 110.0 0.0
              f <- lpf s (Param 800.0) (Param 4.0)
              a <- gain f (Param 0.4)
              b <- add a (Param 0.0)
              out 0 b
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> do
            let regions = rgRuntimeRegions rg
                bufs    = [r | r <- regions, rrKernel r == RSawLpfGain]
                tails   = [r | r <- regions, rrKernel r == RNodeLoop]
            case (bufs, tails) of
              ([buf], [tail_]) -> do
                bfWrites       (rfBuses (rrFootprint buf))   @?= S.empty
                bfReads        (rfBuses (rrFootprint buf))   @?= S.empty
                bfWrites       (rfBuses (rrFootprint tail_)) @?= S.singleton 0
                bfReads        (rfBuses (rrFootprint tail_)) @?= S.empty

                let busPrec = regionBusPrecedence rg
                M.findWithDefault S.empty (rrIndex tail_) busPrec
                  @?= S.empty

                let structPrec = regionStructuralPrecedence rg
                M.findWithDefault S.empty (rrIndex tail_) structPrec
                  @?= S.singleton (rrIndex buf)

                let deps = regionDependencies rg
                M.findWithDefault S.empty (rrIndex tail_) deps
                  @?= S.singleton (rrIndex buf)
                M.findWithDefault S.empty (rrIndex buf) deps
                  @?= S.empty
              _ -> assertFailure $
                "expected one RSawLpfGain region + one RNodeLoop tail, got "
                <> show (length bufs) <> " + " <> show (length tails)

    , testCase "BusInDelayed reader does not induce a dependency edge" $ do
        let g = runSynth $ do
              s1 <- sinOsc 220.0 0.0
              g1 <- gain s1 (Param 0.3)
              busOut 5 g1
              d  <- busInDelayed 5
              g2 <- gain d (Param 0.4)
              out 0 g2
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> do
            let regions   = rgRuntimeRegions rg
                producers = [r | r <- regions, rrKernel r == RSinGainOut]
                readers   = [r | r <- regions, rrKernel r == RNodeLoop]
            case (producers, readers) of
              ([p], [r]) -> do
                bfWrites       (rfBuses (rrFootprint p)) @?= S.singleton 5
                bfReads        (rfBuses (rrFootprint p)) @?= S.empty
                bfDelayedReads (rfBuses (rrFootprint p)) @?= S.empty

                bfWrites       (rfBuses (rrFootprint r)) @?= S.singleton 0
                bfReads        (rfBuses (rrFootprint r)) @?= S.empty
                bfDelayedReads (rfBuses (rrFootprint r)) @?= S.singleton 5

                let busPrec    = regionBusPrecedence rg
                    structPrec = regionStructuralPrecedence rg
                    deps       = regionDependencies rg
                M.findWithDefault S.empty (rrIndex r) busPrec    @?= S.empty
                M.findWithDefault S.empty (rrIndex r) structPrec @?= S.empty
                M.findWithDefault S.empty (rrIndex r) deps       @?= S.empty
                M.findWithDefault S.empty (rrIndex p) deps       @?= S.empty
              _ -> assertFailure $
                "expected one RSinGainOut producer + one RNodeLoop "
                <> "reader, got "
                <> show (length producers) <> " + "
                <> show (length readers)

    , testCase "independent regions have disjoint footprints + no deps" $ do
        let g = runSynth $ do
              s1 <- sinOsc 220.0 0.0
              a1 <- gain s1 (Param 0.4)
              out 0 a1
              s2 <- sinOsc 440.0 0.0
              a2 <- gain s2 (Param 0.4)
              out 1 a2
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> do
            let regions = rgRuntimeRegions rg
            length [r | r <- regions, rrKernel r == RSinGainOut] @?= 2
            let writes = [bfWrites (rfBuses (rrFootprint r)) | r <- regions]
            S.unions writes @?= S.fromList [0, 1]
            let deps = regionDependencies rg
            all (S.null . snd) (M.toList deps) @?= True

    , testCase "multi-template send/return: per-region footprints survive compileTemplateGraph" $ do
        let voice = runSynth $ do
              s <- sinOsc 220.0 0.0
              a <- gain s (Param 0.4)
              busOut 5 a
            fx = runSynth $ do
              r <- busIn 5
              f <- lpf r (Param 800.0) (Param 4.0)
              a <- gain f (Param 0.6)
              out 0 a

        tg <- case compileTemplateGraph
                     [("voice", voice), ("fx", fx)] of
          Right t  -> pure t
          Left err -> assertFailure err >> error "unreachable"

        let voiceTpl = head [t | t <- tgTemplates tg, tplName t == "voice"]
            fxTpl    = head [t | t <- tgTemplates tg, tplName t == "fx"]
            voiceRg  = tplGraph voiceTpl
            fxRg     = tplGraph fxTpl

        case rgRuntimeRegions voiceRg of
          [r] -> do
            rrKernel r @?= RSinGainOut
            bfWrites (rfBuses (rrFootprint r)) @?= S.singleton 5
            bfReads  (rfBuses (rrFootprint r)) @?= S.empty
            regionDependencies voiceRg
              @?= M.singleton (rrIndex r) S.empty
          rs -> assertFailure $
            "voice template: expected one region, got "
            <> show (length rs)

        case rgRuntimeRegions fxRg of
          [r] -> do
            rrKernel r @?= RBusInLpfGainOut
            bfWrites (rfBuses (rrFootprint r)) @?= S.singleton 0
            bfReads  (rfBuses (rrFootprint r)) @?= S.singleton 5
            regionDependencies fxRg
              @?= M.singleton (rrIndex r) S.empty
          rs -> assertFailure $
            "fx template: expected one region, got "
            <> show (length rs)

    , testCase "isLiveBusKind: exhaustively {KBusIn, KOut, KBusOut}; everything else no" $ do
        let live = [k | k <- [minBound .. maxBound :: NodeKind]
                      , isLiveBusKind k]
        live @?= [KOut, KBusOut, KBusIn]

    , testCase "regionHasLiveBus: chain with KOut is a barrier" $ do
        let g = runSynth $ do
              s <- sinOsc 440.0 0.0
              a <- gain s (Param 0.5)
              out 0 a
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> do
            case rgRuntimeRegions rg of
              [r] -> regionHasLiveBus rg r @?= True
              rs -> assertFailure $
                "expected exactly one region, got " <> show (length rs)

    , testCase "regionHasLiveBus: kernel-split — buffer region not a barrier, sink region is" $ do
        let g = runSynth $ do
              s <- sawOsc 110.0 0.0
              f <- lpf s (Param 800.0) (Param 4.0)
              a <- gain f (Param 0.4)
              b <- add a (Param 0.0)
              out 0 b
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> do
            let regions = rgRuntimeRegions rg
                bufs    = [r | r <- regions, rrKernel r == RSawLpfGain]
                tails   = [r | r <- regions, rrKernel r == RNodeLoop]
            case (bufs, tails) of
              ([buf], [tail_]) -> do
                regionHasLiveBus rg buf   @?= False
                regionHasLiveBus rg tail_ @?= True
              _ -> assertFailure $
                "expected one RSawLpfGain region + one RNodeLoop "
                <> "tail, got " <> show (length bufs)
                <> " + " <> show (length tails)

    , testCase "regionHasLiveBus: send/return — both regions are barriers" $ do
        let g = runSynth $ do
              s <- sinOsc 220.0 0.0
              busOut 5 s
              r <- busIn 5
              f <- lpf r (Param 800.0) (Param 4.0)
              a <- gain f (Param 0.5)
              out 0 a
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> do
            let regions = rgRuntimeRegions rg
            all (regionHasLiveBus rg) regions @?= True
    ]

------------------------------------------------------------
-- §4.E.2a: regionSchedule planner
------------------------------------------------------------

regionSchedulePlannerTests :: TestTree
regionSchedulePlannerTests =
  -- Phase 4.E.2a: pure single-thread region scheduler planner.
  -- 'regionSchedule' encodes the contract a future scheduler
  -- consumes — barrier regions (live-bus) execute in
  -- compile-decreed 'rrIndex' order; non-barrier regions are
  -- topologically scheduled within each barrier-delimited
  -- segment using 'regionDependencies' with 'rrIndex' as the
  -- stable tie-breaker. No runtime change in this slice.
  testGroup "Phase 4.E.2a: regionSchedule planner"
    [ testCase "single-region chain: schedule is [0]" $ do
        let g = runSynth $ do
              s <- sinOsc 440.0 0.0
              a <- gain s (Param 0.5)
              out 0 a
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> regionSchedule rg @?= Right [RegionIndex 0]

    , testCase "send/return barriers: both regions barriers, schedule = rrIndex order" $ do
        let g = runSynth $ do
              s <- sinOsc 220.0 0.0
              busOut 5 s
              r <- busIn 5
              f <- lpf r (Param 800.0) (Param 4.0)
              a <- gain f (Param 0.5)
              out 0 a
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> do
            let regions  = rgRuntimeRegions rg
                segments = segmentByBarrier rg
            all (regionHasLiveBus rg) regions @?= True
            length segments @?= 2
            let isBarrier seg = case seg of
                  Barrier _ -> True
                  _         -> False
            all isBarrier segments @?= True
            regionSchedule rg @?= Right (map rrIndex regions)

    , testCase "kernel-split: free buffer region precedes barrier tail" $ do
        let g = runSynth $ do
              s <- sawOsc 110.0 0.0
              f <- lpf s (Param 800.0) (Param 4.0)
              a <- gain f (Param 0.4)
              b <- add a (Param 0.0)
              out 0 b
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> do
            let regions = rgRuntimeRegions rg
                bufs    = [r | r <- regions, rrKernel r == RSawLpfGain]
                tails   = [r | r <- regions, rrKernel r == RNodeLoop]
            case (bufs, tails) of
              ([buf], [tail_]) -> do
                regionHasLiveBus rg buf   @?= False
                regionHasLiveBus rg tail_ @?= True
                segmentByBarrier rg @?= [ FreeSegment [buf]
                                        , Barrier tail_
                                        ]
                regionSchedule rg @?= Right [rrIndex buf, rrIndex tail_]
              _ -> assertFailure $
                "expected one RSawLpfGain region + one RNodeLoop "
                <> "tail, got " <> show (length bufs)
                <> " + " <> show (length tails)

    , testCase "BusInDelayed: schedule is rrIndex order, both barriers" $ do
        let g = runSynth $ do
              s1 <- sinOsc 220.0 0.0
              g1 <- gain s1 (Param 0.3)
              busOut 5 g1
              d  <- busInDelayed 5
              g2 <- gain d (Param 0.4)
              out 0 g2
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> do
            let regions = rgRuntimeRegions rg
            all (regionHasLiveBus rg) regions @?= True
            regionSchedule rg @?= Right (map rrIndex regions)

    , testCase "independent free regions: stable rrIndex order in single segment" $ do
        let g = runSynth $ do
              s1 <- sawOsc 110.0 0.0
              f1 <- lpf s1 (Param 800.0)  (Param 4.0)
              g1 <- gain f1 (Param 0.4)
              s2 <- sawOsc 220.0 0.0
              f2 <- lpf s2 (Param 1200.0) (Param 4.0)
              g2 <- gain f2 (Param 0.4)
              summed <- add g1 g2
              out 0 summed
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> do
            let regions = rgRuntimeRegions rg
                buffers = [r | r <- regions, rrKernel r == RSawLpfGain]
                tails   = [r | r <- regions, rrKernel r == RNodeLoop]
            case (buffers, tails) of
              ([b1, b2], [tail_]) -> do
                regionHasLiveBus rg b1    @?= False
                regionHasLiveBus rg b2    @?= False
                regionHasLiveBus rg tail_ @?= True
                segmentByBarrier rg
                  @?= [ FreeSegment [b1, b2], Barrier tail_ ]
                regionSchedule rg
                  @?= Right [ rrIndex b1, rrIndex b2, rrIndex tail_ ]
              _ -> assertFailure $
                "expected two RSawLpfGain regions + one RNodeLoop "
                <> "tail, got "
                <> show (length buffers) <> " + "
                <> show (length tails)

    , testCase "multi-template: per-template schedule = [0] for each one-region template" $ do
        let voice = runSynth $ do
              s <- sinOsc 220.0 0.0
              a <- gain s (Param 0.4)
              busOut 5 a
            fx = runSynth $ do
              r <- busIn 5
              f <- lpf r (Param 800.0) (Param 4.0)
              a <- gain f (Param 0.6)
              out 0 a

        tg <- case compileTemplateGraph
                     [("voice", voice), ("fx", fx)] of
          Right t  -> pure t
          Left err -> assertFailure err >> error "unreachable"

        let voiceTpl = head [t | t <- tgTemplates tg, tplName t == "voice"]
            fxTpl    = head [t | t <- tgTemplates tg, tplName t == "fx"]

        regionSchedule (tplGraph voiceTpl) @?= Right [RegionIndex 0]
        regionSchedule (tplGraph fxTpl)    @?= Right [RegionIndex 0]

    , testCase "rejects non-ascending rgRuntimeRegions order" $ do
        let g = runSynth $ do
              s <- sawOsc 110.0 0.0
              f <- lpf s (Param 800.0) (Param 4.0)
              a <- gain f (Param 0.4)
              b <- add a (Param 0.0)
              out 0 b
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> do
            let bad = rg { rgRuntimeRegions =
                             reverse (rgRuntimeRegions rg) }
            case regionSchedule bad of
              Left msg ->
                assertBool
                  ("expected mention of dense ascending in: "
                   <> msg)
                  ("dense" `isInfixOf` msg)
              Right ixs ->
                assertFailure $
                  "regionSchedule should have rejected the "
                  <> "reversed graph; got " <> show ixs

    , testCase "rejects duplicate rrIndex in rgRuntimeRegions" $ do
        let g = runSynth $ do
              s <- sinOsc 440.0 0.0
              a <- gain s (Param 0.5)
              out 0 a
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> case rgRuntimeRegions rg of
            [r] -> do
              let bad = rg { rgRuntimeRegions = [r, r] }
              case regionSchedule bad of
                Left msg ->
                  assertBool
                    ("expected dense-ascending diagnostic in: "
                     <> msg)
                    ("dense" `isInfixOf` msg)
                Right ixs ->
                  assertFailure $
                    "regionSchedule should have rejected the "
                    <> "duplicate-index graph; got " <> show ixs
            rs -> assertFailure $
              "expected a single region, got "
              <> show (length rs)
    ]

------------------------------------------------------------
-- §4.E.2b: loaders consume scheduledRuntimeRegions
------------------------------------------------------------

regionScheduleLoadersTests :: TestTree
regionScheduleLoadersTests =
  -- Phase 4.E.2b: loaders register regions through the schedule.
  testGroup "Phase 4.E.2b: loaders consume scheduledRuntimeRegions"
    [ testCase "loadRuntimeGraph: scheduled order = rgRuntimeRegions" $ do
        let g = runSynth $ do
              s <- sawOsc 110.0 0.0
              f <- lpf s (Param 800.0) (Param 4.0)
              a <- gain f (Param 0.4)
              b <- add a (Param 0.0)
              out 0 b
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> case scheduledRuntimeRegions rg of
            Left err -> assertFailure $
              "scheduledRuntimeRegions failed: " <> err
            Right scheduled ->
              map rrIndex scheduled @?= map rrIndex (rgRuntimeRegions rg)

    , testCase "loadRuntimeGraphFused: scheduled order = rgRuntimeRegions" $ do
        let g = runSynth $ do
              s <- sinOsc 440.0 0.0
              a <- gain s (Param 0.5)
              b <- add a (Param 0.0)
              out 0 b
        case lowerGraph g >>= compileRuntimeGraphFused of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> case scheduledRuntimeRegions rg of
            Left err -> assertFailure $
              "scheduledRuntimeRegions failed: " <> err
            Right scheduled ->
              map rrIndex scheduled @?= map rrIndex (rgRuntimeRegions rg)

    , testCase "loadTemplateGraph: per-template scheduled order = rgRuntimeRegions" $ do
        let voice = runSynth $ do
              s <- sinOsc 220.0 0.0
              a <- gain s (Param 0.4)
              busOut 5 a
            fx = runSynth $ do
              r <- busIn 5
              f <- lpf r (Param 800.0) (Param 4.0)
              a <- gain f (Param 0.6)
              out 0 a
        case compileTemplateGraph [("voice", voice), ("fx", fx)] of
          Left err -> assertFailure err
          Right tg ->
            mapM_ (\tpl ->
              case scheduledRuntimeRegions (tplGraph tpl) of
                Left err -> assertFailure $
                  "template " <> show (tplName tpl)
                  <> ": scheduledRuntimeRegions failed: " <> err
                Right scheduled ->
                  map rrIndex scheduled @?=
                    map rrIndex (rgRuntimeRegions (tplGraph tpl)))
              (tgTemplates tg)

    , testCase "loadTemplateGraphFused: per-template scheduled order = rgRuntimeRegions" $ do
        let voice = runSynth $ do
              s <- sinOsc 220.0 0.0
              a <- gain s (Param 0.4)
              busOut 5 a
            fx = runSynth $ do
              r <- busIn 5
              f <- lpf r (Param 800.0) (Param 4.0)
              a <- gain f (Param 0.6)
              b <- add a (Param 0.0)
              out 0 b
        case compileTemplateGraphFused
                [("voice", voice), ("fx", fx)] of
          Left err -> assertFailure err
          Right tg ->
            mapM_ (\tpl ->
              case scheduledRuntimeRegions (tplGraph tpl) of
                Left err -> assertFailure $
                  "template " <> show (tplName tpl)
                  <> ": scheduledRuntimeRegions failed: " <> err
                Right scheduled ->
                  map rrIndex scheduled @?=
                    map rrIndex (rgRuntimeRegions (tplGraph tpl)))
              (tgTemplates tg)

    , testCase "loadRuntimeGraph: failed schedule preserves previous graph" $ do
        let nframes, sizeOfFloat :: Int
            nframes     = 256
            sizeOfFloat = 4
            good = runSynth $ do
              s <- sawOsc 110.0 0.0
              f <- lpf s (Param 800.0) (Param 4.0)
              a <- gain f (Param 0.4)
              b <- add a (Param 0.0)
              out 0 b
        rt <- case lowerGraph good >>= compileRuntimeGraph of
          Right r  -> pure r
          Left err -> assertFailure err >> error "unreachable"
        assertBool
          "expected good graph to have at least two regions"
          (length (rgRuntimeRegions rt) >= 2)
        let bad = rt { rgRuntimeRegions =
                         reverse (rgRuntimeRegions rt) }
        withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
          loadRuntimeGraph handle rt
          c_rt_graph_process handle (fromIntegral nframes)
          before <-
            allocaBytes (nframes * sizeOfFloat) $ \buf -> do
              _ <- c_rt_graph_read_bus handle 0
                     (fromIntegral nframes) (castPtr buf)
              cs <- peekArray nframes (buf :: PtrCFloat)
              pure (map (\(CFloat x) -> x) cs)

          let attempt :: IO (Either IOError ())
              attempt = try $ loadRuntimeGraph handle bad
          result <- attempt
          case result of
            Right () ->
              assertFailure $
                "loadRuntimeGraph should have rejected the "
                <> "malformed graph"
            Left e ->
              assertBool
                ("expected dense-ordering diagnostic in: "
                 <> show e)
                ("dense" `isInfixOf` show e)

          c_rt_graph_process handle (fromIntegral nframes)
          after <-
            allocaBytes (nframes * sizeOfFloat) $ \buf -> do
              _ <- c_rt_graph_read_bus handle 0
                     (fromIntegral nframes) (castPtr buf)
              cs <- peekArray nframes (buf :: PtrCFloat)
              pure (map (\(CFloat x) -> x) cs)

          let peakBefore = maximum (map abs before)
              peakAfter  = maximum (map abs after)
          assertBool ("peak before > 0, got " <> show peakBefore)
                     (peakBefore > 0.05)
          assertBool ("peak after > 0, got " <> show peakAfter)
                     (peakAfter > 0.05)
          assertBool
            ("peaks should be in same ballpark; before="
             <> show peakBefore <> " after=" <> show peakAfter)
            (abs (peakBefore - peakAfter) < 0.5 * peakBefore)
    ]

------------------------------------------------------------
-- §4.E.2c: regionScheduleStats descriptive counts
------------------------------------------------------------

regionScheduleStatsTests :: TestTree
regionScheduleStatsTests =
  -- Phase 4.E.2c (parallel-readiness survey): descriptive
  -- 'regionScheduleStats' counts.
  testGroup "Phase 4.E.2c: regionScheduleStats descriptive counts"
    [ testCase "single-region (sin -> out): 1 barrier, 0 free, max widths 0" $ do
        let g = runSynth $ do
              s <- sinOsc 440.0 0.0
              a <- gain s (Param 0.5)
              out 0 a
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> case regionScheduleStats rg of
            Left err -> assertFailure $ "stats failed: " <> err
            Right s ->
              s @?= RegionScheduleStats
                { rssTotal               = 1
                , rssBarriers            = 1
                , rssFree                = 0
                , rssFreeSegments        = 0
                , rssMaxFreeSegmentWidth = 0
                , rssMaxFreeLayerWidth   = 0
                , rssSharedWriteHazards  = 0
                , rssMaxRunnableLayerWidth
                                         = 0
                , rssMaxReductionLayerWidth
                                         = 0
                }

    , testCase "saw -> lpf -> gain -> add -> out: 1 free + 1 barrier, max widths 1" $ do
        let g = runSynth $ do
              s <- sawOsc 110.0 0.0
              f <- lpf s (Param 800.0) (Param 4.0)
              a <- gain f (Param 0.4)
              b <- add a (Param 0.0)
              out 0 b
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> case regionScheduleStats rg of
            Left err -> assertFailure $ "stats failed: " <> err
            Right s ->
              s @?= RegionScheduleStats
                { rssTotal               = 2
                , rssBarriers            = 1
                , rssFree                = 1
                , rssFreeSegments        = 1
                , rssMaxFreeSegmentWidth = 1
                , rssMaxFreeLayerWidth   = 1
                , rssSharedWriteHazards  = 0
                , rssMaxRunnableLayerWidth
                                         = 1
                , rssMaxReductionLayerWidth
                                         = 0
                }

    , testCase "two independent buffers + shared tail: free width 2 at layer 0" $ do
        let g = runSynth $ do
              s1 <- sawOsc 110.0 0.0
              f1 <- lpf s1 (Param 800.0)  (Param 4.0)
              g1 <- gain f1 (Param 0.4)
              s2 <- sawOsc 220.0 0.0
              f2 <- lpf s2 (Param 1200.0) (Param 4.0)
              g2 <- gain f2 (Param 0.4)
              summed <- add g1 g2
              out 0 summed
        case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure $ "compile failed: " <> err
          Right rg -> do
            case regionScheduleStats rg of
              Left err -> assertFailure $ "stats failed: " <> err
              Right s ->
                s @?= RegionScheduleStats
                  { rssTotal               = 3
                  , rssBarriers            = 1
                  , rssFree                = 2
                  , rssFreeSegments        = 1
                  , rssMaxFreeSegmentWidth = 2
                  , rssMaxFreeLayerWidth   = 2
                  , rssSharedWriteHazards  = 0
                  , rssMaxRunnableLayerWidth
                                           = 2
                  , rssMaxReductionLayerWidth
                                           = 0
                  }
            layeredRegionSchedule rg @?=
              Right
                [ ScheduleFreeLayer FreeLayer
                    { flRegions = [RegionIndex 0, RegionIndex 1]
                    , flSharedWriteHazards = []
                    }
                , ScheduleBarrier (RegionIndex 2)
                ]

    , testCase "addScheduleStats: counts add, widths max" $ do
        let a = RegionScheduleStats 3 1 2 1 2 2 0 2 0
            b = RegionScheduleStats 5 4 1 1 1 1 1 1 1
        addScheduleStats emptyScheduleStats a @?= a
        addScheduleStats a emptyScheduleStats @?= a
        addScheduleStats a b @?=
          RegionScheduleStats
            { rssTotal               = 8
            , rssBarriers            = 5
            , rssFree                = 3
            , rssFreeSegments        = 2
            , rssMaxFreeSegmentWidth = 2
            , rssMaxFreeLayerWidth   = 2
            , rssSharedWriteHazards  = 1
            , rssMaxRunnableLayerWidth
                                     = 2
            , rssMaxReductionLayerWidth
                                     = 1
            }

    , testCase "templateScheduleStats: chain ensemble has layer width 1" $ do
        let voice = runSynth $ do
              s <- sinOsc 220.0 0.0
              a <- gain s (Param 0.4)
              busOut 5 a
            fx = runSynth $ do
              r <- busIn 5
              f <- lpf r (Param 800.0) (Param 4.0)
              a <- gain f (Param 0.6)
              out 0 a
        case compileTemplateGraph [("voice", voice), ("fx", fx)] of
          Left err -> assertFailure err
          Right tg -> case templateScheduleStats tg of
            Left err -> assertFailure $ "stats failed: " <> err
            Right s -> do
              tssTemplateCount         s @?= 2
              tssMaxTemplateLayerWidth s @?= 1
              tssSharedWriteHazards    s @?= 0
              tssMaxTemplateRunnableWidth s @?= 1
              tssMaxTemplateReductionWidth s @?= 0
              rssTotal    (tssAggregate s) @?= 2
              rssBarriers (tssAggregate s) @?= 2

    , testCase "templateScheduleStats: disjoint writers are runnable width 2" $ do
        let left = runSynth $ do
              s <- sawOsc 110.0 0.0
              a <- gain s (Param 0.3)
              out 0 a
            right = runSynth $ do
              s <- sawOsc 220.0 0.0
              a <- gain s (Param 0.3)
              out 1 a
        case compileTemplateGraph [("left", left), ("right", right)] of
          Left err -> assertFailure err
          Right tg -> case templateScheduleStats tg of
            Left err -> assertFailure $ "stats failed: " <> err
            Right s -> do
              tssTemplateCount              s @?= 2
              tssMaxTemplateLayerWidth      s @?= 2
              tssSharedWriteHazards         s @?= 0
              tssMaxTemplateRunnableWidth   s @?= 2
              tssMaxTemplateReductionWidth  s @?= 0

    , testCase "templateScheduleStats: two voices + one fx → layer width 2" $ do
        let voiceL = runSynth $ do
              s <- sawOsc 110.0 0.0
              a <- gain s (Param 0.3)
              busOut 7 a
            voiceR = runSynth $ do
              s <- sawOsc 220.0 0.0
              a <- gain s (Param 0.3)
              busOut 7 a
            fx = runSynth $ do
              r <- busIn 7
              f <- lpf r (Param 1200.0) (Param 0.7)
              a <- gain f (Param 0.6)
              out 0 a
        case compileTemplateGraph
                [ ("voice-l", voiceL)
                , ("voice-r", voiceR)
                , ("fx",      fx)
                ] of
          Left err -> assertFailure err
          Right tg -> case templateScheduleStats tg of
            Left err -> assertFailure $ "stats failed: " <> err
            Right s -> do
              tssTemplateCount              s @?= 3
              tssMaxTemplateLayerWidth      s @?= 2
              tssSharedWriteHazards         s @?= 1
              tssMaxTemplateRunnableWidth   s @?= 1
              tssMaxTemplateReductionWidth  s @?= 2
    ]
