{-# LANGUAGE OverloadedStrings #-}

-- | Deterministic coverage for the operator-string contract the
-- Phase 8h step 3c MIDI listener hooks drive against:
-- 'renderMIDIAcceptLine' / 'renderMIDIAcceptLineWithControls' and
-- 'renderMIDIIssueLine' / 'renderMIDIIssueLineWithControls' in
-- "MetaSonic.App.ManifestLiveCommon".
--
-- The 'Maybe' return on both renderers encodes:
--
--   * Accept side: a packet whose enqueue was rejected renders
--     'Nothing' so 'mmlhOnIssue' is the single source of the
--     operator-facing line (the same dedup policy the OSC renderer
--     uses).
--   * Issue side: 'MmliIgnoredEvent' renders 'Nothing' so non-CC
--     MIDI events on a manifest path stay silent by default.
--
-- The synthetic fan-out section composes
-- 'liveMIDIListenerHooksForObservedWith' against an IORef sink and
-- an observer to pin that accepted writes both print to the sink
-- and update the observer.
module MetaSonic.Spec.AppManifestLiveCommonMIDIRender
  ( appManifestLiveCommonMIDIRenderTests
  ) where

import           Data.IORef                             (IORef, modifyIORef',
                                                         newIORef, readIORef)
import           Data.Word                              (Word8)
import           Test.Tasty                             (TestTree, testGroup)
import           Test.Tasty.HUnit                       (testCase, (@?=))

import           MetaSonic.App.ManifestLiveCommon       (liveMIDIListenerHooksForObservedWith,
                                                         renderMIDIAcceptLine,
                                                         renderMIDIAcceptLineWithControls,
                                                         renderMIDIIssueLine,
                                                         renderMIDIIssueLineWithControls)
import           MetaSonic.App.ManifestMIDIListener     (ManifestMIDIListenerHooks (..),
                                                         ManifestMIDIListenerIssue (..))
import           MetaSonic.App.ManifestReloadMIDIBinding
                                                        (ManifestMIDIAddressIssue (..),
                                                         ManifestMIDIControlBinding (..),
                                                         ManifestMIDIIngressTarget (..))
import           MetaSonic.App.ManifestReloadMIDIIngress
                                                        (ManifestMIDIIngressIssue (..))
import           MetaSonic.Bridge.Source                (MigrationKey (..))
import           MetaSonic.Pattern                      (ControlTag (..),
                                                         VoiceKey (..))
import           MetaSonic.Session.Arbitration          (ArbitrationPolicy (..))
import           MetaSonic.Session.Command              (SessionCommand (..))
import           MetaSonic.Session.FanIn                (SessionFanInEnqueueResult (..))
import           MetaSonic.Session.MIDIProducer         (MIDIProducerEvent (..))
import           MetaSonic.Session.Queue                (CommandSequence (..),
                                                         ProducerId (..),
                                                         ProducerKind (..),
                                                         QueuedSessionCommand (..),
                                                         SessionEnqueueIssue (..),
                                                         SessionEnqueueResult (..))

import qualified Data.Map.Strict                        as M
import qualified Data.Text                              as T


appManifestLiveCommonMIDIRenderTests :: TestTree
appManifestLiveCommonMIDIRenderTests =
  testGroup "App manifest live common: MIDI listener-event line renderers"
  [ testGroup "renderMIDIAcceptLine"  renderMIDIAcceptLineTests
  , testGroup "renderMIDIIssueLine"   renderMIDIIssueLineTests
  , testGroup "liveMIDIListenerHooksForObservedWith fan-out"
              syntheticFanOutTests
  ]


-- ---------------------------------------------------------------------------
-- renderMIDIAcceptLine: the accept-side renderer (Maybe encodes dedup)
-- ---------------------------------------------------------------------------

renderMIDIAcceptLineTests :: [TestTree]
renderMIDIAcceptLineTests =
  [ testCase "SessionEnqueued renders 'Just \"midi accept: ...\"'" $
      renderMIDIAcceptLine (acceptedFanIn sampleControlWrite)
        @?= Just "midi accept: /v0/lpf/0 value=0.75"

  , testCase "SessionEnqueued uses manifest binding display name when available" $
      renderMIDIAcceptLineWithControls
        [sampleControlBinding]
        (acceptedFanIn sampleControlWrite)
        @?= Just "midi accept: /v0/lpf/0 name=\"cutoff\" value=0.75"

  , testCase "SessionEnqueued trims trailing float noise via renderOperatorValue" $
      renderMIDIAcceptLineWithControls
        [sampleControlBinding]
        (acceptedFanIn
          (CmdControlWrite sampleVoiceKey sampleControlTag 0.18000000715255737))
        @?= Just "midi accept: /v0/lpf/0 name=\"cutoff\" value=0.18"

  , testCase "SessionEnqueueRejected SeiReloadInProgress returns Nothing (dedup)" $
      renderMIDIAcceptLine (rejectedFanIn sampleControlWrite SeiReloadInProgress)
        @?= Nothing

  , testCase "SessionEnqueueRejected SeiQueueFull also returns Nothing" $
      renderMIDIAcceptLine (rejectedFanIn sampleControlWrite (SeiQueueFull 64))
        @?= Nothing

  , testCase "unmatched ControlTag still renders the address (metadata fallback)" $
      -- The manifest binding list above is target-local and may not
      -- carry every tag the listener forwards. The renderer should
      -- still emit a line so accepted writes never disappear.
      renderMIDIAcceptLineWithControls
        []  -- no bindings at all
        (acceptedFanIn sampleControlWrite)
        @?= Just "midi accept: /v0/lpf/0 value=0.75"
  ]


-- ---------------------------------------------------------------------------
-- renderMIDIIssueLine: the issue-side renderer (Maybe encodes silent
-- MmliIgnoredEvent)
-- ---------------------------------------------------------------------------

renderMIDIIssueLineTests :: [TestTree]
renderMIDIIssueLineTests =
  [ testCase "MmiiChannelFiltered renders the channel-filtered line" $
      renderMIDIIssueLine
        (MmliIngressIssue (MmiiChannelFiltered 4))
        @?= Just "midi reject (channel-filtered): ch=4"

  , testCase "MmaiUnknownCC without bindings renders just cc=N (no bound context)" $
      renderMIDIIssueLine
        (MmliIngressIssue (MmiiAddressIssue (MmaiUnknownCC 17)))
        @?= Just "midi reject (cc-unbound): cc=17"

  , testCase "MmaiUnknownCC with bindings lists bound CCs in ascending order" $
      -- Bindings declared in reverse order: 74, 7. Renderer should
      -- present 7, 74 ascending so operator output stays stable
      -- across manifest ordering.
      renderMIDIIssueLineWithControls
        [sampleControlBinding { mmcbCC = 74 }
        , sampleControlBinding { mmcbCC = 7
                               , mmcbControlTag =
                                   ControlTag (MigrationKey "gain") 0
                               }
        ]
        (MmliIngressIssue (MmiiAddressIssue (MmaiUnknownCC 17)))
        @?= Just "midi reject (cc-unbound): cc=17 (bound: 7, 74)"

  , testCase "MmiiInvalidChannel renders the bad-data line" $
      renderMIDIIssueLine
        (MmliIngressIssue (MmiiInvalidChannel 16))
        @?= Just "midi reject (bad-data): channel=16"

  , testCase "MmiiInvalidDataByte renders the bad-data line" $
      renderMIDIIssueLine
        (MmliIngressIssue (MmiiInvalidDataByte 130))
        @?= Just "midi reject (bad-data): byte=130"

  , testCase "SeiReloadInProgress renders the reload-window line" $
      renderMIDIIssueLine
        (MmliEnqueueRejected sampleControlWrite SeiReloadInProgress)
        @?= Just
              ("midi reject (reload-window): CmdControlWrite voice=v0 tag="
               <> show sampleControlTag
               <> " value=0.75")

  , testCase "SeiReloadInProgress label has no 'issue=' suffix" $
      -- Matches the OSC reload-window contract: the label itself
      -- names the cause, so 'issue=' would be redundant.
      case renderMIDIIssueLine
             (MmliEnqueueRejected sampleControlWrite SeiReloadInProgress) of
        Just line ->
          assertNoSubstring "issue=" line
        Nothing ->
          fail "expected Just; got Nothing"

  , testCase "SeiQueueFull keeps the generic 'midi enqueue-reject: ... issue=...' shape" $
      renderMIDIIssueLine
        (MmliEnqueueRejected sampleControlWrite (SeiQueueFull 64))
        @?= Just
              ("midi enqueue-reject: CmdControlWrite voice=v0 tag="
               <> show sampleControlTag
               <> " value=0.75 issue=SeiQueueFull 64")

  , testCase "MmliIgnoredEvent returns Nothing (silent by default)" $
      renderMIDIIssueLine
        (MmliIgnoredEvent (MIDIProducerNoteOn 0 60 100))
        @?= Nothing
  ]


-- ---------------------------------------------------------------------------
-- liveMIDIListenerHooksForObservedWith fan-out
-- ---------------------------------------------------------------------------

syntheticFanOutTests :: [TestTree]
syntheticFanOutTests =
  [ testCase "accepted CmdControlWrite prints to sink AND updates observer" $ do
      sinkRef    <- newIORef []
      observerRef <- newIORef []
      let hooks =
            liveMIDIListenerHooksForObservedWith
              (sampleTarget [sampleControlBinding])
              (\v t val ->
                  modifyIORef' observerRef (++ [(v, t, val)]))
              (\line -> modifyIORef' sinkRef (++ [line]))
      mmlhOnAccepted hooks (acceptedFanIn sampleControlWrite)
      sinkLines <- readIORef sinkRef
      observed  <- readIORef observerRef
      sinkLines @?= ["  midi accept: /v0/lpf/0 name=\"cutoff\" value=0.75"]
      observed  @?= [(sampleVoiceKey, sampleControlTag, 0.75)]

  , testCase "rejected enqueue prints nothing and leaves observer untouched" $ do
      -- The dedup policy: rejection lines come from mmlhOnIssue,
      -- not from mmlhOnAccepted. The accepted hook should output
      -- nothing for a rejected enqueue and must not call the
      -- observer.
      sinkRef    <- newIORef []
      observerRef <- newIORef []
      let hooks =
            liveMIDIListenerHooksForObservedWith
              (sampleTarget [sampleControlBinding])
              (\v t val ->
                  modifyIORef' observerRef (++ [(v, t, val)]))
              (\line -> modifyIORef' sinkRef (++ [line]))
      mmlhOnAccepted hooks
        (rejectedFanIn sampleControlWrite SeiReloadInProgress)
      sinkLines <- readIORef sinkRef
      observed  <- readIORef observerRef
      sinkLines @?= ([] :: [String])
      observed  @?= ([] :: [(VoiceKey, ControlTag, Double)])

  , testCase "MmliIngressIssue prints the issue line" $ do
      sinkRef <- newIORef []
      let hooks =
            liveMIDIListenerHooksForObservedWith
              (sampleTarget [sampleControlBinding])
              (\_ _ _ -> pure ())
              (\line -> modifyIORef' sinkRef (++ [line]))
      mmlhOnIssue hooks (MmliIngressIssue (MmiiChannelFiltered 4))
      sinkLines <- readIORef sinkRef
      sinkLines @?= ["  midi reject (channel-filtered): ch=4"]

  , testCase "MmliIgnoredEvent prints nothing (silent by default)" $ do
      sinkRef <- newIORef []
      let hooks =
            liveMIDIListenerHooksForObservedWith
              (sampleTarget [sampleControlBinding])
              (\_ _ _ -> pure ())
              (\line -> modifyIORef' sinkRef (++ [line]))
      mmlhOnIssue hooks (MmliIgnoredEvent (MIDIProducerNoteOn 0 60 100))
      sinkLines <- readIORef sinkRef
      sinkLines @?= ([] :: [String])
  ]


-- ---------------------------------------------------------------------------
-- Test fixtures
-- ---------------------------------------------------------------------------

sampleVoiceKey :: VoiceKey
sampleVoiceKey = VoiceKey "v0"

sampleControlTag :: ControlTag
sampleControlTag = ControlTag (MigrationKey "lpf") 0

sampleControlBinding :: ManifestMIDIControlBinding
sampleControlBinding = ManifestMIDIControlBinding
  { mmcbControlTag  = sampleControlTag
  , mmcbDisplayName = "cutoff"
  , mmcbCC          = 74
  , mmcbDefault     = 600.0
  , mmcbRangeMin    = 200.0
  , mmcbRangeMax    = 6000.0
  }

sampleControlWrite :: SessionCommand
sampleControlWrite =
  CmdControlWrite sampleVoiceKey sampleControlTag 0.75

sampleProducerId :: ProducerId
sampleProducerId = ProducerId ProducerMIDI (T.pack "test-renderer")

sampleQueued :: QueuedSessionCommand
sampleQueued = QueuedSessionCommand
  { qscSequence = CommandSequence 0
  , qscProducer = sampleProducerId
  , qscCommand  = sampleControlWrite
  }

acceptedFanIn :: SessionCommand -> SessionFanInEnqueueResult
acceptedFanIn cmd = SessionFanInEnqueueResult
  { sfierResult     = SessionEnqueued sampleQueued { qscCommand = cmd }
  , sfierQueueDepth = 1
  }

rejectedFanIn
  :: SessionCommand
  -> SessionEnqueueIssue
  -> SessionFanInEnqueueResult
rejectedFanIn cmd issue = SessionFanInEnqueueResult
  { sfierResult     =
      SessionEnqueueRejected sampleProducerId cmd issue
  , sfierQueueDepth = 0
  }

sampleTarget :: [ManifestMIDIControlBinding] -> ManifestMIDIIngressTarget
sampleTarget bindings = ManifestMIDIIngressTarget
  { mmitDemoKey           = "test-demo"
  , mmitDefaultVoice      = VoiceKey "fx"
  , mmitControls          = bindings
  , mmitCCRoutes          = M.empty
  , mmitArbitrationPolicy = FifoOnly
  }


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

assertNoSubstring :: String -> String -> IO ()
assertNoSubstring needle haystack
  | needle `isSubstring` haystack =
      fail ("expected no " <> show needle <> " in: " <> show haystack)
  | otherwise =
      pure ()

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
