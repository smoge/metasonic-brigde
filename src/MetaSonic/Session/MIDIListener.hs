{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.MIDIListener
-- Description : Session-backed decoded MIDI listener.
--
-- This module is the session-facing MIDI listener substrate. It owns a
-- bracketed worker thread over an injected decoded-event source, keeps
-- producer-local MIDI note state, and enqueues commands into a
-- 'SessionFanInHost' through 'MetaSonic.Session.MIDIProducer'.
--
-- It deliberately does not open PortMIDI devices, choose a live clock,
-- define channel remapping/splits, arbitrate against OSC beyond the
-- existing FIFO fan-in queue, or repair a diverged owner. Real device
-- ownership should be added later as a source behind this decoded-event
-- boundary.

module MetaSonic.Session.MIDIListener
  ( -- * Decoded event source
    MIDIListenerSource (..)

    -- * Listener handle
  , SessionMIDIListener
  , readSessionMIDIListenerState

    -- * Listener-side issues
  , SessionMIDIListenerIssue (..)

    -- * Hooks
  , SessionMIDIListenerHooks (..)
  , defaultSessionMIDIListenerHooks

    -- * Bracketed listener
  , withSessionMIDIListener
  , withSessionMIDIListenerHooks
  ) where

import           Control.Concurrent             (forkIO, killThread)
import           Control.DeepSeq                (NFData)
import           Control.Exception              (bracket)
import           Control.Monad                  (forM_)
import           Data.IORef                     (IORef, newIORef, readIORef,
                                                 writeIORef)
import           GHC.Generics                   (Generic)

import           MetaSonic.Session.Command      (SessionCommand)
import           MetaSonic.Session.FanIn        (SessionFanInEnqueueResult (..),
                                                 SessionFanInHost)
import           MetaSonic.Session.MIDIProducer (MIDIProducerCommandBatch (..),
                                                 MIDIProducerEnqueueResult (..),
                                                 MIDIProducerEvent,
                                                 MIDIProducerIssue,
                                                 MIDIProducerOptions,
                                                 MIDIProducerState,
                                                 enqueueMIDIProducerEvent)
import           MetaSonic.Session.Queue        (SessionEnqueueIssue,
                                                 SessionEnqueueResult (..))


-- | A source of already-decoded MIDI producer events.
--
-- Returning 'Nothing' means the source reached end-of-input and the
-- listener worker should exit normally. A blocking source is interrupted
-- by the bracket finalizer via 'killThread'. Source implementations
-- should not throw synchronous exceptions for ordinary device/read
-- failures; if 'mlsReadEvent' does throw, the worker terminates without
-- listener-hook notification and the last readable state remains as
-- post-mortem diagnostic state.
newtype MIDIListenerSource = MIDIListenerSource
  { mlsReadEvent :: IO (Maybe MIDIProducerEvent)
  }

-- | Opaque handle for a running session MIDI listener.
newtype SessionMIDIListener = SessionMIDIListener
  { smlStateRef :: IORef MIDIProducerState
  }

-- | Read the listener-owned MIDI producer state.
readSessionMIDIListenerState
  :: SessionMIDIListener
  -> IO MIDIProducerState
readSessionMIDIListenerState =
  readIORef . smlStateRef

-- | Everything this listener can report without killing the listener
-- thread.
data SessionMIDIListenerIssue
  = SmliProducerRejected !MIDIProducerIssue
    -- ^ The decoded event was refused by the MIDI producer adapter.
  | SmliEnqueueRejected !SessionCommand !SessionEnqueueIssue
    -- ^ The decoded event produced a command, but the fan-in queue
    -- rejected it. In v1 this is expected to be queue-full.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Session-backed MIDI listener hooks. Production callers can discard
-- both hooks; tests use them for synchronization and issue capture.
data SessionMIDIListenerHooks = SessionMIDIListenerHooks
  { smlhOnProducerResult :: !(MIDIProducerEnqueueResult -> IO ())
    -- ^ Called after every source event has gone through the MIDI
    -- producer adapter.
  , smlhOnIssue          :: !(SessionMIDIListenerIssue -> IO ())
    -- ^ Called for MIDI producer rejections and fan-in enqueue
    -- rejections.
  }

-- | Default hooks: discard diagnostics and producer results.
defaultSessionMIDIListenerHooks :: SessionMIDIListenerHooks
defaultSessionMIDIListenerHooks = SessionMIDIListenerHooks
  { smlhOnProducerResult = \_ -> pure ()
  , smlhOnIssue          = \_ -> pure ()
  }

-- | Run a worker over a decoded MIDI source for the body lifetime.
--
-- The listener only enqueues into the supplied fan-in host; it never
-- drains it. Producer-local note state starts from the supplied initial
-- state and advances only according to 'enqueueMIDIProducerEvent'.
-- Producer options, including channel filtering, are captured for the
-- worker lifetime; use a new listener bracket for a new policy.
withSessionMIDIListener
  :: MIDIProducerOptions
  -> MIDIProducerState
  -> MIDIListenerSource
  -> SessionFanInHost
  -> (SessionMIDIListener -> IO a)
  -> IO a
withSessionMIDIListener =
  withSessionMIDIListenerHooks defaultSessionMIDIListenerHooks

-- | Same shape as 'withSessionMIDIListener' but with explicit hooks.
withSessionMIDIListenerHooks
  :: SessionMIDIListenerHooks
  -> MIDIProducerOptions
  -> MIDIProducerState
  -> MIDIListenerSource
  -> SessionFanInHost
  -> (SessionMIDIListener -> IO a)
  -> IO a
withSessionMIDIListenerHooks hooks producerOpts initialState source host body = do
  stateRef <- newIORef initialState
  let listener = SessionMIDIListener
        { smlStateRef = stateRef
        }
  bracket
    (forkIO (midiListenerLoop hooks producerOpts source host stateRef))
    killThread
    (\_ -> body listener)

midiListenerLoop
  :: SessionMIDIListenerHooks
  -> MIDIProducerOptions
  -> MIDIListenerSource
  -> SessionFanInHost
  -> IORef MIDIProducerState
  -> IO ()
midiListenerLoop hooks producerOpts source host stateRef =
  loop
  where
    loop = do
      mEvent <- mlsReadEvent source
      case mEvent of
        Nothing ->
          pure ()
        Just event -> do
          st <- readIORef stateRef
          result <- enqueueMIDIProducerEvent producerOpts st event host
          let st' = resultState result
          writeIORef stateRef st'
          smlhOnProducerResult hooks result
          reportIssues result
          loop

    resultState result = case result of
      MIDIProducerRejected _ st ->
        st
      MIDIProducerEnqueueAttempted batch _ ->
        mpcbState batch

    reportIssues result = case result of
      MIDIProducerRejected issue _ ->
        smlhOnIssue hooks (SmliProducerRejected issue)
      MIDIProducerEnqueueAttempted batch enqueueResults ->
        forM_ (zip (mpcbCommands batch) enqueueResults) $
          \(cmd, enqueueResult) ->
            case sfierResult enqueueResult of
              SessionEnqueued _ ->
                pure ()
              SessionEnqueueRejected _ _ issue ->
                smlhOnIssue hooks (SmliEnqueueRejected cmd issue)
