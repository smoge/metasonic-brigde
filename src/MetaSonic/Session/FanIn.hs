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
-- snapshot, owner-reload admission, and current-owner audio
-- lifecycle behind an 'MVar'.
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
  , SessionFanInAudioIssue (..)

    -- * Operation reports
  , SessionFanInEnqueueResult (..)
  , SessionFanInDrainResult (..)
  , SessionFanInSnapshot (..)
  , SessionFanInReloadReport (..)

    -- * Audio lifecycle
  , SessionFanInAudioOptions (..)
  , SessionFanInAudioFFI (..)
  , defaultSessionFanInAudioFFI
  , startSessionFanInHostAudio
  , startSessionFanInHostAudioWith
  , stopSessionFanInHostAudio
  , stopSessionFanInHostAudioWith
  , stopSessionFanInHostAudioFadeWith

    -- * Scoped host
  , withSessionFanInHost
  , withSessionFanInHostHooks
  , openSessionFanInHost
  , openSessionFanInHostHooks
  , closeSessionFanInHost
  , enqueueSessionFanInCommand
  , drainSessionFanInHost
  , readSessionFanInHost
  , reloadSessionFanInHostOwnerStoppedAudio
  ) where

import           Control.Concurrent.MVar         (MVar, modifyMVar, newMVar)
import           Control.Exception               (finally, mask, mask_,
                                                  onException)
import           Control.DeepSeq                 (NFData)
import           Control.Monad                   (forM_)
import           Foreign.Ptr                     (Ptr)
import           GHC.Generics                    (Generic)

import qualified MetaSonic.Bridge.FFI            as FFI
import           MetaSonic.Bridge.FFI            (RTGraph)
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
                                                  sessionOwnerHandleOwner,
                                                  sessionOwnerHandleRTGraph,
                                                  sessionOwnerState,
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
  , sfihsAudioRunning :: !Bool
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
  | SfriAudioStillRunning
  | SfriNoOwner
  | SfriOwnerSetupFailed !SessionAdapterSetupIssue
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Audio-lifecycle configuration for the current fan-in owner.
--
-- The host (not the session layer) supplies these per call; the fan-in
-- host does not retain audio configuration across owner replacement.
data SessionFanInAudioOptions = SessionFanInAudioOptions
  { sfiaoOutputChannels :: !Int
  , sfiaoDeviceID       :: !Int
  , sfiaoReadyTimeoutMs :: !Int
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Injected FFI entry points for current-owner audio lifecycle.
--
-- Production code uses 'defaultSessionFanInAudioFFI'. Tests inject mocks
-- so the audio state machine is observable without PortAudio.
--
-- 'saffiStopAudioFade' is the Phase 8f graceful-stop entry: it applies
-- a brief linear output fade before stopping. It is used by the host-
-- stack close path ('stopSessionFanInHostAudioFadeWith') — the close
-- slot every supervised production route wires through. In-window
-- reload stop continues to use 'saffiStopAudio' so reload sequencing
-- is unaffected by the fade.
data SessionFanInAudioFFI = SessionFanInAudioFFI
  { saffiStartAudio       :: !(Ptr RTGraph -> Int -> Int -> IO Int)
  , saffiWaitAudioStarted :: !(Ptr RTGraph -> Int -> IO Bool)
  , saffiStopAudio        :: !(Ptr RTGraph -> IO ())
  , saffiStopAudioFade    :: !(Ptr RTGraph -> Int -> IO ())
  }

-- | Real-FFI audio entry points.
defaultSessionFanInAudioFFI :: SessionFanInAudioFFI
defaultSessionFanInAudioFFI = SessionFanInAudioFFI
  { saffiStartAudio       = FFI.startAudio
  , saffiWaitAudioStarted = FFI.waitAudioStarted
  , saffiStopAudio        = FFI.stopAudio
  , saffiStopAudioFade    = FFI.stopAudioFade
  }

-- | Current-owner audio lifecycle failures.
data SessionFanInAudioIssue
  = SfaiNoOwner
  | SfaiReloadInProgress
  | SfaiAudioAlreadyRunning
  | SfaiAudioAlreadyStopped
  | SfaiStartFailed !Int
    -- ^ Underlying 'startAudio' returned a nonzero status code.
  | SfaiReadyTimeout
    -- ^ 'startAudio' accepted, but the runtime did not flip to
    -- audio-running within the configured ready timeout. The helper
    -- calls 'stopAudio' before returning so PortAudio is not left in an
    -- indeterminate state.
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
  , sfisAudioRunning :: !Bool
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
  mask $ \restore -> do
    openResult <- openSessionFanInHostHooks hooks graph opts
    case openResult of
      Left issue ->
        pure (Left issue)
      Right host ->
        (Right <$> restore (action host))
          `finally` closeSessionFanInHost host

-- | Open a fan-in host outside a bracket. Pair with
-- 'closeSessionFanInHost'.
--
-- 'withSessionFanInHostHooks' is still the preferred entry for
-- scope-bracket usage. This pair exists so callers that need separate
-- open/close primitives (e.g., supervised host stacks) can drive the
-- lifecycle imperatively without promoting the bracket via a worker
-- thread. The open path acquires the owner under 'mask_' so an async
-- exception cannot leak an acquired owner before the host handle
-- becomes visible to the caller.
openSessionFanInHost
  :: TemplateGraph
  -> SessionFanInOptions
  -> IO (Either SessionFanInSetupIssue SessionFanInHost)
openSessionFanInHost =
  openSessionFanInHostHooks defaultSessionFanInHostHooks

-- | Open a fan-in host with explicit hooks. See 'openSessionFanInHost'.
openSessionFanInHostHooks
  :: SessionFanInHostHooks
  -> TemplateGraph
  -> SessionFanInOptions
  -> IO (Either SessionFanInSetupIssue SessionFanInHost)
openSessionFanInHostHooks hooks graph opts =
  case newSessionCommandQueue (sfioQueueOptions opts) of
    Left issue ->
      pure (Left (SfisiQueue issue))
    Right queue ->
      mask_ $ do
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
              , sfihsAudioRunning =
                  False
              , sfihsLastState =
                  initialSessionState graph
              , sfihsLastStatus =
                  SessionOwnerReady
              }
            pure $ Right SessionFanInHost
              { sfihState =
                  stateVar
              , sfihHooks =
                  hooks
              }

