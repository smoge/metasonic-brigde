{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.Resolve
-- Description : Pure OSC resolve-state rebuild for session hot-swap prep.
--
-- This module defines the pure recovery step for session hot-swap
-- policy. After a new 'TemplateGraph' has installed successfully, the
-- OSC address space can be rebuilt from the voices that survived the
-- swap.
--
-- The rebuild policy is intentionally narrow:
--
-- * start from 'emptyResolveState' for the newly installed graph;
-- * preserve bindings whose template still exists;
-- * re-validate symbolic 'VoiceKey's through the existing dispatcher
--   grammar;
-- * report every dropped binding in input order.
--
-- It does not install graphs, touch an 'RTGraph', write to the
-- realtime queue, or retry stale symbolic addresses. Bindings that
-- cannot be represented in the new graph are dropped with explicit
-- diagnostics.
--
-- See [notes/2026-05-12-n-session-prep-a-contract.md].

module MetaSonic.Session.Resolve
  ( -- * Migration Types
    VoiceBinding (..)
  , ResolveRebuildIssue (..)
  , ResolveRebuildResult (..)

    -- * Transformation
  , rebuildResolveState
  ) where

import           Control.DeepSeq            (NFData)
import qualified Data.ByteString.Char8      as BSC
import           GHC.Generics               (Generic)

import           MetaSonic.Bridge.Templates (Template (..), TemplateGraph (..))
import           MetaSonic.OSC.Dispatch     (DispatchIssue, ResolveState,
                                             emptyResolveState, registerVoice)
import           MetaSonic.Pattern          (TemplateName (..), VoiceKey (..))


-- | A voice binding the session wants to preserve across a graph
-- hot-swap. The binding is symbolic at the edge ('VoiceKey' and
-- 'TemplateName') plus the runtime voice slot assigned by the session
-- owner.
data VoiceBinding = VoiceBinding
  { vbVoiceKey     :: !VoiceKey
    -- ^ Symbolic identifier used by OSC, Pattern, and other producers.
  , vbSlotId       :: !Int
    -- ^ Runtime voice slot to re-associate with the symbolic key.
  , vbTemplateName :: !TemplateName
    -- ^ Template this voice was instantiated from.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Reasons a binding could not be carried into the rebuilt
-- 'ResolveState'.
data ResolveRebuildIssue
  = RriInvalidVoiceKey !VoiceKey !DispatchIssue
    -- ^ The existing OSC dispatch registration path refused the
    -- voice key (reserved path segment or identifier-profile failure).
  | RriMissingTemplate !VoiceKey !TemplateName
    -- ^ The new 'TemplateGraph' no longer carries the template the
    -- voice was spawned against.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Result of rebuilding resolution: the new state plus every binding
-- dropped along the way, in input order.
data ResolveRebuildResult = ResolveRebuildResult
  { rrrState   :: !ResolveState
    -- ^ Successfully populated OSC resolution map for the new graph.
  , rrrDropped :: ![ResolveRebuildIssue]
    -- ^ Bindings that could not migrate, preserved in input order.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Rebuild OSC resolve state for a newly installed 'TemplateGraph'.
--
-- Policy:
--
-- * start from 'emptyResolveState' for the new graph;
-- * preserve bindings whose template still exists;
-- * validate voice keys with the existing OSC registration path;
-- * drop missing-template or invalid-key bindings with diagnostics.
rebuildResolveState
  :: TemplateGraph
  -> [VoiceBinding]
  -> ResolveRebuildResult
rebuildResolveState tg bindings =
  let (rs, droppedRev) = foldl' step (emptyResolveState tg, []) bindings
  in ResolveRebuildResult
       { rrrState   = rs
       , rrrDropped = reverse droppedRev
       }
  where
    step
      :: (ResolveState, [ResolveRebuildIssue])
      -> VoiceBinding
      -> (ResolveState, [ResolveRebuildIssue])
    step (rs, dropped) binding
      | not (templateExists (vbTemplateName binding)) =
          (rs, RriMissingTemplate
                 (vbVoiceKey binding)
                 (vbTemplateName binding)
               : dropped)
      | otherwise =
          case registerVoice
                 (voiceKeyBytes (vbVoiceKey binding))
                 (vbSlotId binding)
                 (templateNameBytes (vbTemplateName binding))
                 rs of
            Right rs' ->
              (rs', dropped)
            Left issue ->
              (rs, RriInvalidVoiceKey (vbVoiceKey binding) issue : dropped)

    templateExists :: TemplateName -> Bool
    templateExists (TemplateName name) =
      any ((== name) . tplName) (tgTemplates tg)

voiceKeyBytes :: VoiceKey -> BSC.ByteString
voiceKeyBytes = BSC.pack . unVoiceKey

templateNameBytes :: TemplateName -> BSC.ByteString
templateNameBytes = BSC.pack . unTemplateName
