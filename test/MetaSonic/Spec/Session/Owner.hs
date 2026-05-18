-- | Session Prep F: single-threaded runtime owner tests.
--
-- These cases pin the 'SessionOwner' wrapper that combines an
-- 'RTGraphAdapter' with 'SessionState' under one
-- 'withSessionOwner' bracket. The owner is the first surface where
-- setup failure, structured divergence, and non-terminal rejection
-- are all expressible in one place — the lower-level 'Step' and
-- 'RTGraphAdapter' slices pin those behaviors individually; this
-- slice pins them through the owner's single command-step API.
--
-- Coverage:
--
--   * Construction surfaces the initial state and 'SessionOwnerReady'.
--   * Construction surfaces structured setup failure
--     ('SasiDuplicateTemplateName') without leaving a partial owner.
--   * Voice-start mutates internal state; voice-stop removes it;
--     control-write leaves state unchanged. Status stays
--     'SessionOwnerReady' after each.
--   * A hot-swap install failure diverges the owner exactly once;
--     subsequent commands return 'SessionOwnerBlocked' with the
--     same reason, taken from the early-exit branch.
--   * Empty-session hot-swap updates the graph and lets a new
--     voice start under the post-swap template set.
--   * Unsupported preserving hot-swap and admission rejection are
--     both non-terminal — status stays 'SessionOwnerReady'.
--
-- Extracted from "MetaSonic.Spec.Session" as the ninth slice of
-- the Session megafile split. The only SessionShared helper this
-- cohort needs is 'duplicateFirstTwoTemplates'; everything else is
-- public 'MetaSonic.Session.*' surface.
module MetaSonic.Spec.Session.Owner (sessionOwnerTests) where

import qualified Data.Map.Strict                 as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source         (MigrationKey (..))
import           MetaSonic.Pattern               (ControlTag (..),
                                                  Pattern (patternTemplates),
                                                  SwapLabel (..),
                                                  TemplateName (..),
                                                  VoiceKey (..))
import           MetaSonic.Pattern.Corpus        (arpeggioSendReturn,
                                                  droneVibrato, polyphonicStab)
import           MetaSonic.Session.Command
import           MetaSonic.Session.Owner
import           MetaSonic.Session.RTGraphAdapter (SessionAdapterSetupIssue (..))
import           MetaSonic.Session.Resolve
import           MetaSonic.Session.Runtime
import           MetaSonic.Session.State
import           MetaSonic.Session.Step

import           MetaSonic.Spec.SessionShared    (duplicateFirstTwoTemplates)