-- | Close a fan-in host opened by 'openSessionFanInHost' /
-- 'openSessionFanInHostHooks'.
--
-- Releases the current owner generation if present. Runs under
-- 'mask_' so the read-then-release window cannot be interrupted by an
-- async exception. Safe to call more than once.
closeSessionFanInHost :: SessionFanInHost -> IO ()
closeSessionFanInHost host =
  mask_ (releaseSessionFanInHostOwners host)

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
          , sfisAudioRunning =
              sfihsAudioRunning hostState'
          }
      )

-- | Start audio on the fan-in host's current owner.
--
-- Validates that an owner is installed, reload is not in progress, and
-- audio is not already running. The fan-in state transitions to
-- audio-running under the admission lock /before/ any FFI call runs,
-- so a concurrent 'reloadSessionFanInHostOwnerStoppedAudio' cannot
-- admit during the FFI window. On failure after admission the helper
-- attempts to stop audio: if cleanup 'stopAudio' returns successfully
-- the audio flag is reverted to False; if cleanup 'stopAudio' fails
-- (throws or is interrupted), the flag stays True and the exception
-- propagates, so a later reload fails closed with
-- 'SfriAudioStillRunning' rather than disposing the owner while the
-- C++ stream might still be live.
--
-- Bundles a wait-for-callback-ready step; returns 'SfaiReadyTimeout' if
-- the configured timeout elapses, after issuing 'stopAudio' to avoid
-- leaving PortAudio in an indeterminate state.
startSessionFanInHostAudio
  :: SessionFanInHost
  -> SessionFanInAudioOptions
  -> IO (Either SessionFanInAudioIssue ())
startSessionFanInHostAudio =
  startSessionFanInHostAudioWith defaultSessionFanInAudioFFI

-- | 'startSessionFanInHostAudio' with injected FFI; intended for tests.
startSessionFanInHostAudioWith
  :: SessionFanInAudioFFI
  -> SessionFanInHost
  -> SessionFanInAudioOptions
  -> IO (Either SessionFanInAudioIssue ())
startSessionFanInHostAudioWith ffi host opts = mask $ \restore -> do
  admitted <- modifyMVar (sfihState host) $ \hostState ->
    case (sfihsReloadStatus hostState, sfihsOwner hostState, sfihsAudioRunning hostState) of
      (SessionFanInReloadInProgress, _, _) ->
        pure (hostState, Left SfaiReloadInProgress)
      (SessionFanInReloadFailed, _, _) ->
        pure (hostState, Left SfaiNoOwner)
      (SessionFanInNormalOperation, Nothing, _) ->
        pure (hostState, Left SfaiNoOwner)
      (SessionFanInNormalOperation, Just _, True) ->
        pure (hostState, Left SfaiAudioAlreadyRunning)
      (SessionFanInNormalOperation, Just owner, False) ->
        pure
          ( hostState { sfihsAudioRunning = True }
          , Right owner
          )
  case admitted of
    Left issue ->
      pure (Left issue)
    Right ownerHandle -> do
      let rt          = sessionOwnerHandleRTGraph ownerHandle
          markStopped = setSessionFanInAudioRunning host False
          -- Cleanup is fail-closed: only flip the host to audio-stopped
          -- after stopAudio has returned successfully. If the cleanup
          -- stopAudio throws or is interrupted, the audio-running flag
          -- stays True so a later reload rejects with
          -- SfriAudioStillRunning rather than disposing the owner while
          -- the C++ stream might still be live.
          stopAndMark = saffiStopAudio ffi rt >> markStopped
      rc <- restore (saffiStartAudio ffi rt
                       (sfiaoOutputChannels opts)
                       (sfiaoDeviceID opts))
              `onException` stopAndMark
      if rc /= 0
        then do
          markStopped
          pure (Left (SfaiStartFailed rc))
        else do
          ready <- restore
                     (saffiWaitAudioStarted ffi rt
                        (sfiaoReadyTimeoutMs opts))
                     `onException` stopAndMark
          if ready
            then pure (Right ())
            else do
              stopAndMark
              pure (Left SfaiReadyTimeout)

