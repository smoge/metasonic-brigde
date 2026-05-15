{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.FanIn
-- Description : Serialized session command fan-in host.
--
-- This module defines Session Prep P's generic producer fan-in
-- boundary. It owns a reloadable 'SessionOwner' generation and one
-- bounded 'SessionCommandQueue', then serializes enqueue, drain,
-- snapshot, and owner-reload admission behind an 'MVar'.
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
  , SessionFanInReloadStatus (..)
  , SessionFanInReloadIssue (..)

    -- * Operation reports
  , SessionFanInEnqueueResult (..)
  , SessionFanInDrainResult (..)
  , SessionFanInSnapshot (..)
  , SessionFanInReloadReport (..)

    -- * Scoped host
  , withSessionFanInHost
  , withSessionFanInHostHooks
  , enqueueSessionFanInCommand
  , drainSessionFanInHost
  , readSessionFanInHost
  , reloadSessionFanInHostOwnerStoppedAudio
  ) where

import           Control.Concurrent.MVar         (MVar, modifyMVar, newMVar)
import           Control.Exception               (finally, mask,
                                                  onException)
import           Control.DeepSeq                 (NFData)
import           Control.Monad                   (forM_)
import           GHC.Generics                    (Generic)

import           MetaSonic.Bridge.Templates      (TemplateGraph)
import           MetaSonic.Session.AdapterIssue  (SessionAdapterSetupIssue)
import           MetaSonic.Session.Command       (SessionCommand)
import           MetaSonic.Session.Owner         (SessionOwnerDivergence (..),
                                                  SessionOwnerHandle,
                                                  SessionOwnerOptions,
                                                  SessionOwnerStatus (..),
                                                  acquireSessionOwner,
                                                  defaultSessionOwnerOptions,
                                                  releaseSessionOwner,
                                                  sessionOwnerState,
                                                  sessionOwnerHandleOwner,
                                                  sessionOwnerStatus)
import           MetaSonic.Session.Queue         (ProducerId,
                                                  SessionCommandQueue,
                                                  SessionDrainResult (..),
                                                  SessionEnqueueIssue (..),
                                                  SessionEnqueueResult (..),
                                                  SessionQueueOptions,
                                                  SessionQueueSetupIssue,
                                                  defaultSessionQueueOptions,
                                                  drainSessionCommandQueue,
                                                  enqueueSessionCommand,
                                                  newSessionCommandQueue,
                                                  queuedCommandCount)
import           MetaSonic.Session.State         (SessionState,
                                                  initialSessionState)


-- | Hidden serialized host for producer command fan-in.
--
-- The constructor stays private so callers cannot bypass the lock or
-- retain the underlying 'SessionOwner' outside the bracket.
data SessionFanInHost = SessionFanInHost
  { sfihState :: !(MVar SessionFanInHostState)
  , sfihHooks :: !SessionFanInHostHooks
  }

