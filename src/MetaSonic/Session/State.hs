{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.State
-- Description : Pure session admission and commit state.
--
-- This module is the Session Prep B boundary between producer intent
-- and runtime execution. Admission is read-only: it validates a
-- 'SessionCommand' and returns a 'SessionPlan'. State changes only
-- when the caller applies a 'SessionCommit' after the corresponding
-- runtime action has succeeded.
--
-- The module owns no 'RTGraph', writes no realtime queue, performs no
-- IO, and does not install graphs.
--
-- See [notes/2026-05-12-o-session-prep-b-admission-commit.md].

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
  , SessionCommitIssue (..)
  , applySessionCommit
  , applyPlannedCommit
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
import           MetaSonic.Session.Command  (HotSwapInstallMode (..),
                                             SessionCommand (..),
                                             SessionIssue (..))
import           MetaSonic.Session.Resolve  (ResolveRebuildIssue (..),
                                             ResolveRebuildResult (..),
                                             VoiceBinding (..),
                                             rebuildResolveState)


-- | Pure session-visible state. This mirrors facts the session owner
-- can reason about; it is not runtime ownership.
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

-- | Work a runtime adapter may attempt after admission.
data SessionPlan
  = PlanVoiceStart !TemplateName !VoiceKey ![(ControlTag, Value)]
  | PlanVoiceStop !VoiceBinding
  | PlanControlWrite !VoiceBinding !ControlTag !Value
  | PlanHotSwap !HotSwapInstallMode !SwapLabel !TemplateGraph !ResolveRebuildResult
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

-- | Internal issue vocabulary for matching an admitted plan with the
-- runtime fact that claims the attempted work succeeded.
data SessionCommitIssue
  = SciUnexpectedCommit !SessionPlan !SessionCommit
  | SciVoiceKeyMismatch !VoiceKey !VoiceKey
  | SciTemplateMismatch !TemplateName !TemplateName
  | SciSwapLabelMismatch !SwapLabel !SwapLabel
  | SciGraphMismatch
  | SciControlPlanHasNoStateCommit
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
      (PlanHotSwap HotSwapAllowRebuild label graph (previewResolveRebuild graph st))

  CmdHotSwapPreservingOnly label graph ->
    SessionAdmitted cmd
      (PlanHotSwap HotSwapPreservingOnly label graph (previewResolveRebuild graph st))

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

-- | Apply a commit only after proving it matches the admitted plan
-- that authorized the runtime attempt. A 'Left' result never mutates
-- the supplied 'SessionState'.
applyPlannedCommit
  :: SessionPlan
  -> SessionCommit
  -> SessionState
  -> Either SessionCommitIssue (SessionState, Maybe ResolveRebuildResult)
applyPlannedCommit plan commit st =
  case (plan, commit) of
    (PlanVoiceStart expectedTemplate expectedVoice _, CommitVoiceStarted binding)
      | vbVoiceKey binding /= expectedVoice ->
          Left (SciVoiceKeyMismatch expectedVoice (vbVoiceKey binding))
      | vbTemplateName binding /= expectedTemplate ->
          Left (SciTemplateMismatch expectedTemplate (vbTemplateName binding))
      | otherwise ->
          Right (applySessionCommit commit st, Nothing)

    (PlanVoiceStart {}, _) ->
      Left (SciUnexpectedCommit plan commit)

    (PlanVoiceStop binding, CommitVoiceStopped actualVoice)
      | actualVoice /= vbVoiceKey binding ->
          Left (SciVoiceKeyMismatch (vbVoiceKey binding) actualVoice)
      | otherwise ->
          Right (applySessionCommit commit st, Nothing)

    (PlanVoiceStop {}, _) ->
      Left (SciUnexpectedCommit plan commit)

    (PlanControlWrite {}, _) ->
      Left SciControlPlanHasNoStateCommit

    (PlanHotSwap _ expectedLabel expectedGraph _, CommitGraphInstalled actualLabel actualGraph)
      | actualLabel /= expectedLabel ->
          Left (SciSwapLabelMismatch expectedLabel actualLabel)
      | actualGraph /= expectedGraph ->
          Left SciGraphMismatch
      | otherwise ->
          let (st', result) = commitGraphInstalled actualLabel actualGraph st
          in Right (st', Just result)

    (PlanHotSwap {}, _) ->
      Left (SciUnexpectedCommit plan commit)

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
