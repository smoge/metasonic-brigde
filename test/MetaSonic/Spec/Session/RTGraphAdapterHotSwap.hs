-- | Session Prep E: RTGraph adapter hot-swap and preserving-
-- migration tests.
--
-- These cases drive 'stepSessionCommand' against the real RTGraph
-- adapter (via 'withInstalledAdapter') for every hot-swap shape:
-- plain graph install on an empty session, the rebuild-forbidden
-- preserving-only path, install failure that preserves the
-- structured setup issue, drops that fall out of a destructive
-- swap, unsupported preserving rejection (both
-- 'CmdHotSwap' and 'CmdHotSwapPreservingOnly'), and preserving
-- migration that keeps live voices' runtime slots through the
-- swap (single voice and two voices). Together with
-- "MetaSonic.Spec.Session.RTGraphAdapterInstall" this closes the
-- Prep E RTGraph-adapter behavior surface.
--
-- Coverage:
--
--   * Empty-session 'CmdHotSwap' installs the new graph; a
--     follow-up voice start succeeds on the post-swap template
--     set.
--   * 'CmdHotSwapPreservingOnly' on an empty session is rejected
--     with 'SriHotSwapRebuildForbidden' and the original graph
--     stays usable.
--   * 'CmdHotSwap' install failure surfaces the structured
--     'SasiDuplicateTemplateName' inside 'SriHotSwapInstallFailed'.
--   * 'CmdHotSwap' that drops every live voice installs and
--     reports drops; the new graph commits with an empty voice
--     map.
--   * Unsupported preserving via either 'CmdHotSwap' or
--     'CmdHotSwapPreservingOnly' rejects with
--     'SriHotSwapWouldPreserveVoices' and leaves the live voice's
--     runtime slot Live.
--   * Preserving migration of a supported active voice keeps the
--     same 'VoiceBinding' across swaps, advances the runtime
--     swap generation counter, and accepts a follow-up
--     control-write.
--   * Both 'CmdHotSwap' and 'CmdHotSwapPreservingOnly' paths
--     share that migration behavior.
--   * Two-voice preserving migration keeps both bindings and
--     leaves both runtime slots Live.
--
-- Extracted from "MetaSonic.Spec.Session" as the eighth slice of
-- the Session megafile split. 'compileTemplateGraphOrFail' moved
-- to "MetaSonic.Spec.SessionShared" in the same commit because
-- three of the cases depend on it and two of its remaining
-- callers still live in the parent module.
module MetaSonic.Spec.Session.RTGraphAdapterHotSwap
  ( sessionRTGraphAdapterHotSwapTests
  ) where

import qualified Data.Map.Strict                 as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.Demos              (dronePreserveSmoothCutoffBright,
                                                   dronePreserveSmoothCutoffDark)
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.Source         (MigrationKey (..))
import           MetaSonic.Pattern               (ControlTag (..),
                                                  Pattern (patternTemplates),
                                                  SwapLabel (..),
                                                  TemplateName (..),
                                                  VoiceKey (..))
import           MetaSonic.Pattern.Corpus        (arpeggioSendReturn,
                                                  droneVibrato, hotSwapEdit,
                                                  hotSwapEditAfterTemplates,
                                                  polyphonicStab)
import           MetaSonic.Session.Command
import           MetaSonic.Session.RTGraphAdapter
import           MetaSonic.Session.Resolve
import           MetaSonic.Session.Runtime
import           MetaSonic.Session.State
import           MetaSonic.Session.Step

import           MetaSonic.Spec.SessionShared    (compileTemplateGraphOrFail,
                                                  duplicateFirstTwoTemplates,
                                                  withInstalledAdapter)


