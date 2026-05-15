{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.Owner
-- Description : Single-threaded runtime owner for session commands.
--
-- This module defines the Session Prep F owner vocabulary and
-- single-threaded owner operations. It owns a scoped runtime handle
-- through 'withSessionOwner' and composes the Prep D/E step path. The
-- owner itself does not add producer fan-in or a realtime queue; later
-- modules wrap it when they need those boundaries.
--
-- The 'SessionOwner' constructor is intentionally hidden. Callers must
-- not fabricate owner values or manage the underlying runtime pieces
-- directly.
--
-- See [notes/2026-05-12-s-session-prep-f-runtime-owner.md].

module MetaSonic.Session.Owner
  ( -- * Owner
    SessionOwner
  , SessionOwnerHandle

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
  , acquireSessionOwner
  , releaseSessionOwner
  , sessionOwnerHandleOwner
  , stepSessionOwner
  , sessionOwnerState
  , sessionOwnerStatus
  ) where

import           Control.Exception                (finally, mask,
                                                   onException)
import           Control.DeepSeq                  (NFData)
import           Data.IORef                       (IORef, newIORef,
                                                   readIORef, writeIORef)
import           Foreign.Ptr                      (Ptr)
import           GHC.Generics                     (Generic)

import           MetaSonic.Bridge.FFI             (RTGraph, createRTGraph,
                                                   destroyRTGraph)
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

-- | Manually scoped owner handle.
--
-- This exists for higher-level session hosts that must keep one outer
-- host lifetime while replacing the current owner generation. Plain
-- callers should keep using 'withSessionOwner'.
data SessionOwnerHandle = SessionOwnerHandle
  { sohOwner   :: !SessionOwner
  , sohRTGraph :: !(Ptr RTGraph)
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
  mask $ \restore -> do
    acquired <- acquireSessionOwner graph opts
    case acquired of
      Left issue ->
        pure (Left issue)
      Right handle ->
        (Right <$> restore (action (sessionOwnerHandleOwner handle)))
          `finally` releaseSessionOwner handle

-- | Acquire an owner generation without a continuation bracket.
--
-- The returned handle must be released exactly once with
-- 'releaseSessionOwner'. If setup fails, the temporary RTGraph is
-- released before the failure is returned.
acquireSessionOwner
  :: TemplateGraph
  -> SessionOwnerOptions
  -> IO (Either SessionAdapterSetupIssue SessionOwnerHandle)
acquireSessionOwner graph opts =
  mask $ \restore -> do
    rt <- createRTGraph (sooBuilderCapacity opts) (sooMaxFrames opts)
    adapterResult <- restore
      (RTGraphAdapter.newRTGraphAdapter
        rt
        graph
        (sooAdapterOptions opts))
      `onException` destroyRTGraph rt
    case adapterResult of
      Left issue -> do
        destroyRTGraph rt
        pure (Left issue)
      Right adapter -> do
        stateRef <- newIORef (initialSessionState graph)
        statusRef <- newIORef SessionOwnerReady
        pure $ Right SessionOwnerHandle
          { sohOwner =
              SessionOwner
                { soState   = stateRef
                , soStatus  = statusRef
                , soAdapter = adapter
                }
          , sohRTGraph =
              rt
          }

-- | Release an owner generation acquired by 'acquireSessionOwner'.
releaseSessionOwner :: SessionOwnerHandle -> IO ()
releaseSessionOwner =
  destroyRTGraph . sohRTGraph

-- | Borrow the owner value from a live handle.
sessionOwnerHandleOwner :: SessionOwnerHandle -> SessionOwner
sessionOwnerHandleOwner =
  sohOwner

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
  -- and explicit stopped-audio requirements from scripted-only
  -- adapters are retryable without rebuilding owner state.
  _ ->
    Nothing
