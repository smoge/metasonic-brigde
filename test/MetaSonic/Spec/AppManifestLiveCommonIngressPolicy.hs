-- | Pins the constants in 'MetaSonic.App.ManifestLiveCommon.liveIngressTargetPolicy'.
--
-- The MIDI default voice is the load-bearing one: live MIDI ingress
-- enqueues 'CmdControlWrite' under this voice, and @values@ only
-- renders rows for voices the live stack has actually spawned.
-- 'autoStartTemplates' in 'ManifestLiveCommon' keeps the literal
-- voice 'fx' for a template named 'fx' and assigns 'v<index>' to
-- every other non-'fx' template, so 'v0' matches the first non-'fx'
-- auto-spawn slot of every demo built today (including saw/noise's
-- @drone@ template). See Phase 8h step 3c design note for the
-- default-voice rationale and the corner-case caveat for demos
-- whose only template is literally named 'fx'.
module MetaSonic.Spec.AppManifestLiveCommonIngressPolicy
  ( appManifestLiveCommonIngressPolicyTests
  ) where

import           Test.Tasty       (TestTree, testGroup)
import           Test.Tasty.HUnit (testCase, (@?=))

import           MetaSonic.App.ManifestLiveCommon
                                                  (liveIngressTargetPolicy)
import           MetaSonic.App.ManifestReloadBinding
                                                  (ManifestUIVoiceSelection (..))
import           MetaSonic.App.ManifestReloadIngressTarget
                                                  (ManifestReloadIngressTargetPolicy (..))
import           MetaSonic.Pattern                (VoiceKey (..))


appManifestLiveCommonIngressPolicyTests :: TestTree
appManifestLiveCommonIngressPolicyTests =
  testGroup "App manifest live common: ingress target policy"
  [ testCase "MIDI default voice is v0 (matches auto-start non-fx slot)" $
      mritpMIDIDefaultVoice liveIngressTargetPolicy @?= VoiceKey "v0"

  , testCase "UI default voice is v0" $
      muvsDefaultVoice (mritpUIVoiceSelection liveIngressTargetPolicy)
        @?= VoiceKey "v0"

  , testCase "UI focused voice is unset (no operator-pinned focus by default)" $
      muvsFocusedVoice (mritpUIVoiceSelection liveIngressTargetPolicy)
        @?= Nothing
  ]
