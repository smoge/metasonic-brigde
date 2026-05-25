-- | Deterministic coverage for the stale-by-reload attribution
-- helpers in "MetaSonic.App.ManifestLiveCommon".
--
-- Phase 8h step 3e v1 slice 3 (pure-helper half): pins the
-- 'classifyStaleByReload' filter, the 'retiredVoiceKeyMap'
-- projection, and the 'renderStaleByReloadCommands' operator
-- render. Runtime wiring (drain-hook IORef snapshot, dispatcher
-- output block) lands in the follow-up slice.
--
-- The classifier intentionally narrows to 'SiStaleVoice' on
-- 'CmdVoiceOff' / 'CmdControlWrite' against a retired key. Other
-- shapes — non-rejecting drain steps, 'SiUnknownTemplate', non-
-- retired voice keys — return 'Nothing' and never appear in the
-- @stale-by-reload commands:@ block.
module MetaSonic.Spec.AppManifestLiveCommonStaleByReload
  ( appManifestLiveCommonStaleByReloadTests
  ) where

import qualified Data.ByteString.Char8                  as OBSC
import qualified Data.Map.Strict                        as M
import qualified Data.Text                              as T

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestLiveCommon       (AttributedStaleCommand (..),
                                                         classifyStaleByReload,
                                                         classifyStaleByReloadAll,
                                                         renderStaleByReloadCommands,
                                                         retiredVoiceKeyMap)
import           MetaSonic.Bridge.Source                (MigrationKey (..))
import qualified MetaSonic.OSC.Dispatch                 as OSC
import           MetaSonic.Pattern                      (ControlTag (..),
                                                         TemplateName (..),
                                                         VoiceKey (..))
import           MetaSonic.Session.Command              (SessionCommand (..),
                                                         SessionIssue (..))
import           MetaSonic.Session.Owner                (SessionOwnerDivergence (..),
                                                         SessionOwnerStepResult (..))
import           MetaSonic.Session.Queue                (CommandSequence (..),
                                                         ProducerId (..),
                                                         ProducerKind (..),
                                                         QueuedSessionCommand (..),
                                                         SessionDrainItem (..))
import           MetaSonic.Session.Resolve              (RetiredVoiceBinding (..),
                                                         RetiredVoiceReason (..),
                                                         VoiceBinding (..))
import           MetaSonic.Session.Step                 (SessionStepResult (..))


