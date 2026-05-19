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
  , ManifestReloadHostStrategy (..)
  , ManifestReloadHostStrategyIssue (..)
  , ManifestReloadHostStrategyRan (..)
  , preservingAllowsStoppedAudioFallback
  , manifestReloadHostOps
  , manifestPreservingReloadHostOps
  , reloadManifestStoppedAudioHost
  , reloadManifestStoppedAudioHostWithEvents
  , reloadManifestPreservingHost
  , reloadManifestPreservingHostWithEvents
  , reloadManifestHostWithStrategy
  , reloadManifestHostWithStrategyWithEvents
  , runReloadHostStrategyWithEvents
  ) where

import           MetaSonic.App.ManifestReloadEvent
                                                  (ManifestReloadEvent (..),
                                                   noManifestReloadEvents)
import           MetaSonic.App.ManifestReloadIngress
                                                  (ManifestReloadIngressManager,
                                                   closeManifestReloadIngress,
                                                   openFreshManifestReloadIngress,
                                                   resumeManifestReloadIngress)
import           MetaSonic.App.ManifestReloadHost.Types
                                                  (ManifestReloadHostIssue (..),
                                                   ManifestReloadHostStrategy (..),
                                                   ManifestReloadHostStrategyIssue (..),
                                                   ManifestReloadHostStrategyRan (..))
import           MetaSonic.App.ManifestReloadOrchestration
                                                  (HostPreservingDrainFailure (..),
                                                   HostPreservingReloadFailure (..),
                                                   HostPreservingReloadIssue (..),
                                                   HostPreservingReloadOps (..),
                                                   HostStoppedAudioDrainFailure (..),
                                                   HostStoppedAudioReloadFailure (..),
                                                   HostStoppedAudioReloadIssue,
                                                   HostStoppedAudioReloadOps (..),
                                                   orchestrateHostPreservingReloadWithEvents,
                                                   orchestrateHostStoppedAudioReloadWithEvents)
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
    , mrhcOnEvent           :: !(ManifestReloadEvent
                                   (ManifestReloadHostIssue ingressIssue)
                                 -> IO ())
      -- ^ Operator-facing event sink invoked by the
      -- @reload...WithEvents@ entrypoints at each strategy /
      -- phase / recovery / fallback boundary. The non-@WithEvents@
      -- entrypoints discard this field by overriding it with
      -- 'noManifestReloadEvents' before delegating, so legacy
      -- callers stay silent regardless of what they pass here.
      -- Construction sites that do not want events should set
      -- this to 'noManifestReloadEvents'.
    }

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

-- | Run one host-facing stopped-audio manifest reload attempt. No-op
-- on the event channel: 'mrhcOnEvent' is overridden with
-- 'noManifestReloadEvents' before delegating, so this entrypoint is
-- silent regardless of what the caller supplied. Use
-- 'reloadManifestStoppedAudioHostWithEvents' for the variant that
-- honors the config's event sink.
reloadManifestStoppedAudioHost
  :: ManifestReloadHostConfig target ingressIssue handle
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> MR.ManifestReloadRequest
  -> IO (Either
          (HostStoppedAudioReloadIssue
            (ManifestReloadHostIssue ingressIssue))
          ())
reloadManifestStoppedAudioHost config =
  reloadManifestStoppedAudioHostWithEvents
    (config { mrhcOnEvent = noManifestReloadEvents })

-- | Run one host-facing stopped-audio manifest reload attempt,
-- emitting structured 'ManifestReloadEvent' transitions through
-- the @mrhcOnEvent@ hook supplied in the config. The orchestrator
-- emits the phase + resume-recovery events; this wrapper adds no
-- strategy events (no strategy is in play for a single-phase
-- reload).
reloadManifestStoppedAudioHostWithEvents
  :: ManifestReloadHostConfig target ingressIssue handle
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> MR.ManifestReloadRequest
  -> IO (Either
          (HostStoppedAudioReloadIssue
            (ManifestReloadHostIssue ingressIssue))
          ())
reloadManifestStoppedAudioHostWithEvents config doc catalog request =
  orchestrateHostStoppedAudioReloadWithEvents
    (mrhcOnEvent config)
    (manifestReloadHostOps config doc catalog)
    request

