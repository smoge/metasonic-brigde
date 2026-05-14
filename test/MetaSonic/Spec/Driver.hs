{-# LANGUAGE LambdaCase #-}

-- | Pattern driver feasibility checks shared by pattern-facing tests.
module MetaSonic.Spec.Driver where

import qualified Data.Map.Strict           as M
import qualified Data.Set                  as S
import           Data.List                 (find)
import           Data.Maybe                (isJust)

import           MetaSonic.Bridge.Compile   (RuntimeGraph (..),
                                             RuntimeNode (..))
import           MetaSonic.Bridge.Source    (MigrationKey (..))
import           MetaSonic.Bridge.Templates
import           MetaSonic.Pattern

-- | Anything a driver would need to refuse the pattern.
data DriverIssue
  = OutOfOrderEvent      !SamplePos !SamplePos
  | UnknownTemplate      !TemplateName
  | DuplicateVoiceOn     !VoiceKey
  | UnknownVoiceForOff   !VoiceKey
  | UnknownVoiceForWrite !VoiceKey
  | UnknownControlNode   !TemplateName !MigrationKey
  | InvalidControlSlot   !TemplateName !MigrationKey !Int !Int
    -- ^ ctSlot is out of range. Fields: requested slot, the
    -- resolved node's actual control count.
  | HotSwapTemplateLost  !VoiceKey !TemplateName
    -- ^ A 'PEHotSwap' payload omits a template for which a voice
    -- was still open. The driver would have to either force-release
    -- the orphan voice or refuse the swap; v1 validator reports it
    -- and drops the voice from the open set so subsequent writes
    -- against it surface as 'UnknownVoiceForWrite'.
  deriving (Eq, Show)

-- | Walk a pattern's events against its 'patternTemplates' and
-- collect every reason a driver could not execute them. Returns the
-- empty list iff the pattern is feasible.
--
-- The active 'TemplateGraph' is threaded through the fold: a
-- 'PEHotSwap' event replaces it, so subsequent 'TemplateName' /
-- 'ControlTag' resolution runs against the new payload. This means
-- a row that opens a voice, hot-swaps, and writes to that voice
-- post-swap is rejected if the new payload no longer carries the
-- voice's template or tagged nodes.
--
-- Deferred to 6.A.3: §5.2 state-preservation invariants across a
-- hot-swap. A swap payload that retains a voice's template name but
-- moves the voice's migration-keyed nodes to different 'NodeKind's
-- would still pass this validator while breaking state migration.
-- Naming the gap here lets 6.A.3 inherit a specific TODO rather
-- than rediscover it empirically.
checkDriverFeasibility
  :: Pattern
  -> [(SamplePos, PatternEvent)]
  -> [DriverIssue]
checkDriverFeasibility pat = go (patternTemplates pat) M.empty Nothing
  where
    go :: TemplateGraph
       -> M.Map VoiceKey TemplateName
       -> Maybe SamplePos
       -> [(SamplePos, PatternEvent)]
       -> [DriverIssue]
    go _  _    _        []                 = []
    go tg open lastPos  ((pos, ev) : rest) =
      let templates = tgTemplates tg

          lookupT :: TemplateName -> Maybe Template
          lookupT (TemplateName n) = find ((== n) . tplName) templates

          resolveNode :: TemplateName -> MigrationKey -> Maybe RuntimeNode
          resolveNode tname key = do
            t <- lookupT tname
            find (\n -> rnMigrationKey n == Just key)
                 (rgNodes (tplGraph t))

          checkCtrl :: TemplateName -> ControlTag -> [DriverIssue]
          checkCtrl tname (ControlTag key slot) =
            case resolveNode tname key of
              Nothing -> [UnknownControlNode tname key]
              Just n  ->
                let count = length (rnControls n)
                in if slot < 0 || slot >= count
                     then [InvalidControlSlot tname key slot count]
                     else []

          orderIssue = case lastPos of
            Just lp | pos < lp -> [OutOfOrderEvent pos lp]
            _                  -> []
      in case ev of
        PEVoiceOn tname vkey ctrls ->
          let tIssue  = if isJust (lookupT tname) then [] else [UnknownTemplate tname]
              dIssue  = if M.member vkey open then [DuplicateVoiceOn vkey] else []
              cIssue  = concatMap (checkCtrl tname . fst) ctrls
              open'   = M.insert vkey tname open
          in orderIssue ++ tIssue ++ dIssue ++ cIssue
             ++ go tg open' (Just pos) rest

        PEVoiceOff vkey ->
          case M.lookup vkey open of
            Nothing -> orderIssue ++ [UnknownVoiceForOff vkey]
                       ++ go tg open (Just pos) rest
            Just _  -> orderIssue
                       ++ go tg (M.delete vkey open) (Just pos) rest

        PEControlWrite vkey ct _ ->
          case M.lookup vkey open of
            Nothing -> orderIssue ++ [UnknownVoiceForWrite vkey]
                       ++ go tg open (Just pos) rest
            Just tname ->
              let cIssue = checkCtrl tname ct
              in orderIssue ++ cIssue ++ go tg open (Just pos) rest

        PEHotSwap _ newTg ->
          let newNames = S.fromList (map tplName (tgTemplates newTg))
              isLost (TemplateName n) = not (S.member n newNames)
              lostIssues =
                [ HotSwapTemplateLost vk tname
                | (vk, tname) <- M.toList open
                , isLost tname
                ]
              remainingOpen = M.filter (not . isLost) open
          in orderIssue ++ lostIssues
             ++ go newTg remainingOpen (Just pos) rest
