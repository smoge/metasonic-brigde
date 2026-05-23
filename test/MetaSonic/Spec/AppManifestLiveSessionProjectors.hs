{-# LANGUAGE OverloadedStrings #-}

-- | Pin the Phase 8h step 3c per-route initial-open ingress
-- projectors used by 'runSupervised' to surface MIDI startup
-- failures through 'renderLiveProdIngressIssue'.
--
-- Each projector matches a single shape — its route's outer
-- wrapper plus the inner 'RhsoiIngressOpenFailed' — and returns
-- 'Nothing' for everything else so unrelated startup failures
-- (audio start, partial cleanup, in-window reload) keep their
-- existing supervisor causeLabel path.
module MetaSonic.Spec.AppManifestLiveSessionProjectors
  ( appManifestLiveSessionProjectorsTests
  ) where

import           Test.Tasty       (TestTree, testGroup)
import           Test.Tasty.HUnit (testCase, (@?=))

import           MetaSonic.App.ManifestLiveIngressOps
                                                  (LiveIngressIssue (..),
                                                   LiveProdIngressIssue)
import           MetaSonic.App.ManifestLiveSession
                                                  (projectPreservingInitialIngressFailure,
                                                   projectStoppedAudioInitialIngressFailure,
                                                   projectTryPreservingInitialIngressFailure)
import           MetaSonic.App.ManifestMIDIIngressOps
                                                  (ManifestMIDIIngressOpsIssue (..))
import           MetaSonic.App.ManifestMIDIPortMIDI
                                                  (ManifestMIDIPortMIDIError (..))
import           MetaSonic.App.ManifestOSCIngressOps
                                                  (ManifestOSCIngressOpsIssue (..))
import           MetaSonic.App.ManifestOSCListener
                                                  (ManifestOSCListenerOpenIssue (..))
import           MetaSonic.App.ManifestReloadHostStack
                                                  (ReloadHostStackOpenIssue (..),
                                                   StoppedAudioHostStackIssue (..))
import           MetaSonic.App.ManifestReloadMIDIBinding
                                                  (ManifestMIDIProjectionIssue (..))
import           MetaSonic.App.ManifestReloadPreservingHostStack
                                                  (PreservingHostStackIssue (..))
import           MetaSonic.App.ManifestReloadTryPreservingHostStack
                                                  (TryPreservingHostStackIssue (..))


appManifestLiveSessionProjectorsTests :: TestTree
appManifestLiveSessionProjectorsTests =
  testGroup "App manifest live-session initial-open ingress projectors (Phase 8h step 3c)"
  [ testGroup "StoppedAudio route"  stoppedAudioTests
  , testGroup "Preserving route"    preservingTests
  , testGroup "TryPreserving route" tryPreservingTests
  ]


-- ---------------------------------------------------------------------------
-- StoppedAudio
-- ---------------------------------------------------------------------------

stoppedAudioTests :: [TestTree]
stoppedAudioTests =
  [ testCase "SahsiOpen (RhsoiIngressOpenFailed midi) → Just (LiiMIDI ...)" $
      projectStoppedAudioInitialIngressFailure
        (SahsiOpen (RhsoiIngressOpenFailed sampleMIDIIssue))
        @?= Just sampleMIDIIssue

  , testCase "SahsiOpen (RhsoiIngressOpenFailed osc) → Just (LiiOSC ...)" $
      projectStoppedAudioInitialIngressFailure
        (SahsiOpen (RhsoiIngressOpenFailed sampleOSCIssue))
        @?= Just sampleOSCIssue

  , testCase "SahsiOpen (RhsoiIngressTargetProjectionFailed _) → Nothing (route-other arm)" $
      projectStoppedAudioInitialIngressFailure
        (SahsiOpen (RhsoiIngressTargetProjectionFailed sampleProjectionIssue))
        @?= Nothing
  ]


-- ---------------------------------------------------------------------------
-- Preserving
-- ---------------------------------------------------------------------------

preservingTests :: [TestTree]
preservingTests =
  [ testCase "PahsiOpen (RhsoiIngressOpenFailed midi) → Just (LiiMIDI ...)" $
      projectPreservingInitialIngressFailure
        (PahsiOpen (RhsoiIngressOpenFailed sampleMIDIIssue))
        @?= Just sampleMIDIIssue

  , testCase "PahsiOpen (RhsoiIngressOpenFailed osc) → Just (LiiOSC ...)" $
      projectPreservingInitialIngressFailure
        (PahsiOpen (RhsoiIngressOpenFailed sampleOSCIssue))
        @?= Just sampleOSCIssue

  , testCase "PahsiOpen (RhsoiIngressTargetProjectionFailed _) → Nothing (route-other arm)" $
      projectPreservingInitialIngressFailure
        (PahsiOpen (RhsoiIngressTargetProjectionFailed sampleProjectionIssue))
        @?= Nothing
  ]


-- ---------------------------------------------------------------------------
-- TryPreserving
-- ---------------------------------------------------------------------------

tryPreservingTests :: [TestTree]
tryPreservingTests =
  [ testCase "TpahsiOpen (RhsoiIngressOpenFailed midi) → Just (LiiMIDI ...)" $
      projectTryPreservingInitialIngressFailure
        (TpahsiOpen (RhsoiIngressOpenFailed sampleMIDIIssue))
        @?= Just sampleMIDIIssue

  , testCase "TpahsiOpen (RhsoiIngressOpenFailed osc) → Just (LiiOSC ...)" $
      projectTryPreservingInitialIngressFailure
        (TpahsiOpen (RhsoiIngressOpenFailed sampleOSCIssue))
        @?= Just sampleOSCIssue

  , testCase "TpahsiOpen (RhsoiIngressTargetProjectionFailed _) → Nothing (route-other arm)" $
      projectTryPreservingInitialIngressFailure
        (TpahsiOpen (RhsoiIngressTargetProjectionFailed sampleProjectionIssue))
        @?= Nothing
  ]


-- ---------------------------------------------------------------------------
-- Sample LiveProdIngressIssue values
-- ---------------------------------------------------------------------------

-- | Stand-in for the operator-visible MIDI startup failure.
-- Composing this projector result with 'renderLiveProdIngressIssue'
-- (pinned in 'AppManifestLiveIngressOps' step 6a) yields the
-- @"no input device for --midi-device N"@ operator string.
sampleMIDIIssue :: LiveProdIngressIssue
sampleMIDIIssue =
  LiiMIDI (MmioiSourceOpenFailed MmppNoInputDevice)


sampleOSCIssue :: LiveProdIngressIssue
sampleOSCIssue =
  LiiOSC (MoioiOpenFailed (MoloiBindFailed "bind failure"))


-- | A non-Open arm of 'ReloadHostStackOpenIssue' used in the
-- "route-other" projector tests. The projector must return
-- 'Nothing' on this so the supervisor's existing causeLabel path
-- renders MIDI projection failures unchanged.
sampleProjectionIssue :: ManifestMIDIProjectionIssue
sampleProjectionIssue =
  MmpiDuplicateCC (74, [])
