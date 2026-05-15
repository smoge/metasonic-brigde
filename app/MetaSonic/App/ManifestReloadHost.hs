{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadHost
-- Description : Host-facing stopped-audio manifest reload command.
--
-- This module wires the stopped-audio host orchestration to the real
-- session-layer pieces that have landed so far: manifest planning,
-- 'SessionFanInService' quiesce/drain, current-owner audio lifecycle,
-- stopped-audio owner reload, and fresh ingress bracket management.
--
-- It still does not define concrete MIDI/OSC/UI listener factories or
-- a device-backed CLI smoke. The host supplies an ingress manager whose
-- handles represent whatever listener/producer bracket bundle the app
-- owns.

module MetaSonic.App.ManifestReloadHost
  ( ManifestReloadHostConfig (..)
  , ManifestReloadHostIssue (..)
  , manifestReloadHostOps
  , reloadManifestStoppedAudioHost
  ) where

import           MetaSonic.App.ManifestReloadIngress
                                                  (ManifestReloadIngressManager,
                                                   closeManifestReloadIngress,
                                                   openFreshManifestReloadIngress,
                                                   resumeManifestReloadIngress)
import           MetaSonic.App.ManifestReloadOrchestration
                                                  (HostStoppedAudioDrainFailure (..),
                                                   HostStoppedAudioReloadFailure (..),
                                                   HostStoppedAudioReloadIssue,
                                                   HostStoppedAudioReloadOps (..),
                                                   orchestrateHostStoppedAudioReload)
import           MetaSonic.Authoring.Manifest    (AuthoringManifestDoc)
import           MetaSonic.Session.FanIn         (SessionFanInAudioFFI,
                                                   SessionFanInAudioIssue,
                                                   SessionFanInAudioOptions,
                                                   SessionFanInDrainResult (..),
                                                   SessionFanInReloadIssue (..),
                                                   startSessionFanInHostAudioWith,
                                                   stopSessionFanInHostAudioWith)
import           MetaSonic.Session.FanInService  (SessionFanInService,
                                                   quiesceAndDrainSessionFanInService,
                                                   resumeSessionFanInService,
                                                   sessionFanInServiceHost)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.ManifestReload.Runtime
                                                  (reloadManifestSessionStoppedAudio)
import           MetaSonic.Session.Owner         (SessionOwnerOptions)
import           MetaSonic.Session.Queue         (SessionDrainResult (..))


-- | Runtime objects and policy supplied by the app host for one reload.
data ManifestReloadHostConfig target ingressIssue handle =
  ManifestReloadHostConfig
    { mrhcService           :: !SessionFanInService
      -- ^ Service whose host owns the reloadable session owner.
    , mrhcIngressManager    :: !(ManifestReloadIngressManager
                                  target ingressIssue handle)
      -- ^ App-owned listener/producer bracket manager.
    , mrhcOldIngressTarget  :: !target
      -- ^ Target used to reopen old ingress after retryable failures.
    , mrhcNewIngressTarget  :: !target
      -- ^ Target used to open fresh ingress after successful reload.
    , mrhcAudioFFI          :: !SessionFanInAudioFFI
      -- ^ Injected audio lifecycle. Production code should pass
      -- 'defaultSessionFanInAudioFFI'; tests pass fakes.
    , mrhcAudioOptions      :: !SessionFanInAudioOptions
    , mrhcOwnerOptions      :: !SessionOwnerOptions
    }

-- | Unified issue type for the host command slots.
data ManifestReloadHostIssue ingressIssue
  = MrhiPlanning !MR.ManifestReloadIssue
  | MrhiIngress !ingressIssue
  | MrhiDrainStopped !SessionFanInDrainResult
  | MrhiDrainLeftQueued !SessionFanInDrainResult
  | MrhiAudio !SessionFanInAudioIssue
  | MrhiReload !SessionFanInReloadIssue
  deriving stock (Eq, Show)

-- | Build orchestration slots backed by the real session host pieces.
manifestReloadHostOps
  :: ManifestReloadHostConfig target ingressIssue handle
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> HostStoppedAudioReloadOps
       MR.ManifestReloadRequest
       MR.ManifestReloadPlan
       (ManifestReloadHostIssue ingressIssue)
manifestReloadHostOps config doc catalog =
  HostStoppedAudioReloadOps
    { hsaroPreparePlan =
        \request ->
          pure $ case MR.planManifestReload doc catalog request of
            Left issue ->
              Left (MrhiPlanning issue)
            Right plan ->
              Right plan
    , hsaroQuiesceIngress =
        mapIngress (closeManifestReloadIngress ingressManager)
    , hsaroDrainLive =
        drainLive
    , hsaroStopOldAudio =
        stopAudio
    , hsaroReloadStopped =
        reloadStopped
    , hsaroRestartOldAudio =
        startAudio
    , hsaroResumeOldIngress =
        resumeServiceAndIngress
          (resumeManifestReloadIngress
             ingressManager
             (mrhcOldIngressTarget config))
    , hsaroStartNewAudio =
        startAudio
    , hsaroReopenIngress =
        resumeServiceAndIngress
          (openFreshManifestReloadIngress
             ingressManager
             (mrhcNewIngressTarget config))
    , hsaroStopNewAudio =
        discardStopAudioResult
    }
  where
    service =
      mrhcService config
    host =
      sessionFanInServiceHost service
    ingressManager =
      mrhcIngressManager config
    audioFFI =
      mrhcAudioFFI config
    audioOptions =
      mrhcAudioOptions config
    ownerOptions =
      mrhcOwnerOptions config

    mapIngress action = do
      result <- action
      pure $ case result of
        Left issue ->
          Left (MrhiIngress issue)
        Right () ->
          Right ()

    resumeServiceAndIngress action = do
      resumeSessionFanInService service
      result <- action
      case result of
        Left issue -> do
          _ <- quiesceAndDrainSessionFanInService service
          pure (Left (MrhiIngress issue))
        Right () ->
          pure (Right ())

    drainLive = do
      -- App ingress close runs first so listener/producer finalizers can
      -- still submit last commands. This step pairs that handoff with
      -- service-side quiesce and the final queue drain.
      drained <- quiesceAndDrainSessionFanInService service
      pure $
        case sdrStopped (sfidrDrain drained) of
          Just _ ->
            Left (HsadfTerminal (MrhiDrainStopped drained))
          Nothing
            | sfidrQueueDepth drained == 0 ->
                Right ()
            | otherwise ->
                Left (HsadfRetryable (MrhiDrainLeftQueued drained))

    stopAudio =
      mapAudio (stopSessionFanInHostAudioWith audioFFI host)

    startAudio =
      mapAudio (startSessionFanInHostAudioWith audioFFI host audioOptions)

    mapAudio action = do
      result <- action
      pure $ case result of
        Left issue ->
          Left (MrhiAudio issue)
        Right () ->
          Right ()

    reloadStopped plan = do
      result <-
        reloadManifestSessionStoppedAudio
          host
          ownerOptions
          plan
      pure $ case result of
        Left issue ->
          Left (mapReloadIssue issue)
        Right _report ->
          Right ()

    discardStopAudioResult =
      stopSessionFanInHostAudioWith audioFFI host >> pure ()

-- | Run one host-facing stopped-audio manifest reload attempt.
reloadManifestStoppedAudioHost
  :: ManifestReloadHostConfig target ingressIssue handle
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> MR.ManifestReloadRequest
  -> IO (Either
          (HostStoppedAudioReloadIssue
            (ManifestReloadHostIssue ingressIssue))
          ())
reloadManifestStoppedAudioHost config doc catalog request =
  orchestrateHostStoppedAudioReload
    (manifestReloadHostOps config doc catalog)
    request

mapReloadIssue
  :: SessionFanInReloadIssue
  -> HostStoppedAudioReloadFailure (ManifestReloadHostIssue ingressIssue)
mapReloadIssue issue =
  case issue of
    SfriReloadAlreadyInProgress ->
      oldOwnerStillInstalled
    SfriQueueNotEmpty _ ->
      oldOwnerStillInstalled
    SfriAudioStillRunning ->
      oldOwnerStillInstalled
    SfriNoOwner ->
      noOwner
    SfriOwnerSetupFailed _ ->
      noOwner
  where
    oldOwnerStillInstalled =
      HsarfOldOwnerStillInstalled (MrhiReload issue)
    noOwner =
      HsarfNoOwner (MrhiReload issue)
