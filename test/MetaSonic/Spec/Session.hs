{-# LANGUAGE LambdaCase #-}

-- | Session command, runtime ownership, queue, host, UI, and OSC producer tests.
module MetaSonic.Spec.Session where

import qualified Data.Map.Strict           as M
import qualified Data.Text                 as T
import           Data.List                 (isInfixOf, sort)
import           Control.Concurrent        (forkIO, newEmptyMVar, putMVar,
                                            takeMVar)
import           Control.Exception         (SomeException, displayException,
                                            evaluate, try)
import           Control.Monad             (forM, forM_)
import           Data.Maybe                (listToMaybe, mapMaybe)
import           Data.IORef                (modifyIORef', newIORef, readIORef,
                                            writeIORef)
import           System.Timeout            (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Buffer
import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.ControlTarget
import qualified MetaSonic.OSC.Dispatch    as OSC
import qualified MetaSonic.OSC.Wire        as OSC
import           MetaSonic.Pattern
import           MetaSonic.Pattern.Corpus
import           MetaSonic.Session.Arbitration
import           MetaSonic.Session.ArbitrationGateway
import           MetaSonic.Session.Command
import           MetaSonic.Session.Resolve
import           MetaSonic.Session.Report
import           MetaSonic.Session.Runtime
import           MetaSonic.Session.State
import           MetaSonic.Session.Step
import           MetaSonic.Session.RTGraphAdapter
import           MetaSonic.Session.Owner
import           MetaSonic.Session.Queue
import           MetaSonic.Session.PatternProducer
import           MetaSonic.Session.Runner
import           MetaSonic.Session.Host
import           MetaSonic.Session.FanIn
import           MetaSonic.Session.FanInService
import           MetaSonic.Session.OSCProducer
import qualified MetaSonic.Session.OSCListener as OSCS
import           MetaSonic.Session.UIProducer
import           MetaSonic.Types
import           MetaSonic.Spec.Core
import           MetaSonic.Spec.SessionShared

import qualified Data.ByteString           as OBS
import qualified Data.ByteString.Char8     as OBSC

-- Shared 'SessionRuntimeAdapter' mock used by 'sessionStepTests' (in
-- "MetaSonic.Spec.Session.Step") and by later cohorts in this module
-- that drive 'stepSessionCommand' against a canned outcome.
constantAdapter
  :: Applicative m
  => Either SessionRuntimeIssue SessionRuntimeSuccess
  -> SessionRuntimeAdapter m
constantAdapter outcome =
  SessionRuntimeAdapter $ \_ -> pure outcome

sessionRTGraphAdapterTests :: TestTree
sessionRTGraphAdapterTests = testGroup "Session Prep E: RTGraph session install"
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

  , testCase "step hot-swap of empty session installs new graph" $ do
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
  where
    totalTemplateNodes tg =
      sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

    withInstalledAdapter tg opts action =
      withRTGraph (totalTemplateNodes tg + 16) 64 $ \rt -> do
        result <- newRTGraphAdapter rt tg opts
        case result of
          Left issue ->
            assertFailure ("expected RTGraph adapter, got: " <> show issue)
          Right adapter ->
            action rt adapter

------------------------------------------------------------
-- Session Prep F: single-threaded runtime owner
------------------------------------------------------------

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

duplicateFirstTwoTemplates :: TemplateGraph -> TemplateGraph
duplicateFirstTwoTemplates base =
  case tgTemplates base of
    (a : b : rest) ->
      base { tgTemplates =
               a { tplName = "dup" }
             : b { tplName = "dup" }
             : rest
           }
    _ ->
      error "expected at least two templates for duplicate-name test"

------------------------------------------------------------
-- Session Prep G: producer queue and owner drain
------------------------------------------------------------

sessionQueueTests :: TestTree
sessionQueueTests = testGroup "Session Prep G: producer queue"
  [ testCase "default options construct a positive bounded queue" $ do
      sqoCapacity defaultSessionQueueOptions @?= 128
      case newSessionCommandQueue defaultSessionQueueOptions of
        Left issue ->
          assertFailure ("expected default queue, got: " <> show issue)
        Right queue ->
          queue @?= queue

  , testCase "invalid queue capacities reject at construction" $ do
      newSessionCommandQueue (SessionQueueOptions 0)
        @?= Left (SqsiInvalidCapacity 0)
      newSessionCommandQueue (SessionQueueOptions (-1))
        @?= Left (SqsiInvalidCapacity (-1))

  , testCase "enqueue assigns per-queue sequence and rejects when full" $ do
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let pat = testProducer ProducerPattern "pattern"
          osc = testProducer ProducerOSC "osc"
          cmd0 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          cmd1 = CmdVoiceOff (VoiceKey "v0")
          cmd2 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v1") []
          (queue1, enq0) = enqueueSessionCommand pat cmd0 queue0
          (queue2, enq1) = enqueueSessionCommand osc cmd1 queue1
          (queue3, enq2) = enqueueSessionCommand pat cmd2 queue2
      case (enq0, enq1) of
        (SessionEnqueued q0, SessionEnqueued q1) -> do
          qscSequence q0 @?= CommandSequence 0
          qscSequence q1 @?= CommandSequence 1
          qscProducer q0 @?= pat
          qscProducer q1 @?= osc
        other ->
          assertFailure ("expected two accepted enqueues, got: " <> show other)
      enq2 @?= SessionEnqueueRejected pat cmd2 (SeiQueueFull 2)
      queue3 @?= queue2

  , testCase "rejected enqueue does not consume a sequence number" $ do
      queue0 <- queueOrFail (SessionQueueOptions 1)
      let producer = testProducer ProducerTest "test"
          cmd0 = CmdVoiceOn (TemplateName "missing") (VoiceKey "v0") []
          rejectedCmd = CmdVoiceOn (TemplateName "missing") (VoiceKey "v1") []
          cmd1 = CmdVoiceOn (TemplateName "missing") (VoiceKey "v2") []
      (queue1, queued0) <- enqueueOrFail producer cmd0 queue0
      qscSequence queued0 @?= CommandSequence 0
      let (queueFull, rejected) =
            enqueueSessionCommand producer rejectedCmd queue1
      rejected @?=
        SessionEnqueueRejected producer rejectedCmd (SeiQueueFull 1)
      queueFull @?= queue1
      drained <- withSessionOwner
                   (patternTemplates droneVibrato)
                   defaultSessionOwnerOptions
                   (`drainSessionCommandQueue` queueFull)
      queue2 <- case drained of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (queue2, drain) -> do
          map sdiQueued (sdrItems drain) @?= [queued0]
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          pure queue2
      (_queue3, queued1) <- enqueueOrFail producer cmd1 queue2
      qscSequence queued1 @?= CommandSequence 1

  , testCase "drain preserves FIFO order and producer identity" $ do
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let pat = testProducer ProducerPattern "pattern"
          osc = testProducer ProducerOSC "osc"
          cmd0 = CmdVoiceOn (TemplateName "missing") (VoiceKey "p0") []
          cmd1 = CmdVoiceOn (TemplateName "missing") (VoiceKey "o0") []
      (queue1, queued0) <- enqueueOrFail pat cmd0 queue0
      (queue2, queued1) <- enqueueOrFail osc cmd1 queue1
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  (`drainSessionCommandQueue` queue2)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (_queue3, drain) -> do
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          map sdiQueued (sdrItems drain) @?= [queued0, queued1]
          map sdiResult (sdrItems drain)
            @?= [ SessionOwnerStep
                    (StepRejected (SiUnknownTemplate (TemplateName "missing")))
                , SessionOwnerStep
                    (StepRejected (SiUnknownTemplate (TemplateName "missing")))
                ]

  , testCase "drain control-write accepts without owner state mutation" $ do
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let producer = testProducer ProducerUI "ui"
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          writeCmd = CmdControlWrite
                       (VoiceKey "v0")
                       (ControlTag (MigrationKey "lpf") 0)
                       900.0
      (queue1, queued) <- enqueueOrFail producer writeCmd queue0
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  $ \owner -> do
                    started <- stepSessionOwner owner startCmd
                    before <- sessionOwnerState owner
                    drained <- drainSessionCommandQueue owner queue1
                    afterState <- sessionOwnerState owner
                    pure (started, before, drained, afterState)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing),
               before, (_queue2, drain), afterState) -> do
          afterState @?= before
          sdrItems drain @?=
            [SessionDrainItem queued (SessionOwnerStep StepControlAccepted)]
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
        Right other ->
          assertFailure ("expected started owner and accepted control write, got: "
                         <> show other)

  , testCase "divergence stops drain and leaves remaining command queued" $ do
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let oldGraph = patternTemplates droneVibrato
          badGraph = duplicateFirstTwoTemplates
                       (patternTemplates arpeggioSendReturn)
          producer = testProducer ProducerPattern "pattern"
          issue = SasiDuplicateTemplateName (TemplateName "dup")
          divergedReason = SodHotSwapInstallFailed issue
          badSwap = CmdHotSwap (SwapLabel "bad-graph") badGraph
          later = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      (queue1, badQueued) <- enqueueOrFail producer badSwap queue0
      (queue2, laterQueued) <- enqueueOrFail producer later queue1
      firstDrain <- withSessionOwner oldGraph defaultSessionOwnerOptions $
        \owner -> drainSessionCommandQueue owner queue2
      (remainingQueue, firstResult) <- case firstDrain of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right value ->
          pure value
      sdrItems firstResult @?=
        [ SessionDrainItem
            badQueued
            (SessionOwnerDivergedNow
              (StepRuntimeFailed (SriHotSwapInstallFailed issue))
              divergedReason)
        ]
      sdrRemaining firstResult @?= 1
      sdrStopped firstResult @?= Just divergedReason

      secondDrain <- withSessionOwner oldGraph defaultSessionOwnerOptions $
        \owner -> drainSessionCommandQueue owner remainingQueue
      case secondDrain of
        Left setupIssue ->
          assertFailure ("expected second session owner, got: " <> show setupIssue)
        Right (_emptyQueue, secondResult) -> do
          map sdiQueued (sdrItems secondResult) @?= [laterQueued]
          case map sdiResult (sdrItems secondResult) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure ("expected remaining voice-start commit, got: "
                             <> show other)
          sdrRemaining secondResult @?= 0
          sdrStopped secondResult @?= Nothing

  , testCase "already-diverged owner blocks first queued command and stops" $ do
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let oldGraph = patternTemplates droneVibrato
          badGraph = duplicateFirstTwoTemplates
                       (patternTemplates arpeggioSendReturn)
          producer = testProducer ProducerTest "test"
          issue = SasiDuplicateTemplateName (TemplateName "dup")
          divergedReason = SodHotSwapInstallFailed issue
          badSwap = CmdHotSwap (SwapLabel "bad-graph") badGraph
          cmd0 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          cmd1 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v1") []
      (queue1, queued0) <- enqueueOrFail producer cmd0 queue0
      (queue2, _queued1) <- enqueueOrFail producer cmd1 queue1
      result <- withSessionOwner oldGraph defaultSessionOwnerOptions $
        \owner -> do
          diverged <- stepSessionOwner owner badSwap
          drained <- drainSessionCommandQueue owner queue2
          pure (diverged, drained)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (SessionOwnerDivergedNow
                 (StepRuntimeFailed (SriHotSwapInstallFailed _))
                 _,
               (_remainingQueue, drain)) -> do
          sdrItems drain @?=
            [SessionDrainItem queued0 (SessionOwnerBlocked divergedReason)]
          sdrRemaining drain @?= 1
          sdrStopped drain @?= Just divergedReason
        Right other ->
          assertFailure ("expected diverged owner then blocked drain, got: "
                         <> show other)
  ]

queueOrFail :: SessionQueueOptions -> IO SessionCommandQueue
queueOrFail opts =
  case newSessionCommandQueue opts of
    Left issue ->
      assertFailure ("expected queue, got: " <> show issue)
    Right queue ->
      pure queue

enqueueOrFail
  :: ProducerId
  -> SessionCommand
  -> SessionCommandQueue
  -> IO (SessionCommandQueue, QueuedSessionCommand)
