{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE EmptyDataDecls     #-}

-- |
-- Module      : MetaSonic.Session.Owner
-- Description : Type surface for the single-threaded session owner.
--
-- This module starts Session Prep F by defining the owner vocabulary
-- only. Construction, stepping, and runtime ownership behavior land in
-- the following Prep F slices.
--
-- The 'SessionOwner' constructor is intentionally hidden. Callers must
-- not fabricate owner values or manage the underlying runtime pieces
-- directly.
--
-- See [notes/2026-05-12-session-prep-f-runtime-owner.md].

module MetaSonic.Session.Owner
  ( -- * Owner
    SessionOwner

    -- * Options
  , SessionOwnerOptions (..)

    -- * Status and divergence
  , SessionOwnerStatus (..)
  , SessionOwnerDivergence (..)

    -- * Step result
  , SessionOwnerStepResult (..)
  ) where

import           Control.DeepSeq                  (NFData)
import           GHC.Generics                     (Generic)

import           MetaSonic.Session.AdapterIssue   (SessionAdapterSetupIssue)
import           MetaSonic.Session.RTGraphAdapter (RTGraphAdapterOptions)
import           MetaSonic.Session.State          (SessionCommitIssue)
import           MetaSonic.Session.Step           (SessionStepResult)


-- | Hidden owner for a caller-scoped runtime session.
--
-- The constructor and fields land with the construction slice. This
-- declaration is intentionally empty so callers cannot fabricate
-- owners. When the body lands, remove the 'EmptyDataDecls' pragma.
data SessionOwner

-- | Construction options for the future owner bracket.
data SessionOwnerOptions = SessionOwnerOptions
  { sooBuilderCapacity :: !Int
  , sooMaxFrames       :: !Int
  , sooAdapterOptions  :: !RTGraphAdapterOptions
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Current health of the owner.
data SessionOwnerStatus
  = SessionOwnerReady
    -- ^ Runtime and pure 'SessionState' are still known to agree.
  | SessionOwnerDiverged !SessionOwnerDivergence
    -- ^ The owner hit a terminal divergence and must be torn down.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Terminal divergence reasons for the single-threaded owner.
data SessionOwnerDivergence
  = SodHotSwapInstallFailed !SessionAdapterSetupIssue
    -- ^ Constrained hot-swap install failed; runtime may be in an
    -- indeterminate state while pure session state still claims the
    -- old graph.
  | SodBackendStopped
    -- ^ Realtime backend stopped; queued operations may never drain.
  | SodCommitMismatch !SessionCommitIssue
    -- ^ Adapter returned a commit that did not match the admitted plan.
  | SodAdapterProtocolBug !String
    -- ^ Adapter returned the wrong success shape for the plan.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Result of one owner-mediated command step.
data SessionOwnerStepResult
  = SessionOwnerStep !SessionStepResult
    -- ^ Normal step result; the owner remains ready.
  | SessionOwnerDivergedNow !SessionStepResult !SessionOwnerDivergence
    -- ^ This command produced a terminal divergence. The underlying
    -- step result is preserved for audit, and later commands are
    -- blocked.
  | SessionOwnerBlocked !SessionOwnerDivergence
    -- ^ The owner had already diverged, so the adapter was not called.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)
