-- | Session Prep G: producer queue and owner drain tests.
--
-- These cases pin the 'SessionCommandQueue' — capacity validation,
-- 'enqueueSessionCommand' / 'SessionEnqueued' / 'SessionEnqueueRejected'
-- semantics, per-queue 'CommandSequence' allocation, and the
-- 'drainSessionCommandQueue' contract that runs queued commands
-- through a 'SessionOwner' until it stops (capacity full,
-- divergence, or empty).
--
-- Coverage:
--
--   * Default options construct a positive bounded queue;
--     non-positive capacities reject at construction.
--   * Enqueue success advances a per-queue 'CommandSequence';
--     enqueue failure on a full queue leaves both queue state and
--     the sequence counter untouched.
--   * Drain preserves FIFO order, producer identity, and per-item
--     'SessionOwnerStep' results, including the
--     non-state-mutating 'StepControlAccepted' shape.
--   * A hot-swap install failure mid-drain stops the drain with
--     the structured divergence reason and leaves the remaining
--     command queued for a subsequent drain attempt.
--   * Draining against an already-diverged owner returns
--     'SessionOwnerBlocked' for the first queued command and
--     stops immediately.
--
-- Extracted from "MetaSonic.Spec.Session" as the tenth slice of
-- the Session megafile split. The cohort's two private helpers
-- 'queueOrFail' and 'enqueueOrFail' moved to
-- "MetaSonic.Spec.SessionShared" in the same commit, because both
-- have remaining callers in the parent (Arbitration,
-- ArbitrationGateway, Host, FanIn cohorts) and now need a stable
-- shared home. 'duplicateFirstTwoTemplates' and 'testProducer'
-- continue to come from SessionShared unchanged.
module MetaSonic.Spec.Session.Queue (sessionQueueTests) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source         (MigrationKey (..))
import           MetaSonic.Pattern               (ControlTag (..),
                                                  Pattern (patternTemplates),
                                                  SwapLabel (..),
                                                  TemplateName (..),
                                                  VoiceKey (..))
import           MetaSonic.Pattern.Corpus        (arpeggioSendReturn,
                                                  droneVibrato)
import           MetaSonic.Session.Command
import           MetaSonic.Session.Owner
import           MetaSonic.Session.Queue
import           MetaSonic.Session.RTGraphAdapter (SessionAdapterSetupIssue (..))
import           MetaSonic.Session.Runtime
import           MetaSonic.Session.Step

import           MetaSonic.Spec.SessionShared    (duplicateFirstTwoTemplates,
                                                  enqueueOrFail, queueOrFail,
                                                  testProducer)


