-- | Session Prep D: runtime adapter shell tests.
--
-- Pins 'stepSessionCommand' against mock 'SessionRuntimeAdapter'
-- implementations. No RTGraph, audio backend, or realtime queue is
-- touched at this layer — the real adapter belongs to a later
-- slice and must satisfy the same contract these mock-driven cases
-- assert.
--
-- Coverage:
--
--   * Admission rejection short-circuits before the adapter runs
--     (call counter remains zero).
--   * Voice-start success commits the runtime 'VoiceBinding' and
--     mutates 'SessionState' through the planned commit handshake.
--   * Voice-start runtime failure leaves 'SessionState' unchanged.
--   * A runtime 'CommitVoiceStarted' with a key the plan didn't
--     name surfaces as 'StepCommitMismatch'.
--   * Control-write success leaves 'SessionState' unchanged
--     (control writes have no state commit).
--   * A commit-shaped success on a control-write plan is a
--     protocol mismatch ('SciControlPlanHasNoStateCommit').
--   * Hot-swap success returns the commit-time
--     'ResolveRebuildResult'.
--   * 'RuntimeControlWriteAccepted' on a non-control plan is an
--     adapter protocol bug.
--   * 'PEVoiceOn' flows through 'fromPatternEvent' and
--     'stepSessionCommand' end-to-end.
--
-- Extracted from "MetaSonic.Spec.Session" as the fifth slice of
-- the Session megafile split. 'constantAdapter' stays in the
-- parent module — it is also used by a later cohort in
-- "MetaSonic.Spec.Session" and is imported from there.
module MetaSonic.Spec.Session.Step (sessionStepTests) where

import qualified Data.ByteString.Char8          as OBSC
import           Data.IORef                     (modifyIORef', newIORef,
                                                 readIORef)
import           Data.List                      (isInfixOf)
import qualified Data.Map.Strict                as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source        (MigrationKey (..))
import qualified MetaSonic.OSC.Dispatch         as OSC
import           MetaSonic.Pattern              (ControlTag (..),
                                                 Pattern (patternTemplates),
                                                 PatternEvent (..),
                                                 SwapLabel (..),
                                                 TemplateName (..),
                                                 VoiceKey (..))
import           MetaSonic.Pattern.Corpus       (droneVibrato, polyphonicStab)
import           MetaSonic.Session.Command
import           MetaSonic.Session.Resolve
import           MetaSonic.Session.Runtime
import           MetaSonic.Session.State
import           MetaSonic.Session.Step

import           MetaSonic.Spec.Session         (constantAdapter)


