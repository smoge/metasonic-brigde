{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.Arbitration
-- Description : Pure session producer arbitration policy.
--
-- This module records the pure policy surface for deciding whether a
-- producer may submit a command before the command reaches fan-in.
-- It does not enqueue, drain, coalesce, or mutate producer state.
-- Accepted commands still rely on 'MetaSonic.Session.FanIn' and
-- 'MetaSonic.Session.Queue' for strict FIFO behavior.
--
-- Priority and claim tables are pure inputs. A gateway above this
-- module is responsible for maintaining them with 'setControlOwner',
-- 'claimControlTarget', and 'releaseControlTarget'; without that,
-- 'ProducerPriority' with an empty owner table reduces to 'FifoOnly'
-- for unowned targets.
--
-- v1 arbitration only targets 'CmdControlWrite'. Lifecycle and
-- hot-swap commands bypass control arbitration; future lifecycle
-- policies must add explicit issue reporting instead of silently
-- dropping or collapsing commands.
--
-- See [notes/2026-05-14-a-session-producer-coexistence-arbitration.md].

module MetaSonic.Session.Arbitration
  ( -- * Targets
    ControlArbitrationTarget (..)
  , sessionCommandControlTarget

    -- * Policy state
  , ControlOwnerTable
  , emptyControlOwnerTable
  , lookupControlOwner
  , setControlOwner
  , clearControlOwner
  , TargetClaimTable
  , emptyTargetClaimTable
  , lookupTargetClaim
  , claimControlTarget
  , releaseControlTarget

    -- * Policies
  , ArbitrationPolicy (..)

    -- * Decisions
  , ArbitrationRejectReason (..)
  , ArbitrationIssue (..)
  , ArbitrationDecision (..)
  , arbitrateSessionCommand
  , recordAcceptedSessionCommand
  ) where

import           Control.DeepSeq           (NFData)
import           Data.List                 (elemIndex)
import qualified Data.Map.Strict           as M
import           Data.Map.Strict           (Map)
import           GHC.Generics              (Generic)

import           MetaSonic.Pattern         (ControlTag, VoiceKey)
import           MetaSonic.Session.Command (SessionCommand (..))
import           MetaSonic.Session.Queue   (ProducerId (..), ProducerKind)


-- | Symbolic control target used by cross-producer arbitration.
--
-- The target intentionally mirrors 'CmdControlWrite'. Producer
-- identity is not part of the key: arbitration decides which producer
-- is allowed to write this target before the command reaches fan-in.
data ControlArbitrationTarget = ControlArbitrationTarget
  { catVoiceKey   :: !VoiceKey
  , catControlTag :: !ControlTag
  } deriving stock    (Eq, Ord, Show, Generic)
    deriving anyclass (NFData)

-- | Extract the v1 arbitration target for commands that have one.
--
-- Lifecycle and hot-swap commands return 'Nothing' because they bypass
-- v1 control arbitration.
sessionCommandControlTarget :: SessionCommand -> Maybe ControlArbitrationTarget
sessionCommandControlTarget command = case command of
  CmdControlWrite vkey target _ ->
    Just (ControlArbitrationTarget vkey target)
  CmdVoiceOn _ _ _ ->
    Nothing
  CmdVoiceOff _ ->
    Nothing
  CmdHotSwap _ _ ->
    Nothing
  CmdHotSwapPreservingOnly _ _ ->
    Nothing

-- | Current per-control owner table for priority-style policies.
--
-- A later gateway can update this table after accepted control writes.
-- This module only reads and transforms the table purely.
newtype ControlOwnerTable = ControlOwnerTable
  { unControlOwnerTable :: Map ControlArbitrationTarget ProducerId
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

emptyControlOwnerTable :: ControlOwnerTable
emptyControlOwnerTable =
  ControlOwnerTable M.empty

lookupControlOwner
  :: ControlArbitrationTarget
  -> ControlOwnerTable
  -> Maybe ProducerId
lookupControlOwner target (ControlOwnerTable owners) =
  M.lookup target owners

setControlOwner
  :: ControlArbitrationTarget
  -> ProducerId
  -> ControlOwnerTable
  -> ControlOwnerTable
setControlOwner target producer (ControlOwnerTable owners) =
  ControlOwnerTable (M.insert target producer owners)

clearControlOwner
  :: ControlArbitrationTarget
  -> ControlOwnerTable
  -> ControlOwnerTable
clearControlOwner target (ControlOwnerTable owners) =
  ControlOwnerTable (M.delete target owners)

-- | Explicit claims for target-claim arbitration.
--
-- A claim is stronger than priority: only the claiming producer can
-- write that target until the claim is released by a policy wrapper.
newtype TargetClaimTable = TargetClaimTable
  { unTargetClaimTable :: Map ControlArbitrationTarget ProducerId
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

emptyTargetClaimTable :: TargetClaimTable
emptyTargetClaimTable =
  TargetClaimTable M.empty

lookupTargetClaim
  :: ControlArbitrationTarget
  -> TargetClaimTable
  -> Maybe ProducerId
lookupTargetClaim target (TargetClaimTable claims) =
  M.lookup target claims

claimControlTarget
  :: ControlArbitrationTarget
  -> ProducerId
  -> TargetClaimTable
  -> TargetClaimTable
claimControlTarget target producer (TargetClaimTable claims) =
  TargetClaimTable (M.insert target producer claims)

releaseControlTarget
  :: ControlArbitrationTarget
  -> TargetClaimTable
  -> TargetClaimTable
releaseControlTarget target (TargetClaimTable claims) =
  TargetClaimTable (M.delete target claims)

-- | Pure producer-arbitration policy.
--
-- 'FifoOnly' is the default v1 behavior: every producer is allowed by
-- arbitration and fan-in remains the only ordering contract.
--
-- 'ProducerPriority' orders producer kinds from highest to lowest
-- priority. If a current owner exists for the target, a lower-priority
-- producer is rejected. Equal priority preserves FIFO behavior by
-- allowing the write.
--
-- 'TargetClaim' allows only the claiming producer to write a claimed
-- target. Unclaimed targets pass through.
data ArbitrationPolicy
  = FifoOnly
  | ProducerPriority ![ProducerKind] !ControlOwnerTable
  | TargetClaim !TargetClaimTable
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

data ArbitrationRejectReason
  = ArrLowerPriorityThan !ProducerId
    -- ^ Another producer currently owns the target and has higher
    -- priority under the configured priority table.
  | ArrTargetClaimedBy !ProducerId
    -- ^ Another producer currently claims the target.
  | ArrUnsupportedLifecyclePolicy
    -- ^ Reserved for future policies that choose to arbitrate
    -- lifecycle or hot-swap commands instead of using the v1 bypass.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Observable policy rejection.
--
-- The retryable flag is informational. Producers decide whether and
-- how to retry; the flag only states whether the same policy state
-- would admit a re-submission.
data ArbitrationIssue = ArbitrationIssue
  { aiProducer  :: !ProducerId
  , aiCommand   :: !SessionCommand
  , aiTarget    :: !(Maybe ControlArbitrationTarget)
  , aiReason    :: !ArbitrationRejectReason
  , aiRetryable :: !Bool
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

data ArbitrationDecision
  = ArbitrationAllowed
  | ArbitrationRejected !ArbitrationIssue
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Decide whether a producer may submit a command under a pure policy.
--
-- This function never enqueues and never updates policy state. A later
-- producer gateway or session policy wrapper can use the decision and
-- update owner/claim tables around accepted control writes.
arbitrateSessionCommand
  :: ArbitrationPolicy
  -> ProducerId
  -> SessionCommand
  -> ArbitrationDecision
arbitrateSessionCommand policy producer command =
  case sessionCommandControlTarget command of
    Nothing ->
      ArbitrationAllowed
    Just target ->
      arbitrateControlTarget policy producer command target

-- | Update pure policy state after a command has been accepted.
--
-- This is intentionally separate from 'arbitrateSessionCommand'. A
-- gateway should call it only after the downstream enqueue has
-- succeeded, so queue-full or other enqueue rejections do not claim
-- ownership for commands that never reached fan-in.
recordAcceptedSessionCommand
  :: ArbitrationPolicy
  -> ProducerId
  -> SessionCommand
  -> ArbitrationPolicy
recordAcceptedSessionCommand policy producer command =
  case (policy, sessionCommandControlTarget command) of
    (ProducerPriority priorities owners, Just target) ->
      ProducerPriority priorities (setControlOwner target producer owners)
    _ ->
      policy

arbitrateControlTarget
  :: ArbitrationPolicy
  -> ProducerId
  -> SessionCommand
  -> ControlArbitrationTarget
  -> ArbitrationDecision
arbitrateControlTarget policy producer command target =
  case policy of
    FifoOnly ->
      ArbitrationAllowed
    ProducerPriority priorities owners ->
      case lookupControlOwner target owners of
        Nothing ->
          ArbitrationAllowed
        Just currentOwner
          | producerAllowedByPriority priorities producer currentOwner ->
              ArbitrationAllowed
          | otherwise ->
              reject command producer (Just target)
                (ArrLowerPriorityThan currentOwner)
                False
    TargetClaim claims ->
      case lookupTargetClaim target claims of
        Nothing ->
          ArbitrationAllowed
        Just claimant
          | claimant == producer ->
              ArbitrationAllowed
          | otherwise ->
              reject command producer (Just target)
                (ArrTargetClaimedBy claimant)
                False

producerAllowedByPriority :: [ProducerKind] -> ProducerId -> ProducerId -> Bool
producerAllowedByPriority priorities incoming currentOwner =
  priorityRank priorities (producerKind incoming)
    <= priorityRank priorities (producerKind currentOwner)

priorityRank :: [ProducerKind] -> ProducerKind -> Int
priorityRank priorities kind =
  case elemIndex kind priorities of
    Just idx ->
      idx
    Nothing ->
      length priorities

reject
  :: SessionCommand
  -> ProducerId
  -> Maybe ControlArbitrationTarget
  -> ArbitrationRejectReason
  -> Bool
  -> ArbitrationDecision
reject command producer target reason retryable =
  ArbitrationRejected ArbitrationIssue
    { aiProducer  = producer
    , aiCommand   = command
    , aiTarget    = target
    , aiReason    = reason
    , aiRetryable = retryable
    }