data SessionFanInHostState = SessionFanInHostState
  { sfihsOwner        :: !(Maybe SessionOwnerHandle)
  , sfihsQueue        :: !SessionCommandQueue
  , sfihsReloadStatus :: !SessionFanInReloadStatus
  , sfihsLastState    :: !SessionState
  , sfihsLastStatus   :: !SessionOwnerStatus
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

-- | Reload admission state for a fan-in host.
data SessionFanInReloadStatus
  = SessionFanInNormalOperation
  | SessionFanInReloadInProgress
  | SessionFanInReloadFailed
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Stopped-audio owner-reload admission/setup failures.
data SessionFanInReloadIssue
  = SfriReloadAlreadyInProgress
  | SfriQueueNotEmpty !Int
  | SfriNoOwner
  | SfriOwnerSetupFailed !SessionAdapterSetupIssue
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
  { sfisQueueDepth   :: !Int
  , sfisOwnerState   :: !SessionState
  , sfisOwnerStatus  :: !SessionOwnerStatus
  , sfisReloadStatus :: !SessionFanInReloadStatus
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Successful stopped-audio owner reload report.
data SessionFanInReloadReport = SessionFanInReloadReport
  { sfirrQueueDepth  :: !Int
  , sfirrOwnerState  :: !SessionState
  , sfirrOwnerStatus :: !SessionOwnerStatus
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
    Right queue ->
      mask $ \restore -> do
        ownerResult <-
          acquireSessionOwner graph (sfioOwnerOptions opts)
        case ownerResult of
          Left issue ->
            pure (Left (SfisiOwner issue))
          Right owner -> do
            stateVar <- newMVar SessionFanInHostState
              { sfihsOwner =
                  Just owner
              , sfihsQueue =
                  queue
              , sfihsReloadStatus =
                  SessionFanInNormalOperation
              , sfihsLastState =
                  initialSessionState graph
              , sfihsLastStatus =
                  SessionOwnerReady
              }
            let host = SessionFanInHost
                  { sfihState =
                      stateVar
                  , sfihHooks =
                      hooks
                  }
            Right <$> restore (action host)
              `finally` releaseSessionFanInHostOwners host

-- | Enqueue one producer command under the host lock.
enqueueSessionFanInCommand
  :: ProducerId
  -> SessionCommand
  -> SessionFanInHost
  -> IO SessionFanInEnqueueResult
enqueueSessionFanInCommand producer cmd host = do
  result <- modifyMVar (sfihState host) $ \hostState -> do
    let queue = sfihsQueue hostState
        reject issue =
          ( hostState
          , SessionFanInEnqueueResult
              { sfierResult =
                  SessionEnqueueRejected producer cmd issue
              , sfierQueueDepth =
                  queuedCommandCount queue
              }
          )
    case (sfihsReloadStatus hostState, sfihsOwner hostState) of
      (SessionFanInNormalOperation, Just _) ->
        let (queue', enqueueResult) = enqueueSessionCommand producer cmd queue
            hostState' = hostState { sfihsQueue = queue' }
        in pure
             ( hostState'
             , SessionFanInEnqueueResult
                 { sfierResult =
                     enqueueResult
                 , sfierQueueDepth =
                     queuedCommandCount queue'
                 }
             )
      (SessionFanInReloadInProgress, _) ->
        pure (reject SeiReloadInProgress)
      (SessionFanInReloadFailed, _) ->
        pure (reject SeiSessionUnavailable)
      (SessionFanInNormalOperation, Nothing) ->
        pure (reject SeiSessionUnavailable)
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
  modifyMVar (sfihState host) $ \hostState -> do
    let queue = sfihsQueue hostState
        emptyDrain stopped =
          SessionFanInDrainResult
            { sfidrDrain =
                SessionDrainResult
                  { sdrItems =
                      []
                  , sdrRemaining =
                      queuedCommandCount queue
                  , sdrStopped =
                      stopped
                  }
            , sfidrQueueDepth =
                queuedCommandCount queue
            }
    case (sfihsReloadStatus hostState, sfihsOwner hostState) of
      (SessionFanInNormalOperation, Just ownerHandle) -> do
        (queue', drain) <-
          drainSessionCommandQueue
            (sessionOwnerHandleOwner ownerHandle)
            queue
        pure
          ( hostState { sfihsQueue = queue' }
          , SessionFanInDrainResult
              { sfidrDrain =
                  drain
              , sfidrQueueDepth =
                  queuedCommandCount queue'
              }
          )
      (SessionFanInReloadInProgress, _) ->
        pure (hostState, emptyDrain Nothing)
      (SessionFanInReloadFailed, _) ->
        pure (hostState, emptyDrain (Just SodBackendStopped))
      (SessionFanInNormalOperation, Nothing) ->
        pure (hostState, emptyDrain (Just SodBackendStopped))

-- | Read a consistent fan-in host snapshot.
readSessionFanInHost
  :: SessionFanInHost
  -> IO SessionFanInSnapshot
readSessionFanInHost host =
  modifyMVar (sfihState host) $ \hostState -> do
    (hostState', ownerState, ownerStatus) <-
      case sfihsOwner hostState of
        Nothing ->
          pure
            ( hostState
            , sfihsLastState hostState
            , sfihsLastStatus hostState
            )
        Just ownerHandle -> do
          ownerState <- sessionOwnerState (sessionOwnerHandleOwner ownerHandle)
          ownerStatus <- sessionOwnerStatus (sessionOwnerHandleOwner ownerHandle)
          pure
            ( hostState
                { sfihsLastState =
                    ownerState
                , sfihsLastStatus =
                    ownerStatus
                }
            , ownerState
            , ownerStatus
            )
    pure
      ( hostState'
      , SessionFanInSnapshot
          { sfisQueueDepth =
              queuedCommandCount (sfihsQueue hostState')
          , sfisOwnerState =
              ownerState
          , sfisOwnerStatus =
              ownerStatus
          , sfisReloadStatus =
              sfihsReloadStatus hostState'
          }
      )

-- | Replace the current owner after the host has stopped audio,
-- quiesced producers, and drained the queue.
--
-- The helper enforces only the precondition it can observe: the
-- queue must be empty and the host must be in normal operation. It
-- does not call start/stop audio, drain accepted commands, or reset
-- producer/listener state.
reloadSessionFanInHostOwnerStoppedAudio
  :: SessionFanInHost
  -> TemplateGraph
  -> SessionOwnerOptions
  -> IO (Either SessionFanInReloadIssue SessionFanInReloadReport)
reloadSessionFanInHostOwnerStoppedAudio host graph opts = mask $ \_restore -> do
  admitted <- modifyMVar (sfihState host) $ \hostState -> do
    let queueDepth = queuedCommandCount (sfihsQueue hostState)
    case sfihsReloadStatus hostState of
      SessionFanInReloadInProgress ->
        pure (hostState, Left SfriReloadAlreadyInProgress)
      SessionFanInReloadFailed ->
        pure (hostState, Left SfriNoOwner)
      SessionFanInNormalOperation ->
        case sfihsOwner hostState of
          Nothing ->
            pure (hostState, Left SfriNoOwner)
          Just ownerHandle
            | queueDepth /= 0 ->
                pure (hostState, Left (SfriQueueNotEmpty queueDepth))
            | otherwise ->
                pure
                  ( hostState
                      { sfihsOwner =
                          Nothing
                      , sfihsReloadStatus =
                          SessionFanInReloadInProgress
                      }
                  , Right ownerHandle
                  )
  case admitted of
    Left issue ->
      pure (Left issue)
    Right oldOwner -> do
      releaseSessionOwner oldOwner
        `onException` markReloadFailed host
      acquired <- acquireSessionOwner graph opts
        `onException` markReloadFailed host
      case acquired of
        Left setupIssue -> do
          markReloadFailed host
          pure (Left (SfriOwnerSetupFailed setupIssue))
        Right newOwner ->
          installReloadedOwner newOwner
            `onException`
              (releaseSessionOwner newOwner `finally` markReloadFailed host)
  where
    installReloadedOwner newOwner = do
      ownerState <- sessionOwnerState (sessionOwnerHandleOwner newOwner)
      ownerStatus <- sessionOwnerStatus (sessionOwnerHandleOwner newOwner)
      modifyMVar (sfihState host) $ \hostState ->
        pure
          ( hostState
              { sfihsOwner =
                  Just newOwner
              , sfihsReloadStatus =
                  SessionFanInNormalOperation
              , sfihsLastState =
                  ownerState
              , sfihsLastStatus =
                  ownerStatus
              }
          , ()
          )
      pure $ Right SessionFanInReloadReport
        { sfirrQueueDepth =
            0
        , sfirrOwnerState =
            ownerState
        , sfirrOwnerStatus =
            ownerStatus
        }

markReloadFailed :: SessionFanInHost -> IO ()
markReloadFailed host =
  modifyMVar (sfihState host) $ \hostState ->
    pure
      ( hostState
          { sfihsOwner =
              Nothing
          , sfihsReloadStatus =
              SessionFanInReloadFailed
          }
      , ()
      )

releaseSessionFanInHostOwners :: SessionFanInHost -> IO ()
releaseSessionFanInHostOwners host = do
  owner <- modifyMVar (sfihState host) $ \hostState ->
    pure
      ( hostState
          { sfihsOwner =
              Nothing
          , sfihsReloadStatus =
              SessionFanInReloadFailed
          }
      , sfihsOwner hostState
      )
  forM_ owner releaseSessionOwner
