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
import           Data.List                 (isInfixOf, isPrefixOf, nub, sort,
                                            sortBy)
import           Control.Exception         (try)
import           Data.Maybe                (mapMaybe)
import           Data.Ord                  (comparing)
import           Data.Word                 (Word8)
import           Foreign.C.Types           (CDouble (..), CFloat (..))
import           Foreign.Marshal.Alloc     (allocaBytes)
import           Foreign.Marshal.Array     (peekArray)
import           Foreign.Ptr               (Ptr, castPtr)

import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck     as QC

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI      (c_rt_graph_instance_alive,
                                            c_rt_graph_instance_count,
                                            c_rt_graph_instance_release,
                                            c_rt_graph_instance_set_control,
                                            c_rt_graph_instance_status,
                                            c_rt_graph_kind_supported,
                                            c_rt_graph_process,
                                            c_rt_graph_read_bus,
                                            c_rt_graph_template_count,
                                            c_rt_graph_template_instance_add,
                                            instanceStatusLive,
                                            instanceStatusReleasing,
                                            loadRuntimeGraph,
                                            loadRuntimeGraphFused,
                                            loadTemplateGraph,
                                            loadTemplateGraphFused,
                                            withRTGraph)
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Bridge.Validate
import           MetaSonic.Types

main :: IO ()
main = defaultMain $ testGroup "MetaSonic"
  [ unitTests
  , properties
  , crossCuttingTests
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
    -- summarises a single template's bus surface; compileTemplateGraph
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
              bfDelayedReads (tplFootprint readerTpl)
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
                  )
                ]
          case compileTemplateGraph [("naughty", badGraph)] of
            Right _  -> assertFailure
              "expected per-template compile error to surface"
            Left err ->
              assertBool ("expected template name in error, got: " <> err)
                         ("naughty" `isInfixOf` err)
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
        -- compile path is unchanged in observable behaviour by
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
          let g = runSynth $ do
                o <- sinOsc 440.0 0.0
                a <- gain o (Param 0.5)
                out 0 a
          case lowerGraph g >>= compileRuntimeGraphFused of
            Left err -> assertFailure $ "compile failed: " <> err
            Right rg -> do
              length (rgNodes rg) @?= 3
              let gainNode = head [n | n <- rgNodes rg, rnKind n == KGain]
                  sinNode  = head [n | n <- rgNodes rg, rnKind n == KSinOsc]
                  outNode  = head [n | n <- rgNodes rg, rnKind n == KOut]
              rnElided gainNode @?= True
              rnElided sinNode  @?= False
              rnElided outNode  @?= False
              rnInputs outNode @?=
                [ RFused (FScaleFrom (rnIndex sinNode) (PortIndex 0)
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
  }

-- A hand-built graph with a 0 -> 1 -> 0 cycle.
cycleGraph :: SynthGraph
cycleGraph = SynthGraph $ M.fromList
  [ ( NodeID 0
    , NodeSpec (NodeID 0) "gain-a"
        (Gain (Audio (NodeID 1) (PortIndex 0)) (Param 0.5)) )
  , ( NodeID 1
    , NodeSpec (NodeID 1) "gain-b"
        (Gain (Audio (NodeID 0) (PortIndex 0)) (Param 0.5)) )
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

  , -- Step C (c) guard: feeding a fused graph through the unfused
    -- 'loadRuntimeGraph' must fail fast with the documented error,
    -- not miswire silently. This pins the contract until Step C (e)
    -- adds a fused-aware loader.
    testCase "loadRuntimeGraph rejects RFused inputs with the documented error" $ do
      let graph = runSynth $ do
            o <- sinOsc 440.0 0.0
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
      let nframes = 256
          graph = runSynth $ do
            o <- sinOsc 440.0 0.0
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
      -- 440 Hz at 0.5 gain ⇒ peak ≈ 0.5. Non-silent confirms the
      -- fused-input scratch materialisation reached the consumer
      -- and the elided Gain didn't break dispatch.
      assertBool ("expected non-silent fused render, peak = " <> show peak)
                 (peak > 0.4 && peak < 0.55)

  , -- Step C (f): bit-equivalence battery. For every graph in
    -- 'fusedEquivalenceCases' the unfused render (loadRuntimeGraph
    -- + compileRuntimeGraph) must equal the fused render
    -- (loadRuntimeGraphFused + compileRuntimeGraphFused) sample-
    -- for-sample. The fused path takes a different runtime route
    -- — elided dispatch + fused-scale resolver — but the
    -- materialisation discipline (cast double→float, multiply) is
    -- chosen to mirror process_gain's scalar branch exactly, so
    -- equivalence is bit-strict, not approx.
    --
    -- Each case must actually exercise fusion: the assertion
    -- includes a sanity check that the fused graph produced at
    -- least one RFused input and at least one elided node.
    testGroup "Step C (f): fused render equals unfused render"
      [ testCase name $ assertFusedEquivalent name graph
      | (name, graph) <- fusedEquivalenceCases
      ]

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
            -- resolve_input reads controls[0] when materialising
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
      let nframes = 256
          fusedChain = runSynth $ do
            o <- sinOsc 440.0 0.0
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
  ]

-- | Render @graph@ through the unfused and fused loaders and assert
-- their outputs are bit-identical on every bus the graph writes
-- (not only bus 0). Comparing every output bus catches the case
-- where a fanout's second fused branch is miswired but its sibling
-- on bus 0 happens to match. Also verifies that the fused compile
-- actually triggered fusion (≥1 RFused input + ≥1 elided node) so
-- the test isn't degenerate.
assertFusedEquivalent :: String -> SynthGraph -> Assertion
assertFusedEquivalent name graph = do
  let nframes = 256
  rtUn <- case lowerGraph graph >>= compileRuntimeGraph of
    Right r  -> pure r
    Left err -> assertFailure (name <> ": compile (unfused) failed: " <> err)
                  >> error "unreachable"
  rtF  <- case lowerGraph graph >>= compileRuntimeGraphFused of
    Right r  -> pure r
    Left err -> assertFailure (name <> ": compile (fused) failed: " <> err)
                  >> error "unreachable"

  assertBool (name <> ": fused compile produced no RFused inputs")
    (not (null [() | n <- rgNodes rtF, RFused _ <- rnInputs n]))
  assertBool (name <> ": fused compile elided no nodes")
    (any rnElided (rgNodes rtF))

  -- Walk the (unfused) graph to collect every bus index that an Out
  -- or BusOut node writes to. rnControls[0] holds the bus id by
  -- convention (see kindSpec for KOut / KBusOut). Bus indices that
  -- both graphs write to are compared sample-for-sample; if either
  -- side renders silence on a bus the other one drives, the test
  -- fails.
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

  unfused <- render loadRuntimeGraph      rtUn
  fused   <- render loadRuntimeGraphFused rtF
  assertBool
    (name <> ": fused render must match unfused render on every bus "
       <> show buses)
    (unfused == fused)
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
  | OBPF       Int Double Double -- source-index, centre, q
  | ONotch     Int Double Double -- source-index, centre, q
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
interpret = go [] S.empty
  where
    go :: [Connection] -> S.Set Int -> [Op] -> SynthM ()
    go _ _ [] = pure ()

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
