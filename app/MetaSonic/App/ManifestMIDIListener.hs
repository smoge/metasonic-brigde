{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : MetaSonic.App.ManifestMIDIListener
-- Description : Manifest-target-aware MIDI listener for the device-backed
--               manifest MIDI path.
--
-- This module is the MIDI analogue of 'MetaSonic.App.ManifestOSCListener'.
-- It owns a small worker over an injected decoded-event source
-- ('MetaSonic.Session.MIDIListener.MIDIListenerSource') and routes each
-- 'MIDIProducerControlChange' event through 'submitManifestMIDICCEvent'
-- so that CCs bound by the current manifest produce a
-- producer-default-voice 'CmdControlWrite' while CCs absent from the
-- manifest reject at the projection layer.
--
-- It deliberately does not wrap 'MetaSonic.Session.MIDIListener'. The
-- session listener's semantics (active notes, sustain, coalescing,
-- pitch-bend, producer-local note/CC translation) belong to the rich
-- session MIDI path, not the v1 manifest path that
-- 'submitManifestMIDICCEvent' encodes. Non-CC events are reported via
-- the 'MmliIgnoredEvent' hook for diagnostics so a host can later route
-- them elsewhere; this module never installs note state.
--
-- The decoded-event source is the same 'MIDIListenerSource' the session
-- listener consumes, so callers can feed this listener with
-- 'MetaSonic.Session.MIDIPortMIDI.portMIDIListenerSource' (real device)
-- or with a test-time mock; the listener core stays runnable without
-- PortMIDI hardware.

module MetaSonic.App.ManifestMIDIListener
  ( -- * Hooks and issues
    ManifestMIDIListenerHooks (..)
  , defaultManifestMIDIListenerHooks
  , ManifestMIDIListenerIssue (..)

    -- * Bracketed listener
  , withManifestMIDIListener

    -- * Handle-style listener
  , ManifestMIDIListenerHandle
  , openManifestMIDIListener
  , closeManifestMIDIListener
  ) where

import           Control.Concurrent               (ThreadId,
                                                   forkIOWithUnmask,
                                                   killThread)
import           Control.Concurrent.MVar          (MVar, newEmptyMVar,
                                                   putMVar, readMVar)
import           Control.Exception                (SomeException, bracket,
                                                   mask_, try)

import           MetaSonic.App.ManifestReloadMIDIBinding
                                                  (ManifestMIDIIngressTarget)
import           MetaSonic.App.ManifestReloadMIDIIngress
                                                  (ManifestMIDICCInput (..),
                                                   ManifestMIDIIngressIssue,
                                                   ManifestMIDIIngressResult (..),
                                                   submitManifestMIDICCEvent)
import           MetaSonic.Session.Command        (SessionCommand)
import           MetaSonic.Session.FanIn          (SessionFanInEnqueueResult (..),
                                                   SessionFanInHost)
import           MetaSonic.Session.MIDIListener   (MIDIListenerSource (..))
import           MetaSonic.Session.MIDIProducer   (MIDIProducerEvent (..),
                                                   MIDIProducerOptions)
import           MetaSonic.Session.Queue          (SessionEnqueueIssue,
                                                   SessionEnqueueResult (..))


-- | Manifest-target-aware listener rejection.
--
-- 'MmliIngressIssue' wraps a projection-side rejection (channel/data
-- byte invalid, channel filtered, CC unbound). 'MmliEnqueueRejected'
-- covers the fan-in queue refusing a manifest-validated command,
-- typically queue-full. 'MmliIgnoredEvent' covers non-CC events the
-- v1 manifest path does not route (note-on/off, pitch-bend,
-- all-notes-off); they are reported for diagnostics and otherwise
-- dropped. Sustain is normally MIDI CC 64; a manifest that binds CC
-- 64 enqueues a control write like any other manifest-bound CC,
-- rather than triggering 'MmliIgnoredEvent'.
data ManifestMIDIListenerIssue
  = MmliIngressIssue !ManifestMIDIIngressIssue
  | MmliEnqueueRejected !SessionCommand !SessionEnqueueIssue
  | MmliIgnoredEvent !MIDIProducerEvent
  deriving (Eq, Show)

-- | Diagnostic hooks for one listener.
--
-- 'mmlhOnAccepted' fires for every CC event that survived projection
-- validation, regardless of whether the fan-in accepted the resulting
-- command. Tests use it for synchronization; production callers can
-- discard it. 'mmlhOnIssue' captures all three rejection shapes.
data ManifestMIDIListenerHooks = ManifestMIDIListenerHooks
  { mmlhOnAccepted :: !(SessionFanInEnqueueResult -> IO ())
  , mmlhOnIssue    :: !(ManifestMIDIListenerIssue -> IO ())
  }

defaultManifestMIDIListenerHooks :: ManifestMIDIListenerHooks
defaultManifestMIDIListenerHooks = ManifestMIDIListenerHooks
  { mmlhOnAccepted =
      \_ -> pure ()
  , mmlhOnIssue =
      \_ -> pure ()
  }

