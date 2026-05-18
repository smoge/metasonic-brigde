-- | Session Prep A: OSC resolve-state rebuild tests.
--
-- Pins the pure rebuild policy a future session owner will use
-- after a successful graph install. The helper rebuilds symbolic
-- OSC resolution only; it does not install graphs or touch the
-- RTGraph. Diagnostic ordering and the live-state round-trip
-- through 'OSC.dispatch' are pinned alongside the happy path so a
-- regression in either path surfaces here rather than downstream.
--
-- Extracted from "MetaSonic.Spec.Session" as the second slice of
-- the Session megafile split. Like 'sessionCommandTests', the cases
-- depend only on the public 'MetaSonic.Session.Resolve' /
-- 'MetaSonic.OSC.Dispatch' / 'MetaSonic.Pattern' / 'MetaSonic.Pattern.Corpus'
-- surfaces — no shared helpers from "MetaSonic.Spec.SessionShared"
-- needed at this slice.
module MetaSonic.Spec.Session.Resolve (sessionResolveTests) where

import qualified Data.ByteString.Char8        as OBSC
import qualified Data.Map.Strict              as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile       (rgNodes, rnIndex,
                                                 rnMigrationKey)
import           MetaSonic.Bridge.Source        (MigrationKey (..))
import           MetaSonic.Bridge.Templates     (tgTemplates, tplGraph,
                                                 tplName)
import qualified MetaSonic.OSC.Dispatch         as OSC
import qualified MetaSonic.OSC.Wire             as OSC
import           MetaSonic.Pattern              (Pattern (patternTemplates),
                                                 TemplateName (..),
                                                 VoiceKey (..))
import           MetaSonic.Pattern.Corpus       (droneVibrato, polyphonicStab)
import           MetaSonic.Session.Resolve


sessionResolveTests :: TestTree
sessionResolveTests = testGroup "Session Prep A: resolve rebuild"
  [ testCase "valid binding survives rebuild" $ do
      let tg = patternTemplates droneVibrato
          result = rebuildResolveState tg
            [ VoiceBinding
                { vbVoiceKey     = VoiceKey "v0"
                , vbSlotId       = 7
                , vbTemplateName = TemplateName "drone"
                }
            ]
      rrrDropped result @?= []
      OSC.resolveStateVoices (rrrState result)
        @?= M.fromList [(OBSC.pack "v0", (7, OBSC.pack "drone"))]

  , testCase "missing template binding is dropped" $ do
      let tg = patternTemplates polyphonicStab
          result = rebuildResolveState tg
            [ VoiceBinding
                { vbVoiceKey     = VoiceKey "v0"
                , vbSlotId       = 7
                , vbTemplateName = TemplateName "drone"
                }
            ]
      rrrDropped result
        @?= [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
      OSC.resolveStateVoices (rrrState result) @?= M.empty

  , testCase "invalid voice key is dropped through OSC validation" $ do
      let tg = patternTemplates droneVibrato
          result = rebuildResolveState tg
            [ VoiceBinding
                { vbVoiceKey     = VoiceKey "bad/key"
                , vbSlotId       = 7
                , vbTemplateName = TemplateName "drone"
                }
            ]
      rrrDropped result
        @?= [ RriInvalidVoiceKey
                (VoiceKey "bad/key")
                (OSC.DiIdentifierProfile (OBSC.pack "bad/key"))
            ]
      OSC.resolveStateVoices (rrrState result) @?= M.empty

  , testCase "dropped binding diagnostics preserve input order" $ do
      let tg = patternTemplates droneVibrato
          result = rebuildResolveState tg
            [ VoiceBinding (VoiceKey "gone")    1 (TemplateName "missing")
            , VoiceBinding (VoiceKey "bad/key") 2 (TemplateName "drone")
            , VoiceBinding (VoiceKey "v0")      3 (TemplateName "drone")
            ]
      rrrDropped result
        @?= [ RriMissingTemplate (VoiceKey "gone") (TemplateName "missing")
            , RriInvalidVoiceKey
                (VoiceKey "bad/key")
                (OSC.DiIdentifierProfile (OBSC.pack "bad/key"))
            ]
      OSC.resolveStateVoices (rrrState result)
        @?= M.fromList [(OBSC.pack "v0", (3, OBSC.pack "drone"))]

  , testCase "retained binding resolves through rebuilt state" $ do
      let tg = patternTemplates droneVibrato
          result = rebuildResolveState tg
            [ VoiceBinding
                { vbVoiceKey     = VoiceKey "v0"
                , vbSlotId       = 7
                , vbTemplateName = TemplateName "drone"
                }
            ]
          msg = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                               [OSC.OscArgFloat 1800.0]
      rrrDropped result @?= []
      case OSC.dispatch (rrrState result) msg of
        Right (OSC.DAControlWrite
                  { OSC.daSlotId     = slotId
                  , OSC.daNodeIndex  = nodeIx
                  , OSC.daControlIdx = ctrlIx
                  , OSC.daValue      = value
                  }) -> do
          slotId @?= 7
          ctrlIx @?= 0
          value @?= 1800.0
          let lpfTargets =
                [ rnIndex n
                | tpl <- tgTemplates tg
                , tplName tpl == "drone"
                , n   <- rgNodes (tplGraph tpl)
                , rnMigrationKey n == Just (MigrationKey "lpf")
                ]
          assertBool
            ("expected lpf target, got " <> show nodeIx
             <> " from " <> show lpfTargets)
            (nodeIx `elem` lpfTargets)
        other ->
          assertFailure ("expected control-write dispatch, got: " <> show other)
  ]
