-- | Session Prep P: generic producer fan-in host tests.
--
-- This is the first shared command-ingress host for concrete OSC,
-- MIDI, UI, Pattern, or future background producers. It remains
-- caller-driven: producers enqueue commands, and a caller or later
-- worker decides when to drain. The companion service (worker
-- lifecycle around this host) lives in
-- "MetaSonic.Spec.Session.FanInService".
module MetaSonic.Spec.Session.FanInHost
  ( sessionFanInHostTests
  ) where

import qualified Data.Map.Strict           as M
import           Control.Concurrent        (forkIO, newEmptyMVar, putMVar,
                                            takeMVar)
import           Control.Monad             (forM, forM_)
import           Data.List                 (sort)
import           System.Timeout            (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source            (MigrationKey (..))
import           MetaSonic.Pattern                  (ControlTag (..),
                                                     Pattern (..),
                                                     SwapLabel (..),
                                                     TemplateName (..),
                                                     VoiceKey (..))
import           MetaSonic.Pattern.Corpus           (arpeggioSendReturn,
                                                     droneVibrato)
import           MetaSonic.Session.AdapterIssue     (SessionAdapterSetupIssue (..))
import           MetaSonic.Session.Command          (SessionCommand (..))
import           MetaSonic.Session.FanIn
import           MetaSonic.Session.Owner            (SessionOwnerDivergence (..),
                                                     SessionOwnerStatus (..),
                                                     SessionOwnerStepResult (..))
import           MetaSonic.Session.Queue
import           MetaSonic.Session.Runtime          (SessionRuntimeIssue (..))
import           MetaSonic.Session.State            (ssVoices)
import           MetaSonic.Session.Step             (SessionStepResult (..))
import           MetaSonic.Spec.SessionShared       (duplicateFirstTwoTemplates,
                                                     fanInQueuedOrFail,
                                                     testProducer)

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