sessionStepTests :: TestTree
sessionStepTests = testGroup "Session Prep D: runtime adapter shell"
  [ testCase "admission rejection does not call the runtime adapter" $ do
      counter <- newIORef (0 :: Int)
      let adapter = SessionRuntimeAdapter $ \_ -> do
            modifyIORef' counter (+1)
            pure (Left SriBackendStopped)
          st  = initialSessionState (patternTemplates droneVibrato)
          cmd = CmdVoiceOn (TemplateName "missing") (VoiceKey "v0") []
      result <- stepSessionCommand adapter cmd st
      result @?= StepRejected (SiUnknownTemplate (TemplateName "missing"))
      calls <- readIORef counter
      calls @?= 0

  , testCase "voice-start success commits the runtime VoiceBinding" $ do
      let st0     = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding (VoiceKey "v0") 17 (TemplateName "drone")
          adapter = constantAdapter
                      (Right (RuntimeCommitted (CommitVoiceStarted binding)))
          cmd     = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      result <- stepSessionCommand adapter cmd st0
      case result of
        StepCommitted st1 rebuild -> do
          rebuild @?= Nothing
          ssVoices st1 @?= M.fromList [(VoiceKey "v0", binding)]
          OSC.resolveStateVoices (ssResolve st1)
            @?= M.fromList [(OBSC.pack "v0", (17, OBSC.pack "drone"))]
        other ->
          assertFailure ("expected StepCommitted, got: " <> show other)

  , testCase "voice-start runtime failure leaves state unchanged" $ do
      let st0     = initialSessionState (patternTemplates droneVibrato)
          adapter = constantAdapter (Left SriVoiceAllocationFailed)
          cmd     = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      result <- stepSessionCommand adapter cmd st0
      result @?= StepRuntimeFailed SriVoiceAllocationFailed
      admitSessionCommand cmd st0
        @?= SessionAdmitted cmd
              (PlanVoiceStart (TemplateName "drone") (VoiceKey "v0") [])

  , testCase "wrong runtime commit surfaces as StepCommitMismatch" $ do
      let st0       = initialSessionState (patternTemplates droneVibrato)
          wrongBind = VoiceBinding (VoiceKey "v1") 17 (TemplateName "drone")
          adapter   = constantAdapter
                        (Right (RuntimeCommitted (CommitVoiceStarted wrongBind)))
          cmd       = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      result <- stepSessionCommand adapter cmd st0
      result @?= StepCommitMismatch
                   (SciVoiceKeyMismatch (VoiceKey "v0") (VoiceKey "v1"))

  , testCase "control-write success leaves SessionState unchanged" $ do
      let graph   = patternTemplates droneVibrato
          binding = VoiceBinding (VoiceKey "v0") 17 (TemplateName "drone")
          st0     = applySessionCommit
                      (CommitVoiceStarted binding)
                      (initialSessionState graph)
          adapter = constantAdapter (Right RuntimeControlWriteAccepted)
          cmd     = CmdControlWrite
                      (VoiceKey "v0")
                      (ControlTag (MigrationKey "lpf") 0)
                      1800.0
      result <- stepSessionCommand adapter cmd st0
      result @?= StepControlAccepted
      admitSessionCommand cmd st0
        @?= SessionAdmitted cmd
              (PlanControlWrite binding (ControlTag (MigrationKey "lpf") 0) 1800.0)

  , testCase "commit-shaped success on control-write is a commit mismatch" $ do
      let graph   = patternTemplates droneVibrato
          binding = VoiceBinding (VoiceKey "v0") 17 (TemplateName "drone")
          st0     = applySessionCommit
                      (CommitVoiceStarted binding)
                      (initialSessionState graph)
          commit  = CommitVoiceStopped (VoiceKey "v0")
          adapter = constantAdapter (Right (RuntimeCommitted commit))
          cmd     = CmdControlWrite
                      (VoiceKey "v0")
                      (ControlTag (MigrationKey "lpf") 0)
                      1800.0
      result <- stepSessionCommand adapter cmd st0
      result @?= StepCommitMismatch SciControlPlanHasNoStateCommit
      ssVoices (applySessionCommit commit st0) @?= M.empty

  , testCase "hot-swap success returns commit-time ResolveRebuildResult" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          binding  = VoiceBinding (VoiceKey "v0") 17 (TemplateName "drone")
          st0      = applySessionCommit
                       (CommitVoiceStarted binding)
                       (initialSessionState oldGraph)
          adapter  = constantAdapter
                       (Right (RuntimeCommitted
                                 (CommitGraphInstalled (SwapLabel "swap") newGraph)))
          cmd      = CmdHotSwap (SwapLabel "swap") newGraph
          expected = [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
      result <- stepSessionCommand adapter cmd st0
      case result of
        StepCommitted st1 (Just rebuild) -> do
          ssGraph st1 @?= newGraph
          ssVoices st1 @?= M.empty
          rrrDropped rebuild @?= expected
        other ->
          assertFailure ("expected StepCommitted with rebuild, got: " <> show other)

  , testCase "control-write ack on a non-control plan is a protocol bug" $ do
      let st0     = initialSessionState (patternTemplates droneVibrato)
          adapter = constantAdapter (Right RuntimeControlWriteAccepted)
          cmd     = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      result <- stepSessionCommand adapter cmd st0
      case result of
        StepAdapterProtocolBug msg ->
          assertBool ("expected PlanVoiceStart in protocol-bug message: " <> msg)
                     ("PlanVoiceStart" `isInfixOf` msg)
        other ->
          assertFailure ("expected StepAdapterProtocolBug, got: " <> show other)

  , testCase "PEVoiceOn flows through fromPatternEvent and stepSessionCommand" $ do
      let st0     = initialSessionState (patternTemplates droneVibrato)
          ev      = PEVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          cmd     = fromPatternEvent ev
          binding = VoiceBinding (VoiceKey "v0") 17 (TemplateName "drone")
          adapter = constantAdapter
                      (Right (RuntimeCommitted (CommitVoiceStarted binding)))
      result <- stepSessionCommand adapter cmd st0
      case result of
        StepCommitted st1 Nothing ->
          ssVoices st1 @?= M.fromList [(VoiceKey "v0", binding)]
        other ->
          assertFailure ("expected StepCommitted via pattern event, got: " <> show other)
  ]