appManifestLiveCommonStaleByReloadTests :: TestTree
appManifestLiveCommonStaleByReloadTests =
  testGroup "App manifest live common: stale-by-reload attribution"
  [ testGroup "retiredVoiceKeyMap"
      [ testCase "empty list projects to empty map" $
          retiredVoiceKeyMap [] @?= M.empty

      , testCase "preserving retired voices project to (key, reason) entries" $
          retiredVoiceKeyMap
            [ RetiredVoiceBinding
                (VoiceBinding (VoiceKey "lead/1") 0 (TemplateName "saw_lead"))
                RvrTemplateGone
            , RetiredVoiceBinding
                (VoiceBinding (VoiceKey "bad/key") 2 (TemplateName "drone"))
                (RvrInvalidVoiceKey
                  (OSC.DiIdentifierProfile (OBSC.pack "bad/key")))
            ]
            @?= M.fromList
              [ ( VoiceKey "lead/1"
                , RvrTemplateGone)
              , ( VoiceKey "bad/key"
                , RvrInvalidVoiceKey
                    (OSC.DiIdentifierProfile (OBSC.pack "bad/key")))
              ]

      , testCase "stopped-audio retired voices project to RvrOwnerReplaced entries" $
          retiredVoiceKeyMap
            [ RetiredVoiceBinding
                (VoiceBinding (VoiceKey "v0") 0 (TemplateName "drone"))
                RvrOwnerReplaced
            , RetiredVoiceBinding
                (VoiceBinding (VoiceKey "v1") 1 (TemplateName "drone"))
                RvrOwnerReplaced
            ]
            @?= M.fromList
              [ (VoiceKey "v0", RvrOwnerReplaced)
              , (VoiceKey "v1", RvrOwnerReplaced)
              ]
      ]

  , testGroup "classifyStaleByReload"
      [ testCase "VoiceOff against retired voice attributes to the reload" $
          classifyStaleByReload retiredLead
            (drainItem
               oscProducer
               (CmdVoiceOff (VoiceKey "lead/1"))
               (rejected (SiStaleVoice (VoiceKey "lead/1"))))
            @?= Just AttributedStaleCommand
              { ascProducer = oscProducer
              , ascCommand  = CmdVoiceOff (VoiceKey "lead/1")
              , ascVoiceKey = VoiceKey "lead/1"
              , ascReason   = RvrTemplateGone
              }

      , testCase "ControlWrite against retired voice attributes to the reload" $
          classifyStaleByReload retiredLead
            (drainItem
               midiProducer
               (CmdControlWrite (VoiceKey "lead/1") cutoffTag 1500.0)
               (rejected (SiStaleVoice (VoiceKey "lead/1"))))
            @?= Just AttributedStaleCommand
              { ascProducer = midiProducer
              , ascCommand  = CmdControlWrite (VoiceKey "lead/1") cutoffTag 1500.0
              , ascVoiceKey = VoiceKey "lead/1"
              , ascReason   = RvrTemplateGone
              }

      , testCase "SiStaleVoice against a non-retired voice does not attribute" $
          classifyStaleByReload retiredLead
            (drainItem
               oscProducer
               (CmdVoiceOff (VoiceKey "untouched/0"))
               (rejected (SiStaleVoice (VoiceKey "untouched/0"))))
            @?= Nothing

      , testCase "SiUnknownTemplate is not attributed (deferred to v2 lane)" $
          classifyStaleByReload retiredLead
            (drainItem
               uiProducer
               (CmdVoiceOn (TemplateName "gone") (VoiceKey "v0") [])
               (rejected (SiUnknownTemplate (TemplateName "gone"))))
            @?= Nothing

      , testCase "Non-rejection drain step (e.g. control accepted) does not attribute" $
          classifyStaleByReload retiredLead
            (drainItem
               uiProducer
               (CmdControlWrite (VoiceKey "lead/1") cutoffTag 1500.0)
               (SessionOwnerStep StepControlAccepted))
            @?= Nothing

      , testCase "Owner-blocked drain step does not attribute even if it would have matched" $
          classifyStaleByReload retiredLead
            (drainItem
               oscProducer
               (CmdVoiceOff (VoiceKey "lead/1"))
               (SessionOwnerBlocked SodBackendStopped))
            @?= Nothing

      , testCase "Command-shape guard: VoiceOn carrying SiStaleVoice does not attribute (defensive against synthetic items)" $
          -- The real admitSessionCommand only emits SiStaleVoice for
          -- CmdVoiceOff / CmdControlWrite, but the helper is
          -- exported and could see a synthetic drain item where the
          -- command is something else (e.g. CmdVoiceOn) but the
          -- rejection still claims a stale voice. The guard prevents
          -- that misattribution.
          classifyStaleByReload retiredLead
            (drainItem
               oscProducer
               (CmdVoiceOn (TemplateName "saw_lead") (VoiceKey "lead/1") [])
               (rejected (SiStaleVoice (VoiceKey "lead/1"))))
            @?= Nothing

      , testCase "Voice-key cross-check: VoiceOff with mismatched key vs issue does not attribute" $
          -- Defensive against synthetic items where the command's
          -- voice key disagrees with the issue's voice key. The real
          -- admission path can't produce this — it derives the issue
          -- from the command — but the exported helper should not
          -- attribute under that disagreement.
          classifyStaleByReload retiredLead
            (drainItem
               oscProducer
               (CmdVoiceOff (VoiceKey "other"))
               (rejected (SiStaleVoice (VoiceKey "lead/1"))))
            @?= Nothing

      , testCase "Voice-key cross-check: ControlWrite with mismatched key vs issue does not attribute" $
          classifyStaleByReload retiredLead
            (drainItem
               midiProducer
               (CmdControlWrite (VoiceKey "other") cutoffTag 1500.0)
               (rejected (SiStaleVoice (VoiceKey "lead/1"))))
            @?= Nothing

      , testCase "Owner-diverged-now still attributes the underlying rejection" $
          -- The drain item carries the SessionStepResult that ran
          -- before the divergence finalized; if the step rejected
          -- with SiStaleVoice against a retired voice, attribution
          -- still applies.
          classifyStaleByReload retiredLead
            (drainItem
               oscProducer
               (CmdVoiceOff (VoiceKey "lead/1"))
               (SessionOwnerDivergedNow
                  (StepRejected (SiStaleVoice (VoiceKey "lead/1")))
                  SodBackendStopped))
            @?= Just AttributedStaleCommand
              { ascProducer = oscProducer
              , ascCommand  = CmdVoiceOff (VoiceKey "lead/1")
              , ascVoiceKey = VoiceKey "lead/1"
              , ascReason   = RvrTemplateGone
              }
      ]

  , testGroup "classifyStaleByReloadAll"
      [ testCase "preserves input order and filters out non-matches" $
          classifyStaleByReloadAll retiredLead
            [ drainItem
                oscProducer
                (CmdVoiceOff (VoiceKey "lead/1"))
                (rejected (SiStaleVoice (VoiceKey "lead/1")))
            , drainItem
                midiProducer
                (CmdControlWrite (VoiceKey "untouched/0") cutoffTag 600.0)
                (rejected (SiStaleVoice (VoiceKey "untouched/0")))
            , drainItem
                uiProducer
                (CmdControlWrite (VoiceKey "lead/1") cutoffTag 1500.0)
                (rejected (SiStaleVoice (VoiceKey "lead/1")))
            ]
            @?=
              [ AttributedStaleCommand
                  { ascProducer = oscProducer
                  , ascCommand  = CmdVoiceOff (VoiceKey "lead/1")
                  , ascVoiceKey = VoiceKey "lead/1"
                  , ascReason   = RvrTemplateGone
                  }
              , AttributedStaleCommand
                  { ascProducer = uiProducer
                  , ascCommand  = CmdControlWrite (VoiceKey "lead/1") cutoffTag 1500.0
                  , ascVoiceKey = VoiceKey "lead/1"
                  , ascReason   = RvrTemplateGone
                  }
              ]
      ]

  , testGroup "renderStaleByReloadCommands"
      [ testCase "empty input renders (none)" $
          renderStaleByReloadCommands [] @?= ["    (none)"]

      , testCase "single OSC voice-off renders the producer kind, command, and reason" $
          renderStaleByReloadCommands
            [ AttributedStaleCommand
                { ascProducer = oscProducer
                , ascCommand  = CmdVoiceOff (VoiceKey "lead/1")
                , ascVoiceKey = VoiceKey "lead/1"
                , ascReason   = RvrTemplateGone
                }
            ]
            @?=
              [ "    - osc voice-off voice=lead/1  "
                <> "-> reload retired voice \"lead/1\" (template-gone)"
              ]

      , testCase "MIDI control-write under an owner-replaced retirement renders cleanly" $
          renderStaleByReloadCommands
            [ AttributedStaleCommand
                { ascProducer = midiProducer
                , ascCommand  = CmdControlWrite (VoiceKey "v0") cutoffTag 1500.0
                , ascVoiceKey = VoiceKey "v0"
                , ascReason   = RvrOwnerReplaced
                }
            ]
            @?=
              [ "    - midi control-write voice=v0 "
                <> "tag=ControlTag {ctNodeTag = MigrationKey {unMigrationKey = \"lpf\"}, ctSlot = 0}  "
                <> "-> reload retired voice \"v0\" (owner-replaced)"
              ]

      , testCase "multiple attributions render one row each in input order" $
          renderStaleByReloadCommands
            [ AttributedStaleCommand
                { ascProducer = oscProducer
                , ascCommand  = CmdVoiceOff (VoiceKey "lead/1")
                , ascVoiceKey = VoiceKey "lead/1"
                , ascReason   = RvrTemplateGone
                }
            , AttributedStaleCommand
                { ascProducer = uiProducer
                , ascCommand  = CmdVoiceOff (VoiceKey "pad/A")
                , ascVoiceKey = VoiceKey "pad/A"
                , ascReason   = RvrInvalidVoiceKey
                                  (OSC.DiIdentifierProfile (OBSC.pack "pad/A"))
                }
            ]
            @?=
              [ "    - osc voice-off voice=lead/1  "
                <> "-> reload retired voice \"lead/1\" (template-gone)"
              , "    - ui voice-off voice=pad/A  "
                <> "-> reload retired voice \"pad/A\" (invalid-key)"
              ]
      ]
  ]
  where
    retiredLead =
      M.fromList [(VoiceKey "lead/1", RvrTemplateGone)]

    cutoffTag = ControlTag (MigrationKey "lpf") 0

    oscProducer  = ProducerId ProducerOSC  (T.pack "test-osc")
    midiProducer = ProducerId ProducerMIDI (T.pack "test-midi")
    uiProducer   = ProducerId ProducerUI   (T.pack "test-ui")

    rejected issue = SessionOwnerStep (StepRejected issue)

    drainItem producer cmd result =
      SessionDrainItem
        { sdiQueued = QueuedSessionCommand
            { qscSequence = CommandSequence 1
            , qscProducer = producer
            , qscCommand  = cmd
            }
        , sdiResult = result
        }
