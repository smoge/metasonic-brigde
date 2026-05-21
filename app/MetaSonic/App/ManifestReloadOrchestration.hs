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
  , orchestrateHostStoppedAudioReloadWithEvents
  , orchestrateHostPreservingReload
  , orchestrateHostPreservingReloadWithEvents
  ) where

import           MetaSonic.App.ManifestReloadEvent
                   (ManifestReloadEvent (..),
                    noManifestReloadEvents)
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

-- | Run the stopped-audio reload window. No-event wrapper that
-- preserves the slice-zero signature; see
-- 'orchestrateHostStoppedAudioReloadWithEvents' for documentation
-- of the failure-and-cleanup contract and for the variant that
-- emits structured events.
orchestrateHostStoppedAudioReload
  :: HostStoppedAudioReloadOps request plan issue
  -> request
  -> IO (Either (HostStoppedAudioReloadIssue issue) ())
orchestrateHostStoppedAudioReload =
  orchestrateHostStoppedAudioReloadWithEvents noManifestReloadEvents

-- | Run the stopped-audio reload window, emitting structured
-- 'ManifestReloadEvent' transitions through @onEvent@ at each stage
-- boundary.
--
-- The lifecycle of one call is:
--
--   1. 'MreStoppedAudioReloadStarted'
--   2. On success: 'MreStoppedAudioReloadCommitted'.
--   3. On failure: 'MreStoppedAudioReloadRejected' carrying the
--      structured 'HostStoppedAudioReloadIssue'. The same payload
--      is also returned in the 'Left' branch.
--
-- Resume-old-ingress recovery (the @hsaroResumeOldIngress@ call
-- that runs after a retryable quiesce / drain / pre-dispose
-- rejection) is surfaced as its own event family:
-- 'MreResumeOldIngressStarted', then either
-- 'MreResumeOldIngressSucceeded' or 'MreResumeOldIngressFailed'.
-- Operators get to see the recovery attempt in real time even
-- though the @Hsari*ResumeFailed@ constructors only fold the
-- result into the final return value.
--
-- Retryable failure paths (quiesce failure, retryable drain
-- failure, pre-dispose helper rejection) attempt
-- 'hsaroResumeOldIngress' so the host returns to a live state
-- running the previous plan. Resume-failure variants
-- (@*ResumeFailed@) report when the resume itself failed and the
-- host is left with the old owner running but no live ingress.
-- Terminal drain failures do not attempt automatic ingress
-- resume.
orchestrateHostStoppedAudioReloadWithEvents
  :: (ManifestReloadEvent issue -> IO ())
  -> HostStoppedAudioReloadOps request plan issue
  -> request
  -> IO (Either (HostStoppedAudioReloadIssue issue) ())
orchestrateHostStoppedAudioReloadWithEvents onEvent ops request = do
  onEvent MreStoppedAudioReloadStarted
  prepared <- hsaroPreparePlan ops request
  case prepared of
    Left issue ->
      finish (HsariPlanRejected issue)
    Right plan ->
      quiesce plan
  where
    finish issue = do
      onEvent (MreStoppedAudioReloadRejected issue)
      pure (Left issue)

    finishOk = do
      onEvent MreStoppedAudioReloadCommitted
      pure (Right ())

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
          finish (HsariDrainFailedTerminal issue)
        Right () ->
          stopOldAudio plan

    stopOldAudio plan = do
      result <- hsaroStopOldAudio ops
      case result of
        Left issue ->
          finish (HsariStopOldAudioFailed issue)
        Right () ->
          reloadStopped plan

    reloadStopped plan = do
      result <- hsaroReloadStopped ops plan
      case result of
        Left (HsarfOldOwnerStillInstalled issue) ->
          restartOldAudio issue
        Left (HsarfNoOwner issue) ->
          finish (HsariReloadFailedNoOwner issue)
        Right () ->
          startNewAudio

    restartOldAudio issue = do
      result <- hsaroRestartOldAudio ops
      case result of
        Left restartIssue ->
          finish
            (HsariReloadRejectedOldOwnerRestartFailed issue restartIssue)
        Right () ->
          resumeAfterFailure
            issue
            HsariReloadRejectedOldOwnerRestarted
            HsariReloadRejectedOldOwnerResumeFailed

    startNewAudio = do
      result <- hsaroStartNewAudio ops
      case result of
        Left issue ->
          finish (HsariAudioRestartFailed issue)
        Right () ->
          reopenIngress

    reopenIngress = do
      result <- hsaroReopenIngress ops
      case result of
        Left issue -> do
          hsaroStopNewAudio ops
          finish (HsariListenerRestartFailed issue)
        Right () ->
          finishOk

    resumeAfterFailure originalIssue mkResumed mkResumeFailed = do
      onEvent MreResumeOldIngressStarted
      resumeResult <- hsaroResumeOldIngress ops
      case resumeResult of
        Right () -> do
          onEvent MreResumeOldIngressSucceeded
          finish (mkResumed originalIssue)
        Left resumeIssue -> do
          onEvent (MreResumeOldIngressFailed resumeIssue)
          finish (mkResumeFailed originalIssue resumeIssue)

