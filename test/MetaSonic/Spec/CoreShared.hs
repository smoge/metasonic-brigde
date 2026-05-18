{-# LANGUAGE LambdaCase #-}

-- | Shared test helpers, graph fixtures, generators, and OSC wire
-- fixtures previously living in "MetaSonic.Spec.Core".
--
-- Splitting them out lets non-Core test modules (FFI cohorts, the
-- AuthoringDSL cohort, the OSC-listener cohorts, the manifest-reload
-- cohorts) import only the shared surface they actually need without
-- pulling in the @unitTests@ / @properties@ trees. "MetaSonic.Spec.Core"
-- is now the owner of those trees and re-imports this module open so
-- its property predicates can still reference the generators here.
module MetaSonic.Spec.CoreShared where

import qualified Data.Map.Strict           as M
import qualified Data.Set                  as S
import           Data.List                 (nub, sort)
import           Data.Word                 (Word8)
import           Foreign.C.Types           (CFloat)
import           Foreign.Ptr               (Ptr)

import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck     as QC

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Types

import qualified Data.ByteString           as OBS
import qualified Data.ByteString.Char8     as OBSC
import qualified Network.Socket            as OSCN
import qualified Network.Socket.ByteString as OSCNSB

type PtrCFloat = Ptr CFloat

runtimeGraphBuilderCapacity :: RuntimeGraph -> Int
runtimeGraphBuilderCapacity = length . rgNodes

templateGraphBuilderCapacity :: TemplateGraph -> Int
templateGraphBuilderCapacity =
  sum . map (length . rgNodes . tplGraph) . tgTemplates

kindHistogram :: SynthGraph -> [(String, Int)]
kindHistogram g =
  let kinds = [ show (inferKind (nsUgen spec))
              | spec <- M.elems (sgNodes g) ]
  in sort [ (k, length (filter (== k) kinds))
          | k <- nub kinds ]

-- | The list of source NodeSpecs whose UGen lowers to the given kind.
nodesByKind :: SynthGraph -> NodeKind -> [NodeSpec]
nodesByKind g k =
  [ spec | spec <- M.elems (sgNodes g), inferKind (nsUgen spec) == k ]

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

-- | Used by the C0a "free layer with non-contiguous ordinals"
-- regression. The intended shape, post-formRegions /
-- selectRegionKernels, is three free buffer-terminal regions
-- (region 0, region 1, region 2) plus a barrier sink, where
-- region 1 structurally depends on region 0 (the second saw
-- chain feeds gain1's output into its own LPF) and region 2 is
-- independent. With that shape, 'goLayers' partitions the ready
-- frontier as [{0, 2}, {1}] — non-contiguous in regionSchedule
-- order [0, 1, 2]. The test asserts the divergence and verifies
-- the FFI metadata preserves the ordinal set.
divergentLayerGraph :: SynthGraph
divergentLayerGraph = runSynth $ do
  s1 <- sawOsc 110.0 0.0
  f1 <- lpf s1 (Param 800.0)  (Param 4.0)
  g1 <- gain f1 (Param 0.4)
  -- Cross-region structural edge: this LPF reads g1's output,
  -- and selectRegionKernels claims [s1, f1, g1] as a fused
  -- buffer-terminal region, leaving [f2, g2] in its own region.
  f2 <- lpf g1 (Param 1500.0) (Param 4.0)
  g2 <- gain f2 (Param 0.4)
  -- Independent free buffer chain.
  s3 <- sawOsc 220.0 0.0
  f3 <- lpf s3 (Param 1000.0) (Param 4.0)
  g3 <- gain f3 (Param 0.4)
  summed <- add g2 g3
  out 0 summed

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

ugenKind :: UGen -> NodeKind
ugenKind = \case
  SinOsc{}        -> KSinOsc
  SawOsc{}        -> KSawOsc
  PulseOsc{}      -> KPulseOsc
  TriOsc{}        -> KTriOsc
  NoiseGen        -> KNoiseGen
  LPF{}           -> KLPF
  HPF{}           -> KHPF
  BPF{}           -> KBPF
  Notch{}         -> KNotch
  Gain{}          -> KGain
  Add{}           -> KAdd
  Env{}           -> KEnv
  Out{}           -> KOut
  BusOut{}        -> KBusOut
  BusIn{}         -> KBusIn
  BusInDelayed{}  -> KBusInDelayed
  Delay{}         -> KDelay
  Smooth{}        -> KSmooth
  PlayBufMono{}   -> KPlayBufMono
  RecordBufMono{} -> KRecordBufMono
  SpectralFreeze{} -> KSpectralFreeze
  StaticPlugin{}  -> KStaticPlugin

-- The empty graph: no nodes at all.
emptyGraph_ :: SynthGraph
emptyGraph_ = runSynth (pure ())

-- An Out node fed by a constant — no audio source. Useful as a
-- degenerate case that should still compile (the runtime treats
-- unconnected Out as silence).
silentOutGraph :: SynthGraph
silentOutGraph = runSynth $ out 0 (Param 0)

-- Two completely independent subgraphs: SinOsc 440 → Out 0,
-- and SinOsc 660 → Out 1. No shared nodes.
disconnectedGraph :: SynthGraph
disconnectedGraph = runSynth $ do
  o1 <- sinOsc 440.0 0.0
  out 0 o1
  o2 <- sinOsc 660.0 0.0
  out 1 o2

-- A hand-built graph that references a non-existent NodeID. The DSL
-- alone cannot construct one; we use the raw Map constructor.
missingDepGraph :: SynthGraph
missingDepGraph = SynthGraph $ M.singleton (NodeID 0) NodeSpec
  { nsID   = NodeID 0
  , nsName = "out"
  , nsUgen = Out 0 (Audio (NodeID 99) (PortIndex 0))
  , nsMigrationKey = Nothing
  }

-- A hand-built graph with a 0 -> 1 -> 0 cycle.
cycleGraph :: SynthGraph
cycleGraph = SynthGraph $ M.fromList
  [ ( NodeID 0
    , NodeSpec (NodeID 0) "gain-a"
        (Gain (Audio (NodeID 1) (PortIndex 0)) (Param 0.5))
        Nothing )
  , ( NodeID 1
    , NodeSpec (NodeID 1) "gain-b"
        (Gain (Audio (NodeID 0) (PortIndex 0)) (Param 0.5))
        Nothing )
  ]

-- | The propagated 'irRate' of the first node of the given kind in
-- the lowered IR. The rate-propagation unit tests use this to assert
-- per-kind rate outcomes after 'lowerGraph' (which runs
-- 'propagateRates' as part of its pipeline). Errors loudly when the
-- graph fails to lower or doesn't contain a node of that kind, so
-- a misspelled test setup surfaces as a clear test failure rather
-- than a silent wrong rate.
rateOfFirst :: NodeKind -> SynthGraph -> Rate
rateOfFirst k g = case lowerGraph g of
  Left err -> error $ "rateOfFirst: lowerGraph failed: " <> err
  Right ir -> case [ irRate n | n <- giNodes ir, irKind n == k ] of
    (r : _) -> r
    []      -> error $ "rateOfFirst: no node of kind " <> show k <> " in graph"

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
-- Generator: well-formed SynthGraphs
------------------------------------------------------------
--
-- Strategy: generate a list of DSL operations and replay them
-- inside SynthM. Each operation that needs a source node picks
-- an index into the list of NodeIDs allocated so far, modulo
-- the current source-list length. This guarantees referential
-- integrity by construction.
--
-- The "*Mod" variants exercise audio-rate modulation paths
-- (FM, ring-mod, audio bias, audio gate to Env) that the
-- Param-only variants never touch.

data Op
  = OSinOsc    Double Double
  | OSinOscMod Int Double      -- audio-rate freq from source-idx, phase
  | OSawOsc    Double Double
  | OPulseOsc  Double Double Double
                               -- freq, phase, width
  | OPulseOscWMod Double Double Int
                               -- freq, phase, audio-source-idx -> width
                               -- (exercises the new audio-rate
                               -- intermodulation primitive)
  | OTriOsc    Double Double
  | OTriOscMod Int Double      -- audio-rate freq, phase
  | ONoise
  | OGain      Int Double      -- audio source-idx, constant gain
  | OGainMod   Int Int         -- audio × audio (ring-mod shape)
  | OLPF       Int Double Double -- source-index, cutoff, q
  | OHPF       Int Double Double -- source-index, cutoff, q
  | OBPF       Int Double Double -- source-index, center, q
  | ONotch     Int Double Double -- source-index, center, q
  | OAdd       Double Int      -- bias × audio source-idx
  | OAddMod    Int Int         -- audio + audio
  | OEnv       Int Double Double Double Double
                               -- gate-source-idx, A, D, S, R
  | OBusOut         Int Int          -- bus, audio source-index
  | OBusIn          Int              -- bus
  | OBusInDelayed   Int              -- bus (feedback-safe reader)
  | ODelay          Double Double Int
                                     -- max-time (s), time const (s), signal-idx
  | ODelayMod       Double Int Int   -- max-time (s), signal-idx, time-source-idx
  | OSmooth         Double Double    -- base-freq (Hz), constant target value
  | OSmoothMod      Double Int       -- base-freq (Hz), audio-source-idx
  | OOut            Int Int          -- channel, source-index
  deriving (Eq, Show)

genOp :: Gen Op
genOp = oneof
  [ OSinOsc    <$> choose (50, 8000) <*> choose (0.0, 1.0)
  , OSinOscMod <$> nonNegInt         <*> choose (0.0, 1.0)
  , OSawOsc    <$> choose (50, 8000) <*> choose (0.0, 1.0)
  , OPulseOsc  <$> choose (50, 8000) <*> choose (0.0, 1.0)
                                     <*> choose (0.05, 0.95)
  , OPulseOscWMod <$> choose (50, 8000) <*> choose (0.0, 1.0)
                                     <*> nonNegInt
  , OTriOsc    <$> choose (50, 8000) <*> choose (0.0, 1.0)
  , OTriOscMod <$> nonNegInt         <*> choose (0.0, 1.0)
  , pure ONoise
  , OGain    <$> nonNegInt <*> choose (0.0, 1.0)
  , OGainMod <$> nonNegInt <*> nonNegInt
  , OLPF     <$> nonNegInt <*> choose (50, 8000) <*> choose (0.1, 4.0)
  , OHPF     <$> nonNegInt <*> choose (50, 8000) <*> choose (0.1, 4.0)
  , OBPF     <$> nonNegInt <*> choose (50, 8000) <*> choose (0.1, 4.0)
  , ONotch   <$> nonNegInt <*> choose (50, 8000) <*> choose (0.1, 4.0)
  , OAdd     <$> choose (-1.0, 1.0) <*> nonNegInt
  , OAddMod  <$> nonNegInt <*> nonNegInt
  , OEnv     <$> nonNegInt
             <*> choose (0.001, 0.1) <*> choose (0.001, 0.5)
             <*> choose (0.0, 1.0)   <*> choose (0.001, 0.5)
  , OBusOut       <$> choose (0, 3) <*> nonNegInt
  , OBusIn        <$> choose (0, 3)
  , OBusInDelayed <$> choose (0, 3)
  -- Delay max-time stays bounded so the runtime allocator doesn't
  -- chase pathological buffer sizes during randomised testing. Time
  -- (the read offset) is allowed to overshoot the max occasionally;
  -- the kernel clamps. Both are exercised against propagateRates,
  -- the kindSpec arity check, and dense lowering by every property.
  , ODelay        <$> choose (0.001, 0.05)
                  <*> choose (0.0,   0.04)
                  <*> nonNegInt
  , ODelayMod     <$> choose (0.001, 0.05)
                  <*> nonNegInt <*> nonNegInt
  , OSmooth       <$> choose (5.0, 500.0)  <*> choose (-1.0, 1.0)
  , OSmoothMod    <$> choose (5.0, 500.0)  <*> nonNegInt
  , OOut          <$> choose (0, 1) <*> nonNegInt
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

-- | Generator for fused/unfused FFI render-equivalence: a strictly
-- deterministic, always-renderable subset of 'genWellFormedGraph'.
--
-- Three differences from 'genWellFormedGraph' that matter here:
--
--   * 'ONoise' is filtered out. The C++ 'q::white_noise_gen' is
--     seeded per 'GraphInstance', so two separate runtime handles
--     (one for the unfused render, one for the fused render) emit
--     different sample sequences even on a topologically identical
--     graph. That nondeterminism would mask any actual fusion bug.
--   * A fresh scalar Gain/Add suffix is appended and wired to bus 7,
--     guaranteeing both a non-empty bus list to compare and at least
--     one single-consumer fusion site. Random ops may add their own
--     'OOut' / 'OBusOut' on buses 0-3, and those are still compared
--     too — bus 7 is the floor, not the ceiling.
--   * The op generator is /tilted/ toward 'OGain' and 'OAdd' so a
--     reasonable fraction of random graphs actually exercise the
--     fusion machinery. Using 'genOp' raw produced ~8% fusion-
--     triggered cases (Gain and Add are 2 of ~24 uniformly-weighted
--     ops, and only some of those have rnConsumerCount == 1); the
--     guaranteed scalar suffix makes fusion coverage the expected case
--     rather than an accident of later random consumers.
--
-- Cap is smaller than 'genWellFormedGraph' (12 ops vs 16) because each
-- case round-trips through the FFI and renders 64 frames on both
-- paths.
genFusableRenderableGraph :: Gen SynthGraph
genFusableRenderableGraph = sized $ \sz -> do
  n      <- choose (0, max 1 (min 12 sz))
  ops    <- vectorOf n genFusableOp
  suffix <- genFusedConsumer
  pure $ runSynth $ do
    xs <- interpretConnections (OSinOsc 440 0 : ops)
    case reverse xs of
      []        -> pure ()  -- impossible: the seed SinOsc always appends
      src : _   -> do
        fused <- suffix src
        out 7 fused

-- | Final scalar consumer used by 'genFusableRenderableGraph' to
-- guarantee at least one fusion site. It is appended after all random
-- ops, so no later node can add a second consumer and invalidate the
-- single-consumer gate.
genFusedConsumer :: Gen (Connection -> SynthM Connection)
genFusedConsumer = oneof
  [ do k <- choose (0.05, 1.0)
       pure $ \src -> gain src (Param k)
  , do b <- choose (-1.0, 1.0)
       pure $ \src -> add src (Param b)
  , do b <- choose (-1.0, 1.0)
       pure $ \src -> add (Param b) src
  , do k <- choose (0.05, 1.0)
       b <- choose (-1.0, 1.0)
       pure $ \src -> do
         scaled <- gain src (Param k)
         add scaled (Param b)
  , do b <- choose (-1.0, 1.0)
       k <- choose (0.05, 1.0)
       pure $ \src -> do
         biased <- add src (Param b)
         gain biased (Param k)
  ]

-- | Op generator biased toward fusion candidates. 'OGain' and 'OAdd'
-- (the only two fusable kinds today) get higher weights so chains
-- and fan-outs of scalar arithmetic actually appear in the
-- distribution; the rest of 'genOp' (less 'ONoise') falls through
-- with the original uniform weighting under the remaining mass.
genFusableOp :: Gen Op
genFusableOp = frequency
  [ (3, OGain <$> choose (0, 100)        <*> choose (0.0, 1.0))
  , (3, OAdd  <$> choose (-1.0, 1.0)     <*> choose (0, 100))
  , (4, genOp `suchThat` (\o -> not (isNoise o)))
  ]
  where
    isNoise ONoise = True
    isNoise _      = False

-- | Drop one leaf node at a time. A node is a 'leaf' if no other
-- node's UGen depends on it. Each shrink produces a strictly smaller
-- graph that is still well-formed (no dangling 'NodeID' references),
-- so QuickCheck reduces a failing 16-op graph to the minimal subset
-- that still triggers the failure.
shrinkSynthGraph :: SynthGraph -> [SynthGraph]
shrinkSynthGraph g =
  [ SynthGraph (M.delete nid nodes)
  | nid <- M.keys nodes
  , isLeaf nid
  ]
  where
    nodes      = sgNodes g
    allDeps    = concatMap (dependencies . nsUgen) (M.elems nodes)
    isLeaf nid = nid `notElem` allDeps

{- Note [Generator avoids E_r cycles]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'OBusOut' / 'OOut' / 'OBusIn' Ops can interact through bus numbers, so
the generator could in principle build a graph where 'BusIn n' is
structurally upstream of a later 'BusOut n' (or 'Out n' — the two share
a kernel and a 'BusWrite n' effect), closing a cycle through the E_r
edge that the scheduler adds. 'validateAndSort' would then reject the
graph and 'propValidates' would fail — *not* a real bug, just generator
noise.

The interpreter avoids this by tracking the set of bus numbers already
"poisoned" by a 'BusIn' op. A later 'OBusOut n' or 'OOut n' on a poisoned
bus is silently skipped. With this discipline, no generated graph contains
an E_r cycle by construction, so all existing properties extend cleanly
to graphs with bus routing.

'OBusInDelayed' is *deliberately* not in this poisoning set. A
'BusInDelayed n' carries 'BusReadDelayed n' rather than 'BusRead n',
which the scheduler ignores when deriving E_r — so a downstream
'OBusOut n' on the same bus closes a feedback path that crosses the
block boundary, not a within-block cycle. The generator is therefore
free to emit feedback patterns ('OBusInDelayed bus' followed by
'OBusOut bus') and 'propValidates' must accept them. This is the QC
counterpart of the dedicated unit test "feedback graph through
busInDelayed topologically sorts".
-}

interpret :: [Op] -> SynthM ()
interpret ops = do
  _ <- interpretConnections ops
  pure ()

interpretConnections :: [Op] -> SynthM [Connection]
interpretConnections = go [] S.empty
  where
    go :: [Connection] -> S.Set Int -> [Op] -> SynthM [Connection]
    go xs _ [] = pure xs

    go xs r (OSinOsc f p : rest) = do
      c <- sinOsc (Param f) (Param p)
      go (xs <> [c]) r rest

    go xs r (OSinOscMod i p : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let freq = xs !! (i `mod` length xs)
          c <- sinOsc freq (Param p)
          go (xs <> [c]) r rest

    go xs r (OSawOsc f p : rest) = do
      c <- sawOsc (Param f) (Param p)
      go (xs <> [c]) r rest

    go xs r (OPulseOsc f p w : rest) = do
      c <- pulseOsc (Param f) (Param p) (Param w)
      go (xs <> [c]) r rest

    go xs r (OPulseOscWMod f p i : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let w = xs !! (i `mod` length xs)
          c <- pulseOsc (Param f) (Param p) w
          go (xs <> [c]) r rest

    go xs r (OTriOsc f p : rest) = do
      c <- triOsc (Param f) (Param p)
      go (xs <> [c]) r rest

    go xs r (OTriOscMod i p : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let freq = xs !! (i `mod` length xs)
          c <- triOsc freq (Param p)
          go (xs <> [c]) r rest

    go xs r (ONoise : rest) = do
      c <- noiseGen
      go (xs <> [c]) r rest

    go xs r (OGain i a : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- gain src (Param a)
          go (xs <> [c]) r rest

    go xs r (OGainMod i j : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let m = length xs
              s = xs !! (i `mod` m)
              a = xs !! (j `mod` m)
          c <- gain s a
          go (xs <> [c]) r rest

    go xs r (OLPF i f q : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- lpf src (Param f) (Param q)
          go (xs <> [c]) r rest

    go xs r (OHPF i f q : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- hpf src (Param f) (Param q)
          go (xs <> [c]) r rest

    go xs r (OBPF i f q : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- bpf src (Param f) (Param q)
          go (xs <> [c]) r rest

    go xs r (ONotch i f q : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- notch src (Param f) (Param q)
          go (xs <> [c]) r rest

    go xs r (OAdd b i : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- add (Param b) src
          go (xs <> [c]) r rest

    go xs r (OAddMod i j : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let m = length xs
              a = xs !! (i `mod` m)
              b = xs !! (j `mod` m)
          c <- add a b
          go (xs <> [c]) r rest

    go xs r (OEnv i ea ed es er : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let gate = xs !! (i `mod` length xs)
          c <- env gate (Param ea) (Param ed) (Param es) (Param er)
          go (xs <> [c]) r rest

    go xs r (OBusOut bus i : rest)
      | null xs            = go xs r rest
      | bus `S.member` r   = go xs r rest  -- skip to avoid an E_r cycle
      | otherwise          = do
          let src = xs !! (i `mod` length xs)
          busOut bus src
          go xs r rest

    go xs r (OBusIn bus : rest) = do
      c <- busIn bus
      go (xs <> [c]) (S.insert bus r) rest

    -- Feedback-safe reader: contributes no E_r edge, so no bus
    -- needs to be poisoned. A later 'OBusOut bus' on the same
    -- bus is allowed and closes a (cross-block) feedback path
    -- that the scheduler accepts. See Note [Generator avoids E_r
    -- cycles] for why this is the deliberate distinction.
    go xs r (OBusInDelayed bus : rest) = do
      c <- busInDelayed bus
      go (xs <> [c]) r rest

    -- Delay with a constant time. Floor is SampleRate (stateful),
    -- effect is Pure (per-instance buffer), so propagation and E_r
    -- machinery already cover it through the existing properties.
    go xs r (ODelay maxT t i : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- delayL maxT src (Param t)
          go (xs <> [c]) r rest

    -- Delay with audio-rate delay-time modulation: pulls another
    -- node's output into port 1.
    go xs r (ODelayMod maxT i j : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let m   = length xs
              sig = xs !! (i `mod` m)
              tin = xs !! (j `mod` m)
          c <- delayL maxT sig tin
          go (xs <> [c]) r rest

    -- Smooth on a Param target — the typical CC-update use case.
    go xs r (OSmooth baseHz t : rest) = do
      c <- smooth baseHz (Param t)
      go (xs <> [c]) r rest

    -- Smooth on an audio source — exercises the connected-input path
    -- of the kernel.
    go xs r (OSmoothMod baseHz i : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- smooth baseHz src
          go (xs <> [c]) r rest

    go xs r (OOut ch i : rest)
      | null xs            = go xs r rest
      | ch  `S.member` r   = go xs r rest  -- skip to avoid an E_r cycle
      | otherwise          = do
          let src = xs !! (i `mod` length xs)
          out ch src
          go xs r rest

------------------------------------------------------------
-- Shared OSC test fixtures
------------------------------------------------------------

-- ----- Hand-built wire fixtures ------------------------------

-- An OSC-string is null-terminated, padded with zeros to a
-- 4-byte boundary. The padding count is the smallest p ≥ 0 such
-- that (length s + 1 + p) ≡ 0 mod 4.
oscString :: OBSC.ByteString -> OBSC.ByteString
oscString s =
  let n    = OBS.length s
      pad  = (4 - ((n + 1) `mod` 4)) `mod` 4
      zeros = OBS.replicate (1 + pad) 0
  in s `OBS.append` zeros

-- Big-endian 4-byte encoding of a Word32.
be4 :: [Word8] -> OBSC.ByteString
be4 = OBS.pack

-- The bit pattern of 1500.0 :: Float in IEEE 754 big-endian is
-- 0x44BB8000.
floatBytes1500 :: OBSC.ByteString
floatBytes1500 = be4 [0x44, 0xBB, 0x80, 0x00]

-- 42 as a big-endian 32-bit signed integer: 0x0000002A.
intBytes42 :: OBSC.ByteString
intBytes42 = be4 [0x00, 0x00, 0x00, 0x2A]

-- A complete OSC message: /fx0/lpf/0 ,f 1500.0
messageBytesFx0LpfFloat :: OBSC.ByteString
messageBytesFx0LpfFloat = OBS.concat
  [ oscString (OBSC.pack "/fx0/lpf/0")
  , oscString (OBSC.pack ",f")
  , floatBytes1500
  ]

-- /fx0/outgain/0 ,i 42
messageBytesFx0OutgainInt :: OBSC.ByteString
messageBytesFx0OutgainInt = OBS.concat
  [ oscString (OBSC.pack "/fx0/outgain/0")
  , oscString (OBSC.pack ",i")
  , intBytes42
  ]

messageBytesV0LpfFloat :: OBSC.ByteString
messageBytesV0LpfFloat = OBS.concat
  [ oscString (OBSC.pack "/v0/lpf/0")
  , oscString (OBSC.pack ",f")
  , floatBytes1500
  ]

messageBytesSwapLpfFloat :: OBSC.ByteString
messageBytesSwapLpfFloat = OBS.concat
  [ oscString (OBSC.pack "/swap/lpf/0")
  , oscString (OBSC.pack ",f")
  , floatBytes1500
  ]

-- | Send a UDP datagram to a loopback port. Used by the listener
-- tests as the OSC client side. Opens, sends, closes — no
-- response handling.
sendUdpLoopback :: Int -> OBS.ByteString -> IO ()
sendUdpLoopback port payload = do
  let hints = OSCN.defaultHints
        { OSCN.addrSocketType = OSCN.Datagram
        , OSCN.addrFamily     = OSCN.AF_INET
        }
  addrs <- OSCN.getAddrInfo (Just hints) (Just "127.0.0.1")
                            (Just (show port))
  case addrs of
    []         -> error "sendUdpLoopback: no resolved address"
    (addr : _) -> do
      sock <- OSCN.socket (OSCN.addrFamily addr)
                          (OSCN.addrSocketType addr)
                          (OSCN.addrProtocol addr)
      _    <- OSCNSB.sendTo sock payload (OSCN.addrAddress addr)
      OSCN.close sock
