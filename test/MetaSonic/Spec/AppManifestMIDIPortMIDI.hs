-- | CI-safe tests for the PortMIDI-backed manifest MIDI source factory.
--
-- The deterministic surface tested here is the @hasDevice == False@
-- branch: an invalid PortMIDI device id produces a valid source handle
-- whose 'portMIDISourceHasDevice' returns 'False', so the factory must
-- close the idle handle and report 'MmppNoInputDevice'. The
-- 'Nothing'-open branch is exercised by the upstream PortMIDI test
-- suite and not by the factory layer.
--
-- A device-active success path is not in scope here; that's a manual
-- device-backed smoke after this slice.
module MetaSonic.Spec.AppManifestMIDIPortMIDI where

import qualified Data.Map.Strict                  as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestMIDIIngressOps
                                                  (ManifestMIDIIngressOpsIssue (..),
                                                   ManifestMIDISourceFactory (..),
                                                   defaultManifestMIDIIngressOpsHooks,
                                                   manifestMIDIIngressOps)
import           MetaSonic.App.ManifestMIDIListener
                                                  (defaultManifestMIDIListenerHooks)
import           MetaSonic.App.ManifestMIDIPortMIDI
                                                  (ManifestMIDIPortMIDIError (..),
                                                   manifestPortMIDISourceFactory)
import           MetaSonic.App.ManifestReloadBinding
                                                  (ManifestUIVoiceSelection (..))
import           MetaSonic.App.ManifestReloadIngress
                                                  (ManifestReloadIngressOps (..))
import           MetaSonic.App.ManifestReloadIngressTarget
                                                  (ManifestReloadIngressTarget,
                                                   ManifestReloadIngressTargetPolicy (..),
                                                   manifestReloadIngressTargetFromPlan)
import           MetaSonic.Bridge.Source          (MigrationKey (..))
import           MetaSonic.Bridge.Templates       (TemplateGraph (..))
import           MetaSonic.Pattern                (ControlTag (..),
                                                   SwapLabel (..),
                                                   VoiceKey (..))
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy (..))
import           MetaSonic.Session.FanIn          (defaultSessionFanInOptions,
                                                   withSessionFanInHost)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.MIDIPortMIDI   (PortMIDISourceOptions (..),
                                                   defaultPortMIDISourceOptions)
import           MetaSonic.Session.MIDIProducer   (defaultMIDIProducerOptions)
import           MetaSonic.Session.RTGraphAdapter (defaultRTGraphAdapterOptions)


appManifestMIDIPortMIDITests :: TestTree
appManifestMIDIPortMIDITests =
  testGroup "App manifest MIDI PortMIDI source factory"
  [ testCase "invalid device id surfaces NoInputDevice from the factory" $ do
      let factory = manifestPortMIDISourceFactory invalidPortMIDIOptions
      result <- mmsfOpenSource factory
      case result of
        Left MmppNoInputDevice ->
          pure ()
        Left other ->
          assertFailure
            ("expected NoInputDevice, got: " <> show other)
        Right _ ->
          assertFailure
            "expected NoInputDevice, got: a usable PortMIDI source\
            \ (PortMIDISource has no Show instance)"

  , testCase "factory composes with manifestMIDIIngressOps and surfaces MmioiSourceOpenFailed NoInputDevice" $ do
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              let factory =
                    manifestPortMIDISourceFactory invalidPortMIDIOptions
                  ops =
                    manifestMIDIIngressOps
                      defaultManifestMIDIListenerHooks
                      defaultManifestMIDIIngressOpsHooks
                      defaultMIDIProducerOptions
                      host
                      factory
              mrioOpenIngress ops (projectOrFail validPlan)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Left (MmioiSourceOpenFailed MmppNoInputDevice)) ->
          pure ()
        Right (Left other) ->
          assertFailure
            ("expected MmioiSourceOpenFailed NoInputDevice, got: "
             <> show other)
        Right (Right _) ->
          assertFailure
            "expected MmioiSourceOpenFailed NoInputDevice, got: a\
            \ usable ManifestMIDIIngressHandle\
            \ (PortMIDISource has no Show instance)"
  ]

invalidPortMIDIOptions :: PortMIDISourceOptions
invalidPortMIDIOptions = defaultPortMIDISourceOptions
  { pmsoDeviceId =
      Just 2147483647
  , pmsoPollDelayUsec =
      1000
  }

projectOrFail
  :: MR.ManifestReloadPlan
  -> ManifestReloadIngressTarget
projectOrFail plan =
  case manifestReloadIngressTargetFromPlan policy plan of
    Right target ->
      target
    Left issue ->
      error ("test setup: combined target projection failed: " <> show issue)

policy :: ManifestReloadIngressTargetPolicy
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
              "vol"
          , MR.mcsControlTag =
              ControlTag (MigrationKey "vol") 0
          , MR.mcsDefault =
              0.3
          , MR.mcsRangeMin =
              0.0
          , MR.mcsRangeMax =
              1.0
          , MR.mcsSmoothingHz =
              30.0
          , MR.mcsCC =
              Just 7
          }
      ]
  , MR.mrlpArbitrationPolicy =
      FifoOnly
  }
