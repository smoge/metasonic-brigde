-- | App-level manifest reload ingress binding projection tests.
module MetaSonic.Spec.AppManifestReloadBinding where

import qualified Data.Map.Strict                  as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestReloadBinding
import           MetaSonic.Bridge.Source          (MigrationKey (..))
import           MetaSonic.Bridge.Templates       (TemplateGraph (..))
import           MetaSonic.Pattern                (ControlTag (..),
                                                   SwapLabel (..),
                                                   VoiceKey (..))
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy (..))
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.RTGraphAdapter (defaultRTGraphAdapterOptions)


appManifestReloadBindingTests :: TestTree
appManifestReloadBindingTests =
  testGroup "App manifest reload binding projection"
  [ testCase "surviving control tags retain last-written values" $ do
      let target =
            manifestUIIngressTargetFromPlan
              voiceSelection
              (M.fromList [(cutoffTag, 2400.0)])
              validPlan
      case muitControls target of
        cutoffBinding : _ -> do
          muicControlTag cutoffBinding @?= cutoffTag
          muicCurrent cutoffBinding @?= 2400.0
          muicValueSource cutoffBinding @?= MuicRetainedValue
        other ->
          assertFailure ("expected at least one binding, got: " <> show other)

  , testCase "new controls use manifest defaults" $ do
      let target =
            manifestUIIngressTargetFromPlan
              voiceSelection
              M.empty
              validPlan
      case muitControls target of
        cutoffBinding : volBinding : _ -> do
          muicCurrent cutoffBinding @?= 1200.0
          muicValueSource cutoffBinding @?= MuicManifestDefault
          muicControlTag volBinding @?= volTag
          muicCurrent volBinding @?= 0.3
          muicValueSource volBinding @?= MuicManifestDefault
        other ->
          assertFailure ("expected two bindings, got: " <> show other)

  , testCase "removed controls are absent from the target" $ do
      let target =
            manifestUIIngressTargetFromPlan
              voiceSelection
              (M.fromList [(staleTag, 99.0)])
              validPlan
      map muicControlTag (muitControls target)
        @?= [cutoffTag, volTag]

  , testCase "voice-selection policy is carried unchanged" $ do
      let target =
            manifestUIIngressTargetFromPlan
              voiceSelection
              M.empty
              validPlan
      muitVoiceSelection target @?= voiceSelection

  , testCase "arbitration policy is carried as the target policy" $ do
      let target =
            manifestUIIngressTargetFromPlan
              voiceSelection
              M.empty
              validPlan
      muitArbitrationPolicy target @?= FifoOnly

  , testCase "retained values remain visible through ingress target plumbing" $ do
      let target =
            manifestUIIngressTargetFromPlan
              voiceSelection
              (M.fromList [(volTag, 0.75)])
              validPlan
      case drop 1 (muitControls target) of
        volBinding : _ -> do
          muicDisplayName volBinding @?= "vol"
          muicCurrent volBinding @?= 0.75
          muicValueSource volBinding @?= MuicRetainedValue
        other ->
          assertFailure ("expected second binding, got: " <> show other)
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
      Just 7
  }

voiceSelection :: ManifestUIVoiceSelection
voiceSelection = ManifestUIVoiceSelection
  { muvsFocusedVoice =
      Just (VoiceKey "v1")
  , muvsDefaultVoice =
      VoiceKey "fx0"
  }

cutoffTag :: ControlTag
cutoffTag =
  ControlTag (MigrationKey "cutoff") 1

volTag :: ControlTag
volTag =
  ControlTag (MigrationKey "vol") 1

staleTag :: ControlTag
staleTag =
  ControlTag (MigrationKey "old") 0
