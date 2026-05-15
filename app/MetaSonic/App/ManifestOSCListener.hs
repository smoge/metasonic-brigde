{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : MetaSonic.App.ManifestOSCListener
-- Description : Manifest-target-aware OSC UDP listener.
--
-- This module composes the existing UDP listener substrate
-- ('MetaSonic.OSC.Listen.withListenerLoop') with the manifest-aware
-- packet validator ('MetaSonic.App.ManifestReloadOSCIngress'). Each
-- received datagram is parsed as an 'OscMessage', validated against the
-- supplied 'ManifestOSCIngressTarget' before forwarding through the
-- OSC producer, and either accepted, rejected at the manifest
-- projection, or dropped by the fan-in queue. Packets that target
-- controls absent from the current manifest never reach
-- 'MetaSonic.Session.OSCProducer'.
--
-- Two surfaces are provided. 'withManifestOSCListener' is the
-- bracketed wrapper, useful for one-shot tests or short-lived smoke
-- runs. 'openManifestOSCListener' / 'closeManifestOSCListener' form a
-- handle-style API used by 'MetaSonic.App.ManifestReloadIngress' when a
-- preserving reload must close the old ingress and open a fresh one
-- against the new target without reusing the same bracket frame.

module MetaSonic.App.ManifestOSCListener
  ( -- * Configuration (re-exported from "MetaSonic.OSC.Listen")
    ListenerConfig (..)
  , defaultListenerConfig
  , ListenerInfo (..)

    -- * Hooks and issues
  , ManifestOSCListenerHooks (..)
  , defaultManifestOSCListenerHooks
  , ManifestOSCListenerIssue (..)

    -- * Bracketed listener
  , withManifestOSCListener

    -- * Handle-style listener
  , ManifestOSCListenerHandle
  , ManifestOSCListenerOpenIssue (..)
  , openManifestOSCListener
  , closeManifestOSCListener
  ) where

import           Control.Concurrent               (ThreadId,
                                                   forkIOWithUnmask,
                                                   killThread)
import           Control.Concurrent.MVar          (MVar, newEmptyMVar,
                                                   putMVar, readMVar,
                                                   takeMVar, tryPutMVar)
import           Control.Exception                (SomeException, mask,
                                                   onException, try)
import           Data.ByteString                  (ByteString)

import           MetaSonic.App.ManifestReloadOSCBinding
                                                  (ManifestOSCIngressTarget)
import           MetaSonic.App.ManifestReloadOSCIngress
                                                  (ManifestOSCIngressIssue,
                                                   ManifestOSCIngressResult (..),
                                                   submitManifestOSCMessage)
import           MetaSonic.OSC.Listen             (ListenerConfig (..),
                                                   ListenerInfo (..),
                                                   defaultListenerConfig,
                                                   withListenerLoop)
import           MetaSonic.OSC.Wire               (parseMessage)
import           MetaSonic.Session.Command        (SessionCommand)
import           MetaSonic.Session.FanIn          (SessionFanInEnqueueResult (..),
                                                   SessionFanInHost)
import           MetaSonic.Session.OSCProducer    (OSCProducerEnqueueResult (..),
                                                   OSCProducerOptions)
import           MetaSonic.Session.Queue          (SessionEnqueueIssue,
                                                   SessionEnqueueResult (..))


-- | Manifest-target-aware listener rejection.
--
-- 'MoliParseFailure' covers a raw OSC parser rejection on the wire
-- bytes; 'MoliManifestIssue' covers the manifest-side rejection
-- (symbolic decode failure or projection rejection on the
-- 'ControlTag'); 'MoliEnqueueRejected' covers the fan-in queue
-- refusing the manifest-validated command, typically queue-full.
data ManifestOSCListenerIssue
  = MoliParseFailure !String
  | MoliManifestIssue !ManifestOSCIngressIssue
  | MoliEnqueueRejected !SessionCommand !SessionEnqueueIssue
  deriving (Eq, Show)

-- | Diagnostic hooks for one listener.
--
-- 'molhOnAccepted' fires for every packet that survived parser and
-- manifest validation, regardless of whether the fan-in accepted the
-- resulting command. Tests use it for synchronization;
-- 'molhOnIssue' captures rejection reasons. Production callers can
-- discard both.
data ManifestOSCListenerHooks = ManifestOSCListenerHooks
  { molhOnAccepted :: !(OSCProducerEnqueueResult -> IO ())
  , molhOnIssue    :: !(ManifestOSCListenerIssue -> IO ())
  }

-- | Discard accepted-packet observations and listener issues.
defaultManifestOSCListenerHooks :: ManifestOSCListenerHooks
defaultManifestOSCListenerHooks = ManifestOSCListenerHooks
  { molhOnAccepted =
      \_ -> pure ()
  , molhOnIssue =
      \_ -> pure ()
  }

-- | Bracketed listener: bind a UDP socket, run the packet loop
-- against the supplied target and fan-in host, run the body, then
-- tear the listener down.
--
-- The body sees the bound 'ListenerInfo' so a test can learn the
-- OS-assigned port when 'lcPort = 0'.
withManifestOSCListener
  :: ManifestOSCListenerHooks
  -> OSCProducerOptions
  -> ManifestOSCIngressTarget
  -> SessionFanInHost
  -> ListenerConfig
  -> (ListenerInfo -> IO a)
  -> IO a
withManifestOSCListener hooks opts target host cfg body =
  withListenerLoop
    cfg
    (processManifestOSCPacket hooks opts target host)
    body

processManifestOSCPacket
  :: ManifestOSCListenerHooks
  -> OSCProducerOptions
  -> ManifestOSCIngressTarget
  -> SessionFanInHost
  -> ByteString
  -> IO ()
processManifestOSCPacket hooks opts target host bytes =
  case parseMessage bytes of
    Left err ->
      molhOnIssue hooks (MoliParseFailure err)
    Right msg -> do
      result <- submitManifestOSCMessage opts target msg host
      case moirOutcome result of
        Left issue ->
          molhOnIssue hooks (MoliManifestIssue issue)
        Right producerResult -> do
          molhOnAccepted hooks producerResult
          reportProducerEnqueue (molhOnIssue hooks) producerResult

reportProducerEnqueue
  :: (ManifestOSCListenerIssue -> IO ())
  -> OSCProducerEnqueueResult
  -> IO ()
reportProducerEnqueue onIssue producerResult =
  case producerResult of
    OSCProducerDecodeRejected _ ->
      pure ()
    OSCProducerEnqueueAttempted cmd enqueueResult ->
      case sfierResult enqueueResult of
        SessionEnqueued _ ->
          pure ()
        SessionEnqueueRejected _ _ issue ->
          onIssue (MoliEnqueueRejected cmd issue)

-- | A live listener owning one UDP socket and one listener thread.
--
-- Construct via 'openManifestOSCListener'; release via
-- 'closeManifestOSCListener'. The internal worker holds the bracketed
-- 'withListenerLoop' frame open until close is signalled, so resource
-- cleanup goes through the same path as the bracketed wrapper.
data ManifestOSCListenerHandle = ManifestOSCListenerHandle
  { mosCloseSignal :: !(MVar ())
  , mosDoneSignal  :: !(MVar ())
  }

-- | Why opening a listener failed.
--
-- Today this only carries a string from an IO exception (socket bind
-- failure, address resolution failure, etc.) so callers can render the
-- underlying diagnostic.
newtype ManifestOSCListenerOpenIssue
  = MoloiBindFailed String
  deriving (Eq, Show)

-- | Open a manifest-target-aware listener and return a handle.
--
-- This is the handle-style entry point used by
-- 'MetaSonic.App.ManifestReloadIngress' wiring. The internal worker
-- enters 'withListenerLoop' and blocks on the close signal so the
-- bracket holds the socket open. Failure to bind is reported as
-- 'MoloiBindFailed'.
--
-- Async-exception safe: the open path runs under 'mask', and the
-- worker is forked unmasked via 'forkIOWithUnmask' so its bracket
-- body remains interruptible at 'takeMVar'. If the caller is
-- interrupted while waiting for the handle, the worker is signalled
-- closed, then killed as escalation, and the cleanup blocks on the
-- worker's 'doneMV' before re-raising — so a partially-acquired
-- socket is always released through the bracket. A small leak window
-- remains in 'openListenerSocket' between socket allocation and
-- bind; that is accepted in v1 because the alternative is waiting
-- forever on a hung bind.
openManifestOSCListener
  :: ManifestOSCListenerHooks
  -> OSCProducerOptions
  -> ManifestOSCIngressTarget
  -> SessionFanInHost
  -> ListenerConfig
  -> IO (Either ManifestOSCListenerOpenIssue
                (ManifestOSCListenerHandle, ListenerInfo))
openManifestOSCListener hooks opts target host cfg = do
  result   <- newEmptyMVar
  closeMV  <- newEmptyMVar
  doneMV   <- newEmptyMVar
  mask $ \restore -> do
    tid <- forkIOWithUnmask $ \unmaskWorker -> do
      outcome <- unmaskWorker $ try $
        withListenerLoop
          cfg
          (processManifestOSCPacket hooks opts target host)
          (\info -> do
              putMVar result (Right info)
              takeMVar closeMV)
      case outcome of
        Left (e :: SomeException) -> do
          -- Either bind failed before the body ran or the body itself
          -- died. The bracket has already torn down the socket and
          -- listener thread by the time this branch runs.
          _ <- tryPutMVar result (Left (MoloiBindFailed (show e)))
          pure ()
        Right () ->
          pure ()
      putMVar doneMV ()
    outcome <-
      restore (takeMVar result)
        `onException` shutdownWorker tid closeMV doneMV
    case outcome of
      Left issue -> do
        _ <- readMVar doneMV
        pure (Left issue)
      Right info ->
        pure (Right
          ( ManifestOSCListenerHandle
              { mosCloseSignal =
                  closeMV
              , mosDoneSignal =
                  doneMV
              }
          , info))

shutdownWorker :: ThreadId -> MVar () -> MVar () -> IO ()
shutdownWorker tid closeMV doneMV = do
  -- Polite close first: if the worker is past acquire and waiting on
  -- the close MVar, this unblocks the body and bracket cleanup runs
  -- masked, releasing the socket.
  _ <- tryPutMVar closeMV ()
  -- Escalation: if the worker has not reached the close MVar yet
  -- (still inside the bracket's acquire phase), killThread interrupts
  -- it. killThread is a no-op if the worker has already exited.
  killThread tid
  -- Wait for the worker's doneMV so we know cleanup is fully complete
  -- before re-raising the caller's exception.
  _ <- readMVar doneMV
  pure ()

-- | Signal close and wait for the worker thread's bracket cleanup to
-- finish. Idempotent: a second call is a no-op because the close
-- MVar uses 'tryPutMVar'.
closeManifestOSCListener :: ManifestOSCListenerHandle -> IO ()
closeManifestOSCListener handle = do
  _ <- tryPutMVar (mosCloseSignal handle) ()
  _ <- readMVar (mosDoneSignal handle)
  pure ()
