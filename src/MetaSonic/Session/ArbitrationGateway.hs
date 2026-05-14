{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.ArbitrationGateway
-- Description : Optional arbitration wrapper around session fan-in.
--
-- This module provides the first opt-in gateway for applying
-- 'MetaSonic.Session.Arbitration' before producer commands reach
-- 'MetaSonic.Session.FanIn'. It deliberately does not change
-- 'MetaSonic.Session.Queue' or 'MetaSonic.Session.FanIn': accepted
-- commands are still enqueued through the normal fan-in API and drain
-- in strict FIFO order.
--
-- The default gateway policy is 'FifoOnly', so callers that opt into a
-- gateway but do not configure policy keep the existing producer
-- behavior. Rejections are reported before enqueue and do not consume
-- queue capacity or command sequence numbers.

module MetaSonic.Session.ArbitrationGateway
  ( -- * Gateway
    SessionArbitrationGateway

    -- * Options
  , SessionArbitrationGatewayOptions (..)
  , defaultSessionArbitrationGatewayOptions

    -- * Enqueue reporting
  , SessionArbitrationGatewayEnqueueResult (..)

    -- * Operations
  , newSessionArbitrationGateway
  , withSessionArbitrationGateway
  , readSessionArbitrationGatewayPolicy
  , enqueueArbitratedSessionFanInCommand
  ) where

import           Control.Concurrent.MVar         (MVar, modifyMVar, newMVar,
                                                  readMVar)
import           Control.DeepSeq                 (NFData)
import           GHC.Generics                    (Generic)

import           MetaSonic.Session.Arbitration   (ArbitrationDecision (..),
                                                  ArbitrationIssue,
                                                  ArbitrationPolicy (..),
                                                  arbitrateSessionCommand,
                                                  recordAcceptedSessionCommand)
import           MetaSonic.Session.Command       (SessionCommand)
import           MetaSonic.Session.FanIn         (SessionFanInEnqueueResult (..),
                                                  SessionFanInHost,
                                                  enqueueSessionFanInCommand)
import           MetaSonic.Session.Queue         (ProducerId,
                                                  SessionEnqueueResult (..))


-- | Shared arbitration gateway state.
--
-- Concrete producers can share one gateway to make same-target policy
-- decisions against the same owner/claim state before commands reach
-- fan-in.
newtype SessionArbitrationGateway = SessionArbitrationGateway
  { sagPolicy :: MVar ArbitrationPolicy
  }

-- | Construction options for an arbitration gateway.
data SessionArbitrationGatewayOptions = SessionArbitrationGatewayOptions
  { sagoInitialPolicy :: !ArbitrationPolicy
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Default policy preserves existing producer behavior.
defaultSessionArbitrationGatewayOptions :: SessionArbitrationGatewayOptions
defaultSessionArbitrationGatewayOptions = SessionArbitrationGatewayOptions
  { sagoInitialPolicy = FifoOnly
  }

-- | Result of one arbitration-gated fan-in enqueue attempt.
data SessionArbitrationGatewayEnqueueResult
  = SagArbitrationRejected !ArbitrationIssue
    -- ^ Policy rejected the command before fan-in enqueue.
  | SagEnqueueAttempted !SessionFanInEnqueueResult
    -- ^ Policy allowed the command; inspect the nested result for
    -- queue-full or accepted-command details.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

newSessionArbitrationGateway
  :: SessionArbitrationGatewayOptions
  -> IO SessionArbitrationGateway
newSessionArbitrationGateway opts = do
  policyVar <- newMVar (sagoInitialPolicy opts)
  pure SessionArbitrationGateway
    { sagPolicy = policyVar
    }

withSessionArbitrationGateway
  :: SessionArbitrationGatewayOptions
  -> (SessionArbitrationGateway -> IO a)
  -> IO a
withSessionArbitrationGateway opts action = do
  gateway <- newSessionArbitrationGateway opts
  action gateway

readSessionArbitrationGatewayPolicy
  :: SessionArbitrationGateway
  -> IO ArbitrationPolicy
readSessionArbitrationGatewayPolicy gateway =
  readMVar (sagPolicy gateway)

-- | Arbitrate one command, then enqueue it through fan-in if allowed.
--
-- The gateway lock spans the policy decision and downstream enqueue so
-- accepted ownership updates follow the same order as admitted fan-in
-- commands. If fan-in rejects the command, policy state is left
-- unchanged.
enqueueArbitratedSessionFanInCommand
  :: SessionArbitrationGateway
  -> ProducerId
  -> SessionCommand
  -> SessionFanInHost
  -> IO SessionArbitrationGatewayEnqueueResult
enqueueArbitratedSessionFanInCommand gateway producer command host =
  modifyMVar (sagPolicy gateway) $ \policy ->
    case arbitrateSessionCommand policy producer command of
      ArbitrationRejected issue ->
        pure (policy, SagArbitrationRejected issue)
      ArbitrationAllowed -> do
        result <- enqueueSessionFanInCommand producer command host
        let policy' =
              case sfierResult result of
                SessionEnqueued {} ->
                  recordAcceptedSessionCommand policy producer command
                SessionEnqueueRejected {} ->
                  policy
        pure (policy', SagEnqueueAttempted result)
