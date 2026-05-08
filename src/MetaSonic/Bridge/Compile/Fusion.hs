-- |
-- Module      : MetaSonic.Bridge.Compile.Fusion
-- Description : §4.C scalar affine fusion — elide single-edge
--               scalar Gain / Add chains into 'RFused' inputs on
--               the eventual non-candidate consumer.
--
-- The single entry point is 'fuseRuntimeGraph': a 'RuntimeGraph'
-- transform that walks 'rgNodes', identifies candidate Gains and
-- Adds, and rewrites each non-candidate consumer's 'RFrom' inputs
-- into 'RFused' values that absorb the upstream candidate chain.
-- Every elided node stays in 'rgNodes' with 'rnElided = True' so
-- its 'NodeIndex' remains addressable through 'set_control' and
-- the realtime control queue.
--
-- See Note [Scalar affine fusion] for the algorithmic contract:
-- which nodes qualify, how chains are extended, which 'FusedInput'
-- variant is emitted for which chain shape, and the float-rounding
-- identity discipline.
--
-- Re-exported by 'MetaSonic.Bridge.Compile' for the public surface.
module MetaSonic.Bridge.Compile.Fusion
  ( fuseRuntimeGraph
  ) where

import qualified Data.Map.Strict as M
import qualified Data.Set        as S

import           MetaSonic.Bridge.Compile.Types
import           MetaSonic.Types

{- Note [Scalar affine fusion]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The Step-C fusion pass elides scalar 'KGain' and 'KAdd' nodes whose
entire role is to multiply or bias a single-consumer signal by a
control-rate scalar. After fusion, a non-candidate consumer reads
the upstream producer directly through an 'RFused' input that
applies the chain of operations inline.

A node @g@ is a /candidate/ iff all of the following hold:

  1. @rnOutputUse g == RegionLocal@ — its output never escapes the
     region (Step B-Light).
  2. @rnConsumerCount g == 1@ — a single 'FromNode' reader, so
     destructive single-edge rewriting cannot orphan a sibling
     consumer.
  3. @not (rnElided g)@ — not already elided by a prior pass.
  4. The kind-specific shape:

     * 'KGain' with @rnInputs == [RFrom _ _, RConst _]@ — signal on
       port 0, scalar gain on port 1. Audio-modulated gains
       (@[RFrom, RFrom]@) stay dispatched.
     * 'KAdd' with @rnInputs == [RFrom _ _, RConst _]@ — signal on
       port 0, bias from control slot 1.
     * 'KAdd' with @rnInputs == [RConst _, RFrom _ _]@ — bias from
       control slot 0, signal on port 1. Audio-rate Add
       (@[RFrom, RFrom]@) stays dispatched.

Chain extension. The rewrite is driven from /non-candidate/
consumers: for each input @RFrom srcIx _@ whose @srcIx@ is a
candidate, walk upstream through candidates and collect them into a
chain @[Sn, …, S1]@ stopping at the first non-candidate source. The
walked candidates are marked 'rnElided'; the consumer's input
becomes 'RFused' carrying the upstream source and the chain in
source-to-sink order @[S1, …, Sn]@. Each chain element is tagged as
either 'AffScale' (from a Gain) or 'AffBias' (from an Add).

Variant selection. A pure-scale chain (every step is 'AffScale')
emits 'FScaleFrom' (length 1) or 'FScaleChainFrom' (length ≥ 2),
preserving the IR shape that single-edge tests already pin. A chain
that contains at least one 'AffBias' step emits 'FAffineFrom'
regardless of length — including a single elided Add. Mixed Gain /
Add chains in either order compose end-to-end through one
'FAffineFrom' on the eventual non-candidate sink.

Driving the rewrite from non-candidate consumers means a candidate
whose own consumer is /also/ a candidate is never the rewriting
site — the chain is collected once, by the eventual non-candidate
sink. This is how the algorithm avoids both double-fusion and
recursion on already-fused inputs.

Termination. Each candidate's 'rnConsumerCount' is exactly 1, so a
chain has a unique sink. The graph is a DAG, so the upstream walk
cannot loop. The walk terminates at the first non-candidate
'rnIndex' encountered — typically the producer of the original
signal (e.g., a 'KSinOsc'), but it can also be an audio-modulated
Gain or audio-rate Add whose shape gate excludes it.

Identity preservation. Every elided node remains in 'rgNodes' with
'rnElided = True', preserving its 'NodeIndex'. Direct
'rt_graph_instance_set_control' / realtime control writes to the
elided node continue to land on @inst.nodes[node].controls[slot]@;
the runtime reads each scale or bias live at fused-input evaluation
time, exactly as the kernel's controls-fallback branch does. No
control-addressable identity disappears, including for nodes in
the middle of a chain.

Float-rounding identity. The fused resolver applies steps in
source-to-sink order, casting each control to 'float' before the
operation, mirroring chained 'process_gain' / 'process_add' kernels
exactly. Scales are /not/ pre-multiplied and biases are /not/
pre-summed (float arithmetic is non-associative), so chained-fused
output is bit-identical to chained-unfused output.

Counter-state. 'rnConsumerCount' and 'rnOutputUse' are not
recomputed by the rewrite. They reflect the post-compile state,
not the post-fusion state. A future fusion pass that needs updated
counts must rebuild them.
-}

