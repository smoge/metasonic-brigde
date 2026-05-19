{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadEvent
-- Description : Structured operator-visible event stream for the
--               manifest reload orchestrator.
--
-- The host's @reloadManifestHostWithStrategy@ returns one final
-- 'Either' classifying the strategy outcome. That answer is the
-- right control-flow contract but the wrong shape for an operator
-- timeline: it collapses the preserving phase, the stopped-audio
-- phase, the resume-old-ingress recovery sub-step, and the fallback
-- admission decision into a single terminal value with no intra-run
-- structure.
--
-- 'ManifestReloadEvent' is the per-transition timeline that runs
-- alongside the 'Either'. Each constructor names one boundary the
-- orchestrator crossed; the failure payloads reuse the existing
-- structured @HostPreservingReloadIssue@ /
-- @HostStoppedAudioReloadIssue@ ADTs so the event stream loses no
-- precision compared to the final result, and operators / tests can
-- pattern-match on the inner constructors directly
-- (e.g. @MrePreservingReloadRejected (HpariDrainRejectedResumeFailed drainErr resumeErr)@).
--
-- This module is types-only by design. The first slice lands the
-- contract for review without committing to an IO threading shape:
-- the next slice will add an @onReloadEvent :: ManifestReloadEvent
-- issue -> IO ()@ hook field to the orchestrator config and wire
-- the existing @reloadManifestHostWithStrategy@ entrypoints as
-- no-op-hook wrappers around an @-WithEvents@ inner.

module MetaSonic.App.ManifestReloadEvent
  ( ManifestReloadEvent (..)
  , noManifestReloadEvents
  ) where

import           MetaSonic.App.ManifestReloadHost.Types
                                                  (ManifestReloadHostStrategy,
                                                   ManifestReloadHostStrategyIssue,
                                                   ManifestReloadHostStrategyRan)
import           MetaSonic.App.ManifestReloadOrchestration.Types
                                                  (HostPreservingReloadIssue,
                                                   HostStoppedAudioReloadIssue)

-- | One operator-visible transition in a manifest reload run.
--
-- Constructors are grouped by the boundary they cross:
--
--   * Strategy lifecycle (3 constructors): which strategy the
--     orchestrator was asked to run, and what it ultimately
--     produced. These bracket every run; @MreStrategyStarted@ is
--     always first and exactly one of @MreStrategySucceeded@ /
--     @MreStrategyFailed@ is always last.
--
--   * Preserving reload phase (3 constructors): the preserving
--     hot-swap attempt. Fires for both 'RequirePreserving' and
--     'TryPreservingThenStoppedAudio' strategies.
--
--   * Stopped-audio reload phase (3 constructors): the
--     stopped-audio reinstall attempt. Fires for 'StoppedAudioOnly'
--     and for the fallback half of 'TryPreservingThenStoppedAudio'.
--
--   * Resume-old-ingress recovery (3 constructors): the
--     resume-after-retryable-failure sub-step that runs inside both
--     phases. Surfaced as its own event family so the timeline
--     shows the recovery attempt and its outcome, even when the
--     final issue eventually collapses to a single
--     @*ResumeFailed@ constructor in the @Hpari*@ / @Hsari*@ ADTs.
--
--   * Fallback admission (2 constructors): the
--     'TryPreservingThenStoppedAudio' strategy's decision point
--     after a preserving rejection. Fires only on the
--     try-then-fallback path.
--
-- The @issue@ type parameter matches the existing orchestration
-- layer's polymorphism: real hosts instantiate at @issue ~
-- ManifestReloadHostIssue ingressIssue@; tests can pick @String@
-- or a small fake.
data ManifestReloadEvent issue
  = ------------------------------------------------------------
    -- Strategy lifecycle.
    ------------------------------------------------------------

    -- | The strategy resolver has decided which strategy to run.
    -- Fires exactly once at the top of every run, before any
    -- phase or recovery events.
    MreStrategyStarted !ManifestReloadHostStrategy

    -- | The strategy completed with an install. The payload
    -- distinguishes which install path actually ran, including
    -- the preserving-rejected-then-stopped-audio case.
  | MreStrategySucceeded !(ManifestReloadHostStrategyRan issue)

    -- | The strategy completed without an install. The payload
    -- preserves both the original failure and any fallback
    -- failure that followed.
  | MreStrategyFailed !(ManifestReloadHostStrategyIssue issue)

    ------------------------------------------------------------
    -- Preserving reload phase.
    ------------------------------------------------------------

    -- | About to attempt the preserving hot-swap. Fires after the
    -- strategy resolver has admitted the preserving path
    -- (i.e. for 'RequirePreserving' and the first half of
    -- 'TryPreservingThenStoppedAudio').
  | MrePreservingReloadStarted

    -- | The preserving hot-swap installed cleanly. Audio was
    -- never stopped, voices were preserved, and ingress has been
    -- reopened against the new owner.
  | MrePreservingReloadCommitted

    -- | The preserving hot-swap was rejected. The payload is the
    -- structured outcome from
    -- @orchestrateHostPreservingReload@; operators pattern-match
    -- on the inner @Hpari*@ constructor for the failing stage
    -- (plan / quiesce / drain / reload / ingress-restart).
  | MrePreservingReloadRejected !(HostPreservingReloadIssue issue)

    ------------------------------------------------------------
    -- Stopped-audio reload phase.
    ------------------------------------------------------------

    -- | About to attempt the stopped-audio reload. Fires for
    -- 'StoppedAudioOnly' at strategy entry and for the second
    -- half of 'TryPreservingThenStoppedAudio' after the
    -- 'MreFallbackAdmitted' event.
  | MreStoppedAudioReloadStarted

    -- | The stopped-audio reload installed cleanly. The new
    -- owner is live, audio has restarted, and ingress has been
    -- reopened.
  | MreStoppedAudioReloadCommitted

    -- | The stopped-audio reload was rejected. The payload is
    -- the structured outcome from
    -- @orchestrateHostStoppedAudioReload@; the inner @Hsari*@
    -- constructor names the failing stage and the cleanup
    -- attempted.
  | MreStoppedAudioReloadRejected !(HostStoppedAudioReloadIssue issue)

    ------------------------------------------------------------
    -- Resume-old-ingress recovery.
    ------------------------------------------------------------

    -- | Inside an active phase, a retryable failure has fired
    -- (quiesce, drain-retryable, or reload-rejected-old-owner-
    -- still-installed) and the orchestrator is about to attempt
    -- to resume the old ingress. Both phases use this event;
    -- correlation with the active phase comes from the timeline
    -- order.
  | MreResumeOldIngressStarted

    -- | The old ingress was successfully reopened after a
    -- retryable failure. The phase will still surface a
    -- rejection, but the host has returned to a live state
    -- running the previous plan.
  | MreResumeOldIngressSucceeded

    -- | The old-ingress resume attempt failed. The phase will
    -- surface a @*ResumeFailed@ constructor and the host is left
    -- in a degraded state (old owner running, no live ingress).
    -- The payload is the resume failure itself; the preceding
    -- failure that triggered the resume is in the phase
    -- rejection event.
  | MreResumeOldIngressFailed !issue

    ------------------------------------------------------------
    -- Fallback admission.
    ------------------------------------------------------------

    -- | The 'TryPreservingThenStoppedAudio' strategy has just
    -- accepted a preserving rejection that proves the old owner
    -- is still installed and old ingress has resumed, and is
    -- about to fire 'MreStoppedAudioReloadStarted'. The payload
    -- is the preserving rejection that triggered the fallback,
    -- carried for operator output without forcing them to scan
    -- backwards in the timeline.
  | MreFallbackAdmitted !(HostPreservingReloadIssue issue)

    -- | The 'TryPreservingThenStoppedAudio' strategy has
    -- rejected a preserving failure as ineligible for fallback
    -- (terminal preserving failure or
    -- already-changed-live-owner). The strategy will surface
    -- the original failure; no 'MreStoppedAudioReload*' events
    -- will follow.
  | MreFallbackDeclined !(HostPreservingReloadIssue issue)
  deriving stock (Eq, Show)

-- | A 'ManifestReloadEvent' callback that discards every event. The
-- canonical default for the @mrhcOnEvent@ field on
-- @ManifestReloadHostConfig@ and the @onEvent@ parameter of the
-- @-WithEvents@ orchestration functions, used by the no-events
-- entrypoints. Polymorphic in @issue@ so the same constant works at
-- every instantiation.
noManifestReloadEvents :: ManifestReloadEvent issue -> IO ()
noManifestReloadEvents _ = pure ()
