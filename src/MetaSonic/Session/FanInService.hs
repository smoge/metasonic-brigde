{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.FanInService
-- Description : Minimal background drain service for session fan-in.
--
-- This module adds a narrow lifecycle wrapper around
-- 'MetaSonic.Session.FanIn'. It allocates a scoped 'SessionFanInHost',
-- installs a wakeup hook for successful enqueues, and runs one
-- background worker that drains the host after wakeups.
--
-- The service deliberately keeps the existing raw enqueue path as FIFO.
-- Callers can opt into a service-owned arbitration gateway and use the
-- arbitrated enqueue path, but no producer is routed through that path
-- by default. The service still does not repair a diverged owner, define
-- a realtime command queue, or make OSC/MIDI/UI policy decisions. On
-- owner divergence it reports the stopped drain and lets the worker exit.

module MetaSonic.Session.FanInService
  ( -- * Service
    SessionFanInService
  , sessionFanInServiceHost

    -- * Options
  , SessionFanInServiceOptions (..)
  , defaultSessionFanInServiceOptions

    -- * Hooks
  , SessionFanInServiceHooks (..)
  , defaultSessionFanInServiceHooks

    -- * Issues
  , SessionFanInServiceSetupIssue (..)
  , SessionFanInServiceIssue (..)

    -- * Scoped service
  , withSessionFanInService
  , withSessionFanInServiceHooks
  , enqueueSessionFanInServiceCommand
  , enqueueArbitratedSessionFanInServiceCommand
  , readSessionFanInService
  ) where

import           Control.Concurrent        (MVar, forkIO, killThread,
                                            newEmptyMVar, putMVar, takeMVar,
                                            tryPutMVar)
import           Control.DeepSeq           (NFData)
import           Control.Exception         (finally)
import           Control.Monad             (unless, void, when)
import           Data.IORef                (IORef, newIORef, readIORef,
                                            writeIORef)
import           GHC.Generics              (Generic)
import           System.Timeout            (timeout)

import           MetaSonic.Bridge.Templates (TemplateGraph)
import           MetaSonic.Session.Arbitration
                                            (ArbitrationIssue)
import           MetaSonic.Session.ArbitrationGateway
                                            (SessionArbitrationGateway,
                                             SessionArbitrationGatewayEnqueueResult (..),
                                             SessionArbitrationGatewayOptions,
                                             enqueueArbitratedSessionFanInCommand,
                                             newSessionArbitrationGateway)
import           MetaSonic.Session.Command  (SessionCommand)
import           MetaSonic.Session.FanIn    (SessionFanInDrainResult (..),
                                             SessionFanInEnqueueResult,
                                             SessionFanInHost,
                                             SessionFanInHostHooks (..),
                                             SessionFanInOptions,
                                             SessionFanInSetupIssue,
                                             SessionFanInSnapshot,
                                             defaultSessionFanInOptions,
                                             defaultSessionFanInHostHooks,
                                             drainSessionFanInHost,
                                             enqueueSessionFanInCommand,
                                             readSessionFanInHost,
                                             withSessionFanInHostHooks)
import           MetaSonic.Session.Queue    (ProducerId,
                                             SessionDrainResult (..))


-- | Hidden handle for the scoped fan-in drain service.
data SessionFanInService = SessionFanInService
  { sfsvcHost :: !SessionFanInHost
  , sfsvcGateway :: !(Maybe SessionArbitrationGateway)
  , sfsvcHooks :: !SessionFanInServiceHooks
  }

-- | Access the underlying fan-in host for existing concrete producers.
--
-- Enqueues through this host wake the service worker because the
-- service installs a host enqueue hook at construction.
sessionFanInServiceHost :: SessionFanInService -> SessionFanInHost
sessionFanInServiceHost =
  sfsvcHost

-- | Construction options for the fan-in service.
data SessionFanInServiceOptions = SessionFanInServiceOptions
  { sfsoFanInOptions :: !SessionFanInOptions
  , sfsoArbitrationGatewayOptions :: !(Maybe SessionArbitrationGatewayOptions)
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Conservative service defaults.
--
-- Arbitration is disabled by default. Calling
-- 'enqueueArbitratedSessionFanInServiceCommand' with this default still
-- preserves FIFO behavior by submitting directly to fan-in.
defaultSessionFanInServiceOptions :: SessionFanInServiceOptions
defaultSessionFanInServiceOptions = SessionFanInServiceOptions
  { sfsoFanInOptions = defaultSessionFanInOptions
  , sfsoArbitrationGatewayOptions = Nothing
  }

-- | Service lifecycle hooks.
data SessionFanInServiceHooks = SessionFanInServiceHooks
  { sfshOnDrain :: !(SessionFanInDrainResult -> IO ())
  , sfshOnIssue :: !(SessionFanInServiceIssue -> IO ())
  }

-- | Default no-op lifecycle hooks.
defaultSessionFanInServiceHooks :: SessionFanInServiceHooks
defaultSessionFanInServiceHooks = SessionFanInServiceHooks
  { sfshOnDrain = \_ -> pure ()
  , sfshOnIssue = \_ -> pure ()
  }

-- | Service construction failures.
newtype SessionFanInServiceSetupIssue
  = SfsisiFanIn SessionFanInSetupIssue
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Runtime issues reported by the service.
data SessionFanInServiceIssue
  = SfsiiDrainStopped !SessionFanInDrainResult
    -- ^ The background drain worker observed a stopped drain.
  | SfsiiArbitrationRejected !ArbitrationIssue
    -- ^ The service-owned arbitration gateway rejected a command before
    -- fan-in enqueue. This is policy denial, not queue pressure.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Allocate a scoped fan-in service with default hooks.
withSessionFanInService
  :: TemplateGraph
  -> SessionFanInServiceOptions
  -> (SessionFanInService -> IO a)
  -> IO (Either SessionFanInServiceSetupIssue a)
withSessionFanInService =
  withSessionFanInServiceHooks defaultSessionFanInServiceHooks

-- | Allocate a scoped fan-in service with explicit lifecycle hooks.
--
-- The worker shuts down when the callback exits. Shutdown first asks
-- the worker to exit cooperatively, then kills it if a service hook or
-- drain path blocks past a fixed 50 ms grace period. The grace period
-- is deliberately not configurable until a real hook needs policy
-- control; blocked teardown is worse than force-killing this service
-- worker. The underlying fan-in host and owner bracket are released
-- only after the worker finalizer reports completion.
withSessionFanInServiceHooks
  :: SessionFanInServiceHooks
  -> TemplateGraph
  -> SessionFanInServiceOptions
  -> (SessionFanInService -> IO a)
  -> IO (Either SessionFanInServiceSetupIssue a)
withSessionFanInServiceHooks hooks graph opts action = do
  wake <- newEmptyMVar
  closing <- newIORef False
  done <- newEmptyMVar
  let signalWorker =
        void (tryPutMVar wake ())
      hostHooks = defaultSessionFanInHostHooks
        { sfihhOnEnqueued = signalWorker
        }
  result <-
    withSessionFanInHostHooks
      hostHooks
      graph
      (sfsoFanInOptions opts)
      $ \host -> do
          gateway <- traverse
            newSessionArbitrationGateway
            (sfsoArbitrationGatewayOptions opts)
          worker <- forkIO (serviceLoop hooks closing wake done host)
          let service = SessionFanInService
                { sfsvcHost = host
                , sfsvcGateway = gateway
                , sfsvcHooks = hooks
                }
              stop = do
                writeIORef closing True
                signalWorker
                mDone <- timeout serviceShutdownGraceUsec (takeMVar done)
                case mDone of
                  Just () ->
                    pure ()
                  Nothing -> do
                    killThread worker
                    takeMVar done
          action service `finally` stop
  case result of
    Left issue ->
      pure (Left (SfsisiFanIn issue))
    Right value ->
      pure (Right value)

-- | Enqueue one command through the service-owned fan-in host.
--
-- This is the raw FIFO path. If a gateway is configured via
-- 'sfsoArbitrationGatewayOptions', this function still bypasses it and
-- therefore does not reject by policy or update gateway owner state.
-- Callers that need consistent policy enforcement across producers must
-- route every producer through
-- 'enqueueArbitratedSessionFanInServiceCommand'. Mixing raw and
-- arbitrated paths with a configured gateway silently bypasses policy
-- for raw-path commands.
enqueueSessionFanInServiceCommand
  :: ProducerId
  -> SessionCommand
  -> SessionFanInService
  -> IO SessionFanInEnqueueResult
enqueueSessionFanInServiceCommand producer cmd service =
  enqueueSessionFanInCommand producer cmd (sfsvcHost service)

-- | Enqueue one command through the optional service-owned gateway.
--
-- With default options this falls back to the raw FIFO service enqueue.
-- In that configuration only 'SagEnqueueAttempted' results are produced;
-- 'SagArbitrationRejected' is reachable only when a gateway is
-- configured.
--
-- When 'sfsoArbitrationGatewayOptions' is configured, policy rejection
-- happens before fan-in and therefore does not wake the drain worker,
-- consume queue capacity, or assign a command sequence.
enqueueArbitratedSessionFanInServiceCommand
  :: ProducerId
  -> SessionCommand
  -> SessionFanInService
  -> IO SessionArbitrationGatewayEnqueueResult
enqueueArbitratedSessionFanInServiceCommand producer cmd service =
  case sfsvcGateway service of
    Nothing ->
      SagEnqueueAttempted
        <$> enqueueSessionFanInServiceCommand producer cmd service
    Just gateway -> do
      result <-
        enqueueArbitratedSessionFanInCommand
          gateway producer cmd (sfsvcHost service)
      case result of
        SagArbitrationRejected issue ->
          sfshOnIssue (sfsvcHooks service)
            (SfsiiArbitrationRejected issue)
        SagEnqueueAttempted {} ->
          pure ()
      pure result

-- | Read the service-owned fan-in host snapshot.
readSessionFanInService
  :: SessionFanInService
  -> IO SessionFanInSnapshot
readSessionFanInService =
  readSessionFanInHost . sfsvcHost

serviceLoop
  :: SessionFanInServiceHooks
  -> IORef Bool
  -> MVar ()
  -> MVar ()
  -> SessionFanInHost
  -> IO ()
serviceLoop hooks closing wake done host =
  loop `finally` putMVar done ()
  where
    loop = do
      takeMVar wake
      shouldClose <- readIORef closing
      unless shouldClose $ do
        drained <- drainSessionFanInHost host
        sfshOnDrain hooks drained
        case sdrStopped (sfidrDrain drained) of
          Just _reason ->
            sfshOnIssue hooks (SfsiiDrainStopped drained)
          Nothing -> do
            when (sfidrQueueDepth drained > 0) $
              void (tryPutMVar wake ())
            loop

serviceShutdownGraceUsec :: Int
-- Keep this fixed until slow shutdown hooks become a real use case.
-- The value is long enough for normal no-op/reporting hooks and short
-- enough that a blocked hook cannot hang bracket teardown in practice.
serviceShutdownGraceUsec =
  50000
