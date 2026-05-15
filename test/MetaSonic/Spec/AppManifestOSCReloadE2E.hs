-- | End-to-end packet-traffic test for device-backed OSC ingress
-- across a real manifest reload strategy run.
--
-- This module combines four landed pieces: the manifest-target-aware UDP
-- listener (`MetaSonic.App.ManifestOSCListener`), the ingress-ops
-- adapter (`MetaSonic.App.ManifestOSCIngressOps`), the host strategy
-- selector (`reloadManifestHostWithStrategy`), and the fan-in
-- service. It proves the close-old/open-fresh contract under real
-- traffic in two strategy modes:
--
-- * The fallback test runs `TryPreservingThenStoppedAudio` against an
--   empty-owner setup so the strategy commits the stopped-audio
--   fallback path; OSC packets before and after the swap exercise the
--   manifest projection on both listeners.
--
-- * The preserving test installs a live voice on the
--   `hotSwapEdit` / `hotSwapEditAfterTemplates` graph pair before the
--   reload, runs the same strategy, and asserts the preserving path
--   commits (`Right MrhsrPreserving`, no `AudioStop`, voice survives,
--   new graph installed) under the same OSC swap contract.
module MetaSonic.Spec.AppManifestOSCReloadE2E where

import           Control.Concurrent.Chan          (Chan, newChan, readChan,
                                                   writeChan)
import           Control.Concurrent.MVar          (newEmptyMVar, putMVar,
                                                   takeMVar)
import           Control.Exception                (bracket_)
import           Control.Monad                    (void)
import qualified Data.ByteString.Char8            as OBSC
import           Data.IORef                       (IORef, modifyIORef',
                                                   newIORef, readIORef)
