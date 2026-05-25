-- | Deterministic coverage for the retired-binding renderer in
-- "MetaSonic.App.ManifestLiveCommon".
--
-- Phase 8h step 3e v1 slice 2: 'renderRetiredBindings' is the pure
-- operator-string contract for the @retired bindings:@ block. It
-- pairs with 'retiredBindingsFromEvents' which scans the reload-
-- event timeline for the commit event's payload.
--
-- The renderer has three policy branches:
--
--   * empty list → @(none)@
--   * non-empty, all 'RvrOwnerReplaced' → single
--     @all NN voices retired by owner replacement@ summary
--     (stopped-audio always retires every pre-reload binding)
--   * otherwise → one bullet per binding, with voice key,
--     template, and rendered reason
--
-- Stale-by-reload attribution (slice 3) consumes the same
-- 'retiredBindingsFromEvents' projection.
module MetaSonic.Spec.AppManifestLiveCommonRetiredBindings
  ( appManifestLiveCommonRetiredBindingsTests
  ) where

import qualified Data.ByteString.Char8                  as OBSC

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestLiveCommon       (renderRetiredBindings,
                                                         renderRetiredVoiceReason,
                                                         retiredBindingsFromEvents)
import           MetaSonic.App.ManifestReloadEvent      (ManifestReloadEvent (..))
import           MetaSonic.App.ManifestReloadOrchestration
                                                        (HostPreservingReloadIssue (..))
import qualified MetaSonic.OSC.Dispatch                 as OSC
import           MetaSonic.Pattern                      (TemplateName (..),
                                                         VoiceKey (..))
import           MetaSonic.Session.Resolve              (RetiredVoiceBinding (..),
                                                         RetiredVoiceReason (..),
                                                         VoiceBinding (..))


