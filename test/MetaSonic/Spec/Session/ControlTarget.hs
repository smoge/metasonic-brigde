-- | Session Prep E: shared control-target resolver tests.
--
-- The real RTGraph session adapter will use the same symbolic
-- @(TemplateName, ControlTag)@ lookup as OSC dispatch. These cases
-- pin the pure 'resolveControlTarget' helper before adapter code
-- starts depending on it.
--
-- Coverage:
--
--   * A known target resolves to a runtime node index and the
--     requested control slot.
--   * Each structured 'ControlTargetIssue' fires for the right
--     input shape: missing template, unknown node tag, and the
--     out-of-range control slot (both positive and negative).
--
-- Extracted from "MetaSonic.Spec.Session" as the sixth slice of
-- the Session megafile split. The cases depend on
-- 'MetaSonic.ControlTarget' plus the existing 'Pattern' /
-- 'Pattern.Corpus' / 'Bridge.*' surfaces; no shared helpers from
-- "MetaSonic.Spec.Session" are needed at this slice.
module MetaSonic.Spec.Session.ControlTarget (controlTargetTests) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile       (rgNodes, rnIndex,
                                                 rnMigrationKey)
import           MetaSonic.Bridge.Source        (MigrationKey (..))
import           MetaSonic.Bridge.Templates     (tgTemplates, tplGraph, tplName)
import           MetaSonic.ControlTarget
import           MetaSonic.Pattern              (ControlTag (..),
                                                 Pattern (patternTemplates),
                                                 TemplateName (..))
import           MetaSonic.Pattern.Corpus       (droneVibrato)


controlTargetTests :: TestTree
controlTargetTests = testGroup "Session Prep E: control target resolver"
  [ testCase "known target resolves to runtime node and control slot" $ do
      let tg      = patternTemplates droneVibrato
          target  = ControlTag (MigrationKey "lpf") 1
          lpfHits =
            [ rnIndex n
            | tpl <- tgTemplates tg
            , tplName tpl == "drone"
            , n <- rgNodes (tplGraph tpl)
            , rnMigrationKey n == Just (MigrationKey "lpf")
            ]
      case resolveControlTarget tg (TemplateName "drone") target of
        Right resolved -> do
          targetControlSlot resolved @?= 1
          assertBool
            ("expected lpf runtime target, got "
              <> show (targetNodeIndex resolved)
              <> " from candidates "
              <> show lpfHits)
            (targetNodeIndex resolved `elem` lpfHits)
        Left issue ->
          assertFailure ("expected resolved control target, got: " <> show issue)

  , testCase "missing template is reported structurally" $ do
      let tg = patternTemplates droneVibrato
      resolveControlTarget
        tg
        (TemplateName "missing")
        (ControlTag (MigrationKey "lpf") 0)
        @?= Left (CtiMissingTemplate (TemplateName "missing"))

  , testCase "missing node tag is reported structurally" $ do
      let tg = patternTemplates droneVibrato
      resolveControlTarget
        tg
        (TemplateName "drone")
        (ControlTag (MigrationKey "no-such-tag") 0)
        @?= Left
              (CtiUnknownNodeTag
                 (TemplateName "drone")
                 (MigrationKey "no-such-tag"))

  , testCase "invalid control slot reports requested and available counts" $ do
      let tg = patternTemplates droneVibrato
      resolveControlTarget
        tg
        (TemplateName "drone")
        (ControlTag (MigrationKey "lpf") 99)
        @?= Left
              (CtiInvalidControlSlot
                 (TemplateName "drone")
                 (MigrationKey "lpf")
                 99
                 2)

  , testCase "negative control slot reports requested and available counts" $ do
      let tg = patternTemplates droneVibrato
      resolveControlTarget
        tg
        (TemplateName "drone")
        (ControlTag (MigrationKey "lpf") (-1))
        @?= Left
              (CtiInvalidControlSlot
                 (TemplateName "drone")
                 (MigrationKey "lpf")
                 (-1)
                 2)
  ]
