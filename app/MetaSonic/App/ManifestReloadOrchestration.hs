{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadOrchestration
-- Description : Host-side stopped-audio manifest reload orchestration.
--
-- This module models the app-owned reload window from
-- notes/2026-05-14-j-host-stopped-audio-manifest-reload-orchestration.md
-- without committing to PortAudio, concrete listener brackets, or a
-- particular manifest input path. The real host command can later wire
-- these slots to plan validation, 'SessionFanInService' quiescence,
-- fan-in owner reload, audio lifecycle helpers, and listener factories.

module MetaSonic.App.ManifestReloadOrchestration
  ( HostStoppedAudioReloadOps (..)
  , HostStoppedAudioReloadIssue (..)
  , HostStoppedAudioDrainFailure (..)
  , HostStoppedAudioReloadFailure (..)
  , HostPreservingReloadOps (..)
  , HostPreservingReloadIssue (..)
  , HostPreservingDrainFailure (..)
  , HostPreservingReloadFailure (..)
  , wireManifestReloadIngress
  , orchestrateHostStoppedAudioReload
  , orchestrateHostPreservingReload
  ) where

import           MetaSonic.App.ManifestReloadIngress
                   (ManifestReloadIngressManager,
                    closeManifestReloadIngress,
                    openFreshManifestReloadIngress,
                    resumeManifestReloadIngress)


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

-- | Fill the orchestration ingress slots from a fresh-bracket manager.
--
-- The old target is used when a retryable failure needs to reopen the
-- previous known-good ingress. The new target is used after the reload
-- helper has installed the requested owner and new audio has started.
wireManifestReloadIngress
  :: ManifestReloadIngressManager target issue handle
  -> target
  -> target
  -> HostStoppedAudioReloadOps request plan issue
  -> HostStoppedAudioReloadOps request plan issue
wireManifestReloadIngress manager oldTarget newTarget ops =
  ops
    { hsaroQuiesceIngress =
        closeManifestReloadIngress manager
    , hsaroResumeOldIngress =
        resumeManifestReloadIngress manager oldTarget
    , hsaroReopenIngress =
        openFreshManifestReloadIngress manager newTarget
    }

-- | Run the stopped-audio reload window.
--
-- On success, the requested plan is installed, audio has restarted, and
-- ingress has reopened. On failure, the returned constructor documents
-- the boundary that failed and the cleanup policy that was attempted.
--
-- Retryable failure paths (quiesce failure, retryable drain failure,
-- pre-dispose helper rejection) attempt 'hsaroResumeOldIngress' so the
-- host returns to a live state running the previous plan.
-- Resume-failure variants (@*ResumeFailed@) report when the resume
-- itself failed and the host is left with the old owner running but no
-- live ingress. Terminal drain failures do not attempt automatic
-- ingress resume.
orchestrateHostStoppedAudioReload
  :: HostStoppedAudioReloadOps request plan issue
  -> request
  -> IO (Either (HostStoppedAudioReloadIssue issue) ())
orchestrateHostStoppedAudioReload ops request = do
  prepared <- hsaroPreparePlan ops request
  case prepared of
    Left issue ->
      pure (Left (HsariPlanRejected issue))
    Right plan ->
      quiesce plan
  where
    quiesce plan = do
      result <- hsaroQuiesceIngress ops
      case result of
        Left issue ->
          resumeAfterFailure
            issue
            HsariQuiesceRejected
            HsariQuiesceRejectedResumeFailed
        Right () ->
          drain plan

    drain plan = do
      result <- hsaroDrainLive ops
      case result of
        Left (HsadfRetryable issue) ->
          resumeAfterFailure
            issue
            HsariDrainRejected
            HsariDrainRejectedResumeFailed
        Left (HsadfTerminal issue) ->
          pure (Left (HsariDrainFailedTerminal issue))
        Right () ->
          stopOldAudio plan

    stopOldAudio plan = do
      result <- hsaroStopOldAudio ops
      case result of
        Left issue ->
          pure (Left (HsariStopOldAudioFailed issue))
        Right () ->
          reloadStopped plan

    reloadStopped plan = do
      result <- hsaroReloadStopped ops plan
      case result of
        Left (HsarfOldOwnerStillInstalled issue) ->
          restartOldAudio issue
        Left (HsarfNoOwner issue) ->
          pure (Left (HsariReloadFailedNoOwner issue))
        Right () ->
          startNewAudio

    restartOldAudio issue = do
      result <- hsaroRestartOldAudio ops
      case result of
        Left restartIssue ->
          pure
            (Left (HsariReloadRejectedOldOwnerRestartFailed issue restartIssue))
        Right () ->
          resumeAfterFailure
            issue
            HsariReloadRejectedOldOwnerRestarted
            HsariReloadRejectedOldOwnerResumeFailed

    startNewAudio = do
      result <- hsaroStartNewAudio ops
      case result of
        Left issue ->
          pure (Left (HsariAudioRestartFailed issue))
        Right () ->
          reopenIngress

    reopenIngress = do
      result <- hsaroReopenIngress ops
      case result of
        Left issue -> do
          hsaroStopNewAudio ops
          pure (Left (HsariListenerRestartFailed issue))
        Right () ->
          pure (Right ())

    resumeAfterFailure originalIssue mkResumed mkResumeFailed = do
      resumeResult <- hsaroResumeOldIngress ops
      pure $ case resumeResult of
        Right () ->
          Left (mkResumed originalIssue)
        Left resumeIssue ->
          Left (mkResumeFailed originalIssue resumeIssue)

-- | Run the live preserving reload window.
--
-- On success, the requested plan has been submitted through the
-- preserving hot-swap path, audio was never stopped, the same owner is
-- still live, service ingress has resumed, and concrete ingress has
-- reopened for the installed graph.
--
-- Retryable failure paths attempt service resume followed by old
-- ingress resume. Terminal drain/reload failures do not automatically
-- reopen ingress because the owner/service health is no longer known.
orchestrateHostPreservingReload
  :: HostPreservingReloadOps request plan issue
  -> request
  -> IO (Either (HostPreservingReloadIssue issue) ())
orchestrateHostPreservingReload ops request = do
  prepared <- hproPreparePlan ops request
  case prepared of
    Left issue ->
      pure (Left (HpariPlanRejected issue))
    Right plan ->
      quiesce plan
  where
    quiesce plan = do
      result <- hproQuiesceIngress ops
      case result of
        Left issue ->
          resumeAfterFailure
            issue
            HpariQuiesceRejected
            HpariQuiesceRejectedResumeFailed
        Right () ->
          drain plan

    drain plan = do
      result <- hproDrainLive ops
      case result of
        Left (HprdfRetryable issue) ->
          resumeAfterFailure
            issue
            HpariDrainRejected
            HpariDrainRejectedResumeFailed
        Left (HprdfTerminal issue) ->
          pure (Left (HpariDrainFailedTerminal issue))
        Right () ->
          reloadPreserving plan

    reloadPreserving plan = do
      result <- hproReloadPreserving ops plan
      case result of
        Left (HprfOldOwnerStillInstalled issue) ->
          resumeAfterFailure
            issue
            HpariReloadRejected
            HpariReloadRejectedResumeFailed
        Left (HprfTerminal issue) ->
          pure (Left (HpariReloadFailedTerminal issue))
        Right () ->
          reopenNewIngress

    reopenNewIngress = do
      hproResumeService ops
      result <- hproReopenIngress ops
      pure $ case result of
        Left issue ->
          Left (HpariIngressRestartFailed issue)
        Right () ->
          Right ()

    resumeAfterFailure originalIssue mkResumed mkResumeFailed = do
      hproResumeService ops
      resumeResult <- hproResumeOldIngress ops
      pure $ case resumeResult of
        Right () ->
          Left (mkResumed originalIssue)
        Left resumeIssue ->
          Left (mkResumeFailed originalIssue resumeIssue)
