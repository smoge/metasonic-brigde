{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.UIProducer
-- Description : Haskell-only UI intent adapter for session fan-in.
--
-- This module defines the narrow UI producer bridge for the generic
-- session fan-in host. It consumes already-decoded UI intents, checks
-- only the producer-local value shape, converts them to
-- 'SessionCommand's, and submits them as 'ProducerUI'. Callers can
-- either submit to a plain fan-in host or explicitly choose the
-- service-owned arbitration path.
--
-- It deliberately doesn't implement a GUI toolkit binding, read an
-- authoring manifest, authorize commands, drain the session host, or
-- repair a diverged owner.

module MetaSonic.Session.UIProducer
  ( -- * Intents
    UIProducerIntent (..)

    -- * Options
  , UIProducerOptions (..)
  , defaultUIProducerOptions
  , uiProducerId

    -- * Issues
  , UIProducerIssue (..)

    -- * Translation
  , decodeUISessionCommand

    -- * Fan-in submission
  , UIProducerEnqueueResult (..)
  , UIProducerArbitratedEnqueueResult (..)
  , enqueueUIProducerIntent
  , enqueueArbitratedUIProducerIntent
  ) where

import           Control.DeepSeq            (NFData)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           GHC.Generics               (Generic)

import           MetaSonic.Bridge.Templates (TemplateGraph)
import           MetaSonic.Pattern          (ControlTag, SwapLabel,
                                             TemplateName, Value, VoiceKey)
import           MetaSonic.Session.Command  (SessionCommand (..))
import           MetaSonic.Session.ArbitrationGateway
                                             (SessionArbitrationGatewayEnqueueResult)
import           MetaSonic.Session.FanIn    (SessionFanInEnqueueResult,
                                             SessionFanInHost,
                                             enqueueSessionFanInCommand)
import           MetaSonic.Session.FanInService
                                             (SessionFanInService,
                                              enqueueArbitratedSessionFanInServiceCommand)
import           MetaSonic.Session.Queue    (ProducerId (..),
                                             ProducerKind (ProducerUI))


-- | Already-decoded UI intent.
--
-- This is not a wire format and not a manifest format. GUI/tool code
-- can map its widgets or commands into this small ADT, then let the
-- session layers validate symbolic voice/template/control references
-- at admission and execution time.
data UIProducerIntent
  = UIVoiceOn      !TemplateName !VoiceKey ![(ControlTag, Value)]
  | UIVoiceOff     !VoiceKey
  | UIControlWrite !VoiceKey !ControlTag !Value
  | UIHotSwap      !SwapLabel !TemplateGraph
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Construction-free options for attributing UI producer commands.
data UIProducerOptions = UIProducerOptions
  { upoProducerName :: !Text
    -- ^ Free-form diagnostic producer name. The default is @"ui"@.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Conservative default identity for UI producer ingress.
defaultUIProducerOptions :: UIProducerOptions
defaultUIProducerOptions = UIProducerOptions
  { upoProducerName = T.pack "ui"
  }

-- | Producer-local issue detected before fan-in enqueue.
data UIProducerIssue
  = UpiNonFiniteInitialControl !ControlTag !Value
  | UpiNonFiniteControlValue !ControlTag !Value
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Result of translating and enqueueing one UI intent.
data UIProducerEnqueueResult
  = UIProducerRejected !UIProducerIssue
    -- ^ The UI intent failed producer-local shape checks, so no
    -- command was submitted to the fan-in host.
  | UIProducerEnqueueAttempted !SessionCommand !SessionFanInEnqueueResult
    -- ^ The intent decoded to a command and was passed to the fan-in
    -- host. Inspect the nested enqueue result for queue-full or
    -- accepted-command details.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Result of translating and enqueueing one UI intent through the
-- explicitly arbitrated service path.
data UIProducerArbitratedEnqueueResult
  = UIProducerArbitratedRejected !UIProducerIssue
    -- ^ The UI intent failed producer-local shape checks, so no
    -- command was submitted to the service.
  | UIProducerArbitratedEnqueueAttempted
      !SessionCommand
      !SessionArbitrationGatewayEnqueueResult
    -- ^ The intent decoded to a command and was passed to the
    -- service-owned arbitration path. Inspect the nested result for
    -- policy rejection, queue-full, or accepted-command details.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Producer identity used for commands emitted by this adapter.
uiProducerId :: UIProducerOptions -> ProducerId
uiProducerId opts =
  ProducerId ProducerUI (upoProducerName opts)

-- | Decode one UI intent into the shared session-command vocabulary.
--
-- This adapter rejects non-finite UI values before they can enter the
-- fan-in queue. Symbolic template, voice, and control validation
-- remains centralized in the session owner/admission path.
decodeUISessionCommand
  :: UIProducerIntent
  -> Either UIProducerIssue SessionCommand
decodeUISessionCommand intent = case intent of
  UIVoiceOn tname vkey controls -> do
    mapM_ validateInitial controls
    Right (CmdVoiceOn tname vkey controls)
  UIVoiceOff vkey ->
    Right (CmdVoiceOff vkey)
  UIControlWrite vkey target value -> do
    validateControl target value
    Right (CmdControlWrite vkey target value)
  UIHotSwap label graph ->
    Right (CmdHotSwap label graph)
  where
    validateInitial (target, value)
      | finiteValue value =
          Right ()
      | otherwise =
          Left (UpiNonFiniteInitialControl target value)

    validateControl target value
      | finiteValue value =
          Right ()
      | otherwise =
          Left (UpiNonFiniteControlValue target value)

-- | Decode and submit one UI intent to a fan-in host.
--
-- This function only enqueues. It deliberately does not drain the host
-- or perform runtime target resolution; callers choose those policies.
-- Callers using a 'SessionFanInService' with a configured arbitration
-- gateway should switch to 'enqueueArbitratedUIProducerIntent' for
-- consistent policy enforcement; calling this function with a
-- service-derived host bypasses the configured gateway.
enqueueUIProducerIntent
  :: UIProducerOptions
  -> UIProducerIntent
  -> SessionFanInHost
  -> IO UIProducerEnqueueResult
enqueueUIProducerIntent opts intent host =
  case decodeUISessionCommand intent of
    Left issue ->
      pure (UIProducerRejected issue)
    Right command -> do
      result <-
        enqueueSessionFanInCommand (uiProducerId opts) command host
      pure (UIProducerEnqueueAttempted command result)

-- | Decode and submit one UI intent to the explicit service-owned
-- arbitration path.
--
-- Existing UI producers should keep using 'enqueueUIProducerIntent'
-- unless the surrounding session deliberately opts into
-- 'SessionFanInService' arbitration. With default service options this
-- still preserves FIFO behavior; with configured gateway options, policy
-- rejection is surfaced through the nested
-- 'SessionArbitrationGatewayEnqueueResult' and the service issue hook.
enqueueArbitratedUIProducerIntent
  :: UIProducerOptions
  -> UIProducerIntent
  -> SessionFanInService
  -> IO UIProducerArbitratedEnqueueResult
enqueueArbitratedUIProducerIntent opts intent service =
  case decodeUISessionCommand intent of
    Left issue ->
      pure (UIProducerArbitratedRejected issue)
    Right command -> do
      result <-
        enqueueArbitratedSessionFanInServiceCommand
          (uiProducerId opts)
          command
          service
      pure (UIProducerArbitratedEnqueueAttempted command result)

finiteValue :: Value -> Bool
finiteValue value =
  not (isNaN value || isInfinite value)
