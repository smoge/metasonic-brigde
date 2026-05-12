{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.State
-- Description : Pure session admission and commit state.
--
-- This module is the Session Prep B boundary between producer intent
-- and later runtime execution. Admission is read-only: it validates a
-- 'SessionCommand' and returns a 'SessionPlan'. State changes only
-- when the caller applies a 'SessionCommit' after the corresponding
-- runtime action has succeeded.
--
-- The module owns no 'RTGraph', writes no realtime queue, performs no
-- IO, and does not install graphs.
--
-- See [notes/2026-05-12-session-prep-b-admission-commit.md].

module MetaSonic.Session.State
  ( -- * State
    SessionState (..)
  , initialSessionState

    -- * Admission
  , SessionPlan (..)
  , SessionAdmissionResult (..)
  , admitSessionCommand

    -- * Commits
  , SessionCommit (..)
  , applySessionCommit
  , commitGraphInstalled
  ) where

import           Control.DeepSeq            (NFData)
import qualified Data.ByteString.Char8      as BSC
import qualified Data.Map.Strict            as M
import qualified Data.Set                   as S
import           GHC.Generics               (Generic)

import           MetaSonic.Bridge.Templates (Template (..), TemplateGraph (..))
import           MetaSonic.OSC.Dispatch     (ResolveState, dropVoice,
                                             emptyResolveState, registerVoice,
                                             validateVoiceKey)
import           MetaSonic.Pattern          (ControlTag, SwapLabel,
                                             TemplateName (..), Value,
                                             VoiceKey (..))
import           MetaSonic.Session.Command  (SessionCommand (..),
                                             SessionIssue (..))
import           MetaSonic.Session.Resolve  (ResolveRebuildIssue (..),
                                             ResolveRebuildResult (..),
                                             VoiceBinding (..),
                                             rebuildResolveState)


-- | Pure session-visible state. This mirrors facts a future session
-- owner can reason about; it is not runtime ownership.
data SessionState = SessionState
  { ssGraph   :: !TemplateGraph
  , ssVoices  :: !(M.Map VoiceKey VoiceBinding)
  , ssResolve :: !ResolveState
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Build the initial session state around an installed graph. An
-- empty graph is a valid boot state; no template lookup succeeds until
-- a later graph-install commit replaces it.
initialSessionState :: TemplateGraph -> SessionState
initialSessionState tg = SessionState
  { ssGraph   = tg
  , ssVoices  = M.empty
  , ssResolve = emptyResolveState tg
  }

-- | Work a future runtime shell may attempt after admission.
data SessionPlan
  = PlanVoiceStart !TemplateName !VoiceKey ![(ControlTag, Value)]
  | PlanVoiceStop !VoiceBinding
  | PlanControlWrite !VoiceBinding !ControlTag !Value
  | PlanHotSwap !SwapLabel !TemplateGraph !ResolveRebuildResult
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Result of read-only command admission.
data SessionAdmissionResult
  = SessionAdmitted !SessionCommand !SessionPlan
  | SessionRejected !SessionCommand !SessionIssue
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Runtime facts that may update pure session state after the
-- corresponding action has succeeded outside this module.
data SessionCommit
  = CommitVoiceStarted !VoiceBinding
  | CommitVoiceStopped !VoiceKey
  | CommitGraphInstalled !SwapLabel !TemplateGraph
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Validate a command against the current pure session state without
-- mutating that state.
admitSessionCommand :: SessionCommand -> SessionState -> SessionAdmissionResult
admitSessionCommand cmd st = case cmd of
  CmdVoiceOn tname vkey controls
    | not (templateExists tname (ssGraph st)) ->
        SessionRejected cmd (SiUnknownTemplate tname)
    | M.member vkey (ssVoices st) ->
        SessionRejected cmd (SiVoiceAlreadyActive vkey)
    | Left _ <- validateVoiceKey (voiceKeyBytes vkey) ->
        SessionRejected cmd (SiInvalidVoiceKey vkey)
    | otherwise ->
        SessionAdmitted cmd (PlanVoiceStart tname vkey controls)

  CmdVoiceOff vkey ->
    case M.lookup vkey (ssVoices st) of
      Just binding ->
        SessionAdmitted cmd (PlanVoiceStop binding)
      Nothing ->
        SessionRejected cmd (SiStaleVoice vkey)

  CmdControlWrite vkey target value ->
    case M.lookup vkey (ssVoices st) of
      Just binding ->
        SessionAdmitted cmd (PlanControlWrite binding target value)
      Nothing ->
        SessionRejected cmd (SiStaleVoice vkey)

  CmdHotSwap label graph ->
    SessionAdmitted cmd
      (PlanHotSwap label graph (previewResolveRebuild graph st))

-- | Apply a successful runtime fact to pure session state.
applySessionCommit :: SessionCommit -> SessionState -> SessionState
applySessionCommit commit st = case commit of
  CommitVoiceStarted binding ->
    case registerVoice
           (voiceKeyBytes (vbVoiceKey binding))
           (vbSlotId binding)
           (templateNameBytes (vbTemplateName binding))
           (ssResolve st) of
      Right resolve' ->
        st { ssVoices  = M.insert (vbVoiceKey binding) binding (ssVoices st)
           , ssResolve = resolve'
           }
      Left _ ->
        error "applySessionCommit: invariant violated; invalid committed voice binding"

  CommitVoiceStopped vkey ->
    st { ssVoices  = M.delete vkey (ssVoices st)
       , ssResolve = dropVoice (voiceKeyBytes vkey) (ssResolve st)
       }

  CommitGraphInstalled label graph ->
    fst (commitGraphInstalled label graph st)

-- | Commit a graph install and return the authoritative resolve
-- rebuild result produced at commit time. This is the API to use when
-- the caller needs to log or route the actual dropped-voice list; a
-- 'PlanHotSwap' preview is admission-time only and may be stale.
commitGraphInstalled
  :: SwapLabel
  -> TemplateGraph
  -> SessionState
  -> (SessionState, ResolveRebuildResult)
commitGraphInstalled _label graph st =
  let result = previewResolveRebuild graph st
      dropped = S.fromList (map rebuildIssueVoiceKey (rrrDropped result))
      st' = st { ssGraph   = graph
               , ssVoices  = M.withoutKeys (ssVoices st) dropped
               , ssResolve = rrrState result
               }
  in (st', result)

previewResolveRebuild :: TemplateGraph -> SessionState -> ResolveRebuildResult
previewResolveRebuild graph st =
  -- SessionState keys voices by VoiceKey, so rebuild diagnostics use
  -- deterministic key order rather than runtime/start order.
  rebuildResolveState graph (M.elems (ssVoices st))

templateExists :: TemplateName -> TemplateGraph -> Bool
templateExists (TemplateName name) tg =
  any ((== name) . tplName) (tgTemplates tg)

rebuildIssueVoiceKey :: ResolveRebuildIssue -> VoiceKey
rebuildIssueVoiceKey issue = case issue of
  RriInvalidVoiceKey vkey _ ->
    vkey
  RriMissingTemplate vkey _ ->
    vkey

voiceKeyBytes :: VoiceKey -> BSC.ByteString
voiceKeyBytes = BSC.pack . unVoiceKey

templateNameBytes :: TemplateName -> BSC.ByteString
templateNameBytes = BSC.pack . unTemplateName
