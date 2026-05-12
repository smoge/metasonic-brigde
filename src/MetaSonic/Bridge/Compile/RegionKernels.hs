{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DerivingStrategies #-}
-- |
-- Module      : MetaSonic.Bridge.Compile.RegionKernels
-- Description : §4.B region-kernel selection — match contiguous
--               kernel-eligible chains inside each region and split
--               them into kernel-tagged sub-regions.
--
-- See Note [Region kernel selection] for the full contract: which
-- shapes are recognized, longest-match priority, and the per-kernel
-- preconditions every 'matches*' predicate enforces.
--
-- Re-exported by 'MetaSonic.Bridge.Compile' for the public surface.
-- The internal helpers ('isSinkTerminal', 'signalSourceIs',
-- 'isScalarGain', 'KernelMatch', 'findKernelMatch') are not
-- re-exported — they only matter inside this module.
module MetaSonic.Bridge.Compile.RegionKernels
  ( selectRegionKernels
  ) where

import qualified Data.Map.Strict as M

import           MetaSonic.Bridge.Compile.Types
import           MetaSonic.Types


{- Note [Region kernel selection]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'formRegions' is greedy on rate compatibility, so a chain like @SawOsc
→ LPF → Gain → Out@ lands as a single region (all four inferred
'SampleRate'). A shape detector for a fused kernel can therefore not
match a whole region; it has to find a contiguous /subsequence/ inside
one.

'selectRegionKernels' walks each region produced by
'compileRuntimeGraph', searches for the leftmost match of any
recognized shape, and on a hit /splits/ the region into up to three
pieces:

  * prefix  ('RNodeLoop')    — nodes before the match (skipped if empty)
  * middle  (matched kernel) — exactly the matched shape, with
                               'kernelArity'-many members
  * suffix  ('RNodeLoop')    — nodes after the match (recursively
                               scanned for further matches)

Match arity is /not/ implicit: 'findKernelMatch' returns a
'KernelMatch' descriptor that carries 'kmLength' = 'kernelArity'
'kmKernel'. Adding a kernel of any arity is a matter of extending
'kernelArity' and the dispatch in 'findKernelMatch' — the splitter
consumes whatever length the descriptor reports.

Currently five kernel shapes are recognized. The sink-terminal kernels
accept either 'KOut' or 'KBusOut' at the terminal slot; both dispatch
to the same per-node kernel ('process_out' on the C++ side) and read
their bus index from @rnControls[0]@, so the fused kernel body absorbs
them identically. See 'isSinkTerminal'.

  * 'RSawLpfGain' — 3-node buffer-terminal:
    @[KSawOsc, KLPF, KGain]@. The gain's output buffer is
    materialized because some external consumer reads it
    (typically a separate sink in the trailing 'RNodeLoop'
    region, or an 'Add' / 'KGain' / 'BusIn' in a downstream
    chain).

  * 'RSinGainOut' — 3-node sink-terminal:
    @[KSinOsc, KGain, /sink/]@ where /sink/ is 'KOut' or
    'KBusOut'. The sink is /inside/ the kernel; bus accumulation
    and §2.E sink-peak tracking happen inside the fused per-
    sample loop. No buffer is materialized.

  * 'RSawGainOut' — 3-node sink-terminal:
    @[KSawOsc, KGain, /sink/]@. The saw counterpart of
    'RSinGainOut'; identical structure with @q::saw@ in place of
    @q::sin@ in the per-sample body. Added after the
    @--fusion-survey@ scan flagged @Saw → Gain → sink@ as the
    most-missed shape on the demo set.

  * 'RNoiseGainOut' — 3-node sink-terminal:
    @[KNoiseGen, KGain, /sink/]@. Different state class from the
    oscillator sink kernels: NoiseGen carries a
    'q::white_noise_gen' xorshift PRNG (no phase iterator, no
    freq port, no controls), so the C++ kernel body is one PRNG
    read per sample × scalar gain — no 'drive_oscillator' wrap.
    Bit-equivalence depends on advancing the PRNG once per
    sample exactly as 'process_noisegen' does.

  * 'RSawLpfGainOut' — 4-node sink-terminal:
    @[KSawOsc, KLPF, KGain, /sink/]@. Combines saw + LPF + gain
    processing with the inline bus accumulation and sink-peak
    tracking; like 'RSinGainOut' it materializes no intermediate
    buffer and accepts either sink kind at the terminal slot.

  * 'RBusInLpfGainOut' — 4-node sink-terminal:
    @[KBusIn, KLPF, KGain, /sink/]@. The send-return tail kernel:
    voice template writes a bus, fx template's @[BusIn, LPF, Gain,
    Out]@ chain reads it. The producer is a bus reader (no
    oscillator state), so the kernel inlines
    @output_buses[busin_bus][i]@ instead of stepping a phase
    iterator. Filter / gain / sink absorption are identical to
    'RSawLpfGainOut'.

/Longest-match priority/. At each candidate offset 'findKernelMatch'
tries shapes longest-first: for example, on @[SawOsc, LPF, Gain, Out]@
the 4-node 'RSawLpfGainOut' wins over the 3-node 'RSawLpfGain' prefix
that would otherwise leave the 'Out' stranded in a trailing
'RNodeLoop' region. The 3-node kernel still fires whenever the longer
shape's preconditions fail — notably when the gain has multiple
consumers, or its single consumer is something other than a sink
terminal (e.g. an 'Add' or another 'Gain' on a downstream chain). See
the corresponding @matches*@ predicates and the "fallback" tests in
'Spec.hs'.

The runtime sees a clean "kernel tag per region" model and dispatches
accordingly. RegionIndex is renumbered after the split so consumers
downstream see contiguous indices.

Match preconditions, common to every fused kernel (3-node and
4-node alike):

  1. The contiguous member nodes have the kernel-specific kinds
     in the kernel-specific order, and exactly 'kernelArity'
     members are consumed.
  2. None of the matched members is 'rnElided' (defensive —
     should always hold pre-fusion).
  3. 'rnConsumerCount' is exactly 1 for every /non-terminal/
     member, and each of those single consumers /is/ the next
     node in the chain. This is the "single-use internal edges"
     rule rolled together with "no external escape from the
     intermediate buffers": the chain is the only reader of
     those buffers, so the fused kernel can keep their per-
     sample value in registers without materializing it. For
     buffer-terminal kernels ('RSawLpfGain') the terminal node's
     consumer count is unconstrained — its output /is/
     materialized. For sink-terminal kernels the terminal is a
     sink ('rnConsumerCount == 0' by construction).
  4. The Gain in the chain has scalar shape
     @[RFrom _ _, RConst _]@ — signal port wired from the
     previous member, gain port unwired (constant control).
     Audio-modulated gain stays on 'RNodeLoop' just like §4.C's
     scalar Gain fusion stays off audio-rate Gains.
  5. Where the kernel /absorbs/ the Gain's output (any sink-
     terminal shape, currently 'RSinGainOut' and
     'RSawLpfGainOut'), the Gain itself must additionally have
     'rnConsumerCount == 1' — otherwise an external consumer
     also reads the gain's buffer and the sink-terminal kernel
     must not absorb it. Longest-match falls through to the
     buffer-terminal 'RSawLpfGain' in that case.