enqueueOrFail producer cmd queue =
  case enqueueSessionCommand producer cmd queue of
    (queue', SessionEnqueued queued) ->
      pure (queue', queued)
    (_queue', other) ->
      assertFailure ("expected enqueue success, got: " <> show other)

------------------------------------------------------------
-- Session producer arbitration policy
------------------------------------------------------------

sessionArbitrationTests :: TestTree
sessionArbitrationTests =
  testGroup "Session producer arbitration policy"
  [ testCase "FifoOnly accepts same-target writes from multiple producers" $ do
      let patternProducer = testProducer ProducerPattern "pattern"
          oscProducer     = testProducer ProducerOSC "osc"
          writeCmd = CmdControlWrite (VoiceKey "v0") levelTag 0.75
      arbitrateSessionCommand FifoOnly patternProducer writeCmd
        @?= ArbitrationAllowed
      arbitrateSessionCommand FifoOnly oscProducer writeCmd
        @?= ArbitrationAllowed

  , testCase "priority policy accepts winner and rejects loser" $ do
      let currentOwner = testProducer ProducerOSC "osc"
          winner       = testProducer ProducerMIDI "midi"
          loser        = testProducer ProducerPattern "pattern"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          command =
            CmdControlWrite (VoiceKey "v0") levelTag 0.5
          owners =
            setControlOwner target currentOwner emptyControlOwnerTable
          policy =
            ProducerPriority
              [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
              owners
          expectedIssue = ArbitrationIssue
            { aiProducer  = loser
            , aiCommand   = command
            , aiTarget    = Just target
            , aiReason    = ArrLowerPriorityThan currentOwner
            , aiRetryable = False
            }
      arbitrateSessionCommand policy winner command
        @?= ArbitrationAllowed
      arbitrateSessionCommand policy loser command
        @?= ArbitrationRejected expectedIssue

  , testCase "priority policy allows equal-priority producers" $ do
      let owner     = testProducer ProducerMIDI "midi-a"
          peer      = testProducer ProducerMIDI "midi-b"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          command =
            CmdControlWrite (VoiceKey "v0") levelTag 0.5
          owners =
            setControlOwner target owner emptyControlOwnerTable
          policy =
            ProducerPriority
              [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
              owners
      arbitrateSessionCommand policy owner command
        @?= ArbitrationAllowed
      arbitrateSessionCommand policy peer command
        @?= ArbitrationAllowed

  , testCase "priority policy allows unowned targets" $ do
      let producer = testProducer ProducerPattern "pattern"
          command =
            CmdControlWrite (VoiceKey "v0") levelTag 0.5
          policy =
            ProducerPriority
              [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
              emptyControlOwnerTable
      arbitrateSessionCommand policy producer command
        @?= ArbitrationAllowed

  , testCase "target claim blocks only the claimed control target" $ do
      let claimant  = testProducer ProducerUI "ui"
          blocked   = testProducer ProducerMIDI "midi"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          otherTarget =
            ControlArbitrationTarget (VoiceKey "v0") freqTag
          command =
            CmdControlWrite (VoiceKey "v0") levelTag 0.25
          otherCommand =
            CmdControlWrite (VoiceKey "v0") freqTag 440.0
          claims =
            claimControlTarget target claimant emptyTargetClaimTable
          policy =
            TargetClaim claims
          expectedIssue = ArbitrationIssue
            { aiProducer  = blocked
            , aiCommand   = command
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      arbitrateSessionCommand policy claimant command
        @?= ArbitrationAllowed
      arbitrateSessionCommand policy blocked command
        @?= ArbitrationRejected expectedIssue
      arbitrateSessionCommand policy blocked otherCommand
        @?= ArbitrationAllowed
      sessionCommandControlTarget otherCommand @?= Just otherTarget

  , testCase "lifecycle and hot-swap commands bypass v1 control arbitration" $ do
      let claimant = testProducer ProducerUI "ui"
          producer = testProducer ProducerMIDI "midi"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          policy =
            TargetClaim
              (claimControlTarget target claimant emptyTargetClaimTable)
          commands =
            [ CmdVoiceOn (TemplateName "voice") (VoiceKey "v0") []
            , CmdVoiceOff (VoiceKey "v0")
            , CmdHotSwap (SwapLabel "refresh") (patternTemplates droneVibrato)
            ]
      map sessionCommandControlTarget commands
        @?= replicate (length commands) Nothing
      map (arbitrateSessionCommand policy producer) commands
        @?= replicate (length commands) ArbitrationAllowed
  ]

sessionArbitrationGatewayTests :: TestTree
sessionArbitrationGatewayTests =
  testGroup "Session producer arbitration gateway"
  [ testCase "default FifoOnly gateway preserves fan-in enqueue behavior" $ do
      let graph = patternTemplates droneVibrato
          patternProducer = testProducer ProducerPattern "pattern"
          oscProducer     = testProducer ProducerOSC "osc"
          command0 =
            CmdControlWrite (VoiceKey "v0") levelTag 0.25
          command1 =
            CmdControlWrite (VoiceKey "v0") levelTag 0.5
      result <-
        withSessionFanInHost graph defaultSessionFanInOptions $ \host ->
          withSessionArbitrationGateway
            defaultSessionArbitrationGatewayOptions
            $ \gateway -> do
                enq0 <- enqueueArbitratedSessionFanInCommand
                          gateway patternProducer command0 host
                enq1 <- enqueueArbitratedSessionFanInCommand
                          gateway oscProducer command1 host
                policy <- readSessionArbitrationGatewayPolicy gateway
                pure (enq0, enq1, policy)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (enq0, enq1, policy) -> do
          q0 <- gatewayQueuedOrFail enq0
          q1 <- gatewayQueuedOrFail enq1
          qscSequence q0 @?= CommandSequence 0
          qscSequence q1 @?= CommandSequence 1
          map qscProducer [q0, q1] @?= [patternProducer, oscProducer]
          policy @?= FifoOnly

  , testCase "priority gateway rejects before fan-in and updates owner on accept" $ do
      let graph = patternTemplates droneVibrato
          oscProducer     = testProducer ProducerOSC "osc"
          midiProducer    = testProducer ProducerMIDI "midi"
          patternProducer = testProducer ProducerPattern "pattern"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          command =
            CmdControlWrite (VoiceKey "v0") levelTag 0.5
          opts = defaultSessionArbitrationGatewayOptions
            { sagoInitialPolicy =
                ProducerPriority
                  [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
                  emptyControlOwnerTable
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = patternProducer
            , aiCommand   = command
            , aiTarget    = Just target
            , aiReason    = ArrLowerPriorityThan oscProducer
            , aiRetryable = False
            }
      result <-
        withSessionFanInHost graph defaultSessionFanInOptions $ \host ->
          withSessionArbitrationGateway opts $ \gateway -> do
            enq0 <- enqueueArbitratedSessionFanInCommand
                      gateway oscProducer command host
            policyAfterOsc <- readSessionArbitrationGatewayPolicy gateway
            rejected <- enqueueArbitratedSessionFanInCommand
                          gateway patternProducer command host
            snapshotAfterReject <- readSessionFanInHost host
            enq1 <- enqueueArbitratedSessionFanInCommand
                      gateway midiProducer command host
            policyAfterMidi <- readSessionArbitrationGatewayPolicy gateway
            snapshotAfterMidi <- readSessionFanInHost host
            pure
              ( enq0
              , policyAfterOsc
              , rejected
              , snapshotAfterReject
              , enq1
              , policyAfterMidi
              , snapshotAfterMidi
              )
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right
          ( enq0
          , policyAfterOsc
          , rejected
          , snapshotAfterReject
          , enq1
          , policyAfterMidi
          , snapshotAfterMidi
          ) -> do
            q0 <- gatewayQueuedOrFail enq0
            q1 <- gatewayQueuedOrFail enq1
            qscSequence q0 @?= CommandSequence 0
            qscSequence q1 @?= CommandSequence 1
            qscProducer q0 @?= oscProducer
            qscProducer q1 @?= midiProducer
            rejected @?= SagArbitrationRejected expectedIssue
            sfisQueueDepth snapshotAfterReject @?= 1
            sfisQueueDepth snapshotAfterMidi @?= 2
            assertPriorityOwner policyAfterOsc target oscProducer
            assertPriorityOwner policyAfterMidi target midiProducer

  , testCase "priority gateway keeps owner unchanged when fan-in rejects" $ do
      let graph = patternTemplates droneVibrato
          fanInOpts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          oscProducer  = testProducer ProducerOSC "osc"
          midiProducer = testProducer ProducerMIDI "midi"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          oscCommand =
            CmdControlWrite (VoiceKey "v0") levelTag 0.25
          midiCommand =
            CmdControlWrite (VoiceKey "v0") levelTag 0.75
          gatewayOpts = defaultSessionArbitrationGatewayOptions
            { sagoInitialPolicy =
                ProducerPriority
                  [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
                  emptyControlOwnerTable
            }
      result <-
        withSessionFanInHost graph fanInOpts $ \host ->
          withSessionArbitrationGateway gatewayOpts $ \gateway -> do
            enq0 <- enqueueArbitratedSessionFanInCommand
                      gateway oscProducer oscCommand host
            policyAfterOsc <- readSessionArbitrationGatewayPolicy gateway
            rejected <- enqueueArbitratedSessionFanInCommand
                          gateway midiProducer midiCommand host
            policyAfterReject <- readSessionArbitrationGatewayPolicy gateway
            snapshotAfterReject <- readSessionFanInHost host
            pure
              ( enq0
              , policyAfterOsc
              , rejected
              , policyAfterReject
              , snapshotAfterReject
              )
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right
          ( enq0
          , policyAfterOsc
          , rejected
          , policyAfterReject
          , snapshotAfterReject
          ) -> do
            q0 <- gatewayQueuedOrFail enq0
            qscProducer q0 @?= oscProducer
            case rejected of
              SagArbitrationRejected issue ->
                assertFailure ("expected fan-in rejection, got: "
                               <> show issue)
              SagEnqueueAttempted fanInResult -> do
                sfierResult fanInResult
                  @?= SessionEnqueueRejected
                        midiProducer
                        midiCommand
                        (SeiQueueFull 1)
                sfierQueueDepth fanInResult @?= 1
            sfisQueueDepth snapshotAfterReject @?= 1
            assertPriorityOwner policyAfterOsc target oscProducer
            assertPriorityOwner policyAfterReject target oscProducer

  , testCase "target-claim gateway rejects only the claimed target before fan-in" $ do
      let graph = patternTemplates droneVibrato
          claimant = testProducer ProducerUI "ui"
          blocked  = testProducer ProducerMIDI "midi"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          claimedCommand =
            CmdControlWrite (VoiceKey "v0") levelTag 0.25
          otherCommand =
            CmdControlWrite (VoiceKey "v0") freqTag 440.0
          gatewayOpts = defaultSessionArbitrationGatewayOptions
            { sagoInitialPolicy =
                TargetClaim
                  (claimControlTarget target claimant emptyTargetClaimTable)
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = blocked
            , aiCommand   = claimedCommand
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      result <-
        withSessionFanInHost graph defaultSessionFanInOptions $ \host ->
          withSessionArbitrationGateway gatewayOpts $ \gateway -> do
            claimantEnq <- enqueueArbitratedSessionFanInCommand
                             gateway claimant claimedCommand host
            rejected <- enqueueArbitratedSessionFanInCommand
                          gateway blocked claimedCommand host
            otherEnq <- enqueueArbitratedSessionFanInCommand
                          gateway blocked otherCommand host
            snapshot <- readSessionFanInHost host
            pure (claimantEnq, rejected, otherEnq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (claimantEnq, rejected, otherEnq, snapshot) -> do
          q0 <- gatewayQueuedOrFail claimantEnq
          q1 <- gatewayQueuedOrFail otherEnq
          qscSequence q0 @?= CommandSequence 0
          qscSequence q1 @?= CommandSequence 1
          qscProducer q0 @?= claimant
          qscProducer q1 @?= blocked
          qscCommand q0 @?= claimedCommand
          qscCommand q1 @?= otherCommand
          rejected @?= SagArbitrationRejected expectedIssue
          sfisQueueDepth snapshot @?= 2
  ]

------------------------------------------------------------
-- Session Prep H: Pattern producer bridge
------------------------------------------------------------

sessionPatternProducerTests :: TestTree
sessionPatternProducerTests = testGroup "Session Prep H: Pattern producer"
  [ testCase "default options construct Pattern producer identity" $ do
      assertBool
        "expected positive default block size"
        (ppoBlockFrames defaultPatternProducerOptions > 0)
      producer <- patternProducerOrFail defaultPatternProducerOptions
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let outcome = enqueuePatternBlock droneVibrato producer queue0
          result = peoResult outcome
      perNextStart result @?= SamplePos (ppoBlockFrames defaultPatternProducerOptions)
      case perItems result of
        [item] ->
          case peiResult item of
            SessionEnqueued queued ->
              qscProducer queued
                @?= ProducerId ProducerPattern (T.pack "pattern")
            other ->
              assertFailure ("expected default producer enqueue, got: "
                             <> show other)
        other ->
          assertFailure ("expected one default producer item, got: "
                         <> show other)

  , testCase "invalid block sizes reject at construction" $ do
      newPatternProducerState
        (defaultPatternProducerOptions { ppoBlockFrames = 0 })
        @?= Left (PpiInvalidBlockFrames 0)
      newPatternProducerState
        (defaultPatternProducerOptions { ppoBlockFrames = (-8) })
        @?= Left (PpiInvalidBlockFrames (-8))

  , testCase "backlog predicate tracks queue-pressure retry state" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 1)
      partialRetryQueue <- queueOrFail (SessionQueueOptions 1)
      finalRetryQueue <- queueOrFail (SessionQueueOptions 8)
      let events = missingVoiceEvents 3
          pat = droneVibrato { patternEvents = staticEvents events }
          outcome1 = enqueuePatternBlock pat producer queue0
          outcome2 =
            enqueuePatternBlock pat (peoState outcome1) partialRetryQueue
          outcome3 =
            enqueuePatternBlock pat (peoState outcome2) finalRetryQueue
      assertBool
        "new Pattern producer should start without backlog"
        (not (isBacklogged producer))
      assertBool
        "partial enqueue rejection should leave producer backlogged"
        (isBacklogged (peoState outcome1))
      assertBool
        "partial retry should keep producer backlogged"
        (isBacklogged (peoState outcome2))
      assertBool
        "successful final retry should clear producer backlog"
        (not (isBacklogged (peoState outcome3)))
      perBacklogged (peoResult outcome1) @?= 2
      perBacklogged (peoResult outcome2) @?= 1
      perBacklogged (peoResult outcome3) @?= 0

  , testCase "empty block advances cursor and enqueues nothing" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 16 })
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let emptyPattern = droneVibrato
            { patternEvents = staticEvents [] }
          outcome = enqueuePatternBlock emptyPattern producer queue0
          result = peoResult outcome
      perItems result @?= []
      perBacklogged result @?= 0
      perNextStart result @?= SamplePos 16

  , testCase "first droneVibrato block enqueues expected VoiceOn command" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions
          { ppoProducerName = T.pack "composer"
          , ppoBlockFrames  = 64
          })
      queue0 <- queueOrFail (SessionQueueOptions 4)
      expectedEvent <- case listToMaybe droneVibratoEvents of
        Just event ->
          pure event
        Nothing ->
          assertFailure "expected droneVibratoEvents to contain a first event"
      let outcome = enqueuePatternBlock droneVibrato producer queue0
      case perItems (peoResult outcome) of
        [item] -> do
          peiSamplePos item @?= fst expectedEvent
          peiEvent item @?= snd expectedEvent
          peiCommand item @?= fromPatternEvent (snd expectedEvent)
          case peiResult item of
            SessionEnqueued queued -> do
              qscSequence queued @?= CommandSequence 0
              qscProducer queued
                @?= ProducerId ProducerPattern (T.pack "composer")
            other ->
              assertFailure ("expected queued VoiceOn, got: " <> show other)
        other ->
          assertFailure ("expected one droneVibrato item, got: " <> show other)

  , testCase "same-sample Pattern events preserve emit order" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 1 })
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let expected = take 2 arpeggioSendReturnEvents
          outcome = enqueuePatternBlock arpeggioSendReturn producer queue0
          items = perItems (peoResult outcome)
      map peiEvent items @?= map snd expected
      map peiSamplePos items @?= map fst expected
      mapMaybe itemSequence items @?= [CommandSequence 0, CommandSequence 1]

  , testCase "every PatternEvent constructor maps through fromPatternEvent" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 8)
      let events =
            [ ( SamplePos 0
              , PEVoiceOn (TemplateName "drone") (VoiceKey "v0") []
              )
            , ( SamplePos 1
              , PEControlWrite
                  (VoiceKey "v0")
                  (ControlTag (MigrationKey "lpf") 0)
                  1200.0
              )
            , ( SamplePos 2
              , PEVoiceOff (VoiceKey "v0")
              )
            , ( SamplePos 3
              , PEHotSwap
                  (SwapLabel "edit")
                  (patternTemplates polyphonicStab)
              )
            ]
          pat = droneVibrato { patternEvents = staticEvents events }
          outcome = enqueuePatternBlock pat producer queue0
          items = perItems (peoResult outcome)
      map peiEvent items @?= map snd events
      map peiCommand items @?= map (fromPatternEvent . snd) events
      perBacklogged (peoResult outcome) @?= 0

  , testCase "full queue stops at first rejection and retains tail backlog" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 1)
      retryQueue <- queueOrFail (SessionQueueOptions 8)
      let events = missingVoiceEvents 4
          pat = droneVibrato { patternEvents = staticEvents events }
          outcome1 = enqueuePatternBlock pat producer queue0
          result1 = peoResult outcome1
      map peiEvent (perItems result1) @?= map snd (take 2 events)
      perBacklogged result1 @?= 3
      case map peiResult (perItems result1) of
        [SessionEnqueued _, SessionEnqueueRejected {}] ->
          pure ()
        other ->
          assertFailure ("expected enqueue then rejection, got: "
                         <> show other)

      let outcome2 = enqueuePatternBlock pat (peoState outcome1) retryQueue
          result2 = peoResult outcome2
      perNextStart result2 @?= perNextStart result1
      perBacklogged result2 @?= 0
      map peiEvent (perItems result2) @?= map snd (drop 1 events)

  , testCase "rejected backlog does not consume queue sequence numbers" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let events = missingVoiceEvents 3
          pat = droneVibrato { patternEvents = staticEvents events }
          outcome1 = enqueuePatternBlock pat producer queue0
          result1 = peoResult outcome1
      mapMaybe itemSequence (perItems result1)
        @?= [CommandSequence 0, CommandSequence 1]
      perBacklogged result1 @?= 1

      drained <- withSessionOwner
                   (patternTemplates droneVibrato)
                   defaultSessionOwnerOptions
                   (\owner -> drainSessionCommandQueue owner (peoQueue outcome1))
      drainedQueue <- case drained of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (queue1, drain) -> do
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          pure queue1

      let outcome2 = enqueuePatternBlock pat (peoState outcome1) drainedQueue
          result2 = peoResult outcome2
      perNextStart result2 @?= perNextStart result1
      perBacklogged result2 @?= 0
      map peiEvent (perItems result2) @?= [snd (events !! 2)]
      mapMaybe itemSequence (perItems result2) @?= [CommandSequence 2]

  , testCase "retry call does not generate a fresh range after backlog drains" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 2)
      retryQueue <- queueOrFail (SessionQueueOptions 8)
      nextQueue <- queueOrFail (SessionQueueOptions 8)
      let events =
            missingVoiceEventsAt [0, 1, 2, 8]
          pat = droneVibrato { patternEvents = staticEvents events }
          outcome1 = enqueuePatternBlock pat producer queue0
          outcome2 = enqueuePatternBlock pat (peoState outcome1) retryQueue
          outcome3 = enqueuePatternBlock pat (peoState outcome2) nextQueue
      perBacklogged (peoResult outcome1) @?= 1
      perNextStart (peoResult outcome2)
        @?= perNextStart (peoResult outcome1)
      map peiSamplePos (perItems (peoResult outcome2))
        @?= [SamplePos 2]
      perBacklogged (peoResult outcome2) @?= 0
      perNextStart (peoResult outcome3) @?= SamplePos 16
      map peiSamplePos (perItems (peoResult outcome3))
        @?= [SamplePos 8]

  , testCase "producer enqueue drains through owner and commits a real voice" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 64 })
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let outcome = enqueuePatternBlock droneVibrato producer queue0
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  $ \owner -> do
                    drained <- drainSessionCommandQueue owner (peoQueue outcome)
                    st <- sessionOwnerState owner
                    pure (drained, st)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right ((_queue1, drain), st) -> do
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          case map sdiResult (sdrItems drain) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure ("expected committed Pattern producer voice, got: "
                             <> show other)
          assertBool
            ("expected v0 voice after drain, got " <> show (ssVoices st))
            (M.member (VoiceKey "v0") (ssVoices st))

  , testCase "arbitrated service Pattern enqueue defaults to FIFO" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions
          { ppoProducerName = T.pack "pattern-arb"
          , ppoBlockFrames  = 64
          })
      expectedEvent <- case listToMaybe droneVibratoEvents of
        Just event ->
          pure event
        Nothing ->
          assertFailure "expected droneVibratoEvents to contain a first event"
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              outcome <- enqueueArbitratedPatternBlock
                           droneVibrato
                           producer
                           service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (outcome, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (outcome, Just drained, snapshot) -> do
          let result' = paeoResult outcome
          assertBool
            "arbitrated Pattern producer should not leave backlog after one clean block"
            (not (isBacklogged (paeoState outcome)))
          paerBacklogged result' @?= 0
          paerNextStart result' @?= SamplePos 64
          case paerItems result' of
            [item] -> do
              paeiSamplePos item @?= fst expectedEvent
              paeiEvent item @?= snd expectedEvent
              paeiCommand item @?= fromPatternEvent (snd expectedEvent)
              queued <- gatewayQueuedOrFail (paeiResult item)
              qscProducer queued
                @?= ProducerId ProducerPattern (T.pack "pattern-arb")
              qscCommand queued @?= paeiCommand item
              map sdiQueued (sdrItems (sfidrDrain drained)) @?= [queued]
              case map sdiResult (sdrItems (sfidrDrain drained)) of
                [SessionOwnerStep (StepCommitted _ Nothing)] ->
                  pure ()
                other ->
                  assertFailure
                    ("expected arbitrated Pattern voice-on to commit, got: "
                     <> show other)
            other ->
              assertFailure ("expected one arbitrated Pattern item, got: "
                             <> show other)
          sfisQueueDepth snapshot @?= 0
          assertBool
            "expected Pattern voice after arbitrated service drain"
            (M.member (VoiceKey "v0") (ssVoices (sfisOwnerState snapshot)))
        Right (_outcome, Nothing, _snapshot) ->
          assertFailure "timed out waiting for arbitrated Pattern service drain"

  , testCase "arbitrated service Pattern rejection reports service issue" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions
          { ppoProducerName = T.pack "pattern-arb"
          , ppoBlockFrames  = 8
          })
      let event =
            ( SamplePos 0
            , PEControlWrite (VoiceKey "v0") levelTag 0.75
            )
          pat = droneVibrato { patternEvents = staticEvents [event] }
          command = fromPatternEvent (snd event)
          producerId = ProducerId ProducerPattern (T.pack "pattern-arb")
          claimant = testProducer ProducerUI "ui"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          serviceOpts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = producerId
            , aiCommand   = command
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            , sfshOnIssue = putMVar issueVar
            }
          (patternTemplates droneVibrato)
          serviceOpts
          $ \service -> do
              outcome <- enqueueArbitratedPatternBlock pat producer service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              mDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (outcome, mIssue, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (outcome, Just reported, Nothing, snapshot) -> do
          let result' = paeoResult outcome
          assertBool
            "policy-rejected Pattern event should remain backlogged"
            (isBacklogged (paeoState outcome))
          paerBacklogged result' @?= 1
          paerNextStart result' @?= SamplePos 8
          case paerItems result' of
            [item] -> do
              paeiSamplePos item @?= fst event
              paeiEvent item @?= snd event
              paeiCommand item @?= command
              paeiResult item @?= SagArbitrationRejected expectedIssue
            other ->
              assertFailure
                ("expected one rejected arbitrated Pattern item, got: "
                 <> show other)
          reported @?= SfsiiArbitrationRejected expectedIssue
          sfisQueueDepth snapshot @?= 0
        Right (_outcome, Nothing, _mDrain, _snapshot) ->
          assertFailure "timed out waiting for Pattern arbitration rejection issue"
        Right (_outcome, Just _reported, Just extraDrain, _snapshot) ->
          assertFailure
            ("Pattern policy rejection unexpectedly woke service drain: "
             <> show extraDrain)

  , testCase "arbitrated service Pattern halts on mid-block rejection" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions
          { ppoProducerName = T.pack "pattern-arb"
          , ppoBlockFrames  = 8
          })
      let firstTarget = ControlTag (MigrationKey "lpf") 1
          claimedTarget = levelTag
          firstEvent =
            ( SamplePos 0
            , PEControlWrite (VoiceKey "v0") firstTarget 4.0
            )
          rejectedEvent =
            ( SamplePos 1
            , PEControlWrite (VoiceKey "v0") claimedTarget 0.75
            )
          tailEvent =
            (SamplePos 2, PEVoiceOff (VoiceKey "v0"))
          events =
            [firstEvent, rejectedEvent, tailEvent]
          pat = droneVibrato { patternEvents = staticEvents events }
          producerId = ProducerId ProducerPattern (T.pack "pattern-arb")
          claimant = testProducer ProducerUI "ui"
          target =
            ControlArbitrationTarget (VoiceKey "v0") claimedTarget
          firstCommand = fromPatternEvent (snd firstEvent)
          rejectedCommand = fromPatternEvent (snd rejectedEvent)
          tailCommand = fromPatternEvent (snd tailEvent)
          serviceOpts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = producerId
            , aiCommand   = rejectedCommand
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            , sfshOnIssue = putMVar issueVar
            }
          (patternTemplates droneVibrato)
          serviceOpts
          $ \service -> do
              outcome <- enqueueArbitratedPatternBlock pat producer service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              mFirstDrain <- timeout 1000000 (takeMVar drainedVar)
              mSecondDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (outcome, mIssue, mFirstDrain, mSecondDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (outcome, Just reported, Just firstDrain, Nothing, snapshot) -> do
          let result' = paeoResult outcome
              items = paerItems result'
          assertBool
            "mid-block rejection should leave Pattern producer backlogged"
            (isBacklogged (paeoState outcome))
          paerBacklogged result' @?= 2
          paerNextStart result' @?= SamplePos 8
          map paeiCommand items @?= [firstCommand, rejectedCommand]
          assertBool
            "tail command should not be attempted after mid-block rejection"
            (tailCommand `notElem` map paeiCommand items)
          case items of
            [acceptedItem, rejectedItem] -> do
              queued <- gatewayQueuedOrFail (paeiResult acceptedItem)
              qscProducer queued @?= producerId
              qscCommand queued @?= firstCommand
              paeiResult rejectedItem
                @?= SagArbitrationRejected expectedIssue
              map sdiQueued (sdrItems (sfidrDrain firstDrain))
                @?= [queued]
              length (sdrItems (sfidrDrain firstDrain)) @?= 1
            other ->
              assertFailure
                ("expected accepted then rejected Pattern items, got: "
                 <> show other)
          reported @?= SfsiiArbitrationRejected expectedIssue
          sfisQueueDepth snapshot @?= 0
        Right (_outcome, Nothing, _mFirstDrain, _mSecondDrain, _snapshot) ->
          assertFailure "timed out waiting for Pattern arbitration rejection issue"
        Right (_outcome, Just _reported, Nothing, _mSecondDrain, _snapshot) ->
          assertFailure "timed out waiting for admitted Pattern drain"
        Right (_outcome, Just _reported, Just _firstDrain, Just extraDrain, _snapshot) ->
          assertFailure
            ("Pattern mid-block rejection unexpectedly produced extra drain: "
             <> show extraDrain)
  ]

