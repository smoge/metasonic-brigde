-- | App-level manifest-target-aware MIDI listener tests.
--
-- The listener is exercised over a test-only 'MIDIListenerSource'
-- backed by a 'Chan (Maybe MIDIProducerEvent)' so CI never depends on
-- a real PortMIDI device. The PortMIDI-backed source is exercised by
-- a separate device-dependent suite.
module MetaSonic.Spec.AppManifestMIDIListener where

import           Control.Concurrent.Chan          (Chan, newChan, readChan,
                                                   writeChan)
import           Control.Concurrent.MVar          (newEmptyMVar, putMVar,
                                                   takeMVar)
import qualified Data.Map.Strict                  as M
import qualified Data.Text                        as T
import           Data.Word                        (Word8)
import           System.Timeout                   (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestMIDIListener
import           MetaSonic.App.ManifestReloadMIDIBinding
                                                  (ManifestMIDIIngressTarget,
                                                   manifestMIDIIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadMIDIIngress
                                                  (ManifestMIDIIngressIssue (..))
import           MetaSonic.Bridge.Source          (MigrationKey (..))
import           MetaSonic.Bridge.Templates       (TemplateGraph (..))
import           MetaSonic.Pattern                (ControlTag (..),
                                                   SwapLabel (..),
                                                   VoiceKey (..))
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy (..))
import           MetaSonic.Session.Command        (SessionCommand (..))
import           MetaSonic.Session.FanIn          (SessionFanInEnqueueResult (..),
                                                   SessionFanInOptions (..),
                                                   SessionFanInSnapshot (..),
                                                   defaultSessionFanInOptions,
                                                   enqueueSessionFanInCommand,
                                                   readSessionFanInHost,
                                                   withSessionFanInHost)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.MIDIListener   (MIDIListenerSource (..))
import           MetaSonic.Session.MIDIProducer   (MIDIProducerEvent (..),
                                                   defaultMIDIProducerOptions)
import           MetaSonic.Session.Queue          (ProducerId (..),
                                                   ProducerKind (..),
                                                   QueuedSessionCommand (..),
                                                   SessionEnqueueIssue (..),
                                                   SessionEnqueueResult (..),
                                                   SessionQueueOptions (..))
import           MetaSonic.Session.RTGraphAdapter (defaultRTGraphAdapterOptions)


appManifestMIDIListenerTests :: TestTree
appManifestMIDIListenerTests =
  testGroup "App manifest MIDI listener"
  [ testCase "bound CC event forwards a scaled CmdControlWrite" $ do
      let target = projectOrFail validPlan
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              acceptedMV <- newEmptyMVar
              issueMV    <- newEmptyMVar
              let hooks = ManifestMIDIListenerHooks
                    { mmlhOnAccepted =
                        putMVar acceptedMV
                    , mmlhOnIssue =
                        putMVar issueMV
                    }
              ch <- newChan
              writeChan ch (Just (MIDIProducerControlChange 0 volCC 127))
              writeChan ch Nothing
              withManifestMIDIListener
                hooks
                defaultMIDIProducerOptions
                target
                host
                (chanSource ch)
                (do
                  outcome <- timeout 1000000 (takeMVar acceptedMV)
                  snapshot <- readSessionFanInHost host
                  pure (outcome, snapshot))
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just enq, snapshot) -> do
          case sfierResult enq of
            SessionEnqueued queued ->
              qscCommand queued
                @?= CmdControlWrite defaultVoice volTag 1.0
            other ->
              assertFailure ("expected enqueued, got: " <> show other)
          sfisQueueDepth snapshot @?= 1
        Right (other, _) ->
          assertFailure ("expected accepted event, got: " <> show other)

  , testCase "unbound CC event rejects at the manifest layer and queue stays empty" $ do
      let target = projectOrFail validPlan
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              issueMV <- newEmptyMVar
              let hooks = ManifestMIDIListenerHooks
                    { mmlhOnAccepted =
                        \_ -> pure ()
                    , mmlhOnIssue =
                        putMVar issueMV
                    }
              ch <- newChan
              writeChan ch (Just (MIDIProducerControlChange 0 23 64))
              writeChan ch Nothing
              withManifestMIDIListener
                hooks
                defaultMIDIProducerOptions
                target
                host
                (chanSource ch)
                (do
                  outcome <- timeout 1000000 (takeMVar issueMV)
                  snapshot <- readSessionFanInHost host
                  pure (outcome, snapshot))
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MmliIngressIssue (MmiiAddressIssue _)), snapshot) ->
          sfisQueueDepth snapshot @?= 0
        Right other ->
          assertFailure
            ("expected manifest address rejection, got: " <> show other)

  , testCase "non-CC events are ignored with an MmliIgnoredEvent diagnostic" $ do
      let target = projectOrFail validPlan
          noteOn = MIDIProducerNoteOn 0 60 100
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              issueMV <- newEmptyMVar
              let hooks = ManifestMIDIListenerHooks
                    { mmlhOnAccepted =
                        \_ -> pure ()
                    , mmlhOnIssue =
                        putMVar issueMV
                    }
              ch <- newChan
              writeChan ch (Just noteOn)
              writeChan ch Nothing
              withManifestMIDIListener
                hooks
                defaultMIDIProducerOptions
                target
                host
                (chanSource ch)
                (do
                  outcome <- timeout 1000000 (takeMVar issueMV)
                  snapshot <- readSessionFanInHost host
                  pure (outcome, snapshot))
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MmliIgnoredEvent ignored), snapshot) -> do
          ignored @?= noteOn
          sfisQueueDepth snapshot @?= 0
        Right other ->
          assertFailure
            ("expected ignored-event diagnostic, got: " <> show other)

  , testCase "open/close handle is idempotent and tears down the worker" $ do
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              let target = projectOrFail validPlan
              ch <- newChan
              handle <-
                openManifestMIDIListener
                  defaultManifestMIDIListenerHooks
                  defaultMIDIProducerOptions
                  target
                  host
                  (chanSource ch)
              closeManifestMIDIListener handle
              -- A second close is a no-op.
              closeManifestMIDIListener handle
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right () ->
          pure ()

  , testCase "queue-full fan-in rejection surfaces as MmliEnqueueRejected" $ do
      -- Pre-fill a capacity-1 fan-in queue, then drive a bound CC
      -- event through the listener. The CC validates against the
      -- manifest projection, the producer attempts to enqueue, and
      -- the fan-in queue refuses with SeiQueueFull; the listener
      -- surfaces that as MmliEnqueueRejected on the issue hook.
      let target = projectOrFail validPlan
          expectedCmd = CmdControlWrite defaultVoice volTag 1.0
          smallQueue = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          prefillCmd = CmdVoiceOff (VoiceKey "prefill")
          prefillProducer =
            ProducerId ProducerTest (T.pack "prefill")
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          smallQueue
          $ \host -> do
              _prefill <-
                enqueueSessionFanInCommand prefillProducer prefillCmd host
              issueMV <- newEmptyMVar
              let hooks = ManifestMIDIListenerHooks
                    { mmlhOnAccepted =
                        \_ -> pure ()
                    , mmlhOnIssue =
                        putMVar issueMV
                    }
              ch <- newChan
              writeChan ch (Just (MIDIProducerControlChange 0 volCC 127))
              writeChan ch Nothing
              withManifestMIDIListener
                hooks
                defaultMIDIProducerOptions
                target
                host
                (chanSource ch)
                (timeout 1000000 (takeMVar issueMV))
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MmliEnqueueRejected cmd (SeiQueueFull cap))) -> do
          cmd @?= expectedCmd
          cap @?= 1
        Right other ->
          assertFailure
            ("expected MmliEnqueueRejected with SeiQueueFull, got: "
             <> show other)

  , testCase "reopen with a different target changes the accepted CC set" $ do
      let firstTarget = projectOrFail validPlan
          secondTarget = projectOrFail volRemappedPlan
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              acceptedMV <- newEmptyMVar
              issueMV    <- newEmptyMVar
              let hooks = ManifestMIDIListenerHooks
                    { mmlhOnAccepted =
                        putMVar acceptedMV
                    , mmlhOnIssue =
                        putMVar issueMV
                    }

              -- First listener: vol on CC 7 accepts; CC 11 rejects.
              ch1 <- newChan
              writeChan ch1 (Just (MIDIProducerControlChange 0 volCC 127))
              firstAccepted <-
                withManifestMIDIListener
                  hooks
                  defaultMIDIProducerOptions
                  firstTarget
                  host
                  (chanSource ch1)
                  (timeout 1000000 (takeMVar acceptedMV))

              -- Second listener (new target): vol remapped to CC 11;
              -- CC 7 now rejects, CC 11 accepts.
              ch2 <- newChan
              writeChan ch2 (Just (MIDIProducerControlChange 0 volCC 127))
              writeChan ch2 (Just (MIDIProducerControlChange 0 11 127))
              (oldRejected, secondAccepted) <-
                withManifestMIDIListener
                  hooks
                  defaultMIDIProducerOptions
                  secondTarget
                  host
                  (chanSource ch2)
                  (do
                    rejection <- timeout 1000000 (takeMVar issueMV)
                    accepted <- timeout 1000000 (takeMVar acceptedMV)
                    pure (rejection, accepted))

              pure (firstAccepted, oldRejected, secondAccepted)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right
          ( Just firstEnq
          , Just (MmliIngressIssue (MmiiAddressIssue _))
          , Just secondEnq
          ) -> do
            case sfierResult firstEnq of
              SessionEnqueued q ->
                qscCommand q
                  @?= CmdControlWrite defaultVoice volTag 1.0
              other ->
                assertFailure ("expected first enqueued, got: " <> show other)
            case sfierResult secondEnq of
              SessionEnqueued q ->
                qscCommand q
                  @?= CmdControlWrite defaultVoice volTag 1.0
              other ->
                assertFailure ("expected second enqueued, got: " <> show other)
        Right other ->
          assertFailure
            ("expected first-accept/old-reject/new-accept, got: "
             <> show other)
  ]

