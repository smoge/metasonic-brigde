{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.Runtime
-- Description : Narrow adapter vocabulary for the Session Prep D shell.
--
-- This module defines the injected adapter contract a future runtime
-- owner will satisfy. It does not own an 'RTGraph', does not call
-- FFI, does not assume a queue, and does not depend on a C++ session
-- object. Mock adapters live entirely in test code.
--
-- See [notes/2026-05-12-session-prep-d-runtime-adapter-shell.md].

module MetaSonic.Session.Runtime
  ( -- * Adapter
    SessionRuntimeAdapter (..)

    -- * Runtime operations
  , RealtimeOp (..)

    -- * Outcomes
  , SessionRuntimeSuccess (..)
  , SessionRuntimeIssue (..)

    -- * Runtime install/setup issues
  , SessionAdapterSetupIssue (..)
  , SessionPrewarmIssue (..)
  ) where

import           Control.DeepSeq          (NFData)
import           GHC.Generics             (Generic)

import           MetaSonic.ControlTarget  (ControlTargetIssue)
import           MetaSonic.Pattern        (TemplateName)
import           MetaSonic.Session.AdapterIssue
                                             (SessionAdapterSetupIssue (..),
                                             SessionPrewarmIssue (..))
import           MetaSonic.Session.State  (SessionCommit, SessionPlan)


-- | Record-of-functions adapter for executing one admitted
-- 'SessionPlan' against an injected runtime. The orchestrator in
-- 'MetaSonic.Session.Step' is the only intended caller.
--
-- The adapter runs in an arbitrary 'Monad' so the same shell pins both
-- pure mocks (via 'Identity') and real 'IO' adapters.
newtype SessionRuntimeAdapter m = SessionRuntimeAdapter
  { sraRun
      :: SessionPlan
      -> m (Either SessionRuntimeIssue SessionRuntimeSuccess)
  }

-- | Successful runtime outcome.
--
-- Voice-start, voice-stop, and graph-install plans return a committed
-- fact that the orchestrator will feed through the Prep C plan/commit
-- handshake. Control-write plans return an acknowledgement only:
-- there is no 'SessionCommit' constructor for them because no
-- 'SessionState' mutation is needed at this layer.
data SessionRuntimeSuccess
  = RuntimeCommitted !SessionCommit
  | RuntimeControlWriteAccepted
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Realtime ABI operation whose queue interaction failed.
data RealtimeOp
  = RtOpReserve
  | RtOpActivate
  | RtOpCancel
  | RtOpRelease
  | RtOpSetControl
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Vocabulary for runtime-side failures reported by an adapter.
--
-- Deliberately distinct from 'SessionIssue' (producer-facing
-- admission rejection) and 'SessionCommitIssue' (plan/commit
-- handshake mismatch). Setup/install failures normally surface from
-- adapter construction, but constrained hot-swap wraps the same
-- structured setup vocabulary because graph install runs through the
-- runtime adapter. The free-form 'SriAdapterReason' is a documented
-- escape hatch for unexpected adapter-specific text; normal realtime
-- failures should use the structured constructors.
data SessionRuntimeIssue
  = SriVoiceAllocationFailed
  | SriUnknownRuntimeTemplate !TemplateName
  | SriControlTargetRejected !ControlTargetIssue
  | SriRealtimeQueueFull !RealtimeOp
  | SriHotSwapWouldPreserveVoices
    -- ^ Prep E only supports graph installs whose rebuild preview
    -- leaves no surviving logical voices.
  | SriHotSwapInstallFailed !SessionAdapterSetupIssue
    -- ^ A constrained hot-swap reached graph installation but the
    -- underlying setup/install helper failed.
  | SriControlWriteRejected
  | SriBackendStopped
  | SriAdapterReason !String
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)