For sink-terminal kernels there is no extra precondition on the
terminal sink ('KOut' or 'KBusOut'): it has no audio output, and its
bus index lives in 'rnControls', not 'rnInputs'.

Step-§4.B fusion claims its members /before/ §4.C runs, so
'fuseRuntimeGraph' must skip nodes that are members of a
non-'RNodeLoop' region — otherwise §4.C would elide a Gain that the
region kernel still expects to address by control slot. The candidate
predicate in 'fuseRuntimeGraph' enforces that gate.
-}

-- | §4.B: scan every region for fused-kernel shape matches and split
-- / re-tag accordingly. The selector recurses over the suffix after
-- each match, so a single original 'RNodeLoop' region that contains
-- @N@ independent eligible chains is reduced to its full maximal
-- non-overlapping selection in one compile pass — not @N@ accidental
-- re-runs.
--
-- Idempotent: a second pass is a no-op because regions already tagged
-- with a non-'RNodeLoop' kernel are returned unchanged, and any
-- 'RNodeLoop' region produced by an earlier pass is exactly the
-- pre/post slice that already failed to match.
--
-- See Note [Region kernel selection].
selectRegionKernels :: RuntimeGraph -> RuntimeGraph
selectRegionKernels rg =
  let nodeMap :: M.Map NodeIndex RuntimeNode
      nodeMap = M.fromList [(rnIndex n, n) | n <- rgNodes rg]

      -- Drop empty parts; stamp rrIndex with a placeholder
      -- (renumbered after splat) and inherit rrRate from the
      -- enclosing original region.
      placeholder = RegionIndex (-1)
      mkPart rate ks ker
        | null ks   = []
        | otherwise =
            [ RuntimeRegion
                { rrIndex     = placeholder
                , rrRate      = rate
                , rrNodes     = ks
                , rrExec      = execKernel ker
                , rrFootprint = emptyResourceFootprint
                  -- Re-derived by 'attachRegionFootprints' after
                  -- 'selectRegionKernels' finishes splitting; safe to
                  -- leave empty until then.
                }
            ]

      split :: RuntimeRegion -> [RuntimeRegion]
      split r
        | rrKernel r /= RNodeLoop = [r]
        | otherwise =
            case findKernelMatch nodeMap (rrNodes r) of
              Nothing -> [r]
              Just KernelMatch{ kmOffset = off, kmLength = len, kmKernel = kern } ->
                let members      = rrNodes r
                    (pre, restA) = splitAt off members
                    (mid, post)  = splitAt len restA
                    rate         = rrRate r
                    -- The prefix cannot itself contain an earlier
                    -- match (findKernelMatch returns the leftmost
                    -- offset across all shapes), so it stays
                    -- RNodeLoop without further inspection. The
                    -- suffix may contain another independent chain of
                    -- any recognized shape — recurse on a synthetic
                    -- RNodeLoop region carrying the same rate so the
                    -- selector reaches its own fixed point in one
                    -- pass.
                    postRegion =
                      RuntimeRegion
                        { rrIndex     = placeholder
                        , rrRate      = rate
                        , rrNodes     = post
                        , rrExec      = ExecNodeLoop
                        , rrFootprint = emptyResourceFootprint
                          -- See note on 'mkPart'.
                        }
                in  mkPart rate pre RNodeLoop
                 ++ mkPart rate mid kern
                 ++ (if null post then [] else split postRegion)

      splat = concatMap split (rgRuntimeRegions rg)

      renumbered = zipWith setIx [0..] splat
        where setIx i r = r { rrIndex = RegionIndex i }
  in rg { rgRuntimeRegions = renumbered }

