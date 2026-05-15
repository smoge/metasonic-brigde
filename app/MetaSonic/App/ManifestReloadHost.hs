{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadHost
-- Description : Host-facing manifest reload commands.
--
-- This module wires the host reload orchestration to the real
-- session-layer pieces that have landed so far: manifest planning,
-- 'SessionFanInService' quiesce/drain, current-owner audio lifecycle,
-- stopped-audio owner reload, preserving hot-swap, and fresh ingress
-- bracket management.
--
-- It still does not define concrete MIDI/OSC/UI listener factories or
-- a device-backed CLI smoke. The host supplies an ingress manager whose
-- handles represent whatever listener/producer bracket bundle the app
-- owns.

module MetaSonic.App.ManifestReloadHost
  ( ManifestReloadHostConfig (..)
  , ManifestReloadHostIssue (..)
  , manifestReloadHostOps
  , manifestPreservingReloadHostOps
  , reloadManifestStoppedAudioHost
  , reloadManifestPreservingHost
  ) where

import           MetaSonic.App.ManifestReloadIngress
                                                  (ManifestReloadIngressManager,
                                                   closeManifestReloadIngress,
                                                   openFreshManifestReloadIngress,
                                                   resumeManifestReloadIngress)
import           MetaSonic.App.ManifestReloadOrchestration
                                                  (HostPreservingDrainFailure (..),
                                                   HostPreservingReloadFailure (..),
                                                   HostPreservingReloadIssue,
                                                   HostPreservingReloadOps (..),
                                                   HostStoppedAudioDrainFailure (..),
                                                   HostStoppedAudioReloadFailure (..),
                                                   HostStoppedAudioReloadIssue,
                                                   HostStoppedAudioReloadOps (..),
                                                   orchestrateHostPreservingReload,
                                                   orchestrateHostStoppedAudioReload)
import           MetaSonic.Authoring.Manifest    (AuthoringManifestDoc)
import           MetaSonic.Session.FanIn         (SessionFanInAudioFFI,
                                                   SessionFanInAudioIssue,
                                                   SessionFanInAudioOptions,
                                                   SessionFanInDrainResult (..),
                                                   SessionFanInEnqueueResult (..),
                                                   SessionFanInReloadIssue (..),
                                                   startSessionFanInHostAudioWith,
                                                   stopSessionFanInHostAudioWith)
import           MetaSonic.Session.FanInService  (SessionFanInService,
                                                   quiesceAndDrainSessionFanInService,
                                                   resumeSessionFanInService,
                                                   sessionFanInServiceHost)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.ManifestReload.Runtime
                                                  (ManifestPreservingHotSwapReport (..),
                                                   reloadManifestSessionPreservingHotSwap,
                                                   reloadManifestSessionStoppedAudio)
import           MetaSonic.Session.Owner         (SessionOwnerOptions,
                                                  SessionOwnerStepResult (..))
import           MetaSonic.Session.Queue         (ProducerId,
                                                  QueuedSessionCommand (..),
                                                  SessionDrainItem (..),
                                                  SessionDrainResult (..),
                                                  SessionEnqueueResult (..))
import           MetaSonic.Session.Step          (SessionStepResult (..))


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
  | MrhiPreservingReloadRejected !ManifestPreservingHotSwapReport
  | MrhiPreservingReloadStopped !ManifestPreservingHotSwapReport
  | MrhiPreservingReloadUnexpected !ManifestPreservingHotSwapReport
  deriving stock (Eq, Show)

-- | Build stopped-audio orchestration slots backed by the real session
-- host pieces.
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
        preparePlan doc catalog
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

-- | Build preserving hot-swap orchestration slots backed by the real
-- session host pieces.
manifestPreservingReloadHostOps
  :: ProducerId
  -> ManifestReloadHostConfig target ingressIssue handle
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> HostPreservingReloadOps
       MR.ManifestReloadRequest
       MR.ManifestReloadPlan
       (ManifestReloadHostIssue ingressIssue)
manifestPreservingReloadHostOps producer config doc catalog =
  HostPreservingReloadOps
    { hproPreparePlan =
        preparePlan doc catalog
    , hproQuiesceIngress =
        mapIngress (closeManifestReloadIngress ingressManager)
    , hproDrainLive =
        drainPreservingLive
    , hproReloadPreserving =
        reloadPreserving
    , hproResumeService =
        resumeSessionFanInService service
    , hproResumeOldIngress =
        mapIngress
          (resumeManifestReloadIngress
             ingressManager
             (mrhcOldIngressTarget config))
    , hproReopenIngress =
        mapIngress
          (openFreshManifestReloadIngress
             ingressManager
             (mrhcNewIngressTarget config))
    }
  where
    service =
      mrhcService config
    host =
      sessionFanInServiceHost service
    ingressManager =
      mrhcIngressManager config

    mapIngress action = do
      result <- action
      pure $ case result of
        Left issue ->
          Left (MrhiIngress issue)
        Right () ->
          Right ()

    drainPreservingLive = do
      -- Same preflight handoff as the stopped-audio path, but failure
      -- is classified in the preserving reload vocabulary and audio
      -- remains live.
      drained <- quiesceAndDrainSessionFanInService service
      pure $
        case sdrStopped (sfidrDrain drained) of
          Just _ ->
            Left (HprdfTerminal (MrhiDrainStopped drained))
          Nothing
            | sfidrQueueDepth drained == 0 ->
                Right ()
            | otherwise ->
                -- Defensive for future bounded/fenced drain variants:
                -- today's healthy service drain empties the queue, and
                -- owner-stopped leftovers are classified by the
                -- 'sdrStopped' branch above.
                Left (HprdfRetryable (MrhiDrainLeftQueued drained))

    reloadPreserving plan = do
      report <-
        reloadManifestSessionPreservingHotSwap
          producer
          host
          plan
      pure (mapPreservingReloadReport report)

preparePlan
  :: AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> MR.ManifestReloadRequest
  -> IO (Either (ManifestReloadHostIssue ingressIssue) MR.ManifestReloadPlan)
preparePlan doc catalog request =
  pure $ case MR.planManifestReload doc catalog request of
    Left issue ->
      Left (MrhiPlanning issue)
    Right plan ->
      Right plan

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

-- | Run one host-facing preserving manifest reload attempt.
reloadManifestPreservingHost
  :: ProducerId
  -> ManifestReloadHostConfig target ingressIssue handle
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> MR.ManifestReloadRequest
  -> IO (Either
          (HostPreservingReloadIssue
            (ManifestReloadHostIssue ingressIssue))
          ())
reloadManifestPreservingHost producer config doc catalog request =
  orchestrateHostPreservingReload
    (manifestPreservingReloadHostOps producer config doc catalog)
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

mapPreservingReloadReport
  :: ManifestPreservingHotSwapReport
  -> Either
       (HostPreservingReloadFailure (ManifestReloadHostIssue ingressIssue))
       ()
mapPreservingReloadReport report =
  case sfierResult (mphsrEnqueueResult report) of
    SessionEnqueueRejected {} ->
      -- Defensive under the strict v1 host contract: preflight drains
      -- before this enqueue and the producer is configured by the
      -- caller. Treat rejection as retryable because the old owner is
      -- still installed.
      oldOwnerStillInstalled
    SessionEnqueued {} ->
      case mphsrDrainResult report of
        Nothing ->
          unexpectedDrain
        Just drained ->
          case sdrStopped (sfidrDrain drained) of
            Just _ ->
              stoppedDrain
            Nothing
              | sfidrQueueDepth drained /= 0 ->
                  unexpectedDrain
              | sdrRemaining (sfidrDrain drained) /= 0 ->
                  unexpectedDrain
              | otherwise ->
                  classifyDrainItems (sdrItems (sfidrDrain drained))
  where
    oldOwnerStillInstalled =
      Left
        (HprfOldOwnerStillInstalled
          (MrhiPreservingReloadRejected report))

    stoppedDrain =
      Left
        (HprfTerminal
          (MrhiPreservingReloadStopped report))

    unexpectedDrain =
      Left
        (HprfTerminal
          (MrhiPreservingReloadUnexpected report))

    classifyDrainItems items =
      case items of
        [SessionDrainItem queued result]
          | qscCommand queued == mphsrCommand report ->
              classifyStepResult result
        _ ->
          unexpectedDrain

    classifyStepResult result =
      case result of
        SessionOwnerStep step ->
          classifySessionStep step
        SessionOwnerDivergedNow {} ->
          stoppedDrain
        SessionOwnerBlocked {} ->
          stoppedDrain

    classifySessionStep step =
      case step of
        StepCommitted _ (Just _) ->
          Right ()
        StepRuntimeFailed {} ->
          oldOwnerStillInstalled
        StepRejected {} ->
          oldOwnerStillInstalled
        StepCommitted _ Nothing ->
          unexpectedDrain
        StepCommitMismatch {} ->
          unexpectedDrain
        StepAdapterProtocolBug {} ->
          unexpectedDrain
        StepControlAccepted ->
          unexpectedDrain
