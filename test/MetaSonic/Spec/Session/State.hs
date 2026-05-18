-- | Session Prep B/C: pure admission, commit state, and handshake
-- tests.
--
-- Pins the split between read-only command admission and state-
-- changing commits, plus the Prep C checked plan/commit handshake.
-- The cases do not allocate runtime voices, install graphs, write
-- queues, or touch RTGraph.
--
-- Coverage:
--
--   * Initial state behavior (empty graph rejects unknown templates).
--   * Voice-start: admission plans without mutating state; commit
--     inserts the binding + OSC resolve entry; loud failure on an
--     invariant-violating committed binding.
--   * Voice-off / control-write: admission requires an active voice,
--     stale targets reject without mutation.
--   * Hot-swap: admission previews drops, commit reports the
--     authoritative drop set, resolve state rebuilds, surviving
--     voices stay bound.
--   * Planned plan/commit handshake: matching commits apply, all
--     mismatches reject the commit without mutation (key,
--     template, ctor, swap-label, graph-identity, and the no-
--     state-commit rule for PlanControlWrite).
--
-- Extracted from "MetaSonic.Spec.Session" as the fourth slice of
-- the Session megafile split. Like the prior three Prep A slices,
-- the cases depend only on public surfaces; no shared helpers
-- from "MetaSonic.Spec.SessionShared" needed at this slice.
module MetaSonic.Spec.Session.State (sessionStateTests) where

import           Control.Exception              (SomeException,
                                                 displayException,
                                                 evaluate, try)
import           Control.Monad                  (forM_)
import qualified Data.ByteString.Char8          as OBSC
import           Data.List                      (isInfixOf)
import qualified Data.Map.Strict                as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source        (MigrationKey (..))
import           MetaSonic.Bridge.Templates     (TemplateGraph (..))
import qualified MetaSonic.OSC.Dispatch         as OSC
import           MetaSonic.Pattern              (ControlTag (..),
                                                 Pattern (patternTemplates),
                                                 SwapLabel (..),
                                                 TemplateName (..),
                                                 VoiceKey (..))
import           MetaSonic.Pattern.Corpus       (droneVibrato, polyphonicStab)
import           MetaSonic.Session.Command
import           MetaSonic.Session.Resolve
import           MetaSonic.Session.State


