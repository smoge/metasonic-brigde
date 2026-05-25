{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.ManifestReload.Runtime
-- Description : Runtime-facing manifest reload helpers.
--
-- This module implements runtime-facing helpers from
-- notes/2026-05-14-i-manifest-reload-runtime-strategy.md. Callers
-- supply a prevalidated 'ManifestReloadPlan' and choose the install
-- strategy explicitly: stopped-audio owner replacement, or preserving
-- hot-swap through the live fan-in path.

module MetaSonic.Session.ManifestReload.Runtime
  ( ManifestStoppedAudioReloadReport (..)
  , ManifestPreservingHotSwapReport (..)
  , reloadManifestSessionStoppedAudio
  , reloadManifestSessionPreservingHotSwap
  ) where

import           Control.DeepSeq                 (NFData)
import           GHC.Generics                    (Generic)

import           MetaSonic.Pattern               (SwapLabel)
import           MetaSonic.Session.Command       (SessionCommand)
import           MetaSonic.Session.FanIn         (SessionFanInDrainResult,
                                                  SessionFanInEnqueueResult (..),
                                                  SessionFanInHost,
                                                  SessionFanInSnapshot (..),
                                                  SessionFanInReloadIssue,
                                                  SessionFanInReloadReport (..),
                                                  drainSessionFanInHost,
                                                  enqueueSessionFanInCommand,
                                                  readSessionFanInHost,
                                                  reloadSessionFanInHostOwnerStoppedAudio)
import           MetaSonic.Session.ManifestReload
                                                (ManifestReloadPlan (..),
                                                 manifestReloadCommand,
                                                 manifestSessionOwnerOptions)
import           MetaSonic.Session.Owner         (SessionOwnerOptions,
                                                  SessionOwnerStatus)
import           MetaSonic.Session.Queue         (ProducerId,
                                                  SessionEnqueueResult (..))
import           MetaSonic.Session.Resolve       (RetiredVoiceBinding)
import           MetaSonic.Session.State         (SessionState)


-- | Successful manifest stopped-reload report.
--
-- A successful reload means a new owner has been constructed and
-- installed under the fan-in host. The caller still owns audio restart
-- and producer/listener bracket restart.
data ManifestStoppedAudioReloadReport = ManifestStoppedAudioReloadReport
  { msarrDemoKey              :: !String
  , msarrSwapLabel            :: !SwapLabel
  , msarrOwnerState           :: !SessionState
  , msarrOwnerStatus          :: !SessionOwnerStatus
  , msarrListenersMustRestart :: !Bool
  , msarrRetired              :: ![RetiredVoiceBinding]
    -- ^ Phase 8h step 3e v1: voice bindings the old owner held
    -- immediately before release, forwarded verbatim from
    -- 'sfirrRetired' on 'SessionFanInReloadReport'. Each entry
    -- carries 'RvrOwnerReplaced' — the stopped-audio path discards
    -- the entire pre-reload voice map regardless of template
    -- survival.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Report from submitting a preserving manifest reload through the
-- existing owner/fan-in command path.
--
-- The helper returns a report for both accepted and rejected enqueue
-- attempts. If enqueue is rejected, no queue drain is attempted, so the
-- helper does not accidentally process unrelated pending work.
data ManifestPreservingHotSwapReport = ManifestPreservingHotSwapReport
  { mphsrDemoKey       :: !String
  , mphsrSwapLabel     :: !SwapLabel
  , mphsrCommand       :: !SessionCommand
  , mphsrEnqueueResult :: !SessionFanInEnqueueResult
  , mphsrDrainResult   :: !(Maybe SessionFanInDrainResult)
    -- ^ Drain result for all commands drained after a successful
    -- enqueue, including this helper's accepted hot-swap command.
    -- 'Nothing' means enqueue was rejected and no drain was attempted.
  , mphsrOwnerState    :: !SessionState
    -- ^ Host owner state from the post-drain or post-rejection
    -- snapshot.
  , mphsrOwnerStatus   :: !SessionOwnerStatus
    -- ^ Host owner status from the post-drain or post-rejection
    -- snapshot.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Replace the host's current owner from a prevalidated manifest
-- reload plan.
--
-- Preconditions owned by the caller:
--
-- * the plan has already been produced by 'planManifestReload';
-- * realtime audio is stopped;
-- * producers/listeners are quiescent;
-- * accepted queued commands have already drained.
--
-- The helper enforces the observable queue-empty admission rule and
-- never calls start/stop audio itself.
reloadManifestSessionStoppedAudio
  :: SessionFanInHost
  -> SessionOwnerOptions
  -> ManifestReloadPlan
  -> IO (Either SessionFanInReloadIssue ManifestStoppedAudioReloadReport)
reloadManifestSessionStoppedAudio host baseOptions plan = do
  result <-
    reloadSessionFanInHostOwnerStoppedAudio
      host
      (mrlpTemplateGraph plan)
      (manifestSessionOwnerOptions baseOptions plan)
  pure $ case result of
    Left issue ->
      Left issue
    Right report ->
      Right ManifestStoppedAudioReloadReport
        { msarrDemoKey =
            mrlpDemoKey plan
        , msarrSwapLabel =
            mrlpSwapLabel plan
        , msarrOwnerState =
            sfirrOwnerState report
        , msarrOwnerStatus =
            sfirrOwnerStatus report
        , msarrListenersMustRestart =
            True
        , msarrRetired =
            sfirrRetired report
        }

-- | Submit a manifest reload as a preserving-only hot-swap command.
--
-- This is the live-reload sibling of 'reloadManifestSessionStoppedAudio':
-- it projects the prevalidated plan to 'manifestReloadCommand', enqueues
-- that command through the existing producer fan-in host, and, if
-- accepted, drains all currently queued commands through the current
-- owner, including the accepted manifest hot-swap command.
--
-- Unlike 'reloadManifestSessionStoppedAudio', this helper has no
-- queue-empty admission rule. That asymmetry is intentional: the live
-- preserving path composes with producer playback already admitted to
-- the fan-in queue. It never replaces the owner, never calls the
-- stopped-audio reload helper, and never falls back to clear/rebuild
-- semantics on behalf of the caller.
--
-- A rejected enqueue is reported directly with no drain attempt.
reloadManifestSessionPreservingHotSwap
  :: ProducerId
  -> SessionFanInHost
  -> ManifestReloadPlan
  -> IO ManifestPreservingHotSwapReport
reloadManifestSessionPreservingHotSwap producer host plan = do
  let command = manifestReloadCommand plan
  enqueueResult <- enqueueSessionFanInCommand producer command host
  drainResult <- case sfierResult enqueueResult of
    SessionEnqueued {} ->
      Just <$> drainSessionFanInHost host
    SessionEnqueueRejected {} ->
      pure Nothing
  snapshot <- readSessionFanInHost host
  pure ManifestPreservingHotSwapReport
    { mphsrDemoKey =
        mrlpDemoKey plan
    , mphsrSwapLabel =
        mrlpSwapLabel plan
    , mphsrCommand =
        command
    , mphsrEnqueueResult =
        enqueueResult
    , mphsrDrainResult =
        drainResult
    , mphsrOwnerState =
        sfisOwnerState snapshot
    , mphsrOwnerStatus =
        sfisOwnerStatus snapshot
    }
