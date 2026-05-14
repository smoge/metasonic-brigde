{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.Host
-- Description : Thread-safe Pattern session host shell.
--
-- This module defines Session Prep J's first serialized host boundary
-- around the Prep F/G/H/I pieces. It owns the 'SessionOwner' bracket
-- and stores Pattern producer plus queue state behind an 'MVar' so
-- callers can safely issue synchronous Pattern steps from multiple
-- Haskell threads.
--
-- It is still caller-driven. It does not create a background worker,
-- does not define a realtime clock, does not add concrete OSC/MIDI/UI
-- adapters, and does not define its own hot-swap recovery policy; it
-- inherits owner/adapter behavior.
--
-- See [notes/2026-05-13-c-session-prep-j-thread-safe-host.md].

module MetaSonic.Session.Host
  ( -- * Host
    PatternSessionHost

    -- * Options
  , PatternSessionHostOptions (..)
  , defaultPatternSessionHostOptions

    -- * Setup issues
  , PatternSessionHostSetupIssue (..)

    -- * Snapshot
  , PatternSessionHostSnapshot (..)

    -- * Scoped host
  , withPatternSessionHost
  , stepPatternSessionHost
  , readPatternSessionHost
  ) where

import           Control.Concurrent.MVar         (MVar, modifyMVar, newMVar,
                                                  withMVar)
import           Control.DeepSeq                 (NFData)
import           GHC.Generics                    (Generic)

import           MetaSonic.Bridge.Templates      (TemplateGraph)
import           MetaSonic.Pattern               (Pattern)
import           MetaSonic.Session.AdapterIssue  (SessionAdapterSetupIssue)
import           MetaSonic.Session.Owner         (SessionOwner,
                                                  SessionOwnerOptions,
                                                  SessionOwnerStatus,
                                                  defaultSessionOwnerOptions,
                                                  sessionOwnerState,
                                                  sessionOwnerStatus,
                                                  withSessionOwner)
import           MetaSonic.Session.PatternProducer
                                                 (PatternProducerIssue,
                                                  PatternProducerOptions,
                                                  PatternProducerState,
                                                  defaultPatternProducerOptions,
                                                  isBacklogged,
                                                  newPatternProducerState)
import           MetaSonic.Session.Queue         (SessionCommandQueue,
                                                  SessionQueueOptions,
                                                  SessionQueueSetupIssue,
                                                  defaultSessionQueueOptions,
                                                  newSessionCommandQueue)
import           MetaSonic.Session.Runner        (PatternRunnerStepResult (..),
                                                  stepPatternSession)
import           MetaSonic.Session.State         (SessionState)


-- | Hidden host for a scoped Pattern-driven session.
--
-- The constructor stays private so callers cannot bypass the host lock
-- or retain the underlying 'SessionOwner' outside the bracket.
data PatternSessionHost = PatternSessionHost
  { pshOwner :: !SessionOwner
  , pshState :: !(MVar PatternSessionHostState)
  }

data PatternSessionHostState = PatternSessionHostState
  { pshInternalProducer :: !PatternProducerState
  , pshInternalQueue    :: !SessionCommandQueue
  }

-- | Construction options for a Pattern session host.
data PatternSessionHostOptions = PatternSessionHostOptions
  { pshoProducerOptions :: !PatternProducerOptions
  , pshoQueueOptions    :: !SessionQueueOptions
  , pshoOwnerOptions    :: !SessionOwnerOptions
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Conservative test/demo defaults for the serialized Pattern host.
defaultPatternSessionHostOptions :: PatternSessionHostOptions
defaultPatternSessionHostOptions = PatternSessionHostOptions
  { pshoProducerOptions = defaultPatternProducerOptions
  , pshoQueueOptions    = defaultSessionQueueOptions
  , pshoOwnerOptions    = defaultSessionOwnerOptions
  }

-- | Host construction failures from any owned subcomponent.
data PatternSessionHostSetupIssue
  = PshsiPatternProducer !PatternProducerIssue
  | PshsiQueue !SessionQueueSetupIssue
  | PshsiOwner !SessionAdapterSetupIssue
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Thread-safe read-only host snapshot.
data PatternSessionHostSnapshot = PatternSessionHostSnapshot
  { pshsBacklogged  :: !Bool
  , pshsOwnerState  :: !SessionState
  , pshsOwnerStatus :: !SessionOwnerStatus
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Allocate a scoped, serialized Pattern session host.
--
-- The host owns the 'SessionOwner' bracket and must not escape the
-- callback. Producer and queue setup are validated before allocating
-- the runtime owner.
withPatternSessionHost
  :: TemplateGraph
  -> PatternSessionHostOptions
  -> (PatternSessionHost -> IO a)
  -> IO (Either PatternSessionHostSetupIssue a)
withPatternSessionHost graph opts action =
  case newPatternProducerState (pshoProducerOptions opts) of
    Left issue ->
      pure (Left (PshsiPatternProducer issue))
    Right producer ->
      case newSessionCommandQueue (pshoQueueOptions opts) of
        Left issue ->
          pure (Left (PshsiQueue issue))
        Right queue -> do
          ownerResult <-
            withSessionOwner graph (pshoOwnerOptions opts) $ \owner -> do
              stateVar <- newMVar PatternSessionHostState
                { pshInternalProducer = producer
                , pshInternalQueue    = queue
                }
              action PatternSessionHost
                { pshOwner = owner
                , pshState = stateVar
                }
          case ownerResult of
            Left issue ->
              pure (Left (PshsiOwner issue))
            Right value ->
              pure (Right value)

-- | Run one serialized Pattern step through the hosted owner.
--
-- The lock covers Pattern producer state, queue state, and the
-- single-threaded owner step. Concurrent callers therefore observe a
-- sequence of whole Prep I runner steps, never interleaved updates.
stepPatternSessionHost
  :: Pattern
  -> PatternSessionHost
  -> IO PatternRunnerStepResult
stepPatternSessionHost pat host =
  modifyMVar (pshState host) $ \state -> do
    step <- stepPatternSession
      pat
      (pshInternalProducer state)
      (pshInternalQueue state)
      (pshOwner host)
    let state' = state
          { pshInternalProducer = prsState step
          , pshInternalQueue    = prsQueue step
          }
    pure (state', step)

-- | Read a consistent host snapshot.
readPatternSessionHost
  :: PatternSessionHost
  -> IO PatternSessionHostSnapshot
readPatternSessionHost host =
  withMVar (pshState host) $ \state -> do
    ownerState <- sessionOwnerState (pshOwner host)
    ownerStatus <- sessionOwnerStatus (pshOwner host)
    pure PatternSessionHostSnapshot
      { pshsBacklogged =
          isBacklogged (pshInternalProducer state)
      , pshsOwnerState =
          ownerState
      , pshsOwnerStatus =
          ownerStatus
      }
