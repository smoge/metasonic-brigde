-- | App-level UI producer binding tests over the manifest UI projection.
module MetaSonic.Spec.AppManifestReloadUIIngress where

import qualified Data.Map.Strict                  as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestReloadBinding
                                                  (ManifestUIIngressTarget,
                                                   ManifestUIVoiceSelection (..),
                                                   manifestUIIngressTargetFromPlan,
                                                   muicControlTag,
                                                   muicCurrent,
                                                   muicValueSource,
                                                   muitControls,
                                                   ManifestUIControlValueSource (..))
import           MetaSonic.App.ManifestReloadUIIngress
import           MetaSonic.Bridge.Source          (MigrationKey (..))
import           MetaSonic.Bridge.Templates       (TemplateGraph (..))
import           MetaSonic.Pattern                (ControlTag (..),
                                                   SwapLabel (..),
                                                   VoiceKey (..))
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy (..))
import           MetaSonic.Session.Command        (SessionCommand (..))
import           MetaSonic.Session.FanIn          (SessionFanInEnqueueResult (..),
                                                   SessionFanInOptions (..),
                                                   defaultSessionFanInOptions,
                                                   enqueueSessionFanInCommand,
                                                   withSessionFanInHost)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.Queue          (ProducerKind (..),
                                                   QueuedSessionCommand (..),
                                                   SessionEnqueueIssue (..),
                                                   SessionEnqueueResult (..),
                                                   SessionQueueOptions (..))
import           MetaSonic.Session.RTGraphAdapter (defaultRTGraphAdapterOptions)
import           MetaSonic.Session.UIProducer     (UIProducerEnqueueResult (..),
                                                   defaultUIProducerOptions,
                                                   uiProducerId)
import           MetaSonic.Spec.SessionShared     (testProducer)


