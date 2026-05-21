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

  -- See notes/2026-05-21-d-manifest-osc-range-rejection.md for the
  -- contract these rows pin: inclusive bounds, NaN rejected as
  -- out-of-range, producer never called on reject.
  , testCase "value at rangeMin is accepted (inclusive lower bound)" $ do
      let target = manifestOSCIngressTargetFromPlan validPlan
          msg = OscMessage
            { oscAddr = BSC.pack "/v0/cutoff/1"
            , oscArgs = [OscArgFloat 200.0]
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
            command @?= CmdControlWrite (VoiceKey "v0") cutoffTag 200.0
            queued <- fanInQueuedOrFail enq
            qscCommand queued @?= command
          other ->
            assertFailure
              ("expected accept at rangeMin, got: " <> show other)

  , testCase "value at rangeMax is accepted (inclusive upper bound)" $ do
      let target = manifestOSCIngressTargetFromPlan validPlan
          msg = OscMessage
            { oscAddr = BSC.pack "/v0/cutoff/1"
            , oscArgs = [OscArgFloat 8000.0]
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
            command @?= CmdControlWrite (VoiceKey "v0") cutoffTag 8000.0
            queued <- fanInQueuedOrFail enq
            qscCommand queued @?= command
          other ->
            assertFailure
              ("expected accept at rangeMax, got: " <> show other)

  -- The OSC wire format uses 32-bit floats; values not exactly
  -- representable in single precision round-trip with small drift
  -- when promoted back to Double. The chosen rejection values
  -- (199.0 and 9000.0) are integers <= 2^24, so they round-trip
  -- exactly and the equality assertions below remain precise.
  , testCase "value below rangeMin rejects with MoiiValueOutOfRange (producer not called)" $ do
      let target = manifestOSCIngressTargetFromPlan validPlan
          msg = OscMessage
            { oscAddr = BSC.pack "/v0/cutoff/1"
            , oscArgs = [OscArgFloat 199.0]
            }
      withFanInOrFail $ \host -> do
        result <-
          submitManifestOSCMessage
            defaultOSCProducerOptions
            target
            msg
            host
        case moirOutcome result of
          Left (MoiiValueOutOfRange tag value lo hi) -> do
            tag   @?= cutoffTag
            value @?= 199.0
            lo    @?= 200.0
            hi    @?= 8000.0
          other ->
            assertFailure
              ("expected out-of-range below min, got: " <> show other)
        snapshot <- readSessionFanInHost host
        sfisQueueDepth snapshot @?= 0

  , testCase "value above rangeMax rejects with MoiiValueOutOfRange (producer not called)" $ do
      let target = manifestOSCIngressTargetFromPlan validPlan
          msg = OscMessage
            { oscAddr = BSC.pack "/v0/cutoff/1"
            , oscArgs = [OscArgFloat 9000.0]
            }
      withFanInOrFail $ \host -> do
        result <-
          submitManifestOSCMessage
            defaultOSCProducerOptions
            target
            msg
            host
        case moirOutcome result of
          Left (MoiiValueOutOfRange tag value lo hi) -> do
            tag   @?= cutoffTag
            value @?= 9000.0
            lo    @?= 200.0
            hi    @?= 8000.0
          other ->
            assertFailure
              ("expected out-of-range above max, got: " <> show other)
        snapshot <- readSessionFanInHost host
        sfisQueueDepth snapshot @?= 0

  , testCase "NaN rejects with MoiiValueOutOfRange (NaN comparisons are all False; explicit isNaN arm catches it)" $ do
      let target = manifestOSCIngressTargetFromPlan validPlan
          msg = OscMessage
            { oscAddr = BSC.pack "/v0/cutoff/1"
            , oscArgs = [OscArgFloat (0/0)]
            }
      withFanInOrFail $ \host -> do
        result <-
          submitManifestOSCMessage
            defaultOSCProducerOptions
            target
            msg
            host
        case moirOutcome result of
          Left (MoiiValueOutOfRange tag value lo hi) -> do
            tag   @?= cutoffTag
            assertBool ("expected NaN value, got: " <> show value) (isNaN value)
            lo    @?= 200.0
            hi    @?= 8000.0
          other ->
            assertFailure
              ("expected out-of-range for NaN, got: " <> show other)
        snapshot <- readSessionFanInHost host
        sfisQueueDepth snapshot @?= 0

  -- Degenerate-but-legal range: a manifest may declare
  -- rangeMin == rangeMax (single-valued control). The accept
  -- predicate is inclusive on both sides, so the exact midpoint
  -- accepts and the producer is called. See
  -- notes/2026-05-21-d-manifest-osc-range-rejection.md.
  , testCase "zero-width range accepts the exact boundary value (rangeMin == rangeMax)" $ do
      let target = manifestOSCIngressTargetFromPlan zeroWidthPlan
          msg = OscMessage
            { oscAddr = BSC.pack "/v0/cutoff/1"
            , oscArgs = [OscArgFloat 0.0]
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
            command @?= CmdControlWrite (VoiceKey "v0") cutoffTag 0.0
            queued <- fanInQueuedOrFail enq
            qscCommand queued @?= command
          other ->
            assertFailure
              ("expected accept at zero-width range midpoint, got: "
                <> show other)
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

-- | Same cutoff tag as 'validPlan' but with @rangeMin == rangeMax == 0.0@.
-- Used to pin the inclusive-bound contract at the degenerate-but-legal
-- end (single-valued control).
zeroWidthPlan :: MR.ManifestReloadPlan
zeroWidthPlan = MR.ManifestReloadPlan
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
              0.0
          , MR.mcsRangeMin =
              0.0
          , MR.mcsRangeMax =
              0.0
          , MR.mcsSmoothingHz =
              30.0
          , MR.mcsCC =
              Nothing
          }
      ]
  , MR.mrlpArbitrationPolicy =
      FifoOnly
  }
