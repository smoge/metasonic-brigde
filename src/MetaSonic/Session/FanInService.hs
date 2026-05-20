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
  , openSessionFanInService
  , openSessionFanInServiceHooks
  , closeSessionFanInService
  , enqueueSessionFanInServiceCommand
  , enqueueArbitratedSessionFanInServiceCommand
  , quiesceAndDrainSessionFanInService
  , resumeSessionFanInService
  , readSessionFanInService
  ) where

import           Control.Concurrent        (MVar, ThreadId,
                                            forkIOWithUnmask, killThread,
                                            modifyMVar_, newEmptyMVar,
                                            newMVar, putMVar, readMVar,
                                            takeMVar, tryPutMVar, tryTakeMVar,
                                            withMVar)
import           Control.DeepSeq           (NFData)
import           Control.Exception         (finally, mask, mask_,
                                            onException)
import           Control.Monad             (void, when)
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
                                             SessionFanInEnqueueResult (..),
                                             SessionFanInHost,
                                             SessionFanInHostHooks (..),
                                             SessionFanInOptions,
                                             SessionFanInSetupIssue,
                                             SessionFanInSnapshot (..),
                                             closeSessionFanInHost,
                                             defaultSessionFanInOptions,
                                             defaultSessionFanInHostHooks,
                                             drainSessionFanInHost,
                                             enqueueSessionFanInCommand,
                                             openSessionFanInHostHooks,
                                             readSessionFanInHost)
import           MetaSonic.Session.Queue    (ProducerId,
                                             SessionDrainResult (..),
                                             SessionEnqueueIssue (..),
                                             SessionEnqueueResult (..))


-- | Hidden handle for the scoped fan-in drain service.
data SessionFanInService = SessionFanInService
  { sfsvcHost :: !SessionFanInHost
  , sfsvcGateway :: !(Maybe SessionArbitrationGateway)
  , sfsvcHooks :: !SessionFanInServiceHooks
  , sfsvcControl :: !SessionFanInServiceControl
  }

data SessionFanInServiceControl = SessionFanInServiceControl
  { sfscIngress         :: !(MVar SessionFanInServiceIngress)
  , sfscWorkerAccepting :: !(IORef Bool)
  , sfscWake            :: !(MVar ())
  , sfscDone            :: !(MVar ())
  , sfscWorker          :: !(MVar ThreadId)
  }

data SessionFanInServiceIngress
  = SessionFanInServiceIngressOpen
  | SessionFanInServiceIngressQuiesced

-- | Access the underlying fan-in host for existing concrete producers.
--
-- Enqueues through this host wake the service worker because the
-- service installs a host enqueue hook at construction while the service
-- is running. After 'quiesceAndDrainSessionFanInService', raw host
-- enqueues still bypass service ingress policy while service enqueue
-- helpers reject until 'resumeSessionFanInService' starts a fresh worker.
-- The caller must have quiesced producers first.
-- If this service was configured with an arbitration gateway, callers
-- that need consistent policy enforcement should prefer
-- 'enqueueArbitratedSessionFanInServiceCommand'. Using the returned
-- host directly bypasses the configured gateway.
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
--
-- 'sfshOnIssue' may run concurrently from the drain worker
-- ('SfsiiDrainStopped') and from callers of the arbitrated enqueue path
-- ('SfsiiArbitrationRejected'), so hook implementations that share
-- mutable state must synchronize their own updates.
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
--
-- Composed from 'openSessionFanInServiceHooks' and
-- 'closeSessionFanInService' under 'mask' + 'finally' so the close
-- runs even if the action throws an async exception.
withSessionFanInServiceHooks
  :: SessionFanInServiceHooks
  -> TemplateGraph
  -> SessionFanInServiceOptions
  -> (SessionFanInService -> IO a)
  -> IO (Either SessionFanInServiceSetupIssue a)
withSessionFanInServiceHooks hooks graph opts action =
  mask $ \restore -> do
    openResult <- openSessionFanInServiceHooks hooks graph opts
    case openResult of
      Left issue ->
        pure (Left issue)
      Right service ->
        (Right <$> restore (action service))
          `finally` closeSessionFanInService service

-- | Open a fan-in service outside a bracket. Pair with
-- 'closeSessionFanInService'.
--
-- 'withSessionFanInServiceHooks' is the preferred entry for
-- scope-bracket usage. This pair exists so callers that need separate
-- open/close primitives (e.g., supervised host stacks) can drive the
-- lifecycle imperatively without promoting the bracket via a worker
-- thread. If worker construction fails after the host is opened, the
-- host is closed before the failure is rethrown so the owner cannot
-- leak.
openSessionFanInService
  :: TemplateGraph
  -> SessionFanInServiceOptions
  -> IO (Either SessionFanInServiceSetupIssue SessionFanInService)