-- | Stop audio on the fan-in host's current owner.
--
-- Validates that an owner is installed, reload is not in progress, and
-- audio is currently running. The audio-running flag is cleared only
-- /after/ 'stopAudio' returns successfully. If 'stopAudio' is
-- interrupted, the flag stays True and the caller can retry — fail
-- closed against a stale "stopped" state that would let reload dispose
-- the owner while the C++ callback might still be live.
stopSessionFanInHostAudio
  :: SessionFanInHost
  -> IO (Either SessionFanInAudioIssue ())
stopSessionFanInHostAudio =
  stopSessionFanInHostAudioWith defaultSessionFanInAudioFFI

-- | 'stopSessionFanInHostAudio' with injected FFI; intended for tests.
stopSessionFanInHostAudioWith
  :: SessionFanInAudioFFI
  -> SessionFanInHost
  -> IO (Either SessionFanInAudioIssue ())
stopSessionFanInHostAudioWith ffi host = mask $ \restore -> do
  admitted <- modifyMVar (sfihState host) $ \hostState ->
    case (sfihsReloadStatus hostState, sfihsOwner hostState, sfihsAudioRunning hostState) of
      (SessionFanInReloadInProgress, _, _) ->
        pure (hostState, Left SfaiReloadInProgress)
      (SessionFanInReloadFailed, _, _) ->
        pure (hostState, Left SfaiNoOwner)
      (SessionFanInNormalOperation, Nothing, _) ->
        pure (hostState, Left SfaiNoOwner)
      (SessionFanInNormalOperation, Just _, False) ->
        pure (hostState, Left SfaiAudioAlreadyStopped)
      (SessionFanInNormalOperation, Just owner, True) ->
        pure (hostState, Right owner)
  case admitted of
    Left issue ->
      pure (Left issue)
    Right ownerHandle -> do
      let rt = sessionOwnerHandleRTGraph ownerHandle
      restore (saffiStopAudio ffi rt)
      setSessionFanInAudioRunning host False
      pure (Right ())

-- | Phase 8f: graceful-stop counterpart to
-- 'stopSessionFanInHostAudioWith'. Identical admission and fail-closed
-- semantics — only the FFI entry differs: this helper calls
-- 'saffiStopAudioFade' with @fadeMs@ so the runtime applies a brief
-- linear output ramp before closing the stream. Intended for the host-
-- stack close path; in-window reload stop continues to use
-- 'stopSessionFanInHostAudioWith'.
stopSessionFanInHostAudioFadeWith
  :: SessionFanInAudioFFI
  -> Int
  -> SessionFanInHost
  -> IO (Either SessionFanInAudioIssue ())
stopSessionFanInHostAudioFadeWith ffi fadeMs host = mask $ \restore -> do
  admitted <- modifyMVar (sfihState host) $ \hostState ->
    case (sfihsReloadStatus hostState, sfihsOwner hostState, sfihsAudioRunning hostState) of
      (SessionFanInReloadInProgress, _, _) ->
        pure (hostState, Left SfaiReloadInProgress)
      (SessionFanInReloadFailed, _, _) ->
        pure (hostState, Left SfaiNoOwner)
      (SessionFanInNormalOperation, Nothing, _) ->
        pure (hostState, Left SfaiNoOwner)
      (SessionFanInNormalOperation, Just _, False) ->
        pure (hostState, Left SfaiAudioAlreadyStopped)
      (SessionFanInNormalOperation, Just owner, True) ->
        pure (hostState, Right owner)
  case admitted of
    Left issue ->
      pure (Left issue)
    Right ownerHandle -> do
      let rt = sessionOwnerHandleRTGraph ownerHandle
      restore (saffiStopAudioFade ffi rt fadeMs)
      setSessionFanInAudioRunning host False
      pure (Right ())

setSessionFanInAudioRunning :: SessionFanInHost -> Bool -> IO ()
setSessionFanInAudioRunning host running =
  modifyMVar (sfihState host) $ \hostState ->
    pure (hostState { sfihsAudioRunning = running }, ())

-- | Replace the current owner after the host has stopped audio,
-- quiesced producers, and drained the queue.
--
-- The helper enforces only the preconditions it can observe: audio
-- must be stopped, the queue must be empty, and the host must be in
-- normal operation. It does not call start/stop audio, drain accepted
-- commands, or reset producer/listener state.
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
            | sfihsAudioRunning hostState ->
                pure (hostState, Left SfriAudioStillRunning)
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
