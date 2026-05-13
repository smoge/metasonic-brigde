{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.Queue
-- Description : Producer-ingress queue vocabulary for session owners.
--
-- This module defines Session Prep G's bounded producer queue. It sits
-- above 'MetaSonic.Session.Owner' and below the concrete Pattern
-- bridge, the generic fan-in host, and future OSC/MIDI/UI producer
-- adapters.
--
-- The queue modeled here is a Haskell-side producer-intent queue. It
-- is not the C++ realtime ABI queue, is not audio-thread visible, and
-- does not enforce thread safety.
--
-- See [notes/2026-05-12-session-prep-g-producer-queue.md].

module MetaSonic.Session.Queue
  ( -- * Producers
    ProducerKind (..)
  , ProducerId (..)

    -- * Queue entries
  , CommandSequence (..)
  , QueuedSessionCommand (..)

    -- * Queue state and options
  , SessionCommandQueue
  , SessionQueueOptions (..)
  , defaultSessionQueueOptions

    -- * Enqueue outcomes
  , SessionQueueSetupIssue (..)
  , SessionEnqueueIssue (..)
  , SessionEnqueueResult (..)

    -- * Drain outcomes
  , SessionDrainItem (..)
  , SessionDrainResult (..)

    -- * Operations
  , newSessionCommandQueue
  , enqueueSessionCommand
  , drainSessionCommandQueue
  , queuedCommandCount
  ) where

import           Control.DeepSeq           (NFData)
import           Data.Text                 (Text)
import           Data.Word                 (Word64)
import           GHC.Generics              (Generic)

import           MetaSonic.Session.Command (SessionCommand)
import           MetaSonic.Session.Owner   (SessionOwner,
                                            SessionOwnerDivergence,
                                            SessionOwnerStepResult (..),
                                            stepSessionOwner)


-- | Logical producer class for diagnostic attribution.
--
-- The enum is closed in v1. A future concrete external adapter can add
-- another constructor once there is a real use case. 'Ord' is derived
-- to support map-keyed per-producer diagnostics in later slices.
data ProducerKind
  = ProducerPattern
  | ProducerOSC
  | ProducerMIDI
  | ProducerUI
  | ProducerTest
  deriving stock    (Eq, Ord, Show, Generic)
  deriving anyclass (NFData)

-- | Diagnostic identity for a command producer.
--
-- 'producerName' is free-form diagnostic text. It is not validated and
-- has no authorization meaning.
data ProducerId = ProducerId
  { producerKind :: !ProducerKind
  , producerName :: !Text
  } deriving stock    (Eq, Ord, Show, Generic)
    deriving anyclass (NFData)

-- | Per-queue monotonically increasing command sequence number.
--
-- Sequence values are not globally unique across queue lifetimes.
newtype CommandSequence = CommandSequence
  { unCommandSequence :: Word64
  } deriving stock    (Eq, Ord, Show, Generic)
    deriving anyclass (NFData)

-- | One accepted command in the producer queue.
data QueuedSessionCommand = QueuedSessionCommand
  { qscSequence :: !CommandSequence
  , qscProducer :: !ProducerId
  , qscCommand  :: !SessionCommand
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Bounded producer-intent queue state.
--
-- The constructor is hidden so callers cannot fabricate invalid
-- capacity, sequence, or pending-command combinations.
data SessionCommandQueue = SessionCommandQueue
  { scqOptions      :: !SessionQueueOptions
  , scqNextSequence :: !CommandSequence
    -- Stored as a head-first list. Enqueue appends at the tail (O(n)
    -- for capacity-bounded queues). The hidden constructor lets this
    -- move to a sequence if profiling demands it.
  , scqPending      :: ![QueuedSessionCommand]
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Queue construction options.
data SessionQueueOptions = SessionQueueOptions
  { sqoCapacity :: !Int
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Conservative test/demo defaults for producer ingress.
defaultSessionQueueOptions :: SessionQueueOptions
defaultSessionQueueOptions = SessionQueueOptions
  { sqoCapacity = 128
  }

-- | Queue construction failures.
data SessionQueueSetupIssue
  = SqsiInvalidCapacity !Int
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Enqueue-time failures.
data SessionEnqueueIssue
  = SeiQueueFull !Int
    -- ^ The queue was already at the configured capacity.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Result of attempting to enqueue one producer command.
data SessionEnqueueResult
  = SessionEnqueued !QueuedSessionCommand
  | SessionEnqueueRejected !ProducerId !SessionCommand !SessionEnqueueIssue
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | One owner-step result paired with the queued command that produced it.
data SessionDrainItem = SessionDrainItem
  { sdiQueued :: !QueuedSessionCommand
  , sdiResult :: !SessionOwnerStepResult
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Result of draining queued commands into a session owner.
data SessionDrainResult = SessionDrainResult
  { sdrItems     :: ![SessionDrainItem]
  , sdrRemaining :: !Int
  , sdrStopped   :: !(Maybe SessionOwnerDivergence)
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Construct an empty bounded producer queue.
newSessionCommandQueue
  :: SessionQueueOptions
  -> Either SessionQueueSetupIssue SessionCommandQueue
newSessionCommandQueue opts
  | sqoCapacity opts <= 0 =
      Left (SqsiInvalidCapacity (sqoCapacity opts))
  | otherwise =
      Right SessionCommandQueue
        { scqOptions      = opts
        , scqNextSequence = CommandSequence 0
        , scqPending      = []
        }

-- | Number of commands currently waiting in the queue.
queuedCommandCount :: SessionCommandQueue -> Int
queuedCommandCount =
  length . scqPending

-- | Enqueue one producer command.
--
-- The returned queue is always usable. On rejection it is the original
-- queue unchanged.
enqueueSessionCommand
  :: ProducerId
  -> SessionCommand
  -> SessionCommandQueue
  -> (SessionCommandQueue, SessionEnqueueResult)
enqueueSessionCommand producer cmd queue
  | length (scqPending queue) >= sqoCapacity (scqOptions queue) =
      ( queue
      , SessionEnqueueRejected
          producer
          cmd
          (SeiQueueFull (sqoCapacity (scqOptions queue)))
      )
  | otherwise =
      let queued = QueuedSessionCommand
            { qscSequence = scqNextSequence queue
            , qscProducer = producer
            , qscCommand  = cmd
            }
          queue' = queue
            { scqNextSequence =
                nextCommandSequence (scqNextSequence queue)
            , scqPending =
                scqPending queue ++ [queued]
            }
      in (queue', SessionEnqueued queued)

-- | Drain queued commands into a single-threaded session owner.
--
-- Commands already stepped are removed from the returned queue. If the
-- owner diverges or is already blocked, the unprocessed tail remains
-- queued in its original order.
drainSessionCommandQueue
  :: SessionOwner
  -> SessionCommandQueue
  -> IO (SessionCommandQueue, SessionDrainResult)
drainSessionCommandQueue owner queue =
  go [] (scqPending queue)
  where
    go drainedRev [] =
      pure
        ( queue { scqPending = [] }
        , SessionDrainResult
            { sdrItems     = reverse drainedRev
            , sdrRemaining = 0
            , sdrStopped   = Nothing
            }
        )
    go drainedRev (queued : rest) = do
      result <- stepSessionOwner owner (qscCommand queued)
      let item = SessionDrainItem
            { sdiQueued = queued
            , sdiResult = result
            }
          drainedRev' = item : drainedRev
      case drainStopReason result of
        Just reason ->
          pure
            ( queue { scqPending = rest }
            , SessionDrainResult
                { sdrItems     = reverse drainedRev'
                , sdrRemaining = length rest
                , sdrStopped   = Just reason
                }
            )
        Nothing ->
          go drainedRev' rest

nextCommandSequence :: CommandSequence -> CommandSequence
nextCommandSequence (CommandSequence n) =
  CommandSequence (n + 1)

drainStopReason :: SessionOwnerStepResult -> Maybe SessionOwnerDivergence
drainStopReason result = case result of
  SessionOwnerDivergedNow _ reason ->
    Just reason
  SessionOwnerBlocked reason ->
    Just reason
  _ ->
    Nothing