-- | Run one host-facing preserving manifest reload attempt. No-op
-- on the event channel; see 'reloadManifestStoppedAudioHost' for
-- the silencing rationale, and
-- 'reloadManifestPreservingHostWithEvents' for the variant that
-- emits structured events.
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
reloadManifestPreservingHost producer config =
  reloadManifestPreservingHostWithEvents
    producer
    (config { mrhcOnEvent = noManifestReloadEvents })

-- | Run one host-facing preserving manifest reload attempt, emitting
-- structured 'ManifestReloadEvent' transitions through the
-- @mrhcOnEvent@ hook supplied in the config. The orchestrator emits
-- the phase + resume-recovery events; this wrapper adds no strategy
-- events.
reloadManifestPreservingHostWithEvents
  :: ProducerId
  -> ManifestReloadHostConfig target ingressIssue handle
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> MR.ManifestReloadRequest
  -> IO (Either
          (HostPreservingReloadIssue
            (ManifestReloadHostIssue ingressIssue))
          ())
reloadManifestPreservingHostWithEvents producer config doc catalog request =
  orchestrateHostPreservingReloadWithEvents
    (mrhcOnEvent config)
    (manifestPreservingReloadHostOps producer config doc catalog)
    request

-- | Run one manifest reload through an explicit host strategy. No-op
-- on the event channel; see 'reloadManifestStoppedAudioHost' for
-- the silencing rationale, and
-- 'reloadManifestHostWithStrategyWithEvents' for the variant that
-- emits structured events.
--
-- The producer id is used only by preserving-capable modes. In
-- 'TryPreservingThenStoppedAudio', stopped-audio fallback is attempted
-- only after a retryable preserving command rejection; all other
-- preserving failures are returned directly.
reloadManifestHostWithStrategy
  :: ProducerId
  -> ManifestReloadHostStrategy
  -> ManifestReloadHostConfig target ingressIssue handle
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> MR.ManifestReloadRequest
  -> IO (Either
          (ManifestReloadHostStrategyIssue
            (ManifestReloadHostIssue ingressIssue))
          (ManifestReloadHostStrategyRan
            (ManifestReloadHostIssue ingressIssue)))
reloadManifestHostWithStrategy producer strategy config =
  reloadManifestHostWithStrategyWithEvents
    producer
    strategy
    (config { mrhcOnEvent = noManifestReloadEvents })

-- | Run one manifest reload through an explicit host strategy,
-- emitting structured 'ManifestReloadEvent' transitions through
-- the @mrhcOnEvent@ hook supplied in the config.
--
-- The event timeline for one call is:
--
--   1. 'MreStrategyStarted' carrying the requested strategy.
--   2. Preserving / stopped-audio phase events (and any resume
--      recovery events) emitted by the orchestrator layer.
--   3. For 'TryPreservingThenStoppedAudio', after a preserving
--      rejection: 'MreFallbackAdmitted' if
--      'preservingAllowsStoppedAudioFallback' returned 'True',
--      'MreFallbackDeclined' otherwise. The fallback admission
--      event fires immediately before the stopped-audio phase
--      begins; the decline event fires when the strategy
--      surfaces the preserving rejection without a fallback
--      attempt.
--   4. 'MreStrategySucceeded' carrying the
--      'ManifestReloadHostStrategyRan' on success, or
--      'MreStrategyFailed' carrying the
--      'ManifestReloadHostStrategyIssue' on failure.
reloadManifestHostWithStrategyWithEvents
  :: ProducerId
  -> ManifestReloadHostStrategy
  -> ManifestReloadHostConfig target ingressIssue handle
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> MR.ManifestReloadRequest
  -> IO (Either
          (ManifestReloadHostStrategyIssue
            (ManifestReloadHostIssue ingressIssue))
          (ManifestReloadHostStrategyRan
            (ManifestReloadHostIssue ingressIssue)))
reloadManifestHostWithStrategyWithEvents producer strategy config doc catalog request =
  runReloadHostStrategyWithEvents
    (mrhcOnEvent config)
    strategy
    (reloadManifestPreservingHostWithEvents producer config doc catalog request)
    (reloadManifestStoppedAudioHostWithEvents config doc catalog request)

