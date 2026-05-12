{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Bridge.Planner
-- Description : Phase 7.C survey-only fusion planner
--
-- The Phase 7.C planner is a Haskell-only, diagnostic-only pass that
-- walks a 'RuntimeGraph', identifies contiguous sink-terminal
-- candidates within single regions, and emits a 'Verdict' per
-- candidate. Nothing executes; nothing crosses the FFI.
--
-- This module defines the verdict-bearing data types, the planner
-- pass that produces them, and the selected-candidate view consumed
-- by survey/snapshot tooling.
--
-- See @notes/2026-05-11-phase-7c-planner-decision.md@ for the
-- legality rule list, the "no chain-caps union" constraint, and the
-- relationship to the existing §4.B kernel set.

module MetaSonic.Bridge.Planner
  ( -- * Verdict surface
    Verdict (..)
  , FusionCandidate (..)
  , RejectionReason (..)
    -- * Convenience predicates
  , verdictCandidate
  , isAccepted
  , isRejected
  , selectedFusionCandidates
    -- * Planning pass
  , planRuntimeGraph
  , planRegion
    -- * Allow list (exposed for tests)
  , statefulInteriorAllowList
  ) where

import           Control.DeepSeq                  (NFData)
import           Data.List                        (find, isInfixOf)
import           Data.Maybe                       (fromMaybe, listToMaybe,
                                                   mapMaybe)
import           GHC.Generics                     (Generic)

import           MetaSonic.Bridge.Compile.Types   (RegionIndex,
                                                   RegionKernel (..),
                                                   RuntimeInput (..),
                                                   RuntimeGraph (..),
                                                   RuntimeNode (..),
                                                   RuntimeRegion (..))
import           MetaSonic.Types                  (KindCapability (..),
                                                   NodeIndex, NodeKind (..),
                                                   PortIndex (..),
                                                   kindCapabilities,
                                                   kindLatency)

-- | A contiguous, dense-order sub-sequence of nodes within a single
-- 'RuntimeRegion' whose last member is a 'CapSinkTerminal' node.
--
-- The planner walks regions, builds 'FusionCandidate's, then issues
-- a 'Verdict' per candidate. The candidate carries enough context
-- for both diagnostic output and future cost-lab joins; it
-- intentionally does not carry a profitability estimate.
data FusionCandidate = FusionCandidate
  { fcRegion       :: !RegionIndex
    -- ^ The region the candidate lives in. Candidates never cross
    -- region boundaries.
  , fcMembers      :: ![NodeIndex]
    -- ^ Dense-order member indices, head to terminal sink.
  , fcMemberKinds  :: ![NodeKind]
    -- ^ The 'NodeKind' for each member, parallel to 'fcMembers'.
    -- Carried explicitly so consumers don't need to re-lookup
    -- against the 'RuntimeGraph' for shape reporting.
  , fcMatchedShape :: !(Maybe RegionKernel)
    -- ^ The §4.B kernel that already claims this segment, if any.
    -- 'Just k' means a hand-written kernel already handles this
    -- shape; an 'Accepted' candidate with 'Just _' is "already
    -- covered" and should not motivate a new generated kernel
    -- until cost-lab evidence shows the generated path beats the
    -- hand-written one.
  , fcLengthNodes  :: !Int
    -- ^ @length fcMembers@. Carried so consumers don't recompute
    -- it; the planner asserts this matches 'fcMembers' length.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Why the planner rejected a candidate. Each constructor cites
-- the specific node or structural fact that caused the rejection,
-- so future cost-model joins can key off the reason rather than a
-- catch-all category.
--
-- Adding a new rejection cause should add a new constructor rather
-- than overloading 'ReasonStatefulInterior' or
-- 'ReasonResourceMidChain' — the names favor "what specifically
-- failed" over a category bucket.
data RejectionReason
  = ReasonHardBarrier !NodeIndex !NodeKind
    -- ^ A 'CapHardBarrier' node appeared anywhere in the candidate.
    -- Today only 'KStaticPlugin' triggers this; refinement is the
    -- §6.E.3 per-plugin catalog follow-up.
  | ReasonLatencyMidChain !NodeIndex !NodeKind !Int
    -- ^ A 'CapLatencyBearing' node appeared somewhere other than
    -- the terminal sink. The 'Int' carries the kind's declared
    -- latency (samples) for diagnostic reporting.
  | ReasonResourceMidChain !NodeIndex !NodeKind
    -- ^ A 'CapResourceAccess' node appeared in the candidate but
    -- was not the terminal sink. This is the rule that
    -- distinguishes a safe terminal 'KOut' from a hazardous mid-
    -- chain 'KBusOut'.
  | ReasonStatefulInterior !NodeIndex !NodeKind
    -- ^ A 'CapStatefulOp' interior node was not on the planner's
    -- narrow allow-list (initially 'KLPF', 'KHPF', 'KBPF', 'KNotch'
    -- in §4.B-recognizable shapes). Other stateful kinds need
    -- per-shape cost-lab evidence before joining the allow-list.
  | ReasonFanoutEscape !NodeIndex !Int
    -- ^ A non-terminal node fans out to more than one consumer.
    -- The 'Int' is the consumer count. Fanout absorption is a
    -- profitability question, not legality, but the planner
    -- rejects fanout candidates today so the cost lab can study
    -- the duplicated-work tradeoff in isolation.
  | ReasonNonAdjacentDataflow !NodeIndex !NodeIndex !NodeKind
    -- ^ The previous member does not feed the next member's
    -- principal signal input. The fields are previous member,
    -- next member, and next kind.
  | ReasonTooShort !Int
    -- ^ The candidate is below the minimum length (today: 2). The
    -- 'Int' is the actual length.
  | ReasonNoTerminalSink
    -- ^ Structural; included for future-proofing. Candidate
    -- formation guarantees a terminal sink today, so this is not
    -- triggerable.
  | ReasonCrossesRegion !NodeIndex
    -- ^ Structural; included for future-proofing. Candidates are
    -- formed within a single region today, so this is not
    -- triggerable.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | The planner's per-candidate output. 'Accepted' means the
-- candidate cleared every legality rule; it says nothing about
-- profitability (that lives in Phase 7.A's cost lab).
data Verdict
  = Accepted !FusionCandidate
  | Rejected !FusionCandidate !RejectionReason
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Project out the underlying candidate regardless of verdict.
verdictCandidate :: Verdict -> FusionCandidate
verdictCandidate (Accepted c)   = c
verdictCandidate (Rejected c _) = c

isAccepted :: Verdict -> Bool
isAccepted (Accepted _) = True
isAccepted _            = False

isRejected :: Verdict -> Bool
isRejected (Rejected _ _) = True
isRejected _              = False

-- | Accepted candidates after nested candidates have been coalesced
-- to maximal same-region segments. The raw 'Verdict' stream remains
-- useful for diagnostics; this selected view is the executor-facing
-- shape that avoids treating @Gain -> Out@ as generated-eligible when
-- it is just a suffix of an accepted @Sin -> Gain -> Out@ candidate.
--
-- Call this per 'RuntimeGraph' / survey row. 'NodeIndex' and
-- 'RegionIndex' are graph-local, so aggregating verdicts across
-- graphs before selection would merge unrelated candidates.
selectedFusionCandidates :: [Verdict] -> [FusionCandidate]
selectedFusionCandidates verdicts =
  [ c
  | c <- accepted
  , not (any (`strictlyContainsCandidate` c) accepted)
  ]
  where
    accepted = [c | Accepted c <- verdicts]

strictlyContainsCandidate :: FusionCandidate -> FusionCandidate -> Bool
strictlyContainsCandidate outer inner =
  fcRegion outer == fcRegion inner
    && fcLengthNodes outer > fcLengthNodes inner
    && fcMembers inner `isInfixOf` fcMembers outer

------------------------------------------------------------
-- Planning pass
------------------------------------------------------------

-- | Plan every region in a runtime graph. The output is a flat
-- list of verdicts; consumers can group by 'fcRegion' or filter by
-- 'isAccepted' / 'isRejected'.
planRuntimeGraph :: RuntimeGraph -> [Verdict]
planRuntimeGraph rg =
  concatMap (planRegion rg) (rgRuntimeRegions rg)

-- | Plan a single region.
--
-- Candidates are formed by scanning region members in dense order.
-- For each member that carries 'CapSinkTerminal', every contiguous
-- sub-sequence of length ≥ 2 ending at that sink is a candidate;
-- each candidate gets a 'Verdict'. This intentionally over-reports:
-- a 4-node sink-terminal chain produces three nested candidates
-- (lengths 2, 3, and 4). The cost-lab consumption pass coalesces.
planRegion :: RuntimeGraph -> RuntimeRegion -> [Verdict]
planRegion rg region =
  let memberNodes = mapMaybe (`lookupNode` rg) (rrNodes region)
      sinkPosns   =
        [ i | (i, n) <- zip [0 ..] memberNodes, isSinkTerminal n ]
      candidates  =
        [ slice
        | sinkAt  <- sinkPosns
        , startAt <- [sinkAt - 1, sinkAt - 2 .. 0]
        , let slice = take (sinkAt - startAt + 1) (drop startAt memberNodes)
        , length slice >= 2
        ]
  in map (judgeCandidate region) candidates

judgeCandidate :: RuntimeRegion -> [RuntimeNode] -> Verdict
judgeCandidate region nodes =
  let candidate = mkCandidate region nodes
  in case firstViolation nodes of
       Just r  -> Rejected candidate r
       Nothing -> Accepted candidate

mkCandidate :: RuntimeRegion -> [RuntimeNode] -> FusionCandidate
mkCandidate region nodes =
  FusionCandidate
    { fcRegion       = rrIndex region
    , fcMembers      = map rnIndex nodes
    , fcMemberKinds  = map rnKind  nodes
    , fcMatchedShape = matchedShape region nodes
    , fcLengthNodes  = length nodes
    }

-- | A candidate's matched shape is the region's kernel iff the
-- candidate's members are exactly the region's members and the
-- kernel is a real fused kernel (not 'RNodeLoop'). A candidate that
-- is a proper subset of a fused region's members is not "claimed"
-- by that kernel — the kernel would have to match the candidate's
-- exact shape to claim it.
matchedShape :: RuntimeRegion -> [RuntimeNode] -> Maybe RegionKernel
matchedShape region nodes
  | rrKernel region /= RNodeLoop
  , map rnIndex nodes == rrNodes region
  = Just (rrKernel region)
  | otherwise = Nothing

------------------------------------------------------------
-- Legality rule application
------------------------------------------------------------

-- | Walk the candidate in order and return the first node-level or
-- structural violation. Position-aware: position 0 is the source
-- (relaxed rules for stateful kinds and resource access), positions
-- @[1..len-2]@ are true interior (strict rules), position @len-1@ is
-- the terminal sink. See
-- @notes/2026-05-11-phase-7c-planner-decision.md@.
firstViolation :: [RuntimeNode] -> Maybe RejectionReason
firstViolation nodes =
  let len = length nodes
  in case nodes of
       []    -> Just ReasonNoTerminalSink
       _     ->
         let sink           = last nodes
             nonSinkIndexed = zip [0 :: Int ..] (init nodes)
         in firstJust
              [ checkLength len
              , if isSinkTerminal sink
                  then Nothing
                  else Just ReasonNoTerminalSink
              , firstJust [ checkNonSinkAt pos n
                          | (pos, n) <- nonSinkIndexed ]
              , checkAdjacentDataflow nodes
              ]

checkLength :: Int -> Maybe RejectionReason
checkLength n
  | n < 2     = Just (ReasonTooShort n)
  | otherwise = Nothing

-- | Per-node legality check for a non-sink node at position @pos@.
--
-- Hard barriers and latency-bearing kinds are rejected regardless
-- of position. Resource access and stateful-not-on-allow-list are
-- only rejected at true-interior positions (@pos >= 1@) — the
-- source (@pos == 0@) is allowed to be a stateful producer
-- (e.g., 'KSinOsc' in @Sin → Gain → Out@) or a resource reader
-- (e.g., 'KBusIn' in @BusIn → LPF → Gain → Out@). Fanout escape
-- applies at every non-sink position because duplicating a fanout
-- producer is the same profitability question at any depth.
checkNonSinkAt :: Int -> RuntimeNode -> Maybe RejectionReason
checkNonSinkAt pos n
  | CapHardBarrier `elem` caps =
      Just (ReasonHardBarrier (rnIndex n) (rnKind n))
  | CapLatencyBearing `elem` caps =
      Just (ReasonLatencyMidChain
              (rnIndex n) (rnKind n)
              (fromMaybe 0 (kindLatency (rnKind n))))
  | pos >= 1
  , CapResourceAccess `elem` caps =
      Just (ReasonResourceMidChain (rnIndex n) (rnKind n))
  | pos >= 1
  , CapStatefulOp `elem` caps
  , rnKind n `notElem` statefulInteriorAllowList =
      Just (ReasonStatefulInterior (rnIndex n) (rnKind n))
  | rnConsumerCount n /= 1 =
      Just (ReasonFanoutEscape (rnIndex n) (rnConsumerCount n))
  | otherwise = Nothing
  where
    caps = kindCapabilities (rnKind n)

checkAdjacentDataflow :: [RuntimeNode] -> Maybe RejectionReason
checkAdjacentDataflow nodes =
  firstJust
    [ if principalInputFrom (rnIndex prev) next
        then Nothing
        else Just (ReasonNonAdjacentDataflow
                    (rnIndex prev) (rnIndex next) (rnKind next))
    | (prev, next) <- zip nodes (drop 1 nodes)
    ]

principalInputFrom :: NodeIndex -> RuntimeNode -> Bool
principalInputFrom srcIx node = case rnInputs node of
  RFrom s (PortIndex 0) : _ -> s == srcIx
  _                         -> False

isSinkTerminal :: RuntimeNode -> Bool
isSinkTerminal n =
  CapSinkTerminal `elem` kindCapabilities (rnKind n)

-- | The narrow allow-list of stateful kinds the planner accepts as
-- interior nodes. Biquads only at this slice. Adding 'KDelay',
-- 'KSmooth', or 'KEnv' requires '--fusion-cost-lab' evidence; the
-- list lives here and is intentionally a separate table from
-- 'kindCapabilities'.
statefulInteriorAllowList :: [NodeKind]
statefulInteriorAllowList = [KLPF, KHPF, KBPF, KNotch]

------------------------------------------------------------
-- Local helpers
------------------------------------------------------------

lookupNode :: NodeIndex -> RuntimeGraph -> Maybe RuntimeNode
lookupNode ix rg = find (\n -> rnIndex n == ix) (rgNodes rg)

firstJust :: [Maybe a] -> Maybe a
firstJust = listToMaybe . mapMaybe id