openSessionFanInService =
  openSessionFanInServiceHooks defaultSessionFanInServiceHooks

-- | Open a fan-in service with explicit hooks. See
-- 'openSessionFanInService'.
openSessionFanInServiceHooks
  :: SessionFanInServiceHooks
  -> TemplateGraph
  -> SessionFanInServiceOptions
  -> IO (Either SessionFanInServiceSetupIssue SessionFanInService)
openSessionFanInServiceHooks hooks graph opts = mask_ $ do
  wake <- newEmptyMVar
  accepting <- newIORef True
  ingress <- newMVar SessionFanInServiceIngressOpen
  done <- newEmptyMVar
  workerVar <- newEmptyMVar
  let control = SessionFanInServiceControl
        { sfscIngress = ingress
        , sfscWorkerAccepting = accepting
        , sfscWake = wake
        , sfscDone = done
        , sfscWorker = workerVar
        }
      signalWorker =
        signalSessionFanInServiceWorker control
      hostHooks = defaultSessionFanInHostHooks
        { sfihhOnEnqueued = signalWorker
        }
  hostResult <- openSessionFanInHostHooks
    hostHooks
    graph
    (sfsoFanInOptions opts)
  case hostResult of
    Left issue ->
      pure (Left (SfsisiFanIn issue))
    Right host ->
      flip onException (closeSessionFanInHost host) $ do
        gateway <- traverse
          newSessionArbitrationGateway
          (sfsoArbitrationGatewayOptions opts)
        worker <- startSessionFanInServiceWorker hooks control host
        putMVar workerVar worker
        pure $ Right SessionFanInService
          { sfsvcHost = host
          , sfsvcGateway = gateway
          , sfsvcHooks = hooks
          , sfsvcControl = control
          }

-- | Close a fan-in service opened by 'openSessionFanInService' /
-- 'openSessionFanInServiceHooks'.
--
-- Stops the background drain worker first (cooperative exit, then
-- forced after the fixed 50 ms grace) and only then closes the host
-- so the worker cannot re-pull from a released owner. Runs under
-- 'mask_' so async exceptions cannot interrupt the worker/host
-- handoff. Safe to call more than once.
closeSessionFanInService :: SessionFanInService -> IO ()
closeSessionFanInService service = mask_ $ do
  stopSessionFanInServiceWorker (sfsvcControl service)
  closeSessionFanInHost (sfsvcHost service)

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
  withServiceIngress
    producer
    cmd
    service
    (enqueueSessionFanInCommand producer cmd (sfsvcHost service))
    pure

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
  withServiceIngress producer cmd service open (pure . SagEnqueueAttempted)
  where
    open =
      case sfsvcGateway service of
        Nothing ->
          SagEnqueueAttempted
            <$> enqueueSessionFanInCommand producer cmd (sfsvcHost service)
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

-- | Stop the service worker from accepting further wakeups and perform
-- one final orchestration-owned drain.
--
-- This is the handoff point for stopped-audio reload orchestration: the
-- background worker exits first, so it cannot re-pull commands after the
-- caller's final drain observes an empty queue. Service enqueue helpers
-- reject after this call starts. Raw access through
-- 'sessionFanInServiceHost' can still bypass that service ingress gate,
-- so hosts must quiesce concrete producers before calling this helper.
quiesceAndDrainSessionFanInService
  :: SessionFanInService
  -> IO SessionFanInDrainResult
quiesceAndDrainSessionFanInService service = do
  let control = sfsvcControl service
  closeSessionFanInServiceIngress control
  wakeSessionFanInServiceWorker control
  readMVar (sfscDone control)
  drainSessionFanInHost (sfsvcHost service)

-- | Reopen the service ingress and start a fresh drain worker after a
-- quiesce/drain handoff.
--
-- This is intended for host reload recovery and success paths that
-- continue using the same scoped 'SessionFanInService'. It does not
-- repair a diverged owner; if the owner is still stopped, the resumed
-- worker will report the next stopped drain normally.
resumeSessionFanInService
  :: SessionFanInService
  -> IO ()
resumeSessionFanInService service =
  resumeSessionFanInServiceWorker
    (sfsvcHooks service)
    (sfsvcControl service)
    (sfsvcHost service)

-- | Read the service-owned fan-in host snapshot.
readSessionFanInService
  :: SessionFanInService
  -> IO SessionFanInSnapshot
