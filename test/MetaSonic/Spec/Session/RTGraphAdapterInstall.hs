-- | Session Prep E: RTGraph adapter install / voice-lifecycle /
-- control-write tests.
--
-- These cases drive 'installSessionGraph' and 'newRTGraphAdapter'
-- against a real RTGraph handle (via 'withInstalledAdapter') and
-- pin the install-side contract: graph install, prewarm
-- reservations, duplicate-name rejection, adapter constructor,
-- voice-start through the planned commit handshake, voice-stop
-- queues a release, and control-write success / unknown-target
-- failure. Hot-swap and preserving-migration cases remain in
-- "MetaSonic.Spec.Session" for the next slice.
--
-- Coverage:
--
--   * 'installSessionGraph' removes the auto-spawn slot, records
--     the prewarm count, and leaves a reservable slot for the
--     realtime reserve.
--   * The configured per-template polyphony is honored end-to-end
--     by the realtime reserve.
--   * Duplicate template names reject before the install commits.
--   * 'newRTGraphAdapter' installs the graph and the constructed
--     adapter can run 'PlanVoiceStart'.
--   * 'stepSessionCommand' voice-start success commits a reserved
--     slot binding; the runtime instance reports
--     'instanceStatusLive'.
--   * 'fromPatternEvent' → 'stepSessionCommand' round-trip drives
--     the same path end-to-end.
--   * Empty-pool voice-start reports allocation failure.
--   * Invalid initial control cancels the reservation back to the
--     available pool.
--   * Voice-stop queues a release and clears the session binding.
--   * Control-write to a known target is accepted; unknown target
--     fails with 'SriControlTargetRejected'.
--
-- Extracted from "MetaSonic.Spec.Session" as the seventh slice of
-- the Session megafile split. The two private helpers
-- 'totalTemplateNodes' / 'withInstalledAdapter' (and the
-- previously-parent-resident 'duplicateFirstTwoTemplates') moved
-- to "MetaSonic.Spec.SessionShared" in the same commit, because
-- the slice-8 hot-swap module needs all three. Group label was
-- renamed from "RTGraph session install" to "RTGraph adapter
-- install" to match the slice-8 "RTGraph adapter hot-swap" label.
module MetaSonic.Spec.Session.RTGraphAdapterInstall
  ( sessionRTGraphAdapterInstallTests
  ) where

import           Control.Monad                   (forM, forM_)
import qualified Data.Map.Strict                 as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.Source         (MigrationKey (..))
import           MetaSonic.ControlTarget         (ControlTargetIssue (..))
import           MetaSonic.Pattern               (ControlTag (..),
                                                  Pattern (patternTemplates),
                                                  PatternEvent (..),
                                                  TemplateName (..),
                                                  VoiceKey (..))
import           MetaSonic.Pattern.Corpus        (arpeggioSendReturn,
                                                  droneVibrato)
import           MetaSonic.Session.Command
import           MetaSonic.Session.RTGraphAdapter
import           MetaSonic.Session.Resolve
import           MetaSonic.Session.Runtime
import           MetaSonic.Session.State
import           MetaSonic.Session.Step

import           MetaSonic.Spec.SessionShared    (duplicateFirstTwoTemplates,
                                                  totalTemplateNodes,
                                                  withInstalledAdapter)


