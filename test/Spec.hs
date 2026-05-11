{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : Spec
-- Description : Structural and end-to-end tests for the MetaSonic compiler pipeline
--
-- Three layers of coverage:
--
--   * Unit tests on the demo graphs from Main, asserting that
--     validateAndSort, lowerGraph, and compileRuntimeGraph all
--     succeed and produce well-formed output, plus edge-graph
--     and dependency-extraction units.
--
--   * QuickCheck properties on randomly generated, well-formed
--     SynthGraphs, asserting compile-pass invariants
--     (dense indices, topological order, bijection between source
--     and runtime nodes, kind preservation, determinism, and
--     region-formation structure).
--
--   * Cross-cutting end-to-end tests that build a graph in
--     Haskell, push it through the full pipeline + FFI, render
--     a block via 'c_rt_graph_process', and assert on the audio
--     samples coming out of 'c_rt_graph_read_bus'. This is the
--     only layer that exercises FFI marshaling end-to-end.

module Main (main) where

import qualified Data.Map.Strict           as M
import qualified Data.Set                  as S
import           Data.List                 (find, isInfixOf, isPrefixOf, nub,
                                            sort, sortBy)
import           Control.Concurrent        (forkIO, newEmptyMVar, putMVar,
                                            takeMVar, threadDelay)
import           Control.Exception         (try)
import           Control.Monad             (forM, forM_, when)
import           Data.Maybe                (isJust, isNothing, listToMaybe,
                                            mapMaybe)
import           Data.Ord                  (comparing)
import           Data.Word                 (Word8)
import           Foreign.C.Types           (CDouble (..), CFloat (..),
                                            CInt, CLLong)
import           Foreign.Marshal.Alloc     (allocaBytes)
import           Foreign.Marshal.Array     (peekArray)
import           Foreign.Ptr               (Ptr, castPtr)

import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck     as QC

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI      (RTGraph,
                                            HotSwapWaitResult (..),
                                            SwapMigrationStats (..),
                                            c_rt_graph_realtime_set_control,
                                            c_rt_graph_test_swap_generation,
                                            c_rt_graph_ensure_bus,
                                            c_rt_graph_instance_alive,
                                            c_rt_graph_instance_count,
                                            c_rt_graph_instance_release,
                                            c_rt_graph_instance_remove,
                                            c_rt_graph_instance_set_control,
                                            c_rt_graph_instance_status,
                                            c_rt_graph_kind_supported,
                                            c_rt_graph_region_kernel_supported,
                                            c_rt_graph_clear,
                                            c_rt_graph_process,
                                            c_rt_graph_read_bus,
                                            c_rt_graph_template_add,
                                            c_rt_graph_template_count,
                                            c_rt_graph_template_instance_add,
                                            c_rt_graph_template_set_polyphony,
                                            c_rt_graph_test_global_schedule_entry_count,
                                            c_rt_graph_test_global_schedule_entry_instance,
                                            c_rt_graph_test_global_schedule_entry_step,
                                            c_rt_graph_test_global_schedule_entry_template,
                                            c_rt_graph_test_global_schedule_band_count,
                                            c_rt_graph_test_global_schedule_band_entry_count,
                                            c_rt_graph_test_global_schedule_band_first_entry,
                                            c_rt_graph_test_global_schedule_band_kind,
                                            c_rt_graph_test_last_parallel_band_count,
                                            c_rt_graph_test_last_parallel_entry_count,
                                            c_rt_graph_test_set_worker_pool_size,
                                            c_rt_graph_test_set_global_schedule_execution,
                                            c_rt_graph_test_set_reduction_capture,
                                            c_rt_graph_test_template_schedule_step_count,
                                            c_rt_graph_test_template_schedule_step_item_count,
                                            c_rt_graph_test_template_schedule_step_kind,
                                            c_rt_graph_test_template_schedule_step_region,
                                            c_rt_graph_test_buffer_read_count,
                                            c_rt_graph_test_buffer_invalid_read_count,
                                            c_rt_graph_test_buffer_write_count,
                                            c_rt_graph_test_buffer_invalid_write_count,
                                            c_rt_graph_test_spectral_analysis_count,
                                            c_rt_graph_test_spectral_resynthesis_count,
                                            instanceStatusLive,
                                            instanceStatusReleasing,
                                            collectRetiredSwapStats,
                                            hotSwapRuntimeGraph,
                                            hotSwapRuntimeGraphFused,
                                            hotSwapRuntimeGraphAndWait,
                                            hotSwapTemplateGraph,
                                            hotSwapTemplateGraphFused,
                                            loadRuntimeGraph,
                                            loadRuntimeGraphFused,
                                            loadTemplateGraph,
                                            loadTemplateGraphFused,
                                            withRTGraph)
import           MetaSonic.Bridge.Buffer   (BufferIssue (..), allocBuffer,
                                            clearBuffer,
                                            collectRetiredBuffer,
                                            loadBuffer, retireBuffer)
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Bridge.Validate
import qualified MetaSonic.OSC.Dispatch          as OSC
import qualified MetaSonic.OSC.Dispatch.Internal as OSCI
import qualified MetaSonic.OSC.Listen            as OSC
import qualified MetaSonic.OSC.Wire              as OSC

import qualified Network.Socket                  as OSCN
import qualified Network.Socket.ByteString       as OSCNSB
import           Data.IORef                      (modifyIORef',
                                                  newIORef,
                                                  readIORef)
import           System.Timeout                  (timeout)
import           MetaSonic.Pattern
import           MetaSonic.Pattern.Corpus
import           MetaSonic.Types

import qualified Data.ByteString           as OBS
import qualified Data.ByteString.Char8     as OBSC
import           Data.Word                 (Word8)

main :: IO ()
main = defaultMain $ testGroup "MetaSonic"
  [ unitTests
  , properties
  , crossCuttingTests
  , t9DirectEqualsReductionTests
  , c0aLoaderMetadataTests
  , c0bGlobalScheduleTests
  , c0cScheduleExecutorTests
  , c0dGlobalScheduleBandTests
  , c1cWorkerScheduleTests
  , patternCorpusTests
  , oscWireAndDispatchTests
  , oscListenerTests
  , oscEndToEndTests
  , oscPortParserTests
  , bufferPoolTests
  , playBufMonoTests
  , recordBufMonoSkeletonTests
  , spectralFreezeSkeletonTests
  ]

------------------------------------------------------------
-- Sample graphs (mirrors of the demos in app/Main.hs)
------------------------------------------------------------

simpleGraph :: SynthGraph
simpleGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  out 0 osc

chainGraph :: SynthGraph
chainGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  g   <- gain osc 0.5
  out 0 g

fanOutGraph :: SynthGraph
fanOutGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  g1  <- gain osc 0.3
  g2  <- gain osc 0.7
  out 0 g1
  out 1 g2

-- | Used by the C0a "free layer with non-contiguous ordinals"
-- regression. The intended shape, post-formRegions /
-- selectRegionKernels, is three free buffer-terminal regions
-- (region 0, region 1, region 2) plus a barrier sink, where
-- region 1 structurally depends on region 0 (the second saw
-- chain feeds gain1's output into its own LPF) and region 2 is
-- independent. With that shape, 'goLayers' partitions the ready
-- frontier as [{0, 2}, {1}] — non-contiguous in regionSchedule
-- order [0, 1, 2]. The test asserts the divergence and verifies
-- the FFI metadata preserves the ordinal set.
divergentLayerGraph :: SynthGraph
divergentLayerGraph = runSynth $ do
  s1 <- sawOsc 110.0 0.0
  f1 <- lpf s1 (Param 800.0)  (Param 4.0)
  g1 <- gain f1 (Param 0.4)
  -- Cross-region structural edge: this LPF reads g1's output,
  -- and selectRegionKernels claims [s1, f1, g1] as a fused
  -- buffer-terminal region, leaving [f2, g2] in its own region.
  f2 <- lpf g1 (Param 1500.0) (Param 4.0)
  g2 <- gain f2 (Param 0.4)
  -- Independent free buffer chain.
  s3 <- sawOsc 220.0 0.0
  f3 <- lpf s3 (Param 1000.0) (Param 4.0)
  g3 <- gain f3 (Param 0.4)
  summed <- add g2 g3
  out 0 summed

sawGraph :: SynthGraph
sawGraph = runSynth $ do
  osc <- sawOsc 440.0 0.0
  g   <- gain osc 0.4
  out 0 g

noiseLpfGraph :: SynthGraph
noiseLpfGraph = runSynth $ do
  n <- noiseGen
  f <- lpf n 800.0 0.7
  g <- gain f 0.4
  out 0 g

ringModGraph :: SynthGraph
ringModGraph = runSynth $ do
  carrier   <- sinOsc 440.0 0.0
  modulator <- sinOsc 7.0 0.0
  ring      <- gain carrier modulator
  amped     <- gain ring 0.3
  out 0 amped

fmGraph :: SynthGraph
fmGraph = runSynth $ do
  lfo       <- sinOsc 5.0 0.0
  deviation <- gain lfo 30.0
  freq      <- add 440.0 deviation
  carrier   <- sinOsc freq 0.0
  amped     <- gain carrier 0.3
  out 0 amped

demoGraphs :: [(String, SynthGraph)]
demoGraphs =
  [ ("simple",    simpleGraph)
  , ("chain",     chainGraph)
  , ("fanout",    fanOutGraph)
  , ("saw",       sawGraph)
  , ("noise-lpf", noiseLpfGraph)
  , ("ringmod",   ringModGraph)
  , ("fm",        fmGraph)
  ]

------------------------------------------------------------
-- Unit tests
------------------------------------------------------------

unitTests :: TestTree
unitTests = testGroup "Unit tests"
  [ testGroup "validateAndSort succeeds on demo graphs"
      [ testCase name $ case validateAndSort g of
          Right _  -> pure ()
          Left err -> assertFailure $ "validateAndSort failed: " <> err
      | (name, g) <- demoGraphs
      ]

  , testGroup "lowerGraph preserves node count on demo graphs"
      [ testCase name $ case lowerGraph g of
          Left err -> assertFailure $ "lowerGraph failed: " <> err
          Right ir -> length (giNodes ir) @?= M.size (sgNodes g)
      | (name, g) <- demoGraphs
      ]

  , testGroup "compileRuntimeGraph produces dense indices on demo graphs"
      [ testCase name $ case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure err
          Right rt -> assertDenseIndices rt
      | (name, g) <- demoGraphs
      ]

  , testGroup "every RFrom references an earlier index on demo graphs"
      [ testCase name $ case lowerGraph g >>= compileRuntimeGraph of
          Left err -> assertFailure err
          Right rt -> assertTopoOrder rt
      | (name, g) <- demoGraphs
      ]

  , testGroup "node-index resolution: Connection → NodeID → NodeIndex"
      [ testCase "captured Connections resolve to their dense post-compile indices" $
          let (caps, sg) = runSynthWith $ do
                osc  <- sinOsc 440 0
                amp  <- gain osc 0.5
                _    <- out 0 amp
                pure (osc, amp)
              (oscConn, ampConn) = caps
          in case lowerGraph sg >>= compileRuntimeGraph of
               Left err -> assertFailure err
               Right rt -> do
                 -- Builder order is sinOsc, gain, out; topological
                 -- order matches builder order here, so dense indices
                 -- are 0, 1, 2 respectively.
                 let resolve c = connectionNodeID c >>= resolveNodeIndex rt
                 resolve oscConn @?= Just (NodeIndex 0)
                 resolve ampConn @?= Just (NodeIndex 1)

      , testCase "Param connections carry no NodeID" $
          connectionNodeID (Param 0.5) @?= Nothing

      , testCase "resolveNodeIndex returns Nothing for an unknown NodeID" $
          let sg = runSynth $ do
                osc <- sinOsc 440 0
                _   <- out 0 osc
                pure ()
          in case lowerGraph sg >>= compileRuntimeGraph of
               Left err -> assertFailure err
               Right rt -> resolveNodeIndex rt (NodeID 999) @?= Nothing
      ]

  , testGroup "migration keys"
      [ testCase "tagged builder survives lowering and runtime compile" $
          let sg = runSynth $ do
                osc <- tagged "voice-osc" (sinOsc 440 0)
                _   <- out 0 osc
                pure ()
          in case lowerGraph sg >>= compileRuntimeGraph of
               Left err -> assertFailure err
               Right rt -> do
                 let taggedNodes =
                       [ n
                       | n <- rgNodes rt
                       , rnMigrationKey n == Just (MigrationKey "voice-osc")
                       ]
                 case taggedNodes of
                   [n] -> rnKind n @?= KSinOsc
                   _   -> assertFailure $
                            "expected exactly one tagged node, got "
                         <> show (length taggedNodes)

      , testCase "validateAndSort rejects duplicate migration keys" $
          let sg = runSynth $ do
                a <- tagged "dup" (sinOsc 440 0)
                b <- tagged "dup" (sawOsc 220 0)
                _ <- out 0 a
                _ <- out 1 b
                pure ()
          in case validateAndSort sg of
               Right _  ->
                 assertFailure "expected duplicate migration key rejection"
               Left err ->
                 assertBool
                   ("expected duplicate-key diagnostic, got: " <> err)
                   ("Duplicate migration key" `isInfixOf` err)

      , testCase "validateAndSort rejects overlong migration keys" $
          let sg = runSynth $ do
                osc <- tagged "0123456789abcdefX" (sinOsc 440 0)
                _   <- out 0 osc
                pure ()
          in case validateAndSort sg of
               Right _  ->
                 assertFailure "expected overlong migration key rejection"
               Left err ->
                 assertBool
                   ("expected too-long diagnostic, got: " <> err)
                   ("too long" `isInfixOf` err)

      , testCase "migration keys accept UTF-8 bytes through the FFI" $ do
          let key = "voice-" <> [toEnum 0xe9 :: Char]
              sg = runSynth $ do
                osc <- tagged key (sinOsc 440 0)
                _   <- out 0 osc
                pure ()
          case lowerGraph sg >>= compileRuntimeGraph of
            Left err -> assertFailure err
            Right rt -> do
              assertBool
                "expected compiled runtime node to preserve UTF-8 key"
                (any ((== Just (MigrationKey key)) . rnMigrationKey)
                     (rgNodes rt))
              withRTGraph (length (rgNodes rt)) 64 $ \handle ->
                loadRuntimeGraph handle rt

      , testCase "validateAndSort rejects keys over 16 UTF-8 bytes" $
          let key = replicate 9 (toEnum 0xe9 :: Char)
              sg = runSynth $ do
                osc <- tagged key (sinOsc 440 0)
                _   <- out 0 osc
                pure ()
          in case validateAndSort sg of
               Right _  ->
                 assertFailure "expected overlong UTF-8 migration key rejection"
               Left err ->
                 assertBool
                   ("expected UTF-8 byte-length diagnostic, got: " <> err)
                   ("too long" `isInfixOf` err)
      ]

  , testGroup "cc builder: auto-records CCSpec + auto-inserts Smooth"
      [ testCase "cc inserts a Smooth node and records the binding" $
          let ((vol, target), _, specs) = runSynthCCs $ do
                v <- cc 7 0.3 0.0 1.0
                t <- gain v 0.5
                _ <- out 0 t
                pure (v, t)
          in do
            -- The Connection returned by 'cc' points at a real
            -- audio-rate node (the inserted Smooth).
            connectionNodeID vol @?= Just (NodeID 0)
            -- Exactly one CC binding was registered, pointing at the
            -- Smooth node's control[1] (target) with the declared
            -- range.
            length specs @?= 1
            case specs of
              [s] -> do
                ccsNumber s @?= (7 :: Word8)
                ccsNode   s @?= NodeID 0
                ccsCtl    s @?= 1
                ccsMin    s @?= 0.0
                ccsMax    s @?= 1.0
              _   -> assertFailure "expected one CC spec"
            -- Sanity: the Smooth node is wired into the downstream
            -- gain — i.e. 'cc' didn't accidentally produce an orphan.
            connectionNodeID target @?= Just (NodeID 1)

      , testCase "multiple cc calls preserve declaration order" $
          let (_, _, specs) = runSynthCCs $ do
                _ <- cc 7  0.5 0.0 1.0
                _ <- cc 74 0.3 0.0 1.0
                _ <- cc 11 0.0 0.0 1.0
                pure ()
          in map ccsNumber specs @?= [7, 74, 11]

      , testCase "cc-allocated Smooth resolves to a dense NodeIndex post-compile" $
          let ((volConn, _), sg, _) = runSynthCCs $ do
                v <- cc 1 0.0 0.0 1.0
                _ <- out 0 v
                pure (v, ())
          in case lowerGraph sg >>= compileRuntimeGraph of
               Left err -> assertFailure err
               Right rt -> case connectionNodeID volConn of
                 Nothing  -> assertFailure "cc returned a Param connection"
                 Just nid -> case resolveNodeIndex rt nid of
                   Nothing -> assertFailure
                              "cc-Smooth's NodeID not in compiled graph"
                   Just ni -> ni @?= NodeIndex 0

      , testCase "cc-allocated node compiles to KSmooth with controls = [20, init]" $
          -- Pin the kindSpec layout — the runner relies on
          -- controls[1] being the target. A regression that
          -- allocated a different kind, or shuffled the controls
          -- list, would silently break the CC dispatch.
          let sg = runSynth $ do
                v <- cc 64 0.42 0.0 1.0
                _ <- out 0 v
                pure ()
          in case lowerGraph sg >>= compileRuntimeGraph of
               Left err -> assertFailure err
               Right rt ->
                 let smooths = [ n | n <- rgNodes rt, rnKind n == KSmooth ]
                 in case smooths of
                      [n] -> rnControls n @?= [20.0, 0.42]
                      _   -> assertFailure $
                               "expected exactly one KSmooth, got "
                            <> show (length smooths)

      , testCase "same CC number registered twice records two specs (multi-target)" $
          -- Multiple mappings sharing a CC number is a deliberate
          -- feature of the C ABI (see MidiVoiceProcessor docs).
          -- 'cc' should not deduplicate.
          let (_, _, specs) = runSynthCCs $ do
                _ <- cc 7 0.5 0.0 1.0
                _ <- cc 7 0.0 0.0 0.5  -- second binding to same CC
                pure ()
          in do
            length specs @?= 2
            map ccsNumber specs @?= [7, 7]
            -- Each binding gets its own NodeID (own Smooth node).
            map ccsNode specs @?= [NodeID 0, NodeID 1]

      , testCase "runSynth and runSynthWith still work when cc is used (specs discarded)" $
          -- Backwards-compat pin: legacy callers that don't care
          -- about CC bindings can use 'runSynth' / 'runSynthWith'
          -- and get a well-formed graph with the cc-allocated Smooth
          -- nodes intact.
          let body = do
                v <- cc 1 0.0 0.0 1.0
                _ <- out 0 v
                pure v
              graphRunSynth     = runSynth body
              (volC, graphRWith) = runSynthWith body
              sgEqual = graphRunSynth == graphRWith
          in do
            assertBool "runSynth and runSynthWith produce the same graph" sgEqual
            -- The captured Connection still resolves correctly.
            case lowerGraph graphRunSynth >>= compileRuntimeGraph of
              Left err -> assertFailure err
              Right rt -> case connectionNodeID volC of
                Nothing  -> assertFailure "cc returned a Param connection"
                Just nid -> case resolveNodeIndex rt nid of
                  Nothing -> assertFailure "cc-Smooth NodeID missing"
                  Just _  -> pure ()
      ]

  , testCase "checkDependencies rejects missing references" $
      case checkDependencies missingDepGraph of
        Right () ->
          assertFailure "expected checkDependencies to reject missing dep"
        Left err ->
          assertBool ("expected 'Missing' in error, got: " <> err)
                    ("Missing" `isPrefixOf` err)

  , testCase "validateAndSort rejects cycles" $
      case validateAndSort cycleGraph of
        Right _ ->
          assertFailure "expected validateAndSort to reject cycle"
        Left err ->
          assertBool ("expected 'Cycle' in error, got: " <> err)
                    ("Cycle" `isPrefixOf` err)

  , testCase "ringmod: a gain node has both inputs wired as RFrom" $
      case lowerGraph ringModGraph >>= compileRuntimeGraph of
        Left err -> assertFailure err
        Right rt ->
          let hasTwoAudioInputs n =
                rnKind n == KGain
                && length [() | RFrom _ _ <- rnInputs n] == 2
          in assertBool
               "expected a Gain node with two RFrom inputs in ringmod"
               (any hasTwoAudioInputs (rgNodes rt))

  , testCase "fm: a SinOsc has its frequency port wired as RFrom" $
      case lowerGraph fmGraph >>= compileRuntimeGraph of
        Left err -> assertFailure err
        Right rt ->
          let hasModulatedFreq n = case (rnKind n, rnInputs n) of
                (KSinOsc, RFrom _ _ : _) -> True
                _                        -> False
          in assertBool
               "expected a SinOsc with RFrom on port 0 in fm graph"
               (any hasModulatedFreq (rgNodes rt))

  , testCase "fm: contains an Add node biasing freq off zero" $
      case lowerGraph fmGraph >>= compileRuntimeGraph of
        Left err -> assertFailure err
        Right rt ->
          let isVibratoBias n = case (rnKind n, rnControls n, rnInputs n) of
                (KAdd, 440.0 : _, _ : RFrom _ _ : _) -> True
                _                                    -> False
          in assertBool
               "expected an Add node with bias=440.0 and modulated port 1"
               (any isVibratoBias (rgNodes rt))

  , -- Contract test: every Haskell NodeKind must map to a kindTag
    -- that the C++ runtime recognizes via kind_from_tag. Adding a
    -- constructor to NodeKind without updating rt_graph.cpp will fail
    -- here. Enum/Bounded on NodeKind ensures new constructors are
    -- automatically covered.
    testGroup "C ABI agrees on every NodeKind tag"
      [ testCase (show k) $ do
          ok <- c_rt_graph_kind_supported (kindTag k)
          assertBool
            ("rt_graph_kind_supported(" <> show (kindTag k) <> ") "
              <> "returned 0 for " <> show k <> " — C++ kind_from_tag "
              <> "is missing this case")
            (ok == 1)
      | k <- [minBound .. maxBound :: NodeKind]
      ]

  , -- Phase 4.B: every Haskell RegionKernel must round-trip through
    -- the C ABI introspection entry. Mirrors the kindTag agreement
    -- test for node kinds. If RegionKernel grows a new constructor
    -- without the matching C++ enum entry, this test catches the
    -- drift before any region kernel lands silently.
    testGroup "C ABI agrees on every RegionKernel tag"
      [ testCase (show k) $ do
          ok <- c_rt_graph_region_kernel_supported (kernelTag k)
          assertBool
            ("rt_graph_region_kernel_supported(" <> show (kernelTag k)
              <> ") returned 0 for " <> show k
              <> " — C++ region_kernel_from_tag is missing this case")
            (ok == 1)
      | k <- [minBound .. maxBound :: RegionKernel]
      ]

  , testGroup "Edge graphs"
      [ testCase "empty graph: validateAndSort succeeds with no nodes" $
          case validateAndSort emptyGraph_ of
            Right []  -> pure ()
            Right ns  -> assertFailure $ "expected [], got " <> show (length ns) <> " nodes"
            Left  err -> assertFailure $ "validateAndSort failed: " <> err

      , testCase "empty graph: lowerGraph yields 0 IR nodes" $
          case lowerGraph emptyGraph_ of
            Right ir -> length (giNodes ir) @?= 0
            Left err -> assertFailure $ "lowerGraph failed: " <> err

      , testCase "empty graph: compileRuntimeGraph yields 0 runtime nodes" $
          case lowerGraph emptyGraph_ >>= compileRuntimeGraph of
            Right rt -> length (rgNodes rt) @?= 0
            Left err -> assertFailure $ "compile failed: " <> err

      , testCase "single Out with Param source compiles and has 1 node" $
          case lowerGraph silentOutGraph >>= compileRuntimeGraph of
            Right rt -> do
              length (rgNodes rt) @?= 1
              case rgNodes rt of
                [n] -> rnKind n @?= KOut
                _   -> assertFailure "expected one node"
            Left err -> assertFailure err

      , testCase "disconnected subgraphs: both Outs survive lowering" $
          case lowerGraph disconnectedGraph >>= compileRuntimeGraph of
            Right rt -> do
              let outs = [ n | n <- rgNodes rt, rnKind n == KOut ]
              length outs @?= 2
              let chans = sort (map (head . rnControls) outs)
              chans @?= [0.0, 1.0]
            Left err -> assertFailure err
      ]

  , testGroup "dependencies (Source-level UGen → [NodeID])"
      [ testCase "all-Param UGen has no dependencies" $ do
          dependencies (SinOsc (Param 440) (Param 0)) @?= []
          dependencies (LPF (Param 0) (Param 800) (Param 0.7)) @?= []
          dependencies (Gain (Param 0) (Param 0.5)) @?= []
          dependencies (Add (Param 1) (Param 2)) @?= []
          dependencies NoiseGen @?= []
          dependencies (Out 0 (Param 0)) @?= []

      , testCase "single-Audio input contributes one dependency" $
          dependencies (Gain (Audio (NodeID 7) (PortIndex 0)) (Param 0.5))
            @?= [NodeID 7]

      , testCase "two-Audio inputs contribute both, in argument order" $
          dependencies
            (Gain (Audio (NodeID 1) (PortIndex 0))
                  (Audio (NodeID 2) (PortIndex 0)))
            @?= [NodeID 1, NodeID 2]

      , testCase "mixed Audio/Param: only Audio contributes" $
          dependencies
            (Add (Param 440)
                 (Audio (NodeID 99) (PortIndex 0)))
            @?= [NodeID 99]

      , testCase "LPF with audio sig + param controls: only sig" $
          dependencies
            (LPF (Audio (NodeID 3) (PortIndex 0))
                 (Param 800)
                 (Param 0.7))
            @?= [NodeID 3]

      , testCase "Out wraps its source dependency" $
          dependencies (Out 0 (Audio (NodeID 42) (PortIndex 0)))
            @?= [NodeID 42]
      ]

  , testGroup "Bus routing (BusIn/BusOut and E_r edges)"
      [ testCase "validateAndSort orders BusOut before BusIn on the same bus" $ do
          -- Structurally there is no edge between the BusOut and the
          -- BusIn — only the bus number connects them. The E_r edge
          -- derived from BusWrite/BusRead must force the writer first.
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                busOut 5 o
                t <- busIn 5
                out 0 t
          case validateAndSort g of
            Left err  -> assertFailure $ "validateAndSort failed: " <> err
            Right ord ->
              let nodes = sgNodes g
                  posOf nid = head [ i | (i, k) <- zip [0..] ord, k == nid ]
                  busOutPos = head
                    [ posOf nid
                    | (nid, ns) <- M.toList nodes
                    , case nsUgen ns of BusOut{} -> True; _ -> False ]
                  busInPos = head
                    [ posOf nid
                    | (nid, ns) <- M.toList nodes
                    , case nsUgen ns of BusIn{} -> True; _ -> False ]
              in assertBool
                   ("BusOut at " <> show busOutPos
                    <> " must precede BusIn at " <> show busInPos)
                   (busOutPos < busInPos)

      , testCase "validateAndSort orders Out before BusIn on the same bus" $ do
          -- Out and BusOut share a runtime kernel and the same bus pool,
          -- so an Out n must induce the same E_r writer→reader ordering
          -- against a BusIn n that a BusOut n does. Earlier versions made
          -- Out 'Pure', a latent bug exposed once cross-template bus
          -- routing made Out and BusOut's disagreement visible.
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                out 0 o
                t <- busIn 0
                busOut 9 t
          case validateAndSort g of
            Left err  -> assertFailure $ "validateAndSort failed: " <> err
            Right ord ->
              let nodes  = sgNodes g
                  posOf nid = head [ i | (i, k) <- zip [0..] ord, k == nid ]
                  outPos = head
                    [ posOf nid
                    | (nid, ns) <- M.toList nodes
                    , case nsUgen ns of Out{} -> True; _ -> False ]
                  busInPos = head
                    [ posOf nid
                    | (nid, ns) <- M.toList nodes
                    , case nsUgen ns of BusIn{} -> True; _ -> False ]
              in assertBool
                   ("Out at " <> show outPos
                    <> " must precede BusIn at " <> show busInPos)
                   (outPos < busInPos)

      , testCase "validateAndSort rejects a BusOut→BusIn cycle on the same bus" $ do
          -- A node both writes and reads bus 5: BusIn 5 feeds a Gain
          -- whose output is written back via BusOut 5. Structurally
          -- this is acyclic (BusIn has no input, BusOut has one input),
          -- but the E_r edge BusOut→BusIn closes the loop.
          let g = runSynth $ do
                t <- busIn 5
                amped <- gain t 0.9
                busOut 5 amped
                out 0 t
          case validateAndSort g of
            Right _   -> assertFailure
              "expected validateAndSort to reject a same-bus E_r cycle"
            Left err  ->
              assertBool ("expected 'Cycle' in error, got: " <> err)
                         ("Cycle" `isPrefixOf` err)

      , testCase "different buses are independent (no spurious edges)" $ do
          -- BusOut 5 and BusIn 6 must not be ordered: they touch
          -- different buses. This catches a regression where busEdges
          -- ignored the bus-number guard.
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                busOut 5 o
                _ <- busIn 6  -- never written, but should still validate
                out 0 o
          case validateAndSort g of
            Left err -> assertFailure $ "validateAndSort failed: " <> err
            Right _  -> pure ()

      , testCase "busInDelayed contributes no E_r edge (busEdges ignores it)" $ do
          -- A graph with BusOut 5 and BusInDelayed 5 (no live BusIn)
          -- must produce zero E_r edges. If busEdges ever started
          -- pairing BusReadDelayed with BusWrite, feedback graphs
          -- would stop scheduling — this test pins the asymmetry.
          let g = runSynth $ do
                o   <- sinOsc 440.0 0.0
                busOut 5 o
                _   <- busInDelayed 5
                out 0 o
          busEdges g @?= []

      , -- Rate propagation tests live just below; rate machinery
        -- and bus machinery share the same IR pipeline so it's
        -- convenient to keep them adjacent.
        testCase "feedback graph through busInDelayed topologically sorts" $ do
          -- This is the smoke test for the whole Phase 2 design: a
          -- graph whose only "cycle" closes through BusInDelayed must
          -- be accepted by the scheduler. Replacing busInDelayed with
          -- busIn would (correctly) close an E_r cycle and be
          -- rejected — see "rejects a BusOut→BusIn cycle on the same
          -- bus" above.
          let g = runSynth $ do
                tap <- busInDelayed 5
                o   <- sinOsc 220.0 0.0
                mix <- add o tap
                amp <- gain mix 0.5
                busOut 5 amp
                out 0 amp
          case validateAndSort g of
            Left err -> assertFailure $
              "feedback graph through busInDelayed should sort, got: " <> err
            Right _  -> pure ()
      ]

  , -- Template-level precedence from bus dataflow. busFootprint
    -- summarizes a single template's bus surface; compileTemplateGraph
    -- composes several templates and derives a topological execution
    -- order from their footprints. The pattern mirrors the intra-graph
    -- E_r machinery one tier up; see Note [Template-level precedence
    -- from bus dataflow] in "MetaSonic.Bridge.Templates".
    testGroup "TemplateGraph (inter-template ordering)"
      [ testCase "busFootprint of a graph with no bus ops contains only the Out write" $ do
          let g  = runSynth $ do
                o <- sinOsc 440.0 0.0
                amped <- gain o 0.5
                out 0 amped
              ir = case lowerGraph g of
                     Right ir' -> ir'
                     Left err  -> error err
              fp = busFootprint ir
          -- Out 0 contributes BusWrite 0 — Out and BusOut share the
          -- annotation now. The graph has no live or delayed reads.
          bfWrites       fp @?= S.singleton 0
          bfReads        fp @?= S.empty
          bfDelayedReads fp @?= S.empty

      , testCase "busFootprint records BusOut writes and BusIn reads" $ do
          let g  = runSynth $ do
                o <- sinOsc 440.0 0.0
                busOut 5 o
                t <- busIn 7
                out 0 t
              ir = case lowerGraph g of
                     Right ir' -> ir'
                     Left err  -> error err
              fp = busFootprint ir
          bfWrites       fp @?= S.fromList [0, 5]   -- Out 0 + BusOut 5
          bfReads        fp @?= S.singleton 7
          bfDelayedReads fp @?= S.empty

      , testCase "busFootprint separates delayed reads from live reads" $ do
          let g  = runSynth $ do
                tap <- busInDelayed 9
                o   <- sinOsc 220.0 0.0
                mix <- add o tap
                amp <- gain mix 0.5
                busOut 9 amp
                out 0 amp
              ir = case lowerGraph g of
                     Right ir' -> ir'
                     Left err  -> error err
              fp = busFootprint ir
          bfWrites       fp @?= S.fromList [0, 9]
          bfReads        fp @?= S.empty
          bfDelayedReads fp @?= S.singleton 9

      , testCase "single template compiles to a one-element TemplateGraph" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                out 0 o
          case compileTemplateGraph [("solo", g)] of
            Left err -> assertFailure $ "compileTemplateGraph failed: " <> err
            Right tg -> do
              length (tgTemplates tg) @?= 1
              tplName (head (tgTemplates tg)) @?= "solo"
              -- One template can't precede itself; the precedence
              -- entry maps to the empty set.
              M.findWithDefault S.empty (TemplateID 0) (tgPrecedence tg)
                @?= S.empty

      , testCase "writer template precedes reader template (cross-bus dataflow)" $ do
          -- Producer writes bus 5; Consumer reads bus 5 and routes to
          -- hardware. compileTemplateGraph must put Producer first.
          let producer = runSynth $ do
                o <- sinOsc 440.0 0.0
                busOut 5 o
              consumer = runSynth $ do
                t <- busIn 5
                out 0 t
          case compileTemplateGraph
                 [("consumer", consumer), ("producer", producer)] of
            Left err -> assertFailure $ "compileTemplateGraph failed: " <> err
            Right tg -> do
              -- Order: producer before consumer, regardless of input
              -- order. The TemplateID is the input position; the
              -- producer was input #1 (consumer was input #0).
              map tplName (tgTemplates tg) @?= ["producer", "consumer"]
              -- Precedence is reader-keyed: consumer (TemplateID 0)
              -- depends on producer (TemplateID 1).
              M.findWithDefault S.empty (TemplateID 0) (tgPrecedence tg)
                @?= S.singleton (TemplateID 1)

      , testCase "templates with disjoint buses run in input order (no precedence)" $ do
          -- Two leaf voices on different hardware channels; neither
          -- reads what the other writes. There is no precedence and
          -- the topo sort preserves input order.
          let voiceA = runSynth $ do
                o <- sinOsc 440.0 0.0
                out 0 o
              voiceB = runSynth $ do
                o <- sinOsc 660.0 0.0
                out 1 o
          case compileTemplateGraph [("a", voiceA), ("b", voiceB)] of
            Left err -> assertFailure $ "compileTemplateGraph failed: " <> err
            Right tg -> do
              map tplName (tgTemplates tg) @?= ["a", "b"]
              M.findWithDefault S.empty (TemplateID 0) (tgPrecedence tg)
                @?= S.empty
              M.findWithDefault S.empty (TemplateID 1) (tgPrecedence tg)
                @?= S.empty

      , testCase "three-template chain sorts transitively (A→B→C)" $ do
          -- A writes 5; B reads 5 and writes 7; C reads 7. The only
          -- valid order is A, B, C.
          let a = runSynth $ do { o <- sinOsc 440.0 0.0; busOut 5 o }
              b = runSynth $ do
                    s <- busIn 5
                    g <- gain s 0.5
                    busOut 7 g
              c = runSynth $ do
                    t <- busIn 7
                    out 0 t
          -- Intentionally feed in an order other than A, B, C to
          -- prove the sort is real and not just preserving input
          -- order.
          case compileTemplateGraph [("c", c), ("a", a), ("b", b)] of
            Left err -> assertFailure $ "compileTemplateGraph failed: " <> err
            Right tg ->
              map tplName (tgTemplates tg) @?= ["a", "b", "c"]

      , testCase "BusInDelayed reader does not induce inter-template precedence" $ do
          -- producer writes bus 5; reader reads bus 5 *delayed*. There
          -- is no live-read intersection, so the templates can run in
          -- either order — the topo sort preserves input order.
          let producer = runSynth $ do
                o <- sinOsc 440.0 0.0
                busOut 5 o
              reader = runSynth $ do
                t <- busInDelayed 5
                out 0 t
          case compileTemplateGraph
                 [("reader", reader), ("producer", producer)] of
            Left err -> assertFailure $ "compileTemplateGraph failed: " <> err
            Right tg -> do
              -- No precedence either way.
              M.findWithDefault S.empty (TemplateID 0) (tgPrecedence tg)
                @?= S.empty
              M.findWithDefault S.empty (TemplateID 1) (tgPrecedence tg)
                @?= S.empty
              -- And the reader's delayed read shows up in the
              -- footprint where it belongs.
              let readerTpl = head [ t | t <- tgTemplates tg
                                       , tplName t == "reader" ]
              bfDelayedReads (rfBuses (tplFootprint readerTpl))
                @?= S.singleton 5

      , testCase "mutual live writes/reads form a cycle (rejected)" $ do
          -- A writes 5 and reads 7; B writes 7 and reads 5. Each
          -- template depends on the other through a live read, which
          -- is unschedulable across templates within one block. The
          -- compiler must reject this; the user's remedy is to turn
          -- one of the live reads into a delayed read.
          let a = runSynth $ do
                o <- sinOsc 440.0 0.0
                busOut 5 o
                t <- busIn 7
                out 0 t
              b = runSynth $ do
                s <- sinOsc 220.0 0.0
                busOut 7 s
                u <- busIn 5
                out 1 u
          case compileTemplateGraph [("a", a), ("b", b)] of
            Right _  -> assertFailure
              "expected compileTemplateGraph to reject a precedence cycle"
            Left err ->
              assertBool ("expected 'cycle' diagnostic, got: " <> err)
                         ("cycle" `isInfixOf` err)

      , testCase "duplicate template names are rejected" $ do
          let g = runSynth $ do { o <- sinOsc 440.0 0.0; out 0 o }
          case compileTemplateGraph [("dup", g), ("dup", g)] of
            Right _  -> assertFailure
              "expected compileTemplateGraph to reject duplicate names"
            Left err ->
              assertBool ("expected 'duplicate' diagnostic, got: " <> err)
                         ("duplicate" `isInfixOf` err)

      , testCase "per-template lowering errors are surfaced with the template name" $ do
          -- Build a SynthGraph with a dangling NodeID by hand. The
          -- diagnostic must mention the template's name so multi-
          -- template setups are debuggable.
          let badGraph = SynthGraph $ M.fromList
                [ ( NodeID 0
                  , NodeSpec (NodeID 0) "out"
                      (Out 0 (Audio (NodeID 99) (PortIndex 0)))
                      Nothing
                  )
                ]
          case compileTemplateGraph [("naughty", badGraph)] of
            Right _  -> assertFailure
              "expected per-template compile error to surface"
            Left err ->
              assertBool ("expected template name in error, got: " <> err)
                         ("naughty" `isInfixOf` err)

      , -- §6.C.4 slice 3: templatePrecedes unions bus + buffer
        -- edges. Bus and buffer ids live in disjoint namespaces,
        -- so neither half can spuriously trip the other.

        testCase "templatePrecedes: BufWrite \8594 BufRead on same buffer adds an edge" $ do
          let writer = emptyResourceFootprint
                { rfBuffers = emptyBufferFootprint
                    { bfBufWrites = S.singleton 3 } }
              reader = emptyResourceFootprint
                { rfBuffers = emptyBufferFootprint
                    { bfBufReads = S.singleton 3 } }
          templatePrecedes writer reader @?= True
          -- Asymmetric: the reader does not precede the writer.
          templatePrecedes reader writer @?= False

      , testCase "templatePrecedes: BufWrite on a different buffer does not add an edge" $ do
          let writer = emptyResourceFootprint
                { rfBuffers = emptyBufferFootprint
                    { bfBufWrites = S.singleton 3 } }
              reader = emptyResourceFootprint
                { rfBuffers = emptyBufferFootprint
                    { bfBufReads = S.singleton 4 } }
          templatePrecedes writer reader @?= False

      , testCase "templatePrecedes: BufRead alone is non-ordering" $ do
          -- Two readers on the same buffer: no edge (identical
          -- reads commute, matching the BusIn/BusIn convention).
          let readerA = emptyResourceFootprint
                { rfBuffers = emptyBufferFootprint
                    { bfBufReads = S.singleton 1 } }
              readerB = readerA
          templatePrecedes readerA readerB @?= False

      , testCase "templatePrecedes: bus 5 / buffer 5 share an int but not a namespace" $ do
          -- A regression guard for the disjoint-id-space property:
          -- a template writing bus 5 must not precede a template
          -- that only reads BUFFER 5 (or vice versa).
          let busWriter5 = emptyResourceFootprint
                { rfBuses = emptyFootprint
                    { bfWrites = S.singleton 5 } }
              bufReader5 = emptyResourceFootprint
                { rfBuffers = emptyBufferFootprint
                    { bfBufReads = S.singleton 5 } }
              bufWriter5 = emptyResourceFootprint
                { rfBuffers = emptyBufferFootprint
                    { bfBufWrites = S.singleton 5 } }
              busReader5 = emptyResourceFootprint
                { rfBuses = emptyFootprint
                    { bfReads = S.singleton 5 } }
          templatePrecedes busWriter5 bufReader5 @?= False
          templatePrecedes bufWriter5 busReader5 @?= False

      , testCase "computePrecedence: bus + buffer edges both register" $ do
          -- Three templates: A writes bus 0, B writes buffer 7,
          -- C reads both. computePrecedence should map C \8594 {A, B}.
          let dummyRG = RuntimeGraph [] []
              tA = Template (TemplateID 0) "A" dummyRG
                   emptyResourceFootprint
                     { rfBuses = emptyFootprint
                         { bfWrites = S.singleton 0 } }
              tB = Template (TemplateID 1) "B" dummyRG
                   emptyResourceFootprint
                     { rfBuffers = emptyBufferFootprint
                         { bfBufWrites = S.singleton 7 } }
              tC = Template (TemplateID 2) "C" dummyRG
                   emptyResourceFootprint
                     { rfBuses   = emptyFootprint
                         { bfReads    = S.singleton 0 }
                     , rfBuffers = emptyBufferFootprint
                         { bfBufReads = S.singleton 7 }
                     }
              prec = computePrecedence [tA, tB, tC]
          M.lookup (TemplateID 2) prec
            @?= Just (S.fromList [TemplateID 0, TemplateID 1])
          M.lookup (TemplateID 0) prec @?= Just S.empty
          M.lookup (TemplateID 1) prec @?= Just S.empty

      -- §6.C.4 slice 4: reject same-buffer BufWrite across
      -- templates. Tests exercise checkNoSharedBufferWriters
      -- directly (no BufWrite UGen exists yet — the writer kind
      -- lands in the §6.C.4 follow-up).

      , testCase "checkNoSharedBufferWriters: distinct writers on distinct buffers is OK" $ do
          let dummyRG = RuntimeGraph [] []
              tA = Template (TemplateID 0) "A" dummyRG
                   emptyResourceFootprint
                     { rfBuffers = emptyBufferFootprint
                         { bfBufWrites = S.singleton 0 } }
              tB = Template (TemplateID 1) "B" dummyRG
                   emptyResourceFootprint
                     { rfBuffers = emptyBufferFootprint
                         { bfBufWrites = S.singleton 1 } }
          checkNoSharedBufferWriters [tA, tB] @?= Right ()

      , testCase "checkNoSharedBufferWriters: BufWrite + BufRead on the same buffer is OK" $ do
          let dummyRG = RuntimeGraph [] []
              tWriter = Template (TemplateID 0) "writer" dummyRG
                   emptyResourceFootprint
                     { rfBuffers = emptyBufferFootprint
                         { bfBufWrites = S.singleton 3 } }
              tReader = Template (TemplateID 1) "reader" dummyRG
                   emptyResourceFootprint
                     { rfBuffers = emptyBufferFootprint
                         { bfBufReads = S.singleton 3 } }
          checkNoSharedBufferWriters [tWriter, tReader] @?= Right ()

      , testCase "checkNoSharedBufferWriters: two writers on the same buffer is rejected" $ do
          let dummyRG = RuntimeGraph [] []
              tA = Template (TemplateID 0) "first" dummyRG
                   emptyResourceFootprint
                     { rfBuffers = emptyBufferFootprint
                         { bfBufWrites = S.singleton 2 } }
              tB = Template (TemplateID 1) "second" dummyRG
                   emptyResourceFootprint
                     { rfBuffers = emptyBufferFootprint
                         { bfBufWrites = S.singleton 2 } }
          case checkNoSharedBufferWriters [tA, tB] of
            Right () -> assertFailure
              "expected same-buffer BufWrite conflict to be rejected"
            Left err -> do
              assertBool
                ("diagnostic must name buffer 2; got: " <> err)
                ("buffer 2" `isInfixOf` err)
              assertBool
                ("diagnostic must mention 'first'; got: " <> err)
                ("first"   `isInfixOf` err)
              assertBool
                ("diagnostic must mention 'second'; got: " <> err)
                ("second"  `isInfixOf` err)

      , testCase "checkNoSharedBufferWriters: bus 5 / buffer 5 are not aliased" $ do
          -- Regression guard for the disjoint-id-space property:
          -- two templates writing BUS 5 and BUFFER 5 respectively
          -- must not be flagged as a buffer-write conflict.
          let dummyRG = RuntimeGraph [] []
              tBus = Template (TemplateID 0) "bus_writer" dummyRG
                   emptyResourceFootprint
                     { rfBuses = emptyFootprint
                         { bfWrites = S.singleton 5 } }
              tBuf = Template (TemplateID 1) "buf_writer" dummyRG
                   emptyResourceFootprint
                     { rfBuffers = emptyBufferFootprint
                         { bfBufWrites = S.singleton 5 } }
          checkNoSharedBufferWriters [tBus, tBuf] @?= Right ()

      -- §6.C.4 extractor pin. The synthetic-footprint tests above
      -- exercise the precedence rule against hand-built
      -- ResourceFootprints; this one closes the loop by checking
      -- that a real playBufMono SynthGraph actually populates
      -- bfBufReads through the resourceFootprint and the
      -- runtimeNodeResourceFootprint extractors. Without this pin,
      -- a future change that breaks the BufRead path in inferEff
      -- or in the runtime-node extractor would fail silently
      -- (every precedence test currently uses synthetic footprints).

      , testCase "resourceFootprint: playBufMono populates bfBufReads from inferEff" $ do
          let g = runSynth $ do
                s <- playBufMono (Buffer 7) (Param 1.0) (Param 0) (Param 0)
                out 0 s
              ir = case lowerGraph g of
                     Right ir' -> ir'
                     Left err  -> error err
              fp = resourceFootprint ir
          bfBufWrites       (rfBuffers fp) @?= S.empty
          bfBufReads        (rfBuffers fp) @?= S.singleton 7
          bfBufDelayedReads (rfBuffers fp) @?= S.empty
          -- The bus half still records the Out 0 write.
          bfWrites (rfBuses fp) @?= S.singleton 0

      , testCase "runtimeNodeResourceFootprint: KPlayBufMono carries bfBufReads from controls[0]" $ do
          -- After compileTemplateGraph, every region's
          -- rrFootprint should contain the buffer id resolved
          -- from rnControls[0] on each KPlayBufMono node. This
          -- proves the post-IR extractor agrees with the
          -- pre-IR resourceFootprint above.
          let g = runSynth $ do
                s <- playBufMono (Buffer 7) (Param 1.0) (Param 0) (Param 0)
                out 0 s
          tg <- case compileTemplateGraph [("reader", g)] of
                  Right t  -> pure t
                  Left err -> assertFailure err >> error "unreachable"
          let tpl = head (tgTemplates tg)
              regions = rgRuntimeRegions (tplGraph tpl)
              bufReads =
                S.unions
                  [ bfBufReads (rfBuffers (rrFootprint r))
                  | r <- regions ]
          bufReads @?= S.singleton 7
          -- And the template-level aggregate sees the same id.
          bfBufReads (rfBuffers (tplFootprint tpl))
            @?= S.singleton 7
      ]

  , -- Rate propagation: 'inferRate' returns each kind's *floor*; the
    -- post-lowering pass 'propagateRates' lifts a node's rate to the
    -- join of its inputs and that floor. These tests pin the matrix
    -- of floor × input-rate combinations (stateful kinds stay at
    -- SampleRate; stateless transforms inherit; pure-Param subgraphs
    -- collapse to CompileRate).
    --
    -- See Note [Rate inference vs rate propagation] in
    -- "MetaSonic.Bridge.IR".
    testGroup "Rate propagation"
      [ testCase "kind floors: producers SampleRate, transforms CompileRate" $ do
          ksRate (kindSpec KSinOsc)        @?= SampleRate
          ksRate (kindSpec KSawOsc)        @?= SampleRate
          ksRate (kindSpec KNoiseGen)      @?= SampleRate
          ksRate (kindSpec KLPF)           @?= SampleRate
          ksRate (kindSpec KEnv)           @?= SampleRate
          ksRate (kindSpec KBusIn)         @?= SampleRate
          ksRate (kindSpec KBusInDelayed)  @?= SampleRate
          ksRate (kindSpec KGain)          @?= CompileRate
          ksRate (kindSpec KAdd)           @?= CompileRate
          ksRate (kindSpec KOut)           @?= CompileRate
          ksRate (kindSpec KBusOut)        @?= CompileRate

      , testCase "SinOsc: floor wins over Param inputs (still SampleRate)" $ do
          let g = runSynth $ do
                _ <- sinOsc 440.0 0.0
                pure ()
          rateOfFirst KSinOsc g @?= SampleRate

      , testCase "Pure-Param Gain stays at CompileRate" $ do
          -- Both inputs are Param literals (CompileRate); Gain's floor
          -- is CompileRate; the join is CompileRate. A future pass
          -- could fold this away — for now, assert it's at least
          -- annotated correctly.
          let g = runSynth $ do
                _ <- gain (Param 0.5) (Param 0.3)
                pure ()
          rateOfFirst KGain g @?= CompileRate

      , testCase "Gain fed by SinOsc lifts to SampleRate" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                _ <- gain o 0.5
                pure ()
          rateOfFirst KGain g @?= SampleRate

      , testCase "Out inherits its input's rate" $ do
          -- Audio-driven Out → SampleRate.
          let gAudio = runSynth $ do
                o <- sinOsc 440.0 0.0
                out 0 o
          rateOfFirst KOut gAudio @?= SampleRate
          -- Param-driven Out → CompileRate.
          let gParam = runSynth $ out 0 (Param 0.0)
          rateOfFirst KOut gParam @?= CompileRate

      , testCase "Stateful LPF keeps SampleRate even with all-Param inputs" $ do
          -- LPF's biquad delay state cannot be coarsened, so its floor
          -- is SampleRate regardless of input rates.
          let g = runSynth $ do
                _ <- lpf (Param 0.0) (Param 800.0) (Param 0.7)
                pure ()
          rateOfFirst KLPF g @?= SampleRate

      , testCase "Add: CompileRate when both Param, SampleRate when one is audio" $ do
          let gConst = runSynth $ do
                _ <- add (Param 1.0) (Param 2.0)
                pure ()
          rateOfFirst KAdd gConst @?= CompileRate
          let gMix = runSynth $ do
                o <- sinOsc 440.0 0.0
                _ <- add (Param 1.0) o
                pure ()
          rateOfFirst KAdd gMix @?= SampleRate

      , testCase "multi-hop chain: every downstream node lifts to SampleRate" $ do
          -- SinOsc → Gain → Gain → Out: the SampleRate floor at the
          -- source propagates all the way to the sink.
          let g = runSynth $ do
                o   <- sinOsc 440.0 0.0
                g1  <- gain o 0.7
                g2  <- gain g1 0.5
                out 0 g2
          case lowerGraph g of
            Left err -> assertFailure $ "lowerGraph failed: " <> err
            Right ir ->
              let rates = map irRate (giNodes ir)
              in assertEqual
                   "every node along the chain should be SampleRate"
                   (replicate (length rates) SampleRate)
                   rates

      , testCase "disjoint subgraphs: CompileRate and SampleRate coexist" $ do
          -- One subgraph runs on Params only (Gain Param Param); the
          -- other is audio-driven (SinOsc → Out). Expect at least one
          -- of each rate among the lowered nodes.
          let g = runSynth $ do
                _   <- gain (Param 0.5) (Param 0.3)  -- CompileRate cluster
                o   <- sinOsc 440.0 0.0              -- SampleRate
                out 0 o                              -- SampleRate via inherit
          case lowerGraph g of
            Left err -> assertFailure $ "lowerGraph failed: " <> err
            Right ir -> do
              let rates = map irRate (giNodes ir)
              assertBool
                ("expected at least one CompileRate node, got " <> show rates)
                (CompileRate `elem` rates)
              assertBool
                ("expected at least one SampleRate node, got " <> show rates)
                (SampleRate `elem` rates)

      , testCase "BusOut/BusIn through-graph: rates lift to SampleRate" $ do
          -- BusOut floor is CompileRate but its input (SinOsc) is
          -- SampleRate, so the BusOut node ends up SampleRate. BusIn
          -- floor is SampleRate (intrinsic).
          let g = runSynth $ do
                o   <- sinOsc 440.0 0.0
                busOut 5 o
                tap <- busIn 5
                out 0 tap
          rateOfFirst KBusOut g @?= SampleRate
          rateOfFirst KBusIn  g @?= SampleRate

      , testCase "propagateRates is idempotent" $ do
          -- Running propagation twice must yield the same IR as
          -- running it once. This is the post-condition of a
          -- correctly-defined fixed-point lift.
          let g = runSynth $ do
                o  <- sinOsc 440.0 0.0
                g1 <- gain o 0.7
                out 0 g1
          case lowerGraph g of
            Left err -> assertFailure err
            Right ir -> propagateRates (propagateRates ir) @?= ir

      , testCase "Delay: floor SampleRate (stateful per-node ring buffer)" $ do
          -- The delay's floor is SampleRate because its read/write are
          -- per-sample and the buffer carries per-sample history. Even
          -- with all-Param inputs, the floor wins.
          let g = runSynth $ do
                _ <- delayL 0.01 (Param 0.0) (Param 0.005)
                pure ()
          rateOfFirst KDelay g @?= SampleRate

      , testCase "Delay fed by SinOsc: SampleRate (floor and inputs agree)" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                _ <- delayL 0.01 o (Param 0.005)
                pure ()
          rateOfFirst KDelay g @?= SampleRate

      , -- Region-rate absorption: a CompileRate helper (an all-Param
        -- Gain producing a static amplitude) sits adjacent to a
        -- SampleRate path (SinOsc → Gain → Out) and is folded into
        -- the same region instead of forming its own. The dominant
        -- rate (SampleRate) wins for regRate.
        -- See Note [Region rate compatibility] in MetaSonic.Bridge.Compile.
        testCase "CompileRate absorption: helper folds into adjacent SampleRate region" $ do
          let g = runSynth $ do
                s   <- sinOsc 440.0 0.0
                amp <- gain (Param 0.5) (Param 0.3)  -- CompileRate Gain
                sc  <- gain s amp                     -- SampleRate Gain
                out 0 sc
          case lowerGraph g of
            Left err -> assertFailure $ "lowerGraph failed: " <> err
            Right ir -> do
              let rg      = formRegions (giNodes ir)
                  regions = rgRegions rg
                  rates   = map irRate (giNodes ir)
              -- Sanity: rates still mixed at the node level.
              assertBool
                ("expected at least one CompileRate node, got " <> show rates)
                (CompileRate `elem` rates)
              assertBool
                ("expected at least one SampleRate node, got " <> show rates)
                (SampleRate `elem` rates)
              -- Absorption: a single SampleRate region holds them all.
              assertEqual
                "absorption should yield exactly one region"
                1 (length regions)
              case regions of
                [r] -> do
                  regRate r   @?= SampleRate
                  length (regNodes r) @?= length (giNodes ir)
                _   -> assertFailure "unreachable: length checked above"

      , -- Step B-Light: pinned output-use counts on a known graph.
        -- Linear chain SinOsc → Gain → Out: each transform has
        -- exactly one consumer; Out is a sink with no consumers.
        -- See Note [Output-use classification] in MetaSonic.Bridge.Compile.
        testCase "rnOutputUse on a linear SinOsc → Gain → Out chain" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                a <- gain o (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let uses = map rnOutputUse (rgNodes rg)
              length [() | NoOutput      <- uses] @?= 1
              length [() | RegionLocal   <- uses] @?= 2
              length [() | RegionEscapes <- uses] @?= 0
              -- Step-C single-edge fusion gate: every transform has
              -- exactly one consumer; the Out sink has zero.
              [ rnConsumerCount n
                | n <- rgNodes rg, rnKind n /= KOut
                ] @?= [1, 1]
              [ rnConsumerCount n
                | n <- rgNodes rg, rnKind n == KOut
                ] @?= [0]

      , -- Fan-out: a single SinOsc feeds two Gains. Both Gains are
        -- still RegionLocal (no cross-region escape) but the SinOsc's
        -- rnConsumerCount is 2, so it fails the destructive single-
        -- edge fusion gate. This is the case the gate is designed to
        -- catch — without it, fusion would clobber one Gain by
        -- inlining into the other.
        testCase "rnConsumerCount on SinOsc with fan-out to two Gains" $ do
          let g = runSynth $ do
                o  <- sinOsc 440.0 0.0
                g1 <- gain o (Param 0.5)
                g2 <- gain o (Param 0.3)
                out 0 g1
                out 1 g2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let uses = map rnOutputUse (rgNodes rg)
              length [() | NoOutput      <- uses] @?= 2
              length [() | RegionLocal   <- uses] @?= 3
              length [() | RegionEscapes <- uses] @?= 0
              [ rnConsumerCount n
                | n <- rgNodes rg, rnKind n == KSinOsc
                ] @?= [2]
              [ rnConsumerCount n
                | n <- rgNodes rg, rnKind n == KGain
                ] @?= [1, 1]

      , -- Bus routing keeps every transform RegionLocal too: BusOut
        -- and Out are NoOutput sinks; SinOsc's output is consumed by
        -- BusOut in the same region; BusIn's output is consumed by
        -- Out in the same region. The same-bus dataflow doesn't go
        -- through the rnInputs graph (it goes through the server bus
        -- pool), so BusIn has no FromNode consumer beyond Out and
        -- SinOsc has no FromNode consumer beyond BusOut.
        testCase "rnOutputUse on a BusOut → BusIn round-trip" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                busOut 5 o
                v <- busIn 5
                out 0 v
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let uses = map rnOutputUse (rgNodes rg)
              -- 2 sinks (BusOut + Out), 2 producers (SinOsc + BusIn).
              length [() | NoOutput      <- uses] @?= 2
              length [() | RegionLocal   <- uses] @?= 2
              length [() | RegionEscapes <- uses] @?= 0

      , -- Step C invariant: 'compileRuntimeGraph' never sets
        -- 'rnElided'. Only 'fuseRuntimeGraph' (added later in Step
        -- C) flips the bit. This pins the contract that the unfused
        -- compile path is unchanged in observable behavior by
        -- Step B's machinery additions.
        testCase "compileRuntimeGraph leaves rnElided False on every node" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                a <- gain o (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> all (not . rnElided) (rgNodes rg) @?= True

      , -- Step C (c): chain SinOsc → Gain(Param 0.5) → Out, fused.
        -- Expectations:
        --   * rgNodes length is 3 (no node removed).
        --   * Gain has rnElided = True.
        --   * Out's input is RFused (FScaleFrom sinOsc 0 gain 0).
        --   * SinOsc and Out keep rnElided = False.
        -- See Note [Single-edge Gain fusion].
        testCase "fuseRuntimeGraph: linear chain elides Gain, redirects Out" $ do
          -- Uses an 'Env' source rather than any oscillator because
          -- §4.B's growing kernel set claims every contiguous
          -- @{Sin,Saw} → Gain → sink@ shape today, and (per
          -- 'notes/2026-05-08-fusion-strategy.md') is the part of the design
          -- expected to expand. Env is stateful and explicitly
          -- excluded from kernel candidacy in that note, so §4.B
          -- can't claim @Env → Gain → Out@ now or later, and §4.C
          -- gets to do its single-edge Gain elision. The mechanism
          -- under test is unchanged; only the source kind differs.
          let g = runSynth $ do
                o <- env (Param 1.0) 0.0005 0.002 1.0 0.002
                a <- gain o (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              length (rgNodes rg) @?= 3
              let gainNode = head [n | n <- rgNodes rg, rnKind n == KGain]
                  envNode  = head [n | n <- rgNodes rg, rnKind n == KEnv]
                  outNode  = head [n | n <- rgNodes rg, rnKind n == KOut]
              rnElided gainNode @?= True
              rnElided envNode  @?= False
              rnElided outNode  @?= False
              rnInputs outNode @?=
                [ RFused (FScaleFrom (rnIndex envNode) (PortIndex 0)
                                     (rnIndex gainNode) (ControlIndex 0))
                ]

      , -- Audio-modulated Gain ('gain sig modSig') has rnInputs[1] as
        -- RFrom (not RConst), so the shape gate fails and no fusion
        -- happens. This case keeps the Gain dispatched.
        testCase "fuseRuntimeGraph: audio-modulated Gain is left alone" $ do
          let g = runSynth $ do
                sig <- sinOsc 440.0 0.0
                m   <- sinOsc 73.0  0.0
                a   <- gain sig m
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              all (not . rnElided) (rgNodes rg) @?= True
              -- No RFused inputs introduced.
              null [() | n <- rgNodes rg
                       , RFused _ <- rnInputs n
                       ] @?= True

      , -- Fan-out: SinOsc → 2× Gain → 2× Out. Each Gain has a single
        -- consumer (its own Out), so both Gains fuse independently.
        -- The shared SinOsc isn't a Gain candidate, so the chain
        -- walk terminates at SinOsc for both branches and each
        -- fuses as a length-1 'FScaleFrom'.
        testCase "fuseRuntimeGraph: fan-out fuses both Gains independently" $ do
          let g = runSynth $ do
                o  <- sinOsc 440.0 0.0
                g1 <- gain o (Param 0.5)
                g2 <- gain o (Param 0.3)
                out 0 g1
                out 1 g2
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let gains = [n | n <- rgNodes rg, rnKind n == KGain]
                  outs  = [n | n <- rgNodes rg, rnKind n == KOut]
              length gains                          @?= 2
              all rnElided gains                    @?= True
              -- Each Out reads through an RFused.
              [length [() | RFused _ <- rnInputs o] | o <- outs] @?= [1, 1]

      , -- Identity preservation: fusion never reorders, removes, or
        -- renames nodes. rnOriginalID and rnIndex are unchanged
        -- across a (compileRuntimeGraph, compileRuntimeGraphFused)
        -- pair on the same source graph.
        testCase "fuseRuntimeGraph preserves NodeIndex and rnOriginalID" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                a <- gain o (Param 0.5)
                out 0 a
          case (,) <$> (lowerGraph g >>= compileRuntimeGraph)
                   <*> (lowerGraph g >>= compileRuntimeGraphFused) of
            Left err -> assertFailure $ "compile failed: " <> err
            Right (unfused, fused) -> do
              map rnIndex      (rgNodes fused)
                @?= map rnIndex      (rgNodes unfused)
              map rnOriginalID (rgNodes fused)
                @?= map rnOriginalID (rgNodes unfused)
              map rnKind       (rgNodes fused)
                @?= map rnKind       (rgNodes unfused)

      , -- Chain extension: SinOsc → Gain₁(0.5) → Gain₂(0.25) →
        -- Out collapses both scalar Gains into one fused chain on
        -- Out's input. Both Gains are elided; the chain is stored
        -- in source-to-sink order so the resolver applies 0.5
        -- before 0.25 — same float-rounding order as the unfused
        -- chained kernels would.
        testCase "fuseRuntimeGraph: chain of two Gains fuses into FScaleChainFrom" $ do
          let g = runSynth $ do
                o  <- sinOsc 440.0 0.0
                a1 <- gain o  (Param 0.5)
                a2 <- gain a1 (Param 0.25)
                out 0 a2
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              length (rgNodes rg) @?= 4
              let nodes = rgNodes rg
                  sinNode  = head [n | n <- nodes, rnKind n == KSinOsc]
                  gainsExec = [n | n <- nodes, rnKind n == KGain]
                  outNode  = head [n | n <- nodes, rnKind n == KOut]
              length gainsExec @?= 2
              let [gUpstream, gDownstream] = gainsExec
              -- Both Gains are elided; chain ate the whole run.
              rnElided gUpstream   @?= True
              rnElided gDownstream @?= True
              -- Out's input is the chain in source-to-sink order:
              -- SinOsc:0 × gUpstream.c[0] × gDownstream.c[0].
              rnInputs outNode @?=
                [ RFused (FScaleChainFrom (rnIndex sinNode) (PortIndex 0)
                            [ ScaleRef (rnIndex gUpstream)   (ControlIndex 0)
                            , ScaleRef (rnIndex gDownstream) (ControlIndex 0)
                            ])
                ]

      , -- Length-3 chain: SinOsc → G1(0.5) → G2(0.25) → G3(0.125)
        -- → Out. All three Gains elided; chain length 3 in
        -- source-to-sink order.
        testCase "fuseRuntimeGraph: chain of three Gains fuses end-to-end" $ do
          let g = runSynth $ do
                o  <- sinOsc 440.0 0.0
                a1 <- gain o  (Param 0.5)
                a2 <- gain a1 (Param 0.25)
                a3 <- gain a2 (Param 0.125)
                out 0 a3
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes   = rgNodes rg
                  gains   = [n | n <- nodes, rnKind n == KGain]
                  outNode = head [n | n <- nodes, rnKind n == KOut]
              length gains @?= 3
              all rnElided gains @?= True
              case rnInputs outNode of
                [RFused (FScaleChainFrom _ _ scales)] ->
                  length scales @?= 3
                other -> assertFailure $
                  "expected single FScaleChainFrom of length 3, got "
                    <> show other

      , -- Chain stops at audio-modulated Gain. carrier × modulator
        -- (audio-modulated, gate-4 reject) followed by scalar Gain
        -- → Out: only the trailing scalar Gain fuses; the audio-
        -- modulated Gain stays dispatched. Chain length is 1, so
        -- the IR uses FScaleFrom (not FScaleChainFrom) — the chain
        -- terminator is the audio-modulated Gain itself.
        testCase "fuseRuntimeGraph: chain stops at audio-modulated Gain" $ do
          let g = runSynth $ do
                c <- sinOsc 440.0 0.0
                m <- sinOsc  73.0 0.0
                r <- gain c m            -- audio-modulated: not fusable
                a <- gain r (Param 0.5)  -- scalar: fuses
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  gains = [n | n <- nodes, rnKind n == KGain]
              length gains @?= 2
              -- Exactly one Gain elided (the scalar one).
              length [() | n <- gains, rnElided n] @?= 1
              -- Out's input is FScaleFrom (length-1, not chain).
              let outNode = head [n | n <- nodes, rnKind n == KOut]
              case rnInputs outNode of
                [RFused FScaleFrom{}] -> pure ()
                other -> assertFailure $
                  "expected FScaleFrom on Out, got " <> show other

      , -- Mid-chain multi-consumer: a Gain in the middle of what
        -- *would* be a chain has rnConsumerCount > 1 and so fails
        -- the candidate predicate. Chain extension must stop there
        -- and not elide it.
        --
        --   SinOsc → G1(0.5) → { G2(0.25) → Out0,  G3(0.125) → Out1 }
        --
        -- G1 has two consumers (G2 and G3) and is therefore not a
        -- candidate. The two trailing Gains each fuse independently
        -- as length-1 FScaleFrom with G1 as the source — the chain
        -- never grows past G1 because G1 is non-candidate.
        testCase "fuseRuntimeGraph: chain stops at multi-consumer mid-chain Gain" $ do
          let g = runSynth $ do
                o  <- sinOsc 440.0 0.0
                a1 <- gain o (Param 0.5)
                a2 <- gain a1 (Param 0.25)
                a3 <- gain a1 (Param 0.125)
                out 0 a2
                out 1 a3
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  gains = [n | n <- nodes, rnKind n == KGain]
              length gains @?= 3
              -- G1 stays dispatched (consumer count 2). G2 and G3
              -- each fuse as length-1.
              let elidedG = [n | n <- gains, rnElided n]
              length elidedG @?= 2
              -- Both Out nodes carry an RFused FScaleFrom (length-1
              -- chain), not an FScaleChainFrom.
              let outs = [n | n <- nodes, rnKind n == KOut]
              length outs @?= 2
              let isLengthOne (RFused FScaleFrom{}) = True
                  isLengthOne _                     = False
              all isLengthOne (concatMap rnInputs outs) @?= True

      , -- Idempotence: applying the rewrite twice must equal applying
        -- it once. Elided Gains fail the candidate predicate
        -- (rnElided check) on the second pass, so nothing changes.
        testCase "fuseRuntimeGraph is idempotent" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                a <- gain o (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              fuseRuntimeGraph (fuseRuntimeGraph rg) @?= fuseRuntimeGraph rg

      , -- Chain idempotence: a second pass over an already-fused
        -- chain must be a no-op. After the first pass every Gain
        -- in the chain is rnElided (failing gate 4 of the candidate
        -- predicate via 'not (rnElided n)'), and the consumer's
        -- input is RFused (which 'tryFuseInput' ignores since it
        -- only matches RFrom). Pinned separately from the length-1
        -- idempotence test so a regression in chain handling
        -- doesn't masquerade as the single-edge bug.
        testCase "fuseRuntimeGraph is idempotent on chains" $ do
          let g = runSynth $ do
                o  <- sinOsc 440.0 0.0
                a1 <- gain o  (Param 0.5)
                a2 <- gain a1 (Param 0.25)
                a3 <- gain a2 (Param 0.125)
                out 0 a3
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              fuseRuntimeGraph (fuseRuntimeGraph rg) @?= fuseRuntimeGraph rg

      , -- Phase 4.C.2: a single scalar Add with a constant bias on
        -- port 1 elides the Add and rewrites Out's input to
        -- 'FAffineFrom' with one 'AffBias' step. The pure-scale
        -- 'FScaleFrom' / 'FScaleChainFrom' shapes are reserved for
        -- chains that are entirely Gains, so any presence of a bias
        -- step lands in 'FAffineFrom'.
        testCase "fuseRuntimeGraph: scalar Add (bias on port 1) fuses into FAffineFrom" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                b <- add o (Param 0.1)   -- bias on port 1
                out 0 b
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  sinNode = head [n | n <- nodes, rnKind n == KSinOsc]
                  addNode = head [n | n <- nodes, rnKind n == KAdd]
                  outNode = head [n | n <- nodes, rnKind n == KOut]
              rnElided addNode @?= True
              rnInputs outNode @?=
                [ RFused (FAffineFrom (rnIndex sinNode) (PortIndex 0)
                            [ AffBias (rnIndex addNode) (ControlIndex 1) ])
                ]

      , -- Bias on port 0: 'add (Param 0.1) signal' lowers to
        -- @rnInputs == [RConst 0.1, RFrom signal 0]@, signal port
        -- is 1, bias control slot is 0. The candidate predicate
        -- accepts both shapes; the AffBias must record control 0
        -- in this case so the runtime reads the right slot.
        testCase "fuseRuntimeGraph: scalar Add (bias on port 0) fuses with control 0" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                b <- add (Param 0.1) o   -- bias on port 0
                out 0 b
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  sinNode = head [n | n <- nodes, rnKind n == KSinOsc]
                  addNode = head [n | n <- nodes, rnKind n == KAdd]
                  outNode = head [n | n <- nodes, rnKind n == KOut]
              rnElided addNode @?= True
              -- Source signal port from the Add's input[1]; bias
              -- control is slot 0 (where the Param literal landed).
              rnInputs outNode @?=
                [ RFused (FAffineFrom (rnIndex sinNode) (PortIndex 0)
                            [ AffBias (rnIndex addNode) (ControlIndex 0) ])
                ]

      , -- Audio-rate Add (signal + signal) is not a candidate. The
        -- gate enforces "exactly one signal input, the other slot a
        -- constant"; @add c m@ with both audio sources fails it,
        -- exactly like audio-modulated Gain stays dispatched.
        testCase "fuseRuntimeGraph: audio-rate Add stays dispatched" $ do
          let g = runSynth $ do
                c <- sinOsc 440.0 0.0
                m <- sinOsc  73.0 0.0
                s <- add c m            -- audio + audio: not fusable
                out 0 s
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  addNode = head [n | n <- nodes, rnKind n == KAdd]
              rnElided addNode @?= False
              -- No RFused inputs introduced.
              null [() | n <- nodes, RFused _ <- rnInputs n] @?= True

      , -- Composition order 1: SinOsc → Gain(k) → Add(b) → Out
        -- collapses both into one FAffineFrom with [AffScale k,
        -- AffBias b] in source-to-sink order. The resolver applies
        -- src*k first, then +b, mirroring the unfused kernel chain.
        testCase "fuseRuntimeGraph: Gain → Add composes into AffineFrom [scale, bias]" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                a <- gain o (Param 0.5)
                b <- add  a (Param 0.1)
                out 0 b
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  sinNode  = head [n | n <- nodes, rnKind n == KSinOsc]
                  gainNode = head [n | n <- nodes, rnKind n == KGain]
                  addNode  = head [n | n <- nodes, rnKind n == KAdd]
                  outNode  = head [n | n <- nodes, rnKind n == KOut]
              rnElided gainNode @?= True
              rnElided addNode  @?= True
              rnInputs outNode @?=
                [ RFused (FAffineFrom (rnIndex sinNode) (PortIndex 0)
                            [ AffScale (rnIndex gainNode) (ControlIndex 0)
                            , AffBias  (rnIndex addNode)  (ControlIndex 1)
                            ])
                ]

      , -- Composition order 2: SinOsc → Add(b) → Gain(k) → Out
        -- collapses to FAffineFrom [AffBias b, AffScale k]. The
        -- resolver applies +b first, then *k, matching the unfused
        -- chain's float arithmetic. Pinning both orderings catches
        -- any "scales always come before biases" sorting bug.
        testCase "fuseRuntimeGraph: Add → Gain composes into AffineFrom [bias, scale]" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                b <- add  o (Param 0.1)
                a <- gain b (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  sinNode  = head [n | n <- nodes, rnKind n == KSinOsc]
                  gainNode = head [n | n <- nodes, rnKind n == KGain]
                  addNode  = head [n | n <- nodes, rnKind n == KAdd]
                  outNode  = head [n | n <- nodes, rnKind n == KOut]
              rnElided gainNode @?= True
              rnElided addNode  @?= True
              rnInputs outNode @?=
                [ RFused (FAffineFrom (rnIndex sinNode) (PortIndex 0)
                            [ AffBias  (rnIndex addNode)  (ControlIndex 1)
                            , AffScale (rnIndex gainNode) (ControlIndex 0)
                            ])
                ]

      , -- Mid-chain multi-consumer Add: an Add in the middle of
        -- what would be a chain fails gate 3 (rnConsumerCount > 1)
        -- and stays dispatched. The downstream chain segments still
        -- fuse independently.
        testCase "fuseRuntimeGraph: chain stops at multi-consumer mid-chain Add" $ do
          let g = runSynth $ do
                o  <- sinOsc 440.0 0.0
                b  <- add o (Param 0.1)        -- shared by both branches
                g1 <- gain b (Param 0.5)
                g2 <- gain b (Param 0.25)
                out 0 g1
                out 1 g2
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let nodes = rgNodes rg
                  addNode = head [n | n <- nodes, rnKind n == KAdd]
              -- Add stays dispatched (consumer count 2).
              rnElided addNode @?= False
              -- Both Gains elided; both Outs read through FScaleFrom
              -- (length-1 scale-only chain stops at the dispatched Add).
              let gains = [n | n <- nodes, rnKind n == KGain]
              length [() | n <- gains, rnElided n] @?= 2
              let outs = [n | n <- nodes, rnKind n == KOut]
                  isFScaleFrom (RFused FScaleFrom{}) = True
                  isFScaleFrom _                      = False
              all isFScaleFrom (concatMap rnInputs outs) @?= True

      , -- Affine idempotence: a second pass over an already-fused
        -- mixed Gain/Add chain must be a no-op. Same gate-9 check
        -- as the chain-idempotence pin from §4.C.1, but on a chain
        -- that exercises the FAffineFrom path.
        testCase "fuseRuntimeGraph is idempotent on affine chains" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                a <- gain o (Param 0.5)
                b <- add  a (Param 0.1)
                k <- gain b (Param 0.25)
                out 0 k
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              fuseRuntimeGraph (fuseRuntimeGraph rg) @?= fuseRuntimeGraph rg

      , -- Step C precondition: pin Gain's compiled shape so the
        -- single-edge fusion rewrite has something stable to match
        -- against. For 'gain o (Param k)':
        --   * rnInputs[0] is RFrom <o's index> 0 — the audio signal.
        --   * rnInputs[1] is RConst k          — the gain port is
        --     unconnected; the literal flows to the C++ control slot
        --     and the kernel takes its else-branch reading
        --     controls[0]. set_control(gainNode, 0, _) is therefore
        --     observable on the unfused output, which is what makes
        --     the fused form's (gainNode, ControlIndex 0) reference
        --     semantically equivalent.
        --   * rnControls is [k] — connDefault pulls the Param's value
        --     into the single Gain control slot.
        -- See connDefault and ugenView in MetaSonic.Bridge.Source.
        testCase "Gain's compiled IR shape pins Step-C fusion preconditions" $ do
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                a <- gain o (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              case [n | n <- rgNodes rg, rnKind n == KGain] of
                [gn] -> do
                  rnControls gn @?= [0.5]
                  case rnInputs gn of
                    [RFrom _ (PortIndex 0), RConst 0.5] -> pure ()
                    other -> assertFailure $
                      "unexpected rnInputs shape: " <> show other
                gns -> assertFailure $
                  "expected exactly one Gain node, got " <> show (length gns)
      ]

  , -- Phase 4.B region kernel selection. The greedy 'formRegions'
    -- lumps a whole rate-compatible chain into one region;
    -- 'selectRegionKernels' splits it so each matched contiguous
    -- shape becomes its own kernel-tagged region. This test group
    -- pins the IR-level region overlay; the FFI / C++ side is
    -- exercised by the bit-equivalence battery below.
    testGroup "Phase 4.B: selectRegionKernels"
      [ -- 4-node sink-terminal claim. The whole chain
        -- @[SawOsc, LPF, Gain, Out]@ is contiguous, the 4-node
        -- match wins by longest-match priority over the 3-node
        -- 'RSawLpfGain' prefix, and the entire chain becomes one
        -- 'RSawLpfGainOut' region. Pinning this is the structural
        -- evidence that 'findKernelMatch' actually preferred the
        -- longer shape.
        testCase "saw → lpf → gain → out: full region tagged RSawLpfGainOut" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              -- 4-node match wins; the 3-node prefix shape never
              -- gets to claim anything.
              length [() | RSawLpfGainOut <- kernels] @?= 1
              length [() | RSawLpfGain    <- kernels] @?= 0
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RSawLpfGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 4
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KSawOsc, KLPF, KGain, KOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- BusOut as sink terminal. The 4-node 'RSawLpfGainOut'
        -- shape accepts either 'KOut' or 'KBusOut' at the
        -- terminal slot — same reasoning as the 3-node sink
        -- variant. Pins that the kind-sequence assertion still
        -- tags as RSawLpfGainOut and that no buffer-terminal
        -- 'RSawLpfGain' fallback sneaks in.
        testCase "saw → lpf → gain → busOut: full region tagged RSawLpfGainOut" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                busOut 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RSawLpfGainOut <- kernels] @?= 1
              length [() | RSawLpfGain    <- kernels] @?= 0
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RSawLpfGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 4
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KSawOsc, KLPF, KGain, KBusOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- 3-node buffer-terminal claim with a non-sink consumer.
        -- The chain feeds the gain into an 'Add' instead of into
        -- a sink ('KOut' or 'KBusOut'), so the 4-node
        -- 'RSawLpfGainOut' shape's @rnKind out_ ∈ {KOut, KBusOut}@
        -- gate fails. Longest-match falls through to 'RSawLpfGain'
        -- on the 3-node prefix; the Add and Out land in a
        -- trailing 'RNodeLoop' region. Pins that 'RSawLpfGain' is
        -- still alive after longest-match priority redirected the
        -- saw → lpf → gain → out fixture to the 4-node kernel,
        -- and that the test fixture is robust to sink-class
        -- generalizations like @busOut@ joining @out@ as a sink
        -- terminal.
        testCase "saw → lpf → gain → add → out: middle region tagged RSawLpfGain" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)        -- non-sink consumer of gain
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RSawLpfGain    <- kernels] @?= 1
              length [() | RSawLpfGainOut <- kernels] @?= 0
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RSawLpfGain] of
                [r] -> do
                  length (rrNodes r) @?= 3
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KSawOsc, KLPF, KGain]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- §4.C interaction (4-node kernel): when §4.B's 4-node
        -- 'RSawLpfGainOut' claims the chain, §4.C must skip the
        -- Gain. Otherwise scalar Gain fusion would elide it and
        -- the region kernel would have no live gain to read
        -- 'controls[0]' from.
        testCase "fuseRuntimeGraph: defers to region kernel on saw → lpf → gain → out" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              -- The Gain stays dispatched (rnElided = False) and
              -- nobody carries an RFused — §4.B owns it.
              let gainNode = head [n | n <- rgNodes rg, rnKind n == KGain]
              rnElided gainNode @?= False
              null [() | n <- rgNodes rg, RFused _ <- rnInputs n] @?= True

      , -- Negative: audio-modulated gain blocks §4.B (gain port 1
        -- is RFrom, not RConst). The region stays RNodeLoop.
        testCase "near-miss: audio-modulated gain stays RNodeLoop" $ do
          let g = runSynth $ do
                s   <- sawOsc 110.0 0.0
                f   <- lpf s (Param 800.0) (Param 4.0)
                lfo <- sinOsc 6.0 0.0
                a   <- gain f lfo            -- audio-rate gain modulation
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              null [() | RSawLpfGain <- map rrKernel (rgRuntimeRegions rg)]
                @?= True

      , -- Negative: an extra consumer of the LPF intermediate
        -- (lpf has rnConsumerCount > 1) blocks §4.B because the
        -- fused kernel can't keep lpf's output in registers — the
        -- second consumer needs a materialized buffer.
        testCase "near-miss: lpf with multiple consumers stays RNodeLoop" $ do
          let g = runSynth $ do
                s  <- sawOsc 110.0 0.0
                f  <- lpf s (Param 800.0) (Param 4.0)
                a1 <- gain f (Param 0.4)
                a2 <- gain f (Param 0.2)     -- second consumer of lpf
                out 0 a1
                out 1 a2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              null [() | RSawLpfGain <- map rrKernel (rgRuntimeRegions rg)]
                @?= True

      , -- Negative: a saw whose output is also read by something
        -- outside the chain (saw rnConsumerCount > 1) blocks §4.B.
        -- The lpf's freq input here is wired to the saw, which is
        -- a real audio-rate filter sweep but also makes saw a
        -- multi-consumer node — so the fused kernel can't elide
        -- saw's output materialization.
        testCase "near-miss: saw with multiple consumers stays RNodeLoop" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                -- saw feeds lpf signal AND lpf cutoff (consumer count 2)
                f <- lpf s s (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              null [() | RSawLpfGain <- map rrKernel (rgRuntimeRegions rg)]
                @?= True

      , -- 3-node sink-terminal saw kernel: SawOsc → Gain → Out is
        -- the saw counterpart of 'RSinGainOut'. Same single-edge,
        -- scalar-gain rules; same Out-or-BusOut sink class. Pinned
        -- because the previous "near-miss: saw → gain (no LPF)"
        -- test asserted /no/ kernel claimed this shape — that
        -- assertion was the right contract before 'RSawGainOut'
        -- existed and is now exactly inverted.
        testCase "saw → gain → out: middle region tagged RSawGainOut" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                a <- gain s (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RSawGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RSawGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 3
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KSawOsc, KGain, KOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- BusOut as sink terminal for the saw 3-node kernel —
        -- mirrors the parallel test for 'RSinGainOut'. Pins that
        -- 'isSinkTerminal' / 'is_sink_terminal' propagates to the
        -- new kernel's gate.
        testCase "saw → gain → busOut: middle region tagged RSawGainOut" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                a <- gain s (Param 0.4)
                busOut 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RSawGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RSawGainOut] of
                [r] -> do
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KSawOsc, KGain, KBusOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- §4.C deferral on the new kernel: with §4.B claiming the
        -- whole chain, §4.C must skip the Gain. Otherwise scalar
        -- Gain fusion would elide it and 'process_region_saw_gain_out'
        -- would lose its live read of @gain_node.controls[0]@.
        -- Mirrors the SinGainOut deferral test.
        testCase "fuseRuntimeGraph: defers to §4.B kernel on saw → gain → out" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                a <- gain s (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let gainNode = head [n | n <- rgNodes rg, rnKind n == KGain]
              rnElided gainNode @?= False
              null [() | n <- rgNodes rg, RFused _ <- rnInputs n] @?= True

      , -- 3-node sink-terminal noise kernel: NoiseGen → Gain →
        -- Out. Different state class from the oscillator sink
        -- kernels (xorshift PRNG, no audio inputs, no controls
        -- on the producer), but the matcher's structural gates
        -- are identical — only the producer kind changes.
        testCase "noise → gain → out: middle region tagged RNoiseGainOut" $ do
          let g = runSynth $ do
                n <- noiseGen
                a <- gain n (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RNoiseGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RNoiseGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 3
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KNoiseGen, KGain, KOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- BusOut as sink terminal for the noise 3-node kernel —
        -- mirrors the Sin and Saw busOut variants.
        testCase "noise → gain → busOut: middle region tagged RNoiseGainOut" $ do
          let g = runSynth $ do
                n <- noiseGen
                a <- gain n (Param 0.4)
                busOut 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RNoiseGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RNoiseGainOut] of
                [r] -> do
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KNoiseGen, KGain, KBusOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- §4.C deferral on the noise kernel: with §4.B claiming
        -- the chain, §4.C must skip the Gain. Mirrors the Sin /
        -- Saw deferral tests; the kernel's per-block read of
        -- @gain_node.controls[0]@ depends on the gain staying
        -- live in the runtime graph.
        testCase "fuseRuntimeGraph: defers to §4.B kernel on noise → gain → out" $ do
          let g = runSynth $ do
                n <- noiseGen
                a <- gain n (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let gainNode = head [n | n <- rgNodes rg, rnKind n == KGain]
              rnElided gainNode @?= False
              null [() | n <- rgNodes rg, RFused _ <- rnInputs n] @?= True

      , -- 4-node-specific gate: 'matchesSawLpfGainOut' adds
        -- 'rnConsumerCount gain == 1' on top of 'matchesSawLpfGain'.
        -- A graph where the gain feeds two Outs satisfies the
        -- 3-node prefix predicate but fails the 4-node gain-
        -- consumer rule, so longest-match fails over from
        -- 'RSawLpfGainOut' to 'RSawLpfGain'. Pinned because this is
        -- the structural property that justifies keeping both
        -- kernels — the 3-node one materializes the gain's output
        -- buffer for external readers, the 4-node one absorbs the
        -- single Out and skips materialization.
        testCase "fallback: multi-consumer gain falls through from RSawLpfGainOut to RSawLpfGain" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
                out 1 a                    -- second consumer of gain
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RSawLpfGain    <- kernels] @?= 1
              length [() | RSawLpfGainOut <- kernels] @?= 0

      , -- 4-node negative: audio-modulated gain blocks both the
        -- 4-node kernel AND the 3-node fallback (both gates
        -- require 'isScalarGain'), so the whole chain stays
        -- 'RNodeLoop'. Distinct from the 3-node-only audio-mod
        -- near-miss above because it specifically pins the 4-node
        -- shape's behavior on the same blocker.
        testCase "near-miss (4-node): audio-modulated gain stays RNodeLoop" $ do
          let g = runSynth $ do
                s   <- sawOsc 110.0 0.0
                f   <- lpf s (Param 800.0) (Param 4.0)
                lfo <- sinOsc 6.0 0.0
                a   <- gain f lfo            -- audio-rate gain modulation
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RSawLpfGainOut <- kernels] @?= True
              null [() | RSawLpfGain    <- kernels] @?= True

      , -- §4.B BusIn-rooted 4-node sink-terminal claim.
        -- @[BusIn, LPF, Gain, Out]@ matches 'matchesBusInLpfGainOut'
        -- and the whole chain becomes one 'RBusInLpfGainOut' region.
        -- Same longest-match-wins structural property as
        -- 'RSawLpfGainOut' but on the non-oscillator producer axis.
        testCase "busIn → lpf → gain → out: full region tagged RBusInLpfGainOut" $ do
          let g = runSynth $ do
                r <- busIn 7
                f <- lpf r (Param 1500.0) (Param 4.0)
                a <- gain f (Param 0.6)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RBusInLpfGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg
                      , rrKernel r == RBusInLpfGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 4
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KBusIn, KLPF, KGain, KOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got "
                  <> show (length rs)

      , -- BusOut as sink terminal for the BusIn-rooted shape.
        -- Pins that the kind-sequence assertion still tags as
        -- 'RBusInLpfGainOut' regardless of whether the absorbed
        -- terminal is 'KOut' or 'KBusOut'.
        testCase "busIn → lpf → gain → busOut: full region tagged RBusInLpfGainOut" $ do
          let g = runSynth $ do
                r <- busIn 7
                f <- lpf r (Param 1500.0) (Param 4.0)
                a <- gain f (Param 0.6)
                busOut 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RBusInLpfGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg
                      , rrKernel r == RBusInLpfGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 4
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KBusIn, KLPF, KGain, KBusOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got "
                  <> show (length rs)

      , -- Near-miss: BusIn fans out to two consumers. The single-
        -- use internal-edge precondition on the BusIn fails, so
        -- the 4-node match is rejected. Without an LPF-rooted
        -- 3-node fallback (we don't have one), the chain stays
        -- 'RNodeLoop'. Pins that the multi-consumer gate is the
        -- BusIn counterpart of 'matchesSawLpfGainOut's
        -- 'rnConsumerCount saw == 1' rule.
        testCase "near-miss: multi-consumer BusIn blocks RBusInLpfGainOut" $ do
          let g = runSynth $ do
                r  <- busIn 7
                f1 <- lpf r (Param 800.0)  (Param 4.0)
                f2 <- lpf r (Param 2400.0) (Param 4.0)   -- second consumer of busIn
                a1 <- gain f1 (Param 0.4); out 0 a1
                a2 <- gain f2 (Param 0.4); out 1 a2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RBusInLpfGainOut <- kernels] @?= True

      , -- Near-miss: audio-modulated gain in a BusIn-rooted chain.
        -- 'isScalarGain' fails on the gain, so the 4-node kernel
        -- doesn't fire. Mirrors the audio-mod near-miss pinned for
        -- 'RSawLpfGainOut'.
        testCase "near-miss (BusIn): audio-modulated gain stays RNodeLoop" $ do
          let g = runSynth $ do
                r   <- busIn 7
                f   <- lpf r (Param 1500.0) (Param 4.0)
                lfo <- sinOsc 6.0 0.0
                a   <- gain f lfo                    -- audio-rate gain modulation
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RBusInLpfGainOut <- kernels] @?= True

      , -- Near-miss: the chain ends at a non-sink consumer (Add),
        -- so 'isSinkTerminal' on the terminal slot fails and the
        -- 4-node match is rejected. Without an LPF-rooted 3-node
        -- fallback for the BusIn-rooted shape, the chain stays
        -- 'RNodeLoop'. Pins that the sink-class gate distinguishes
        -- 'RBusInLpfGainOut' from a hypothetical "BusIn-rooted
        -- buffer-terminal" kernel.
        testCase "near-miss (BusIn): non-sink terminal stays RNodeLoop" $ do
          let g = runSynth $ do
                r <- busIn 7
                f <- lpf r (Param 1500.0) (Param 4.0)
                a <- gain f (Param 0.6)
                b <- add a (Param 0.0)              -- non-sink consumer
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RBusInLpfGainOut <- kernels] @?= True

      , -- §4.C interaction (BusIn-rooted 4-node kernel): when
        -- §4.B's 'RBusInLpfGainOut' claims the chain, §4.C must
        -- skip the Gain. Otherwise scalar-Gain elision would
        -- eliminate the live control slot the kernel reads
        -- 'controls[0]' from. Mirrors the §4.C-deferral pin for
        -- 'RSawLpfGainOut'.
        testCase "fuseRuntimeGraph: defers to RBusInLpfGainOut on busIn → lpf → gain → out" $ do
          let g = runSynth $ do
                r <- busIn 7
                f <- lpf r (Param 1500.0) (Param 4.0)
                a <- gain f (Param 0.6)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "fused compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RBusInLpfGainOut <- kernels] @?= 1
              -- The Gain is a member of the kernel's region, not
              -- elided by §4.C (otherwise the kernel would have no
              -- live control slot to read 'controls[0]' from).
              let elidedKinds =
                    [rnKind n | n <- rgNodes rg, rnElided n]
              KGain `elem` elidedKinds @?= False

      , -- §4.B Noise-rooted 4-node sink-terminal claim. The noise
        -- counterpart of 'RSawLpfGainOut' / 'RBusInLpfGainOut': same
        -- LPF/Gain/sink pipeline, but the producer is a PRNG-state
        -- generator, not a phase iterator or bus reader. Pins that
        -- 'matchesNoiseLpfGainOut' fires on @[NoiseGen, LPF, Gain,
        -- Out]@ and that the whole chain becomes one region tagged
        -- 'RNoiseLpfGainOut'.
        testCase "noise → lpf → gain → out: full region tagged RNoiseLpfGainOut" $ do
          let g = runSynth $ do
                n <- noiseGen
                f <- lpf n (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RNoiseLpfGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg
                      , rrKernel r == RNoiseLpfGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 4
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KNoiseGen, KLPF, KGain, KOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got "
                  <> show (length rs)

      , -- BusOut as sink terminal for the Noise-rooted shape. Same
        -- bus-kind-agnostic claim the kernel makes on the C++ side.
        testCase "noise → lpf → gain → busOut: full region tagged RNoiseLpfGainOut" $ do
          let g = runSynth $ do
                n <- noiseGen
                f <- lpf n (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                busOut 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RNoiseLpfGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg
                      , rrKernel r == RNoiseLpfGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 4
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KNoiseGen, KLPF, KGain, KBusOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got "
                  <> show (length rs)

      , -- Near-miss: NoiseGen feeds two consumers, breaking the
        -- single-use-edge gate at the head. The 4-node kernel is
        -- rejected; with no Noise-rooted fallback the chain stays
        -- 'RNodeLoop'. Pins that the multi-consumer gate is the
        -- noise counterpart of the saw / busin rule.
        testCase "near-miss: multi-consumer NoiseGen blocks RNoiseLpfGainOut" $ do
          let g = runSynth $ do
                n  <- noiseGen
                f1 <- lpf n (Param 800.0)  (Param 4.0)
                f2 <- lpf n (Param 2400.0) (Param 4.0)   -- second consumer of noise
                a1 <- gain f1 (Param 0.4); out 0 a1
                a2 <- gain f2 (Param 0.4); out 1 a2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RNoiseLpfGainOut <- kernels] @?= True

      , -- Near-miss: LPF feeds two Gains. Same 'rnConsumerCount lpf
        -- == 1' precondition that blocks the saw-rooted variant.
        testCase "near-miss (Noise): multi-consumer LPF blocks RNoiseLpfGainOut" $ do
          let g = runSynth $ do
                n  <- noiseGen
                f  <- lpf n (Param 1000.0) (Param 4.0)
                a1 <- gain f (Param 0.3); out 0 a1
                a2 <- gain f (Param 0.2); out 1 a2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RNoiseLpfGainOut <- kernels] @?= True

      , -- Near-miss: audio-modulated gain in a Noise-rooted chain.
        -- 'isScalarGain' fails on the gain, the 4-node kernel
        -- doesn't fire. Mirrors the audio-mod near-miss pinned for
        -- the saw / busin variants.
        testCase "near-miss (Noise): audio-modulated gain stays RNodeLoop" $ do
          let g = runSynth $ do
                n   <- noiseGen
                f   <- lpf n (Param 1500.0) (Param 4.0)
                lfo <- sinOsc 6.0 0.0
                a   <- gain f lfo                    -- audio-rate gain modulation
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RNoiseLpfGainOut <- kernels] @?= True

      , -- Near-miss: chain ends at a non-sink consumer (Add). The
        -- sink-class gate fails; without a Noise-rooted buffer-
        -- terminal kernel the chain stays 'RNodeLoop'. Mirrors the
        -- non-sink near-miss pinned for the busin variant.
        testCase "near-miss (Noise): non-sink terminal stays RNodeLoop" $ do
          let g = runSynth $ do
                n <- noiseGen
                f <- lpf n (Param 1500.0) (Param 4.0)
                a <- gain f (Param 0.6)
                b <- add a (Param 0.0)              -- non-sink consumer
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              null [() | RNoiseLpfGainOut <- kernels] @?= True

      , -- §4.C interaction (Noise-rooted 4-node kernel): same Gain-
        -- elision deferral as 'RSawLpfGainOut' / 'RBusInLpfGainOut'.
        -- The kernel reads gain 'controls[0]', so §4.C must leave
        -- the Gain in place when the kernel claims the chain.
        testCase "fuseRuntimeGraph: defers to RNoiseLpfGainOut on noise → lpf → gain → out" $ do
          let g = runSynth $ do
                n <- noiseGen
                f <- lpf n (Param 1500.0) (Param 4.0)
                a <- gain f (Param 0.6)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "fused compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RNoiseLpfGainOut <- kernels] @?= 1
              let elidedKinds =
                    [rnKind n | n <- rgNodes rg, rnElided n]
              KGain `elem` elidedKinds @?= False

      , -- Idempotence: a second pass over an already-tagged region
        -- must be a no-op. Pinned because 'selectRegionKernels'
        -- recurses on splits and a regression that re-fires on
        -- already-tagged regions would silently double-walk the
        -- region list.
        testCase "selectRegionKernels is idempotent" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              selectRegionKernels rg @?= rg

      , -- Phase 4.B sink-terminal: SinOsc → Gain → Out is the second
        -- recognized kernel shape. Distinct protocol axis from
        -- 'RSawLpfGain' (which is buffer-terminal): the 'Out' node
        -- lives /inside/ the fused region, so the kernel does the
        -- bus accumulation and §2.E sink-peak update inline rather
        -- than materializing an intermediate buffer.
        testCase "sin → gain → out: middle region tagged RSinGainOut" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              -- Exactly one fused region and it covers the whole
              -- chain (no trailing 'RNodeLoop' region for an
              -- external Out, because the Out is now a kernel
              -- member).
              length [() | RSinGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RSinGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 3
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KSinOsc, KGain, KOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- BusOut as sink terminal. 'RSinGainOut' accepts either
        -- 'KOut' or 'KBusOut' at the terminal slot — both
        -- dispatch to 'process_out' on the C++ side and read the
        -- bus index from @rnControls[0]@, so the kernel body
        -- absorbs them identically. Pins that the Haskell-side
        -- 'isSinkTerminal' gate accepts BusOut and that the
        -- region's kind sequence still tags as RSinGainOut.
        testCase "sin → gain → busOut: middle region tagged RSinGainOut" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                busOut 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let kernels = map rrKernel (rgRuntimeRegions rg)
              length [() | RSinGainOut <- kernels] @?= 1
              case [r | r <- rgRuntimeRegions rg, rrKernel r == RSinGainOut] of
                [r] -> do
                  length (rrNodes r) @?= 3
                  let kinds = [ rnKind n
                              | ix <- rrNodes r
                              , n <- rgNodes rg, rnIndex n == ix ]
                  kinds @?= [KSinOsc, KGain, KBusOut]
                rs -> assertFailure $
                  "expected exactly one fused region, got " <> show (length rs)

      , -- §4.C interaction: §4.B claims this shape /before/ §4.C
        -- runs. Without that claim, §4.C would elide the Gain into
        -- an 'FScaleFrom' on Out's input (the original §4.C
        -- behavior for sin → gain → out). Pinned because the
        -- region kernel needs the Gain's control slot still
        -- addressable, so eliding it would silently break
        -- 'process_region_sin_gain_out''s read of
        -- @gain_node.controls[0]@.
        testCase "fuseRuntimeGraph: defers to §4.B kernel on sin → gain → out" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let gainNode = head [n | n <- rgNodes rg, rnKind n == KGain]
              rnElided gainNode @?= False
              null [() | n <- rgNodes rg, RFused _ <- rnInputs n] @?= True

      , -- Negative: audio-modulated gain blocks the kernel for the
        -- same reason it blocks 'RSawLpfGain' — the per-sample
        -- arithmetic can no longer be folded into the same float
        -- rounding sequence as the unfused chain.
        testCase "near-miss (sin chain): audio-modulated gain stays RNodeLoop" $ do
          let g = runSynth $ do
                s   <- sinOsc 440.0 0.0
                lfo <- sinOsc 6.0 0.0
                a   <- gain s lfo            -- audio-rate gain modulation
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              null [() | RSinGainOut <- map rrKernel (rgRuntimeRegions rg)]
                @?= True

      , -- Negative: a SinOsc with multiple consumers can't be
        -- claimed by the kernel because the second consumer needs
        -- the SinOsc's output materialized, but the kernel keeps
        -- it in registers.
        testCase "near-miss (sin chain): multi-consumer sin stays RNodeLoop" $ do
          let g = runSynth $ do
                s  <- sinOsc 440.0 0.0
                a1 <- gain s (Param 0.5)
                a2 <- gain s (Param 0.3)     -- second consumer of sin
                out 0 a1
                out 1 a2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              null [() | RSinGainOut <- map rrKernel (rgRuntimeRegions rg)]
                @?= True

      , -- Negative: a Gain whose output feeds two Outs has consumer
        -- count 2 — the kernel's "single internal edge" rule
        -- rejects it, exactly the way 'RSawLpfGain' rejects an LPF
        -- with multiple consumers.
        testCase "near-miss (sin chain): multi-consumer gain stays RNodeLoop" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
                out 1 a                       -- second consumer of gain
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg ->
              null [() | RSinGainOut <- map rrKernel (rgRuntimeRegions rg)]
                @?= True

      , -- Multi-match: two independent saw → lpf → gain chains in
        -- one original region must both be tagged in a single
        -- 'selectRegionKernels' pass. The selector recurses on the
        -- suffix after each match, so missing the second chain
        -- would mean an optimization that depends on the loader
        -- accidentally re-running the pass. Idempotence still
        -- holds: a second 'selectRegionKernels' application is a
        -- no-op on the already-tagged result.
        --
        -- Why each chain tags as 'RSawLpfGain' rather than the
        -- longer 'RSawLpfGainOut': the topo sort emits both
        -- sinks at the /end/ of the region, after both
        -- saw/lpf/gain triples. Each gain's sink consumer is
        -- therefore not contiguous with the prefix, so the
        -- 4-node 'RSawLpfGainOut' shape's contiguity gate
        -- (gainIx feeds the next listed member) fails for each
        -- chain and longest-match falls through to the 3-node
        -- 'RSawLpfGain'. 'busOut' vs 'out' is incidental here —
        -- either sink kind produces the same trace because the
        -- topo-order clumping is what breaks contiguity, not the
        -- terminal kind.
        testCase "two chains in one region: both tagged in one pass" $ do
          let g = runSynth $ do
                s1 <- sawOsc 110.0 0.0
                f1 <- lpf s1 (Param 800.0) (Param 4.0)
                a1 <- gain f1 (Param 0.4)
                s2 <- sawOsc 220.0 0.0
                f2 <- lpf s2 (Param 1200.0) (Param 4.0)
                a2 <- gain f2 (Param 0.3)
                busOut 0 a1
                busOut 1 a2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              -- Both chains must come back tagged from one pass.
              let tagged = [ r | r <- rgRuntimeRegions rg
                               , rrKernel r == RSawLpfGain ]
              length tagged @?= 2
              -- Each tagged region must cover exactly its own three
              -- nodes in the canonical [Saw, LPF, Gain] order — no
              -- accidental cross-chain claim.
              let nodeMap = M.fromList
                    [ (rnIndex n, n) | n <- rgNodes rg ]
                  kindsOf r =
                    [ rnKind n
                    | ix <- rrNodes r
                    , Just n <- [M.lookup ix nodeMap] ]
              mapM_ (\r -> do
                        length (rrNodes r) @?= 3
                        kindsOf r @?= [KSawOsc, KLPF, KGain])
                    tagged
              -- Idempotence on the multi-match result: re-running
              -- 'selectRegionKernels' after both chains have already
              -- been claimed must not split or relabel anything.
              selectRegionKernels rg @?= rg
      ]

  , -- Phase 4.E.1 + 4.E.1b: per-region BusFootprint metadata plus
    -- the dependency views consumed by future scheduling work.
    -- 'regionBusPrecedence' is the bus-only edge subgraph;
    -- 'regionStructuralPrecedence' is the cross-region port edges
    -- introduced by 'selectRegionKernels' splits;
    -- 'regionDependencies' is the union — the actual "must
    -- precede" relation. No runtime behavior change in either
    -- slice — 'compileRuntimeGraph' still produces regions in the
    -- same topologically valid order; the tests pin the metadata
    -- only. See Note [Region dependency contract] in
    -- 'MetaSonic.Bridge.Compile' for why both edge classes
    -- matter.
    testGroup "Phase 4.E.1: per-region BusFootprint and dependencies"
      [ -- Single-region baseline: a sin → gain → out chain claims
        -- 'RSinGainOut' as one region. Footprint writes only the
        -- sink bus; no reads of any kind. Both views are empty
        -- for this region (no other region exists, no port edges
        -- to cross, no read sets to intersect against).
        testCase "single-region chain: footprint writes {0}, no reads, empty deps" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              case rgRuntimeRegions rg of
                [r] -> do
                  bfWrites       (rfBuses (rrFootprint r)) @?= S.singleton 0
                  bfReads        (rfBuses (rrFootprint r)) @?= S.empty
                  bfDelayedReads (rfBuses (rrFootprint r)) @?= S.empty
                  regionDependencies rg @?=
                    M.singleton (rrIndex r) S.empty
                rs -> assertFailure $
                  "expected exactly one region, got " <> show (length rs)

      , -- Internal send/return: a sin → busOut 5 producer chain
        -- followed by a busIn 5 → lpf → gain → out 0 consumer
        -- chain. §4.B's longest-match priority claims the consumer
        -- chain as 'RBusInLpfGainOut' and 'selectRegionKernels'
        -- splits the source region into a producer 'RNodeLoop'
        -- region (sin + busOut) and a consumer kernel region.
        --
        -- The footprints must reflect the split: producer writes
        -- bus 5; consumer reads bus 5 and writes bus 0. The
        -- consumer's dependency on the producer is /bus-borne/
        -- here — there's no port edge crossing the region
        -- boundary (the consumer's first node is BusIn, which has
        -- no audio inputs). 'regionBusPrecedence' must capture
        -- the edge; 'regionDependencies' must agree.
        testCase "internal send/return: consumer region depends on producer (bus edge)" $ do
          let g = runSynth $ do
                s <- sinOsc 220.0 0.0
                busOut 5 s
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              -- Identify the two regions by their kernel tags:
              -- producer is RNodeLoop (sin + busOut not a §4.B
              -- shape), consumer is RBusInLpfGainOut.
              let producers = [r | r <- rgRuntimeRegions rg
                                 , rrKernel r == RNodeLoop]
                  consumers = [r | r <- rgRuntimeRegions rg
                                 , rrKernel r == RBusInLpfGainOut]
              case (producers, consumers) of
                ([p], [c]) -> do
                  bfWrites       (rfBuses (rrFootprint p)) @?= S.singleton 5
                  bfReads        (rfBuses (rrFootprint p)) @?= S.empty
                  bfWrites       (rfBuses (rrFootprint c)) @?= S.singleton 0
                  bfReads        (rfBuses (rrFootprint c)) @?= S.singleton 5
                  bfDelayedReads (rfBuses (rrFootprint c)) @?= S.empty

                  let busPrec = regionBusPrecedence rg
                      structPrec = regionStructuralPrecedence rg
                      deps = regionDependencies rg
                  -- Bus edge present.
                  M.findWithDefault S.empty (rrIndex c) busPrec
                    @?= S.singleton (rrIndex p)
                  -- BusIn has no audio inputs, so no port edge
                  -- crosses from producer to consumer.
                  M.findWithDefault S.empty (rrIndex c) structPrec
                    @?= S.empty
                  -- Union (the headline view) carries the bus edge.
                  M.findWithDefault S.empty (rrIndex c) deps
                    @?= S.singleton (rrIndex p)
                  M.findWithDefault S.empty (rrIndex p) deps
                    @?= S.empty
                _ -> assertFailure $
                  "expected one RNodeLoop producer + one RBusInLpfGainOut "
                  <> "consumer, got "
                  <> show (length producers) <> " + "
                  <> show (length consumers)

      , -- §4.E.1b regression: kernel-split structural edges.
        -- @saw → lpf → gain → add → out@ is the canonical case
        -- 'regionBusPrecedence' alone would miss. 'RSawLpfGain'
        -- (buffer-terminal) claims @[Saw, LPF, Gain]@; the
        -- trailing @[Add, Out]@ stays 'RNodeLoop'. The trailing
        -- region reads the materialized gain output through a
        -- port edge (Add's signal input is RFrom Gain). No bus
        -- is involved, so 'regionBusPrecedence' is empty — but
        -- the trailing region absolutely cannot run before
        -- 'RSawLpfGain', and a parallel scheduler that consumed
        -- only the bus view would happily race them.
        --
        -- This is the load-bearing pin for
        -- 'regionStructuralPrecedence' / 'regionDependencies'.
        -- See Note [Region dependency contract].
        testCase "kernel-split chain: structural port edge across region boundary" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)        -- non-sink consumer of Gain;
                                              -- blocks RSawLpfGainOut
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions = rgRuntimeRegions rg
                  bufs    = [r | r <- regions, rrKernel r == RSawLpfGain]
                  tails   = [r | r <- regions, rrKernel r == RNodeLoop]
              case (bufs, tails) of
                ([buf], [tail_]) -> do
                  -- Footprints: producer writes nothing (gain
                  -- materializes a buffer, not a bus); consumer
                  -- writes bus 0 via Out, reads no bus.
                  bfWrites       (rfBuses (rrFootprint buf))   @?= S.empty
                  bfReads        (rfBuses (rrFootprint buf))   @?= S.empty
                  bfWrites       (rfBuses (rrFootprint tail_)) @?= S.singleton 0
                  bfReads        (rfBuses (rrFootprint tail_)) @?= S.empty

                  -- Bus view alone misses the dependency (no bus
                  -- writes / reads intersect).
                  let busPrec = regionBusPrecedence rg
                  M.findWithDefault S.empty (rrIndex tail_) busPrec
                    @?= S.empty

                  -- Structural view catches it: Add (in tail
                  -- region) has RFrom pointing into the buffer
                  -- region.
                  let structPrec = regionStructuralPrecedence rg
                  M.findWithDefault S.empty (rrIndex tail_) structPrec
                    @?= S.singleton (rrIndex buf)

                  -- Headline: the union carries the structural
                  -- edge. Anyone consulting 'regionDependencies'
                  -- sees the dependency that 'regionBusPrecedence'
                  -- alone would miss.
                  let deps = regionDependencies rg
                  M.findWithDefault S.empty (rrIndex tail_) deps
                    @?= S.singleton (rrIndex buf)
                  M.findWithDefault S.empty (rrIndex buf) deps
                    @?= S.empty
                _ -> assertFailure $
                  "expected one RSawLpfGain region + one RNodeLoop tail, got "
                  <> show (length bufs) <> " + " <> show (length tails)

      , -- BusInDelayed must NOT induce precedence. The graph has
        -- a producer chain that writes bus 5 (claimed as
        -- 'RSinGainOut' via BusOut) and a delayed-reader chain
        -- (busInDelayed 5 → gain → out) that reads bus 5
        -- /delayed/ rather than live. The producer region's
        -- footprint has writes={5}; the reader region's footprint
        -- has delayedReads={5} and writes={0}. Both
        -- 'regionBusPrecedence' (delayed reads excluded by rule)
        -- and 'regionStructuralPrecedence' (BusInDelayed has no
        -- audio inputs, so no port edge) report no edge — and
        -- therefore 'regionDependencies' must be empty.
        testCase "BusInDelayed reader does not induce a dependency edge" $ do
          let g = runSynth $ do
                s1 <- sinOsc 220.0 0.0
                g1 <- gain s1 (Param 0.3)
                busOut 5 g1                        -- producer: §4.B claims RSinGainOut via BusOut
                d  <- busInDelayed 5
                g2 <- gain d (Param 0.4)
                out 0 g2                           -- reader: 3-node, no §4.B kernel for KBusInDelayed
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions   = rgRuntimeRegions rg
                  producers = [r | r <- regions, rrKernel r == RSinGainOut]
                  readers   = [r | r <- regions, rrKernel r == RNodeLoop]
              case (producers, readers) of
                ([p], [r]) -> do
                  bfWrites       (rfBuses (rrFootprint p)) @?= S.singleton 5
                  bfReads        (rfBuses (rrFootprint p)) @?= S.empty
                  bfDelayedReads (rfBuses (rrFootprint p)) @?= S.empty

                  bfWrites       (rfBuses (rrFootprint r)) @?= S.singleton 0
                  bfReads        (rfBuses (rrFootprint r)) @?= S.empty
                  bfDelayedReads (rfBuses (rrFootprint r)) @?= S.singleton 5

                  -- Headline assertion: no edge in any view.
                  let busPrec    = regionBusPrecedence rg
                      structPrec = regionStructuralPrecedence rg
                      deps       = regionDependencies rg
                  M.findWithDefault S.empty (rrIndex r) busPrec    @?= S.empty
                  M.findWithDefault S.empty (rrIndex r) structPrec @?= S.empty
                  M.findWithDefault S.empty (rrIndex r) deps       @?= S.empty
                  M.findWithDefault S.empty (rrIndex p) deps       @?= S.empty
                _ -> assertFailure $
                  "expected one RSinGainOut producer + one RNodeLoop "
                  <> "reader, got "
                  <> show (length producers) <> " + "
                  <> show (length readers)

      , -- Independent regions must have disjoint footprints and no
        -- precedence edges between them. Two parallel sin → gain
        -- → out chains writing different sink buses both claim
        -- 'RSinGainOut' but neither reads any bus and neither
        -- consumes the other's output — so every dependency view
        -- is empty everywhere.
        testCase "independent regions have disjoint footprints + no deps" $ do
          let g = runSynth $ do
                s1 <- sinOsc 220.0 0.0
                a1 <- gain s1 (Param 0.4)
                out 0 a1
                s2 <- sinOsc 440.0 0.0
                a2 <- gain s2 (Param 0.4)
                out 1 a2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions = rgRuntimeRegions rg
              length [r | r <- regions, rrKernel r == RSinGainOut] @?= 2
              -- Each kernel region writes exactly one bus; the
              -- two written buses are disjoint.
              let writes = [bfWrites (rfBuses (rrFootprint r)) | r <- regions]
              S.unions writes @?= S.fromList [0, 1]
              -- Every dependency view is empty for every region.
              let deps = regionDependencies rg
              all (S.null . snd) (M.toList deps) @?= True

      , -- Multi-template send/return: each template compiles to
        -- its own RuntimeGraph through 'compileTemplateGraph',
        -- and the per-region BusFootprint must be populated
        -- through that pipeline (not just through the
        -- single-graph 'compileRuntimeGraph' direct path).
        --
        -- The voice template's region claims RSinGainOut via
        -- BusOut and writes bus 5; the fx template's region
        -- claims RBusInLpfGainOut and reads bus 5 / writes bus 0.
        -- Intra-template dependencies are empty within each
        -- (single-region per template; cross-template ordering is
        -- handled by 'compileTemplateGraph', not by the
        -- per-region view).
        testCase "multi-template send/return: per-region footprints survive compileTemplateGraph" $ do
          let voice = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                busOut 5 a
              fx = runSynth $ do
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.6)
                out 0 a

          tg <- case compileTemplateGraph
                       [("voice", voice), ("fx", fx)] of
            Right t  -> pure t
            Left err -> assertFailure err >> error "unreachable"

          let voiceTpl = head [t | t <- tgTemplates tg, tplName t == "voice"]
              fxTpl    = head [t | t <- tgTemplates tg, tplName t == "fx"]
              voiceRg  = tplGraph voiceTpl
              fxRg     = tplGraph fxTpl

          -- Voice side: one region claiming RSinGainOut, footprint
          -- writes bus 5.
          case rgRuntimeRegions voiceRg of
            [r] -> do
              rrKernel r @?= RSinGainOut
              bfWrites (rfBuses (rrFootprint r)) @?= S.singleton 5
              bfReads  (rfBuses (rrFootprint r)) @?= S.empty
              regionDependencies voiceRg
                @?= M.singleton (rrIndex r) S.empty
            rs -> assertFailure $
              "voice template: expected one region, got "
              <> show (length rs)

          -- Fx side: one region claiming RBusInLpfGainOut,
          -- footprint reads bus 5 and writes bus 0.
          case rgRuntimeRegions fxRg of
            [r] -> do
              rrKernel r @?= RBusInLpfGainOut
              bfWrites (rfBuses (rrFootprint r)) @?= S.singleton 0
              bfReads  (rfBuses (rrFootprint r)) @?= S.singleton 5
              regionDependencies fxRg
                @?= M.singleton (rrIndex r) S.empty
            rs -> assertFailure $
              "fx template: expected one region, got "
              <> show (length rs)

      , -- §4.E.1c barrier predicate at the NodeKind level. The
        -- three live-bus kinds (KBusIn / KOut / KBusOut) each
        -- carry a runtime-redirectable bus index in
        -- 'rnControls[0]', so any region containing them is a
        -- scheduler barrier. KBusInDelayed is excluded — its
        -- read is from the previous block's snapshot, which is
        -- deterministic regardless of intra-block scheduling
        -- order.
        --
        -- This pins the kind-level contract directly so the
        -- graph-level tests below can rely on it for shape-
        -- specific cases without re-arguing the policy.
        testCase "isLiveBusKind: exhaustively {KBusIn, KOut, KBusOut}; everything else no" $ do
          -- Enumerate every 'NodeKind' so the assertion proves the
          -- exact membership of the live-bus set, not just spot-
          -- checks. A new kind added to 'Types.hs' that is
          -- accidentally classified as live-bus (or accidentally
          -- excluded from it) fails this test the next time the
          -- suite runs.
          --
          -- 'NodeKind' has no 'Ord', so the comparison is on lists
          -- in declaration ('Enum') order rather than sets.
          let live = [k | k <- [minBound .. maxBound :: NodeKind]
                        , isLiveBusKind k]
          -- Expected list is also in declaration order, which
          -- happens to match the enum: KOut < KBusOut < KBusIn.
          live @?= [KOut, KBusOut, KBusIn]

      , -- A simple sin → gain → out chain has KOut in its
        -- single region, so 'regionHasLiveBus' must say True —
        -- the region is a barrier. (Effectively every chain
        -- ending in Out / BusOut is a barrier under the policy.)
        testCase "regionHasLiveBus: chain with KOut is a barrier" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              case rgRuntimeRegions rg of
                [r] -> regionHasLiveBus rg r @?= True
                rs -> assertFailure $
                  "expected exactly one region, got " <> show (length rs)

      , -- §4.E.1c × kernel-split: in the canonical
        -- @saw → lpf → gain → add → out@ split, the
        -- 'RSawLpfGain' buffer region has /no/ live-bus node and
        -- is therefore /not/ a barrier — its dependency is
        -- structural (the trailing region reads its gain output
        -- via a port edge, see the §4.E.1b test above), but the
        -- region itself can in principle be moved by a
        -- non-barrier-aware scheduler so long as it precedes the
        -- consumer. The trailing 'RNodeLoop' region carrying
        -- @[Add, Out]@ /is/ a barrier (via KOut) and stays in
        -- compile-decreed order regardless of dependency
        -- analysis.
        --
        -- Pins the discrimination: barrier-ness tracks live-bus
        -- membership only, not dependency-graph reach.
        testCase "regionHasLiveBus: kernel-split — buffer region not a barrier, sink region is" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions = rgRuntimeRegions rg
                  bufs    = [r | r <- regions, rrKernel r == RSawLpfGain]
                  tails   = [r | r <- regions, rrKernel r == RNodeLoop]
              case (bufs, tails) of
                ([buf], [tail_]) -> do
                  regionHasLiveBus rg buf   @?= False
                  regionHasLiveBus rg tail_ @?= True
                _ -> assertFailure $
                  "expected one RSawLpfGain region + one RNodeLoop "
                  <> "tail, got " <> show (length bufs)
                  <> " + " <> show (length tails)

      , -- Internal send/return: both regions contain live-bus
        -- nodes (producer has KBusOut, consumer has KBusIn and
        -- KOut), so both are barriers. The dependency between
        -- them ('regionBusPrecedence' edge) is incidental for the
        -- barrier predicate — barrier-ness is per-region,
        -- independent of whether there's an inter-region edge.
        testCase "regionHasLiveBus: send/return — both regions are barriers" $ do
          let g = runSynth $ do
                s <- sinOsc 220.0 0.0
                busOut 5 s
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions = rgRuntimeRegions rg
              all (regionHasLiveBus rg) regions @?= True
      ]

  , -- Phase 4.E.2a: pure single-thread region scheduler planner.
    -- 'regionSchedule' encodes the contract a future scheduler
    -- consumes — barrier regions (live-bus) execute in
    -- compile-decreed 'rrIndex' order; non-barrier regions are
    -- topologically scheduled within each barrier-delimited
    -- segment using 'regionDependencies' with 'rrIndex' as the
    -- stable tie-breaker. No runtime change in this slice.
    --
    -- Today's 'compileRuntimeGraph' produces a topologically
    -- valid 'rrIndex' sequence, so 'regionSchedule' returns
    -- 'rrIndex' order verbatim. The tests pin /that property/
    -- across the relevant graph shapes, so a future change that
    -- accidentally introduces a real reorder is caught here
    -- before §4.E.2b lands and starts depending on the contract
    -- for actual concurrency.
    testGroup "Phase 4.E.2a: regionSchedule planner"
      [ -- Single-region baseline: only one region, schedule must
        -- be its singleton index.
        testCase "single-region chain: schedule is [0]" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> regionSchedule rg @?= Right [RegionIndex 0]

      , -- Internal send/return: producer (KBusOut) and consumer
        -- (RBusInLpfGainOut, contains KBusIn + KOut) are both
        -- barriers, anchored at their compile-decreed positions.
        -- Schedule equals 'rrIndex' order; segmentByBarrier sees
        -- two singleton barrier slots and no free segment.
        testCase "send/return barriers: both regions barriers, schedule = rrIndex order" $ do
          let g = runSynth $ do
                s <- sinOsc 220.0 0.0
                busOut 5 s
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions  = rgRuntimeRegions rg
                  segments = segmentByBarrier rg
              -- Both regions are barriers under §4.E.1c.
              all (regionHasLiveBus rg) regions @?= True
              length segments @?= 2
              -- Both segments are 'Barrier' (no free runs between
              -- them). Pattern match inline rather than using a
              -- helper to keep the assertion self-explanatory.
              let isBarrier seg = case seg of
                    Barrier _ -> True
                    _         -> False
              all isBarrier segments @?= True
              regionSchedule rg @?= Right (map rrIndex regions)

      , -- Kernel-split structural-edge case: 'RSawLpfGain'
        -- buffer region (no live-bus, free) precedes the
        -- trailing 'RNodeLoop' tail (KOut, barrier). The
        -- structural cross-region edge (Add reads Gain across
        -- the region boundary) is part of 'regionDependencies',
        -- but the planner doesn't need to reorder anything —
        -- 'rrIndex' order is already topologically valid.
        --
        -- Pins: a free region preceding a barrier ends up in a
        -- one-element free segment, then the barrier. The barrier
        -- doesn't get folded into the free segment.
        testCase "kernel-split: free buffer region precedes barrier tail" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions = rgRuntimeRegions rg
                  bufs    = [r | r <- regions, rrKernel r == RSawLpfGain]
                  tails   = [r | r <- regions, rrKernel r == RNodeLoop]
              case (bufs, tails) of
                ([buf], [tail_]) -> do
                  -- Free region is not a barrier, tail is.
                  regionHasLiveBus rg buf   @?= False
                  regionHasLiveBus rg tail_ @?= True
                  -- segmentByBarrier emits free segment, then
                  -- barrier — same number of slices as regions
                  -- since the free segment carries one region.
                  segmentByBarrier rg @?= [ FreeSegment [buf]
                                          , Barrier tail_
                                          ]
                  -- Schedule equals rrIndex order.
                  regionSchedule rg @?= Right [rrIndex buf, rrIndex tail_]
                _ -> assertFailure $
                  "expected one RSawLpfGain region + one RNodeLoop "
                  <> "tail, got " <> show (length bufs)
                  <> " + " <> show (length tails)

      , -- BusInDelayed reader: the delayed read does not
        -- contribute to 'regionDependencies' (and so doesn't
        -- create a precedence edge between producer and reader).
        -- Both regions in this graph contain live-bus nodes
        -- (producer has KBusOut; reader has KOut), so both are
        -- barriers and the schedule is 'rrIndex' order. Pins
        -- that delayed-only readers don't somehow short-circuit
        -- the barrier classification.
        testCase "BusInDelayed: schedule is rrIndex order, both barriers" $ do
          let g = runSynth $ do
                s1 <- sinOsc 220.0 0.0
                g1 <- gain s1 (Param 0.3)
                busOut 5 g1
                d  <- busInDelayed 5
                g2 <- gain d (Param 0.4)
                out 0 g2
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions = rgRuntimeRegions rg
              all (regionHasLiveBus rg) regions @?= True
              regionSchedule rg @?= Right (map rrIndex regions)

      , -- Independent non-barrier reordering: a graph with /two/
        -- 'RSawLpfGain' free regions adjacent in 'rrIndex' order,
        -- both feeding the same trailing 'RNodeLoop' barrier
        -- (Add + Out). The free regions land in a single free
        -- segment; the planner topologically sorts them with
        -- stable 'rrIndex' tie-breaking. Since the two free
        -- regions are independent (neither depends on the
        -- other), the stable rrIndex order is the natural
        -- output.
        --
        -- This is the headline test for stable-rrIndex
        -- reordering: the segment has more than one non-barrier
        -- region, the topo-sort actually has a choice, and the
        -- choice is the rrIndex order.
        testCase "independent free regions: stable rrIndex order in single segment" $ do
          let g = runSynth $ do
                s1 <- sawOsc 110.0 0.0
                f1 <- lpf s1 (Param 800.0)  (Param 4.0)
                g1 <- gain f1 (Param 0.4)
                s2 <- sawOsc 220.0 0.0
                f2 <- lpf s2 (Param 1200.0) (Param 4.0)
                g2 <- gain f2 (Param 0.4)
                summed <- add g1 g2
                out 0 summed
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let regions = rgRuntimeRegions rg
                  buffers = [r | r <- regions, rrKernel r == RSawLpfGain]
                  tails   = [r | r <- regions, rrKernel r == RNodeLoop]
              case (buffers, tails) of
                ([b1, b2], [tail_]) -> do
                  -- Both buffer regions are free; the tail is a
                  -- barrier (KOut).
                  regionHasLiveBus rg b1    @?= False
                  regionHasLiveBus rg b2    @?= False
                  regionHasLiveBus rg tail_ @?= True
                  -- The free segment groups both buffer regions;
                  -- the barrier follows.
                  segmentByBarrier rg
                    @?= [ FreeSegment [b1, b2], Barrier tail_ ]
                  -- Schedule emits both free regions in rrIndex
                  -- order, then the barrier.
                  regionSchedule rg
                    @?= Right [ rrIndex b1, rrIndex b2, rrIndex tail_ ]
                _ -> assertFailure $
                  "expected two RSawLpfGain regions + one RNodeLoop "
                  <> "tail, got "
                  <> show (length buffers) <> " + "
                  <> show (length tails)

      , -- Multi-template send/return: each template's 'RuntimeGraph'
        -- carries its own one-region schedule. The voice template
        -- is a barrier (RSinGainOut via BusOut), the fx template is
        -- a barrier (RBusInLpfGainOut). Pins that the planner runs
        -- correctly through 'compileTemplateGraph' as well as the
        -- single-graph 'compileRuntimeGraph' direct path.
        testCase "multi-template: per-template schedule = [0] for each one-region template" $ do
          let voice = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                busOut 5 a
              fx = runSynth $ do
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.6)
                out 0 a

          tg <- case compileTemplateGraph
                       [("voice", voice), ("fx", fx)] of
            Right t  -> pure t
            Left err -> assertFailure err >> error "unreachable"

          let voiceTpl = head [t | t <- tgTemplates tg, tplName t == "voice"]
              fxTpl    = head [t | t <- tgTemplates tg, tplName t == "fx"]

          regionSchedule (tplGraph voiceTpl) @?= Right [RegionIndex 0]
          regionSchedule (tplGraph fxTpl)    @?= Right [RegionIndex 0]

      , -- Fail-loud planner, list-order contract:
        -- 'rgRuntimeRegions' must be dense ascending by 'rrIndex'
        -- from 0. 'segmentByBarrier' walks the list in /list/
        -- order and 'topoSortStable' uses list order as the
        -- stable tie-breaker, so the documented "barriers stay in
        -- rrIndex order, free regions tie-break by rrIndex"
        -- contract only holds when the list /is/ rrIndex order.
        --
        -- Reversing the kernel-split region list produces a
        -- non-ascending sequence; the planner must reject it
        -- before scheduling.
        testCase "rejects non-ascending rgRuntimeRegions order" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              let bad = rg { rgRuntimeRegions =
                               reverse (rgRuntimeRegions rg) }
              case regionSchedule bad of
                Left msg ->
                  assertBool
                    ("expected mention of dense ascending in: "
                     <> msg)
                    ("dense" `isInfixOf` msg)
                Right ixs ->
                  assertFailure $
                    "regionSchedule should have rejected the "
                    <> "reversed graph; got " <> show ixs

      , -- Fail-loud planner, duplicate-index variant: hand-build
        -- a 'rgRuntimeRegions' with the same 'rrIndex' twice.
        -- This exercises the dense-ascending check on a malformed
        -- list that's not just a reversal — duplicates and gaps
        -- should also be rejected.
        testCase "rejects duplicate rrIndex in rgRuntimeRegions" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> case rgRuntimeRegions rg of
              [r] -> do
                let bad = rg { rgRuntimeRegions = [r, r] }
                case regionSchedule bad of
                  Left msg ->
                    assertBool
                      ("expected dense-ascending diagnostic in: "
                       <> msg)
                      ("dense" `isInfixOf` msg)
                  Right ixs ->
                    assertFailure $
                      "regionSchedule should have rejected the "
                      <> "duplicate-index graph; got " <> show ixs
              rs -> assertFailure $
                "expected a single region, got "
                <> show (length rs)
      ]

  , -- Phase 4.E.2b: loaders register regions through the schedule.
    --
    -- These tests pin the loader-side contract — the four loaders
    -- ('loadRuntimeGraph', 'loadRuntimeGraphFused', 'loadTemplateGraph',
    -- 'loadTemplateGraphFused') each register regions on the C++
    -- side via 'scheduledRuntimeRegions', not the raw 'rgRuntimeRegions'
    -- list. Today the planner is the identity over 'rrIndex' order on
    -- well-formed compile output, so the two are equal: equality here
    -- /is/ the bit-equivalence claim. A future change that breaks
    -- the planner identity (or the dense-ascending invariant) is
    -- caught by 'regionSchedule' before any C++ mutation, not by
    -- silent reorder at the runtime.
    --
    -- We don't compare against rendered audio because the existing
    -- render-equivalence suite (loadTemplateGraph: cross-template
    -- send/return, BusOut/BusIn round-trip, etc.) already covers
    -- end-to-end equivalence; these tests pin the precise loader
    -- contract.
    testGroup "Phase 4.E.2b: loaders consume scheduledRuntimeRegions"
      [ -- Single-template, unfused: same input as 'loadRuntimeGraph'
        -- exercises end-to-end. Confirm scheduled order matches
        -- rgRuntimeRegions order (planner identity property).
        testCase "loadRuntimeGraph: scheduled order = rgRuntimeRegions" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> case scheduledRuntimeRegions rg of
              Left err -> assertFailure $
                "scheduledRuntimeRegions failed: " <> err
              Right scheduled ->
                map rrIndex scheduled @?= map rrIndex (rgRuntimeRegions rg)

      , -- Single-template, fused: same input shape as the canonical
        -- fused-render tests; confirm scheduled order matches.
        testCase "loadRuntimeGraphFused: scheduled order = rgRuntimeRegions" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                b <- add a (Param 0.0)
                out 0 b
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> case scheduledRuntimeRegions rg of
              Left err -> assertFailure $
                "scheduledRuntimeRegions failed: " <> err
              Right scheduled ->
                map rrIndex scheduled @?= map rrIndex (rgRuntimeRegions rg)

      , -- Multi-template, unfused: per-template schedule equals
        -- per-template rgRuntimeRegions order.
        testCase "loadTemplateGraph: per-template scheduled order = rgRuntimeRegions" $ do
          let voice = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                busOut 5 a
              fx = runSynth $ do
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.6)
                out 0 a
          case compileTemplateGraph [("voice", voice), ("fx", fx)] of
            Left err -> assertFailure err
            Right tg ->
              -- For every template, scheduled order matches raw.
              mapM_ (\tpl ->
                case scheduledRuntimeRegions (tplGraph tpl) of
                  Left err -> assertFailure $
                    "template " <> show (tplName tpl)
                    <> ": scheduledRuntimeRegions failed: " <> err
                  Right scheduled ->
                    map rrIndex scheduled @?=
                      map rrIndex (rgRuntimeRegions (tplGraph tpl)))
                (tgTemplates tg)

      , -- Multi-template, fused: same as above but through the
        -- fused compile path so rg may carry RFused / rnElided.
        testCase "loadTemplateGraphFused: per-template scheduled order = rgRuntimeRegions" $ do
          let voice = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                busOut 5 a
              fx = runSynth $ do
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.6)
                b <- add a (Param 0.0)
                out 0 b
          case compileTemplateGraphFused
                  [("voice", voice), ("fx", fx)] of
            Left err -> assertFailure err
            Right tg ->
              mapM_ (\tpl ->
                case scheduledRuntimeRegions (tplGraph tpl) of
                  Left err -> assertFailure $
                    "template " <> show (tplName tpl)
                    <> ": scheduledRuntimeRegions failed: " <> err
                  Right scheduled ->
                    map rrIndex scheduled @?=
                      map rrIndex (rgRuntimeRegions (tplGraph tpl)))
                (tgTemplates tg)

      , -- §4.E.2b loader-preservation contract: a failed schedule
        -- must not disturb the currently loaded graph. Compute the
        -- schedule first, fail before 'c_rt_graph_clear', leave
        -- the previous graph fully renderable.
        --
        -- Procedure: load a good graph, snapshot bus 0 after one
        -- block. Construct a malformed graph (reverse the region
        -- list — trips the dense-ascending check). 'try' to load
        -- it; expect 'Left'. Render another block on the same
        -- handle and confirm it is non-silent and at a similar
        -- peak level. (We can't compare sample-for-sample because
        -- the oscillator phase has advanced; the right invariant
        -- is "same audible signal, just one block later".)
        testCase "loadRuntimeGraph: failed schedule preserves previous graph" $ do
          let nframes, sizeOfFloat :: Int
              nframes     = 256
              sizeOfFloat = 4
              -- Two-region graph: an 'RSawLpfGain' buffer feeds an
              -- 'RNodeLoop' tail. Reversing 'rgRuntimeRegions'
              -- produces a non-ascending list that the planner
              -- must reject.
              good = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)
                out 0 b
          rt <- case lowerGraph good >>= compileRuntimeGraph of
            Right r  -> pure r
            Left err -> assertFailure err >> error "unreachable"
          -- Sanity: the chosen graph has at least two regions, so
          -- the reversal is observable.
          assertBool
            "expected good graph to have at least two regions"
            (length (rgRuntimeRegions rt) >= 2)
          let bad = rt { rgRuntimeRegions =
                           reverse (rgRuntimeRegions rt) }
          withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
            loadRuntimeGraph handle rt
            c_rt_graph_process handle (fromIntegral nframes)
            before <-
              allocaBytes (nframes * sizeOfFloat) $ \buf -> do
                _ <- c_rt_graph_read_bus handle 0
                       (fromIntegral nframes) (castPtr buf)
                cs <- peekArray nframes (buf :: PtrCFloat)
                pure (map (\(CFloat x) -> x) cs)

            -- Attempt the bad load; must fail before clear.
            let attempt :: IO (Either IOError ())
                attempt = try $ loadRuntimeGraph handle bad
            result <- attempt
            case result of
              Right () ->
                assertFailure $
                  "loadRuntimeGraph should have rejected the "
                  <> "malformed graph"
              Left e ->
                assertBool
                  ("expected dense-ordering diagnostic in: "
                   <> show e)
                  ("dense" `isInfixOf` show e)

            -- The previously loaded graph must still produce the
            -- same audio. Render another block and compare.
            c_rt_graph_process handle (fromIntegral nframes)
            after <-
              allocaBytes (nframes * sizeOfFloat) $ \buf -> do
                _ <- c_rt_graph_read_bus handle 0
                       (fromIntegral nframes) (castPtr buf)
                cs <- peekArray nframes (buf :: PtrCFloat)
                pure (map (\(CFloat x) -> x) cs)

            -- 'before' is block 0 and 'after' is block 1 of the
            -- /same/ continuous oscillator. Pinning that both
            -- blocks render non-silent audio at a similar level
            -- shows the graph survived the failed load — a
            -- half-cleared state would produce silence or
            -- diverge in level. We don't compare sample-for-sample
            -- because the oscillator phase advances between
            -- blocks (which is the correct behavior).
            let peakBefore = maximum (map abs before)
                peakAfter  = maximum (map abs after)
            assertBool ("peak before > 0, got " <> show peakBefore)
                       (peakBefore > 0.05)
            assertBool ("peak after > 0, got " <> show peakAfter)
                       (peakAfter > 0.05)
            assertBool
              ("peaks should be in same ballpark; before="
               <> show peakBefore <> " after=" <> show peakAfter)
              (abs (peakBefore - peakAfter) < 0.5 * peakBefore)
      ]

  , -- Phase 4.E.2c (parallel-readiness survey): descriptive
    -- 'regionScheduleStats' counts. Read-only summary used by
    -- '--fusion-survey' to answer "do graphs have wide non-barrier
    -- work?" before any worker-pool design lands.
    testGroup "Phase 4.E.2c: regionScheduleStats descriptive counts"
      [ -- Single-region all-barrier graph: one barrier, no free.
        testCase "single-region (sin -> out): 1 barrier, 0 free, max widths 0" $ do
          let g = runSynth $ do
                s <- sinOsc 440.0 0.0
                a <- gain s (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> case regionScheduleStats rg of
              Left err -> assertFailure $ "stats failed: " <> err
              Right s ->
                s @?= RegionScheduleStats
                  { rssTotal               = 1
                  , rssBarriers            = 1
                  , rssFree                = 0
                  , rssFreeSegments        = 0
                  , rssMaxFreeSegmentWidth = 0
                  , rssMaxFreeLayerWidth   = 0
                  , rssSharedWriteHazards  = 0
                  , rssMaxRunnableLayerWidth
                                           = 0
                  , rssMaxReductionLayerWidth
                                           = 0
                  }

      , -- Kernel-split: free buffer + barrier tail.
        testCase "saw -> lpf -> gain -> add -> out: 1 free + 1 barrier, max widths 1" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                b <- add a (Param 0.0)
                out 0 b
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> case regionScheduleStats rg of
              Left err -> assertFailure $ "stats failed: " <> err
              Right s ->
                s @?= RegionScheduleStats
                  { rssTotal               = 2
                  , rssBarriers            = 1
                  , rssFree                = 1
                  , rssFreeSegments        = 1
                  , rssMaxFreeSegmentWidth = 1
                  , rssMaxFreeLayerWidth   = 1
                  , rssSharedWriteHazards  = 0
                  , rssMaxRunnableLayerWidth
                                           = 1
                  , rssMaxReductionLayerWidth
                                           = 0
                  }

      , -- Headline parallelism case: two independent free buffers
        -- in one segment. Width = 2 at both segment and layer
        -- level (regions are independent → one layer of size 2).
        testCase "two independent buffers + shared tail: free width 2 at layer 0" $ do
          let g = runSynth $ do
                s1 <- sawOsc 110.0 0.0
                f1 <- lpf s1 (Param 800.0)  (Param 4.0)
                g1 <- gain f1 (Param 0.4)
                s2 <- sawOsc 220.0 0.0
                f2 <- lpf s2 (Param 1200.0) (Param 4.0)
                g2 <- gain f2 (Param 0.4)
                summed <- add g1 g2
                out 0 summed
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              case regionScheduleStats rg of
                Left err -> assertFailure $ "stats failed: " <> err
                Right s ->
                  s @?= RegionScheduleStats
                    { rssTotal               = 3
                    , rssBarriers            = 1
                    , rssFree                = 2
                    , rssFreeSegments        = 1
                    , rssMaxFreeSegmentWidth = 2
                    , rssMaxFreeLayerWidth   = 2
                    , rssSharedWriteHazards  = 0
                    , rssMaxRunnableLayerWidth
                                             = 2
                    , rssMaxReductionLayerWidth
                                             = 0
                    }
              layeredRegionSchedule rg @?=
                Right
                  [ ScheduleFreeLayer FreeLayer
                      { flRegions = [RegionIndex 0, RegionIndex 1]
                      , flSharedWriteHazards = []
                      }
                  , ScheduleBarrier (RegionIndex 2)
                  ]

      , -- Aggregation: empty + s = s, and (a + b) sums counts and
        -- maxes widths.
        testCase "addScheduleStats: counts add, widths max" $ do
          let a = RegionScheduleStats 3 1 2 1 2 2 0 2 0
              b = RegionScheduleStats 5 4 1 1 1 1 1 1 1
          addScheduleStats emptyScheduleStats a @?= a
          addScheduleStats a emptyScheduleStats @?= a
          addScheduleStats a b @?=
            RegionScheduleStats
              { rssTotal               = 8
              , rssBarriers            = 5
              , rssFree                = 3
              , rssFreeSegments        = 2
              , rssMaxFreeSegmentWidth = 2
              , rssMaxFreeLayerWidth   = 2
              , rssSharedWriteHazards  = 1
              , rssMaxRunnableLayerWidth
                                       = 2
              , rssMaxReductionLayerWidth
                                       = 1
              }

      , -- Cross-template width: a chain ensemble (voice → fx via
        -- shared bus) has 'tssMaxTemplateLayerWidth' = 1, even
        -- though the per-template aggregate sums two regions.
        testCase "templateScheduleStats: chain ensemble has layer width 1" $ do
          let voice = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                busOut 5 a
              fx = runSynth $ do
                r <- busIn 5
                f <- lpf r (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.6)
                out 0 a
          case compileTemplateGraph [("voice", voice), ("fx", fx)] of
            Left err -> assertFailure err
            Right tg -> case templateScheduleStats tg of
              Left err -> assertFailure $ "stats failed: " <> err
              Right s -> do
                tssTemplateCount         s @?= 2
                tssMaxTemplateLayerWidth s @?= 1
                tssSharedWriteHazards    s @?= 0
                tssMaxTemplateRunnableWidth s @?= 1
                tssMaxTemplateReductionWidth s @?= 0
                rssTotal    (tssAggregate s) @?= 2
                rssBarriers (tssAggregate s) @?= 2

      , -- Two independent voices writing different buses have no
        -- precedence on each other and no shared-write hazard, so
        -- the full layer-0 width is runnable without reduction.
        testCase "templateScheduleStats: disjoint writers are runnable width 2" $ do
          let left = runSynth $ do
                s <- sawOsc 110.0 0.0
                a <- gain s (Param 0.3)
                out 0 a
              right = runSynth $ do
                s <- sawOsc 220.0 0.0
                a <- gain s (Param 0.3)
                out 1 a
          case compileTemplateGraph [("left", left), ("right", right)] of
            Left err -> assertFailure err
            Right tg -> case templateScheduleStats tg of
              Left err -> assertFailure $ "stats failed: " <> err
              Right s -> do
                tssTemplateCount              s @?= 2
                tssMaxTemplateLayerWidth      s @?= 2
                tssSharedWriteHazards         s @?= 0
                tssMaxTemplateRunnableWidth   s @?= 2
                tssMaxTemplateReductionWidth  s @?= 0

      , -- Two independent voices feeding one fx: voices have no
        -- precedence on each other (both write the same bus,
        -- neither reads from the other), so layer 0 = {voice-l,
        -- voice-r}, layer 1 = {fx}. Max template precedence
        -- width = 2. Because the two voices also share bus 7,
        -- the full layer is reduction-needed width, not runnable
        -- width.
        testCase "templateScheduleStats: two voices + one fx → layer width 2" $ do
          let voiceL = runSynth $ do
                s <- sawOsc 110.0 0.0
                a <- gain s (Param 0.3)
                busOut 7 a
              voiceR = runSynth $ do
                s <- sawOsc 220.0 0.0
                a <- gain s (Param 0.3)
                busOut 7 a
              fx = runSynth $ do
                r <- busIn 7
                f <- lpf r (Param 1200.0) (Param 0.7)
                a <- gain f (Param 0.6)
                out 0 a
          case compileTemplateGraph
                  [ ("voice-l", voiceL)
                  , ("voice-r", voiceR)
                  , ("fx",      fx)
                  ] of
            Left err -> assertFailure err
            Right tg -> case templateScheduleStats tg of
              Left err -> assertFailure $ "stats failed: " <> err
              Right s -> do
                tssTemplateCount              s @?= 3
                tssMaxTemplateLayerWidth      s @?= 2
                tssSharedWriteHazards         s @?= 1
                tssMaxTemplateRunnableWidth   s @?= 1
                tssMaxTemplateReductionWidth  s @?= 2
      ]

  , testGroup "Phase 4.D.1: rnRate carries IR-propagated rate"
      [ -- The runtime graph must preserve every IR node's
        -- propagated 'irRate' on the corresponding 'rnRate'. This
        -- is the load-bearing pin for §4.D.1: the descriptive
        -- view's whole job is to keep IR rate inference
        -- observable through the runtime boundary, so any drift
        -- between the two would silently break the survey's
        -- distribution counts and make rate-shaped optimization
        -- decisions unsound.
        testCase "rnRate matches irRate for every node (mixed osc + transform)" $ do
          let g = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                out 0 a
          ir <- case lowerGraph g of
            Right x  -> pure x
            Left err -> assertFailure ("lowerGraph failed: " <> err)
                          >> error "unreachable"
          rt <- case compileRuntimeGraph ir of
            Right x  -> pure x
            Left err -> assertFailure ("compile failed: " <> err)
                          >> error "unreachable"
          let irByID =
                M.fromList [(irNodeID n, irRate n) | n <- giNodes ir]
              checkOne n = case M.lookup (rnOriginalID n) irByID of
                Just r ->
                  assertEqual ("rnRate vs irRate for " <> show (rnIndex n))
                              r (rnRate n)
                Nothing ->
                  assertFailure $ "missing IR rate for "
                               <> show (rnOriginalID n)
          mapM_ checkOne (rgNodes rt)

      , -- Pure-literal subgraph: 'KOut' has a 'CompileRate' kind
        -- floor, its only input is a 'Literal' (also 'CompileRate'),
        -- and propagation joins to 'CompileRate'. This is the
        -- "stays low where possible" pin — any future regression
        -- that always lifts to 'SampleRate' would fire it.
        testCase "constant-only graph (out (Param 0.0)) stays at CompileRate" $ do
          let g = runSynth (out 0 (Param 0.0))
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let rates = map rnRate (rgNodes rt)
              assertBool ("expected all CompileRate, got " <> show rates)
                         (all (== CompileRate) rates)

      , -- Oscillator chain: the 'KSinOsc' floor is 'SampleRate',
        -- and propagation lifts every downstream node to match.
        -- This is the dual of the constant-only test: when an
        -- audio producer is in the graph, the join must reach
        -- every reachable consumer.
        testCase "oscillator chain lifts every downstream node to SampleRate" $ do
          let g = runSynth $ do
                s <- sinOsc 220.0 0.0
                a <- gain s (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let kindRates =
                    [(rnKind n, rnRate n) | n <- rgNodes rt]
              assertEqual "kind/rate pairs"
                [(KSinOsc, SampleRate)
                ,(KGain,   SampleRate)
                ,(KOut,    SampleRate)
                ]
                kindRates

      , -- Region rate consistency: for every region produced by
        -- 'compileRuntimeGraph', the region's 'rrRate' must equal
        -- the max of its members' 'rnRate'. 'formRegions' already
        -- computes 'regRate' as the join over members at the IR
        -- level; this test pins that the runtime's per-node and
        -- per-region rate views stay in agreement after lowering,
        -- so the descriptive survey can't end up reporting a
        -- region rate that no member node actually claims.
        testCase "every rrRate equals max of member rnRates" $ do
          let g = runSynth $ do
                s <- sawOsc 110.0 0.0
                f <- lpf s (Param 800.0) (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let nodeMap =
                    M.fromList [(rnIndex n, rnRate n) | n <- rgNodes rt]
                  memberRate ix =
                    M.findWithDefault CompileRate ix nodeMap
              sequence_
                [ assertEqual
                    ("region " <> show (rrIndex r) <> " rrRate vs join")
                    (maximum (CompileRate : map memberRate (rrNodes r)))
                    (rrRate r)
                | r <- rgRuntimeRegions rt
                ]

      , -- Bucket-count integrity: a per-rate histogram of all
        -- runtime nodes must sum to the node count exactly. The
        -- survey footer divides 'rdSample' by this total to
        -- compute @S%@; if the bucket counts and the node count
        -- could ever disagree (double-counting, missing rate
        -- value, off-by-one), the headline percentage would be
        -- wrong. Walking 'rgNodes' once and binning by 'rnRate'
        -- here mirrors what 'rateDistribution' does in the survey
        -- driver.
        testCase "rate-bucket counts sum to total node count" $ do
          let g = runSynth $ do
                s1 <- sinOsc 220.0 0.0; a1 <- gain s1 (Param 0.3); out 0 a1
                s2 <- sawOsc 110.0 0.0; a2 <- gain s2 (Param 0.3); out 1 a2
                n  <- noiseGen;         a3 <- gain n  (Param 0.1); out 0 a3
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let nodes = rgNodes rt
                  total = length nodes
                  countAt r = length (filter ((== r) . rnRate) nodes)
                  c = countAt CompileRate
                  i = countAt InitRate
                  b = countAt BlockRate
                  s = countAt SampleRate
              assertEqual "bucket sum vs total" total (c + i + b + s)
              -- Sanity: this graph is osc/noise dominated, so
              -- every node must end up at SampleRate.
              assertEqual "all nodes SampleRate on osc-only graph"
                          total s
      ]

  , testGroup "Phase 4.D.2: portInfo metadata"
      [ -- Totality: for every 'NodeKind', 'portInfo' must return
        -- 'Just' on every port in @[0 .. ksAudioArity - 1]@ and
        -- 'Nothing' on the next index past that range. This is the
        -- drift guard between 'kindSpec' (which the §4.B / §4.D
        -- code paths already trust) and the new per-port table.
        -- Without it, adding an audio input to a 'UGen' constructor
        -- could leave 'portInfo' stale and silently drop edges
        -- from the §4.D.2 edge-rate survey.
        testCase "portInfo is total over the declared audio-input range" $
          sequence_
            [ do
                let arity = ksAudioArity (kindSpec k)
                sequence_
                  [ assertBool
                      (show k <> " port " <> show i
                       <> " should have a PortInfo entry")
                      (case portInfo k (PortIndex i) of
                         Just _  -> True
                         Nothing -> False)
                  | i <- [0 .. arity - 1]
                  ]
                assertEqual
                  (show k <> " port " <> show arity
                   <> " (one past the declared arity) must be Nothing")
                  Nothing
                  (portInfo k (PortIndex arity))
            | k <- [minBound .. maxBound :: NodeKind]
            ]

      , -- Pin the load-bearing classifications. These three
        -- entries are the survey's whole reason to exist:
        --   * Filter freq / q are block-latched (sample 0 only).
        --   * Oscillator phase is init-only (never resolved per
        --     block).
        --   * Gain.amount is sample-accurate (counter-example for
        --     the handoff-doc claim that "scalar gain amount is a
        --     block-latch opportunity" — it is not, when wired).
        -- Any drift in these specific rows would invalidate the
        -- §4.D.2 opportunity number directly, so they're pinned
        -- by name rather than by enumeration.
        testCase "filter freq/q are PortBlockLatched, named freq/q" $ do
          portInfo KLPF (PortIndex 1)
            @?= Just (PortInfo PortBlockLatched "freq")
          portInfo KLPF (PortIndex 2)
            @?= Just (PortInfo PortBlockLatched "q")
          portInfo KHPF (PortIndex 1)
            @?= Just (PortInfo PortBlockLatched "freq")
          portInfo KBPF (PortIndex 2)
            @?= Just (PortInfo PortBlockLatched "q")
          portInfo KNotch (PortIndex 1)
            @?= Just (PortInfo PortBlockLatched "freq")

      , -- Phase ports are 'PortIgnored', not 'PortInitOnly': the
        -- C++ kernels never resolve port 1 in the audio loop, so a
        -- wired 'RFrom' source is silently dropped (the kernel
        -- takes the initial phase from 'rnControls[1]' at
        -- construction). This distinction matters for the
        -- §4.D.2 opportunity count — 'PortIgnored' edges are
        -- excluded because there is no consumption to demote.
        testCase "oscillator phase ports are PortIgnored, named phase" $ do
          portInfo KSinOsc   (PortIndex 1)
            @?= Just (PortInfo PortIgnored "phase")
          portInfo KSawOsc   (PortIndex 1)
            @?= Just (PortInfo PortIgnored "phase")
          portInfo KTriOsc   (PortIndex 1)
            @?= Just (PortInfo PortIgnored "phase")
          portInfo KPulseOsc (PortIndex 1)
            @?= Just (PortInfo PortIgnored "phase")

      , testCase "Gain.amount is PortSampleAccurate (not block-latched)" $ do
          portInfo KGain (PortIndex 1)
            @?= Just (PortInfo PortSampleAccurate "amount")
          -- Spot-check sibling sample-accurate rows so a future
          -- change that flips Gain.amount accidentally also
          -- flips at least one of these.
          portInfo KPulseOsc (PortIndex 2)
            @?= Just (PortInfo PortSampleAccurate "width")
          portInfo KDelay   (PortIndex 1)
            @?= Just (PortInfo PortSampleAccurate "time")
          portInfo KSmooth  (PortIndex 0)
            @?= Just (PortInfo PortSampleAccurate "target")

      , testCase "kinds with no audio inputs return Nothing on every port" $
          sequence_
            [ assertEqual
                (show k <> " port 0 should be Nothing")
                Nothing
                (portInfo k (PortIndex 0))
            | k <- [KNoiseGen, KBusIn, KBusInDelayed]
            ]

      , -- Producer-grouped headline (§4.D.2 'opportunity' count).
        -- An LFO that feeds /both/ LPF.freq (PortBlockLatched) and
        -- Gain.amount (PortSampleAccurate) is /not/ an opportunity:
        -- it must remain sample-rate to serve its sample-accurate
        -- consumer, even though one of its edges lands in a
        -- block-latched bucket. Counting edges instead of producers
        -- would over-report this case — 1 producer node would show
        -- as 2 opportunity edges.
        testCase "sampleRateOpportunityProducers: shared LFO is NOT an opportunity" $ do
          let g = runSynth $ do
                lfo <- sinOsc 4.0 0.0
                s   <- sawOsc 110.0 0.0
                f   <- lpf s lfo (Param 4.0)   -- LFO → lpf.freq (block-latched)
                a   <- gain f lfo              -- LFO → gain.amount (sample-acc.)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let ops = sampleRateOpportunityProducers rt
              assertBool
                ("LFO with mixed-policy consumers must not be flagged "
                 <> "as an opportunity, got: " <> show ops)
                (KSinOsc `notElem` ops)

      , -- Counter-pin to the shared-LFO test: a sample-rate
        -- producer whose /every/ active consumer is non-sample-
        -- accurate (here, an LFO feeding only LPF.freq) does
        -- qualify as an opportunity.
        testCase "sampleRateOpportunityProducers: LFO → LPF.freq alone IS an opportunity" $ do
          let g = runSynth $ do
                lfo <- sinOsc 4.0 0.0
                s   <- sawOsc 110.0 0.0
                f   <- lpf s lfo (Param 4.0)
                a   <- gain f (Param 0.4)      -- gain.amount is constant
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let ops = sampleRateOpportunityProducers rt
              assertBool
                ("LFO with only block-latched consumer must be "
                 <> "flagged, got: " <> show ops)
                (KSinOsc `elem` ops)

      , -- Phase-port edges must not inflate the opportunity count.
        -- An LFO wired to the phase port of a sin oscillator is
        -- silently dropped by the runtime (PortIgnored), so the
        -- LFO has /no/ active consumers in this graph and is not
        -- an opportunity — even though "the LFO has only non-
        -- sample-accurate consumers" looks superficially true.
        testCase "sampleRateOpportunityProducers: PortIgnored consumers don't qualify" $ do
          let g = runSynth $ do
                lfo <- sinOsc 4.0 0.0
                s   <- sinOsc 220.0 lfo        -- LFO → sin.phase (PortIgnored)
                a   <- gain s (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let ops = sampleRateOpportunityProducers rt
              -- The LFO has only an ignored consumer (sin.phase);
              -- the carrier sin has only sample-accurate consumers
              -- (gain.sig); neither qualifies.
              assertEqual
                ("expected no opportunity producers in "
                 <> "phase-mod-only graph, got: " <> show ops)
                [] ops

      , -- Integration of 'edgeRateBuckets' with 'portInfo'. An
        -- Env-driven LPF cutoff is the canonical §4.D.2
        -- opportunity edge: the 'KEnv' source has 'rnRate =
        -- SampleRate' (kind floor), and 'KLPF' port 1 has
        -- consumption policy 'PortBlockLatched'. The bucket lookup
        -- must produce exactly one such edge with the expected
        -- producer kind and example string. Catches drift where a
        -- future change to either the kind floors, 'propagateRates',
        -- the unfused-graph contract of 'compileRuntimeGraph', or
        -- the 'portInfo' table would silently re-classify the edge.
        testCase "edgeRateBuckets: Env → LPF.freq lands in (SampleRate, PortBlockLatched)" $ do
          let g = runSynth $ do
                e <- env (Param 1.0) 0.005 0.05 0.7 0.5
                n <- noiseGen
                f <- lpf n e (Param 4.0)
                a <- gain f (Param 0.4)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraph of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rt -> do
              let buckets = edgeRateBuckets rt
                  key     = (SampleRate, PortBlockLatched)
              case M.lookup key buckets of
                Nothing ->
                  assertFailure $
                    "expected a bucket at " <> show key
                    <> ", got " <> show (M.keys buckets)
                Just b -> do
                  -- Exactly one Env → LPF.freq edge.
                  erbEdgeCount b @?= 1
                  -- Producer kind = Env.
                  KEnv `elem` erbProducerKinds b @?= True
                  -- Example string ends with the LPF.freq
                  -- destination so survey output is legible.
                  case erbExample b of
                    Just s ->
                      assertBool
                        ("example should mention LPF.freq, got: " <> s)
                        ("KLPF.freq" `isInfixOf` s)
                    Nothing ->
                      assertFailure "bucket missing example"
      ]

  , testCase "kindTag is injective" $
      let ks = [minBound .. maxBound :: NodeKind]
          ts = map kindTag ks
      in assertEqual
           "two NodeKinds share a kindTag — C++ dispatch will collide"
           (length ks)
           (length (nub ts))
  ]

-- | Source-level UGen → NodeKind. Used by the kind-multiset
-- preservation property.
ugenKind :: UGen -> NodeKind
ugenKind = \case
  SinOsc{}        -> KSinOsc
  SawOsc{}        -> KSawOsc
  PulseOsc{}      -> KPulseOsc
  TriOsc{}        -> KTriOsc
  NoiseGen        -> KNoiseGen
  LPF{}           -> KLPF
  HPF{}           -> KHPF
  BPF{}           -> KBPF
  Notch{}         -> KNotch
  Gain{}          -> KGain
  Add{}           -> KAdd
  Env{}           -> KEnv
  Out{}           -> KOut
  BusOut{}        -> KBusOut
  BusIn{}         -> KBusIn
  BusInDelayed{}  -> KBusInDelayed
  Delay{}         -> KDelay
  Smooth{}        -> KSmooth

-- The empty graph: no nodes at all.
emptyGraph_ :: SynthGraph
emptyGraph_ = runSynth (pure ())

-- An Out node fed by a constant — no audio source. Useful as a
-- degenerate case that should still compile (the runtime treats
-- unconnected Out as silence).
silentOutGraph :: SynthGraph
silentOutGraph = runSynth $ out 0 (Param 0)

-- Two completely independent subgraphs: SinOsc 440 → Out 0,
-- and SinOsc 660 → Out 1. No shared nodes.
disconnectedGraph :: SynthGraph
disconnectedGraph = runSynth $ do
  o1 <- sinOsc 440.0 0.0
  out 0 o1
  o2 <- sinOsc 660.0 0.0
  out 1 o2

-- A hand-built graph that references a non-existent NodeID. The DSL
-- alone cannot construct one; we use the raw Map constructor.
missingDepGraph :: SynthGraph
missingDepGraph = SynthGraph $ M.singleton (NodeID 0) NodeSpec
  { nsID   = NodeID 0
  , nsName = "out"
  , nsUgen = Out 0 (Audio (NodeID 99) (PortIndex 0))
  , nsMigrationKey = Nothing
  }

-- A hand-built graph with a 0 -> 1 -> 0 cycle.
cycleGraph :: SynthGraph
cycleGraph = SynthGraph $ M.fromList
  [ ( NodeID 0
    , NodeSpec (NodeID 0) "gain-a"
        (Gain (Audio (NodeID 1) (PortIndex 0)) (Param 0.5))
        Nothing )
  , ( NodeID 1
    , NodeSpec (NodeID 1) "gain-b"
        (Gain (Audio (NodeID 0) (PortIndex 0)) (Param 0.5))
        Nothing )
  ]

-- | The propagated 'irRate' of the first node of the given kind in
-- the lowered IR. The rate-propagation unit tests use this to assert
-- per-kind rate outcomes after 'lowerGraph' (which runs
-- 'propagateRates' as part of its pipeline). Errors loudly when the
-- graph fails to lower or doesn't contain a node of that kind, so
-- a misspelled test setup surfaces as a clear test failure rather
-- than a silent wrong rate.
rateOfFirst :: NodeKind -> SynthGraph -> Rate
rateOfFirst k g = case lowerGraph g of
  Left err -> error $ "rateOfFirst: lowerGraph failed: " <> err
  Right ir -> case [ irRate n | n <- giNodes ir, irKind n == k ] of
    (r : _) -> r
    []      -> error $ "rateOfFirst: no node of kind " <> show k <> " in graph"

assertDenseIndices :: RuntimeGraph -> Assertion
assertDenseIndices rt =
  let n   = length (rgNodes rt)
      idx = [ i | RuntimeNode { rnIndex = NodeIndex i } <- rgNodes rt ]
  in idx @?= [0 .. n - 1]

assertTopoOrder :: RuntimeGraph -> Assertion
assertTopoOrder rt =
  mapM_ checkNode (rgNodes rt)
  where
    checkNode node =
      let NodeIndex here = rnIndex node
      in mapM_ (checkInput here) (rnInputs node)

    checkInput here = \case
      RFrom (NodeIndex src) _ ->
        assertBool
          ("input src=" <> show src <> " is not earlier than dst=" <> show here)
          (src < here)
      RConst _ -> pure ()

------------------------------------------------------------
-- Property tests
------------------------------------------------------------

properties :: TestTree
properties = testGroup "Properties"
  [ QC.testProperty "compileRuntimeGraph: indices are [0..n-1]" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propDenseIndices

  , QC.testProperty "compileRuntimeGraph: every RFrom is in [0, n) and earlier" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propTopoOrder

  , QC.testProperty "lowerGraph preserves node count" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propPreservesCount

  , QC.testProperty "validateAndSort succeeds on well-formed graphs" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propValidates

  , QC.testProperty "ugenView arities match kindSpec for every UGen" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propUgenViewMatchesSpec

  , QC.testProperty "compileRuntimeGraph is deterministic" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propDeterministic

  , QC.testProperty "every source NodeID appears once as rnOriginalID" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propBijection

  , QC.testProperty "kind multiset preserved from source to runtime" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propKindCounts

  , QC.testProperty "Out-spec count preserved as KOut node count" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propOutCount

  , QC.testProperty "dependencies of every UGen point at existing nodes" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propDepsExist

  , QC.testProperty "regions partition the IR nodes" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionPartition

  , QC.testProperty "rgNodeMap and regNodes agree" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionNodeMapConsistent

  , QC.testProperty "region IDs are unique" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionIDsUnique

  , QC.testProperty "region deps refer only to existing regions, no self-edges" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionDepsWellFormed

  , QC.testProperty "every region's rate is compatible with its member nodes" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionRateCompatible

  , QC.testProperty "RuntimeGraph region overlay round-trips formRegions" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRuntimeRegionsRoundTrip

  , QC.testProperty "RuntimeGraph regions partition node indices contiguously" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRuntimeRegionsContiguous

  , QC.testProperty "rnOutputUse classification matches consumer-region membership" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propOutputUseConsistent

  , QC.testProperty "rnConsumerCount matches direct FromNode references" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propConsumerCountConsistent

  , QC.testProperty "every BusOut precedes every same-bus BusIn in the schedule" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propBusOrdering

  , -- Rate propagation: see Note [Rate inference vs rate propagation]
    -- in "MetaSonic.Bridge.IR" for the algorithm. These properties pin
    -- the three structural invariants of the lift:
    --
    --   1. each node's rate is at least its kind's floor
    --   2. each node's rate is at least every input's rate
    --   3. running the lift twice is the same as running it once
    --
    -- (1) is the kind-floor guarantee. (2) is the join law of the
    -- lattice — the whole point of propagation. (3) is idempotence:
    -- the lift reaches a fixed point in one pass.
    QC.testProperty "every node's irRate ≥ kind floor (post-propagation)" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRateAtLeastFloor

  , QC.testProperty "every node's irRate ≥ max of its inputs' rates" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRateAtLeastInputs

  , QC.testProperty "propagateRates is idempotent on lowered IR" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propPropagationIdempotent

  , QC.testProperty "propagateRates preserves all fields except irRate" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propPropagationStructural
  ]

propDenseIndices :: SynthGraph -> Property
propDenseIndices g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    let n   = length (rgNodes rt)
        idx = [ i | RuntimeNode { rnIndex = NodeIndex i } <- rgNodes rt ]
    in idx === [0 .. n - 1]

propTopoOrder :: SynthGraph -> Property
propTopoOrder g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    let n = length (rgNodes rt)
    in conjoin
         [ counterexample ("node " <> show (rnIndex node)) $
             all (refsEarlier n (rnIndex node)) (rnInputs node)
         | node <- rgNodes rt
         ]
  where
    refsEarlier n (NodeIndex dst) (RFrom (NodeIndex src) _) =
      src >= 0 && src < dst && src < n
    refsEarlier _ _               (RConst _)                = True

propPreservesCount :: SynthGraph -> Property
propPreservesCount g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> length (giNodes ir) === M.size (sgNodes g)

propValidates :: SynthGraph -> Property
propValidates g = case validateAndSort g of
  Left err -> counterexample ("validateAndSort failed: " <> err) False
  Right _  -> property True

-- | Drift guard for the per-kind metadata: for every UGen in a
-- generated graph, the arities reported by @ugenView@ must match
-- the @kindSpec@ table.
propUgenViewMatchesSpec :: SynthGraph -> Property
propUgenViewMatchesSpec g = conjoin
  [ counterexample (show u) $
         length (uvInputs   v) === ksAudioArity   ks
    .&&. length (uvControls v) === ksControlArity ks
  | ns <- M.elems (sgNodes g)
  , let u  = nsUgen ns
        v  = ugenView u
        ks = kindSpec (uvKind v)
  ]

-- | Compiling the same graph twice must produce identical RuntimeGraphs.
propDeterministic :: SynthGraph -> Property
propDeterministic g =
  let r1 = lowerGraph g >>= compileRuntimeGraph
      r2 = lowerGraph g >>= compileRuntimeGraph
  in r1 === r2

-- | Every source NodeID appears exactly once as rnOriginalID.
propBijection :: SynthGraph -> Property
propBijection g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    sort (map rnOriginalID (rgNodes rt)) === sort (M.keys (sgNodes g))

-- | The multiset of NodeKinds is preserved from source to runtime.
propKindCounts :: SynthGraph -> Property
propKindCounts g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    let byTag    = sortBy (comparing kindTag)
        srcKinds = byTag (map (ugenKind . nsUgen) (M.elems (sgNodes g)))
        rtKinds  = byTag (map rnKind (rgNodes rt))
    in srcKinds === rtKinds

-- | Number of Out specs in the source equals number of KOut nodes in
-- the runtime.
propOutCount :: SynthGraph -> Property
propOutCount g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    let srcOuts = length [ () | NodeSpec { nsUgen = Out{} } <- M.elems (sgNodes g) ]
        rtOuts  = length [ () | n <- rgNodes rt, rnKind n == KOut ]
    in srcOuts === rtOuts

-- | Every NodeID returned by 'dependencies' on a node in the graph
-- must be a node-key in that graph.
propDepsExist :: SynthGraph -> Property
propDepsExist g =
  let nodes = sgNodes g
      keys  = M.keysSet nodes
      bad   = [ (nid, dep)
              | (nid, spec) <- M.toList nodes
              , dep <- dependencies (nsUgen spec)
              , dep `S.notMember` keys
              ]
  in counterexample ("dangling deps: " <> show bad) (null bad)

------------------------------------------------------------
-- Region-formation invariants
------------------------------------------------------------

-- | Every IR node appears in exactly one region.
propRegionPartition :: SynthGraph -> Property
propRegionPartition g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg          = formRegions (giNodes ir)
        regionIDs   = concatMap regNodes (rgRegions rg)
        irNodeIDs   = map irNodeID (giNodes ir)
    in conjoin
         [ counterexample "region members are not unique" $
             length regionIDs === length (nub regionIDs)
         , counterexample "region members ≠ IR nodes" $
             sort regionIDs === sort irNodeIDs
         ]

-- | rgNodeMap matches regNodes membership both ways.
propRegionNodeMapConsistent :: SynthGraph -> Property
propRegionNodeMapConsistent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg = formRegions (giNodes ir)
        forwardOK =
          [ M.lookup nid (rgNodeMap rg) == Just (regID r)
          | r <- rgRegions rg, nid <- regNodes r
          ]
        reverseOK =
          [ nid `elem` regNodes r
          | (nid, rid) <- M.toList (rgNodeMap rg)
          , Just r <- [findRegion rid (rgRegions rg)]
          ]
    in conjoin
         [ counterexample "regNodes → rgNodeMap mismatch" $
             property (and forwardOK)
         , counterexample "rgNodeMap → regNodes mismatch" $
             property (and reverseOK)
         ]
  where
    findRegion rid = lookup rid . map (\r -> (regID r, r))

-- | Region IDs are unique within a RegionGraph.
propRegionIDsUnique :: SynthGraph -> Property
propRegionIDsUnique g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rids = map regID (rgRegions (formRegions (giNodes ir)))
    in length rids === length (nub rids)

-- | Region deps refer only to existing region IDs, and never to a
-- region's own ID.
propRegionDepsWellFormed :: SynthGraph -> Property
propRegionDepsWellFormed g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg     = formRegions (giNodes ir)
        allIDs = S.fromList (map regID (rgRegions rg))
    in conjoin
         [ counterexample (show (regID r) <> " has bad deps: " <> show (regDeps r)) $
             property $
               regDeps r `S.isSubsetOf` allIDs
               && regID r `S.notMember` regDeps r
         | r <- rgRegions rg
         ]

-- | Every same-bus (BusWrite n, BusRead n) pair must have the writer
-- precede the reader in the topological order. This is the property
-- version of the unit tests in @Bus routing (BusIn/BusOut and E_r
-- edges)@: it asserts that 'effectiveDeps' actually puts every
-- writer before every reader, on every randomly generated graph.
--
-- Cycles in E_s ∪ E_r show up as a 'Left' from 'validateAndSort' and
-- are skipped (the cycle-rejection unit test covers those).
propBusOrdering :: SynthGraph -> Property
propBusOrdering g = case validateAndSort g of
  Left _    -> property True
  Right ord ->
    let posOf   = M.fromList (zip ord [(0 :: Int) ..])
        nodes   = M.toList (sgNodes g)
        writers = [ (nid, n) | (nid, ns) <- nodes
                             , BusWrite n <- inferEff (nsUgen ns) ]
        readers = [ (nid, n) | (nid, ns) <- nodes
                             , BusRead  n <- inferEff (nsUgen ns) ]
        bad =
          [ (w, r, n)
          | (w, bw) <- writers
          , (r, br) <- readers
          , bw == br
          , let n  = bw
                pw = posOf M.! w
                pr = posOf M.! r
          , pw >= pr
          ]
    in counterexample ("bad bus orderings: " <> show bad) (null bad)

-- | Every node's propagated rate must be at least its kind's floor.
-- This is the trivial half of the join: a kind floor is one of the
-- arguments of 'max', so the result is always ≥ the floor.
propRateAtLeastFloor :: SynthGraph -> Property
propRateAtLeastFloor g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> conjoin
    [ counterexample
        ("node " <> show (irNodeID n) <> " of kind " <> show (irKind n)
          <> ": irRate " <> show (irRate n)
          <> " < floor " <> show floor_)
        (irRate n >= floor_)
    | n <- giNodes ir
    , let floor_ = ksRate (kindSpec (irKind n))
    ]

-- | Every node's propagated rate must be at least the maximum rate of
-- its inputs (FromNode inputs contribute the source node's rate;
-- Literal inputs contribute CompileRate). This is the load-bearing
-- half of the join: it's the property that makes
-- 'MetaSonic.Bridge.IR.checkRateEdges' vacuous post-propagation.
propRateAtLeastInputs :: SynthGraph -> Property
propRateAtLeastInputs g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rateMap = M.fromList [ (irNodeID n, irRate n) | n <- giNodes ir ]
    in conjoin
         [ counterexample
             ("node " <> show (irNodeID n)
               <> ": irRate " <> show (irRate n)
               <> " < input rate " <> show inRate
               <> " (input " <> show inp <> ")")
             (irRate n >= inRate)
         | n   <- giNodes ir
         , inp <- irInputs n
         , let inRate = case inp of
                 FromNode src _ -> M.findWithDefault CompileRate src rateMap
                 Literal _      -> CompileRate
         ]

-- | Propagation reaches a fixed point in one pass. Running it twice
-- on a lowered IR must yield the same IR as running it once. This is
-- a defensive correctness check: a non-idempotent join would mean
-- some node's rate is changing on the second pass, which can only
-- happen if the first pass missed a join somewhere.
propPropagationIdempotent :: SynthGraph -> Property
propPropagationIdempotent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> propagateRates ir === ir

-- | Propagation only touches 'irRate'. NodeID, kind, inputs,
-- controls, and effects must be byte-identical before and after.
-- A regression here would mean the lift is mutating something it
-- shouldn't — and any of those fields drifting would break
-- downstream lowering, FFI marshalling, or scheduling.
propPropagationStructural :: SynthGraph -> Property
propPropagationStructural g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let lifted = propagateRates ir
        same field name =
          counterexample ("propagation changed " <> name) $
            map field (giNodes ir) === map field (giNodes lifted)
    in conjoin
         [ same irNodeID   "irNodeID"
         , same irKind     "irKind"
         , same irInputs   "irInputs"
         , same irControls "irControls"
         , same irEffects  "irEffects"
         ]

-- | Region rate is consistent with its members'. After CompileRate
-- absorption (see Note [Region rate compatibility] in
-- MetaSonic.Bridge.Compile), member rates may differ from 'regRate':
-- a CompileRate helper folded into a SampleRate region keeps its own
-- 'irRate = CompileRate' while the region's 'regRate' stays SampleRate.
-- Two invariants together replace the old "all equal" check:
--
--   1. Every member rate is compatible with 'regRate', i.e. either
--      equal to it or 'CompileRate'.
--   2. 'regRate' is the maximum of member rates, so at least one
--      member's rate equals 'regRate' (the dominant one that drove
--      the join).
propRegionRateCompatible :: SynthGraph -> Property
propRegionRateCompatible g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg     = formRegions (giNodes ir)
        nodes  = giNodes ir
        rateOf nid = irRate <$> findNode nid nodes
        memberRates r = [ mr | nid <- regNodes r, Just mr <- [rateOf nid] ]
        compatible rr mr = mr == rr || mr == CompileRate
    in conjoin
         [ conjoin
             [ counterexample
                 (show (regID r) <> ": member " <> show nid
                    <> " has rate " <> show (rateOf nid)
                    <> " not compatible with regRate " <> show (regRate r))
                 $ property $ maybe False (compatible (regRate r)) (rateOf nid)
             | nid <- regNodes r
             ] .&&.
             counterexample
               (show (regID r) <> ": regRate " <> show (regRate r)
                  <> " is not max of member rates " <> show (memberRates r))
               (property $ regRate r == maximum (regRate r : memberRates r)
                          && regRate r `elem` memberRates r)
         | r <- rgRegions rg
         ]
  where
    findNode nid = lookup nid . map (\n -> (irNodeID n, n))

-- | Step A round-trip property: the runtime region overlay produced
-- by 'compileRuntimeGraph' must agree with 'formRegions (giNodes ir)'
-- on count, rate, member count, and the per-region NodeID-to-NodeIndex
-- translation. Pins the contract that loaders use to send regions
-- across the FFI.
propRuntimeRegionsRoundTrip :: SynthGraph -> Property
propRuntimeRegionsRoundTrip g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let compileRegions = rgRegions (formRegions (giNodes ir))
          runtime        = rgRuntimeRegions rg
          indexMap = M.fromList
            [ (rnOriginalID n, rnIndex n) | n <- rgNodes rg ]
          translate nid = M.lookup nid indexMap
      in conjoin
           [ counterexample "region count mismatch" $
               length runtime === length compileRegions
           , conjoin
               [ counterexample
                   (show i <> ": rate mismatch")
                   (rrRate rr === regRate cr)
                 .&&.
                 counterexample
                   (show i <> ": members differ from translated formRegions output")
                   (rrNodes rr === mapMaybe translate (regNodes cr))
               | (i, rr, cr) <- zip3 [(0 :: Int) ..] runtime compileRegions
               ]
           ]

-- | Step A structural invariant: every 'RuntimeRegion' covers a
-- contiguous run of 'NodeIndex' values, regions concatenate in order
-- to exactly @[0 .. length (rgNodes rg) - 1]@, and no node is in
-- two regions. This locks the contiguity contract the C++ side
-- relies on (RegionSpec carries first_node + node_count).
propRuntimeRegionsContiguous :: SynthGraph -> Property
propRuntimeRegionsContiguous g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let runtime    = rgRuntimeRegions rg
          unwrap (NodeIndex i) = i
          flat       = concatMap (map unwrap . rrNodes) runtime
          totalNodes = length (rgNodes rg)
          eachContiguous =
            [ counterexample (show (rrIndex r) <> ": members are not contiguous: " <> show ixs) $
                property $
                  let ixs = map unwrap (rrNodes r)
                  in not (null ixs)
                       && ixs == [head ixs .. head ixs + length ixs - 1]
            | r <- runtime
            , let ixs = map unwrap (rrNodes r)
            ]
      in conjoin
           [ counterexample "regions do not concatenate to [0 .. n-1]" $
               flat === [0 .. totalNodes - 1]
           , conjoin eachContiguous
           ]

-- | Step B-Light: 'rnOutputUse' must agree with the actual consumer /
-- region structure. Three invariants:
--
--   1. 'NoOutput' iff the node's kind is a sink ('KOut' / 'KBusOut').
--   2. 'RegionLocal' iff the node has output AND every consumer is in
--      the same region (vacuously true when there are no consumers).
--   3. 'RegionEscapes' iff the node has output AND at least one
--      consumer is in a different region.
--
-- See Note [Output-use classification] in MetaSonic.Bridge.Compile.
propOutputUseConsistent :: SynthGraph -> Property
propOutputUseConsistent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let nodeRegion = M.fromList
            [ (ix, rrIndex r)
            | r <- rgRuntimeRegions rg, ix <- rrNodes r
            ]
          consumersOf ix =
            [ rnIndex c
            | c <- rgNodes rg
            , RFrom src _ <- rnInputs c
            , src == ix
            ]
          isSink k = k == KOut || k == KBusOut
          expected n
            | isSink (rnKind n) = NoOutput
            | otherwise =
                let myReg = M.lookup (rnIndex n) nodeRegion
                    cs    = consumersOf (rnIndex n)
                    same  = all (\c -> M.lookup c nodeRegion == myReg) cs
                in if same then RegionLocal else RegionEscapes
      in conjoin
           [ counterexample
               (show (rnIndex n) <> " (" <> show (rnKind n)
                  <> "): rnOutputUse = " <> show (rnOutputUse n)
                  <> ", expected " <> show (expected n))
               (rnOutputUse n === expected n)
           | n <- rgNodes rg
           ]

-- | 'rnConsumerCount' equals the number of direct 'FromNode'
-- references to this node across 'rgNodes'. The crisp Step-C
-- single-edge fusion predicate (rnOutputUse == RegionLocal &&
-- rnConsumerCount == 1) only works if this count is honest.
propConsumerCountConsistent :: SynthGraph -> Property
propConsumerCountConsistent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let countFor ix =
            length
              [ ()
              | c <- rgNodes rg
              , RFrom src _ <- rnInputs c
              , src == ix
              ]
      in conjoin
           [ counterexample
               (show (rnIndex n) <> ": rnConsumerCount = "
                  <> show (rnConsumerCount n)
                  <> ", direct count = " <> show (countFor (rnIndex n)))
               (rnConsumerCount n === countFor (rnIndex n))
           | n <- rgNodes rg
           ]

------------------------------------------------------------
-- Cross-cutting end-to-end tests through the FFI
------------------------------------------------------------
--
-- Builds a SynthGraph via the Haskell DSL, runs the full pipeline
-- (lower → compile → loadRuntimeGraph), renders one block via
-- c_rt_graph_process + c_rt_graph_read_bus, and compares the
-- resulting samples to an analytical expectation. This is the
-- only test layer that exercises the entire FFI marshaling.

crossCuttingTests :: TestTree
crossCuttingTests = testGroup "End-to-end FFI"
  [ testCase "SinOsc(440) round-trips through FFI to audible sin samples" $ do
      let nframes :: Int
          nframes  = 256
          sampleRate :: Double
          sampleRate = 48000.0
          tau :: Double
          tau = 2.0 * pi

          graph = runSynth $ do
            o <- sinOsc 440.0 0.0
            out 0 o

      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          wrote <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                       (castPtr buf)
          fromIntegral wrote @?= nframes
          cs <- peekArray nframes (buf :: PtrCFloat)
          let samples = map (\(CFloat x) -> x) cs

          let peak = maximum (map abs samples)
          assertBool ("peak ≈ 1, got " <> show peak)
                     (abs (peak - 1.0) < 0.05)
          assertBool ("sample 0 ≈ 0, got " <> show (head samples))
                     (abs (head samples) < 0.02)

          mapM_ (checkAt sampleRate tau samples) [25, 50, 100, 200]

  , testCase "Gain(SinOsc, 0.5) round-trips with halved peak" $ do
      let nframes = 256
          graph = runSynth $ do
            o <- sinOsc 440.0 0.0
            g <- gain o 0.5
            out 0 g

      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          let peak = maximum (map (\(CFloat x) -> abs x) cs)
          assertBool ("expected peak ≈ 0.5, got " <> show peak)
                     (abs (peak - 0.5) < 0.05)

  , testCase "Env(gate=1, A=0.5ms, D=2ms, S=0.5, R=10ms) attacks then decays to sustain" $ do
      -- 1024 frames at 48 kHz ≈ 21 ms. With A=0.5ms + D=2ms the envelope
      -- should reach near-1 in attack and settle near 0.5 in sustain
      -- before the block ends. Gate held high via Param 1.0.
      let nframes = 1024
          graph = runSynth $ do
            e <- env (Param 1.0) (Param 0.0005) (Param 0.002) (Param 0.5) (Param 0.01)
            out 0 e

      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          let samples = map (\(CFloat x) -> x) cs
              peak    = maximum samples
              tailAvg = sum (drop 900 samples) / fromIntegral (nframes - 900)
          assertBool ("attack peak should reach near 1, got " <> show peak)
                     (peak > 0.9)
          assertBool ("sustain tail should sit near 0.5, got avg " <> show tailAvg)
                     (abs (tailAvg - 0.5) < 0.1)

  , testCase "rendering 2×N frames matches one 2N block (state continuity across blocks)" $ do
      -- Two consecutive blocks of N frames must produce the same samples
      -- as a single 2N-frame render. This pins the runtime's per-block
      -- state continuity (oscillator phase, LPF state, future bus
      -- snapshots) end-to-end. It is the precondition for any work that
      -- extends across-block semantics — Phase 2's BusInDelayed in
      -- particular — so a regression here would invalidate that work
      -- before it starts.
      --
      -- The graph mixes a SinOsc (phase state), an LPF (filter state)
      -- and a BusOut/BusIn round-trip (bus pool state). If any of
      -- those were reset at block boundaries, the two halves wouldn't
      -- splice cleanly into the single block.
      let nhalf     = 128
          nfull     = 2 * nhalf
          maxFrames = nfull
          graph     = runSynth $ do
            o      <- sinOsc 440.0 0.0
            busOut 5 o
            tap    <- busIn 5
            filt   <- lpf tap 800.0 0.7
            out 0 filt
      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      let renderN handle n = allocaBytes (n * sizeOfFloat) $ \buf -> do
            c_rt_graph_process handle (fromIntegral n)
            _  <- c_rt_graph_read_bus handle 0 (fromIntegral n) (castPtr buf)
            cs <- peekArray n (buf :: PtrCFloat)
            pure (map (\(CFloat x) -> x) cs)

      full <- withRTGraph (length (rgNodes rt)) maxFrames $ \handle -> do
        loadRuntimeGraph handle rt
        renderN handle nfull

      halves <- withRTGraph (length (rgNodes rt)) maxFrames $ \handle -> do
        loadRuntimeGraph handle rt
        h1 <- renderN handle nhalf
        h2 <- renderN handle nhalf
        pure (h1 ++ h2)

      length full @?= nfull
      length halves @?= nfull
      let maxDiff = maximum (zipWith (\a b -> abs (a - b)) full halves)
      assertBool
        ("expected bit-equivalent samples, max diff = " <> show maxDiff)
        (maxDiff < 1e-5)

  , testCase "hotSwapRuntimeGraph publishes, installs, and collects migration stats" $ do
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

        before <- c_rt_graph_test_swap_generation handle
        before @?= 0

        published <- hotSwapRuntimeGraph handle capacity nframes newRt
        published @?= True

        -- The helper publishes only; installation still waits for a
        -- block boundary, so there is nothing to collect yet.
        early <- collectRetiredSwapStats handle
        early @?= Nothing

        c_rt_graph_process handle (fromIntegral nframes)
        after <- c_rt_graph_test_swap_generation handle
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

        beforeGen <- c_rt_graph_test_swap_generation handle

        rejected <- hotSwapTemplateGraph handle capacity nframes reorderedTg
        rejected @?= False

        -- A rejected publish must not advance the install counter.
        afterReject <- c_rt_graph_test_swap_generation handle
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
        beforeGen <- c_rt_graph_test_swap_generation handle

        rejected <- hotSwapTemplateGraphFused handle capacity nframes reorderedTg
        rejected @?= False

        afterReject <- c_rt_graph_test_swap_generation handle
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
                gen <- c_rt_graph_test_swap_generation handle
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

  , -- Step C (c) guard: feeding a fused graph through the unfused
    -- 'loadRuntimeGraph' must fail fast with the documented error,
    -- not miswire silently. This pins the contract until Step C (e)
    -- adds a fused-aware loader.
    testCase "loadRuntimeGraph rejects RFused inputs with the documented error" $ do
      -- 'Env' source: durable §4.C-only fixture (no §4.B kernel
      -- candidate, per notes/2026-05-08-fusion-strategy.md). We need §4.C to
      -- actually emit an 'RFused' input for the loader-rejection
      -- check to fire.
      let graph = runSynth $ do
            o <- env (Param 1.0) 0.0005 0.002 1.0 0.002
            a <- gain o (Param 0.5)
            out 0 a
      rt <- case lowerGraph graph >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      -- Sanity: the fused graph really has at least one RFused.
      assertBool "fused compile produced no RFused inputs"
        (not (null [() | n <- rgNodes rt, RFused _ <- rnInputs n]))
      let attempt :: IO (Either IOError ())
          attempt = try $
            withRTGraph (length (rgNodes rt)) 64 $ \handle ->
              loadRuntimeGraph handle rt
      result <- attempt
      case result of
        Right () ->
          assertFailure "expected loadRuntimeGraph to fail on RFused input"
        Left e ->
          assertBool
            ("error message did not mention the fused loader: " <> show e)
            ("RFused input requires the fused loader" `isInfixOf` show e)

  , -- Step C (e) smoke test: 'loadRuntimeGraphFused' loads a graph
    -- containing 'RFused' and 'rnElided' without throwing, and the
    -- audio path produces non-silent output. Bit-identical
    -- equivalence with the unfused render is pinned in Step C (f).
    testCase "loadRuntimeGraphFused: fused graph renders non-silent audio" $ do
      -- 'Env' source: durable §4.C-only fixture. With gate=1 and
      -- sustain=1 the envelope settles at ~1.0 within a few ms
      -- (well under the 256-frame block), so peak after the 0.5
      -- gain is ~0.5 — same expected magnitude the previous saw
      -- fixture targeted, just from a different source.
      let nframes = 256
          graph = runSynth $ do
            o <- env (Param 1.0) 0.0005 0.002 1.0 0.002
            a <- gain o (Param 0.5)
            out 0 a
      rt <- case lowerGraph graph >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      -- Confirm the fused compile produced both signals: an RFused
      -- input on Out and an elided Gain. Without these the test
      -- would not exercise the new loader passes.
      assertBool "fused compile produced no RFused inputs"
        (not (null [() | n <- rgNodes rt, RFused _ <- rnInputs n]))
      assertBool "fused compile elided no nodes"
        (any rnElided (rgNodes rt))

      samples <- withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraphFused handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _  <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                    (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          pure (map (\(CFloat x) -> x) cs)

      let peak = maximum (map abs samples)
      -- Env at sustain=1 × 0.5 gain ⇒ peak ≈ 0.5. Non-silent
      -- confirms the fused-input scratch materialization reached
      -- the consumer and the elided Gain didn't break dispatch.
      assertBool ("expected non-silent fused render, peak = " <> show peak)
                 (peak > 0.4 && peak < 0.6)

  , -- Step C (f): bit-equivalence battery. For every graph in
    -- 'fusedEquivalenceCases' the unfused render (loadRuntimeGraph
    -- + compileRuntimeGraph) must equal the fused render
    -- (loadRuntimeGraphFused + compileRuntimeGraphFused) sample-
    -- for-sample. The fused path takes a different runtime route
    -- — elided dispatch + fused-input resolver (any of single-scale,
    -- scale chain, or affine; selected by the FusedInput
    -- constructor) — but each step's materialization discipline
    -- (cast double→float, multiply or add) is chosen to mirror
    -- process_gain / process_add scalar branches exactly, so
    -- equivalence is bit-strict, not approx.
    --
    -- Each case must actually exercise fusion: the assertion
    -- includes a sanity check that the fused graph produced at
    -- least one RFused input and at least one elided node.
    testGroup "Step C (f): fused render equals unfused render"
      [ testCase name $ assertFusedEquivalent name graph
      | (name, graph) <- fusedEquivalenceCases
      ]

  , -- Property-based fused/unfused render equivalence on random
    -- topology. Same contract as the testGroup above, but the
    -- graph is QuickCheck-generated by 'genFusableRenderableGraph'
    -- (deterministic subset: no NoiseGen, always-renderable bus 7
    -- floor). A coverage gate ensures the generated cases actually
    -- exercise fusion instead of mostly comparing identical unfused
    -- loader paths.
    QC.testProperty "fused render equals unfused render on random graphs" $
      forAllShrink genFusableRenderableGraph shrinkSynthGraph
        prop_fusedRenderEqualsUnfused

  , -- Step C (f): control identity. A live set_control on the
    -- elided Gain node must steer the fused output exactly as it
    -- steers the unfused Gain's kernel. This is the load-bearing
    -- claim that elided nodes remain control-addressable through
    -- the FFI: NodeIndex, control slot, and control values all
    -- survive elision.
    testCase "Step C (f): set_control on elided Gain matches unfused output" $ do
      let nframes = 256
          chain = runSynth $ do
            o <- sinOsc 440.0 0.0
            a <- gain o (Param 0.5)  -- initial scalar gain
            out 0 a
          newGain = 0.7 :: Double

      rtUn <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      -- The elided Gain's NodeIndex must survive identically in
      -- both graphs. compileRuntimeGraphFused preserves rgNodes
      -- ordering (Step C (c)) so the index is the same.
      let gainIdxFromGraph rg =
            case [rnIndex n | n <- rgNodes rg, rnKind n == KGain] of
              [NodeIndex i] -> i
              other -> error $ "expected one Gain, got " <> show other
          gainIxUn = gainIdxFromGraph rtUn
          gainIxF  = gainIdxFromGraph rtF
      gainIxUn @?= gainIxF

      let renderWith loader rt = withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
            loader handle rt
            -- Live control write on the (elided / dispatched) Gain.
            -- In the fused graph the kernel never runs, but
            -- resolve_input reads controls[0] when materializing
            -- the FScaleFrom; in the unfused graph process_gain's
            -- scalar branch reads the same slot. Both should
            -- track newGain identically.
            c_rt_graph_instance_set_control handle 0
              (fromIntegral gainIxUn) 0 (CDouble newGain)
            c_rt_graph_process handle (fromIntegral nframes)
            allocaBytes (nframes * sizeOfFloat) $ \buf -> do
              _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                       (castPtr buf)
              cs <- peekArray nframes (buf :: PtrCFloat)
              pure (map (\(CFloat x) -> x) cs)

      unfusedSamples <- renderWith loadRuntimeGraph      rtUn
      fusedSamples   <- renderWith loadRuntimeGraphFused rtF

      length unfusedSamples @?= length fusedSamples
      assertBool "fused/unfused samples differ after live set_control"
        (unfusedSamples == fusedSamples)
      -- Sanity: the new gain actually took effect — a 440 Hz sine
      -- at 0.7 should peak around 0.7, not at the original 0.5.
      let peak = maximum (map abs unfusedSamples)
      assertBool ("expected peak ≈ 0.7 after set_control, got " <> show peak)
                 (peak > 0.6 && peak < 0.75)

  , -- Chain control identity. With both Gains in a chain elided,
    -- live set_control on every Gain in the chain must steer the
    -- fused output exactly as it steers the unfused chain of
    -- process_gain kernels. The fact that *both* mid-chain Gains
    -- remain control-addressable is the guarantee that
    -- 'rt_graph_template_connect_fused_scale_chain_input' stored
    -- each ScaleRef and the resolver reads each control live —
    -- pre-multiplication or stale caching would either silently
    -- ignore one of the writes or change the output's float-
    -- rounding profile. Done as a separate test from the
    -- single-Gain identity test so a regression in chain handling
    -- doesn't masquerade as the simpler bug.
    testCase "Step C: set_control on every elided Gain in a chain matches unfused output" $ do
      let nframes = 256
          chain = runSynth $ do
            o  <- sinOsc 440.0 0.0
            a1 <- gain o  (Param 0.5)
            a2 <- gain a1 (Param 0.25)
            out 0 a2
          newG1 = 0.7  :: Double
          newG2 = 0.6  :: Double

      rtUn <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      -- Both Gains' NodeIndex must survive identically across
      -- fused/unfused. compileRuntimeGraphFused preserves rgNodes
      -- ordering, so the indices line up.
      let gainIxs rg =
            [ rnIndex n | n <- rgNodes rg, rnKind n == KGain ]
      gainIxs rtUn @?= gainIxs rtF
      case gainIxs rtF of
        [_, _] -> pure ()
        other  -> assertFailure $
          "expected exactly two Gains in chain, got " <> show other
      let [NodeIndex g1, NodeIndex g2] = gainIxs rtF

      -- Sanity: the fused compile actually produced a chain (not
      -- two independent FScaleFroms). If this assertion ever flips
      -- to FScaleFrom, the chain extension regressed.
      assertBool "chain test: expected FScaleChainFrom on Out's input"
        (not (null
          [ ()
          | n <- rgNodes rtF
          , rnKind n == KOut
          , RFused FScaleChainFrom{} <- rnInputs n
          ]))

      let renderWith loader rt = withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
            loader handle rt
            -- Mutate both elided Gain controls. In the unfused
            -- graph each kernel reads its own controls[0]; in the
            -- fused graph the chain resolver reads each ScaleRef's
            -- live control. Both reads must reflect the new values.
            c_rt_graph_instance_set_control handle 0
              (fromIntegral g1) 0 (CDouble newG1)
            c_rt_graph_instance_set_control handle 0
              (fromIntegral g2) 0 (CDouble newG2)
            c_rt_graph_process handle (fromIntegral nframes)
            allocaBytes (nframes * sizeOfFloat) $ \buf -> do
              _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                       (castPtr buf)
              cs <- peekArray nframes (buf :: PtrCFloat)
              pure (map (\(CFloat x) -> x) cs)

      unfusedSamples <- renderWith loadRuntimeGraph      rtUn
      fusedSamples   <- renderWith loadRuntimeGraphFused rtF

      length unfusedSamples @?= length fusedSamples
      assertBool "chain fused/unfused samples differ after live set_control on both Gains"
        (unfusedSamples == fusedSamples)
      -- Sanity: combined gain ≈ 0.7 * 0.6 = 0.42, so peak should
      -- be near that on a 440 Hz sine.
      let peak = maximum (map abs unfusedSamples)
      assertBool ("expected peak ≈ 0.42 after chain set_control, got " <> show peak)
                 (peak > 0.36 && peak < 0.48)

  , -- Phase 4.C.2: control identity on a mixed Gain/Add chain. With
    -- both nodes elided into one FAffineFrom on Out's input, live
    -- set_control on the Gain's scale AND on the Add's bias must
    -- steer the fused output exactly as the unfused chain. This
    -- pins (a) that the affine resolver reads each step's control
    -- live every block and (b) that the bias control slot (1 in
    -- this test) is wired correctly from the Haskell IR through to
    -- the FFI marshalling and the C++ resolver.
    testCase "Phase 4.C.2: set_control on elided Gain and Add in a mixed chain matches unfused" $ do
      let nframes = 256
          chain = runSynth $ do
            o <- sinOsc 440.0 0.0
            a <- gain o (Param 0.5)
            b <- add  a (Param 0.1)
            out 0 b
          newGain = 0.7  :: Double
          newBias = 0.05 :: Double

      rtUn <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      -- Sanity: the fused compile actually emitted FAffineFrom (not
      -- two separate fused inputs). Regression catch if the affine
      -- composition rule ever changes shape.
      assertBool "expected FAffineFrom on Out's input"
        (not (null
          [ ()
          | n <- rgNodes rtF
          , rnKind n == KOut
          , RFused FAffineFrom{} <- rnInputs n
          ]))

      let gainIxOf rg =
            case [rnIndex n | n <- rgNodes rg, rnKind n == KGain] of
              [NodeIndex i] -> i
              other -> error $ "expected one Gain, got " <> show other
          addIxOf rg =
            case [rnIndex n | n <- rgNodes rg, rnKind n == KAdd] of
              [NodeIndex i] -> i
              other -> error $ "expected one Add, got " <> show other
      gainIxOf rtUn @?= gainIxOf rtF
      addIxOf  rtUn @?= addIxOf  rtF
      let gainIx = gainIxOf rtF
          addIx  = addIxOf  rtF

      let renderWith loader rt = withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
            loader handle rt
            -- Mutate the Gain's scale (slot 0) and the Add's bias
            -- (slot 1, since 'add a (Param k)' lowers with the bias
            -- on port 1 → control 1). Both must take effect through
            -- the affine resolver every block.
            c_rt_graph_instance_set_control handle 0
              (fromIntegral gainIx) 0 (CDouble newGain)
            c_rt_graph_instance_set_control handle 0
              (fromIntegral addIx)  1 (CDouble newBias)
            c_rt_graph_process handle (fromIntegral nframes)
            allocaBytes (nframes * sizeOfFloat) $ \buf -> do
              _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                       (castPtr buf)
              cs <- peekArray nframes (buf :: PtrCFloat)
              pure (map (\(CFloat x) -> x) cs)

      unfusedSamples <- renderWith loadRuntimeGraph      rtUn
      fusedSamples   <- renderWith loadRuntimeGraphFused rtF

      length unfusedSamples @?= length fusedSamples
      assertBool "affine fused/unfused samples differ after live set_control on Gain + Add"
        (unfusedSamples == fusedSamples)
      -- Sanity: amplitude oscillates between 0.05 - 0.7 = -0.65 and
      -- 0.05 + 0.7 = 0.75, so the peak magnitude should be ≈ 0.75
      -- (the bias is constant DC, the sine oscillates around it).
      let peak = maximum (map abs unfusedSamples)
      assertBool ("expected peak ≈ 0.75 after set_control on scale+bias, got " <> show peak)
                 (peak > 0.7 && peak < 0.78)

  , -- Phase 4.B kernel control identity. Live 'set_control' on
    -- every control slot the SinGainOut kernel reads — sin.freq,
    -- gain.amount, out.bus — must steer the fused render exactly
    -- as it steers a node-loop baseline. A regression where the
    -- kernel cached any of these once at load time (rather than
    -- reading 'inst.nodes[i].controls[k]' live each block) would
    -- silently ignore later set_control writes; a regression
    -- where the wrong slot was wired would shift the bug from
    -- "ignored" to "applied to the wrong control."
    --
    -- The baseline strips the region-kernel tags so the same
    -- compiled graph dispatches via 'process_sinosc' /
    -- 'process_gain' / 'process_out' instead of the kernel —
    -- without that strip, both sides would dispatch through the
    -- kernel and the test would compare identical paths.
    testCase "Phase 4.B: set_control on kernel freq/gain/bus matches node-loop baseline" $ do
      let nframes = 256
          chain = runSynth $ do
            s <- sinOsc 440.0 0.0
            a <- gain s (Param 0.5)
            out 0 a                       -- initial bus: 0
          newFreq = 330.0 :: Double
          newGain = 0.3   :: Double
          newBus  = 2     :: Int          -- redirect to bus 2

      rtUnRaw <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      -- Sanity: the fused side carries an RSinGainOut region (else
      -- the test isn't testing what it claims).
      assertBool "Phase 4.B: fused compile has no RSinGainOut region"
        (any ((== RSinGainOut) . rrKernel) (rgRuntimeRegions rtF))

      -- Strip kernels on the baseline so its render takes the
      -- per-node dispatch path on the same compiled graph.
      let rtUn = stripRegionKernels rtUnRaw

          ixOf k rg =
            let NodeIndex i = head [rnIndex n | n <- rgNodes rg, rnKind n == k]
            in i
          sinIx  = ixOf KSinOsc rtF
          gainIx = ixOf KGain   rtF
          outIx  = ixOf KOut    rtF

      let sizeOfFloat' = 4 :: Int
          renderBus loader rt readBus =
            withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
              loader handle rt
              -- Grow the bus pool to cover the redirected target.
              -- Post-§2.E ABI: 'rt_graph_instance_set_control' no
              -- longer side-effects bus growth; explicit
              -- 'rt_graph_ensure_bus' is required.
              c_rt_graph_ensure_bus handle (fromIntegral newBus)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral sinIx)  0 (CDouble newFreq)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral gainIx) 0 (CDouble newGain)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral outIx)  0 (CDouble (fromIntegral newBus))
              c_rt_graph_process handle (fromIntegral nframes)
              allocaBytes (nframes * sizeOfFloat') $ \buf -> do
                _ <- c_rt_graph_read_bus handle (fromIntegral readBus)
                                         (fromIntegral nframes) (castPtr buf)
                cs <- peekArray nframes (buf :: PtrCFloat)
                pure (map (\(CFloat x) -> x) cs)

      -- Render the redirected bus on both sides.
      baselineSamples <- renderBus loadRuntimeGraph      rtUn newBus
      fusedSamples    <- renderBus loadRuntimeGraphFused rtF  newBus

      length baselineSamples @?= length fusedSamples
      assertBool
        ("Phase 4.B: kernel set_control divergence on bus " <> show newBus)
        (baselineSamples == fusedSamples)

      -- Sanity: 330 Hz sin at 0.3 gain ⇒ peak ≈ 0.3.
      let peak = maximum (map abs baselineSamples)
      assertBool ("expected peak ≈ 0.3 after set_control, got " <> show peak)
                 (peak > 0.25 && peak < 0.35)

  , -- Phase 4.B 4-node kernel control identity. Mirrors the 3-node
    -- 'RSinGainOut' control-write test but exercises every control
    -- the 'RSawLpfGainOut' kernel reads: saw.freq, lpf.freq (slot
    -- 0), lpf.q (slot 1), gain.amount, and out.bus. The LPF's two
    -- distinct control slots are the new ground here — a
    -- regression where the kernel's block-rate latch read the
    -- wrong slot, or didn't refresh on a Q change, would diverge
    -- from the per-node baseline that runs the unfused
    -- 'process_lpf' kernel.
    --
    -- The baseline strips region kernels so its render takes
    -- per-node dispatch on the same compiled graph; bit-identical
    -- samples on the redirected bus prove every control reaches
    -- the right slot in the right form.
    testCase "Phase 4.B: set_control on RSawLpfGainOut covers saw.freq + lpf.freq/q + gain + bus" $ do
      let nframes = 256
          chain = runSynth $ do
            s <- sawOsc 110.0 0.0
            f <- lpf s (Param 800.0) (Param 4.0)
            a <- gain f (Param 0.4)
            out 0 a                       -- initial bus: 0
          newSawFreq = 220.0  :: Double   -- shift fundamental
          newLpfFreq = 1500.0 :: Double   -- raise cutoff (more harmonics pass)
          newLpfQ    = 6.0    :: Double   -- raise Q
          newGain    = 0.3    :: Double
          newBus     = 2      :: Int      -- redirect to bus 2

      rtUnRaw <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      assertBool "Phase 4.B: fused compile has no RSawLpfGainOut region"
        (any ((== RSawLpfGainOut) . rrKernel) (rgRuntimeRegions rtF))

      let rtUn = stripRegionKernels rtUnRaw

          ixOf k rg =
            let NodeIndex i = head [rnIndex n | n <- rgNodes rg, rnKind n == k]
            in i
          sawIx  = ixOf KSawOsc rtF
          lpfIx  = ixOf KLPF    rtF
          gainIx = ixOf KGain   rtF
          outIx  = ixOf KOut    rtF

      let sizeOfFloat' = 4 :: Int
          renderBus loader rt readBus =
            withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
              loader handle rt
              c_rt_graph_ensure_bus handle (fromIntegral newBus)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral sawIx)  0 (CDouble newSawFreq)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral lpfIx)  0 (CDouble newLpfFreq)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral lpfIx)  1 (CDouble newLpfQ)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral gainIx) 0 (CDouble newGain)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral outIx)  0 (CDouble (fromIntegral newBus))
              c_rt_graph_process handle (fromIntegral nframes)
              allocaBytes (nframes * sizeOfFloat') $ \buf -> do
                _ <- c_rt_graph_read_bus handle (fromIntegral readBus)
                                         (fromIntegral nframes) (castPtr buf)
                cs <- peekArray nframes (buf :: PtrCFloat)
                pure (map (\(CFloat x) -> x) cs)

      baselineSamples <- renderBus loadRuntimeGraph      rtUn newBus
      fusedSamples    <- renderBus loadRuntimeGraphFused rtF  newBus

      length baselineSamples @?= length fusedSamples
      assertBool
        ("Phase 4.B: 4-node kernel set_control divergence on bus " <> show newBus)
        (baselineSamples == fusedSamples)

      -- Sanity: a 220 Hz saw through an LPF cutoff at 1500 Hz with
      -- moderate Q, scaled by 0.3, must produce non-silent output.
      -- Bounds are loose — exact peak depends on filter response —
      -- the goal is just to flag a stuck-zero render.
      let peak = maximum (map abs baselineSamples)
      assertBool ("expected non-silent render on bus " <> show newBus
                  <> ", got peak " <> show peak)
                 (peak > 0.05)

  , -- Phase 4.B: 'RBusInLpfGainOut' control identity. Mirrors the
    -- 'RSawLpfGainOut' set_control test but exercises the controls
    -- specific to the BusIn-rooted shape: busin.bus (slot 0),
    -- lpf.freq (slot 0), lpf.q (slot 1), gain.amount, and
    -- out.bus. Critically, busin.bus is the new ground here: the
    -- kernel reads 'output_buses[busin_bus][i]' inline, so
    -- redirecting the BusIn to a different source bus must steer
    -- the kernel exactly as it steers the per-node 'process_busin'
    -- baseline.
    --
    -- The graph carries /two/ independent voice writers — a 440 Hz
    -- sine on bus 5 (the BusIn's graph default) and a 220 Hz saw
    -- on bus 6 (the redirect target). Setting busin.bus from 5 to
    -- 6 swaps the entire downstream signal: LPF now filters a
    -- saw, gain scales the saw, the sink accumulates the filtered
    -- saw. If the kernel hard-coded the source bus or otherwise
    -- didn't honor live control writes, the baseline would
    -- observe the redirect through 'process_busin' but the fused
    -- path would still read the sine — they'd diverge. Bit-
    -- equivalence on the redirected sink bus pins that the kernel
    -- reads 'busin.controls[0]' fresh on every block.
    testCase "Phase 4.B: set_control on RBusInLpfGainOut covers busin.bus + lpf.freq/q + gain + out.bus" $ do
      let nframes = 256
          chain = runSynth $ do
            o1 <- sinOsc 440.0 0.0
            busOut 5 o1                              -- bus 5: 440 Hz sine (busIn graph default)
            o2 <- sawOsc 220.0 0.0
            busOut 6 o2                              -- bus 6: 220 Hz saw (redirect target)
            r <- busIn 5
            f <- lpf r (Param 800.0) (Param 4.0)
            a <- gain f (Param 0.4)
            out 0 a                                  -- initial sink: bus 0
          newLpfFreq    = 1500.0 :: Double
          newLpfQ       = 6.0    :: Double
          newGain       = 0.3    :: Double
          newSinkBus    = 2      :: Int              -- redirect sink
          newBusInBus   = 6      :: Int              -- redirect to the saw writer

      rtUnRaw <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      assertBool "Phase 4.B: fused compile has no RBusInLpfGainOut region"
        (any ((== RBusInLpfGainOut) . rrKernel) (rgRuntimeRegions rtF))

      let rtUn = stripRegionKernels rtUnRaw

          ixOf k rg =
            let NodeIndex i = head [rnIndex n | n <- rgNodes rg, rnKind n == k]
            in i
          busInIx = ixOf KBusIn rtF
          lpfIx   = ixOf KLPF   rtF
          gainIx  = ixOf KGain  rtF
          outIx   = ixOf KOut   rtF

      let sizeOfFloat' = 4 :: Int
          renderBus loader rt readBus =
            withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
              loader handle rt
              c_rt_graph_ensure_bus handle (fromIntegral newSinkBus)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral busInIx) 0 (CDouble (fromIntegral newBusInBus))
              c_rt_graph_instance_set_control handle 0
                (fromIntegral lpfIx)   0 (CDouble newLpfFreq)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral lpfIx)   1 (CDouble newLpfQ)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral gainIx)  0 (CDouble newGain)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral outIx)   0 (CDouble (fromIntegral newSinkBus))
              c_rt_graph_process handle (fromIntegral nframes)
              allocaBytes (nframes * sizeOfFloat') $ \buf -> do
                _ <- c_rt_graph_read_bus handle (fromIntegral readBus)
                                         (fromIntegral nframes) (castPtr buf)
                cs <- peekArray nframes (buf :: PtrCFloat)
                pure (map (\(CFloat x) -> x) cs)

      baselineSamples <- renderBus loadRuntimeGraph      rtUn newSinkBus
      fusedSamples    <- renderBus loadRuntimeGraphFused rtF  newSinkBus

      length baselineSamples @?= length fusedSamples
      assertBool
        ("Phase 4.B: RBusInLpfGainOut set_control divergence on bus "
         <> show newSinkBus)
        (baselineSamples == fusedSamples)

      -- Sanity: a 440 Hz sine through an LPF at 1500 Hz with
      -- moderate Q, scaled by 0.3, must produce non-silent output
      -- on the redirected bus. Same loose-peak threshold as the
      -- RSawLpfGainOut variant.
      let peak = maximum (map abs baselineSamples)
      assertBool ("expected non-silent render on bus " <> show newSinkBus
                  <> ", got peak " <> show peak)
                 (peak > 0.05)

  , -- Phase 4.B regression: 'RBusInLpfGainOut' state advancement
    -- on an invalid source bus.
    --
    -- Background: the per-node 'process_busin' fills its output
    -- buffer with zeros when 'busin.bus' is invalid, and
    -- 'process_lpf' /still runs/ over those zeros — advancing the
    -- IIR state and emitting the filter's natural decay envelope
    -- if the state was non-zero from a prior valid block. An
    -- early version of 'process_region_busin_lpf_gain_out'
    -- silent-no-op'd the entire block on invalid 'busin.bus',
    -- which froze the LPF state and skipped all 'block_sink_peak'
    -- + sink-accumulation work. The bug surfaces on a subsequent
    -- valid-bus block as a state mismatch: the per-node baseline's
    -- LPF state has settled toward zero, while the buggy fused
    -- side's still holds the prior block's filter history.
    --
    -- This test deliberately walks that exact transition: warm
    -- the LPF on a real signal, switch 'busin.bus' to an invalid
    -- index for one block, switch back to a valid index, and
    -- compare every block's sink output against the stripped
    -- baseline. Bit-equivalence across all four blocks pins that
    -- the kernel's invalid-bus path keeps the LPF advancing.
    testCase "Phase 4.B: RBusInLpfGainOut state advances on invalid source bus" $ do
      let nframes    = 256
          validBus   = 5  :: Int
          invalidBus = -1 :: Int                     -- triggers silent-source path
          chain = runSynth $ do
            o <- sinOsc 220.0 0.0
            busOut validBus o                        -- voice writes the BusIn's source
            r <- busIn validBus
            f <- lpf r (Param 800.0) (Param 6.0)     -- moderate Q: noticeable ringing decay
            a <- gain f (Param 0.6)
            out 0 a

      rtUnRaw <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      assertBool "fused compile lacks RBusInLpfGainOut"
        (any ((== RBusInLpfGainOut) . rrKernel) (rgRuntimeRegions rtF))

      let rtUn    = stripRegionKernels rtUnRaw
          ixOf k rg =
            let NodeIndex i = head [rnIndex n | n <- rgNodes rg, rnKind n == k]
            in i
          busInIx = ixOf KBusIn rtF

      let sizeOfFloat' = 4 :: Int
          -- Render four blocks with control flips between them, and
          -- return the per-block sink bus reads in execution order.
          -- Reading the bus after each block (rather than only at
          -- the end) lets the assertion message show /which/ block
          -- diverged when the test fails — block 3 indicts the
          -- silent-block decay; block 4 indicts the post-transition
          -- state mismatch.
          renderSequence loader rt =
            withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
              loader handle rt
              let processAndRead = do
                    c_rt_graph_process handle (fromIntegral nframes)
                    allocaBytes (nframes * sizeOfFloat') $ \buf -> do
                      _ <- c_rt_graph_read_bus handle 0
                             (fromIntegral nframes) (castPtr buf)
                      cs <- peekArray nframes (buf :: PtrCFloat)
                      pure (map (\(CFloat x) -> x) cs)
              -- Blocks 1+2: valid source bus. LPF state warms up
              -- on the 220 Hz sine.
              b1 <- processAndRead
              b2 <- processAndRead
              -- Switch BusIn to invalid; run block 3.
              c_rt_graph_instance_set_control handle 0
                (fromIntegral busInIx) 0
                (CDouble (fromIntegral invalidBus))
              b3 <- processAndRead
              -- Switch back to valid; run block 4. State mismatch
              -- from block 3 surfaces here as a transient diff.
              c_rt_graph_instance_set_control handle 0
                (fromIntegral busInIx) 0
                (CDouble (fromIntegral validBus))
              b4 <- processAndRead
              pure [b1, b2, b3, b4]

      baselineBlocks <- renderSequence loadRuntimeGraph      rtUn
      fusedBlocks    <- renderSequence loadRuntimeGraphFused rtF

      length baselineBlocks @?= length fusedBlocks
      let labeled = zip3 ([1..] :: [Int]) baselineBlocks fusedBlocks
      sequence_
        [ assertBool
            ("RBusInLpfGainOut: fused diverges from per-node baseline "
             <> "on block " <> show n
             <> " (block 3 indicts silent-bus state freeze; "
             <> "block 4 indicts post-transition state mismatch)")
            (b == f)
        | (n, b, f) <- labeled
        ]

      -- Sanity: blocks 1+2 (warm LPF on a 220 Hz sine through 800 Hz
      -- LPF, scaled by 0.6) must be non-silent — otherwise the
      -- "LPF state actually warmed up" premise of the test fails
      -- and a regression on the silent-bus path would slip past.
      let warmPeak = maximum
            (map abs (concat (take 2 fusedBlocks)))
      assertBool
        ("expected LPF to warm up on the valid bus, peak=" <> show warmPeak)
        (warmPeak > 0.05)

  , -- Phase 4.B: 'RNoiseLpfGainOut' control identity. NoiseGen has
    -- no controls of its own (the PRNG state isn't redirectable by
    -- a set_control write; it's owned by 'NoiseGenState'), so the
    -- live-control surface is just lpf.freq, lpf.q, gain.amount,
    -- and out.bus. Bit-equivalence with the stripped node-loop
    -- baseline pins three things at once:
    --
    --   * the kernel reads each LPF / Gain / Out control fresh on
    --     every block, just like 'process_lpf' / 'process_gain' /
    --     'process_out' do;
    --   * the LPF block-rate freq/q latch matches the per-node
    --     latch under control writes;
    --   * the kernel and per-node paths advance the
    --     'q::white_noise_gen' state at the same rate (one pull
    --     per output sample) — the load-bearing PRNG-cadence
    --     parity.
    testCase "Phase 4.B: set_control on RNoiseLpfGainOut covers lpf.freq/q + gain + out.bus" $ do
      let nframes = 256
          chain = runSynth $ do
            n <- noiseGen
            f <- lpf n (Param 800.0) (Param 4.0)
            a <- gain f (Param 0.4)
            out 0 a
          newLpfFreq = 1500.0 :: Double
          newLpfQ    = 6.0    :: Double
          newGain    = 0.3    :: Double
          newSinkBus = 2      :: Int

      rtUnRaw <- case lowerGraph chain >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      rtF  <- case lowerGraph chain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      assertBool "Phase 4.B: fused compile has no RNoiseLpfGainOut region"
        (any ((== RNoiseLpfGainOut) . rrKernel) (rgRuntimeRegions rtF))

      let rtUn = stripRegionKernels rtUnRaw

          ixOf k rg =
            let NodeIndex i = head [rnIndex n | n <- rgNodes rg, rnKind n == k]
            in i
          lpfIx  = ixOf KLPF  rtF
          gainIx = ixOf KGain rtF
          outIx  = ixOf KOut  rtF

      let sizeOfFloat' = 4 :: Int
          renderBus loader rt readBus =
            withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
              loader handle rt
              c_rt_graph_ensure_bus handle (fromIntegral newSinkBus)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral lpfIx)  0 (CDouble newLpfFreq)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral lpfIx)  1 (CDouble newLpfQ)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral gainIx) 0 (CDouble newGain)
              c_rt_graph_instance_set_control handle 0
                (fromIntegral outIx)  0 (CDouble (fromIntegral newSinkBus))
              c_rt_graph_process handle (fromIntegral nframes)
              allocaBytes (nframes * sizeOfFloat') $ \buf -> do
                _ <- c_rt_graph_read_bus handle (fromIntegral readBus)
                                         (fromIntegral nframes) (castPtr buf)
                cs <- peekArray nframes (buf :: PtrCFloat)
                pure (map (\(CFloat x) -> x) cs)

      baselineSamples <- renderBus loadRuntimeGraph      rtUn newSinkBus
      fusedSamples    <- renderBus loadRuntimeGraphFused rtF  newSinkBus

      length baselineSamples @?= length fusedSamples
      assertBool
        ("Phase 4.B: RNoiseLpfGainOut set_control divergence on bus "
         <> show newSinkBus)
        (baselineSamples == fusedSamples)

      -- Sanity: filtered noise scaled by 0.3 through an LPF at
      -- 1500 Hz must produce non-silent output on the redirected
      -- bus. Same loose-peak threshold as the BusIn variant.
      let peak = maximum (map abs baselineSamples)
      assertBool ("expected non-silent render on bus " <> show newSinkBus
                  <> ", got peak " <> show peak)
                 (peak > 0.05)

  , testCase "BusOut → BusIn round-trip preserves the SinOsc signal" $ do
      -- A SinOsc writes to bus 5 via BusOut; a BusIn reads bus 5; that
      -- read is gain-attenuated and sent to hardware bus 0. We then
      -- read bus 0 and check we hear the original sine, halved.
      --
      -- This exercises:
      --   * E_r ordering: BusOut(5) must execute before BusIn(5).
      --   * Same-cycle semantics: BusIn sees the live, accumulated value.
      --   * Bus pool unification: bus 5 lives in the same pool as bus 0.
      let nframes = 256
          graph = runSynth $ do
            o      <- sinOsc 440.0 0.0
            busOut 5 o
            tap    <- busIn 5
            scaled <- gain tap 0.5
            out 0 scaled

      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          let peak = maximum (map (\(CFloat x) -> abs x) cs)
          -- Original SinOsc has peak 1.0, gain 0.5 halves it. If E_r
          -- ordering broke and BusIn ran before BusOut, the bus would
          -- still be zero and the peak would be ~0.
          assertBool ("expected peak ≈ 0.5 from BusOut→BusIn round-trip, got " <> show peak)
                     (abs (peak - 0.5) < 0.05)

  , testCase "Out and BusOut writing to the same bus sum (unified pool)" $ do
      -- Pins the unified-pool model: a bus written by Out and a bus
      -- written by BusOut targeting the same bus number share the
      -- same memory and accumulate together. If the runtime ever
      -- regressed to two pools, this test would catch it.
      --
      -- SinOsc → Out 0 (peak ≈ 1) AND SinOsc' → BusOut 0 (peak ≈ 1)
      -- on the same bus number. The bus pool is unified, so the read
      -- of bus 0 should see the sum (peak ≈ 2).
      let nframes = 256
          graph = runSynth $ do
            o1 <- sinOsc 440.0 0.0
            o2 <- sinOsc 440.0 0.0
            out 0 o1
            busOut 0 o2

      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          let peak = maximum (map (\(CFloat x) -> x) cs)
          assertBool
            ("expected Out + BusOut to sum to peak ≈ 2 on shared bus 0, got "
              <> show peak)
            (peak > 1.5 && peak < 2.1)

  , testCase "two BusIn readers on the same bus see the same value (fan-out)" $ do
      -- BusIn 5 read by two consumers; both should see the live value.
      -- We feed each into a Gain (one ×0.3, one ×0.7) and route both
      -- to the hardware via separate Out channels, then check that
      -- the reads were *of the same source* by recovering their sum
      -- on bus 0 — peak should be (0.3 + 0.7) × 1 = 1.0.
      let nframes = 256
          graph = runSynth $ do
            o      <- sinOsc 440.0 0.0
            busOut 5 o
            tap1   <- busIn 5
            tap2   <- busIn 5
            g1     <- gain tap1 0.3
            g2     <- gain tap2 0.7
            out 0 g1
            out 0 g2  -- accumulates onto bus 0 with g1

      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          let peak = maximum (map (\(CFloat x) -> abs x) cs)
          assertBool
            ("expected (0.3 + 0.7) × SinOsc peak ≈ 1.0, got " <> show peak)
            (abs (peak - 1.0) < 0.05)

  , testCase "BusInDelayed: one-block delay end-to-end through the FFI" $ do
      -- The Haskell-side counterpart to the C++ "BusInDelayed reads
      -- the previous block's BusOut contents" test. Renders two
      -- consecutive blocks of the same graph and asserts:
      --
      --   * On block 1, BusInDelayed reads zero (no previous block),
      --     so Out(0) is silence.
      --   * On block 2, BusInDelayed reads what BusOut wrote during
      --     block 1, so Out(0) on block 2 is bit-identical to bus 5
      --     on block 1.
      --
      -- This pins the entire Phase 2 path: the C++ swap, the
      -- BusReadDelayed effect being excluded from E_r, the schedule
      -- placing BusInDelayed wherever it falls, the FFI marshalling
      -- of KBusInDelayed, and the runtime kernel reading from
      -- output_buses_prev.
      let nframes = 128
          maxFrames = nframes
          graph = runSynth $ do
            o   <- sinOsc 440.0 0.0
            busOut 5 o
            tap <- busInDelayed 5
            out 0 tap
      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      let readBus handle bus n = allocaBytes (n * sizeOfFloat) $ \buf -> do
            _  <- c_rt_graph_read_bus handle (fromIntegral bus)
                                      (fromIntegral n) (castPtr buf)
            cs <- peekArray n (buf :: PtrCFloat)
            pure (map (\(CFloat x) -> x) cs)

      withRTGraph (length (rgNodes rt)) maxFrames $ \handle -> do
        loadRuntimeGraph handle rt

        -- Block 1.
        c_rt_graph_process handle (fromIntegral nframes)
        block1Out  <- readBus handle 0 nframes
        block1Bus5 <- readBus handle 5 nframes

        let peak1 = maximum (map abs block1Out)
        assertBool
          ("block 1 should be silence (snapshot is zero), got peak " <> show peak1)
          (peak1 < 1e-5)
        let peakBus5 = maximum (map abs block1Bus5)
        assertBool
          ("block 1's BusOut should still write a real sine to bus 5, got peak "
            <> show peakBus5)
          (peakBus5 > 0.9)

        -- Block 2.
        c_rt_graph_process handle (fromIntegral nframes)
        block2Out <- readBus handle 0 nframes

        let maxDiff = maximum (zipWith (\a b -> abs (a - b)) block1Bus5 block2Out)
        assertBool
          ("block 2's BusInDelayed must reproduce block 1's bus 5; max diff = "
            <> show maxDiff)
          (maxDiff < 1e-5)

  , testCase "delayL: 5ms delay shifts a SinOsc output by ~240 samples" $ do
      -- Render one block of a SinOsc → delayL 0.01 (max) ~ 0.005 (time)
      -- → Out chain. The kernel's q::delay maps time*sps to a
      -- fractional read index that produces (time*sps + 1) samples of
      -- effective delay. At sps=48000, 5ms ≈ 240 samples.
      --
      -- The first ~240 output samples should be silence (the buffer
      -- still holds zeros). After that, the SinOsc output appears.
      -- We allow ±2 samples of slop and only assert that:
      --
      --   * a clear silence-then-signal transition exists
      --   * the transition lands within 240 ± 5 samples
      --   * post-transition the peak resembles a sine (≈ 1.0)
      --
      -- This is the FFI-level proof that the delay UGen survives
      -- marshalling, configures the q::delay buffer at load, and
      -- produces correct output across the boundary.
      let nframes = 1024
          sps :: Double
          sps = 48000.0
          delaySec = 0.005
          expectedDelay = round (delaySec * sps) :: Int   -- 240
          graph = runSynth $ do
            o <- sinOsc 440.0 0.0
            d <- delayL 0.01 o (Param delaySec)
            out 0 d
      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _  <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                    (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          let samples = map (\(CFloat x) -> x) cs

              -- Locate the silence→signal transition point.
              isSilent x = abs x < 0.05
              transition = length (takeWhile isSilent samples)

          assertBool
            ("expected silence-then-signal transition near sample "
              <> show expectedDelay <> ", got transition at " <> show transition)
            (abs (transition - expectedDelay) <= 5)

          -- Post-transition the SinOsc shape should be intact (peak ~1).
          let postDelay = drop (transition + 20) samples
              peakPost  = maximum (map abs postDelay)
          assertBool
            ("expected post-delay peak ≈ 1.0, got " <> show peakPost)
            (abs (peakPost - 1.0) < 0.05)

  , testCase "smooth: Param target seeds the smoother to steady state" $ do
      -- End-to-end FFI proof for Phase 3.3c. Smooth wraps
      -- q::dynamic_smoother and seeds its IIR state to the first
      -- input sample on the first process call, so a fresh graph
      -- with a constant Param target should emit that target value
      -- across the entire first block — no "ramp from zero" attack.
      let nframes = 256
          target  = 0.5 :: Float
          graph   = runSynth $ do
            s <- smooth 20.0 (Param (realToFrac target))
            out 0 s

      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          let samples = map (\(CFloat x) -> x) cs
              maxDev  = maximum (map (\x -> abs (x - target)) samples)
          assertBool
            ("smooth seeded steady-state should hold target " <> show target
              <> " across the whole block, got max deviation " <> show maxDev)
            (maxDev < 1e-4)

  , testCase "Env(gate=0) idle stays silent" $ do
      let nframes = 256
          graph = runSynth $ do
            e <- env (Param 0.0) (Param 0.01) (Param 0.05) (Param 0.5) (Param 0.1)
            out 0 e

      rt <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          let peak = maximum (map (\(CFloat x) -> abs x) cs)
          assertBool ("idle envelope should be silent, got peak " <> show peak)
                     (peak < 1e-6)

  -- ----------------------------------------------------------------
  -- Multi-template loading (§2.D.3)
  -- ----------------------------------------------------------------
  --
  -- These tests exercise loadTemplateGraph end-to-end: a
  -- TemplateGraph compiled by compileTemplateGraph is transferred
  -- across the FFI, the C-side process_graph runs templates in
  -- registration order with one auto-spawned instance per template,
  -- and bus reads confirm both per-template independence and
  -- cross-template routing through the shared bus pool.

  , testCase "loadTemplateGraph: single-template ensemble runs identically to loadRuntimeGraph" $ do
      let nframes = 256
          single  = runSynth $ do
            o <- sinOsc 440.0 0.0
            out 0 o

      -- Reference: legacy loadRuntimeGraph path.
      rt <- case lowerGraph single >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      legacyBus <- withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraph handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          pure (map (\(CFloat x) -> x) cs)

      -- Multi-template path with a one-template ensemble.
      tg <- case compileTemplateGraph [("solo", single)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      tgBus <- withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadTemplateGraph handle tg
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          pure (map (\(CFloat x) -> x) cs)

      -- Both paths must produce bit-identical samples: the spec
      -- defaults loadTemplateGraph writes via
      -- rt_graph_template_set_default propagate to the auto-spawned
      -- instance, so the resulting RTGraph state is equivalent to
      -- the legacy single-template setup.
      assertBool "single-template ensemble should match legacy load"
                 (legacyBus == tgBus)

  , -- Step C (e) coverage: 'loadTemplateGraphFused' has its own
    -- lifecycle (remove auto-instance, populate per-template, spawn
    -- after fused wiring) distinct from the single-template fused
    -- loader. Pin that a fused single-template ensemble loaded
    -- through the multi-template fused path renders bit-identically
    -- to the same fused graph loaded through the single-template
    -- fused path. This exercises:
    --   * cTid 0 path for the first (and only) template.
    --   * Fused-input wiring before instance spawn — make_instance
    --     picks up the spec's full fused_input_count.
    --   * Elision marking against template id 0.
    testCase "loadTemplateGraphFused: single-template ensemble matches loadRuntimeGraphFused" $ do
      -- 'Env' source: durable §4.C-only fixture. The test
      -- specifically wants §4.C's RFused-on-Out wiring exercised
      -- through the single-template ensemble path, with no
      -- chance of §4.B claiming the chain instead.
      let nframes = 256
          fusedChain = runSynth $ do
            o <- env (Param 1.0) 0.0005 0.002 1.0 0.002
            a <- gain o (Param 0.5)
            out 0 a

      rt <- case lowerGraph fusedChain >>= compileRuntimeGraphFused of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      -- Sanity: the fused compile actually produced fused signals
      -- so the test exercises the new loader passes.
      assertBool "fused chain produced no RFused inputs"
        (not (null [() | n <- rgNodes rt, RFused _ <- rnInputs n]))
      assertBool "fused chain elided no nodes"
        (any rnElided (rgNodes rt))

      singleBus <- withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadRuntimeGraphFused handle rt
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          pure (map (\(CFloat x) -> x) cs)

      tg <- case compileTemplateGraphFused [("solo", fusedChain)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      -- The fused TemplateGraph must actually carry RFused inputs
      -- and elided nodes; otherwise loadTemplateGraphFused's new
      -- passes never run and a regression in them slips past.
      let tgRg = tplGraph (head (tgTemplates tg))
      assertBool "fused TemplateGraph carried no RFused inputs"
        (not (null [() | n <- rgNodes tgRg, RFused _ <- rnInputs n]))
      assertBool "fused TemplateGraph elided no nodes"
        (any rnElided (rgNodes tgRg))

      tgBus <- withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
        loadTemplateGraphFused handle tg
        c_rt_graph_process handle (fromIntegral nframes)
        allocaBytes (nframes * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                   (castPtr buf)
          cs <- peekArray nframes (buf :: PtrCFloat)
          pure (map (\(CFloat x) -> x) cs)

      assertBool "fused single-template ensemble should match fused single load"
                 (singleBus == tgBus)

  , testCase "loadTemplateGraph: registers N templates with N instances" $ do
      -- A two-template ensemble. Both produce independent SinOsc
      -- voices on different hardware buses.
      let voiceA = runSynth $ do
            o <- sinOsc 220.0 0.0
            out 0 o
          voiceB = runSynth $ do
            o <- sinOsc 660.0 0.0
            out 1 o

      tg <- case compileTemplateGraph [("a", voiceA), ("b", voiceB)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes = sum (map (length . rgNodes . tplGraph)
                                (tgTemplates tg))

      withRTGraph totalNodes 256 $ \handle -> do
        loadTemplateGraph handle tg

        -- After loading: two templates, two live instances (one per
        -- template). The auto-created instance 0 from rt_graph_clear
        -- was removed by loadTemplateGraph, so instance ids are 0
        -- and 1, both alive.
        nT <- c_rt_graph_template_count handle
        nT @?= 2
        nI <- c_rt_graph_instance_count handle
        nI @?= 2
        a0 <- c_rt_graph_instance_alive handle 0
        a1 <- c_rt_graph_instance_alive handle 1
        a0 @?= 1
        a1 @?= 1

        c_rt_graph_process handle 256
        allocaBytes (256 * sizeOfFloat) $ \buf -> do
          -- Bus 0: voice A's 220 Hz sine.
          _ <- c_rt_graph_read_bus handle 0 256 (castPtr buf)
          cs0 <- peekArray 256 (buf :: PtrCFloat)
          let peak0 = maximum (map (\(CFloat x) -> abs x) cs0)
          assertBool ("bus 0 (voice A) should sing, peak=" <> show peak0)
                     (peak0 > 0.9)

          -- Bus 1: voice B's 660 Hz sine.
          _ <- c_rt_graph_read_bus handle 1 256 (castPtr buf)
          cs1 <- peekArray 256 (buf :: PtrCFloat)
          let peak1 = maximum (map (\(CFloat x) -> abs x) cs1)
          assertBool ("bus 1 (voice B) should sing, peak=" <> show peak1)
                     (peak1 > 0.9)

  , -- Phase 4.B: 'RBusInLpfGainOut' end-to-end through a real
    -- multi-template send/return. The /fx/ template's
    -- @[BusIn, LPF, Gain, Out]@ chain is what the survey's
    -- BusIn-rooted opportunity scan was tracking; this test pins
    -- bit-equivalence between the kernel and the per-node baseline
    -- /through the actual cross-template loader path/, not just a
    -- single-graph approximation.
    --
    -- 'compileTemplateGraph' compiles each template through
    -- 'compileRuntimeGraph' (which runs 'selectRegionKernels'
    -- unconditionally), so the fx template's chain claims
    -- 'RBusInLpfGainOut' on the fused side. The baseline strips
    -- region kernels per template — same TemplateGraph shape, just
    -- per-node dispatch — so the comparison isolates the kernel's
    -- output from any other change.
    testCase "loadTemplateGraph: cross-template send/return claims RBusInLpfGainOut bit-equivalently" $ do
      let nframes = 256
          voice = runSynth $ do
            o <- sinOsc 440.0 0.0
            busOut 5 o                            -- voice template writes bus 5
          fx = runSynth $ do
            r <- busIn 5
            f <- lpf r (Param 1500.0) (Param 4.0)
            a <- gain f (Param 0.6)
            out 0 a                               -- fx-tail kernel sinks to bus 0

      tg <- case compileTemplateGraph [("voice", voice), ("fx", fx)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      -- Sanity: the fx template's chain claims RBusInLpfGainOut.
      -- If this assertion fires, the test isn't testing what it
      -- claims (a future kernel-precondition tightening might have
      -- silently disclaimed the chain).
      let fxTpl = head [t | t <- tgTemplates tg, tplName t == "fx"]
          fxKernels = map rrKernel (rgRuntimeRegions (tplGraph fxTpl))
      assertBool "fx template should carry an RBusInLpfGainOut region"
        (RBusInLpfGainOut `elem` fxKernels)

      -- Stripped TemplateGraph: same shape, kernels forced to
      -- RNodeLoop. Per-node dispatch on the C side; bit-equivalent
      -- baseline by construction.
      let strippedTg = tg
            { tgTemplates =
                [ tpl { tplGraph = stripRegionKernels (tplGraph tpl) }
                | tpl <- tgTemplates tg ]
            }

      let totalNodes = sum (map (length . rgNodes . tplGraph)
                                (tgTemplates tg))
          renderTg label thisTg =
            withRTGraph totalNodes nframes $ \handle -> do
              loadTemplateGraph handle thisTg
              c_rt_graph_process handle (fromIntegral nframes)
              allocaBytes (nframes * sizeOfFloat) $ \buf -> do
                _ <- c_rt_graph_read_bus handle 0 (fromIntegral nframes)
                                         (castPtr buf)
                cs <- peekArray nframes (buf :: PtrCFloat)
                pure (label, map (\(CFloat x) -> x) cs)

      (_, fusedSamples)    <- renderTg "fused"    tg
      (_, baselineSamples) <- renderTg "baseline" strippedTg

      length fusedSamples @?= length baselineSamples
      assertBool
        ("RBusInLpfGainOut (template path): kernel diverges from "
         <> "per-node baseline on bus 0")
        (fusedSamples == baselineSamples)

      -- Sanity: the fx chain actually processes the voice signal
      -- — we want a non-silent render so any future regression
      -- where the kernel reads zeros (e.g. wrong source bus) shows
      -- up as a peak collapse, not as silently-bit-equivalent
      -- silence.
      let peak = maximum (map abs fusedSamples)
      assertBool ("expected non-silent send/return on bus 0, peak="
                  <> show peak)
                 (peak > 0.05)

  , testCase "loadTemplateGraph: cross-template routing (BusOut → BusIn through shared pool)" $ do
      -- Producer template writes a SinOsc to bus 5; consumer
      -- template reads bus 5 and routes to hardware bus 0. This is
      -- the headline §2.D.3 use case: two MetaDefs, server-global
      -- bus pool, compileTemplateGraph orders producer before
      -- consumer because consumer's read-set intersects producer's
      -- write-set.
      let producer = runSynth $ do
            o <- sinOsc 330.0 0.0
            busOut 5 o
          consumer = runSynth $ do
            t <- busIn 5
            out 0 t

      tg <- case compileTemplateGraph
                   [("consumer", consumer), ("producer", producer)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      -- compileTemplateGraph should have re-ordered: producer
      -- before consumer, regardless of input order.
      map tplName (tgTemplates tg) @?= ["producer", "consumer"]

      let totalNodes = sum (map (length . rgNodes . tplGraph)
                                (tgTemplates tg))

      withRTGraph totalNodes 256 $ \handle -> do
        loadTemplateGraph handle tg
        c_rt_graph_process handle 256

        allocaBytes (256 * sizeOfFloat) $ \buf -> do
          _ <- c_rt_graph_read_bus handle 0 256 (castPtr buf)
          cs <- peekArray 256 (buf :: PtrCFloat)
          let peak = maximum (map (\(CFloat x) -> abs x) cs)
          assertBool
            ("hardware bus 0 should carry the routed signal, peak="
              <> show peak)
            (peak > 0.9)

  , testCase "loadTemplateGraph: extra instances spawned post-load share the spec defaults" $ do
      -- After loadTemplateGraph spawns the initial instance per
      -- template, the user can call c_rt_graph_template_instance_add
      -- to spawn more instances of the same template. Those new
      -- instances inherit the spec defaults that
      -- rt_graph_template_set_default wrote during loading.
      let voice = runSynth $ do
            o <- sinOsc 440.0 0.0
            out 0 o

      tg <- case compileTemplateGraph [("voice", voice)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes = length (rgNodes (tplGraph (head (tgTemplates tg))))

      withRTGraph totalNodes 256 $ \handle -> do
        loadTemplateGraph handle tg

        -- Spawn a second instance of template 0. Should land at
        -- slot 1 (slot 0 is the auto-spawned one).
        i2 <- c_rt_graph_template_instance_add handle 0
        i2 @?= 1

        -- Reroute the second instance to bus 1 so its contribution
        -- is observable on its own. (Both instances default to
        -- bus 0, so they would otherwise sum.)
        --
        -- Out node is at index 1; control 0 is the bus index.
        c_rt_graph_instance_set_control handle 1 1 0 1.0

        c_rt_graph_process handle 256
        allocaBytes (256 * sizeOfFloat) $ \buf -> do
          -- Bus 0: original instance's 440 Hz sine.
          _ <- c_rt_graph_read_bus handle 0 256 (castPtr buf)
          cs0 <- peekArray 256 (buf :: PtrCFloat)
          let peak0 = maximum (map (\(CFloat x) -> abs x) cs0)
          assertBool ("bus 0 should sing, peak=" <> show peak0)
                     (peak0 > 0.9)

          -- Bus 1: second instance's 440 Hz sine (same spec
          -- default, different output bus).
          _ <- c_rt_graph_read_bus handle 1 256 (castPtr buf)
          cs1 <- peekArray 256 (buf :: PtrCFloat)
          let peak1 = maximum (map (\(CFloat x) -> abs x) cs1)
          assertBool
            ("bus 1 (second instance) should also sing, peak="
              <> show peak1)
            (peak1 > 0.9)

  , testCase "§2.E release-then-free: Live → Releasing → freed slot" $ do
      -- Smoke test for the §2.E lifecycle FFI surface
      -- (c_rt_graph_instance_release, c_rt_graph_instance_status):
      --   1. status is Live after load,
      --   2. flips to Releasing on release(),
      --   3. the slot is auto-freed once the envelope tail decays
      --      below the runtime's silence threshold for a small
      --      window (status -> -1, alive -> 0).
      -- See Note [§2.E: release-then-free instance lifecycle] in
      -- rt_graph.cpp for the design.
      let voice = runSynth $ do
            -- Held gate (1.0), short release so the test runs in
            -- a few dozen blocks rather than seconds.
            e <- env 1.0 0.0005 0.002 0.5 0.002
            out 0 e

      let rg = case lowerGraph voice >>= compileRuntimeGraph of
            Right r  -> r
            Left err -> error err
          totalNodes = length (rgNodes rg)

      withRTGraph totalNodes 256 $ \handle -> do
        loadRuntimeGraph handle rg

        -- Pre-release: the auto-spawned instance 0 is Live.
        s0 <- c_rt_graph_instance_status handle 0
        s0 @?= instanceStatusLive

        -- Render one block so the envelope leaves idle and reaches
        -- sustain. (Releasing an idle envelope is a degenerate case
        -- — q's release() is a no-op when the gate never opened.)
        c_rt_graph_process handle 256

        -- Trigger release. Status flips immediately; slot stays
        -- alive because the tail still has to render.
        c_rt_graph_instance_release handle 0
        s1 <- c_rt_graph_instance_status handle 0
        s1 @?= instanceStatusReleasing
        a1 <- c_rt_graph_instance_alive handle 0
        a1 @?= 1

        -- Drive blocks until the runtime auto-frees the slot. With
        -- R = 2 ms and silence-window = 8 blocks of 256 frames at
        -- 48 kHz, ~64 blocks is a comfortable upper bound.
        let drain n
              | n <= 0    = pure False
              | otherwise = do
                  c_rt_graph_process handle 256
                  alive <- c_rt_graph_instance_alive handle 0
                  if alive == 0 then pure True else drain (n - 1)
        freed <- drain 64
        assertBool "instance should auto-free within 64 blocks" freed

        -- Post-free: status is -1 (dead/invalid).
        s2 <- c_rt_graph_instance_status handle 0
        s2 @?= (-1)

  , -- Phase 4.B sink-terminal kernel × §2.E release lifecycle.
    -- The 'process_region_sin_gain_out' kernel takes over the bus
    -- accumulation /and/ the per-block 'inst.block_sink_peak'
    -- update from 'process_out'. §2.E silence detection reads
    -- block_sink_peak after each instance runs; a kernel that
    -- forgot to update it would either free voices too early
    -- (peak under-reported) or never (peak stuck at the last
    -- value).
    --
    -- Both variants register an RSinGainOut region and an Env on
    -- a separate bus. The Env's release decay drives the §2.E
    -- state machine; the kernel's gain control determines whether
    -- the fused chain contributes to peak.
    --
    --   variantA: gain = 0.0  → kernel writes silence; once Env
    --             tail decays, peak < threshold, voice frees.
    --   variantB: gain = 0.5  → kernel writes |sin|·0.5 ≈ 0.5
    --             every block, /forever/. Even after Env decays,
    --             the kernel's contribution keeps peak above the
    --             silence threshold and the voice never frees.
    --
    -- A bug where the kernel didn't update block_sink_peak at all
    -- would flip variantB to "frees" — caught here.
    testCase "Phase 4.B kernel: sink-peak tracking gates §2.E release-then-free" $ do
      let mkVoice scalarGain = runSynth $ do
            s <- sinOsc 440.0 0.0
            a <- gain s (Param scalarGain)
            out 1 a                      -- kernel chain on bus 1
            e <- env 1.0 0.0005 0.002 0.5 0.002
            out 0 e                       -- env on bus 0

          driveAndDrain g maxBlocks = do
            let rg = case lowerGraph g >>= compileRuntimeGraph of
                  Right r  -> r
                  Left err -> error err
                totalNodes = length (rgNodes rg)
            -- Sanity: §4.B is actually claiming the kernel chain.
            assertBool "voice does not contain RSinGainOut region"
              (any ((== RSinGainOut) . rrKernel) (rgRuntimeRegions rg))
            withRTGraph totalNodes 256 $ \handle -> do
              loadRuntimeGraph handle rg
              -- One block to leave envelope-idle and reach sustain.
              c_rt_graph_process handle 256
              c_rt_graph_instance_release handle 0
              let drain n
                    | n <= 0    = pure False
                    | otherwise = do
                        c_rt_graph_process handle 256
                        alive <- c_rt_graph_instance_alive handle 0
                        if alive == 0 then pure True else drain (n - 1)
              drain maxBlocks

      freedSilent <- driveAndDrain (mkVoice 0.0) 64
      assertBool
        "variantA (silent kernel + Env): voice should auto-free within 64 blocks"
        freedSilent

      freedAudible <- driveAndDrain (mkVoice 0.5) 64
      assertBool
        "variantB (audible kernel + Env): voice must NOT free — kernel keeps sink-peak above threshold"
        (not freedAudible)
  ]
  where
    sizeOfFloat = 4 :: Int

    checkAt sr tau samples i = do
      let n        = fromIntegral i :: Double
          t        = n / sr
          expected = sin (tau * 440.0 * t)
          actual   = realToFrac (samples !! i) :: Double
      assertBool
        ("sample " <> show i <> " expected " <> show expected
         <> ", got " <> show actual)
        (abs (actual - expected) < 0.05)

type PtrCFloat = Ptr CFloat

runtimeGraphBuilderCapacity :: RuntimeGraph -> Int
runtimeGraphBuilderCapacity = length . rgNodes

templateGraphBuilderCapacity :: TemplateGraph -> Int
templateGraphBuilderCapacity =
  sum . map (length . rgNodes . tplGraph) . tgTemplates

------------------------------------------------------------
-- Step C (f): fused render equivalence cases + helper
------------------------------------------------------------

-- | Demo-shaped graphs that all contain at least one fusable Gain.
-- 'assertFusedEquivalent' renders each one through the unfused and
-- fused FFI loaders and asserts bit-for-bit sample equality. Cases
-- that don't fuse (no scalar Gain, e.g. NoiseGen-only chains, or
-- audio-modulated gain) are excluded — they would pass trivially
-- because 'fuseRuntimeGraph' is a no-op on them.
fusedEquivalenceCases :: [(String, SynthGraph)]
fusedEquivalenceCases =
  [ ("chain", runSynth $ do
       o <- sinOsc 440.0 0.0
       a <- gain o (Param 0.5)
       out 0 a)

  , ("fanout (two scalar Gains share a SinOsc)", runSynth $ do
       o  <- sinOsc 440.0 0.0
       g1 <- gain o (Param 0.5)
       g2 <- gain o (Param 0.3)
       out 0 g1
       out 1 g2)

  , ("saw → lpf → scalar gain → out", runSynth $ do
       s <- sawOsc 110.0 0.0
       f <- lpf s (Param 800.0) (Param 4.0)
       a <- gain f (Param 0.4)
       out 0 a)

    -- BusOut as sink terminal. The §4.B sink-terminal kernels
    -- ('RSinGainOut' / 'RSawLpfGainOut') accept either KOut or
    -- KBusOut at the terminal slot. Both render paths (kernel
    -- fused vs stripRegionKernels node-loop baseline) read the
    -- bus index from controls[0] and accumulate into the same
    -- bus pool, so bit-equivalence on the resulting bus is the
    -- structural pin that the kernel body really is bus-kind-
    -- agnostic (i.e. that the dispatch guard and the kernel
    -- agree on what "sink" means).
  , ("§4.B sink-terminal via busOut: sin → gain → busOut", runSynth $ do
       o <- sinOsc 440.0 0.0
       a <- gain o (Param 0.5)
       busOut 0 a)

  , ("§4.B sink-terminal via busOut: saw → lpf → gain → busOut", runSynth $ do
       s <- sawOsc 110.0 0.0
       f <- lpf s (Param 800.0) (Param 4.0)
       a <- gain f (Param 0.4)
       busOut 0 a)

    -- 'RSawGainOut' coverage: the saw counterpart of the
    -- 'RSinGainOut' chain case. q::saw with poly-BLEP × scalar
    -- gain → bus accumulation. Bit-identical to the per-node
    -- chain (process_sawosc + process_gain + process_out) by
    -- construction.
  , ("§4.B sink-terminal: saw → gain → out", runSynth $ do
       s <- sawOsc 110.0 0.0
       a <- gain s (Param 0.4)
       out 0 a)

  , ("§4.B sink-terminal via busOut: saw → gain → busOut", runSynth $ do
       s <- sawOsc 110.0 0.0
       a <- gain s (Param 0.4)
       busOut 0 a)

    -- 'RNoiseGainOut' coverage. Different state class than the
    -- oscillator kernels: NoiseGen carries a 'q::white_noise_gen'
    -- xorshift PRNG. The kernel calls 'noise()' once per output
    -- sample — same cadence as 'process_noisegen' — so two
    -- compiles of the same graph see identical PRNG sequences.
    -- 'assertFusedEquivalent' compares against a
    -- 'stripRegionKernels' baseline that drives the same fresh
    -- 'NoiseGenState' through 'process_noisegen', so any drift
    -- in PRNG-advance cadence between the kernel and per-node
    -- paths shows up as a sample-level diff. This is the
    -- load-bearing equivalence pin for the noise kernel.
  , ("§4.B sink-terminal: noise → gain → out", runSynth $ do
       n <- noiseGen
       a <- gain n (Param 0.4)
       out 0 a)

  , ("§4.B sink-terminal via busOut: noise → gain → busOut", runSynth $ do
       n <- noiseGen
       a <- gain n (Param 0.4)
       busOut 0 a)

    -- 'RBusInLpfGainOut' coverage. The first non-oscillator
    -- producer kernel: source is a bus reader, not a generator.
    -- The fused kernel reads 'output_buses[busin_bus][i]' inline
    -- (mirroring 'process_busin's std::copy_n + per-node LPF +
    -- per-node Gain + per-node Out); the stripped baseline runs
    -- those same per-node steps in sequence. Bit-equivalence on
    -- the sink bus pins that the inlined bus read produces the
    -- same float as the materialized 'process_busin' copy would
    -- have, in the same per-sample order.
    --
    -- We pair a BusOut writer with the BusIn reader in the same
    -- graph (bus 5 carries a SinOsc) so the chain processes a
    -- real signal rather than silence from an unwritten bus —
    -- otherwise the test would degenerate into "fused silence ==
    -- baseline silence", which is too weak to catch a per-sample
    -- divergence introduced by a future change.
  , ("§4.B sink-terminal: busIn → lpf → gain → out", runSynth $ do
       o <- sinOsc 440.0 0.0
       busOut 5 o                              -- voice side: bus 5 carries the carrier
       r <- busIn 5
       f <- lpf r (Param 1500.0) (Param 4.0)
       a <- gain f (Param 0.6)
       out 0 a)                                -- fx-tail kernel sinks to bus 0

  , ("§4.B sink-terminal via busOut: busIn → lpf → gain → busOut", runSynth $ do
       o <- sinOsc 440.0 0.0
       busOut 5 o
       r <- busIn 5
       f <- lpf r (Param 1500.0) (Param 4.0)
       a <- gain f (Param 0.6)
       busOut 1 a)                             -- BusOut as absorbed terminal

    -- 'RNoiseLpfGainOut' coverage. PRNG-cadence parity is the
    -- load-bearing invariant: 'process_region_noise_lpf_gain_out'
    -- calls 'noisegen->noise()' exactly once per output sample, in
    -- the same order 'process_noisegen' does, before recentering
    -- and feeding the LPF. The stripped baseline drives the same
    -- fresh 'NoiseGenState' through 'process_noisegen' frame-by-
    -- frame, so any drift in PRNG-advance cadence between fused
    -- and per-node paths shows up as a sample-level diff in the
    -- bus accumulation. This is the equivalence pin that catches
    -- a future change accidentally double-pulling, skipping, or
    -- reordering the PRNG step relative to the LPF transition.
  , ("§4.B sink-terminal: noise → lpf → gain → out", runSynth $ do
       n <- noiseGen
       f <- lpf n (Param 1200.0) (Param 4.0)
       a <- gain f (Param 0.3)
       out 0 a)

  , ("§4.B sink-terminal via busOut: noise → lpf → gain → busOut", runSynth $ do
       n <- noiseGen
       f <- lpf n (Param 1200.0) (Param 4.0)
       a <- gain f (Param 0.3)
       busOut 0 a)                             -- BusOut as absorbed terminal

  , ("ring mod (audio-mod gain stays dispatched, output gain fuses)", runSynth $ do
       c <- sinOsc 440.0 0.0
       m <- sinOsc 73.0  0.0
       r <- gain c m              -- audio-modulated: no fusion (kept dispatched)
       a <- gain r (Param 0.5)    -- scalar: fuses
       out 0 a)

  , ("fm carrier with scalar output gain", runSynth $ do
       lfo <- sinOsc 6.0 0.0
       dev <- gain lfo (Param 8.0)        -- scalar dev gain: fuses into carrier.freq
       car <- sinOsc dev 0.0
       a   <- gain car (Param 0.4)        -- scalar output gain: fuses into Out
       out 0 a)

  -- Chain extension cases. Two and three consecutive scalar Gains
  -- collapse into one fused chain on Out's input. The fused
  -- resolver must apply each scale in source-to-sink order and
  -- cast control to float per step (no pre-multiplication), so
  -- the rendered samples must be bit-identical to the unfused
  -- chain of process_gain kernels.
  , ("scalar Gain chain x2", runSynth $ do
       o  <- sinOsc 440.0 0.0
       a1 <- gain o  (Param 0.5)
       a2 <- gain a1 (Param 0.25)
       out 0 a2)

  , ("scalar Gain chain x3", runSynth $ do
       o  <- sinOsc 440.0 0.0
       a1 <- gain o  (Param 0.5)
       a2 <- gain a1 (Param 0.25)
       a3 <- gain a2 (Param 0.125)
       out 0 a3)

  -- Phase 4.C.2 affine cases. A single Add elides into FAffineFrom
  -- [AffBias _ _]; mixed Gain/Add chains compose end-to-end through
  -- one FAffineFrom on Out's input. The fused resolver applies each
  -- step in source-to-sink order with the same NaN sanitization as
  -- the unfused kernels, so output must be bit-identical.
  , ("scalar Add bias", runSynth $ do
       o <- sinOsc 440.0 0.0
       b <- add o (Param 0.1)
       out 0 b)

  , ("Add (bias on port 0)", runSynth $ do
       o <- sinOsc 440.0 0.0
       b <- add (Param 0.1) o
       out 0 b)

  , ("Gain → Add composition", runSynth $ do
       o <- sinOsc 440.0 0.0
       a <- gain o (Param 0.5)
       b <- add  a (Param 0.1)
       out 0 b)

  , ("Add → Gain composition", runSynth $ do
       o <- sinOsc 440.0 0.0
       b <- add  o (Param 0.1)
       a <- gain b (Param 0.5)
       out 0 a)

  , ("Gain → Add → Gain mixed chain", runSynth $ do
       o  <- sinOsc 440.0 0.0
       a1 <- gain o  (Param 0.5)
       b  <- add  a1 (Param 0.1)
       a2 <- gain b  (Param 0.25)
       out 0 a2)
  ]

-- | QuickCheck property: for any deterministic, renderable graph
-- produced by 'genFusableRenderableGraph', the fused runtime path
-- must render bit-identical samples to a node-loop baseline on
-- every bus the graph writes.
--
-- The point of this property is /not/ to hand-check more topology
-- shapes than the structural unit tests already do; it's to exercise
-- the contract — same dense graph identity, same FFI lifecycle, same
-- C++ resolver — over random topology, including shapes nobody
-- thought to write down. Bit-equivalence (===) is the right
-- comparison: process_gain / process_add scalar branches, the chain
-- resolver, and the affine resolver all use the same NaN-sanitized
-- @float@ casts, so any difference is a bug.
--
-- The baseline side applies 'stripRegionKernels' before render so
-- 'loadRuntimeGraph' takes the per-node dispatch path on every
-- region, even ones §4.B would have claimed. Without the strip,
-- 'compileRuntimeGraph' itself would have already tagged matching
-- regions with kernels and a broken 'process_region_*' could pass
-- by matching itself — same blind spot the named-case helper
-- 'assertFusedEquivalent' avoids.
--
-- 'cover' gates the fraction of cases that actually exercise fusion
-- on the fused path. The predicate mirrors 'assertFusedEquivalent':
-- a graph counts as fused if the fused compile produced any of (a)
-- an 'RFused' input, (b) an 'rnElided' node, or (c) a non-'RNodeLoop'
-- region. Each prong is a distinct fusion mechanism — §4.C single-
-- input rewrites contribute (a) and (b), §4.B region kernels
-- contribute (c). A predicate that only checked rnElided would
-- mis-classify minimal §4.B-only cases (e.g. sin → gain → out, which
-- the 'RSinGainOut' kernel claims before §4.C can elide the gain) as
-- "no fusion," even though they are real fused-kernel-vs-baseline
-- comparisons. This protects the property from degenerating into a
-- sanity check on two equivalent loader paths if the generator
-- later drifts away from fusable shapes. A trivial 'True' is
-- returned for graphs that compile cleanly but write no comparable
-- buses, classified separately.
prop_fusedRenderEqualsUnfused :: SynthGraph -> Property
prop_fusedRenderEqualsUnfused graph =
  case (lowerGraph graph >>= compileRuntimeGraph,
        lowerGraph graph >>= compileRuntimeGraphFused) of
    (Left e,  _      ) -> counterexample ("baseline compile failed: " <> e) False
    (_,       Left e ) -> counterexample ("fused compile failed: "    <> e) False
    (Right rtUn0, Right rtF) ->
      -- Strip region kernels from the baseline so its render takes
      -- the per-node dispatch path; rgNodes/controls are unchanged,
      -- so the bus walk below still sees every Out/BusOut.
      let rtUn  = stripRegionKernels rtUn0
          buses = nub
            [ truncate v
            | n <- rgNodes rtUn
            , rnKind n == KOut || rnKind n == KBusOut
            , v : _ <- [rnControls n]
            , v >= 0
            ] :: [Int]
          triggered = fusedSomehow rtF
       in checkCoverage
        . cover 90 triggered          "fusion triggered"
        . classify (not triggered)    "no fusion (vacuous on fused path)"
        . classify (null buses)       "no comparable bus (vacuous render)"
        $ ioProperty $
          if null buses
            then pure (property True)
            else do
              let nframes = 64
                  sizeOfFloat = 4
                  cap = max 1 (length (rgNodes rtUn))
                  render loader rt =
                    withRTGraph cap nframes $ \handle -> do
                      _ <- loader handle rt
                      c_rt_graph_process handle (fromIntegral nframes)
                      allocaBytes (nframes * sizeOfFloat) $ \buf ->
                        traverse (readBus handle buf) buses
                  readBus handle buf bus = do
                    _ <- c_rt_graph_read_bus handle (fromIntegral bus)
                                             (fromIntegral nframes) (castPtr buf)
                    cs <- peekArray nframes (buf :: PtrCFloat)
                    pure (bus, map (\(CFloat x) -> x) cs)
              baseline <- render loadRuntimeGraph      rtUn
              fused    <- render loadRuntimeGraphFused rtF
              pure $ counterexample ("buses compared: " <> show buses)
                   $ baseline === fused

-- | Force every region in a 'RuntimeGraph' back to 'RNodeLoop'.
-- 'compileRuntimeGraph' runs 'selectRegionKernels' unconditionally,
-- so the "unfused" output of 'compileRuntimeGraph' already carries
-- §4.B kernel tags. Without stripping them, an equivalence test
-- that renders @compileRuntimeGraph@ vs @compileRuntimeGraphFused@
-- would dispatch /both/ sides through 'process_region_*', and a
-- broken kernel implementation could pass by matching itself.
-- Stripping the baseline gives an honest comparison: the baseline
-- takes the per-node dispatch path while the fused side exercises
-- whichever kernels and rewrites §4.B / §4.C selected.
stripRegionKernels :: RuntimeGraph -> RuntimeGraph
stripRegionKernels rg = rg
  { rgRuntimeRegions =
      map (\r -> r { rrKernel = RNodeLoop }) (rgRuntimeRegions rg)
  }

-- | A 'RuntimeGraph' has been touched by some form of fusion if it
-- carries §4.C single-input rewrite artifacts (an 'RFused' input
-- or an 'rnElided' node) or a §4.B region-kernel claim (any
-- region whose 'rrKernel' is not 'RNodeLoop'). Used as the sanity
-- gate by both 'assertFusedEquivalent' and the random
-- 'prop_fusedRenderEqualsUnfused' so a regression in either path
-- (or a generator that drifts toward unfusable shapes) is caught
-- the same way. Centralised so the two call sites cannot drift
-- as more fusion mechanisms land.
fusedSomehow :: RuntimeGraph -> Bool
fusedSomehow rg =
  not (null [() | n <- rgNodes rg, RFused _ <- rnInputs n])
    || any rnElided (rgNodes rg)
    || any ((/= RNodeLoop) . rrKernel) (rgRuntimeRegions rg)

-- | Render @graph@ through a node-loop baseline and the fused
-- loader, asserting their outputs are bit-identical on every bus
-- the graph writes (not only bus 0). Comparing every output bus
-- catches the case where a fanout's second fused branch is
-- miswired but its sibling on bus 0 happens to match. Also
-- verifies that the fused compile actually triggered fusion (≥1
-- RFused input + ≥1 elided node, or a non-RNodeLoop region) so
-- the test isn't degenerate.
--
-- The "node-loop baseline" is the same compiled graph as the fused
-- side, except every region is forced back to 'RNodeLoop' via
-- 'stripRegionKernels' — see that helper for why this matters.
assertFusedEquivalent :: String -> SynthGraph -> Assertion
assertFusedEquivalent name graph = do
  let nframes = 256
  -- Strip kernels from the baseline so 'loadRuntimeGraph' takes the
  -- per-node dispatch path even on regions §4.B would have claimed.
  rtUn <- case lowerGraph graph >>= compileRuntimeGraph of
    Right r  -> pure (stripRegionKernels r)
    Left err -> assertFailure (name <> ": compile (node-loop baseline) failed: " <> err)
                  >> error "unreachable"
  rtF  <- case lowerGraph graph >>= compileRuntimeGraphFused of
    Right r  -> pure r
    Left err -> assertFailure (name <> ": compile (fused) failed: " <> err)
                  >> error "unreachable"

  -- Sanity gate: the fused compile must actually fuse /something/
  -- — see 'fusedSomehow' for the predicate. A graph whose fused
  -- render trivially equals the baseline render because no fusion
  -- fired isn't a useful equivalence case.
  assertBool (name <> ": fused compile triggered no fusion of any kind")
    (fusedSomehow rtF)

  -- Walk the baseline graph to collect every bus index that an Out
  -- or BusOut node writes to. rnControls[0] holds the bus id by
  -- convention (see kindSpec for KOut / KBusOut). Bus indices that
  -- both graphs write to are compared sample-for-sample; if either
  -- side renders silence on a bus the other one drives, the test
  -- fails. Stripping kernels does not change rgNodes or controls,
  -- so walking rtUn here still sees every Out the original graph
  -- declared.
  let busesWritten rg =
        nub
          [ truncate v
          | n <- rgNodes rg
          , rnKind n == KOut || rnKind n == KBusOut
          , v : _ <- [rnControls n]
          , v >= 0
          ]
      buses = busesWritten rtUn
  assertBool (name <> ": graph writes no output buses to compare")
             (not (null buses))

  let render loader rt =
        withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
          loader handle rt
          c_rt_graph_process handle (fromIntegral nframes)
          allocaBytes (nframes * sizeOfFloat) $ \buf ->
            traverse (\bus -> readBus handle bus buf) buses
      readBus handle bus buf = do
        _ <- c_rt_graph_read_bus handle (fromIntegral bus)
                                 (fromIntegral nframes) (castPtr buf)
        cs <- peekArray nframes (buf :: PtrCFloat)
        pure (bus, map (\(CFloat x) -> x) cs)

  baseline <- render loadRuntimeGraph      rtUn
  fused    <- render loadRuntimeGraphFused rtF
  assertBool
    (name <> ": fused render must match node-loop baseline on every bus "
       <> show buses)
    (baseline == fused)
  where
    -- Mirrors the local sizeOfFloat in crossCuttingTests' where-clause.
    sizeOfFloat = 4 :: Int

------------------------------------------------------------
-- Generator: well-formed SynthGraphs
------------------------------------------------------------
--
-- Strategy: generate a list of DSL operations and replay them
-- inside SynthM. Each operation that needs a source node picks
-- an index into the list of NodeIDs allocated so far, modulo
-- the current source-list length. This guarantees referential
-- integrity by construction.
--
-- The "*Mod" variants exercise audio-rate modulation paths
-- (FM, ring-mod, audio bias, audio gate to Env) that the
-- Param-only variants never touch.

data Op
  = OSinOsc    Double Double
  | OSinOscMod Int Double      -- audio-rate freq from source-idx, phase
  | OSawOsc    Double Double
  | OPulseOsc  Double Double Double
                               -- freq, phase, width
  | OPulseOscWMod Double Double Int
                               -- freq, phase, audio-source-idx -> width
                               -- (exercises the new audio-rate
                               -- intermodulation primitive)
  | OTriOsc    Double Double
  | OTriOscMod Int Double      -- audio-rate freq, phase
  | ONoise
  | OGain      Int Double      -- audio source-idx, constant gain
  | OGainMod   Int Int         -- audio × audio (ring-mod shape)
  | OLPF       Int Double Double -- source-index, cutoff, q
  | OHPF       Int Double Double -- source-index, cutoff, q
  | OBPF       Int Double Double -- source-index, center, q
  | ONotch     Int Double Double -- source-index, center, q
  | OAdd       Double Int      -- bias × audio source-idx
  | OAddMod    Int Int         -- audio + audio
  | OEnv       Int Double Double Double Double
                               -- gate-source-idx, A, D, S, R
  | OBusOut         Int Int          -- bus, audio source-index
  | OBusIn          Int              -- bus
  | OBusInDelayed   Int              -- bus (feedback-safe reader)
  | ODelay          Double Double Int
                                     -- max-time (s), time const (s), signal-idx
  | ODelayMod       Double Int Int   -- max-time (s), signal-idx, time-source-idx
  | OSmooth         Double Double    -- base-freq (Hz), constant target value
  | OSmoothMod      Double Int       -- base-freq (Hz), audio-source-idx
  | OOut            Int Int          -- channel, source-index
  deriving (Eq, Show)

genOp :: Gen Op
genOp = oneof
  [ OSinOsc    <$> choose (50, 8000) <*> choose (0.0, 1.0)
  , OSinOscMod <$> nonNegInt         <*> choose (0.0, 1.0)
  , OSawOsc    <$> choose (50, 8000) <*> choose (0.0, 1.0)
  , OPulseOsc  <$> choose (50, 8000) <*> choose (0.0, 1.0)
                                     <*> choose (0.05, 0.95)
  , OPulseOscWMod <$> choose (50, 8000) <*> choose (0.0, 1.0)
                                     <*> nonNegInt
  , OTriOsc    <$> choose (50, 8000) <*> choose (0.0, 1.0)
  , OTriOscMod <$> nonNegInt         <*> choose (0.0, 1.0)
  , pure ONoise
  , OGain    <$> nonNegInt <*> choose (0.0, 1.0)
  , OGainMod <$> nonNegInt <*> nonNegInt
  , OLPF     <$> nonNegInt <*> choose (50, 8000) <*> choose (0.1, 4.0)
  , OHPF     <$> nonNegInt <*> choose (50, 8000) <*> choose (0.1, 4.0)
  , OBPF     <$> nonNegInt <*> choose (50, 8000) <*> choose (0.1, 4.0)
  , ONotch   <$> nonNegInt <*> choose (50, 8000) <*> choose (0.1, 4.0)
  , OAdd     <$> choose (-1.0, 1.0) <*> nonNegInt
  , OAddMod  <$> nonNegInt <*> nonNegInt
  , OEnv     <$> nonNegInt
             <*> choose (0.001, 0.1) <*> choose (0.001, 0.5)
             <*> choose (0.0, 1.0)   <*> choose (0.001, 0.5)
  , OBusOut       <$> choose (0, 3) <*> nonNegInt
  , OBusIn        <$> choose (0, 3)
  , OBusInDelayed <$> choose (0, 3)
  -- Delay max-time stays bounded so the runtime allocator doesn't
  -- chase pathological buffer sizes during randomised testing. Time
  -- (the read offset) is allowed to overshoot the max occasionally;
  -- the kernel clamps. Both are exercised against propagateRates,
  -- the kindSpec arity check, and dense lowering by every property.
  , ODelay        <$> choose (0.001, 0.05)
                  <*> choose (0.0,   0.04)
                  <*> nonNegInt
  , ODelayMod     <$> choose (0.001, 0.05)
                  <*> nonNegInt <*> nonNegInt
  , OSmooth       <$> choose (5.0, 500.0)  <*> choose (-1.0, 1.0)
  , OSmoothMod    <$> choose (5.0, 500.0)  <*> nonNegInt
  , OOut          <$> choose (0, 1) <*> nonNegInt
  ]
  where
    nonNegInt = choose (0, 100)

genWellFormedGraph :: Gen SynthGraph
genWellFormedGraph = sized $ \sz -> do
  -- Cap the generator at 16 ops for fast iteration; sz=100 by default
  -- but the absolute size doesn't change the invariants we're testing.
  n   <- choose (1, max 1 (min 16 sz))
  ops <- vectorOf n genOp
  pure $ runSynth (interpret (OSinOsc 440 0 : ops))

-- | Generator for fused/unfused FFI render-equivalence: a strictly
-- deterministic, always-renderable subset of 'genWellFormedGraph'.
--
-- Three differences from 'genWellFormedGraph' that matter here:
--
--   * 'ONoise' is filtered out. The C++ 'q::white_noise_gen' is
--     seeded per 'GraphInstance', so two separate runtime handles
--     (one for the unfused render, one for the fused render) emit
--     different sample sequences even on a topologically identical
--     graph. That nondeterminism would mask any actual fusion bug.
--   * A fresh scalar Gain/Add suffix is appended and wired to bus 7,
--     guaranteeing both a non-empty bus list to compare and at least
--     one single-consumer fusion site. Random ops may add their own
--     'OOut' / 'OBusOut' on buses 0-3, and those are still compared
--     too — bus 7 is the floor, not the ceiling.
--   * The op generator is /tilted/ toward 'OGain' and 'OAdd' so a
--     reasonable fraction of random graphs actually exercise the
--     fusion machinery. Using 'genOp' raw produced ~8% fusion-
--     triggered cases (Gain and Add are 2 of ~24 uniformly-weighted
--     ops, and only some of those have rnConsumerCount == 1); the
--     guaranteed scalar suffix makes fusion coverage the expected case
--     rather than an accident of later random consumers.
--
-- Cap is smaller than 'genWellFormedGraph' (12 ops vs 16) because each
-- case round-trips through the FFI and renders 64 frames on both
-- paths.
genFusableRenderableGraph :: Gen SynthGraph
genFusableRenderableGraph = sized $ \sz -> do
  n      <- choose (0, max 1 (min 12 sz))
  ops    <- vectorOf n genFusableOp
  suffix <- genFusedConsumer
  pure $ runSynth $ do
    xs <- interpretConnections (OSinOsc 440 0 : ops)
    case reverse xs of
      []        -> pure ()  -- impossible: the seed SinOsc always appends
      src : _   -> do
        fused <- suffix src
        out 7 fused

-- | Final scalar consumer used by 'genFusableRenderableGraph' to
-- guarantee at least one fusion site. It is appended after all random
-- ops, so no later node can add a second consumer and invalidate the
-- single-consumer gate.
genFusedConsumer :: Gen (Connection -> SynthM Connection)
genFusedConsumer = oneof
  [ do k <- choose (0.05, 1.0)
       pure $ \src -> gain src (Param k)
  , do b <- choose (-1.0, 1.0)
       pure $ \src -> add src (Param b)
  , do b <- choose (-1.0, 1.0)
       pure $ \src -> add (Param b) src
  , do k <- choose (0.05, 1.0)
       b <- choose (-1.0, 1.0)
       pure $ \src -> do
         scaled <- gain src (Param k)
         add scaled (Param b)
  , do b <- choose (-1.0, 1.0)
       k <- choose (0.05, 1.0)
       pure $ \src -> do
         biased <- add src (Param b)
         gain biased (Param k)
  ]

-- | Op generator biased toward fusion candidates. 'OGain' and 'OAdd'
-- (the only two fusable kinds today) get higher weights so chains
-- and fan-outs of scalar arithmetic actually appear in the
-- distribution; the rest of 'genOp' (less 'ONoise') falls through
-- with the original uniform weighting under the remaining mass.
genFusableOp :: Gen Op
genFusableOp = frequency
  [ (3, OGain <$> choose (0, 100)        <*> choose (0.0, 1.0))
  , (3, OAdd  <$> choose (-1.0, 1.0)     <*> choose (0, 100))
  , (4, genOp `suchThat` (\o -> not (isNoise o)))
  ]
  where
    isNoise ONoise = True
    isNoise _      = False

-- | Drop one leaf node at a time. A node is a 'leaf' if no other
-- node's UGen depends on it. Each shrink produces a strictly smaller
-- graph that is still well-formed (no dangling 'NodeID' references),
-- so QuickCheck reduces a failing 16-op graph to the minimal subset
-- that still triggers the failure.
shrinkSynthGraph :: SynthGraph -> [SynthGraph]
shrinkSynthGraph g =
  [ SynthGraph (M.delete nid nodes)
  | nid <- M.keys nodes
  , isLeaf nid
  ]
  where
    nodes      = sgNodes g
    allDeps    = concatMap (dependencies . nsUgen) (M.elems nodes)
    isLeaf nid = nid `notElem` allDeps

{- Note [Generator avoids E_r cycles]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'OBusOut' / 'OOut' / 'OBusIn' Ops can interact through bus numbers, so
the generator could in principle build a graph where 'BusIn n' is
structurally upstream of a later 'BusOut n' (or 'Out n' — the two share
a kernel and a 'BusWrite n' effect), closing a cycle through the E_r
edge that the scheduler adds. 'validateAndSort' would then reject the
graph and 'propValidates' would fail — *not* a real bug, just generator
noise.

The interpreter avoids this by tracking the set of bus numbers already
"poisoned" by a 'BusIn' op. A later 'OBusOut n' or 'OOut n' on a poisoned
bus is silently skipped. With this discipline, no generated graph contains
an E_r cycle by construction, so all existing properties extend cleanly
to graphs with bus routing.

'OBusInDelayed' is *deliberately* not in this poisoning set. A
'BusInDelayed n' carries 'BusReadDelayed n' rather than 'BusRead n',
which the scheduler ignores when deriving E_r — so a downstream
'OBusOut n' on the same bus closes a feedback path that crosses the
block boundary, not a within-block cycle. The generator is therefore
free to emit feedback patterns ('OBusInDelayed bus' followed by
'OBusOut bus') and 'propValidates' must accept them. This is the QC
counterpart of the dedicated unit test "feedback graph through
busInDelayed topologically sorts".
-}

interpret :: [Op] -> SynthM ()
interpret ops = do
  _ <- interpretConnections ops
  pure ()

interpretConnections :: [Op] -> SynthM [Connection]
interpretConnections = go [] S.empty
  where
    go :: [Connection] -> S.Set Int -> [Op] -> SynthM [Connection]
    go xs _ [] = pure xs

    go xs r (OSinOsc f p : rest) = do
      c <- sinOsc (Param f) (Param p)
      go (xs <> [c]) r rest

    go xs r (OSinOscMod i p : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let freq = xs !! (i `mod` length xs)
          c <- sinOsc freq (Param p)
          go (xs <> [c]) r rest

    go xs r (OSawOsc f p : rest) = do
      c <- sawOsc (Param f) (Param p)
      go (xs <> [c]) r rest

    go xs r (OPulseOsc f p w : rest) = do
      c <- pulseOsc (Param f) (Param p) (Param w)
      go (xs <> [c]) r rest

    go xs r (OPulseOscWMod f p i : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let w = xs !! (i `mod` length xs)
          c <- pulseOsc (Param f) (Param p) w
          go (xs <> [c]) r rest

    go xs r (OTriOsc f p : rest) = do
      c <- triOsc (Param f) (Param p)
      go (xs <> [c]) r rest

    go xs r (OTriOscMod i p : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let freq = xs !! (i `mod` length xs)
          c <- triOsc freq (Param p)
          go (xs <> [c]) r rest

    go xs r (ONoise : rest) = do
      c <- noiseGen
      go (xs <> [c]) r rest

    go xs r (OGain i a : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- gain src (Param a)
          go (xs <> [c]) r rest

    go xs r (OGainMod i j : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let m = length xs
              s = xs !! (i `mod` m)
              a = xs !! (j `mod` m)
          c <- gain s a
          go (xs <> [c]) r rest

    go xs r (OLPF i f q : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- lpf src (Param f) (Param q)
          go (xs <> [c]) r rest

    go xs r (OHPF i f q : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- hpf src (Param f) (Param q)
          go (xs <> [c]) r rest

    go xs r (OBPF i f q : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- bpf src (Param f) (Param q)
          go (xs <> [c]) r rest

    go xs r (ONotch i f q : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- notch src (Param f) (Param q)
          go (xs <> [c]) r rest

    go xs r (OAdd b i : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- add (Param b) src
          go (xs <> [c]) r rest

    go xs r (OAddMod i j : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let m = length xs
              a = xs !! (i `mod` m)
              b = xs !! (j `mod` m)
          c <- add a b
          go (xs <> [c]) r rest

    go xs r (OEnv i ea ed es er : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let gate = xs !! (i `mod` length xs)
          c <- env gate (Param ea) (Param ed) (Param es) (Param er)
          go (xs <> [c]) r rest

    go xs r (OBusOut bus i : rest)
      | null xs            = go xs r rest
      | bus `S.member` r   = go xs r rest  -- skip to avoid an E_r cycle
      | otherwise          = do
          let src = xs !! (i `mod` length xs)
          busOut bus src
          go xs r rest

    go xs r (OBusIn bus : rest) = do
      c <- busIn bus
      go (xs <> [c]) (S.insert bus r) rest

    -- Feedback-safe reader: contributes no E_r edge, so no bus
    -- needs to be poisoned. A later 'OBusOut bus' on the same
    -- bus is allowed and closes a (cross-block) feedback path
    -- that the scheduler accepts. See Note [Generator avoids E_r
    -- cycles] for why this is the deliberate distinction.
    go xs r (OBusInDelayed bus : rest) = do
      c <- busInDelayed bus
      go (xs <> [c]) r rest

    -- Delay with a constant time. Floor is SampleRate (stateful),
    -- effect is Pure (per-instance buffer), so propagation and E_r
    -- machinery already cover it through the existing properties.
    go xs r (ODelay maxT t i : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- delayL maxT src (Param t)
          go (xs <> [c]) r rest

    -- Delay with audio-rate delay-time modulation: pulls another
    -- node's output into port 1.
    go xs r (ODelayMod maxT i j : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let m   = length xs
              sig = xs !! (i `mod` m)
              tin = xs !! (j `mod` m)
          c <- delayL maxT sig tin
          go (xs <> [c]) r rest

    -- Smooth on a Param target — the typical CC-update use case.
    go xs r (OSmooth baseHz t : rest) = do
      c <- smooth baseHz (Param t)
      go (xs <> [c]) r rest

    -- Smooth on an audio source — exercises the connected-input path
    -- of the kernel.
    go xs r (OSmoothMod baseHz i : rest)
      | null xs   = go xs r rest
      | otherwise = do
          let src = xs !! (i `mod` length xs)
          c <- smooth baseHz src
          go (xs <> [c]) r rest

    go xs r (OOut ch i : rest)
      | null xs            = go xs r rest
      | ch  `S.member` r   = go xs r rest  -- skip to avoid an E_r cycle
      | otherwise          = do
          let src = xs !! (i `mod` length xs)
          out ch src
          go xs r rest

------------------------------------------------------------
-- T-9: direct ≡ reduction equivalence (Phase §4.E.2.B3)
------------------------------------------------------------
--
-- The headline gate from notes/2026-05-08-deterministic-bus-reduction-design.md.
-- For every shape in t9CorpusGraphs / t9CorpusTemplates, render N
-- blocks in direct mode and N blocks in reduction-capture mode
-- (which folds slots back into output_buses on every sink-producing
-- step) and assert byte-identical bus 0 samples per block. Coverage:
--
--   * Single-template, unfused loader  (loadRuntimeGraph)
--   * Single-template, fused   loader  (loadRuntimeGraphFused)
--   * Multi-template send/return live  (loadTemplateGraph / Fused)
--   * Multi-template send/return delayed (BusInDelayed via the
--     block-end swap)
--   * Multi-template 3-stage chain (transitive cross-template flow)
--
-- Per-block exact equality (==) is the gate; any IEEE drift fails.
-- The corpus mirrors the pure-render shapes from app/Main.hs's
-- demoTable and adds the cross-template cases compileTemplateGraph
-- exercises; together they cover every kernel that holds a
-- SinkAccumulator or routes through process_out today.

-- Demos that exist in app/Main.hs but not in 'demoGraphs' above.
-- Mirrored here so the T-9 corpus matches the runtime audio path.
noiseGraph :: SynthGraph
noiseGraph = runSynth $ do
  n <- noiseGen
  g <- gain n 0.15
  out 0 g

filteredSawGraph :: SynthGraph
filteredSawGraph = runSynth $ do
  osc <- sawOsc 110.0 0.0
  f   <- lpf osc 1200.0 1.5
  g   <- gain f 0.6
  out 0 g

detunedSawGraph :: SynthGraph
detunedSawGraph = runSynth $ do
  osc1 <- sawOsc 220.0 0.0
  osc2 <- sawOsc 220.5 0.5     -- phase offset avoids cancellation
  g1   <- gain osc1 0.3
  g2   <- gain osc2 0.3
  out 0 g1
  out 0 g2                     -- two writers on bus 0; reduction mode
                               -- must keep them in distinct slots and
                               -- fold in canonical order.

envPluckGraph :: SynthGraph
envPluckGraph = runSynth $ do
  e     <- env 1.0 0.005 0.2 0.0 0.1
  tone  <- sinOsc 220.0 0.0
  amped <- gain tone e
  scale <- gain amped 0.5
  out 0 scale

intermodGraph :: SynthGraph
intermodGraph = runSynth $ do
  lfo1   <- triOsc 0.7 0.0
  lfo1s  <- gain lfo1 0.35
  width  <- add  lfo1s 0.5
  lfo2   <- sinOsc 0.3 0.0
  lfo2s  <- gain lfo2 800.0
  cutoff <- add  lfo2s 1200.0
  voice  <- pulseOsc 220.0 0.0 width
  filt   <- bpf voice cutoff 4.0
  master <- gain filt 0.4
  out 0 master

t9CorpusGraphs :: [(String, SynthGraph)]
t9CorpusGraphs = demoGraphs ++
  [ ("noise",        noiseGraph)
  , ("filtered-saw", filteredSawGraph)
  , ("detuned-saw",  detunedSawGraph)
  , ("env-pluck",    envPluckGraph)
  , ("intermod",     intermodGraph)
  ]

-- Multi-template corpus: the canonical send/return shapes the
-- compileTemplateGraph tests already exercise in their precedence
-- form. T-9 runs them through loadTemplateGraph / loadTemplateGraphFused
-- under both modes and asserts bit-identical output.
sendReturnLiveTG :: TemplateGraph
sendReturnLiveTG =
  let producer = runSynth $ do
        o <- sinOsc 440.0 0.0
        busOut 5 o
      consumer = runSynth $ do
        t <- busIn 5
        out 0 t
  in case compileTemplateGraph
            [("producer", producer), ("consumer", consumer)] of
       Right tg  -> tg
       Left  err -> error ("sendReturnLiveTG: " <> err)

sendReturnDelayedTG :: TemplateGraph
sendReturnDelayedTG =
  let producer = runSynth $ do
        o <- sawOsc 220.0 0.0
        g <- gain o 0.5
        busOut 6 g
      consumer = runSynth $ do
        t <- busInDelayed 6
        out 0 t
  in case compileTemplateGraph
            [("producer", producer), ("consumer", consumer)] of
       Right tg  -> tg
       Left  err -> error ("sendReturnDelayedTG: " <> err)

threeTemplateChainTG :: TemplateGraph
threeTemplateChainTG =
  let a = runSynth $ do
        o <- sinOsc 330.0 0.0
        busOut 5 o
      b = runSynth $ do
        s <- busIn 5
        g <- gain s 0.5
        busOut 7 g
      c = runSynth $ do
        t <- busIn 7
        out 0 t
  in case compileTemplateGraph [("a", a), ("b", b), ("c", c)] of
       Right tg  -> tg
       Left  err -> error ("threeTemplateChainTG: " <> err)

t9CorpusTemplates :: [(String, TemplateGraph)]
t9CorpusTemplates =
  [ ("send-return-live",    sendReturnLiveTG)
  , ("send-return-delayed", sendReturnDelayedTG)
  , ("three-template-chain", threeTemplateChainTG)
  ]

-- Render @blocks@ blocks of @nframes@ frames each, returning a
-- list of (bus, samples) pairs per block — one pair per bus in the
-- supplied bus list, in the same order. Optionally enables
-- reduction-capture mode for the whole render. The capture switch
-- flips the runtime to fold slot contributions back into
-- output_buses on every sink step, but the externally visible bus
-- values must remain byte-identical to the direct path on every
-- relevant bus — that's what T-9 verifies.
renderBlocksRG :: (Ptr RTGraph -> RuntimeGraph -> IO ())
               -> RuntimeGraph
               -> Bool   -- reduction-capture on?
               -> Int    -- nframes per block
               -> Int    -- block count
               -> [Int]  -- buses to read each block
               -> IO [[(Int, [Float])]]
renderBlocksRG loader rt reduction nframes blocks buses =
  renderBlocksRGWithFlags loader rt reduction False nframes blocks buses

renderBlocksRGWithFlags :: (Ptr RTGraph -> RuntimeGraph -> IO ())
                        -> RuntimeGraph
                        -> Bool   -- reduction-capture on?
                        -> Bool   -- schedule executor on?
                        -> Int
                        -> Int
                        -> [Int]
                        -> IO [[(Int, [Float])]]
renderBlocksRGWithFlags loader rt reduction scheduleExec nframes blocks buses =
  renderBlocksRGWithWorkerPool
    loader rt reduction scheduleExec 0 nframes blocks buses

renderBlocksRGWithWorkerPool :: (Ptr RTGraph -> RuntimeGraph -> IO ())
                             -> RuntimeGraph
                             -> Bool   -- reduction-capture on?
                             -> Bool   -- schedule executor on?
                             -> Int    -- logical worker-pool size
                             -> Int
                             -> Int
                             -> [Int]
                             -> IO [[(Int, [Float])]]
renderBlocksRGWithWorkerPool
    loader rt reduction scheduleExec workerPool nframes blocks buses =
  withRTGraph (length (rgNodes rt)) nframes $ \handle -> do
    loader handle rt
    when (workerPool > 0) $
      c_rt_graph_test_set_worker_pool_size handle (fromIntegral workerPool)
    when reduction $
      c_rt_graph_test_set_reduction_capture handle 1
    when scheduleExec $
      c_rt_graph_test_set_global_schedule_execution handle 1
    forM [1 .. blocks] $ \_ -> processAndReadBuses handle nframes buses

renderBlocksTG :: (Ptr RTGraph -> TemplateGraph -> IO ())
               -> TemplateGraph
               -> Bool
               -> Int
               -> Int
               -> [Int]
               -> IO [[(Int, [Float])]]
renderBlocksTG loader tg reduction nframes blocks buses =
  renderBlocksTGWithFlags loader tg reduction False nframes blocks buses

renderBlocksTGWithFlags :: (Ptr RTGraph -> TemplateGraph -> IO ())
                        -> TemplateGraph
                        -> Bool
                        -> Bool
                        -> Int
                        -> Int
                        -> [Int]
                        -> IO [[(Int, [Float])]]
renderBlocksTGWithFlags loader tg reduction scheduleExec nframes blocks buses =
  renderBlocksTGWithWorkerPool
    loader tg reduction scheduleExec 0 nframes blocks buses

renderBlocksTGWithWorkerPool :: (Ptr RTGraph -> TemplateGraph -> IO ())
                             -> TemplateGraph
                             -> Bool   -- reduction-capture on?
                             -> Bool   -- schedule executor on?
                             -> Int    -- logical worker-pool size
                             -> Int
                             -> Int
                             -> [Int]
                             -> IO [[(Int, [Float])]]
renderBlocksTGWithWorkerPool
    loader tg reduction scheduleExec workerPool nframes blocks buses =
  let totalNodes = sum (map (length . rgNodes . tplGraph)
                            (tgTemplates tg))
  in withRTGraph totalNodes nframes $ \handle -> do
       loader handle tg
       when (workerPool > 0) $
         c_rt_graph_test_set_worker_pool_size handle (fromIntegral workerPool)
       when reduction $
         c_rt_graph_test_set_reduction_capture handle 1
       when scheduleExec $
         c_rt_graph_test_set_global_schedule_execution handle 1
       forM [1 .. blocks] $ \_ -> processAndReadBuses handle nframes buses

-- Process one block, then read every bus in the supplied list.
-- Asserts c_rt_graph_read_bus returns exactly nframes for each bus
-- so a short read (ABI bug, missing bus) is caught here rather than
-- silently producing zeros that happen to compare equal.
processAndReadBuses
  :: Ptr RTGraph -> Int -> [Int] -> IO [(Int, [Float])]
processAndReadBuses handle nframes buses = do
  c_rt_graph_process handle (fromIntegral nframes)
  forM buses $ \b -> do
    vs <- readBus handle b nframes
    pure (b, vs)

readBus :: Ptr RTGraph -> Int -> Int -> IO [Float]
readBus handle bus nframes =
  allocaBytes (nframes * sizeOfFloatT9) $ \buf -> do
    n <- c_rt_graph_read_bus handle (fromIntegral bus)
                             (fromIntegral nframes) (castPtr buf)
    fromIntegral n @?= nframes
    cs <- peekArray nframes (buf :: PtrCFloat)
    pure (map (\(CFloat x) -> x) cs)
  where
    sizeOfFloatT9 = 4

-- Buses the graph reads from or writes to, derived from per-node
-- kinds: KOut / KBusOut write, KBusIn / KBusInDelayed read. The bus
-- index lives in rnControls[0] for all four kinds (see
-- ugenView in Bridge/Source.hs). Bus 0 is always included so the
-- master out-bus is checked even on graphs that only touch private
-- buses; the result is sorted and deduplicated. Negative indices
-- are dropped to match the loader's busIndexOf, so randomized or
-- malformed inputs cannot ask the runtime to read a bus it never
-- registers.
relevantBuses :: RuntimeGraph -> [Int]
relevantBuses rt =
  let touchesBus n = case rnKind n of
        KOut          -> True
        KBusOut       -> True
        KBusIn        -> True
        KBusInDelayed -> True
        _             -> False
      idxOf n = case rnControls n of
        (b : _) ->
          let i = truncate b :: Int
          in if i >= 0 then Just i else Nothing
        []      -> Nothing
      buses = mapMaybe idxOf (filter touchesBus (rgNodes rt))
  in sort (nub (0 : buses))

relevantBusesTG :: TemplateGraph -> [Int]
relevantBusesTG tg =
  sort (nub (concatMap (relevantBuses . tplGraph) (tgTemplates tg)))

-- Direct-vs-reduction equivalence assertion. Renders the same graph
-- through the same loader twice — once direct, once with reduction
-- capture — and requires every block to be byte-identical on every
-- relevant bus.
assertDirectEqualsReductionRG
  :: String
  -> (Ptr RTGraph -> RuntimeGraph -> IO ())
  -> RuntimeGraph
  -> Int   -- nframes per block
  -> Int   -- block count
  -> Assertion
assertDirectEqualsReductionRG label loader rt nframes blocks = do
  let buses = relevantBuses rt
  d <- renderBlocksRG loader rt False nframes blocks buses
  r <- renderBlocksRG loader rt True  nframes blocks buses
  assertBlocksEqual label d r

assertDirectEqualsReductionTG
  :: String
  -> (Ptr RTGraph -> TemplateGraph -> IO ())
  -> TemplateGraph
  -> Int
  -> Int
  -> Assertion
assertDirectEqualsReductionTG label loader tg nframes blocks = do
  let buses = relevantBusesTG tg
  d <- renderBlocksTG loader tg False nframes blocks buses
  r <- renderBlocksTG loader tg True  nframes blocks buses
  assertBlocksEqual label d r

assertDirectEqualsScheduleRG
  :: String
  -> (Ptr RTGraph -> RuntimeGraph -> IO ())
  -> RuntimeGraph
  -> Int
  -> Int
  -> Assertion
assertDirectEqualsScheduleRG label loader rt nframes blocks = do
  let buses = relevantBuses rt
  legacy <- renderBlocksRGWithFlags loader rt False False nframes blocks buses
  sched  <- renderBlocksRGWithFlags loader rt False True  nframes blocks buses
  assertBlocksEqual (label <> ": legacy/schedule") legacy sched

assertDirectEqualsScheduleTG
  :: String
  -> (Ptr RTGraph -> TemplateGraph -> IO ())
  -> TemplateGraph
  -> Int
  -> Int
  -> Assertion
assertDirectEqualsScheduleTG label loader tg nframes blocks = do
  let buses = relevantBusesTG tg
  legacy <- renderBlocksTGWithFlags loader tg False False nframes blocks buses
  sched  <- renderBlocksTGWithFlags loader tg False True  nframes blocks buses
  assertBlocksEqual (label <> ": legacy/schedule") legacy sched

assertScheduleDirectEqualsReductionRG
  :: String
  -> (Ptr RTGraph -> RuntimeGraph -> IO ())
  -> RuntimeGraph
  -> Int
  -> Int
  -> Assertion
assertScheduleDirectEqualsReductionRG label loader rt nframes blocks = do
  let buses = relevantBuses rt
  d <- renderBlocksRGWithFlags loader rt False True nframes blocks buses
  r <- renderBlocksRGWithFlags loader rt True  True nframes blocks buses
  assertBlocksEqual (label <> ": schedule direct/reduction") d r

assertScheduleDirectEqualsReductionTG
  :: String
  -> (Ptr RTGraph -> TemplateGraph -> IO ())
  -> TemplateGraph
  -> Int
  -> Int
  -> Assertion
assertScheduleDirectEqualsReductionTG label loader tg nframes blocks = do
  let buses = relevantBusesTG tg
  d <- renderBlocksTGWithFlags loader tg False True nframes blocks buses
  r <- renderBlocksTGWithFlags loader tg True  True nframes blocks buses
  assertBlocksEqual (label <> ": schedule direct/reduction") d r

assertSchedulePoolDirectEqualsReductionRG
  :: String
  -> (Ptr RTGraph -> RuntimeGraph -> IO ())
  -> RuntimeGraph
  -> Int
  -> Int
  -> Int
  -> Assertion
assertSchedulePoolDirectEqualsReductionRG
    label loader rt workerPool nframes blocks = do
  let buses = relevantBuses rt
  d <- renderBlocksRGWithWorkerPool
         loader rt False True workerPool nframes blocks buses
  r <- renderBlocksRGWithWorkerPool
         loader rt True  True workerPool nframes blocks buses
  assertBlocksEqual
    (label <> ": schedule pool direct/reduction") d r

assertSchedulePoolDirectEqualsReductionTG
  :: String
  -> (Ptr RTGraph -> TemplateGraph -> IO ())
  -> TemplateGraph
  -> Int
  -> Int
  -> Int
  -> Assertion
assertSchedulePoolDirectEqualsReductionTG
    label loader tg workerPool nframes blocks = do
  let buses = relevantBusesTG tg
  d <- renderBlocksTGWithWorkerPool
         loader tg False True workerPool nframes blocks buses
  r <- renderBlocksTGWithWorkerPool
         loader tg True  True workerPool nframes blocks buses
  assertBlocksEqual
    (label <> ": schedule pool direct/reduction") d r

assertDirectEqualsSchedulePoolRG
  :: String
  -> (Ptr RTGraph -> RuntimeGraph -> IO ())
  -> RuntimeGraph
  -> Int
  -> Int
  -> Int
  -> Assertion
assertDirectEqualsSchedulePoolRG label loader rt workerPool nframes blocks = do
  let buses = relevantBuses rt
  legacy <- renderBlocksRGWithWorkerPool
              loader rt False False 0 nframes blocks buses
  sched  <- renderBlocksRGWithWorkerPool
              loader rt False True workerPool nframes blocks buses
  assertBlocksEqual (label <> ": legacy/schedule-pool") legacy sched

-- Per-block, per-bus exact-equality check. Reports the first
-- divergent (block, bus, frame) so a failure points straight at the
-- kernel that broke the contract.
assertBlocksEqual
  :: String
  -> [[(Int, [Float])]]
  -> [[(Int, [Float])]]
  -> Assertion
assertBlocksEqual label direct reduced = do
  length direct @?= length reduced
  forM_ (zip3 [0 :: Int ..] direct reduced) $ \(b, db, rb) -> do
    map fst db @?= map fst rb
    forM_ (zip db rb) $ \((busIdx, dvs), (_, rvs)) ->
      forM_ (zip3 [0 :: Int ..] dvs rvs) $ \(fi, dv, rv) ->
        when (dv /= rv) $
          assertFailure $
            label <> ": direct/reduction diverge at block " <> show b
            <> ", bus " <> show busIdx
            <> ", frame " <> show fi
            <> ": direct=" <> show dv <> " reduced=" <> show rv

-- Compile a SynthGraph through both lowering paths so a single test
-- can route the same source through unfused and fused loaders. The
-- error path on either compile is a hard test failure — these are
-- demo shapes that all compile cleanly.
compileBoth
  :: String -> SynthGraph -> IO (RuntimeGraph, RuntimeGraph)
compileBoth name g = do
  rtUn <- case lowerGraph g >>= compileRuntimeGraph of
    Right r  -> pure r
    Left err -> assertFailure
                  (name <> ": compileRuntimeGraph failed: " <> err)
                >> error "unreachable"
  rtF  <- case lowerGraph g >>= compileRuntimeGraphFused of
    Right r  -> pure r
    Left err -> assertFailure
                  (name <> ": compileRuntimeGraphFused failed: " <> err)
                >> error "unreachable"
  pure (rtUn, rtF)

t9DirectEqualsReductionTests :: TestTree
t9DirectEqualsReductionTests =
  let nframes = 256
      blocks  = 4   -- enough to cover BusInDelayed's prev-pool path
                    -- (block 2 picks up block 1's folded writes via
                    -- the swap; later blocks expose any state-
                    -- continuity drift in oscillators / filters).
  in testGroup "T-9: direct ≡ reduction"
       [ testGroup "single template, unfused loader"
           [ testCase name $ do
               (rtUn, _) <- compileBoth name g
               assertDirectEqualsReductionRG
                 name loadRuntimeGraph rtUn nframes blocks
           | (name, g) <- t9CorpusGraphs
           ]

       , testGroup "single template, fused loader"
           [ testCase name $ do
               (_, rtF) <- compileBoth name g
               assertDirectEqualsReductionRG
                 name loadRuntimeGraphFused rtF nframes blocks
           | (name, g) <- t9CorpusGraphs
           ]

       , testGroup "multi-template, unfused loader"
           [ testCase name $
               assertDirectEqualsReductionTG
                 name loadTemplateGraph tg nframes blocks
           | (name, tg) <- t9CorpusTemplates
           ]

       , testGroup "multi-template, fused loader"
           [ testCase name $
               assertDirectEqualsReductionTG
                 name loadTemplateGraphFused tg nframes blocks
           | (name, tg) <- t9CorpusTemplates
           ]
       ]

------------------------------------------------------------
-- Phase 4.E.2.C0a: layer-aware loader metadata
------------------------------------------------------------
--
-- C0a is a metadata-only ABI slice: every loader ships
-- 'layeredRegionSchedule' across the FFI as a sequence of
-- (kind, [region_ordinals]) pairs over the template's registered
-- region vector. Each step's ordinal list is materialised on the
-- C side via MetaDef::schedule_step_regions, so a non-contiguous
-- free layer like {0, 2} stays {0, 2}. Execution is unchanged —
-- process_instance still iterates regions in registration order —
-- but the runtime now stores the layered view so C0b can build a
-- per-block global schedule from it. These tests pin the
-- projection: every loader's output equals
-- 'expectedScheduleStepItems' applied to the corresponding
-- 'layeredRegionSchedule', and stale step / item queries return
-- -1.

-- | Mirror of 'scheduleStepItems' in @MetaSonic.Bridge.FFI@. The
-- tag encoding (0 = Barrier, 1 = FreeLayer) matches the C-side
-- 'ScheduleStepKind'. The duplication is deliberate: this helper
-- pins the contract the FFI helper must implement, so a future
-- divergence shows up as a test failure rather than silently
-- corrupting metadata. Returns @Left@ if any rrIndex in the
-- schedule is missing from @scheduled@ — by construction that
-- shouldn't happen, but a hard test failure beats a silent
-- mismapping.
expectedScheduleStepItems
  :: [RuntimeRegion]
  -> [ScheduleStep]
  -> Either String [(Int, [Int])]
expectedScheduleStepItems scheduled = traverse step
  where
    pairs = zip [0 :: Int ..] scheduled
    ordinal ix =
      case [i | (i, r) <- pairs, rrIndex r == ix] of
        (n : _) -> Right n
        []      -> Left $
          "expectedScheduleStepItems: rrIndex " <> show ix
          <> " not in scheduledRuntimeRegions"
    step (ScheduleBarrier ix)   = do
      o <- ordinal ix
      pure (0, [o])
    step (ScheduleFreeLayer fl) = do
      os <- traverse ordinal (flRegions fl)
      pure (1, os)

-- | Read every schedule step the runtime currently has for one
-- template, projected back to the same (kind, [ordinals]) shape
-- 'expectedScheduleStepItems' produces. Per-item ordinals are
-- resolved through MetaDef::schedule_step_regions, so a layer
-- with non-contiguous ordinals (e.g. {0, 2}) stays {0, 2}.
readScheduleSteps :: Ptr RTGraph -> Int -> IO [(Int, [Int])]
readScheduleSteps handle tid = do
  cnt <- c_rt_graph_test_template_schedule_step_count handle
           (fromIntegral tid)
  forM [0 .. fromIntegral cnt - 1] $ \i -> do
    k    <- c_rt_graph_test_template_schedule_step_kind handle
              (fromIntegral tid) i
    iCnt <- c_rt_graph_test_template_schedule_step_item_count
              handle (fromIntegral tid) i
    ords <- forM [0 .. fromIntegral iCnt - 1] $ \j ->
      c_rt_graph_test_template_schedule_step_region handle
        (fromIntegral tid) i j
    pure (fromIntegral k, map fromIntegral ords)

assertLoaderShipsScheduleRG
  :: String
  -> (Ptr RTGraph -> RuntimeGraph -> IO ())
  -> RuntimeGraph
  -> Assertion
assertLoaderShipsScheduleRG label loader rg = do
  scheduled <- case scheduledRuntimeRegions rg of
    Right rs -> pure rs
    Left err -> assertFailure
                  (label <> ": scheduledRuntimeRegions: " <> err)
                >> error "unreachable"
  steps <- case layeredRegionSchedule rg of
    Right ss -> pure ss
    Left err -> assertFailure
                  (label <> ": layeredRegionSchedule: " <> err)
                >> error "unreachable"
  expected <- case expectedScheduleStepItems scheduled steps of
    Right xs -> pure xs
    Left err -> assertFailure (label <> ": " <> err)
                >> error "unreachable"
  withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
    loader handle rg
    actual <- readScheduleSteps handle 0
    actual @?= expected
    -- Out-of-range step queries return -1 even when the schedule
    -- itself is non-empty: catches a future change that swallows
    -- the bounds check on the tail.
    let stepCount = fromIntegral (length expected) :: CInt
    badKind <- c_rt_graph_test_template_schedule_step_kind handle 0
                 stepCount
    badKind @?= -1
    -- Out-of-range item queries on the last valid step also return
    -- -1 (item bounds, not just step bounds).
    when (not (null expected)) $ do
      let lastStep = fromIntegral (length expected - 1) :: CInt
          itemOver = fromIntegral
                       (length (snd (last expected))) :: CInt
      badItem <- c_rt_graph_test_template_schedule_step_region
                   handle 0 lastStep itemOver
      badItem @?= -1

assertLoaderShipsScheduleTG
  :: String
  -> (Ptr RTGraph -> TemplateGraph -> IO ())
  -> TemplateGraph
  -> Assertion
assertLoaderShipsScheduleTG label loader tg = do
  expectedPerTpl <-
    forM (zip [0 ..] (tgTemplates tg)) $ \(i, tpl) -> do
      let rg = tplGraph tpl
      scheduled <- case scheduledRuntimeRegions rg of
        Right rs -> pure rs
        Left err -> assertFailure
          (label <> ": template " <> show (tplName tpl)
           <> ": " <> err)
          >> error "unreachable"
      steps <- case layeredRegionSchedule rg of
        Right ss -> pure ss
        Left err -> assertFailure
          (label <> ": template " <> show (tplName tpl)
           <> ": " <> err)
          >> error "unreachable"
      expected <- case expectedScheduleStepItems scheduled steps of
        Right xs -> pure xs
        Left err -> assertFailure
          (label <> ": template " <> show (tplName tpl)
           <> ": " <> err)
          >> error "unreachable"
      pure (i :: Int, expected)
  let totalNodes = sum (map (length . rgNodes . tplGraph)
                            (tgTemplates tg))
  withRTGraph totalNodes 256 $ \handle -> do
    loader handle tg
    forM_ expectedPerTpl $ \(tid, expected) -> do
      actual <- readScheduleSteps handle tid
      actual @?= expected

c0aLoaderMetadataTests :: TestTree
c0aLoaderMetadataTests =
  testGroup "Phase 4.E.2.C0a: layer-aware loader metadata"
    -- Universal invariant: 'layeredRegionSchedule' and
    -- 'regionSchedule' must cover the same /set/ of regions for any
    -- well-formed graph, even though their orderings can differ.
    -- 'goLayers' partitions the ready frontier and emits all ready
    -- regions per layer, while 'topoSortStable' picks one ready
    -- region at a time, so a free segment 0 → 1, 2 (independent)
    -- yields layered = [{0, 2}, {1}] but linear = [0, 1, 2] —
    -- different orderings of the same set. This test pins the
    -- coverage property without overconstraining the order, so a
    -- future corpus graph with non-contiguous layers (see the
    -- divergent-layer regression below) does not fail this test
    -- for the wrong reason.
    [ testGroup "layeredRegionSchedule and regionSchedule cover the same regions"
        [ testCase name $ do
            (rgU, _) <- compileBoth name g
            flatRegions <- case regionSchedule rgU of
              Right rs -> pure rs
              Left err -> assertFailure
                            (name <> ": regionSchedule: " <> err)
                          >> error "unreachable"
            steps <- case layeredRegionSchedule rgU of
              Right ss -> pure ss
              Left err -> assertFailure
                            (name <> ": layeredRegionSchedule: " <> err)
                          >> error "unreachable"
            sort (concatMap stepRegions steps) @?= sort flatRegions
        | (name, g) <- t9CorpusGraphs
        ]

    , testGroup "loadRuntimeGraph ships schedule steps"
        [ testCase name $ do
            (rgU, _) <- compileBoth name g
            assertLoaderShipsScheduleRG name loadRuntimeGraph rgU
        | (name, g) <- t9CorpusGraphs
        ]

    , testGroup "loadRuntimeGraphFused ships schedule steps"
        [ testCase name $ do
            (_, rgF) <- compileBoth name g
            assertLoaderShipsScheduleRG name loadRuntimeGraphFused rgF
        | (name, g) <- t9CorpusGraphs
        ]

    , testGroup "loadTemplateGraph ships schedule steps"
        [ testCase name $
            assertLoaderShipsScheduleTG name loadTemplateGraph tg
        | (name, tg) <- t9CorpusTemplates
        ]

    , testGroup "loadTemplateGraphFused ships schedule steps"
        [ testCase name $
            assertLoaderShipsScheduleTG name loadTemplateGraphFused tg
        | (name, tg) <- t9CorpusTemplates
        ]

    -- Reload on the same handle clears prior schedule metadata: load
    -- a non-trivial graph, then a trivial one, and check the second
    -- load's metadata is exactly what 'layeredRegionSchedule' says
    -- — i.e. the prior schedule is gone, not concatenated.
    , testCase "reload clears prior schedule metadata" $ do
        (rgChain,  _) <- compileBoth "chain"  chainGraph
        (rgSimple, _) <- compileBoth "simple" simpleGraph
        let totalNodes = max (length (rgNodes rgChain))
                             (length (rgNodes rgSimple))
        withRTGraph totalNodes 256 $ \handle -> do
          loadRuntimeGraph handle rgChain
          firstCount <- c_rt_graph_test_template_schedule_step_count
                          handle 0
          assertBool "expected non-zero schedule steps after first load"
                     (firstCount > 0)
          loadRuntimeGraph handle rgSimple
          actual    <- readScheduleSteps handle 0
          scheduled <- case scheduledRuntimeRegions rgSimple of
            Right rs -> pure rs
            Left err -> assertFailure
                          ("simple: scheduledRuntimeRegions: " <> err)
                        >> error "unreachable"
          steps <- case layeredRegionSchedule rgSimple of
            Right ss -> pure ss
            Left err -> assertFailure
                          ("simple: layeredRegionSchedule: " <> err)
                        >> error "unreachable"
          expected <-
            case expectedScheduleStepItems scheduled steps of
              Right xs -> pure xs
              Left err -> assertFailure ("simple: " <> err)
                          >> error "unreachable"
          actual @?= expected

    -- Regression for the contiguous-range encoding bug: the indirect
    -- ABI must preserve a non-contiguous free layer's ordinal set
    -- exactly. The graph is shaped so 'formRegions' yields three
    -- non-barrier regions where region 1 structurally depends on
    -- region 0 (via the cross-region RFrom edge from gain1 into the
    -- second saw chain) and region 2 is independent. 'goLayers'
    -- partitions the ready frontier, so the expected layers are
    -- [{0, 2}, {1}], non-contiguous in regionSchedule order
    -- [0, 1, 2]. A contiguous-range encoding would silently rewrite
    -- layer 0 to {0, 1}, putting a dependent region in the wrong
    -- layer once C0b consumes the metadata. This test pins the
    -- per-item shape end-to-end.
    , testCase "free layer with non-contiguous ordinals" $ do
        rg <- case lowerGraph divergentLayerGraph
                >>= compileRuntimeGraph of
          Right rg' -> pure rg'
          Left err  -> assertFailure
                         ("divergent: compile: " <> err)
                       >> error "unreachable"
        -- First check the planner: the linear schedule and the
        -- layered schedule must diverge in the documented way.
        scheduled <- case scheduledRuntimeRegions rg of
          Right rs -> pure rs
          Left err -> assertFailure
                        ("divergent: scheduledRuntimeRegions: " <> err)
                      >> error "unreachable"
        steps <- case layeredRegionSchedule rg of
          Right ss -> pure ss
          Left err -> assertFailure
                        ("divergent: layeredRegionSchedule: " <> err)
                      >> error "unreachable"
        let regionCount    = length scheduled
            layerSizes     = map (length . stepRegions) steps
        -- Diagnostic guard: the test only proves the regression
        -- if formRegions actually produces a non-contiguous free
        -- layer. If a future change to formRegions /
        -- selectRegionKernels collapses the shape, fail loudly so
        -- the synth graph can be repaired rather than silently
        -- becoming a contiguous-shape test.
        assertBool
          ("expected at least one free layer of size > 1 with a "
           <> "trailing free layer of size 1 (non-contiguous "
           <> "ordinals); got region count " <> show regionCount
           <> ", layer sizes " <> show layerSizes)
          (any (\(a, b) -> a > 1 && b == 1)
               (zip layerSizes (drop 1 layerSizes)))
        expected <-
          case expectedScheduleStepItems scheduled steps of
            Right xs -> pure xs
            Left err -> assertFailure ("divergent: " <> err)
                        >> error "unreachable"
        -- Drive the projection through the FFI to prove the
        -- runtime stores the actual ordinal set, not a contiguous
        -- range. Compare via the per-item readout.
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          actual <- readScheduleSteps handle 0
          actual @?= expected
    ]
  where
    stepRegions (ScheduleBarrier ix)   = [ix]
    stepRegions (ScheduleFreeLayer fl) = flRegions fl

------------------------------------------------------------
-- Phase 4.E.2.C0b: per-block global schedule
------------------------------------------------------------
--
-- The runtime rebuilds a global schedule at the top of every
-- 'rt_graph_process' call: a flat list of
-- (template_id, instance_slot, step_index) entries in canonical
--   template ascending → instance slot ascending → step ascending
-- order, filtered to instances whose state is Active or
-- Releasing. These tests pin the shape the C0c serial executor
-- consumes when its test switch is enabled. Cross-resolution to
-- per-step kind / ordinal data goes through the C0a accessors;
-- the divergent-layer case proves a non-contiguous free layer
-- survives all the way out to a global-schedule consumer.

-- | Read every entry of the global schedule as a list of
-- (template_id, instance_slot, step_index) triples.
readGlobalSchedule :: Ptr RTGraph -> IO [(Int, Int, Int)]
readGlobalSchedule h = do
  cnt <- c_rt_graph_test_global_schedule_entry_count h
  forM [0 .. fromIntegral cnt - 1] $ \i -> do
    t <- c_rt_graph_test_global_schedule_entry_template h i
    s <- c_rt_graph_test_global_schedule_entry_instance h i
    p <- c_rt_graph_test_global_schedule_entry_step      h i
    pure (fromIntegral t, fromIntegral s, fromIntegral p)

-- | Read every C0d global-schedule band as
-- (kind, first_entry, entry_count), where kind is 0 = Barrier and
-- 1 = Free.
readGlobalScheduleBands :: Ptr RTGraph -> IO [(Int, Int, Int)]
readGlobalScheduleBands h = do
  cnt <- c_rt_graph_test_global_schedule_band_count h
  forM [0 .. fromIntegral cnt - 1] $ \i -> do
    k <- c_rt_graph_test_global_schedule_band_kind h i
    f <- c_rt_graph_test_global_schedule_band_first_entry h i
    n <- c_rt_graph_test_global_schedule_band_entry_count h i
    pure (fromIntegral k, fromIntegral f, fromIntegral n)

-- | Assert the C0d band vector is a conservative, contiguous
-- partition of the C0b entry vector. Barrier bands must be singleton
-- barrier steps. Free bands must contain only FreeLayer steps and
-- cannot contain two entries for the same instance slot.
assertGlobalScheduleBandsWellFormed :: String -> Ptr RTGraph -> Assertion
assertGlobalScheduleBandsWellFormed label h = do
  entries <- readGlobalSchedule h
  bands   <- readGlobalScheduleBands h

  let ranges =
        concat
          [ [first .. first + count - 1]
          | (_kind, first, count) <- bands
          ]
      expectedRange = [0 .. length entries - 1]
  ranges @?= expectedRange

  forM_ (zip [0 :: Int ..] bands) $ \(bandIndex, (kind, first, count)) -> do
    assertBool
      (label <> ": band " <> show bandIndex <> " has non-positive count")
      (count > 0)
    assertBool
      (label <> ": band " <> show bandIndex <> " starts out of range")
      (first >= 0 && first + count <= length entries)
    let slice = take count (drop first entries)
    stepKinds <- forM slice $ \(tid, _slot, step) ->
      c_rt_graph_test_template_schedule_step_kind h
        (fromIntegral tid) (fromIntegral step)
    case kind of
      0 -> do
        count @?= 1
        stepKinds @?= [0]
      1 -> do
        stepKinds @?= replicate count 1
        let slots = [slot | (_tid, slot, _step) <- slice]
        slots @?= nub slots
      _ -> assertFailure
             (label <> ": unexpected band kind " <> show kind)

  let over = fromIntegral (length bands) :: CInt
  badKind <- c_rt_graph_test_global_schedule_band_kind h over
  badFirst <- c_rt_graph_test_global_schedule_band_first_entry h over
  badCount <- c_rt_graph_test_global_schedule_band_entry_count h over
  badKind @?= -1
  badFirst @?= -1
  badCount @?= -1

-- | Pure expectation for a single-template graph: emit
-- (0, slot, step) triples for every (slot in @slots@, step in
-- the layered schedule), in slot-then-step order. Steps come from
-- 'layeredRegionSchedule' to make the test contract obvious;
-- assertion failure here would indicate either a planner or
-- loader regression.
expectedGlobalRG :: RuntimeGraph -> [Int] -> [(Int, Int, Int)]
expectedGlobalRG rg slots =
  let stepCount = case layeredRegionSchedule rg of
        Right ss -> length ss
        Left _   -> 0
  in [ (0, slot, step)
     | slot <- slots
     , step <- [0 .. stepCount - 1]
     ]

-- | Multi-template counterpart: emit per-template entries in
-- registration order, then per-instance-slot, then per-step. The
-- caller supplies the live slot list per template_id so this
-- helper does not need to know about the runtime instance pool.
expectedGlobalTG
  :: TemplateGraph -> [(Int, [Int])] -> [(Int, Int, Int)]
expectedGlobalTG tg perTpl =
  let tplCount = zip [0 :: Int ..] (tgTemplates tg)
      stepCountFor i = case lookup i tplCount of
        Just t -> case layeredRegionSchedule (tplGraph t) of
          Right ss -> length ss
          Left _   -> 0
        Nothing -> 0
  in [ (tid, slot, step)
     | (tid, slots) <- perTpl
     , slot <- slots
     , step <- [0 .. stepCountFor tid - 1]
     ]

c0bGlobalScheduleTests :: TestTree
c0bGlobalScheduleTests =
  testGroup "Phase 4.E.2.C0b: per-block global schedule"
    [ -- Default state has no schedule_steps anywhere, so the
      -- global schedule must be empty even after a process tick.
      -- This pins the "no metadata, no schedule" fallback for the
      -- legacy single-template build path.
      testCase "fresh handle: empty global schedule" $
        withRTGraph 4 256 $ \handle -> do
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          actual @?= []

    , -- The single auto-spawned instance produces one entry per
      -- step in canonical (0, 0, step) order.
      testCase "single instance, single template" $ do
        (rg, _) <- compileBoth "chain" chainGraph
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          actual @?= expectedGlobalRG rg [0]

    , -- Spawning more instances of the same template appends slots
      -- to the canonical order: slot 0 → slot 1 → slot 2, with the
      -- full step list interleaved per slot.
      testCase "multiple instances preserve slot order" $ do
        (rg, _) <- compileBoth "chain" chainGraph
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          _ <- c_rt_graph_template_instance_add handle 0
          _ <- c_rt_graph_template_instance_add handle 0
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          actual @?= expectedGlobalRG rg [0, 1, 2]

    , -- 'instance_remove' transitions the slot to Available, which
      -- the build skips. Verify the middle slot disappears while
      -- slots 0 and 2 remain in canonical order.
      testCase "Available slot is skipped" $ do
        (rg, _) <- compileBoth "chain" chainGraph
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          extra1 <- c_rt_graph_template_instance_add handle 0
          _      <- c_rt_graph_template_instance_add handle 0
          c_rt_graph_instance_remove handle extra1
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          actual @?= expectedGlobalRG rg [0, 2]

    , -- A graph with an Env node: 'instance_release' transitions
      -- to Releasing rather than Available, so the slot must
      -- still appear in the global schedule until §2.E's silence
      -- detector promotes it to Available many blocks later.
      -- envPluckGraph's release time (0.1s ≈ 19 blocks at
      -- 256/48000s) is comfortably longer than the one block this
      -- test runs, and the gain is non-trivial so block_sink_peak
      -- starts well above the silence threshold.
      testCase "Releasing slot stays in schedule" $ do
        (rg, _) <- compileBoth "envPluck" envPluckGraph
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          c_rt_graph_process handle 256   -- warm up
          c_rt_graph_instance_release handle 0
          status <- c_rt_graph_instance_status handle 0
          status @?= instanceStatusReleasing
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          actual @?= expectedGlobalRG rg [0]

    , -- For a multi-template graph the outer ordering is
      -- template_id ascending; only after every entry of template
      -- 0 has been emitted does any entry of template 1 appear.
      -- 'sendReturnLiveTG' has two templates with one instance
      -- each (auto-spawned by 'loadTemplateGraph').
      testCase "multi-template: template before instance order" $ do
        let tg = sendReturnLiveTG
            totalNodes = sum (map (length . rgNodes . tplGraph)
                                  (tgTemplates tg))
        withRTGraph totalNodes 256 $ \handle -> do
          loadTemplateGraph handle tg
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          let perTpl = [ (i, [i])
                       | i <- [0 .. length (tgTemplates tg) - 1]
                       ]
          actual @?= expectedGlobalTG tg perTpl
          -- Stronger ordering check: every template-0 entry must
          -- precede every template-1 entry in the flat list.
          let tids   = map (\(t, _, _) -> t) actual
              afterT = dropWhile (== 0) tids
          all (== 1) afterT @?= True

    , -- Stronger regression for the canonical-order contract: the
      -- previous case's slot indices coincide with template_id
      -- (template 0 → slot 0, template 1 → slot 1), so it doesn't
      -- prove that template order /dominates/ slot order. Spawn an
      -- extra template-0 instance after the auto-spawned pair,
      -- which the pool places at slot 2 (first growth past the
      -- occupied 0,1). Slot order is now interleaved across
      -- templates (template 0 owns slots 0, 2; template 1 owns
      -- slot 1) but the global schedule must still group all
      -- template-0 entries before any template-1 entry.
      testCase "multi-template: template order dominates slot order" $ do
        let tg = sendReturnLiveTG
            totalNodes = sum (map (length . rgNodes . tplGraph)
                                  (tgTemplates tg))
        withRTGraph (totalNodes + 16) 256 $ \handle -> do
          loadTemplateGraph handle tg
          extraSlot <- c_rt_graph_template_instance_add handle 0
          extraSlot @?= 2  -- pool grew past the auto-spawned 0,1
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          actual @?= expectedGlobalTG tg
            [ (0, [0, 2])  -- template 0 owns slot 0 (auto) and slot 2 (extra)
            , (1, [1])     -- template 1 owns slot 1 (auto)
            ]
          -- Pin the dominance directly: the flat tid sequence must
          -- be a non-decreasing run, so a slot-1 entry can never
          -- appear between two slot-0 entries.
          let tids = map (\(t, _, _) -> t) actual
          tids @?= sort tids
          -- And the slot interleaving must actually be present in
          -- this test's data (otherwise we're not exercising the
          -- "template order dominates" path).
          let tidSlots = nub [(t, s) | (t, s, _) <- actual]
          tidSlots @?= [(0, 0), (0, 2), (1, 1)]

    , -- Non-contiguous free-layer ordinals must survive into the
      -- global schedule. This test resolves each entry's
      -- (template, step) through the C0a accessors and pins the
      -- divergent layer's ordinals at [0, 2] (not [0, 1]).
      testCase "non-contiguous layer ordinals survive" $ do
        rg <- case lowerGraph divergentLayerGraph
                >>= compileRuntimeGraph of
          Right rg' -> pure rg'
          Left err  -> assertFailure
                         ("c0b divergent compile: " <> err)
                       >> error "unreachable"
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          c_rt_graph_process handle 256
          entries <- readGlobalSchedule handle
          -- Resolve every entry's step back to its ordinal list.
          ordinalsPerEntry <-
            forM entries $ \(tid, _slot, step) -> do
              n <- c_rt_graph_test_template_schedule_step_item_count
                     handle (fromIntegral tid)
                     (fromIntegral step)
              forM [0 .. fromIntegral n - 1] $ \j ->
                c_rt_graph_test_template_schedule_step_region
                  handle (fromIntegral tid)
                  (fromIntegral step) j
          let toInts = map fromIntegral
              -- Split entries by step_index; instance 0 only.
              steps  = nub (map (\(_, _, p) -> p) entries)
              perStep =
                [ ( s
                  , [ ords
                    | ((_, _, p), ords) <- zip entries
                                              (map toInts
                                                   ordinalsPerEntry)
                    , p == s
                    ]
                  )
                | s <- steps
                ]
          -- Pin the divergent shape: step 0 = [0, 2], step 1 = [1],
          -- step 2 = [3] (the barrier sink). The entries for the
          -- single instance present each step exactly once.
          map snd perStep @?=
            [ [[0, 2]]
            , [[1]]
            , [[3]]
            ]

    , -- Reload through a Haskell loader calls c_rt_graph_clear
      -- internally, which drops the prior block's global schedule
      -- snapshot. After the second load the global schedule must
      -- reflect only the new graph's shape.
      testCase "reload clears prior global schedule" $ do
        (rgChain,  _) <- compileBoth "chain"  chainGraph
        (rgSimple, _) <- compileBoth "simple" simpleGraph
        let totalNodes = max (length (rgNodes rgChain))
                             (length (rgNodes rgSimple))
        withRTGraph totalNodes 256 $ \handle -> do
          loadRuntimeGraph handle rgChain
          c_rt_graph_process handle 256
          firstCount <- c_rt_graph_test_global_schedule_entry_count
                          handle
          assertBool "expected non-empty schedule after first load"
                     (firstCount > 0)
          loadRuntimeGraph handle rgSimple
          c_rt_graph_process handle 256
          actual <- readGlobalSchedule handle
          actual @?= expectedGlobalRG rgSimple [0]
    ]

------------------------------------------------------------
-- Phase 4.E.2.C0c/C1a: global-schedule banded serial executor
------------------------------------------------------------
--
-- C0c promotes the C0b global schedule from observation to an
-- executable serial path, gated by a test-only switch. C1a routes that
-- executor through C0d bands, still serially. This group keeps the
-- worker pool disabled: the schedule executor must render
-- byte-identical output to the legacy nested loop, preserve §2.E
-- release accounting, and keep the B3 reduction-capture equivalence
-- when both switches are enabled.
-- C++-only graphs with no schedule metadata fall back to the legacy
-- executor; that path is covered in the C++ test suite because Haskell
-- loaders always ship schedule metadata.

c0cScheduleExecutorTests :: TestTree
c0cScheduleExecutorTests =
  let nframes = 256
      blocks  = 4
  in testGroup "Phase 4.E.2.C0c/C1a: global-schedule banded serial executor"
       [ testGroup "legacy executor equals global schedule"
           [ testCase "single template, unfused" $ do
               (rg, _) <- compileBoth "chain" chainGraph
               assertDirectEqualsScheduleRG
                 "chain" loadRuntimeGraph rg nframes blocks

           , testCase "single template, fused" $ do
               (_, rg) <- compileBoth "filtered-saw" filteredSawGraph
               assertDirectEqualsScheduleRG
                 "filtered-saw" loadRuntimeGraphFused rg nframes blocks

           , testCase "multi-template live send/return" $
               assertDirectEqualsScheduleTG
                 "send-return-live" loadTemplateGraph
                 sendReturnLiveTG nframes blocks

           , testCase "non-contiguous free layer" $ do
               rg <- case lowerGraph divergentLayerGraph
                       >>= compileRuntimeGraph of
                 Right rg' -> pure rg'
                 Left err  -> assertFailure
                                ("c0c divergent compile: " <> err)
                              >> error "unreachable"
               assertDirectEqualsScheduleRG
                 "divergent-layer" loadRuntimeGraph rg nframes blocks
           ]

       , testGroup "T-9 under global schedule"
           [ testGroup "single template, unfused loader"
               [ testCase name $ do
                   (rtUn, _) <- compileBoth name g
                   assertScheduleDirectEqualsReductionRG
                     name loadRuntimeGraph rtUn nframes blocks
               | (name, g) <- t9CorpusGraphs
               ]

           , testGroup "single template, fused loader"
               [ testCase name $ do
                   (_, rtF) <- compileBoth name g
                   assertScheduleDirectEqualsReductionRG
                     name loadRuntimeGraphFused rtF nframes blocks
               | (name, g) <- t9CorpusGraphs
               ]

           , testGroup "multi-template, unfused loader"
               [ testCase name $
                   assertScheduleDirectEqualsReductionTG
                     name loadTemplateGraph tg nframes blocks
               | (name, tg) <- t9CorpusTemplates
               ]

           , testGroup "multi-template, fused loader"
               [ testCase name $
                   assertScheduleDirectEqualsReductionTG
                     name loadTemplateGraphFused tg nframes blocks
               | (name, tg) <- t9CorpusTemplates
               ]
           ]

       , testCase "release-then-free still runs once per instance block" $ do
           let voice = runSynth $ do
                 e <- env 1.0 0.0005 0.002 0.5 0.002
                 out 0 e
               rg = case lowerGraph voice >>= compileRuntimeGraph of
                 Right r  -> r
                 Left err -> error err

           withRTGraph (length (rgNodes rg)) nframes $ \handle -> do
             loadRuntimeGraph handle rg
             c_rt_graph_test_set_global_schedule_execution handle 1

             s0 <- c_rt_graph_instance_status handle 0
             s0 @?= instanceStatusLive

             c_rt_graph_process handle (fromIntegral nframes)
             c_rt_graph_instance_release handle 0
             s1 <- c_rt_graph_instance_status handle 0
             s1 @?= instanceStatusReleasing

             let drain n
                   | n <= 0    = pure False
                   | otherwise = do
                       c_rt_graph_process handle (fromIntegral nframes)
                       alive <- c_rt_graph_instance_alive handle 0
                       if alive == 0 then pure True else drain (n - 1)
             freed <- drain (64 :: Int)
             assertBool
               "scheduled executor should auto-free within 64 blocks"
               freed

             s2 <- c_rt_graph_instance_status handle 0
             s2 @?= (-1)
       ]

------------------------------------------------------------
-- Phase 4.E.2.C0d: global-schedule runnable bands
------------------------------------------------------------
--
-- C0d derives the banded view that C1a consumes serially and C1c can
-- consume as worker dispatch groups. The conservative v1
-- rule is intentionally narrow:
-- barriers are singleton serial bands, and a free band contains only
-- FreeLayer entries with at most one step per instance slot. That
-- avoids violating per-instance layer order without shipping the full
-- region dependency graph to the runtime.

c0dGlobalScheduleBandTests :: TestTree
c0dGlobalScheduleBandTests =
  testGroup "Phase 4.E.2.C0d: global-schedule runnable bands"
    [ testCase "fresh handle: empty bands" $
        withRTGraph 4 256 $ \handle -> do
          c_rt_graph_process handle 256
          entries <- readGlobalSchedule handle
          bands   <- readGlobalScheduleBands handle
          entries @?= []
          bands   @?= []

    , testCase "bands form a conservative partition" $ do
        (rg, _) <- compileBoth "chain" chainGraph
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          c_rt_graph_process handle 256
          assertGlobalScheduleBandsWellFormed "chain" handle

    , testCase "free-only instances share one band" $ do
        let computeOnly = runSynth $ do
              o <- sinOsc 110.0 0.0
              _ <- gain o 0.25
              pure ()
        rg <- case lowerGraph computeOnly >>= compileRuntimeGraph of
          Right r  -> pure r
          Left err -> assertFailure ("compute-only compile: " <> err)
                      >> error "unreachable"
        steps <- case layeredRegionSchedule rg of
          Right ss -> pure ss
          Left err -> assertFailure
                        ("compute-only layered schedule: " <> err)
                      >> error "unreachable"
        let expectedFreeOnly =
              case steps of
                [ScheduleFreeLayer _] -> True
                _                     -> False
        assertBool
          ("expected compute-only graph to be one free layer, got "
           <> show steps)
          expectedFreeOnly

        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          _ <- c_rt_graph_template_instance_add handle 0
          _ <- c_rt_graph_template_instance_add handle 0
          c_rt_graph_process handle 256
          entries <- readGlobalSchedule handle
          entries @?= expectedGlobalRG rg [0, 1, 2]
          bands <- readGlobalScheduleBands handle
          bands @?= [(1, 0, 3)]
          assertGlobalScheduleBandsWellFormed "compute-only" handle

    , testCase "same-instance free layers split before barrier" $ do
        rg <- case lowerGraph divergentLayerGraph >>= compileRuntimeGraph of
          Right r  -> pure r
          Left err -> assertFailure ("c0d divergent compile: " <> err)
                      >> error "unreachable"
        withRTGraph (length (rgNodes rg)) 256 $ \handle -> do
          loadRuntimeGraph handle rg
          c_rt_graph_process handle 256
          entries <- readGlobalSchedule handle
          entries @?= expectedGlobalRG rg [0]
          bands <- readGlobalScheduleBands handle
          bands @?= [(1, 0, 1), (1, 1, 1), (0, 2, 1)]
          assertGlobalScheduleBandsWellFormed "divergent" handle

    , testCase "reload clears prior band snapshot" $ do
        (rgChain,  _) <- compileBoth "chain"  chainGraph
        (rgSimple, _) <- compileBoth "simple" simpleGraph
        let totalNodes = max (length (rgNodes rgChain))
                             (length (rgNodes rgSimple))
        withRTGraph totalNodes 256 $ \handle -> do
          loadRuntimeGraph handle rgChain
          c_rt_graph_process handle 256
          firstCount <- c_rt_graph_test_global_schedule_band_count handle
          assertBool "expected non-empty bands after first load"
                     (firstCount > 0)
          loadRuntimeGraph handle rgSimple
          c_rt_graph_process handle 256
          assertGlobalScheduleBandsWellFormed "simple after reload" handle
    ]

------------------------------------------------------------
-- Phase 4.E.2.C1c-c: worker-schedule integration gates
------------------------------------------------------------
--
-- C1c-b added the conservative worker-dispatch path for eligible Free
-- bands. C1c-c keeps the same bit-equivalence discipline as T-9 and
-- C0c, but enables the graph-owned worker pool while the schedule
-- executor is active. The corpus test catches loader/runtime boundary
-- drift; the final small test proves that Haskell-loaded metadata can
-- enter the worker path, not merely run with idle background threads.

c1cWorkerScheduleTests :: TestTree
c1cWorkerScheduleTests =
  let nframes = 256
      blocks  = 4
      pool    = 3
  in testGroup "Phase 4.E.2.C1c-c: worker-schedule equivalence"
       [ testGroup "T-9 under global schedule + pool_size=3"
           [ testGroup "single template, unfused loader"
               [ testCase name $ do
                   (rtUn, _) <- compileBoth name g
                   assertSchedulePoolDirectEqualsReductionRG
                     name loadRuntimeGraph rtUn pool nframes blocks
               | (name, g) <- t9CorpusGraphs
               ]

           , testGroup "single template, fused loader"
               [ testCase name $ do
                   (_, rtF) <- compileBoth name g
                   assertSchedulePoolDirectEqualsReductionRG
                     name loadRuntimeGraphFused rtF pool nframes blocks
               | (name, g) <- t9CorpusGraphs
               ]

           , testGroup "multi-template, unfused loader"
               [ testCase name $
                   assertSchedulePoolDirectEqualsReductionTG
                     name loadTemplateGraph tg pool nframes blocks
               | (name, tg) <- t9CorpusTemplates
               ]

           , testGroup "multi-template, fused loader"
               [ testCase name $
                   assertSchedulePoolDirectEqualsReductionTG
                     name loadTemplateGraphFused tg pool nframes blocks
               | (name, tg) <- t9CorpusTemplates
               ]
           ]

       , testCase "schedule pool matches legacy on a representative graph" $ do
           (rg, _) <- compileBoth "chain" chainGraph
           assertDirectEqualsSchedulePoolRG
             "chain" loadRuntimeGraph rg pool nframes blocks

       , testCase "Haskell-loaded free-only graph enters worker dispatch" $ do
           let computeOnly = runSynth $ do
                 o <- sinOsc 110.0 0.0
                 _ <- gain o 0.25
                 pure ()
           rg <- case lowerGraph computeOnly >>= compileRuntimeGraph of
             Right r  -> pure r
             Left err -> assertFailure ("c1c compute-only compile: " <> err)
                         >> error "unreachable"

           withRTGraph (length (rgNodes rg)) nframes $ \handle -> do
             loadRuntimeGraph handle rg
             _ <- c_rt_graph_template_instance_add handle 0
             _ <- c_rt_graph_template_instance_add handle 0
             c_rt_graph_test_set_worker_pool_size handle (fromIntegral pool)
             c_rt_graph_test_set_global_schedule_execution handle 1
             c_rt_graph_process handle (fromIntegral nframes)

             bands <- c_rt_graph_test_last_parallel_band_count handle
             entries <- c_rt_graph_test_last_parallel_entry_count handle
             assertBool "expected at least one worker-dispatched band"
                        (bands > 0)
             entries @?= 3
       ]

------------------------------------------------------------
-- Phase 6.A.2: pattern corpus
--
-- Three verification layers:
--   1. Deterministic expansion: 'expandPattern' over the fixed
--      'corpusRange' produces an inline-pinned event list per row.
--   2. Corpus shape: each row's compiled 'TemplateGraph' carries the
--      kernels / template-count / ordering hypothesized in the
--      Phase 6.A.2 design note.
--   3. Driver-stub feasibility: 'checkDriverFeasibility' walks each
--      row's events and confirms every PEControlWrite / PEVoiceOff
--      has a prior PEVoiceOn for the same VoiceKey, every TemplateName
--      resolves against patternTemplates, every ControlTag's NodeTag
--      resolves to a tagged node in the referenced template, and
--      SamplePos is non-decreasing.
------------------------------------------------------------

-- | Anything a driver would need to refuse the pattern.
data DriverIssue
  = OutOfOrderEvent      !SamplePos !SamplePos
  | UnknownTemplate      !TemplateName
  | DuplicateVoiceOn     !VoiceKey
  | UnknownVoiceForOff   !VoiceKey
  | UnknownVoiceForWrite !VoiceKey
  | UnknownControlNode   !TemplateName !MigrationKey
  | InvalidControlSlot   !TemplateName !MigrationKey !Int !Int
    -- ^ ctSlot is out of range. Fields: requested slot, the
    -- resolved node's actual control count.
  | HotSwapTemplateLost  !VoiceKey !TemplateName
    -- ^ A 'PEHotSwap' payload omits a template for which a voice
    -- was still open. The driver would have to either force-release
    -- the orphan voice or refuse the swap; v1 validator reports it
    -- and drops the voice from the open set so subsequent writes
    -- against it surface as 'UnknownVoiceForWrite'.
  deriving (Eq, Show)

-- | Walk a pattern's events against its 'patternTemplates' and
-- collect every reason a driver could not execute them. Returns the
-- empty list iff the pattern is feasible.
--
-- The active 'TemplateGraph' is threaded through the fold: a
-- 'PEHotSwap' event replaces it, so subsequent 'TemplateName' /
-- 'ControlTag' resolution runs against the new payload. This means
-- a row that opens a voice, hot-swaps, and writes to that voice
-- post-swap is rejected if the new payload no longer carries the
-- voice's template or tagged nodes.
--
-- Deferred to 6.A.3: §5.2 state-preservation invariants across a
-- hot-swap. A swap payload that retains a voice's template name but
-- moves the voice's migration-keyed nodes to different 'NodeKind's
-- would still pass this validator while breaking state migration.
-- Naming the gap here lets 6.A.3 inherit a specific TODO rather
-- than rediscover it empirically.
checkDriverFeasibility
  :: Pattern
  -> [(SamplePos, PatternEvent)]
  -> [DriverIssue]
checkDriverFeasibility pat = go (patternTemplates pat) M.empty Nothing
  where
    go :: TemplateGraph
       -> M.Map VoiceKey TemplateName
       -> Maybe SamplePos
       -> [(SamplePos, PatternEvent)]
       -> [DriverIssue]
    go _  _    _        []                 = []
    go tg open lastPos  ((pos, ev) : rest) =
      let templates = tgTemplates tg

          lookupT :: TemplateName -> Maybe Template
          lookupT (TemplateName n) = find ((== n) . tplName) templates

          resolveNode :: TemplateName -> MigrationKey -> Maybe RuntimeNode
          resolveNode tname key = do
            t <- lookupT tname
            find (\n -> rnMigrationKey n == Just key)
                 (rgNodes (tplGraph t))

          checkCtrl :: TemplateName -> ControlTag -> [DriverIssue]
          checkCtrl tname (ControlTag key slot) =
            case resolveNode tname key of
              Nothing -> [UnknownControlNode tname key]
              Just n  ->
                let count = length (rnControls n)
                in if slot < 0 || slot >= count
                     then [InvalidControlSlot tname key slot count]
                     else []

          orderIssue = case lastPos of
            Just lp | pos < lp -> [OutOfOrderEvent pos lp]
            _                  -> []
      in case ev of
        PEVoiceOn tname vkey ctrls ->
          let tIssue  = if isJust (lookupT tname) then [] else [UnknownTemplate tname]
              dIssue  = if M.member vkey open then [DuplicateVoiceOn vkey] else []
              cIssue  = concatMap (checkCtrl tname . fst) ctrls
              open'   = M.insert vkey tname open
          in orderIssue ++ tIssue ++ dIssue ++ cIssue
             ++ go tg open' (Just pos) rest

        PEVoiceOff vkey ->
          case M.lookup vkey open of
            Nothing -> orderIssue ++ [UnknownVoiceForOff vkey]
                       ++ go tg open (Just pos) rest
            Just _  -> orderIssue
                       ++ go tg (M.delete vkey open) (Just pos) rest

        PEControlWrite vkey ct _ ->
          case M.lookup vkey open of
            Nothing -> orderIssue ++ [UnknownVoiceForWrite vkey]
                       ++ go tg open (Just pos) rest
            Just tname ->
              let cIssue = checkCtrl tname ct
              in orderIssue ++ cIssue ++ go tg open (Just pos) rest

        PEHotSwap _ newTg ->
          let newNames = S.fromList (map tplName (tgTemplates newTg))
              isLost (TemplateName n) = not (S.member n newNames)
              lostIssues =
                [ HotSwapTemplateLost vk tname
                | (vk, tname) <- M.toList open
                , isLost tname
                ]
              remainingOpen = M.filter (not . isLost) open
          in orderIssue ++ lostIssues
             ++ go newTg remainingOpen (Just pos) rest

patternCorpusTests :: TestTree
patternCorpusTests = testGroup "Phase 6.A.2: pattern corpus"
  [ testGroup "deterministic expansion pins"
      [ testCase "droneVibrato" $
          expandPattern droneVibrato corpusRange @?= droneVibratoEvents
      , testCase "arpeggioSendReturn" $
          expandPattern arpeggioSendReturn corpusRange @?= arpeggioSendReturnEvents
      , testCase "polyphonicStab" $
          expandPattern polyphonicStab corpusRange @?= polyphonicStabEvents
      , testCase "hotSwapEdit" $
          expandPattern hotSwapEdit corpusRange @?= hotSwapEditEvents
      , testCase "layeredEnsemble" $
          expandPattern layeredEnsemble corpusRange @?= layeredEnsembleEvents
      ]

  , testGroup "corpus shape pins"
      [ testCase "droneVibrato: one template named 'drone'" $ do
          let names = map tplName (tgTemplates (patternTemplates droneVibrato))
          names @?= ["drone"]

      , testCase "arpeggioSendReturn: voice + fx; fx claims RBusInLpfGainOut" $ do
          let tg   = patternTemplates arpeggioSendReturn
              names = sort (map tplName (tgTemplates tg))
          names @?= ["fx", "voice"]
          -- fx must come after voice (voice writes bus 5, fx reads it).
          map tplName (tgTemplates tg) @?= ["voice", "fx"]
          let fxKernels =
                [ rrKernel r
                | t <- tgTemplates tg
                , tplName t == "fx"
                , r <- rgRuntimeRegions (tplGraph t)
                ]
          assertBool
            ("expected RBusInLpfGainOut in fx kernels: " <> show fxKernels)
            (RBusInLpfGainOut `elem` fxKernels)

      , testCase "polyphonicStab: audio-modulated Gain blocks RNoiseLpfGainOut" $ do
          let tg      = patternTemplates polyphonicStab
              names   = map tplName (tgTemplates tg)
              kernels = concat
                [ map rrKernel (rgRuntimeRegions (tplGraph t))
                | t <- tgTemplates tg
                ]
          names @?= ["stab"]
          assertBool
            ("expected RNoiseLpfGainOut absent (envelope-modulated Gain): "
             <> show kernels)
            (RNoiseLpfGainOut `notElem` kernels)

      , testCase "hotSwapEdit: 'drone' template and swap payload" $ do
          let names = map tplName (tgTemplates (patternTemplates hotSwapEdit))
          names @?= ["drone"]
          let swapPayloadNames =
                [ map tplName (tgTemplates tg2)
                | (_, PEHotSwap _ tg2) <- hotSwapEditEvents
                ]
          swapPayloadNames @?= [["drone"]]

      , testCase "layeredEnsemble: bass + pad + fx; fx is scheduled last" $ do
          let tg     = patternTemplates layeredEnsemble
              names  = map tplName (tgTemplates tg)
          sort names @?= ["bass", "fx", "pad"]
          -- fx reads bus 5, bass and pad both write it; fx must
          -- follow both in the inter-template precedence order.
          last names @?= "fx"
          let fxKernels =
                [ rrKernel r
                | t <- tgTemplates tg
                , tplName t == "fx"
                , r <- rgRuntimeRegions (tplGraph t)
                ]
          assertBool
            ("expected RBusInLpfGainOut in ensemble fx kernels: "
             <> show fxKernels)
            (RBusInLpfGainOut `elem` fxKernels)
      ]

  , testGroup "driver-stub feasibility"
      [ testCase "droneVibrato"       $
          checkDriverFeasibility droneVibrato       droneVibratoEvents       @?= []
      , testCase "arpeggioSendReturn" $
          checkDriverFeasibility arpeggioSendReturn arpeggioSendReturnEvents @?= []
      , testCase "polyphonicStab"     $
          checkDriverFeasibility polyphonicStab     polyphonicStabEvents     @?= []
      , testCase "hotSwapEdit"        $
          checkDriverFeasibility hotSwapEdit        hotSwapEditEvents        @?= []
      , testCase "layeredEnsemble"    $
          checkDriverFeasibility layeredEnsemble    layeredEnsembleEvents    @?= []
      ]

  , testGroup "range-aware patternEvents"
      [ testCase "empty range yields no events" $
          expandPattern droneVibrato
            (SampleRange (SamplePos 0) (SamplePos 0))
          @?= []

      , testCase "range entirely after all events yields no events" $
          expandPattern droneVibrato
            (SampleRange (SamplePos 200000) (SamplePos 300000))
          @?= []

      , testCase "subrange [90000, 100000) isolates the 96000 control write" $
          expandPattern droneVibrato
            (SampleRange (SamplePos 90000) (SamplePos 100000))
          @?=
            [ ( SamplePos 96000
              , PEControlWrite (VoiceKey "v0")
                  (ControlTag (MigrationKey "lpf") 0) 800.0
              )
            ]

      , testCase
          "patternEvents itself respects the range (no expandPattern clamp)"
          $ do
            let r = SampleRange (SamplePos 90000) (SamplePos 100000)
            patternEvents droneVibrato r @?=
              [ ( SamplePos 96000
                , PEControlWrite (VoiceKey "v0")
                    (ControlTag (MigrationKey "lpf") 0) 800.0
                )
              ]

      , testCase
          "polyphonicStab subrange [10000, 30000) captures all 8 voice-offs"
          $ do
            let r = SampleRange (SamplePos 10000) (SamplePos 30000)
                evs = expandPattern polyphonicStab r
            length evs @?= 8
            all (\(SamplePos t, _) -> t == 24000) evs @?= True
      ]

  , testGroup "driver-stub negative cases"
      [ testCase "out-of-range ctSlot reports InvalidControlSlot" $ do
          -- droneVibrato's "lpf" node has 2 controls (freq + q);
          -- slot 99 is well out of range.
          let badEvents =
                [ (SamplePos 0,
                     PEVoiceOn (TemplateName "drone") (VoiceKey "v0")
                       [(ControlTag (MigrationKey "lpf") 99, 1500.0)])
                ]
              badPattern = droneVibrato
                { patternEvents = const badEvents }
          case checkDriverFeasibility badPattern badEvents of
            [InvalidControlSlot
              (TemplateName "drone") (MigrationKey "lpf") 99 _] ->
              pure ()
            issues ->
              assertFailure $
                "expected InvalidControlSlot, got: " <> show issues

      , testCase "unknown NodeTag reports UnknownControlNode" $ do
          let badEvents =
                [ (SamplePos 0,
                     PEVoiceOn (TemplateName "drone") (VoiceKey "v0")
                       [(ControlTag (MigrationKey "no-such-tag") 0,
                         1.0)])
                ]
              badPattern = droneVibrato
                { patternEvents = const badEvents }
          case checkDriverFeasibility badPattern badEvents of
            [UnknownControlNode
              (TemplateName "drone")
              (MigrationKey "no-such-tag")] ->
              pure ()
            issues ->
              assertFailure $
                "expected UnknownControlNode, got: " <> show issues

      , testCase
          "hot-swap losing an open voice's template reports HotSwapTemplateLost"
          $ do
            -- Open a "drone" voice, then swap to a payload that
            -- only carries a "stab" template. The validator should
            -- flag the orphaned voice and drop it from the open
            -- set; the subsequent PEControlWrite then surfaces as
            -- UnknownVoiceForWrite.
            let orphanTg = patternTemplates polyphonicStab
                badEvents =
                  [ (SamplePos 0,
                       PEVoiceOn (TemplateName "drone") (VoiceKey "v0")
                         [(ControlTag (MigrationKey "lpf") 0, 1500.0)])
                  , (SamplePos 96000,
                       PEHotSwap (SwapLabel "drop-drone") orphanTg)
                  , (SamplePos 120000,
                       PEControlWrite (VoiceKey "v0")
                         (ControlTag (MigrationKey "lpf") 0) 2000.0)
                  ]
                badPattern = droneVibrato
                  { patternEvents = const badEvents }
            checkDriverFeasibility badPattern badEvents @?=
              [ HotSwapTemplateLost (VoiceKey "v0") (TemplateName "drone")
              , UnknownVoiceForWrite (VoiceKey "v0")
              ]
      ]
  ]

------------------------------------------------------------
-- Phase 6.B.2a: OSC wire + dispatch
--
-- Three test groups:
--   1. Pure wire parser: hand-crafted byte sequences round-trip
--      to expected OscMessage values; bundles and unsupported
--      type tags are rejected explicitly.
--   2. Dispatch against the arpeggio-send-return fx template
--      (which carries 'tagged "lpf" / "outgain"') registered as
--      one voice key. Positive case writes a control; negative
--      cases mirror the §6.A DriverIssue shape.
--   3. OSC-safe identifier profile boundary cases.
------------------------------------------------------------

oscWireAndDispatchTests :: TestTree
oscWireAndDispatchTests = testGroup "Phase 6.B.2a: OSC wire + dispatch"
  [ wireTests
  , dispatchTests
  , identifierProfileTests
  ]

-- ----- Hand-built wire fixtures ------------------------------

-- An OSC-string is null-terminated, padded with zeros to a
-- 4-byte boundary. The padding count is the smallest p ≥ 0 such
-- that (length s + 1 + p) ≡ 0 mod 4.
oscString :: OBSC.ByteString -> OBSC.ByteString
oscString s =
  let n    = OBS.length s
      pad  = (4 - ((n + 1) `mod` 4)) `mod` 4
      zeros = OBS.replicate (1 + pad) 0
  in s `OBS.append` zeros

-- Big-endian 4-byte encoding of a Word32.
be4 :: [Word8] -> OBSC.ByteString
be4 = OBS.pack

-- The bit pattern of 1500.0 :: Float in IEEE 754 big-endian is
-- 0x44BB8000.
floatBytes1500 :: OBSC.ByteString
floatBytes1500 = be4 [0x44, 0xBB, 0x80, 0x00]

-- 42 as a big-endian 32-bit signed integer: 0x0000002A.
intBytes42 :: OBSC.ByteString
intBytes42 = be4 [0x00, 0x00, 0x00, 0x2A]

-- A complete OSC message: /fx0/lpf/0 ,f 1500.0
messageBytesFx0LpfFloat :: OBSC.ByteString
messageBytesFx0LpfFloat = OBS.concat
  [ oscString (OBSC.pack "/fx0/lpf/0")
  , oscString (OBSC.pack ",f")
  , floatBytes1500
  ]

-- /fx0/outgain/0 ,i 42
messageBytesFx0OutgainInt :: OBSC.ByteString
messageBytesFx0OutgainInt = OBS.concat
  [ oscString (OBSC.pack "/fx0/outgain/0")
  , oscString (OBSC.pack ",i")
  , intBytes42
  ]

wireTests :: TestTree
wireTests = testGroup "wire parser"
  [ testCase "parses /fx0/lpf/0 ,f 1500.0" $
      OSC.parseMessage messageBytesFx0LpfFloat
        @?= Right (OSC.OscMessage (OBSC.pack "/fx0/lpf/0")
                                   [OSC.OscArgFloat 1500.0])

  , testCase "parses /fx0/outgain/0 ,i 42" $
      OSC.parseMessage messageBytesFx0OutgainInt
        @?= Right (OSC.OscMessage (OBSC.pack "/fx0/outgain/0")
                                   [OSC.OscArgInt 42])

  , testCase "rejects an OSC bundle prefix" $
      case OSC.parseMessage (oscString (OBSC.pack "#bundle")) of
        Left  err -> assertBool ("expected bundle rejection, got: " <> err)
                                ("bundle" `isInfixOf` err)
        Right msg -> assertFailure ("expected Left, got: " <> show msg)

  , testCase "rejects an unsupported type tag" $ do
      let bytes = OBS.concat
            [ oscString (OBSC.pack "/foo")
            , oscString (OBSC.pack ",s")
            , oscString (OBSC.pack "hello")
            ]
      case OSC.parseMessage bytes of
        Left  _   -> pure ()
        Right msg -> assertFailure ("expected Left, got: " <> show msg)

  , testCase "rejects a truncated argument" $ do
      -- ,f promises 4 argument bytes; supply only 2.
      let bytes = OBS.concat
            [ oscString (OBSC.pack "/foo")
            , oscString (OBSC.pack ",f")
            , OBS.pack [0x44, 0xBB]
            ]
      case OSC.parseMessage bytes of
        Left  _   -> pure ()
        Right msg -> assertFailure ("expected Left, got: " <> show msg)

  , testCase "rejects trailing bytes after declared arguments" $ do
      -- A valid /fx0/lpf/0 ,f 1500.0 message followed by 4
      -- extra bytes the wire spec does not authorize.
      let bytes = OBS.concat
            [ messageBytesFx0LpfFloat
            , OBS.pack [0x00, 0x00, 0x00, 0x00]
            ]
      case OSC.parseMessage bytes of
        Left err -> assertBool ("expected trailing-byte rejection, got: " <> err)
                               ("trailing" `isInfixOf` err)
        Right msg -> assertFailure ("expected Left, got: " <> show msg)

  , testCase "rejects non-zero bytes in OSC-string padding" $ do
      -- '/foo' is 4 bytes + 1 NUL = 5 raw bytes; padding is
      -- 3 bytes to reach the next 4-byte boundary. A conforming
      -- producer fills them with NUL; we plant 0xFF in the
      -- first padding slot and assert the parser rejects it.
      let badAddrField =
            OBS.pack [0x2F, 0x66, 0x6F, 0x6F, 0x00, 0xFF, 0x00, 0x00]
          bytes = OBS.concat
            [ badAddrField
            , oscString (OBSC.pack ",f")
            , floatBytes1500
            ]
      case OSC.parseMessage bytes of
        Left err -> assertBool ("expected padding-zero rejection, got: " <> err)
                               ("padding" `isInfixOf` err)
        Right msg -> assertFailure ("expected Left, got: " <> show msg)
  ]

-- ----- Dispatch against a 6.A corpus template ----------------

-- Build a ResolveState that registers voice key "fx0" against
-- the arpeggio-send-return fx template. The voice's runtime
-- slot id is fixed at 1 (the IO layer would have this from a
-- prior rt_graph_realtime_reserve call). The fixture's
-- invariant is that "fx0" is OSC-safe; the @error@ below fires
-- only if 'registerVoice' is reused with a malformed key later.
arpeggioFxResolveState :: OSC.ResolveState
arpeggioFxResolveState =
  case OSC.registerVoice (OBSC.pack "fx0") 1 (OBSC.pack "fx")
         (OSC.emptyResolveState (patternTemplates arpeggioSendReturn)) of
    Right rs  -> rs
    Left  iss -> error $ "test fixture: " <> show iss

dispatchTests :: TestTree
dispatchTests = testGroup "dispatch against arpeggio-send-return/fx"
  [ testCase "control write resolves to the fx template's lpf slot 0" $ do
      let msg = OSC.OscMessage (OBSC.pack "/fx0/lpf/0")
                                [OSC.OscArgFloat 1500.0]
      case OSC.dispatch arpeggioFxResolveState msg of
        Right (OSC.DAControlWrite
                  { OSC.daSlotId     = 1
                  , OSC.daControlIdx = 0
                  , OSC.daValue      = v
                  }) -> v @?= 1500.0
        other -> assertFailure ("unexpected dispatch result: " <> show other)

  , testCase "int argument coerces to Double" $ do
      let msg = OSC.OscMessage (OBSC.pack "/fx0/outgain/0")
                                [OSC.OscArgInt 1]
      case OSC.dispatch arpeggioFxResolveState msg of
        Right da -> OSC.daValue da @?= 1.0
        Left  i  -> assertFailure ("expected success, got: " <> show i)

  , testCase "unknown voice key surfaces as DiUnknownVoice" $ do
      let msg = OSC.OscMessage (OBSC.pack "/no-such/lpf/0")
                                [OSC.OscArgFloat 1.0]
      OSC.dispatch arpeggioFxResolveState msg
        @?= Left (OSC.DiUnknownVoice (OBSC.pack "no-such"))

  , testCase "unknown node tag surfaces as DiUnknownNodeTag" $ do
      let msg = OSC.OscMessage (OBSC.pack "/fx0/no-such/0")
                                [OSC.OscArgFloat 1.0]
      OSC.dispatch arpeggioFxResolveState msg
        @?= Left (OSC.DiUnknownNodeTag (OBSC.pack "fx0")
                                        (OBSC.pack "no-such"))

  , testCase "out-of-range slot surfaces as DiInvalidControlSlot" $ do
      -- The fx template's lpf node has 2 controls (freq, q);
      -- slot 99 is out of range.
      let msg = OSC.OscMessage (OBSC.pack "/fx0/lpf/99")
                                [OSC.OscArgFloat 1.0]
      case OSC.dispatch arpeggioFxResolveState msg of
        Left (OSC.DiInvalidControlSlot
                  v t 99 _) -> do
          v @?= OBSC.pack "fx0"
          t @?= OBSC.pack "lpf"
        other -> assertFailure ("unexpected dispatch result: " <> show other)

  , testCase "reserved path segment 'swap' surfaces as DiReservedPathSegment" $ do
      let msg = OSC.OscMessage (OBSC.pack "/swap/lpf/0")
                                [OSC.OscArgFloat 1.0]
      OSC.dispatch arpeggioFxResolveState msg
        @?= Left (OSC.DiReservedPathSegment (OBSC.pack "swap"))

  , testCase "malformed address surfaces as DiInvalidAddressFormat" $ do
      let msg = OSC.OscMessage (OBSC.pack "/fx0/lpf") [OSC.OscArgFloat 1.0]
      OSC.dispatch arpeggioFxResolveState msg
        @?= Left (OSC.DiInvalidAddressFormat (OBSC.pack "/fx0/lpf"))

  , testCase "non-integer slot surfaces as DiSlotNotInteger" $ do
      let msg = OSC.OscMessage (OBSC.pack "/fx0/lpf/cutoff")
                                [OSC.OscArgFloat 1.0]
      OSC.dispatch arpeggioFxResolveState msg
        @?= Left (OSC.DiSlotNotInteger (OBSC.pack "cutoff"))

  , testCase "zero arguments surface as DiUnsupportedArgShape" $ do
      let msg = OSC.OscMessage (OBSC.pack "/fx0/lpf/0") []
      OSC.dispatch arpeggioFxResolveState msg
        @?= Left (OSC.DiUnsupportedArgShape 0)

  , testCase "two arguments surface as DiUnsupportedArgShape" $ do
      let msg = OSC.OscMessage (OBSC.pack "/fx0/lpf/0")
                                [OSC.OscArgFloat 1.0, OSC.OscArgInt 2]
      OSC.dispatch arpeggioFxResolveState msg
        @?= Left (OSC.DiUnsupportedArgShape 2)
  ]

-- ----- OSC-safe identifier profile ---------------------------

identifierProfileTests :: TestTree
identifierProfileTests = testGroup "OSC-safe identifier profile"
  [ testCase "accepts plain ASCII alphanumeric" $
      OSC.isOscSafeIdentifier (OBSC.pack "fx0") @?= True

  , testCase "accepts underscore and hyphen" $ do
      OSC.isOscSafeIdentifier (OBSC.pack "snare_hi") @?= True
      OSC.isOscSafeIdentifier (OBSC.pack "kick-1")   @?= True

  , testCase "rejects empty string" $
      OSC.isOscSafeIdentifier OBS.empty @?= False

  , testCase "rejects strings longer than 16 bytes" $
      OSC.isOscSafeIdentifier (OBSC.pack "abcdefghijklmnopq")  -- 17
        @?= False

  , testCase "rejects strings containing '/'" $
      OSC.isOscSafeIdentifier (OBSC.pack "foo/bar") @?= False

  , testCase "rejects strings containing spaces" $
      OSC.isOscSafeIdentifier (OBSC.pack "foo bar") @?= False

  , testCase "registerVoice accepts an OSC-safe key" $
      case OSC.registerVoice (OBSC.pack "v0") 1 (OBSC.pack "drone")
             (OSC.emptyResolveState (patternTemplates droneVibrato)) of
        Right _   -> pure ()
        Left  iss -> assertFailure (show iss)

  , testCase "registerVoice rejects a reserved word" $
      OSC.registerVoice (OBSC.pack "swap") 1 (OBSC.pack "fx")
        (OSC.emptyResolveState (patternTemplates arpeggioSendReturn))
        @?= Left (OSC.DiReservedPathSegment (OBSC.pack "swap"))

  , testCase "registerVoice rejects an identifier-profile violation" $
      case OSC.registerVoice (OBSC.pack "bad name") 1 (OBSC.pack "fx")
             (OSC.emptyResolveState (patternTemplates arpeggioSendReturn)) of
        Left (OSC.DiIdentifierProfile k) -> k @?= OBSC.pack "bad name"
        other -> assertFailure (show other)

  , testCase "registerVoiceUnchecked stays reachable in state but not via dispatch" $ do
      -- Defense-in-depth: even if internal code installs a key
      -- outside the OSC-safe profile via the escape hatch, the
      -- dispatch path-segment validator catches non-conforming
      -- segments before the lookup runs. The registered-but-
      -- unreachable voice is documentation of the design
      -- property, not a separate gate.
      let rs = OSCI.registerVoiceUnchecked
                 (OBSC.pack "bad name") 1 (OBSC.pack "fx")
                 (OSC.emptyResolveState (patternTemplates arpeggioSendReturn))
          msg = OSC.OscMessage (OBSC.pack "/bad/lpf/0")
                                [OSC.OscArgFloat 1.0]
      -- 'bad' is OSC-safe (dispatch never sees 'bad name'),
      -- so the path doesn't match any registered key and the
      -- voice-lookup miss surfaces.
      OSC.dispatch rs msg
        @?= Left (OSC.DiUnknownVoice (OBSC.pack "bad"))
  ]

------------------------------------------------------------
-- Phase 6.B.2b: OSC listener (bracketed UDP)
--
-- Four tests:
--   1. Bracket cleanup: withOscListener returns; the listener
--      thread and socket are torn down.
--   2. Loopback: a UDP packet sent to the bound port reaches the
--      SetControlFn hook with the resolved (slot, node, slot,
--      value) tuple.
--   3. Malformed packet: junk bytes surface as LiParseFailure
--      via the issue hook and do not kill the listener — a
--      subsequent valid packet still dispatches.
--   4. Queue-full: a SetControlFn returning False surfaces as
--      LiQueueFull via the issue hook, not as an exception.
--
-- Tests use port 0 (OS-assigned) so they never collide with each
-- other or with anything bound on a fixed port. A 1-second
-- timeout wraps the blocking takeMVars so a regression that
-- breaks the listener hangs the test instead of running forever.
------------------------------------------------------------

oscListenerTests :: TestTree
oscListenerTests = testGroup "Phase 6.B.2b: OSC listener (bracketed UDP)"
  [ testCase "bracket cleanup: body return tears down listener" $ do
      rsRef <- newIORef arpeggioFxResolveState
      let hooks = OSC.ListenerHooks
            { OSC.lhSetControl = \_ _ _ _ -> pure True
            , OSC.lhOnIssue    = \_ -> pure ()
            }
      result <- OSC.withOscListenerHooks hooks rsRef
                  (OSC.defaultListenerConfig 0)
                  (\_info -> pure (42 :: Int))
      result @?= 42

  , testCase "loopback packet reaches the SetControlFn hook" $ do
      rsRef    <- newIORef arpeggioFxResolveState
      received <- newEmptyMVar
      let hooks = OSC.ListenerHooks
            { OSC.lhSetControl = \slotId nodeIx ctrlSlot val -> do
                putMVar received (slotId, nodeIx, ctrlSlot, val)
                pure True
            , OSC.lhOnIssue = \_ -> pure ()
            }
      OSC.withOscListenerHooks hooks rsRef (OSC.defaultListenerConfig 0)
        $ \info -> do
            sendUdpLoopback (OSC.liBoundPort info) messageBytesFx0LpfFloat
            mTuple <- timeout 1000000 (takeMVar received)
            case mTuple of
              Just (slotId, _node, ctrlSlot, val) -> do
                slotId   @?= 1
                ctrlSlot @?= 0
                val      @?= 1500.0
              Nothing ->
                assertFailure
                  "listener did not invoke SetControlFn within 1s"

  , testCase "malformed packet surfaces as LiParseFailure; listener continues" $ do
      rsRef  <- newIORef arpeggioFxResolveState
      issues <- newIORef []
      validDone <- newEmptyMVar
      let hooks = OSC.ListenerHooks
            { OSC.lhSetControl = \_ _ _ _ -> do
                putMVar validDone ()
                pure True
            , OSC.lhOnIssue = \i -> modifyIORef' issues (i :)
            }
      OSC.withOscListenerHooks hooks rsRef (OSC.defaultListenerConfig 0)
        $ \info -> do
            -- Junk bytes: no NUL, no valid OSC structure.
            sendUdpLoopback (OSC.liBoundPort info)
                            (OBS.pack [0x01, 0x02, 0x03, 0x04])
            -- Then a well-formed packet to prove the listener
            -- survived and is still processing.
            sendUdpLoopback (OSC.liBoundPort info) messageBytesFx0LpfFloat
            mDone <- timeout 1000000 (takeMVar validDone)
            case mDone of
              Just () -> pure ()
              Nothing ->
                assertFailure
                  "valid packet was not dispatched after malformed one"
      issueList <- readIORef issues
      assertBool ("expected at least one LiParseFailure issue, got: "
                  <> show issueList)
                 (any isParseFailure issueList)

  , testCase "queue-full surfaces as LiQueueFull, not an exception" $ do
      rsRef  <- newIORef arpeggioFxResolveState
      issues <- newEmptyMVar
      let hooks = OSC.ListenerHooks
            { OSC.lhSetControl = \_ _ _ _ -> pure False
              -- ^ pretend the realtime queue is always full
            , OSC.lhOnIssue    = putMVar issues
            }
      OSC.withOscListenerHooks hooks rsRef (OSC.defaultListenerConfig 0)
        $ \info -> do
            sendUdpLoopback (OSC.liBoundPort info) messageBytesFx0LpfFloat
            mIssue <- timeout 1000000 (takeMVar issues)
            case mIssue of
              Just (OSC.LiQueueFull 1 _ 0) -> pure ()
              other ->
                assertFailure $
                  "expected LiQueueFull, got: " <> show other
  ]
  where
    isParseFailure (OSC.LiParseFailure _) = True
    isParseFailure _                      = False

-- | Send a UDP datagram to a loopback port. Used by the listener
-- tests as the OSC client side. Opens, sends, closes — no
-- response handling.
sendUdpLoopback :: Int -> OBS.ByteString -> IO ()
sendUdpLoopback port payload = do
  let hints = OSCN.defaultHints
        { OSCN.addrSocketType = OSCN.Datagram
        , OSCN.addrFamily     = OSCN.AF_INET
        }
  addrs <- OSCN.getAddrInfo (Just hints) (Just "127.0.0.1")
                            (Just (show port))
  case addrs of
    []         -> error "sendUdpLoopback: no resolved address"
    (addr : _) -> do
      sock <- OSCN.socket (OSCN.addrFamily addr)
                          (OSCN.addrSocketType addr)
                          (OSCN.addrProtocol addr)
      _    <- OSCNSB.sendTo sock payload (OSCN.addrAddress addr)
      OSCN.close sock

------------------------------------------------------------
-- Phase 6.B.3: end-to-end OSC loopback verification
--
-- Drives the production listener against a real loaded
-- TemplateGraph, sends a UDP packet, and verifies the realtime
-- queue actually applied the control write — by reading bus
-- samples before and after and asserting the peak amplitude
-- changed in the predicted direction.
--
-- The hook layer is used only for thread-synchronisation: the
-- mock SetControlFn calls the real c_rt_graph_realtime_set_control
-- (the same call the production listener would make) and ALSO
-- signals an MVar so the test thread knows when to render the
-- post-OSC block. This proves the full receive → parse →
-- dispatch → FFI path without depending on threadDelay, and
-- without standing up external OSC tooling or audio hardware.
------------------------------------------------------------

oscEndToEndTests :: TestTree
oscEndToEndTests = testGroup "Phase 6.B.3: OSC end-to-end loopback"
  [ testCase "UDP /v0/outgain/0 0.1 changes the bus-0 peak amplitude" $ do
      let nframes  = 256
          sizeOfF :: Int
          sizeOfF = 4

          -- A tiny tagged graph: 440 Hz sine through a scalar
          -- gain (tagged "outgain") to hardware bus 0. Default
          -- gain 0.5, so the rendered peak is ~0.5 before the
          -- OSC write and ~0.1 after.
          graph = runSynth $ do
            o <- sinOsc 440.0 0.0
            g <- tagged "outgain" (gain o 0.5)
            out 0 g

      tg <- case compileTemplateGraph [("default", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \handle -> do
        loadTemplateGraph handle tg
        -- loadTemplateGraph auto-spawns instance 0 of each
        -- template; slot id 0 references the auto-spawn.

        rs0 <-
          case OSC.registerVoice (OBSC.pack "v0") 0 (OBSC.pack "default")
                 (OSC.emptyResolveState tg) of
            Right rs  -> pure rs
            Left  iss -> assertFailure (show iss)
                         >> error "unreachable"
        rsRef <- newIORef rs0

        -- Synchronisation hook. Wraps the production
        -- 'defaultListenerHooks' so we exercise the exact FFI
        -- call the CLI uses, then signals an MVar so the test
        -- knows when to render the post-OSC block.
        setCtrlDone <- newEmptyMVar
        let baseHooks = OSC.defaultListenerHooks handle
            setCtrl slotId nodeIx ctrlSlot val = do
              ok <- OSC.lhSetControl baseHooks
                      slotId nodeIx ctrlSlot val
              putMVar setCtrlDone ()
              pure ok
            hooks = baseHooks { OSC.lhSetControl = setCtrl }

        OSC.withOscListenerHooks hooks rsRef
          (OSC.defaultListenerConfig 0) $ \info -> do

          -- Render an initial block at the default gain (0.5)
          -- and capture the peak amplitude.
          c_rt_graph_process handle (fromIntegral nframes)
          allocaBytes (nframes * sizeOfF) $ \buf -> do
            _ <- c_rt_graph_read_bus handle 0
                   (fromIntegral nframes) (castPtr buf)
            initial <- peekArray nframes (buf :: PtrCFloat)
            let initialPeak =
                  maximum (map (\(CFloat x) -> abs x) initial)
            assertBool
              ("initial peak (gain=0.5) should be > 0.4, got "
               <> show initialPeak)
              (initialPeak > 0.4)

            -- Send the OSC packet: /v0/outgain/0 ,f 0.1
            -- The big-endian bit pattern for 0.1f is 0x3DCCCCCD.
            let packet = OBS.concat
                  [ oscString (OBSC.pack "/v0/outgain/0")
                  , oscString (OBSC.pack ",f")
                  , OBS.pack [0x3D, 0xCC, 0xCC, 0xCD]
                  ]
            sendUdpLoopback (OSC.liBoundPort info) packet

            -- Wait for the listener thread to receive the
            -- packet and finish the FFI call. 1-second timeout
            -- means a regression that breaks the listener
            -- fails the test fast instead of hanging.
            mDone <- timeout 1000000 (takeMVar setCtrlDone)
            case mDone of
              Just () -> pure ()
              Nothing ->
                assertFailure
                  "listener did not call FFI within 1s"

            -- Render another block. The realtime queue has
            -- the new gain (0.1) enqueued; rt_graph_process
            -- drains it before rendering.
            c_rt_graph_process handle (fromIntegral nframes)
            _ <- c_rt_graph_read_bus handle 0
                   (fromIntegral nframes) (castPtr buf)
            changed <- peekArray nframes (buf :: PtrCFloat)
            let changedPeak =
                  maximum (map (\(CFloat x) -> abs x) changed)
            assertBool
              ("post-OSC peak (gain=0.1) should be in (0.05, 0.2), got "
               <> show changedPeak)
              (changedPeak > 0.05 && changedPeak < 0.2)
  ]

------------------------------------------------------------
-- Phase 6.B.4: --osc-listen port parser regression tests
--
-- 'parseListenerPort' is the library-side validator that the
-- '--osc-listen [PORT]' CLI option uses to reject malformed or
-- out-of-range tokens. The CLI used to silently fall back to the
-- default port on bad input; these tests pin the strict behaviour.
------------------------------------------------------------

oscPortParserTests :: TestTree
oscPortParserTests = testGroup "Phase 6.B.4: --osc-listen port parser"
  [ testCase "accepts canonical port" $
      OSC.parseListenerPort "7000" @?= Just 7000

  , testCase "accepts low end of range" $
      OSC.parseListenerPort "1" @?= Just 1

  , testCase "accepts high end of range" $
      OSC.parseListenerPort "65535" @?= Just 65535

  , testCase "rejects zero" $
      OSC.parseListenerPort "0" @?= Nothing

  , testCase "rejects out-of-range numeric" $
      OSC.parseListenerPort "70000" @?= Nothing

  , testCase "rejects six-digit overflow guard" $
      OSC.parseListenerPort "100000" @?= Nothing

  , testCase "rejects non-digit token" $
      OSC.parseListenerPort "foo" @?= Nothing

  , testCase "rejects mixed digits and letters" $
      OSC.parseListenerPort "7000x" @?= Nothing

  , testCase "rejects empty string" $
      OSC.parseListenerPort "" @?= Nothing

  , testCase "rejects negative" $
      OSC.parseListenerPort "-7000" @?= Nothing
  ]

------------------------------------------------------------
-- Phase 6.C.3a: buffer pool wrapper tests
--
-- Exercises MetaSonic.Bridge.Buffer (alloc / load / clear)
-- against the C++ buffer pool ABI. No kernel involvement —
-- these tests verify the FFI return codes are translated to
-- BufferIssue exceptions correctly.
------------------------------------------------------------

bufferPoolTests :: TestTree
bufferPoolTests = testGroup "Phase 6.C.3a: buffer pool wrapper"
  [ testCase "alloc returns ID 0 on a fresh graph" $
      withRTGraph 16 256 $ \rt -> do
        buf <- allocBuffer rt 256
        bufferId buf @?= 0

  , testCase "alloc twice returns IDs 0 and 1" $
      withRTGraph 16 256 $ \rt -> do
        b0 <- allocBuffer rt 256
        b1 <- allocBuffer rt 256
        (bufferId b0, bufferId b1) @?= (0, 1)

  , testCase "alloc past pool capacity raises BiPoolFull" $
      withRTGraph 16 256 $ \rt -> do
        -- The pool is 64 wide. Filling it exactly should succeed;
        -- the 65th call must throw BiPoolFull.
        forM_ [0 .. 63 :: Int] $ \_ -> allocBuffer rt 1
        result <- try (allocBuffer rt 1)
        case result of
          Left BiPoolFull -> pure ()
          Left e          -> assertFailure $
            "expected BiPoolFull, got " <> show e
          Right b         -> assertFailure $
            "expected BiPoolFull, got Buffer " <> show (bufferId b)

  , testCase "loadBuffer rejects an unallocated ID" $
      withRTGraph 16 256 $ \rt -> do
        -- Construct a Buffer handle that has never been allocated.
        let fake = Buffer 99
        result <- try (loadBuffer rt fake [1.0, 2.0, 3.0])
        case result of
          Left (BiUnknownBufferId i) -> i @?= 99
          Left e                     -> assertFailure $
            "expected BiUnknownBufferId 99, got " <> show e
          Right _                    -> assertFailure
            "expected BiUnknownBufferId, got success"

  , testCase "loadBuffer rejects frame_count exceeding capacity" $
      withRTGraph 16 256 $ \rt -> do
        buf <- allocBuffer rt 4
        result <- try (loadBuffer rt buf [1, 2, 3, 4, 5, 6])
        case result of
          Left (BiFrameCountExceedsBuffer n) -> n @?= 6
          Left e                             -> assertFailure $
            "expected BiFrameCountExceedsBuffer, got " <> show e
          Right ()                           -> assertFailure
            "expected BiFrameCountExceedsBuffer, got success"

  , testCase "allocBuffer rejects negative frame count" $
      withRTGraph 16 256 $ \rt -> do
        result <- try (allocBuffer rt (-1))
        case result of
          Left (BiInvalidFrameCount n) -> n @?= (-1)
          Left e                       -> assertFailure $
            "expected BiInvalidFrameCount (-1), got " <> show e
          Right b                      -> assertFailure $
            "expected BiInvalidFrameCount, got Buffer " <> show b

  , testCase "clear-then-load reports BiUnknownBufferId" $
      withRTGraph 16 256 $ \rt -> do
        buf <- allocBuffer rt 4
        clearBuffer rt buf
        result <- try (loadBuffer rt buf [1, 2, 3])
        case result of
          Left (BiUnknownBufferId i) -> i @?= bufferId buf
          Left e                     -> assertFailure $
            "expected BiUnknownBufferId, got " <> show e
          Right _                    -> assertFailure
            "expected BiUnknownBufferId, got success"

  , testCase "clearBuffer on unallocated ID raises BiUnknownBufferId" $
      withRTGraph 16 256 $ \rt -> do
        result <- try (clearBuffer rt (Buffer 5))
        case result of
          Left (BiUnknownBufferId i) -> i @?= 5
          Left e                     -> assertFailure $
            "expected BiUnknownBufferId 5, got " <> show e
          Right _                    -> assertFailure
            "expected BiUnknownBufferId, got success"

  , testCase "alloc, clear, then alloc again reuses ID 0" $
      withRTGraph 16 256 $ \rt -> do
        b0 <- allocBuffer rt 64
        clearBuffer rt b0
        b1 <- allocBuffer rt 64
        bufferId b1 @?= 0
  ]

------------------------------------------------------------
-- Phase 6.C.3a: PlayBufMono end-to-end tests
--
-- Drives the real audio kernel against a loaded buffer:
-- load known samples, build playBufMono -> out, render one
-- block, assert bus-0 matches the loaded samples within
-- linear-interpolation tolerance, and counter-confirm that
-- the kernel actually read the buffer (rather than emitting
-- silent zeros that happened to match).
------------------------------------------------------------

playBufMonoTests :: TestTree
playBufMonoTests = testGroup "Phase 6.C.3a: PlayBufMono kernel"
  [ testCase "loads a 256-frame table and plays it forward" $ do
      let nframes  = 256
          sizeOfF :: Int
          sizeOfF = 4
          -- A 256-sample sine table. The kernel reads at rate=1.0
          -- starting at frame 0, so bus-0 should reproduce the
          -- table exactly (linear-interpolation between adjacent
          -- equal samples — rate=1.0 — is a no-op).
          table =
            [ sin (2 * pi * fromIntegral (i :: Int) / 256)
            | i <- [0 .. nframes - 1]
            ]
          graph = runSynthWithBuffer 0 $ \buf -> do
            s <- playBufMono buf (Param 1.0) (Param 0) (Param 0)
            out 0 s

      tg <- case compileTemplateGraph [("default", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \rt -> do
        -- §6.C.3b: buffer pool is now keyed off the RTGraph handle,
        -- so alloc-before-loadTemplateGraph also works. The
        -- ordering here is historical — kept because the
        -- surrounding test already reads cleaner this way.
        loadTemplateGraph rt tg
        buf <- allocBuffer rt nframes
        loadBuffer rt buf table
        bufferId buf @?= 0

        c_rt_graph_process rt (fromIntegral nframes)
        readCount    <- c_rt_graph_test_buffer_read_count    rt
        invalidCount <- c_rt_graph_test_buffer_invalid_read_count rt
        -- Counter-confirmed validation: the kernel must have
        -- read every output sample from the buffer. Without
        -- this assertion an all-zeros output would pass the
        -- value comparison below (every sample of the sine
        -- table near the zero crossing is small).
        readCount    @?= fromIntegral nframes
        invalidCount @?= 0

        allocaBytes (nframes * sizeOfF) $ \buf' -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr buf')
          rendered <- peekArray nframes (buf' :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
          assertBool
            ("rendered output should match the loaded sine table "
             <> "to within 1e-5 tolerance")
            (all (\(a, b) -> abs (a - b) < 1.0e-5)
                 (zip rcvs (map realToFrac table)))

  , testCase "unallocated buffer ID emits zeros + increments invalid-read counter" $ do
      let nframes  = 128
          sizeOfF :: Int
          sizeOfF = 4
          -- Reference Buffer 99 — well past the allocated set.
          graph = runSynth $ do
            s <- playBufMono (Buffer 99) (Param 1.0) (Param 0) (Param 0)
            out 0 s

      tg <- case compileTemplateGraph [("default", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        readCount    <- c_rt_graph_test_buffer_read_count    rt
        invalidCount <- c_rt_graph_test_buffer_invalid_read_count rt
        readCount    @?= 0
        invalidCount @?= fromIntegral nframes

        allocaBytes (nframes * sizeOfF) $ \bufPtr -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bufPtr)
          rendered <- peekArray nframes (bufPtr :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
          assertBool
            "unallocated ID must emit silence"
            (all (== 0.0) rcvs)

  , testCase "clear-then-render emits zeros + increments invalid-read counter" $ do
      let nframes  = 64
          sizeOfF :: Int
          sizeOfF = 4
          -- Allocate, load, clear *before* loading the graph so
          -- the configured control-0 value points at a cleared
          -- buffer ID. The kernel hits the invalid-read path.
          table = replicate nframes 0.5
          graphAt buf = runSynth $ do
            s <- playBufMono buf (Param 1.0) (Param 0) (Param 0)
            out 0 s

      withRTGraph 16 nframes $ \rt -> do
        buf <- allocBuffer rt nframes
        loadBuffer  rt buf table
        clearBuffer rt buf

        tg <- case compileTemplateGraph [("default", graphAt buf)] of
          Right t  -> pure t
          Left err -> assertFailure err >> error "unreachable"

        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        readCount    <- c_rt_graph_test_buffer_read_count    rt
        invalidCount <- c_rt_graph_test_buffer_invalid_read_count rt
        readCount    @?= 0
        invalidCount @?= fromIntegral nframes

        allocaBytes (nframes * sizeOfF) $ \bufPtr -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bufPtr)
          rendered <- peekArray nframes (bufPtr :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
          assertBool
            "cleared buffer must emit silence"
            (all (== 0.0) rcvs)

  , testCase "start_frame seeds the playhead at instance reset" $
      -- 8-frame buffer played back from frame 3 with rate=1.0,
      -- loop=0. Output: samples[3..7] then silence past the end.
      -- 5 in-bounds reads (frames 3..7) and 3 past-the-end reads.
      let table     = [10, 20, 30, 40, 50, 60, 70, 80] :: [Float]
          nframes   = length table
          expected  = [40, 50, 60, 70, 80, 0, 0, 0] :: [Float]
      in runPlayBufScenario table 1.0 3.0 0.0 nframes expected 5 3
           "start_frame=3"

  , testCase "loop_flag=1 wraps back to start_frame past the end" $
      -- 4-frame buffer rendered for 12 samples with loop=1: every
      -- output sample is a valid read after wrap.
      let table    = [1, 2, 3, 4] :: [Float]
          expected = [1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4] :: [Float]
      in runPlayBufScenario table 1.0 0.0 1.0 12 expected 12 0
           "loop wrap"

  , testCase "loop_flag=0 goes silent past the last frame (one-shot)" $
      -- Same 4-frame buffer, loop=0, 8 samples: 4 in-bounds reads
      -- then 4 past-the-end zero emits.
      let table    = [1, 2, 3, 4] :: [Float]
          expected = [1, 2, 3, 4, 0, 0, 0, 0] :: [Float]
      in runPlayBufScenario table 1.0 0.0 0.0 8 expected 4 4
           "one-shot boundary"

  , testCase "fractional rate yields linear interpolation" $
      -- 8-frame table of even integers, rate=0.5: positions are
      -- 0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5 — all in-bounds; every
      -- output sample counts as a valid read.
      let table    = [0, 2, 4, 6, 8, 10, 12, 14] :: [Float]
          expected = [0, 1, 2, 3, 4, 5, 6, 7] :: [Float]
      in runPlayBufScenario table 0.5 0.0 0.0 8 expected 8 0
           "fractional rate / linear interp"

  , testCase "negative rate is clamped to 0 (playhead frozen)" $
      -- rate=-1.0 clamps to 0 every sample; the playhead never
      -- advances and the kernel re-emits samples[0] = 10.
      let table    = [10, 20, 30, 40] :: [Float]
          expected = replicate 8 10 :: [Float]
      in runPlayBufScenario table (-1.0) 0.0 0.0 8 expected 8 0
           "negative rate clamp"

  , -- Regression test for the §6.C.2 contract: buffer_id is
    -- consulted at instance reset, never re-read per block. Build
    -- a graph that references Buffer 0 (filled with 7.0); load
    -- Buffer 1 with a different constant (99.0); render once and
    -- confirm output is 7.0; then live-write controls[0] = 1.0
    -- through rt_graph_instance_set_control and render again. The
    -- output must still be 7.0 — a regression that re-reads
    -- controls[0] per block would flip to 99.0 here.
    testCase "live set_control on slot 0 does not retarget buffer_id" $ do
      let nframes = 64
          sizeOfF :: Int
          sizeOfF = 4
          tableA = replicate nframes (7.0 :: Float)
          tableB = replicate nframes (99.0 :: Float)
          graph = runSynth $ do
            -- loop=1 so the entire 64-sample render reads valid
            -- samples; rate=1.0; start_frame=0.
            s <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 1.0)
            out 0 s

      tg <- case compileTemplateGraph [("default", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
          playBufIx =
            case [ rnIndex n
                 | tpl <- tgTemplates tg
                 , n   <- rgNodes (tplGraph tpl)
                 , rnKind n == KPlayBufMono
                 ] of
              [NodeIndex i] -> i
              other         -> error $
                "expected one PlayBufMono node, got " <> show other

      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        -- §6.C.3b: the buffer pool is keyed off the RTGraph
        -- handle now, so alloc-before-load also works. Kept
        -- post-load for readability — the surrounding test
        -- builds the graph and the buffers in the same logical
        -- step.
        bufA <- allocBuffer rt nframes
        bufB <- allocBuffer rt nframes
        bufferId bufA @?= 0
        bufferId bufB @?= 1
        loadBuffer rt bufA tableA
        loadBuffer rt bufB tableB

        let readBlock = allocaBytes (nframes * sizeOfF) $ \bufPtr -> do
              _ <- c_rt_graph_read_bus rt 0
                     (fromIntegral nframes) (castPtr bufPtr)
              rendered <- peekArray nframes (bufPtr :: PtrCFloat)
              pure (map (\(CFloat x) -> x) rendered)

        -- Block 1: kernel reads frozen buffer_id = 0, expects 7.0.
        c_rt_graph_process rt (fromIntegral nframes)
        block1 <- readBlock
        assertBool
          ("first block must come from buffer 0 (all 7.0); got "
           <> show (take 4 block1) <> " ...")
          (all (\x -> abs (x - 7.0) < 1.0e-5) block1)

        -- Live-write controls[0] = 1.0 on the PlayBufMono node.
        -- A kernel that re-reads controls[0] per block would now
        -- play from buffer 1 (all 99.0); a kernel that respects
        -- the §6.C.2 contract stays on buffer 0.
        c_rt_graph_instance_set_control rt 0
          (fromIntegral playBufIx) 0 (CDouble 1.0)

        c_rt_graph_process rt (fromIntegral nframes)
        block2 <- readBlock
        assertBool
          ("second block must STILL come from buffer 0 (all 7.0) "
           <> "after live set_control on slot 0; got "
           <> show (take 4 block2) <> " ... "
           <> "(a value near 99.0 means buffer_id was re-read)")
          (all (\x -> abs (x - 7.0) < 1.0e-5) block2)

        -- Counter sanity: 2 blocks × nframes valid reads, no
        -- invalid reads. A regression that took the invalid-read
        -- path would not pass this either.
        readCount    <- c_rt_graph_test_buffer_read_count         rt
        invalidCount <- c_rt_graph_test_buffer_invalid_read_count rt
        readCount    @?= fromIntegral (2 * nframes)
        invalidCount @?= 0

  , -- §6.C.3b slice 1: the buffer pool is keyed off the RTGraph
    -- handle, not RTGraphState, so a c_rt_graph_clear must leave
    -- the allocated buffers (and the per-handle counters)
    -- intact. Regression test against a future change that puts
    -- the pool back on RTGraphState.
    testCase "buffer pool survives c_rt_graph_clear" $
      withRTGraph 16 256 $ \rt -> do
        buf <- allocBuffer rt 8
        loadBuffer rt buf [1, 2, 3, 4, 5, 6, 7, 8]

        c_rt_graph_clear rt

        -- The allocated slot is still in use, so a fresh alloc
        -- must return ID 1 (not reuse 0). A pool wipe would
        -- return ID 0 here.
        buf2 <- allocBuffer rt 8
        bufferId buf2 @?= 1
        -- And the original slot's samples are still loaded; if
        -- the pool had been wiped, loadBuffer against `buf`
        -- (ID 0) would now throw BiUnknownBufferId.
        loadBuffer rt buf [9, 10, 11, 12, 13, 14, 15, 16]

  , -- §6.C.3b slice 1: hot-swap survival. Build a graph that
    -- references Buffer 0, load + render one block, run a full
    -- prepare_swap_from_graph + publish_swap + install cycle
    -- (which moves the old RTGraphState into the retire slot),
    -- render again with the SAME buffer ID still resolving to
    -- the SAME samples. A regression that put the pool back on
    -- RTGraphState would either crash on the second render
    -- (slot 0 unallocated in the new world) or emit silence
    -- (invalid-read path).
    testCase "buffer pool survives prepare_swap / publish_swap" $ do
      let nframes = 64
          sizeOfF :: Int
          sizeOfF = 4
          fill = replicate nframes (4.25 :: Float)
          graphRef = runSynth $ do
            s <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 1.0)
            out 0 s

      tg <- case compileTemplateGraph [("default", graphRef)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let capacity = templateGraphBuilderCapacity tg + 4

      withRTGraph capacity nframes $ \rt -> do
        buf <- allocBuffer rt nframes
        bufferId buf @?= 0
        loadBuffer rt buf fill

        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)

        let readBlock = allocaBytes (nframes * sizeOfF) $ \bp -> do
              _ <- c_rt_graph_read_bus rt 0
                     (fromIntegral nframes) (castPtr bp)
              rendered <- peekArray nframes (bp :: PtrCFloat)
              pure (map (\(CFloat x) -> x) rendered)

        block1 <- readBlock
        assertBool
          ("pre-swap block should render the fill (4.25); got "
           <> show (take 4 block1))
          (all (\x -> abs (x - 4.25) < 1.0e-5) block1)

        -- Run a full swap cycle through the public Haskell helper:
        -- prepare from the same template (the buffer reference
        -- carries across as a normal control[0] = 0 setup), publish,
        -- and let process_graph install on the next block.
        published <- hotSwapTemplateGraph rt capacity nframes tg
        published @?= True
        c_rt_graph_process rt (fromIntegral nframes)
        gen <- c_rt_graph_test_swap_generation rt
        gen @?= 1

        -- Render once more — the new world's PlayBufMono kernel
        -- should resolve buffer 0 and read the SAME samples.
        block2 <- readBlock
        assertBool
          ("post-swap block must still render the fill (4.25) — "
           <> "buffer pool was retired with old RTGraphState; got "
           <> show (take 4 block2))
          (all (\x -> abs (x - 4.25) < 1.0e-5) block2)

        -- Counter-confirm: two blocks × nframes valid reads
        -- accumulate across the swap. The new RTGraphState gets a
        -- fresh playhead (instance reset on install), but the
        -- handle-scoped counters do NOT reset — the same way the
        -- buffer pool itself does not reset.
        readCount    <- c_rt_graph_test_buffer_read_count         rt
        invalidCount <- c_rt_graph_test_buffer_invalid_read_count rt
        readCount    @?= fromIntegral (2 * nframes)
        invalidCount @?= 0

        _ <- collectRetiredSwapStats rt
        pure ()

  , -- §6.C.3b slice 2 retire-mid-render lifecycle. Alloc two
    -- buffers with distinguishable fills, build a graph that
    -- references buffer 0, render one block (assert fill 7.0),
    -- retire buffer 0 while audio is conceptually running,
    -- render another block (the kernel must take the
    -- invalid-read path, emit zeros, tick the invalid counter),
    -- collect the retired slot (succeeds because process_graph
    -- between retire and collect advanced the
    -- buffer-retire-generation counter), re-alloc, confirm we
    -- get ID 0 back with fresh empty storage.
    testCase "retire / collect lifecycle reclaims a slot live-safely" $ do
      let nframes = 64
          sizeOfF :: Int
          sizeOfF = 4
          fillA = replicate nframes (7.0 :: Float)
          fillB = replicate nframes (99.0 :: Float)
          graph = runSynth $ do
            s <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 1.0)
            out 0 s

      tg <- case compileTemplateGraph [("default", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \rt -> do
        buf0 <- allocBuffer rt nframes
        buf1 <- allocBuffer rt nframes
        bufferId buf0 @?= 0
        bufferId buf1 @?= 1
        loadBuffer rt buf0 fillA
        loadBuffer rt buf1 fillB

        loadTemplateGraph rt tg

        let readBlock = allocaBytes (nframes * sizeOfF) $ \bp -> do
              _ <- c_rt_graph_read_bus rt 0
                     (fromIntegral nframes) (castPtr bp)
              rendered <- peekArray nframes (bp :: PtrCFloat)
              pure (map (\(CFloat x) -> x) rendered)

        -- Block 1: kernel reads buffer 0 → fill A.
        c_rt_graph_process rt (fromIntegral nframes)
        block1 <- readBlock
        assertBool
          ("pre-retire block must read fill A (7.0); got "
           <> show (take 4 block1))
          (all (\x -> abs (x - 7.0) < 1.0e-5) block1)

        -- Live retire. Audio thread (conceptually running) is now
        -- between blocks; any captured samples.data() pointer is
        -- out of scope. The next kernel call must see Retired.
        retireBuffer rt buf0

        -- Collect IMMEDIATELY — the audio thread has not crossed
        -- a block boundary since retire, so the slot is still
        -- live and the call must fail with BiCollectStillLive.
        early <- try (collectRetiredBuffer rt buf0)
        case early of
          Left (BiCollectStillLive i) -> i @?= bufferId buf0
          Left e -> assertFailure $
            "expected BiCollectStillLive before a block ran, got "
              <> show (e :: BufferIssue)
          Right () -> assertFailure
            "collect must reject a retired slot before a block has run"

        -- Block 2: kernel sees Retired through the acquire-load
        -- and takes the invalid-read path. fillA is still in
        -- the slot's samples vector (retire doesn't touch
        -- storage), but the kernel never accesses it.
        c_rt_graph_process rt (fromIntegral nframes)
        block2 <- readBlock
        assertBool
          ("post-retire block must emit silence; got "
           <> show (take 4 block2))
          (all (== 0.0) block2)

        -- Now collect succeeds — buffer-retire-generation
        -- advanced when process_graph ticked at the top of
        -- block 2.
        collectRetiredBuffer rt buf0

        -- Re-alloc must return ID 0 (slot is back to Unallocated).
        -- A regression that left the slot Retired would return
        -- ID 2 here (next free past the still-allocated buf1).
        buf0' <- allocBuffer rt nframes
        bufferId buf0' @?= 0

        -- The fresh alloc zero-initialises samples; nothing
        -- carries over from fillA. Load a third pattern just to
        -- confirm the slot is actually writable again, then
        -- render and assert.
        loadBuffer rt buf0' (replicate nframes 0.25)
        c_rt_graph_process rt (fromIntegral nframes)
        block3 <- readBlock
        assertBool
          ("post-realloc block must read the new fill (0.25); got "
           <> show (take 4 block3))
          (all (\x -> abs (x - 0.25) < 1.0e-5) block3)

        -- Counter sanity. Two valid render blocks (block 1 + block 3)
        -- and one invalid render block (block 2). The retire/collect
        -- cycle itself ticks no read counters.
        readCount    <- c_rt_graph_test_buffer_read_count         rt
        invalidCount <- c_rt_graph_test_buffer_invalid_read_count rt
        readCount    @?= fromIntegral (2 * nframes)
        invalidCount @?= fromIntegral nframes

  , -- §6.C.3b slice 2: collect-without-retire is BiNotRetired,
    -- not BiCollectStillLive. Tests that the wrapper distinguishes
    -- the two failure modes correctly.
    testCase "collectRetiredBuffer on an Allocated slot raises BiNotRetired" $
      withRTGraph 16 64 $ \rt -> do
        buf <- allocBuffer rt 8
        result <- try (collectRetiredBuffer rt buf)
        case result of
          Left (BiNotRetired i) -> i @?= bufferId buf
          Left e                -> assertFailure $
            "expected BiNotRetired, got " <> show (e :: BufferIssue)
          Right ()              -> assertFailure
            "collect must reject a slot that was never retired"

  , -- §6.C.3b slice 2: clearBuffer is stopped-audio-only and now
    -- refuses to touch Retired slots — callers must go through
    -- collectRetiredBuffer to recycle a retired slot.
    testCase "clearBuffer rejects a Retired slot with BiUnknownBufferId" $
      withRTGraph 16 64 $ \rt -> do
        buf <- allocBuffer rt 8
        retireBuffer rt buf
        result <- try (clearBuffer rt buf)
        case result of
          Left (BiUnknownBufferId i) -> i @?= bufferId buf
          Left e                     -> assertFailure $
            "expected BiUnknownBufferId on a retired slot, got "
              <> show (e :: BufferIssue)
          Right ()                   -> assertFailure
            "clear must reject a retired slot"
  ]

-- | Test helper: render `nframes` of a `playBufMono` graph over a
-- single-template world, with the buffer's samples loaded and the
-- four `playBufMono` controls fixed to producer-provided defaults.
-- Asserts the rendered bus-0 output matches `expected` to within
-- 1e-5 and counter-confirms via @rt_graph_test_buffer_read_count@
-- (so an all-zeros regression cannot pass a value comparison).
runPlayBufScenario
  :: [Float]    -- ^ buffer samples
  -> Double     -- ^ rate
  -> Double     -- ^ start_frame argument (Param)
  -> Double     -- ^ loop_flag (Param)
  -> Int        -- ^ frames to render
  -> [Float]    -- ^ expected bus-0 output
  -> Int        -- ^ expected valid read count (buffer_read_count delta)
  -> Int        -- ^ expected invalid read count (buffer_invalid_read_count delta)
  -> String     -- ^ scenario label (used in failure messages)
  -> IO ()
runPlayBufScenario
    table rate start loopFlag nframes expected
    expectedValid expectedInvalid label = do
  let bufFrames = length table
      sizeOfF :: Int
      sizeOfF = 4
      graph = runSynthWithBuffer 0 $ \buf -> do
        s <- playBufMono buf (Param rate) (Param start) (Param loopFlag)
        out 0 s

  tg <- case compileTemplateGraph [("default", graph)] of
    Right t  -> pure t
    Left err -> assertFailure err >> error "unreachable"

  let totalNodes =
        sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

  withRTGraph totalNodes nframes $ \rt -> do
    loadTemplateGraph rt tg
    buf <- allocBuffer rt bufFrames
    loadBuffer rt buf table
    bufferId buf @?= 0

    c_rt_graph_process rt (fromIntegral nframes)
    readCount    <- c_rt_graph_test_buffer_read_count         rt
    invalidCount <- c_rt_graph_test_buffer_invalid_read_count rt
    -- Counter-confirmed validation: lock the exact read/invalid
    -- mix so a regression that emits zeros via a different code
    -- path (e.g. the kernel taking the wrong branch) cannot pass
    -- silently. See [feedback_counter_confirmed_validation.md].
    readCount    @?= fromIntegral expectedValid
    invalidCount @?= fromIntegral expectedInvalid

    allocaBytes (nframes * sizeOfF) $ \bufPtr -> do
      _ <- c_rt_graph_read_bus rt 0
             (fromIntegral nframes) (castPtr bufPtr)
      rendered <- peekArray nframes (bufPtr :: PtrCFloat)
      let rcvs = map (\(CFloat x) -> x) rendered
      assertBool
        (label <> ": rendered output mismatch.\n"
         <> "expected: " <> show expected <> "\n"
         <> "got:      " <> show rcvs)
        (all (\(a, b) -> abs (a - b) < 1.0e-5)
             (zip rcvs expected))

-- | Test helper: allocate a Buffer (without an RTGraph available)
-- so that the SynthM closure in the test reads identically to
-- the producer-side flow. The actual allocation happens at test
-- time; this just hands the test a stable id.
runSynthWithBuffer :: Int -> (Buffer -> SynthM ()) -> SynthGraph
runSynthWithBuffer bid k = runSynth (k (Buffer bid))

------------------------------------------------------------
-- Phase 6.C.4 follow-up: RecordBufMono kernel.
--
-- Pins the surface and a minimum-viable end-to-end render:
-- the kernel writes signal_in into an Allocated slot
-- sample-by-sample, advances the per-instance write head,
-- forwards signal_in to the audio output unchanged, and ticks
-- buffer_write_count per valid sample. The full record-then-
-- playback / retire-during-write / loop wrap / one-shot
-- boundary / live set_control regression / same-buffer
-- rejection / scheduler band coverage lands in the test-suite
-- commit alongside this slice.
------------------------------------------------------------

recordBufMonoSkeletonTests :: TestTree
recordBufMonoSkeletonTests =
  testGroup "Phase 6.C.4 follow-up: RecordBufMono kernel"
  [ testCase "inferEff produces a BufWrite on the buffer id" $ do
      let g = runSynth $ do
            src <- sinOsc 440.0 0.0
            mon <- recordBufMono (Buffer 7) src (Param 0.0)
            out 0 mon
          ir = case lowerGraph g of
                 Right ir' -> ir'
                 Left err  -> error err
          fp = resourceFootprint ir
      bfBufWrites       (rfBuffers fp) @?= S.singleton 7
      bfBufReads        (rfBuffers fp) @?= S.empty
      bfBufDelayedReads (rfBuffers fp) @?= S.empty

  , testCase "kindSpec / portInfo agree on KRecordBufMono shape" $ do
      -- Cross-check the per-kind table against the contract
      -- pinned in the design note. ksAudioArity drives every
      -- post-IR site that walks input ports; ksControlArity
      -- drives the default-controls vector size.
      ksTag          (kindSpec KRecordBufMono) @?= 21
      ksRate         (kindSpec KRecordBufMono) @?= SampleRate
      ksAudioArity   (kindSpec KRecordBufMono) @?= 2
      ksControlArity (kindSpec KRecordBufMono) @?= 3
      ksLabel        (kindSpec KRecordBufMono) @?= "recordBufMono"
      portInfo KRecordBufMono (PortIndex 0)
        @?= Just (PortInfo PortSampleAccurate "signal_in")
      portInfo KRecordBufMono (PortIndex 1)
        @?= Just (PortInfo PortSampleAccurate "loop_flag")
      portInfo KRecordBufMono (PortIndex 2) @?= Nothing

  , testCase "kernel writes signal_in and passes it through unchanged" $ do
      -- A graph that records a constant 0.25 into a 64-sample
      -- buffer and routes the pass-through to bus 0. After one
      -- block:
      --   * bus 0 must read 0.25 everywhere (pass-through).
      --   * buffer_write_count must equal nframes (every sample
      --     hit the valid-write path).
      --   * buffer_invalid_write_count must be 0 (slot stays
      --     Allocated for the whole block).
      let nframes = 64
          sizeOfF :: Int
          sizeOfF = 4
          graph = runSynth $ do
            mon <- recordBufMono (Buffer 0) (Param 0.25) (Param 0.0)
            out 0 mon

      tg <- case compileTemplateGraph [("default", graph)] of
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

        writeCount        <- c_rt_graph_test_buffer_write_count          rt
        invalidWriteCount <- c_rt_graph_test_buffer_invalid_write_count  rt
        writeCount        @?= fromIntegral nframes
        invalidWriteCount @?= 0

        allocaBytes (nframes * sizeOfF) $ \bp -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bp)
          rendered <- peekArray nframes (bp :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
          assertBool
            ("monitor output must equal signal_in (0.25); got "
             <> show (take 4 rcvs))
            (all (\x -> abs (x - 0.25) < 1.0e-5) rcvs)

  , -- §6.C.4 follow-up: record-then-playback, single block,
    -- two templates referencing the same buffer. The §6.C.4
    -- precedence union puts the writer template before the
    -- reader, so within one process_graph call the writer
    -- fills the buffer and the reader reads what was just
    -- written. Counter-confirmed both sides.
    testCase "record-then-playback within one block" $ do
      let nframes = 32
          sizeOfF :: Int
          sizeOfF = 4
          writerGraph = runSynth $ do
            -- recordBufMono is a sink-like writer with a
            -- pass-through output we ignore here.
            _ <- recordBufMono (Buffer 0) (Param 0.375) (Param 0.0)
            pure ()
          readerGraph = runSynth $ do
            s <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 0)
            out 0 s

      tg <- case compileTemplateGraph
                   [ ("writer", writerGraph)
                   , ("reader", readerGraph) ] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      -- §6.C.4 precedence union: writer must precede reader.
      let names = map tplName (tgTemplates tg)
      assertEqual "writer must precede reader after topo-sort"
        ["writer", "reader"] names

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \rt -> do
        buf <- allocBuffer rt nframes
        bufferId buf @?= 0
        loadBuffer rt buf (replicate nframes 0.0)

        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)

        writeCount <- c_rt_graph_test_buffer_write_count        rt
        readCount  <- c_rt_graph_test_buffer_read_count         rt
        invalidW   <- c_rt_graph_test_buffer_invalid_write_count rt
        invalidR   <- c_rt_graph_test_buffer_invalid_read_count  rt
        writeCount @?= fromIntegral nframes
        readCount  @?= fromIntegral nframes
        invalidW   @?= 0
        invalidR   @?= 0

        allocaBytes (nframes * sizeOfF) $ \bp -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bp)
          rendered <- peekArray nframes (bp :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
          assertBool
            ("reader must read back the recorded 0.375 from "
             <> "buffer 0 (pre-load was zeros); got "
             <> show (take 4 rcvs))
            (all (\x -> abs (x - 0.375) < 1.0e-5) rcvs)

  , -- §6.C.4 follow-up: retire-during-write. Render block 1
    -- (writer ticks valid count), retire the buffer, render
    -- block 2 (writer ticks invalid count, storage untouched),
    -- collect and re-alloc, render block 3 (valid count
    -- resumes). Mirrors the §6.C.3b retire-during-read test
    -- exactly.
    testCase "retire-during-write takes the invalid path; collect re-arms" $ do
      let nframes = 32
          -- Loop so the write head wraps within a block and the
          -- re-allocated slot is immediately writable again. A
          -- one-shot writer's head would be parked at the end of
          -- the buffer after block 1, and the kernel state
          -- survives retire / collect / re-alloc (we don't
          -- migrate writer state — Note [Per-node RecordBufMono
          -- state]). Looping avoids that interaction here and
          -- keeps the test scoped to the retire semantics.
          writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 1.0)
            pure ()

      tg <- case compileTemplateGraph [("writer", writerGraph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \rt -> do
        buf <- allocBuffer rt nframes
        loadBuffer rt buf (replicate nframes 0.0)
        loadTemplateGraph rt tg

        c_rt_graph_process rt (fromIntegral nframes)
        w1 <- c_rt_graph_test_buffer_write_count          rt
        i1 <- c_rt_graph_test_buffer_invalid_write_count  rt
        w1 @?= fromIntegral nframes
        i1 @?= 0

        retireBuffer rt buf
        c_rt_graph_process rt (fromIntegral nframes)
        w2 <- c_rt_graph_test_buffer_write_count          rt
        i2 <- c_rt_graph_test_buffer_invalid_write_count  rt
        -- Block 2 took the invalid path on every sample; the
        -- write counter must not have moved.
        w2 @?= w1
        i2 @?= fromIntegral nframes

        collectRetiredBuffer rt buf
        buf' <- allocBuffer rt nframes
        bufferId buf' @?= 0
        loadBuffer rt buf' (replicate nframes 0.0)

        c_rt_graph_process rt (fromIntegral nframes)
        w3 <- c_rt_graph_test_buffer_write_count          rt
        i3 <- c_rt_graph_test_buffer_invalid_write_count  rt
        -- After collect + re-alloc, the writer resumes valid
        -- writes (the kernel instance's write_head is whatever
        -- block 2 left it at — block 2 did not advance it).
        -- valid-count picks up by nframes; invalid unchanged.
        w3 @?= w2 + fromIntegral nframes
        i3 @?= i2

  , -- §6.C.4 follow-up: loop wrap. 4-frame buffer rendered for
    -- 12 samples with loop_flag=1; the kernel must wrap the
    -- write head and every sample is a valid write. Counter-
    -- confirmed.
    testCase "loop_flag=1 wraps the write head past the end" $ do
      let nframes = 12
          bufFrames = 4
          writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 1.0)
            pure ()

      tg <- case compileTemplateGraph [("writer", writerGraph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \rt -> do
        buf <- allocBuffer rt bufFrames
        loadBuffer rt buf (replicate bufFrames 0.0)
        loadTemplateGraph rt tg

        c_rt_graph_process rt (fromIntegral nframes)
        w <- c_rt_graph_test_buffer_write_count          rt
        i <- c_rt_graph_test_buffer_invalid_write_count  rt
        w @?= fromIntegral nframes
        i @?= 0

  , -- §6.C.4 follow-up: one-shot end. Same 4-frame buffer,
    -- 12 samples, loop_flag=0. After frame 3 the head is past
    -- the end and every subsequent sample takes the invalid
    -- path. Counter-confirmed: bufFrames valid writes, the
    -- remainder invalid.
    testCase "loop_flag=0 stops writing past the buffer end" $ do
      let nframes = 12
          bufFrames = 4
          writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 0.0)
            pure ()

      tg <- case compileTemplateGraph [("writer", writerGraph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \rt -> do
        buf <- allocBuffer rt bufFrames
        loadBuffer rt buf (replicate bufFrames 0.0)
        loadTemplateGraph rt tg

        c_rt_graph_process rt (fromIntegral nframes)
        w <- c_rt_graph_test_buffer_write_count          rt
        i <- c_rt_graph_test_buffer_invalid_write_count  rt
        w @?= fromIntegral bufFrames
        i @?= fromIntegral (nframes - bufFrames)

  , -- §6.C.4 follow-up: live set_control on slot 0 does NOT
    -- retarget the writer. Mirrors the §6.C.2 frozen-
    -- buffer-id regression test on the read side.
    testCase "live set_control on slot 0 does not retarget the writer" $ do
      let nframes = 16
          writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 0.0)
            pure ()

      tg <- case compileTemplateGraph [("writer", writerGraph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
          recIx =
            case [ rnIndex n
                 | tpl <- tgTemplates tg
                 , n   <- rgNodes (tplGraph tpl)
                 , rnKind n == KRecordBufMono
                 ] of
              [NodeIndex i] -> i
              other         -> error $
                "expected one RecordBufMono node, got " <> show other

      withRTGraph totalNodes nframes $ \rt -> do
        buf0 <- allocBuffer rt nframes
        buf1 <- allocBuffer rt nframes
        bufferId buf0 @?= 0
        bufferId buf1 @?= 1
        loadBuffer rt buf0 (replicate nframes 0.0)
        loadBuffer rt buf1 (replicate nframes 0.0)
        loadTemplateGraph rt tg

        -- Block 1: writer targets buffer 0 (the frozen id at
        -- instance reset).
        c_rt_graph_process rt (fromIntegral nframes)
        w1 <- c_rt_graph_test_buffer_write_count rt
        w1 @?= fromIntegral nframes

        -- Live-write controls[0] = 1.0 on the writer. A kernel
        -- that re-reads controls[0] per block would silently
        -- start writing buffer 1 from here onward. The §6.C.2
        -- contract pins the kernel to st->buffer_id, which is
        -- frozen at 0.
        c_rt_graph_instance_set_control rt 0
          (fromIntegral recIx) 0 (CDouble 1.0)

        c_rt_graph_process rt (fromIntegral nframes)
        w2 <- c_rt_graph_test_buffer_write_count rt
        i2 <- c_rt_graph_test_buffer_invalid_write_count rt
        -- Either (a) the writer kept writing buffer 0 — head
        -- continued past the end and stopped (loop_flag=0), so
        -- the second block's writes are all invalid; or (b) a
        -- regression would point the writer at buffer 1 which
        -- still has frames available, racking up nframes valid
        -- writes. The first nframes valid writes of block 1
        -- exactly filled buffer 0, so block 2 must be all
        -- invalid.
        w2 @?= w1
        i2 @?= fromIntegral nframes

  , -- §6.C.4 follow-up: same-buffer write from two templates is
    -- rejected at compileTemplateGraph time. This is the §6.C.4
    -- slice-4 diagnostic, now exercised end-to-end via the
    -- DSL builder (the existing slice-4 test used hand-built
    -- ResourceFootprints).
    testCase "same-buffer recordBufMono across templates is rejected" $ do
      let g1 = runSynth $ do
            _ <- recordBufMono (Buffer 3) (Param 0.25) (Param 0.0)
            pure ()
          g2 = runSynth $ do
            _ <- recordBufMono (Buffer 3) (Param 0.75) (Param 0.0)
            pure ()
      case compileTemplateGraph [("first", g1), ("second", g2)] of
        Right _ -> assertFailure
          "expected same-buffer BufWrite to be rejected end-to-end"
        Left err -> do
          assertBool
            ("diagnostic must mention 'buffer 3'; got: " <> err)
            ("buffer 3" `isInfixOf` err)
          assertBool
            ("diagnostic must mention 'first'; got: " <> err)
            ("first"  `isInfixOf` err)
          assertBool
            ("diagnostic must mention 'second'; got: " <> err)
            ("second" `isInfixOf` err)

  , -- §6.C.4 follow-up: scheduler barrier. A region with a
    -- writer must appear as a Barrier in segmentByBarrier's
    -- output, never inside a FreeSegment. Conservative
    -- serialization keeps the writer kernel from running in
    -- parallel with anything else.
    testCase "writer region is a scheduler Barrier, not a FreeSegment" $ do
      let writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 0.0)
            pure ()
      rg <- case lowerGraph writerGraph >>= compileRuntimeGraph of
              Right r  -> pure r
              Left err -> assertFailure err >> error "unreachable"

      let segments = segmentByBarrier rg
          writerInBarrier = any
            (\seg -> case seg of
                Barrier r ->
                  any (\nodeIx -> case [ rnKind n
                                       | n <- rgNodes rg
                                       , rnIndex n == nodeIx ] of
                                    [KRecordBufMono] -> True
                                    _                -> False)
                      (rrNodes r)
                FreeSegment _ -> False)
            segments
          writerInFreeSegment = any
            (\seg -> case seg of
                FreeSegment rs ->
                  any (\r -> any (\nodeIx ->
                                     case [ rnKind n
                                          | n <- rgNodes rg
                                          , rnIndex n == nodeIx ] of
                                       [KRecordBufMono] -> True
                                       _                -> False)
                                 (rrNodes r))
                      rs
                Barrier _ -> False)
            segments
      assertBool
        ("writer region must appear in a Barrier; segments = "
         <> show (length segments))
        writerInBarrier
      assertBool
        "writer region must never appear inside a FreeSegment"
        (not writerInFreeSegment)

  , -- §6.C.5 commit 1: a template whose footprint carries a
    -- BufWrite must be loaded with polyphony cap = 1. The auto-
    -- spawned instance at load time succeeds; any second
    -- c_rt_graph_template_instance_add for the same template
    -- must return -1 (cap reached, no voice stealing).
    testCase "writer template auto-spawn succeeds; second instance rejected" $ do
      let writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 0.0)
            pure ()

      tg <- case compileTemplateGraph [("writer", writerGraph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph (totalNodes + 8) 64 $ \rt -> do
        _ <- allocBuffer rt 64
        loadTemplateGraph rt tg

        -- The auto-spawn already occupies slot 0; the live count
        -- for template 0 is therefore 1, matching the cap.
        extra <- c_rt_graph_template_instance_add rt 0
        extra @?= (-1)

  , -- §6.C.5 commit 1: non-writer templates must keep the
    -- default polyphony (8). We don't peek at the cap directly
    -- (no FFI accessor) — instead we verify behavior: spawn
    -- multiple instances and confirm they all succeed.
    testCase "non-writer template keeps default polyphony behavior" $ do
      let readerGraph = runSynth $ do
            s <- sinOsc (Param 440.0) (Param 0.0)
            out 0 s

      tg <- case compileTemplateGraph [("reader", readerGraph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph (totalNodes + 32) 64 $ \rt -> do
        loadTemplateGraph rt tg
        -- Slot 0 is auto-spawned; spawning three more must
        -- succeed under the default cap of 8 (4 live total).
        s1 <- c_rt_graph_template_instance_add rt 0
        s2 <- c_rt_graph_template_instance_add rt 0
        s3 <- c_rt_graph_template_instance_add rt 0
        assertBool
          ("expected three additional non-writer instances; got "
           <> show [s1, s2, s3])
          (all (>= 0) [s1, s2, s3])

  , -- §6.C.5 commit 1: the clamp must apply when the writer
    -- template is registered as a *non-first* template too. The
    -- fused loader path shares the same clamping helper; this
    -- exercises it via a two-template mix.
    testCase "writer clamp survives non-first template position" $ do
      let readerGraph = runSynth $ do
            s <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 0)
            out 0 s
          writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 1.0)
            pure ()

      tg <- case compileTemplateGraph
                   [ ("reader", readerGraph)
                   , ("writer", writerGraph) ] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      -- After §6.C.4 topo-sort the writer must be first in
      -- execution order, so on the C side template_id 0 is the
      -- writer and template_id 1 is the reader.
      let names = map tplName (tgTemplates tg)
      assertEqual "writer must precede reader after topo-sort"
        ["writer", "reader"] names

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph (totalNodes + 16) 64 $ \rt -> do
        _ <- allocBuffer rt 64
        loadTemplateGraph rt tg

        -- Writer is template 0; second spawn must be rejected.
        writerExtra <- c_rt_graph_template_instance_add rt 0
        writerExtra @?= (-1)
        -- Reader is template 1; second spawn must succeed under
        -- the default cap.
        readerExtra <- c_rt_graph_template_instance_add rt 1
        assertBool
          ("reader second-instance spawn must succeed; got "
           <> show readerExtra)
          (readerExtra >= 0)

  , -- §6.C.5 commit 2: two writer nodes against the same buffer
    -- in one SynthGraph must be rejected by validation. The
    -- diagnostic names the offending buffer id so authors can
    -- locate the conflict instead of chasing a downstream
    -- topology error.
    testCase "duplicate same-buffer writers in one graph are rejected" $ do
      let g = runSynth $ do
            _ <- recordBufMono (Buffer 2) (Param 0.25) (Param 0.0)
            _ <- recordBufMono (Buffer 2) (Param 0.75) (Param 0.0)
            pure ()
      case lowerGraph g of
        Right _ -> assertFailure
          "expected duplicate BufWrite on buffer 2 to be rejected"
        Left err ->
          assertBool
            ("diagnostic must mention 'buffer 2'; got: " <> err)
            ("buffer 2" `isInfixOf` err)

  , -- §6.C.5 commit 2: writers targeting *different* buffers
    -- compose freely. The rule is per-buffer, not per-graph.
    testCase "writers to different buffers in one graph are accepted" $ do
      let g = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.25) (Param 0.0)
            _ <- recordBufMono (Buffer 1) (Param 0.75) (Param 0.0)
            pure ()
      case lowerGraph g of
        Right _  -> pure ()
        Left err -> assertFailure $
          "writers to different buffers must lower cleanly; got: "
          <> err

  , -- §6.C.5 commit 2: writer + reader on the same buffer is
    -- the canonical compose case. The E_r edge pins the
    -- writer before the reader; nothing about that pattern is
    -- ambiguous.
    testCase "writer + reader on same buffer in one graph is accepted" $ do
      let g = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 0.0)
            s <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 0)
            out 0 s
      case lowerGraph g of
        Right _  -> pure ()
        Left err -> assertFailure $
          "writer + reader on same buffer must lower cleanly; got: "
          <> err

  , -- §6.C.5 follow-up: loadRuntimeGraph (single-template
    -- loader, used by the legacy ABI and by app/Main.hs's demo
    -- helpers) must clamp writer-template polyphony to 1 the
    -- same way the multi-template loader does. The runtime
    -- backstop in rt_graph.cpp catches direct-C-ABI callers;
    -- this test pins the Haskell loader's declarative clamp.
    testCase "loadRuntimeGraph clamps a writer graph's polyphony" $ do
      let writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 0.0)
            pure ()

      rg <- case lowerGraph writerGraph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rg) + 8) 64 $ \rt -> do
        _ <- allocBuffer rt 64
        loadRuntimeGraph rt rg

        -- Auto-spawn took slot 0; second spawn must hit the cap.
        extra <- c_rt_graph_template_instance_add rt 0
        extra @?= (-1)

  , -- §6.C.5 follow-up: loadRuntimeGraphFused mirrors the
    -- unfused loader. Even though the demo graph here has no
    -- RFused inputs, the loader must still apply the clamp on
    -- the same writer-presence rule.
    testCase "loadRuntimeGraphFused clamps a writer graph's polyphony" $ do
      let writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 0.0)
            pure ()

      rg <- case lowerGraph writerGraph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rg) + 8) 64 $ \rt -> do
        _ <- allocBuffer rt 64
        loadRuntimeGraphFused rt rg

        extra <- c_rt_graph_template_instance_add rt 0
        extra @?= (-1)

  , -- §6.C.5 follow-up: a non-writer graph loaded via
    -- loadRuntimeGraph must keep its default polyphony (8) —
    -- the clamp is gated on the writer-presence check.
    testCase "loadRuntimeGraph leaves non-writer polyphony untouched" $ do
      let readerGraph = runSynth $ do
            s <- sinOsc (Param 440.0) (Param 0.0)
            out 0 s

      rg <- case lowerGraph readerGraph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rg) + 32) 64 $ \rt -> do
        loadRuntimeGraph rt rg
        -- Slot 0 is auto-spawned; spawning three more must
        -- succeed under the default cap of 8.
        s1 <- c_rt_graph_template_instance_add rt 0
        s2 <- c_rt_graph_template_instance_add rt 0
        s3 <- c_rt_graph_template_instance_add rt 0
        assertBool
          ("expected three additional non-writer instances; got "
           <> show [s1, s2, s3])
          (all (>= 0) [s1, s2, s3])
  ]

------------------------------------------------------------
-- §6.D slice 1: KSpectralFreeze surface + C++ skeleton
--
-- Slice-1 tests pin only the Haskell-side shape and the
-- declared latency. No kernel-output assertions yet — the
-- C++ side is a stub that emits silence. Slice 2 adds the
-- real STFT body + pre-roll silence + warmed-up impulse +
-- sine reconstruction; slice 3 adds the freeze gate tests.
--
-- Property tests in 'unitTests' iterate over every
-- 'NodeKind' (kindTag-vs-kind_supported, ugenView arities,
-- portInfo coverage) and therefore extend through
-- 'KSpectralFreeze' automatically — slice 1 inherits that
-- coverage without writing a new test.
------------------------------------------------------------

spectralFreezeSkeletonTests :: TestTree
spectralFreezeSkeletonTests =
  testGroup "Phase 6.D slice 1: SpectralFreeze surface"
  [ testCase "inferEff produces Pure" $ do
      -- §6.D: spectral kinds own their windowing state per
      -- instance, nothing crosses a graph boundary. Pinning
      -- this means a future spectrum-streaming kind that
      -- needs a real Eff axis is forced to introduce it
      -- deliberately rather than fall through the default.
      let g = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
          ir = case lowerGraph g of
                 Right ir' -> ir'
                 Left err  -> error err
          freezeEffs =
            [ eff
            | n   <- giNodes ir
            , eff <- irEffects n
            , irKind n == KSpectralFreeze
            ]
      freezeEffs @?= [Pure]

  , testCase "kindSpec / portInfo / kindLatency agree on shape" $ do
      ksTag          (kindSpec KSpectralFreeze) @?= 22
      ksRate         (kindSpec KSpectralFreeze) @?= SampleRate
      ksAudioArity   (kindSpec KSpectralFreeze) @?= 2
      ksControlArity (kindSpec KSpectralFreeze) @?= 2
      ksLabel        (kindSpec KSpectralFreeze) @?= "spectralFreeze"
      portInfo KSpectralFreeze (PortIndex 0)
        @?= Just (PortInfo PortSampleAccurate "signal_in")
      portInfo KSpectralFreeze (PortIndex 1)
        @?= Just (PortInfo PortSampleAccurate "freeze_flag")
      portInfo KSpectralFreeze (PortIndex 2) @?= Nothing

  , testCase "kindLatency declares N=1024 for KSpectralFreeze" $ do
      kindLatency KSpectralFreeze @?= Just 1024
      -- Everything else must stay Nothing — the accessor is
      -- only meaningful on kinds that introduce inherent
      -- pipeline latency.
      kindLatency KSinOsc         @?= Nothing
      kindLatency KGain           @?= Nothing
      kindLatency KLPF            @?= Nothing
      kindLatency KPlayBufMono    @?= Nothing
      kindLatency KRecordBufMono  @?= Nothing

  , testCase "ugenView arities match kindSpec for SpectralFreeze" $ do
      -- The local check that the global property
      -- 'ugenView arities match kindSpec for every UGen'
      -- already covers — but a focused unit case here makes
      -- intent obvious for reviewers reading slice 1 in
      -- isolation.
      let view = ugenView
            (SpectralFreeze (Param 0.0) (Param 0.0))
      length (uvInputs view)   @?= 2
      length (uvControls view) @?= 2

  , testCase "spectralFreeze graph compiles and renders without crashing" $ do
      -- Stub-era smoke test, retained for the slice-1
      -- invariant: the kind loads, dispatches, and a
      -- process_graph call returns normally. Slice 2 adds
      -- the kernel-correctness assertions below.
      let nframes = 64
          graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)

  -- ----------------------------------------------------------
  -- §6.D slice 2: real STFT pass-through, counters, Barrier
  --
  -- All tests below run with N=1024 / hop=256 — the constants
  -- baked into 'SpectralFreezeState'. If those constants change
  -- the test expectations have to follow.
  -- ----------------------------------------------------------

  , testCase "pre-roll is silent below numerical noise" $ do
      -- Frames 0..N-1 of the output are zero by construction:
      -- no analysis hops have fired yet (the first hop boundary
      -- is at samples_in == N), so the output ring is the
      -- value-initialized zero buffer.
      let nframes = 1024  -- exactly N
          graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
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
          rendered <- peekArray nframes (bp :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
              peak = maximum (map abs rcvs)
          assertBool
            ("pre-roll must be silent (peak < 1e-3); got "
             <> show peak)
            (peak < 1.0e-3)

  , testCase "counter math: analysis and resynthesis tick on every hop in pass-through" $ do
      -- Render exactly 4N frames. After 4*1024 samples_in
      -- counter, the analysis condition (samples_in % hop == 0
      -- AND samples_in >= N) fires at samples_in =
      -- N, N+hop, N+2*hop, ..., 4N. That gives floor((4N - N)
      -- / hop) + 1 = floor(3*1024 / 256) + 1 = 13 hops. Both
      -- counters tick once per hop in pass-through.
      let n       = 1024 :: Int
          hop     = 256  :: Int
          totalF  = 4 * n
          nframes = totalF
          graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        analysis  <- c_rt_graph_test_spectral_analysis_count    rt
        resynth   <- c_rt_graph_test_spectral_resynthesis_count rt
        let expected = fromIntegral
              ((totalF - n) `div` hop + 1) :: CLLong
        analysis @?= expected
        resynth  @?= expected

  , testCase "warmed-up impulse emerges N samples after injection" $ do
      -- Feed 2N silent frames, then an impulse at frame 2N,
      -- through spectralFreeze in pass-through mode. The
      -- impulse must emerge ~N samples after injection — at
      -- the response peak — proving the declared kindLatency
      -- of 1024. Frame-0 injection is *not* used: with causal
      -- startup the first analysis window's edge is at frame
      -- 0 where the Hann weight is zero and no overlapping
      -- pre-roll contributes, so an impulse there would be
      -- attenuated by alignment rather than latency
      -- (§2.3 of the 6.D design note).
      --
      -- Drive the input from playBufMono reading a 4N-frame
      -- buffer with a single non-zero sample at frame 2N. The
      -- buffer is the only way the DSL can express a
      -- one-shot time-positioned signal without adding new
      -- generators.
      let n        = 1024 :: Int
          totalF   = 4 * n
          impulseF = 2 * n         -- inject at frame 2N
          nframes  = totalF
          graph = runSynth $ do
            sig    <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 0)
            frozen <- spectralFreeze sig (Param 0.0)
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        buf <- allocBuffer rt totalF
        bufferId buf @?= 0
        -- Build the impulse: silence everywhere, 1.0 at
        -- frame 2N.
        let impulseFrames =
              [ if i == impulseF then 1.0 else 0.0
              | i <- [0 .. totalF - 1]
              ]
        loadBuffer rt buf impulseFrames
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        allocaBytes (nframes * 4) $ \bp -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bp)
          rendered <- peekArray nframes (bp :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
              -- Locate the global peak position in the
              -- output. With N-sample steady-state latency,
              -- the impulse's energy is spread by Hann
              -- windowing but peaks ~N samples after
              -- injection.
              indexed = zip [0 :: Int ..] (map abs rcvs)
              (peakIdx, peakAmp) =
                foldr (\p@(_, a) q@(_, b) -> if a > b then p else q)
                      (0, 0) indexed
              expectedPeak = impulseF + n
              tolerance    = 16 :: Int  -- a single hop
          assertBool
            ("output must have non-trivial energy; peak amp = "
             <> show peakAmp)
            (peakAmp > 1.0e-3)
          assertBool
            ("impulse peak must land near frame " <> show expectedPeak
             <> " (= injection " <> show impulseF
             <> " + latency " <> show n <> "); observed peak at frame "
             <> show peakIdx)
            (abs (peakIdx - expectedPeak) <= tolerance)

  , testCase "pass-through reconstructs a 440 Hz sine in steady state" $ do
      -- Render 4N frames of a 440 Hz sine, skip the first 2N
      -- (pre-roll + warmup), and assert the steady-state peak
      -- amplitude is within 5% of 1.0. WOLA normalization
      -- targets unity gain; the 5% tolerance covers the
      -- Hann-window contribution sum that doesn't quite
      -- reach exact COLA at hop = N/4 (the analytic value
      -- for the chosen overlap is ~1.5 / 1.5 = 1.0, and
      -- numerical rounding in the FFT roundtrip plus the
      -- N-truncated window cosine series adds <1% in
      -- practice).
      let n       = 1024 :: Int
          totalF  = 4 * n
          nframes = totalF
          graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
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
          rendered <- peekArray nframes (bp :: PtrCFloat)
          let rcvs       = map (\(CFloat x) -> x) rendered
              steady     = drop (2 * n) rcvs
              steadyPeak = maximum (map abs steady)
          assertBool
            ("steady-state pass-through must reach unity (±5%); "
             <> "peak = " <> show steadyPeak)
            (steadyPeak > 0.95 && steadyPeak < 1.05)

  , testCase "spectral region is a scheduler Barrier" $ do
      -- regionHasSpectral makes any region containing a
      -- KSpectralFreeze node a Barrier. The spectral kernel
      -- never runs in a FreeSegment.
      let graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
      rg <- case lowerGraph graph >>= compileRuntimeGraph of
              Right r  -> pure r
              Left err -> assertFailure err >> error "unreachable"
      let segments = segmentByBarrier rg
          regionHasFreezeKind r =
            any (\nodeIx -> case [ rnKind n
                                 | n <- rgNodes rg
                                 , rnIndex n == nodeIx ] of
                              [KSpectralFreeze] -> True
                              _                 -> False)
                (rrNodes r)
          freezeInBarrier = any
            (\seg -> case seg of
                Barrier r     -> regionHasFreezeKind r
                FreeSegment _ -> False)
            segments
          freezeInFree = any
            (\seg -> case seg of
                FreeSegment rs -> any regionHasFreezeKind rs
                Barrier _      -> False)
            segments
      assertBool
        ("spectral region must appear in a Barrier; segments = "
         <> show (length segments))
        freezeInBarrier
      assertBool
        "spectral region must never appear inside a FreeSegment"
        (not freezeInFree)

  -- ----------------------------------------------------------
  -- §6.D slice 3: freeze gate
  --
  -- Slice 3 wires the freeze_flag input into the kernel. At
  -- each hop boundary the kernel hop-latches the flag and
  -- selects between pass-through (analyze + persist + IFFT)
  -- and freeze (skip analysis, reconstruct from stored
  -- Hermitian half + IFFT). The two counters diverge in
  -- freeze mode (analysis stops; resynthesis continues).
  -- ----------------------------------------------------------

  , testCase "freeze halts analysis but continues resynthesis" $ do
      -- Render 8N frames with freeze_flag stuck at 1 from
      -- the start (Param 1.0). The first hop fires at
      -- samples_in = N; since freeze_valid is false (no
      -- analysis ever ran), the kernel emits silence
      -- through IFFT. analysis_count stays at 0; the
      -- resynthesis counter ticks once per hop.
      let n       = 1024 :: Int
          hop     = 256  :: Int
          totalF  = 8 * n
          nframes = totalF
          graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 1.0)  -- freeze=on from start
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        analysis <- c_rt_graph_test_spectral_analysis_count    rt
        resynth  <- c_rt_graph_test_spectral_resynthesis_count rt
        let expectedResynth = fromIntegral
              ((totalF - n) `div` hop + 1) :: CLLong
        analysis @?= 0
        resynth  @?= expectedResynth

  , testCase "freeze mode sustains the frozen content after the input goes silent" $ do
      -- The strict freeze-sustain test: input must genuinely
      -- go silent during the freeze window so the test
      -- proves the *frozen spectrum* keeps producing output
      -- (not just that the analysis kept running but the
      -- counter happens to not advance).
      --
      -- Drive signal_in from playBufMono on a precomputed
      -- buffer: frames1 of 440 Hz sine, then frames2 of
      -- zeros. Block 1 (frames1 long) runs in pass-through,
      -- analyzing the sine and persisting the spectrum.
      -- Then we set freeze_default = 1.0 live; block 2
      -- (frames2 long) reads zeros from the buffer's tail —
      -- so signal_in is honestly silent — and the only way
      -- the output stays non-trivial is if the kernel keeps
      -- emitting the frozen spectrum.
      let n        = 1024 :: Int
          frames1  = 4 * n
          frames2  = 2 * n
          totalF   = frames1 + frames2
          -- Sample rate is wired into the C++ side (48000);
          -- the exact phase doesn't matter for this test as
          -- long as the buffer carries a real 440 Hz tone
          -- through frames 0..frames1-1.
          sr       = 48000 :: Double
          freq     = 440   :: Double
          sineSamples =
            [ realToFrac
                (sin (2 * pi * freq * fromIntegral i / sr))
              :: Float
            | i <- [0 .. frames1 - 1]
            ]
          silenceTail = replicate frames2 (0.0 :: Float)
          bufContents = sineSamples ++ silenceTail
          graph = runSynth $ do
            -- One-shot playback: rate=1.0, start_frame=0,
            -- loop=0. After the buffer is exhausted (which
            -- it is partway through block 2) playBufMono
            -- emits zeros — also genuinely silent.
            src <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 0)
            -- Wire freeze_in to a constant; flip the live
            -- control between blocks.
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph (totalNodes + 8) (max frames1 frames2) $ \rt -> do
        buf <- allocBuffer rt totalF
        bufferId buf @?= 0
        loadBuffer rt buf bufContents
        loadTemplateGraph rt tg

        -- Block 1: pass-through. The kernel sees the sine,
        -- records spectra at each hop.
        c_rt_graph_process rt (fromIntegral frames1)
        analysis1 <- c_rt_graph_test_spectral_analysis_count rt
        assertBool
          ("block 1 must record some analyses; got "
           <> show analysis1)
          (analysis1 > 0)

        -- Flip freeze on. spectralFreeze is the second node
        -- in the topo order (playBufMono = 0, spectralFreeze
        -- = 1, out = 2); controls[1] is the freeze_default
        -- that the kernel falls back on when freeze_in is
        -- empty (Param 0.0 means no wired RFrom source).
        c_rt_graph_instance_set_control rt 0 1 1 1.0

        -- Block 2: input is now silent (buffer exhausted +
        -- buffer tail is zeros, both render to 0.0 on
        -- signal_in). The frozen spectrum is the only thing
        -- left contributing to the output.
        c_rt_graph_process rt (fromIntegral frames2)
        analysis2 <- c_rt_graph_test_spectral_analysis_count rt
        -- Analysis_count must not advance during freeze.
        analysis2 @?= analysis1

        allocaBytes (frames2 * 4) $ \bp -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral frames2) (castPtr bp)
          rendered <- peekArray frames2 (bp :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
              peak = maximum (map abs rcvs)
          assertBool
            ("frozen output must keep producing the recorded "
             <> "sine after signal_in goes silent; peak = "
             <> show peak)
            (peak > 0.1)

  , testCase "hop-boundary latch: freeze_flag read happens at the hop's fi" $ do
      -- §6.D hardening: prove the kernel hop-latches the
      -- freeze_flag at exactly fi = hop boundary, not at
      -- block-start, block-end, or a sample-rounded
      -- approximation. The kernel reads
      -- @freeze_in[fi]@ where @fi@ is the loop index at the
      -- moment a hop fires. With N=1024 / hop=256 the first
      -- three hops fire at fi=1023, 1279, 1535 (samples_in
      -- crosses 1024 / 1280 / 1536). If we vary the freeze
      -- transition by a single frame around fi=1279, the
      -- expected analysis_count flips because the hop-1
      -- decision flips.
      --
      -- Two sub-scenarios, each in its own RT graph:
      --
      --   transition = 1279 → freeze_in[1279] = 1 → hop 1
      --     freezes → analysis_count = 1 (only hop 0).
      --
      --   transition = 1280 → freeze_in[1279] = 0 → hop 1
      --     analyzes; hop 2 (fi=1535) reads
      --     freeze_in[1535] = 1 → freezes →
      --     analysis_count = 2.
      --
      -- The 1-frame difference between the two scenarios is
      -- the proof: the latch lands at exactly the hop's fi,
      -- not anywhere else.
      let n         = 1024 :: Int
          hop       = 256  :: Int
          nframes   = n + 2 * hop          -- 1536: covers hops at fi=1023, 1279, 1535
          freezeBuf transitionF =
            [ if i >= transitionF then 1.0 else 0.0 :: Float
            | i <- [0 .. nframes - 1]
            ]
          -- Two separate audio buffers: buffer 0 is the
          -- signal_in source (silent sine — content doesn't
          -- matter, only the freeze_flag does), buffer 1 is
          -- the freeze_flag transition.
          graph = runSynth $ do
            -- A signal source for spectralFreeze. The
            -- content doesn't change the analysis_count
            -- assertion — we're testing the freeze gate
            -- only. Use a sinOsc so the kernel has real
            -- audio to analyze on pass-through hops.
            sig <- sinOsc 440.0 0.0
            -- The freeze_flag, driven from playBufMono on a
            -- buffer whose values transition mid-render.
            fl  <- playBufMono (Buffer 1) (Param 1.0) (Param 0) (Param 0)
            frozen <- spectralFreeze sig fl
            out 0 frozen

          runWithTransition transitionF expectedAnalysis = do
            tg <- case compileTemplateGraph
                         [("freeze", graph)] of
              Right t  -> pure t
              Left err -> assertFailure err >> error "unreachable"
            let totalNodes =
                  sum (map (length . rgNodes . tplGraph)
                           (tgTemplates tg))
            withRTGraph (totalNodes + 8) nframes $ \rt -> do
              -- Buffer 0 reserved for the signal — left
              -- unallocated since signal_in is wired from
              -- sinOsc, not a buffer. Buffer 1 holds the
              -- freeze transition pattern.
              _    <- allocBuffer rt 4  -- placeholder so buf 1 lands as id 1
              fbuf <- allocBuffer rt nframes
              bufferId fbuf @?= 1
              loadBuffer rt fbuf (freezeBuf transitionF)
              loadTemplateGraph rt tg
              c_rt_graph_process rt (fromIntegral nframes)
              analysis <- c_rt_graph_test_spectral_analysis_count rt
              assertEqual
                ("transition at fi=" <> show transitionF
                 <> " must produce analysis_count = "
                 <> show expectedAnalysis)
                expectedAnalysis analysis

      runWithTransition 1279 1
      runWithTransition 1280 2

  , testCase "unfreeze recovery: analysis resumes after the flag drops" $ do
      -- Three blocks: pass-through, freeze, then unfreeze.
      -- Each phase verifies its own counter contract:
      -- block 1 advances analysis, block 2 freezes it,
      -- block 3 advances analysis again.
      let n       = 1024 :: Int
          phase   = 4 * n
          nframes = phase
          graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph (totalNodes + 8) nframes $ \rt -> do
        loadTemplateGraph rt tg

        c_rt_graph_process rt (fromIntegral phase)
        a1 <- c_rt_graph_test_spectral_analysis_count rt

        c_rt_graph_instance_set_control rt 0 1 1 1.0   -- freeze on
        c_rt_graph_process rt (fromIntegral phase)
        a2 <- c_rt_graph_test_spectral_analysis_count rt
        a2 @?= a1                                       -- analysis paused

        c_rt_graph_instance_set_control rt 0 1 1 0.0   -- freeze off
        c_rt_graph_process rt (fromIntegral phase)
        a3 <- c_rt_graph_test_spectral_analysis_count rt
        assertBool
          ("analysis must resume after unfreeze; "
           <> "a1=" <> show a1 <> " a2=" <> show a2
           <> " a3=" <> show a3)
          (a3 > a2)
  ]
