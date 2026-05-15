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
  , HostStoppedAudioReloadFailure (..)
  , orchestrateHostStoppedAudioReload
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
    , hsaroDrainLive         :: !(IO (Either issue ()))
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

-- | User-visible outcome for one host stopped-audio reload attempt.
data HostStoppedAudioReloadIssue issue
  = HsariPlanRejected !issue
  | HsariQuiesceRejected !issue
  | HsariDrainRejected !issue
  | HsariStopOldAudioFailed !issue
  | HsariReloadRejectedOldOwnerRestarted !issue
  | HsariReloadRejectedOldOwnerRestartFailed !issue !issue
  | HsariReloadFailedNoOwner !issue
  | HsariAudioRestartFailed !issue
  | HsariListenerRestartFailed !issue
  deriving stock (Eq, Show)

-- | Run the stopped-audio reload window.
--
-- On success, the requested plan is installed, audio has restarted, and
-- ingress has reopened. On failure, the returned constructor documents
-- the boundary that failed and the cleanup policy that was attempted.
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
          pure (Left (HsariQuiesceRejected issue))
        Right () ->
          drain plan

    drain plan = do
      result <- hsaroDrainLive ops
      case result of
        Left issue ->
          pure (Left (HsariDrainRejected issue))
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
      pure $ case result of
        Right () ->
          Left (HsariReloadRejectedOldOwnerRestarted issue)
        Left restartIssue ->
          Left (HsariReloadRejectedOldOwnerRestartFailed issue restartIssue)

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
