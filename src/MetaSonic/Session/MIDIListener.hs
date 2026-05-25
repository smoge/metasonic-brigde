{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}

-- |
-- Module      : MetaSonic.Session.MIDIListener
-- Description : Session-backed decoded MIDI listener.
--
-- This module is the session-facing MIDI listener substrate. It owns a
-- bracketed worker thread over an injected decoded-event source, keeps
-- producer-local MIDI note and control-coalescing state, and submits
-- generated commands through 'MetaSonic.Session.MIDIProducer' into
-- either a 'SessionFanInHost' (the raw FIFO path) or the explicit
-- service-owned arbitration path on a 'SessionFanInService' (the
-- arbitrated path). Both paths share the same decode, coalescing,
-- fence, and timed-flush machinery; only per-command submission and
-- policy-rejection reporting differ.
--
-- It deliberately does not open PortMIDI devices, choose a live clock,
-- define channel remapping/splits, or repair a diverged owner. Real
-- device ownership should be added later as a source behind this
-- decoded-event boundary.

module MetaSonic.Session.MIDIListener
  ( -- * Decoded event source
    MIDIListenerSource (..)

    -- * Listener handle
  , SessionMIDIListener
  , readSessionMIDIListenerState
  , readSessionMIDIListenerCoalescingStats

    -- * Listener options
  , SessionMIDIListenerOptions (..)
  , defaultSessionMIDIListenerOptions

    -- * Listener-side coalescing diagnostics
  , SessionMIDIListenerCoalescingStats (..)

    -- * Listener-side issues
  , SessionMIDIListenerIssue (..)

    -- * Hooks
  , SessionMIDIListenerHooks (..)
  , defaultSessionMIDIListenerHooks
  , SessionMIDIArbitratedListenerHooks (..)
  , defaultSessionMIDIArbitratedListenerHooks

    -- * Bracketed listener
  , withSessionMIDIListener
  , withSessionMIDIListenerHooks
  , withSessionMIDIListenerHooksAndOptions
  , withArbitratedSessionMIDIListener
  , withArbitratedSessionMIDIListenerHooks
  , withArbitratedSessionMIDIListenerHooksAndOptions
  ) where

import           Control.Concurrent             (forkIO, killThread,
                                                 threadDelay)
import           Control.Concurrent.MVar        (MVar, modifyMVar, newMVar,
                                                 readMVar)
import           Control.DeepSeq                (NFData)
import           Control.Exception              (bracket)
import           Control.Monad                  (forever, forM_)
import qualified Data.Map.Strict                as M
import           GHC.Generics                   (Generic)

import           MetaSonic.Pattern              (ControlTag, Value, VoiceKey)
import           MetaSonic.Session.Arbitration  (ArbitrationIssue)
import           MetaSonic.Session.ArbitrationGateway
                                                (SessionArbitrationGatewayEnqueueResult (..))
import           MetaSonic.Session.Command      (SessionCommand (..))
import           MetaSonic.Session.FanIn        (SessionFanInEnqueueResult (..),
                                                 SessionFanInHost,
                                                 enqueueSessionFanInCommand)
import           MetaSonic.Session.FanInService (SessionFanInService,
                                                 enqueueArbitratedSessionFanInServiceCommand)
import           MetaSonic.Session.MIDIProducer (MIDIProducerArbitratedEnqueueResult (..),
                                                 MIDIProducerCommandBatch (..),
                                                 MIDIProducerEnqueueResult (..),
                                                 MIDIProducerEvent,
                                                 MIDIProducerIssue,
                                                 MIDIProducerOptions,
                                                 MIDIProducerState,
                                                 decodeMIDISessionCommands,
                                                 midiProducerId)
import           MetaSonic.Session.Queue        (SessionEnqueueIssue,
                                                 SessionEnqueueResult (..))


-- | A source of already-decoded MIDI producer events.
--
-- Returning 'Nothing' means the source reached end-of-input and the
-- listener worker should exit normally. A blocking source is interrupted
-- by the bracket finalizer via 'killThread'. Source implementations
-- should not throw synchronous exceptions for ordinary device/read
-- failures; if 'mlsReadEvent' does throw, the worker terminates without
-- listener-hook notification and the last readable state remains as
-- post-mortem diagnostic state.
newtype MIDIListenerSource = MIDIListenerSource
  { mlsReadEvent :: IO (Maybe MIDIProducerEvent)
  }

