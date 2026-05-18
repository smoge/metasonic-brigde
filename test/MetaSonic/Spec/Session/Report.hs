-- | Session Prep A: lifecycle reports tests.
--
-- Pins the read-only reporting surface a future session owner can
-- render or log outside the audio thread. The 'MetaSonic.Session.Report'
-- helpers read existing counters and metadata only — no mutation,
-- no install, no FFI side effects beyond the underlying counter
-- reads. The cases cover:
--
--   * Fresh-RTGraph initial state (zero counters + identity plugin
--     registered in the static plugin registry).
--   * Plugin call counter advances by one per processed block.
--   * Buffer read counter records every invalid read attempt.
--   * Buffer write counter records every recordBufMono write frame.
--
-- Extracted from "MetaSonic.Spec.Session" as the third slice of
-- the Session megafile split. Like the prior two Prep A slices,
-- the cases depend only on public 'MetaSonic.Session.Report' +
-- 'MetaSonic.Bridge.*' surfaces — no shared helpers from
-- "MetaSonic.Spec.SessionShared" needed at this slice.
module MetaSonic.Spec.Session.Report (sessionReportTests) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Buffer       (allocBuffer, loadBuffer)
import           MetaSonic.Bridge.Compile      (compileRuntimeGraph, rgNodes)
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR           (lowerGraph)
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates    (compileTemplateGraph,
                                                tgTemplates, tplGraph)
import           MetaSonic.Session.Report
import           MetaSonic.Types               (Buffer (..))


sessionReportTests :: TestTree
sessionReportTests = testGroup "Session Prep A: lifecycle reports"
  [ testCase "fresh report starts with zero counters and static plugins" $
      withRTGraph 4 64 $ \rt -> do
        report <- readSessionLifecycleReport rt
        slrBuffers report @?= BufferLifecycleReport 0 0 0 0
        plrCallCount (slrPlugins report) @?= 0
        plrInvalidCallCount (slrPlugins report) @?= 0
        assertBool
          ("expected identity plugin in registry: "
           <> show (plrRegistered (slrPlugins report)))
          (any ((== "identity") . pluginEntryName)
               (plrRegistered (slrPlugins report)))

  , testCase "plugin report observes identity dispatch counters" $ do
      let nframes = 64
          graph = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sinOsc 220.0 0.0
            y <- staticPlugin identityPlugin a b
            out 0 y
      tg <- case compileTemplateGraph [("plugin", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        before <- readPluginLifecycleReport rt
        plrCallCount before @?= 0
        plrInvalidCallCount before @?= 0

        c_rt_graph_process rt (fromIntegral nframes)
        pluginAfter <- readPluginLifecycleReport rt
        plrCallCount pluginAfter @?= 1
        plrInvalidCallCount pluginAfter @?= 0
        assertBool
          "plugin registry should remain visible after processing"
          (any ((== "identity") . pluginEntryName)
               (plrRegistered pluginAfter))

  , testCase "buffer report observes invalid read counters" $ do
      let nframes = 32
          graph = runSynth $ do
            s <- playBufMono (Buffer 99) (Param 1.0) (Param 0) (Param 0)
            out 0 s
      rtGraph <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      withRTGraph (length (rgNodes rtGraph)) nframes $ \rt -> do
        loadRuntimeGraph rt rtGraph
        c_rt_graph_process rt (fromIntegral nframes)
        report <- readBufferLifecycleReport rt
        blrReadCount report @?= 0
        blrInvalidReadCount report @?= fromIntegral nframes
        blrWriteCount report @?= 0
        blrInvalidWriteCount report @?= 0

  , testCase "buffer report observes recordBufMono write counters" $ do
      let nframes = 64
          graph = runSynth $ do
            mon <- recordBufMono (Buffer 0) (Param 0.25) (Param 0.0)
            out 0 mon
      tg <- case compileTemplateGraph [("record", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        buf <- allocBuffer rt nframes
        bufferId buf @?= 0
        loadBuffer rt buf (replicate nframes 0.0)
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        report <- readBufferLifecycleReport rt
        blrReadCount report @?= 0
        blrInvalidReadCount report @?= 0
        blrWriteCount report @?= fromIntegral nframes
        blrInvalidWriteCount report @?= 0
  ]
