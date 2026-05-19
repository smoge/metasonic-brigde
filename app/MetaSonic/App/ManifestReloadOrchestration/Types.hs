{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadOrchestration.Types
-- Description : Pure types for the host stopped-audio / preserving
--               manifest reload orchestration.
--
-- This module owns the data declarations consumed by both the
-- orchestration functions in "MetaSonic.App.ManifestReloadOrchestration"
-- and downstream type modules such as
-- "MetaSonic.App.ManifestReloadEvent". Splitting the types out of the
-- function module keeps the dependency direction clean: event /
-- timeline modules can import these types without pulling in the
-- orchestration IO or the @ManifestReloadIngress@ dependency.

module MetaSonic.App.ManifestReloadOrchestration.Types
  ( HostStoppedAudioReloadOps (..)
  , HostStoppedAudioReloadIssue (..)
  , HostStoppedAudioDrainFailure (..)
  , HostStoppedAudioReloadFailure (..)
  , HostPreservingReloadOps (..)
  , HostPreservingReloadIssue (..)
  , HostPreservingDrainFailure (..)
  , HostPreservingReloadFailure (..)
  ) where


-- | Operations owned by an audio-running host reload command.
--
-- The sequence is deliberately explicit so tests can pin the failure
-- boundaries before the slots are wired to real audio and listener
-- resources.
data HostStoppedAudioReloadOps request plan issue =
  HostStoppedAudioReloadOps
    { hsaroPreparePlan       :: !(request -> IO (Either issue plan))
      -- ^ Validate/import the requested manifest and produce the
      -- stopped-audio reload plan. Failure here must leave the running
      -- old stack untouched.
    , hsaroQuiesceIngress    :: !(IO (Either issue ()))
      -- ^ Close producer/listener ingress. Listener finalizers may still
      -- submit final commands that the following live drain must consume.
    , hsaroDrainLive         :: !(IO (Either (HostStoppedAudioDrainFailure issue) ()))
      -- ^ Drain already accepted commands while old audio is still live.
    , hsaroStopOldAudio      :: !(IO (Either issue ()))
      -- ^ Stop audio on the old owner after ingress is closed and the
      -- accepted queue has drained.
    , hsaroReloadStopped     :: !(plan -> IO (Either (HostStoppedAudioReloadFailure issue) ()))
      -- ^ Replace the stopped owner. The failure shape distinguishes
      -- pre-dispose rejection from post-dispose no-owner failure.
    , hsaroRestartOldAudio   :: !(IO (Either issue ()))
      -- ^ Best-effort restart for pre-dispose reload rejection, where
      -- the old owner is still installed.
    , hsaroResumeOldIngress  :: !(IO (Either issue ()))
      -- ^ Reopen producer/listener brackets against the old owner. Used
      -- by retryable failure paths (quiesce/drain failure, pre-dispose
      -- helper rejection followed by old-audio restart) so the host
      -- returns to a live state running the previous plan rather than a
      -- live-audio-but-no-ingress degraded state. Idempotent: safe to
      -- call when ingress is already open.
    , hsaroStartNewAudio     :: !(IO (Either issue ()))
      -- ^ Start audio on the newly installed owner.
    , hsaroReopenIngress     :: !(IO (Either issue ()))
      -- ^ Reopen required producer/listener brackets after new audio is
      -- ready.
    , hsaroStopNewAudio      :: !(IO ())
      -- ^ Cleanup used when listener reopen fails after new audio has
      -- already started.
    }

-- | Owner state after a stopped-audio reload helper failure.
data HostStoppedAudioReloadFailure issue
  = HsarfOldOwnerStillInstalled !issue
    -- ^ The helper rejected before disposing the old owner, e.g.
    -- queue-not-empty admission failure.
  | HsarfNoOwner !issue
    -- ^ The helper failed after disposing the old owner, e.g. owner
    -- setup failure. The caller must not try to restart old audio.
  deriving stock (Eq, Show)

-- | Recovery policy for live-drain failures.
data HostStoppedAudioDrainFailure issue
  = HsadfRetryable !issue
    -- ^ The old owner/service can still be resumed, so orchestration
    -- should reopen old ingress after reporting the rejection.
  | HsadfTerminal !issue
    -- ^ The old owner or service is no longer healthy enough for
    -- automatic ingress resume.
  deriving stock (Eq, Show)

-- | User-visible outcome for one host stopped-audio reload attempt.
--
-- Variants ending in @ResumeFailed@ name two causes: the original
-- failure and the subsequent resume-ingress failure. They mark a
-- partially recovered host that has the old owner installed but no
-- live ingress, which is degraded but not catastrophic - the caller
-- can retry resume later or escalate to host rebuild.
data HostStoppedAudioReloadIssue issue
  = HsariPlanRejected !issue
  | HsariQuiesceRejected !issue
  | HsariQuiesceRejectedResumeFailed !issue !issue
  | HsariDrainRejected !issue
  | HsariDrainRejectedResumeFailed !issue !issue
  | HsariDrainFailedTerminal !issue
  | HsariStopOldAudioFailed !issue
  | HsariReloadRejectedOldOwnerRestarted !issue
  | HsariReloadRejectedOldOwnerRestartFailed !issue !issue
  | HsariReloadRejectedOldOwnerResumeFailed !issue !issue
  | HsariReloadFailedNoOwner !issue
  | HsariAudioRestartFailed !issue
  | HsariListenerRestartFailed !issue
  deriving stock (Eq, Show)

-- | Operations owned by a live preserving manifest reload command.
--
-- This is intentionally stricter than the low-level preserving helper:
-- v1 closes ingress, drains already admitted commands, and requires the
-- drain slot to prove a clean handoff before submitting the preserving
-- hot-swap command. It never stops audio and never replaces the owner.
data HostPreservingReloadOps request plan issue =
  HostPreservingReloadOps
    { hproPreparePlan       :: !(request -> IO (Either issue plan))
      -- ^ Validate/import the requested manifest and produce a
      -- preserving reload plan. Failure leaves the running stack
      -- untouched.
    , hproQuiesceIngress    :: !(IO (Either issue ()))
      -- ^ Close producer/listener ingress so no new commands are
      -- admitted while the preserving command is installed.
    , hproDrainLive         :: !(IO (Either (HostPreservingDrainFailure issue) ()))
      -- ^ Quiesce the service worker and drain accepted commands. V1
      -- requires this slot to reject if the queue is not cleanly empty
      -- after the handoff. A leftover-queue rejection should be
      -- 'HprdfRetryable' for now: the old owner is still live, so the
      -- host can resume old ingress and let a later policy decide
      -- whether to retry, fence more strictly, or fall back.
    , hproReloadPreserving  :: !(plan -> IO (Either (HostPreservingReloadFailure issue) ()))
      -- ^ Submit the preserving-only hot-swap through the live fan-in
      -- path. Failure shape distinguishes retryable old-owner-still-live
      -- rejection from terminal owner/service failure.
    , hproResumeService     :: !(IO ())
      -- ^ Reopen the fan-in service gate and worker before concrete
      -- ingress is reopened. This slot is intentionally infallible at
      -- the expected-error level and should be idempotent; unexpected
      -- exceptions may still propagate.
    , hproResumeOldIngress  :: !(IO (Either issue ()))
      -- ^ Reopen old producer/listener brackets after a retryable
      -- failure. Idempotent: safe when ingress never fully closed.
    , hproReopenIngress     :: !(IO (Either issue ()))
      -- ^ Open fresh producer/listener brackets for the graph now
      -- installed in the same live owner.
    }

-- | Recovery policy for preserving-reload preflight drain failures.
data HostPreservingDrainFailure issue
  = HprdfRetryable !issue
    -- ^ The old owner/service can still be resumed.
  | HprdfTerminal !issue
    -- ^ The old owner/service is not healthy enough for automatic
    -- ingress resume.
  deriving stock (Eq, Show)

-- | Owner/service state after the preserving hot-swap command fails.
data HostPreservingReloadFailure issue
  = HprfOldOwnerStillInstalled !issue
    -- ^ The preserving command rejected without replacing or stopping
    -- the old owner.
  | HprfTerminal !issue
    -- ^ The preserving command reached a terminal owner/service state.
  deriving stock (Eq, Show)

-- | User-visible outcome for one preserving manifest reload attempt.
data HostPreservingReloadIssue issue
  = HpariPlanRejected !issue
  | HpariQuiesceRejected !issue
  | HpariQuiesceRejectedResumeFailed !issue !issue
  | HpariDrainRejected !issue
  | HpariDrainRejectedResumeFailed !issue !issue
  | HpariDrainFailedTerminal !issue
  | HpariReloadRejected !issue
  | HpariReloadRejectedResumeFailed !issue !issue
  | HpariReloadFailedTerminal !issue
  | HpariIngressRestartFailed !issue
  deriving stock (Eq, Show)
