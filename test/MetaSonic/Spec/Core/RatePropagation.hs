-- | Tests for rate inference and propagation: 'inferRate' returns
-- each kind's *floor*; the post-lowering pass 'propagateRates' lifts
-- a node's rate to the join of its inputs and that floor. These
-- tests pin the matrix of floor × input-rate combinations (stateful
-- kinds stay at 'SampleRate'; stateless transforms inherit;
-- pure-Param subgraphs collapse to 'CompileRate'), plus the
-- region-rate absorption rule whereby a 'CompileRate' helper folds
-- into an adjacent 'SampleRate' region.
--
-- See @Note [Rate inference vs rate propagation]@ in
-- "MetaSonic.Bridge.IR" and @Note [Region rate compatibility]@ in
-- "MetaSonic.Bridge.Compile".
module MetaSonic.Spec.Core.RatePropagation
  ( ratePropagationTests
  ) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Types

import           MetaSonic.Spec.CoreShared

ratePropagationTests :: TestTree
ratePropagationTests =
  testGroup "Rate propagation"
    [ testCase "kind floors: producers SampleRate, transforms CompileRate" $ do
        ksRate (kindSpec KSinOsc)        @?= SampleRate
        ksRate (kindSpec KSawOsc)        @?= SampleRate
        ksRate (kindSpec KNoiseGen)      @?= SampleRate
        ksRate (kindSpec KLPF)           @?= SampleRate
        ksRate (kindSpec KEnv)           @?= SampleRate
        ksRate (kindSpec KBusIn)         @?= SampleRate
        ksRate (kindSpec KBusInDelayed)  @?= SampleRate
        ksRate (kindSpec KGain)          @?= CompileRate
        ksRate (kindSpec KAdd)           @?= CompileRate
        ksRate (kindSpec KOut)           @?= CompileRate
        ksRate (kindSpec KBusOut)        @?= CompileRate

    , testCase "SinOsc: floor wins over Param inputs (still SampleRate)" $ do
        let g = runSynth $ do
              _ <- sinOsc 440.0 0.0
              pure ()
        rateOfFirst KSinOsc g @?= SampleRate

    , testCase "Pure-Param Gain stays at CompileRate" $ do
        -- Both inputs are Param literals (CompileRate); Gain's floor
        -- is CompileRate; the join is CompileRate. A future pass
        -- could fold this away — for now, assert it's at least
        -- annotated correctly.
        let g = runSynth $ do
              _ <- gain (Param 0.5) (Param 0.3)
              pure ()
        rateOfFirst KGain g @?= CompileRate

    , testCase "Gain fed by SinOsc lifts to SampleRate" $ do
        let g = runSynth $ do
              o <- sinOsc 440.0 0.0
              _ <- gain o 0.5
              pure ()
        rateOfFirst KGain g @?= SampleRate

    , testCase "Out inherits its input's rate" $ do
        -- Audio-driven Out → SampleRate.
        let gAudio = runSynth $ do
              o <- sinOsc 440.0 0.0
              out 0 o
        rateOfFirst KOut gAudio @?= SampleRate
        -- Param-driven Out → CompileRate.
        let gParam = runSynth $ out 0 (Param 0.0)
        rateOfFirst KOut gParam @?= CompileRate

    , testCase "Stateful LPF keeps SampleRate even with all-Param inputs" $ do
        -- LPF's biquad delay state cannot be coarsened, so its floor
        -- is SampleRate regardless of input rates.
        let g = runSynth $ do
              _ <- lpf (Param 0.0) (Param 800.0) (Param 0.7)
              pure ()
        rateOfFirst KLPF g @?= SampleRate

    , testCase "Add: CompileRate when both Param, SampleRate when one is audio" $ do
        let gConst = runSynth $ do
              _ <- add (Param 1.0) (Param 2.0)
              pure ()
        rateOfFirst KAdd gConst @?= CompileRate
        let gMix = runSynth $ do
              o <- sinOsc 440.0 0.0
              _ <- add (Param 1.0) o
              pure ()
        rateOfFirst KAdd gMix @?= SampleRate

    , testCase "multi-hop chain: every downstream node lifts to SampleRate" $ do
        -- SinOsc → Gain → Gain → Out: the SampleRate floor at the
        -- source propagates all the way to the sink.
        let g = runSynth $ do
              o   <- sinOsc 440.0 0.0
              g1  <- gain o 0.7
              g2  <- gain g1 0.5
              out 0 g2
        case lowerGraph g of
          Left err -> assertFailure $ "lowerGraph failed: " <> err
          Right ir ->
            let rates = map irRate (giNodes ir)
            in assertEqual
                 "every node along the chain should be SampleRate"
                 (replicate (length rates) SampleRate)
                 rates

    , testCase "disjoint subgraphs: CompileRate and SampleRate coexist" $ do
        -- One subgraph runs on Params only (Gain Param Param); the
        -- other is audio-driven (SinOsc → Out). Expect at least one
        -- of each rate among the lowered nodes.
        let g = runSynth $ do
              _   <- gain (Param 0.5) (Param 0.3)  -- CompileRate cluster
              o   <- sinOsc 440.0 0.0              -- SampleRate
              out 0 o                              -- SampleRate via inherit
        case lowerGraph g of
          Left err -> assertFailure $ "lowerGraph failed: " <> err
          Right ir -> do
            let rates = map irRate (giNodes ir)
            assertBool
              ("expected at least one CompileRate node, got " <> show rates)
              (CompileRate `elem` rates)
            assertBool
              ("expected at least one SampleRate node, got " <> show rates)
              (SampleRate `elem` rates)

    , testCase "BusOut/BusIn through-graph: rates lift to SampleRate" $ do
        -- BusOut floor is CompileRate but its input (SinOsc) is
        -- SampleRate, so the BusOut node ends up SampleRate. BusIn
        -- floor is SampleRate (intrinsic).
        let g = runSynth $ do
              o   <- sinOsc 440.0 0.0
              busOut 5 o
              tap <- busIn 5
              out 0 tap
        rateOfFirst KBusOut g @?= SampleRate
        rateOfFirst KBusIn  g @?= SampleRate

    , testCase "propagateRates is idempotent" $ do
        -- Running propagation twice must yield the same IR as
        -- running it once. This is the post-condition of a
        -- correctly-defined fixed-point lift.
        let g = runSynth $ do
              o  <- sinOsc 440.0 0.0
              g1 <- gain o 0.7
              out 0 g1
        case lowerGraph g of
          Left err -> assertFailure err
          Right ir -> propagateRates (propagateRates ir) @?= ir

    , testCase "Delay: floor SampleRate (stateful per-node ring buffer)" $ do
        -- The delay's floor is SampleRate because its read/write are
        -- per-sample and the buffer carries per-sample history. Even
        -- with all-Param inputs, the floor wins.
        let g = runSynth $ do
              _ <- delayL 0.01 (Param 0.0) (Param 0.005)
              pure ()
        rateOfFirst KDelay g @?= SampleRate

    , testCase "Delay fed by SinOsc: SampleRate (floor and inputs agree)" $ do
        let g = runSynth $ do
              o <- sinOsc 440.0 0.0
              _ <- delayL 0.01 o (Param 0.005)
              pure ()
        rateOfFirst KDelay g @?= SampleRate

    , -- Region-rate absorption: a CompileRate helper (an all-Param
      -- Gain producing a static amplitude) sits adjacent to a
      -- SampleRate path (SinOsc → Gain → Out) and is folded into
      -- the same region instead of forming its own. The dominant
      -- rate (SampleRate) wins for regRate.
      -- See Note [Region rate compatibility] in MetaSonic.Bridge.Compile.
      testCase "CompileRate absorption: helper folds into adjacent SampleRate region" $ do
        let g = runSynth $ do
              s   <- sinOsc 440.0 0.0
              amp <- gain (Param 0.5) (Param 0.3)  -- CompileRate Gain
              sc  <- gain s amp                     -- SampleRate Gain
              out 0 sc
        case lowerGraph g of
          Left err -> assertFailure $ "lowerGraph failed: " <> err
          Right ir -> do
            let rg      = formRegions (giNodes ir)
                regions = rgRegions rg
                rates   = map irRate (giNodes ir)
            -- Sanity: rates still mixed at the node level.
            assertBool
              ("expected at least one CompileRate node, got " <> show rates)
              (CompileRate `elem` rates)
            assertBool
              ("expected at least one SampleRate node, got " <> show rates)
              (SampleRate `elem` rates)
            -- Absorption: a single SampleRate region holds them all.
            assertEqual
              "absorption should yield exactly one region"
              1 (length regions)
            case regions of
              [r] -> do
                regRate r   @?= SampleRate
                length (regNodes r) @?= length (giNodes ir)
              _   -> assertFailure "unreachable: length checked above"
    ]
