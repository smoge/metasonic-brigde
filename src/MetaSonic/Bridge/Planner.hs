{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Bridge.Planner
-- Description : Phase 7.C survey-only fusion planner (data types)
--
-- The Phase 7.C planner is a Haskell-only, diagnostic-only pass that
-- walks a 'RuntimeGraph', identifies contiguous sink-terminal
-- candidates within single regions, and emits a 'Verdict' per
-- candidate. Nothing executes; nothing crosses the FFI.
--
-- This module defines the verdict-bearing data types only. The
-- pass that produces them lives in a follow-up slice ('planRegion',
-- 'planRuntimeGraph') so the type contract can be reviewed in
-- isolation.
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
  ) where

import           Control.DeepSeq                  (NFData)
import           GHC.Generics                     (Generic)

import           MetaSonic.Bridge.Compile.Types   (RegionIndex,
                                                   RegionKernel)
import           MetaSonic.Types                  (NodeIndex, NodeKind)

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
