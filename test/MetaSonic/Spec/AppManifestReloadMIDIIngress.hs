-- | Host-level MIDI CC ingress smoke against the projected manifest target.
module MetaSonic.Spec.AppManifestReloadMIDIIngress where

import qualified Data.Map.Strict                  as M
import qualified Data.Set                         as S
import           Data.Word                        (Word8)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestReloadMIDIBinding
                                                  (ManifestMIDIAddressIssue (..),
                                                   manifestMIDIIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadMIDIIngress
import           MetaSonic.Bridge.Source          (MigrationKey (..))
import           MetaSonic.Bridge.Templates       (TemplateGraph (..))
import           MetaSonic.Pattern                (ControlTag (..),
                                                   SwapLabel (..),
                                                   VoiceKey (..))
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy (..))
import           MetaSonic.Session.Command        (SessionCommand (..))
import           MetaSonic.Session.FanIn          (SessionFanInEnqueueResult (..),
                                                   SessionFanInHost,
                                                   SessionFanInOptions (..),
                                                   SessionFanInSnapshot (..),
                                                   defaultSessionFanInOptions,
                                                   enqueueSessionFanInCommand,
                                                   readSessionFanInHost,
                                                   withSessionFanInHost)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.MIDIProducer   (MIDIChannelFilter (..),
                                                   MIDIProducerOptions (..),
                                                   defaultMIDIProducerOptions)
import           MetaSonic.Session.Queue          (ProducerKind (..),
                                                   QueuedSessionCommand (..),
                                                   SessionEnqueueIssue (..),
                                                   SessionEnqueueResult (..),
                                                   SessionQueueOptions (..))
import           MetaSonic.Session.RTGraphAdapter (defaultRTGraphAdapterOptions)
import           MetaSonic.Spec.SessionShared     (testProducer)


