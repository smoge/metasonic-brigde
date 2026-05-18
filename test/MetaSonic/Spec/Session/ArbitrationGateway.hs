-- | Session producer arbitration-gateway tests.
--
-- Exercises 'withSessionArbitrationGateway' as the policy-gated
-- entry point in front of the fan-in host: FIFO baseline, priority
-- accept/reject + owner updates, fan-in rejection leaving owners
-- unchanged, and per-target claim isolation. The local
-- 'assertPriorityOwner' helper stays cohort-private; the shared
-- 'gatewayQueuedOrFail' / 'fanInQueuedOrFail' unwrappers live in
-- "MetaSonic.Spec.SessionShared".
module MetaSonic.Spec.Session.ArbitrationGateway
  ( sessionArbitrationGatewayTests
  ) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Pattern                  (VoiceKey (..),
                                                     patternTemplates)
import           MetaSonic.Pattern.Corpus           (droneVibrato)
import           MetaSonic.Session.Arbitration
import           MetaSonic.Session.ArbitrationGateway
import           MetaSonic.Session.Command
import           MetaSonic.Session.FanIn
import           MetaSonic.Session.Queue            (CommandSequence (..),
                                                     ProducerId,
                                                     ProducerKind (..),
                                                     QueuedSessionCommand (..),
                                                     SessionEnqueueIssue (..),
                                                     SessionEnqueueResult (..),
                                                     SessionQueueOptions (..))
import           MetaSonic.Spec.SessionShared       (freqTag,
                                                     gatewayQueuedOrFail,
                                                     levelTag, testProducer)

