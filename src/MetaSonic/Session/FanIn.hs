{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.FanIn
-- Description : Serialized session command fan-in host.
--
-- This module defines Session Prep P's generic producer fan-in
-- boundary. It owns a scoped 'SessionOwner' and one bounded
-- 'SessionCommandQueue', then serializes enqueue, drain, and snapshot
-- operations behind an 'MVar'.
--
-- It does not parse OSC, read MIDI, create a background worker, define
-- a realtime clock, or add a new runtime queue. Concrete producers can
-- submit 'SessionCommand' values here once they have chosen their own
-- protocol-specific translation policy.
--
-- See [notes/2026-05-13-h-session-prep-p-producer-fan-in-host.md].

module MetaSonic.Session.FanIn
  ( -- * Host
    SessionFanInHost

    -- * Options
  , SessionFanInOptions (..)
  , defaultSessionFanInOptions
  , SessionFanInHostHooks (..)
  , defaultSessionFanInHostHooks

    -- * Setup issues
  , SessionFanInSetupIssue (..)

    -- * Operation reports
  , SessionFanInEnqueueResult (..)
  , SessionFanInDrainResult (..)
  , SessionFanInSnapshot (..)

    -- * Scoped host
  , withSessionFanInHost
  , withSessionFanInHostHooks
  , enqueueSessionFanInCommand
  , drainSessionFanInHost
  , readSessionFanInHost
  ) where

import           Control.Concurrent.MVar         (MVar, modifyMVar, newMVar,
                                                  withMVar)
import           Control.DeepSeq                 (NFData)
import           GHC.Generics                    (Generic)

import           MetaSonic.Bridge.Templates      (TemplateGraph)
import           MetaSonic.Session.AdapterIssue  (SessionAdapterSetupIssue)
import           MetaSonic.Session.Command       (SessionCommand)
import           MetaSonic.Session.Owner         (SessionOwner,
                                                  SessionOwnerOptions,
                                                  SessionOwnerStatus,
                                                  defaultSessionOwnerOptions,
                                                  sessionOwnerState,
                                                  sessionOwnerStatus,
                                                  withSessionOwner)
import           MetaSonic.Session.Queue         (ProducerId,
                                                  SessionCommandQueue,
                                                  SessionDrainResult,
                                                  SessionEnqueueResult (..),
                                                  SessionQueueOptions,
                                                  SessionQueueSetupIssue,
                                                  defaultSessionQueueOptions,
                                                  drainSessionCommandQueue,
                                                  enqueueSessionCommand,
                                                  newSessionCommandQueue,
                                                  queuedCommandCount)
import           MetaSonic.Session.State         (SessionState)


-- | Hidden serialized host for producer command fan-in.
--
-- The constructor stays private so callers cannot bypass the lock or
-- retain the underlying 'SessionOwner' outside the bracket.
data SessionFanInHost = SessionFanInHost
  { sfihOwner :: !SessionOwner
  , sfihQueue :: !(MVar SessionCommandQueue)
  , sfihHooks :: !SessionFanInHostHooks
  }

-- | Construction options for the generic fan-in host.
data SessionFanInOptions = SessionFanInOptions
  { sfioQueueOptions :: !SessionQueueOptions
  , sfioOwnerOptions :: !SessionOwnerOptions
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Conservative test/demo defaults for command fan-in.
defaultSessionFanInOptions :: SessionFanInOptions
defaultSessionFanInOptions = SessionFanInOptions
  { sfioQueueOptions = defaultSessionQueueOptions
  , sfioOwnerOptions = defaultSessionOwnerOptions
  }

-- | Optional host hooks.
--
-- The default hook preserves Prep P's caller-driven behavior. A later
-- service can install a wakeup hook without changing producer APIs.
data SessionFanInHostHooks = SessionFanInHostHooks
  { sfihhOnEnqueued :: !(IO ())
    -- ^ Called after a command is successfully queued.
  }

-- | Caller-driven fan-in host hooks.
defaultSessionFanInHostHooks :: SessionFanInHostHooks
defaultSessionFanInHostHooks = SessionFanInHostHooks
  { sfihhOnEnqueued = pure ()
  }

-- | Host construction failures from any owned subcomponent.
data SessionFanInSetupIssue
  = SfisiQueue !SessionQueueSetupIssue
  | SfisiOwner !SessionAdapterSetupIssue
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Result of one serialized enqueue attempt.
data SessionFanInEnqueueResult = SessionFanInEnqueueResult
  { sfierResult     :: !SessionEnqueueResult
  , sfierQueueDepth :: !Int
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Result of one serialized queue drain.
data SessionFanInDrainResult = SessionFanInDrainResult
  { sfidrDrain      :: !SessionDrainResult
  , sfidrQueueDepth :: !Int
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Lock-protected snapshot of queued work and owner state.
data SessionFanInSnapshot = SessionFanInSnapshot
  { sfisQueueDepth  :: !Int
  , sfisOwnerState  :: !SessionState
  , sfisOwnerStatus :: !SessionOwnerStatus
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Allocate a scoped, serialized command fan-in host.
--
-- Queue setup is validated before allocating the runtime owner.
withSessionFanInHost
  :: TemplateGraph
  -> SessionFanInOptions
  -> (SessionFanInHost -> IO a)
  -> IO (Either SessionFanInSetupIssue a)
withSessionFanInHost =
  withSessionFanInHostHooks defaultSessionFanInHostHooks

-- | Allocate a scoped fan-in host with explicit hooks.
withSessionFanInHostHooks
  :: SessionFanInHostHooks
  -> TemplateGraph
  -> SessionFanInOptions
  -> (SessionFanInHost -> IO a)
  -> IO (Either SessionFanInSetupIssue a)
withSessionFanInHostHooks hooks graph opts action =
  case newSessionCommandQueue (sfioQueueOptions opts) of
    Left issue ->
      pure (Left (SfisiQueue issue))
    Right queue -> do
      ownerResult <-
        withSessionOwner graph (sfioOwnerOptions opts) $ \owner -> do
          queueVar <- newMVar queue
          action SessionFanInHost
            { sfihOwner = owner
            , sfihQueue = queueVar
            , sfihHooks = hooks
            }
      case ownerResult of
        Left issue ->
          pure (Left (SfisiOwner issue))
        Right value ->
          pure (Right value)

-- | Enqueue one producer command under the host lock.
enqueueSessionFanInCommand
  :: ProducerId
  -> SessionCommand
  -> SessionFanInHost
  -> IO SessionFanInEnqueueResult
enqueueSessionFanInCommand producer cmd host = do
  result <- modifyMVar (sfihQueue host) $ \queue -> do
    let (queue', enqueueResult) = enqueueSessionCommand producer cmd queue
    pure
      ( queue'
      , SessionFanInEnqueueResult
          { sfierResult =
              enqueueResult
          , sfierQueueDepth =
              queuedCommandCount queue'
          }
      )
  case sfierResult result of
    SessionEnqueued {} ->
      sfihhOnEnqueued (sfihHooks host)
    SessionEnqueueRejected {} ->
      pure ()
  pure result

-- | Drain queued commands through the owned session owner.
--
-- The lock covers the whole drain, including any preserving hot-swap
-- publish/wait/collect/commit sequence reached by the owner.
drainSessionFanInHost
  :: SessionFanInHost
  -> IO SessionFanInDrainResult
drainSessionFanInHost host =
  modifyMVar (sfihQueue host) $ \queue -> do
    (queue', drain) <- drainSessionCommandQueue (sfihOwner host) queue
    pure
      ( queue'
      , SessionFanInDrainResult
          { sfidrDrain =
              drain
          , sfidrQueueDepth =
              queuedCommandCount queue'
          }
      )

-- | Read a consistent fan-in host snapshot.
readSessionFanInHost
  :: SessionFanInHost
  -> IO SessionFanInSnapshot
readSessionFanInHost host =
  withMVar (sfihQueue host) $ \queue -> do
    ownerState <- sessionOwnerState (sfihOwner host)
    ownerStatus <- sessionOwnerStatus (sfihOwner host)
    pure SessionFanInSnapshot
      { sfisQueueDepth =
          queuedCommandCount queue
      , sfisOwnerState =
          ownerState
      , sfisOwnerStatus =
          ownerStatus
      }