-- | Pure-strategy core of 'reloadManifestHostWithStrategyWithEvents'
-- exposed for focused event-order tests. Given an 'onEvent' sink,
-- a 'ManifestReloadHostStrategy', and the two phase actions
-- (preserving and stopped-audio) already bound against whatever
-- ops/config the caller wants, runs the strategy and emits the
-- 'MreStrategyStarted' / 'MreFallback{Admitted,Declined}' /
-- 'MreStrategy{Succeeded,Failed}' transitions. Phase and resume
-- events come from the supplied actions; this helper adds only the
-- strategy-level frame.
runReloadHostStrategyWithEvents
  :: (ManifestReloadEvent (ManifestReloadHostIssue ingressIssue) -> IO ())
  -> ManifestReloadHostStrategy
  -> IO (Either
           (HostPreservingReloadIssue
              (ManifestReloadHostIssue ingressIssue))
           ())
     -- ^ Preserving phase action. The orchestrator-level
     -- 'MrePreservingReload*' / 'MreResumeOldIngress*' events are
     -- expected to come from inside this action.
  -> IO (Either
           (HostStoppedAudioReloadIssue
              (ManifestReloadHostIssue ingressIssue))
           ())
     -- ^ Stopped-audio phase action. The orchestrator-level
     -- 'MreStoppedAudioReload*' / 'MreResumeOldIngress*' events
     -- are expected to come from inside this action.
  -> IO (Either
          (ManifestReloadHostStrategyIssue
            (ManifestReloadHostIssue ingressIssue))
          (ManifestReloadHostStrategyRan
            (ManifestReloadHostIssue ingressIssue)))
runReloadHostStrategyWithEvents onEvent strategy runPreserving runStopped = do
  onEvent (MreStrategyStarted strategy)
  case strategy of
    RequirePreserving -> do
      preserving <- runPreserving
      case preserving of
        Left issue ->
          strategyFailed (MrhsiPreservingFailed issue)
        Right () ->
          strategySucceeded MrhsrPreserving
    TryPreservingThenStoppedAudio -> do
      preserving <- runPreserving
      case preserving of
        Right () ->
          strategySucceeded MrhsrPreserving
        Left preservingIssue
          | preservingAllowsStoppedAudioFallback preservingIssue -> do
              onEvent (MreFallbackAdmitted preservingIssue)
              runFallback preservingIssue
          | otherwise -> do
              onEvent (MreFallbackDeclined preservingIssue)
              strategyFailed (MrhsiPreservingFailed preservingIssue)
    StoppedAudioOnly -> do
      stopped <- runStopped
      case stopped of
        Left issue ->
          strategyFailed (MrhsiStoppedAudioFailed issue)
        Right () ->
          strategySucceeded MrhsrStoppedAudio
  where
    strategySucceeded ran = do
      onEvent (MreStrategySucceeded ran)
      pure (Right ran)

    strategyFailed issue = do
      onEvent (MreStrategyFailed issue)
      pure (Left issue)

    runFallback preservingIssue = do
      stopped <- runStopped
      case stopped of
        Left stoppedIssue ->
          strategyFailed
            (MrhsiFallbackStoppedAudioFailed
              preservingIssue
              stoppedIssue)
        Right () ->
          strategySucceeded
            (MrhsrStoppedAudioAfterPreservingRejected preservingIssue)

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

preservingAllowsStoppedAudioFallback
  :: HostPreservingReloadIssue issue
  -> Bool
preservingAllowsStoppedAudioFallback issue =
  -- Conservative fallback gate: only a plain preserving reload
  -- rejection proves old ingress resumed and the old owner is still the
  -- live graph. Drain/quiesce failures may have pending work or only a
  -- partially recovered ingress surface, and post-install failures have
  -- already changed the live owner.
  case issue of
    HpariReloadRejected {} ->
      True
    HpariPlanRejected {} ->
      False
    HpariQuiesceRejected {} ->
      False
    HpariQuiesceRejectedResumeFailed {} ->
      False
    HpariDrainRejected {} ->
      False
    HpariDrainRejectedResumeFailed {} ->
      False
    HpariDrainFailedTerminal {} ->
      False
    HpariReloadRejectedResumeFailed {} ->
      False
    HpariReloadFailedTerminal {} ->
      False
    HpariIngressRestartFailed {} ->
      False

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
