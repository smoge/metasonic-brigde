{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : MetaSonic.OSC.Listen
-- Description : Phase 6.B.2b — bracketed UDP listener for OSC
--               control writes.
--
-- A small library entry point that owns one UDP socket, runs one
-- listener thread, and drives the §6.B.2a pure pipeline against
-- a supplied 'RTGraph' handle and 'IORef' 'ResolveState'. No CLI,
-- no audio-thread substrate, no new realtime ABI.
--
-- Single-producer assumption: the listener is the sole writer to
-- the runtime's realtime control queue from this surface. Mixing
-- OSC with another producer (a future 6.A pattern driver) is out
-- of v1 scope (mirrors §5.3's single-producer / single-collector
-- limitation).
--
-- See the §6.B design note for scope and architecture decisions.

module MetaSonic.OSC.Listen
  ( -- * Configuration
    ListenerConfig (..)
  , defaultListenerConfig
  , ListenerInfo (..)
    -- * Listener-side issues
  , ListenerIssue (..)
    -- * Pluggable hooks (production + test)
  , SetControlFn
  , ListenerHooks (..)
  , defaultListenerHooks
    -- * Bracketed listener
  , withOscListener
  , withOscListenerHooks
  ) where

import           Control.Concurrent             (forkIO, killThread)
import           Control.DeepSeq                (NFData)
import           Control.Exception              (IOException, bracket, try)
import           Data.IORef                     (IORef, readIORef)
import           Foreign.C.Types                (CDouble (..))
import           Foreign.Ptr                    (Ptr)
import           GHC.Generics                   (Generic)
import qualified Network.Socket                 as N
import qualified Network.Socket.ByteString      as NSB

import           MetaSonic.Bridge.FFI           (RTGraph,
                                                  c_rt_graph_realtime_set_control)
import           MetaSonic.OSC.Dispatch         (DispatchAction (..),
                                                  DispatchIssue, ResolveState,
                                                  dispatch)
import           MetaSonic.OSC.Wire             (parseMessage)
import           MetaSonic.Types                (NodeIndex (..))

----------------------------------------------------------------------
-- Configuration
----------------------------------------------------------------------

-- | UDP socket configuration. 'lcPort' = 0 asks the OS to pick a
-- free port (and the actual bound port is reported via
-- 'ListenerInfo'), which is what tests use to avoid hardcoding.
data ListenerConfig = ListenerConfig
  { lcBindHost    :: !String
    -- ^ Bind address. Defaults to @"127.0.0.1"@ — loopback only.
  , lcPort        :: !Int
    -- ^ UDP port. @0@ asks the OS to allocate one.
  , lcMaxDatagram :: !Int
    -- ^ Maximum bytes per recv. OSC messages are small in practice;
    -- 4096 is more than enough for any v1-shaped packet.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

defaultListenerConfig :: Int -> ListenerConfig
defaultListenerConfig port = ListenerConfig
  { lcBindHost    = "127.0.0.1"
  , lcPort        = port
  , lcMaxDatagram = 4096
  }

-- | Runtime information about the bound socket. Reported to the
-- body callback so tests can learn the OS-assigned port.
newtype ListenerInfo = ListenerInfo
  { liBoundPort :: Int
  } deriving stock (Eq, Show)

----------------------------------------------------------------------
-- Issue ADT
----------------------------------------------------------------------

-- | Everything a listener can drop a packet for without killing
-- itself. Surfaces via the 'lhOnIssue' hook; production callers
-- discard these, tests record them.
data ListenerIssue
  = LiParseFailure    !String
    -- ^ 'parseMessage' refused the datagram. The 'String' is the
    -- underlying diagnostic ("missing NUL", "trailing bytes",
    -- ...).
  | LiDispatchFailure !DispatchIssue
    -- ^ The message parsed but 'dispatch' refused it. The
    -- 'DispatchIssue' is the underlying reason (unknown voice,
    -- out-of-range slot, ...).
  | LiQueueFull       !Int !NodeIndex !Int
    -- ^ The realtime control queue refused the write (queue
    -- full). Fields: slot id, node index, control slot — enough
    -- for an operator to spot which write was dropped.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

----------------------------------------------------------------------
-- Hooks
----------------------------------------------------------------------

-- | The side effect a listener performs for a 'DAControlWrite'.
-- Returns 'True' if the realtime queue accepted the write, 'False'
-- on queue full. The production binding wraps
-- @rt_graph_realtime_set_control@; tests substitute a recording
-- mock.
type SetControlFn
  =  Int        -- ^ slot id
  -> NodeIndex  -- ^ node index
  -> Int        -- ^ control slot
  -> Double     -- ^ value
  -> IO Bool

-- | Listener hooks. The production set ('defaultListenerHooks')
-- writes through the realtime FFI and discards issues; tests
-- replace one or both for observation.
data ListenerHooks = ListenerHooks
  { lhSetControl :: !SetControlFn
  , lhOnIssue    :: !(ListenerIssue -> IO ())
  }

-- | Production hooks: write through the realtime FFI, discard
-- issues silently. A future operator-facing logger could replace
-- 'lhOnIssue' to send drops to a structured log.
defaultListenerHooks :: Ptr RTGraph -> ListenerHooks
defaultListenerHooks rt = ListenerHooks
  { lhSetControl = \slotId (NodeIndex nodeIx) ctrlSlot val -> do
      r <- c_rt_graph_realtime_set_control
             rt
             (fromIntegral slotId)
             (fromIntegral nodeIx)
             (fromIntegral ctrlSlot)
             (CDouble val)
      pure (r /= 0)
  , lhOnIssue    = \_ -> pure ()
  }

----------------------------------------------------------------------
-- Bracketed listener
----------------------------------------------------------------------

-- | Production entry: bind the configured UDP port, run the
-- listener thread, run the body, then tear down the listener and
-- close the socket. Bracketed so an exception in the body still
-- releases resources cleanly.
withOscListener
  :: Ptr RTGraph
  -> IORef ResolveState
  -> ListenerConfig
  -> (ListenerInfo -> IO a)
  -> IO a
withOscListener rt = withOscListenerHooks (defaultListenerHooks rt)

-- | Same shape as 'withOscListener' but takes an explicit
-- 'ListenerHooks'. Used by tests to record set-control calls and
-- listener issues without involving the FFI.
withOscListenerHooks
  :: ListenerHooks
  -> IORef ResolveState
  -> ListenerConfig
  -> (ListenerInfo -> IO a)
  -> IO a
withOscListenerHooks hooks rsRef cfg body =
  bracket (openListenerSocket cfg) closeListenerSocket $ \(sock, info) ->
    bracket
      (forkIO (listenerLoop sock hooks rsRef cfg))
      killThread
      (\_ -> body info)

openListenerSocket :: ListenerConfig -> IO (N.Socket, ListenerInfo)
openListenerSocket cfg = do
  let hints = N.defaultHints
        { N.addrSocketType = N.Datagram
        , N.addrFamily     = N.AF_INET
        , N.addrFlags      = [N.AI_PASSIVE]
        }
  addrs <- N.getAddrInfo (Just hints) (Just (lcBindHost cfg))
                         (Just (show (lcPort cfg)))
  case addrs of
    []         -> ioError (userError "OSC listener: no bind address available")
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

closeListenerSocket :: (N.Socket, ListenerInfo) -> IO ()
closeListenerSocket (sock, _) = N.close sock

-- The listener loop. Exits cleanly when 'recvFrom' raises an
-- 'IOException' (socket closed by the bracket cleanup) or when an
-- async exception ('ThreadKilled' from 'killThread') propagates.
-- The 'IOException' catch is deliberately narrow: 'ThreadKilled'
-- is an 'AsyncException', not an 'IOException', and must continue
-- to propagate so the bracket teardown works.
listenerLoop
  :: N.Socket
  -> ListenerHooks
  -> IORef ResolveState
  -> ListenerConfig
  -> IO ()
listenerLoop sock hooks rsRef cfg = loop
  where
    maxBytes = lcMaxDatagram cfg

    loop = do
      result <- try (NSB.recvFrom sock maxBytes)
      case result of
        Left (_ :: IOException) -> pure ()
        Right (bytes, _from)    -> processPacket bytes >> loop

    processPacket bytes = case parseMessage bytes of
      Left err  -> lhOnIssue hooks (LiParseFailure err)
      Right msg -> do
        rs <- readIORef rsRef
        case dispatch rs msg of
          Left issue -> lhOnIssue hooks (LiDispatchFailure issue)
          Right (DAControlWrite slotId nodeIx ctrlSlot val) -> do
            ok <- lhSetControl hooks slotId nodeIx ctrlSlot val
            if ok
              then pure ()
              else lhOnIssue hooks (LiQueueFull slotId nodeIx ctrlSlot)