sessionRTGraphAdapterInstallTests :: TestTree
sessionRTGraphAdapterInstallTests =
  testGroup "Session Prep E: RTGraph adapter install"
  [ testCase "session install removes auto-spawn and leaves a reservable slot" $ do
      let tg         = patternTemplates droneVibrato
          totalNodes = totalTemplateNodes tg
      withRTGraph (totalNodes + 8) 64 $ \rt -> do
        result <- installSessionGraph rt tg defaultRTGraphAdapterOptions
        case result of
          Left issue ->
            assertFailure ("expected session graph install, got: " <> show issue)
          Right st -> do
            rtgasTemplateIds st
              @?= M.fromList [(TemplateName "drone", 0)]
            rtgasPrewarmCounts st
              @?= M.fromList [(TemplateName "drone", 1)]
            case M.lookup (TemplateName "drone") (rtgasAutoSpawnedSlots st) of
              Nothing ->
                assertFailure "expected recorded auto-spawn slot for drone"
              Just autoSlot -> do
                status <- c_rt_graph_instance_status rt (fromIntegral autoSlot)
                status @?= (-1)

            count <- c_rt_graph_instance_count rt
            statuses <- forM [0 .. count - 1] $ \slot ->
              c_rt_graph_instance_status rt slot
            assertBool
              ("expected no live logical voices after install, got statuses "
               <> show statuses)
              (all (== (-1)) statuses)

            slot <- c_rt_graph_realtime_reserve rt 0
            assertBool ("expected reserve to claim prewarmed slot, got "
                        <> show slot)
                       (slot >= 0)
            c_rt_graph_realtime_cancel rt slot

  , testCase "configured prewarm count is claimed through realtime reserve" $ do
      let tg         = patternTemplates droneVibrato
          totalNodes = totalTemplateNodes tg
          opts       = defaultRTGraphAdapterOptions
            { raoPerTemplatePolyphony =
                M.singleton (TemplateName "drone") 3
            }
      withRTGraph (totalNodes + 16) 64 $ \rt -> do
        result <- installSessionGraph rt tg opts
        case result of
          Left issue ->
            assertFailure ("expected session graph install, got: " <> show issue)
          Right st -> do
            rtgasPrewarmCounts st
              @?= M.fromList [(TemplateName "drone", 3)]
            slots <- forM [1 .. 3 :: Int] $ \_ ->
              c_rt_graph_realtime_reserve rt 0
            assertBool ("expected three successful reservations, got "
                        <> show slots)
                       (all (>= 0) slots)
            fourth <- c_rt_graph_realtime_reserve rt 0
            fourth @?= (-1)
            forM_ slots (c_rt_graph_realtime_cancel rt)

  , testCase "duplicate template names are rejected before install" $ do
      let base = patternTemplates arpeggioSendReturn
          duplicated = duplicateFirstTwoTemplates base
      withRTGraph 16 64 $ \rt -> do
        result <- installSessionGraph
                    rt
                    duplicated
                    defaultRTGraphAdapterOptions
        result @?= Left (SasiDuplicateTemplateName (TemplateName "dup"))
        templateCount <- c_rt_graph_template_count rt
        instanceCount <- c_rt_graph_instance_count rt
        templateCount @?= 1
        instanceCount @?= 1

  , testCase "adapter constructor installs graph and starts voice through adapter" $ do
      let tg         = patternTemplates droneVibrato
          totalNodes = totalTemplateNodes tg
      withRTGraph (totalNodes + 8) 64 $ \rt -> do
        result <- newRTGraphAdapter rt tg defaultRTGraphAdapterOptions
        case result of
          Left issue ->
            assertFailure ("expected RTGraph adapter, got: " <> show issue)
          Right adapter -> do
            slot <- c_rt_graph_realtime_reserve rt 0
            assertBool ("expected constructor to prewarm reservable slot, got "
                        <> show slot)
                       (slot >= 0)
            c_rt_graph_realtime_cancel rt slot

            outcome <- sraRun adapter
              (PlanVoiceStart (TemplateName "drone") (VoiceKey "v1") [])
            case outcome of
              Right (RuntimeCommitted (CommitVoiceStarted binding)) -> do
                vbVoiceKey binding @?= VoiceKey "v1"
                vbTemplateName binding @?= TemplateName "drone"
                assertBool ("expected runtime slot, got " <> show (vbSlotId binding))
                           (vbSlotId binding >= 0)
              other ->
                assertFailure ("expected committed voice start, got: " <> show other)

  , testCase "step voice-start success commits reserved slot binding" $ do
      let tg  = patternTemplates droneVibrato
          st0 = initialSessionState tg
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0")
                  [(ControlTag (MigrationKey "lpf") 0, 1200.0)]
      withInstalledAdapter tg defaultRTGraphAdapterOptions $ \rt adapter -> do
        result <- stepSessionCommand adapter cmd st0
        case result of
          StepCommitted st1 Nothing ->
            case M.lookup (VoiceKey "v0") (ssVoices st1) of
              Just binding -> do
                vbTemplateName binding @?= TemplateName "drone"
                assertBool ("expected runtime slot, got "
                            <> show (vbSlotId binding))
                           (vbSlotId binding >= 0)
                c_rt_graph_process rt 1
                status <- c_rt_graph_instance_status
                            rt
                            (fromIntegral (vbSlotId binding))
                status @?= instanceStatusLive
              Nothing ->
                assertFailure "expected committed voice binding"
          other ->
            assertFailure ("expected StepCommitted, got: " <> show other)

  , testCase "fromPatternEvent voice-on drives real RTGraph adapter" $ do
      let tg  = patternTemplates droneVibrato
          st0 = initialSessionState tg
          ev  = PEVoiceOn
                  (TemplateName "drone")
                  (VoiceKey "pv0")
                  [(ControlTag (MigrationKey "lpf") 0, 900.0)]
          cmd = fromPatternEvent ev
      withInstalledAdapter tg defaultRTGraphAdapterOptions $ \rt adapter -> do
        result <- stepSessionCommand adapter cmd st0
        case result of
          StepCommitted st1 Nothing ->
            case M.lookup (VoiceKey "pv0") (ssVoices st1) of
              Just binding -> do
                c_rt_graph_process rt 1
                status <- c_rt_graph_instance_status
                            rt
                            (fromIntegral (vbSlotId binding))
                status @?= instanceStatusLive
              Nothing ->
                assertFailure "expected committed PatternEvent voice binding"
          other ->
            assertFailure
              ("expected PatternEvent-backed RTGraph commit, got: " <> show other)

  , testCase "step voice-start with empty pool reports allocation failure" $ do
      let tg  = patternTemplates droneVibrato
          st0 = initialSessionState tg
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      withInstalledAdapter tg defaultRTGraphAdapterOptions $ \rt adapter -> do
        held <- c_rt_graph_realtime_reserve rt 0
        assertBool ("expected setup reservation, got " <> show held) (held >= 0)
        result <- stepSessionCommand adapter cmd st0
        result @?= StepRuntimeFailed SriVoiceAllocationFailed
        c_rt_graph_realtime_cancel rt held

  , testCase "step voice-start invalid initial control cancels reservation" $ do
      let tg      = patternTemplates droneVibrato
          st0     = initialSessionState tg
          badTag  = ControlTag (MigrationKey "missing") 0
          cmd     = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0")
                      [(badTag, 1.0)]
          issue   = CtiUnknownNodeTag
                      (TemplateName "drone")
                      (MigrationKey "missing")
      withInstalledAdapter tg defaultRTGraphAdapterOptions $ \rt adapter -> do
        result <- stepSessionCommand adapter cmd st0
        result @?= StepRuntimeFailed (SriControlTargetRejected issue)
        -- defaultRTGraphAdapterOptions prewarms exactly one slot, so
        -- this reserve can only succeed if the failed start canceled
        -- its reservation back to Available.
        slot <- c_rt_graph_realtime_reserve rt 0
        assertBool ("expected canceled reservation to be reusable, got "
                    <> show slot)
                   (slot >= 0)
        c_rt_graph_realtime_cancel rt slot

  , testCase "step voice-stop queues release and clears session binding" $ do
      let tg       = patternTemplates droneVibrato
          st0      = initialSessionState tg
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          stopCmd  = CmdVoiceOff (VoiceKey "v0")
      withInstalledAdapter tg defaultRTGraphAdapterOptions $ \rt adapter -> do
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing -> do
            case M.lookup (VoiceKey "v0") (ssVoices st1) of
              Nothing ->
                assertFailure "expected committed voice binding"
              Just binding -> do
                c_rt_graph_process rt 1
                stopped <- stepSessionCommand adapter stopCmd st1
                case stopped of
                  StepCommitted st2 Nothing -> do
                    ssVoices st2 @?= M.empty
                    -- Voice-stop success means the release was queued;
                    -- this test intentionally does not assert post-drain
                    -- runtime slot status.
                    assertBool ("expected stopped binding slot, got "
                                <> show (vbSlotId binding))
                               (vbSlotId binding >= 0)
                  other ->
                    assertFailure
                      ("expected stopped voice commit, got: " <> show other)
          other ->
            assertFailure ("expected start commit, got: " <> show other)

  , testCase "step control-write to known target is accepted" $ do
      let tg       = patternTemplates droneVibrato
          st0      = initialSessionState tg
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          writeCmd = CmdControlWrite
                       (VoiceKey "v0")
                       (ControlTag (MigrationKey "lpf") 0)
                       1800.0
      withInstalledAdapter tg defaultRTGraphAdapterOptions $ \rt adapter -> do
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing -> do
            c_rt_graph_process rt 1
            written <- stepSessionCommand adapter writeCmd st1
            written @?= StepControlAccepted
          other ->
            assertFailure ("expected start commit, got: " <> show other)

  , testCase "step control-write to unknown target is rejected" $ do
      let tg       = patternTemplates droneVibrato
          st0      = initialSessionState tg
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          badTag   = ControlTag (MigrationKey "missing") 0
          writeCmd = CmdControlWrite (VoiceKey "v0") badTag 1800.0
          issue    = CtiUnknownNodeTag
                       (TemplateName "drone")
                       (MigrationKey "missing")
      withInstalledAdapter tg defaultRTGraphAdapterOptions $ \rt adapter -> do
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing -> do
            c_rt_graph_process rt 1
            written <- stepSessionCommand adapter writeCmd st1
            written @?= StepRuntimeFailed (SriControlTargetRejected issue)
          other ->
            assertFailure ("expected start commit, got: " <> show other)
  ]
