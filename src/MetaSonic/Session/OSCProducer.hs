{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.OSCProducer
-- Description : OSC-to-session producer adapter.
--
-- This module is the concrete OSC producer bridge for the generic
-- session fan-in host. It translates the OSC dispatch grammar's
-- symbolic control-write shape into 'SessionCommand' values and can
-- submit them under a 'ProducerOSC' identity.
--
-- It does not own a socket, create a listener thread, drain the
-- session host, or resolve symbolic controls to runtime node indices.
-- Those concerns remain in the OSC listener, fan-in host, and session
-- owner layers.

module MetaSonic.Session.OSCProducer
  ( -- * Options
    OSCProducerOptions (..)
  , defaultOSCProducerOptions

    -- * Enqueue reporting
  , OSCProducerEnqueueResult (..)
  , OSCProducerArbitratedEnqueueResult (..)

    -- * Operations
  , oscProducerId
  , decodeOSCSessionCommand
  , enqueueOSCControlWrite
  , enqueueArbitratedOSCControlWrite
  ) where

import           Control.DeepSeq                 (NFData)
import           Data.Text                       (Text)
import qualified Data.Text                       as T
import           GHC.Generics                    (Generic)

import           MetaSonic.OSC.Dispatch.Internal (DispatchIssue,
                                                  SymbolicControlWrite (..),
                                                  decodeSymbolicControlWrite)
import           MetaSonic.OSC.Wire              (OscMessage)
import           MetaSonic.Session.ArbitrationGateway
                                                  (SessionArbitrationGatewayEnqueueResult)
import           MetaSonic.Session.Command       (SessionCommand (..))
import           MetaSonic.Session.FanIn         (SessionFanInEnqueueResult,
                                                  SessionFanInHost,
                                                  enqueueSessionFanInCommand)
import           MetaSonic.Session.FanInService  (SessionFanInService,
                                                  enqueueArbitratedSessionFanInServiceCommand)
import           MetaSonic.Session.Queue         (ProducerId (..),
                                                  ProducerKind (ProducerOSC))


-- | Construction-free options for attributing OSC producer commands.
data OSCProducerOptions = OSCProducerOptions
  { opoProducerName :: !Text
    -- ^ Free-form diagnostic producer name. The default is @"osc"@.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Conservative default identity for OSC producer ingress.
defaultOSCProducerOptions :: OSCProducerOptions
defaultOSCProducerOptions = OSCProducerOptions
  { opoProducerName = T.pack "osc"
  }

-- | Result of attempting to accept one OSC control-write message.
data OSCProducerEnqueueResult
  = OSCProducerDecodeRejected !DispatchIssue
    -- ^ The message did not match the symbolic OSC control-write
    -- grammar, so no command was submitted to the fan-in host.
  | OSCProducerEnqueueAttempted !SessionCommand !SessionFanInEnqueueResult
    -- ^ The message decoded to a command and was passed to the
    -- fan-in host. Inspect the nested enqueue result for queue-full
    -- or accepted-command details.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Result of attempting to accept one OSC control-write message through
-- the explicitly arbitrated service path.
data OSCProducerArbitratedEnqueueResult
  = OSCProducerArbitratedDecodeRejected !DispatchIssue
    -- ^ The message did not match the symbolic OSC control-write
    -- grammar, so no command was submitted to the service.
  | OSCProducerArbitratedEnqueueAttempted
      !SessionCommand
      !SessionArbitrationGatewayEnqueueResult
    -- ^ The message decoded to a command and was passed to the
    -- service-owned arbitration path. Inspect the nested result for
    -- policy rejection, queue-full, or accepted-command details.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Producer identity used for commands emitted by this adapter.
oscProducerId :: OSCProducerOptions -> ProducerId
oscProducerId opts =
  ProducerId ProducerOSC (opoProducerName opts)

-- | Decode one OSC message into the shared session-command vocabulary.
--
-- v1 accepts only symbolic control writes:
-- @/<voice>/<node-tag>/<slot>@ plus exactly one int or float argument.
decodeOSCSessionCommand
  :: OscMessage -> Either DispatchIssue SessionCommand
decodeOSCSessionCommand msg = do
  SymbolicControlWrite voiceKey controlTag value <-
    decodeSymbolicControlWrite msg
  Right (CmdControlWrite voiceKey controlTag value)

-- | Decode and submit one OSC control-write message to a fan-in host.
--
-- This function only enqueues. It deliberately does not drain the host
-- or perform runtime target resolution; callers choose those policies.
-- Callers using a 'SessionFanInService' with a configured arbitration
-- gateway should switch to 'enqueueArbitratedOSCControlWrite' for
-- consistent policy enforcement; calling this function with a
-- service-derived host bypasses the configured gateway.
enqueueOSCControlWrite
  :: OSCProducerOptions
  -> OscMessage
  -> SessionFanInHost
  -> IO OSCProducerEnqueueResult
enqueueOSCControlWrite opts msg host =
  case decodeOSCSessionCommand msg of
    Left issue ->
      pure (OSCProducerDecodeRejected issue)
    Right command -> do
      result <-
        enqueueSessionFanInCommand (oscProducerId opts) command host
      pure (OSCProducerEnqueueAttempted command result)

-- | Decode and submit one OSC control-write message to the explicit
-- service-owned arbitration path.
--
-- Existing OSC producers should keep using 'enqueueOSCControlWrite'
-- unless the surrounding session deliberately opts into
-- 'SessionFanInService' arbitration. With default service options this
-- still preserves FIFO behavior; with configured gateway options, policy
-- rejection is surfaced through the nested
-- 'SessionArbitrationGatewayEnqueueResult' and the service issue hook.
enqueueArbitratedOSCControlWrite
  :: OSCProducerOptions
  -> OscMessage
  -> SessionFanInService
  -> IO OSCProducerArbitratedEnqueueResult
enqueueArbitratedOSCControlWrite opts msg service =
  case decodeOSCSessionCommand msg of
    Left issue ->
      pure (OSCProducerArbitratedDecodeRejected issue)
    Right command -> do
      result <-
        enqueueArbitratedSessionFanInServiceCommand
          (oscProducerId opts)
          command
          service
      pure (OSCProducerArbitratedEnqueueAttempted command result)
