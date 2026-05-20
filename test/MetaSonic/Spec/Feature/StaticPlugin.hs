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
  , oneTapDelayPluginTests
  ) where

import           Control.Monad             (forM_)
import           Data.List                 (isInfixOf)
import           Data.Maybe                (listToMaybe)
import           Foreign.C.Types           (CFloat (..), CInt)
import           Foreign.Marshal.Alloc     (allocaBytes)
import           Foreign.Marshal.Array     (peekArray)
import           Foreign.Ptr               (Ptr, castPtr)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Buffer          (allocBuffer, loadBuffer)
import           MetaSonic.Bridge.Compile         (rgNodes, RuntimeNode (..))
import           MetaSonic.Bridge.Compile.Latency (DeclaredNodeLatency (..),
                                                   declaredLatencyFootprint,
                                                   nodeDeclaredLatency)
import           MetaSonic.Bridge.Compile.Types   (NodeOutputUse (..))
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR              (giNodes, irEffects, irKind,
                                                   lowerGraph)
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates       (TemplateGraph,
                                                   compileTemplateGraph,
                                                   tgTemplates, tplGraph)
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

-- | §6.E v2 second-static-plugin contract
-- (notes/2026-05-19-d-phase-6e4-second-static-plugin-contract.md §5).
-- Pairs the second catalog row + plugin-aware accessor with
-- counter-confirmed audio behavior on `oneTapDelayPlugin`.
oneTapDelayPluginTests :: TestTree
oneTapDelayPluginTests = testGroup "Phase 6.E v2: one-tap-delay plugin"
  [ -- §5 #1 — Haskell catalog row, lookup, and id resolution.
    testCase "Haskell plugin metadata catalog exposes one-tap-delay row" $ do
      let expected = StaticPluginInfo
            { spiRef            = oneTapDelayPlugin
            , spiPluginId       = 1
            , spiAudioInputs    = 2
            , spiAudioOutputs   = 1
            , spiLatencySamples = 1
            , spiEffects        = [Pure]
            , spiLabel          = "one-tap-delay"
            }
      staticPluginInfo oneTapDelayPlugin @?= Just expected
      staticPluginId oneTapDelayPlugin    @?= Just 1
      staticPluginInfoById 1              @?= Just expected
      staticPluginInfoById 0              @?= staticPluginInfo identityPlugin

    -- §5 #2 — inferEff for one-tap-delay is [Pure].
  , testCase "inferEff produces Pure for oneTapDelayPlugin" $ do
      let g = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sinOsc 220.0 0.0
            y <- staticPlugin oneTapDelayPlugin a b
            out 0 y
          ir = case lowerGraph g of
                 Right ir' -> ir'
                 Left err  -> error err
          pluginEffs =
            [ eff | n <- giNodes ir, irKind n == KStaticPlugin, eff <- irEffects n ]
      pluginEffs @?= [Pure]

    -- §5 #3 — Runtime registry agreement.
  , testCase "runtime plugin registry agrees on one-tap-delay metadata" $ do
      entries <- pluginRegistryEntries
      let rows = filter ((== "one-tap-delay") . pluginEntryName) entries
      case rows of
        [row] -> case staticPluginInfo oneTapDelayPlugin of
          Just meta -> do
            pluginEntryId             row @?= spiPluginId       meta
            pluginEntryAudioInputs    row @?= spiAudioInputs    meta
            pluginEntryAudioOutputs   row @?= spiAudioOutputs   meta
            pluginEntryLatencySamples row @?= spiLatencySamples meta
            assertBool "expected non-zero state bytes" (pluginEntryStateBytes row > 0)
          Nothing -> assertFailure "missing Haskell one-tap-delay row"
        _ -> assertFailure $
          "expected exactly one one-tap-delay registry row, got: " <> show rows

    -- §5 #4 — nodeDeclaredLatency through the catalog.
  , testCase "nodeDeclaredLatency resolves one-tap-delay to Just 1" $ do
      let oneTapGraph = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sinOsc 220.0 0.0
            y <- staticPlugin oneTapDelayPlugin a b
            out 0 y
          identityGraph = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sinOsc 220.0 0.0
            y <- staticPlugin identityPlugin a b
            out 0 y
          firstPluginNode tg =
            head [ n
                 | t <- tgTemplates tg
                 , n <- rgNodes (tplGraph t)
                 , rnKind n == KStaticPlugin
                 ]
      tgOneTap   <- either assertFailure' pure (compileTemplateGraph [("g", oneTapGraph)])
      tgIdentity <- either assertFailure' pure (compileTemplateGraph [("g", identityGraph)])
      nodeDeclaredLatency (firstPluginNode tgOneTap)   @?= Just 1
      nodeDeclaredLatency (firstPluginNode tgIdentity) @?= Nothing

    -- §5 #4a — finitePluginId edge cases + nodeDeclaredLatency on
    --          synthetic RuntimeNode values the compiler would
    --          never legitimately produce.
  , testCase "finitePluginId rejects NaN / Inf / negative / non-integral / out-of-range" $ do
      finitePluginId 0                     @?= Just 0
      finitePluginId 1                     @?= Just 1
      finitePluginId (0 / 0)               @?= Nothing  -- NaN
      finitePluginId (1 / 0)               @?= Nothing  -- +Inf
      finitePluginId (- (1 / 0))           @?= Nothing  -- -Inf
      finitePluginId (-1)                  @?= Nothing
      finitePluginId 0.5                   @?= Nothing
      finitePluginId 1.5                   @?= Nothing
      finitePluginId 1e100                 @?= Nothing  -- overflows Int via round
      finitePluginId (2 ** 53)             @?= Nothing  -- exclusive upper bound
      finitePluginId (2 ** 54)             @?= Nothing  -- clearly above the bound
      let boundary = round maxExactPluginId - 1 :: Int
      finitePluginId (fromIntegral boundary) @?= Just boundary

  , testCase "nodeDeclaredLatency rejects malformed plugin_id values" $ do
      let mk pid = (mkPluginNode [pid]) { rnKind = KStaticPlugin }
      nodeDeclaredLatency ((mkPluginNode []) { rnKind = KStaticPlugin })
                                            @?= Nothing  -- empty controls
      nodeDeclaredLatency (mk (0 / 0))     @?= Nothing  -- NaN
      nodeDeclaredLatency (mk 1e100)       @?= Nothing  -- out-of-range
      nodeDeclaredLatency (mk (-1))        @?= Nothing  -- negative
      nodeDeclaredLatency (mk 999)         @?= Nothing  -- no catalog row

    -- §5 #5 — declaredLatencyFootprint includes the one-tap row.
  , testCase "declaredLatencyFootprint includes the one-tap-delay row" $ do
      let oneTapGraph = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sinOsc 220.0 0.0
            y <- staticPlugin oneTapDelayPlugin a b
            out 0 y
          identityGraph = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sinOsc 220.0 0.0
            y <- staticPlugin identityPlugin a b
            out 0 y
      tgOneTap   <- either assertFailure' pure (compileTemplateGraph [("g", oneTapGraph)])
      tgIdentity <- either assertFailure' pure (compileTemplateGraph [("g", identityGraph)])
      let footprint tg =
            concatMap (declaredLatencyFootprint . tplGraph) (tgTemplates tg)
          pluginRows = filter ((== KStaticPlugin) . dnlKind) (footprint tgOneTap)
      pluginRows @?= [head pluginRows]  -- exactly one one-tap-delay row
      dnlLatency (head pluginRows) @?= 1
      filter ((== KStaticPlugin) . dnlKind) (footprint tgIdentity) @?= []

    -- §5 #6 — plugin_call_count ticks once per block over N blocks.
  , testCase "plugin_call_count ticks once per block for one-tap-delay" $ do
      let nframes = 16
          nblocks = 5 :: Int
          graph = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sinOsc 220.0 0.0
            y <- staticPlugin oneTapDelayPlugin a b
            out 0 y
      tg <- either assertFailure' pure (compileTemplateGraph [("g", graph)])
      withRTGraph (totalNodes tg) nframes $ \rt -> do
        loadTemplateGraph rt tg
        forM_ [1 .. nblocks] $ \_ ->
          c_rt_graph_process rt (fromIntegral nframes)
        calls   <- c_rt_graph_test_plugin_call_count rt
        invalid <- c_rt_graph_test_invalid_plugin_call_count rt
        calls   @?= fromIntegral nblocks
        invalid @?= 0

    -- §5 #7 — output delay is exactly 1 sample across a single block.
  , testCase "one-tap-delay emits the impulse one sample late" $ do
      let nframes = 16
          impulseAt = 3 :: Int
          buf       = Buffer 0
          graph = runSynth $ do
            sig <- playBufMono buf (Param 1.0) (Param 0) (Param 0)
            y   <- staticPlugin oneTapDelayPlugin sig (Param 0.0)
            out 0 y
      tg <- either assertFailure' pure (compileTemplateGraph [("g", graph)])
      withRTGraph (totalNodes tg) nframes $ \rt -> do
        loadTemplateGraph rt tg
        b <- allocBuffer rt nframes
        loadBuffer rt b
          [ if i == impulseAt then 1.0 else 0.0 | i <- [0 .. nframes - 1] ]
        c_rt_graph_process rt (fromIntegral nframes)
        samples <- readBus rt 0 nframes
        invalid <- c_rt_graph_test_invalid_plugin_call_count rt
        invalid @?= 0
        zipWith (-) samples (expectedImpulse nframes (impulseAt + 1))
          @?= replicate nframes 0.0

    -- §5 #8 — delay carries across block boundaries.
  , testCase "one-tap-delay carries state across block boundaries" $ do
      let nframes  = 64
          buf      = Buffer 0
          graph    = runSynth $ do
            sig <- playBufMono buf (Param 1.0) (Param 0) (Param 0)
            y   <- staticPlugin oneTapDelayPlugin sig (Param 0.0)
            out 0 y
          -- 128-frame buffer with impulse at frame 63 (last sample of
          -- block 0). Block 0 swallows the impulse into prev_sum; block
          -- 1's first sample emits it.
          impulseFrame = nframes - 1
          bufferLen    = nframes * 2
      tg <- either assertFailure' pure (compileTemplateGraph [("g", graph)])
      withRTGraph (totalNodes tg) nframes $ \rt -> do
        loadTemplateGraph rt tg
        b <- allocBuffer rt bufferLen
        loadBuffer rt b
          [ if i == impulseFrame then 1.0 else 0.0 | i <- [0 .. bufferLen - 1] ]
        c_rt_graph_process rt (fromIntegral nframes)
        block0 <- readBus rt 0 nframes
        c_rt_graph_process rt (fromIntegral nframes)
        block1 <- readBus rt 0 nframes
        block0 @?= replicate nframes 0.0
        block1 @?= (1.0 : replicate (nframes - 1) 0.0)

    -- §5 #8a — null-as-zero on both inputs is silent + healthy.
  , testCase "one-tap-delay treats both null inputs as zero (no invalid ticks)" $ do
      let nframes = 16
          graph   = runSynth $ do
            y <- staticPlugin oneTapDelayPlugin (Param 0.0) (Param 0.0)
            out 0 y
      tg <- either assertFailure' pure (compileTemplateGraph [("g", graph)])
      withRTGraph (totalNodes tg) nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        samples <- readBus rt 0 nframes
        calls   <- c_rt_graph_test_plugin_call_count rt
        invalid <- c_rt_graph_test_invalid_plugin_call_count rt
        samples @?= replicate nframes 0.0
        calls   @?= 1
        invalid @?= 0

    -- §5 #9 — independent state across two plugin nodes in one template.
  , testCase "two one-tap-delay nodes in one template have independent state" $ do
      let nframes = 16
          bufA    = Buffer 0
          bufB    = Buffer 1
          graph = runSynth $ do
            sa <- playBufMono bufA (Param 1.0) (Param 0) (Param 0)
            sb <- playBufMono bufB (Param 1.0) (Param 0) (Param 0)
            pa <- staticPlugin oneTapDelayPlugin sa (Param 0.0)
            pb <- staticPlugin oneTapDelayPlugin sb (Param 0.0)
            busOut 0 pa
            busOut 1 pb
      tg <- either assertFailure' pure (compileTemplateGraph [("g", graph)])
      withRTGraph (totalNodes tg) nframes $ \rt -> do
        loadTemplateGraph rt tg
        ba <- allocBuffer rt nframes
        bb <- allocBuffer rt nframes
        -- Buffer A: impulse at the last sample so plugin α writes
        -- prev_sum = 1 at the end of block 0 but never emits it.
        loadBuffer rt ba
          [ if i == nframes - 1 then 1.0 else 0.0 | i <- [0 .. nframes - 1] ]
        loadBuffer rt bb (replicate nframes 0.0)
        bufferId ba @?= 0
        bufferId bb @?= 1
        c_rt_graph_process rt (fromIntegral nframes)
        bus0 <- readBus rt 0 nframes
        bus1 <- readBus rt 1 nframes
        bus0 @?= replicate nframes 0.0
        -- The leak assertion: shared storage would put `1.0` at bus 1[0]
        -- because plugin α writes prev_sum=1 mid-block.
        bus1 @?= replicate nframes 0.0
        calls <- c_rt_graph_test_plugin_call_count rt
        calls @?= 2

    -- §5 #10 — independent state across two voices of the same
    -- template. Voice A is the auto-spawned slot 0 keeping the
    -- default bus-0 routing; voice B is a second
    -- 'c_rt_graph_template_instance_add' call whose busOut control
    -- is overridden per-instance to route at bus 1. Both voices
    -- read the same buffer (impulse at the last sample) — with
    -- per-instance state, neither voice emits the carried sample
    -- in block 0; with shared storage on PluginSpec, voice B reads
    -- voice A's mid-block prev_sum=1 and emits 1 at bus 1[0].
  , testCase "two voices of a one-tap-delay template have independent state" $ do
      let nframes = 16
          buf     = Buffer 0
          graph = runSynth $ do
            s <- playBufMono buf (Param 1.0) (Param 0) (Param 0)
            p <- staticPlugin oneTapDelayPlugin s (Param 0.0)
            busOut 0 p
      tg <- either assertFailure' pure (compileTemplateGraph [("g", graph)])
      withRTGraph (totalNodes tg * 3) nframes $ \rt -> do
        loadTemplateGraph rt tg
        b <- allocBuffer rt nframes
        loadBuffer rt b
          [ if i == nframes - 1 then 1.0 else 0.0 | i <- [0 .. nframes - 1] ]
        slotB <- c_rt_graph_template_instance_add rt 0
        assertBool "second voice spawned" (slotB >= 0)
        -- The graph only declares busOut 0, so the loader's
        -- bus-pool sizing pass only grew the server up to bus 0.
        -- rt_graph_instance_set_control mutates the per-instance
        -- control but does not resize the bus pool; without an
        -- explicit ensure-bus, voice B's writes would land in a
        -- non-existent bus and rt_graph_read_bus would return 0
        -- samples — which 'readBus' now catches via its
        -- "wrote == n" assertion.
        c_rt_graph_ensure_bus rt 1
        -- busOut sits at the last node index; its control 0 is the
        -- destination bus. Override only voice B so the two voices
        -- write to distinct buses.
        let busOutIdx = fromIntegral (totalNodes tg - 1) :: CInt
        c_rt_graph_instance_set_control rt slotB busOutIdx 0 1.0
        c_rt_graph_process rt (fromIntegral nframes)
        bus0  <- readBus rt 0 nframes
        bus1  <- readBus rt 1 nframes
        calls <- c_rt_graph_test_plugin_call_count rt
        bus0  @?= replicate nframes 0.0
        bus1  @?= replicate nframes 0.0
        calls @?= 2

    -- §5 #11 — Identity and one-tap-delay coexist; dispatcher picks
    -- the right vtable per plugin id.
  , testCase "Identity and one-tap-delay coexist on the same graph" $ do
      let nframes = 16
          buf     = Buffer 0
          graph = runSynth $ do
            -- Identity branch: bit-exact a + b on bus 0.
            a <- sinOsc 440.0 0.0
            b <- sinOsc 220.0 0.0
            ya <- staticPlugin identityPlugin a b
            busOut 0 ya
            -- One-tap branch: impulse → delayed impulse on bus 1.
            s <- playBufMono buf (Param 1.0) (Param 0) (Param 0)
            yo <- staticPlugin oneTapDelayPlugin s (Param 0.0)
            busOut 1 yo
          addGraph = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sinOsc 220.0 0.0
            y <- add a b
            busOut 0 y
      tg    <- either assertFailure' pure (compileTemplateGraph [("g", graph)])
      tgAdd <- either assertFailure' pure (compileTemplateGraph [("g", addGraph)])
      identityBus <- withRTGraph (totalNodes tg) nframes $ \rt -> do
        loadTemplateGraph rt tg
        b <- allocBuffer rt nframes
        loadBuffer rt b
          [ if i == 3 then 1.0 else 0.0 | i <- [0 .. nframes - 1] ]
        c_rt_graph_process rt (fromIntegral nframes)
        bus0 <- readBus rt 0 nframes
        bus1 <- readBus rt 1 nframes
        calls <- c_rt_graph_test_plugin_call_count rt
        calls @?= 2
        bus1 @?= expectedImpulse nframes 4
        pure bus0
      addBus <- withRTGraph (totalNodes tgAdd) nframes $ \rt -> do
        loadTemplateGraph rt tgAdd
        c_rt_graph_process rt (fromIntegral nframes)
        readBus rt 0 nframes
      identityBus @?= addBus

    -- §5 #12 — kind-level metadata stays untouched in v2.
  , testCase "kindLatency / kindCapabilities for KStaticPlugin stay unchanged" $ do
      kindLatency      KStaticPlugin @?= Nothing
      kindCapabilities KStaticPlugin @?= [CapHardBarrier]
  ]
  where
    assertFailure' :: String -> IO a
    assertFailure' msg = assertFailure msg >> error "unreachable"

    totalNodes :: TemplateGraph -> Int
    totalNodes tg =
      sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

    -- | Read exactly @n@ samples from a bus. Asserts the read count
    -- equals @n@: c_rt_graph_read_bus returns 0 for a bus that
    -- doesn't exist, which would otherwise let a test silently see
    -- the caller's zero-initialized scratch buffer instead of the
    -- bus's actual contents — a false negative on any "bus N is
    -- silent" assertion.
    readBus :: Ptr RTGraph -> Int -> Int -> IO [Float]
    readBus rt bus n =
      allocaBytes (n * 4) $ \bp -> do
        wrote <- c_rt_graph_read_bus rt (fromIntegral bus)
                                        (fromIntegral n) (castPtr bp)
        wrote @?= fromIntegral n
        xs <- peekArray n (bp :: Ptr CFloat)
        pure [ x | CFloat x <- xs ]

    expectedImpulse :: Int -> Int -> [Float]
    expectedImpulse n k =
      [ if i == k then 1.0 else 0.0 | i <- [0 .. n - 1] ]

    -- | A minimal RuntimeNode for synthetic accessor tests. Only
    -- 'rnKind' and 'rnControls' actually drive 'nodeDeclaredLatency';
    -- every other field gets a benign default. The caller overrides
    -- 'rnKind' / 'rnControls' on the record literal.
    mkPluginNode :: [Double] -> RuntimeNode
    mkPluginNode ctrls = RuntimeNode
      { rnIndex         = NodeIndex 0
      , rnOriginalID    = NodeID 0
      , rnKind          = KStaticPlugin
      , rnInputs        = []
      , rnControls      = ctrls
      , rnMigrationKey  = Nothing
      , rnOutputUse     = NoOutput
      , rnConsumerCount = 0
      , rnElided        = False
      , rnRate          = SampleRate
      }