sessionStateTests :: TestTree
sessionStateTests = testGroup "Session Prep B/C: admission, commits, and handshake"
  [ testCase "initial state accepts an empty graph as boot state" $ do
      let bootGraph = TemplateGraph [] M.empty
          st  = initialSessionState bootGraph
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      ssGraph st @?= bootGraph
      ssVoices st @?= M.empty
      OSC.resolveStateVoices (ssResolve st) @?= M.empty
      admitSessionCommand cmd st
        @?= SessionRejected cmd (SiUnknownTemplate (TemplateName "drone"))

  , testCase "known-template voice start plans without mutating state" $ do
      let tg       = patternTemplates droneVibrato
          st       = initialSessionState tg
          controls = [(ControlTag (MigrationKey "amp") 0, 0.25)]
          cmd      = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") controls
      admitSessionCommand cmd st
        @?= SessionAdmitted cmd
              (PlanVoiceStart (TemplateName "drone") (VoiceKey "v0") controls)
      ssVoices st @?= M.empty
      OSC.resolveStateVoices (ssResolve st) @?= M.empty

  , testCase "admitted voice start has no effect without commit" $ do
      let tg  = patternTemplates droneVibrato
          st  = initialSessionState tg
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          off = CmdVoiceOff (VoiceKey "v0")
      admitSessionCommand cmd st
        @?= SessionAdmitted cmd
              (PlanVoiceStart (TemplateName "drone") (VoiceKey "v0") [])
      -- Simulated runtime failure: no CommitVoiceStarted is applied.
      ssVoices st @?= M.empty
      OSC.resolveStateVoices (ssResolve st) @?= M.empty
      admitSessionCommand off st
        @?= SessionRejected off (SiStaleVoice (VoiceKey "v0"))

  , testCase "unknown template and malformed keys reject at admission" $ do
      let st = initialSessionState (patternTemplates droneVibrato)
          unknown =
            CmdVoiceOn (TemplateName "missing") (VoiceKey "v0") []
          malformed =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "bad/key") []
          reserved =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "swap") []
      admitSessionCommand unknown st
        @?= SessionRejected unknown (SiUnknownTemplate (TemplateName "missing"))
      admitSessionCommand malformed st
        @?= SessionRejected malformed (SiInvalidVoiceKey (VoiceKey "bad/key"))
      admitSessionCommand reserved st
        @?= SessionRejected reserved (SiInvalidVoiceKey (VoiceKey "swap"))

  , testCase "voice-start commit inserts binding and resolve entry" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding
            { vbVoiceKey     = VoiceKey "v0"
            , vbSlotId       = 11
            , vbTemplateName = TemplateName "drone"
            }
          st1 = applySessionCommit (CommitVoiceStarted binding) st0
      ssVoices st1 @?= M.fromList [(VoiceKey "v0", binding)]
      OSC.resolveStateVoices (ssResolve st1)
        @?= M.fromList [(OBSC.pack "v0", (11, OBSC.pack "drone"))]

  , testCase "voice-start commit rejects invalid runtime binding loudly" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding (VoiceKey "bad/key") 11 (TemplateName "drone")
      thrown <- try (evaluate (applySessionCommit (CommitVoiceStarted binding) st0))
                  :: IO (Either SomeException SessionState)
      case thrown of
        Left ex ->
          assertBool
            "exception should explain the SessionCommit invariant"
            ("invariant violated" `isInfixOf` displayException ex)
        Right _ ->
          assertFailure "expected invalid committed binding to fail loudly"

  , testCase "duplicate active voice rejects after start commit" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding (VoiceKey "v0") 11 (TemplateName "drone")
          st1 = applySessionCommit (CommitVoiceStarted binding) st0
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      admitSessionCommand cmd st1
        @?= SessionRejected cmd (SiVoiceAlreadyActive (VoiceKey "v0"))

  , testCase "voice off and control write plan only for active voices" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding (VoiceKey "v0") 11 (TemplateName "drone")
          st1 = applySessionCommit (CommitVoiceStarted binding) st0
          target = ControlTag (MigrationKey "lpf") 0
          off = CmdVoiceOff (VoiceKey "v0")
          write = CmdControlWrite (VoiceKey "v0") target 1800.0
          staleOff = CmdVoiceOff (VoiceKey "missing")
          staleWrite = CmdControlWrite (VoiceKey "missing") target 1800.0
      admitSessionCommand off st1
        @?= SessionAdmitted off (PlanVoiceStop binding)
      admitSessionCommand write st1
        @?= SessionAdmitted write (PlanControlWrite binding target 1800.0)
      admitSessionCommand staleOff st1
        @?= SessionRejected staleOff (SiStaleVoice (VoiceKey "missing"))
      admitSessionCommand staleWrite st1
        @?= SessionRejected staleWrite (SiStaleVoice (VoiceKey "missing"))

  , testCase "voice-stop commit removes binding and resolve entry" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding (VoiceKey "v0") 11 (TemplateName "drone")
          st1 = applySessionCommit (CommitVoiceStarted binding) st0
          st2 = applySessionCommit (CommitVoiceStopped (VoiceKey "v0")) st1
      ssVoices st2 @?= M.empty
      OSC.resolveStateVoices (ssResolve st2) @?= M.empty

  , testCase "hot-swap admission previews drops without installing graph" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          binding = VoiceBinding (VoiceKey "v0") 11 (TemplateName "drone")
          st0 = applySessionCommit
                  (CommitVoiceStarted binding)
                  (initialSessionState oldGraph)
          cmd = CmdHotSwap (SwapLabel "remove-drone") newGraph
          expectedDrop =
            [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
      case admitSessionCommand cmd st0 of
        SessionAdmitted _ (PlanHotSwap mode _ graph preview) -> do
          mode @?= HotSwapAllowRebuild
          graph @?= newGraph
          rrrDropped preview @?= expectedDrop
        other ->
          assertFailure ("expected hot-swap plan, got: " <> show other)
      ssGraph st0 @?= oldGraph
      OSC.resolveStateTemplate (ssResolve st0) @?= oldGraph

  , testCase "graph-install commit reports authoritative drops" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          binding0 = VoiceBinding (VoiceKey "v0") 11 (TemplateName "drone")
          binding1 = VoiceBinding (VoiceKey "v1") 12 (TemplateName "drone")
          st0 = applySessionCommit
                  (CommitVoiceStarted binding0)
                  (initialSessionState oldGraph)
          cmd = CmdHotSwap (SwapLabel "remove-drone") newGraph
          previewDrop =
            [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
          commitDrop =
            [ RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")
            , RriMissingTemplate (VoiceKey "v1") (TemplateName "drone")
            ]
      case admitSessionCommand cmd st0 of
        SessionAdmitted _ (PlanHotSwap _ _ _ preview) ->
          rrrDropped preview @?= previewDrop
        other ->
          assertFailure ("expected hot-swap plan, got: " <> show other)
      let st1 = applySessionCommit (CommitVoiceStarted binding1) st0
          (st2, committed) =
            commitGraphInstalled (SwapLabel "remove-drone") newGraph st1
      rrrDropped committed @?= commitDrop
      ssVoices st2 @?= M.empty
      OSC.resolveStateTemplate (ssResolve st2) @?= newGraph

  , testCase "graph-install commit rebuilds resolve and drops missing voices" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          binding = VoiceBinding (VoiceKey "v0") 11 (TemplateName "drone")
          st0 = applySessionCommit
                  (CommitVoiceStarted binding)
                  (initialSessionState oldGraph)
          (st1, result) =
            commitGraphInstalled (SwapLabel "remove-drone") newGraph st0
      ssGraph st1 @?= newGraph
      ssVoices st1 @?= M.empty
      OSC.resolveStateTemplate (ssResolve st1) @?= newGraph
      OSC.resolveStateVoices (ssResolve st1) @?= M.empty
      rrrDropped result
        @?= [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]

  , testCase "graph-install commit preserves surviving voices" $ do
      let graph = patternTemplates droneVibrato
          binding = VoiceBinding (VoiceKey "v0") 11 (TemplateName "drone")
          st0 = applySessionCommit
                  (CommitVoiceStarted binding)
                  (initialSessionState graph)
          (st1, result) = commitGraphInstalled (SwapLabel "same") graph st0
      ssGraph st1 @?= graph
      ssVoices st1 @?= M.fromList [(VoiceKey "v0", binding)]
      OSC.resolveStateVoices (ssResolve st1)
        @?= M.fromList [(OBSC.pack "v0", (11, OBSC.pack "drone"))]
      rrrDropped result @?= []

  , testCase "planned voice-start accepts matching commit" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          plan = PlanVoiceStart (TemplateName "drone") (VoiceKey "v0") []
          binding = VoiceBinding (VoiceKey "v0") 21 (TemplateName "drone")
          commit = CommitVoiceStarted binding
      case applyPlannedCommit plan commit st0 of
        Right (st1, result) -> do
          result @?= Nothing
          ssVoices st1 @?= M.fromList [(VoiceKey "v0", binding)]
          OSC.resolveStateVoices (ssResolve st1)
            @?= M.fromList [(OBSC.pack "v0", (21, OBSC.pack "drone"))]
        Left issue ->
          assertFailure ("expected planned voice-start commit, got: " <> show issue)

  , testCase "planned voice-start rejects mismatches without mutation" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          plan = PlanVoiceStart (TemplateName "drone") (VoiceKey "v0") []
          wrongKeyBinding =
            VoiceBinding (VoiceKey "v1") 21 (TemplateName "drone")
          wrongKey = CommitVoiceStarted wrongKeyBinding
          wrongTemplate = CommitVoiceStarted
            (VoiceBinding (VoiceKey "v0") 21 (TemplateName "other"))
          wrongCtor = CommitVoiceStopped (VoiceKey "v0")
      applyPlannedCommit plan wrongKey st0
        @?= Left (SciVoiceKeyMismatch (VoiceKey "v0") (VoiceKey "v1"))
      applyPlannedCommit plan wrongTemplate st0
        @?= Left (SciTemplateMismatch (TemplateName "drone") (TemplateName "other"))
      applyPlannedCommit plan wrongCtor st0
        @?= Left (SciUnexpectedCommit plan wrongCtor)
      let directWrongKey = applySessionCommit wrongKey st0
      ssVoices directWrongKey @?= M.fromList [(VoiceKey "v1", wrongKeyBinding)]
      OSC.resolveStateVoices (ssResolve directWrongKey)
        @?= M.fromList [(OBSC.pack "v1", (21, OBSC.pack "drone"))]

  , testCase "planned voice-stop accepts matching commit" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding (VoiceKey "v0") 21 (TemplateName "drone")
          st1 = applySessionCommit (CommitVoiceStarted binding) st0
          plan = PlanVoiceStop binding
          commit = CommitVoiceStopped (VoiceKey "v0")
      case applyPlannedCommit plan commit st1 of
        Right (st2, result) -> do
          result @?= Nothing
          ssVoices st2 @?= M.empty
          OSC.resolveStateVoices (ssResolve st2) @?= M.empty
        Left issue ->
          assertFailure ("expected planned voice-stop commit, got: " <> show issue)

  , testCase "planned voice-stop rejects mismatches without mutation" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding (VoiceKey "v0") 21 (TemplateName "drone")
          st1 = applySessionCommit (CommitVoiceStarted binding) st0
          plan = PlanVoiceStop binding
          wrongKey = CommitVoiceStopped (VoiceKey "v1")
          wrongStartBinding =
            VoiceBinding (VoiceKey "v0") 22 (TemplateName "drone")
          wrongCtor = CommitVoiceStarted wrongStartBinding
      applyPlannedCommit plan wrongKey st1
        @?= Left (SciVoiceKeyMismatch (VoiceKey "v0") (VoiceKey "v1"))
      applyPlannedCommit plan wrongCtor st1
        @?= Left (SciUnexpectedCommit plan wrongCtor)
      let directWrongCtor = applySessionCommit wrongCtor st1
      ssVoices directWrongCtor
        @?= M.fromList [(VoiceKey "v0", wrongStartBinding)]
      OSC.resolveStateVoices (ssResolve directWrongCtor)
        @?= M.fromList [(OBSC.pack "v0", (22, OBSC.pack "drone"))]

  , testCase "planned control-write rejects all state commits" $ do
      let graph = patternTemplates droneVibrato
          binding = VoiceBinding (VoiceKey "v0") 21 (TemplateName "drone")
          plan = PlanControlWrite
            binding
            (ControlTag (MigrationKey "lpf") 0)
            1800.0
          commits =
            [ CommitVoiceStarted binding
            , CommitVoiceStopped (VoiceKey "v0")
            , CommitGraphInstalled (SwapLabel "same") graph
            ]
      forM_ commits $ \commit ->
        applyPlannedCommit plan commit (initialSessionState graph)
          @?= Left SciControlPlanHasNoStateCommit

  , testCase "planned hot-swap returns authoritative commit-time rebuild" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          swapLabel = SwapLabel "remove-drone"
          binding0 = VoiceBinding (VoiceKey "v0") 21 (TemplateName "drone")
          binding1 = VoiceBinding (VoiceKey "v1") 22 (TemplateName "drone")
          st0 = applySessionCommit
                  (CommitVoiceStarted binding0)
                  (initialSessionState oldGraph)
          cmd = CmdHotSwap swapLabel newGraph
          expectedPreview =
            [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
          expectedCommit =
            [ RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")
            , RriMissingTemplate (VoiceKey "v1") (TemplateName "drone")
            ]
      case admitSessionCommand cmd st0 of
        SessionAdmitted _ plan@(PlanHotSwap _ _ _ preview) -> do
          rrrDropped preview @?= expectedPreview
          let st1 = applySessionCommit (CommitVoiceStarted binding1) st0
              commit = CommitGraphInstalled swapLabel newGraph
          case applyPlannedCommit plan commit st1 of
            Right (st2, Just committed) -> do
              rrrDropped committed @?= expectedCommit
              ssGraph st2 @?= newGraph
              ssVoices st2 @?= M.empty
            other ->
              assertFailure ("expected planned hot-swap commit, got: " <> show other)
        other ->
          assertFailure ("expected hot-swap plan, got: " <> show other)

  , testCase "planned hot-swap rejects mismatches without mutation" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          swapLabel = SwapLabel "remove-drone"
          wrongLabel = SwapLabel "other"
          binding = VoiceBinding (VoiceKey "v0") 21 (TemplateName "drone")
          st0 = applySessionCommit
                  (CommitVoiceStarted binding)
                  (initialSessionState oldGraph)
          plan = PlanHotSwap
                   HotSwapAllowRebuild
                   swapLabel
                   newGraph
                   (rebuildResolveState newGraph [binding])
          wrongLabelCommit = CommitGraphInstalled wrongLabel newGraph
          wrongGraphCommit = CommitGraphInstalled swapLabel oldGraph
          wrongCtor = CommitVoiceStopped (VoiceKey "v0")
      applyPlannedCommit plan wrongLabelCommit st0
        @?= Left (SciSwapLabelMismatch swapLabel wrongLabel)
      applyPlannedCommit plan wrongGraphCommit st0
        @?= Left SciGraphMismatch
      applyPlannedCommit plan wrongCtor st0
        @?= Left (SciUnexpectedCommit plan wrongCtor)
      let directWrongLabel = applySessionCommit wrongLabelCommit st0
      ssGraph directWrongLabel @?= newGraph
      ssVoices directWrongLabel @?= M.empty
      OSC.resolveStateVoices (ssResolve directWrongLabel) @?= M.empty
  ]
