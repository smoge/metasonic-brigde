-- | App-level combined manifest ingress target projection tests.
module MetaSonic.Spec.AppManifestReloadIngressTarget where

import qualified Data.Map.Strict                  as M
import           Data.Word                        (Word8)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestReloadBinding
                                                  (ManifestUIControlValueSource (..),
                                                   ManifestUIVoiceSelection (..),
                                                   muicControlTag,
                                                   muicCurrent,
                                                   muicValueSource,
                                                   muitControls,
                                                   muitDemoKey)
import           MetaSonic.App.ManifestReloadIngressTarget
import           MetaSonic.App.ManifestReloadMIDIBinding
                                                  (ManifestMIDIProjectionIssue (..),
                                                   mmcbControlTag,
                                                   mmitControls,
                                                   mmitDefaultVoice,
                                                   mmitDemoKey)
import           MetaSonic.App.ManifestReloadOSCBinding
                                                  (mocbControlTag,
                                                   motControls,
                                                   motDemoKey)
import           MetaSonic.Bridge.Source          (MigrationKey (..))
import           MetaSonic.Bridge.Templates       (TemplateGraph (..))
import           MetaSonic.Pattern                (ControlTag (..),
                                                   SwapLabel (..),
                                                   VoiceKey (..))
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy (..))
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.RTGraphAdapter (defaultRTGraphAdapterOptions)


appManifestReloadIngressTargetTests :: TestTree
appManifestReloadIngressTargetTests =
  testGroup "App manifest reload combined ingress target"
  [ testCase "bundle carries UI, OSC, and MIDI projections from one plan" $ do
      case manifestReloadIngressTargetFromPlan defaultPolicy validPlan of
        Right target -> do
          muitDemoKey (mitUI target) @?= "demo"
          motDemoKey (mitOSC target) @?= "demo"
          mmitDemoKey (mitMIDI target) @?= "demo"
          map muicControlTag (muitControls (mitUI target))
            @?= [cutoffTag, volTag]
          map mocbControlTag (motControls (mitOSC target))
            @?= [cutoffTag, volTag]
          map mmcbControlTag (mmitControls (mitMIDI target))
            @?= [volTag]
          mmitDefaultVoice (mitMIDI target) @?= midiDefaultVoice
        Left issue ->
          assertFailure
            ("expected combined target to project, got: " <> show issue)

  , testCase "MIDI duplicate CC blocks combined target construction" $ do
      let dupPlan = validPlan
            { MR.mrlpControlSurface =
                [ cutoffControl { MR.mcsCC = Just volCC }
                , volControl
                ]
            }
      case manifestReloadIngressTargetFromPlan defaultPolicy dupPlan of
        Left (MmpiDuplicateCC (cc, tags)) -> do
          cc @?= volCC
          tags @?= [cutoffTag, volTag]
        Right _ ->
          assertFailure
            "expected duplicate-CC plan to fail combined target construction"

  , testCase "reload to a smaller surface drops controls from every projection" $ do
      let trimmedPlan = validPlan
            { MR.mrlpControlSurface =
                [cutoffControl]
            }
      case manifestReloadIngressTargetFromPlan defaultPolicy trimmedPlan of
        Right target -> do
          map muicControlTag (muitControls (mitUI target))
            @?= [cutoffTag]
          map mocbControlTag (motControls (mitOSC target))
            @?= [cutoffTag]
          map mmcbControlTag (mmitControls (mitMIDI target))
            @?= []
        Left issue ->
          assertFailure
            ("expected trimmed plan to project, got: " <> show issue)

  , testCase "UI retain map carries through to the bundled UI projection" $ do
      let retainedPolicy = defaultPolicy
            { mritpUIRetainedValues =
                M.fromList [(cutoffTag, 2400.0)]
            }
      case manifestReloadIngressTargetFromPlan retainedPolicy validPlan of
        Right target ->
          case filter ((cutoffTag ==) . muicControlTag)
                      (muitControls (mitUI target)) of
            binding : _ -> do
              muicCurrent binding @?= 2400.0
              muicValueSource binding @?= MuicRetainedValue
            [] ->
              assertFailure "expected cutoff binding in bundled UI projection"
        Left issue ->
          assertFailure
            ("expected retained-projection to succeed, got: " <> show issue)
  ]

defaultPolicy :: ManifestReloadIngressTargetPolicy
defaultPolicy = ManifestReloadIngressTargetPolicy
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
      midiDefaultVoice
  }

midiDefaultVoice :: VoiceKey
midiDefaultVoice =
  VoiceKey "fx"

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