import qualified Data.Map.Strict                  as M
import qualified Data.Text                        as T
import           System.Timeout                   (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestOSCIngressOps
                                                  (ManifestOSCIngressHandle (..),
                                                   manifestOSCIngressOps)
import           MetaSonic.App.ManifestOSCListener
                                                  (ListenerInfo (..),
                                                   ManifestOSCListenerHooks (..),
                                                   ManifestOSCListenerIssue (..),
                                                   defaultListenerConfig)
import           MetaSonic.App.ManifestReloadBinding
                                                  (ManifestUIVoiceSelection (..))
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
                                                  (ManifestReloadIngressTarget,
                                                   ManifestReloadIngressTargetPolicy (..),
                                                   manifestReloadIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadOSCIngress
                                                  (ManifestOSCIngressIssue (..))
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
import           MetaSonic.Session.OSCProducer    (OSCProducerEnqueueResult (..),
                                                   defaultOSCProducerOptions)
import           MetaSonic.Session.Owner          (defaultSessionOwnerOptions)
import           MetaSonic.Session.Queue          (ProducerId (..),
                                                   ProducerKind (..),
                                                   SessionEnqueueResult (..))
import           MetaSonic.Session.State          (SessionState (..))
import           MetaSonic.Spec.Core              (sendUdpLoopback)


appManifestOSCReloadE2ETests :: TestTree
appManifestOSCReloadE2ETests =
  testGroup "App manifest OSC reload end-to-end"
  [ testCase "TryPreservingThenStoppedAudio swaps device-backed OSC ingress under real traffic" $ do
      oldTarget <- projectOrFail "demo-cutoff"
      newTarget <- projectOrFail "demo-vol"

      acceptedMV <- newEmptyMVar
      issueMV    <- newEmptyMVar
      let hooks = ManifestOSCListenerHooks
            { molhOnAccepted =
                putMVar acceptedMV
            , molhOnIssue =
                putMVar issueMV
            }

      let audioFFI = fakeAudioFFI
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
              let ops =
                    manifestOSCIngressOps
                      hooks
                      defaultOSCProducerOptions
                      (sessionFanInServiceHost service)
                      (defaultListenerConfig 0)

              -- Open initial OSC ingress against the old target.
              initialOpened <- mrioOpenIngress ops oldTarget
              initialHandle <-
                case initialOpened of
                  Left issue ->
                    assertFailure
                      ("expected initial open, got: " <> show issue)
                    >> error "unreachable"
                  Right h ->
                    pure h
              let initialPort = liBoundPort (moihInfo initialHandle)

              -- Pre-reload: send cutoff packet, expect acceptance.
              sendUdpLoopback initialPort cutoffPacket
              preReloadResult <- timeout 1000000 (takeMVar acceptedMV)

              ingressManager <-
                newManifestReloadIngressManager ops oldTarget initialHandle

              -- Bracket the strategy run so the ingress manager is
              -- always closed before the test asserts. Without this
              -- the post-reload UDP socket would leak across tests.
              bracket_
                (startAudio audioFFI audioOpts service)
                (void (closeManifestReloadIngress ingressManager))
                (runStrategyAndAssertSwap
                  ingressManager
                  oldTarget
                  newTarget
                  audioFFI
                  audioOpts
                  service
                  acceptedMV
                  issueMV
                  preReloadResult)

      case svcResult of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right () ->
          pure ()

  , testCase "TryPreservingThenStoppedAudio preserves live voice and swaps OSC ingress under real traffic" $ do
      -- Preserving variant: install a live voice on the old graph
      -- BEFORE reload, run TryPreservingThenStoppedAudio, assert the
      -- preserving path commits (no stopped-audio fallback), the
      -- voice survives, audio never stops, and old/new OSC paths
      -- swap correctly. Reuses the preserving-compatible graph pair
      -- from the existing AppManifestReloadHost fixture
      -- (`hotSwapEdit` / `hotSwapEditAfterTemplates`).
      oldTarget <- projectPreservingTargetOrFail "preserve-cutoff"
      newTarget <- projectPreservingTargetOrFail "preserve-vol"

      acceptedMV <- newEmptyMVar
      issueMV    <- newEmptyMVar
      let hooks = ManifestOSCListenerHooks
            { molhOnAccepted =
                putMVar acceptedMV
            , molhOnIssue =
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
              let ops =
                    manifestOSCIngressOps
                      hooks
                      defaultOSCProducerOptions
                      (sessionFanInServiceHost service)
                      (defaultListenerConfig 0)

              initialOpened <- mrioOpenIngress ops oldTarget
              initialHandle <-
                case initialOpened of
                  Left issue ->
                    assertFailure
                      ("expected initial open, got: " <> show issue)
                    >> error "unreachable"
                  Right h ->
                    pure h
              let initialPort = liBoundPort (moihInfo initialHandle)

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
                  drainCh
                  audioEventsRef
                  acceptedMV
                  issueMV
                  initialPort)

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

    runStrategyAndAssertSwap ingressManager oldTarget newTarget audioFFI
        audioOpts service acceptedMV issueMV preReloadResult = do
      case preReloadResult of
        Just (OSCProducerEnqueueAttempted _cmd _) ->
          pure ()
        other ->
          assertFailure
            ("expected pre-reload cutoff accepted, got: "
             <> show other)

      let request = ManifestReloadRequest
            { mrrDemoKey =
                "demo-vol"
            , mrrSwapLabel =
                SwapLabel "demo-vol"
            , mrrResourcePolicy =
                defaultManifestResourcePolicy
            }
          config = ManifestReloadHostConfig
            { mrhcService =
                service
            , mrhcIngressManager =
                ingressManager
            , mrhcOldIngressTarget =
                -- The stopped-audio fallback path this test exercises
                -- never resumes through the old target, but the config
                -- stays semantically correct so a future strategy
                -- change that takes the retryable branch won't pick
                -- up a stale fixture.
                oldTarget
            , mrhcNewIngressTarget =
                newTarget
            , mrhcAudioFFI =
                audioFFI
            , mrhcAudioOptions =
                audioOpts
            , mrhcOwnerOptions =
                defaultSessionOwnerOptions
            }

      outcome <-
        reloadManifestHostWithStrategy
          (ProducerId ProducerOSC (T.pack "manifest-osc-reload-e2e"))
          TryPreservingThenStoppedAudio
          config
          manifestDoc
          testCatalog
          request

      case outcome of
        Right (MrhsrStoppedAudioAfterPreservingRejected _) ->
          pure ()
        other ->
          assertFailure
            ("expected MrhsrStoppedAudioAfterPreservingRejected, got: "
             <> show other)

      snapshot <- readManifestReloadIngressManager ingressManager
      (_target', handle') <-
        case snapshot of
          MrisOpen t h ->
            pure (t, h)
          MrisClosed ->
            assertFailure
              "expected ingress open after stopped-audio swap"
            >> error "unreachable"
      let newPort = liBoundPort (moihInfo handle')

      -- Post-reload, old path → new listener: manifest rejection.
      sendUdpLoopback newPort cutoffPacket
      postOldResult <- timeout 1000000 (takeMVar issueMV)
      case postOldResult of
        Just (MoliManifestIssue (MoiiAddressIssue _)) ->
          pure ()
        other ->
          assertFailure
            ("expected post-reload cutoff rejection, got: "
             <> show other)

      -- Post-reload, new path → new listener: accepted.
      sendUdpLoopback newPort volPacket
      postNewResult <- timeout 1000000 (takeMVar acceptedMV)
      case postNewResult of
        Just (OSCProducerEnqueueAttempted _cmd _) ->
          pure ()
        other ->
          assertFailure
            ("expected post-reload vol accepted, got: " <> show other)

    -- Lookup helper.
    projectOrFail demoKey =
      case planManifestReload manifestDoc testCatalog
             (planRequestFor demoKey) of
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

    -- Lookup helper for the preserving catalog.
    projectPreservingTargetOrFail demoKey =
      case planManifestReload preservingManifestDoc preservingCatalog
             (planRequestFor demoKey) of
        Left issue ->
          assertFailure
            ("expected preserving plan for " <> demoKey
             <> ", got: " <> show issue)
          >> error "unreachable"
        Right plan ->
          case manifestReloadIngressTargetFromPlan policy plan of
            Left issue ->
              assertFailure
                ("expected preserving target for " <> demoKey
                 <> ", got: " <> show issue)
              >> error "unreachable"
            Right target ->
              pure target

    runPreservingScenario ingressManager oldTarget newTarget audioFFI
        audioOpts service drainCh audioEventsRef acceptedMV issueMV
        initialPort = do
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

      -- Pre-reload: old OSC path accepts on initial listener.
      sendUdpLoopback initialPort cutoffPacket
      preReloadResult <- timeout 1000000 (takeMVar acceptedMV)
      case preReloadResult of
        Just (OSCProducerEnqueueAttempted _cmd _) ->
          pure ()
        other ->
          assertFailure
            ("expected pre-reload cutoff accepted, got: "
             <> show other)

      -- Run the preserving strategy.
      let request = ManifestReloadRequest
            { mrrDemoKey =
                "preserve-vol"
            , mrrSwapLabel =
                SwapLabel "preserve-vol"
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
            }
      outcome <-
        reloadManifestHostWithStrategy
          (ProducerId ProducerUI
            (T.pack "manifest-osc-reload-e2e-preserve"))
          TryPreservingThenStoppedAudio
          config
          preservingManifestDoc
          preservingCatalog
          request
      outcome @?= Right MrhsrPreserving

      -- The strategy committed preserving — assert audio kept
      -- running across the swap (no AudioStop fired) and the live
      -- voice survived.
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

      -- Read the fresh ingress snapshot and exercise post-reload
      -- traffic: old path rejects, new path accepts.
      reloadSnapshot <- readManifestReloadIngressManager ingressManager
      handle' <-
        case reloadSnapshot of
          MrisOpen _ h ->
            pure h
          MrisClosed ->
            assertFailure
              "expected ingress open after preserving reload"
            >> error "unreachable"
      let newPort = liBoundPort (moihInfo handle')

      sendUdpLoopback newPort cutoffPacket
      postOldResult <- timeout 1000000 (takeMVar issueMV)
      case postOldResult of
        Just (MoliManifestIssue (MoiiAddressIssue _)) ->
          pure ()
        other ->
          assertFailure
            ("expected post-reload cutoff rejection, got: "
             <> show other)

      sendUdpLoopback newPort volPacket
      postNewResult <- timeout 1000000 (takeMVar acceptedMV)
      case postNewResult of
        Just (OSCProducerEnqueueAttempted _cmd _) ->
          pure ()
        other ->
          assertFailure
            ("expected post-reload vol accepted, got: " <> show other)

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
          VoiceKey "fx"
      }

-- | Two-entry catalog with disjoint control surfaces: one demo carries
-- a "cutoff" control, the other carries a "vol" control.
testCatalog :: [ManifestReloadCatalogEntry]
testCatalog =
  [ ManifestReloadCatalogEntry
      { mrcDemoKey =
          "demo-cutoff"
      , mrcManifest =
          cutoffManifest
      , mrcTemplateGraph =
          TemplateGraph [] M.empty
      }
  , ManifestReloadCatalogEntry
      { mrcDemoKey =
          "demo-vol"
      , mrcManifest =
          volManifest
      , mrcTemplateGraph =
          TemplateGraph [] M.empty
      }
  ]

manifestDoc :: AuthoringManifestDoc
manifestDoc = AuthoringManifestDoc
  { docSchemaVersion =
      manifestSchemaVersion
  , docDemos =
      [cutoffManifest, volManifest]
  }

cutoffManifest :: AuthoringManifest
cutoffManifest = AuthoringManifest
  { mfDemoKey   =
      "demo-cutoff"
  , mfTemplates =
      []
  , mfBuses     =
      []
  , mfControls  =
      [cutoffControl]
  }

volManifest :: AuthoringManifest
volManifest = AuthoringManifest
  { mfDemoKey   =
      "demo-vol"
  , mfTemplates =
      []
  , mfBuses     =
      []
  , mfControls  =
      [volControl]
  }

cutoffControl :: ManifestControl
cutoffControl = ManifestControl
  { mcName        =
      "cutoff"
  , mcDefault     =
      1200.0
  , mcRangeMin    =
      200.0
  , mcRangeMax    =
      8000.0
  , mcSmoothingHz =
      30.0
  , mcCC          =
      Nothing
  , mcKey         =
      "cutoff"
  , mcSlot        =
      0
  }

volControl :: ManifestControl
volControl = ManifestControl
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
      Nothing
  , mcKey         =
      "vol"
  , mcSlot        =
      0
  }

cutoffPacket :: OBSC.ByteString
cutoffPacket = oscMessageBytes "/v0/cutoff/0"

volPacket :: OBSC.ByteString
volPacket = oscMessageBytes "/v0/vol/0"

oscMessageBytes :: String -> OBSC.ByteString
oscMessageBytes addr = OBSC.concat
  [ oscString (OBSC.pack addr)
  , oscString (OBSC.pack ",f")
  , floatBytes1500
  ]

oscString :: OBSC.ByteString -> OBSC.ByteString
oscString s =
  let n   = OBSC.length s
      pad = (4 - ((n + 1) `mod` 4)) `mod` 4
  in s `OBSC.append` OBSC.replicate (1 + pad) '\NUL'

floatBytes1500 :: OBSC.ByteString
floatBytes1500 = OBSC.pack ['\x44', '\xBB', '\x80', '\NUL']

fakeAudioFFI :: SessionFanInAudioFFI
fakeAudioFFI = SessionFanInAudioFFI
  { saffiStartAudio =
      \_rt _channels _deviceID -> pure 0
  , saffiWaitAudioStarted =
      \_rt _timeoutMs -> pure True
  , saffiStopAudio =
      \_rt -> pure ()
  }

-- | Tagged audio FFI events captured during the preserving test so
-- assertions can confirm @AudioStop@ never fired.
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
  }

-- | Preserving catalog reuses the existing hot-swap fixture pair so
-- the new graph can migrate the live voice from the old graph. Both
-- entries declare the @drone@ template the voice targets.
preservingCatalog :: [ManifestReloadCatalogEntry]
preservingCatalog =
  [preservingOldEntry, preservingNewEntry]

preservingManifestDoc :: AuthoringManifestDoc
preservingManifestDoc = AuthoringManifestDoc
  { docSchemaVersion =
      manifestSchemaVersion
  , docDemos =
      [ preservingDroneManifest "preserve-cutoff" cutoffControl
      , preservingDroneManifest "preserve-vol"    volControl
      ]
  }

preservingOldEntry :: ManifestReloadCatalogEntry
preservingOldEntry = ManifestReloadCatalogEntry
  { mrcDemoKey =
      "preserve-cutoff"
  , mrcManifest =
      preservingDroneManifest "preserve-cutoff" cutoffControl
  , mrcTemplateGraph =
      patternTemplates hotSwapEdit
  }

preservingNewEntry :: ManifestReloadCatalogEntry
preservingNewEntry = ManifestReloadCatalogEntry
  { mrcDemoKey =
      "preserve-vol"
  , mrcManifest =
      preservingDroneManifest "preserve-vol" volControl
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

preservingVoiceKey :: VoiceKey
preservingVoiceKey =
  VoiceKey "v0"

preservingVoiceOnCommand :: SessionCommand
preservingVoiceOnCommand =
  CmdVoiceOn
    (TemplateName "drone")
    preservingVoiceKey
    [(ControlTag (MigrationKey "lpf") 0, 1500.0)]

preservingVoiceProducer :: ProducerId
preservingVoiceProducer =
  ProducerId ProducerPattern (T.pack "preserving-voice")