appManifestReloadMIDIIngressTests :: TestTree
appManifestReloadMIDIIngressTests =
  testGroup "App manifest reload MIDI ingress smoke"
  [ testCase "bound CC forwards a scaled CmdControlWrite to the default voice" $ do
      let target = projectedTarget validPlan
          input = ManifestMIDICCInput
            { mmciChannel = 0
            , mmciCC = volCC
            , mmciValue = 127
            }
      withFanInOrFail $ \host -> do
        result <-
          submitManifestMIDICCEvent
            defaultMIDIProducerOptions
            target
            input
            host
        case mmirOutcome result of
          Right enq -> do
            queued <- fanInQueuedOrFail enq
            qscCommand queued
              @?= CmdControlWrite defaultVoice volTag 1.0
          other ->
            assertFailure
              ("expected MIDI enqueue, got: " <> show other)

  , testCase "midpoint CC value scales through the binding range" $ do
      let target = projectedTarget validPlan
          input = ManifestMIDICCInput
            { mmciChannel = 0
            , mmciCC = volCC
            , mmciValue = 64
            }
      withFanInOrFail $ \host -> do
        result <-
          submitManifestMIDICCEvent
            defaultMIDIProducerOptions
            target
            input
            host
        case mmirOutcome result of
          Right enq -> do
            queued <- fanInQueuedOrFail enq
            case qscCommand queued of
              CmdControlWrite voice tag value -> do
                voice @?= defaultVoice
                tag @?= volTag
                assertBool
                  ("expected midpoint value around 0.504, got: " <> show value)
                  (abs (value - 0.5039370078740157) < 1e-9)
              other ->
                assertFailure
                  ("expected CmdControlWrite, got: " <> show other)
          other ->
            assertFailure
              ("expected MIDI enqueue, got: " <> show other)

  , testCase "unbound CC rejects with MmiiAddressIssue and queue stays empty" $ do
      let target = projectedTarget validPlan
          input = ManifestMIDICCInput
            { mmciChannel = 0
            , mmciCC = 23
            , mmciValue = 64
            }
      withFanInOrFail $ \host -> do
        result <-
          submitManifestMIDICCEvent
            defaultMIDIProducerOptions
            target
            input
            host
        case mmirOutcome result of
          Left (MmiiAddressIssue (MmaiUnknownCC cc)) ->
            cc @?= 23
          other ->
            assertFailure
              ("expected unknown CC rejection, got: " <> show other)
        snapshot <- readSessionFanInHost host
        sfisQueueDepth snapshot @?= 0

  , testCase "removed CC after reload rejects with MmiiAddressIssue" $ do
      let trimmedPlan = validPlan
            { MR.mrlpControlSurface =
                [cutoffControl]
            }
          target = projectedTarget trimmedPlan
          input = ManifestMIDICCInput
            { mmciChannel = 0
            , mmciCC = volCC
            , mmciValue = 64
            }
      withFanInOrFail $ \host -> do
        result <-
          submitManifestMIDICCEvent
            defaultMIDIProducerOptions
            target
            input
            host
        case mmirOutcome result of
          Left (MmiiAddressIssue (MmaiUnknownCC cc)) ->
            cc @?= volCC
          other ->
            assertFailure
              ("expected reload-removed CC rejection, got: " <> show other)
        snapshot <- readSessionFanInHost host
        sfisQueueDepth snapshot @?= 0

  , testCase "remapped CC accepts the new CC and rejects the old one" $ do
      let remappedPlan = validPlan
            { MR.mrlpControlSurface =
                [ cutoffControl
                , volControl { MR.mcsCC = Just 11 }
                ]
            }
          target = projectedTarget remappedPlan
      withFanInOrFail $ \host -> do
        oldResult <-
          submitManifestMIDICCEvent
            defaultMIDIProducerOptions
            target
            ManifestMIDICCInput
              { mmciChannel = 0
              , mmciCC = volCC
              , mmciValue = 127
              }
            host
        case mmirOutcome oldResult of
          Left (MmiiAddressIssue (MmaiUnknownCC cc)) ->
            cc @?= volCC
          other ->
            assertFailure
              ("expected old CC to reject after remap, got: " <> show other)

        newResult <-
          submitManifestMIDICCEvent
            defaultMIDIProducerOptions
            target
            ManifestMIDICCInput
              { mmciChannel = 0
              , mmciCC = 11
              , mmciValue = 127
              }
            host
        case mmirOutcome newResult of
          Right enq -> do
            queued <- fanInQueuedOrFail enq
            qscCommand queued
              @?= CmdControlWrite defaultVoice volTag 1.0
          other ->
            assertFailure
              ("expected new CC to enqueue, got: " <> show other)

  , testCase "invalid channel rejects with MmiiInvalidChannel and queue stays empty" $ do
      let target = projectedTarget validPlan
          input = ManifestMIDICCInput
            { mmciChannel = 16
            , mmciCC = volCC
            , mmciValue = 64
            }
      withFanInOrFail $ \host -> do
        result <-
          submitManifestMIDICCEvent
            defaultMIDIProducerOptions
            target
            input
            host
        mmirOutcome result @?= Left (MmiiInvalidChannel 16)
        snapshot <- readSessionFanInHost host
        sfisQueueDepth snapshot @?= 0

  , testCase "channel filtered by allow-list rejects with MmiiChannelFiltered and queue stays empty" $ do
      let target = projectedTarget validPlan
          filteredOpts = defaultMIDIProducerOptions
            { mpoChannelFilter = MIDIChannelAllowList (S.fromList [0])
            }
          input = ManifestMIDICCInput
            { mmciChannel = 1
            , mmciCC = volCC
            , mmciValue = 64
            }
      withFanInOrFail $ \host -> do
        result <-
          submitManifestMIDICCEvent
            filteredOpts
            target
            input
            host
        mmirOutcome result @?= Left (MmiiChannelFiltered 1)
        snapshot <- readSessionFanInHost host
        sfisQueueDepth snapshot @?= 0

  , testCase "allow-listed channel still enqueues under the same filter" $ do
      let target = projectedTarget validPlan
          filteredOpts = defaultMIDIProducerOptions
            { mpoChannelFilter = MIDIChannelAllowList (S.fromList [0])
            }
          input = ManifestMIDICCInput
            { mmciChannel = 0
            , mmciCC = volCC
            , mmciValue = 127
            }
      withFanInOrFail $ \host -> do
        result <-
          submitManifestMIDICCEvent
            filteredOpts
            target
            input
            host
        case mmirOutcome result of
          Right enq -> do
            queued <- fanInQueuedOrFail enq
            qscCommand queued
              @?= CmdControlWrite defaultVoice volTag 1.0
          other ->
            assertFailure
              ("expected allow-listed channel to enqueue, got: " <> show other)

  , testCase "invalid data byte rejects with MmiiInvalidDataByte and queue stays empty" $ do
      let target = projectedTarget validPlan
          input = ManifestMIDICCInput
            { mmciChannel = 0
            , mmciCC = volCC
            , mmciValue = 200
            }
      withFanInOrFail $ \host -> do
        result <-
          submitManifestMIDICCEvent
            defaultMIDIProducerOptions
            target
            input
            host
        mmirOutcome result @?= Left (MmiiInvalidDataByte 200)
        snapshot <- readSessionFanInHost host
        sfisQueueDepth snapshot @?= 0

  , testCase "queue-full fan-in rejection surfaces in the outcome" $ do
      let target = projectedTarget validPlan
          fanInOpts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          prefillCmd = CmdVoiceOff (VoiceKey "prefill")
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          fanInOpts
          $ \host -> do
              _ <-
                enqueueSessionFanInCommand
                  (testProducer ProducerTest "prefill")
                  prefillCmd
                  host
              submitManifestMIDICCEvent
                defaultMIDIProducerOptions
                target
                ManifestMIDICCInput
                  { mmciChannel = 0
                  , mmciCC = volCC
                  , mmciValue = 127
                  }
                host
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right outcome ->
          case mmirOutcome outcome of
            Right enq ->
              case sfierResult enq of
                SessionEnqueueRejected _ _ (SeiQueueFull cap) ->
                  cap @?= 1
                other ->
                  assertFailure
                    ("expected queue-full rejection, got: " <> show other)
            other ->
              assertFailure
                ("expected MIDI enqueue attempt, got: " <> show other)
  ]
  where
    projectedTarget plan =
      case manifestMIDIIngressTargetFromPlan defaultVoice plan of
        Right target ->
          target
        Left issue ->
          error
            ("test setup: expected projection to succeed, got: "
             <> show issue)

    withFanInOrFail :: (SessionFanInHost -> IO ()) -> IO ()
    withFanInOrFail action = do
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          action
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right () ->
          pure ()

    fanInQueuedOrFail enq =
      case sfierResult enq of
        SessionEnqueued queued ->
          pure queued
        other ->
          assertFailure ("expected enqueued, got: " <> show other)
          >> error "unreachable"