-- | Result of a successful kernel-shape lookup in 'findKernelMatch'.
-- Carrying the matched length explicitly makes the selector
-- independent of any single hardcoded arity (the 3-node-only era) and
-- lets the descriptor grow with new shapes ('RSawLpfGainOut' is the
-- first 4-node entry) without further changes to
-- 'selectRegionKernels'.
data KernelMatch = KernelMatch
  { kmOffset :: !Int            -- ^ Member offset of the match.
  , kmLength :: !Int            -- ^ Number of consumed members; equals 'kernelArity'.
  , kmKernel :: !RegionKernel   -- ^ Tag the matched region carries.
  }
  deriving stock (Eq, Show)

-- | Look for the leftmost match of any recognized kernel shape in a
-- region's member list.
--
-- /Longest-match priority/ at each offset: a 4-node match beats a
-- 3-node match starting at the same position, so a chain @[KSawOsc,
-- KLPF, KGain, KOut]@ is claimed by 'RSawLpfGainOut' as a whole
-- rather than getting its prefix cherry-picked by 'RSawLpfGain'.
-- Without this, the existing 3-node kernel would always win on a
-- 4-node chain (the prefix matches), the terminating 'Out' would land
-- in a trailing 'RNodeLoop' region, and the buffer-vs-sink protocol
-- distinction the kernels are meant to expose would be invisible.
--
-- Shapes are listed longest-first; ties (same length, distinct
-- predicates) fall through in declaration order, but every existing
-- shape is mutually exclusive at the leading-kind level ('KSawOsc' vs
-- 'KSinOsc') so ordering only matters when a future shape collides on
-- prefix.
findKernelMatch
  :: M.Map NodeIndex RuntimeNode
  -> [NodeIndex]
  -> Maybe KernelMatch