appManifestLiveCommonRetiredBindingsTests :: TestTree
appManifestLiveCommonRetiredBindingsTests =
  testGroup "App manifest live common: retired bindings renderer"
  [ testGroup "renderRetiredVoiceReason"
      [ testCase "RvrTemplateGone renders as 'template-gone'" $
          renderRetiredVoiceReason RvrTemplateGone
            @?= "template-gone"
      , testCase "RvrInvalidVoiceKey renders as 'invalid-key' (issue discarded)" $
          renderRetiredVoiceReason
            (RvrInvalidVoiceKey
               (OSC.DiIdentifierProfile (OBSC.pack "bad/key")))
            @?= "invalid-key"
      , testCase "RvrOwnerReplaced renders as 'owner-replaced'" $
          renderRetiredVoiceReason RvrOwnerReplaced
            @?= "owner-replaced"
      ]

  , testGroup "renderRetiredBindings"
      [ testCase "empty list renders as a single (none) row" $
          renderRetiredBindings [] @?= ["    (none)"]

      , testCase "stopped-audio (all RvrOwnerReplaced) collapses to a summary row" $
          renderRetiredBindings
            [ RetiredVoiceBinding
                (VoiceBinding (VoiceKey "v0") 0 (TemplateName "drone"))
                RvrOwnerReplaced
            , RetiredVoiceBinding
                (VoiceBinding (VoiceKey "v1") 1 (TemplateName "drone"))
                RvrOwnerReplaced
            , RetiredVoiceBinding
                (VoiceBinding (VoiceKey "v2") 2 (TemplateName "drone"))
                RvrOwnerReplaced
            ]
            @?= ["    - all 3 voices retired by owner replacement"]

      , testCase "single RvrOwnerReplaced still uses the summary (with 1)" $
          renderRetiredBindings
            [ RetiredVoiceBinding
                (VoiceBinding (VoiceKey "v0") 0 (TemplateName "drone"))
                RvrOwnerReplaced
            ]
            @?= ["    - all 1 voices retired by owner replacement"]

      , testCase "preserving (RvrTemplateGone) renders per-binding rows" $
          renderRetiredBindings
            [ RetiredVoiceBinding
                (VoiceBinding (VoiceKey "lead/1") 0 (TemplateName "saw_lead"))
                RvrTemplateGone
            , RetiredVoiceBinding
                (VoiceBinding (VoiceKey "pad/A") 1 (TemplateName "sustain"))
                RvrTemplateGone
            ]
            @?=
              [ "    - voice \"lead/1\" template \"saw_lead\" reason: template-gone"
              , "    - voice \"pad/A\" template \"sustain\" reason: template-gone"
              ]

      , testCase "preserving (mixed reasons) renders one row per binding in input order" $
          renderRetiredBindings
            [ RetiredVoiceBinding
                (VoiceBinding (VoiceKey "lead/1") 0 (TemplateName "saw_lead"))
                RvrTemplateGone
            , RetiredVoiceBinding
                (VoiceBinding (VoiceKey "bad/key") 2 (TemplateName "drone"))
                (RvrInvalidVoiceKey
                  (OSC.DiIdentifierProfile (OBSC.pack "bad/key")))
            ]
            @?=
              [ "    - voice \"lead/1\" template \"saw_lead\" reason: template-gone"
              , "    - voice \"bad/key\" template \"drone\" reason: invalid-key"
              ]

      , testCase "owner-replaced mixed with template-gone falls through to per-binding rows" $
          -- The summary branch fires only when *every* entry is
          -- RvrOwnerReplaced; a single preserving-style reason in the
          -- list keeps the per-binding render. Stopped-audio never
          -- produces this shape today (it only emits
          -- RvrOwnerReplaced), but the renderer should be robust to
          -- the mixed input.
          renderRetiredBindings
            [ RetiredVoiceBinding
                (VoiceBinding (VoiceKey "v0") 0 (TemplateName "drone"))
                RvrOwnerReplaced
            , RetiredVoiceBinding
                (VoiceBinding (VoiceKey "lead/1") 1 (TemplateName "saw_lead"))
                RvrTemplateGone
            ]
            @?=
              [ "    - voice \"v0\" template \"drone\" reason: owner-replaced"
              , "    - voice \"lead/1\" template \"saw_lead\" reason: template-gone"
              ]
      ]

  , testGroup "retiredBindingsFromEvents"
      [ testCase "empty event list returns Nothing" $
          retiredBindingsFromEvents ([] :: [ManifestReloadEvent String])
            @?= Nothing

      , testCase "timeline without a commit event returns Nothing" $
          retiredBindingsFromEvents
            ([ MrePreservingReloadStarted
             , MrePreservingReloadRejected
                 (HpariPlanRejected "plan rejected")
             ] :: [ManifestReloadEvent String])
            @?= Nothing

      , testCase "preserving commit returns the carried payload" $ do
          let leadGone =
                RetiredVoiceBinding
                  (VoiceBinding (VoiceKey "lead/1") 0 (TemplateName "saw_lead"))
                  RvrTemplateGone
          retiredBindingsFromEvents
            ([ MrePreservingReloadStarted
             , MrePreservingReloadCommitted [leadGone]
             ] :: [ManifestReloadEvent String])
            @?= Just [leadGone]

      , testCase "stopped-audio commit returns the carried payload" $ do
          let droneRetired =
                RetiredVoiceBinding
                  (VoiceBinding (VoiceKey "v0") 0 (TemplateName "drone"))
                  RvrOwnerReplaced
          retiredBindingsFromEvents
            ([ MreStoppedAudioReloadStarted
             , MreStoppedAudioReloadCommitted [droneRetired]
             ] :: [ManifestReloadEvent String])
            @?= Just [droneRetired]

      , testCase "try-preserving-then-stopped-audio: stopped-audio commit wins over earlier rejection" $ do
          -- The TryPreservingThenStoppedAudio strategy can emit a
          -- preserving rejection followed by a stopped-audio commit.
          -- The scan returns the last commit event's payload.
          let droneRetired =
                RetiredVoiceBinding
                  (VoiceBinding (VoiceKey "v0") 0 (TemplateName "drone"))
                  RvrOwnerReplaced
          retiredBindingsFromEvents
            ([ MrePreservingReloadStarted
             , MrePreservingReloadRejected
                 (HpariPlanRejected "plan rejected")
             , MreStoppedAudioReloadStarted
             , MreStoppedAudioReloadCommitted [droneRetired]
             ] :: [ManifestReloadEvent String])
            @?= Just [droneRetired]
      ]
  ]
