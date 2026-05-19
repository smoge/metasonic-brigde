{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadHost.Types
-- Description : Pure types for host-level manifest reload strategy.
--
-- This module owns the host-level data declarations consumed by
-- "MetaSonic.App.ManifestReloadHost" and by downstream type modules
-- such as "MetaSonic.App.ManifestReloadEvent". Splitting the strategy
-- types out lets the event module depend on them without pulling in
-- the host's IO surface, which is what makes a future slice able to
-- import the event types from "MetaSonic.App.ManifestReloadHost"
-- without creating a cycle.
--
-- @ManifestReloadHostConfig@ is intentionally left in the function
-- module: it references the @SessionFanInService@ /
-- @ManifestReloadIngressManager@ / @SessionFanInAudioFFI@ runtime
-- surfaces that only host functions need.

module MetaSonic.App.ManifestReloadHost.Types
  ( ManifestReloadHostIssue (..)
  , ManifestReloadHostStrategy (..)
  , ManifestReloadHostStrategyIssue (..)
  , ManifestReloadHostStrategyRan (..)
  ) where

import           MetaSonic.App.ManifestReloadOrchestration.Types
                                                  (HostPreservingReloadIssue,
                                                   HostStoppedAudioReloadIssue)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.ManifestReload.Runtime
                                                  (ManifestPreservingHotSwapReport)
import           MetaSonic.Session.FanIn         (SessionFanInAudioIssue,
                                                  SessionFanInDrainResult,
                                                  SessionFanInReloadIssue)


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

-- | Explicit host-level manifest reload strategy.
--
-- 'TryPreservingThenStoppedAudio' falls back only from preserving
-- rejection paths that prove the old owner is still installed and old
-- ingress has resumed. It never falls back after preserving has
-- already changed the live owner.
data ManifestReloadHostStrategy
  = RequirePreserving
  | TryPreservingThenStoppedAudio
  | StoppedAudioOnly
  deriving stock (Eq, Show)

-- | Strategy-level failure with both causes preserved when explicit
-- fallback was attempted.
data ManifestReloadHostStrategyIssue issue
  = MrhsiPreservingFailed !(HostPreservingReloadIssue issue)
  | MrhsiStoppedAudioFailed !(HostStoppedAudioReloadIssue issue)
  | MrhsiFallbackStoppedAudioFailed
      !(HostPreservingReloadIssue issue)
      !(HostStoppedAudioReloadIssue issue)
  deriving stock (Eq, Show)

-- | Successful strategy outcome, including which install path actually
-- ran.
data ManifestReloadHostStrategyRan issue
  = MrhsrPreserving
  | MrhsrStoppedAudio
  | MrhsrStoppedAudioAfterPreservingRejected
      !(HostPreservingReloadIssue issue)
  deriving stock (Eq, Show)
