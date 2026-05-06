{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : Spec
-- Description : Structural tests for the MetaSonic compiler pipeline
--
-- Two layers of coverage:
--
--   * Unit tests on the demo graphs from Main, asserting that
--     validateAndSort, lowerGraph, and compileRuntimeGraph all
--     succeed and produce well-formed output.
--
--   * QuickCheck properties on randomly generated, well-formed
--     SynthGraphs, asserting the dense-lowering invariants:
--     contiguous indices, every RFrom references an earlier
--     index, lowerGraph preserves node count.
--
-- The generator builds graphs by replaying a list of DSL operations
-- inside the SynthM monad, so referential integrity is guaranteed
-- by construction. We do not try to generate cycles or dangling
-- references here; cycle detection is exercised by a hand-built
-- unit test.

module Main (main) where

import qualified Data.Map.Strict           as M
import           Data.List                 (isPrefixOf)

import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck     as QC

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI      (c_rt_graph_kind_supported)
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Validate
import           MetaSonic.Types

main :: IO ()
main = defaultMain $ testGroup "MetaSonic"
  [ unitTests
  , properties
  ]

------------------------------------------------------------
-- Sample graphs (mirrors of the demos in app/Main.hs)
------------------------------------------------------------

simpleGraph :: SynthGraph
simpleGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  out 0 osc

chainGraph :: SynthGraph
chainGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  g   <- gain osc 0.5
  out 0 g

fanOutGraph :: SynthGraph
fanOutGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  g1  <- gain osc 0.3
  g2  <- gain osc 0.7
  out 0 g1
  out 1 g2

sawGraph :: SynthGraph
sawGraph = runSynth $ do
  osc <- sawOsc 440.0 0.0
  g   <- gain osc 0.4
  out 0 g

noiseLpfGraph :: SynthGraph
noiseLpfGraph = runSynth $ do
  n <- noiseGen
  f <- lpf n 800.0 0.7
  g <- gain f 0.4
  out 0 g

ringModGraph :: SynthGraph
ringModGraph = runSynth $ do
  carrier   <- sinOsc 440.0 0.0
  modulator <- sinOsc 7.0 0.0
  ring      <- gain carrier modulator
  amped     <- gain ring 0.3
  out 0 amped

fmGraph :: SynthGraph
fmGraph = runSynth $ do
  lfo       <- sinOsc 5.0 0.0
  deviation <- gain lfo 30.0
  freq      <- add 440.0 deviation
  carrier   <- sinOsc freq 0.0
  amped     <- gain carrier 0.3
  out 0 amped

demoGraphs :: [(String, SynthGraph)]
demoGraphs =
  [ ("simple",    simpleGraph)
  , ("chain",     chainGraph)
  , ("fanout",    fanOutGraph)
  , ("saw",       sawGraph)
  , ("noise-lpf", noiseLpfGraph)
  , ("ringmod",   ringModGraph)
  , ("fm",        fmGraph)
  ]

------------------------------------------------------------
-- Unit tests
------------------------------------------------------------

unitTests :: TestTree
unitTests = testGroup "Unit tests"
  [ testGroup "validateAndSort succeeds on demo graphs"
      [ testCase name $ case validateAndSort g of
          Right _  -> pure ()
          Left err -> assertFailure $ "validateAndSort failed: " <> err
      | (name, g) <- demoGraphs
      ]

  , testGroup "lowerGraph preserves node count on demo graphs"
      [ testCase name $ case lowerGraph g of
          Left err -> assertFailure $ "lowerGraph failed: " <> err
          Right ir -> length (giNodes ir) @?= M.size (sgNodes g)
      | (name, g) <- demoGraphs
      ]

  , testGroup "compileRuntimeGraph produces dense indices on demo graphs"
      [ testCase name $ case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure err
          Right rt -> assertDenseIndices rt
      | (name, g) <- demoGraphs
      ]

  , testGroup "every RFrom references an earlier index on demo graphs"
      [ testCase name $ case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure err
          Right rt -> assertTopoOrder rt
      | (name, g) <- demoGraphs
      ]

  , testCase "checkDependencies rejects missing references" $
      case checkDependencies missingDepGraph of
        Right () ->
          assertFailure "expected checkDependencies to reject missing dep"
        Left err ->
          assertBool ("expected 'Missing' in error, got: " <> err)
                    ("Missing" `isPrefixOf` err)

  , testCase "validateAndSort rejects cycles" $
      case validateAndSort cycleGraph of
        Right _ ->
          assertFailure "expected validateAndSort to reject cycle"
        Left err ->
          assertBool ("expected 'Cycle' in error, got: " <> err)
                    ("Cycle" `isPrefixOf` err)

  , testCase "ringmod: a gain node has both inputs wired as RFrom" $
      case lowerGraph ringModGraph >>= compileRuntimeGraph of
        Left err -> assertFailure err
        Right rt ->
          let -- The ring-mod multiply is the Gain node whose BOTH inputs
              -- are RFrom. The output gain stage has only its port 0 wired.
              hasTwoAudioInputs n =
                rnKind n == KGain
                && length [() | RFrom _ _ <- rnInputs n] == 2
          in assertBool
               "expected a Gain node with two RFrom inputs in ringmod"
               (any hasTwoAudioInputs (rgNodes rt))

  , testCase "fm: a SinOsc has its frequency port wired as RFrom" $
      case lowerGraph fmGraph >>= compileRuntimeGraph of
        Left err -> assertFailure err
        Right rt ->
          let -- The FM carrier is a SinOsc whose port-0 (freq) input
              -- is RFrom (audio-rate modulator). The LFO SinOsc has
              -- port-0 as RConst (literal 5 Hz).
              hasModulatedFreq n = case (rnKind n, rnInputs n) of
                (KSinOsc, RFrom _ _ : _) -> True
                _                        -> False
          in assertBool
               "expected a SinOsc with RFrom on port 0 in fm graph"
               (any hasModulatedFreq (rgNodes rt))

  , testCase "fm: contains an Add node biasing freq off zero" $
      case lowerGraph fmGraph >>= compileRuntimeGraph of
        Left err -> assertFailure err
        Right rt ->
          let -- The Add node should have 440.0 as its first control
              -- (the bias) and an RFrom on port 1 (the deviation).
              isVibratoBias n = case (rnKind n, rnControls n, rnInputs n) of
                (KAdd, 440.0 : _, _ : RFrom _ _ : _) -> True
                _                                    -> False
          in assertBool
               "expected an Add node with bias=440.0 and modulated port 1"
               (any isVibratoBias (rgNodes rt))

  , -- Contract test: every Haskell NodeKind must map to a kindTag
    -- that the C++ runtime recognizes via kind_from_tag. Adding a
    -- constructor to NodeKind without updating rt_graph.cpp will fail
    -- here. Enum/Bounded on NodeKind ensures new constructors are
    -- automatically covered.
    testGroup "C ABI agrees on every NodeKind tag"
      [ testCase (show k) $ do
          ok <- c_rt_graph_kind_supported (kindTag k)
          assertBool
            ("rt_graph_kind_supported(" <> show (kindTag k) <> ") "
              <> "returned 0 for " <> show k <> " — C++ kind_from_tag "
              <> "is missing this case")
            (ok == 1)
      | k <- [minBound .. maxBound :: NodeKind]
      ]
  ]

-- A hand-built graph that references a non-existent NodeID. The DSL
-- alone cannot construct one; we use the raw Map constructor.
missingDepGraph :: SynthGraph
missingDepGraph = SynthGraph $ M.singleton (NodeID 0) NodeSpec
  { nsID   = NodeID 0
  , nsName = "out"
  , nsUgen = Out 0 (Audio (NodeID 99) (PortIndex 0))
  }

-- A hand-built graph with a 0 -> 1 -> 0 cycle.
cycleGraph :: SynthGraph
cycleGraph = SynthGraph $ M.fromList
  [ ( NodeID 0
    , NodeSpec (NodeID 0) "gain-a"
        (Gain (Audio (NodeID 1) (PortIndex 0)) (Param 0.5)) )
  , ( NodeID 1
    , NodeSpec (NodeID 1) "gain-b"
        (Gain (Audio (NodeID 0) (PortIndex 0)) (Param 0.5)) )
  ]

assertDenseIndices :: RuntimeGraph -> Assertion
assertDenseIndices rt =
  let n   = length (rgNodes rt)
      idx = [ i | RuntimeNode { rnIndex = NodeIndex i } <- rgNodes rt ]
  in idx @?= [0 .. n - 1]

assertTopoOrder :: RuntimeGraph -> Assertion
assertTopoOrder rt =
  mapM_ checkNode (rgNodes rt)
  where
    checkNode node =
      let NodeIndex here = rnIndex node
      in mapM_ (checkInput here) (rnInputs node)

    checkInput here = \case
      RFrom (NodeIndex src) _ ->
        assertBool
          ("input src=" <> show src <> " is not earlier than dst=" <> show here)
          (src < here)
      RConst _ -> pure ()

------------------------------------------------------------
-- Property tests
------------------------------------------------------------

properties :: TestTree
properties = testGroup "Properties"
  [ QC.testProperty "compileRuntimeGraph: indices are [0..n-1]" $
      forAllShrink genWellFormedGraph (const []) propDenseIndices

  , QC.testProperty "compileRuntimeGraph: every RFrom references an earlier index" $
      forAllShrink genWellFormedGraph (const []) propTopoOrder

  , QC.testProperty "lowerGraph preserves node count" $
      forAllShrink genWellFormedGraph (const []) propPreservesCount

  , QC.testProperty "validateAndSort succeeds on well-formed graphs" $
      forAllShrink genWellFormedGraph (const []) propValidates
  ]

propDenseIndices :: SynthGraph -> Property
propDenseIndices g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    let n   = length (rgNodes rt)
        idx = [ i | RuntimeNode { rnIndex = NodeIndex i } <- rgNodes rt ]
    in idx === [0 .. n - 1]

propTopoOrder :: SynthGraph -> Property
propTopoOrder g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt -> conjoin
    [ counterexample ("node " <> show (rnIndex node)) $
        all (refsEarlier (rnIndex node)) (rnInputs node)
    | node <- rgNodes rt
    ]
  where
    refsEarlier (NodeIndex dst) (RFrom (NodeIndex src) _) = src < dst
    refsEarlier _               (RConst _)                = True

propPreservesCount :: SynthGraph -> Property
propPreservesCount g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> length (giNodes ir) === M.size (sgNodes g)

propValidates :: SynthGraph -> Property
propValidates g = case validateAndSort g of
  Left err -> counterexample ("validateAndSort failed: " <> err) False
  Right _  -> property True

------------------------------------------------------------
-- Generator: well-formed SynthGraphs
------------------------------------------------------------
--
-- Strategy: generate a list of DSL operations and replay them
-- inside SynthM. Each operation that needs a source node picks
-- an index into the list of NodeIDs allocated so far, modulo
-- the current source-list length. This guarantees referential
-- integrity by construction.
--
-- We always start with one OSinOsc to make sure later transform
-- ops have a source available. Ops that cannot be satisfied
-- (transform with no sources) are skipped; this only happens at
-- the very start, before any source has been added.

data Op
  = OSinOsc Float Float
  | OSawOsc Float Float
  | ONoise
  | OGain   Int Float        -- source-index, gain amount
  | OLPF    Int Float Float  -- source-index, cutoff, q
  | OOut    Int Int          -- channel, source-index
  deriving (Eq, Show)

genOp :: Gen Op
genOp = oneof
  [ OSinOsc <$> choose (50, 8000) <*> choose (0.0, 1.0)
  , OSawOsc <$> choose (50, 8000) <*> choose (0.0, 1.0)
  , pure ONoise
  , OGain <$> nonNegInt <*> choose (0.0, 1.0)
  , OLPF  <$> nonNegInt <*> choose (50, 8000) <*> choose (0.1, 4.0)
  , OOut  <$> choose (0, 1) <*> nonNegInt
  ]
  where
    nonNegInt = choose (0, 100)

genWellFormedGraph :: Gen SynthGraph
genWellFormedGraph = sized $ \sz -> do
  -- Cap the generator at 16 ops for fast iteration; sz=100 by default
  -- but the absolute size doesn't change the invariants we're testing.
  n   <- choose (1, max 1 (min 16 sz))
  ops <- vectorOf n genOp
  pure $ runSynth (interpret (OSinOsc 440 0 : ops))

interpret :: [Op] -> SynthM ()
interpret = go []
  where
    go :: [Connection] -> [Op] -> SynthM ()
    go _ [] = pure ()

    go xs (OSinOsc f p : rest) = do
      c <- sinOsc (Param f) (Param p)
      go (xs <> [c]) rest

    go xs (OSawOsc f p : rest) = do
      c <- sawOsc (Param f) (Param p)
      go (xs <> [c]) rest

    go xs (ONoise : rest) = do
      c <- noiseGen
      go (xs <> [c]) rest

    go xs (OGain i a : rest)
      | null xs   = go xs rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- gain src (Param a)
          go (xs <> [c]) rest

    go xs (OLPF i f q : rest)
      | null xs   = go xs rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- lpf src (Param f) (Param q)
          go (xs <> [c]) rest

    go xs (OOut ch i : rest)
      | null xs   = go xs rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          out ch src
          go xs rest
