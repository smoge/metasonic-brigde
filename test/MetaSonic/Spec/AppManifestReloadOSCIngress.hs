-- | Host-level OSC ingress smoke using real session OSC producer/listener
-- decoder pieces against the projected manifest target.
module MetaSonic.Spec.AppManifestReloadOSCIngress where

import qualified Data.ByteString.Char8            as BSC
import qualified Data.Map.Strict                  as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestReloadOSCBinding
                                                  (manifestOSCIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadOSCIngress
import           MetaSonic.Bridge.Source          (MigrationKey (..))
import           MetaSonic.Bridge.Templates       (TemplateGraph (..))
import           MetaSonic.OSC.Wire               (OscArg (..), OscMessage (..))
import           MetaSonic.Pattern                (ControlTag (..),
                                                   SwapLabel (..),
                                                   VoiceKey (..))
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy (..))
import           MetaSonic.Session.Command        (SessionCommand (..))
import           MetaSonic.Session.FanIn          (SessionFanInEnqueueResult (..),
                                                   SessionFanInSnapshot (..),
                                                   defaultSessionFanInOptions,
                                                   readSessionFanInHost,
                                                   withSessionFanInHost)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.OSCProducer    (OSCProducerEnqueueResult (..),
                                                   defaultOSCProducerOptions)
import           MetaSonic.Session.Queue          (QueuedSessionCommand (..),
                                                   SessionEnqueueResult (..))
import           MetaSonic.Session.RTGraphAdapter (defaultRTGraphAdapterOptions)


appManifestReloadOSCIngressTests :: TestTree
appManifestReloadOSCIngressTests =
  testGroup "App manifest reload OSC ingress smoke"
  [ testCase "known address forwards a CmdControlWrite through the OSC producer" $ do
      let target = manifestOSCIngressTargetFromPlan validPlan
          msg = OscMessage
            { oscAddr = BSC.pack "/v0/cutoff/1"
            , oscArgs = [OscArgFloat 2400.0]
            }
      withFanInOrFail $ \host -> do
        result <-
          submitManifestOSCMessage
            defaultOSCProducerOptions
            target
            msg
            host
        case moirOutcome result of
          Right (OSCProducerEnqueueAttempted command enq) -> do
            command @?= CmdControlWrite (VoiceKey "v0") cutoffTag 2400.0
            queued <- fanInQueuedOrFail enq
            qscCommand queued @?= command
          other ->
            assertFailure
              ("expected OSC enqueue success, got: " <> show other)

  , testCase "unknown address tag rejects at the projection without enqueue" $ do
      let target = manifestOSCIngressTargetFromPlan validPlan
          msg = OscMessage
            { oscAddr = BSC.pack "/v0/old/0"
            , oscArgs = [OscArgFloat 1.0]
            }
      withFanInOrFail $ \host -> do
        result <-
          submitManifestOSCMessage
            defaultOSCProducerOptions
            target
            msg
            host
        case moirOutcome result of
          Left (MoiiAddressIssue _) ->
            pure ()
          other ->
            assertFailure
              ("expected projection rejection, got: " <> show other)
        snapshot <- readSessionFanInHost host
        sfisQueueDepth snapshot @?= 0

  , testCase "malformed address rejects at the decoder without enqueue" $ do
      let target = manifestOSCIngressTargetFromPlan validPlan
          msg = OscMessage
            { oscAddr = BSC.pack "/just-one-segment"
            , oscArgs = [OscArgFloat 1.0]
            }
      withFanInOrFail $ \host -> do
        result <-
          submitManifestOSCMessage
            defaultOSCProducerOptions
            target
            msg
            host
        case moirOutcome result of
          Left (MoiiDecodeFailed _) ->
            pure ()
          other ->
            assertFailure
              ("expected decoder rejection, got: " <> show other)
        snapshot <- readSessionFanInHost host
        sfisQueueDepth snapshot @?= 0
  ]
  where
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
