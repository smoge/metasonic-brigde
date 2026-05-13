{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.OSCListener
-- Description : Session-backed OSC UDP listener.
--
-- This module is the session-facing OSC listener. It owns a bracketed
-- UDP socket and listener thread, parses OSC packets, and enqueues
-- decoded control writes into a 'SessionFanInHost' through
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

    -- * Bracketed listener
  , withSessionOSCListener
  , withSessionOSCListenerHooks
  ) where

import           Control.DeepSeq                 (NFData)
import           GHC.Generics                    (Generic)

import           MetaSonic.OSC.Dispatch.Internal (DispatchIssue)
import           MetaSonic.OSC.Listen            (ListenerConfig (..),
                                                  ListenerInfo (..),
                                                  defaultListenerConfig,
                                                  withListenerLoop)
import           MetaSonic.OSC.Wire              (parseMessage)
import           MetaSonic.Session.Command       (SessionCommand)
import           MetaSonic.Session.FanIn         (SessionFanInEnqueueResult (..),
                                                  SessionFanInHost)
import           MetaSonic.Session.OSCProducer   (OSCProducerEnqueueResult (..),
                                                  OSCProducerOptions,
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
              reportEnqueueIssue cmd enqueueResult

    reportEnqueueIssue cmd enqueueResult =
      case sfierResult enqueueResult of
        SessionEnqueued _ ->
          pure ()
        SessionEnqueueRejected _ _ issue ->
          solhOnIssue hooks (SoliEnqueueRejected cmd issue)
