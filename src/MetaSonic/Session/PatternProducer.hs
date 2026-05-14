{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.PatternProducer
-- Description : Pattern-to-session producer bridge vocabulary.
--
-- This module defines Session Prep H's pure Pattern producer bridge.
-- The bridge sits above
-- 'MetaSonic.Session.Queue' and turns 'MetaSonic.Pattern.PatternEvent'
-- values into queued 'MetaSonic.Session.Command.SessionCommand'
-- values.
--
-- This module is Haskell-only. It does not own a 'SessionOwner', does
-- not drain queues, does not create threads, and does not define a
-- realtime clock. Callers can use the pure queue helper or explicitly
-- choose the service-owned arbitration path.
--
-- See [notes/2026-05-12-u-session-prep-h-pattern-producer.md].

module MetaSonic.Session.PatternProducer
  ( -- * Options
    PatternProducerOptions (..)
  , defaultPatternProducerOptions

    -- * Producer state
  , PatternProducerState

    -- * Setup issues
  , PatternProducerIssue (..)

    -- * Enqueue reporting
  , PatternEnqueueItem (..)
  , PatternEnqueueResult (..)
  , PatternEnqueueOutcome (..)
  , PatternArbitratedEnqueueItem (..)
  , PatternArbitratedEnqueueResult (..)
  , PatternArbitratedEnqueueOutcome (..)

    -- * Operations
  , newPatternProducerState
  , enqueuePatternBlock
  , enqueueArbitratedPatternBlock
  , isBacklogged
  ) where

import           Control.DeepSeq           (NFData)
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import           GHC.Generics              (Generic)

import           MetaSonic.Pattern         (Pattern, PatternEvent,
                                            SamplePos (..), SampleRange (..),
                                            expandPattern)
import           MetaSonic.Session.ArbitrationGateway
                                           (SessionArbitrationGatewayEnqueueResult (..))
import           MetaSonic.Session.Command (SessionCommand, fromPatternEvent)
import           MetaSonic.Session.FanIn   (SessionFanInEnqueueResult (..))
import           MetaSonic.Session.FanInService
                                           (SessionFanInService,
                                            enqueueArbitratedSessionFanInServiceCommand)
import           MetaSonic.Session.Queue   (ProducerId (..),
                                            ProducerKind (ProducerPattern),
                                            SessionCommandQueue,
                                            SessionEnqueueResult (..),
                                            enqueueSessionCommand)


-- | Construction options for the pure Pattern producer bridge.
--
-- Production callers with a real timing model should choose
-- 'ppoBlockFrames' explicitly.
data PatternProducerOptions = PatternProducerOptions
  { ppoProducerName :: !Text
    -- ^ Free-form diagnostic producer name. The default will be
    -- @"pattern"@.
  , ppoBlockFrames  :: !Int
    -- ^ Deterministic sample-frame width for one generated Pattern
    -- range. Must be positive once construction is implemented.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Conservative test/demo defaults for Pattern producer ingress.
defaultPatternProducerOptions :: PatternProducerOptions
defaultPatternProducerOptions = PatternProducerOptions
  { ppoProducerName = T.pack "pattern"
  , ppoBlockFrames  = 64
  }

-- | Hidden pure producer state.
--
-- The constructor stays private so callers cannot fabricate cursor or
-- backlog combinations.
data PatternProducerState = PatternProducerState
  { ppsProducer    :: !ProducerId
  , ppsBlockFrames :: !Int
  , ppsNextStart   :: !SamplePos
  , ppsBacklog     :: ![(SamplePos, PatternEvent)]
    -- ^ Events generated but not yet accepted by the queue, in
    -- Pattern emit order. Bounded by one expanded block; retried
    -- head-first before the next range is generated.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Check if the producer has events waiting to be retried.
isBacklogged :: PatternProducerState -> Bool
isBacklogged = not . null . ppsBacklog

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

-- | One Pattern event attempted against the service-owned arbitration
-- path.
data PatternArbitratedEnqueueItem = PatternArbitratedEnqueueItem
  { paeiSamplePos :: !SamplePos
    -- ^ Original Pattern sample position.
  , paeiEvent     :: !PatternEvent
    -- ^ Original Pattern event.
  , paeiCommand   :: !SessionCommand
    -- ^ Command produced by 'MetaSonic.Session.Command.fromPatternEvent'.
  , paeiResult    :: !SessionArbitrationGatewayEnqueueResult
    -- ^ Service-owned arbitration/fan-in result for this attempted
    -- event.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Summary of one service-backed Pattern producer enqueue call.
data PatternArbitratedEnqueueResult = PatternArbitratedEnqueueResult
  { paerItems      :: ![PatternArbitratedEnqueueItem]
    -- ^ Attempted events in Pattern order.
  , paerBacklogged :: !Int
    -- ^ Number of events retained for retry after this call.
  , paerNextStart  :: !SamplePos
    -- ^ Producer cursor after this call. Backlog retry calls do not
    -- advance this cursor.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Named return value for the producer state and service-backed
-- enqueue report.
data PatternArbitratedEnqueueOutcome = PatternArbitratedEnqueueOutcome
  { paeoState  :: !PatternProducerState
  , paeoResult :: !PatternArbitratedEnqueueResult
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Construct an initial Pattern producer state.
newPatternProducerState
  :: PatternProducerOptions
  -> Either PatternProducerIssue PatternProducerState
newPatternProducerState opts
  | ppoBlockFrames opts <= 0 =
      Left (PpiInvalidBlockFrames (ppoBlockFrames opts))
  | otherwise =
      Right PatternProducerState
        { ppsProducer =
            ProducerId ProducerPattern (ppoProducerName opts)
        , ppsBlockFrames =
            ppoBlockFrames opts
        , ppsNextStart =
            SamplePos 0
        , ppsBacklog =
            []
        }

-- | Enqueue one Pattern block, or retry one pending backlog.
--
-- Calls that start with backlog retry only that backlog. They do not
-- generate a new Pattern range in the same call, even if the backlog
-- fully drains. This raw queue helper does not consult a service-owned
-- arbitration gateway; callers that need consistent service-level
-- policy enforcement should use 'enqueueArbitratedPatternBlock'.
enqueuePatternBlock
  :: Pattern
  -> PatternProducerState
  -> SessionCommandQueue
  -> PatternEnqueueOutcome
enqueuePatternBlock pat state queue =
  let (events, stateWithCursor) = eventsForCall pat state
      (state', queue', items) =
        enqueueEvents stateWithCursor queue events
      result = PatternEnqueueResult
        { perItems      = items
        , perBacklogged = length (ppsBacklog state')
        , perNextStart  = ppsNextStart state'
        }
  in PatternEnqueueOutcome
       { peoState  = state'
       , peoQueue  = queue'
       , peoResult = result
       }

-- | Enqueue one Pattern block through the explicit service-owned
-- arbitration path.
--
-- This is the Pattern counterpart to the OSC/UI explicit arbitrated
-- helpers. Existing Pattern callers should keep using
-- 'enqueuePatternBlock', 'MetaSonic.Session.Runner.stepPatternSession',
-- or 'MetaSonic.Session.Host.stepPatternSessionHost' unless the
-- surrounding session deliberately opts into 'SessionFanInService'
-- arbitration. With default service options this still preserves FIFO
-- behavior; with configured gateway options, policy rejection stops the
-- current Pattern call at the rejected event and retains that event plus
-- the remaining tail as backlog for a later retry.
enqueueArbitratedPatternBlock
  :: Pattern
  -> PatternProducerState
  -> SessionFanInService
  -> IO PatternArbitratedEnqueueOutcome
enqueueArbitratedPatternBlock pat state service = do
  let (events, stateWithCursor) = eventsForCall pat state
  (state', items) <-
    enqueueArbitratedEvents stateWithCursor service events
  let result = PatternArbitratedEnqueueResult
        { paerItems      = items
        , paerBacklogged = length (ppsBacklog state')
        , paerNextStart  = ppsNextStart state'
        }
  pure PatternArbitratedEnqueueOutcome
    { paeoState  = state'
    , paeoResult = result
    }

eventsForCall
  :: Pattern
  -> PatternProducerState
  -> ([(SamplePos, PatternEvent)], PatternProducerState)
eventsForCall pat state =
  case ppsBacklog state of
    [] ->
      let start = ppsNextStart state
          end = addSampleFrames (ppsBlockFrames state) start
          events = expandPattern pat (SampleRange start end)
          -- The cursor advances once when the range is generated, not
          -- when every event is accepted. A partial enqueue rejection
          -- leaves backlog inside this consumed range; retry calls must
          -- not roll the cursor back.
      in (events, state { ppsNextStart = end })
    backlog ->
      (backlog, state)

enqueueEvents
  :: PatternProducerState
  -> SessionCommandQueue
  -> [(SamplePos, PatternEvent)]
  -> (PatternProducerState, SessionCommandQueue, [PatternEnqueueItem])
enqueueEvents state queue events =
  let (finalBacklog, finalQueue, items) = go [] queue events
  in (state { ppsBacklog = finalBacklog }, finalQueue, items)
  where
    go itemsRev currentQueue [] = ([], currentQueue, reverse itemsRev)
    go itemsRev currentQueue ((samplePos, event) : rest) =
      let command = fromPatternEvent event
          (queue', res) =
            enqueueSessionCommand (ppsProducer state) command currentQueue
          item = PatternEnqueueItem
            { peiSamplePos = samplePos
            , peiEvent     = event
            , peiCommand   = command
            , peiResult    = res
            }
      in case res of
           SessionEnqueued _ ->
             go (item : itemsRev) queue' rest
           SessionEnqueueRejected {} ->
             ((samplePos, event) : rest, queue', reverse (item : itemsRev))

enqueueArbitratedEvents
  :: PatternProducerState
  -> SessionFanInService
  -> [(SamplePos, PatternEvent)]
  -> IO (PatternProducerState, [PatternArbitratedEnqueueItem])
enqueueArbitratedEvents state service events =
  go [] events
  where
    go itemsRev [] =
      pure (state { ppsBacklog = [] }, reverse itemsRev)
    go itemsRev ((samplePos, event) : rest) = do
      let command = fromPatternEvent event
      res <-
        enqueueArbitratedSessionFanInServiceCommand
          (ppsProducer state)
          command
          service
      let item = PatternArbitratedEnqueueItem
            { paeiSamplePos = samplePos
            , paeiEvent     = event
            , paeiCommand   = command
            , paeiResult    = res
            }
      case res of
        SagArbitrationRejected {} ->
          pure
            ( state { ppsBacklog = (samplePos, event) : rest }
            , reverse (item : itemsRev)
            )
        SagEnqueueAttempted fanInResult ->
          case sfierResult fanInResult of
            SessionEnqueued {} ->
              go (item : itemsRev) rest
            SessionEnqueueRejected {} ->
              pure
                ( state { ppsBacklog = (samplePos, event) : rest }
                , reverse (item : itemsRev)
                )

addSampleFrames :: Int -> SamplePos -> SamplePos
addSampleFrames n (SamplePos start) =
  SamplePos (start + n)