-- | Run the live preserving reload window. No-event wrapper that
-- preserves the slice-zero signature; see
-- 'orchestrateHostPreservingReloadWithEvents' for documentation of
-- the failure-and-cleanup contract and for the variant that emits
-- structured events.
orchestrateHostPreservingReload
  :: HostPreservingReloadOps request plan issue
  -> request
  -> IO (Either (HostPreservingReloadIssue issue) ())
orchestrateHostPreservingReload =
  orchestrateHostPreservingReloadWithEvents noManifestReloadEvents

-- | Run the live preserving reload window, emitting structured
-- 'ManifestReloadEvent' transitions through @onEvent@ at each stage
-- boundary.
--
-- The lifecycle of one call is:
--
--   1. 'MrePreservingReloadStarted'
--   2. On success: 'MrePreservingReloadCommitted'.
--   3. On failure: 'MrePreservingReloadRejected' carrying the
--      structured 'HostPreservingReloadIssue'. The same payload is
--      also returned in the 'Left' branch.
--
-- Resume-old-ingress recovery is surfaced as its own event family;
-- see 'orchestrateHostStoppedAudioReloadWithEvents' for the
-- detailed semantics. The preserving variant uses the same
-- recovery contract for retryable quiesce, drain, and
-- reload-rejected-old-owner-still-installed paths.
--
-- On success, the requested plan has been submitted through the
-- preserving hot-swap path, audio was never stopped, the same
-- owner is still live, service ingress has resumed, and concrete
-- ingress has reopened for the installed graph.
--
-- Retryable failure paths attempt service resume followed by old
-- ingress resume. Terminal drain/reload failures do not
-- automatically reopen ingress because the owner/service health is
-- no longer known.
orchestrateHostPreservingReloadWithEvents
  :: (ManifestReloadEvent issue -> IO ())
  -> HostPreservingReloadOps request plan issue
  -> request
  -> IO (Either (HostPreservingReloadIssue issue) ())
orchestrateHostPreservingReloadWithEvents onEvent ops request = do
  onEvent MrePreservingReloadStarted
  prepared <- hproPreparePlan ops request
  case prepared of
    Left issue ->
      finish (HpariPlanRejected issue)
    Right plan ->
      quiesce plan
  where
    finish issue = do
      onEvent (MrePreservingReloadRejected issue)
      pure (Left issue)

    finishOk = do
      onEvent MrePreservingReloadCommitted
      pure (Right ())

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
          finish (HpariDrainFailedTerminal issue)
        Right () ->
          reloadPreserving plan

    reloadPreserving plan = do
      result <- hproReloadPreserving ops plan
      case result of
        Left (HprfReloadEnqueueRejected issue) -> do
          -- Surface the specific failure mode (the fan-in service
          -- refused to enqueue the preserving command) before the
          -- timeline collapses to the generic 'HpariReloadRejected'
          -- outcome via 'resumeAfterFailure'.
          onEvent (MrePreservingReloadEnqueueRejected issue)
          resumeAfterFailure
            issue
            HpariReloadRejected
            HpariReloadRejectedResumeFailed
        Left (HprfOldOwnerStillInstalled issue) ->
          resumeAfterFailure
            issue
            HpariReloadRejected
            HpariReloadRejectedResumeFailed
        Left (HprfTerminal issue) ->
          finish (HpariReloadFailedTerminal issue)
        Right () ->
          reopenNewIngress

    reopenNewIngress = do
      hproResumeService ops
      result <- hproReopenIngress ops
      case result of
        Left issue ->
          finish (HpariIngressRestartFailed issue)
        Right () ->
          finishOk

    resumeAfterFailure originalIssue mkResumed mkResumeFailed = do
      hproResumeService ops
      onEvent MreResumeOldIngressStarted
      resumeResult <- hproResumeOldIngress ops
      case resumeResult of
        Right () -> do
          onEvent MreResumeOldIngressSucceeded
          finish (mkResumed originalIssue)
        Left resumeIssue -> do
          onEvent (MreResumeOldIngressFailed resumeIssue)
          finish (mkResumeFailed originalIssue resumeIssue)