readSessionFanInService =
  readSessionFanInHost . sfsvcHost

serviceLoop
  :: SessionFanInServiceHooks
  -> SessionFanInServiceControl
  -> SessionFanInHost
  -> IO ()
serviceLoop hooks control host =
  loop `finally` putMVar (sfscDone control) ()
  where
    loop = do
      takeMVar (sfscWake control)
      shouldRun <- readIORef (sfscWorkerAccepting control)
      when shouldRun $ do
        drained <- drainSessionFanInHost host
        sfshOnDrain hooks drained
        case sdrStopped (sfidrDrain drained) of
          Just _reason ->
            sfshOnIssue hooks (SfsiiDrainStopped drained)
          Nothing -> do
            shouldContinue <- readIORef (sfscWorkerAccepting control)
            when shouldContinue $ do
              when (sfidrQueueDepth drained > 0) $
                signalSessionFanInServiceWorker control
              loop

withServiceIngress
  :: ProducerId
  -> SessionCommand
  -> SessionFanInService
  -> IO a
  -> (SessionFanInEnqueueResult -> IO a)
  -> IO a
withServiceIngress producer cmd service enqueue reject =
  withMVar (sfscIngress (sfsvcControl service)) $ \ingress ->
    case ingress of
      SessionFanInServiceIngressOpen ->
        enqueue
      SessionFanInServiceIngressQuiesced ->
        rejectServiceEnqueue producer cmd service >>= reject

rejectServiceEnqueue
  :: ProducerId
  -> SessionCommand
  -> SessionFanInService
  -> IO SessionFanInEnqueueResult
rejectServiceEnqueue producer cmd service = do
  snapshot <- readSessionFanInService service
  pure SessionFanInEnqueueResult
    { sfierResult =
        SessionEnqueueRejected producer cmd SeiReloadInProgress
    , sfierQueueDepth =
        sfisQueueDepth snapshot
    }

closeSessionFanInServiceIngress :: SessionFanInServiceControl -> IO ()
closeSessionFanInServiceIngress control =
  modifyMVar_ (sfscIngress control) $ \_ingress -> do
    writeIORef (sfscWorkerAccepting control) False
    pure SessionFanInServiceIngressQuiesced

signalSessionFanInServiceWorker :: SessionFanInServiceControl -> IO ()
signalSessionFanInServiceWorker control = do
  accepting <- readIORef (sfscWorkerAccepting control)
  when accepting $
    wakeSessionFanInServiceWorker control

wakeSessionFanInServiceWorker :: SessionFanInServiceControl -> IO ()
wakeSessionFanInServiceWorker control =
  void (tryPutMVar (sfscWake control) ())

resumeSessionFanInServiceWorker
  :: SessionFanInServiceHooks
  -> SessionFanInServiceControl
  -> SessionFanInHost
  -> IO ()
resumeSessionFanInServiceWorker hooks control host =
  modifyMVar_ (sfscIngress control) $ \ingress ->
    case ingress of
      SessionFanInServiceIngressOpen ->
        pure SessionFanInServiceIngressOpen
      SessionFanInServiceIngressQuiesced -> do
        readMVar (sfscDone control)
        mask_ $ do
          void (tryTakeMVar (sfscDone control))
          void (tryTakeMVar (sfscWake control))
          writeIORef (sfscWorkerAccepting control) True
          worker <- startSessionFanInServiceWorker hooks control host
          modifyMVar_ (sfscWorker control) $ \_oldWorker ->
            pure worker
          pure SessionFanInServiceIngressOpen

startSessionFanInServiceWorker
  :: SessionFanInServiceHooks
  -> SessionFanInServiceControl
  -> SessionFanInHost
  -> IO ThreadId
startSessionFanInServiceWorker hooks control host =
  forkIOWithUnmask $ \unmask ->
    unmask (serviceLoop hooks control host)

stopSessionFanInServiceWorker :: SessionFanInServiceControl -> IO ()
stopSessionFanInServiceWorker control = do
  closeSessionFanInServiceIngress control
  wakeSessionFanInServiceWorker control
  mDone <- timeout serviceShutdownGraceUsec (readMVar (sfscDone control))
  case mDone of
    Just () ->
      pure ()
    Nothing -> do
      worker <- readMVar (sfscWorker control)
      killThread worker
      readMVar (sfscDone control)

serviceShutdownGraceUsec :: Int
-- Keep this fixed until slow shutdown hooks become a real use case.
-- The value is long enough for normal no-op/reporting hooks and short
-- enough that a blocked hook cannot hang bracket teardown in practice.
serviceShutdownGraceUsec =
  50000
