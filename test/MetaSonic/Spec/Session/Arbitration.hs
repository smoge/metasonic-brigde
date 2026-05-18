-- | Session producer arbitration policy tests.
--
-- Covers 'arbitrateSessionCommand' across the FIFO, producer-priority,
-- and target-claim policies, plus the v1 lifecycle/hot-swap bypass.
-- Uses the shared 'freqTag'/'levelTag' control tags from
-- "MetaSonic.Spec.SessionShared".
module MetaSonic.Spec.Session.Arbitration
  ( sessionArbitrationTests
  ) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Pattern                  (SwapLabel (..),
                                                     TemplateName (..),
                                                     VoiceKey (..),
                                                     patternTemplates)
import           MetaSonic.Pattern.Corpus           (droneVibrato)
import           MetaSonic.Session.Arbitration
import           MetaSonic.Session.Command
import           MetaSonic.Session.Queue            (ProducerKind (..))
import           MetaSonic.Spec.SessionShared       (freqTag, levelTag,
                                                     testProducer)

sessionArbitrationTests :: TestTree
sessionArbitrationTests =
  testGroup "Session producer arbitration policy"
  [ testCase "FifoOnly accepts same-target writes from multiple producers" $ do
      let patternProducer = testProducer ProducerPattern "pattern"
          oscProducer     = testProducer ProducerOSC "osc"
          writeCmd = CmdControlWrite (VoiceKey "v0") levelTag 0.75
      arbitrateSessionCommand FifoOnly patternProducer writeCmd
        @?= ArbitrationAllowed
      arbitrateSessionCommand FifoOnly oscProducer writeCmd
        @?= ArbitrationAllowed

  , testCase "priority policy accepts winner and rejects loser" $ do
      let currentOwner = testProducer ProducerOSC "osc"
          winner       = testProducer ProducerMIDI "midi"
          loser        = testProducer ProducerPattern "pattern"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          command =
            CmdControlWrite (VoiceKey "v0") levelTag 0.5
          owners =
            setControlOwner target currentOwner emptyControlOwnerTable
          policy =
            ProducerPriority
              [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
              owners
          expectedIssue = ArbitrationIssue
            { aiProducer  = loser
            , aiCommand   = command
            , aiTarget    = Just target
            , aiReason    = ArrLowerPriorityThan currentOwner
            , aiRetryable = False
            }
      arbitrateSessionCommand policy winner command
        @?= ArbitrationAllowed
      arbitrateSessionCommand policy loser command
        @?= ArbitrationRejected expectedIssue

  , testCase "priority policy allows equal-priority producers" $ do
      let owner     = testProducer ProducerMIDI "midi-a"
          peer      = testProducer ProducerMIDI "midi-b"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          command =
            CmdControlWrite (VoiceKey "v0") levelTag 0.5
          owners =
            setControlOwner target owner emptyControlOwnerTable
          policy =
            ProducerPriority
              [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
              owners
      arbitrateSessionCommand policy owner command
        @?= ArbitrationAllowed
      arbitrateSessionCommand policy peer command
        @?= ArbitrationAllowed

  , testCase "priority policy allows unowned targets" $ do
      let producer = testProducer ProducerPattern "pattern"
          command =
            CmdControlWrite (VoiceKey "v0") levelTag 0.5
          policy =
            ProducerPriority
              [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
              emptyControlOwnerTable
      arbitrateSessionCommand policy producer command
        @?= ArbitrationAllowed

  , testCase "target claim blocks only the claimed control target" $ do
      let claimant  = testProducer ProducerUI "ui"
          blocked   = testProducer ProducerMIDI "midi"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          otherTarget =
            ControlArbitrationTarget (VoiceKey "v0") freqTag
          command =
            CmdControlWrite (VoiceKey "v0") levelTag 0.25
          otherCommand =
            CmdControlWrite (VoiceKey "v0") freqTag 440.0
          claims =
            claimControlTarget target claimant emptyTargetClaimTable
          policy =
            TargetClaim claims
          expectedIssue = ArbitrationIssue
            { aiProducer  = blocked
            , aiCommand   = command
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      arbitrateSessionCommand policy claimant command
        @?= ArbitrationAllowed
      arbitrateSessionCommand policy blocked command
        @?= ArbitrationRejected expectedIssue
      arbitrateSessionCommand policy blocked otherCommand
        @?= ArbitrationAllowed
      sessionCommandControlTarget otherCommand @?= Just otherTarget

  , testCase "lifecycle and hot-swap commands bypass v1 control arbitration" $ do
      let claimant = testProducer ProducerUI "ui"
          producer = testProducer ProducerMIDI "midi"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          policy =
            TargetClaim
              (claimControlTarget target claimant emptyTargetClaimTable)
          commands =
            [ CmdVoiceOn (TemplateName "voice") (VoiceKey "v0") []
            , CmdVoiceOff (VoiceKey "v0")
            , CmdHotSwap (SwapLabel "refresh") (patternTemplates droneVibrato)
            ]
      map sessionCommandControlTarget commands
        @?= replicate (length commands) Nothing
      map (arbitrateSessionCommand policy producer) commands
        @?= replicate (length commands) ArbitrationAllowed
  ]
