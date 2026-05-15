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
  , reloadSupervised
  ) where


-- | Injected slots the supervisor drives. The supervisor itself does
-- no IO beyond sequencing these.
data SupervisorOps plan e = SupervisorOps
  { sopsInWindowReload :: !(plan -> IO (Either e ()))
    -- ^ Attempt the in-window stopped-audio reload against the
    -- currently active stack. Right () on full success (new owner
    -- installed, audio restarted, listeners reopened). Left e on any
    -- terminal in-window failure.
  , sopsCloseStack     :: !(IO ())
    -- ^ Dispose the current host/audio/listener stack. Invoked exactly
    -- once before rebuild after an in-window failure.
  , sopsOpenStack      :: !(plan -> IO (Either e ()))
    -- ^ Construct a fresh stack from the supplied plan. Used only on
    -- the rebuild path; invoked with the captured fallback plan, never
    -- the failed requested plan.
  }

-- | Result of one supervised reload call.
data SupervisedReloadOutcome e
  = SupervisedReloadCommitted
    -- ^ Requested plan installed end-to-end.
  | SupervisedReloadRejectedRecovered !e
    -- ^ Requested plan failed; rebuild from the captured fallback plan
    -- succeeded. The host is running the previous plan again. The
    -- payload describes the in-window failure that triggered recovery.
  | SupervisedReloadEscalated !e !e
    -- ^ Requested plan failed and the rebuild from the fallback plan
    -- also failed. The host has no live stack. Payload is
    -- (in-window failure, rebuild failure) in that order.
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
  attempt <- sopsInWindowReload ops requested
  case attempt of
    Right () ->
      pure SupervisedReloadCommitted
    Left originalErr -> do
      sopsCloseStack ops
      rebuild <- sopsOpenStack ops fallback
      pure $ case rebuild of
        Right () ->
          SupervisedReloadRejectedRecovered originalErr
        Left rebuildErr ->
          SupervisedReloadEscalated originalErr rebuildErr
