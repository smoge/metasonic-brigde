-- | Session Prep A: command vocabulary tests.
--
-- Pins the structural adapter from the existing 'PatternEvent'
-- vocabulary into the future 'SessionCommand' vocabulary. The
-- cases are pure constructor-equality checks against
-- 'fromPatternEvent'; no command execution, queue write, or
-- runtime ownership is implied.
--
-- Extracted from "MetaSonic.Spec.Session" as the first slice of
-- the Session megafile split. The cases depend only on the public
-- 'MetaSonic.Session.Command', 'MetaSonic.Pattern', and
-- 'MetaSonic.Pattern.Corpus' surfaces — no shared helpers from
-- "MetaSonic.Spec.SessionShared" needed at this slice.
module MetaSonic.Spec.Session.Command (sessionCommandTests) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source        (MigrationKey (..))
import           MetaSonic.Pattern              (ControlTag (..),
                                                 Pattern (patternTemplates),
                                                 PatternEvent (..),
                                                 SwapLabel (..),
                                                 TemplateName (..),
                                                 VoiceKey (..))
import           MetaSonic.Pattern.Corpus       (hotSwapEdit)
import           MetaSonic.Session.Command


sessionCommandTests :: TestTree
sessionCommandTests = testGroup "Session Prep A: command vocabulary"
  [ testCase "PEVoiceOn adapts to CmdVoiceOn" $ do
      let tname = TemplateName "voice"
          vkey  = VoiceKey "v0"
          ctrls =
            [ (ControlTag (MigrationKey "freq") 0, 440.0)
            , (ControlTag (MigrationKey "amp")  1, 0.25)
            ]
      fromPatternEvent (PEVoiceOn tname vkey ctrls)
        @?= CmdVoiceOn tname vkey ctrls

  , testCase "PEVoiceOff adapts to CmdVoiceOff" $ do
      let vkey = VoiceKey "v0"
      fromPatternEvent (PEVoiceOff vkey)
        @?= CmdVoiceOff vkey

  , testCase "PEControlWrite adapts to CmdControlWrite" $ do
      let vkey   = VoiceKey "v0"
          target = ControlTag (MigrationKey "cutoff") 0
      fromPatternEvent (PEControlWrite vkey target 1200.0)
        @?= CmdControlWrite vkey target 1200.0

  , testCase "PEHotSwap adapts to CmdHotSwap and preserves payload" $ do
      let swapLabel = SwapLabel "edit-cutoff"
          tg        = patternTemplates hotSwapEdit
      fromPatternEvent (PEHotSwap swapLabel tg)
        @?= CmdHotSwap swapLabel tg

  , testCase "diagnostic events are structural values, not execution" $ do
      let cmd   = CmdVoiceOff (VoiceKey "stale")
          issue = SiStaleVoice (VoiceKey "stale")
      SessionCommandRejected cmd issue
        @?= SessionCommandRejected cmd issue
  ]
