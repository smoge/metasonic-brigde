{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.Runner
-- Description : Single-threaded scripted Pattern-session runner.
--
-- This module promotes the producer/queue/owner composition that
-- Prep H tests use inline into one named library boundary. It does
-- not create threads, does not consult a wall clock, does not drive
-- a background drain loop, and does not own the 'SessionOwner'
-- bracket. It composes Prep F, Prep G, and Prep H.
--
-- See [notes/2026-05-13-session-prep-i-scripted-runner.md].

module MetaSonic.Session.Runner
  ( -- * Step result
    PatternRunnerStepResult (..)

    -- * Operations
  , stepPatternSession
  ) where

import           Control.DeepSeq                 (NFData)
import           GHC.Generics                    (Generic)

import           MetaSonic.Pattern               (Pattern)
import           MetaSonic.Session.Owner         (SessionOwner)
import           MetaSonic.Session.PatternProducer
                                                 (PatternEnqueueOutcome (..),
                                                  PatternEnqueueResult,
                                                  PatternProducerState,
                                                  enqueuePatternBlock)
import           MetaSonic.Session.Queue         (SessionCommandQueue,
                                                  SessionDrainResult,
                                                  drainSessionCommandQueue)


-- | One observable scripted-runner step.
--
-- 'prsState' and 'prsQueue' are the producer state and queue the
-- caller should feed into the next 'stepPatternSession' call.
-- 'prsEnqueue' and 'prsDrain' are the two sub-reports from this
-- step's enqueue and drain calls.
data PatternRunnerStepResult = PatternRunnerStepResult
  { prsState   :: !PatternProducerState
  , prsQueue   :: !SessionCommandQueue
  , prsEnqueue :: !PatternEnqueueResult
  , prsDrain   :: !SessionDrainResult
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Run one scripted Pattern-session step.
--
-- Order is fixed: enqueue one block or backlog retry, then drain the
-- resulting queue once into the owner. The owner bracket is not
-- managed here; callers compose this with 'withSessionOwner' (or any
-- owner-lifetime story they prefer).
--
-- Divergence is reported through 'prsDrain', not by throwing. Later
-- calls still type-check; the drain will simply mark every item as
-- blocked until the owner is rebuilt.
stepPatternSession
  :: Pattern
  -> PatternProducerState
  -> SessionCommandQueue
  -> SessionOwner
  -> IO PatternRunnerStepResult
stepPatternSession pat state queue owner = do
  let outcome = enqueuePatternBlock pat state queue
  (queue', drain) <- drainSessionCommandQueue owner (peoQueue outcome)
  pure PatternRunnerStepResult
    { prsState   = peoState outcome
    , prsQueue   = queue'
    , prsEnqueue = peoResult outcome
    , prsDrain   = drain
    }