findKernelMatch nodes = go 0
  where
    -- Try each candidate at the current offset, longest first; if
    -- none match, advance by one and retry.
    go !i ixs = case (matchHere ixs, ixs) of
      (Just km, _)  -> Just km { kmOffset = i }
      (Nothing, _ : rest) -> go (i + 1) rest
      (Nothing, [])       -> Nothing

    matchHere ixs = case ixs of
      a : b : c : d : _
        | matchesSawLpfGainOut nodes a b c d ->
            Just (mkMatch RSawLpfGainOut)
        | matchesBusInLpfGainOut nodes a b c d ->
            Just (mkMatch RBusInLpfGainOut)
        | matchesNoiseLpfGainOut nodes a b c d ->
            Just (mkMatch RNoiseLpfGainOut)
      _ -> match3 ixs

    match3 ixs = case ixs of
      a : b : c : _
        | matchesSawLpfGain   nodes a b c -> Just (mkMatch RSawLpfGain)
        | matchesSinGainOut   nodes a b c -> Just (mkMatch RSinGainOut)
        | matchesSawGainOut   nodes a b c -> Just (mkMatch RSawGainOut)
        | matchesNoiseGainOut nodes a b c -> Just (mkMatch RNoiseGainOut)
      _ -> Nothing

    -- 'kmOffset = -1' is a placeholder; 'go' fills in the real
    -- offset once the match is hoisted to the top level.
    mkMatch k = KernelMatch
      { kmOffset = -1
      , kmLength = kernelArity k
      , kmKernel = k
      }

matchesSawLpfGain
  :: M.Map NodeIndex RuntimeNode
  -> NodeIndex -> NodeIndex -> NodeIndex
  -> Bool
matchesSawLpfGain nodes sawIx lpfIx gainIx =
  case (M.lookup sawIx nodes, M.lookup lpfIx nodes, M.lookup gainIx nodes) of
    (Just saw, Just lpf, Just gain) ->
      rnKind saw == KSawOsc
        && rnKind lpf == KLPF
        && rnKind gain == KGain
        && not (rnElided saw)
        && not (rnElided lpf)
        && not (rnElided gain)
        && rnConsumerCount saw == 1
        && rnConsumerCount lpf == 1
        && signalSourceIs sawIx lpf
        && signalSourceIs lpfIx gain
        && isScalarGain gain
    _ -> False

-- | The sink-terminal shape: KSinOsc → KGain → /sink/
-- with the same single-use internal-edge / scalar-gain rules as
-- 'matchesSawLpfGain'. The terminal sink can be either 'KOut' or
-- 'KBusOut' — both dispatch to the same per-node kernel
-- ('process_out' on the C++ side) and read their bus index from
-- 'rnControls[0]', so the kernel body absorbs them identically. The
-- terminal node has 'rnConsumerCount == 0' by construction (sinks
-- have no downstream readers), so the only constraint on it is that
-- the gain feeds it through port 0.
matchesSinGainOut
  :: M.Map NodeIndex RuntimeNode
  -> NodeIndex -> NodeIndex -> NodeIndex
  -> Bool
