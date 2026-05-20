{-# LANGUAGE DeriveFunctor      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadSupervisor
-- Description : Outer recovery policy for stopped-audio manifest reload.
--
-- Implements the binding invariants from
-- notes/2026-05-14-k-host-reload-supervisor.md: capture the plan
-- running at reload entry as a per-call fallback, attempt the
-- in-window reload, and on terminal failure close the current stack
-- and rebuild from that fallback. One bounded recovery attempt. If
-- the rebuild also fails, escalate; never retry against the failed
-- requested plan.
--
-- The supervisor is generic over both the plan and the failure type
-- so the pure/fake harness can exercise the state machine without
-- touching PortAudio, listeners, or the real fan-in host. The eventual
-- audio-running host command (j-note slice 4) wires real
-- 'SupervisorOps' against the landed audio seam, the in-window
-- orchestrator, and listener bracket factories.

module MetaSonic.App.ManifestReloadSupervisor
  ( SupervisorOps (..)
  , SupervisedReloadOutcome (..)
  , InWindowReloadOutcome (..)
  , inWindowOutcomeFromEither
  , reloadSupervised
  ) where

import           Control.Exception (onException)


-- | Classified outcome of one in-window reload attempt.
--
-- The supervisor drives different recovery behavior per variant:
--
--   * 'InWindowReloadCommitted' — no recovery; the new plan is live.
--   * 'InWindowReloadRejectedLiveFallback' — no recovery; the
--     producer guarantees the old owner / ingress is still installed
--     and the stack is safely running the fallback plan. The
--     supervisor does NOT close-then-rebuild.
--   * 'InWindowReloadTerminal' — recovery; the stack may be in an
--     unknown state. The supervisor closes it and rebuilds from the
--     captured fallback plan.
--
-- The producer is responsible for classifying its failure into the
-- right variant. The stopped-audio path can only produce 'Committed'
-- or 'Terminal' by construction (audio stops before the reinstall, so
-- there is no "old owner is still installed" branch). Preserving and
-- try-preserving paths produce all three: plain preserving rejection
-- with a resumed old ingress maps to 'RejectedLiveFallback', terminal
-- preserving failures (post-install errors, ingress restart failures)
-- map to 'Terminal'.
data InWindowReloadOutcome e
  = InWindowReloadCommitted
  | InWindowReloadRejectedLiveFallback !e
  | InWindowReloadTerminal !e
  deriving stock (Eq, Show, Functor)

-- | Lift a binary success/failure result into the classified
-- 'InWindowReloadOutcome' shape by treating every 'Left' as
-- 'InWindowReloadTerminal'. The stopped-audio path uses this because
-- by construction it cannot produce 'InWindowReloadRejectedLiveFallback'
-- — audio stops before reinstall, so there is no \"old owner still
-- installed\" branch to surface. Preserving / try-preserving paths
-- must classify their failures manually instead of going through this
-- shim.
inWindowOutcomeFromEither :: Either e () -> InWindowReloadOutcome e
inWindowOutcomeFromEither (Left e)   = InWindowReloadTerminal e
inWindowOutcomeFromEither (Right ()) = InWindowReloadCommitted

-- | Injected slots the supervisor drives. The supervisor itself does
-- no IO beyond sequencing these.
data SupervisorOps plan e = SupervisorOps
  { sopsInWindowReload :: !(plan -> plan -> IO (InWindowReloadOutcome e))
    -- ^ Attempt the in-window reload against the currently active
    -- stack. Takes the @fallback@ plan (the previously-current plan;
    -- the one the stack is currently running) followed by the
    -- @requested@ plan. The fallback is threaded through so the
    -- producer can re-derive any plan-dependent state at the reload
    -- boundary (e.g. project the current ingress target from the
    -- fallback rather than reading a cached field on the stack).
    --
    -- See 'InWindowReloadOutcome' for the classification the
    -- producer must apply.
  , sopsCloseStack     :: !(IO ())
    -- ^ Dispose the current host/audio/listener stack. Invoked exactly
    -- once before rebuild on the 'InWindowReloadTerminal' path. Not
    -- invoked on 'InWindowReloadRejectedLiveFallback' (the stack is
    -- still live and serving the fallback plan).
  , sopsOpenStack      :: !(plan -> IO (Either e ()))
    -- ^ Construct a fresh stack from the supplied plan. Used only on
    -- the rebuild path; invoked with the captured fallback plan, never
    -- the failed requested plan.
  }

-- | Result of one supervised reload call.
data SupervisedReloadOutcome e
  = SupervisedReloadCommitted
    -- ^ Requested plan installed end-to-end.
  | SupervisedReloadRequestRejected !e
    -- ^ Requested plan was rejected; the stack is still running the
    -- fallback plan with the old owner / ingress intact. No
    -- close/rebuild occurred. The payload describes the in-window
    -- rejection (e.g. a plain preserving-reload rejection that
    -- resumed old ingress).
  | SupervisedReloadRejectedRecovered !e
    -- ^ Requested plan failed terminally; rebuild from the captured
    -- fallback plan succeeded. The host is running the previous plan
    -- again. The payload describes the in-window failure that
    -- triggered recovery.
  | SupervisedReloadEscalated !e !e
    -- ^ Requested plan failed terminally and the rebuild from the
    -- fallback plan also failed. The host has no live stack. Payload
    -- is (in-window failure, rebuild failure) in that order.
  deriving stock (Eq, Show)

-- | Drive a single supervised reload attempt.
--
-- The @fallback@ argument is the plan running at reload entry — by
-- construction, the plan the supervisor was running end-to-end
-- immediately before the user's request. The supervisor captures it
-- once at the start of this call; if the in-window reload commits,
-- the fallback is discarded; if anything fails, rebuild targets the
-- fallback, never the @requested@ plan.
--
-- The supervisor performs at most one rebuild attempt. If both the
-- requested reload and the rebuild fail, the call returns
-- 'SupervisedReloadEscalated' without further retries.
reloadSupervised
  :: SupervisorOps plan e
  -> plan
  -> plan
  -> IO (SupervisedReloadOutcome e)
reloadSupervised ops fallback requested = do
  -- §238 test-checklist invariant: an exception during the in-window
  -- reload must not leak the still-live previous stack. 'onException'
  -- runs 'sopsCloseStack' when 'sopsInWindowReload' throws (sync or
  -- async) and then rethrows; on a normal classified return it does
  -- not fire, so the explicit close on the recovery path below is
  -- not double-called.
  attempt <- sopsInWindowReload ops fallback requested
                `onException` sopsCloseStack ops
  case attempt of
    InWindowReloadCommitted ->
      pure SupervisedReloadCommitted
    InWindowReloadRejectedLiveFallback rejectErr ->
      -- The producer guarantees the stack is still serving the
      -- fallback plan; no close/open runs. The CLI surfaces this
      -- without claiming a rebuild happened.
      pure (SupervisedReloadRequestRejected rejectErr)
    InWindowReloadTerminal originalErr -> do
      -- Recovery path. 'sopsCloseStack' is best-effort: if it throws,
      -- the in-window failure escapes without a rebuild attempt — the
      -- caller is responsible for process-level escalation. The new
      -- stack constructed by 'sopsOpenStack' is required by contract
      -- to clean up any partial state internally before propagating.
      sopsCloseStack ops
      rebuild <- sopsOpenStack ops fallback
      pure $ case rebuild of
        Right () ->
          SupervisedReloadRejectedRecovered originalErr
        Left rebuildErr ->
          SupervisedReloadEscalated originalErr rebuildErr