sessionOwnerTests :: TestTree
sessionOwnerTests = testGroup "Session Prep F: runtime owner"
  [ testCase "owner construction initializes state and status" $ do
      let tg = patternTemplates droneVibrato
      result <- withSessionOwner tg defaultSessionOwnerOptions $ \owner -> do
        st <- sessionOwnerState owner
        status <- sessionOwnerStatus owner
        pure (st, status)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (st, status) -> do
          ssGraph st @?= tg
          ssVoices st @?= M.empty
          status @?= SessionOwnerReady

  , testCase "owner construction surfaces setup failure" $ do
      let duplicated = duplicateFirstTwoTemplates
                         (patternTemplates arpeggioSendReturn)
      result <- withSessionOwner
                  duplicated
                  defaultSessionOwnerOptions
                  (\_ -> pure ())
      result @?= Left (SasiDuplicateTemplateName (TemplateName "dup"))

  , testCase "owner voice-start mutates internal state" $ do
      let tg  = patternTemplates droneVibrato
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      result <- withSessionOwner tg defaultSessionOwnerOptions $ \owner -> do
        stepped <- stepSessionOwner owner cmd
        st <- sessionOwnerState owner
        status <- sessionOwnerStatus owner
        pure (stepped, st, status)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing), st, status) -> do
          assertBool
            "expected owner state to contain started voice"
            (M.member (VoiceKey "v0") (ssVoices st))
          status @?= SessionOwnerReady
        Right other ->
          assertFailure ("expected owner voice-start commit, got: " <> show other)

  , testCase "owner voice-stop removes internal binding" $ do
      let tg       = patternTemplates droneVibrato
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          stopCmd  = CmdVoiceOff (VoiceKey "v0")
      result <- withSessionOwner tg defaultSessionOwnerOptions $ \owner -> do
        started <- stepSessionOwner owner startCmd
        stopped <- stepSessionOwner owner stopCmd
        st <- sessionOwnerState owner
        status <- sessionOwnerStatus owner
        pure (started, stopped, st, status)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing),
               SessionOwnerStep (StepCommitted _ Nothing), st, status) -> do
          ssVoices st @?= M.empty
          status @?= SessionOwnerReady
        Right other ->
          assertFailure ("expected owner voice-stop commit, got: " <> show other)

  , testCase "owner control-write accepts without state mutation" $ do
      let tg       = patternTemplates droneVibrato
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          writeCmd = CmdControlWrite
                       (VoiceKey "v0")
                       (ControlTag (MigrationKey "lpf") 0)
                       700.0
      result <- withSessionOwner tg defaultSessionOwnerOptions $ \owner -> do
        started <- stepSessionOwner owner startCmd
        before <- sessionOwnerState owner
        written <- stepSessionOwner owner writeCmd
        afterState <- sessionOwnerState owner
        status <- sessionOwnerStatus owner
        pure (started, before, written, afterState, status)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing), before,
               SessionOwnerStep StepControlAccepted, afterState, status) -> do
          afterState @?= before
          status @?= SessionOwnerReady
        Right other ->
          assertFailure ("expected owner control-write accept, got: " <> show other)

  , testCase "owner duplicate hot-swap diverges and blocks later commands" $ do
      let oldGraph = patternTemplates droneVibrato
          badGraph = duplicateFirstTwoTemplates
                       (patternTemplates arpeggioSendReturn)
          issue    = SasiDuplicateTemplateName (TemplateName "dup")
          divergedReason = SodHotSwapInstallFailed issue
          swapCmd  = CmdHotSwap (SwapLabel "bad-graph") badGraph
          laterCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      result <- withSessionOwner oldGraph defaultSessionOwnerOptions $ \owner -> do
        diverged <- stepSessionOwner owner swapCmd
        status <- sessionOwnerStatus owner
        blocked <- stepSessionOwner owner laterCmd
        pure (diverged, status, blocked)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (diverged, status, blocked) -> do
          diverged @?= SessionOwnerDivergedNow
            (StepRuntimeFailed (SriHotSwapInstallFailed issue))
            divergedReason
          status @?= SessionOwnerDiverged divergedReason
          -- SessionOwnerBlocked is produced only by the
          -- stepSessionOwner early-exit branch, before adapter
          -- invocation.
          blocked @?= SessionOwnerBlocked divergedReason

  , testCase "owner empty-session hot-swap updates graph and starts new voice" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          swapCmd  = CmdHotSwap (SwapLabel "to-stab") newGraph
          startCmd = CmdVoiceOn (TemplateName "stab") (VoiceKey "s0") []
      result <- withSessionOwner oldGraph defaultSessionOwnerOptions $ \owner -> do
        swapped <- stepSessionOwner owner swapCmd
        afterSwap <- sessionOwnerState owner
        started <- stepSessionOwner owner startCmd
        afterStart <- sessionOwnerState owner
        status <- sessionOwnerStatus owner
        pure (swapped, afterSwap, started, afterStart, status)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ (Just rebuild)),
               afterSwap,
               SessionOwnerStep (StepCommitted _ Nothing),
               afterStart,
               status) -> do
          ssGraph afterSwap @?= newGraph
          ssVoices afterSwap @?= M.empty
          rrrDropped rebuild @?= []
          ssGraph afterStart @?= newGraph
          assertBool
            "expected owner state to contain started stab voice"
            (M.member (VoiceKey "s0") (ssVoices afterStart))
          status @?= SessionOwnerReady
        Right other ->
          assertFailure ("expected owner hot-swap then voice-start, got: "
                         <> show other)

  , testCase "owner unsupported preserving hot-swap rejection is non-terminal" $ do
      let graph    = patternTemplates droneVibrato
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          swapCmd  = CmdHotSwap (SwapLabel "preserve") graph
      result <- withSessionOwner graph defaultSessionOwnerOptions $ \owner -> do
        started <- stepSessionOwner owner startCmd
        rejected <- stepSessionOwner owner swapCmd
        status <- sessionOwnerStatus owner
        pure (started, rejected, status)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing),
               SessionOwnerStep (StepRuntimeFailed SriHotSwapWouldPreserveVoices),
               status) ->
          status @?= SessionOwnerReady
        Right other ->
          assertFailure
            ("expected non-terminal preserving hot-swap rejection, got: "
             <> show other)

  , testCase "owner admission rejection is non-terminal" $ do
      let tg  = patternTemplates droneVibrato
          cmd = CmdVoiceOn (TemplateName "missing") (VoiceKey "v0") []
      result <- withSessionOwner tg defaultSessionOwnerOptions $ \owner -> do
        rejected <- stepSessionOwner owner cmd
        status <- sessionOwnerStatus owner
        pure (rejected, status)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepRejected (SiUnknownTemplate (TemplateName "missing"))),
               status) ->
          status @?= SessionOwnerReady
        Right other ->
          assertFailure ("expected non-terminal admission rejection, got: "
                         <> show other)
  ]