-- | Wrap a 'Chan (Maybe MIDIProducerEvent)' as a 'MIDIListenerSource'.
-- A 'Nothing' value drives the listener loop to natural end-of-input;
-- 'Just' values are forwarded to the per-event processor.
chanSource :: Chan (Maybe MIDIProducerEvent) -> MIDIListenerSource
chanSource ch =
  MIDIListenerSource (readChan ch)

projectOrFail :: MR.ManifestReloadPlan -> ManifestMIDIIngressTarget
projectOrFail plan =
  case manifestMIDIIngressTargetFromPlan defaultVoice plan of
    Right target ->
      target
    Left issue ->
      error ("test setup: MIDI projection failed: " <> show issue)

validPlan :: MR.ManifestReloadPlan
validPlan = manifestPlanWith [cutoffControl, volControl]

volRemappedPlan :: MR.ManifestReloadPlan
volRemappedPlan = manifestPlanWith
  [ cutoffControl
  , volControl { MR.mcsCC = Just 11 }
  ]

manifestPlanWith :: [MR.ManifestControlSurface] -> MR.ManifestReloadPlan
manifestPlanWith controls = MR.ManifestReloadPlan
  { MR.mrlpDemoKey =
      "demo"
  , MR.mrlpSwapLabel =
      SwapLabel "reload"
  , MR.mrlpTemplateGraph =
      TemplateGraph [] M.empty
  , MR.mrlpAdapterOptions =
      defaultRTGraphAdapterOptions
  , MR.mrlpControlSurface =
      controls
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
  ControlTag (MigrationKey "cutoff") 0

volTag :: ControlTag
volTag =
  ControlTag (MigrationKey "vol") 0

volCC :: Word8
volCC =
  7

defaultVoice :: VoiceKey
defaultVoice =
  VoiceKey "fx"
