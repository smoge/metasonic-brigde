-- | End-to-end MIDI packet-traffic tests across a real manifest reload.
--
-- Mirrors 'MetaSonic.Spec.AppManifestOSCReloadE2E' for the MIDI side.
-- Each test drives real @MIDIProducerControlChange@ events through the
-- manifest MIDI listener via 'manifestMIDIIngressOps' with a
-- @Chan@-backed source factory (so CI never needs a PortMIDI device),
-- runs @reloadManifestHostWithStrategy TryPreservingThenStoppedAudio@
-- through the real strategy selector, and asserts the close-old / open-
-- fresh contract under real traffic in two strategy modes:
--
-- * The fallback test runs against an empty-owner setup so the strategy
--   commits the stopped-audio fallback path; CC events before and after
--   the swap exercise the manifest projection on both listener
--   generations.
--
-- * The preserving test reuses the @hotSwapEdit@ /
--   @hotSwapEditAfterTemplates@ preserving-compatible graph pair,
--   installs a live voice before the reload, and asserts the
--   preserving path commits (@Right MrhsrPreserving@, no @AudioStop@
--   audio FFI event, voice survives, new graph installed) under the
--   same CC swap contract.

module MetaSonic.Spec.AppManifestMIDIReloadE2E where

import           Control.Concurrent.Chan          (Chan, newChan, readChan,
                                                   writeChan)
import           Control.Concurrent.MVar          (newEmptyMVar, putMVar,
                                                   takeMVar)
import           Control.Exception                (bracket_)
import           Control.Monad                    (void)
import           Data.IORef                       (IORef, modifyIORef',
                                                   newIORef, readIORef)
