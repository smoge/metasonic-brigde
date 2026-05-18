-- | Session UI producer adapter tests.
--
-- This adapter is Haskell-only and consumes already-decoded UI
-- intents. It is not a GUI toolkit binding, manifest reload path, or
-- authorization layer. Tests cover the synchronous decode/enqueue
-- surface plus the service-host and arbitrated-gateway paths through
-- "MetaSonic.Session.FanInService".
module MetaSonic.Spec.Session.UIProducer
  ( sessionUIProducerTests
  ) where

import qualified Data.Map.Strict           as M
import qualified Data.Text                 as T
import           Control.Concurrent        (newEmptyMVar, putMVar, takeMVar)
import           System.Timeout            (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Pattern                  (Pattern (..),
                                                     SwapLabel (..),
                                                     TemplateName (..),
                                                     VoiceKey (..))
import           MetaSonic.Pattern.Corpus           (droneVibrato)
import           MetaSonic.Session.Arbitration
import           MetaSonic.Session.ArbitrationGateway
import           MetaSonic.Session.Command          (SessionCommand (..))
import           MetaSonic.Session.FanIn
import           MetaSonic.Session.FanInService
import           MetaSonic.Session.Owner            (SessionOwnerStepResult (..))
import           MetaSonic.Session.Queue
import           MetaSonic.Session.State            (ssVoices)
import           MetaSonic.Session.Step             (SessionStepResult (..))
import           MetaSonic.Session.UIProducer
import           MetaSonic.Spec.SessionShared       (fanInQueuedOrFail,
                                                     gatewayQueuedOrFail,
                                                     levelTag, testProducer)

sessionUIProducerTests :: TestTree
sessionUIProducerTests =
  testGroup "Session UI producer adapter"
  [ testCase "decodes UI intents to session commands" $ do
      let start =
            UIVoiceOn
              (TemplateName "drone")
              (VoiceKey "u0")
              [(levelTag, 0.5)]
          write =
            UIControlWrite (VoiceKey "u0") levelTag 0.75
          stop =
            UIVoiceOff (VoiceKey "u0")
          swap =
            UIHotSwap
              (SwapLabel "ui-swap")
              (patternTemplates droneVibrato)
      decodeUISessionCommand start
        @?= Right (CmdVoiceOn
                    (TemplateName "drone")
                    (VoiceKey "u0")
                    [(levelTag, 0.5)])
      decodeUISessionCommand write
        @?= Right (CmdControlWrite (VoiceKey "u0") levelTag 0.75)
      decodeUISessionCommand stop
        @?= Right (CmdVoiceOff (VoiceKey "u0"))
      decodeUISessionCommand swap
        @?= Right (CmdHotSwap
                    (SwapLabel "ui-swap")
                    (patternTemplates droneVibrato))

  , testCase "rejects non-finite UI values before enqueue" $ do
      let infinity = 1.0 / 0.0
      decodeUISessionCommand
        (UIControlWrite (VoiceKey "u0") levelTag infinity)
        @?= Left (UpiNonFiniteControlValue levelTag infinity)
      decodeUISessionCommand
        (UIVoiceOn
          (TemplateName "drone")
          (VoiceKey "u0")
          [(levelTag, infinity)])
        @?= Left (UpiNonFiniteInitialControl levelTag infinity)

  , testCase "successful enqueue attributes command to ProducerUI" $ do
      let opts = testUIProducerOptions
          intent =
            UIVoiceOn (TemplateName "drone") (VoiceKey "u0") []
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  defaultSessionFanInOptions
                  $ \host -> do
                    enq <- enqueueUIProducerIntent opts intent host
                    snapshot <- readSessionFanInHost host
                    pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (UIProducerEnqueueAttempted command enq, snapshot) -> do
          queued <- fanInQueuedOrFail enq
          command @?= CmdVoiceOn (TemplateName "drone") (VoiceKey "u0") []
          producerKind (qscProducer queued) @?= ProducerUI
          producerName (qscProducer queued) @?= upoProducerName opts
          qscCommand queued @?= command
          sfierQueueDepth enq @?= 1
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected UI enqueue attempt, got: " <> show other)

  , testCase "decode rejection does not enqueue" $ do
      let infinity = 1.0 / 0.0
          intent = UIControlWrite (VoiceKey "u0") levelTag infinity
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  defaultSessionFanInOptions
                  $ \host -> do
                    enq <- enqueueUIProducerIntent
                             testUIProducerOptions
                             intent
                             host
                    snapshot <- readSessionFanInHost host
                    pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (UIProducerRejected issue, snapshot) -> do
          issue @?= UpiNonFiniteControlValue levelTag infinity
          sfisQueueDepth snapshot @?= 0
        Right other ->
          assertFailure ("expected UI rejection, got: " <> show other)

  , testCase "queue-full surfaces through UI enqueue result" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
          intent =
            UIVoiceOn (TemplateName "drone") (VoiceKey "u0") []
          expected =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "u0") []
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  opts
                  $ \host -> do
                    _prefill <-
                      enqueueSessionFanInCommand
                        (testProducer ProducerTest "prefill")
                        prefill
                        host
                    enqueueUIProducerIntent
                      testUIProducerOptions
                      intent
                      host
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (UIProducerEnqueueAttempted command enq) -> do
          command @?= expected
          sfierResult enq
            @?= SessionEnqueueRejected
                  (uiProducerId testUIProducerOptions)
                  expected
                  (SeiQueueFull 1)
        Right other ->
          assertFailure ("expected queue-full UI enqueue, got: " <> show other)

  , testCase "service host wakes worker for UI voice-on" $ do
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueUIProducerIntent
                       testUIProducerOptions
                       (UIVoiceOn (TemplateName "drone") (VoiceKey "u0") [])
                       (sessionFanInServiceHost service)
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (UIProducerEnqueueAttempted _ enq, Just drained, snapshot) -> do
          queued <- fanInQueuedOrFail enq
          map sdiQueued (sdrItems (sfidrDrain drained)) @?= [queued]
          case map sdiResult (sdrItems (sfidrDrain drained)) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure
                ("expected UI voice-on to commit through service, got: "
                 <> show other)
          sfisQueueDepth snapshot @?= 0
          assertBool
            "expected UI voice after service drain"
            (M.member (VoiceKey "u0") (ssVoices (sfisOwnerState snapshot)))
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for UI service drain"
        Right other ->
          assertFailure ("expected UI service enqueue, got: " <> show other)

  , testCase "arbitrated service UI enqueue defaults to FIFO" $ do
      let intent =
            UIVoiceOn (TemplateName "drone") (VoiceKey "u0") []
          expected =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "u0") []
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueArbitratedUIProducerIntent
                       testUIProducerOptions
                       intent
                       service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( UIProducerArbitratedEnqueueAttempted command gatewayResult
          , Just drained
          , snapshot
          ) -> do
            command @?= expected
            queued <- gatewayQueuedOrFail gatewayResult
            qscProducer queued @?= uiProducerId testUIProducerOptions
            qscCommand queued @?= expected
            map sdiQueued (sdrItems (sfidrDrain drained)) @?= [queued]
            case map sdiResult (sdrItems (sfidrDrain drained)) of
              [SessionOwnerStep (StepCommitted _ Nothing)] ->
                pure ()
              other ->
                assertFailure
                  ("expected arbitrated UI voice-on to commit, got: "
                   <> show other)
            sfisQueueDepth snapshot @?= 0
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for arbitrated UI service drain"
        Right other ->
          assertFailure ("expected arbitrated UI service enqueue, got: "
                         <> show other)

  , testCase "arbitrated service UI rejection reports service issue" $ do
      let intent =
            UIControlWrite (VoiceKey "u0") levelTag 0.75
          expected =
            CmdControlWrite (VoiceKey "u0") levelTag 0.75
          producer = uiProducerId testUIProducerOptions
          claimant = testProducer ProducerOSC "osc"
          target =
            ControlArbitrationTarget (VoiceKey "u0") levelTag
          serviceOpts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = producer
            , aiCommand   = expected
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
              enq <- enqueueArbitratedUIProducerIntent
                       testUIProducerOptions
                       intent
                       service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              mDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mIssue, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( UIProducerArbitratedEnqueueAttempted command rejected
          , Just reported
          , Nothing
          , snapshot
          ) -> do
            command @?= expected
            rejected @?= SagArbitrationRejected expectedIssue
            reported @?= SfsiiArbitrationRejected expectedIssue
            sfisQueueDepth snapshot @?= 0
        Right (UIProducerArbitratedRejected issue, _mIssue, _mDrain, _snapshot) ->
          assertFailure ("expected arbitrated enqueue attempt, got local rejection: "
                         <> show issue)
        Right (_enq, Nothing, _mDrain, _snapshot) ->
          assertFailure "timed out waiting for UI arbitration rejection issue"
        Right (_enq, Just _reported, Just extraDrain, _snapshot) ->
          assertFailure
            ("UI policy rejection unexpectedly woke service drain: "
             <> show extraDrain)

  , testCase "arbitrated service UI decode rejection does not report issue" $ do
      let infinity = 1.0 / 0.0
          intent = UIControlWrite (VoiceKey "u0") levelTag infinity
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnIssue = putMVar issueVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              rejected <- enqueueArbitratedUIProducerIntent
                            testUIProducerOptions
                            intent
                            service
              mIssue <- timeout 100000 (takeMVar issueVar)
              snapshot <- readSessionFanInService service
              pure (rejected, mIssue, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (rejected, Nothing, snapshot) -> do
          rejected
            @?= UIProducerArbitratedRejected
                  (UpiNonFiniteControlValue levelTag infinity)
          sfisQueueDepth snapshot @?= 0
        Right (_rejected, Just issue, _snapshot) ->
          assertFailure
            ("UI decode rejection unexpectedly reported service issue: "
             <> show issue)
  ]

testUIProducerOptions :: UIProducerOptions
testUIProducerOptions = defaultUIProducerOptions
  { upoProducerName = T.pack "ui-test"
  }
