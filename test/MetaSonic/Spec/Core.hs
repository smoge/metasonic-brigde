{-# LANGUAGE LambdaCase #-}

-- | Graph fixtures, generators, shared helpers, and core compiler properties.
module MetaSonic.Spec.Core where

import qualified Data.Map.Strict           as M
import qualified Data.Set                  as S
import           Data.List                 (isInfixOf, isPrefixOf, nub, sort,
                                            sortBy)
import           Control.Exception         (try)
import           Data.Maybe                (mapMaybe)
import           Data.Ord                  (comparing)
import           Data.Word                 (Word8)
import           Foreign.C.Types           (CFloat (..))
import           Foreign.Marshal.Alloc     (allocaBytes)
import           Foreign.Marshal.Array     (peekArray)
import           Foreign.Ptr               (Ptr, castPtr)

import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck     as QC

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI      (c_rt_graph_kind_supported,
                                            c_rt_graph_process,
                                            c_rt_graph_read_bus,
                                            c_rt_graph_region_kernel_supported,
                                            loadRuntimeGraph,
                                            withRTGraph)
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Bridge.Validate
import           MetaSonic.Types

import           MetaSonic.Spec.Core.BusRouting (busRoutingCoreTests)
import           MetaSonic.Spec.Core.CCBuilder (ccBuilderTests)
import           MetaSonic.Spec.Core.Dependencies (dependenciesTests)
import           MetaSonic.Spec.Core.MigrationKeys (migrationKeyTests)
import           MetaSonic.Spec.Core.NodeIndex (nodeIndexResolutionTests)
import           MetaSonic.Spec.Core.TemplateGraph (templateGraphTests)
import           MetaSonic.Spec.CoreShared

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

  , nodeIndexResolutionTests

  , migrationKeyTests

  , ccBuilderTests

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
          let hasTwoAudioInputs n =
                rnKind n == KGain
                && length [() | RFrom _ _ <- rnInputs n] == 2
          in assertBool
               "expected a Gain node with two RFrom inputs in ringmod"
               (any hasTwoAudioInputs (rgNodes rt))

  , testCase "fm: a SinOsc has its frequency port wired as RFrom" $
      case lowerGraph fmGraph >>= compileRuntimeGraph of
        Left err -> assertFailure err
        Right rt ->
          let hasModulatedFreq n = case (rnKind n, rnInputs n) of
                (KSinOsc, RFrom _ _ : _) -> True
                _                        -> False
          in assertBool
               "expected a SinOsc with RFrom on port 0 in fm graph"
               (any hasModulatedFreq (rgNodes rt))

  , testCase "fm: contains an Add node biasing freq off zero" $
      case lowerGraph fmGraph >>= compileRuntimeGraph of
        Left err -> assertFailure err
        Right rt ->
          let isVibratoBias n = case (rnKind n, rnControls n, rnInputs n) of
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

  , -- Phase 4.B: every Haskell RegionKernel must round-trip through
    -- the C ABI introspection entry. Mirrors the kindTag agreement
    -- test for node kinds. If RegionKernel grows a new constructor
    -- without the matching C++ enum entry, this test catches the
    -- drift before any region kernel lands silently.
    testGroup "C ABI agrees on every RegionKernel tag"
      [ testCase (show k) $ do
          ok <- c_rt_graph_region_kernel_supported (kernelTag k)
          assertBool
            ("rt_graph_region_kernel_supported(" <> show (kernelTag k)
              <> ") returned 0 for " <> show k
              <> " — C++ region_kernel_from_tag is missing this case")
            (ok == 1)
      | k <- [minBound .. maxBound :: RegionKernel]
      ]

  , testGroup "Edge graphs"
      [ testCase "empty graph: validateAndSort succeeds with no nodes" $
          case validateAndSort emptyGraph_ of
            Right []  -> pure ()
            Right ns  -> assertFailure $ "expected [], got " <> show (length ns) <> " nodes"
            Left  err -> assertFailure $ "validateAndSort failed: " <> err

      , testCase "empty graph: lowerGraph yields 0 IR nodes" $
          case lowerGraph emptyGraph_ of
            Right ir -> length (giNodes ir) @?= 0
            Left err -> assertFailure $ "lowerGraph failed: " <> err

      , testCase "empty graph: compileRuntimeGraph yields 0 runtime nodes" $
          case lowerGraph emptyGraph_ >>= compileRuntimeGraph of
            Right rt -> length (rgNodes rt) @?= 0
            Left err -> assertFailure $ "compile failed: " <> err

      , testCase "single Out with Param source compiles and has 1 node" $
          case lowerGraph silentOutGraph >>= compileRuntimeGraph of
            Right rt -> do
              length (rgNodes rt) @?= 1
              case rgNodes rt of
                [n] -> rnKind n @?= KOut
                _   -> assertFailure "expected one node"
            Left err -> assertFailure err

      , testCase "disconnected subgraphs: both Outs survive lowering" $
          case lowerGraph disconnectedGraph >>= compileRuntimeGraph of
            Right rt -> do
              let outs = [ n | n <- rgNodes rt, rnKind n == KOut ]
              length outs @?= 2
              let chans = sort (map (head . rnControls) outs)
              chans @?= [0.0, 1.0]
            Left err -> assertFailure err
      ]

  , dependenciesTests

  , busRoutingCoreTests

  , templateGraphTests

  , -- Rate propagation: 'inferRate' returns each kind's *floor*; the
    -- post-lowering pass 'propagateRates' lifts a node's rate to the
    -- join of its inputs and that floor. These tests pin the matrix
    -- of floor × input-rate combinations (stateful kinds stay at
    -- SampleRate; stateless transforms inherit; pure-Param subgraphs
    -- collapse to CompileRate).
    --
    -- See Note [Rate inference vs rate propagation] in
    -- "MetaSonic.Bridge.IR".
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

      , -- Step B-Light: pinned output-use counts on a known graph.
        -- Linear chain SinOsc → Gain → Out: each transform has
        -- exactly one consumer; Out is a sink with no consumers.
        -- See Note [Output-use classification] in MetaSonic.Bridge.Compile.
        testCase "rnOutputUse on a linear SinOsc → Gain → Out chain" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                a <- gain o (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let uses = map rnOutputUse (rgNodes rg)
              length [() | NoOutput      <- uses] @?= 1
              length [() | RegionLocal   <- uses] @?= 2
              length [() | RegionEscapes <- uses] @?= 0
              -- Step-C single-edge fusion gate: every transform has
              -- exactly one consumer; the Out sink has zero.
              [ rnConsumerCount n
                | n <- rgNodes rg, rnKind n /= KOut
                ] @?= [1, 1]
              [ rnConsumerCount n
                | n <- rgNodes rg, rnKind n == KOut
                ] @?= [0]

      , -- Fan-out: a single SinOsc feeds two Gains. Both Gains are
        -- still RegionLocal (no cross-region escape) but the SinOsc's
        -- rnConsumerCount is 2, so it fails the destructive single-
        -- edge fusion gate. This is the case the gate is designed to
        -- catch — without it, fusion would clobber one Gain by
        -- inlining into the other.
        testCase "rnConsumerCount on SinOsc with fan-out to two Gains" $ do
          let g = runSynth $ do
                o  <- sinOsc 440.0 0.0
                g1 <- gain o (Param 0.5)
                g2 <- gain o (Param 0.3)
                out 0 g1
                out 1 g2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let uses = map rnOutputUse (rgNodes rg)
              length [() | NoOutput      <- uses] @?= 2
              length [() | RegionLocal   <- uses] @?= 3
              length [() | RegionEscapes <- uses] @?= 0
              [ rnConsumerCount n
                | n <- rgNodes rg, rnKind n == KSinOsc
                ] @?= [2]
              [ rnConsumerCount n
                | n <- rgNodes rg, rnKind n == KGain
                ] @?= [1, 1]

      , -- Bus routing keeps every transform RegionLocal too: BusOut
        -- and Out are NoOutput sinks; SinOsc's output is consumed by
        -- BusOut in the same region; BusIn's output is consumed by
        -- Out in the same region. The same-bus dataflow doesn't go
        -- through the rnInputs graph (it goes through the server bus
        -- pool), so BusIn has no FromNode consumer beyond Out and
        -- SinOsc has no FromNode consumer beyond BusOut.
        testCase "rnOutputUse on a BusOut → BusIn round-trip" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                busOut 5 o
                v <- busIn 5
                out 0 v
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let uses = map rnOutputUse (rgNodes rg)
              -- 2 sinks (BusOut + Out), 2 producers (SinOsc + BusIn).
              length [() | NoOutput      <- uses] @?= 2
              length [() | RegionLocal   <- uses] @?= 2
              length [() | RegionEscapes <- uses] @?= 0

      , -- Step C invariant: 'compileRuntimeGraph' never sets
        -- 'rnElided'. Only 'fuseRuntimeGraph' (added later in Step
        -- C) flips the bit. This pins the contract that the unfused
        -- compile path is unchanged in observable behavior by
        -- Step B's machinery additions.
        testCase "compileRuntimeGraph leaves rnElided False on every node" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                a <- gain o (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> all (not . rnElided) (rgNodes rg) @?= True

      , -- Step C (c): chain SinOsc → Gain(Param 0.5) → Out, fused.
        -- Expectations:
        --   * rgNodes length is 3 (no node removed).
        --   * Gain has rnElided = True.
        --   * Out's input is RFused (FScaleFrom sinOsc 0 gain 0).
        --   * SinOsc and Out keep rnElided = False.
        -- See Note [Single-edge Gain fusion].
        testCase "fuseRuntimeGraph: linear chain elides Gain, redirects Out" $ do
          -- Uses an 'Env' source rather than any oscillator because
          -- §4.B's growing kernel set claims every contiguous
          -- @{Sin,Saw} → Gain → sink@ shape today, and (per
          -- 'notes/2026-05-08-e-fusion-strategy.md') is the part of the design
          -- expected to expand. Env is stateful and explicitly
          -- excluded from kernel candidacy in that note, so §4.B
          -- can't claim @Env → Gain → Out@ now or later, and §4.C
          -- gets to do its single-edge Gain elision. The mechanism
          -- under test is unchanged; only the source kind differs.
          let g = runSynth $ do
                o <- env (Param 1.0) 0.0005 0.002 1.0 0.002
                a <- gain o (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              length (rgNodes rg) @?= 3
              let gainNode = head [n | n <- rgNodes rg, rnKind n == KGain]
                  envNode  = head [n | n <- rgNodes rg, rnKind n == KEnv]
                  outNode  = head [n | n <- rgNodes rg, rnKind n == KOut]
              rnElided gainNode @?= True
              rnElided envNode  @?= False
              rnElided outNode  @?= False
              rnInputs outNode @?=
                [ RFused (FScaleFrom (rnIndex envNode) (PortIndex 0)
                                     (rnIndex gainNode) (ControlIndex 0))
                ]

      , -- Audio-modulated Gain ('gain sig modSig') has rnInputs[1] as
        -- RFrom (not RConst), so the shape gate fails and no fusion
        -- happens. This case keeps the Gain dispatched.
        testCase "fuseRuntimeGraph: audio-modulated Gain is left alone" $ do
          let g = runSynth $ do
                sig <- sinOsc 440.0 0.0
                m   <- sinOsc 73.0  0.0
                a   <- gain sig m
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              all (not . rnElided) (rgNodes rg) @?= True
              -- No RFused inputs introduced.
              null [() | n <- rgNodes rg
                       , RFused _ <- rnInputs n
                       ] @?= True

      , -- Fan-out: SinOsc → 2× Gain → 2× Out. Each Gain has a single
        -- consumer (its own Out), so both Gains fuse independently.
        -- The shared SinOsc isn't a Gain candidate, so the chain
        -- walk terminates at SinOsc for both branches and each
        -- fuses as a length-1 'FScaleFrom'.
        testCase "fuseRuntimeGraph: fan-out fuses both Gains independently" $ do
          let g = runSynth $ do
                o  <- sinOsc 440.0 0.0
                g1 <- gain o (Param 0.5)
                g2 <- gain o (Param 0.3)
                out 0 g1
                out 1 g2
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let gains = [n | n <- rgNodes rg, rnKind n == KGain]
                  outs  = [n | n <- rgNodes rg, rnKind n == KOut]
              length gains                          @?= 2
              all rnElided gains                    @?= True
              -- Each Out reads through an RFused.
              [length [() | RFused _ <- rnInputs o] | o <- outs] @?= [1, 1]

      , -- Identity preservation: fusion never reorders, removes, or
        -- renames nodes. rnOriginalID and rnIndex are unchanged
        -- across a (compileRuntimeGraph, compileRuntimeGraphFused)
        -- pair on the same source graph.
        testCase "fuseRuntimeGraph preserves NodeIndex and rnOriginalID" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                a <- gain o (Param 0.5)
                out 0 a
          case (,) <$> (lowerGraph g >>= compileRuntimeGraph)
                   <*> (lowerGraph g >>= compileRuntimeGraphFused) of
            Left err -> assertFailure $ "compile failed: " <> err
            Right (unfused, fused) -> do
              map rnIndex      (rgNodes fused)
                @?= map rnIndex      (rgNodes unfused)
              map rnOriginalID (rgNodes fused)
                @?= map rnOriginalID (rgNodes unfused)
              map rnKind       (rgNodes fused)
                @?= map rnKind       (rgNodes unfused)

      , -- Chain extension: SinOsc → Gain₁(0.5) → Gain₂(0.25) →
        -- Out collapses both scalar Gains into one fused chain on
        -- Out's input. Both Gains are elided; the chain is stored
        -- in source-to-sink order so the resolver applies 0.5
        -- before 0.25 — same float-rounding order as the unfused
        -- chained kernels would.
        testCase "fuseRuntimeGraph: chain of two Gains fuses into FScaleChainFrom" $ do
          let g = runSynth $ do
                o  <- sinOsc 440.0 0.0
                a1 <- gain o  (Param 0.5)
                a2 <- gain a1 (Param 0.25)
                out 0 a2
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              length (rgNodes rg) @?= 4
              let nodes = rgNodes rg
                  sinNode  = head [n | n <- nodes, rnKind n == KSinOsc]
                  gainsExec = [n | n <- nodes, rnKind n == KGain]
                  outNode  = head [n | n <- nodes, rnKind n == KOut]
              length gainsExec @?= 2
              let [gUpstream, gDownstream] = gainsExec
              -- Both Gains are elided; chain ate the whole run.
              rnElided gUpstream   @?= True
              rnElided gDownstream @?= True
              -- Out's input is the chain in source-to-sink order:
              -- SinOsc:0 × gUpstream.c[0] × gDownstream.c[0].
              rnInputs outNode @?=
                [ RFused (FScaleChainFrom (rnIndex sinNode) (PortIndex 0)
                            [ ScaleRef (rnIndex gUpstream)   (ControlIndex 0)
                            , ScaleRef (rnIndex gDownstream) (ControlIndex 0)
                            ])
                ]

      , -- Length-3 chain: SinOsc → G1(0.5) → G2(0.25) → G3(0.125)
        -- → Out. All three Gains elided; chain length 3 in
        -- source-to-sink order.
        testCase "fuseRuntimeGraph: chain of three Gains fuses end-to-end" $ do
          let g = runSynth $ do
                o  <- sinOsc 440.0 0.0
                a1 <- gain o  (Param 0.5)
                a2 <- gain a1 (Param 0.25)
                a3 <- gain a2 (Param 0.125)
                out 0 a3
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes   = rgNodes rg
                  gains   = [n | n <- nodes, rnKind n == KGain]
                  outNode = head [n | n <- nodes, rnKind n == KOut]
              length gains @?= 3
              all rnElided gains @?= True
              case rnInputs outNode of
                [RFused (FScaleChainFrom _ _ scales)] ->
                  length scales @?= 3
                other -> assertFailure $
                  "expected single FScaleChainFrom of length 3, got "
                    <> show other

      , -- Chain stops at audio-modulated Gain. carrier × modulator
        -- (audio-modulated, gate-4 reject) followed by scalar Gain
        -- → Out: only the trailing scalar Gain fuses; the audio-
        -- modulated Gain stays dispatched. Chain length is 1, so
        -- the IR uses FScaleFrom (not FScaleChainFrom) — the chain
        -- terminator is the audio-modulated Gain itself.
        testCase "fuseRuntimeGraph: chain stops at audio-modulated Gain" $ do
          let g = runSynth $ do
                c <- sinOsc 440.0 0.0
                m <- sinOsc  73.0 0.0
                r <- gain c m            -- audio-modulated: not fusable
                a <- gain r (Param 0.5)  -- scalar: fuses
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  gains = [n | n <- nodes, rnKind n == KGain]
              length gains @?= 2
              -- Exactly one Gain elided (the scalar one).
              length [() | n <- gains, rnElided n] @?= 1
              -- Out's input is FScaleFrom (length-1, not chain).
              let outNode = head [n | n <- nodes, rnKind n == KOut]
              case rnInputs outNode of
                [RFused FScaleFrom{}] -> pure ()
                other -> assertFailure $
                  "expected FScaleFrom on Out, got " <> show other

      , -- Mid-chain multi-consumer: a Gain in the middle of what
        -- *would* be a chain has rnConsumerCount > 1 and so fails
        -- the candidate predicate. Chain extension must stop there
        -- and not elide it.
        --
        --   SinOsc → G1(0.5) → { G2(0.25) → Out0,  G3(0.125) → Out1 }
        --
        -- G1 has two consumers (G2 and G3) and is therefore not a
        -- candidate. The two trailing Gains each fuse independently
        -- as length-1 FScaleFrom with G1 as the source — the chain
        -- never grows past G1 because G1 is non-candidate.
        testCase "fuseRuntimeGraph: chain stops at multi-consumer mid-chain Gain" $ do
          let g = runSynth $ do
                o  <- sinOsc 440.0 0.0
                a1 <- gain o (Param 0.5)
                a2 <- gain a1 (Param 0.25)
                a3 <- gain a1 (Param 0.125)
                out 0 a2
                out 1 a3
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  gains = [n | n <- nodes, rnKind n == KGain]
              length gains @?= 3
              -- G1 stays dispatched (consumer count 2). G2 and G3
              -- each fuse as length-1.
              let elidedG = [n | n <- gains, rnElided n]
              length elidedG @?= 2
              -- Both Out nodes carry an RFused FScaleFrom (length-1
              -- chain), not an FScaleChainFrom.
              let outs = [n | n <- nodes, rnKind n == KOut]
              length outs @?= 2
              let isLengthOne (RFused FScaleFrom{}) = True
                  isLengthOne _                     = False
              all isLengthOne (concatMap rnInputs outs) @?= True

      , -- Idempotence: applying the rewrite twice must equal applying
        -- it once. Elided Gains fail the candidate predicate
        -- (rnElided check) on the second pass, so nothing changes.
        testCase "fuseRuntimeGraph is idempotent" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                a <- gain o (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              fuseRuntimeGraph (fuseRuntimeGraph rg) @?= fuseRuntimeGraph rg

      , -- Chain idempotence: a second pass over an already-fused
        -- chain must be a no-op. After the first pass every Gain
        -- in the chain is rnElided (failing gate 4 of the candidate
        -- predicate via 'not (rnElided n)'), and the consumer's
        -- input is RFused (which 'tryFuseInput' ignores since it
        -- only matches RFrom). Pinned separately from the length-1
        -- idempotence test so a regression in chain handling
        -- doesn't masquerade as the single-edge bug.
        testCase "fuseRuntimeGraph is idempotent on chains" $ do
          let g = runSynth $ do
                o  <- sinOsc 440.0 0.0
                a1 <- gain o  (Param 0.5)
                a2 <- gain a1 (Param 0.25)
                a3 <- gain a2 (Param 0.125)
                out 0 a3
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              fuseRuntimeGraph (fuseRuntimeGraph rg) @?= fuseRuntimeGraph rg

      , -- Phase 4.C.2: a single scalar Add with a constant bias on
        -- port 1 elides the Add and rewrites Out's input to
        -- 'FAffineFrom' with one 'AffBias' step. The pure-scale
        -- 'FScaleFrom' / 'FScaleChainFrom' shapes are reserved for
        -- chains that are entirely Gains, so any presence of a bias
        -- step lands in 'FAffineFrom'.
        testCase "fuseRuntimeGraph: scalar Add (bias on port 1) fuses into FAffineFrom" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                b <- add o (Param 0.1)   -- bias on port 1
                out 0 b
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  sinNode = head [n | n <- nodes, rnKind n == KSinOsc]
                  addNode = head [n | n <- nodes, rnKind n == KAdd]
                  outNode = head [n | n <- nodes, rnKind n == KOut]
              rnElided addNode @?= True
              rnInputs outNode @?=
                [ RFused (FAffineFrom (rnIndex sinNode) (PortIndex 0)
                            [ AffBias (rnIndex addNode) (ControlIndex 1) ])
                ]

      , -- Bias on port 0: 'add (Param 0.1) signal' lowers to
        -- @rnInputs == [RConst 0.1, RFrom signal 0]@, signal port
        -- is 1, bias control slot is 0. The candidate predicate
        -- accepts both shapes; the AffBias must record control 0
        -- in this case so the runtime reads the right slot.
        testCase "fuseRuntimeGraph: scalar Add (bias on port 0) fuses with control 0" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                b <- add (Param 0.1) o   -- bias on port 0
                out 0 b
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  sinNode = head [n | n <- nodes, rnKind n == KSinOsc]
                  addNode = head [n | n <- nodes, rnKind n == KAdd]
                  outNode = head [n | n <- nodes, rnKind n == KOut]
              rnElided addNode @?= True
              -- Source signal port from the Add's input[1]; bias
              -- control is slot 0 (where the Param literal landed).
              rnInputs outNode @?=
                [ RFused (FAffineFrom (rnIndex sinNode) (PortIndex 0)
                            [ AffBias (rnIndex addNode) (ControlIndex 0) ])
                ]

      , -- Audio-rate Add (signal + signal) is not a candidate. The
        -- gate enforces "exactly one signal input, the other slot a
        -- constant"; @add c m@ with both audio sources fails it,
        -- exactly like audio-modulated Gain stays dispatched.
        testCase "fuseRuntimeGraph: audio-rate Add stays dispatched" $ do
          let g = runSynth $ do
                c <- sinOsc 440.0 0.0
                m <- sinOsc  73.0 0.0
                s <- add c m            -- audio + audio: not fusable
                out 0 s
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  addNode = head [n | n <- nodes, rnKind n == KAdd]
              rnElided addNode @?= False
              -- No RFused inputs introduced.
              null [() | n <- nodes, RFused _ <- rnInputs n] @?= True

      , -- Composition order 1: SinOsc → Gain(k) → Add(b) → Out
        -- collapses both into one FAffineFrom with [AffScale k,
        -- AffBias b] in source-to-sink order. The resolver applies
        -- src*k first, then +b, mirroring the unfused kernel chain.
        testCase "fuseRuntimeGraph: Gain → Add composes into AffineFrom [scale, bias]" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                a <- gain o (Param 0.5)
                b <- add  a (Param 0.1)
                out 0 b
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  sinNode  = head [n | n <- nodes, rnKind n == KSinOsc]
                  gainNode = head [n | n <- nodes, rnKind n == KGain]
                  addNode  = head [n | n <- nodes, rnKind n == KAdd]
                  outNode  = head [n | n <- nodes, rnKind n == KOut]
              rnElided gainNode @?= True
              rnElided addNode  @?= True
              rnInputs outNode @?=
                [ RFused (FAffineFrom (rnIndex sinNode) (PortIndex 0)
                            [ AffScale (rnIndex gainNode) (ControlIndex 0)
                            , AffBias  (rnIndex addNode)  (ControlIndex 1)
                            ])
                ]

      , -- Composition order 2: SinOsc → Add(b) → Gain(k) → Out
        -- collapses to FAffineFrom [AffBias b, AffScale k]. The
        -- resolver applies +b first, then *k, matching the unfused
        -- chain's float arithmetic. Pinning both orderings catches
        -- any "scales always come before biases" sorting bug.
        testCase "fuseRuntimeGraph: Add → Gain composes into AffineFrom [bias, scale]" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                b <- add  o (Param 0.1)
                a <- gain b (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  sinNode  = head [n | n <- nodes, rnKind n == KSinOsc]
                  gainNode = head [n | n <- nodes, rnKind n == KGain]
                  addNode  = head [n | n <- nodes, rnKind n == KAdd]
                  outNode  = head [n | n <- nodes, rnKind n == KOut]
              rnElided gainNode @?= True
              rnElided addNode  @?= True
              rnInputs outNode @?=
                [ RFused (FAffineFrom (rnIndex sinNode) (PortIndex 0)
                            [ AffBias  (rnIndex addNode)  (ControlIndex 1)
                            , AffScale (rnIndex gainNode) (ControlIndex 0)
                            ])
                ]

      , -- Mid-chain multi-consumer Add: an Add in the middle of
        -- what would be a chain fails gate 3 (rnConsumerCount > 1)
        -- and stays dispatched. The downstream chain segments still
        -- fuse independently.
        testCase "fuseRuntimeGraph: chain stops at multi-consumer mid-chain Add" $ do
          let g = runSynth $ do
                o  <- sinOsc 440.0 0.0
                b  <- add o (Param 0.1)        -- shared by both branches
                g1 <- gain b (Param 0.5)
                g2 <- gain b (Param 0.25)
                out 0 g1
                out 1 g2
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  addNode = head [n | n <- nodes, rnKind n == KAdd]
              -- Add stays dispatched (consumer count 2).
              rnElided addNode @?= False
              -- Both Gains elided; both Outs read through FScaleFrom
              -- (length-1 scale-only chain stops at the dispatched Add).
              let gains = [n | n <- nodes, rnKind n == KGain]
              length [() | n <- gains, rnElided n] @?= 2
              let outs = [n | n <- nodes, rnKind n == KOut]
                  isFScaleFrom (RFused FScaleFrom{}) = True
                  isFScaleFrom _                      = False
              all isFScaleFrom (concatMap rnInputs outs) @?= True

      , -- Affine idempotence: a second pass over an already-fused
        -- mixed Gain/Add chain must be a no-op. Same gate-9 check
        -- as the chain-idempotence pin from §4.C.1, but on a chain
        -- that exercises the FAffineFrom path.
        testCase "fuseRuntimeGraph is idempotent on affine chains" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                a <- gain o (Param 0.5)
                b <- add  a (Param 0.1)
                k <- gain b (Param 0.25)
                out 0 k
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              fuseRuntimeGraph (fuseRuntimeGraph rg) @?= fuseRuntimeGraph rg

      , -- Step C precondition: pin Gain's compiled shape so the
        -- single-edge fusion rewrite has something stable to match
        -- against. For 'gain o (Param k)':
        --   * rnInputs[0] is RFrom <o's index> 0 — the audio signal.
        --   * rnInputs[1] is RConst k          — the gain port is
        --     unconnected; the literal flows to the C++ control slot
        --     and the kernel takes its else-branch reading
        --     controls[0]. set_control(gainNode, 0, _) is therefore
        --     observable on the unfused output, which is what makes
        --     the fused form's (gainNode, ControlIndex 0) reference
        --     semantically equivalent.
        --   * rnControls is [k] — connDefault pulls the Param's value
        --     into the single Gain control slot.
        -- See connDefault and ugenView in MetaSonic.Bridge.Source.
        testCase "Gain's compiled IR shape pins Step-C fusion preconditions" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                a <- gain o (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              case [n | n <- rgNodes rg, rnKind n == KGain] of
                [gn] -> do
                  rnControls gn @?= [0.5]
                  case rnInputs gn of
                    [RFrom _ (PortIndex 0), RConst 0.5] -> pure ()
                    other -> assertFailure $
                      "unexpected rnInputs shape: " <> show other
                gns -> assertFailure $
                  "expected exactly one Gain node, got " <> show (length gns)
      ]

  , -- Phase 4.B region kernel selection. The greedy 'formRegions'
    -- lumps a whole rate-compatible chain into one region;
    -- 'selectRegionKernels' splits it so each matched contiguous
    -- shape becomes its own kernel-tagged region. This test group
    -- pins the IR-level region overlay; the FFI / C++ side is
    -- exercised by the bit-equivalence battery below.
    testGroup "Phase 4.B: selectRegionKernels"
      [ -- 4-node sink-terminal claim. The whole chain
        -- @[SawOsc, LPF, Gain, Out]@ is contiguous, the 4-node
        -- match wins by longest-match priority over the 3-node
        -- 'RSawLpfGain' prefix, and the entire chain becomes one
        -- 'RSawLpfGainOut' region. Pinning this is the structural
        -- evidence that 'findKernelMatch' actually preferred the
        -- longer shape.
        testCase "saw → lpf → gain → out: full region tagged RSawLpfGainOut" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              -- 4-node match wins; the 3-node prefix shape never
              -- gets to claim anything.
              length [() | RSawLpfGainOut <- kernels] @?= 1
              length [() | RSawLpfGain    <- kernels] @?= 0
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RSawLpfGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 4
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KSawOsc, KLPF, KGain, KOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- BusOut as sink terminal. The 4-node 'RSawLpfGainOut'
        -- shape accepts either 'KOut' or 'KBusOut' at the
        -- terminal slot — same reasoning as the 3-node sink
        -- variant. Pins that the kind-sequence assertion still
        -- tags as RSawLpfGainOut and that no buffer-terminal
        -- 'RSawLpfGain' fallback sneaks in.
        testCase "saw → lpf → gain → busOut: full region tagged RSawLpfGainOut" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                busOut 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RSawLpfGainOut <- kernels] @?= 1
              length [() | RSawLpfGain    <- kernels] @?= 0
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RSawLpfGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 4
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KSawOsc, KLPF, KGain, KBusOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- 3-node buffer-terminal claim with a non-sink consumer.
        -- The chain feeds the gain into an 'Add' instead of into
        -- a sink ('KOut' or 'KBusOut'), so the 4-node
        -- 'RSawLpfGainOut' shape's @rnKind out_ ∈ {KOut, KBusOut}@
        -- gate fails. Longest-match falls through to 'RSawLpfGain'
        -- on the 3-node prefix; the Add and Out land in a
        -- trailing 'RNodeLoop' region. Pins that 'RSawLpfGain' is
        -- still alive after longest-match priority redirected the
        -- saw → lpf → gain → out fixture to the 4-node kernel,
        -- and that the test fixture is robust to sink-class
        -- generalizations like @busOut@ joining @out@ as a sink
        -- terminal.
        testCase "saw → lpf → gain → add → out: middle region tagged RSawLpfGain" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)        -- non-sink consumer of gain
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RSawLpfGain    <- kernels] @?= 1
              length [() | RSawLpfGainOut <- kernels] @?= 0
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RSawLpfGain] of
                [r] -> do
                  length (rrNodes r) @?= 3
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KSawOsc, KLPF, KGain]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- §4.C interaction (4-node kernel): when §4.B's 4-node
        -- 'RSawLpfGainOut' claims the chain, §4.C must skip the
        -- Gain. Otherwise scalar Gain fusion would elide it and
        -- the region kernel would have no live gain to read
        -- 'controls[0]' from.
        testCase "fuseRuntimeGraph: defers to region kernel on saw → lpf → gain → out" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              -- The Gain stays dispatched (rnElided = False) and
              -- nobody carries an RFused — §4.B owns it.
              let gainNode = head [n | n <- rgNodes rg, rnKind n == KGain]
              rnElided gainNode @?= False
              null [() | n <- rgNodes rg, RFused _ <- rnInputs n] @?= True

      , -- Negative: audio-modulated gain blocks §4.B (gain port 1
        -- is RFrom, not RConst). The region stays RNodeLoop.
        testCase "near-miss: audio-modulated gain stays RNodeLoop" $ do
          let g = runSynth $ do
                s   <- sawOsc 110.0 0.0
                f   <- lpf s (Param 800.0) (Param 4.0)
                lfo <- sinOsc 6.0 0.0
                a   <- gain f lfo            -- audio-rate gain modulation
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              null [() | RSawLpfGain <- map rrKernel (rgRuntimeRegions rg)]
                @?= True

      , -- Negative: an extra consumer of the LPF intermediate
        -- (lpf has rnConsumerCount > 1) blocks §4.B because the
        -- fused kernel can't keep lpf's output in registers — the
        -- second consumer needs a materialized buffer.
        testCase "near-miss: lpf with multiple consumers stays RNodeLoop" $ do
          let g = runSynth $ do
                s  <- sawOsc 110.0 0.0
                f  <- lpf s (Param 800.0) (Param 4.0)
                a1 <- gain f (Param 0.4)
                a2 <- gain f (Param 0.2)     -- second consumer of lpf
                out 0 a1
                out 1 a2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              null [() | RSawLpfGain <- map rrKernel (rgRuntimeRegions rg)]
                @?= True

      , -- Negative: a saw whose output is also read by something
        -- outside the chain (saw rnConsumerCount > 1) blocks §4.B.
        -- The lpf's freq input here is wired to the saw, which is
        -- a real audio-rate filter sweep but also makes saw a
        -- multi-consumer node — so the fused kernel can't elide
        -- saw's output materialization.
        testCase "near-miss: saw with multiple consumers stays RNodeLoop" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                -- saw feeds lpf signal AND lpf cutoff (consumer count 2)
                f <- lpf s s (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              null [() | RSawLpfGain <- map rrKernel (rgRuntimeRegions rg)]
                @?= True

      , -- 3-node sink-terminal saw kernel: SawOsc → Gain → Out is
        -- the saw counterpart of 'RSinGainOut'. Same single-edge,
        -- scalar-gain rules; same Out-or-BusOut sink class. Pinned
        -- because the previous "near-miss: saw → gain (no LPF)"
        -- test asserted /no/ kernel claimed this shape — that
        -- assertion was the right contract before 'RSawGainOut'
        -- existed and is now exactly inverted.
        testCase "saw → gain → out: middle region tagged RSawGainOut" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                a <- gain s (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RSawGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RSawGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 3
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KSawOsc, KGain, KOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- BusOut as sink terminal for the saw 3-node kernel —
        -- mirrors the parallel test for 'RSinGainOut'. Pins that
        -- 'isSinkTerminal' / 'is_sink_terminal' propagates to the
        -- new kernel's gate.
        testCase "saw → gain → busOut: middle region tagged RSawGainOut" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                a <- gain s (Param 0.4)
                busOut 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RSawGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RSawGainOut] of
                [r] -> do
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KSawOsc, KGain, KBusOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- §4.C deferral on the new kernel: with §4.B claiming the
        -- whole chain, §4.C must skip the Gain. Otherwise scalar
        -- Gain fusion would elide it and 'process_region_saw_gain_out'
        -- would lose its live read of @gain_node.controls[0]@.
        -- Mirrors the SinGainOut deferral test.
        testCase "fuseRuntimeGraph: defers to §4.B kernel on saw → gain → out" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                a <- gain s (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let gainNode = head [n | n <- rgNodes rg, rnKind n == KGain]
              rnElided gainNode @?= False
              null [() | n <- rgNodes rg, RFused _ <- rnInputs n] @?= True

      , -- 3-node sink-terminal noise kernel: NoiseGen → Gain →
        -- Out. Different state class from the oscillator sink
        -- kernels (xorshift PRNG, no audio inputs, no controls
        -- on the producer), but the matcher's structural gates
        -- are identical — only the producer kind changes.
        testCase "noise → gain → out: middle region tagged RNoiseGainOut" $ do
          let g = runSynth $ do
                n <- noiseGen
                a <- gain n (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RNoiseGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RNoiseGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 3
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KNoiseGen, KGain, KOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- BusOut as sink terminal for the noise 3-node kernel —
        -- mirrors the Sin and Saw busOut variants.
        testCase "noise → gain → busOut: middle region tagged RNoiseGainOut" $ do
          let g = runSynth $ do
                n <- noiseGen
                a <- gain n (Param 0.4)
                busOut 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RNoiseGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RNoiseGainOut] of
                [r] -> do
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KNoiseGen, KGain, KBusOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- §4.C deferral on the noise kernel: with §4.B claiming
        -- the chain, §4.C must skip the Gain. Mirrors the Sin /
        -- Saw deferral tests; the kernel's per-block read of
        -- @gain_node.controls[0]@ depends on the gain staying
        -- live in the runtime graph.
        testCase "fuseRuntimeGraph: defers to §4.B kernel on noise → gain → out" $ do
          let g = runSynth $ do
                n <- noiseGen
                a <- gain n (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let gainNode = head [n | n <- rgNodes rg, rnKind n == KGain]
              rnElided gainNode @?= False
              null [() | n <- rgNodes rg, RFused _ <- rnInputs n] @?= True

      , -- 4-node-specific gate: 'matchesSawLpfGainOut' adds
        -- 'rnConsumerCount gain == 1' on top of 'matchesSawLpfGain'.
        -- A graph where the gain feeds two Outs satisfies the
        -- 3-node prefix predicate but fails the 4-node gain-
        -- consumer rule, so longest-match fails over from
        -- 'RSawLpfGainOut' to 'RSawLpfGain'. Pinned because this is
        -- the structural property that justifies keeping both
        -- kernels — the 3-node one materializes the gain's output
        -- buffer for external readers, the 4-node one absorbs the
        -- single Out and skips materialization.
        testCase "fallback: multi-consumer gain falls through from RSawLpfGainOut to RSawLpfGain" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
                out 1 a                    -- second consumer of gain
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RSawLpfGain    <- kernels] @?= 1
              length [() | RSawLpfGainOut <- kernels] @?= 0

      , -- 4-node negative: audio-modulated gain blocks both the
        -- 4-node kernel AND the 3-node fallback (both gates
        -- require 'isScalarGain'), so the whole chain stays
        -- 'RNodeLoop'. Distinct from the 3-node-only audio-mod
        -- near-miss above because it specifically pins the 4-node
        -- shape's behavior on the same blocker.
        testCase "near-miss (4-node): audio-modulated gain stays RNodeLoop" $ do
          let g = runSynth $ do
                s   <- sawOsc 110.0 0.0
                f   <- lpf s (Param 800.0) (Param 4.0)
                lfo <- sinOsc 6.0 0.0
                a   <- gain f lfo            -- audio-rate gain modulation
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RSawLpfGainOut <- kernels] @?= True
              null [() | RSawLpfGain    <- kernels] @?= True

      , -- §4.B BusIn-rooted 4-node sink-terminal claim.
        -- @[BusIn, LPF, Gain, Out]@ matches 'matchesBusInLpfGainOut'
        -- and the whole chain becomes one 'RBusInLpfGainOut' region.
        -- Same longest-match-wins structural property as
        -- 'RSawLpfGainOut' but on the non-oscillator producer axis.
        testCase "busIn → lpf → gain → out: full region tagged RBusInLpfGainOut" $ do
          let g = runSynth $ do
                r <- busIn 7
                f <- lpf r (Param 1500.0) (Param 4.0)
                a <- gain f (Param 0.6)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RBusInLpfGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg
                      , rrKernel r == RBusInLpfGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 4
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KBusIn, KLPF, KGain, KOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got "
                  <> show (length rs)

      , -- BusOut as sink terminal for the BusIn-rooted shape.
        -- Pins that the kind-sequence assertion still tags as
        -- 'RBusInLpfGainOut' regardless of whether the absorbed
        -- terminal is 'KOut' or 'KBusOut'.
        testCase "busIn → lpf → gain → busOut: full region tagged RBusInLpfGainOut" $ do
          let g = runSynth $ do
                r <- busIn 7
                f <- lpf r (Param 1500.0) (Param 4.0)
                a <- gain f (Param 0.6)
                busOut 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RBusInLpfGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg
                      , rrKernel r == RBusInLpfGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 4
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KBusIn, KLPF, KGain, KBusOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got "
                  <> show (length rs)

      , -- Near-miss: BusIn fans out to two consumers. The single-
        -- use internal-edge precondition on the BusIn fails, so
        -- the 4-node match is rejected. Without an LPF-rooted
        -- 3-node fallback (we don't have one), the chain stays
        -- 'RNodeLoop'. Pins that the multi-consumer gate is the
        -- BusIn counterpart of 'matchesSawLpfGainOut's
        -- 'rnConsumerCount saw == 1' rule.
        testCase "near-miss: multi-consumer BusIn blocks RBusInLpfGainOut" $ do
          let g = runSynth $ do
                r  <- busIn 7
                f1 <- lpf r (Param 800.0)  (Param 4.0)
                f2 <- lpf r (Param 2400.0) (Param 4.0)   -- second consumer of busIn
                a1 <- gain f1 (Param 0.4); out 0 a1
                a2 <- gain f2 (Param 0.4); out 1 a2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RBusInLpfGainOut <- kernels] @?= True

      , -- Near-miss: audio-modulated gain in a BusIn-rooted chain.
        -- 'isScalarGain' fails on the gain, so the 4-node kernel
        -- doesn't fire. Mirrors the audio-mod near-miss pinned for
        -- 'RSawLpfGainOut'.
        testCase "near-miss (BusIn): audio-modulated gain stays RNodeLoop" $ do
          let g = runSynth $ do
                r   <- busIn 7
                f   <- lpf r (Param 1500.0) (Param 4.0)
                lfo <- sinOsc 6.0 0.0
                a   <- gain f lfo                    -- audio-rate gain modulation
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RBusInLpfGainOut <- kernels] @?= True

      , -- Near-miss: the chain ends at a non-sink consumer (Add),
        -- so 'isSinkTerminal' on the terminal slot fails and the
        -- 4-node match is rejected. Without an LPF-rooted 3-node
        -- fallback for the BusIn-rooted shape, the chain stays
        -- 'RNodeLoop'. Pins that the sink-class gate distinguishes
        -- 'RBusInLpfGainOut' from a hypothetical "BusIn-rooted
        -- buffer-terminal" kernel.
        testCase "near-miss (BusIn): non-sink terminal stays RNodeLoop" $ do
          let g = runSynth $ do
                r <- busIn 7
                f <- lpf r (Param 1500.0) (Param 4.0)
                a <- gain f (Param 0.6)
                b <- add a (Param 0.0)              -- non-sink consumer
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RBusInLpfGainOut <- kernels] @?= True

      , -- §4.C interaction (BusIn-rooted 4-node kernel): when
        -- §4.B's 'RBusInLpfGainOut' claims the chain, §4.C must
        -- skip the Gain. Otherwise scalar-Gain elision would
        -- eliminate the live control slot the kernel reads
        -- 'controls[0]' from. Mirrors the §4.C-deferral pin for
        -- 'RSawLpfGainOut'.
        testCase "fuseRuntimeGraph: defers to RBusInLpfGainOut on busIn → lpf → gain → out" $ do
          let g = runSynth $ do
                r <- busIn 7
                f <- lpf r (Param 1500.0) (Param 4.0)
                a <- gain f (Param 0.6)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "fused compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RBusInLpfGainOut <- kernels] @?= 1
              -- The Gain is a member of the kernel's region, not
              -- elided by §4.C (otherwise the kernel would have no
              -- live control slot to read 'controls[0]' from).
              let elidedKinds =
                    [rnKind n | n <- rgNodes rg, rnElided n]
              KGain `elem` elidedKinds @?= False

      , -- §4.B Noise-rooted 4-node sink-terminal claim. The noise
        -- counterpart of 'RSawLpfGainOut' / 'RBusInLpfGainOut': same
        -- LPF/Gain/sink pipeline, but the producer is a PRNG-state
        -- generator, not a phase iterator or bus reader. Pins that
        -- 'matchesNoiseLpfGainOut' fires on @[NoiseGen, LPF, Gain,
        -- Out]@ and that the whole chain becomes one region tagged
        -- 'RNoiseLpfGainOut'.
        testCase "noise → lpf → gain → out: full region tagged RNoiseLpfGainOut" $ do
          let g = runSynth $ do
                n <- noiseGen
                f <- lpf n (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RNoiseLpfGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg
                      , rrKernel r == RNoiseLpfGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 4
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KNoiseGen, KLPF, KGain, KOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got "
                  <> show (length rs)

      , -- BusOut as sink terminal for the Noise-rooted shape. Same
        -- bus-kind-agnostic claim the kernel makes on the C++ side.
        testCase "noise → lpf → gain → busOut: full region tagged RNoiseLpfGainOut" $ do
          let g = runSynth $ do
                n <- noiseGen
                f <- lpf n (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                busOut 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RNoiseLpfGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg
                      , rrKernel r == RNoiseLpfGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 4
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KNoiseGen, KLPF, KGain, KBusOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got "
                  <> show (length rs)

      , -- Near-miss: NoiseGen feeds two consumers, breaking the
        -- single-use-edge gate at the head. The 4-node kernel is
        -- rejected; with no Noise-rooted fallback the chain stays
        -- 'RNodeLoop'. Pins that the multi-consumer gate is the
        -- noise counterpart of the saw / busin rule.
        testCase "near-miss: multi-consumer NoiseGen blocks RNoiseLpfGainOut" $ do
          let g = runSynth $ do
                n  <- noiseGen
                f1 <- lpf n (Param 800.0)  (Param 4.0)
                f2 <- lpf n (Param 2400.0) (Param 4.0)   -- second consumer of noise
                a1 <- gain f1 (Param 0.4); out 0 a1
                a2 <- gain f2 (Param 0.4); out 1 a2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RNoiseLpfGainOut <- kernels] @?= True

      , -- Near-miss: LPF feeds two Gains. Same 'rnConsumerCount lpf
        -- == 1' precondition that blocks the saw-rooted variant.
        testCase "near-miss (Noise): multi-consumer LPF blocks RNoiseLpfGainOut" $ do
          let g = runSynth $ do
                n  <- noiseGen
                f  <- lpf n (Param 1000.0) (Param 4.0)
                a1 <- gain f (Param 0.3); out 0 a1
                a2 <- gain f (Param 0.2); out 1 a2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RNoiseLpfGainOut <- kernels] @?= True

      , -- Near-miss: audio-modulated gain in a Noise-rooted chain.
        -- 'isScalarGain' fails on the gain, the 4-node kernel
        -- doesn't fire. Mirrors the audio-mod near-miss pinned for
        -- the saw / busin variants.
        testCase "near-miss (Noise): audio-modulated gain stays RNodeLoop" $ do
          let g = runSynth $ do
                n   <- noiseGen
                f   <- lpf n (Param 1500.0) (Param 4.0)
                lfo <- sinOsc 6.0 0.0
                a   <- gain f lfo                    -- audio-rate gain modulation
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RNoiseLpfGainOut <- kernels] @?= True

      , -- Near-miss: chain ends at a non-sink consumer (Add). The
        -- sink-class gate fails; without a Noise-rooted buffer-
        -- terminal kernel the chain stays 'RNodeLoop'. Mirrors the
        -- non-sink near-miss pinned for the busin variant.
        testCase "near-miss (Noise): non-sink terminal stays RNodeLoop" $ do
          let g = runSynth $ do
                n <- noiseGen
                f <- lpf n (Param 1500.0) (Param 4.0)
                a <- gain f (Param 0.6)
                b <- add a (Param 0.0)              -- non-sink consumer
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RNoiseLpfGainOut <- kernels] @?= True

      , -- §4.C interaction (Noise-rooted 4-node kernel): same Gain-
        -- elision deferral as 'RSawLpfGainOut' / 'RBusInLpfGainOut'.
        -- The kernel reads gain 'controls[0]', so §4.C must leave
        -- the Gain in place when the kernel claims the chain.
        testCase "fuseRuntimeGraph: defers to RNoiseLpfGainOut on noise → lpf → gain → out" $ do
          let g = runSynth $ do
                n <- noiseGen
                f <- lpf n (Param 1500.0) (Param 4.0)
                a <- gain f (Param 0.6)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "fused compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RNoiseLpfGainOut <- kernels] @?= 1
              let elidedKinds =
                    [rnKind n | n <- rgNodes rg, rnElided n]
              KGain `elem` elidedKinds @?= False

      , -- Idempotence: a second pass over an already-tagged region
        -- must be a no-op. Pinned because 'selectRegionKernels'
        -- recurses on splits and a regression that re-fires on
        -- already-tagged regions would silently double-walk the
        -- region list.
        testCase "selectRegionKernels is idempotent" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              selectRegionKernels rg @?= rg

      , -- Phase 4.B sink-terminal: SinOsc → Gain → Out is the second
        -- recognized kernel shape. Distinct protocol axis from
        -- 'RSawLpfGain' (which is buffer-terminal): the 'Out' node
        -- lives /inside/ the fused region, so the kernel does the
        -- bus accumulation and §2.E sink-peak update inline rather
        -- than materializing an intermediate buffer.
        testCase "sin → gain → out: middle region tagged RSinGainOut" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              -- Exactly one fused region and it covers the whole
              -- chain (no trailing 'RNodeLoop' region for an
              -- external Out, because the Out is now a kernel
              -- member).
              length [() | RSinGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RSinGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 3
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KSinOsc, KGain, KOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- BusOut as sink terminal. 'RSinGainOut' accepts either
        -- 'KOut' or 'KBusOut' at the terminal slot — both
        -- dispatch to 'process_out' on the C++ side and read the
        -- bus index from @rnControls[0]@, so the kernel body
        -- absorbs them identically. Pins that the Haskell-side
        -- 'isSinkTerminal' gate accepts BusOut and that the
        -- region's kind sequence still tags as RSinGainOut.
        testCase "sin → gain → busOut: middle region tagged RSinGainOut" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                busOut 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RSinGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RSinGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 3
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KSinOsc, KGain, KBusOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- §4.C interaction: §4.B claims this shape /before/ §4.C
        -- runs. Without that claim, §4.C would elide the Gain into
        -- an 'FScaleFrom' on Out's input (the original §4.C
        -- behavior for sin → gain → out). Pinned because the
        -- region kernel needs the Gain's control slot still
        -- addressable, so eliding it would silently break
        -- 'process_region_sin_gain_out''s read of
        -- @gain_node.controls[0]@.
        testCase "fuseRuntimeGraph: defers to §4.B kernel on sin → gain → out" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let gainNode = head [n | n <- rgNodes rg, rnKind n == KGain]
              rnElided gainNode @?= False
              null [() | n <- rgNodes rg, RFused _ <- rnInputs n] @?= True

      , -- Negative: audio-modulated gain blocks the kernel for the
        -- same reason it blocks 'RSawLpfGain' — the per-sample
        -- arithmetic can no longer be folded into the same float
        -- rounding sequence as the unfused chain.
        testCase "near-miss (sin chain): audio-modulated gain stays RNodeLoop" $ do
          let g = runSynth $ do
                s   <- sinOsc 440.0 0.0
                lfo <- sinOsc 6.0 0.0
                a   <- gain s lfo            -- audio-rate gain modulation
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              null [() | RSinGainOut <- map rrKernel (rgRuntimeRegions rg)]
                @?= True

      , -- Negative: a SinOsc with multiple consumers can't be
        -- claimed by the kernel because the second consumer needs
        -- the SinOsc's output materialized, but the kernel keeps
        -- it in registers.
        testCase "near-miss (sin chain): multi-consumer sin stays RNodeLoop" $ do
          let g = runSynth $ do
                s  <- sinOsc 440.0 0.0
                a1 <- gain s (Param 0.5)
                a2 <- gain s (Param 0.3)     -- second consumer of sin
                out 0 a1
                out 1 a2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              null [() | RSinGainOut <- map rrKernel (rgRuntimeRegions rg)]
                @?= True

      , -- Negative: a Gain whose output feeds two Outs has consumer
        -- count 2 — the kernel's "single internal edge" rule
        -- rejects it, exactly the way 'RSawLpfGain' rejects an LPF
        -- with multiple consumers.
        testCase "near-miss (sin chain): multi-consumer gain stays RNodeLoop" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
                out 1 a                       -- second consumer of gain
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              null [() | RSinGainOut <- map rrKernel (rgRuntimeRegions rg)]
                @?= True

      , -- Multi-match: two independent saw → lpf → gain chains in
        -- one original region must both be tagged in a single
        -- 'selectRegionKernels' pass. The selector recurses on the
        -- suffix after each match, so missing the second chain
        -- would mean an optimization that depends on the loader
        -- accidentally re-running the pass. Idempotence still
        -- holds: a second 'selectRegionKernels' application is a
        -- no-op on the already-tagged result.
        --
        -- Why each chain tags as 'RSawLpfGain' rather than the
        -- longer 'RSawLpfGainOut': the topo sort emits both
        -- sinks at the /end/ of the region, after both
        -- saw/lpf/gain triples. Each gain's sink consumer is
        -- therefore not contiguous with the prefix, so the
        -- 4-node 'RSawLpfGainOut' shape's contiguity gate
        -- (gainIx feeds the next listed member) fails for each
        -- chain and longest-match falls through to the 3-node
        -- 'RSawLpfGain'. 'busOut' vs 'out' is incidental here —
        -- either sink kind produces the same trace because the
        -- topo-order clumping is what breaks contiguity, not the
        -- terminal kind.
        testCase "two chains in one region: both tagged in one pass" $ do
          let g = runSynth $ do
                s1 <- sawOsc 110.0 0.0
                f1 <- lpf s1 (Param 800.0) (Param 4.0)
                a1 <- gain f1 (Param 0.4)
                s2 <- sawOsc 220.0 0.0
                f2 <- lpf s2 (Param 1200.0) (Param 4.0)
                a2 <- gain f2 (Param 0.3)
                busOut 0 a1
                busOut 1 a2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              -- Both chains must come back tagged from one pass.
              let tagged = [ r | r <- rgRuntimeRegions rg
                               , rrKernel r == RSawLpfGain ]
              length tagged @?= 2
              -- Each tagged region must cover exactly its own three
              -- nodes in the canonical [Saw, LPF, Gain] order — no
              -- accidental cross-chain claim.
              let nodeMap = M.fromList
                    [ (rnIndex n, n) | n <- rgNodes rg ]
                  kindsOf r =
                    [ rnKind n
                    | ix <- rrNodes r
                    , Just n <- [M.lookup ix nodeMap] ]
              mapM_ (\r -> do
                        length (rrNodes r) @?= 3
                        kindsOf r @?= [KSawOsc, KLPF, KGain])
                    tagged
              -- Idempotence on the multi-match result: re-running
              -- 'selectRegionKernels' after both chains have already
              -- been claimed must not split or relabel anything.
              selectRegionKernels rg @?= rg
      ]

  , -- Phase 4.E.1 + 4.E.1b: per-region BusFootprint metadata plus
    -- the dependency views consumed by future scheduling work.
    -- 'regionBusPrecedence' is the bus-only edge subgraph;
    -- 'regionStructuralPrecedence' is the cross-region port edges
    -- introduced by 'selectRegionKernels' splits;
    -- 'regionDependencies' is the union — the actual "must
    -- precede" relation. No runtime behavior change in either
    -- slice — 'compileRuntimeGraph' still produces regions in the
    -- same topologically valid order; the tests pin the metadata
    -- only. See Note [Region dependency contract] in
    -- 'MetaSonic.Bridge.Compile' for why both edge classes
    -- matter.
    testGroup "Phase 4.E.1: per-region BusFootprint and dependencies"
      [ -- Single-region baseline: a sin → gain → out chain claims
        -- 'RSinGainOut' as one region. Footprint writes only the
        -- sink bus; no reads of any kind. Both views are empty
        -- for this region (no other region exists, no port edges
        -- to cross, no read sets to intersect against).
        testCase "single-region chain: footprint writes {0}, no reads, empty deps" $ do
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

      , -- Internal send/return: a sin → busOut 5 producer chain
        -- followed by a busIn 5 → lpf → gain → out 0 consumer
        -- chain. §4.B's longest-match priority claims the consumer
        -- chain as 'RBusInLpfGainOut' and 'selectRegionKernels'
        -- splits the source region into a producer 'RNodeLoop'
        -- region (sin + busOut) and a consumer kernel region.
        --
        -- The footprints must reflect the split: producer writes
        -- bus 5; consumer reads bus 5 and writes bus 0. The
        -- consumer's dependency on the producer is /bus-borne/
        -- here — there's no port edge crossing the region
        -- boundary (the consumer's first node is BusIn, which has
        -- no audio inputs). 'regionBusPrecedence' must capture
        -- the edge; 'regionDependencies' must agree.
        testCase "internal send/return: consumer region depends on producer (bus edge)" $ do
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
              -- Identify the two regions by their kernel tags:
              -- producer is RNodeLoop (sin + busOut not a §4.B
              -- shape), consumer is RBusInLpfGainOut.
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
                  -- Bus edge present.
                  M.findWithDefault S.empty (rrIndex c) busPrec
                    @?= S.singleton (rrIndex p)
                  -- BusIn has no audio inputs, so no port edge
                  -- crosses from producer to consumer.
                  M.findWithDefault S.empty (rrIndex c) structPrec
                    @?= S.empty
                  -- Union (the headline view) carries the bus edge.
                  M.findWithDefault S.empty (rrIndex c) deps
                    @?= S.singleton (rrIndex p)
                  M.findWithDefault S.empty (rrIndex p) deps
                    @?= S.empty
                _ -> assertFailure $
                  "expected one RNodeLoop producer + one RBusInLpfGainOut "
                  <> "consumer, got "
                  <> show (length producers) <> " + "
                  <> show (length consumers)

      , -- §4.E.1b regression: kernel-split structural edges.
        -- @saw → lpf → gain → add → out@ is the canonical case
        -- 'regionBusPrecedence' alone would miss. 'RSawLpfGain'
        -- (buffer-terminal) claims @[Saw, LPF, Gain]@; the
        -- trailing @[Add, Out]@ stays 'RNodeLoop'. The trailing
        -- region reads the materialized gain output through a
        -- port edge (Add's signal input is RFrom Gain). No bus
        -- is involved, so 'regionBusPrecedence' is empty — but
        -- the trailing region absolutely cannot run before
        -- 'RSawLpfGain', and a parallel scheduler that consumed
        -- only the bus view would happily race them.
        --
        -- This is the load-bearing pin for
        -- 'regionStructuralPrecedence' / 'regionDependencies'.
        -- See Note [Region dependency contract].
        testCase "kernel-split chain: structural port edge across region boundary" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)        -- non-sink consumer of Gain;
                                              -- blocks RSawLpfGainOut
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions = rgRuntimeRegions rg
                  bufs    = [r | r <- regions, rrKernel r == RSawLpfGain]
                  tails   = [r | r <- regions, rrKernel r == RNodeLoop]
              case (bufs, tails) of
                ([buf], [tail_]) -> do
                  -- Footprints: producer writes nothing (gain
                  -- materializes a buffer, not a bus); consumer
                  -- writes bus 0 via Out, reads no bus.
                  bfWrites       (rfBuses (rrFootprint buf))   @?= S.empty
                  bfReads        (rfBuses (rrFootprint buf))   @?= S.empty
                  bfWrites       (rfBuses (rrFootprint tail_)) @?= S.singleton 0
                  bfReads        (rfBuses (rrFootprint tail_)) @?= S.empty

                  -- Bus view alone misses the dependency (no bus
                  -- writes / reads intersect).
                  let busPrec = regionBusPrecedence rg
                  M.findWithDefault S.empty (rrIndex tail_) busPrec
                    @?= S.empty

                  -- Structural view catches it: Add (in tail
                  -- region) has RFrom pointing into the buffer
                  -- region.
                  let structPrec = regionStructuralPrecedence rg
                  M.findWithDefault S.empty (rrIndex tail_) structPrec
                    @?= S.singleton (rrIndex buf)

                  -- Headline: the union carries the structural
                  -- edge. Anyone consulting 'regionDependencies'
                  -- sees the dependency that 'regionBusPrecedence'
                  -- alone would miss.
                  let deps = regionDependencies rg
                  M.findWithDefault S.empty (rrIndex tail_) deps
                    @?= S.singleton (rrIndex buf)
                  M.findWithDefault S.empty (rrIndex buf) deps
                    @?= S.empty
                _ -> assertFailure $
                  "expected one RSawLpfGain region + one RNodeLoop tail, got "
                  <> show (length bufs) <> " + " <> show (length tails)

      , -- BusInDelayed must NOT induce precedence. The graph has
        -- a producer chain that writes bus 5 (claimed as
        -- 'RSinGainOut' via BusOut) and a delayed-reader chain
        -- (busInDelayed 5 → gain → out) that reads bus 5
        -- /delayed/ rather than live. The producer region's
        -- footprint has writes={5}; the reader region's footprint
        -- has delayedReads={5} and writes={0}. Both
        -- 'regionBusPrecedence' (delayed reads excluded by rule)
        -- and 'regionStructuralPrecedence' (BusInDelayed has no
        -- audio inputs, so no port edge) report no edge — and
        -- therefore 'regionDependencies' must be empty.
        testCase "BusInDelayed reader does not induce a dependency edge" $ do
          let g = runSynth $ do
                s1 <- sinOsc 220.0 0.0
                g1 <- gain s1 (Param 0.3)
                busOut 5 g1                        -- producer: §4.B claims RSinGainOut via BusOut
                d  <- busInDelayed 5
                g2 <- gain d (Param 0.4)
                out 0 g2                           -- reader: 3-node, no §4.B kernel for KBusInDelayed
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

                  -- Headline assertion: no edge in any view.
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

      , -- Independent regions must have disjoint footprints and no
        -- precedence edges between them. Two parallel sin → gain
        -- → out chains writing different sink buses both claim
        -- 'RSinGainOut' but neither reads any bus and neither
        -- consumes the other's output — so every dependency view
        -- is empty everywhere.
        testCase "independent regions have disjoint footprints + no deps" $ do
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
              -- Each kernel region writes exactly one bus; the
              -- two written buses are disjoint.
              let writes = [bfWrites (rfBuses (rrFootprint r)) | r <- regions]
              S.unions writes @?= S.fromList [0, 1]
              -- Every dependency view is empty for every region.
              let deps = regionDependencies rg
              all (S.null . snd) (M.toList deps) @?= True

      , -- Multi-template send/return: each template compiles to
        -- its own RuntimeGraph through 'compileTemplateGraph',
        -- and the per-region BusFootprint must be populated
        -- through that pipeline (not just through the
        -- single-graph 'compileRuntimeGraph' direct path).
        --
        -- The voice template's region claims RSinGainOut via
        -- BusOut and writes bus 5; the fx template's region
        -- claims RBusInLpfGainOut and reads bus 5 / writes bus 0.
        -- Intra-template dependencies are empty within each
        -- (single-region per template; cross-template ordering is
        -- handled by 'compileTemplateGraph', not by the
        -- per-region view).
        testCase "multi-template send/return: per-region footprints survive compileTemplateGraph" $ do
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

          -- Voice side: one region claiming RSinGainOut, footprint
          -- writes bus 5.
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

          -- Fx side: one region claiming RBusInLpfGainOut,
          -- footprint reads bus 5 and writes bus 0.
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

      , -- §4.E.1c barrier predicate at the NodeKind level. The
        -- three live-bus kinds (KBusIn / KOut / KBusOut) each
        -- carry a runtime-redirectable bus index in
        -- 'rnControls[0]', so any region containing them is a
        -- scheduler barrier. KBusInDelayed is excluded — its
        -- read is from the previous block's snapshot, which is
        -- deterministic regardless of intra-block scheduling
        -- order.
        --
        -- This pins the kind-level contract directly so the
        -- graph-level tests below can rely on it for shape-
        -- specific cases without re-arguing the policy.
        testCase "isLiveBusKind: exhaustively {KBusIn, KOut, KBusOut}; everything else no" $ do
          -- Enumerate every 'NodeKind' so the assertion proves the
          -- exact membership of the live-bus set, not just spot-
          -- checks. A new kind added to 'Types.hs' that is
          -- accidentally classified as live-bus (or accidentally
          -- excluded from it) fails this test the next time the
          -- suite runs.
          --
          -- 'NodeKind' has no 'Ord', so the comparison is on lists
          -- in declaration ('Enum') order rather than sets.
          let live = [k | k <- [minBound .. maxBound :: NodeKind]
                        , isLiveBusKind k]
          -- Expected list is also in declaration order, which
          -- happens to match the enum: KOut < KBusOut < KBusIn.
          live @?= [KOut, KBusOut, KBusIn]

      , -- A simple sin → gain → out chain has KOut in its
        -- single region, so 'regionHasLiveBus' must say True —
        -- the region is a barrier. (Effectively every chain
        -- ending in Out / BusOut is a barrier under the policy.)
        testCase "regionHasLiveBus: chain with KOut is a barrier" $ do
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

      , -- §4.E.1c × kernel-split: in the canonical
        -- @saw → lpf → gain → add → out@ split, the
        -- 'RSawLpfGain' buffer region has /no/ live-bus node and
        -- is therefore /not/ a barrier — its dependency is
        -- structural (the trailing region reads its gain output
        -- via a port edge, see the §4.E.1b test above), but the
        -- region itself can in principle be moved by a
        -- non-barrier-aware scheduler so long as it precedes the
        -- consumer. The trailing 'RNodeLoop' region carrying
        -- @[Add, Out]@ /is/ a barrier (via KOut) and stays in
        -- compile-decreed order regardless of dependency
        -- analysis.
        --
        -- Pins the discrimination: barrier-ness tracks live-bus
        -- membership only, not dependency-graph reach.
        testCase "regionHasLiveBus: kernel-split — buffer region not a barrier, sink region is" $ do
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

      , -- Internal send/return: both regions contain live-bus
        -- nodes (producer has KBusOut, consumer has KBusIn and
        -- KOut), so both are barriers. The dependency between
        -- them ('regionBusPrecedence' edge) is incidental for the
        -- barrier predicate — barrier-ness is per-region,
        -- independent of whether there's an inter-region edge.
        testCase "regionHasLiveBus: send/return — both regions are barriers" $ do
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

  , -- Phase 4.E.2a: pure single-thread region scheduler planner.
    -- 'regionSchedule' encodes the contract a future scheduler
    -- consumes — barrier regions (live-bus) execute in
    -- compile-decreed 'rrIndex' order; non-barrier regions are
    -- topologically scheduled within each barrier-delimited
    -- segment using 'regionDependencies' with 'rrIndex' as the
    -- stable tie-breaker. No runtime change in this slice.
    --
    -- Today's 'compileRuntimeGraph' produces a topologically
    -- valid 'rrIndex' sequence, so 'regionSchedule' returns
    -- 'rrIndex' order verbatim. The tests pin /that property/
    -- across the relevant graph shapes, so a future change that
    -- accidentally introduces a real reorder is caught here
    -- before §4.E.2b lands and starts depending on the contract
    -- for actual concurrency.
    testGroup "Phase 4.E.2a: regionSchedule planner"
      [ -- Single-region baseline: only one region, schedule must
        -- be its singleton index.
        testCase "single-region chain: schedule is [0]" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> regionSchedule rg @?= Right [RegionIndex 0]

      , -- Internal send/return: producer (KBusOut) and consumer
        -- (RBusInLpfGainOut, contains KBusIn + KOut) are both
        -- barriers, anchored at their compile-decreed positions.
        -- Schedule equals 'rrIndex' order; segmentByBarrier sees
        -- two singleton barrier slots and no free segment.
        testCase "send/return barriers: both regions barriers, schedule = rrIndex order" $ do
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
              -- Both regions are barriers under §4.E.1c.
              all (regionHasLiveBus rg) regions @?= True
              length segments @?= 2
              -- Both segments are 'Barrier' (no free runs between
              -- them). Pattern match inline rather than using a
              -- helper to keep the assertion self-explanatory.
              let isBarrier seg = case seg of
                    Barrier _ -> True
                    _         -> False
              all isBarrier segments @?= True
              regionSchedule rg @?= Right (map rrIndex regions)

      , -- Kernel-split structural-edge case: 'RSawLpfGain'
        -- buffer region (no live-bus, free) precedes the
        -- trailing 'RNodeLoop' tail (KOut, barrier). The
        -- structural cross-region edge (Add reads Gain across
        -- the region boundary) is part of 'regionDependencies',
        -- but the planner doesn't need to reorder anything —
        -- 'rrIndex' order is already topologically valid.
        --
        -- Pins: a free region preceding a barrier ends up in a
        -- one-element free segment, then the barrier. The barrier
        -- doesn't get folded into the free segment.
        testCase "kernel-split: free buffer region precedes barrier tail" $ do
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
                  -- Free region is not a barrier, tail is.
                  regionHasLiveBus rg buf   @?= False
                  regionHasLiveBus rg tail_ @?= True
                  -- segmentByBarrier emits free segment, then
                  -- barrier — same number of slices as regions
                  -- since the free segment carries one region.
                  segmentByBarrier rg @?= [ FreeSegment [buf]
                                          , Barrier tail_
                                          ]
                  -- Schedule equals rrIndex order.
                  regionSchedule rg @?= Right [rrIndex buf, rrIndex tail_]
                _ -> assertFailure $
                  "expected one RSawLpfGain region + one RNodeLoop "
                  <> "tail, got " <> show (length bufs)
                  <> " + " <> show (length tails)

      , -- BusInDelayed reader: the delayed read does not
        -- contribute to 'regionDependencies' (and so doesn't
        -- create a precedence edge between producer and reader).
        -- Both regions in this graph contain live-bus nodes
        -- (producer has KBusOut; reader has KOut), so both are
        -- barriers and the schedule is 'rrIndex' order. Pins
        -- that delayed-only readers don't somehow short-circuit
        -- the barrier classification.
        testCase "BusInDelayed: schedule is rrIndex order, both barriers" $ do
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

      , -- Independent non-barrier reordering: a graph with /two/
        -- 'RSawLpfGain' free regions adjacent in 'rrIndex' order,
        -- both feeding the same trailing 'RNodeLoop' barrier
        -- (Add + Out). The free regions land in a single free
        -- segment; the planner topologically sorts them with
        -- stable 'rrIndex' tie-breaking. Since the two free
        -- regions are independent (neither depends on the
        -- other), the stable rrIndex order is the natural
        -- output.
        --
        -- This is the headline test for stable-rrIndex
        -- reordering: the segment has more than one non-barrier
        -- region, the topo-sort actually has a choice, and the
        -- choice is the rrIndex order.
        testCase "independent free regions: stable rrIndex order in single segment" $ do
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
                  -- Both buffer regions are free; the tail is a
                  -- barrier (KOut).
                  regionHasLiveBus rg b1    @?= False
                  regionHasLiveBus rg b2    @?= False
                  regionHasLiveBus rg tail_ @?= True
                  -- The free segment groups both buffer regions;
                  -- the barrier follows.
                  segmentByBarrier rg
                    @?= [ FreeSegment [b1, b2], Barrier tail_ ]
                  -- Schedule emits both free regions in rrIndex
                  -- order, then the barrier.
                  regionSchedule rg
                    @?= Right [ rrIndex b1, rrIndex b2, rrIndex tail_ ]
                _ -> assertFailure $
                  "expected two RSawLpfGain regions + one RNodeLoop "
                  <> "tail, got "
                  <> show (length buffers) <> " + "
                  <> show (length tails)

      , -- Multi-template send/return: each template's 'RuntimeGraph'
        -- carries its own one-region schedule. The voice template
        -- is a barrier (RSinGainOut via BusOut), the fx template is
        -- a barrier (RBusInLpfGainOut). Pins that the planner runs
        -- correctly through 'compileTemplateGraph' as well as the
        -- single-graph 'compileRuntimeGraph' direct path.
        testCase "multi-template: per-template schedule = [0] for each one-region template" $ do
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

      , -- Fail-loud planner, list-order contract:
        -- 'rgRuntimeRegions' must be dense ascending by 'rrIndex'
        -- from 0. 'segmentByBarrier' walks the list in /list/
        -- order and 'topoSortStable' uses list order as the
        -- stable tie-breaker, so the documented "barriers stay in
        -- rrIndex order, free regions tie-break by rrIndex"
        -- contract only holds when the list /is/ rrIndex order.
        --
        -- Reversing the kernel-split region list produces a
        -- non-ascending sequence; the planner must reject it
        -- before scheduling.
        testCase "rejects non-ascending rgRuntimeRegions order" $ do
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

      , -- Fail-loud planner, duplicate-index variant: hand-build
        -- a 'rgRuntimeRegions' with the same 'rrIndex' twice.
        -- This exercises the dense-ascending check on a malformed
        -- list that's not just a reversal — duplicates and gaps
        -- should also be rejected.
        testCase "rejects duplicate rrIndex in rgRuntimeRegions" $ do
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

  , -- Phase 4.E.2b: loaders register regions through the schedule.
    --
    -- These tests pin the loader-side contract — the four loaders
    -- ('loadRuntimeGraph', 'loadRuntimeGraphFused', 'loadTemplateGraph',
    -- 'loadTemplateGraphFused') each register regions on the C++
    -- side via 'scheduledRuntimeRegions', not the raw 'rgRuntimeRegions'
    -- list. Today the planner is the identity over 'rrIndex' order on
    -- well-formed compile output, so the two are equal: equality here
    -- /is/ the bit-equivalence claim. A future change that breaks
    -- the planner identity (or the dense-ascending invariant) is
    -- caught by 'regionSchedule' before any C++ mutation, not by
    -- silent reorder at the runtime.
    --
    -- We don't compare against rendered audio because the existing
    -- render-equivalence suite (loadTemplateGraph: cross-template
    -- send/return, BusOut/BusIn round-trip, etc.) already covers
    -- end-to-end equivalence; these tests pin the precise loader
    -- contract.
    testGroup "Phase 4.E.2b: loaders consume scheduledRuntimeRegions"
      [ -- Single-template, unfused: same input as 'loadRuntimeGraph'
        -- exercises end-to-end. Confirm scheduled order matches
        -- rgRuntimeRegions order (planner identity property).
        testCase "loadRuntimeGraph: scheduled order = rgRuntimeRegions" $ do
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

      , -- Single-template, fused: same input shape as the canonical
        -- fused-render tests; confirm scheduled order matches.
        testCase "loadRuntimeGraphFused: scheduled order = rgRuntimeRegions" $ do
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

      , -- Multi-template, unfused: per-template schedule equals
        -- per-template rgRuntimeRegions order.
        testCase "loadTemplateGraph: per-template scheduled order = rgRuntimeRegions" $ do
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
              -- For every template, scheduled order matches raw.
              mapM_ (\tpl ->
                case scheduledRuntimeRegions (tplGraph tpl) of
                  Left err -> assertFailure $
                    "template " <> show (tplName tpl)
                    <> ": scheduledRuntimeRegions failed: " <> err
                  Right scheduled ->
                    map rrIndex scheduled @?=
                      map rrIndex (rgRuntimeRegions (tplGraph tpl)))
                (tgTemplates tg)

      , -- Multi-template, fused: same as above but through the
        -- fused compile path so rg may carry RFused / rnElided.
        testCase "loadTemplateGraphFused: per-template scheduled order = rgRuntimeRegions" $ do
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

      , -- §4.E.2b loader-preservation contract: a failed schedule
        -- must not disturb the currently loaded graph. Compute the
        -- schedule first, fail before 'c_rt_graph_clear', leave
        -- the previous graph fully renderable.
        --
        -- Procedure: load a good graph, snapshot bus 0 after one
        -- block. Construct a malformed graph (reverse the region
        -- list — trips the dense-ascending check). 'try' to load
        -- it; expect 'Left'. Render another block on the same
        -- handle and confirm it is non-silent and at a similar
        -- peak level. (We can't compare sample-for-sample because
        -- the oscillator phase has advanced; the right invariant
        -- is "same audible signal, just one block later".)
        testCase "loadRuntimeGraph: failed schedule preserves previous graph" $ do
          let nframes, sizeOfFloat :: Int
              nframes     = 256
              sizeOfFloat = 4
              -- Two-region graph: an 'RSawLpfGain' buffer feeds an
              -- 'RNodeLoop' tail. Reversing 'rgRuntimeRegions'
              -- produces a non-ascending list that the planner
              -- must reject.
              good = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)
                out 0 b
          rt <- case lowerGraph good >>= compileRuntimeGraph of
            Right r  -> pure r
            Left err -> assertFailure err >> error "unreachable"
          -- Sanity: the chosen graph has at least two regions, so
          -- the reversal is observable.
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

            -- Attempt the bad load; must fail before clear.
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

            -- The previously loaded graph must still produce the
            -- same audio. Render another block and compare.
            c_rt_graph_process handle (fromIntegral nframes)
            after <-
              allocaBytes (nframes * sizeOfFloat) $ \buf -> do
                _ <- c_rt_graph_read_bus handle 0
                       (fromIntegral nframes) (castPtr buf)
                cs <- peekArray nframes (buf :: PtrCFloat)
                pure (map (\(CFloat x) -> x) cs)

            -- 'before' is block 0 and 'after' is block 1 of the
            -- /same/ continuous oscillator. Pinning that both
            -- blocks render non-silent audio at a similar level
            -- shows the graph survived the failed load — a
            -- half-cleared state would produce silence or
            -- diverge in level. We don't compare sample-for-sample
            -- because the oscillator phase advances between
            -- blocks (which is the correct behavior).
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

  , -- Phase 4.E.2c (parallel-readiness survey): descriptive
    -- 'regionScheduleStats' counts. Read-only summary used by
    -- '--fusion-survey' to answer "do graphs have wide non-barrier
    -- work?" before any worker-pool design lands.
    testGroup "Phase 4.E.2c: regionScheduleStats descriptive counts"
      [ -- Single-region all-barrier graph: one barrier, no free.
        testCase "single-region (sin -> out): 1 barrier, 0 free, max widths 0" $ do
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

      , -- Kernel-split: free buffer + barrier tail.
        testCase "saw -> lpf -> gain -> add -> out: 1 free + 1 barrier, max widths 1" $ do
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

      , -- Headline parallelism case: two independent free buffers
        -- in one segment. Width = 2 at both segment and layer
        -- level (regions are independent → one layer of size 2).
        testCase "two independent buffers + shared tail: free width 2 at layer 0" $ do
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

      , -- Aggregation: empty + s = s, and (a + b) sums counts and
        -- maxes widths.
        testCase "addScheduleStats: counts add, widths max" $ do
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

      , -- Cross-template width: a chain ensemble (voice → fx via
        -- shared bus) has 'tssMaxTemplateLayerWidth' = 1, even
        -- though the per-template aggregate sums two regions.
        testCase "templateScheduleStats: chain ensemble has layer width 1" $ do
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

      , -- Two independent voices writing different buses have no
        -- precedence on each other and no shared-write hazard, so
        -- the full layer-0 width is runnable without reduction.
        testCase "templateScheduleStats: disjoint writers are runnable width 2" $ do
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

      , -- Two independent voices feeding one fx: voices have no
        -- precedence on each other (both write the same bus,
        -- neither reads from the other), so layer 0 = {voice-l,
        -- voice-r}, layer 1 = {fx}. Max template precedence
        -- width = 2. Because the two voices also share bus 7,
        -- the full layer is reduction-needed width, not runnable
        -- width.
        testCase "templateScheduleStats: two voices + one fx → layer width 2" $ do
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

  , testGroup "Phase 4.D.1: rnRate carries IR-propagated rate"
      [ -- The runtime graph must preserve every IR node's
        -- propagated 'irRate' on the corresponding 'rnRate'. This
        -- is the load-bearing pin for §4.D.1: the descriptive
        -- view's whole job is to keep IR rate inference
        -- observable through the runtime boundary, so any drift
        -- between the two would silently break the survey's
        -- distribution counts and make rate-shaped optimization
        -- decisions unsound.
        testCase "rnRate matches irRate for every node (mixed osc + transform)" $ do
          let g = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                out 0 a
          ir <- case lowerGraph g of
            Right x  -> pure x
            Left err -> assertFailure ("lowerGraph failed: " <> err)
                          >> error "unreachable"
          rt <- case compileRuntimeGraph ir of
            Right x  -> pure x
            Left err -> assertFailure ("compile failed: " <> err)
                          >> error "unreachable"
          let irByID =
                M.fromList [(irNodeID n, irRate n) | n <- giNodes ir]
              checkOne n = case M.lookup (rnOriginalID n) irByID of
                Just r ->
                  assertEqual ("rnRate vs irRate for " <> show (rnIndex n))
                              r (rnRate n)
                Nothing ->
                  assertFailure $ "missing IR rate for "
                               <> show (rnOriginalID n)
          mapM_ checkOne (rgNodes rt)

      , -- Pure-literal subgraph: 'KOut' has a 'CompileRate' kind
        -- floor, its only input is a 'Literal' (also 'CompileRate'),
        -- and propagation joins to 'CompileRate'. This is the
        -- "stays low where possible" pin — any future regression
        -- that always lifts to 'SampleRate' would fire it.
        testCase "constant-only graph (out (Param 0.0)) stays at CompileRate" $ do
          let g = runSynth (out 0 (Param 0.0))
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let rates = map rnRate (rgNodes rt)
              assertBool ("expected all CompileRate, got " <> show rates)
                         (all (== CompileRate) rates)

      , -- Oscillator chain: the 'KSinOsc' floor is 'SampleRate',
        -- and propagation lifts every downstream node to match.
        -- This is the dual of the constant-only test: when an
        -- audio producer is in the graph, the join must reach
        -- every reachable consumer.
        testCase "oscillator chain lifts every downstream node to SampleRate" $ do
          let g = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let kindRates =
                    [(rnKind n, rnRate n) | n <- rgNodes rt]
              assertEqual "kind/rate pairs"
                [(KSinOsc, SampleRate)
                ,(KGain,   SampleRate)
                ,(KOut,    SampleRate)
                ]
                kindRates

      , -- Region rate consistency: for every region produced by
        -- 'compileRuntimeGraph', the region's 'rrRate' must equal
        -- the max of its members' 'rnRate'. 'formRegions' already
        -- computes 'regRate' as the join over members at the IR
        -- level; this test pins that the runtime's per-node and
        -- per-region rate views stay in agreement after lowering,
        -- so the descriptive survey can't end up reporting a
        -- region rate that no member node actually claims.
        testCase "every rrRate equals max of member rnRates" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let nodeMap =
                    M.fromList [(rnIndex n, rnRate n) | n <- rgNodes rt]
                  memberRate ix =
                    M.findWithDefault CompileRate ix nodeMap
              sequence_
                [ assertEqual
                    ("region " <> show (rrIndex r) <> " rrRate vs join")
                    (maximum (CompileRate : map memberRate (rrNodes r)))
                    (rrRate r)
                | r <- rgRuntimeRegions rt
                ]

      , -- Bucket-count integrity: a per-rate histogram of all
        -- runtime nodes must sum to the node count exactly. The
        -- survey footer divides 'rdSample' by this total to
        -- compute @S%@; if the bucket counts and the node count
        -- could ever disagree (double-counting, missing rate
        -- value, off-by-one), the headline percentage would be
        -- wrong. Walking 'rgNodes' once and binning by 'rnRate'
        -- here mirrors what 'rateDistribution' does in the survey
        -- driver.
        testCase "rate-bucket counts sum to total node count" $ do
          let g = runSynth $ do
                s1 <- sinOsc 220.0 0.0; a1 <- gain s1 (Param 0.3); out 0 a1
                s2 <- sawOsc 110.0 0.0; a2 <- gain s2 (Param 0.3); out 1 a2
                n  <- noiseGen;         a3 <- gain n  (Param 0.1); out 0 a3
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let nodes = rgNodes rt
                  total = length nodes
                  countAt r = length (filter ((== r) . rnRate) nodes)
                  c = countAt CompileRate
                  i = countAt InitRate
                  b = countAt BlockRate
                  s = countAt SampleRate
              assertEqual "bucket sum vs total" total (c + i + b + s)
              -- Sanity: this graph is osc/noise dominated, so
              -- every node must end up at SampleRate.
              assertEqual "all nodes SampleRate on osc-only graph"
                          total s
      ]

  , testGroup "Phase 4.D.2: portInfo metadata"
      [ -- Totality: for every 'NodeKind', 'portInfo' must return
        -- 'Just' on every port in @[0 .. ksAudioArity - 1]@ and
        -- 'Nothing' on the next index past that range. This is the
        -- drift guard between 'kindSpec' (which the §4.B / §4.D
        -- code paths already trust) and the new per-port table.
        -- Without it, adding an audio input to a 'UGen' constructor
        -- could leave 'portInfo' stale and silently drop edges
        -- from the §4.D.2 edge-rate survey.
        testCase "portInfo is total over the declared audio-input range" $
          sequence_
            [ do
                let arity = ksAudioArity (kindSpec k)
                sequence_
                  [ assertBool
                      (show k <> " port " <> show i
                       <> " should have a PortInfo entry")
                      (case portInfo k (PortIndex i) of
                         Just _  -> True
                         Nothing -> False)
                  | i <- [0 .. arity - 1]
                  ]
                assertEqual
                  (show k <> " port " <> show arity
                   <> " (one past the declared arity) must be Nothing")
                  Nothing
                  (portInfo k (PortIndex arity))
            | k <- [minBound .. maxBound :: NodeKind]
            ]

      , -- Pin the load-bearing classifications. These three
        -- entries are the survey's whole reason to exist:
        --   * Filter freq / q are block-latched (sample 0 only).
        --   * Oscillator phase is init-only (never resolved per
        --     block).
        --   * Gain.amount is sample-accurate (counter-example for
        --     the handoff-doc claim that "scalar gain amount is a
        --     block-latch opportunity" — it is not, when wired).
        -- Any drift in these specific rows would invalidate the
        -- §4.D.2 opportunity number directly, so they're pinned
        -- by name rather than by enumeration.
        testCase "filter freq/q are PortBlockLatched, named freq/q" $ do
          portInfo KLPF (PortIndex 1)
            @?= Just (PortInfo PortBlockLatched "freq")
          portInfo KLPF (PortIndex 2)
            @?= Just (PortInfo PortBlockLatched "q")
          portInfo KHPF (PortIndex 1)
            @?= Just (PortInfo PortBlockLatched "freq")
          portInfo KBPF (PortIndex 2)
            @?= Just (PortInfo PortBlockLatched "q")
          portInfo KNotch (PortIndex 1)
            @?= Just (PortInfo PortBlockLatched "freq")

      , -- Phase ports are 'PortIgnored', not 'PortInitOnly': the
        -- C++ kernels never resolve port 1 in the audio loop, so a
        -- wired 'RFrom' source is silently dropped (the kernel
        -- takes the initial phase from 'rnControls[1]' at
        -- construction). This distinction matters for the
        -- §4.D.2 opportunity count — 'PortIgnored' edges are
        -- excluded because there is no consumption to demote.
        testCase "oscillator phase ports are PortIgnored, named phase" $ do
          portInfo KSinOsc   (PortIndex 1)
            @?= Just (PortInfo PortIgnored "phase")
          portInfo KSawOsc   (PortIndex 1)
            @?= Just (PortInfo PortIgnored "phase")
          portInfo KTriOsc   (PortIndex 1)
            @?= Just (PortInfo PortIgnored "phase")
          portInfo KPulseOsc (PortIndex 1)
            @?= Just (PortInfo PortIgnored "phase")

      , testCase "Gain.amount is PortSampleAccurate (not block-latched)" $ do
          portInfo KGain (PortIndex 1)
            @?= Just (PortInfo PortSampleAccurate "amount")
          -- Spot-check sibling sample-accurate rows so a future
          -- change that flips Gain.amount accidentally also
          -- flips at least one of these.
          portInfo KPulseOsc (PortIndex 2)
            @?= Just (PortInfo PortSampleAccurate "width")
          portInfo KDelay   (PortIndex 1)
            @?= Just (PortInfo PortSampleAccurate "time")
          portInfo KSmooth  (PortIndex 0)
            @?= Just (PortInfo PortSampleAccurate "target")

      , testCase "kinds with no audio inputs return Nothing on every port" $
          sequence_
            [ assertEqual
                (show k <> " port 0 should be Nothing")
                Nothing
                (portInfo k (PortIndex 0))
            | k <- [KNoiseGen, KBusIn, KBusInDelayed]
            ]

      , -- Producer-grouped headline (§4.D.2 'opportunity' count).
        -- An LFO that feeds /both/ LPF.freq (PortBlockLatched) and
        -- Gain.amount (PortSampleAccurate) is /not/ an opportunity:
        -- it must remain sample-rate to serve its sample-accurate
        -- consumer, even though one of its edges lands in a
        -- block-latched bucket. Counting edges instead of producers
        -- would over-report this case — 1 producer node would show
        -- as 2 opportunity edges.
        testCase "sampleRateOpportunityProducers: shared LFO is NOT an opportunity" $ do
          let g = runSynth $ do
                lfo <- sinOsc 4.0 0.0
                s   <- sawOsc 110.0 0.0
                f   <- lpf s lfo (Param 4.0)   -- LFO → lpf.freq (block-latched)
                a   <- gain f lfo              -- LFO → gain.amount (sample-acc.)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let ops = sampleRateOpportunityProducers rt
              assertBool
                ("LFO with mixed-policy consumers must not be flagged "
                 <> "as an opportunity, got: " <> show ops)
                (KSinOsc `notElem` ops)

      , -- Counter-pin to the shared-LFO test: a sample-rate
        -- producer whose /every/ active consumer is non-sample-
        -- accurate (here, an LFO feeding only LPF.freq) does
        -- qualify as an opportunity.
        testCase "sampleRateOpportunityProducers: LFO → LPF.freq alone IS an opportunity" $ do
          let g = runSynth $ do
                lfo <- sinOsc 4.0 0.0
                s   <- sawOsc 110.0 0.0
                f   <- lpf s lfo (Param 4.0)
                a   <- gain f (Param 0.4)      -- gain.amount is constant
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let ops = sampleRateOpportunityProducers rt
              assertBool
                ("LFO with only block-latched consumer must be "
                 <> "flagged, got: " <> show ops)
                (KSinOsc `elem` ops)

      , -- Phase-port edges must not inflate the opportunity count.
        -- An LFO wired to the phase port of a sin oscillator is
        -- silently dropped by the runtime (PortIgnored), so the
        -- LFO has /no/ active consumers in this graph and is not
        -- an opportunity — even though "the LFO has only non-
        -- sample-accurate consumers" looks superficially true.
        testCase "sampleRateOpportunityProducers: PortIgnored consumers don't qualify" $ do
          let g = runSynth $ do
                lfo <- sinOsc 4.0 0.0
                s   <- sinOsc 220.0 lfo        -- LFO → sin.phase (PortIgnored)
                a   <- gain s (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let ops = sampleRateOpportunityProducers rt
              -- The LFO has only an ignored consumer (sin.phase);
              -- the carrier sin has only sample-accurate consumers
              -- (gain.sig); neither qualifies.
              assertEqual
                ("expected no opportunity producers in "
                 <> "phase-mod-only graph, got: " <> show ops)
                [] ops

      , -- Integration of 'edgeRateBuckets' with 'portInfo'. An
        -- Env-driven LPF cutoff is the canonical §4.D.2
        -- opportunity edge: the 'KEnv' source has 'rnRate =
        -- SampleRate' (kind floor), and 'KLPF' port 1 has
        -- consumption policy 'PortBlockLatched'. The bucket lookup
        -- must produce exactly one such edge with the expected
        -- producer kind and example string. Catches drift where a
        -- future change to either the kind floors, 'propagateRates',
        -- the unfused-graph contract of 'compileRuntimeGraph', or
        -- the 'portInfo' table would silently re-classify the edge.
        testCase "edgeRateBuckets: Env → LPF.freq lands in (SampleRate, PortBlockLatched)" $ do
          let g = runSynth $ do
                e <- env (Param 1.0) 0.005 0.05 0.7 0.5
                n <- noiseGen
                f <- lpf n e (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let buckets = edgeRateBuckets rt
                  key     = (SampleRate, PortBlockLatched)
              case M.lookup key buckets of
                Nothing ->
                  assertFailure $
                    "expected a bucket at " <> show key
                    <> ", got " <> show (M.keys buckets)
                Just b -> do
                  -- Exactly one Env → LPF.freq edge.
                  erbEdgeCount b @?= 1
                  -- Producer kind = Env.
                  KEnv `elem` erbProducerKinds b @?= True
                  -- Example string ends with the LPF.freq
                  -- destination so survey output is legible.
                  case erbExample b of
                    Just s ->
                      assertBool
                        ("example should mention LPF.freq, got: " <> s)
                        ("KLPF.freq" `isInfixOf` s)
                    Nothing ->
                      assertFailure "bucket missing example"
      ]

  , testCase "kindTag is injective" $
      let ks = [minBound .. maxBound :: NodeKind]
          ts = map kindTag ks
      in assertEqual
           "two NodeKinds share a kindTag — C++ dispatch will collide"
           (length ks)
           (length (nub ts))
  ]

------------------------------------------------------------
-- Property tests
------------------------------------------------------------

properties :: TestTree
properties = testGroup "Properties"
  [ QC.testProperty "compileRuntimeGraph: indices are [0..n-1]" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propDenseIndices

  , QC.testProperty "compileRuntimeGraph: every RFrom is in [0, n) and earlier" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propTopoOrder

  , QC.testProperty "lowerGraph preserves node count" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propPreservesCount

  , QC.testProperty "validateAndSort succeeds on well-formed graphs" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propValidates

  , QC.testProperty "ugenView arities match kindSpec for every UGen" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propUgenViewMatchesSpec

  , QC.testProperty "compileRuntimeGraph is deterministic" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propDeterministic

  , QC.testProperty "every source NodeID appears once as rnOriginalID" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propBijection

  , QC.testProperty "kind multiset preserved from source to runtime" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propKindCounts

  , QC.testProperty "Out-spec count preserved as KOut node count" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propOutCount

  , QC.testProperty "dependencies of every UGen point at existing nodes" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propDepsExist

  , QC.testProperty "regions partition the IR nodes" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionPartition

  , QC.testProperty "rgNodeMap and regNodes agree" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionNodeMapConsistent

  , QC.testProperty "region IDs are unique" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionIDsUnique

  , QC.testProperty "region deps refer only to existing regions, no self-edges" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionDepsWellFormed

  , QC.testProperty "every region's rate is compatible with its member nodes" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionRateCompatible

  , QC.testProperty "RuntimeGraph region overlay round-trips formRegions" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRuntimeRegionsRoundTrip

  , QC.testProperty "RuntimeGraph regions partition node indices contiguously" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRuntimeRegionsContiguous

  , QC.testProperty "rnOutputUse classification matches consumer-region membership" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propOutputUseConsistent

  , QC.testProperty "rnConsumerCount matches direct FromNode references" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propConsumerCountConsistent

  , QC.testProperty "every BusOut precedes every same-bus BusIn in the schedule" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propBusOrdering

  , -- Rate propagation: see Note [Rate inference vs rate propagation]
    -- in "MetaSonic.Bridge.IR" for the algorithm. These properties pin
    -- the three structural invariants of the lift:
    --
    --   1. each node's rate is at least its kind's floor
    --   2. each node's rate is at least every input's rate
    --   3. running the lift twice is the same as running it once
    --
    -- (1) is the kind-floor guarantee. (2) is the join law of the
    -- lattice — the whole point of propagation. (3) is idempotence:
    -- the lift reaches a fixed point in one pass.
    QC.testProperty "every node's irRate ≥ kind floor (post-propagation)" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRateAtLeastFloor

  , QC.testProperty "every node's irRate ≥ max of its inputs' rates" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRateAtLeastInputs

  , QC.testProperty "propagateRates is idempotent on lowered IR" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propPropagationIdempotent

  , QC.testProperty "propagateRates preserves all fields except irRate" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propPropagationStructural
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
  Right rt ->
    let n = length (rgNodes rt)
    in conjoin
         [ counterexample ("node " <> show (rnIndex node)) $
             all (refsEarlier n (rnIndex node)) (rnInputs node)
         | node <- rgNodes rt
         ]
  where
    refsEarlier n (NodeIndex dst) (RFrom (NodeIndex src) _) =
      src >= 0 && src < dst && src < n
    refsEarlier _ _               (RConst _)                = True

propPreservesCount :: SynthGraph -> Property
propPreservesCount g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> length (giNodes ir) === M.size (sgNodes g)

propValidates :: SynthGraph -> Property
propValidates g = case validateAndSort g of
  Left err -> counterexample ("validateAndSort failed: " <> err) False
  Right _  -> property True

-- | Drift guard for the per-kind metadata: for every UGen in a
-- generated graph, the arities reported by @ugenView@ must match
-- the @kindSpec@ table.
propUgenViewMatchesSpec :: SynthGraph -> Property
propUgenViewMatchesSpec g = conjoin
  [ counterexample (show u) $
         length (uvInputs   v) === ksAudioArity   ks
    .&&. length (uvControls v) === ksControlArity ks
  | ns <- M.elems (sgNodes g)
  , let u  = nsUgen ns
        v  = ugenView u
        ks = kindSpec (uvKind v)
  ]

-- | Compiling the same graph twice must produce identical RuntimeGraphs.
propDeterministic :: SynthGraph -> Property
propDeterministic g =
  let r1 = lowerGraph g >>= compileRuntimeGraph
      r2 = lowerGraph g >>= compileRuntimeGraph
  in r1 === r2

-- | Every source NodeID appears exactly once as rnOriginalID.
propBijection :: SynthGraph -> Property
propBijection g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    sort (map rnOriginalID (rgNodes rt)) === sort (M.keys (sgNodes g))

-- | The multiset of NodeKinds is preserved from source to runtime.
propKindCounts :: SynthGraph -> Property
propKindCounts g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    let byTag    = sortBy (comparing kindTag)
        srcKinds = byTag (map (ugenKind . nsUgen) (M.elems (sgNodes g)))
        rtKinds  = byTag (map rnKind (rgNodes rt))
    in srcKinds === rtKinds

-- | Number of Out specs in the source equals number of KOut nodes in
-- the runtime.
propOutCount :: SynthGraph -> Property
propOutCount g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    let srcOuts = length [ () | NodeSpec { nsUgen = Out{} } <- M.elems (sgNodes g) ]
        rtOuts  = length [ () | n <- rgNodes rt, rnKind n == KOut ]
    in srcOuts === rtOuts

-- | Every NodeID returned by 'dependencies' on a node in the graph
-- must be a node-key in that graph.
propDepsExist :: SynthGraph -> Property
propDepsExist g =
  let nodes = sgNodes g
      keys  = M.keysSet nodes
      bad   = [ (nid, dep)
              | (nid, spec) <- M.toList nodes
              , dep <- dependencies (nsUgen spec)
              , dep `S.notMember` keys
              ]
  in counterexample ("dangling deps: " <> show bad) (null bad)

------------------------------------------------------------
-- Region-formation invariants
------------------------------------------------------------

-- | Every IR node appears in exactly one region.
propRegionPartition :: SynthGraph -> Property
propRegionPartition g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg          = formRegions (giNodes ir)
        regionIDs   = concatMap regNodes (rgRegions rg)
        irNodeIDs   = map irNodeID (giNodes ir)
    in conjoin
         [ counterexample "region members are not unique" $
             length regionIDs === length (nub regionIDs)
         , counterexample "region members ≠ IR nodes" $
             sort regionIDs === sort irNodeIDs
         ]

-- | rgNodeMap matches regNodes membership both ways.
propRegionNodeMapConsistent :: SynthGraph -> Property
propRegionNodeMapConsistent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg = formRegions (giNodes ir)
        forwardOK =
          [ M.lookup nid (rgNodeMap rg) == Just (regID r)
          | r <- rgRegions rg, nid <- regNodes r
          ]
        reverseOK =
          [ nid `elem` regNodes r
          | (nid, rid) <- M.toList (rgNodeMap rg)
          , Just r <- [findRegion rid (rgRegions rg)]
          ]
    in conjoin
         [ counterexample "regNodes → rgNodeMap mismatch" $
             property (and forwardOK)
         , counterexample "rgNodeMap → regNodes mismatch" $
             property (and reverseOK)
         ]
  where
    findRegion rid = lookup rid . map (\r -> (regID r, r))

-- | Region IDs are unique within a RegionGraph.
propRegionIDsUnique :: SynthGraph -> Property
propRegionIDsUnique g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rids = map regID (rgRegions (formRegions (giNodes ir)))
    in length rids === length (nub rids)

-- | Region deps refer only to existing region IDs, and never to a
-- region's own ID.
propRegionDepsWellFormed :: SynthGraph -> Property
propRegionDepsWellFormed g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg     = formRegions (giNodes ir)
        allIDs = S.fromList (map regID (rgRegions rg))
    in conjoin
         [ counterexample (show (regID r) <> " has bad deps: " <> show (regDeps r)) $
             property $
               regDeps r `S.isSubsetOf` allIDs
               && regID r `S.notMember` regDeps r
         | r <- rgRegions rg
         ]

-- | Every same-bus (BusWrite n, BusRead n) pair must have the writer
-- precede the reader in the topological order. This is the property
-- version of the unit tests in @Bus routing (BusIn/BusOut and E_r
-- edges)@: it asserts that 'effectiveDeps' actually puts every
-- writer before every reader, on every randomly generated graph.
--
-- Cycles in E_s ∪ E_r show up as a 'Left' from 'validateAndSort' and
-- are skipped (the cycle-rejection unit test covers those).
propBusOrdering :: SynthGraph -> Property
propBusOrdering g = case validateAndSort g of
  Left _    -> property True
  Right ord ->
    let posOf   = M.fromList (zip ord [(0 :: Int) ..])
        nodes   = M.toList (sgNodes g)
        writers = [ (nid, n) | (nid, ns) <- nodes
                             , BusWrite n <- inferEff (nsUgen ns) ]
        readers = [ (nid, n) | (nid, ns) <- nodes
                             , BusRead  n <- inferEff (nsUgen ns) ]
        bad =
          [ (w, r, n)
          | (w, bw) <- writers
          , (r, br) <- readers
          , bw == br
          , let n  = bw
                pw = posOf M.! w
                pr = posOf M.! r
          , pw >= pr
          ]
    in counterexample ("bad bus orderings: " <> show bad) (null bad)

-- | Every node's propagated rate must be at least its kind's floor.
-- This is the trivial half of the join: a kind floor is one of the
-- arguments of 'max', so the result is always ≥ the floor.
propRateAtLeastFloor :: SynthGraph -> Property
propRateAtLeastFloor g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> conjoin
    [ counterexample
        ("node " <> show (irNodeID n) <> " of kind " <> show (irKind n)
          <> ": irRate " <> show (irRate n)
          <> " < floor " <> show floor_)
        (irRate n >= floor_)
    | n <- giNodes ir
    , let floor_ = ksRate (kindSpec (irKind n))
    ]

-- | Every node's propagated rate must be at least the maximum rate of
-- its inputs (FromNode inputs contribute the source node's rate;
-- Literal inputs contribute CompileRate). This is the load-bearing
-- half of the join: it's the property that makes
-- 'MetaSonic.Bridge.IR.checkRateEdges' vacuous post-propagation.
propRateAtLeastInputs :: SynthGraph -> Property
propRateAtLeastInputs g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rateMap = M.fromList [ (irNodeID n, irRate n) | n <- giNodes ir ]
    in conjoin
         [ counterexample
             ("node " <> show (irNodeID n)
               <> ": irRate " <> show (irRate n)
               <> " < input rate " <> show inRate
               <> " (input " <> show inp <> ")")
             (irRate n >= inRate)
         | n   <- giNodes ir
         , inp <- irInputs n
         , let inRate = case inp of
                 FromNode src _ -> M.findWithDefault CompileRate src rateMap
                 Literal _      -> CompileRate
         ]

-- | Propagation reaches a fixed point in one pass. Running it twice
-- on a lowered IR must yield the same IR as running it once. This is
-- a defensive correctness check: a non-idempotent join would mean
-- some node's rate is changing on the second pass, which can only
-- happen if the first pass missed a join somewhere.
propPropagationIdempotent :: SynthGraph -> Property
propPropagationIdempotent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> propagateRates ir === ir

-- | Propagation only touches 'irRate'. NodeID, kind, inputs,
-- controls, and effects must be byte-identical before and after.
-- A regression here would mean the lift is mutating something it
-- shouldn't — and any of those fields drifting would break
-- downstream lowering, FFI marshalling, or scheduling.
propPropagationStructural :: SynthGraph -> Property
propPropagationStructural g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let lifted = propagateRates ir
        same field name =
          counterexample ("propagation changed " <> name) $
            map field (giNodes ir) === map field (giNodes lifted)
    in conjoin
         [ same irNodeID   "irNodeID"
         , same irKind     "irKind"
         , same irInputs   "irInputs"
         , same irControls "irControls"
         , same irEffects  "irEffects"
         ]

-- | Region rate is consistent with its members'. After CompileRate
-- absorption (see Note [Region rate compatibility] in
-- MetaSonic.Bridge.Compile), member rates may differ from 'regRate':
-- a CompileRate helper folded into a SampleRate region keeps its own
-- 'irRate = CompileRate' while the region's 'regRate' stays SampleRate.
-- Two invariants together replace the old "all equal" check:
--
--   1. Every member rate is compatible with 'regRate', i.e. either
--      equal to it or 'CompileRate'.
--   2. 'regRate' is the maximum of member rates, so at least one
--      member's rate equals 'regRate' (the dominant one that drove
--      the join).
propRegionRateCompatible :: SynthGraph -> Property
propRegionRateCompatible g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg     = formRegions (giNodes ir)
        nodes  = giNodes ir
        rateOf nid = irRate <$> findNode nid nodes
        memberRates r = [ mr | nid <- regNodes r, Just mr <- [rateOf nid] ]
        compatible rr mr = mr == rr || mr == CompileRate
    in conjoin
         [ conjoin
             [ counterexample
                 (show (regID r) <> ": member " <> show nid
                    <> " has rate " <> show (rateOf nid)
                    <> " not compatible with regRate " <> show (regRate r))
                 $ property $ maybe False (compatible (regRate r)) (rateOf nid)
             | nid <- regNodes r
             ] .&&.
             counterexample
               (show (regID r) <> ": regRate " <> show (regRate r)
                  <> " is not max of member rates " <> show (memberRates r))
               (property $ regRate r == maximum (regRate r : memberRates r)
                          && regRate r `elem` memberRates r)
         | r <- rgRegions rg
         ]
  where
    findNode nid = lookup nid . map (\n -> (irNodeID n, n))

-- | Step A round-trip property: the runtime region overlay produced
-- by 'compileRuntimeGraph' starts from 'formRegions (giNodes ir)'
-- and may then be split by 'selectRegionKernels'. The final runtime
-- regions must therefore be a rate-preserving refinement of the raw
-- formRegions output, with the same per-region NodeID-to-NodeIndex
-- membership when adjacent refined regions are concatenated.
propRuntimeRegionsRoundTrip :: SynthGraph -> Property
propRuntimeRegionsRoundTrip g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let compileRegions = rgRegions (formRegions (giNodes ir))
          runtime        = rgRuntimeRegions rg
          indexMap = M.fromList
            [ (rnOriginalID n, rnIndex n) | n <- rgNodes rg ]
          translate nid = M.lookup nid indexMap
          expected =
            [ (regRate cr, mapMaybe translate (regNodes cr))
            | cr <- compileRegions
            ]
      in case checkRuntimeRegionRefinement expected runtime of
           Right () -> property True
           Left msg -> counterexample msg False

checkRuntimeRegionRefinement
  :: [(Rate, [NodeIndex])]
  -> [RuntimeRegion]
  -> Either String ()
checkRuntimeRegionRefinement [] [] = Right ()
checkRuntimeRegionRefinement [] extra =
  Left $ "unexpected extra runtime regions: " <> show (map rrIndex extra)
checkRuntimeRegionRefinement ((rate, expectedNodes) : rest) runtime =
  let (chunk, remaining) = takeRuntimeChunk (length expectedNodes) runtime
      actualNodes = concatMap rrNodes chunk
      rates = map rrRate chunk
  in if null chunk
       then Left $ "missing runtime regions for expected nodes " <> show expectedNodes
       else if actualNodes /= expectedNodes
         then Left $
           "runtime region refinement changed members: expected "
           <> show expectedNodes <> ", got " <> show actualNodes
         else if any (/= rate) rates
           then Left $
             "runtime region refinement changed rate for "
             <> show expectedNodes <> ": expected " <> show rate
             <> ", got " <> show rates
           else checkRuntimeRegionRefinement rest remaining

takeRuntimeChunk
  :: Int
  -> [RuntimeRegion]
  -> ([RuntimeRegion], [RuntimeRegion])
takeRuntimeChunk targetLen = go [] 0
  where
    go acc _ [] = (reverse acc, [])
    go acc len rest@(r : rs)
      | len >= targetLen = (reverse acc, rest)
      | otherwise =
          go (r : acc) (len + length (rrNodes r)) rs

-- | Step A structural invariant: every 'RuntimeRegion' covers a
-- contiguous run of 'NodeIndex' values, regions concatenate in order
-- to exactly @[0 .. length (rgNodes rg) - 1]@, and no node is in
-- two regions. This locks the contiguity contract the C++ side
-- relies on (RegionSpec carries first_node + node_count).
propRuntimeRegionsContiguous :: SynthGraph -> Property
propRuntimeRegionsContiguous g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let runtime    = rgRuntimeRegions rg
          unwrap (NodeIndex i) = i
          flat       = concatMap (map unwrap . rrNodes) runtime
          totalNodes = length (rgNodes rg)
          eachContiguous =
            [ counterexample (show (rrIndex r) <> ": members are not contiguous: " <> show ixs) $
                property $
                  let ixs = map unwrap (rrNodes r)
                  in not (null ixs)
                       && ixs == [head ixs .. head ixs + length ixs - 1]
            | r <- runtime
            , let ixs = map unwrap (rrNodes r)
            ]
      in conjoin
           [ counterexample "regions do not concatenate to [0 .. n-1]" $
               flat === [0 .. totalNodes - 1]
           , conjoin eachContiguous
           ]

-- | Step B-Light: 'rnOutputUse' must agree with the actual consumer /
-- region structure. Three invariants:
--
--   1. 'NoOutput' iff the node's kind is a sink ('KOut' / 'KBusOut').
--   2. 'RegionLocal' iff the node has output AND every consumer is in
--      the same region (vacuously true when there are no consumers).
--   3. 'RegionEscapes' iff the node has output AND at least one
--      consumer is in a different region.
--
-- See Note [Output-use classification] in MetaSonic.Bridge.Compile.
propOutputUseConsistent :: SynthGraph -> Property
propOutputUseConsistent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let nodeRegion = M.fromList
            [ (ix, rrIndex r)
            | r <- rgRuntimeRegions rg, ix <- rrNodes r
            ]
          consumersOf ix =
            [ rnIndex c
            | c <- rgNodes rg
            , RFrom src _ <- rnInputs c
            , src == ix
            ]
          isSink k = k == KOut || k == KBusOut
          expected n
            | isSink (rnKind n) = NoOutput
            | otherwise =
                let myReg = M.lookup (rnIndex n) nodeRegion
                    cs    = consumersOf (rnIndex n)
                    same  = all (\c -> M.lookup c nodeRegion == myReg) cs
                in if same then RegionLocal else RegionEscapes
      in conjoin
           [ counterexample
               (show (rnIndex n) <> " (" <> show (rnKind n)
                  <> "): rnOutputUse = " <> show (rnOutputUse n)
                  <> ", expected " <> show (expected n))
               (rnOutputUse n === expected n)
           | n <- rgNodes rg
           ]

-- | 'rnConsumerCount' equals the number of direct 'FromNode'
-- references to this node across 'rgNodes'. The crisp Step-C
-- single-edge fusion predicate (rnOutputUse == RegionLocal &&
-- rnConsumerCount == 1) only works if this count is honest.
propConsumerCountConsistent :: SynthGraph -> Property
propConsumerCountConsistent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let countFor ix =
            length
              [ ()
              | c <- rgNodes rg
              , RFrom src _ <- rnInputs c
              , src == ix
              ]
      in conjoin
           [ counterexample
               (show (rnIndex n) <> ": rnConsumerCount = "
                  <> show (rnConsumerCount n)
                  <> ", direct count = " <> show (countFor (rnIndex n)))
               (rnConsumerCount n === countFor (rnIndex n))
           | n <- rgNodes rg
           ]