------------------------------------------------------------
-- Session Prep I: scripted Pattern runner
------------------------------------------------------------

sessionRunnerTests :: TestTree
sessionRunnerTests = testGroup "Session Prep I: scripted runner"
  [ testCase "one runner step enqueues and commits a Pattern voice" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 64 })
      queue0 <- queueOrFail (SessionQueueOptions 4)
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  $ \owner -> do
                    step <- stepPatternSession droneVibrato producer queue0 owner
                    st <- sessionOwnerState owner
                    pure (step, st)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (step, st) -> do
          assertBool
            "runner should leave the producer without backlog after one block"
            (not (isBacklogged (prsState step)))
          sdrRemaining (prsDrain step) @?= 0
          sdrStopped (prsDrain step) @?= Nothing
          perBacklogged (prsEnqueue step) @?= 0
          case map sdiResult (sdrItems (prsDrain step)) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure ("expected one committed runner voice, got: "
                             <> show other)
          assertBool
            ("expected v0 voice after runner step, got " <> show (ssVoices st))
            (M.member (VoiceKey "v0") (ssVoices st))

  , testCase "backlog retries drain across repeated runner steps" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 1)
      let voiceOn k =
            PEVoiceOn (TemplateName "stab") (VoiceKey k)
              [ (ControlTag (MigrationKey "lpf")      0, 800.0)
              , (ControlTag (MigrationKey "envelope") 0, 1.0)
              ]
          events =
            [ (SamplePos 0, voiceOn "s0")
            , (SamplePos 1, voiceOn "s1")
            , (SamplePos 2, voiceOn "s2")
            ]
          pat = polyphonicStab { patternEvents = staticEvents events }
      let ownerOpts = defaultSessionOwnerOptions
            { sooAdapterOptions = defaultRTGraphAdapterOptions
                { raoPerTemplatePolyphony =
                    M.singleton (TemplateName "stab") 3
                }
            }
      result <- withSessionOwner
                  (patternTemplates polyphonicStab)
                  ownerOpts
                  $ \owner -> do
                    step1 <- stepPatternSession pat producer queue0 owner
                    step2 <- stepPatternSession pat (prsState step1) (prsQueue step1) owner
                    step3 <- stepPatternSession pat (prsState step2) (prsQueue step2) owner
                    st <- sessionOwnerState owner
                    pure (step1, step2, step3, st)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (step1, step2, step3, st) -> do
          assertBool
            "step 1 should leave producer backlogged after queue saturation"
            (isBacklogged (prsState step1))
          assertBool
            "step 2 should still be backlogged after retrying one event"
            (isBacklogged (prsState step2))
          assertBool
            "step 3 should clear producer backlog"
            (not (isBacklogged (prsState step3)))
          perBacklogged (prsEnqueue step1) @?= 2
          perBacklogged (prsEnqueue step2) @?= 1
          perBacklogged (prsEnqueue step3) @?= 0
          sdrStopped (prsDrain step1) @?= Nothing
          sdrStopped (prsDrain step2) @?= Nothing
          sdrStopped (prsDrain step3) @?= Nothing
          assertBool
            ("expected s0, s1, s2 voices after runner backlog drain, got "
              <> show (ssVoices st))
            (all (\k -> M.member (VoiceKey k) (ssVoices st)) ["s0","s1","s2"])

  , testCase "owner divergence stops the runner drain and blocks later steps" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let badGraph = duplicateFirstTwoTemplates
                       (patternTemplates arpeggioSendReturn)
          divergedReason = SodHotSwapInstallFailed
                             (SasiDuplicateTemplateName (TemplateName "dup"))
          events =
            [ (SamplePos 0, PEHotSwap (SwapLabel "bad-graph") badGraph)
            , (SamplePos 1, PEVoiceOn (TemplateName "drone") (VoiceKey "v0") [])
            ]
          pat = droneVibrato { patternEvents = staticEvents events }
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  $ \owner -> do
                    step1 <- stepPatternSession pat producer queue0 owner
                    step2 <- stepPatternSession pat (prsState step1) (prsQueue step1) owner
                    status <- sessionOwnerStatus owner
                    pure (step1, step2, status)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (step1, step2, status) -> do
          sdrStopped (prsDrain step1) @?= Just divergedReason
          sdrRemaining (prsDrain step1) @?= 1
          case map sdiResult (sdrItems (prsDrain step1)) of
            [SessionOwnerDivergedNow
               (StepRuntimeFailed (SriHotSwapInstallFailed _))
               reason] ->
              reason @?= divergedReason
            other ->
              assertFailure ("expected drain to stop on hot-swap divergence, got: "
                             <> show other)
          sdrStopped (prsDrain step2) @?= Just divergedReason
          case map sdiResult (sdrItems (prsDrain step2)) of
            (SessionOwnerBlocked reason : _) ->
              reason @?= divergedReason
            other ->
              assertFailure ("expected later runner step to surface blocked items, got: "
                             <> show other)
          status @?= SessionOwnerDiverged divergedReason

  , testCase "runner step retrying backlog does not advance the cursor" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 1)
      let events = missingVoiceEventsAt [0, 1, 2]
          pat = droneVibrato { patternEvents = staticEvents events }
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  $ \owner -> do
                    step1 <- stepPatternSession pat producer queue0 owner
                    step2 <- stepPatternSession pat (prsState step1) (prsQueue step1) owner
                    pure (step1, step2)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (step1, step2) -> do
          perNextStart (prsEnqueue step1) @?= SamplePos 8
          perNextStart (prsEnqueue step2) @?= perNextStart (prsEnqueue step1)
          assertBool
            "step 1 should be backlogged after queue cap 1"
            (isBacklogged (prsState step1))
          map peiSamplePos (perItems (prsEnqueue step2))
            @?= [SamplePos 1, SamplePos 2]
  ]

