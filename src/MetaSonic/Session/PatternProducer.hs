{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.PatternProducer
-- Description : Pattern-to-session producer bridge vocabulary.
--
-- This module starts Session Prep H by defining the type surface for a
-- pure Pattern producer bridge. The bridge sits above
-- 'MetaSonic.Session.Queue' and turns 'MetaSonic.Pattern.PatternEvent'
-- values into queued 'MetaSonic.Session.Command.SessionCommand'
-- values in later slices.
--
-- This module is Haskell-only. It does not own a 'SessionOwner', does
-- not drain queues, does not create threads, and does not define a
-- realtime clock.
--
-- See [notes/2026-05-12-session-prep-h-pattern-producer.md].

module MetaSonic.Session.PatternProducer
  ( -- * Options
    PatternProducerOptions (..)

    -- * Producer state
  , PatternProducerState

    -- * Setup issues
  , PatternProducerIssue (..)

    -- * Enqueue reporting
  , PatternEnqueueItem (..)
  , PatternEnqueueResult (..)
  , PatternEnqueueOutcome (..)
  ) where

import           Control.DeepSeq             (NFData)
import           Data.Text                   (Text)
import           GHC.Generics                (Generic)

import           MetaSonic.Pattern           (PatternEvent, SamplePos)
import           MetaSonic.Session.Command   (SessionCommand)
import           MetaSonic.Session.Queue     (ProducerId,
                                              SessionCommandQueue,
                                              SessionEnqueueResult)


-- | Construction options for the pure Pattern producer bridge.
--
-- The default value lands with the construction slice. Production
-- callers with a real timing model should choose 'ppoBlockFrames'
-- explicitly.
data PatternProducerOptions = PatternProducerOptions
  { ppoProducerName :: !Text
    -- ^ Free-form diagnostic producer name. The default will be
    -- @"pattern"@.
  , ppoBlockFrames  :: !Int
    -- ^ Deterministic sample-frame width for one generated Pattern
    -- range. Must be positive once construction is implemented.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Hidden pure producer state.
--
-- The constructor stays private so callers cannot fabricate cursor or
-- backlog combinations. Construction and enqueue operations land in
-- later Prep H slices.
data PatternProducerState = PatternProducerState
  { ppsProducer :: !ProducerId
  , ppsBlockFrames :: !Int
  , ppsNextStart :: !SamplePos
  , ppsBacklog :: ![(SamplePos, PatternEvent)]
    -- ^ Events generated but not yet accepted by the queue, in
    -- Pattern emit order. Bounded by one expanded block; retried
    -- head-first before the next range is generated.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Producer setup failures.
data PatternProducerIssue
  = PpiInvalidBlockFrames !Int
    -- ^ 'ppoBlockFrames' was zero or negative.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | One Pattern event attempted against the producer queue.
data PatternEnqueueItem = PatternEnqueueItem
  { peiSamplePos :: !SamplePos
    -- ^ Original Pattern sample position.
  , peiEvent     :: !PatternEvent
    -- ^ Original Pattern event.
  , peiCommand   :: !SessionCommand
    -- ^ Command produced by 'MetaSonic.Session.Command.fromPatternEvent'.
  , peiResult    :: !SessionEnqueueResult
    -- ^ Queue result for this attempted event.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Summary of one Pattern producer enqueue call.
data PatternEnqueueResult = PatternEnqueueResult
  { perItems      :: ![PatternEnqueueItem]
    -- ^ Attempted events in Pattern order.
  , perBacklogged :: !Int
    -- ^ Number of events retained for retry after this call.
  , perNextStart  :: !SamplePos
    -- ^ Producer cursor after this call. Backlog retry calls do not
    -- advance this cursor.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Named return value for the producer state, queue, and report.
data PatternEnqueueOutcome = PatternEnqueueOutcome
  { peoState  :: !PatternProducerState
  , peoQueue  :: !SessionCommandQueue
  , peoResult :: !PatternEnqueueResult
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)