processManifestMIDIEvent
  :: ManifestMIDIListenerHooks
  -> MIDIProducerOptions
  -> ManifestMIDIIngressTarget
  -> SessionFanInHost
  -> MIDIProducerEvent
  -> IO ()
processManifestMIDIEvent hooks opts target host event =
  case event of
    MIDIProducerControlChange ch cc value -> do
      result <-
        submitManifestMIDICCEvent
          opts
          target
          ManifestMIDICCInput
            { mmciChannel =
                ch
            , mmciCC =
                cc
            , mmciValue =
                value
            }
          host
      case mmirOutcome result of
        Left issue ->
          mmlhOnIssue hooks (MmliIngressIssue issue)
        Right enqueueResult -> do
          mmlhOnAccepted hooks enqueueResult
          case sfierResult enqueueResult of
            SessionEnqueued _ ->
              pure ()
            SessionEnqueueRejected _producer cmd issue ->
              mmlhOnIssue hooks (MmliEnqueueRejected cmd issue)
    _ ->
      mmlhOnIssue hooks (MmliIgnoredEvent event)

-- | Worker loop. Reads events from the source until the source returns
-- 'Nothing' (end-of-input) or an async exception (close request)
-- interrupts the blocking read.
runManifestMIDILoop
  :: ManifestMIDIListenerHooks
  -> MIDIProducerOptions
  -> ManifestMIDIIngressTarget
  -> SessionFanInHost
  -> MIDIListenerSource
  -> IO ()
runManifestMIDILoop hooks opts target host source = loop
  where
    loop = do
      mEvent <- mlsReadEvent source
      case mEvent of
        Nothing ->
          pure ()
        Just event -> do
          processManifestMIDIEvent hooks opts target host event
          loop

-- | Bracketed listener: fork a worker over the decoded-event source,
-- run the body, then stop the worker and wait for it to finish.
--
-- Source ownership is the caller's; this bracket only owns the worker
-- thread. End-of-input from the source causes the worker to exit
-- naturally; an exception in the body raises 'killThread' on the
-- worker through 'closeManifestMIDIListener'.
withManifestMIDIListener
  :: ManifestMIDIListenerHooks
  -> MIDIProducerOptions
  -> ManifestMIDIIngressTarget
  -> SessionFanInHost
  -> MIDIListenerSource
  -> IO a
  -> IO a
withManifestMIDIListener hooks opts target host source body =
  bracket
    (openManifestMIDIListener hooks opts target host source)
    closeManifestMIDIListener
    (const body)

-- | A live listener owning one worker thread over a decoded-event
-- source.
--
-- Construct via 'openManifestMIDIListener'; release via
-- 'closeManifestMIDIListener'. The handle does not own the source —
-- callers retain that, including closing any backing device. The
-- worker thread is killed at close time so the underlying source
-- read is interrupted; sources that hold device handles should
-- tolerate this (PortMIDI's polling source does).
data ManifestMIDIListenerHandle = ManifestMIDIListenerHandle
  { mmlhWorker :: !ThreadId
  , mmlhDone   :: !(MVar ())
  }

-- | Open a manifest-target-aware MIDI listener and return a handle.
--
-- Async-exception safe: the open runs under 'mask_' and the worker is
-- forked unmasked via 'forkIOWithUnmask' so its 'mlsReadEvent' call
-- remains interruptible. If the worker raises a synchronous exception
-- (e.g. a source IO failure) it is consumed, the worker exits, and
-- 'mmlhDone' is signalled; per the
-- 'MetaSonic.Session.MIDIListener.MIDIListenerSource' contract,
-- well-behaved sources never throw.
openManifestMIDIListener
  :: ManifestMIDIListenerHooks
  -> MIDIProducerOptions
  -> ManifestMIDIIngressTarget
  -> SessionFanInHost
  -> MIDIListenerSource
  -> IO ManifestMIDIListenerHandle
openManifestMIDIListener hooks opts target host source = mask_ $ do
  doneMV <- newEmptyMVar
  tid <- forkIOWithUnmask $ \unmaskWorker -> do
    _ <-
      try
        (unmaskWorker
          (runManifestMIDILoop hooks opts target host source))
        :: IO (Either SomeException ())
    putMVar doneMV ()
  pure ManifestMIDIListenerHandle
    { mmlhWorker =
        tid
    , mmlhDone =
        doneMV
    }

-- | Stop the worker thread and wait for cleanup.
--
-- Idempotent: 'killThread' on an already-finished worker is a no-op
-- per the GHC docs; 'readMVar' is non-destructive so a second call
-- after 'mmlhDone' is set returns immediately.
closeManifestMIDIListener :: ManifestMIDIListenerHandle -> IO ()
closeManifestMIDIListener handle = do
  killThread (mmlhWorker handle)
  _ <- readMVar (mmlhDone handle)
  pure ()