matchesSinGainOut nodes sinIx gainIx outIx =
  case (M.lookup sinIx nodes, M.lookup gainIx nodes, M.lookup outIx nodes) of
    (Just sin_, Just gain, Just out_) ->
      rnKind sin_ == KSinOsc
        && rnKind gain == KGain
        && isSinkTerminal (rnKind out_)
        && not (rnElided sin_)
        && not (rnElided gain)
        && not (rnElided out_)
        && rnConsumerCount sin_  == 1
        && rnConsumerCount gain == 1
        && signalSourceIs sinIx gain
        && signalSourceIs gainIx out_
        && isScalarGain gain
    _ -> False

-- | The saw counterpart of 'matchesSinGainOut': KSawOsc → KGain → /sink/
-- with the same single-use internal-edge/scalar-gain rules. The
-- /sink/ is either 'KOut' or 'KBusOut'. Identical preconditions to
-- 'matchesSinGainOut' modulo the producer kind; the C++ side reuses
-- 'drive_oscillator' with @q::saw@ in place of @q::sin@ and the same
-- 'SinkAccumulator'.
matchesSawGainOut
  :: M.Map NodeIndex RuntimeNode
  -> NodeIndex -> NodeIndex -> NodeIndex
  -> Bool
matchesSawGainOut nodes sawIx gainIx outIx =
  case (M.lookup sawIx nodes, M.lookup gainIx nodes, M.lookup outIx nodes) of
    (Just saw, Just gain, Just out_) ->
      rnKind saw  == KSawOsc
        && rnKind gain == KGain
        && isSinkTerminal (rnKind out_)
        && not (rnElided saw)
        && not (rnElided gain)
        && not (rnElided out_)
        && rnConsumerCount saw  == 1
        && rnConsumerCount gain == 1
        && signalSourceIs sawIx  gain
        && signalSourceIs gainIx out_
        && isScalarGain gain
    _ -> False

-- | The noise counterpart of 'matchesSinGainOut': KNoiseGen → KGain → /sink/
-- Same shape gates as the oscillator sink-terminal predicates, but
-- covers a different state class — NoiseGen carries a
-- 'q::white_noise_gen' xorshift PRNG rather than a
-- 'q::phase_iterator', and has no audio inputs and no controls of its
-- own. The matcher's preconditions don't change because they only
-- constrain edges, kinds, and consumer counts; the per-sample DSP
-- body on the C++ side is what differs (one PRNG read instead of an
-- oscillator phase advance).
matchesNoiseGainOut
  :: M.Map NodeIndex RuntimeNode
  -> NodeIndex -> NodeIndex -> NodeIndex
  -> Bool
matchesNoiseGainOut nodes noiseIx gainIx outIx =
  case (M.lookup noiseIx nodes, M.lookup gainIx nodes, M.lookup outIx nodes) of
    (Just noise, Just gain, Just out_) ->
      rnKind noise == KNoiseGen
        && rnKind gain == KGain
        && isSinkTerminal (rnKind out_)
        && not (rnElided noise)
        && not (rnElided gain)
        && not (rnElided out_)
        && rnConsumerCount noise == 1
        && rnConsumerCount gain  == 1
        && signalSourceIs noiseIx gain
        && signalSourceIs gainIx  out_
        && isScalarGain gain
    _ -> False

