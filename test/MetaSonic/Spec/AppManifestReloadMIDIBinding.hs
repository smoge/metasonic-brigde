-- | App-level MIDI CC ingress projection tests.
module MetaSonic.Spec.AppManifestReloadMIDIBinding where

import qualified Data.Map.Strict                  as M
import           Data.Word                        (Word8)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestReloadMIDIBinding
import           MetaSonic.Bridge.Source          (MigrationKey (..))
import           MetaSonic.Bridge.Templates       (TemplateGraph (..))
import           MetaSonic.Pattern                (ControlTag (..),
                                                   SwapLabel (..),
                                                   VoiceKey (..))
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy (..))
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.RTGraphAdapter (defaultRTGraphAdapterOptions)


appManifestReloadMIDIBindingTests :: TestTree
appManifestReloadMIDIBindingTests =
  testGroup "App manifest reload MIDI binding projection"
  [ testCase "projection only carries controls with mcsCC = Just" $ do
      case manifestMIDIIngressTargetFromPlan defaultVoice validPlan of
        Right target ->
          map mmcbControlTag (mmitControls target) @?= [volTag]
        Left issue ->
          assertFailure
            ("expected projection to succeed, got: " <> show issue)

  , testCase "demo key, default voice, and arbitration policy carry through" $ do
      case manifestMIDIIngressTargetFromPlan defaultVoice validPlan of
        Right target -> do
          mmitDemoKey target @?= "demo"
          mmitDefaultVoice target @?= defaultVoice
          mmitArbitrationPolicy target @?= FifoOnly
        Left issue ->
          assertFailure
            ("expected projection to succeed, got: " <> show issue)

  , testCase "CC route table keys by mcsCC" $ do
      case manifestMIDIIngressTargetFromPlan defaultVoice validPlan of
        Right target ->
          M.keys (mmitCCRoutes target) @?= [volCC]
        Left issue ->
          assertFailure
            ("expected projection to succeed, got: " <> show issue)

  , testCase "known CC validates and returns its binding" $ do
      case manifestMIDIIngressTargetFromPlan defaultVoice validPlan of
        Right target ->
          case validateMIDICC volCC target of
            Right binding -> do
              mmcbControlTag binding @?= volTag
              mmcbDisplayName binding @?= "vol"
              mmcbCC binding @?= volCC
              mmcbRangeMin binding @?= 0.0
              mmcbRangeMax binding @?= 1.0
            Left issue ->
              assertFailure
                ("expected known CC to validate, got: " <> show issue)
        Left issue ->
          assertFailure
            ("expected projection to succeed, got: " <> show issue)

  , testCase "unknown CC rejects with MmaiUnknownCC" $ do
      case manifestMIDIIngressTargetFromPlan defaultVoice validPlan of
        Right target ->
          validateMIDICC 23 target
            @?= Left (MmaiUnknownCC 23)
        Left issue ->
          assertFailure
            ("expected projection to succeed, got: " <> show issue)

  , testCase "removed CC is absent after reload to a smaller surface" $ do
      let trimmedPlan = validPlan
            { MR.mrlpControlSurface =
                [cutoffControl]
            }
      case manifestMIDIIngressTargetFromPlan defaultVoice trimmedPlan of
        Right target -> do
          M.keys (mmitCCRoutes target) @?= []
          validateMIDICC volCC target
            @?= Left (MmaiUnknownCC volCC)
        Left issue ->
          assertFailure
            ("expected projection to succeed, got: " <> show issue)

  , testCase "CC remap drops the old CC and installs the new one" $ do
      let remappedPlan = validPlan
            { MR.mrlpControlSurface =
                [ cutoffControl
                , volControl { MR.mcsCC = Just 11 }
                ]
            }
      case manifestMIDIIngressTargetFromPlan defaultVoice remappedPlan of
        Right target -> do
          M.keys (mmitCCRoutes target) @?= [11]
          validateMIDICC volCC target
            @?= Left (MmaiUnknownCC volCC)
          case validateMIDICC 11 target of
            Right binding ->
              mmcbControlTag binding @?= volTag
            Left issue ->
              assertFailure
                ("expected remapped CC to validate, got: " <> show issue)
        Left issue ->
          assertFailure
            ("expected projection to succeed, got: " <> show issue)

  , testCase "duplicate CC numbers reject at projection" $ do
      let dupPlan = validPlan
            { MR.mrlpControlSurface =
                [ cutoffControl { MR.mcsCC = Just volCC }
                , volControl
                ]
            }
      case manifestMIDIIngressTargetFromPlan defaultVoice dupPlan of
        Left (MmpiDuplicateCC (cc, tags)) -> do
          cc @?= volCC
          tags @?= [cutoffTag, volTag]
        Right _ ->
          assertFailure
            "expected duplicate-CC projection to reject"
  ]

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
