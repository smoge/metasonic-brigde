-- | Tests for the Phase 4.C single-edge fusion machinery: the
-- 'rnOutputUse' / 'rnConsumerCount' preconditions (Step B) and the
-- 'fuseRuntimeGraph' rewrite itself (Step C), pinning the
-- 'FScaleFrom', 'FScaleChainFrom', and 'FAffineFrom' algebras
-- against the gate predicates that admit them.
--
-- See @Note [Single-edge Gain fusion]@,
-- @Note [Output-use classification]@ in "MetaSonic.Bridge.Compile",
-- and @notes/2026-05-08-e-fusion-strategy.md@ (gitignored) for the
-- non-expanding-kernel rationale that drives the Env-source pin.
module MetaSonic.Spec.Core.FusionAlgebra
  ( fusionAlgebraTests
  ) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Types

fusionAlgebraTests :: TestTree
fusionAlgebraTests =
  testGroup "Phase 4.C: fusion algebra"
    [ testCase "rnOutputUse on a linear SinOsc → Gain → Out chain" $ do
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