-- | Step C: scalar Gain / Add fusion with chain extension. Walks
-- 'rgNodes', identifies candidate Gains and Adds, and for each
-- non-candidate consumer rewrites @RFrom srcIx _@ inputs into
-- 'RFused' values that absorb the upstream candidate chain. All
-- candidates in a fused chain are marked elided; their 'NodeIndex'
-- and controls remain addressable.
--
-- Idempotent: a second call is a no-op because previously-elided
-- nodes fail the candidate predicate ('rnElided' check) and the
-- consumer inputs already carry 'RFused' values that the rewrite
-- ignores.
--
-- See Note [Scalar affine fusion].
fuseRuntimeGraph :: RuntimeGraph -> RuntimeGraph
fuseRuntimeGraph rg =
  let nodes = rgNodes rg

      -- §4.B: nodes that are members of a non-'RNodeLoop' region
      -- have been claimed by a fused region kernel and must be
      -- left alone here. Eliding them via §4.C would invalidate
      -- the region kernel's per-sample loop (it expects the saw,
      -- lpf, and gain nodes to all stay live and addressable).
      regionFused :: S.Set NodeIndex
      regionFused = S.fromList
        [ ix
        | r  <- rgRuntimeRegions rg
        , rrKernel r /= RNodeLoop
        , ix <- rrNodes r
        ]

      -- For a candidate node, classify its incoming signal port and
      -- the affine step it contributes. Returns 'Nothing' for any
      -- node that doesn't match a candidate shape (including
      -- audio-modulated Gain, audio-rate Add, and non-Gain non-Add
      -- nodes). Pulled out of the candidate predicate so the chain
      -- walker can reuse the same dispatch.
      candidateView
        :: RuntimeNode
        -> Maybe (NodeIndex, PortIndex, AffineStep)
      candidateView n
        | rnElided n                      = Nothing
        | rnOutputUse n /= RegionLocal    = Nothing
        | rnConsumerCount n /= 1          = Nothing
        | rnIndex n `S.member` regionFused = Nothing
        | otherwise = case (rnKind n, rnInputs n) of
            (KGain, [RFrom s p, RConst _]) ->
              Just (s, p, AffScale (rnIndex n) (ControlIndex 0))
            (KAdd,  [RFrom s p, RConst _]) ->
              Just (s, p, AffBias  (rnIndex n) (ControlIndex 1))
            (KAdd,  [RConst _, RFrom s p]) ->
              Just (s, p, AffBias  (rnIndex n) (ControlIndex 0))
            _ -> Nothing

      candById :: M.Map NodeIndex (NodeIndex, PortIndex, AffineStep)
      candById = M.fromList
        [ (rnIndex n, view)
        | n <- nodes
        , Just view <- [candidateView n]
        ]

      -- Walk upstream from a candidate node. Returns:
      --   * terminal source node + port (the first non-candidate
      --     producer reached)
      --   * the list of elided node indices (chain members, any
      --     order — only used as a set)
      --   * the chain of AffineStep in source-to-sink order
      --     (first element is the upstream-most candidate)
      walkChain
        :: NodeIndex
        -> (NodeIndex, PortIndex, [NodeIndex], [AffineStep])
      walkChain ix =
        let (src, srcPort, here) = candById M.! ix  -- safe: caller checked
        in case M.lookup src candById of
             Nothing ->
               -- Source is non-candidate: chain ends here.
               (src, srcPort, [ix], [here])
             Just _  ->
               -- Source is itself a candidate: extend upstream and
               -- append the local step so source-to-sink order is
               -- preserved (upstream comes first).
               let (term, termPort, elided, stepsUp) = walkChain src
               in (term, termPort, ix : elided, stepsUp ++ [here])

      -- Try to fuse a single consumer-side input. Returns the
      -- (possibly rewritten) input plus any node indices that
      -- should be marked elided as a result.
      tryFuseInput :: RuntimeInput -> (RuntimeInput, [NodeIndex])
      tryFuseInput inp = case inp of
        RFrom srcIx _port
          | M.member srcIx candById ->
              let (src, srcPort, elidedIxs, steps) = walkChain srcIx
                  -- Pure-scale chains stay on the existing
                  -- FScaleFrom / FScaleChainFrom variants so
                  -- single-edge / pure-chain tests pin the older
                  -- shape unchanged. Anything with a bias step
                  -- (single Add, pure-bias chain, mixed) goes
                  -- into FAffineFrom.
                  fused = case asScalesOnly steps of
                    Just [ScaleRef g0 c0] ->
                      FScaleFrom src srcPort g0 c0
                    Just sr@(_:_:_) ->
                      FScaleChainFrom src srcPort sr
                    _ ->
                      FAffineFrom src srcPort steps
              in (RFused fused, elidedIxs)
        _ -> (inp, [])

      -- If every step is an AffScale, return them as ScaleRefs;
      -- otherwise Nothing.
      asScalesOnly :: [AffineStep] -> Maybe [ScaleRef]
      asScalesOnly = traverse stepToScale
        where
          stepToScale (AffScale n c) = Just (ScaleRef n c)
          stepToScale (AffBias  _ _) = Nothing

      -- Process one node. Candidates are left alone here — they
      -- become elided once a downstream non-candidate consumer
      -- walks them. Non-candidates have each input considered for
      -- chain fusion.
      processNode n
        | M.member (rnIndex n) candById = (n, [])
        | otherwise =
            let pairs   = map tryFuseInput (rnInputs n)
                inputs' = map fst pairs
                elided  = concatMap snd pairs
            in (n { rnInputs = inputs' }, elided)

      processed = map processNode nodes
      newNodes  = map fst processed
      elidedSet = S.fromList (concatMap snd processed)

      finalize n
        | rnIndex n `S.member` elidedSet = n { rnElided = True }
        | otherwise                      = n
  in rg { rgNodes = map finalize newNodes }
