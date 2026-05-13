{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.Owner
-- Description : Single-threaded runtime owner for session commands.
--
-- This module starts Session Prep F by defining the owner vocabulary
-- and the first single-threaded owner operations. It owns a scoped
-- runtime handle through 'withSessionOwner' and composes the Prep D/E
-- step path without adding producer fan-in or a realtime queue.
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
  , defaultSessionOwnerOptions

    -- * Status and divergence
  , SessionOwnerStatus (..)
  , SessionOwnerDivergence (..)

    -- * Step result
  , SessionOwnerStepResult (..)

    -- * Scoped owner
  , withSessionOwner
  , stepSessionOwner
  , sessionOwnerState
  , sessionOwnerStatus
  ) where

import           Control.DeepSeq                  (NFData)
import           Data.IORef                       (IORef, newIORef,
                                                   readIORef, writeIORef)
import           GHC.Generics                     (Generic)

import           MetaSonic.Bridge.FFI             (withRTGraph)
import           MetaSonic.Bridge.Templates       (TemplateGraph)
import           MetaSonic.Session.AdapterIssue   (SessionAdapterSetupIssue)
import           MetaSonic.Session.Command        (SessionCommand)
import           MetaSonic.Session.RTGraphAdapter (RTGraphAdapterOptions)
import qualified MetaSonic.Session.RTGraphAdapter as RTGraphAdapter
import           MetaSonic.Session.Runtime        (SessionRuntimeAdapter,
                                                   SessionRuntimeIssue (..))
import           MetaSonic.Session.State          (SessionCommitIssue,
                                                   SessionState,
                                                   initialSessionState)
import           MetaSonic.Session.Step           (SessionStepResult (..),
                                                   stepSessionCommand)


-- | Hidden owner for a caller-scoped runtime session.
--
-- The owner is single-threaded by contract. Concurrent
-- 'stepSessionOwner' calls race on these private 'IORef's; callers
-- must serialize access.
data SessionOwner = SessionOwner
  { soState   :: !(IORef SessionState)
  , soStatus  :: !(IORef SessionOwnerStatus)
  , soAdapter :: !(SessionRuntimeAdapter IO)
  }

-- | Construction options for the owner bracket.
data SessionOwnerOptions = SessionOwnerOptions
  { sooBuilderCapacity :: !Int
  , sooMaxFrames       :: !Int
  , sooAdapterOptions  :: !RTGraphAdapterOptions
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Conservative test/demo defaults for owner construction.
--
-- Callers with known graph-size or block-size requirements should
-- override these explicitly; Prep F does not infer capacity from graph
-- shape.
defaultSessionOwnerOptions :: SessionOwnerOptions
defaultSessionOwnerOptions = SessionOwnerOptions
  { sooBuilderCapacity = 256
  , sooMaxFrames       = 64
  , sooAdapterOptions  = RTGraphAdapter.defaultRTGraphAdapterOptions
  }

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

-- | Allocate a scoped runtime owner for one template graph.
--
-- Construction failures are returned as 'Left'. Exceptions thrown by
-- the callback propagate after the underlying 'withRTGraph' cleanup
-- runs.
withSessionOwner
  :: TemplateGraph
  -> SessionOwnerOptions
  -> (SessionOwner -> IO a)
  -> IO (Either SessionAdapterSetupIssue a)
withSessionOwner graph opts action =
  withRTGraph (sooBuilderCapacity opts) (sooMaxFrames opts) $ \rt -> do
    adapterResult <-
      RTGraphAdapter.newRTGraphAdapter
        rt
        graph
        (sooAdapterOptions opts)
    case adapterResult of
      Left issue ->
        pure (Left issue)
      Right adapter -> do
        stateRef <- newIORef (initialSessionState graph)
        statusRef <- newIORef SessionOwnerReady
        Right <$> action SessionOwner
          { soState   = stateRef
          , soStatus  = statusRef
          , soAdapter = adapter
          }

-- | Read the last pure session state known to agree with the runtime.
--
-- After divergence, this may be stale relative to actual audio/runtime
-- behavior.
sessionOwnerState :: SessionOwner -> IO SessionState
sessionOwnerState =
  readIORef . soState

-- | Read the current owner status.
sessionOwnerStatus :: SessionOwner -> IO SessionOwnerStatus
sessionOwnerStatus =
  readIORef . soStatus

-- | Run one command through the owned single-threaded step path.
--
-- State is written only for 'StepCommitted'. Terminal divergence is
-- recorded and surfaced as 'SessionOwnerDivergedNow'; later commands
-- return 'SessionOwnerBlocked' without invoking the adapter.
stepSessionOwner
  :: SessionOwner
  -> SessionCommand
  -> IO SessionOwnerStepResult
stepSessionOwner owner cmd = do
  status <- readIORef (soStatus owner)
  case status of
    SessionOwnerDiverged reason ->
      pure (SessionOwnerBlocked reason)
    SessionOwnerReady -> do
      current <- readIORef (soState owner)
      result <- stepSessionCommand (soAdapter owner) cmd current
      case result of
        StepCommitted newState _ ->
          writeIORef (soState owner) newState
        _ ->
          pure ()
      case ownerDivergence result of
        Just reason -> do
          writeIORef (soStatus owner) (SessionOwnerDiverged reason)
          pure (SessionOwnerDivergedNow result reason)
        Nothing ->
          pure (SessionOwnerStep result)

ownerDivergence :: SessionStepResult -> Maybe SessionOwnerDivergence
ownerDivergence result = case result of
  StepRuntimeFailed (SriHotSwapInstallFailed issue) ->
    Just (SodHotSwapInstallFailed issue)
  StepRuntimeFailed SriBackendStopped ->
    Just SodBackendStopped
  StepCommitMismatch issue ->
    Just (SodCommitMismatch issue)
  StepAdapterProtocolBug message ->
    Just (SodAdapterProtocolBug message)
  -- New runtime failures default to non-terminal here. Promote a
  -- constructor explicitly when it represents a state/runtime sync
  -- hazard for the owner. In particular, hot-swap publish backpressure
  -- and stopped-audio requirements are retryable without rebuilding
  -- owner state.
  _ ->
    Nothing