------------------------------------------------------------
-- Session Prep J: serialized Pattern session host
------------------------------------------------------------

sessionHostTests :: TestTree
sessionHostTests = testGroup "Session Prep J: Pattern session host"
  [ testCase "host construction surfaces owned component failures" $ do
      let graph = patternTemplates droneVibrato
          invalidProducerOpts = defaultPatternSessionHostOptions
            { pshoProducerOptions =
                defaultPatternProducerOptions { ppoBlockFrames = 0 }
            }
          invalidQueueOpts = defaultPatternSessionHostOptions
            { pshoQueueOptions = SessionQueueOptions 0
            }
          duplicated = duplicateFirstTwoTemplates
                         (patternTemplates arpeggioSendReturn)
      badProducer <- withPatternSessionHost
                       graph
                       invalidProducerOpts
                       (\_ -> pure ())
      badProducer @?=
        Left (PshsiPatternProducer (PpiInvalidBlockFrames 0))

      badQueue <- withPatternSessionHost
                    graph
                    invalidQueueOpts
                    (\_ -> pure ())
      badQueue @?= Left (PshsiQueue (SqsiInvalidCapacity 0))

      badOwner <- withPatternSessionHost
                    duplicated
                    defaultPatternSessionHostOptions
                    (\_ -> pure ())
      badOwner @?=
        Left (PshsiOwner (SasiDuplicateTemplateName (TemplateName "dup")))

  , testCase "host step commits a Pattern voice and exposes a snapshot" $ do
      result <- withPatternSessionHost
                  (patternTemplates droneVibrato)
                  defaultPatternSessionHostOptions
                  $ \host -> do
                    step <- stepPatternSessionHost droneVibrato host
                    snapshot <- readPatternSessionHost host
                    pure (step, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected Pattern session host, got: " <> show issue)
        Right (step, snapshot) -> do
          sdrRemaining (prsDrain step) @?= 0
          sdrStopped (prsDrain step) @?= Nothing
          assertBool
            "host snapshot should report no backlog after one clean step"
            (not (pshsBacklogged snapshot))
          pshsOwnerStatus snapshot @?= SessionOwnerReady
          assertBool
            ("expected v0 voice in hosted owner state, got "
              <> show (ssVoices (pshsOwnerState snapshot)))
            (M.member (VoiceKey "v0") (ssVoices (pshsOwnerState snapshot)))

  , testCase "host carries Pattern backlog across repeated calls" $ do
      let voiceOn k =
            PEVoiceOn (TemplateName "stab") (VoiceKey k)
              [ (ControlTag (MigrationKey "lpf")      0, 800.0)
              , (ControlTag (MigrationKey "envelope") 0, 1.0)
              ]
          events =
            [ (SamplePos 0, voiceOn "s0")
            , (SamplePos 1, voiceOn "s1")
            , (SamplePos 2, voiceOn "s2")
            ]
          pat = polyphonicStab { patternEvents = staticEvents events }
          ownerOpts = defaultSessionOwnerOptions
            { sooAdapterOptions = defaultRTGraphAdapterOptions
                { raoPerTemplatePolyphony =
                    M.singleton (TemplateName "stab") 3
                }
            }
          hostOpts = defaultPatternSessionHostOptions
            { pshoProducerOptions =
                defaultPatternProducerOptions { ppoBlockFrames = 8 }
            , pshoQueueOptions =
                SessionQueueOptions 1
            , pshoOwnerOptions =
                ownerOpts
            }
      result <- withPatternSessionHost
                  (patternTemplates polyphonicStab)
                  hostOpts
                  $ \host -> do
                    step1 <- stepPatternSessionHost pat host
                    step2 <- stepPatternSessionHost pat host
                    step3 <- stepPatternSessionHost pat host
                    snapshot <- readPatternSessionHost host
                    pure (step1, step2, step3, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected Pattern session host, got: " <> show issue)
        Right (step1, step2, step3, snapshot) -> do
          perBacklogged (prsEnqueue step1) @?= 2
          perBacklogged (prsEnqueue step2) @?= 1
          perBacklogged (prsEnqueue step3) @?= 0
          assertBool
            "host should clear backlog after the third serialized step"
            (not (pshsBacklogged snapshot))
          assertBool
            ("expected s0, s1, s2 voices after hosted backlog drain, got "
              <> show (ssVoices (pshsOwnerState snapshot)))
            (all
              (\k -> M.member (VoiceKey k) (ssVoices (pshsOwnerState snapshot)))
              ["s0", "s1", "s2"])

  , testCase "concurrent host callers serialize whole Pattern steps" $ do
      let events =
            [ ( SamplePos 0
              , PEVoiceOn (TemplateName "drone") (VoiceKey "v0") []
              )
            , ( SamplePos 8
              , PEVoiceOn (TemplateName "drone") (VoiceKey "v1") []
              )
            ]
          pat = droneVibrato { patternEvents = staticEvents events }
          ownerOpts = defaultSessionOwnerOptions
            { sooAdapterOptions = defaultRTGraphAdapterOptions
                { raoPerTemplatePolyphony =
                    M.singleton (TemplateName "drone") 2
                }
            }
          hostOpts = defaultPatternSessionHostOptions
            { pshoProducerOptions =
                defaultPatternProducerOptions { ppoBlockFrames = 8 }
            , pshoQueueOptions =
                SessionQueueOptions 4
            , pshoOwnerOptions =
                ownerOpts
            }
      result <- withPatternSessionHost
                  (patternTemplates droneVibrato)
                  hostOpts
                  $ \host -> do
                    done <- newEmptyMVar
                    let worker =
                          stepPatternSessionHost pat host >>= putMVar done
                    _ <- forkIO worker
                    _ <- forkIO worker
                    mStep1 <- timeout 1000000 (takeMVar done)
                    mStep2 <- timeout 1000000 (takeMVar done)
                    snapshot <- readPatternSessionHost host
                    pure (mStep1, mStep2, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected Pattern session host, got: " <> show issue)
        Right (Just step1, Just step2, snapshot) -> do
          sort (map (perNextStart . prsEnqueue) [step1, step2])
            @?= [SamplePos 8, SamplePos 16]
          assertBool
            ("expected v0 and v1 voices after concurrent hosted steps, got "
              <> show (ssVoices (pshsOwnerState snapshot)))
            (all
              (\k -> M.member (VoiceKey k) (ssVoices (pshsOwnerState snapshot)))
              ["v0", "v1"])
        Right other ->
          assertFailure ("timed out waiting for concurrent hosted steps: "
                         <> show other)
  ]

patternProducerOrFail :: PatternProducerOptions -> IO PatternProducerState
patternProducerOrFail opts =
  case newPatternProducerState opts of
    Left issue ->
      assertFailure ("expected Pattern producer state, got: " <> show issue)
    Right state ->
      pure state

itemSequence :: PatternEnqueueItem -> Maybe CommandSequence
itemSequence item = case peiResult item of
  SessionEnqueued queued ->
    Just (qscSequence queued)
  SessionEnqueueRejected {} ->
    Nothing

------------------------------------------------------------
-- Session Prep L: preserving hot-swap semantics tests
--
-- Prep K is a decision gate, not an implementation. These tests pin
-- the execution-time semantics that preserving implementations must
-- preserve. Unsupported preserving shapes still reject in the real
-- RTGraph adapter; the one preserved-voice missing-control case uses
-- a mock adapter to model a successful preserve path with a stripped
-- post-swap control surface.
------------------------------------------------------------

sessionPreservingHotSwapSpecTests :: TestTree
sessionPreservingHotSwapSpecTests =
  testGroup "Session Prep L: preserving hot-swap semantics"
  [ testCase "queued hot-swap previews after earlier queued voice-start" $ do
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerPattern "pattern"
          startCmd =
            fromPatternEvent
              (PEVoiceOn (TemplateName "drone") (VoiceKey "v0") [])
          swapCmd =
            fromPatternEvent
              (PEHotSwap (SwapLabel "same-after-start") graph)
      (queue1, startQueued) <- enqueueOrFail producer startCmd queue0
      (queue2, swapQueued) <- enqueueOrFail producer swapCmd queue1

      result <- withSessionOwner graph defaultSessionOwnerOptions $
        \owner -> do
          drained <- drainSessionCommandQueue owner queue2
          st <- sessionOwnerState owner
          status <- sessionOwnerStatus owner
          pure (drained, st, status)

      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right ((_queue3, drain), st, status) -> do
          map sdiQueued (sdrItems drain) @?= [startQueued, swapQueued]
          case map sdiResult (sdrItems drain) of
            [ SessionOwnerStep (StepCommitted _ Nothing)
              , SessionOwnerStep
                  (StepRuntimeFailed SriHotSwapWouldPreserveVoices)
              ] ->
                pure ()
            other ->
              assertFailure
                ("expected start commit then preserving-swap rejection, got: "
                 <> show other)
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          status @?= SessionOwnerReady
          assertBool
            "execution-time hot-swap preview should see the started voice"
            (M.member (VoiceKey "v0") (ssVoices st))

  , testCase "second queued hot-swap previews after the first swap commits" $ do
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          producer = testProducer ProducerPattern "pattern"
          startCmd =
            fromPatternEvent
              (PEVoiceOn (TemplateName "drone") (VoiceKey "v0") [])
          dropCmd =
            fromPatternEvent
              (PEHotSwap (SwapLabel "drop-drone") newGraph)
          restoreCmd =
            fromPatternEvent
              (PEHotSwap (SwapLabel "restore-drone") oldGraph)
          expectedDrop =
            [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
      (queue1, dropQueued) <- enqueueOrFail producer dropCmd queue0
      (queue2, restoreQueued) <- enqueueOrFail producer restoreCmd queue1

      result <- withSessionOwner oldGraph defaultSessionOwnerOptions $
        \owner -> do
          started <- stepSessionOwner owner startCmd
          drained <- drainSessionCommandQueue owner queue2
          st <- sessionOwnerState owner
          status <- sessionOwnerStatus owner
          pure (started, drained, st, status)

      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing),
               (_queue3, drain), st, status) -> do
          map sdiQueued (sdrItems drain) @?= [dropQueued, restoreQueued]
          case map sdiResult (sdrItems drain) of
            [ SessionOwnerStep (StepCommitted _ (Just dropRebuild))
              , SessionOwnerStep (StepCommitted _ (Just restoreRebuild))
              ] -> do
                rrrDropped dropRebuild @?= expectedDrop
                rrrDropped restoreRebuild @?= []
            other ->
              assertFailure
                ("expected two hot-swap commits, got: " <> show other)
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          status @?= SessionOwnerReady
          ssGraph st @?= oldGraph
          ssVoices st @?= M.empty
        Right other ->
          assertFailure ("expected started voice before queued swaps, got: "
                         <> show other)

  , testCase "voice-off after swap-dropped voice is stale, not divergence" $ do
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          producer = testProducer ProducerPattern "pattern"
          startCmd =
            fromPatternEvent
              (PEVoiceOn (TemplateName "drone") (VoiceKey "v0") [])
          swapCmd =
            fromPatternEvent
              (PEHotSwap (SwapLabel "drop-drone") newGraph)
          offCmd =
            fromPatternEvent
              (PEVoiceOff (VoiceKey "v0"))
          expectedDrop =
            [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
      (queue1, swapQueued) <- enqueueOrFail producer swapCmd queue0
      (queue2, offQueued) <- enqueueOrFail producer offCmd queue1

      result <- withSessionOwner oldGraph defaultSessionOwnerOptions $
        \owner -> do
          started <- stepSessionOwner owner startCmd
          drained <- drainSessionCommandQueue owner queue2
          st <- sessionOwnerState owner
          status <- sessionOwnerStatus owner
          pure (started, drained, st, status)

      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing),
               (_queue3, drain), st, status) -> do
          map sdiQueued (sdrItems drain) @?= [swapQueued, offQueued]
          case map sdiResult (sdrItems drain) of
            [ SessionOwnerStep (StepCommitted _ (Just rebuild))
              , SessionOwnerStep (StepRejected (SiStaleVoice (VoiceKey "v0")))
              ] ->
                rrrDropped rebuild @?= expectedDrop
            other ->
              assertFailure
                ("expected drop commit then stale voice-off rejection, got: "
                 <> show other)
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          status @?= SessionOwnerReady
          ssGraph st @?= newGraph
          ssVoices st @?= M.empty
        Right other ->
          assertFailure ("expected started voice before queued voice-off, got: "
                         <> show other)

  , testCase "post-swap missing control is explicit runtime failure" $ do
      strippedGraph <- compileTemplateGraphOrFail
        [ ("drone", runSynth $ do
              carrier <- tagged "carrier" (sinOsc (Param 220.0) (Param 0.0))
              out 0 carrier
          )
        ]
      let oldGraph = patternTemplates droneVibrato
          binding = VoiceBinding (VoiceKey "vLead") 7 (TemplateName "drone")
          st0 = applySessionCommit
                  (CommitVoiceStarted binding)
                  (initialSessionState oldGraph)
          swapLabel = SwapLabel "strip-lpf"
          swapCmd = fromPatternEvent (PEHotSwap swapLabel strippedGraph)
          lpfTag = ControlTag (MigrationKey "lpf") 0
          writeCmd =
            fromPatternEvent
              (PEControlWrite (VoiceKey "vLead") lpfTag 2000.0)
          expectedIssue =
            CtiUnknownNodeTag (TemplateName "drone") (MigrationKey "lpf")
          swapAdapter =
            constantAdapter
              (Right (RuntimeCommitted
                (CommitGraphInstalled swapLabel strippedGraph)))
      swapped <- stepSessionCommand swapAdapter swapCmd st0
      case swapped of
        StepCommitted st1 (Just rebuild) -> do
          rrrDropped rebuild @?= []
          M.lookup (VoiceKey "vLead") (ssVoices st1) @?= Just binding
          let resolverAdapter = SessionRuntimeAdapter $ \case
                PlanControlWrite preservedBinding target _ ->
                  pure $ case resolveControlTarget
                                (ssGraph st1)
                                (vbTemplateName preservedBinding)
                                target of
                    Left issue ->
                      Left (SriControlTargetRejected issue)
                    Right _ ->
                      Right RuntimeControlWriteAccepted
                _other ->
                  pure (Right (RuntimeCommitted
                    (CommitGraphInstalled (SwapLabel "unexpected") (ssGraph st1))))
          written <- stepSessionCommand resolverAdapter writeCmd st1
          written @?= StepRuntimeFailed
            (SriControlTargetRejected expectedIssue)
        other ->
          assertFailure ("expected modeled preserving hot-swap commit, got: "
                         <> show other)
  ]

------------------------------------------------------------
-- Session Prep O: live-audio preserving hot-swap orchestration
--
-- These tests do not start PortAudio. They pin the session-visible
-- failure policy with mock 'SessionRuntimeAdapter' results and pin
-- the producer-side live install protocol with deterministic fake
-- publish/wait/collect callbacks.
------------------------------------------------------------

sessionLiveHotSwapOrchestrationTests :: TestTree
sessionLiveHotSwapOrchestrationTests =
  testGroup "Session Prep O: live preserving hot-swap orchestration"
  [ testCase "publish rejection is a retryable runtime failure" $ do
      (st0, cmd, swapLabel, newGraph) <-
        liveHotSwapFixture "live-publish-rejected"
      (result, observedPlan) <-
        runMockLiveHotSwap st0 cmd SriHotSwapPublishRejected
      result @?= StepRuntimeFailed SriHotSwapPublishRejected
      assertObservedPreservingPlan observedPlan swapLabel newGraph

  , testCase "preserving-only publish rejection keeps preserving-only plan" $ do
      (st0, cmd, swapLabel, newGraph) <-
        liveHotSwapFixtureWith
          CmdHotSwapPreservingOnly
          "live-preserving-only-publish-rejected"
      (result, observedPlan) <-
        runMockLiveHotSwap st0 cmd SriHotSwapPublishRejected
      result @?= StepRuntimeFailed SriHotSwapPublishRejected
      assertObservedHotSwapPlan
        HotSwapPreservingOnly
        observedPlan
        swapLabel
        newGraph

  , testCase "install timeout maps to terminal install failure wrapper" $ do
      assertMockLiveInstallFailure
        "live-install-timeout"
        "preserving hot-swap install timed out"

  , testCase "retired-missing maps to terminal install failure wrapper" $ do
      assertMockLiveInstallFailure
        "live-retired-missing"
        "preserving hot-swap installed but retired swap was missing"

  , testCase "incomplete migration maps to terminal install failure wrapper" $ do
      assertMockLiveInstallFailure
        "live-incomplete-migration"
        "preserving hot-swap migration was incomplete"

  , testCase "preserving-only post-publish failures keep preserving-only plan" $ do
      let cases =
            [ ("timeout", "preserving hot-swap install timed out")
            , ( "retired-missing"
              , "preserving hot-swap installed but retired swap was missing"
              )
            , ( "incomplete-migration"
              , "preserving hot-swap migration was incomplete"
              )
            ]
      forM_ cases $ \(labelSuffix, message) ->
        assertMockPreservingOnlyLiveInstallFailure
          ("live-preserving-only-" <> labelSuffix)
          message

  , testCase "deterministic live protocol orders publish wait collect verify" $ do
      eventsRef <- newIORef []
      let record event =
            modifyIORef' eventsRef (<> [event])
          expectations =
            PreservingHotSwapExpectations
              { phsePreservedBindingCount = 2
              , phseExpectedStateCopyCount = 3
              }
          protocol = LiveHotSwapProtocol
            { lhpReadGeneration = do
                record "read-generation"
                pure 11
            , lhpAcquireSwap = do
                record "acquire"
                pure (Right "swap")
            , lhpPublishSwap = \swap -> do
                swap @?= "swap"
                record "publish"
                pure (Right ())
            , lhpWaitForGeneration = \priorGeneration timeoutMs -> do
                priorGeneration @?= 11
                timeoutMs @?= 250
                record "wait"
                pure True
            , lhpCollectRetiredStats = do
                record "collect"
                pure (Just (fakeMigrationStats 3 2))
            }
      result <- runLiveHotSwapProtocol protocol expectations 250
      result @?= Right ()
      events <- readIORef eventsRef
      events
        @?= [ "read-generation"
            , "acquire"
            , "publish"
            , "wait"
            , "collect"
            ]

  , testCase "deterministic live protocol maps post-publish failures" $ do
      let expectations =
            PreservingHotSwapExpectations
              { phsePreservedBindingCount = 2
              , phseExpectedStateCopyCount = 3
              }
      assertLiveProtocolFailure
        expectations
        "timeout"
        (\protocol -> protocol
          { lhpWaitForGeneration = \_ _ -> pure False
          })
        (SriHotSwapInstallFailed
          (SasiLoaderException "preserving hot-swap install timed out"))
      assertLiveProtocolFailure
        expectations
        "retired-missing"
        (\protocol -> protocol
          { lhpCollectRetiredStats = pure Nothing
          })
        (SriHotSwapInstallFailed
          (SasiLoaderException
            "preserving hot-swap installed but retired swap was missing"))
      assertLiveProtocolFailure
        expectations
        "incomplete-migration"
        (\protocol -> protocol
          { lhpCollectRetiredStats =
              pure (Just (fakeMigrationStats 2 2))
          })
        (SriHotSwapInstallFailed
          (SasiLoaderException
            "preserving hot-swap migration was incomplete"))
  ]

liveHotSwapFixture
  :: String
  -> IO (SessionState, SessionCommand, SwapLabel, TemplateGraph)
liveHotSwapFixture =
  liveHotSwapFixtureWith CmdHotSwap

liveHotSwapFixtureWith
  :: (SwapLabel -> TemplateGraph -> SessionCommand)
  -> String
  -> IO (SessionState, SessionCommand, SwapLabel, TemplateGraph)
liveHotSwapFixtureWith commandFor labelText = do
  newGraph <- compileTemplateGraphOrFail hotSwapEditAfterTemplates
  let oldGraph = patternTemplates hotSwapEdit
      binding  = VoiceBinding (VoiceKey "vLive") 3 (TemplateName "drone")
      st0      = applySessionCommit
                   (CommitVoiceStarted binding)
                   (initialSessionState oldGraph)
      label    = SwapLabel labelText
      cmd      = commandFor label newGraph
  pure (st0, cmd, label, newGraph)

runMockLiveHotSwap
  :: SessionState
  -> SessionCommand
  -> SessionRuntimeIssue
  -> IO (SessionStepResult, Maybe SessionPlan)
runMockLiveHotSwap st cmd issue = do
  observedPlanRef <- newIORef Nothing
  let adapter = SessionRuntimeAdapter $ \plan -> do
        writeIORef observedPlanRef (Just plan)
        pure (Left issue)
  result <- stepSessionCommand adapter cmd st
  observedPlan <- readIORef observedPlanRef
  pure (result, observedPlan)

assertMockLiveInstallFailure :: String -> String -> Assertion
assertMockLiveInstallFailure labelText message = do
  (st0, cmd, swapLabel, newGraph) <- liveHotSwapFixture labelText
  let issue = SriHotSwapInstallFailed (SasiLoaderException message)
  (result, observedPlan) <- runMockLiveHotSwap st0 cmd issue
  result @?= StepRuntimeFailed issue
  assertObservedPreservingPlan observedPlan swapLabel newGraph

assertMockPreservingOnlyLiveInstallFailure :: String -> String -> Assertion
assertMockPreservingOnlyLiveInstallFailure labelText message = do
  (st0, cmd, swapLabel, newGraph) <-
    liveHotSwapFixtureWith CmdHotSwapPreservingOnly labelText
  let issue = SriHotSwapInstallFailed (SasiLoaderException message)
  (result, observedPlan) <- runMockLiveHotSwap st0 cmd issue
  result @?= StepRuntimeFailed issue
  assertObservedHotSwapPlan
    HotSwapPreservingOnly
    observedPlan
    swapLabel
    newGraph

assertObservedPreservingPlan
  :: Maybe SessionPlan
  -> SwapLabel
  -> TemplateGraph
  -> Assertion
assertObservedPreservingPlan observedPlan expectedLabel expectedGraph =
  assertObservedHotSwapPlan
    HotSwapAllowRebuild
    observedPlan
    expectedLabel
    expectedGraph

assertObservedHotSwapPlan
  :: HotSwapInstallMode
  -> Maybe SessionPlan
  -> SwapLabel
  -> TemplateGraph
  -> Assertion
assertObservedHotSwapPlan expectedMode observedPlan expectedLabel expectedGraph =
  case observedPlan of
    Just (PlanHotSwap mode label graph rebuild) -> do
      mode @?= expectedMode
      label @?= expectedLabel
      graph @?= expectedGraph
      rrrDropped rebuild @?= []
    other ->
      assertFailure ("expected preserving PlanHotSwap, got: " <> show other)

assertLiveProtocolFailure
  :: PreservingHotSwapExpectations
  -> String
  -> (LiveHotSwapProtocol IO String -> LiveHotSwapProtocol IO String)
  -> SessionRuntimeIssue
  -> Assertion
assertLiveProtocolFailure expectations labelText patch expectedIssue = do
  let protocol = patch (successfulFakeLiveProtocol labelText)
  result <- runLiveHotSwapProtocol protocol expectations 250
  result @?= Left expectedIssue

successfulFakeLiveProtocol :: String -> LiveHotSwapProtocol IO String
successfulFakeLiveProtocol labelText = LiveHotSwapProtocol
  { lhpReadGeneration =
      pure 11
  , lhpAcquireSwap =
      pure (Right ("swap-" <> labelText))
  , lhpPublishSwap =
      const (pure (Right ()))
  , lhpWaitForGeneration =
      \_ _ -> pure True
  , lhpCollectRetiredStats =
      pure (Just (fakeMigrationStats 3 2))
  }

fakeMigrationStats :: Int -> Int -> SwapMigrationStats
fakeMigrationStats stateCopies lifecycleCopies = SwapMigrationStats
  -- The live protocol verifier currently inspects only state and
  -- lifecycle copy counts; the other counters stay explicit so a
  -- future verifier change has a visible test fixture to revisit.
  { smsCommittedCount = 0
  , smsSkippedCount = 0
  , smsInstanceCopyCount = 0
  , smsStateCopyCount = stateCopies
  , smsLifecycleCopyCount = lifecycleCopies
  }

------------------------------------------------------------
-- Session Prep P: generic producer fan-in host
--
-- This is the first shared command-ingress host for concrete OSC,
-- MIDI, UI, Pattern, or future background producers. It remains
-- caller-driven: producers enqueue commands, and a caller or later
-- worker decides when to drain.
------------------------------------------------------------

sessionFanInHostTests :: TestTree
sessionFanInHostTests =
  testGroup "Session Prep P: producer fan-in host"
  [ testCase "drain preserves FIFO across OSC and MIDI producers" $ do
      let graph = patternTemplates droneVibrato
          oscProducer = testProducer ProducerOSC "osc"
          midiProducer = testProducer ProducerMIDI "midi"
          startCmd =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          writeCmd =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              650.0
      result <- withSessionFanInHost graph defaultSessionFanInOptions $
        \host -> do
          enq0 <- enqueueSessionFanInCommand oscProducer startCmd host
          enq1 <- enqueueSessionFanInCommand midiProducer writeCmd host
          drained <- drainSessionFanInHost host
          snapshot <- readSessionFanInHost host
          pure (enq0, enq1, drained, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (enq0, enq1, drained, snapshot) -> do
          q0 <- fanInQueuedOrFail enq0
          q1 <- fanInQueuedOrFail enq1
          qscSequence q0 @?= CommandSequence 0
          qscSequence q1 @?= CommandSequence 1
          map (qscProducer . sdiQueued) (sdrItems (sfidrDrain drained))
            @?= [oscProducer, midiProducer]
          case map sdiResult (sdrItems (sfidrDrain drained)) of
            [ SessionOwnerStep (StepCommitted _ Nothing)
              , SessionOwnerStep StepControlAccepted
              ] ->
                pure ()
            other ->
              assertFailure
                ("expected voice start then control write, got: " <> show other)
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshot @?= 0
          sfisOwnerStatus snapshot @?= SessionOwnerReady
          assertBool
            "expected v0 in fan-in owner state after drain"
            (M.member (VoiceKey "v0") (ssVoices (sfisOwnerState snapshot)))

  , testCase "bounded queue rejects excess producer command" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd0 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          cmd1 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v1") []
      result <- withSessionFanInHost graph opts $ \host -> do
        enq0 <- enqueueSessionFanInCommand producer cmd0 host
        enq1 <- enqueueSessionFanInCommand producer cmd1 host
        snapshot <- readSessionFanInHost host
        pure (enq0, enq1, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (enq0, enq1, snapshot) -> do
          _queued <- fanInQueuedOrFail enq0
          sfierResult enq1
            @?= SessionEnqueueRejected producer cmd1 (SeiQueueFull 1)
          sfierQueueDepth enq1 @?= 1
          sfisQueueDepth snapshot @?= 1
          sfisOwnerStatus snapshot @?= SessionOwnerReady

  , testCase "concurrent producer enqueues serialize sequence numbers" $ do
      let graph = patternTemplates droneVibrato
          opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 4
            }
      result <- withSessionFanInHost graph opts $ \host -> do
        done <- newEmptyMVar
        let worker producer voiceKey =
              enqueueSessionFanInCommand
                producer
                (CmdVoiceOn (TemplateName "drone") voiceKey [])
                host
                >>= putMVar done
        _ <- forkIO (worker (testProducer ProducerOSC "osc") (VoiceKey "v0"))
        _ <- forkIO (worker (testProducer ProducerMIDI "midi") (VoiceKey "v1"))
        mEnq0 <- timeout 1000000 (takeMVar done)
        mEnq1 <- timeout 1000000 (takeMVar done)
        snapshot <- readSessionFanInHost host
        pure (mEnq0, mEnq1, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just enq0, Just enq1, snapshot) -> do
          let results = [sfierResult enq0, sfierResult enq1]
              queued =
                [ queuedCommand
                | SessionEnqueued queuedCommand <- results
                ]
          length queued @?= 2
          sort (map qscSequence queued)
            @?= [CommandSequence 0, CommandSequence 1]
          sort (map (producerKind . qscProducer) queued)
            @?= [ProducerOSC, ProducerMIDI]
          sfisQueueDepth snapshot @?= 2
        Right other ->
          assertFailure ("timed out waiting for fan-in enqueues: "
                         <> show other)

  , testCase "many concurrent producer enqueues keep contiguous sequences" $ do
      let workerCount = 32
          graph = patternTemplates droneVibrato
          opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions workerCount
            }
          producerFor i =
            testProducer
              (if even i then ProducerOSC else ProducerMIDI)
              ("producer-" <> show i)
          commandFor i =
            CmdVoiceOn
              (TemplateName "drone")
              (VoiceKey ("v" <> show i))
              []
      result <- withSessionFanInHost graph opts $ \host -> do
        done <- newEmptyMVar
        let worker i =
              enqueueSessionFanInCommand
                (producerFor i)
                (commandFor i)
                host
                >>= putMVar done
        forM_ [0 .. workerCount - 1] $ \i ->
          forkIO (worker i)
        enqueues <- forM [0 .. workerCount - 1] $ \_ ->
          timeout 2000000 (takeMVar done)
        snapshot <- readSessionFanInHost host
        pure (enqueues, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (mEnqueues, snapshot) ->
          case sequence mEnqueues of
            Nothing ->
              assertFailure "timed out waiting for fan-in enqueue workers"
            Just enqueues -> do
              let queued =
                    [ queuedCommand
                    | SessionEnqueued queuedCommand <-
                        map sfierResult enqueues
                    ]
              length queued @?= workerCount
              sort (map qscSequence queued)
                @?= map (CommandSequence . fromIntegral)
                      [0 .. workerCount - 1]
              sfisQueueDepth snapshot @?= workerCount

  , testCase "drain divergence leaves unprocessed tail queued" $ do
      let oldGraph = patternTemplates droneVibrato
          badGraph =
            duplicateFirstTwoTemplates (patternTemplates arpeggioSendReturn)
          producer = testProducer ProducerUI "ui"
          issue = SasiDuplicateTemplateName (TemplateName "dup")
          reason = SodHotSwapInstallFailed issue
          badCmd = CmdHotSwap (SwapLabel "bad-graph") badGraph
          laterCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      result <- withSessionFanInHost oldGraph defaultSessionFanInOptions $
        \host -> do
          enq0 <- enqueueSessionFanInCommand producer badCmd host
          _enq1 <- enqueueSessionFanInCommand producer laterCmd host
          drained <- drainSessionFanInHost host
          snapshot <- readSessionFanInHost host
          pure (enq0, drained, snapshot)
      case result of
        Left setupIssue ->
          assertFailure ("expected fan-in host, got: " <> show setupIssue)
        Right (enq0, drained, snapshot) -> do
          queued0 <- fanInQueuedOrFail enq0
          sdrItems (sfidrDrain drained) @?=
            [ SessionDrainItem
                queued0
                (SessionOwnerDivergedNow
                  (StepRuntimeFailed (SriHotSwapInstallFailed issue))
                  reason)
            ]
          sdrRemaining (sfidrDrain drained) @?= 1
          sdrStopped (sfidrDrain drained) @?= Just reason
          sfidrQueueDepth drained @?= 1
          sfisQueueDepth snapshot @?= 1
          sfisOwnerStatus snapshot @?= SessionOwnerDiverged reason
  ]

fanInQueuedOrFail
  :: SessionFanInEnqueueResult
  -> IO QueuedSessionCommand
fanInQueuedOrFail result =
  case sfierResult result of
    SessionEnqueued queued ->
      pure queued
    other ->
      assertFailure ("expected fan-in enqueue success, got: " <> show other)

gatewayQueuedOrFail
  :: SessionArbitrationGatewayEnqueueResult
  -> IO QueuedSessionCommand
gatewayQueuedOrFail result =
  case result of
    SagEnqueueAttempted fanInResult ->
      fanInQueuedOrFail fanInResult
    SagArbitrationRejected issue ->
      assertFailure ("expected arbitration gateway enqueue success, got: "
                     <> show issue)

assertPriorityOwner
  :: ArbitrationPolicy
  -> ControlArbitrationTarget
  -> ProducerId
  -> Assertion
assertPriorityOwner policy target expected =
  case policy of
    ProducerPriority _ owners ->
      lookupControlOwner target owners @?= Just expected
    other ->
      assertFailure ("expected priority policy, got: " <> show other)

------------------------------------------------------------
-- Session fan-in drain service
--
-- This is the first minimal background lifecycle wrapper around the
-- generic fan-in host. It wakes on successful enqueue, drains the
-- existing FIFO host, reports stopped drains, and exits on owner
-- divergence. The raw enqueue path remains FIFO; arbitration is only
-- exercised through the explicit service-owned gateway path.
------------------------------------------------------------

sessionFanInServiceTests :: TestTree
sessionFanInServiceTests =
  testGroup "Session fan-in drain service"
  [ testCase "bracket cleanup: body return tears down worker" $ do
      result <-
        withSessionFanInService
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> readSessionFanInService service
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right snapshot -> do
          sfisQueueDepth snapshot @?= 0
          sfisOwnerStatus snapshot @?= SessionOwnerReady

  , testCase "bracket cleanup kills worker when drain hook blocks" $ do
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      hookEntered <- newEmptyMVar
      neverRelease <- newEmptyMVar
      result <- timeout 1000000 $
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain =
                \_drained -> do
                  putMVar hookEntered ()
                  takeMVar neverRelease
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueSessionFanInServiceCommand producer cmd service
              mEntered <- timeout 1000000 (takeMVar hookEntered)
              pure (enq, mEntered)
      case result of
        Nothing ->
          assertFailure
            "service teardown hung while drain hook was blocked"
        Just (Left issue) ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Just (Right (enq, Just ())) -> do
          _queued <- fanInQueuedOrFail enq
          pure ()
        Just (Right (_enq, Nothing)) ->
          assertFailure "timed out waiting for blocking drain hook"

  , testCase "successful enqueue wakes background drain worker" $ do
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueSessionFanInServiceCommand producer cmd service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (enq, Just drained, snapshot) -> do
          queued <- fanInQueuedOrFail enq
          case sdrItems (sfidrDrain drained) of
            [SessionDrainItem drainedQueued
              (SessionOwnerStep (StepCommitted _ Nothing))] ->
                drainedQueued @?= queued
            other ->
              assertFailure
                ("expected one committed background drain, got: "
                 <> show other)
          sdrRemaining (sfidrDrain drained) @?= 0
          sdrStopped (sfidrDrain drained) @?= Nothing
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshot @?= 0
          assertBool
            "expected v0 in service owner state after background drain"
            (M.member (VoiceKey "v0") (ssVoices (sfisOwnerState snapshot)))
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for service drain"

  , testCase "quiesce/drain waits for active worker and owns final drain" $ do
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          firstCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          secondCmd =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              0.75
      hookCount <- newIORef (0 :: Int)
      firstWorkerDrain <- newEmptyMVar
      releaseFirstHook <- newEmptyMVar
      unexpectedWorkerDrain <- newEmptyMVar
      finalDrainVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain =
                \drained -> do
                  n <- readIORef hookCount
                  writeIORef hookCount (n + 1)
                  if n == 0
                    then do
                      putMVar firstWorkerDrain drained
                      takeMVar releaseFirstHook
                    else
                      putMVar unexpectedWorkerDrain drained
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq0 <- enqueueSessionFanInServiceCommand
                        producer firstCmd service
              mFirstDrain <- timeout 1000000 (takeMVar firstWorkerDrain)
              enq1 <- enqueueSessionFanInServiceCommand
                        producer secondCmd service
              _worker <- forkIO $
                quiesceAndDrainSessionFanInService service
                  >>= putMVar finalDrainVar
              mEarlyFinal <- timeout 100000 (takeMVar finalDrainVar)
              putMVar releaseFirstHook ()
              mFinalDrain <- timeout 1000000 (takeMVar finalDrainVar)
              mUnexpectedWorkerDrain <-
                timeout 100000 (takeMVar unexpectedWorkerDrain)
              snapshot <- readSessionFanInService service
              pure
                ( enq0
                , mFirstDrain
                , enq1
                , mEarlyFinal
                , mFinalDrain
                , mUnexpectedWorkerDrain
                , snapshot
                )
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( enq0
          , Just firstDrain
          , enq1
          , Nothing
          , Just finalDrain
          , Nothing
          , snapshot
          ) -> do
            queued0 <- fanInQueuedOrFail enq0
            queued1 <- fanInQueuedOrFail enq1
            case sdrItems (sfidrDrain firstDrain) of
              [SessionDrainItem drainedQueued
                (SessionOwnerStep (StepCommitted _ Nothing))] ->
                  drainedQueued @?= queued0
              other ->
                assertFailure
                  ("expected first worker drain to own v0, got: "
                   <> show other)
            case sdrItems (sfidrDrain finalDrain) of
              [SessionDrainItem drainedQueued
                (SessionOwnerStep StepControlAccepted)] ->
                  drainedQueued @?= queued1
              other ->
                assertFailure
                  ("expected final quiesce drain to own control write, got: "
                   <> show other)
            sfidrQueueDepth finalDrain @?= 0
            sfisQueueDepth snapshot @?= 0
            assertBool
              "expected v0 in owner state after quiesce drain"
              (M.member (VoiceKey "v0") (ssVoices (sfisOwnerState snapshot)))
        Right (_enq0, Nothing, _enq1, _mEarly, _mFinal, _mUnexpected, _snapshot) ->
          assertFailure "timed out waiting for first worker drain"
        Right (_enq0, Just _first, _enq1, Just early, _mFinal, _mUnexpected, _snapshot) ->
          assertFailure
            ("quiesce final drain returned before worker settled: "
             <> show early)
        Right (_enq0, Just _first, _enq1, Nothing, Nothing, _mUnexpected, _snapshot) ->
          assertFailure "timed out waiting for final quiesce drain"
        Right (_enq0, Just _first, _enq1, Nothing, Just _final, Just extra, _snapshot) ->
          assertFailure
            ("background worker drained after quiesce request: "
             <> show extra)

  , testCase "quiesce rejects service enqueues without waking worker" $ do
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              finalDrain <- quiesceAndDrainSessionFanInService service
              rawRejected <- enqueueSessionFanInServiceCommand
                               producer cmd service
              arbitratedRejected <- enqueueArbitratedSessionFanInServiceCommand
                                      producer cmd service
              mWorkerDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure
                ( finalDrain
                , rawRejected
                , arbitratedRejected
                , mWorkerDrain
                , snapshot
                )
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (finalDrain, rawRejected, arbitratedRejected, Nothing, snapshot) -> do
          sdrItems (sfidrDrain finalDrain) @?= []
          sfidrQueueDepth finalDrain @?= 0
          sfierResult rawRejected @?=
            SessionEnqueueRejected producer cmd SeiReloadInProgress
          sfierQueueDepth rawRejected @?= 0
          case arbitratedRejected of
            SagEnqueueAttempted nested -> do
              sfierResult nested @?=
                SessionEnqueueRejected producer cmd SeiReloadInProgress
              sfierQueueDepth nested @?= 0
            other ->
              assertFailure
                ("expected quiesced arbitrated enqueue attempt, got: "
                 <> show other)
          sfisQueueDepth snapshot @?= 0
        Right (_finalDrain, _rawRejected, _arbitratedRejected, Just drained, _snapshot) ->
          assertFailure
            ("quiesced service unexpectedly woke worker: " <> show drained)

  , testCase "resume after quiesce starts a fresh drain worker" $ do
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              finalDrain <- quiesceAndDrainSessionFanInService service
              resumeSessionFanInService service
              enq <- enqueueSessionFanInServiceCommand producer cmd service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (finalDrain, enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (finalDrain, enq, Just drained, snapshot) -> do
          sdrItems (sfidrDrain finalDrain) @?= []
          sfidrQueueDepth finalDrain @?= 0
          queued <- fanInQueuedOrFail enq
          case sdrItems (sfidrDrain drained) of
            [SessionDrainItem drainedQueued
              (SessionOwnerStep (StepCommitted _ Nothing))] ->
                drainedQueued @?= queued
            other ->
              assertFailure
                ("expected resumed worker to drain one command, got: "
                 <> show other)
          sdrStopped (sfidrDrain drained) @?= Nothing
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshot @?= 0
        Right (_finalDrain, _enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for resumed service drain"

  , testCase "default arbitrated enqueue keeps FIFO service behavior" $ do
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueArbitratedSessionFanInServiceCommand
                       producer cmd service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (enq, Just drained, snapshot) -> do
          queued <- gatewayQueuedOrFail enq
          case sdrItems (sfidrDrain drained) of
            [SessionDrainItem drainedQueued
              (SessionOwnerStep (StepCommitted _ Nothing))] ->
                drainedQueued @?= queued
            other ->
              assertFailure
                ("expected one committed arbitrated drain, got: "
                 <> show other)
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshot @?= 0
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for arbitrated service drain"

  , testCase "configured arbitration rejects before service wake" $ do
      let graph = patternTemplates droneVibrato
          oscProducer = testProducer ProducerOSC "osc"
          patternProducer = testProducer ProducerPattern "pattern"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          command =
            CmdControlWrite (VoiceKey "v0") levelTag 0.5
          opts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      ProducerPriority
                        [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
                        emptyControlOwnerTable
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = patternProducer
            , aiCommand   = command
            , aiTarget    = Just target
            , aiReason    = ArrLowerPriorityThan oscProducer
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            , sfshOnIssue = putMVar issueVar
            }
          graph
          opts
          $ \service -> do
              enq0 <- enqueueArbitratedSessionFanInServiceCommand
                        oscProducer command service
              mFirstDrain <- timeout 1000000 (takeMVar drainedVar)
              rejected <- enqueueArbitratedSessionFanInServiceCommand
                            patternProducer command service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              mRejectedDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure
                ( enq0
                , mFirstDrain
                , rejected
                , mIssue
                , mRejectedDrain
                , snapshot
                )
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( enq0
          , Just _firstDrain
          , rejected
          , Just reported
          , Nothing
          , snapshot
          ) -> do
            queued0 <- gatewayQueuedOrFail enq0
            qscProducer queued0 @?= oscProducer
            qscSequence queued0 @?= CommandSequence 0
            rejected @?= SagArbitrationRejected expectedIssue
            reported @?= SfsiiArbitrationRejected expectedIssue
            sfisQueueDepth snapshot @?= 0
        Right (_enq0, Nothing, _rejected, _mIssue, _mRejectedDrain, _snapshot) ->
          assertFailure "timed out waiting for first arbitrated drain"
        Right (_enq0, Just _firstDrain, _rejected, Nothing, _mRejectedDrain, _snapshot) ->
          assertFailure "timed out waiting for arbitration rejection issue"
        Right (_enq0, Just _firstDrain, _rejected, Just _reported, Just extraDrain, _snapshot) ->
          assertFailure
            ("policy rejection unexpectedly woke service drain: "
             <> show extraDrain)

  , testCase "target-claim arbitration rejects before service wake" $ do
      let graph = patternTemplates droneVibrato
          claimant = testProducer ProducerUI "ui"
          blocked  = testProducer ProducerMIDI "midi"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          claimedCommand =
            CmdControlWrite (VoiceKey "v0") levelTag 0.25
          otherCommand =
            CmdControlWrite (VoiceKey "v0") freqTag 440.0
          opts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = blocked
            , aiCommand   = claimedCommand
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          opts
          $ \service -> do
              claimantEnq <- enqueueArbitratedSessionFanInServiceCommand
                               claimant claimedCommand service
              mFirstDrain <- timeout 1000000 (takeMVar drainedVar)
              rejected <- enqueueArbitratedSessionFanInServiceCommand
                            blocked claimedCommand service
              mRejectedDrain <- timeout 100000 (takeMVar drainedVar)
              otherEnq <- enqueueArbitratedSessionFanInServiceCommand
                            blocked otherCommand service
              mOtherDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure
                ( claimantEnq
                , mFirstDrain
                , rejected
                , mRejectedDrain
                , otherEnq
                , mOtherDrain
                , snapshot
                )
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( claimantEnq
          , Just _firstDrain
          , rejected
          , Nothing
          , otherEnq
          , Just _otherDrain
          , snapshot
          ) -> do
            q0 <- gatewayQueuedOrFail claimantEnq
            q1 <- gatewayQueuedOrFail otherEnq
            qscProducer q0 @?= claimant
            qscProducer q1 @?= blocked
            qscSequence q0 @?= CommandSequence 0
            qscSequence q1 @?= CommandSequence 1
            qscCommand q0 @?= claimedCommand
            qscCommand q1 @?= otherCommand
            rejected @?= SagArbitrationRejected expectedIssue
            sfisQueueDepth snapshot @?= 0
        Right (_claimantEnq, Nothing, _rejected, _mRejectedDrain, _otherEnq, _mOtherDrain, _snapshot) ->
          assertFailure "timed out waiting for claimant drain"
        Right (_claimantEnq, Just _firstDrain, _rejected, Just extraDrain, _otherEnq, _mOtherDrain, _snapshot) ->
          assertFailure
            ("target-claim rejection unexpectedly woke service drain: "
             <> show extraDrain)
        Right (_claimantEnq, Just _firstDrain, _rejected, Nothing, _otherEnq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for unrelated target drain"

  , testCase "service host wakes worker for OSC producer enqueue" $ do
      let graph = patternTemplates droneVibrato
          msg = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                [OSC.OscArgFloat 900.0]
          expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              900.0
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <-
                enqueueOSCControlWrite
                  defaultOSCProducerOptions
                  msg
                  (sessionFanInServiceHost service)
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (OSCProducerEnqueueAttempted command enq, Just drained, snapshot) -> do
          command @?= expected
          queued <- fanInQueuedOrFail enq
          qscCommand queued @?= expected
          producerKind (qscProducer queued) @?= ProducerOSC
          case map sdiResult (sdrItems (sfidrDrain drained)) of
            [SessionOwnerStep (StepRejected (SiStaleVoice (VoiceKey "v0")))] ->
              pure ()
            other ->
              assertFailure
                ("expected stale OSC control-write drain, got: " <> show other)
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshot @?= 0
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for OSC service drain"
        Right other ->
          assertFailure ("expected OSC enqueue through service, got: "
                         <> show other)

  , testCase "divergent drain reports issue and stops worker" $ do
      let oldGraph = patternTemplates droneVibrato
          badGraph =
            duplicateFirstTwoTemplates (patternTemplates arpeggioSendReturn)
          producer = testProducer ProducerUI "ui"
          setupIssue = SasiDuplicateTemplateName (TemplateName "dup")
          divergedReason = SodHotSwapInstallFailed setupIssue
          badCmd = CmdHotSwap (SwapLabel "bad-graph") badGraph
          laterCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnIssue = putMVar issueVar
            }
          oldGraph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq0 <- enqueueSessionFanInServiceCommand producer badCmd service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              enq1 <- enqueueSessionFanInServiceCommand producer laterCmd service
              snapshot <- readSessionFanInService service
              pure (enq0, mIssue, enq1, snapshot)
      case result of
        Left serviceIssue ->
          assertFailure ("expected fan-in service, got: " <> show serviceIssue)
        Right (enq0, Just (SfsiiDrainStopped stopped), enq1, snapshot) -> do
          queued0 <- fanInQueuedOrFail enq0
          queued1 <- fanInQueuedOrFail enq1
          sdrItems (sfidrDrain stopped) @?=
            [ SessionDrainItem
                queued0
                (SessionOwnerDivergedNow
                  (StepRuntimeFailed (SriHotSwapInstallFailed setupIssue))
                  divergedReason)
            ]
          sdrRemaining (sfidrDrain stopped) @?= 0
          sdrStopped (sfidrDrain stopped) @?= Just divergedReason
          sfidrQueueDepth stopped @?= 0
          qscSequence queued1 @?= CommandSequence 1
          sfisQueueDepth snapshot @?= 1
          sfisOwnerStatus snapshot @?= SessionOwnerDiverged divergedReason
        Right (_enq0, Nothing, _enq1, _snapshot) ->
          assertFailure "timed out waiting for service stopped-drain issue"
  ]

------------------------------------------------------------
-- Shared control tags for session arbitration and UI tests
------------------------------------------------------------

freqTag :: ControlTag
freqTag =
  ControlTag (MigrationKey "freq") 0

levelTag :: ControlTag
levelTag =
  ControlTag (MigrationKey "level") 0

------------------------------------------------------------
-- Session UI producer adapter
--
-- This adapter is Haskell-only and consumes already-decoded UI
-- intents. It is not a GUI toolkit binding, manifest reload path, or
-- authorization layer.
------------------------------------------------------------

sessionUIProducerTests :: TestTree
sessionUIProducerTests =
  testGroup "Session UI producer adapter"
  [ testCase "decodes UI intents to session commands" $ do
      let start =
            UIVoiceOn
              (TemplateName "drone")
              (VoiceKey "u0")
              [(levelTag, 0.5)]
          write =
            UIControlWrite (VoiceKey "u0") levelTag 0.75
          stop =
            UIVoiceOff (VoiceKey "u0")
          swap =
            UIHotSwap
              (SwapLabel "ui-swap")
              (patternTemplates droneVibrato)
      decodeUISessionCommand start
        @?= Right (CmdVoiceOn
                    (TemplateName "drone")
                    (VoiceKey "u0")
                    [(levelTag, 0.5)])
      decodeUISessionCommand write
        @?= Right (CmdControlWrite (VoiceKey "u0") levelTag 0.75)
      decodeUISessionCommand stop
        @?= Right (CmdVoiceOff (VoiceKey "u0"))
      decodeUISessionCommand swap
        @?= Right (CmdHotSwap
                    (SwapLabel "ui-swap")
                    (patternTemplates droneVibrato))

  , testCase "rejects non-finite UI values before enqueue" $ do
      let infinity = 1.0 / 0.0
      decodeUISessionCommand
        (UIControlWrite (VoiceKey "u0") levelTag infinity)
        @?= Left (UpiNonFiniteControlValue levelTag infinity)
      decodeUISessionCommand
        (UIVoiceOn
          (TemplateName "drone")
          (VoiceKey "u0")
          [(levelTag, infinity)])
        @?= Left (UpiNonFiniteInitialControl levelTag infinity)

  , testCase "successful enqueue attributes command to ProducerUI" $ do
      let opts = testUIProducerOptions
          intent =
            UIVoiceOn (TemplateName "drone") (VoiceKey "u0") []
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  defaultSessionFanInOptions
                  $ \host -> do
                    enq <- enqueueUIProducerIntent opts intent host
                    snapshot <- readSessionFanInHost host
                    pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (UIProducerEnqueueAttempted command enq, snapshot) -> do
          queued <- fanInQueuedOrFail enq
          command @?= CmdVoiceOn (TemplateName "drone") (VoiceKey "u0") []
          producerKind (qscProducer queued) @?= ProducerUI
          producerName (qscProducer queued) @?= upoProducerName opts
          qscCommand queued @?= command
          sfierQueueDepth enq @?= 1
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected UI enqueue attempt, got: " <> show other)

  , testCase "decode rejection does not enqueue" $ do
      let infinity = 1.0 / 0.0
          intent = UIControlWrite (VoiceKey "u0") levelTag infinity
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  defaultSessionFanInOptions
                  $ \host -> do
                    enq <- enqueueUIProducerIntent
                             testUIProducerOptions
                             intent
                             host
                    snapshot <- readSessionFanInHost host
                    pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (UIProducerRejected issue, snapshot) -> do
          issue @?= UpiNonFiniteControlValue levelTag infinity
          sfisQueueDepth snapshot @?= 0
        Right other ->
          assertFailure ("expected UI rejection, got: " <> show other)

  , testCase "queue-full surfaces through UI enqueue result" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
          intent =
            UIVoiceOn (TemplateName "drone") (VoiceKey "u0") []
          expected =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "u0") []
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  opts
                  $ \host -> do
                    _prefill <-
                      enqueueSessionFanInCommand
                        (testProducer ProducerTest "prefill")
                        prefill
                        host
                    enqueueUIProducerIntent
                      testUIProducerOptions
                      intent
                      host
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (UIProducerEnqueueAttempted command enq) -> do
          command @?= expected
          sfierResult enq
            @?= SessionEnqueueRejected
                  (uiProducerId testUIProducerOptions)
                  expected
                  (SeiQueueFull 1)
        Right other ->
          assertFailure ("expected queue-full UI enqueue, got: " <> show other)

  , testCase "service host wakes worker for UI voice-on" $ do
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueUIProducerIntent
                       testUIProducerOptions
                       (UIVoiceOn (TemplateName "drone") (VoiceKey "u0") [])
                       (sessionFanInServiceHost service)
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (UIProducerEnqueueAttempted _ enq, Just drained, snapshot) -> do
          queued <- fanInQueuedOrFail enq
          map sdiQueued (sdrItems (sfidrDrain drained)) @?= [queued]
          case map sdiResult (sdrItems (sfidrDrain drained)) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure
                ("expected UI voice-on to commit through service, got: "
                 <> show other)
          sfisQueueDepth snapshot @?= 0
          assertBool
            "expected UI voice after service drain"
            (M.member (VoiceKey "u0") (ssVoices (sfisOwnerState snapshot)))
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for UI service drain"
        Right other ->
          assertFailure ("expected UI service enqueue, got: " <> show other)

  , testCase "arbitrated service UI enqueue defaults to FIFO" $ do
      let intent =
            UIVoiceOn (TemplateName "drone") (VoiceKey "u0") []
          expected =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "u0") []
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueArbitratedUIProducerIntent
                       testUIProducerOptions
                       intent
                       service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( UIProducerArbitratedEnqueueAttempted command gatewayResult
          , Just drained
          , snapshot
          ) -> do
            command @?= expected
            queued <- gatewayQueuedOrFail gatewayResult
            qscProducer queued @?= uiProducerId testUIProducerOptions
            qscCommand queued @?= expected
            map sdiQueued (sdrItems (sfidrDrain drained)) @?= [queued]
            case map sdiResult (sdrItems (sfidrDrain drained)) of
              [SessionOwnerStep (StepCommitted _ Nothing)] ->
                pure ()
              other ->
                assertFailure
                  ("expected arbitrated UI voice-on to commit, got: "
                   <> show other)
            sfisQueueDepth snapshot @?= 0
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for arbitrated UI service drain"
        Right other ->
          assertFailure ("expected arbitrated UI service enqueue, got: "
                         <> show other)

  , testCase "arbitrated service UI rejection reports service issue" $ do
      let intent =
            UIControlWrite (VoiceKey "u0") levelTag 0.75
          expected =
            CmdControlWrite (VoiceKey "u0") levelTag 0.75
          producer = uiProducerId testUIProducerOptions
          claimant = testProducer ProducerOSC "osc"
          target =
            ControlArbitrationTarget (VoiceKey "u0") levelTag
          serviceOpts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = producer
            , aiCommand   = expected
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            , sfshOnIssue = putMVar issueVar
            }
          (patternTemplates droneVibrato)
          serviceOpts
          $ \service -> do
              enq <- enqueueArbitratedUIProducerIntent
                       testUIProducerOptions
                       intent
                       service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              mDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mIssue, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( UIProducerArbitratedEnqueueAttempted command rejected
          , Just reported
          , Nothing
          , snapshot
          ) -> do
            command @?= expected
            rejected @?= SagArbitrationRejected expectedIssue
            reported @?= SfsiiArbitrationRejected expectedIssue
            sfisQueueDepth snapshot @?= 0
        Right (UIProducerArbitratedRejected issue, _mIssue, _mDrain, _snapshot) ->
          assertFailure ("expected arbitrated enqueue attempt, got local rejection: "
                         <> show issue)
        Right (_enq, Nothing, _mDrain, _snapshot) ->
          assertFailure "timed out waiting for UI arbitration rejection issue"
        Right (_enq, Just _reported, Just extraDrain, _snapshot) ->
          assertFailure
            ("UI policy rejection unexpectedly woke service drain: "
             <> show extraDrain)

  , testCase "arbitrated service UI decode rejection does not report issue" $ do
      let infinity = 1.0 / 0.0
          intent = UIControlWrite (VoiceKey "u0") levelTag infinity
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnIssue = putMVar issueVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              rejected <- enqueueArbitratedUIProducerIntent
                            testUIProducerOptions
                            intent
                            service
              mIssue <- timeout 100000 (takeMVar issueVar)
              snapshot <- readSessionFanInService service
              pure (rejected, mIssue, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (rejected, Nothing, snapshot) -> do
          rejected
            @?= UIProducerArbitratedRejected
                  (UpiNonFiniteControlValue levelTag infinity)
          sfisQueueDepth snapshot @?= 0
        Right (_rejected, Just issue, _snapshot) ->
          assertFailure
            ("UI decode rejection unexpectedly reported service issue: "
             <> show issue)
  ]

testUIProducerOptions :: UIProducerOptions
testUIProducerOptions = defaultUIProducerOptions
  { upoProducerName = T.pack "ui-test"
  }

------------------------------------------------------------
-- Session OSC producer adapter
--
-- The adapter is intentionally narrow: it reuses the OSC dispatch
-- symbolic decoder, converts only control writes to SessionCommand,
-- and submits them to the generic fan-in host as ProducerOSC.
------------------------------------------------------------

sessionOSCProducerTests :: TestTree
sessionOSCProducerTests =
  testGroup "Session OSC producer adapter"
  [ testCase "decodes symbolic OSC control write to session command" $ do
      let msg = OSC.OscMessage (OBSC.pack "/v0/lpf/1")
                                [OSC.OscArgFloat 1800.0]
      decodeOSCSessionCommand msg
        @?= Right
              (CmdControlWrite
                (VoiceKey "v0")
                (ControlTag (MigrationKey "lpf") 1)
                1800.0)

  , testCase "valid control write enqueues under ProducerOSC" $ do
      let graph = patternTemplates droneVibrato
          opts = defaultOSCProducerOptions
          producer = oscProducerId opts
          msg = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                [OSC.OscArgInt 700]
          expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              700.0
      result <- withSessionFanInHost graph defaultSessionFanInOptions $
        \host -> do
          enq <- enqueueOSCControlWrite opts msg host
          snapshot <- readSessionFanInHost host
          pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (OSCProducerEnqueueAttempted command enq, snapshot) -> do
          command @?= expected
          queued <- fanInQueuedOrFail enq
          qscProducer queued @?= producer
          qscCommand queued @?= expected
          sfierQueueDepth enq @?= 1
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected OSC enqueue attempt, got: " <> show other)

  , testCase "arbitrated service path defaults to FIFO behavior" $ do
      let graph = patternTemplates droneVibrato
          opts = defaultOSCProducerOptions
          producer = oscProducerId opts
          msg = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                [OSC.OscArgFloat 1200.0]
          expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1200.0
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueArbitratedOSCControlWrite opts msg service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( OSCProducerArbitratedEnqueueAttempted command gatewayResult
          , Just drained
          , snapshot
          ) -> do
            command @?= expected
            queued <- gatewayQueuedOrFail gatewayResult
            qscProducer queued @?= producer
            qscCommand queued @?= expected
            case map sdiResult (sdrItems (sfidrDrain drained)) of
              [SessionOwnerStep (StepRejected (SiStaleVoice (VoiceKey "v0")))] ->
                pure ()
              other ->
                assertFailure
                  ("expected stale OSC control-write drain, got: "
                   <> show other)
            sfidrQueueDepth drained @?= 0
            sfisQueueDepth snapshot @?= 0
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for arbitrated OSC service drain"
        Right other ->
          assertFailure
            ("expected arbitrated OSC enqueue through service, got: "
             <> show other)

  , testCase "arbitrated service path reports policy rejection" $ do
      let graph = patternTemplates droneVibrato
          opts = defaultOSCProducerOptions
          producer = oscProducerId opts
          claimant = testProducer ProducerUI "ui"
          target =
            ControlArbitrationTarget
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
          msg = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                [OSC.OscArgFloat 1200.0]
          expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1200.0
          serviceOpts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = producer
            , aiCommand   = expected
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            , sfshOnIssue = putMVar issueVar
            }
          graph
          serviceOpts
          $ \service -> do
              rejected <- enqueueArbitratedOSCControlWrite opts msg service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              mDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (rejected, mIssue, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( OSCProducerArbitratedEnqueueAttempted command rejected
          , Just reported
          , Nothing
          , snapshot
          ) -> do
            command @?= expected
            rejected @?= SagArbitrationRejected expectedIssue
            reported @?= SfsiiArbitrationRejected expectedIssue
            sfisQueueDepth snapshot @?= 0
        Right (_rejected, Nothing, _mDrain, _snapshot) ->
          assertFailure "timed out waiting for OSC arbitration issue"
        Right (_rejected, Just _reported, Just extraDrain, _snapshot) ->
          assertFailure
            ("OSC policy rejection unexpectedly woke service drain: "
             <> show extraDrain)

  , testCase "arbitrated service path decode rejection does not report issue" $ do
      let graph = patternTemplates droneVibrato
          msg = OSC.OscMessage (OBSC.pack "/swap/lpf/0")
                                [OSC.OscArgFloat 1.0]
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnIssue = putMVar issueVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              rejected <-
                enqueueArbitratedOSCControlWrite
                  defaultOSCProducerOptions
                  msg
                  service
              mIssue <- timeout 100000 (takeMVar issueVar)
              snapshot <- readSessionFanInService service
              pure (rejected, mIssue, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (rejected, Nothing, snapshot) -> do
          rejected @?=
            OSCProducerArbitratedDecodeRejected
              (OSC.DiReservedPathSegment (OBSC.pack "swap"))
          sfisQueueDepth snapshot @?= 0
        Right (_rejected, Just issue, _snapshot) ->
          assertFailure
            ("OSC decode rejection unexpectedly reported service issue: "
             <> show issue)

  , testCase "reserved and invalid identifiers are rejected" $ do
      let cases =
            [ ( "reserved voice"
              , OSC.OscMessage (OBSC.pack "/swap/lpf/0")
                                [OSC.OscArgFloat 1.0]
              , OSC.DiReservedPathSegment (OBSC.pack "swap")
              )
            , ( "invalid voice"
              , OSC.OscMessage (OBSC.pack "/bad name/lpf/0")
                                [OSC.OscArgFloat 1.0]
              , OSC.DiIdentifierProfile (OBSC.pack "bad name")
              )
            , ( "invalid node tag"
              , OSC.OscMessage (OBSC.pack "/v0/bad name/0")
                                [OSC.OscArgFloat 1.0]
              , OSC.DiIdentifierProfile (OBSC.pack "bad name")
              )
            ]
      forM_ cases $ \(label, msg, expected) ->
        case decodeOSCSessionCommand msg of
          Left issue ->
            issue @?= expected
          Right command ->
            assertFailure
              (label <> ": expected decode rejection, got "
               <> show command)

  , testCase "bad slots and argument shapes are rejected" $ do
      let cases =
            [ ( "non-integer slot"
              , OSC.OscMessage (OBSC.pack "/v0/lpf/cutoff")
                                [OSC.OscArgFloat 1.0]
              , OSC.DiSlotNotInteger (OBSC.pack "cutoff")
              )
            , ( "zero args"
              , OSC.OscMessage (OBSC.pack "/v0/lpf/0") []
              , OSC.DiUnsupportedArgShape 0
              )
            , ( "two args"
              , OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                [OSC.OscArgFloat 1.0, OSC.OscArgInt 2]
              , OSC.DiUnsupportedArgShape 2
              )
            ]
      forM_ cases $ \(label, msg, expected) ->
        case decodeOSCSessionCommand msg of
          Left issue ->
            issue @?= expected
          Right command ->
            assertFailure
              (label <> ": expected decode rejection, got "
               <> show command)

  , testCase "decode rejection does not enqueue" $ do
      let graph = patternTemplates droneVibrato
          msg = OSC.OscMessage (OBSC.pack "/swap/lpf/0")
                                [OSC.OscArgFloat 1.0]
      result <- withSessionFanInHost graph defaultSessionFanInOptions $
        \host -> do
          enq <- enqueueOSCControlWrite defaultOSCProducerOptions msg host
          snapshot <- readSessionFanInHost host
          pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (enq, snapshot) -> do
          enq @?= OSCProducerDecodeRejected
                    (OSC.DiReservedPathSegment (OBSC.pack "swap"))
          sfisQueueDepth snapshot @?= 0

  , testCase "queue-full surfaces through fan-in enqueue result" $ do
      let graph = patternTemplates droneVibrato
          opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          producer = oscProducerId defaultOSCProducerOptions
          msg0 = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                 [OSC.OscArgFloat 800.0]
          msg1 = OSC.OscMessage (OBSC.pack "/v1/lpf/0")
                                 [OSC.OscArgFloat 900.0]
          cmd1 =
            CmdControlWrite
              (VoiceKey "v1")
              (ControlTag (MigrationKey "lpf") 0)
              900.0
      result <- withSessionFanInHost graph opts $ \host -> do
        enq0 <- enqueueOSCControlWrite defaultOSCProducerOptions msg0 host
        enq1 <- enqueueOSCControlWrite defaultOSCProducerOptions msg1 host
        snapshot <- readSessionFanInHost host
        pure (enq0, enq1, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (OSCProducerEnqueueAttempted _ first, second, snapshot) -> do
          _queued <- fanInQueuedOrFail first
          second
            @?= OSCProducerEnqueueAttempted
                  cmd1
                  SessionFanInEnqueueResult
                    { sfierResult =
                        SessionEnqueueRejected
                          producer
                          cmd1
                          (SeiQueueFull 1)
                    , sfierQueueDepth = 1
                    }
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected queue-full OSC enqueue, got: "
                         <> show other)
  ]

------------------------------------------------------------
-- Session OSC listener adapter
--
-- This is the UDP wrapper above the OSC producer adapter. It only
-- enqueues into SessionFanInHost; draining stays caller-driven.
------------------------------------------------------------

sessionOSCListenerTests :: TestTree
sessionOSCListenerTests =
  testGroup "Session OSC listener adapter"
  [ testCase "bracket cleanup: body return tears down listener" $ do
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              OSCS.withSessionOSCListener
                defaultOSCProducerOptions
                host
                (OSCS.defaultListenerConfig 0)
                (\_info -> pure (42 :: Int))
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right value ->
          value @?= 42

  , testCase "loopback packet enqueues but does not drain" $ do
      let expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1500.0
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host -> do
              received <- newEmptyMVar
              let hooks = OSCS.SessionOSCListenerHooks
                    { OSCS.solhOnProducerResult = putMVar received
                    , OSCS.solhOnIssue          = \_ -> pure ()
                    }
              OSCS.withSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                host
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mResult <- timeout 1000000 (takeMVar received)
                    snapshot <- readSessionFanInHost host
                    pure (mResult, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (OSCProducerEnqueueAttempted command enq), snapshot) -> do
          command @?= expected
          queued <- fanInQueuedOrFail enq
          qscCommand queued @?= expected
          producerKind (qscProducer queued) @?= ProducerOSC
          sfisQueueDepth snapshot @?= 1
          sfisOwnerStatus snapshot @?= SessionOwnerReady
          ssVoices (sfisOwnerState snapshot) @?= M.empty
        Right other ->
          assertFailure ("expected one OSC producer result, got: "
                         <> show other)

  , testCase "arbitrated service listener loopback defaults to FIFO" $ do
      let expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1500.0
          producer = oscProducerId defaultOSCProducerOptions
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              received <- newEmptyMVar
              let hooks = OSCS.SessionOSCArbitratedListenerHooks
                    { OSCS.solahOnProducerResult = putMVar received
                    , OSCS.solahOnIssue          = \_ -> pure ()
                    }
              OSCS.withArbitratedSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                service
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mResult <- timeout 1000000 (takeMVar received)
                    mDrain <- timeout 1000000 (takeMVar drainedVar)
                    snapshot <- readSessionFanInService service
                    pure (mResult, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( Just (OSCProducerArbitratedEnqueueAttempted command gatewayResult)
          , Just drained
          , snapshot
          ) -> do
            command @?= expected
            queued <- gatewayQueuedOrFail gatewayResult
            qscProducer queued @?= producer
            qscCommand queued @?= expected
            case map sdiResult (sdrItems (sfidrDrain drained)) of
              [SessionOwnerStep (StepRejected (SiStaleVoice (VoiceKey "v0")))] ->
                pure ()
              other ->
                assertFailure
                  ("expected stale OSC control-write drain, got: "
                   <> show other)
            sfidrQueueDepth drained @?= 0
            sfisQueueDepth snapshot @?= 0
        Right (Nothing, _mDrain, _snapshot) ->
          assertFailure
            "timed out waiting for arbitrated OSC listener result"
        Right (_mResult, Nothing, _snapshot) ->
          assertFailure
            "timed out waiting for arbitrated OSC listener drain"
        Right other ->
          assertFailure
            ("expected arbitrated OSC listener enqueue, got: "
             <> show other)

  , testCase "arbitrated service listener reports policy rejection" $ do
      let expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1500.0
          producer = oscProducerId defaultOSCProducerOptions
          claimant = testProducer ProducerUI "ui"
          target =
            ControlArbitrationTarget
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
          serviceOpts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = producer
            , aiCommand   = expected
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          serviceOpts
          $ \service -> do
              received <- newEmptyMVar
              issues <- newEmptyMVar
              let hooks = OSCS.SessionOSCArbitratedListenerHooks
                    { OSCS.solahOnProducerResult = putMVar received
                    , OSCS.solahOnIssue          = putMVar issues
                    }
              OSCS.withArbitratedSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                service
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mResult <- timeout 1000000 (takeMVar received)
                    mIssue <- timeout 1000000 (takeMVar issues)
                    mDrain <- timeout 100000 (takeMVar drainedVar)
                    snapshot <- readSessionFanInService service
                    pure (mResult, mIssue, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( Just (OSCProducerArbitratedEnqueueAttempted command rejected)
          , Just reported
          , Nothing
          , snapshot
          ) -> do
            command @?= expected
            rejected @?= SagArbitrationRejected expectedIssue
            reported @?= OSCS.SoliArbitrationRejected expectedIssue
            sfisQueueDepth snapshot @?= 0
        Right (Nothing, _mIssue, _mDrain, _snapshot) ->
          assertFailure
            "timed out waiting for arbitrated OSC listener result"
        Right (_mResult, Nothing, _mDrain, _snapshot) ->
          assertFailure
            "timed out waiting for arbitrated OSC listener issue"
        Right (_mResult, Just _reported, Just extraDrain, _snapshot) ->
          assertFailure
            ("OSC listener policy rejection unexpectedly woke service drain: "
             <> show extraDrain)
        Right other ->
          assertFailure
            ("expected arbitrated OSC listener policy rejection, got: "
             <> show other)

  , testCase "arbitrated listener parse issue continues" $ do
      result <-
        withSessionFanInService
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              issues <- newIORef []
              validDone <- newEmptyMVar
              let hooks = OSCS.SessionOSCArbitratedListenerHooks
                    { OSCS.solahOnProducerResult =
                        \result -> case result of
                          OSCProducerArbitratedEnqueueAttempted {} ->
                            putMVar validDone ()
                          OSCProducerArbitratedDecodeRejected {} ->
                            pure ()
                    , OSCS.solahOnIssue =
                        \issue -> modifyIORef' issues (issue :)
                    }
              OSCS.withArbitratedSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                service
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback (OSCS.liBoundPort info)
                                    (OBS.pack [0x01, 0x02, 0x03, 0x04])
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mDone <- timeout 1000000 (takeMVar validDone)
                    issueList <- readIORef issues
                    pure (mDone, issueList)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (Just (), issueList) ->
          assertBool
            ("expected parse failure issue, got: " <> show issueList)
            (any isSessionParseFailure issueList)
        Right other ->
          assertFailure
            ("valid packet was not accepted after malformed one: "
             <> show other)

  , testCase "malformed packet surfaces parse issue; listener continues" $ do
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host -> do
              issues <- newIORef []
              validDone <- newEmptyMVar
              let hooks = OSCS.SessionOSCListenerHooks
                    { OSCS.solhOnProducerResult =
                        \result -> case result of
                          OSCProducerEnqueueAttempted {} ->
                            putMVar validDone ()
                          OSCProducerDecodeRejected {} ->
                            pure ()
                    , OSCS.solhOnIssue =
                        \issue -> modifyIORef' issues (issue :)
                    }
              OSCS.withSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                host
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback (OSCS.liBoundPort info)
                                    (OBS.pack [0x01, 0x02, 0x03, 0x04])
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mDone <- timeout 1000000 (takeMVar validDone)
                    issueList <- readIORef issues
                    pure (mDone, issueList)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (), issueList) ->
          assertBool
            ("expected parse failure issue, got: " <> show issueList)
            (any isSessionParseFailure issueList)
        Right other ->
          assertFailure ("valid packet was not accepted after malformed one: "
                         <> show other)

  , testCase "decode rejection reports issue and does not enqueue" $ do
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host -> do
              issues <- newEmptyMVar
              let hooks = OSCS.SessionOSCListenerHooks
                    { OSCS.solhOnProducerResult = \_ -> pure ()
                    , OSCS.solhOnIssue          = putMVar issues
                    }
              OSCS.withSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                host
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesSwapLpfFloat
                    mIssue <- timeout 1000000 (takeMVar issues)
                    snapshot <- readSessionFanInHost host
                    pure (mIssue, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just issue, snapshot) -> do
          issue
            @?= OSCS.SoliDecodeFailure
                  (OSC.DiReservedPathSegment (OBSC.pack "swap"))
          sfisQueueDepth snapshot @?= 0
        Right other ->
          assertFailure ("expected decode issue, got: " <> show other)

  , testCase "queue-full surfaces as listener issue" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
          expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1500.0
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          opts
          $ \host -> do
              _prefillResult <-
                enqueueSessionFanInCommand
                  (testProducer ProducerTest "prefill")
                  prefill
                  host
              issues <- newEmptyMVar
              let hooks = OSCS.SessionOSCListenerHooks
                    { OSCS.solhOnProducerResult = \_ -> pure ()
                    , OSCS.solhOnIssue          = putMVar issues
                    }
              OSCS.withSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                host
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mIssue <- timeout 1000000 (takeMVar issues)
                    snapshot <- readSessionFanInHost host
                    pure (mIssue, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just issue, snapshot) -> do
          issue @?= OSCS.SoliEnqueueRejected expected (SeiQueueFull 1)
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected queue-full listener issue, got: "
                         <> show other)
  ]
  where
    isSessionParseFailure (OSCS.SoliParseFailure _) = True
    isSessionParseFailure _                         = False

compileTemplateGraphOrFail :: [(String, SynthGraph)] -> IO TemplateGraph
compileTemplateGraphOrFail entries =
  case compileTemplateGraph entries of
    Left err ->
      assertFailure ("expected TemplateGraph, got: " <> err)
    Right tg ->
      pure tg

missingVoiceEvents :: Int -> [(SamplePos, PatternEvent)]
missingVoiceEvents n =
  missingVoiceEventsAt [0 .. n - 1]

missingVoiceEventsAt :: [Int] -> [(SamplePos, PatternEvent)]
missingVoiceEventsAt positions =
  [ ( SamplePos pos
    , PEVoiceOn (TemplateName "missing") (VoiceKey ("v" <> show pos)) []
    )
  | pos <- positions
  ]
