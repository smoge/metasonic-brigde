-- | Tests for the 'cc' builder: it auto-inserts a 'KSmooth' node,
-- records a 'CCSpec' binding (number, NodeID, control index, range),
-- and the resulting Connection resolves to a dense 'NodeIndex'
-- post-compile. Declaration order is preserved, multi-target
-- bindings on the same CC number are allowed, and legacy
-- 'runSynth' / 'runSynthWith' still work when 'cc' is used.
module MetaSonic.Spec.Core.CCBuilder
  ( ccBuilderTests
  ) where

import           Data.Word               (Word8)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Types

ccBuilderTests :: TestTree
ccBuilderTests =
  testGroup "cc builder: auto-records CCSpec + auto-inserts Smooth"
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
