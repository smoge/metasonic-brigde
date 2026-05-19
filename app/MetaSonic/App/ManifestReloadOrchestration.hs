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
--
-- The pure data declarations live in
-- "MetaSonic.App.ManifestReloadOrchestration.Types" so downstream
-- type modules (e.g. "MetaSonic.App.ManifestReloadEvent") can depend
-- on them without pulling in the orchestration IO or the ingress
-- manager. The function and type surfaces are both re-exported from
-- this module so existing consumers don't see the split.

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
import           MetaSonic.App.ManifestReloadOrchestration.Types
                   (HostPreservingDrainFailure (..),
                    HostPreservingReloadFailure (..),
                    HostPreservingReloadIssue (..),
                    HostPreservingReloadOps (..),
                    HostStoppedAudioDrainFailure (..),
                    HostStoppedAudioReloadFailure (..),
                    HostStoppedAudioReloadIssue (..),
                    HostStoppedAudioReloadOps (..))

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
