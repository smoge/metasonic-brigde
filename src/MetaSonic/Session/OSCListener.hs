{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ScopedTypeVariables #-}

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

import           Control.Concurrent              (forkIO, killThread)
import           Control.DeepSeq                 (NFData)
import           Control.Exception               (IOException, bracket, try)
import           GHC.Generics                    (Generic)
import qualified Network.Socket                  as N
import qualified Network.Socket.ByteString       as NSB

import           MetaSonic.OSC.Dispatch.Internal (DispatchIssue)
import           MetaSonic.OSC.Listen            (ListenerConfig (..),
                                                  ListenerInfo (..),
                                                  defaultListenerConfig)
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
  bracket (openSessionListenerSocket cfg) closeSessionListenerSocket $
    \(sock, info) ->
      bracket
        (forkIO (sessionListenerLoop sock hooks producerOpts host cfg))
        killThread
        (\_ -> body info)

openSessionListenerSocket :: ListenerConfig -> IO (N.Socket, ListenerInfo)
openSessionListenerSocket cfg = do
  let hints = N.defaultHints
        { N.addrSocketType = N.Datagram
        , N.addrFamily     = N.AF_INET
        , N.addrFlags      = [N.AI_PASSIVE]
        }
  addrs <- N.getAddrInfo (Just hints) (Just (lcBindHost cfg))
                         (Just (show (lcPort cfg)))
  case addrs of
    [] ->
      ioError (userError "session OSC listener: no bind address available")
    (addr : _) -> do
      sock <- N.socket (N.addrFamily addr)
                       (N.addrSocketType addr)
                       (N.addrProtocol addr)
      N.bind sock (N.addrAddress addr)
      bound <- N.getSocketName sock
      let port = case bound of
            N.SockAddrInet p _      -> fromIntegral p
            N.SockAddrInet6 p _ _ _ -> fromIntegral p
            _                       -> -1
      pure (sock, ListenerInfo { liBoundPort = port })

closeSessionListenerSocket :: (N.Socket, ListenerInfo) -> IO ()
closeSessionListenerSocket (sock, _) =
  N.close sock

sessionListenerLoop
  :: N.Socket
  -> SessionOSCListenerHooks
  -> OSCProducerOptions
  -> SessionFanInHost
  -> ListenerConfig
  -> IO ()
sessionListenerLoop sock hooks producerOpts host cfg = loop
  where
    maxBytes = lcMaxDatagram cfg

    loop = do
      result <- try (NSB.recvFrom sock maxBytes)
      case result of
        Left (_ :: IOException) ->
          pure ()
        Right (bytes, _from) ->
          processPacket bytes >> loop

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