sessionArbitrationGatewayTests :: TestTree
sessionArbitrationGatewayTests =
  testGroup "Session producer arbitration gateway"
  [ testCase "default FifoOnly gateway preserves fan-in enqueue behavior" $ do
      let graph = patternTemplates droneVibrato
          patternProducer = testProducer ProducerPattern "pattern"
          oscProducer     = testProducer ProducerOSC "osc"
          command0 =
            CmdControlWrite (VoiceKey "v0") levelTag 0.25
          command1 =
            CmdControlWrite (VoiceKey "v0") levelTag 0.5
      result <-
        withSessionFanInHost graph defaultSessionFanInOptions $ \host ->
          withSessionArbitrationGateway
            defaultSessionArbitrationGatewayOptions
            $ \gateway -> do
                enq0 <- enqueueArbitratedSessionFanInCommand
                          gateway patternProducer command0 host
                enq1 <- enqueueArbitratedSessionFanInCommand
                          gateway oscProducer command1 host
                policy <- readSessionArbitrationGatewayPolicy gateway
                pure (enq0, enq1, policy)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (enq0, enq1, policy) -> do
          q0 <- gatewayQueuedOrFail enq0
          q1 <- gatewayQueuedOrFail enq1
          qscSequence q0 @?= CommandSequence 0
          qscSequence q1 @?= CommandSequence 1
          map qscProducer [q0, q1] @?= [patternProducer, oscProducer]
          policy @?= FifoOnly

  , testCase "priority gateway rejects before fan-in and updates owner on accept" $ do
      let graph = patternTemplates droneVibrato
          oscProducer     = testProducer ProducerOSC "osc"
          midiProducer    = testProducer ProducerMIDI "midi"
          patternProducer = testProducer ProducerPattern "pattern"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          command =
            CmdControlWrite (VoiceKey "v0") levelTag 0.5
          opts = defaultSessionArbitrationGatewayOptions
            { sagoInitialPolicy =
                ProducerPriority
                  [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
                  emptyControlOwnerTable
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = patternProducer
            , aiCommand   = command
            , aiTarget    = Just target
            , aiReason    = ArrLowerPriorityThan oscProducer
            , aiRetryable = False
            }
      result <-
        withSessionFanInHost graph defaultSessionFanInOptions $ \host ->
          withSessionArbitrationGateway opts $ \gateway -> do
            enq0 <- enqueueArbitratedSessionFanInCommand
                      gateway oscProducer command host
            policyAfterOsc <- readSessionArbitrationGatewayPolicy gateway
            rejected <- enqueueArbitratedSessionFanInCommand
                          gateway patternProducer command host
            snapshotAfterReject <- readSessionFanInHost host
            enq1 <- enqueueArbitratedSessionFanInCommand
                      gateway midiProducer command host
            policyAfterMidi <- readSessionArbitrationGatewayPolicy gateway
            snapshotAfterMidi <- readSessionFanInHost host
            pure
              ( enq0
              , policyAfterOsc
              , rejected
              , snapshotAfterReject
              , enq1
              , policyAfterMidi
              , snapshotAfterMidi
              )
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right
          ( enq0
          , policyAfterOsc
          , rejected
          , snapshotAfterReject
          , enq1
          , policyAfterMidi
          , snapshotAfterMidi
          ) -> do
            q0 <- gatewayQueuedOrFail enq0
            q1 <- gatewayQueuedOrFail enq1
            qscSequence q0 @?= CommandSequence 0
            qscSequence q1 @?= CommandSequence 1
            qscProducer q0 @?= oscProducer
            qscProducer q1 @?= midiProducer
            rejected @?= SagArbitrationRejected expectedIssue
            sfisQueueDepth snapshotAfterReject @?= 1
            sfisQueueDepth snapshotAfterMidi @?= 2
            assertPriorityOwner policyAfterOsc target oscProducer
            assertPriorityOwner policyAfterMidi target midiProducer

  , testCase "priority gateway keeps owner unchanged when fan-in rejects" $ do
      let graph = patternTemplates droneVibrato
          fanInOpts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          oscProducer  = testProducer ProducerOSC "osc"
          midiProducer = testProducer ProducerMIDI "midi"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          oscCommand =
            CmdControlWrite (VoiceKey "v0") levelTag 0.25
          midiCommand =
            CmdControlWrite (VoiceKey "v0") levelTag 0.75
          gatewayOpts = defaultSessionArbitrationGatewayOptions
            { sagoInitialPolicy =
                ProducerPriority
                  [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
                  emptyControlOwnerTable
            }
      result <-
        withSessionFanInHost graph fanInOpts $ \host ->
          withSessionArbitrationGateway gatewayOpts $ \gateway -> do
            enq0 <- enqueueArbitratedSessionFanInCommand
                      gateway oscProducer oscCommand host
            policyAfterOsc <- readSessionArbitrationGatewayPolicy gateway
            rejected <- enqueueArbitratedSessionFanInCommand
                          gateway midiProducer midiCommand host
            policyAfterReject <- readSessionArbitrationGatewayPolicy gateway
            snapshotAfterReject <- readSessionFanInHost host
            pure
              ( enq0
              , policyAfterOsc
              , rejected
              , policyAfterReject
              , snapshotAfterReject
              )
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right
          ( enq0
          , policyAfterOsc
          , rejected
          , policyAfterReject
          , snapshotAfterReject
          ) -> do
            q0 <- gatewayQueuedOrFail enq0
            qscProducer q0 @?= oscProducer
            case rejected of
              SagArbitrationRejected issue ->
                assertFailure ("expected fan-in rejection, got: "
                               <> show issue)
              SagEnqueueAttempted fanInResult -> do
                sfierResult fanInResult
                  @?= SessionEnqueueRejected
                        midiProducer
                        midiCommand
                        (SeiQueueFull 1)
                sfierQueueDepth fanInResult @?= 1
            sfisQueueDepth snapshotAfterReject @?= 1
            assertPriorityOwner policyAfterOsc target oscProducer
            assertPriorityOwner policyAfterReject target oscProducer

  , testCase "target-claim gateway rejects only the claimed target before fan-in" $ do
      let graph = patternTemplates droneVibrato
          claimant = testProducer ProducerUI "ui"
          blocked  = testProducer ProducerMIDI "midi"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          claimedCommand =
            CmdControlWrite (VoiceKey "v0") levelTag 0.25
          otherCommand =
            CmdControlWrite (VoiceKey "v0") freqTag 440.0
          gatewayOpts = defaultSessionArbitrationGatewayOptions
            { sagoInitialPolicy =
                TargetClaim
                  (claimControlTarget target claimant emptyTargetClaimTable)
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = blocked
            , aiCommand   = claimedCommand
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      result <-
        withSessionFanInHost graph defaultSessionFanInOptions $ \host ->
          withSessionArbitrationGateway gatewayOpts $ \gateway -> do
            claimantEnq <- enqueueArbitratedSessionFanInCommand
                             gateway claimant claimedCommand host
            rejected <- enqueueArbitratedSessionFanInCommand
                          gateway blocked claimedCommand host
            otherEnq <- enqueueArbitratedSessionFanInCommand
                          gateway blocked otherCommand host
            snapshot <- readSessionFanInHost host
            pure (claimantEnq, rejected, otherEnq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (claimantEnq, rejected, otherEnq, snapshot) -> do
          q0 <- gatewayQueuedOrFail claimantEnq
          q1 <- gatewayQueuedOrFail otherEnq
          qscSequence q0 @?= CommandSequence 0
          qscSequence q1 @?= CommandSequence 1
          qscProducer q0 @?= claimant
          qscProducer q1 @?= blocked
          qscCommand q0 @?= claimedCommand
          qscCommand q1 @?= otherCommand
          rejected @?= SagArbitrationRejected expectedIssue
          sfisQueueDepth snapshot @?= 2
  ]

assertPriorityOwner
  :: ArbitrationPolicy
  -> ControlArbitrationTarget
  -> ProducerId
  -> Assertion
assertPriorityOwner policy target expected =
  case policy of
    ProducerPriority _ owners ->
      lookupControlOwner target owners @?= Just expected
    other ->
      assertFailure ("expected priority policy, got: " <> show other)
