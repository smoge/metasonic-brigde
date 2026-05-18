-- | Session Prep H: Pattern producer bridge tests.
--
-- Covers the synchronous 'enqueuePatternBlock' surface (defaults,
-- backlog, empty blocks, sequence preservation, queue-full backlog
-- handling) and the arbitrated 'enqueueArbitratedPatternBlock' path
-- through 'withSessionFanInServiceHooks' (FIFO accept, target-claim
-- rejection, mid-block halt). The local 'itemSequence' helper stays
-- cohort-private; producer/missingVoice helpers live in
-- "MetaSonic.Spec.SessionShared".
module MetaSonic.Spec.Session.PatternProducer
  ( sessionPatternProducerTests
  ) where

import qualified Data.Map.Strict           as M
import qualified Data.Text                 as T
import           Control.Concurrent        (newEmptyMVar, putMVar, takeMVar)
import           Data.Maybe                (listToMaybe, mapMaybe)
import           System.Timeout            (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source            (MigrationKey (..))
import           MetaSonic.Pattern
import           MetaSonic.Pattern.Corpus
import           MetaSonic.Session.Arbitration
import           MetaSonic.Session.ArbitrationGateway
import           MetaSonic.Session.Command          (fromPatternEvent)
import           MetaSonic.Session.FanIn
import           MetaSonic.Session.FanInService
import           MetaSonic.Session.Owner
import           MetaSonic.Session.PatternProducer
import           MetaSonic.Session.Queue
import           MetaSonic.Session.State
import           MetaSonic.Session.Step             (SessionStepResult (..))
import           MetaSonic.Spec.SessionShared       (gatewayQueuedOrFail,
                                                     levelTag,
                                                     missingVoiceEvents,
                                                     missingVoiceEventsAt,
                                                     patternProducerOrFail,
                                                     queueOrFail, testProducer)

sessionPatternProducerTests :: TestTree
sessionPatternProducerTests = testGroup "Session Prep H: Pattern producer"
  [ testCase "default options construct Pattern producer identity" $ do
      assertBool
        "expected positive default block size"
        (ppoBlockFrames defaultPatternProducerOptions > 0)
      producer <- patternProducerOrFail defaultPatternProducerOptions
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let outcome = enqueuePatternBlock droneVibrato producer queue0
          result = peoResult outcome
      perNextStart result @?= SamplePos (ppoBlockFrames defaultPatternProducerOptions)
      case perItems result of
        [item] ->
          case peiResult item of
            SessionEnqueued queued ->
              qscProducer queued
                @?= ProducerId ProducerPattern (T.pack "pattern")
            other ->
              assertFailure ("expected default producer enqueue, got: "
                             <> show other)
        other ->
          assertFailure ("expected one default producer item, got: "
                         <> show other)

  , testCase "invalid block sizes reject at construction" $ do
      newPatternProducerState
        (defaultPatternProducerOptions { ppoBlockFrames = 0 })
        @?= Left (PpiInvalidBlockFrames 0)
      newPatternProducerState
        (defaultPatternProducerOptions { ppoBlockFrames = (-8) })
        @?= Left (PpiInvalidBlockFrames (-8))

  , testCase "backlog predicate tracks queue-pressure retry state" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 1)
      partialRetryQueue <- queueOrFail (SessionQueueOptions 1)
      finalRetryQueue <- queueOrFail (SessionQueueOptions 8)
      let events = missingVoiceEvents 3
          pat = droneVibrato { patternEvents = staticEvents events }
          outcome1 = enqueuePatternBlock pat producer queue0
          outcome2 =
            enqueuePatternBlock pat (peoState outcome1) partialRetryQueue
          outcome3 =
            enqueuePatternBlock pat (peoState outcome2) finalRetryQueue
      assertBool
        "new Pattern producer should start without backlog"
        (not (isBacklogged producer))
      assertBool
        "partial enqueue rejection should leave producer backlogged"
        (isBacklogged (peoState outcome1))
      assertBool
        "partial retry should keep producer backlogged"
        (isBacklogged (peoState outcome2))
      assertBool
        "successful final retry should clear producer backlog"
        (not (isBacklogged (peoState outcome3)))
      perBacklogged (peoResult outcome1) @?= 2
      perBacklogged (peoResult outcome2) @?= 1
      perBacklogged (peoResult outcome3) @?= 0

  , testCase "empty block advances cursor and enqueues nothing" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 16 })
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let emptyPattern = droneVibrato
            { patternEvents = staticEvents [] }
          outcome = enqueuePatternBlock emptyPattern producer queue0
          result = peoResult outcome
      perItems result @?= []
      perBacklogged result @?= 0
      perNextStart result @?= SamplePos 16

  , testCase "first droneVibrato block enqueues expected VoiceOn command" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions
          { ppoProducerName = T.pack "composer"
          , ppoBlockFrames  = 64
          })
      queue0 <- queueOrFail (SessionQueueOptions 4)
      expectedEvent <- case listToMaybe droneVibratoEvents of
        Just event ->
          pure event
        Nothing ->
          assertFailure "expected droneVibratoEvents to contain a first event"
      let outcome = enqueuePatternBlock droneVibrato producer queue0
      case perItems (peoResult outcome) of
        [item] -> do
          peiSamplePos item @?= fst expectedEvent
          peiEvent item @?= snd expectedEvent
          peiCommand item @?= fromPatternEvent (snd expectedEvent)
          case peiResult item of
            SessionEnqueued queued -> do
              qscSequence queued @?= CommandSequence 0
              qscProducer queued
                @?= ProducerId ProducerPattern (T.pack "composer")
            other ->
              assertFailure ("expected queued VoiceOn, got: " <> show other)
        other ->
          assertFailure ("expected one droneVibrato item, got: " <> show other)

  , testCase "same-sample Pattern events preserve emit order" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 1 })
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let expected = take 2 arpeggioSendReturnEvents
          outcome = enqueuePatternBlock arpeggioSendReturn producer queue0
          items = perItems (peoResult outcome)
      map peiEvent items @?= map snd expected
      map peiSamplePos items @?= map fst expected
      mapMaybe itemSequence items @?= [CommandSequence 0, CommandSequence 1]

  , testCase "every PatternEvent constructor maps through fromPatternEvent" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 8)
      let events =
            [ ( SamplePos 0
              , PEVoiceOn (TemplateName "drone") (VoiceKey "v0") []
              )
            , ( SamplePos 1
              , PEControlWrite
                  (VoiceKey "v0")
                  (ControlTag (MigrationKey "lpf") 0)
                  1200.0
              )
            , ( SamplePos 2
              , PEVoiceOff (VoiceKey "v0")
              )
            , ( SamplePos 3
              , PEHotSwap
                  (SwapLabel "edit")
                  (patternTemplates polyphonicStab)
              )
            ]
          pat = droneVibrato { patternEvents = staticEvents events }
          outcome = enqueuePatternBlock pat producer queue0
          items = perItems (peoResult outcome)
      map peiEvent items @?= map snd events
      map peiCommand items @?= map (fromPatternEvent . snd) events
      perBacklogged (peoResult outcome) @?= 0

  , testCase "full queue stops at first rejection and retains tail backlog" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 1)
      retryQueue <- queueOrFail (SessionQueueOptions 8)
      let events = missingVoiceEvents 4
          pat = droneVibrato { patternEvents = staticEvents events }
          outcome1 = enqueuePatternBlock pat producer queue0
          result1 = peoResult outcome1
      map peiEvent (perItems result1) @?= map snd (take 2 events)
      perBacklogged result1 @?= 3
      case map peiResult (perItems result1) of
        [SessionEnqueued _, SessionEnqueueRejected {}] ->
          pure ()
        other ->
          assertFailure ("expected enqueue then rejection, got: "
                         <> show other)

      let outcome2 = enqueuePatternBlock pat (peoState outcome1) retryQueue
          result2 = peoResult outcome2
      perNextStart result2 @?= perNextStart result1
      perBacklogged result2 @?= 0
      map peiEvent (perItems result2) @?= map snd (drop 1 events)

  , testCase "rejected backlog does not consume queue sequence numbers" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let events = missingVoiceEvents 3
          pat = droneVibrato { patternEvents = staticEvents events }
          outcome1 = enqueuePatternBlock pat producer queue0
          result1 = peoResult outcome1
      mapMaybe itemSequence (perItems result1)
        @?= [CommandSequence 0, CommandSequence 1]
      perBacklogged result1 @?= 1

      drained <- withSessionOwner
                   (patternTemplates droneVibrato)
                   defaultSessionOwnerOptions
                   (\owner -> drainSessionCommandQueue owner (peoQueue outcome1))
      drainedQueue <- case drained of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (queue1, drain) -> do
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          pure queue1

      let outcome2 = enqueuePatternBlock pat (peoState outcome1) drainedQueue
          result2 = peoResult outcome2
      perNextStart result2 @?= perNextStart result1
      perBacklogged result2 @?= 0
      map peiEvent (perItems result2) @?= [snd (events !! 2)]
      mapMaybe itemSequence (perItems result2) @?= [CommandSequence 2]

  , testCase "retry call does not generate a fresh range after backlog drains" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 2)
      retryQueue <- queueOrFail (SessionQueueOptions 8)
      nextQueue <- queueOrFail (SessionQueueOptions 8)
      let events =
            missingVoiceEventsAt [0, 1, 2, 8]
          pat = droneVibrato { patternEvents = staticEvents events }
          outcome1 = enqueuePatternBlock pat producer queue0
          outcome2 = enqueuePatternBlock pat (peoState outcome1) retryQueue
          outcome3 = enqueuePatternBlock pat (peoState outcome2) nextQueue
      perBacklogged (peoResult outcome1) @?= 1
      perNextStart (peoResult outcome2)
        @?= perNextStart (peoResult outcome1)
      map peiSamplePos (perItems (peoResult outcome2))
        @?= [SamplePos 2]
      perBacklogged (peoResult outcome2) @?= 0
      perNextStart (peoResult outcome3) @?= SamplePos 16
      map peiSamplePos (perItems (peoResult outcome3))
        @?= [SamplePos 8]

  , testCase "producer enqueue drains through owner and commits a real voice" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 64 })
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let outcome = enqueuePatternBlock droneVibrato producer queue0
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  $ \owner -> do
                    drained <- drainSessionCommandQueue owner (peoQueue outcome)
                    st <- sessionOwnerState owner
                    pure (drained, st)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right ((_queue1, drain), st) -> do
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          case map sdiResult (sdrItems drain) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure ("expected committed Pattern producer voice, got: "
                             <> show other)
          assertBool
            ("expected v0 voice after drain, got " <> show (ssVoices st))
            (M.member (VoiceKey "v0") (ssVoices st))

  , testCase "arbitrated service Pattern enqueue defaults to FIFO" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions
          { ppoProducerName = T.pack "pattern-arb"
          , ppoBlockFrames  = 64
          })
      expectedEvent <- case listToMaybe droneVibratoEvents of
        Just event ->
          pure event
        Nothing ->
          assertFailure "expected droneVibratoEvents to contain a first event"
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              outcome <- enqueueArbitratedPatternBlock
                           droneVibrato
                           producer
                           service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (outcome, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (outcome, Just drained, snapshot) -> do
          let result' = paeoResult outcome
          assertBool
            "arbitrated Pattern producer should not leave backlog after one clean block"
            (not (isBacklogged (paeoState outcome)))
          paerBacklogged result' @?= 0
          paerNextStart result' @?= SamplePos 64
          case paerItems result' of
            [item] -> do
              paeiSamplePos item @?= fst expectedEvent
              paeiEvent item @?= snd expectedEvent
              paeiCommand item @?= fromPatternEvent (snd expectedEvent)
              queued <- gatewayQueuedOrFail (paeiResult item)
              qscProducer queued
                @?= ProducerId ProducerPattern (T.pack "pattern-arb")
              qscCommand queued @?= paeiCommand item
              map sdiQueued (sdrItems (sfidrDrain drained)) @?= [queued]
              case map sdiResult (sdrItems (sfidrDrain drained)) of
                [SessionOwnerStep (StepCommitted _ Nothing)] ->
                  pure ()
                other ->
                  assertFailure
                    ("expected arbitrated Pattern voice-on to commit, got: "
                     <> show other)
            other ->
              assertFailure ("expected one arbitrated Pattern item, got: "
                             <> show other)
          sfisQueueDepth snapshot @?= 0
          assertBool
            "expected Pattern voice after arbitrated service drain"
            (M.member (VoiceKey "v0") (ssVoices (sfisOwnerState snapshot)))
        Right (_outcome, Nothing, _snapshot) ->
          assertFailure "timed out waiting for arbitrated Pattern service drain"

  , testCase "arbitrated service Pattern rejection reports service issue" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions
          { ppoProducerName = T.pack "pattern-arb"
          , ppoBlockFrames  = 8
          })
      let event =
            ( SamplePos 0
            , PEControlWrite (VoiceKey "v0") levelTag 0.75
            )
          pat = droneVibrato { patternEvents = staticEvents [event] }
          command = fromPatternEvent (snd event)
          producerId = ProducerId ProducerPattern (T.pack "pattern-arb")
          claimant = testProducer ProducerUI "ui"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          serviceOpts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = producerId
            , aiCommand   = command
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            , sfshOnIssue = putMVar issueVar
            }
          (patternTemplates droneVibrato)
          serviceOpts
          $ \service -> do
              outcome <- enqueueArbitratedPatternBlock pat producer service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              mDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (outcome, mIssue, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (outcome, Just reported, Nothing, snapshot) -> do
          let result' = paeoResult outcome
          assertBool
            "policy-rejected Pattern event should remain backlogged"
            (isBacklogged (paeoState outcome))
          paerBacklogged result' @?= 1
          paerNextStart result' @?= SamplePos 8
          case paerItems result' of
            [item] -> do
              paeiSamplePos item @?= fst event
              paeiEvent item @?= snd event
              paeiCommand item @?= command
              paeiResult item @?= SagArbitrationRejected expectedIssue
            other ->
              assertFailure
                ("expected one rejected arbitrated Pattern item, got: "
                 <> show other)
          reported @?= SfsiiArbitrationRejected expectedIssue
          sfisQueueDepth snapshot @?= 0
        Right (_outcome, Nothing, _mDrain, _snapshot) ->
          assertFailure "timed out waiting for Pattern arbitration rejection issue"
        Right (_outcome, Just _reported, Just extraDrain, _snapshot) ->
          assertFailure
            ("Pattern policy rejection unexpectedly woke service drain: "
             <> show extraDrain)

  , testCase "arbitrated service Pattern halts on mid-block rejection" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions
          { ppoProducerName = T.pack "pattern-arb"
          , ppoBlockFrames  = 8
          })
      let firstTarget = ControlTag (MigrationKey "lpf") 1
          claimedTarget = levelTag
          firstEvent =
            ( SamplePos 0
            , PEControlWrite (VoiceKey "v0") firstTarget 4.0
            )
          rejectedEvent =
            ( SamplePos 1
            , PEControlWrite (VoiceKey "v0") claimedTarget 0.75
            )
          tailEvent =
            (SamplePos 2, PEVoiceOff (VoiceKey "v0"))
          events =
            [firstEvent, rejectedEvent, tailEvent]
          pat = droneVibrato { patternEvents = staticEvents events }
          producerId = ProducerId ProducerPattern (T.pack "pattern-arb")
          claimant = testProducer ProducerUI "ui"
          target =
            ControlArbitrationTarget (VoiceKey "v0") claimedTarget
          firstCommand = fromPatternEvent (snd firstEvent)
          rejectedCommand = fromPatternEvent (snd rejectedEvent)
          tailCommand = fromPatternEvent (snd tailEvent)
          serviceOpts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = producerId
            , aiCommand   = rejectedCommand
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            , sfshOnIssue = putMVar issueVar
            }
          (patternTemplates droneVibrato)
          serviceOpts
          $ \service -> do
              outcome <- enqueueArbitratedPatternBlock pat producer service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              mFirstDrain <- timeout 1000000 (takeMVar drainedVar)
              mSecondDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (outcome, mIssue, mFirstDrain, mSecondDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (outcome, Just reported, Just firstDrain, Nothing, snapshot) -> do
          let result' = paeoResult outcome
              items = paerItems result'
          assertBool
            "mid-block rejection should leave Pattern producer backlogged"
            (isBacklogged (paeoState outcome))
          paerBacklogged result' @?= 2
          paerNextStart result' @?= SamplePos 8
          map paeiCommand items @?= [firstCommand, rejectedCommand]
          assertBool
            "tail command should not be attempted after mid-block rejection"
            (tailCommand `notElem` map paeiCommand items)
          case items of
            [acceptedItem, rejectedItem] -> do
              queued <- gatewayQueuedOrFail (paeiResult acceptedItem)
              qscProducer queued @?= producerId
              qscCommand queued @?= firstCommand
              paeiResult rejectedItem
                @?= SagArbitrationRejected expectedIssue
              map sdiQueued (sdrItems (sfidrDrain firstDrain))
                @?= [queued]
              length (sdrItems (sfidrDrain firstDrain)) @?= 1
            other ->
              assertFailure
                ("expected accepted then rejected Pattern items, got: "
                 <> show other)
          reported @?= SfsiiArbitrationRejected expectedIssue
          sfisQueueDepth snapshot @?= 0
        Right (_outcome, Nothing, _mFirstDrain, _mSecondDrain, _snapshot) ->
          assertFailure "timed out waiting for Pattern arbitration rejection issue"
        Right (_outcome, Just _reported, Nothing, _mSecondDrain, _snapshot) ->
          assertFailure "timed out waiting for admitted Pattern drain"
        Right (_outcome, Just _reported, Just _firstDrain, Just extraDrain, _snapshot) ->
          assertFailure
            ("Pattern mid-block rejection unexpectedly produced extra drain: "
             <> show extraDrain)
  ]

itemSequence :: PatternEnqueueItem -> Maybe CommandSequence
itemSequence item = case peiResult item of
  SessionEnqueued queued ->
    Just (qscSequence queued)
  SessionEnqueueRejected {} ->
    Nothing
