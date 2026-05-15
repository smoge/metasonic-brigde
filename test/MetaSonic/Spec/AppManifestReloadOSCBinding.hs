-- | App-level OSC ingress projection tests.
module MetaSonic.Spec.AppManifestReloadOSCBinding where

import qualified Data.Map.Strict                  as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestReloadOSCBinding
import           MetaSonic.Bridge.Source          (MigrationKey (..))
import           MetaSonic.Bridge.Templates       (TemplateGraph (..))
import           MetaSonic.Pattern                (ControlTag (..),
                                                   SwapLabel (..))
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy (..))
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.RTGraphAdapter (defaultRTGraphAdapterOptions)


appManifestReloadOSCBindingTests :: TestTree
appManifestReloadOSCBindingTests =
  testGroup "App manifest reload OSC binding projection"
  [ testCase "projection covers every manifest control tag in order" $ do
      let target = manifestOSCIngressTargetFromPlan validPlan
      map mocbControlTag (motControls target)
        @?= [cutoffTag, volTag]

  , testCase "demo key and arbitration policy carry through" $ do
      let target = manifestOSCIngressTargetFromPlan validPlan
      motDemoKey target @?= "demo"
      motArbitrationPolicy target @?= FifoOnly

  , testCase "known control validates and returns its binding" $ do
      let target = manifestOSCIngressTargetFromPlan validPlan
      case validateOSCControlTag cutoffTag target of
        Right binding -> do
          mocbControlTag binding @?= cutoffTag
          mocbDisplayName binding @?= "cutoff"
          mocbDefault binding @?= 1200.0
          mocbCC binding @?= Nothing
        Left issue ->
          assertFailure
            ("expected known control to validate, got: " <> show issue)

  , testCase "unknown control rejects with MoaiUnknownControl" $ do
      let target = manifestOSCIngressTargetFromPlan validPlan
      validateOSCControlTag staleTag target
        @?= Left (MoaiUnknownControl staleTag)

  , testCase "removed control is absent after reload to a smaller surface" $ do
      let trimmedPlan = validPlan
            { MR.mrlpControlSurface =
                [cutoffControl]
            }
          target = manifestOSCIngressTargetFromPlan trimmedPlan
      map mocbControlTag (motControls target) @?= [cutoffTag]
      validateOSCControlTag volTag target
        @?= Left (MoaiUnknownControl volTag)

  , testCase "address pattern reflects migration key and slot" $ do
      renderManifestOSCAddressPattern cutoffTag
        @?= "/<voice>/cutoff/1"
      renderManifestOSCAddressPattern volTag
        @?= "/<voice>/vol/1"
      renderManifestOSCAddressTail cutoffTag
        @?= "cutoff/1"
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

cutoffTag :: ControlTag
cutoffTag =
  ControlTag (MigrationKey "cutoff") 1

volTag :: ControlTag
volTag =
  ControlTag (MigrationKey "vol") 1

staleTag :: ControlTag
staleTag =
  ControlTag (MigrationKey "old") 0
