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

import           MetaSonic.Session.Resolve  (RetiredVoiceBinding)


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
    , hsaroReloadStopped     :: !(plan -> IO (Either (HostStoppedAudioReloadFailure issue) [RetiredVoiceBinding]))
      -- ^ Replace the stopped owner. On success returns the list of
      -- voice bindings the old owner held immediately before release
      -- (each carrying 'RvrOwnerReplaced'); the orchestrator forwards
      -- this projection onto 'MreStoppedAudioReloadCommitted'. The
      -- failure shape distinguishes pre-dispose rejection from
      -- post-dispose no-owner failure.
    , hsaroOnRetired         :: !([RetiredVoiceBinding] -> IO ())
      -- ^ Phase 8h step 3e v1 slice 4: side-channel hook invoked
      -- with the retired set after 'hsaroReloadStopped' succeeds
      -- and *before* 'hsaroStartNewAudio' / 'hsaroReopenIngress'.
      -- Lets the host publish a 'lastRetiredRef'-style snapshot in
      -- time for the next producer drain to attribute against it;
      -- the 'MreStoppedAudioReloadCommitted' event still fires
      -- afterwards inside 'finishOk'. Default 'pure ()'.
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
    , hproReloadPreserving  :: !(plan -> IO (Either (HostPreservingReloadFailure issue) [RetiredVoiceBinding]))
      -- ^ Submit the preserving-only hot-swap through the live fan-in
      -- path. On success returns the list of voice bindings that
      -- could not migrate to the new graph (paired with the
      -- 'RvrTemplateGone' / 'RvrInvalidVoiceKey' reason that retired
      -- them); the orchestrator forwards this projection onto
      -- 'MrePreservingReloadCommitted'. Failure shape distinguishes
      -- retryable old-owner-still-live rejection from terminal
      -- owner/service failure.
    , hproOnRetired         :: !([RetiredVoiceBinding] -> IO ())
      -- ^ Phase 8h step 3e v1 slice 4: side-channel hook invoked
      -- with the retired set after 'hproReloadPreserving' succeeds
      -- and *before* 'hproResumeService' / 'hproReopenIngress'.
      -- Without this hook, producer ingress reopens before
      -- 'MrePreservingReloadCommitted' fires and the live shell can
      -- silently miss a stale-by-reload rejection that races a
      -- newly-reopened producer. The 'MrePreservingReloadCommitted'
      -- event still fires afterwards inside 'finishOk'. Default
      -- 'pure ()'.
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
--
-- Both 'HprfReloadEnqueueRejected' and 'HprfOldOwnerStillInstalled'
-- describe a retryable state (the old owner is still installed and
-- old ingress can be resumed) and orchestration collapses them onto
-- the same public outcome ('HpariReloadRejected') so downstream
-- supervisor / fallback policy is unchanged. They differ in /which/
-- failure mode produced the live-stack survivor: the command itself
-- was rejected before it could affect ownership (e.g. fan-in queue
-- still locked), versus the command ran but the owner did not flip
-- (e.g. drained-but-not-replaced). The orchestrator emits a distinct
-- 'MrePreservingReloadEnqueueRejected' event for the enqueue-rejected
-- variant so the operator timeline names the specific failure mode.
data HostPreservingReloadFailure issue
  = HprfReloadEnqueueRejected !issue
    -- ^ The preserving command could not be enqueued at the fan-in
    -- service (e.g. fan-in service still in reload window). The
    -- command never ran and the old owner is unaffected.
  | HprfOldOwnerStillInstalled !issue
    -- ^ The preserving command was enqueued and processed but the
    -- swap did not take effect; the old owner is still installed.
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