-- | The 4-node sink-terminal shape: KSawOsc → KLPF → KGain → /sink/.
-- Combines the buffer-terminal saw/lpf/gain processing of
-- 'matchesSawLpfGain' with the sink-terminal absorption of
-- 'matchesSinGainOut'. The terminal can be either 'KOut' or
-- 'KBusOut' — same reasoning as 'matchesSinGainOut': both
-- dispatch to 'process_out' on the C++ side and the kernel body
-- absorbs them identically. Adds an explicit
-- @rnConsumerCount gain == 1@ requirement on top of the 3-node
-- buffer-terminal kernel: when that holds, the gain's output
-- buffer is unread by anything outside the chain and the kernel
-- is free to inline the bus accumulation. When it doesn't,
-- longest-match falls through to 'matchesSawLpfGain' (which
-- materializes the gain's buffer for external readers).
matchesSawLpfGainOut
  :: M.Map NodeIndex RuntimeNode
  -> NodeIndex -> NodeIndex -> NodeIndex -> NodeIndex
  -> Bool
matchesSawLpfGainOut nodes sawIx lpfIx gainIx outIx =
  case ( M.lookup sawIx nodes
       , M.lookup lpfIx nodes
       , M.lookup gainIx nodes
       , M.lookup outIx nodes ) of
    (Just saw, Just lpf, Just gain, Just out_) ->
      rnKind saw  == KSawOsc
        && rnKind lpf  == KLPF
        && rnKind gain == KGain
        && isSinkTerminal (rnKind out_)
        && not (rnElided saw)
        && not (rnElided lpf)
        && not (rnElided gain)
        && not (rnElided out_)
        && rnConsumerCount saw  == 1
        && rnConsumerCount lpf  == 1
        && rnConsumerCount gain == 1
        && signalSourceIs sawIx  lpf
        && signalSourceIs lpfIx  gain
        && signalSourceIs gainIx out_
        && isScalarGain gain
    _ -> False

-- | The 4-node BusIn-rooted sink-terminal shape: KBusIn → KLPF →
-- KGain → /sink/. The first non-oscillator producer in the §4.B
-- family — the chain's source isn't a generator with phase or PRNG
-- state, it's a bus reader. Same single-use internal-edge /
-- scalar-gain / sink-class rules as 'matchesSawLpfGainOut',
-- mechanically substitute KSawOsc → KBusIn at the head. The
-- 'rnConsumerCount busin == 1' precondition is what licenses the
-- kernel to read 'output_buses[busin_bus][i]' inline rather than
-- materializing a copy through 'process_busin' — if anything else
-- read the BusIn's output buffer, that buffer would have to be
-- written for them, and the fusion would lose its point.
--
-- The matcher has no per-shape rule for the BusIn's bus index. A bus
-- that no node wrote to in the same block reads zero (per
-- 'process_busin' semantics), and the kernel inherits that behavior —
-- silence on the sink-bus side. That's a runtime fact, not a
-- compile-time one, so it doesn't constrain the match.
matchesBusInLpfGainOut
  :: M.Map NodeIndex RuntimeNode
  -> NodeIndex -> NodeIndex -> NodeIndex -> NodeIndex
  -> Bool
matchesBusInLpfGainOut nodes businIx lpfIx gainIx outIx =
  case ( M.lookup businIx nodes
       , M.lookup lpfIx   nodes
       , M.lookup gainIx  nodes
       , M.lookup outIx   nodes ) of
    (Just busin, Just lpf, Just gain, Just out_) ->
      rnKind busin == KBusIn
        && rnKind lpf  == KLPF
        && rnKind gain == KGain
        && isSinkTerminal (rnKind out_)
        && not (rnElided busin)
        && not (rnElided lpf)
        && not (rnElided gain)
        && not (rnElided out_)
        && rnConsumerCount busin == 1
        && rnConsumerCount lpf   == 1
        && rnConsumerCount gain  == 1
        && signalSourceIs businIx lpf
        && signalSourceIs lpfIx   gain
        && signalSourceIs gainIx  out_
        && isScalarGain gain
    _ -> False

-- | The 4-node Noise-rooted sink-terminal shape: KNoiseGen → KLPF
-- → KGain → /sink/. Mechanically the noise counterpart of
-- 'matchesSawLpfGainOut' / 'matchesBusInLpfGainOut': swap the
-- producer kind at the head, keep every other gate. NoiseGen has
-- no audio inputs of its own (the kernel pulls samples directly
-- from the producer's PRNG state), so the only producer-side
-- precondition is the single-consumer requirement that licenses
-- skipping the materialized noise output buffer.
--
-- The matcher imposes no rule on the producer's PRNG state (it's a
-- runtime fact); the equivalence pin between kernel and per-node
-- baseline lives in 'process_region_noise_lpf_gain_out', which calls
-- 'noisegen->noise()' once per output sample in the same order
-- 'process_noisegen' would have.
matchesNoiseLpfGainOut
  :: M.Map NodeIndex RuntimeNode
  -> NodeIndex -> NodeIndex -> NodeIndex -> NodeIndex
  -> Bool
matchesNoiseLpfGainOut nodes noiseIx lpfIx gainIx outIx =
  case ( M.lookup noiseIx nodes
       , M.lookup lpfIx   nodes
       , M.lookup gainIx  nodes
       , M.lookup outIx   nodes ) of
    (Just noise_, Just lpf, Just gain, Just out_) ->
      rnKind noise_ == KNoiseGen
        && rnKind lpf  == KLPF
        && rnKind gain == KGain
        && isSinkTerminal (rnKind out_)
        && not (rnElided noise_)
        && not (rnElided lpf)
        && not (rnElided gain)
        && not (rnElided out_)
        && rnConsumerCount noise_ == 1
        && rnConsumerCount lpf    == 1
        && rnConsumerCount gain   == 1
        && signalSourceIs noiseIx lpf
        && signalSourceIs lpfIx   gain
        && signalSourceIs gainIx  out_
        && isScalarGain gain
    _ -> False

-- | Sink-terminal classifier. Both 'KOut' and 'KBusOut' dispatch to
-- the same per-node kernel ('process_out' on the C++ side) and read
-- their bus index from @rnControls[0]@, so the §4.B sink-terminal
-- kernels accept either as the absorbed terminal. The kernel body
-- is bus-kind-agnostic: the difference between 'KOut' and 'KBusOut'
-- lives at the source level (final hardware output vs intermediate
-- audio bus) and the audio callback routes them identically once
-- they land in the shared bus pool. See @Note [Bus model]@ near the
-- @NodeKind@ enum in @rt_graph.cpp@.
isSinkTerminal :: NodeKind -> Bool
isSinkTerminal KOut    = True
isSinkTerminal KBusOut = True
isSinkTerminal _       = False

-- | Shared between every 'matches*' kernel predicate: the principal
-- audio input of @node@ — port 0 — must be wired to @srcIx@'s
-- principal output port (also port 0). Used to confirm the chain's
-- internal edge is the only producer-side connection to the next
-- member.
--
-- Both port indices are pinned to 0. Today every UGen has a single
-- output port, so wiring through any other source port can't arise
-- from the public DSL; encoding the constraint explicitly hardens the
-- matcher against a future multi-output node that could otherwise
-- sneak through with @RFrom s (PortIndex 1)@ on the same source.
signalSourceIs :: NodeIndex -> RuntimeNode -> Bool
signalSourceIs srcIx node = case rnInputs node of
  RFrom s (PortIndex 0) : _ -> s == srcIx
  _                         -> False

-- | Shared between every 'matches*' kernel predicate that names a
-- gain step: the gain has an audio source on port 0 and a constant
-- control on port 1. Audio-modulated gains (RFrom on port 1) block
-- kernel selection so per-sample arithmetic stays bit-equal to the
-- unfused chain.
isScalarGain :: RuntimeNode -> Bool
isScalarGain node = case rnInputs node of
  [RFrom _ _, RConst _] -> True
  _                     -> False
