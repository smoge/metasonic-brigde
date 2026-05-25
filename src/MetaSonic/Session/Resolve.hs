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

    -- * Retired-voice projection (Phase 8h step 3e v1)
  , RetiredVoiceBinding (..)
  , RetiredVoiceReason (..)

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
  , rrrRetired :: ![RetiredVoiceBinding]
    -- ^ Phase 8h step 3e v1: each dropped binding paired with its
    -- originating 'VoiceBinding' so downstream renderers have the
    -- @VoiceKey + TemplateName@ context that 'rrrDropped' alone
    -- cannot supply (the 'RriInvalidVoiceKey' issue carries no
    -- template name). Same input order as 'rrrDropped'.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)


-- | Phase 8h step 3e v1: operator-facing projection of one retired
-- voice. Pairs the original 'VoiceBinding' the session held with a
-- structured retirement reason so the operator render can name the
-- voice, its template, and why the reload dropped it.
data RetiredVoiceBinding = RetiredVoiceBinding
  { rvbBinding :: !VoiceBinding
  , rvbReason  :: !RetiredVoiceReason
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)


-- | Why a 'VoiceBinding' was retired. Preserving reloads produce the
-- first two reasons (mapped from 'ResolveRebuildIssue'); the
-- stopped-audio path produces only 'RvrOwnerReplaced' because the old
-- owner is released wholesale.
data RetiredVoiceReason
  = RvrTemplateGone
    -- ^ The new 'TemplateGraph' no longer carries the binding's
    -- template. Corresponds to 'RriMissingTemplate'.
  | RvrInvalidVoiceKey !DispatchIssue
    -- ^ The new graph's dispatcher refused the binding's voice key
    -- (e.g. reserved path segment, identifier profile failure).
    -- Corresponds to 'RriInvalidVoiceKey'.
  | RvrOwnerReplaced
    -- ^ Stopped-audio reload: the old owner was released and a fresh
    -- owner acquired with an empty 'ssVoices'. Every pre-reload
    -- binding carries this reason regardless of whether its template
    -- still exists in the new graph.
  deriving stock    (Eq, Show, Generic)
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
  let (rs, droppedRev, retiredRev) =
        foldl' step (emptyResolveState tg, [], []) bindings
  in ResolveRebuildResult
       { rrrState   = rs
       , rrrDropped = reverse droppedRev
       , rrrRetired = reverse retiredRev
       }
  where
    step
      :: (ResolveState, [ResolveRebuildIssue], [RetiredVoiceBinding])
      -> VoiceBinding
      -> (ResolveState, [ResolveRebuildIssue], [RetiredVoiceBinding])
    step (rs, dropped, retired) binding
      | not (templateExists (vbTemplateName binding)) =
          ( rs
          , RriMissingTemplate
              (vbVoiceKey binding)
              (vbTemplateName binding)
            : dropped
          , RetiredVoiceBinding binding RvrTemplateGone : retired
          )
      | otherwise =
          case registerVoice
                 (voiceKeyBytes (vbVoiceKey binding))
                 (vbSlotId binding)
                 (templateNameBytes (vbTemplateName binding))
                 rs of
            Right rs' ->
              (rs', dropped, retired)
            Left issue ->
              ( rs
              , RriInvalidVoiceKey (vbVoiceKey binding) issue : dropped
              , RetiredVoiceBinding binding (RvrInvalidVoiceKey issue)
                : retired
              )

    templateExists :: TemplateName -> Bool
    templateExists (TemplateName name) =
      any ((== name) . tplName) (tgTemplates tg)

voiceKeyBytes :: VoiceKey -> BSC.ByteString
voiceKeyBytes = BSC.pack . unVoiceKey

templateNameBytes :: TemplateName -> BSC.ByteString
templateNameBytes = BSC.pack . unTemplateName
