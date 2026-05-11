-- |
-- Module      : MetaSonic.OSC.Dispatch
-- Description : Phase 6.B.2a — production OSC dispatch surface.
--
-- The safe subset of 'MetaSonic.OSC.Dispatch.Internal':
-- registration always validates the OSC-safe identifier profile
-- and the reserved-word list. Production code (the listener
-- module, the eventual CLI) imports from here and cannot reach
-- 'registerVoiceUnchecked'.
--
-- Tests that need the documented escape hatch import
-- 'MetaSonic.OSC.Dispatch.Internal' directly.

module MetaSonic.OSC.Dispatch
  ( -- * Resolution state
    ResolveState
  , emptyResolveState
  , registerVoice
  , dropVoice
  , installTemplateGraph
  , resolveStateTemplate
  , resolveStateVoices
    -- * Dispatch outputs
  , DispatchAction (..)
  , DispatchIssue (..)
  , dispatch
    -- * OSC-safe identifier profile
  , isOscSafeIdentifier
  , reservedOscPathSegments
  ) where

import           MetaSonic.OSC.Dispatch.Internal
                   ( DispatchAction (..)
                   , DispatchIssue (..)
                   , ResolveState
                   , dispatch
                   , dropVoice
                   , emptyResolveState
                   , installTemplateGraph
                   , isOscSafeIdentifier
                   , registerVoice
                   , reservedOscPathSegments
                   , resolveStateTemplate
                   , resolveStateVoices
                   )