validPlan :: MR.ManifestReloadPlan
validPlan = MR.ManifestReloadPlan
  { MR.mrlpDemoKey =
      "demo"
  , MR.mrlpSwapLabel =
      SwapLabel "reload"
  , MR.mrlpTemplateGraph =
      TemplateGraph [] M.empty
  , MR.mrlpAdapterOptions =
      defaultRTGraphAdapterOptions
  , MR.mrlpControlSurface =
      [ cutoffControl
      , volControl
      ]
  , MR.mrlpArbitrationPolicy =
      FifoOnly
  }

cutoffControl :: MR.ManifestControlSurface
cutoffControl = MR.ManifestControlSurface
  { MR.mcsDisplayName =
      "cutoff"
  , MR.mcsControlTag =
      cutoffTag
  , MR.mcsDefault =
      1200.0
  , MR.mcsRangeMin =
      200.0
  , MR.mcsRangeMax =
      8000.0
  , MR.mcsSmoothingHz =
      30.0
  , MR.mcsCC =
      Nothing
  }

volControl :: MR.ManifestControlSurface
volControl = MR.ManifestControlSurface
  { MR.mcsDisplayName =
      "vol"
  , MR.mcsControlTag =
      volTag
  , MR.mcsDefault =
      0.3
  , MR.mcsRangeMin =
      0.0
  , MR.mcsRangeMax =
      1.0
  , MR.mcsSmoothingHz =
      30.0
  , MR.mcsCC =
      Just volCC
  }

cutoffTag :: ControlTag
cutoffTag =
  ControlTag (MigrationKey "cutoff") 1

volTag :: ControlTag
volTag =
  ControlTag (MigrationKey "vol") 1

volCC :: Word8
volCC =
  7

defaultVoice :: VoiceKey
defaultVoice =
  VoiceKey "fx"
