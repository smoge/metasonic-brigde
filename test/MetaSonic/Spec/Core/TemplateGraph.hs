-- | Tests for the @TemplateGraph@ (inter-template ordering) layer:
-- per-template @busFootprint@ extraction, @compileTemplateGraph@'s
-- topological sort over the bus/buffer precedence DAG, and the
-- helper predicates @templatePrecedes@, @computePrecedence@, and
-- @checkNoSharedBufferWriters@ that the compiler builds on. Includes
-- one extractor pin for @playBufMono@ so the post-IR
-- @runtimeNodeResourceFootprint@ stays in sync with the pre-IR
-- @resourceFootprint@.
--
-- Mirrors the intra-graph E_r machinery one tier up; see
-- @Note [Template-level precedence from bus dataflow]@ in
-- "MetaSonic.Bridge.Templates".
module MetaSonic.Spec.Core.TemplateGraph
  ( templateGraphTests
  ) where

import qualified Data.Map.Strict           as M
import qualified Data.Set                  as S
import           Data.List                 (isInfixOf)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Types

templateGraphTests :: TestTree
templateGraphTests =
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
        let dummyRG = RuntimeGraph [] [] []
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
        let dummyRG = RuntimeGraph [] [] []
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
        let dummyRG = RuntimeGraph [] [] []
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
        let dummyRG = RuntimeGraph [] [] []
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
        let dummyRG = RuntimeGraph [] [] []
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
