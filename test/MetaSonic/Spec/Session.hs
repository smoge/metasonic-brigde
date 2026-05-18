{-# LANGUAGE LambdaCase #-}

-- | Session command, runtime ownership, queue, host, UI, and OSC producer tests.
module MetaSonic.Spec.Session where

import qualified Data.Map.Strict           as M
import qualified Data.Text                 as T
import           Data.List                 (sort)
import           Control.Concurrent        (forkIO, newEmptyMVar, putMVar,
                                            takeMVar)
import           Control.Monad             (forM, forM_)
import           Data.IORef                (modifyIORef', newIORef, readIORef,
                                            writeIORef)
import           System.Timeout            (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source
import qualified MetaSonic.OSC.Dispatch    as OSC
import qualified MetaSonic.OSC.Wire        as OSC
import           MetaSonic.Pattern
import           MetaSonic.Pattern.Corpus
import           MetaSonic.Session.Arbitration
import           MetaSonic.Session.ArbitrationGateway
import           MetaSonic.Session.Command
import           MetaSonic.Session.Runtime
import           MetaSonic.Session.State
import           MetaSonic.Session.Step
import           MetaSonic.Session.Owner
import           MetaSonic.Session.Queue
import           MetaSonic.Session.FanIn
import           MetaSonic.Session.FanInService
import           MetaSonic.Session.OSCProducer
import qualified MetaSonic.Session.OSCListener as OSCS
import           MetaSonic.Session.UIProducer
import           MetaSonic.Spec.Core
import           MetaSonic.Spec.SessionShared

import qualified Data.ByteString           as OBS
import qualified Data.ByteString.Char8     as OBSC

------------------------------------------------------------
-- Session Prep P: generic producer fan-in host
--
-- This is the first shared command-ingress host for concrete OSC,
-- MIDI, UI, Pattern, or future background producers. It remains
-- caller-driven: producers enqueue commands, and a caller or later
-- worker decides when to drain.
------------------------------------------------------------

sessionFanInHostTests :: TestTree
sessionFanInHostTests =
  testGroup "Session Prep P: producer fan-in host"
  [ testCase "drain preserves FIFO across OSC and MIDI producers" $ do
      let graph = patternTemplates droneVibrato
          oscProducer = testProducer ProducerOSC "osc"
          midiProducer = testProducer ProducerMIDI "midi"
          startCmd =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          writeCmd =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              650.0
      result <- withSessionFanInHost graph defaultSessionFanInOptions $
        \host -> do
          enq0 <- enqueueSessionFanInCommand oscProducer startCmd host
          enq1 <- enqueueSessionFanInCommand midiProducer writeCmd host
          drained <- drainSessionFanInHost host
          snapshot <- readSessionFanInHost host
          pure (enq0, enq1, drained, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (enq0, enq1, drained, snapshot) -> do
          q0 <- fanInQueuedOrFail enq0
          q1 <- fanInQueuedOrFail enq1
          qscSequence q0 @?= CommandSequence 0
          qscSequence q1 @?= CommandSequence 1
          map (qscProducer . sdiQueued) (sdrItems (sfidrDrain drained))
            @?= [oscProducer, midiProducer]
          case map sdiResult (sdrItems (sfidrDrain drained)) of
            [ SessionOwnerStep (StepCommitted _ Nothing)
              , SessionOwnerStep StepControlAccepted
              ] ->
                pure ()
            other ->
              assertFailure
                ("expected voice start then control write, got: " <> show other)
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshot @?= 0
          sfisOwnerStatus snapshot @?= SessionOwnerReady
          assertBool
            "expected v0 in fan-in owner state after drain"
            (M.member (VoiceKey "v0") (ssVoices (sfisOwnerState snapshot)))

  , testCase "bounded queue rejects excess producer command" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd0 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          cmd1 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v1") []
      result <- withSessionFanInHost graph opts $ \host -> do
        enq0 <- enqueueSessionFanInCommand producer cmd0 host
        enq1 <- enqueueSessionFanInCommand producer cmd1 host
        snapshot <- readSessionFanInHost host
        pure (enq0, enq1, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (enq0, enq1, snapshot) -> do
          _queued <- fanInQueuedOrFail enq0
          sfierResult enq1
            @?= SessionEnqueueRejected producer cmd1 (SeiQueueFull 1)
          sfierQueueDepth enq1 @?= 1
          sfisQueueDepth snapshot @?= 1
          sfisOwnerStatus snapshot @?= SessionOwnerReady

  , testCase "concurrent producer enqueues serialize sequence numbers" $ do
      let graph = patternTemplates droneVibrato
          opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 4
            }
      result <- withSessionFanInHost graph opts $ \host -> do
        done <- newEmptyMVar
        let worker producer voiceKey =
              enqueueSessionFanInCommand
                producer
                (CmdVoiceOn (TemplateName "drone") voiceKey [])
                host
                >>= putMVar done
        _ <- forkIO (worker (testProducer ProducerOSC "osc") (VoiceKey "v0"))
        _ <- forkIO (worker (testProducer ProducerMIDI "midi") (VoiceKey "v1"))
        mEnq0 <- timeout 1000000 (takeMVar done)
        mEnq1 <- timeout 1000000 (takeMVar done)
        snapshot <- readSessionFanInHost host
        pure (mEnq0, mEnq1, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just enq0, Just enq1, snapshot) -> do
          let results = [sfierResult enq0, sfierResult enq1]
              queued =
                [ queuedCommand
                | SessionEnqueued queuedCommand <- results
                ]
          length queued @?= 2
          sort (map qscSequence queued)
            @?= [CommandSequence 0, CommandSequence 1]
          sort (map (producerKind . qscProducer) queued)
            @?= [ProducerOSC, ProducerMIDI]
          sfisQueueDepth snapshot @?= 2
        Right other ->
          assertFailure ("timed out waiting for fan-in enqueues: "
                         <> show other)

  , testCase "many concurrent producer enqueues keep contiguous sequences" $ do
      let workerCount = 32
          graph = patternTemplates droneVibrato
          opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions workerCount
            }
          producerFor i =
            testProducer
              (if even i then ProducerOSC else ProducerMIDI)
              ("producer-" <> show i)
          commandFor i =
            CmdVoiceOn
              (TemplateName "drone")
              (VoiceKey ("v" <> show i))
              []
      result <- withSessionFanInHost graph opts $ \host -> do
        done <- newEmptyMVar
        let worker i =
              enqueueSessionFanInCommand
                (producerFor i)
                (commandFor i)
                host
                >>= putMVar done
        forM_ [0 .. workerCount - 1] $ \i ->
          forkIO (worker i)
        enqueues <- forM [0 .. workerCount - 1] $ \_ ->
          timeout 2000000 (takeMVar done)
        snapshot <- readSessionFanInHost host
        pure (enqueues, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (mEnqueues, snapshot) ->
          case sequence mEnqueues of
            Nothing ->
              assertFailure "timed out waiting for fan-in enqueue workers"
            Just enqueues -> do
              let queued =
                    [ queuedCommand
                    | SessionEnqueued queuedCommand <-
                        map sfierResult enqueues
                    ]
              length queued @?= workerCount
              sort (map qscSequence queued)
                @?= map (CommandSequence . fromIntegral)
                      [0 .. workerCount - 1]
              sfisQueueDepth snapshot @?= workerCount

  , testCase "drain divergence leaves unprocessed tail queued" $ do
      let oldGraph = patternTemplates droneVibrato
          badGraph =
            duplicateFirstTwoTemplates (patternTemplates arpeggioSendReturn)
          producer = testProducer ProducerUI "ui"
          issue = SasiDuplicateTemplateName (TemplateName "dup")
          reason = SodHotSwapInstallFailed issue
          badCmd = CmdHotSwap (SwapLabel "bad-graph") badGraph
          laterCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      result <- withSessionFanInHost oldGraph defaultSessionFanInOptions $
        \host -> do
          enq0 <- enqueueSessionFanInCommand producer badCmd host
          _enq1 <- enqueueSessionFanInCommand producer laterCmd host
          drained <- drainSessionFanInHost host
          snapshot <- readSessionFanInHost host
          pure (enq0, drained, snapshot)
      case result of
        Left setupIssue ->
          assertFailure ("expected fan-in host, got: " <> show setupIssue)
        Right (enq0, drained, snapshot) -> do
          queued0 <- fanInQueuedOrFail enq0
          sdrItems (sfidrDrain drained) @?=
            [ SessionDrainItem
                queued0
                (SessionOwnerDivergedNow
                  (StepRuntimeFailed (SriHotSwapInstallFailed issue))
                  reason)
            ]
          sdrRemaining (sfidrDrain drained) @?= 1
          sdrStopped (sfidrDrain drained) @?= Just reason
          sfidrQueueDepth drained @?= 1
          sfisQueueDepth snapshot @?= 1
          sfisOwnerStatus snapshot @?= SessionOwnerDiverged reason
  ]

------------------------------------------------------------
-- Session fan-in drain service
--
-- This is the first minimal background lifecycle wrapper around the
-- generic fan-in host. It wakes on successful enqueue, drains the
-- existing FIFO host, reports stopped drains, and exits on owner
-- divergence. The raw enqueue path remains FIFO; arbitration is only
-- exercised through the explicit service-owned gateway path.
------------------------------------------------------------

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

------------------------------------------------------------
-- Session UI producer adapter
--
-- This adapter is Haskell-only and consumes already-decoded UI
-- intents. It is not a GUI toolkit binding, manifest reload path, or
-- authorization layer.
------------------------------------------------------------

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

------------------------------------------------------------
-- Session OSC producer adapter
--
-- The adapter is intentionally narrow: it reuses the OSC dispatch
-- symbolic decoder, converts only control writes to SessionCommand,
-- and submits them to the generic fan-in host as ProducerOSC.
------------------------------------------------------------

sessionOSCProducerTests :: TestTree
sessionOSCProducerTests =
  testGroup "Session OSC producer adapter"
  [ testCase "decodes symbolic OSC control write to session command" $ do
      let msg = OSC.OscMessage (OBSC.pack "/v0/lpf/1")
                                [OSC.OscArgFloat 1800.0]
      decodeOSCSessionCommand msg
        @?= Right
              (CmdControlWrite
                (VoiceKey "v0")
                (ControlTag (MigrationKey "lpf") 1)
                1800.0)

  , testCase "valid control write enqueues under ProducerOSC" $ do
      let graph = patternTemplates droneVibrato
          opts = defaultOSCProducerOptions
          producer = oscProducerId opts
          msg = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                [OSC.OscArgInt 700]
          expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              700.0
      result <- withSessionFanInHost graph defaultSessionFanInOptions $
        \host -> do
          enq <- enqueueOSCControlWrite opts msg host
          snapshot <- readSessionFanInHost host
          pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (OSCProducerEnqueueAttempted command enq, snapshot) -> do
          command @?= expected
          queued <- fanInQueuedOrFail enq
          qscProducer queued @?= producer
          qscCommand queued @?= expected
          sfierQueueDepth enq @?= 1
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected OSC enqueue attempt, got: " <> show other)

  , testCase "arbitrated service path defaults to FIFO behavior" $ do
      let graph = patternTemplates droneVibrato
          opts = defaultOSCProducerOptions
          producer = oscProducerId opts
          msg = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                [OSC.OscArgFloat 1200.0]
          expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1200.0
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueArbitratedOSCControlWrite opts msg service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( OSCProducerArbitratedEnqueueAttempted command gatewayResult
          , Just drained
          , snapshot
          ) -> do
            command @?= expected
            queued <- gatewayQueuedOrFail gatewayResult
            qscProducer queued @?= producer
            qscCommand queued @?= expected
            case map sdiResult (sdrItems (sfidrDrain drained)) of
              [SessionOwnerStep (StepRejected (SiStaleVoice (VoiceKey "v0")))] ->
                pure ()
              other ->
                assertFailure
                  ("expected stale OSC control-write drain, got: "
                   <> show other)
            sfidrQueueDepth drained @?= 0
            sfisQueueDepth snapshot @?= 0
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for arbitrated OSC service drain"
        Right other ->
          assertFailure
            ("expected arbitrated OSC enqueue through service, got: "
             <> show other)

  , testCase "arbitrated service path reports policy rejection" $ do
      let graph = patternTemplates droneVibrato
          opts = defaultOSCProducerOptions
          producer = oscProducerId opts
          claimant = testProducer ProducerUI "ui"
          target =
            ControlArbitrationTarget
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
          msg = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                [OSC.OscArgFloat 1200.0]
          expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1200.0
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
          graph
          serviceOpts
          $ \service -> do
              rejected <- enqueueArbitratedOSCControlWrite opts msg service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              mDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (rejected, mIssue, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( OSCProducerArbitratedEnqueueAttempted command rejected
          , Just reported
          , Nothing
          , snapshot
          ) -> do
            command @?= expected
            rejected @?= SagArbitrationRejected expectedIssue
            reported @?= SfsiiArbitrationRejected expectedIssue
            sfisQueueDepth snapshot @?= 0
        Right (_rejected, Nothing, _mDrain, _snapshot) ->
          assertFailure "timed out waiting for OSC arbitration issue"
        Right (_rejected, Just _reported, Just extraDrain, _snapshot) ->
          assertFailure
            ("OSC policy rejection unexpectedly woke service drain: "
             <> show extraDrain)

  , testCase "arbitrated service path decode rejection does not report issue" $ do
      let graph = patternTemplates droneVibrato
          msg = OSC.OscMessage (OBSC.pack "/swap/lpf/0")
                                [OSC.OscArgFloat 1.0]
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnIssue = putMVar issueVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              rejected <-
                enqueueArbitratedOSCControlWrite
                  defaultOSCProducerOptions
                  msg
                  service
              mIssue <- timeout 100000 (takeMVar issueVar)
              snapshot <- readSessionFanInService service
              pure (rejected, mIssue, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (rejected, Nothing, snapshot) -> do
          rejected @?=
            OSCProducerArbitratedDecodeRejected
              (OSC.DiReservedPathSegment (OBSC.pack "swap"))
          sfisQueueDepth snapshot @?= 0
        Right (_rejected, Just issue, _snapshot) ->
          assertFailure
            ("OSC decode rejection unexpectedly reported service issue: "
             <> show issue)

  , testCase "reserved and invalid identifiers are rejected" $ do
      let cases =
            [ ( "reserved voice"
              , OSC.OscMessage (OBSC.pack "/swap/lpf/0")
                                [OSC.OscArgFloat 1.0]
              , OSC.DiReservedPathSegment (OBSC.pack "swap")
              )
            , ( "invalid voice"
              , OSC.OscMessage (OBSC.pack "/bad name/lpf/0")
                                [OSC.OscArgFloat 1.0]
              , OSC.DiIdentifierProfile (OBSC.pack "bad name")
              )
            , ( "invalid node tag"
              , OSC.OscMessage (OBSC.pack "/v0/bad name/0")
                                [OSC.OscArgFloat 1.0]
              , OSC.DiIdentifierProfile (OBSC.pack "bad name")
              )
            ]
      forM_ cases $ \(label, msg, expected) ->
        case decodeOSCSessionCommand msg of
          Left issue ->
            issue @?= expected
          Right command ->
            assertFailure
              (label <> ": expected decode rejection, got "
               <> show command)

  , testCase "bad slots and argument shapes are rejected" $ do
      let cases =
            [ ( "non-integer slot"
              , OSC.OscMessage (OBSC.pack "/v0/lpf/cutoff")
                                [OSC.OscArgFloat 1.0]
              , OSC.DiSlotNotInteger (OBSC.pack "cutoff")
              )
            , ( "zero args"
              , OSC.OscMessage (OBSC.pack "/v0/lpf/0") []
              , OSC.DiUnsupportedArgShape 0
              )
            , ( "two args"
              , OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                [OSC.OscArgFloat 1.0, OSC.OscArgInt 2]
              , OSC.DiUnsupportedArgShape 2
              )
            ]
      forM_ cases $ \(label, msg, expected) ->
        case decodeOSCSessionCommand msg of
          Left issue ->
            issue @?= expected
          Right command ->
            assertFailure
              (label <> ": expected decode rejection, got "
               <> show command)

  , testCase "decode rejection does not enqueue" $ do
      let graph = patternTemplates droneVibrato
          msg = OSC.OscMessage (OBSC.pack "/swap/lpf/0")
                                [OSC.OscArgFloat 1.0]
      result <- withSessionFanInHost graph defaultSessionFanInOptions $
        \host -> do
          enq <- enqueueOSCControlWrite defaultOSCProducerOptions msg host
          snapshot <- readSessionFanInHost host
          pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (enq, snapshot) -> do
          enq @?= OSCProducerDecodeRejected
                    (OSC.DiReservedPathSegment (OBSC.pack "swap"))
          sfisQueueDepth snapshot @?= 0

  , testCase "queue-full surfaces through fan-in enqueue result" $ do
      let graph = patternTemplates droneVibrato
          opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          producer = oscProducerId defaultOSCProducerOptions
          msg0 = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                 [OSC.OscArgFloat 800.0]
          msg1 = OSC.OscMessage (OBSC.pack "/v1/lpf/0")
                                 [OSC.OscArgFloat 900.0]
          cmd1 =
            CmdControlWrite
              (VoiceKey "v1")
              (ControlTag (MigrationKey "lpf") 0)
              900.0
      result <- withSessionFanInHost graph opts $ \host -> do
        enq0 <- enqueueOSCControlWrite defaultOSCProducerOptions msg0 host
        enq1 <- enqueueOSCControlWrite defaultOSCProducerOptions msg1 host
        snapshot <- readSessionFanInHost host
        pure (enq0, enq1, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (OSCProducerEnqueueAttempted _ first, second, snapshot) -> do
          _queued <- fanInQueuedOrFail first
          second
            @?= OSCProducerEnqueueAttempted
                  cmd1
                  SessionFanInEnqueueResult
                    { sfierResult =
                        SessionEnqueueRejected
                          producer
                          cmd1
                          (SeiQueueFull 1)
                    , sfierQueueDepth = 1
                    }
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected queue-full OSC enqueue, got: "
                         <> show other)
  ]

------------------------------------------------------------
-- Session OSC listener adapter
--
-- This is the UDP wrapper above the OSC producer adapter. It only
-- enqueues into SessionFanInHost; draining stays caller-driven.
------------------------------------------------------------

sessionOSCListenerTests :: TestTree
sessionOSCListenerTests =
  testGroup "Session OSC listener adapter"
  [ testCase "bracket cleanup: body return tears down listener" $ do
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              OSCS.withSessionOSCListener
                defaultOSCProducerOptions
                host
                (OSCS.defaultListenerConfig 0)
                (\_info -> pure (42 :: Int))
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right value ->
          value @?= 42

  , testCase "loopback packet enqueues but does not drain" $ do
      let expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1500.0
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host -> do
              received <- newEmptyMVar
              let hooks = OSCS.SessionOSCListenerHooks
                    { OSCS.solhOnProducerResult = putMVar received
                    , OSCS.solhOnIssue          = \_ -> pure ()
                    }
              OSCS.withSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                host
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mResult <- timeout 1000000 (takeMVar received)
                    snapshot <- readSessionFanInHost host
                    pure (mResult, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (OSCProducerEnqueueAttempted command enq), snapshot) -> do
          command @?= expected
          queued <- fanInQueuedOrFail enq
          qscCommand queued @?= expected
          producerKind (qscProducer queued) @?= ProducerOSC
          sfisQueueDepth snapshot @?= 1
          sfisOwnerStatus snapshot @?= SessionOwnerReady
          ssVoices (sfisOwnerState snapshot) @?= M.empty
        Right other ->
          assertFailure ("expected one OSC producer result, got: "
                         <> show other)

  , testCase "arbitrated service listener loopback defaults to FIFO" $ do
      let expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1500.0
          producer = oscProducerId defaultOSCProducerOptions
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              received <- newEmptyMVar
              let hooks = OSCS.SessionOSCArbitratedListenerHooks
                    { OSCS.solahOnProducerResult = putMVar received
                    , OSCS.solahOnIssue          = \_ -> pure ()
                    }
              OSCS.withArbitratedSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                service
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mResult <- timeout 1000000 (takeMVar received)
                    mDrain <- timeout 1000000 (takeMVar drainedVar)
                    snapshot <- readSessionFanInService service
                    pure (mResult, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( Just (OSCProducerArbitratedEnqueueAttempted command gatewayResult)
          , Just drained
          , snapshot
          ) -> do
            command @?= expected
            queued <- gatewayQueuedOrFail gatewayResult
            qscProducer queued @?= producer
            qscCommand queued @?= expected
            case map sdiResult (sdrItems (sfidrDrain drained)) of
              [SessionOwnerStep (StepRejected (SiStaleVoice (VoiceKey "v0")))] ->
                pure ()
              other ->
                assertFailure
                  ("expected stale OSC control-write drain, got: "
                   <> show other)
            sfidrQueueDepth drained @?= 0
            sfisQueueDepth snapshot @?= 0
        Right (Nothing, _mDrain, _snapshot) ->
          assertFailure
            "timed out waiting for arbitrated OSC listener result"
        Right (_mResult, Nothing, _snapshot) ->
          assertFailure
            "timed out waiting for arbitrated OSC listener drain"
        Right other ->
          assertFailure
            ("expected arbitrated OSC listener enqueue, got: "
             <> show other)

  , testCase "arbitrated service listener reports policy rejection" $ do
      let expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1500.0
          producer = oscProducerId defaultOSCProducerOptions
          claimant = testProducer ProducerUI "ui"
          target =
            ControlArbitrationTarget
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
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
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          serviceOpts
          $ \service -> do
              received <- newEmptyMVar
              issues <- newEmptyMVar
              let hooks = OSCS.SessionOSCArbitratedListenerHooks
                    { OSCS.solahOnProducerResult = putMVar received
                    , OSCS.solahOnIssue          = putMVar issues
                    }
              OSCS.withArbitratedSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                service
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mResult <- timeout 1000000 (takeMVar received)
                    mIssue <- timeout 1000000 (takeMVar issues)
                    mDrain <- timeout 100000 (takeMVar drainedVar)
                    snapshot <- readSessionFanInService service
                    pure (mResult, mIssue, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( Just (OSCProducerArbitratedEnqueueAttempted command rejected)
          , Just reported
          , Nothing
          , snapshot
          ) -> do
            command @?= expected
            rejected @?= SagArbitrationRejected expectedIssue
            reported @?= OSCS.SoliArbitrationRejected expectedIssue
            sfisQueueDepth snapshot @?= 0
        Right (Nothing, _mIssue, _mDrain, _snapshot) ->
          assertFailure
            "timed out waiting for arbitrated OSC listener result"
        Right (_mResult, Nothing, _mDrain, _snapshot) ->
          assertFailure
            "timed out waiting for arbitrated OSC listener issue"
        Right (_mResult, Just _reported, Just extraDrain, _snapshot) ->
          assertFailure
            ("OSC listener policy rejection unexpectedly woke service drain: "
             <> show extraDrain)
        Right other ->
          assertFailure
            ("expected arbitrated OSC listener policy rejection, got: "
             <> show other)

  , testCase "arbitrated listener parse issue continues" $ do
      result <-
        withSessionFanInService
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              issues <- newIORef []
              validDone <- newEmptyMVar
              let hooks = OSCS.SessionOSCArbitratedListenerHooks
                    { OSCS.solahOnProducerResult =
                        \result -> case result of
                          OSCProducerArbitratedEnqueueAttempted {} ->
                            putMVar validDone ()
                          OSCProducerArbitratedDecodeRejected {} ->
                            pure ()
                    , OSCS.solahOnIssue =
                        \issue -> modifyIORef' issues (issue :)
                    }
              OSCS.withArbitratedSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                service
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback (OSCS.liBoundPort info)
                                    (OBS.pack [0x01, 0x02, 0x03, 0x04])
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mDone <- timeout 1000000 (takeMVar validDone)
                    issueList <- readIORef issues
                    pure (mDone, issueList)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (Just (), issueList) ->
          assertBool
            ("expected parse failure issue, got: " <> show issueList)
            (any isSessionParseFailure issueList)
        Right other ->
          assertFailure
            ("valid packet was not accepted after malformed one: "
             <> show other)

  , testCase "malformed packet surfaces parse issue; listener continues" $ do
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host -> do
              issues <- newIORef []
              validDone <- newEmptyMVar
              let hooks = OSCS.SessionOSCListenerHooks
                    { OSCS.solhOnProducerResult =
                        \result -> case result of
                          OSCProducerEnqueueAttempted {} ->
                            putMVar validDone ()
                          OSCProducerDecodeRejected {} ->
                            pure ()
                    , OSCS.solhOnIssue =
                        \issue -> modifyIORef' issues (issue :)
                    }
              OSCS.withSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                host
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback (OSCS.liBoundPort info)
                                    (OBS.pack [0x01, 0x02, 0x03, 0x04])
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mDone <- timeout 1000000 (takeMVar validDone)
                    issueList <- readIORef issues
                    pure (mDone, issueList)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (), issueList) ->
          assertBool
            ("expected parse failure issue, got: " <> show issueList)
            (any isSessionParseFailure issueList)
        Right other ->
          assertFailure ("valid packet was not accepted after malformed one: "
                         <> show other)

  , testCase "decode rejection reports issue and does not enqueue" $ do
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host -> do
              issues <- newEmptyMVar
              let hooks = OSCS.SessionOSCListenerHooks
                    { OSCS.solhOnProducerResult = \_ -> pure ()
                    , OSCS.solhOnIssue          = putMVar issues
                    }
              OSCS.withSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                host
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesSwapLpfFloat
                    mIssue <- timeout 1000000 (takeMVar issues)
                    snapshot <- readSessionFanInHost host
                    pure (mIssue, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just issue, snapshot) -> do
          issue
            @?= OSCS.SoliDecodeFailure
                  (OSC.DiReservedPathSegment (OBSC.pack "swap"))
          sfisQueueDepth snapshot @?= 0
        Right other ->
          assertFailure ("expected decode issue, got: " <> show other)

  , testCase "queue-full surfaces as listener issue" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
          expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1500.0
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          opts
          $ \host -> do
              _prefillResult <-
                enqueueSessionFanInCommand
                  (testProducer ProducerTest "prefill")
                  prefill
                  host
              issues <- newEmptyMVar
              let hooks = OSCS.SessionOSCListenerHooks
                    { OSCS.solhOnProducerResult = \_ -> pure ()
                    , OSCS.solhOnIssue          = putMVar issues
                    }
              OSCS.withSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                host
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mIssue <- timeout 1000000 (takeMVar issues)
                    snapshot <- readSessionFanInHost host
                    pure (mIssue, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just issue, snapshot) -> do
          issue @?= OSCS.SoliEnqueueRejected expected (SeiQueueFull 1)
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected queue-full listener issue, got: "
                         <> show other)
  ]
  where
    isSessionParseFailure (OSCS.SoliParseFailure _) = True
    isSessionParseFailure _                         = False
