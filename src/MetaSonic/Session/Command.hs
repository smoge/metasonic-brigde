{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.Command
-- Description : Intent-based vocabulary for session orchestration.
--
-- This module defines a structural contract for the future session
-- layer. It is the narrow waist between input producers such as
-- patterns, OSC, MIDI, and future authoring/UI actions, and the later
-- execution layer that validates and applies those requests.
--
-- === Architectural scope
--
-- This module is purely declarative. It defines command and
-- diagnostic-event vocabulary, but deliberately abstracts away:
--
-- * ownership of an 'RTGraph';
-- * realtime queue serialization;
-- * graph hot-swap orchestration;
-- * command execution.
--
-- By mirroring 'MetaSonic.Pattern' identifiers, the v1 surface lets
-- disparate input sources converge on one command set instead of
-- growing parallel runtime mutation paths.
--
-- See [notes/2026-05-12-session-prep-a-contract.md]

module MetaSonic.Session.Command
  ( -- * Commands
    SessionCommand (..)
  , fromPatternEvent

    -- * Diagnostic Events
  , SessionEvent (..)
  , SessionIssue (..)
  ) where

import           Control.DeepSeq            (NFData)
import           GHC.Generics               (Generic)

import           MetaSonic.Bridge.Templates (TemplateGraph)
import           MetaSonic.Pattern          (ControlTag, PatternEvent (..),
                                             SwapLabel, TemplateName, Value,
                                             VoiceKey)


-- | Producer-agnostic command vocabulary for a future session owner.
--
-- While these constructors intentionally mirror 'PatternEvent', they
-- serve a different architectural purpose. 'PatternEvent' represents
-- one producer's output; 'SessionCommand' is the normalized request
-- format that the session layer can validate before eventual
-- execution.
data SessionCommand
  = CmdVoiceOn      !TemplateName !VoiceKey ![(ControlTag, Value)]
    -- ^ Request instantiation of one named-template voice with
    -- initial symbolic control values applied before activation.
  | CmdVoiceOff     !VoiceKey
    -- ^ Request release of the named logical voice.
  | CmdControlWrite !VoiceKey !ControlTag !Value
    -- ^ Request a symbolic control write against a live voice.
  | CmdHotSwap      !SwapLabel !TemplateGraph
    -- ^ Request installation of a precompiled replacement template
    -- graph. Install timing and safety policy belong to the future
    -- session owner, not this vocabulary module.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | High-level diagnostic reasons for command rejection.
--
-- This set is intentionally minimal. Detailed runtime, allocation,
-- driver, and install failures belong to the later session-execution
-- slice.
data SessionIssue
  = SiUnknownTemplate !TemplateName
  | SiInvalidVoiceKey !VoiceKey
  | SiStaleVoice      !VoiceKey
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Read-only audit vocabulary for producers, logs, and tests.
--
-- These events describe command admission or rejection only. They do
-- not imply that an accepted command has been processed by the
-- realtime audio thread.
data SessionEvent
  = SessionCommandAccepted !SessionCommand
  | SessionCommandRejected !SessionCommand !SessionIssue
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Lift a 'PatternEvent' into the shared 'SessionCommand' space.
fromPatternEvent :: PatternEvent -> SessionCommand
fromPatternEvent ev = case ev of
  PEVoiceOn tname vkey controls ->
    CmdVoiceOn tname vkey controls
  PEVoiceOff vkey ->
    CmdVoiceOff vkey
  PEControlWrite vkey target value ->
    CmdControlWrite vkey target value
  PEHotSwap label graph ->
    CmdHotSwap label graph
