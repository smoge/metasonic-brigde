-- | Session fan-in drain service tests.
--
-- This is the first minimal background lifecycle wrapper around the
-- generic fan-in host (covered in "MetaSonic.Spec.Session.FanInHost").
-- It wakes on successful enqueue, drains the existing FIFO host,
-- reports stopped drains, and exits on owner divergence. The raw
-- enqueue path remains FIFO; arbitration is only exercised through
-- the explicit service-owned gateway path.
module MetaSonic.Spec.Session.FanInService
  ( sessionFanInServiceTests
  ) where

import qualified Data.Map.Strict           as M
import qualified Data.ByteString.Char8     as OBSC
import           Control.Concurrent        (forkIO, newEmptyMVar, putMVar,
                                            takeMVar)
import           Data.IORef                (newIORef, readIORef, writeIORef)
import           System.Timeout            (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source            (MigrationKey (..))
import qualified MetaSonic.OSC.Wire                 as OSC
import           MetaSonic.Pattern                  (ControlTag (..),
                                                     Pattern (..),
                                                     SwapLabel (..),
                                                     TemplateName (..),
                                                     VoiceKey (..))
import           MetaSonic.Pattern.Corpus           (arpeggioSendReturn,
                                                     droneVibrato)
import           MetaSonic.Session.AdapterIssue     (SessionAdapterSetupIssue (..))
import           MetaSonic.Session.Arbitration
import           MetaSonic.Session.ArbitrationGateway
import           MetaSonic.Session.Command          (SessionCommand (..),
                                                     SessionIssue (..))
import           MetaSonic.Session.FanIn
import           MetaSonic.Session.FanInService
import           MetaSonic.Session.OSCProducer
import           MetaSonic.Session.Owner            (SessionOwnerDivergence (..),
                                                     SessionOwnerStatus (..),
                                                     SessionOwnerStepResult (..))
import           MetaSonic.Session.Queue
import           MetaSonic.Session.Runtime          (SessionRuntimeIssue (..))
import           MetaSonic.Session.State            (ssVoices)
import           MetaSonic.Session.Step             (SessionStepResult (..))
import           MetaSonic.Spec.SessionShared       (duplicateFirstTwoTemplates,
                                                     fanInQueuedOrFail, freqTag,
                                                     gatewayQueuedOrFail,
                                                     levelTag, testProducer)

sessionFanInServiceTests :: TestTree
sessionFanInServiceTests =
  testGroup "Session fan-in drain service"
  [ testCase "bracket cleanup: body return tears down worker" $ do
      result <-
        withSessionFanInService
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> readSessionFanInService service
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right snapshot -> do
          sfisQueueDepth snapshot @?= 0
          sfisOwnerStatus snapshot @?= SessionOwnerReady

  , testCase "bracket cleanup kills worker when drain hook blocks" $ do
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      hookEntered <- newEmptyMVar
      neverRelease <- newEmptyMVar
      result <- timeout 1000000 $
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain =
                \_drained -> do
                  putMVar hookEntered ()
                  takeMVar neverRelease
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueSessionFanInServiceCommand producer cmd service
              mEntered <- timeout 1000000 (takeMVar hookEntered)
              pure (enq, mEntered)
      case result of
        Nothing ->
          assertFailure
            "service teardown hung while drain hook was blocked"
        Just (Left issue) ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Just (Right (enq, Just ())) -> do
          _queued <- fanInQueuedOrFail enq
          pure ()
        Just (Right (_enq, Nothing)) ->
          assertFailure "timed out waiting for blocking drain hook"

  , testCase "successful enqueue wakes background drain worker" $ do
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueSessionFanInServiceCommand producer cmd service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (enq, Just drained, snapshot) -> do
          queued <- fanInQueuedOrFail enq
          case sdrItems (sfidrDrain drained) of
            [SessionDrainItem drainedQueued
              (SessionOwnerStep (StepCommitted _ Nothing))] ->
                drainedQueued @?= queued
            other ->
              assertFailure
                ("expected one committed background drain, got: "
                 <> show other)
          sdrRemaining (sfidrDrain drained) @?= 0
          sdrStopped (sfidrDrain drained) @?= Nothing
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshot @?= 0
          assertBool
            "expected v0 in service owner state after background drain"
            (M.member (VoiceKey "v0") (ssVoices (sfisOwnerState snapshot)))
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for service drain"

  , testCase "quiesce/drain waits for active worker and owns final drain" $ do
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          firstCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          secondCmd =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              0.75
      hookCount <- newIORef (0 :: Int)
      firstWorkerDrain <- newEmptyMVar
      releaseFirstHook <- newEmptyMVar
      unexpectedWorkerDrain <- newEmptyMVar
      finalDrainVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain =
                \drained -> do
                  n <- readIORef hookCount
                  writeIORef hookCount (n + 1)
                  if n == 0
                    then do
                      putMVar firstWorkerDrain drained
                      takeMVar releaseFirstHook
                    else
                      putMVar unexpectedWorkerDrain drained
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq0 <- enqueueSessionFanInServiceCommand
                        producer firstCmd service
              mFirstDrain <- timeout 1000000 (takeMVar firstWorkerDrain)
              enq1 <- enqueueSessionFanInServiceCommand
                        producer secondCmd service
              _worker <- forkIO $
                quiesceAndDrainSessionFanInService service
                  >>= putMVar finalDrainVar
              mEarlyFinal <- timeout 100000 (takeMVar finalDrainVar)
              putMVar releaseFirstHook ()
              mFinalDrain <- timeout 1000000 (takeMVar finalDrainVar)
              mUnexpectedWorkerDrain <-
                timeout 100000 (takeMVar unexpectedWorkerDrain)
              snapshot <- readSessionFanInService service
              pure
                ( enq0
                , mFirstDrain
                , enq1
                , mEarlyFinal
                , mFinalDrain
                , mUnexpectedWorkerDrain
                , snapshot
                )
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( enq0
          , Just firstDrain
          , enq1
          , Nothing
          , Just finalDrain
          , Nothing
          , snapshot
          ) -> do
            queued0 <- fanInQueuedOrFail enq0
            queued1 <- fanInQueuedOrFail enq1
            case sdrItems (sfidrDrain firstDrain) of
              [SessionDrainItem drainedQueued
                (SessionOwnerStep (StepCommitted _ Nothing))] ->
                  drainedQueued @?= queued0
              other ->
                assertFailure
                  ("expected first worker drain to own v0, got: "
                   <> show other)
            case sdrItems (sfidrDrain finalDrain) of
              [SessionDrainItem drainedQueued
                (SessionOwnerStep StepControlAccepted)] ->
                  drainedQueued @?= queued1
              other ->
                assertFailure
                  ("expected final quiesce drain to own control write, got: "
                   <> show other)
            sfidrQueueDepth finalDrain @?= 0
            sfisQueueDepth snapshot @?= 0
            assertBool
              "expected v0 in owner state after quiesce drain"
              (M.member (VoiceKey "v0") (ssVoices (sfisOwnerState snapshot)))
        Right (_enq0, Nothing, _enq1, _mEarly, _mFinal, _mUnexpected, _snapshot) ->
          assertFailure "timed out waiting for first worker drain"
        Right (_enq0, Just _first, _enq1, Just early, _mFinal, _mUnexpected, _snapshot) ->
          assertFailure
            ("quiesce final drain returned before worker settled: "
             <> show early)
        Right (_enq0, Just _first, _enq1, Nothing, Nothing, _mUnexpected, _snapshot) ->
          assertFailure "timed out waiting for final quiesce drain"
        Right (_enq0, Just _first, _enq1, Nothing, Just _final, Just extra, _snapshot) ->
          assertFailure
            ("background worker drained after quiesce request: "
             <> show extra)

  , testCase "quiesce rejects service enqueues without waking worker" $ do
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              finalDrain <- quiesceAndDrainSessionFanInService service
              rawRejected <- enqueueSessionFanInServiceCommand
                               producer cmd service
              arbitratedRejected <- enqueueArbitratedSessionFanInServiceCommand
                                      producer cmd service
              mWorkerDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure
                ( finalDrain
                , rawRejected
                , arbitratedRejected
                , mWorkerDrain
                , snapshot
                )
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (finalDrain, rawRejected, arbitratedRejected, Nothing, snapshot) -> do
          sdrItems (sfidrDrain finalDrain) @?= []
          sfidrQueueDepth finalDrain @?= 0
          sfierResult rawRejected @?=
            SessionEnqueueRejected producer cmd SeiReloadInProgress
          sfierQueueDepth rawRejected @?= 0
          case arbitratedRejected of
            SagEnqueueAttempted nested -> do
              sfierResult nested @?=
                SessionEnqueueRejected producer cmd SeiReloadInProgress
              sfierQueueDepth nested @?= 0
            other ->
              assertFailure
                ("expected quiesced arbitrated enqueue attempt, got: "
                 <> show other)
          sfisQueueDepth snapshot @?= 0
        Right (_finalDrain, _rawRejected, _arbitratedRejected, Just drained, _snapshot) ->
          assertFailure
            ("quiesced service unexpectedly woke worker: " <> show drained)

  , testCase "resume after quiesce starts a fresh drain worker" $ do
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              finalDrain <- quiesceAndDrainSessionFanInService service
              resumeSessionFanInService service
              enq <- enqueueSessionFanInServiceCommand producer cmd service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (finalDrain, enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (finalDrain, enq, Just drained, snapshot) -> do
          sdrItems (sfidrDrain finalDrain) @?= []
          sfidrQueueDepth finalDrain @?= 0
          queued <- fanInQueuedOrFail enq
          case sdrItems (sfidrDrain drained) of
            [SessionDrainItem drainedQueued
              (SessionOwnerStep (StepCommitted _ Nothing))] ->
                drainedQueued @?= queued
            other ->
              assertFailure
                ("expected resumed worker to drain one command, got: "
                 <> show other)
          sdrStopped (sfidrDrain drained) @?= Nothing
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshot @?= 0
        Right (_finalDrain, _enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for resumed service drain"

  , testCase "default arbitrated enqueue keeps FIFO service behavior" $ do
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueArbitratedSessionFanInServiceCommand
                       producer cmd service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (enq, Just drained, snapshot) -> do
          queued <- gatewayQueuedOrFail enq
          case sdrItems (sfidrDrain drained) of
            [SessionDrainItem drainedQueued
              (SessionOwnerStep (StepCommitted _ Nothing))] ->
                drainedQueued @?= queued
            other ->
              assertFailure
                ("expected one committed arbitrated drain, got: "
                 <> show other)
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshot @?= 0
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for arbitrated service drain"

  , testCase "configured arbitration rejects before service wake" $ do
      let graph = patternTemplates droneVibrato
          oscProducer = testProducer ProducerOSC "osc"
          patternProducer = testProducer ProducerPattern "pattern"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          command =
            CmdControlWrite (VoiceKey "v0") levelTag 0.5
          opts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      ProducerPriority
                        [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
                        emptyControlOwnerTable
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = patternProducer
            , aiCommand   = command
            , aiTarget    = Just target
            , aiReason    = ArrLowerPriorityThan oscProducer
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
          graph
          opts
          $ \service -> do
              enq0 <- enqueueArbitratedSessionFanInServiceCommand
                        oscProducer command service
              mFirstDrain <- timeout 1000000 (takeMVar drainedVar)
              rejected <- enqueueArbitratedSessionFanInServiceCommand
                            patternProducer command service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              mRejectedDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure
                ( enq0
                , mFirstDrain
                , rejected
                , mIssue
                , mRejectedDrain
                , snapshot
                )
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( enq0
          , Just _firstDrain
          , rejected
          , Just reported
          , Nothing
          , snapshot
          ) -> do
            queued0 <- gatewayQueuedOrFail enq0
            qscProducer queued0 @?= oscProducer
            qscSequence queued0 @?= CommandSequence 0
            rejected @?= SagArbitrationRejected expectedIssue
            reported @?= SfsiiArbitrationRejected expectedIssue
            sfisQueueDepth snapshot @?= 0
        Right (_enq0, Nothing, _rejected, _mIssue, _mRejectedDrain, _snapshot) ->
          assertFailure "timed out waiting for first arbitrated drain"
        Right (_enq0, Just _firstDrain, _rejected, Nothing, _mRejectedDrain, _snapshot) ->
          assertFailure "timed out waiting for arbitration rejection issue"
        Right (_enq0, Just _firstDrain, _rejected, Just _reported, Just extraDrain, _snapshot) ->
          assertFailure
            ("policy rejection unexpectedly woke service drain: "
             <> show extraDrain)

  , testCase "target-claim arbitration rejects before service wake" $ do
      let graph = patternTemplates droneVibrato
          claimant = testProducer ProducerUI "ui"
          blocked  = testProducer ProducerMIDI "midi"
          target =
            ControlArbitrationTarget (VoiceKey "v0") levelTag
          claimedCommand =
            CmdControlWrite (VoiceKey "v0") levelTag 0.25
          otherCommand =
            CmdControlWrite (VoiceKey "v0") freqTag 440.0
          opts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = blocked
            , aiCommand   = claimedCommand
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          opts
          $ \service -> do
              claimantEnq <- enqueueArbitratedSessionFanInServiceCommand
                               claimant claimedCommand service
              mFirstDrain <- timeout 1000000 (takeMVar drainedVar)
              rejected <- enqueueArbitratedSessionFanInServiceCommand
                            blocked claimedCommand service
              mRejectedDrain <- timeout 100000 (takeMVar drainedVar)
              otherEnq <- enqueueArbitratedSessionFanInServiceCommand
                            blocked otherCommand service
              mOtherDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure
                ( claimantEnq
                , mFirstDrain
                , rejected
                , mRejectedDrain
                , otherEnq
                , mOtherDrain
                , snapshot
                )
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( claimantEnq
          , Just _firstDrain
          , rejected
          , Nothing
          , otherEnq
          , Just _otherDrain
          , snapshot
          ) -> do
            q0 <- gatewayQueuedOrFail claimantEnq
            q1 <- gatewayQueuedOrFail otherEnq
            qscProducer q0 @?= claimant
            qscProducer q1 @?= blocked
            qscSequence q0 @?= CommandSequence 0
            qscSequence q1 @?= CommandSequence 1
            qscCommand q0 @?= claimedCommand
            qscCommand q1 @?= otherCommand
            rejected @?= SagArbitrationRejected expectedIssue
            sfisQueueDepth snapshot @?= 0
        Right (_claimantEnq, Nothing, _rejected, _mRejectedDrain, _otherEnq, _mOtherDrain, _snapshot) ->
          assertFailure "timed out waiting for claimant drain"
        Right (_claimantEnq, Just _firstDrain, _rejected, Just extraDrain, _otherEnq, _mOtherDrain, _snapshot) ->
          assertFailure
            ("target-claim rejection unexpectedly woke service drain: "
             <> show extraDrain)
        Right (_claimantEnq, Just _firstDrain, _rejected, Nothing, _otherEnq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for unrelated target drain"

  , testCase "service host wakes worker for OSC producer enqueue" $ do
      let graph = patternTemplates droneVibrato
          msg = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                [OSC.OscArgFloat 900.0]
          expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              900.0
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <-
                enqueueOSCControlWrite
                  defaultOSCProducerOptions
                  msg
                  (sessionFanInServiceHost service)
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (OSCProducerEnqueueAttempted command enq, Just drained, snapshot) -> do
          command @?= expected
          queued <- fanInQueuedOrFail enq
          qscCommand queued @?= expected
          producerKind (qscProducer queued) @?= ProducerOSC
          case map sdiResult (sdrItems (sfidrDrain drained)) of
            [SessionOwnerStep (StepRejected (SiStaleVoice (VoiceKey "v0")))] ->
              pure ()
            other ->
              assertFailure
                ("expected stale OSC control-write drain, got: " <> show other)
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshot @?= 0
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for OSC service drain"
        Right other ->
          assertFailure ("expected OSC enqueue through service, got: "
                         <> show other)

  , testCase "divergent drain reports issue and stops worker" $ do
      let oldGraph = patternTemplates droneVibrato
          badGraph =
            duplicateFirstTwoTemplates (patternTemplates arpeggioSendReturn)
          producer = testProducer ProducerUI "ui"
          setupIssue = SasiDuplicateTemplateName (TemplateName "dup")
          divergedReason = SodHotSwapInstallFailed setupIssue
          badCmd = CmdHotSwap (SwapLabel "bad-graph") badGraph
          laterCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnIssue = putMVar issueVar
            }
          oldGraph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq0 <- enqueueSessionFanInServiceCommand producer badCmd service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              enq1 <- enqueueSessionFanInServiceCommand producer laterCmd service
              snapshot <- readSessionFanInService service
              pure (enq0, mIssue, enq1, snapshot)
      case result of
        Left serviceIssue ->
          assertFailure ("expected fan-in service, got: " <> show serviceIssue)
        Right (enq0, Just (SfsiiDrainStopped stopped), enq1, snapshot) -> do
          queued0 <- fanInQueuedOrFail enq0
          queued1 <- fanInQueuedOrFail enq1
          sdrItems (sfidrDrain stopped) @?=
            [ SessionDrainItem
                queued0
                (SessionOwnerDivergedNow
                  (StepRuntimeFailed (SriHotSwapInstallFailed setupIssue))
                  divergedReason)
            ]
          sdrRemaining (sfidrDrain stopped) @?= 0
          sdrStopped (sfidrDrain stopped) @?= Just divergedReason
          sfidrQueueDepth stopped @?= 0
          qscSequence queued1 @?= CommandSequence 1
          sfisQueueDepth snapshot @?= 1
          sfisOwnerStatus snapshot @?= SessionOwnerDiverged divergedReason
        Right (_enq0, Nothing, _enq1, _snapshot) ->
          assertFailure "timed out waiting for service stopped-drain issue"
  ]
