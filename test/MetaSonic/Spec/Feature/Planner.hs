-- | Phase 7.C: survey-only fusion planner tests.
--
-- Each case constructs a small 'SynthGraph' that lands a node at the
-- true-interior position, runs the planner, and asserts the expected
-- 'Verdict' shape: the §4.B-matched 3-node candidate is accepted,
-- coalesced suffixes pin the selected set, and each rejection rule
-- (latency, hard barrier, stateful interior, resource mid-chain,
-- non-adjacent dataflow, fanout escape) fires on its own minimal
-- graph.
module MetaSonic.Spec.Feature.Planner
  ( plannerTests
  ) where

import           Data.Maybe                (isJust)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile  (compileRuntimeGraph)
import           MetaSonic.Bridge.IR       (lowerGraph)
import           MetaSonic.Bridge.Planner
import           MetaSonic.Bridge.Source

plannerTests :: TestTree
plannerTests =
  testGroup "Phase 7.C: survey-only fusion planner"
  [ testCase "Sin→Gain→Out yields an accepted candidate matched to a §4.B kernel" $ do
      let g = runSynth $ do
            o <- sinOsc 440 0
            y <- gain o 0.5
            out 0 y
          verdicts = runPlanner g
          matched =
            [ k
            | Accepted c <- verdicts
            , Just k <- [fcMatchedShape c]
            , fcLengthNodes c == 3
            ]
      assertBool
        ("expected an Accepted 3-node candidate matched to a §4.B kernel; got "
         <> show verdicts)
        (not (null matched))

  , testCase "selected candidates coalesce nested accepted suffixes" $ do
      let g = runSynth $ do
            o <- sinOsc 440 0
            y <- gain o 0.5
            out 0 y
          verdicts = runPlanner g
          selected = selectedFusionCandidates verdicts
      [fcLengthNodes c | c <- selected] @?= [3]
      assertBool
        ("expected selected candidate to keep the §4.B match; got "
         <> show selected)
        (any (isJust . fcMatchedShape) selected)

  , testCase "spectralFreeze as true-interior triggers ReasonLatencyMidChain" $ do
      let g = runSynth $ do
            o <- sinOsc 440 0
            f <- spectralFreeze o 0
            y <- gain f 0.5
            out 0 y
          verdicts = runPlanner g
          rejections = [r | Rejected _ r <- verdicts]
      assertBool
        ("expected ReasonLatencyMidChain in rejections; got " <> show rejections)
        (any isLatencyMid rejections)

  , testCase "staticPlugin as true-interior triggers ReasonHardBarrier" $ do
      let g = runSynth $ do
            a <- sinOsc 440 0
            b <- sinOsc 220 0
            p <- staticPlugin identityPlugin a b
            y <- gain p 0.5
            out 0 y
          verdicts = runPlanner g
          rejections = [r | Rejected _ r <- verdicts]
      assertBool
        ("expected ReasonHardBarrier in rejections; got " <> show rejections)
        (any isHardBarrier rejections)

  , testCase "stateful non-allow-list kind (Env) as true-interior is rejected" $ do
      -- Two oscillators feed the chain so the first SinOsc is the
      -- source and the second SinOsc lands at true-interior; the
      -- planner should cite that mid-chain osc, not the source.
      let g = runSynth $ do
            o1 <- sinOsc 440 0
            o2 <- sinOsc 220 0
            y  <- add o1 o2
            z  <- gain y 0.5
            out 0 z
          verdicts = runPlanner g
          rejections = [r | Rejected _ r <- verdicts]
      assertBool
        ("expected ReasonStatefulInterior in rejections; got "
         <> show rejections)
        (any isStatefulInterior rejections)

  , testCase "BusOut as true-interior triggers ReasonResourceMidChain" $ do
      let g = runSynth $ do
            o1 <- triOsc 440 0
            y1 <- gain o1 0.5
            busOut 5 y1
            o2 <- sinOsc 220 0
            out 0 o2
          verdicts = runPlanner g
          rejections = [r | Rejected _ r <- verdicts]
      assertBool
        ("expected ReasonResourceMidChain in rejections; got "
         <> show rejections)
        (any isResourceMid rejections)

  , testCase "contiguous but disconnected members trigger ReasonNonAdjacentDataflow" $ do
      let g = runSynth $ do
            o1 <- sinOsc 440 0
            o2 <- sinOsc 220 0
            y1 <- gain o1 0.5
            y2 <- gain o2 0.25
            out 0 y2
            _  <- gain y1 0.9
            pure ()
          verdicts = runPlanner g
          rejections = [r | Rejected _ r <- verdicts]
      assertBool
        ("expected ReasonNonAdjacentDataflow in rejections; got "
         <> show rejections)
        (any isNonAdjacent rejections)

  , testCase "fanout producer triggers ReasonFanoutEscape" $ do
      -- Same osc feeds two output chains. The osc has
      -- consumerCount=2 and shows up as a non-sink position with
      -- fanout. (The osc is also source-stateful, but the rule
      -- order checks HardBarrier/Latency/Resource/Stateful/Fanout
      -- and the source is exempt from the Stateful check, so
      -- Fanout fires.)
      let g = runSynth $ do
            o  <- sinOsc 440 0
            y1 <- gain o 0.5
            y2 <- gain o 0.3
            out 0 y1
            out 1 y2
          verdicts = runPlanner g
          rejections = [r | Rejected _ r <- verdicts]
      assertBool
        ("expected ReasonFanoutEscape in rejections; got "
         <> show rejections)
        (any isFanoutEscape rejections)
  ]
  where
    runPlanner :: SynthGraph -> [Verdict]
    runPlanner g = case lowerGraph g >>= compileRuntimeGraph of
      Right rg -> planRuntimeGraph rg
      Left err -> error ("expected compile success, got: " <> err)

    isLatencyMid ReasonLatencyMidChain{} = True
    isLatencyMid _                       = False

    isHardBarrier ReasonHardBarrier{}   = True
    isHardBarrier _                     = False

    isStatefulInterior ReasonStatefulInterior{} = True
    isStatefulInterior _                        = False

    isResourceMid ReasonResourceMidChain{} = True
    isResourceMid _                        = False

    isNonAdjacent ReasonNonAdjacentDataflow{} = True
    isNonAdjacent _                           = False

    isFanoutEscape ReasonFanoutEscape{} = True
    isFanoutEscape _                    = False

