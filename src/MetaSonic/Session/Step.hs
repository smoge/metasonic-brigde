{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.Step
-- Description : Single-step orchestrator over admission, adapter, and commit.
--
-- This module pins how Prep B admission, the Prep D runtime adapter,
-- and the Prep C plan/commit handshake compose into one
-- 'SessionCommand' -> 'SessionStepResult' step.
--
-- 'stepSessionCommand' is the only intended entry point. State changes
-- if and only if the result is 'StepCommitted'.
--
-- See [notes/2026-05-12-session-prep-d-runtime-adapter-shell.md].

module MetaSonic.Session.Step
  ( -- * Step result
    SessionStepResult (..)

    -- * Orchestrator
  , stepSessionCommand
  ) where

import           Control.DeepSeq            (NFData)
import           GHC.Generics               (Generic)

import           MetaSonic.Session.Command  (SessionCommand, SessionIssue)
import           MetaSonic.Session.Resolve  (ResolveRebuildResult)
import           MetaSonic.Session.Runtime  (SessionRuntimeAdapter (..),
                                              SessionRuntimeIssue,
                                              SessionRuntimeSuccess (..))
import           MetaSonic.Session.State    (SessionAdmissionResult (..),
                                              SessionCommitIssue,
                                              SessionPlan (..), SessionState,
                                              admitSessionCommand,
                                              applyPlannedCommit)


-- | Outcome of one orchestrated session step.
--
-- 'StepCommitted' is the only constructor that carries an updated
-- 'SessionState'. Every other variant leaves the caller's state
-- unchanged.
data SessionStepResult
  = StepRejected !SessionIssue
    -- ^ Admission refused the command. The runtime adapter was not
    -- invoked.
  | StepRuntimeFailed !SessionRuntimeIssue
    -- ^ The runtime adapter ran and reported failure. State unchanged.
  | StepCommitMismatch !SessionCommitIssue
    -- ^ The adapter reported a 'SessionCommit' but it did not match
    -- the admitted plan. State unchanged. This indicates a runtime or
    -- adapter bug, not a producer error.
  | StepAdapterProtocolBug !String
    -- ^ The adapter returned the wrong 'SessionRuntimeSuccess' shape
    -- for the plan (for example, a control-write acknowledgement for
    -- a hot-swap plan). State unchanged.
  | StepCommitted !SessionState !(Maybe ResolveRebuildResult)
    -- ^ The adapter succeeded and the commit matched. The new state
    -- and the commit-time 'ResolveRebuildResult' (only 'Just' for
    -- graph installs) are returned.
  | StepControlAccepted
    -- ^ The adapter acknowledged a 'PlanControlWrite' without a
    -- session-state mutation. State unchanged by design.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Run one command end-to-end: admit, dispatch through the runtime
-- adapter, then feed any returned commit through the Prep C handshake.
--
-- State mutates only on 'StepCommitted'.
stepSessionCommand
  :: Monad m
  => SessionRuntimeAdapter m
  -> SessionCommand
  -> SessionState
  -> m SessionStepResult
stepSessionCommand adapter cmd st =
  case admitSessionCommand cmd st of
    SessionRejected _ issue ->
      pure (StepRejected issue)
    SessionAdmitted _ plan -> do
      outcome <- sraRun adapter plan
      pure $ case outcome of
        Left runtimeIssue ->
          StepRuntimeFailed runtimeIssue
        Right (RuntimeCommitted commit) ->
          case applyPlannedCommit plan commit st of
            Left commitIssue       -> StepCommitMismatch commitIssue
            Right (st', rebuild)   -> StepCommitted st' rebuild
        Right RuntimeControlWriteAccepted ->
          case plan of
            PlanControlWrite {} -> StepControlAccepted
            _                   -> StepAdapterProtocolBug
              ("runtime returned RuntimeControlWriteAccepted for "
               <> nonControlPlanLabel plan)

nonControlPlanLabel :: SessionPlan -> String
nonControlPlanLabel plan = case plan of
  PlanVoiceStart {}   -> "PlanVoiceStart"
  PlanVoiceStop {}    -> "PlanVoiceStop"
  PlanHotSwap {}      -> "PlanHotSwap"
  PlanControlWrite {} -> "PlanControlWrite"
