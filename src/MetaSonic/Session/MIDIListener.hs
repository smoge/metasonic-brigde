{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.MIDIListener
-- Description : Session-backed decoded MIDI listener.
--
-- This module is the session-facing MIDI listener substrate. It owns a
-- bracketed worker thread over an injected decoded-event source, keeps
-- producer-local MIDI note and control-coalescing state, and enqueues
-- commands into a 'SessionFanInHost' through
-- 'MetaSonic.Session.MIDIProducer'.
--
-- It deliberately does not open PortMIDI devices, choose a live clock,
-- define channel remapping/splits, arbitrate against OSC beyond the
-- existing FIFO fan-in queue, or repair a diverged owner. Real device
-- ownership should be added later as a source behind this decoded-event
-- boundary.

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

    -- * Bracketed listener
  , withSessionMIDIListener
  , withSessionMIDIListenerHooks
  , withSessionMIDIListenerHooksAndOptions
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
import           MetaSonic.Session.Command      (SessionCommand (..))
import           MetaSonic.Session.FanIn        (SessionFanInEnqueueResult (..),
                                                 SessionFanInHost,
                                                 enqueueSessionFanInCommand)
import           MetaSonic.Session.MIDIProducer (MIDIProducerCommandBatch (..),
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
readSessionMIDIListenerState
  :: SessionMIDIListener
  -> IO MIDIProducerState
readSessionMIDIListenerState listener =
  mlwsProducerState <$> readMVar (smlWorkerState listener)

-- | Read producer-local control coalescing counters.
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
    -- ^ Pending control writes accepted by fan-in during coalescer
    -- flushes.
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
  | SmliFenceDroppedForFlushFailure !MIDIProducerEvent !Int
    -- ^ A non-control-write fence event was decoded, but pending
    -- coalesced control writes had to flush first and at least one
    -- flush enqueue was rejected. The fence commands were not
    -- submitted, pending controls remain available for retry, and
    -- the producer state stays at the pre-event value. The 'Int' is
    -- the number of rejected flush enqueues.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Session-backed MIDI listener hooks. Production callers can discard
-- both hooks; tests use them for synchronization and issue capture.
data SessionMIDIListenerHooks = SessionMIDIListenerHooks
  { smlhOnProducerResult :: !(MIDIProducerEnqueueResult -> IO ())
    -- ^ Called after every source event has gone through the MIDI
    -- producer adapter.
  , smlhOnIssue          :: !(SessionMIDIListenerIssue -> IO ())
    -- ^ Called for MIDI producer rejections and fan-in enqueue
    -- rejections.
  }

-- | Default hooks: discard diagnostics and producer results.
defaultSessionMIDIListenerHooks :: SessionMIDIListenerHooks
defaultSessionMIDIListenerHooks = SessionMIDIListenerHooks
  { smlhOnProducerResult = \_ -> pure ()
  , smlhOnIssue          = \_ -> pure ()
  }

-- | Run a worker over a decoded MIDI source for the body lifetime.
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
-- when a later flush submits them. EOF and teardown flushes only report
-- enqueue issues; they do not call 'smlhOnProducerResult'.
--
-- If a fence-triggered flush is rejected, the fence commands are not
-- enqueued and 'SmliFenceDroppedForFlushFailure' is reported.
-- Producer options, including channel filtering, are captured for the
-- worker lifetime; use a new listener bracket for a new policy.
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
  hooks listenerOpts producerOpts initialState source host body = do
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
        (midiListenerLoop hooks producerOpts source host stateVar)
      flusher <- case smloTimedControlFlushUsec listenerOpts of
        Nothing ->
          pure Nothing
        Just usec ->
          Just <$> forkIO
            (midiListenerTimedFlushLoop hooks producerOpts host stateVar
                                        (max 1 usec))
      pure (reader, flusher)

    stopWorkers stateVar (reader, flusher) = do
      killThread reader
      mapM_ killThread flusher
      (commands, results) <-
        flushPendingControls producerOpts host stateVar MIDIFlushEOF
      reportEnqueueIssues hooks commands results

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

data MIDIEventAction
  = MIDIEventRejected !MIDIProducerEnqueueResult
  | MIDIEventDeferred !MIDIProducerEnqueueResult
  | MIDIEventFence !MIDIProducerState !MIDIProducerCommandBatch

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
  :: SessionMIDIListenerHooks
  -> MIDIProducerOptions
  -> MIDIListenerSource
  -> SessionFanInHost
  -> MVar MIDIListenerWorkerState
  -> IO ()
midiListenerLoop hooks producerOpts source host stateVar =
  loop
  where
    loop = do
      mEvent <- mlsReadEvent source
      case mEvent of
        Nothing -> do
          (commands, results) <-
            flushPendingControls producerOpts host stateVar MIDIFlushEOF
          reportEnqueueIssues hooks commands results
        Just event -> do
          (result, eventIssues) <-
            processMIDIEvent producerOpts host stateVar event
          smlhOnProducerResult hooks result
          forM_ eventIssues (smlhOnIssue hooks)
          reportIssues result
          loop

    reportIssues result = case result of
      MIDIProducerRejected issue _ ->
        smlhOnIssue hooks (SmliProducerRejected issue)
      MIDIProducerEnqueueAttempted batch enqueueResults ->
        reportEnqueueIssues hooks (mpcbCommands batch) enqueueResults

midiListenerTimedFlushLoop
  :: SessionMIDIListenerHooks
  -> MIDIProducerOptions
  -> SessionFanInHost
  -> MVar MIDIListenerWorkerState
  -> Int
  -> IO ()
midiListenerTimedFlushLoop hooks producerOpts host stateVar usec =
  forever $ do
    threadDelay usec
    (commands, results) <-
      flushPendingControls producerOpts host stateVar MIDIFlushTimed
    reportEnqueueIssues hooks commands results

reportEnqueueIssues
  :: SessionMIDIListenerHooks
  -> [SessionCommand]
  -> [SessionFanInEnqueueResult]
  -> IO ()
reportEnqueueIssues hooks commands enqueueResults =
  forM_ (zip commands enqueueResults) $
    \(cmd, enqueueResult) ->
      case sfierResult enqueueResult of
        SessionEnqueued _ ->
          pure ()
        SessionEnqueueRejected _ _ issue ->
          smlhOnIssue hooks (SmliEnqueueRejected cmd issue)

processMIDIEvent
  :: MIDIProducerOptions
  -> SessionFanInHost
  -> MVar MIDIListenerWorkerState
  -> MIDIProducerEvent
  -> IO (MIDIProducerEnqueueResult, [SessionMIDIListenerIssue])
processMIDIEvent producerOpts host stateVar event = do
  action <- modifyMVar stateVar $ \workerState ->
    let st = mlwsProducerState workerState
    in case decodeMIDISessionCommands producerOpts st event of
      Left issue ->
        pure
          ( workerState
          , MIDIEventRejected (MIDIProducerRejected issue st)
          )
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
            in pure
                ( workerState'
                , MIDIEventDeferred
                    (MIDIProducerEnqueueAttempted batch [])
                )
        | otherwise ->
            pure (workerState, MIDIEventFence st batch)
  case action of
    MIDIEventRejected result ->
      pure (result, [])
    MIDIEventDeferred result ->
      pure (result, [])
    MIDIEventFence oldState batch -> do
      (flushCommands, flushResults) <-
        flushPendingControls producerOpts host stateVar MIDIFlushFence
      if not (all enqueueAccepted flushResults)
         then do
           let rejectedCount =
                 length (filter (not . enqueueAccepted) flushResults)
               result =
                 MIDIProducerEnqueueAttempted
                   MIDIProducerCommandBatch
                     { mpcbCommands =
                         flushCommands
                     , mpcbState =
                         oldState
                     }
                   flushResults
           pure
             ( result
             , [SmliFenceDroppedForFlushFailure event rejectedCount]
             )
         else do
           eventResults <- traverse
             (\cmd -> enqueueSessionFanInCommand (midiProducerId producerOpts)
                                                 cmd
                                                 host)
             (mpcbCommands batch)
           let allResults = flushResults <> eventResults
               allCommands = flushCommands <> mpcbCommands batch
               finalState =
                 if all enqueueAccepted eventResults
                    then mpcbState batch
                    else oldState
               finalBatch = MIDIProducerCommandBatch
                 { mpcbCommands =
                     allCommands
                 , mpcbState =
                     finalState
                 }
           modifyMVar stateVar $ \workerState ->
             pure
               ( workerState { mlwsProducerState = finalState }
               , (MIDIProducerEnqueueAttempted finalBatch allResults, [])
               )

flushPendingControls
  :: MIDIProducerOptions
  -> SessionFanInHost
  -> MVar MIDIListenerWorkerState
  -> MIDIFlushReason
  -> IO ([SessionCommand], [SessionFanInEnqueueResult])
flushPendingControls producerOpts host stateVar reason =
  modifyMVar stateVar $ \workerState -> do
    let commands = pendingControlCommands (mlwsPending workerState)
    if null commands
       then pure (workerState, ([], []))
       else do
         results <- traverse
           (\cmd -> enqueueSessionFanInCommand (midiProducerId producerOpts)
                                               cmd
                                               host)
           commands
         let acceptedAll = all enqueueAccepted results
             acceptedCount = length (filter enqueueAccepted results)
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
         pure (workerState', (commands, results))

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

enqueueAccepted :: SessionFanInEnqueueResult -> Bool
enqueueAccepted result = case sfierResult result of
  SessionEnqueued {} ->
    True
  SessionEnqueueRejected {} ->
    False