sessionQueueTests :: TestTree
sessionQueueTests = testGroup "Session Prep G: producer queue"
  [ testCase "default options construct a positive bounded queue" $ do
      sqoCapacity defaultSessionQueueOptions @?= 128
      case newSessionCommandQueue defaultSessionQueueOptions of
        Left issue ->
          assertFailure ("expected default queue, got: " <> show issue)
        Right queue ->
          queue @?= queue

  , testCase "invalid queue capacities reject at construction" $ do
      newSessionCommandQueue (SessionQueueOptions 0)
        @?= Left (SqsiInvalidCapacity 0)
      newSessionCommandQueue (SessionQueueOptions (-1))
        @?= Left (SqsiInvalidCapacity (-1))

  , testCase "enqueue assigns per-queue sequence and rejects when full" $ do
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let pat = testProducer ProducerPattern "pattern"
          osc = testProducer ProducerOSC "osc"
          cmd0 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          cmd1 = CmdVoiceOff (VoiceKey "v0")
          cmd2 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v1") []
          (queue1, enq0) = enqueueSessionCommand pat cmd0 queue0
          (queue2, enq1) = enqueueSessionCommand osc cmd1 queue1
          (queue3, enq2) = enqueueSessionCommand pat cmd2 queue2
      case (enq0, enq1) of
        (SessionEnqueued q0, SessionEnqueued q1) -> do
          qscSequence q0 @?= CommandSequence 0
          qscSequence q1 @?= CommandSequence 1
          qscProducer q0 @?= pat
          qscProducer q1 @?= osc
        other ->
          assertFailure ("expected two accepted enqueues, got: " <> show other)
      enq2 @?= SessionEnqueueRejected pat cmd2 (SeiQueueFull 2)
      queue3 @?= queue2

  , testCase "rejected enqueue does not consume a sequence number" $ do
      queue0 <- queueOrFail (SessionQueueOptions 1)
      let producer = testProducer ProducerTest "test"
          cmd0 = CmdVoiceOn (TemplateName "missing") (VoiceKey "v0") []
          rejectedCmd = CmdVoiceOn (TemplateName "missing") (VoiceKey "v1") []
          cmd1 = CmdVoiceOn (TemplateName "missing") (VoiceKey "v2") []
      (queue1, queued0) <- enqueueOrFail producer cmd0 queue0
      qscSequence queued0 @?= CommandSequence 0
      let (queueFull, rejected) =
            enqueueSessionCommand producer rejectedCmd queue1
      rejected @?=
        SessionEnqueueRejected producer rejectedCmd (SeiQueueFull 1)
      queueFull @?= queue1
      drained <- withSessionOwner
                   (patternTemplates droneVibrato)
                   defaultSessionOwnerOptions
                   (`drainSessionCommandQueue` queueFull)
      queue2 <- case drained of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (queue2, drain) -> do
          map sdiQueued (sdrItems drain) @?= [queued0]
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          pure queue2
      (_queue3, queued1) <- enqueueOrFail producer cmd1 queue2
      qscSequence queued1 @?= CommandSequence 1

  , testCase "drain preserves FIFO order and producer identity" $ do
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let pat = testProducer ProducerPattern "pattern"
          osc = testProducer ProducerOSC "osc"
          cmd0 = CmdVoiceOn (TemplateName "missing") (VoiceKey "p0") []
          cmd1 = CmdVoiceOn (TemplateName "missing") (VoiceKey "o0") []
      (queue1, queued0) <- enqueueOrFail pat cmd0 queue0
      (queue2, queued1) <- enqueueOrFail osc cmd1 queue1
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  (`drainSessionCommandQueue` queue2)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (_queue3, drain) -> do
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          map sdiQueued (sdrItems drain) @?= [queued0, queued1]
          map sdiResult (sdrItems drain)
            @?= [ SessionOwnerStep
                    (StepRejected (SiUnknownTemplate (TemplateName "missing")))
                , SessionOwnerStep
                    (StepRejected (SiUnknownTemplate (TemplateName "missing")))
                ]

  , testCase "drain control-write accepts without owner state mutation" $ do
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let producer = testProducer ProducerUI "ui"
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          writeCmd = CmdControlWrite
                       (VoiceKey "v0")
                       (ControlTag (MigrationKey "lpf") 0)
                       900.0
      (queue1, queued) <- enqueueOrFail producer writeCmd queue0
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  $ \owner -> do
                    started <- stepSessionOwner owner startCmd
                    before <- sessionOwnerState owner
                    drained <- drainSessionCommandQueue owner queue1
                    afterState <- sessionOwnerState owner
                    pure (started, before, drained, afterState)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing),
               before, (_queue2, drain), afterState) -> do
          afterState @?= before
          sdrItems drain @?=
            [SessionDrainItem queued (SessionOwnerStep StepControlAccepted)]
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
        Right other ->
          assertFailure ("expected started owner and accepted control write, got: "
                         <> show other)

  , testCase "divergence stops drain and leaves remaining command queued" $ do
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let oldGraph = patternTemplates droneVibrato
          badGraph = duplicateFirstTwoTemplates
                       (patternTemplates arpeggioSendReturn)
          producer = testProducer ProducerPattern "pattern"
          issue = SasiDuplicateTemplateName (TemplateName "dup")
          divergedReason = SodHotSwapInstallFailed issue
          badSwap = CmdHotSwap (SwapLabel "bad-graph") badGraph
          later = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      (queue1, badQueued) <- enqueueOrFail producer badSwap queue0
      (queue2, laterQueued) <- enqueueOrFail producer later queue1
      firstDrain <- withSessionOwner oldGraph defaultSessionOwnerOptions $
        \owner -> drainSessionCommandQueue owner queue2
      (remainingQueue, firstResult) <- case firstDrain of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right value ->
          pure value
      sdrItems firstResult @?=
        [ SessionDrainItem
            badQueued
            (SessionOwnerDivergedNow
              (StepRuntimeFailed (SriHotSwapInstallFailed issue))
              divergedReason)
        ]
      sdrRemaining firstResult @?= 1
      sdrStopped firstResult @?= Just divergedReason

      secondDrain <- withSessionOwner oldGraph defaultSessionOwnerOptions $
        \owner -> drainSessionCommandQueue owner remainingQueue
      case secondDrain of
        Left setupIssue ->
          assertFailure ("expected second session owner, got: " <> show setupIssue)
        Right (_emptyQueue, secondResult) -> do
          map sdiQueued (sdrItems secondResult) @?= [laterQueued]
          case map sdiResult (sdrItems secondResult) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure ("expected remaining voice-start commit, got: "
                             <> show other)
          sdrRemaining secondResult @?= 0
          sdrStopped secondResult @?= Nothing

  , testCase "already-diverged owner blocks first queued command and stops" $ do
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let oldGraph = patternTemplates droneVibrato
          badGraph = duplicateFirstTwoTemplates
                       (patternTemplates arpeggioSendReturn)
          producer = testProducer ProducerTest "test"
          issue = SasiDuplicateTemplateName (TemplateName "dup")
          divergedReason = SodHotSwapInstallFailed issue
          badSwap = CmdHotSwap (SwapLabel "bad-graph") badGraph
          cmd0 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          cmd1 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v1") []
      (queue1, queued0) <- enqueueOrFail producer cmd0 queue0
      (queue2, _queued1) <- enqueueOrFail producer cmd1 queue1
      result <- withSessionOwner oldGraph defaultSessionOwnerOptions $
        \owner -> do
          diverged <- stepSessionOwner owner badSwap
          drained <- drainSessionCommandQueue owner queue2
          pure (diverged, drained)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (SessionOwnerDivergedNow
                 (StepRuntimeFailed (SriHotSwapInstallFailed _))
                 _,
               (_remainingQueue, drain)) -> do
          sdrItems drain @?=
            [SessionDrainItem queued0 (SessionOwnerBlocked divergedReason)]
          sdrRemaining drain @?= 1
          sdrStopped drain @?= Just divergedReason
        Right other ->
          assertFailure ("expected diverged owner then blocked drain, got: "
                         <> show other)
  ]
