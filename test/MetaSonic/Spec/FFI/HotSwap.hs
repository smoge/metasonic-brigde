-- | Hot-swap FFI helper tests: publish / install / collect protocol
-- for the producer-side wrappers in "MetaSonic.Bridge.FFI".
--
-- Each case pins one corner of the prepare → publish → install →
-- collect lifecycle the runtime exposes through 'hotSwapRuntimeGraph',
-- 'hotSwapRuntimeGraphFused', 'hotSwapTemplateGraph[Fused]', and the
-- synchronous 'hotSwapRuntimeGraphAndWait'. The shared invariants:
--
--   * a successful publish advances 'readSwapGeneration' only after a
--     subsequent process block (installation happens at the block
--     boundary, not at publish time);
--   * 'collectRetiredSwapStats' reaps exactly one set of stats per
--     installed swap, then returns 'Nothing';
--   * a rejected publish (overlong identity, reordered template names,
--     retired slot still occupied) must dispose the prepared swap so
--     a follow-up attempt is not contaminated;
--   * template-name identity gates fire before the loader clears the
--     live graph — a rejected load must leave the previous render
--     intact.
--
-- Extracted from "MetaSonic.Spec.FFI" as the seventh slice of the
-- megafile split. Shared helpers ('processAndReadBuses') come from
-- the parent module; the cases otherwise depend only on public
-- 'MetaSonic.Bridge.FFI' / 'MetaSonic.Bridge.Source' entry points.
module MetaSonic.Spec.FFI.HotSwap (hotSwapTests) where

import           Control.Concurrent       (forkIO, newEmptyMVar, putMVar,
                                           takeMVar, threadDelay)
import           Control.Exception        (try)
import           Data.List                (isInfixOf)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile (RuntimeInput (RFused),
                                           compileRuntimeGraph,
                                           compileRuntimeGraphFused,
                                           rgNodes, rnElided, rnInputs)
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR      (lowerGraph)
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates (compileTemplateGraph,
                                             compileTemplateGraphFused,
                                             tgTemplates, tplGraph)

import           MetaSonic.Spec.Core      (runtimeGraphBuilderCapacity,
                                           templateGraphBuilderCapacity)
import           MetaSonic.Spec.FFI       (processAndReadBuses)


