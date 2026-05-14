{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.OSCListener
-- Description : Session-backed OSC UDP listener.
--
-- This module is the session-facing OSC listener. It owns a bracketed
-- UDP socket and listener thread, parses OSC packets, and enqueues
-- decoded control writes into either a 'SessionFanInHost' or the
-- explicit service-owned arbitration path through
-- 'MetaSonic.Session.OSCProducer'.
--
-- It deliberately does not drain the fan-in host, own a background
-- session worker, resolve controls to runtime node indices, or write
-- directly to the realtime control queue. Callers retain those policy
-- decisions.

module MetaSonic.Session.OSCListener
  ( -- * Configuration
    ListenerConfig (..)
  , defaultListenerConfig
  , ListenerInfo (..)

    -- * Listener-side issues
  , SessionOSCListenerIssue (..)

    -- * Hooks
  , SessionOSCListenerHooks (..)
  , defaultSessionOSCListenerHooks
  , SessionOSCArbitratedListenerHooks (..)
  , defaultSessionOSCArbitratedListenerHooks

    -- * Bracketed listener
  , withSessionOSCListener
  , withSessionOSCListenerHooks
  , withArbitratedSessionOSCListener
  , withArbitratedSessionOSCListenerHooks
  ) where

import           Control.DeepSeq                 (NFData)
import           GHC.Generics                    (Generic)

import           MetaSonic.OSC.Dispatch.Internal (DispatchIssue)
import           MetaSonic.OSC.Listen            (ListenerConfig (..),
                                                  ListenerInfo (..),
                                                  defaultListenerConfig,
                                                  withListenerLoop)
import           MetaSonic.OSC.Wire              (parseMessage)
import           MetaSonic.Session.Arbitration   (ArbitrationIssue)
import           MetaSonic.Session.ArbitrationGateway
                                                 (SessionArbitrationGatewayEnqueueResult (..))
import           MetaSonic.Session.Command       (SessionCommand)
import           MetaSonic.Session.FanIn         (SessionFanInEnqueueResult (..),
                                                  SessionFanInHost)
import           MetaSonic.Session.FanInService  (SessionFanInService)
import           MetaSonic.Session.OSCProducer   (OSCProducerArbitratedEnqueueResult (..),
                                                  OSCProducerEnqueueResult (..),
                                                  OSCProducerOptions,
                                                  enqueueArbitratedOSCControlWrite,
                                                  enqueueOSCControlWrite)
import           MetaSonic.Session.Queue         (SessionEnqueueIssue,
                                                  SessionEnqueueResult (..))


-- | Everything this listener can drop a packet for without killing
-- the listener thread.
data SessionOSCListenerIssue
  = SoliParseFailure !String
    -- ^ 'parseMessage' refused the datagram.
  | SoliDecodeFailure !DispatchIssue
    -- ^ The packet parsed as OSC but did not match the symbolic
    -- OSC control-write grammar.
  | SoliEnqueueRejected !SessionCommand !SessionEnqueueIssue
    -- ^ The packet decoded to a command, but the fan-in queue
    -- rejected it. In v1 this is expected to be queue-full.
  | SoliArbitrationRejected !ArbitrationIssue
    -- ^ The packet decoded to a command, but a service-owned
    -- arbitration gateway rejected it before fan-in enqueue. This is
    -- policy denial, not queue pressure.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Session-backed listener hooks. Production callers can discard
-- both hooks; tests use them for synchronization and issue capture.
data SessionOSCListenerHooks = SessionOSCListenerHooks
  { solhOnProducerResult :: !(OSCProducerEnqueueResult -> IO ())
    -- ^ Called after every successfully parsed packet has gone
    -- through the OSC producer adapter.
  , solhOnIssue          :: !(SessionOSCListenerIssue -> IO ())
    -- ^ Called for parse failures, symbolic decode failures, and
    -- fan-in enqueue rejections.
  }

-- | Default hooks: discard diagnostics and producer results.
defaultSessionOSCListenerHooks :: SessionOSCListenerHooks
defaultSessionOSCListenerHooks = SessionOSCListenerHooks
  { solhOnProducerResult = \_ -> pure ()
  , solhOnIssue          = \_ -> pure ()
  }

-- | Session-backed listener hooks for the explicit arbitrated service
-- path. This stays separate from 'SessionOSCListenerHooks' so existing
-- host-based listener users do not need to handle arbitration-shaped
-- producer results.
data SessionOSCArbitratedListenerHooks =
  SessionOSCArbitratedListenerHooks
    { solahOnProducerResult :: !(OSCProducerArbitratedEnqueueResult -> IO ())
      -- ^ Called after every successfully parsed packet has gone
      -- through the arbitrated OSC producer adapter.
    , solahOnIssue          :: !(SessionOSCListenerIssue -> IO ())
      -- ^ Called for parse failures, symbolic decode failures,
      -- service-owned arbitration rejections, and fan-in enqueue
      -- rejections after policy acceptance.
    }

-- | Default arbitrated-listener hooks: discard diagnostics and producer
-- results.
defaultSessionOSCArbitratedListenerHooks
  :: SessionOSCArbitratedListenerHooks
defaultSessionOSCArbitratedListenerHooks =
  SessionOSCArbitratedListenerHooks
    { solahOnProducerResult = \_ -> pure ()
    , solahOnIssue          = \_ -> pure ()
    }

-- | Bind a UDP socket, run a session-backed listener thread, run the
-- body, then stop the thread and close the socket. The listener only
-- enqueues into the supplied fan-in host; it never drains it.
withSessionOSCListener
  :: OSCProducerOptions
  -> SessionFanInHost
  -> ListenerConfig
  -> (ListenerInfo -> IO a)
  -> IO a
withSessionOSCListener =
  withSessionOSCListenerHooks defaultSessionOSCListenerHooks

-- | Same shape as 'withSessionOSCListener' but with explicit hooks.
withSessionOSCListenerHooks
  :: SessionOSCListenerHooks
  -> OSCProducerOptions
  -> SessionFanInHost
  -> ListenerConfig
  -> (ListenerInfo -> IO a)
  -> IO a
withSessionOSCListenerHooks hooks producerOpts host cfg body =
  withListenerLoop cfg processPacket body
  where
    processPacket bytes =
      case parseMessage bytes of
        Left err ->
          solhOnIssue hooks (SoliParseFailure err)
        Right msg -> do
          result <- enqueueOSCControlWrite producerOpts msg host
          solhOnProducerResult hooks result
          case result of
            OSCProducerDecodeRejected issue ->
              solhOnIssue hooks (SoliDecodeFailure issue)
            OSCProducerEnqueueAttempted cmd enqueueResult ->
              reportEnqueueIssue (solhOnIssue hooks) cmd enqueueResult

-- | Bind a UDP socket and route decoded OSC control writes through a
-- 'SessionFanInService''s explicit arbitrated enqueue path.
--
-- This is opt-in. Existing host-based callers should keep using
-- 'withSessionOSCListener' unless the surrounding session deliberately
-- enables service-owned arbitration. With default service options this
-- still preserves FIFO behavior; with configured gateway options,
-- policy rejections are surfaced as 'SoliArbitrationRejected' and do
-- not wake the service drain worker.
withArbitratedSessionOSCListener
  :: OSCProducerOptions
  -> SessionFanInService
  -> ListenerConfig
  -> (ListenerInfo -> IO a)
  -> IO a
withArbitratedSessionOSCListener =
  withArbitratedSessionOSCListenerHooks
    defaultSessionOSCArbitratedListenerHooks

-- | Same shape as 'withArbitratedSessionOSCListener' but with explicit
-- hooks.
--
-- Arbitration rejections also fire the underlying service hook as
-- @SfsiiArbitrationRejected@. Subscribe to the service hook for
-- cross-producer aggregation and to this listener hook for OSC-specific
-- observability; subscribing to both observes the same rejection twice.
withArbitratedSessionOSCListenerHooks
  :: SessionOSCArbitratedListenerHooks
  -> OSCProducerOptions
  -> SessionFanInService
  -> ListenerConfig
  -> (ListenerInfo -> IO a)
  -> IO a
withArbitratedSessionOSCListenerHooks hooks producerOpts service cfg body =
  withListenerLoop cfg processPacket body
  where
    processPacket bytes =
      case parseMessage bytes of
        Left err ->
          solahOnIssue hooks (SoliParseFailure err)
        Right msg -> do
          result <- enqueueArbitratedOSCControlWrite producerOpts msg service
          solahOnProducerResult hooks result
          case result of
            OSCProducerArbitratedDecodeRejected issue ->
              solahOnIssue hooks (SoliDecodeFailure issue)
            OSCProducerArbitratedEnqueueAttempted _cmd
              (SagArbitrationRejected issue) ->
                solahOnIssue hooks (SoliArbitrationRejected issue)
            OSCProducerArbitratedEnqueueAttempted cmd
              (SagEnqueueAttempted enqueueResult) ->
                reportEnqueueIssue (solahOnIssue hooks) cmd enqueueResult

reportEnqueueIssue
  :: (SessionOSCListenerIssue -> IO ())
  -> SessionCommand
  -> SessionFanInEnqueueResult
  -> IO ()
reportEnqueueIssue onIssue cmd enqueueResult =
  case sfierResult enqueueResult of
    SessionEnqueued _ ->
      pure ()
    SessionEnqueueRejected _ _ issue ->
      onIssue (SoliEnqueueRejected cmd issue)