import qualified Data.Map.Strict                  as M
import qualified Data.Text                        as T
import           Data.Word                        (Word8)
import           System.Timeout                   (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestMIDIIngressOps
                                                  (ManifestMIDISourceFactory (..),
                                                   defaultManifestMIDIIngressOpsHooks,
                                                   manifestMIDIIngressOps)
import           MetaSonic.App.ManifestMIDIListener
                                                  (ManifestMIDIListenerHooks (..),
                                                   ManifestMIDIListenerIssue (..))
import           MetaSonic.App.ManifestReloadBinding
                                                  (ManifestUIVoiceSelection (..))
import           MetaSonic.App.ManifestReloadEvent
                                                  (noManifestReloadEvents)
import           MetaSonic.App.ManifestReloadHost
                                                  (ManifestReloadHostConfig (..),
                                                   ManifestReloadHostStrategy (..),
                                                   ManifestReloadHostStrategyRan (..),
                                                   reloadManifestHostWithStrategy)
import           MetaSonic.App.ManifestReloadIngress
                                                  (ManifestReloadIngressOps (..),
                                                   ManifestReloadIngressSnapshot (..),
                                                   closeManifestReloadIngress,
                                                   newManifestReloadIngressManager,
                                                   readManifestReloadIngressManager)
import           MetaSonic.App.ManifestReloadIngressTarget
                                                  (ManifestReloadIngressTargetPolicy (..),
                                                   manifestReloadIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadMIDIIngress
                                                  (ManifestMIDIIngressIssue (..))
import           MetaSonic.Authoring.Manifest     (AuthoringManifest (..),
                                                   AuthoringManifestDoc (..),
                                                   ManifestControl (..),
                                                   ManifestTemplate (..),
                                                   manifestSchemaVersion)
import           MetaSonic.Bridge.Source          (MigrationKey (..),
                                                   SynthGraph)
import           MetaSonic.Bridge.Templates       (TemplateGraph (..),
                                                   compileTemplateGraph)
import           MetaSonic.Pattern                (ControlTag (..),
                                                   SwapLabel (..),
                                                   TemplateName (..),
                                                   VoiceKey (..),
                                                   patternTemplates)
import           MetaSonic.Pattern.Corpus         (hotSwapEdit,
                                                   hotSwapEditAfterTemplates)
import           MetaSonic.Session.Command        (SessionCommand (..))
import           MetaSonic.Session.FanIn          (SessionFanInAudioFFI (..),
                                                   SessionFanInAudioOptions (..),
                                                   SessionFanInEnqueueResult (..),
                                                   SessionFanInSnapshot (..),
                                                   startSessionFanInHostAudioWith)
import           MetaSonic.Session.FanInService   (SessionFanInServiceHooks (..),
                                                   defaultSessionFanInServiceHooks,
                                                   defaultSessionFanInServiceOptions,
                                                   enqueueSessionFanInServiceCommand,
                                                   readSessionFanInService,
                                                   sessionFanInServiceHost,
                                                   withSessionFanInService,
                                                   withSessionFanInServiceHooks)
import           MetaSonic.Session.ManifestReload (ManifestReloadCatalogEntry (..),
                                                   ManifestReloadRequest (..),
                                                   defaultManifestResourcePolicy,
                                                   planManifestReload)
import           MetaSonic.Session.MIDIListener   (MIDIListenerSource (..))
import           MetaSonic.Session.MIDIProducer   (MIDIProducerEvent (..),
                                                   defaultMIDIProducerOptions)
import           MetaSonic.Session.Owner          (defaultSessionOwnerOptions)
import           MetaSonic.Session.Queue          (ProducerId (..),
                                                   ProducerKind (..),
                                                   QueuedSessionCommand (..),
                                                   SessionEnqueueResult (..))
import           MetaSonic.Session.State          (SessionState (..))


appManifestMIDIReloadE2ETests :: TestTree
appManifestMIDIReloadE2ETests =
  testGroup "App manifest MIDI reload end-to-end"
  [ testCase "TryPreservingThenStoppedAudio swaps manifest MIDI ingress under real traffic" $ do
      -- Empty-owner fallback variant: preserving fails for lack of
      -- live bindings, the strategy commits the stopped-audio
      -- fallback, and the CC swap contract holds on both
      -- generations.
      oldTarget <- projectFallbackTarget "demo-cc7"
      newTarget <- projectFallbackTarget "demo-cc11"

      acceptedMV <- newEmptyMVar
      issueMV    <- newEmptyMVar
      let listenerHooks = ManifestMIDIListenerHooks
            { mmlhOnAccepted =
                putMVar acceptedMV
            , mmlhOnIssue =
                putMVar issueMV
            }

      audioEventsRef <- newIORef []
      let audioFFI = capturingAudioFFI audioEventsRef
          audioOpts = SessionFanInAudioOptions
            { sfiaoOutputChannels = 2
            , sfiaoDeviceID       = -1
            , sfiaoReadyTimeoutMs = 100
            }

      svcResult <-
        withSessionFanInService
          (TemplateGraph [] M.empty)
          defaultSessionFanInServiceOptions
          $ \service -> do
              factoryState <- newSourceFactoryState
              let factory = chanSourceFactory factoryState
                  ops =
                    manifestMIDIIngressOps
                      listenerHooks
                      defaultManifestMIDIIngressOpsHooks
                      defaultMIDIProducerOptions
                      (sessionFanInServiceHost service)
                      factory

              initialOpened <- mrioOpenIngress ops oldTarget
              initialHandle <-
                case initialOpened of
                  Left issue ->
                    assertFailure
                      ("expected initial open, got: " <> show issue)
                    >> error "unreachable"
                  Right h ->
                    pure h

              -- Pre-reload: CC 7 accepts on the initial listener.
              writeFactoryEvent factoryState
                (Just (MIDIProducerControlChange 0 ccA 127))
              preReloadResult <-
                timeout 1000000 (takeMVar acceptedMV)

              ingressManager <-
                newManifestReloadIngressManager ops oldTarget initialHandle

              bracket_
                (startAudio audioFFI audioOpts service)
                (void (closeManifestReloadIngress ingressManager))
                (runFallbackScenario
                  ingressManager
                  oldTarget
                  newTarget
                  audioFFI
                  audioOpts
                  service
                  factoryState
                  acceptedMV
                  issueMV
                  preReloadResult)

      case svcResult of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right () ->
          pure ()

  , testCase "TryPreservingThenStoppedAudio preserves live voice and swaps MIDI ingress under real traffic" $ do
      -- Preserving variant: install a live voice on the
      -- hotSwapEdit graph before the reload, run the same strategy,
      -- assert it commits `Right MrhsrPreserving`, audio never
      -- stops, the voice survives, and the new graph is installed.
      -- The MIDI CC swap contract is unchanged.
      oldTarget <- projectPreservingTarget "preserve-cc7"
      newTarget <- projectPreservingTarget "preserve-cc11"

      acceptedMV <- newEmptyMVar
      issueMV    <- newEmptyMVar
      let listenerHooks = ManifestMIDIListenerHooks
            { mmlhOnAccepted =
                putMVar acceptedMV
            , mmlhOnIssue =
                putMVar issueMV
            }

      audioEventsRef <- newIORef []
      drainCh        <- newChan
      let audioFFI = capturingAudioFFI audioEventsRef
          audioOpts = SessionFanInAudioOptions
            { sfiaoOutputChannels = 2
            , sfiaoDeviceID       = -1
            , sfiaoReadyTimeoutMs = 100
            }
          serviceHooks = defaultSessionFanInServiceHooks
            { sfshOnDrain =
                writeChan drainCh
            }

      svcResult <-
        withSessionFanInServiceHooks
          serviceHooks
          (mrcTemplateGraph preservingOldEntry)
          defaultSessionFanInServiceOptions
          $ \service -> do
              factoryState <- newSourceFactoryState
              let factory = chanSourceFactory factoryState
                  ops =
                    manifestMIDIIngressOps
                      listenerHooks
                      defaultManifestMIDIIngressOpsHooks
                      defaultMIDIProducerOptions
                      (sessionFanInServiceHost service)
                      factory

              initialOpened <- mrioOpenIngress ops oldTarget
              initialHandle <-
                case initialOpened of
                  Left issue ->
                    assertFailure
                      ("expected initial open, got: " <> show issue)
                    >> error "unreachable"
                  Right h ->
                    pure h

              ingressManager <-
                newManifestReloadIngressManager ops oldTarget initialHandle

              bracket_
                (startAudio audioFFI audioOpts service)
                (void (closeManifestReloadIngress ingressManager))
                (runPreservingScenario
                  ingressManager
                  oldTarget
                  newTarget
                  audioFFI
                  audioOpts
                  service
                  factoryState
                  drainCh
                  audioEventsRef
                  acceptedMV
                  issueMV)

      case svcResult of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right () ->
          pure ()
  ]
  where
    startAudio audioFFI audioOpts service = do
      started <-
        startSessionFanInHostAudioWith
          audioFFI
          (sessionFanInServiceHost service)
          audioOpts
      case started of
        Left issue ->
          assertFailure
            ("expected fake audio start, got: " <> show issue)
        Right () ->
          pure ()

    runFallbackScenario ingressManager oldTarget newTarget audioFFI
        audioOpts service factoryState acceptedMV issueMV preReloadResult = do
      case preReloadResult of
        Just enq ->
          assertEnqueuedCommand
            "pre-reload cutoff accepted"
            (CmdControlWrite defaultVoice cutoffTag 1.0)
            enq
        Nothing ->
          assertFailure
            "timed out waiting for pre-reload CC acceptance"

      let request = ManifestReloadRequest
            { mrrDemoKey =
                "demo-cc11"
            , mrrSwapLabel =
                SwapLabel "demo-cc11"
            , mrrResourcePolicy =
                defaultManifestResourcePolicy
            }
          config = ManifestReloadHostConfig
            { mrhcService =
                service
            , mrhcIngressManager =
                ingressManager
            , mrhcOldIngressTarget =
                oldTarget
            , mrhcNewIngressTarget =
                newTarget
            , mrhcAudioFFI =
                audioFFI
            , mrhcAudioOptions =
                audioOpts
            , mrhcOwnerOptions =
                defaultSessionOwnerOptions
            , mrhcOnEvent =
                noManifestReloadEvents
            }

      outcome <-
        reloadManifestHostWithStrategy
          midiE2EProducerId
          TryPreservingThenStoppedAudio
          config
          fallbackManifestDoc
          fallbackCatalog
          request

      case outcome of
        Right (MrhsrStoppedAudioAfterPreservingRejected _) ->
          pure ()
        other ->
          assertFailure
            ("expected MrhsrStoppedAudioAfterPreservingRejected, got: "
             <> show other)

      reloadSnapshot <- readManifestReloadIngressManager ingressManager
      case reloadSnapshot of
        MrisOpen _ _ ->
          pure ()
        MrisClosed ->
          assertFailure
            "expected ingress open after stopped-audio swap"

      -- Post-reload: old CC rejects, new CC accepts.
      writeFactoryEvent factoryState
        (Just (MIDIProducerControlChange 0 ccA 127))
      postOldResult <- timeout 1000000 (takeMVar issueMV)
      case postOldResult of
        Just (MmliIngressIssue (MmiiAddressIssue _)) ->
          pure ()
        other ->
          assertFailure
            ("expected post-reload old-CC rejection, got: "
             <> show other)

      writeFactoryEvent factoryState
        (Just (MIDIProducerControlChange 0 ccB 127))
      postNewResult <- timeout 1000000 (takeMVar acceptedMV)
      case postNewResult of
        Just enq ->
          assertEnqueuedCommand
            "post-reload new CC accepted"
            (CmdControlWrite defaultVoice volTag 1.0)
            enq
        Nothing ->
          assertFailure
            "timed out waiting for post-reload CC acceptance"

    runPreservingScenario ingressManager oldTarget newTarget audioFFI
        audioOpts service factoryState drainCh audioEventsRef
        acceptedMV issueMV = do
      -- Install live voice on the old graph.
      voiceEnq <-
        enqueueSessionFanInServiceCommand
          preservingVoiceProducer
          preservingVoiceOnCommand
          service
      case sfierResult voiceEnq of
        SessionEnqueued _ ->
          pure ()
        other ->
          assertFailure
            ("expected voice-on enqueued, got: " <> show other)
      firstDrain <- timeout 1000000 (readChan drainCh)
      case firstDrain of
        Nothing ->
          assertFailure
            "timed out waiting for preserving voice-start drain"
        Just _ ->
          pure ()
      snapshotPreReload <- readSessionFanInService service
      assertBool
        "expected preserving voice live before reload"
        (M.member preservingVoiceKey
          (ssVoices (sfisOwnerState snapshotPreReload)))

      -- Pre-reload: old CC accepts on initial listener.
      writeFactoryEvent factoryState
        (Just (MIDIProducerControlChange 0 ccA 127))
      preReloadResult <- timeout 1000000 (takeMVar acceptedMV)
      case preReloadResult of
        Just enq ->
          assertEnqueuedCommand
            "pre-reload CC accepted"
            (CmdControlWrite defaultVoice cutoffTag 1.0)
            enq
        Nothing ->
          assertFailure
            "timed out waiting for pre-reload CC acceptance"

      let request = ManifestReloadRequest
            { mrrDemoKey =
                "preserve-cc11"
            , mrrSwapLabel =
                SwapLabel "preserve-cc11"
            , mrrResourcePolicy =
                defaultManifestResourcePolicy
            }
          config = ManifestReloadHostConfig
            { mrhcService =
                service
            , mrhcIngressManager =
                ingressManager
            , mrhcOldIngressTarget =
                oldTarget
            , mrhcNewIngressTarget =
                newTarget
            , mrhcAudioFFI =
                audioFFI
            , mrhcAudioOptions =
                audioOpts
            , mrhcOwnerOptions =
                defaultSessionOwnerOptions
            , mrhcOnEvent =
                noManifestReloadEvents
            }
      outcome <-
        reloadManifestHostWithStrategy
          midiE2EProducerId
          TryPreservingThenStoppedAudio
          config
          preservingManifestDoc
          preservingCatalog
          request
      outcome @?= Right MrhsrPreserving

      audioEvents <- readIORef audioEventsRef
      assertBool
        ("expected no AudioStop during preserving reload, got: "
         <> show audioEvents)
        (AudioStop `notElem` audioEvents)
      snapshotPostReload <- readSessionFanInService service
      sfisAudioRunning snapshotPostReload @?= True
      assertBool
        "expected live voice to survive preserving reload"
        (M.member preservingVoiceKey
          (ssVoices (sfisOwnerState snapshotPostReload)))
      ssGraph (sfisOwnerState snapshotPostReload)
        @?= mrcTemplateGraph preservingNewEntry

      reloadSnapshot <- readManifestReloadIngressManager ingressManager
      case reloadSnapshot of
        MrisOpen _ _ ->
          pure ()
        MrisClosed ->
          assertFailure
            "expected ingress open after preserving reload"

      writeFactoryEvent factoryState
        (Just (MIDIProducerControlChange 0 ccA 127))
      postOldResult <- timeout 1000000 (takeMVar issueMV)
      case postOldResult of
        Just (MmliIngressIssue (MmiiAddressIssue _)) ->
          pure ()
        other ->
          assertFailure
            ("expected post-reload old-CC rejection, got: "
             <> show other)

      writeFactoryEvent factoryState
        (Just (MIDIProducerControlChange 0 ccB 127))
      postNewResult <- timeout 1000000 (takeMVar acceptedMV)
      case postNewResult of
        Just enq ->
          assertEnqueuedCommand
            "post-reload new CC accepted"
            (CmdControlWrite defaultVoice volTag 1.0)
            enq
        Nothing ->
          assertFailure
            "timed out waiting for post-reload CC acceptance"

    -- Plan + target projection helpers.

    projectFallbackTarget demoKey =
      projectTarget fallbackManifestDoc fallbackCatalog demoKey

    projectPreservingTarget demoKey =
      projectTarget preservingManifestDoc preservingCatalog demoKey

    projectTarget doc catalog demoKey =
      case planManifestReload doc catalog (planRequestFor demoKey) of
        Left issue ->
          assertFailure
            ("expected plan for " <> demoKey <> ", got: " <> show issue)
          >> error "unreachable"
        Right plan ->
          case manifestReloadIngressTargetFromPlan policy plan of
            Left issue ->
              assertFailure
                ("expected target for " <> demoKey
                 <> ", got: " <> show issue)
              >> error "unreachable"
            Right target ->
              pure target

    planRequestFor demoKey = ManifestReloadRequest
      { mrrDemoKey =
          demoKey
      , mrrSwapLabel =
          SwapLabel demoKey
      , mrrResourcePolicy =
          defaultManifestResourcePolicy
      }

    policy = ManifestReloadIngressTargetPolicy
      { mritpUIVoiceSelection =
          ManifestUIVoiceSelection
            { muvsFocusedVoice =
                Nothing
            , muvsDefaultVoice =
                VoiceKey "v0"
            }
      , mritpUIRetainedValues =
          M.empty
      , mritpMIDIDefaultVoice =
          defaultVoice
      }

------------------------------------------------------------
-- Chan-backed source factory
------------------------------------------------------------

-- | Mutable state behind the test factory: a shared event channel
-- between successive listener generations and counters used for
-- assertions where relevant.
data SourceFactoryState = SourceFactoryState
  { factoryStateEvents :: !(Chan (Maybe MIDIProducerEvent))
  , factoryStateOpens  :: !(IORef Int)
  , factoryStateCloses :: !(IORef Int)
  }

newSourceFactoryState :: IO SourceFactoryState
newSourceFactoryState = do
  ch <- newChan
  opens <- newIORef 0
  closes <- newIORef 0
  pure SourceFactoryState
    { factoryStateEvents =
        ch
    , factoryStateOpens =
        opens
    , factoryStateCloses =
        closes
    }

writeFactoryEvent
  :: SourceFactoryState
  -> Maybe MIDIProducerEvent
  -> IO ()
writeFactoryEvent state =
  writeChan (factoryStateEvents state)

chanSourceFactory
  :: SourceFactoryState
  -> ManifestMIDISourceFactory String ()
chanSourceFactory state = ManifestMIDISourceFactory
  { mmsfOpenSource = do
      modifyIORef' (factoryStateOpens state) (+ 1)
      let listenerSource =
            MIDIListenerSource (readChan (factoryStateEvents state))
      pure (Right ((), listenerSource))
  , mmsfCloseSource = \() -> do
      modifyIORef' (factoryStateCloses state) (+ 1)
      pure (Right ())
  }

------------------------------------------------------------
-- Audio FFI capture
------------------------------------------------------------

-- | Tagged audio FFI events so the preserving test can assert that
-- 'AudioStop' never fired.
data AudioEvent
  = AudioStart
  | AudioReady
  | AudioStop
  deriving (Eq, Show)

capturingAudioFFI :: IORef [AudioEvent] -> SessionFanInAudioFFI
capturingAudioFFI ref = SessionFanInAudioFFI
  { saffiStartAudio =
      \_rt _channels _deviceID -> do
        modifyIORef' ref (<> [AudioStart])
        pure 0
  , saffiWaitAudioStarted =
      \_rt _timeoutMs -> do
        modifyIORef' ref (<> [AudioReady])
        pure True
  , saffiStopAudio =
      \_rt ->
        modifyIORef' ref (<> [AudioStop])
  , saffiStopAudioFade =
      \_rt _fadeMs ->
        modifyIORef' ref (<> [AudioStop])
  }

------------------------------------------------------------
-- Manifest fixtures
------------------------------------------------------------

-- | Fallback fixtures: empty template graph on both sides so
-- preserving has nothing to migrate. Old manifest binds CC 7 to a
-- "cutoff" tag; new manifest binds CC 11 to a "vol" tag.
fallbackManifestDoc :: AuthoringManifestDoc
fallbackManifestDoc = AuthoringManifestDoc
  { docSchemaVersion =
      manifestSchemaVersion
  , docDemos =
      [ noTemplateManifest "demo-cc7"  ccAControl
      , noTemplateManifest "demo-cc11" ccBControl
      ]
  }

fallbackCatalog :: [ManifestReloadCatalogEntry]
fallbackCatalog =
  [ ManifestReloadCatalogEntry
      { mrcDemoKey =
          "demo-cc7"
      , mrcManifest =
          noTemplateManifest "demo-cc7" ccAControl
      , mrcTemplateGraph =
          TemplateGraph [] M.empty
      }
  , ManifestReloadCatalogEntry
      { mrcDemoKey =
          "demo-cc11"
      , mrcManifest =
          noTemplateManifest "demo-cc11" ccBControl
      , mrcTemplateGraph =
          TemplateGraph [] M.empty
      }
  ]

noTemplateManifest :: String -> ManifestControl -> AuthoringManifest
noTemplateManifest key control = AuthoringManifest
  { mfDemoKey =
      key
  , mfTemplates =
      []
  , mfBuses =
      []
  , mfControls =
      [control]
  }

-- | Preserving fixtures: reuse the existing hotSwapEdit /
-- hotSwapEditAfterTemplates graph pair from the host fixture so a
-- live "drone" voice can migrate. Manifest controls keep disjoint
-- CC bindings so the MIDI swap is observable.
preservingManifestDoc :: AuthoringManifestDoc
preservingManifestDoc = AuthoringManifestDoc
  { docSchemaVersion =
      manifestSchemaVersion
  , docDemos =
      [ preservingDroneManifest "preserve-cc7"  ccAControl
      , preservingDroneManifest "preserve-cc11" ccBControl
      ]
  }

preservingCatalog :: [ManifestReloadCatalogEntry]
preservingCatalog =
  [preservingOldEntry, preservingNewEntry]

preservingOldEntry :: ManifestReloadCatalogEntry
preservingOldEntry = ManifestReloadCatalogEntry
  { mrcDemoKey =
      "preserve-cc7"
  , mrcManifest =
      preservingDroneManifest "preserve-cc7" ccAControl
  , mrcTemplateGraph =
      patternTemplates hotSwapEdit
  }

preservingNewEntry :: ManifestReloadCatalogEntry
preservingNewEntry = ManifestReloadCatalogEntry
  { mrcDemoKey =
      "preserve-cc11"
  , mrcManifest =
      preservingDroneManifest "preserve-cc11" ccBControl
  , mrcTemplateGraph =
      compileTemplateGraphOrError hotSwapEditAfterTemplates
  }

preservingDroneManifest :: String -> ManifestControl -> AuthoringManifest
preservingDroneManifest key control = AuthoringManifest
  { mfDemoKey =
      key
  , mfTemplates =
      [ManifestTemplate "drone" "voice"]
  , mfBuses =
      []
  , mfControls =
      [control]
  }

compileTemplateGraphOrError :: [(String, SynthGraph)] -> TemplateGraph
compileTemplateGraphOrError rows =
  case compileTemplateGraph rows of
    Right graph ->
      graph
    Left err ->
      error ("compileTemplateGraph failed: " <> err)

------------------------------------------------------------
-- Per-test fixtures
------------------------------------------------------------

ccAControl :: ManifestControl
ccAControl = ManifestControl
  { mcName        =
      "cutoff"
  , mcDefault     =
      1200.0
  , mcRangeMin    =
      0.0
  , mcRangeMax    =
      1.0
  , mcSmoothingHz =
      30.0
  , mcCC          =
      Just ccA
  , mcKey         =
      "cutoff"
  , mcSlot        =
      0
  }

ccBControl :: ManifestControl
ccBControl = ManifestControl
  { mcName        =
      "vol"
  , mcDefault     =
      0.3
  , mcRangeMin    =
      0.0
  , mcRangeMax    =
      1.0
  , mcSmoothingHz =
      30.0
  , mcCC          =
      Just ccB
  , mcKey         =
      "vol"
  , mcSlot        =
      0
  }

cutoffTag :: ControlTag
cutoffTag = ControlTag (MigrationKey "cutoff") 0

volTag :: ControlTag
volTag = ControlTag (MigrationKey "vol") 0

ccA :: Word8
ccA = 7

ccB :: Word8
ccB = 11

defaultVoice :: VoiceKey
defaultVoice = VoiceKey "fx"

preservingVoiceKey :: VoiceKey
preservingVoiceKey = VoiceKey "v0"

preservingVoiceOnCommand :: SessionCommand
preservingVoiceOnCommand =
  CmdVoiceOn
    (TemplateName "drone")
    preservingVoiceKey
    [(ControlTag (MigrationKey "lpf") 0, 1500.0)]

preservingVoiceProducer :: ProducerId
preservingVoiceProducer =
  ProducerId ProducerPattern (T.pack "preserving-voice")

midiE2EProducerId :: ProducerId
midiE2EProducerId =
  ProducerId ProducerMIDI (T.pack "manifest-midi-reload-e2e")

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

assertEnqueuedCommand
  :: String
  -> SessionCommand
  -> SessionFanInEnqueueResult
  -> Assertion
assertEnqueuedCommand label expected enq =
  case sfierResult enq of
    SessionEnqueued queued ->
      qscCommand queued @?= expected
    other ->
      assertFailure
        (label <> ": expected enqueued, got: " <> show other)