hotSwapTests :: TestTree
hotSwapTests = testGroup "End-to-end FFI: hot-swap"
  [ testCase "hotSwapRuntimeGraph publishes, installs, and collects migration stats" $ do
      let nframes = 256
          graph = runSynth $ do
            o <- tagged "voice-osc" (sinOsc 220.0 0.0)
            out 0 o
          compileOrFail g =
            case lowerGraph g >>= compileRuntimeGraph of
              Right r  -> pure r
              Left err -> assertFailure err >> error "unreachable"

      oldRt <- compileOrFail graph
      newRt <- compileOrFail graph
      let capacity = runtimeGraphBuilderCapacity oldRt + 4

      withRTGraph capacity nframes $ \handle -> do
        loadRuntimeGraph handle oldRt
        c_rt_graph_process handle (fromIntegral nframes)

        before <- readSwapGeneration handle
        before @?= 0

        published <- hotSwapRuntimeGraph handle capacity nframes newRt
        published @?= True

        -- The helper publishes only; installation still waits for a
        -- block boundary, so there is nothing to collect yet.
        early <- collectRetiredSwapStats handle
        early @?= Nothing

        c_rt_graph_process handle (fromIntegral nframes)
        after <- readSwapGeneration handle
        after @?= 1

        stats <- collectRetiredSwapStats handle
        stats @?= Just SwapMigrationStats
          { smsCommittedCount = 1
          , smsSkippedCount = 1
          , smsInstanceCopyCount = 1
          , smsStateCopyCount = 1
          , smsLifecycleCopyCount = 1
          }

        none <- collectRetiredSwapStats handle
        none @?= Nothing

  , testCase "hotSwapRuntimeGraphFused publishes a fused next world" $ do
      let nframes = 256
          graph = runSynth $ do
            e <- env (Param 1.0) 0.0005 0.002 1.0 0.002
            a <- gain e (Param 0.5)
            out 0 a

      rt <- case lowerGraph graph >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      assertBool "fused swap fixture produced no RFused inputs"
        (not (null [() | n <- rgNodes rt, RFused _ <- rnInputs n]))
      assertBool "fused swap fixture elided no nodes"
        (any rnElided (rgNodes rt))

      let capacity = runtimeGraphBuilderCapacity rt + 4
      withRTGraph capacity nframes $ \handle -> do
        loadRuntimeGraphFused handle rt
        c_rt_graph_process handle (fromIntegral nframes)

        published <- hotSwapRuntimeGraphFused handle capacity nframes rt
        published @?= True
        c_rt_graph_process handle (fromIntegral nframes)

        stats <- collectRetiredSwapStats handle
        assertBool "expected fused retired swap stats"
          (case stats of
             Just s  -> smsLifecycleCopyCount s == 1
             Nothing -> False)

  , testCase "hotSwapTemplateGraph publishes a multi-template next world" $ do
      let nframes = 256
          voiceA = runSynth $ do
            o <- sinOsc 220.0 0.0
            out 0 o
          voiceB = runSynth $ do
            o <- sinOsc 660.0 0.0
            out 1 o

      tg <- case compileTemplateGraph [("a", voiceA), ("b", voiceB)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let capacity = templateGraphBuilderCapacity tg + 4
      withRTGraph capacity nframes $ \handle -> do
        loadTemplateGraph handle tg
        c_rt_graph_process handle (fromIntegral nframes)

        published <- hotSwapTemplateGraph handle capacity nframes tg
        published @?= True
        c_rt_graph_process handle (fromIntegral nframes)

        stats <- collectRetiredSwapStats handle
        assertBool "expected template retired swap stats"
          (case stats of
             Just s  -> smsLifecycleCopyCount s == 2
             Nothing -> False)

  , testCase "hotSwapTemplateGraph: same-name same-order swap publishes" $ do
      -- Phase 5.4.B: identical template name list across old and new
      -- worlds must round-trip publish + install. Counter-confirms
      -- that the identity precondition does not block legitimate
      -- swaps; the lifecycle copy count proves the slots actually
      -- migrated rather than getting silently rejected upstream.
      let nframes = 256
          voiceA = runSynth $ do
            o <- sinOsc 220.0 0.0
            out 0 o
          voiceB = runSynth $ do
            o <- sinOsc 660.0 0.0
            out 1 o

      oldTg <- case compileTemplateGraph [("a", voiceA), ("b", voiceB)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      newTg <- case compileTemplateGraph [("a", voiceA), ("b", voiceB)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let capacity = templateGraphBuilderCapacity oldTg + 4
      withRTGraph capacity nframes $ \handle -> do
        loadTemplateGraph handle oldTg
        c_rt_graph_process handle (fromIntegral nframes)

        published <- hotSwapTemplateGraph handle capacity nframes newTg
        published @?= True
        c_rt_graph_process handle (fromIntegral nframes)
        stats <- collectRetiredSwapStats handle
        assertBool "expected retired swap with two lifecycle copies"
          (case stats of
             Just s  -> smsLifecycleCopyCount s == 2
             Nothing -> False)

  , testCase "hotSwapTemplateGraph: reordered names reject before install" $ do
      -- Phase 5.4.B: swapping in a TemplateGraph whose names land at
      -- different template_ids than the live old world must fail
      -- before any block install. The helper returns False because
      -- prepare_swap_from_graph rejects the precondition; no swap
      -- ownership leaks through, so a follow-up same-shape publish
      -- still works.
      let nframes = 256
          voiceA = runSynth $ do
            o <- sinOsc 220.0 0.0
            out 0 o
          voiceB = runSynth $ do
            o <- sinOsc 660.0 0.0
            out 1 o

      oldTg <- case compileTemplateGraph [("a", voiceA), ("b", voiceB)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      reorderedTg <- case compileTemplateGraph [("b", voiceB), ("a", voiceA)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      sameTg <- case compileTemplateGraph [("a", voiceA), ("b", voiceB)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let capacity = templateGraphBuilderCapacity oldTg + 4
      withRTGraph capacity nframes $ \handle -> do
        loadTemplateGraph handle oldTg
        c_rt_graph_process handle (fromIntegral nframes)

        beforeGen <- readSwapGeneration handle

        rejected <- hotSwapTemplateGraph handle capacity nframes reorderedTg
        rejected @?= False

        -- A rejected publish must not advance the install counter.
        afterReject <- readSwapGeneration handle
        afterReject @?= beforeGen

        -- Nothing should be sitting in the retired slot.
        leftover <- collectRetiredSwapStats handle
        leftover @?= Nothing

        -- Same-shape replacement still works after a reject.
        ok <- hotSwapTemplateGraph handle capacity nframes sameTg
        ok @?= True
        c_rt_graph_process handle (fromIntegral nframes)
        stats <- collectRetiredSwapStats handle
        assertBool "expected stats from the recovery publish"
          (case stats of
             Just _  -> True
             Nothing -> False)

  , testCase "loadTemplateGraph: invalid template identity fails before clear" $ do
      -- Phase 5.4.B: template-name identity validation is part of the
      -- pre-clear loader gate. An invalid next TemplateGraph must not
      -- erase the currently loaded graph.
      let nframes = 256
          stableVoice = runSynth $ do
            o <- sinOsc 220.0 0.0
            out 0 o
          tooLongName = "abcdefghijklmnopq" -- 17 ASCII bytes

      stableTg <- case compileTemplateGraph [("stable", stableVoice)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      invalidTg <- case compileTemplateGraph [(tooLongName, stableVoice)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let capacity = templateGraphBuilderCapacity stableTg + 4
      withRTGraph capacity nframes $ \handle -> do
        loadTemplateGraph handle stableTg
        before <- processAndReadBuses handle nframes [0]

        let attempt :: IO (Either IOError ())
            attempt = try $ loadTemplateGraph handle invalidTg
        result <- attempt
        case result of
          Right () ->
            assertFailure "expected loadTemplateGraph to reject overlong identity"
          Left e ->
            assertBool
              ("expected overlong identity diagnostic in: " <> show e)
              ("rt_graph_template_set_identity rejects > 16" `isInfixOf` show e)

        after <- processAndReadBuses handle nframes [0]
        let peak xs = maximum (map abs xs)
            beforePeak = peak (snd (head before))
            afterPeak  = peak (snd (head after))
        assertBool ("expected pre-failure graph to render, peak=" <> show beforePeak)
          (beforePeak > 0.05)
        assertBool ("expected graph to survive failed load, peak=" <> show afterPeak)
          (afterPeak > 0.05)

  , testCase "hotSwapTemplateGraphFused publishes a fused template world" $ do
      let nframes = 256
          graph = runSynth $ do
            e <- env (Param 1.0) 0.0005 0.002 1.0 0.002
            a <- gain e (Param 0.5)
            out 0 a

      tg <- case compileTemplateGraphFused [("solo", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      tgRg <- case tgTemplates tg of
        [tpl] -> pure (tplGraph tpl)
        _ -> assertFailure "expected one fused template" >> error "unreachable"
      assertBool "fused template swap fixture carried no RFused inputs"
        (not (null [() | n <- rgNodes tgRg, RFused _ <- rnInputs n]))
      assertBool "fused template swap fixture elided no nodes"
        (any rnElided (rgNodes tgRg))

      let capacity = templateGraphBuilderCapacity tg + 4
      withRTGraph capacity nframes $ \handle -> do
        loadTemplateGraphFused handle tg
        c_rt_graph_process handle (fromIntegral nframes)

        published <- hotSwapTemplateGraphFused handle capacity nframes tg
        published @?= True
        c_rt_graph_process handle (fromIntegral nframes)

        stats <- collectRetiredSwapStats handle
        assertBool "expected fused template retired swap stats"
          (case stats of
             Just s  -> smsLifecycleCopyCount s == 1
             Nothing -> False)

  , testCase "hotSwapTemplateGraphFused: reordered names reject before install" $ do
      -- Same precondition as the unfused template hot-swap helper, but
      -- pinned on the fused loader path so identity wiring cannot drift
      -- independently.
      let nframes = 256
          voiceA = runSynth $ do
            e <- env (Param 1.0) 0.0005 0.002 1.0 0.002
            a <- gain e (Param 0.5)
            out 0 a
          voiceB = runSynth $ do
            e <- env (Param 1.0) 0.0005 0.002 1.0 0.002
            a <- gain e (Param 0.25)
            out 1 a

      oldTg <- case compileTemplateGraphFused [("a", voiceA), ("b", voiceB)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      reorderedTg <- case compileTemplateGraphFused [("b", voiceB), ("a", voiceA)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let hasRFused tg =
            not (null [ () | tpl <- tgTemplates tg
                           , node <- rgNodes (tplGraph tpl)
                           , RFused _ <- rnInputs node ])
      assertBool "old fused fixture carried no RFused inputs" (hasRFused oldTg)
      assertBool "reordered fused fixture carried no RFused inputs" (hasRFused reorderedTg)

      let capacity = templateGraphBuilderCapacity oldTg + 4
      withRTGraph capacity nframes $ \handle -> do
        loadTemplateGraphFused handle oldTg
        c_rt_graph_process handle (fromIntegral nframes)
        beforeGen <- readSwapGeneration handle

        rejected <- hotSwapTemplateGraphFused handle capacity nframes reorderedTg
        rejected @?= False

        afterReject <- readSwapGeneration handle
        afterReject @?= beforeGen
        leftover <- collectRetiredSwapStats handle
        leftover @?= Nothing

  , testCase "hotSwapRuntimeGraph failed publish disposes the prepared swap" $ do
      let nframes = 256
          graph = runSynth $ do
            o <- tagged "voice-osc" (sinOsc 330.0 0.0)
            out 0 o
          compileOrFail g =
            case lowerGraph g >>= compileRuntimeGraph of
              Right r  -> pure r
              Left err -> assertFailure err >> error "unreachable"

      rt <- compileOrFail graph
      let capacity = runtimeGraphBuilderCapacity rt + 4

      withRTGraph capacity nframes $ \handle -> do
        loadRuntimeGraph handle rt

        first <- hotSwapRuntimeGraph handle capacity nframes rt
        first @?= True
        c_rt_graph_process handle (fromIntegral nframes)

        -- Retired slot is still occupied, so publish must fail. The
        -- helper must cancel the rejected prepared swap; otherwise the
        -- next publish after collection would be contaminated by the
        -- failed attempt.
        blocked <- hotSwapRuntimeGraph handle capacity nframes rt
        blocked @?= False

        firstStats <- collectRetiredSwapStats handle
        assertBool "expected first retired swap stats"
          (case firstStats of
             Just _  -> True
             Nothing -> False)

        second <- hotSwapRuntimeGraph handle capacity nframes rt
        second @?= True
        c_rt_graph_process handle (fromIntegral nframes)
        secondStats <- collectRetiredSwapStats handle
        assertBool "expected second retired swap stats"
          (case secondStats of
             Just _  -> True
             Nothing -> False)

  , testCase "hotSwapRuntimeGraphAndWait waits for install and reaps stats" $ do
      let nframes = 256
          graph = runSynth $ do
            o <- tagged "voice-osc" (sinOsc 440.0 0.0)
            out 0 o
          compileOrFail g =
            case lowerGraph g >>= compileRuntimeGraph of
              Right r  -> pure r
              Left err -> assertFailure err >> error "unreachable"

      rt <- compileOrFail graph
      let capacity = runtimeGraphBuilderCapacity rt + 4

      withRTGraph capacity nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)

        done <- newEmptyMVar
        _ <- forkIO $ do
          -- This fork stands in for the audio callback while the main
          -- thread stays on the producer side. It only runs process
          -- blocks and reads the atomic generation counter.
          let drive 0 = putMVar done False
              drive remaining = do
                threadDelay 1000
                c_rt_graph_process handle (fromIntegral nframes)
                gen <- readSwapGeneration handle
                if gen > 0
                  then putMVar done True
                  else drive (remaining - 1)
          drive (64 :: Int)

        result <- hotSwapRuntimeGraphAndWait handle capacity nframes 1000 rt
        driverSawInstall <- takeMVar done
        assertBool "audio driver did not observe the installed swap"
          driverSawInstall
        result @?= HotSwapInstalled SwapMigrationStats
          { smsCommittedCount = 1
          , smsSkippedCount = 1
          , smsInstanceCopyCount = 1
          , smsStateCopyCount = 1
          , smsLifecycleCopyCount = 1
          }

        none <- collectRetiredSwapStats handle
        none @?= Nothing

  , testCase "hotSwapRuntimeGraphAndWait reports timeout without reaping early" $ do
      let nframes = 256
          graph = runSynth $ do
            o <- tagged "voice-osc" (sinOsc 550.0 0.0)
            out 0 o
          compileOrFail g =
            case lowerGraph g >>= compileRuntimeGraph of
              Right r  -> pure r
              Left err -> assertFailure err >> error "unreachable"

      rt <- compileOrFail graph
      let capacity = runtimeGraphBuilderCapacity rt + 4

      withRTGraph capacity nframes $ \handle -> do
        loadRuntimeGraph handle rt
        result <- hotSwapRuntimeGraphAndWait handle capacity nframes 0 rt
        result @?= HotSwapInstallTimedOut

        -- The timed-out publish is still owned by the runtime. Once
        -- a block installs it, normal collection must still work.
        c_rt_graph_process handle (fromIntegral nframes)
        stats <- collectRetiredSwapStats handle
        assertBool "expected delayed retired swap stats"
          (case stats of
             Just _  -> True
             Nothing -> False)
  ]
