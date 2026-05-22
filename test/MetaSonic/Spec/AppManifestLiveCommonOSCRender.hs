{-# LANGUAGE LambdaCase #-}

-- | Deterministic coverage for the operator-string contract the
-- live OSC listener hooks will eventually drive against:
-- 'renderOSCAcceptLine' and 'renderOSCIssueLine' in
-- "MetaSonic.App.ManifestLiveCommon".
--
-- These two helpers are the canonical rendering surface introduced
-- by @notes/2026-05-20-d-stale-command-rejection-rendering.md@. The
-- 'Maybe' return on 'renderOSCAcceptLine' encodes the dedup policy
-- structurally: a packet whose enqueue was rejected at the
-- fan-in-host layer renders 'Nothing' on the accept side because
-- 'MoliEnqueueRejected' through 'renderOSCIssueLine' is the single
-- source of the operator-facing line for it.
--
-- The hook wiring that actually consumes these helpers is a
-- follow-up commit; the legacy 'renderOSCAccept' \/ 'renderOSCIssue'
-- pair is still in place and still double-prints. The tests here
-- pin the new contract so the wiring commit only has to assert
-- that the helpers compose correctly with the listener fan-out.
module MetaSonic.Spec.AppManifestLiveCommonOSCRender
  ( appManifestLiveCommonOSCRenderTests
  ) where

import           Data.ByteString.Char8                  (pack)
import           Data.Maybe                             (maybeToList)
import qualified Data.Text                              as T
import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestLiveCommon       (renderOSCAcceptLine,
                                                         renderOSCAcceptLineWithControls,
                                                         renderOSCIssueLine)
import           MetaSonic.App.ManifestOSCListener      (ManifestOSCListenerIssue (..))
import           MetaSonic.App.ManifestReloadOSCBinding (ManifestOSCControlBinding (..))
import           MetaSonic.App.ManifestReloadOSCIngress (ManifestOSCIngressIssue (..))
import           MetaSonic.Bridge.Source                (MigrationKey (..))
import           MetaSonic.OSC.Dispatch                 (DispatchIssue (..))
import           MetaSonic.Pattern                      (ControlTag (..),
                                                         VoiceKey (..))
import           MetaSonic.Session.Command              (SessionCommand (..))
import           MetaSonic.Session.FanIn                (SessionFanInEnqueueResult (..))
import           MetaSonic.Session.OSCProducer          (OSCProducerEnqueueResult (..))
import           MetaSonic.Session.Queue                (CommandSequence (..),
                                                         ProducerId (..),
                                                         ProducerKind (..),
                                                         QueuedSessionCommand (..),
                                                         SessionEnqueueIssue (..),
                                                         SessionEnqueueResult (..))


appManifestLiveCommonOSCRenderTests :: TestTree
appManifestLiveCommonOSCRenderTests =
  testGroup "App manifest live common: OSC listener-event line renderers"
  [ testGroup "renderOSCIssueLine"   renderOSCIssueLineTests
  , testGroup "renderOSCAcceptLine"  renderOSCAcceptLineTests
  , testGroup "synthetic listener fan-out composition"
              syntheticFanOutTests
  ]


-- ---------------------------------------------------------------------------
-- renderOSCIssueLine: the issue-side renderer
-- ---------------------------------------------------------------------------

renderOSCIssueLineTests :: [TestTree]
renderOSCIssueLineTests =
  [ testCase "MoliParseFailure renders as 'osc reject (parse): ...'" $
      renderOSCIssueLine (MoliParseFailure "malformed address bytes")
        @?= "osc reject (parse): malformed address bytes"

  , testCase "MoliManifestIssue renders as 'osc reject (manifest): ...'" $
      renderOSCIssueLine
        (MoliManifestIssue
          (MoiiDecodeFailed (DiInvalidAddressFormat (pack "/bad"))))
        @?= "osc reject (manifest): "
            <> show
                 (MoiiDecodeFailed
                   (DiInvalidAddressFormat (pack "/bad")))

  , testCase "SeiReloadInProgress renders the dedicated reload-window line" $
      renderOSCIssueLine
        (MoliEnqueueRejected sampleControlWrite SeiReloadInProgress)
        @?= "osc reject (reload-window): "
            <> "CmdControlWrite voice=v0 tag="
            <> show sampleControlTag
            <> " value=0.75"

  , testCase "SeiReloadInProgress label has no 'issue=' suffix (the label is the cause)" $
      assertBool
        "reload-window line should not carry the redundant issue= suffix"
        (not ("issue=" `isSubstring`
              renderOSCIssueLine
                (MoliEnqueueRejected sampleControlWrite SeiReloadInProgress)))

  , testCase "SeiQueueFull keeps the generic 'osc enqueue-reject: ... issue=...' shape" $
      renderOSCIssueLine
        (MoliEnqueueRejected sampleControlWrite (SeiQueueFull 64))
        @?= "osc enqueue-reject: "
            <> "CmdControlWrite voice=v0 tag="
            <> show sampleControlTag
            <> " value=0.75"
            <> " issue=SeiQueueFull 64"

  , testCase "SeiSessionUnavailable keeps the generic 'osc enqueue-reject: ...' shape" $
      -- See the design note's Contract section: SessionFanInReloadFailed
      -- (or no-owner) packets render generically; only SeiReloadInProgress
      -- gets the (reload-window) label.
      renderOSCIssueLine
        (MoliEnqueueRejected sampleControlWrite SeiSessionUnavailable)
        @?= "osc enqueue-reject: "
            <> "CmdControlWrite voice=v0 tag="
            <> show sampleControlTag
            <> " value=0.75"
            <> " issue=SeiSessionUnavailable"

  , testCase "MoiiValueOutOfRange renders the dedicated out-of-range line" $
      -- See notes/2026-05-21-d-manifest-osc-range-rejection.md: tag
      -- renders through renderManifestOSCAddressTail (e.g. 'lpf/0'),
      -- value and bounds render through 'show :: Double -> String'
      -- (e.g. '0.75', '200.0', '6000.0').
      renderOSCIssueLine
        (MoliManifestIssue (MoiiValueOutOfRange sampleControlTag 0.75 200.0 6000.0))
        @?= "osc reject (out-of-range): tag=lpf/0 value=0.75 range=[200.0, 6000.0]"

  , testCase "MoiiValueOutOfRange renders NaN through the same line shape" $
      -- The accept predicate explicitly rejects NaN (all NaN
      -- comparisons evaluate False, so 'value < lo || value > hi'
      -- alone would accept it). The rendered string pins how 'show
      -- (0/0 :: Double)' surfaces in the line — 'NaN' on GHC today.
      renderOSCIssueLine
        (MoliManifestIssue
          (MoiiValueOutOfRange sampleControlTag (0/0) 200.0 6000.0))
        @?= "osc reject (out-of-range): tag=lpf/0 value=NaN range=[200.0, 6000.0]"

  , testCase "MoiiValueOutOfRange renders a zero-width range without special-casing" $
      -- Degenerate-but-legal: a manifest may declare rangeMin == rangeMax
      -- (single-valued control). The renderer treats it like any other
      -- range; the accept-predicate side (commit 2) rejects every value
      -- but the exact min, which lands here for everything else.
      renderOSCIssueLine
        (MoliManifestIssue (MoiiValueOutOfRange sampleControlTag 0.1 0.0 0.0))
        @?= "osc reject (out-of-range): tag=lpf/0 value=0.1 range=[0.0, 0.0]"
  ]


-- ---------------------------------------------------------------------------
-- renderOSCAcceptLine: the accept-side renderer (Maybe encodes dedup)
-- ---------------------------------------------------------------------------

renderOSCAcceptLineTests :: [TestTree]
renderOSCAcceptLineTests =
  [ testCase "SessionEnqueued renders 'Just \"osc accept: ...\"'" $
      renderOSCAcceptLine
        (OSCProducerEnqueueAttempted
          sampleControlWrite
          (SessionFanInEnqueueResult
            { sfierResult     = SessionEnqueued sampleQueued
            , sfierQueueDepth = 1
            }))
        @?= Just "osc accept: /v0/lpf/0 value=0.75"

  , testCase "SessionEnqueued uses manifest binding display name when available" $
      renderOSCAcceptLineWithControls
        [sampleControlBinding]
        (OSCProducerEnqueueAttempted
          sampleControlWrite
          (SessionFanInEnqueueResult
            { sfierResult     = SessionEnqueued sampleQueued
            , sfierQueueDepth = 1
            }))
        @?= Just "osc accept: /v0/lpf/0 name=\"cutoff\" value=0.75"

  , testCase "SessionEnqueued rounds common float representation noise" $
      renderOSCAcceptLineWithControls
        [sampleControlBinding]
        (OSCProducerEnqueueAttempted
          (CmdControlWrite sampleVoiceKey sampleControlTag 0.18000000715255737)
          (SessionFanInEnqueueResult
            { sfierResult     = SessionEnqueued sampleQueued
            , sfierQueueDepth = 1
            }))
        @?= Just "osc accept: /v0/lpf/0 name=\"cutoff\" value=0.18"

  , testCase "SessionEnqueueRejected SeiReloadInProgress returns Nothing (dedup)" $
      -- The dedup policy: rejected packets are reported through the
      -- issue side. renderOSCAcceptLine returns Nothing so the listener
      -- hook does not double-print.
      renderOSCAcceptLine
        (OSCProducerEnqueueAttempted
          sampleControlWrite
          (SessionFanInEnqueueResult
            { sfierResult     =
                SessionEnqueueRejected
                  sampleProducerId
                  sampleControlWrite
                  SeiReloadInProgress
            , sfierQueueDepth = 0
            }))
        @?= Nothing

  , testCase "SessionEnqueueRejected SeiQueueFull also returns Nothing (dedup applies to every rejection)" $
      renderOSCAcceptLine
        (OSCProducerEnqueueAttempted
          sampleControlWrite
          (SessionFanInEnqueueResult
            { sfierResult     =
                SessionEnqueueRejected
                  sampleProducerId
                  sampleControlWrite
                  (SeiQueueFull 64)
            , sfierQueueDepth = 64
            }))
        @?= Nothing

  , testCase "OSCProducerDecodeRejected renders defensively (path unreachable in manifest listener today)" $
      -- Defensive: the manifest listener's normal flow pre-decodes
      -- before calling the producer, so this arm is currently
      -- unreachable. The renderer covers it anyway so a future
      -- reorganization of the call chain does not silently drop
      -- packets.
      renderOSCAcceptLine
        (OSCProducerDecodeRejected
          (DiInvalidAddressFormat (pack "/bad")))
        @?= Just ("osc reject (decode): "
                  <> show (DiInvalidAddressFormat (pack "/bad")))
  ]


-- ---------------------------------------------------------------------------
-- Synthetic fan-out composition
-- ---------------------------------------------------------------------------

-- | Model how 'processManifestOSCPacket' currently fans out one
-- accepted packet's outcome through both hooks: 'molhOnAccepted' fires
-- with the 'OSCProducerEnqueueResult', then 'molhOnIssue' fires with
-- 'MoliEnqueueRejected' for the same packet if the enqueue was
-- rejected. The expected composed operator output is the
-- concatenation of:
--
--   * 'renderOSCAcceptLine' of the producer result (Just-rendered);
--   * 'renderOSCIssueLine' of any 'MoliEnqueueRejected' the listener
--     would synthesize from that same producer result.
--
-- This mirrors 'reportProducerEnqueue's behavior in the listener
-- without staging the real listener loop. Tests assert that the
-- composed list has exactly one line and matches the expected
-- contract per packet.
composeListenerOutput
  :: OSCProducerEnqueueResult -> [String]
composeListenerOutput result =
  maybeToList (renderOSCAcceptLine result)
    <> map renderOSCIssueLine (enqueueIssueFromResult result)
  where
    enqueueIssueFromResult :: OSCProducerEnqueueResult -> [ManifestOSCListenerIssue]
    enqueueIssueFromResult = \case
      OSCProducerDecodeRejected _ ->
        []  -- decode failures are reported through molhOnIssue
            -- elsewhere (the manifest listener calls
            -- molhOnIssue (MoliManifestIssue ...) on
            -- MoiiDecodeFailed), not through reportProducerEnqueue.
      OSCProducerEnqueueAttempted cmd enqueue ->
        case sfierResult enqueue of
          SessionEnqueued _ ->
            []
          SessionEnqueueRejected _ _ queueIssue ->
            [MoliEnqueueRejected cmd queueIssue]


syntheticFanOutTests :: [TestTree]
syntheticFanOutTests =
  [ testCase "accepted enqueue → exactly one 'osc accept: ...' line" $ do
      let lines_ = composeListenerOutput
            (OSCProducerEnqueueAttempted
              sampleControlWrite
              (SessionFanInEnqueueResult
                { sfierResult     = SessionEnqueued sampleQueued
                , sfierQueueDepth = 1
                }))
      length lines_ @?= 1
      head lines_ @?= "osc accept: /v0/lpf/0 value=0.75"

  , testCase "reload-window rejection → exactly one 'osc reject (reload-window): ...' line (no double-print)" $ do
      -- This is the load-bearing assertion: today the legacy
      -- renderOSCAccept / renderOSCIssue pair prints this line twice;
      -- the new helpers compose into exactly one line.
      let lines_ = composeListenerOutput
            (OSCProducerEnqueueAttempted
              sampleControlWrite
              (SessionFanInEnqueueResult
                { sfierResult     =
                    SessionEnqueueRejected
                      sampleProducerId
                      sampleControlWrite
                      SeiReloadInProgress
                , sfierQueueDepth = 0
                }))
      length lines_ @?= 1
      head lines_ @?= "osc reject (reload-window): "
                       <> "CmdControlWrite voice=v0 tag="
                       <> show sampleControlTag
                       <> " value=0.75"

  , testCase "non-reload enqueue rejection → exactly one generic 'osc enqueue-reject: ...' line" $ do
      let lines_ = composeListenerOutput
            (OSCProducerEnqueueAttempted
              sampleControlWrite
              (SessionFanInEnqueueResult
                { sfierResult     =
                    SessionEnqueueRejected
                      sampleProducerId
                      sampleControlWrite
                      (SeiQueueFull 64)
                , sfierQueueDepth = 64
                }))
      length lines_ @?= 1
      assertBool
        ("expected the line to start with 'osc enqueue-reject: '; got: "
          <> show (head lines_))
        ("osc enqueue-reject: " `isPrefixOf'` head lines_)
  ]


-- ---------------------------------------------------------------------------
-- Test fixtures
-- ---------------------------------------------------------------------------

sampleVoiceKey :: VoiceKey
sampleVoiceKey = VoiceKey "v0"

sampleControlTag :: ControlTag
sampleControlTag = ControlTag (MigrationKey "lpf") 0

sampleControlBinding :: ManifestOSCControlBinding
sampleControlBinding = ManifestOSCControlBinding
  { mocbControlTag =
      sampleControlTag
  , mocbDisplayName =
      "cutoff"
  , mocbDefault =
      600.0
  , mocbRangeMin =
      200.0
  , mocbRangeMax =
      6000.0
  , mocbCC =
      Just 74
  }

sampleControlWrite :: SessionCommand
sampleControlWrite =
  CmdControlWrite sampleVoiceKey sampleControlTag 0.75

sampleProducerId :: ProducerId
sampleProducerId = ProducerId ProducerOSC (T.pack "test-renderer")

-- | A minimal 'QueuedSessionCommand' fixture. The renderer never
-- inspects the queued payload's fields beyond what
-- 'SessionEnqueued' wraps, so a constructor call is sufficient.
sampleQueued :: QueuedSessionCommand
sampleQueued = QueuedSessionCommand
  { qscSequence = CommandSequence 0
  , qscProducer = sampleProducerId
  , qscCommand  = sampleControlWrite
  }


-- ---------------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------------

isSubstring :: String -> String -> Bool
isSubstring needle haystack =
  any (needle `isPrefixOf'`) (tails haystack)
  where
    tails [] = [[]]
    tails xs@(_:rest) = xs : tails rest

isPrefixOf' :: String -> String -> Bool
isPrefixOf' []     _      = True
isPrefixOf' _      []     = False
isPrefixOf' (x:xs) (y:ys) = x == y && isPrefixOf' xs ys
