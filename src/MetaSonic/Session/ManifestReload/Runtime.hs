{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.ManifestReload.Runtime
-- Description : Runtime-facing manifest reload helpers.
--
-- This module implements the non-audio stopped-reload helper from
-- notes/2026-05-14-i-manifest-reload-runtime-strategy.md. The caller
-- supplies a prevalidated 'ManifestReloadPlan', stops audio before
-- calling, and restarts audio/listeners after a successful result.

module MetaSonic.Session.ManifestReload.Runtime
  ( ManifestStoppedAudioReloadReport (..)
  , reloadManifestSessionStoppedAudio
  ) where

import           Control.DeepSeq                 (NFData)
import           GHC.Generics                    (Generic)

import           MetaSonic.Pattern               (SwapLabel)
import           MetaSonic.Session.FanIn         (SessionFanInHost,
                                                  SessionFanInReloadIssue,
                                                  SessionFanInReloadReport (..),
                                                  reloadSessionFanInHostOwnerStoppedAudio)
import           MetaSonic.Session.ManifestReload
                                                (ManifestReloadPlan (..),
                                                 manifestSessionOwnerOptions)
import           MetaSonic.Session.Owner         (SessionOwnerOptions,
                                                  SessionOwnerStatus)
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
        }
