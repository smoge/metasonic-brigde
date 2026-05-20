-- | §6.E slice 2: KStaticPlugin Identity dispatch + counters.
--
-- Pins Haskell-side metadata (kindSpec / portInfo / kindLatency /
-- plugin catalog), unknown-plugin validation, and bit-exact rendering
-- of the Identity plugin against a hand-rolled @add@ graph. The C-side
-- 'c_rt_graph_test_plugin_call_count' counter is used as
-- counter-confirmed validation that the dispatcher actually ran the
-- kernel — not just that the output happened to match silence.
module MetaSonic.Spec.Feature.StaticPlugin
  ( staticPluginSkeletonTests
  ) where

import           Control.Monad             (forM_)
import           Data.List                 (isInfixOf)
import           Data.Maybe                (listToMaybe)
import           Foreign.C.Types           (CFloat (..))
import           Foreign.Marshal.Alloc     (allocaBytes)
import           Foreign.Marshal.Array     (peekArray)
import           Foreign.Ptr               (Ptr, castPtr)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile  (rgNodes)
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR       (giNodes, irEffects, irKind,
                                            lowerGraph)
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates (compileTemplateGraph, tgTemplates,
                                             tplGraph)
import           MetaSonic.Types

staticPluginSkeletonTests :: TestTree
staticPluginSkeletonTests =
  testGroup "Phase 6.E slice 2: Identity dispatch"
  [ testCase "inferEff produces Pure for identityPlugin" $ do
      let g = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sinOsc 220.0 0.0
            y <- staticPlugin identityPlugin a b
            out 0 y
          ir = case lowerGraph g of
                 Right ir' -> ir'
                 Left err  -> error err
          pluginEffs =
            [ eff
            | n   <- giNodes ir
            , eff <- irEffects n
            , irKind n == KStaticPlugin
            ]
      pluginEffs @?= [Pure]

  , testCase "Haskell plugin metadata catalog exposes Identity row" $ do
      listToMaybe staticPluginCatalog @?=
        Just StaticPluginInfo
            { spiRef            = identityPlugin
            , spiPluginId       = 0
            , spiAudioInputs    = 2
            , spiAudioOutputs   = 1
            , spiLatencySamples = 0
            , spiEffects        = [Pure]
            , spiLabel          = "identity"
            }
      staticPluginInfo identityPlugin
        @?= listToMaybe staticPluginCatalog
      staticPluginId identityPlugin @?= Just 0
      staticPluginInfo (PluginRef "missing") @?= Nothing
      staticPluginId (PluginRef "missing") @?= Nothing

  , testCase "kindSpec / portInfo / kindLatency agree on fixed Identity shape" $ do
      ksTag          (kindSpec KStaticPlugin) @?= 23
      ksRate         (kindSpec KStaticPlugin) @?= SampleRate
      ksAudioArity   (kindSpec KStaticPlugin) @?= 2
      ksControlArity (kindSpec KStaticPlugin) @?= 1
      ksLabel        (kindSpec KStaticPlugin) @?= "staticPlugin"
      portInfo KStaticPlugin (PortIndex 0)
        @?= Just (PortInfo PortSampleAccurate "in0")
      portInfo KStaticPlugin (PortIndex 1)
        @?= Just (PortInfo PortSampleAccurate "in1")
      portInfo KStaticPlugin (PortIndex 2) @?= Nothing
      kindLatency KStaticPlugin @?= Nothing

  , testCase "runtime plugin registry exposes Identity metadata" $ do
      entries <- pluginRegistryEntries
      let identityRows =
            filter ((== "identity") . pluginEntryName) entries
      case identityRows of
        [row] -> do
          case staticPluginInfo identityPlugin of
            Just meta -> do
              pluginEntryId row @?= spiPluginId meta
              pluginEntryAudioInputs row @?= spiAudioInputs meta
              pluginEntryAudioOutputs row @?= spiAudioOutputs meta
              pluginEntryLatencySamples row @?= spiLatencySamples meta
              pluginEntryStateBytes row @?= 0
            Nothing ->
              assertFailure "missing Haskell identity plugin metadata row"
        _ ->
          assertFailure $
            "expected exactly one identity plugin row, got: "
            <> show identityRows

  , testCase "ugenView lowers identityPlugin to frozen plugin_id control" $ do
      let view = ugenView
            (StaticPlugin identityPlugin (Param 0.25) (Param 0.75))
      uvKind view @?= KStaticPlugin
      uvInputs view @?= [Param 0.25, Param 0.75]
      uvControls view @?= [0.0]

  , testCase "unregistered plugin name fails validation before lowering" $ do
      let graph = runSynth $ do
            a <- add 1.0 2.0
            b <- add 3.0 4.0
            y <- staticPlugin (PluginRef "missing") a b
            out 0 y
      case lowerGraph graph of
        Left err ->
          assertBool
            ("expected unknown plugin diagnostic, got: " <> err)
            ("Unknown static plugin" `isInfixOf` err)
        Right _ ->
          assertFailure "expected lowerGraph to reject an unknown static plugin"

  -- Slice 2 dispatch tests below. Each one renders identityPlugin
  -- against two sinOsc sources and uses the plugin call counters as
  -- counter-confirmed validation of "the kernel actually ran" — a
  -- bit-equivalence check against a hand-rolled `add` graph in a
  -- separate render proves the output is real plugin work, not the
  -- old silence skeleton.

  , testCase "identity dispatch produces non-silent output and ticks plugin_call_count" $ do
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
        c_rt_graph_process rt (fromIntegral nframes)
        calls   <- c_rt_graph_test_plugin_call_count rt
        invalid <- c_rt_graph_test_invalid_plugin_call_count rt
        calls   @?= 1
        invalid @?= 0
        allocaBytes (nframes * 4) $ \bp -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bp)
          rendered <- peekArray nframes (bp :: Ptr CFloat)
          let peak = maximum (map (abs . (\(CFloat x) -> x)) rendered)
          assertBool
            ("expected non-silent identity output, got peak=" <> show peak)
            (peak > 0.0)

  , testCase "plugin_call_count ticks once per block over N blocks" $ do
      let nframes = 64
          nblocks = 5 :: Int
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
        forM_ [1 .. nblocks] $ \_ ->
          c_rt_graph_process rt (fromIntegral nframes)
        calls   <- c_rt_graph_test_plugin_call_count rt
        invalid <- c_rt_graph_test_invalid_plugin_call_count rt
        calls   @?= fromIntegral nblocks
        invalid @?= 0

  , testCase "identity output is bit-exact to a hand-rolled add graph" $ do
      -- Two graphs with identical sources; one feeds identityPlugin,
      -- the other a normal Add. Rendering them in separate RTGraphs
      -- starting from the same zero-initialized phase state must
      -- produce bit-identical bus 0 samples — Identity's body is
      -- literally `a[i] + b[i]`, so any divergence here means
      -- dispatch wired the wrong input/output spans.
      let nframes = 64
          pluginGraph = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sinOsc 220.0 0.0
            y <- staticPlugin identityPlugin a b
            out 0 y
          addGraph = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sinOsc 220.0 0.0
            y <- add a b
            out 0 y
          render g = do
            tg <- case compileTemplateGraph [("g", g)] of
              Right t  -> pure t
              Left err -> assertFailure err >> error "unreachable"
            let totalNodes =
                  sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
            withRTGraph totalNodes nframes $ \rt -> do
              loadTemplateGraph rt tg
              c_rt_graph_process rt (fromIntegral nframes)
              allocaBytes (nframes * 4) $ \bp -> do
                _ <- c_rt_graph_read_bus rt 0
                       (fromIntegral nframes) (castPtr bp)
                peekArray nframes (bp :: Ptr CFloat)
      viaPlugin <- render pluginGraph
      viaAdd    <- render addGraph
      viaPlugin @?= viaAdd
  ]
