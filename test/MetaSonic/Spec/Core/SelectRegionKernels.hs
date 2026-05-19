-- | Tests for Phase 4.B 'selectRegionKernels': starting from a
-- greedy 'formRegions' overlay, the selector matches contiguous
-- node sequences against the hand-written 'RegionKernel' table and
-- splits each match into its own kernel-tagged region. The cases
-- below pin both positives (4-node sink-terminal claims for the
-- saw, busin, and noise heads; 3-node oscillator-sink and
-- buffer-terminal claims; sink-class equivalence between @Out@ and
-- @BusOut@) and negatives (audio-modulated Gain, multi-consumer
-- producer/intermediate, non-sink terminal). Each producer family
-- also has a §4.C deferral pin asserting that 'fuseRuntimeGraph'
-- leaves the kernel's live control slots alone when §4.B claims
-- the chain.
--
-- Pins the IR-level region overlay; the FFI / C++ side is exercised
-- by the bit-equivalence battery in "MetaSonic.Spec.FFI.*".
module MetaSonic.Spec.Core.SelectRegionKernels
  ( selectRegionKernelsTests
  ) where

import qualified Data.Map.Strict           as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Types

selectRegionKernelsTests :: TestTree
selectRegionKernelsTests =
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