appManifestReloadUIIngressTests :: TestTree
appManifestReloadUIIngressTests =
  testGroup "App manifest reload UI ingress"
  [ testCase "known control writes enqueue a CmdControlWrite" $ do
      let target = projectedTarget focusedVoiceSelection
      withFanInOrFail $ \host -> do
        result <-
          submitManifestUIIngress
            defaultUIProducerOptions
            target
            M.empty
            (ManifestUIIngressInput cutoffTag 2400.0)
            host
        case muirOutcome result of
          Right (UIProducerEnqueueAttempted command enq) -> do
            command @?= CmdControlWrite focusedKey cutoffTag 2400.0
            queued <- fanInQueuedOrFail enq
            qscCommand queued @?= command
          other ->
            assertFailure
              ("expected UI enqueue, got: " <> show other)

  , testCase "focused voice wins over default voice" $ do
      let target = projectedTarget focusedVoiceSelection
      withFanInOrFail $ \host -> do
        result <-
          submitManifestUIIngress
            defaultUIProducerOptions
            target
            M.empty
            (ManifestUIIngressInput cutoffTag 1800.0)
            host
        case muirOutcome result of
          Right (UIProducerEnqueueAttempted command _enq) ->
            command @?= CmdControlWrite focusedKey cutoffTag 1800.0
          other ->
            assertFailure
              ("expected focused-voice enqueue, got: " <> show other)

  , testCase "unfocused voice selection falls back to the default voice" $ do
      let target = projectedTarget unfocusedVoiceSelection
      withFanInOrFail $ \host -> do
        result <-
          submitManifestUIIngress
            defaultUIProducerOptions
            target
            M.empty
            (ManifestUIIngressInput cutoffTag 900.0)
            host
        case muirOutcome result of
          Right (UIProducerEnqueueAttempted command _enq) ->
            command @?= CmdControlWrite defaultKey cutoffTag 900.0
          other ->
            assertFailure
              ("expected default-voice enqueue, got: " <> show other)

  , testCase "unknown control rejects before fan-in enqueue" $ do
      let target = projectedTarget focusedVoiceSelection
      withFanInOrFail $ \host -> do
        result <-
          submitManifestUIIngress
            defaultUIProducerOptions
            target
            (M.fromList [(cutoffTag, 1500.0)])
            (ManifestUIIngressInput staleTag 42.0)
            host
        muirOutcome result @?= Left (MuiiUnknownControl staleTag)
        -- Retain map is unchanged.
        muirRetainedValues result @?= M.fromList [(cutoffTag, 1500.0)]

  , testCase "value below rangeMin rejects before fan-in enqueue" $ do
      let target = projectedTarget focusedVoiceSelection
          retainedBefore = M.fromList [(cutoffTag, 1500.0)]
      withFanInOrFail $ \host -> do
        result <-
          submitManifestUIIngress
            defaultUIProducerOptions
            target
            retainedBefore
            (ManifestUIIngressInput cutoffTag 100.0)
            host
        muirOutcome result @?= Left (MuiiValueOutOfRange cutoffTag 100.0 200.0 8000.0)
        muirRetainedValues result @?= retainedBefore

  , testCase "value above rangeMax rejects before fan-in enqueue" $ do
      let target = projectedTarget focusedVoiceSelection
      withFanInOrFail $ \host -> do
        result <-
          submitManifestUIIngress
            defaultUIProducerOptions
            target
            M.empty
            (ManifestUIIngressInput cutoffTag 9000.0)
            host
        muirOutcome result @?= Left (MuiiValueOutOfRange cutoffTag 9000.0 200.0 8000.0)

  , testCase "value at rangeMin boundary is accepted" $ do
      let target = projectedTarget focusedVoiceSelection
      withFanInOrFail $ \host -> do
        result <-
          submitManifestUIIngress
            defaultUIProducerOptions
            target
            M.empty
            (ManifestUIIngressInput cutoffTag 200.0)
            host
        case muirOutcome result of
          Right (UIProducerEnqueueAttempted command _enq) ->
            command @?= CmdControlWrite focusedKey cutoffTag 200.0
          other ->
            assertFailure
              ("expected boundary-accepted enqueue, got: " <> show other)

  , testCase "non-finite value rejects at the manifest range check (shadows UI producer's non-finite arm) and keeps the retain map" $ do
      -- Phase 8h step 3d: the manifest range check fires before the UI
      -- producer's 'UpiNonFiniteControlValue' arm because infinity
      -- fails @value > rangeMax@ (and NaN trips the 'isNaN' guard).
      -- Mirrors 'submitManifestOSCMessage' — the UI producer's
      -- non-finite arm is still reachable for direct
      -- 'enqueueUIProducerIntent' callers that bypass the manifest
      -- wrapper.
      let target = projectedTarget focusedVoiceSelection
          infinity = 1.0 / 0.0
          retainedBefore = M.fromList [(cutoffTag, 1500.0)]
      withFanInOrFail $ \host -> do
        result <-
          submitManifestUIIngress
            defaultUIProducerOptions
            target
            retainedBefore
            (ManifestUIIngressInput cutoffTag infinity)
            host
        muirOutcome result @?= Left (MuiiValueOutOfRange cutoffTag infinity 200.0 8000.0)
        muirRetainedValues result @?= retainedBefore

  , testCase "queue-full fan-in rejection keeps the retain map" $ do
      let target = projectedTarget focusedVoiceSelection
          retainedBefore = M.fromList [(cutoffTag, 1500.0)]
          fanInOpts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          prefillCmd = CmdVoiceOff (VoiceKey "prefill")
          expectedCmd = CmdControlWrite focusedKey cutoffTag 2400.0
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          fanInOpts
          $ \host -> do
              _prefill <-
                enqueueSessionFanInCommand
                  (testProducer ProducerTest "prefill")
                  prefillCmd
                  host
              submitManifestUIIngress
                defaultUIProducerOptions
                target
                retainedBefore
                (ManifestUIIngressInput cutoffTag 2400.0)
                host
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right outcome -> do
          case muirOutcome outcome of
            Right (UIProducerEnqueueAttempted command enq) -> do
              command @?= expectedCmd
              sfierResult enq
                @?= SessionEnqueueRejected
                      (uiProducerId defaultUIProducerOptions)
                      expectedCmd
                      (SeiQueueFull 1)
            other ->
              assertFailure
                ("expected queue-full UI enqueue attempt, got: " <> show other)
          muirRetainedValues outcome @?= retainedBefore

  , testCase "accepted write updates retained values" $ do
      let target = projectedTarget focusedVoiceSelection
      withFanInOrFail $ \host -> do
        result <-
          submitManifestUIIngress
            defaultUIProducerOptions
            target
            M.empty
            (ManifestUIIngressInput cutoffTag 2400.0)
            host
        case muirOutcome result of
          Right (UIProducerEnqueueAttempted _cmd enq)
            | enqueueAccepted enq ->
                muirRetainedValues result
                  @?= M.fromList [(cutoffTag, 2400.0)]
          other ->
            assertFailure
              ("expected accepted enqueue with retain update, got: "
               <> show other)

  , testCase "reload projection reuses retained value for surviving tag" $ do
      let initialTarget = projectedTarget focusedVoiceSelection
      withFanInOrFail $ \host -> do
        firstWrite <-
          submitManifestUIIngress
            defaultUIProducerOptions
            initialTarget
            M.empty
            (ManifestUIIngressInput cutoffTag 2400.0)
            host
        muirRetainedValues firstWrite
          @?= M.fromList [(cutoffTag, 2400.0)]

        -- Reload to the same plan with the retained map carried over.
        let reprojected =
              manifestUIIngressTargetFromPlan
                focusedVoiceSelection
                (muirRetainedValues firstWrite)
                validPlan
        case filter ((cutoffTag ==) . muicControlTag) (muitControls reprojected) of
          binding : _ -> do
            muicCurrent binding @?= 2400.0
            muicValueSource binding @?= MuicRetainedValue
          [] ->
            assertFailure "expected cutoff binding after reprojection"
  ]
  where
    enqueueAccepted result =
      case sfierResult result of
        SessionEnqueued {} ->
          True
        SessionEnqueueRejected {} ->
          False

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

projectedTarget :: ManifestUIVoiceSelection -> ManifestUIIngressTarget
projectedTarget selection =
  manifestUIIngressTargetFromPlan selection M.empty validPlan

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
      [ MR.ManifestControlSurface
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
      ]
  , MR.mrlpArbitrationPolicy =
      FifoOnly
  }

cutoffTag :: ControlTag
cutoffTag =
  ControlTag (MigrationKey "cutoff") 1

staleTag :: ControlTag
staleTag =
  ControlTag (MigrationKey "old") 0

focusedKey :: VoiceKey
focusedKey =
  VoiceKey "u-focused"

defaultKey :: VoiceKey
defaultKey =
  VoiceKey "u-default"

focusedVoiceSelection :: ManifestUIVoiceSelection
focusedVoiceSelection = ManifestUIVoiceSelection
  { muvsFocusedVoice =
      Just focusedKey
  , muvsDefaultVoice =
      defaultKey
  }

unfocusedVoiceSelection :: ManifestUIVoiceSelection
unfocusedVoiceSelection = ManifestUIVoiceSelection
  { muvsFocusedVoice =
      Nothing
  , muvsDefaultVoice =
      defaultKey
  }
