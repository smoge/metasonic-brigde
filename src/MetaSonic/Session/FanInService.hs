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
-- The service deliberately does not add producer arbitration beyond the
-- existing FIFO queue, repair a diverged owner, define a realtime
-- command queue, or make OSC/MIDI/UI policy decisions. On owner
-- divergence it reports the stopped drain and lets the worker exit.

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
  , readSessionFanInService
  ) where

import           Control.Concurrent        (MVar, forkIO, newEmptyMVar,
                                            putMVar, takeMVar, tryPutMVar)
import           Control.DeepSeq           (NFData)
import           Control.Exception         (finally)
import           Control.Monad             (unless, void, when)
import           Data.IORef                (IORef, newIORef, readIORef,
                                            writeIORef)
import           GHC.Generics              (Generic)

import           MetaSonic.Bridge.Templates (TemplateGraph)
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
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Conservative service defaults.
defaultSessionFanInServiceOptions :: SessionFanInServiceOptions
defaultSessionFanInServiceOptions = SessionFanInServiceOptions
  { sfsoFanInOptions = defaultSessionFanInOptions
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

-- | Runtime issues reported by the background worker.
data SessionFanInServiceIssue
  = SfsiiDrainStopped !SessionFanInDrainResult
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
-- The worker shuts down when the callback exits. Shutdown waits for an
-- in-flight drain to finish, then releases the underlying fan-in host
-- and owner bracket.
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
          _worker <- forkIO (serviceLoop hooks closing wake done host)
          let service = SessionFanInService
                { sfsvcHost = host
                }
              stop = do
                writeIORef closing True
                signalWorker
                takeMVar done
          action service `finally` stop
  case result of
    Left issue ->
      pure (Left (SfsisiFanIn issue))
    Right value ->
      pure (Right value)

-- | Enqueue one command through the service-owned fan-in host.
enqueueSessionFanInServiceCommand
  :: ProducerId
  -> SessionCommand
  -> SessionFanInService
  -> IO SessionFanInEnqueueResult
enqueueSessionFanInServiceCommand producer cmd service =
  enqueueSessionFanInCommand producer cmd (sfsvcHost service)

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