sessionRTGraphAdapterHotSwapTests :: TestTree
sessionRTGraphAdapterHotSwapTests =
  testGroup "Session Prep E: RTGraph adapter hot-swap"
  [ testCase "step hot-swap of empty session installs new graph" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          st0      = initialSessionState oldGraph
          swapCmd  = CmdHotSwap (SwapLabel "to-stab") newGraph
          startCmd = CmdVoiceOn (TemplateName "stab") (VoiceKey "s0") []
      withInstalledAdapter oldGraph defaultRTGraphAdapterOptions $ \_rt adapter -> do
        -- The runtime side is exercised indirectly through the
        -- post-swap voice start; no direct FFI probe is needed here.
        swapped <- stepSessionCommand adapter swapCmd st0
        case swapped of
          StepCommitted st1 (Just rebuild) -> do
            ssGraph st1 @?= newGraph
            ssVoices st1 @?= M.empty
            rrrDropped rebuild @?= []
            started <- stepSessionCommand adapter startCmd st1
            case started of
              StepCommitted st2 Nothing ->
                assertBool
                  "expected stab voice after adapter metadata update"
                  (M.member (VoiceKey "s0") (ssVoices st2))
              other ->
                assertFailure ("expected post-swap voice start, got: " <> show other)
          other ->
            assertFailure ("expected empty-session hot-swap commit, got: "
                           <> show other)

  , testCase "preserving-only hot-swap rejects empty-session rebuild fallback" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          st0      = initialSessionState oldGraph
          swapCmd  = CmdHotSwapPreservingOnly (SwapLabel "to-stab") newGraph
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      withInstalledAdapter oldGraph defaultRTGraphAdapterOptions $ \_rt adapter -> do
        swapped <- stepSessionCommand adapter swapCmd st0
        swapped @?= StepRuntimeFailed SriHotSwapRebuildForbidden

        -- The adapter must not have taken the clear/rebuild fallback.
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing ->
            assertBool
              "expected original graph to remain usable after rejection"
              (M.member (VoiceKey "v0") (ssVoices st1))
          other ->
            assertFailure ("expected original-graph voice start, got: "
                           <> show other)

  , testCase "step hot-swap install failure preserves structured setup issue" $ do
      let oldGraph = patternTemplates droneVibrato
          base     = patternTemplates arpeggioSendReturn
          newGraph = duplicateFirstTwoTemplates base
          st0     = initialSessionState oldGraph
          swapCmd = CmdHotSwap (SwapLabel "bad-graph") newGraph
      withInstalledAdapter oldGraph defaultRTGraphAdapterOptions $ \_rt adapter -> do
        swapped <- stepSessionCommand adapter swapCmd st0
        swapped @?= StepRuntimeFailed
          (SriHotSwapInstallFailed
            (SasiDuplicateTemplateName (TemplateName "dup")))

  , testCase "step hot-swap that drops active voices installs and reports drops" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          st0      = initialSessionState oldGraph
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          swapCmd  = CmdHotSwap (SwapLabel "drop-drone") newGraph
          expected = [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
      withInstalledAdapter oldGraph defaultRTGraphAdapterOptions $ \_rt adapter -> do
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing -> do
            swapped <- stepSessionCommand adapter swapCmd st1
            case swapped of
              StepCommitted st2 (Just rebuild) -> do
                ssGraph st2 @?= newGraph
                ssVoices st2 @?= M.empty
                rrrDropped rebuild @?= expected
              other ->
                assertFailure ("expected dropping hot-swap commit, got: "
                               <> show other)
          other ->
            assertFailure ("expected start commit, got: " <> show other)

  , testCase "step unsupported preserving hot-swap is rejected" $ do
      let graph    = patternTemplates droneVibrato
          st0      = initialSessionState graph
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          swapCmd  = CmdHotSwap (SwapLabel "preserve-drone") graph
      withInstalledAdapter graph defaultRTGraphAdapterOptions $ \rt adapter -> do
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing ->
            case M.lookup (VoiceKey "v0") (ssVoices st1) of
              Nothing ->
                assertFailure "expected committed voice binding"
              Just binding -> do
                c_rt_graph_process rt 1
                before <- c_rt_graph_instance_status
                            rt
                            (fromIntegral (vbSlotId binding))
                before @?= instanceStatusLive
                swapped <- stepSessionCommand adapter swapCmd st1
                swapped @?= StepRuntimeFailed SriHotSwapWouldPreserveVoices
                afterStatus <- c_rt_graph_instance_status
                                 rt
                                 (fromIntegral (vbSlotId binding))
                afterStatus @?= instanceStatusLive
          other ->
            assertFailure ("expected start commit, got: " <> show other)

  , testCase "preserving-only unsupported hot-swap rejects without rebuild" $ do
      let graph    = patternTemplates droneVibrato
          st0      = initialSessionState graph
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          swapCmd  = CmdHotSwapPreservingOnly
                       (SwapLabel "preserve-drone-only")
                       graph
      withInstalledAdapter graph defaultRTGraphAdapterOptions $ \rt adapter -> do
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing ->
            case M.lookup (VoiceKey "v0") (ssVoices st1) of
              Nothing ->
                assertFailure "expected committed voice binding"
              Just binding -> do
                c_rt_graph_process rt 1
                before <- c_rt_graph_instance_status
                            rt
                            (fromIntegral (vbSlotId binding))
                before @?= instanceStatusLive
                swapped <- stepSessionCommand adapter swapCmd st1
                swapped @?= StepRuntimeFailed SriHotSwapWouldPreserveVoices
                afterStatus <- c_rt_graph_instance_status
                                 rt
                                 (fromIntegral (vbSlotId binding))
                afterStatus @?= instanceStatusLive
          other ->
            assertFailure ("expected start commit, got: " <> show other)

  , testCase "step preserving hot-swap migrates supported active voice" $ do
      newGraph <- compileTemplateGraphOrFail hotSwapEditAfterTemplates
      let oldGraph = patternTemplates hotSwapEdit
          st0      = initialSessionState oldGraph
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0")
                       [(ControlTag (MigrationKey "lpf") 0, 1500.0)]
          swapCmd  = CmdHotSwap (SwapLabel "edit-cutoff") newGraph
          writeCmd = CmdControlWrite
                       (VoiceKey "v0")
                       (ControlTag (MigrationKey "lpf") 0)
                       3300.0
      withInstalledAdapter oldGraph defaultRTGraphAdapterOptions $ \rt adapter -> do
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing ->
            case M.lookup (VoiceKey "v0") (ssVoices st1) of
              Nothing ->
                assertFailure "expected committed voice binding"
              Just binding -> do
                c_rt_graph_process rt 1
                beforeStatus <- c_rt_graph_instance_status
                                  rt
                                  (fromIntegral (vbSlotId binding))
                beforeStatus @?= instanceStatusLive
                beforeGeneration <- readSwapGeneration rt
                swapped <- stepSessionCommand adapter swapCmd st1
                case swapped of
                  StepCommitted st2 (Just rebuild) -> do
                    rrrDropped rebuild @?= []
                    ssGraph st2 @?= newGraph
                    M.lookup (VoiceKey "v0") (ssVoices st2) @?= Just binding
                    afterGeneration <- readSwapGeneration rt
                    assertBool
                      "expected preserving swap generation to advance"
                      (afterGeneration > beforeGeneration)
                    afterStatus <- c_rt_graph_instance_status
                                     rt
                                     (fromIntegral (vbSlotId binding))
                    afterStatus @?= instanceStatusLive
                    written <- stepSessionCommand adapter writeCmd st2
                    written @?= StepControlAccepted
                  other ->
                    assertFailure
                      ("expected preserving hot-swap commit, got: "
                       <> show other)
          other ->
            assertFailure ("expected start commit, got: " <> show other)

  , testCase "preserving-only hot-swap migrates supported active voice" $ do
      newGraph <- compileTemplateGraphOrFail hotSwapEditAfterTemplates
      let oldGraph = patternTemplates hotSwapEdit
          st0      = initialSessionState oldGraph
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0")
                       [(ControlTag (MigrationKey "lpf") 0, 1500.0)]
          swapCmd  =
            CmdHotSwapPreservingOnly (SwapLabel "manifest-edit") newGraph
      withInstalledAdapter oldGraph defaultRTGraphAdapterOptions $ \rt adapter -> do
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing ->
            case M.lookup (VoiceKey "v0") (ssVoices st1) of
              Nothing ->
                assertFailure "expected committed voice binding"
              Just binding -> do
                c_rt_graph_process rt 1
                beforeStatus <- c_rt_graph_instance_status
                                  rt
                                  (fromIntegral (vbSlotId binding))
                beforeStatus @?= instanceStatusLive
                beforeGeneration <- readSwapGeneration rt
                swapped <- stepSessionCommand adapter swapCmd st1
                case swapped of
                  StepCommitted st2 (Just rebuild) -> do
                    rrrDropped rebuild @?= []
                    ssGraph st2 @?= newGraph
                    M.lookup (VoiceKey "v0") (ssVoices st2) @?= Just binding
                    afterGeneration <- readSwapGeneration rt
                    assertBool
                      "expected preserving-only swap generation to advance"
                      (afterGeneration > beforeGeneration)
                    afterStatus <- c_rt_graph_instance_status
                                     rt
                                     (fromIntegral (vbSlotId binding))
                    afterStatus @?= instanceStatusLive
                  other ->
                    assertFailure
                      ("expected preserving-only hot-swap commit, got: "
                       <> show other)
          other ->
            assertFailure ("expected start commit, got: " <> show other)

  , testCase "preserving-only hot-swap migrates KSmooth active voice" $ do
      oldGraph <- compileTemplateGraphOrFail
        [("drone", dronePreserveSmoothCutoffDark)]
      newGraph <- compileTemplateGraphOrFail
        [("drone", dronePreserveSmoothCutoffBright)]
      let st0      = initialSessionState oldGraph
          voice    = VoiceKey "v0"
          startCmd = CmdVoiceOn (TemplateName "drone") voice []
          swapCmd  = CmdHotSwapPreservingOnly
                       (SwapLabel "smooth-cutoff")
                       newGraph
          writeCmd = CmdControlWrite
                       voice
                       (ControlTag (MigrationKey "cutoff") 1)
                       1800.0
      withInstalledAdapter oldGraph defaultRTGraphAdapterOptions $ \rt adapter -> do
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing ->
            case M.lookup voice (ssVoices st1) of
              Nothing ->
                assertFailure "expected committed voice binding"
              Just binding -> do
                c_rt_graph_process rt 1
                beforeStatus <- c_rt_graph_instance_status
                                  rt
                                  (fromIntegral (vbSlotId binding))
                beforeStatus @?= instanceStatusLive
                beforeGeneration <- readSwapGeneration rt
                swapped <- stepSessionCommand adapter swapCmd st1
                case swapped of
                  StepCommitted st2 (Just rebuild) -> do
                    rrrDropped rebuild @?= []
                    ssGraph st2 @?= newGraph
                    M.lookup voice (ssVoices st2) @?= Just binding
                    afterGeneration <- readSwapGeneration rt
                    assertBool
                      "expected KSmooth migration swap generation to advance"
                      (afterGeneration > beforeGeneration)
                    afterStatus <- c_rt_graph_instance_status
                                     rt
                                     (fromIntegral (vbSlotId binding))
                    afterStatus @?= instanceStatusLive
                    written <- stepSessionCommand adapter writeCmd st2
                    written @?= StepControlAccepted
                  other ->
                    assertFailure
                      ("expected KSmooth preserving hot-swap commit, got: "
                       <> show other)
          other ->
            assertFailure ("expected start commit, got: " <> show other)

  , testCase "step preserving hot-swap migrates two supported active voices" $ do
      newGraph <- compileTemplateGraphOrFail hotSwapEditAfterTemplates
      let oldGraph = patternTemplates hotSwapEdit
          opts     = defaultRTGraphAdapterOptions
            { raoDefaultPolyphony = 2
            }
          st0      = initialSessionState oldGraph
          v0       = VoiceKey "v0"
          v1       = VoiceKey "v1"
          start key cutoff =
            CmdVoiceOn (TemplateName "drone") key
              [(ControlTag (MigrationKey "lpf") 0, cutoff)]
          swapCmd  = CmdHotSwap (SwapLabel "edit-two") newGraph
      withInstalledAdapter oldGraph opts $ \rt adapter -> do
        started0 <- stepSessionCommand adapter (start v0 1200.0) st0
        case started0 of
          StepCommitted st1 Nothing -> do
            started1 <- stepSessionCommand adapter (start v1 1800.0) st1
            case started1 of
              StepCommitted st2 Nothing -> do
                case (M.lookup v0 (ssVoices st2), M.lookup v1 (ssVoices st2)) of
                  (Just binding0, Just binding1) -> do
                    c_rt_graph_process rt 1
                    before0 <- c_rt_graph_instance_status
                                 rt
                                 (fromIntegral (vbSlotId binding0))
                    before1 <- c_rt_graph_instance_status
                                 rt
                                 (fromIntegral (vbSlotId binding1))
                    before0 @?= instanceStatusLive
                    before1 @?= instanceStatusLive
                    swapped <- stepSessionCommand adapter swapCmd st2
                    case swapped of
                      StepCommitted st3 (Just rebuild) -> do
                        rrrDropped rebuild @?= []
                        ssGraph st3 @?= newGraph
                        M.lookup v0 (ssVoices st3) @?= Just binding0
                        M.lookup v1 (ssVoices st3) @?= Just binding1
                        after0 <- c_rt_graph_instance_status
                                    rt
                                    (fromIntegral (vbSlotId binding0))
                        after1 <- c_rt_graph_instance_status
                                    rt
                                    (fromIntegral (vbSlotId binding1))
                        after0 @?= instanceStatusLive
                        after1 @?= instanceStatusLive
                      other ->
                        assertFailure
                          ("expected two-voice preserving hot-swap commit, got: "
                           <> show other)
                  other ->
                    assertFailure
                      ("expected two committed voice bindings, got: "
                       <> show other)
              other ->
                assertFailure
                  ("expected second start commit, got: " <> show other)
          other ->
            assertFailure ("expected first start commit, got: " <> show other)
  ]