-- | Opaque handle for a running session MIDI listener.
newtype SessionMIDIListener = SessionMIDIListener
  { smlWorkerState :: MVar MIDIListenerWorkerState
  }

-- | Read the listener-owned MIDI producer state.
--
-- This is also valid after the listener bracket exits; in that case it
-- returns the final state snapshot, including any synchronous teardown
-- flush effects.
readSessionMIDIListenerState
  :: SessionMIDIListener
  -> IO MIDIProducerState
readSessionMIDIListenerState listener =
  mlwsProducerState <$> readMVar (smlWorkerState listener)

-- | Read producer-local control coalescing counters.
--
-- This is also valid after the listener bracket exits; in that case it
-- returns the final counters, including any synchronous teardown flush
-- effects.
readSessionMIDIListenerCoalescingStats
  :: SessionMIDIListener
  -> IO SessionMIDIListenerCoalescingStats
readSessionMIDIListenerCoalescingStats listener =
  workerCoalescingStats <$> readMVar (smlWorkerState listener)

-- | Listener worker options.
data SessionMIDIListenerOptions = SessionMIDIListenerOptions
  { smloTimedControlFlushUsec :: !(Maybe Int)
    -- ^ Optional timed flush for pending producer-local control writes.
    -- 'Nothing' leaves only fence and EOF flushes, which is useful for
    -- deterministic tests.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Conservative live default: batch bursts without making held
-- control updates wait for a lifecycle fence.
defaultSessionMIDIListenerOptions :: SessionMIDIListenerOptions
defaultSessionMIDIListenerOptions = SessionMIDIListenerOptions
  { smloTimedControlFlushUsec = Just 20000
  }

-- | Observable listener-local coalescing counters.
data SessionMIDIListenerCoalescingStats = SessionMIDIListenerCoalescingStats
  { smlcsCoalescedCount    :: !Int
    -- ^ Pending writes overwritten by newer writes to the same
    -- @(VoiceKey, ControlTag)@.
  , smlcsFlushedCount      :: !Int
    -- ^ Pending control writes accepted by the submission path during
    -- coalescer flushes.
  , smlcsBarrierFlushCount :: !Int
    -- ^ Non-empty flushes forced by fence commands.
  , smlcsPendingCount      :: !Int
    -- ^ Current pending coalesced control write count.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Everything this listener can report without killing the listener
-- thread.
data SessionMIDIListenerIssue
  = SmliProducerRejected !MIDIProducerIssue
    -- ^ The decoded event was refused by the MIDI producer adapter.
  | SmliEnqueueRejected !SessionCommand !SessionEnqueueIssue
    -- ^ The decoded event produced a command, but the fan-in queue
    -- rejected it. In v1 this is expected to be queue-full.
  | SmliArbitrationRejected !ArbitrationIssue
    -- ^ The decoded event produced a command, but a service-owned
    -- arbitration gateway rejected it before fan-in enqueue. Only
    -- reachable on the arbitrated listener path; the raw FIFO path
    -- never constructs this constructor.
  | SmliFenceDroppedForFlushFailure !MIDIProducerEvent !Int
    -- ^ A non-control-write fence event was decoded, but pending
    -- coalesced control writes had to flush first and at least one
    -- flush submission was rejected. On the raw path this is queue
    -- pressure; on the arbitrated path it can also be policy denial.
    -- The fence commands were not submitted, pending controls remain
    -- available for retry, and the producer state stays at the
    -- pre-event value. The 'Int' is the number of rejected flush
    -- submissions.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Session-backed MIDI listener hooks for the raw FIFO path.
-- Production callers can discard both hooks; tests use them for
-- synchronization and issue capture.
data SessionMIDIListenerHooks = SessionMIDIListenerHooks
  { smlhOnProducerResult :: !(MIDIProducerEnqueueResult -> IO ())
    -- ^ Called after every source event has gone through the MIDI
    -- producer adapter.
  , smlhOnIssue          :: !(SessionMIDIListenerIssue -> IO ())
    -- ^ Called for MIDI producer rejections and fan-in enqueue
    -- rejections.
  }

-- | Default raw-path hooks: discard diagnostics and producer results.
defaultSessionMIDIListenerHooks :: SessionMIDIListenerHooks
defaultSessionMIDIListenerHooks = SessionMIDIListenerHooks
  { smlhOnProducerResult = \_ -> pure ()
  , smlhOnIssue          = \_ -> pure ()
  }

-- | Session-backed MIDI listener hooks for the explicit arbitrated
-- service path. This stays separate from 'SessionMIDIListenerHooks' so
-- existing host-based listener users do not need to handle
-- arbitration-shaped producer results.
data SessionMIDIArbitratedListenerHooks = SessionMIDIArbitratedListenerHooks
  { smlahOnProducerResult :: !(MIDIProducerArbitratedEnqueueResult -> IO ())
    -- ^ Called after every source event has gone through the
    -- arbitrated MIDI producer adapter and any associated flush.
  , smlahOnIssue          :: !(SessionMIDIListenerIssue -> IO ())
    -- ^ Called for MIDI producer rejections, service-owned arbitration
    -- rejections, fan-in enqueue rejections after policy acceptance,
    -- and fence-drop events.
  }

-- | Default arbitrated-path hooks: discard diagnostics and producer
-- results.
defaultSessionMIDIArbitratedListenerHooks
  :: SessionMIDIArbitratedListenerHooks
defaultSessionMIDIArbitratedListenerHooks =
  SessionMIDIArbitratedListenerHooks
    { smlahOnProducerResult = \_ -> pure ()
    , smlahOnIssue          = \_ -> pure ()
    }

-- | Run a worker over a decoded MIDI source for the body lifetime,
-- routing every submission through the raw FIFO fan-in host path.
--
-- The listener only enqueues into the supplied fan-in host; it never
-- drains it. Producer-local note state starts from the supplied initial
-- state. Repeated control writes from one decoded event stream are
-- coalesced locally by @(VoiceKey, ControlTag)@ and flushed before any
-- non-control-write fence, on EOF or teardown, and by the optional
-- timed flush.
--
-- A producer result with a non-empty control-write batch and an empty
-- enqueue-result list means those writes were deferred to the local
-- coalescer; they are reported again with concrete enqueue results
-- when a later flush submits them. During that window,
-- 'readSessionMIDIListenerState' reflects listener-local target state
-- that fan-in and the runtime may not have received yet. EOF and
-- teardown flushes only report enqueue issues; they do not call
-- 'smlhOnProducerResult'.
--
-- If a fence-triggered flush is rejected, the fence commands are not
-- enqueued and 'SmliFenceDroppedForFlushFailure' is reported. Producer
-- options, including channel filtering, are captured for the worker
-- lifetime; use a new listener bracket for a new policy.
withSessionMIDIListener
  :: MIDIProducerOptions
  -> MIDIProducerState
  -> MIDIListenerSource
  -> SessionFanInHost
  -> (SessionMIDIListener -> IO a)
  -> IO a
withSessionMIDIListener =
  withSessionMIDIListenerHooks defaultSessionMIDIListenerHooks

-- | Same shape as 'withSessionMIDIListener' but with explicit hooks.
withSessionMIDIListenerHooks
  :: SessionMIDIListenerHooks
  -> MIDIProducerOptions
  -> MIDIProducerState
  -> MIDIListenerSource
  -> SessionFanInHost
  -> (SessionMIDIListener -> IO a)
  -> IO a
withSessionMIDIListenerHooks hooks =
  withSessionMIDIListenerHooksAndOptions
    hooks
    defaultSessionMIDIListenerOptions

-- | Same shape as 'withSessionMIDIListenerHooks' but with listener
-- options, including timed control-write flush policy.
withSessionMIDIListenerHooksAndOptions
  :: SessionMIDIListenerHooks
  -> SessionMIDIListenerOptions
  -> MIDIProducerOptions
  -> MIDIProducerState
  -> MIDIListenerSource
  -> SessionFanInHost
  -> (SessionMIDIListener -> IO a)
  -> IO a
withSessionMIDIListenerHooksAndOptions
  hooks listenerOpts producerOpts initialState source host =
  runMIDIListener
    (rawListenerEngineOps hooks producerOpts host)
    listenerOpts
    producerOpts
    initialState
    source

-- | Run a worker over a decoded MIDI source for the body lifetime,
-- routing every submission through the explicit service-owned
-- arbitration path on a 'SessionFanInService'.
--
-- This is opt-in. Existing host-based callers should keep using
-- 'withSessionMIDIListener' unless the surrounding session deliberately
-- enables service-owned arbitration. With default service options this
-- still preserves FIFO behavior; with configured gateway options,
-- policy rejections are surfaced as 'SmliArbitrationRejected' and a
-- fence-triggered flush whose submissions include a policy rejection
-- still produces 'SmliFenceDroppedForFlushFailure' so the fence-drop
-- contract is identical across submission paths.
--
-- Arbitration rejections also fire the underlying service hook as
-- @SfsiiArbitrationRejected@. Subscribe to the service hook for
-- cross-producer aggregation and to this listener hook for MIDI-specific
-- observability; subscribing to both observes the same rejection twice.
withArbitratedSessionMIDIListener
  :: MIDIProducerOptions
  -> MIDIProducerState
  -> MIDIListenerSource
  -> SessionFanInService
  -> (SessionMIDIListener -> IO a)
  -> IO a
withArbitratedSessionMIDIListener =
  withArbitratedSessionMIDIListenerHooks
    defaultSessionMIDIArbitratedListenerHooks

-- | Same shape as 'withArbitratedSessionMIDIListener' but with explicit
-- hooks.
withArbitratedSessionMIDIListenerHooks
  :: SessionMIDIArbitratedListenerHooks
  -> MIDIProducerOptions
  -> MIDIProducerState
  -> MIDIListenerSource
  -> SessionFanInService
  -> (SessionMIDIListener -> IO a)
  -> IO a
withArbitratedSessionMIDIListenerHooks hooks =
  withArbitratedSessionMIDIListenerHooksAndOptions
    hooks
    defaultSessionMIDIListenerOptions

-- | Same shape as 'withArbitratedSessionMIDIListenerHooks' but with
-- listener options, including timed control-write flush policy.
withArbitratedSessionMIDIListenerHooksAndOptions
  :: SessionMIDIArbitratedListenerHooks
  -> SessionMIDIListenerOptions
  -> MIDIProducerOptions
  -> MIDIProducerState
  -> MIDIListenerSource
  -> SessionFanInService
  -> (SessionMIDIListener -> IO a)
  -> IO a
withArbitratedSessionMIDIListenerHooksAndOptions
  hooks listenerOpts producerOpts initialState source service =
  runMIDIListener
    (arbitratedListenerEngineOps hooks producerOpts service)
    listenerOpts
    producerOpts
    initialState
    source

type PendingControlKey = (VoiceKey, ControlTag)

data MIDIListenerWorkerState = MIDIListenerWorkerState
  { mlwsProducerState :: !MIDIProducerState
  , mlwsPending       :: !(M.Map PendingControlKey Value)
  , mlwsStats         :: !SessionMIDIListenerCoalescingStats
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

data MIDIFlushReason
  = MIDIFlushFence
  | MIDIFlushTimed
  | MIDIFlushEOF
  deriving stock (Eq, Show)

-- | One submitted command's outcome on either submission path.
--
-- 'LsoEnqueued' carries the underlying fan-in result, whether accepted
-- or rejected by queue pressure. 'LsoPolicyRejected' is only produced
-- on the arbitrated path when a service-owned gateway denies the
-- command before fan-in enqueue.
data ListenerSubmissionOutcome
  = LsoEnqueued !SessionFanInEnqueueResult
  | LsoPolicyRejected !ArbitrationIssue

-- | Engine ops abstract per-path submission and result construction so
-- the worker, coalescer, fence handler, and flush logic can be shared
-- across raw and arbitrated listeners. @result@ is the producer-result
-- type the path constructs for its own hook record.
data ListenerEngineOps result = ListenerEngineOps
  { leoSubmit           :: SessionCommand -> IO ListenerSubmissionOutcome
  , leoBuildAttempted   :: MIDIProducerCommandBatch
                         -> [ListenerSubmissionOutcome]
                         -> result
  , leoBuildRejected    :: MIDIProducerIssue
                         -> MIDIProducerState
                         -> result
  , leoOnProducerResult :: result -> IO ()
  , leoOnIssue          :: SessionMIDIListenerIssue -> IO ()
  }

data MIDIEventAction
  = MIDIEventRejected !MIDIProducerIssue !MIDIProducerState
  | MIDIEventDeferred !MIDIProducerCommandBatch
  | MIDIEventFence !MIDIProducerState !MIDIProducerCommandBatch

rawListenerEngineOps
  :: SessionMIDIListenerHooks
  -> MIDIProducerOptions
  -> SessionFanInHost
  -> ListenerEngineOps MIDIProducerEnqueueResult
rawListenerEngineOps hooks producerOpts host = ListenerEngineOps
  { leoSubmit = \cmd ->
      LsoEnqueued <$>
        enqueueSessionFanInCommand (midiProducerId producerOpts) cmd host
  , leoBuildAttempted = \batch outcomes ->
      MIDIProducerEnqueueAttempted
        batch
        [r | LsoEnqueued r <- outcomes]
  , leoBuildRejected = MIDIProducerRejected
  , leoOnProducerResult = smlhOnProducerResult hooks
  , leoOnIssue          = smlhOnIssue hooks
  }

arbitratedListenerEngineOps
  :: SessionMIDIArbitratedListenerHooks
  -> MIDIProducerOptions
  -> SessionFanInService
  -> ListenerEngineOps MIDIProducerArbitratedEnqueueResult
arbitratedListenerEngineOps hooks producerOpts service = ListenerEngineOps
  { leoSubmit = \cmd -> do
      result <- enqueueArbitratedSessionFanInServiceCommand
                  (midiProducerId producerOpts) cmd service
      pure $ case result of
        SagEnqueueAttempted r       -> LsoEnqueued r
        SagArbitrationRejected issue -> LsoPolicyRejected issue
  , leoBuildAttempted = \batch outcomes ->
      MIDIProducerArbitratedEnqueueAttempted
        batch
        (map outcomeToArbitrated outcomes)
  , leoBuildRejected = MIDIProducerArbitratedRejected
  , leoOnProducerResult = smlahOnProducerResult hooks
  , leoOnIssue          = smlahOnIssue hooks
  }
  where
    outcomeToArbitrated = \case
      LsoEnqueued r           -> SagEnqueueAttempted r
      LsoPolicyRejected issue -> SagArbitrationRejected issue

runMIDIListener
  :: ListenerEngineOps result
  -> SessionMIDIListenerOptions
  -> MIDIProducerOptions
  -> MIDIProducerState
  -> MIDIListenerSource
  -> (SessionMIDIListener -> IO a)
  -> IO a
runMIDIListener ops listenerOpts producerOpts initialState source body = do
  stateVar <- newMVar (initialWorkerState initialState)
  let listener = SessionMIDIListener
        { smlWorkerState = stateVar
        }
  bracket
    (startWorkers stateVar)
    (stopWorkers stateVar)
    (\_ -> body listener)
  where
    startWorkers stateVar = do
      reader <- forkIO
        (midiListenerLoop ops producerOpts source stateVar)
      flusher <- case smloTimedControlFlushUsec listenerOpts of
        Nothing ->
          pure Nothing
        Just usec ->
          Just <$> forkIO
            (midiListenerTimedFlushLoop ops stateVar (max 1 usec))
      pure (reader, flusher)

    stopWorkers stateVar (reader, flusher) = do
      killThread reader
      mapM_ killThread flusher
      (commands, outcomes) <-
        flushPendingControls ops stateVar MIDIFlushEOF
      reportOutcomeIssues (leoOnIssue ops) commands outcomes

initialWorkerState :: MIDIProducerState -> MIDIListenerWorkerState
initialWorkerState st = MIDIListenerWorkerState
  { mlwsProducerState =
      st
  , mlwsPending =
      M.empty
  , mlwsStats =
      SessionMIDIListenerCoalescingStats
        { smlcsCoalescedCount    = 0
        , smlcsFlushedCount      = 0
        , smlcsBarrierFlushCount = 0
        , smlcsPendingCount      = 0
        }
  }

midiListenerLoop
  :: ListenerEngineOps result
  -> MIDIProducerOptions
  -> MIDIListenerSource
  -> MVar MIDIListenerWorkerState
  -> IO ()
midiListenerLoop ops producerOpts source stateVar =
  loop
  where
    loop = do
      mEvent <- mlsReadEvent source
      case mEvent of
        Nothing -> do
          (commands, outcomes) <-
            flushPendingControls ops stateVar MIDIFlushEOF
          reportOutcomeIssues (leoOnIssue ops) commands outcomes
        Just event -> do
          (result, eventIssues) <-
            processMIDIEvent ops producerOpts stateVar event
          leoOnProducerResult ops result
          forM_ eventIssues (leoOnIssue ops)
          loop

midiListenerTimedFlushLoop
  :: ListenerEngineOps result
  -> MVar MIDIListenerWorkerState
  -> Int
  -> IO ()
midiListenerTimedFlushLoop ops stateVar usec =
  forever $ do
    threadDelay usec
    (commands, outcomes) <-
      flushPendingControls ops stateVar MIDIFlushTimed
    reportOutcomeIssues (leoOnIssue ops) commands outcomes

reportOutcomeIssues
  :: (SessionMIDIListenerIssue -> IO ())
  -> [SessionCommand]
  -> [ListenerSubmissionOutcome]
  -> IO ()
reportOutcomeIssues onIssue commands outcomes =
  forM_ (zip commands outcomes) $ \(cmd, outcome) ->
    case outcomeToIssue cmd outcome of
      Nothing ->
        pure ()
      Just issue ->
        onIssue issue

outcomeToIssue
  :: SessionCommand
  -> ListenerSubmissionOutcome
  -> Maybe SessionMIDIListenerIssue
outcomeToIssue cmd outcome = case outcome of
  LsoEnqueued result -> case sfierResult result of
    SessionEnqueued _ ->
      Nothing
    SessionEnqueueRejected _ _ issue ->
      Just (SmliEnqueueRejected cmd issue)
  LsoPolicyRejected issue ->
    Just (SmliArbitrationRejected issue)

processMIDIEvent
  :: ListenerEngineOps result
  -> MIDIProducerOptions
  -> MVar MIDIListenerWorkerState
  -> MIDIProducerEvent
  -> IO (result, [SessionMIDIListenerIssue])
processMIDIEvent ops producerOpts stateVar event = do
  action <- modifyMVar stateVar $ \workerState ->
    let st = mlwsProducerState workerState
    in case decodeMIDISessionCommands producerOpts st event of
      Left issue ->
        pure (workerState, MIDIEventRejected issue st)
      Right batch
        | all isControlWrite (mpcbCommands batch) ->
            let (pending', coalesced) =
                  mergePendingControls (mpcbCommands batch)
                                       (mlwsPending workerState)
                workerState' = workerState
                  { mlwsProducerState =
                      mpcbState batch
                  , mlwsPending =
                      pending'
                  , mlwsStats =
                      addCoalesced coalesced (mlwsStats workerState)
                  }
            in pure (workerState', MIDIEventDeferred batch)
        | otherwise ->
            pure (workerState, MIDIEventFence st batch)
  case action of
    MIDIEventRejected issue st ->
      pure
        ( leoBuildRejected ops issue st
        , [SmliProducerRejected issue]
        )
    MIDIEventDeferred batch ->
      pure (leoBuildAttempted ops batch [], [])
    MIDIEventFence oldState batch -> do
      (flushCommands, flushOutcomes) <-
        flushPendingControls ops stateVar MIDIFlushFence
      if not (all outcomeAccepted flushOutcomes)
         then do
           let rejectedCount =
                 length (filter (not . outcomeAccepted) flushOutcomes)
               flushBatch = MIDIProducerCommandBatch
                 { mpcbCommands =
                     flushCommands
                 , mpcbState =
                     oldState
                 }
               flushIssues =
                 [ issue
                 | (cmd, outcome) <- zip flushCommands flushOutcomes
                 , Just issue <- [outcomeToIssue cmd outcome]
                 ]
           pure
             ( leoBuildAttempted ops flushBatch flushOutcomes
             , SmliFenceDroppedForFlushFailure event rejectedCount
                 : flushIssues
             )
         else do
           eventOutcomes <- traverse (leoSubmit ops) (mpcbCommands batch)
           let allOutcomes = flushOutcomes <> eventOutcomes
               allCommands = flushCommands <> mpcbCommands batch
               finalState =
                 if all outcomeAccepted eventOutcomes
                    then mpcbState batch
                    else oldState
               finalBatch = MIDIProducerCommandBatch
                 { mpcbCommands =
                     allCommands
                 , mpcbState =
                     finalState
                 }
               eventIssues =
                 [ issue
                 | (cmd, outcome) <- zip (mpcbCommands batch) eventOutcomes
                 , Just issue <- [outcomeToIssue cmd outcome]
                 ]
           modifyMVar stateVar $ \workerState ->
             pure
               ( workerState { mlwsProducerState = finalState }
               , (leoBuildAttempted ops finalBatch allOutcomes, eventIssues)
               )

flushPendingControls
  :: ListenerEngineOps result
  -> MVar MIDIListenerWorkerState
  -> MIDIFlushReason
  -> IO ([SessionCommand], [ListenerSubmissionOutcome])
flushPendingControls ops stateVar reason =
  modifyMVar stateVar $ \workerState -> do
    let commands = pendingControlCommands (mlwsPending workerState)
    if null commands
       then pure (workerState, ([], []))
       else do
         outcomes <- traverse (leoSubmit ops) commands
         let acceptedAll = all outcomeAccepted outcomes
             acceptedCount = length (filter outcomeAccepted outcomes)
             pending' =
               if acceptedAll
                  then M.empty
                  else mlwsPending workerState
             stats' =
               addFlush reason acceptedCount (mlwsStats workerState)
             workerState' = workerState
               { mlwsPending =
                   pending'
               , mlwsStats =
                   stats'
               }
         pure (workerState', (commands, outcomes))

mergePendingControls
  :: [SessionCommand]
  -> M.Map PendingControlKey Value
  -> (M.Map PendingControlKey Value, Int)
mergePendingControls commands pending0 =
  foldl' step (pending0, 0) commands
  where
    step (pending, count) cmd = case cmd of
      CmdControlWrite vkey target value ->
        let key = (vkey, target)
            count' =
              if M.member key pending
                 then count + 1
                 else count
        in (M.insert key value pending, count')
      _ ->
        (pending, count)

pendingControlCommands :: M.Map PendingControlKey Value -> [SessionCommand]
pendingControlCommands pending =
  [ CmdControlWrite vkey target value
  | ((vkey, target), value) <- M.toList pending
  ]

workerCoalescingStats
  :: MIDIListenerWorkerState
  -> SessionMIDIListenerCoalescingStats
workerCoalescingStats workerState =
  (mlwsStats workerState)
    { smlcsPendingCount = M.size (mlwsPending workerState)
    }

addCoalesced
  :: Int
  -> SessionMIDIListenerCoalescingStats
  -> SessionMIDIListenerCoalescingStats
addCoalesced n stats =
  stats { smlcsCoalescedCount = smlcsCoalescedCount stats + n }

addFlush
  :: MIDIFlushReason
  -> Int
  -> SessionMIDIListenerCoalescingStats
  -> SessionMIDIListenerCoalescingStats
addFlush reason n stats =
  stats
    { smlcsFlushedCount =
        smlcsFlushedCount stats + n
    , smlcsBarrierFlushCount =
        smlcsBarrierFlushCount stats
        + if reason == MIDIFlushFence then 1 else 0
    }

isControlWrite :: SessionCommand -> Bool
isControlWrite command = case command of
  CmdControlWrite _ _ _ ->
    True
  _ ->
    False

outcomeAccepted :: ListenerSubmissionOutcome -> Bool
outcomeAccepted = \case
  LsoEnqueued result -> case sfierResult result of
    SessionEnqueued {} ->
      True
    SessionEnqueueRejected {} ->
      False
  LsoPolicyRejected _ ->
    False
