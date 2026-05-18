-- | Session Prep I: scripted Pattern runner tests.
--
-- Drives 'stepPatternSession' through one-shot voice commit, backlog
-- retry across repeated steps, owner-divergence stop semantics, and
-- backlog cursor preservation. All helpers come from
-- "MetaSonic.Spec.SessionShared" (patternProducerOrFail, queueOrFail,
-- missingVoiceEventsAt, duplicateFirstTwoTemplates).
module MetaSonic.Spec.Session.Runner
  ( sessionRunnerTests
  ) where

import qualified Data.Map.Strict           as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source            (MigrationKey (..))
import           MetaSonic.Pattern
import           MetaSonic.Pattern.Corpus
import           MetaSonic.Session.AdapterIssue     (SessionAdapterSetupIssue (..))
import           MetaSonic.Session.Owner
import           MetaSonic.Session.PatternProducer
import           MetaSonic.Session.Queue
import           MetaSonic.Session.RTGraphAdapter
import           MetaSonic.Session.Runner
import           MetaSonic.Session.Runtime          (SessionRuntimeIssue (..))
import           MetaSonic.Session.State            (ssVoices)
import           MetaSonic.Session.Step             (SessionStepResult (..))
import           MetaSonic.Spec.SessionShared       (duplicateFirstTwoTemplates,
                                                     missingVoiceEventsAt,
                                                     patternProducerOrFail,
                                                     queueOrFail)

sessionRunnerTests :: TestTree
sessionRunnerTests = testGroup "Session Prep I: scripted runner"
  [ testCase "one runner step enqueues and commits a Pattern voice" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 64 })
      queue0 <- queueOrFail (SessionQueueOptions 4)
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  $ \owner -> do
                    step <- stepPatternSession droneVibrato producer queue0 owner
                    st <- sessionOwnerState owner
                    pure (step, st)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (step, st) -> do
          assertBool
            "runner should leave the producer without backlog after one block"
            (not (isBacklogged (prsState step)))
          sdrRemaining (prsDrain step) @?= 0
          sdrStopped (prsDrain step) @?= Nothing
          perBacklogged (prsEnqueue step) @?= 0
          case map sdiResult (sdrItems (prsDrain step)) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure ("expected one committed runner voice, got: "
                             <> show other)
          assertBool
            ("expected v0 voice after runner step, got " <> show (ssVoices st))
            (M.member (VoiceKey "v0") (ssVoices st))

  , testCase "backlog retries drain across repeated runner steps" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 1)
      let voiceOn k =
            PEVoiceOn (TemplateName "stab") (VoiceKey k)
              [ (ControlTag (MigrationKey "lpf")      0, 800.0)
              , (ControlTag (MigrationKey "envelope") 0, 1.0)
              ]
          events =
            [ (SamplePos 0, voiceOn "s0")
            , (SamplePos 1, voiceOn "s1")
            , (SamplePos 2, voiceOn "s2")
            ]
          pat = polyphonicStab { patternEvents = staticEvents events }
      let ownerOpts = defaultSessionOwnerOptions
            { sooAdapterOptions = defaultRTGraphAdapterOptions
                { raoPerTemplatePolyphony =
                    M.singleton (TemplateName "stab") 3
                }
            }
      result <- withSessionOwner
                  (patternTemplates polyphonicStab)
                  ownerOpts
                  $ \owner -> do
                    step1 <- stepPatternSession pat producer queue0 owner
                    step2 <- stepPatternSession pat (prsState step1) (prsQueue step1) owner
                    step3 <- stepPatternSession pat (prsState step2) (prsQueue step2) owner
                    st <- sessionOwnerState owner
                    pure (step1, step2, step3, st)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (step1, step2, step3, st) -> do
          assertBool
            "step 1 should leave producer backlogged after queue saturation"
            (isBacklogged (prsState step1))
          assertBool
            "step 2 should still be backlogged after retrying one event"
            (isBacklogged (prsState step2))
          assertBool
            "step 3 should clear producer backlog"
            (not (isBacklogged (prsState step3)))
          perBacklogged (prsEnqueue step1) @?= 2
          perBacklogged (prsEnqueue step2) @?= 1
          perBacklogged (prsEnqueue step3) @?= 0
          sdrStopped (prsDrain step1) @?= Nothing
          sdrStopped (prsDrain step2) @?= Nothing
          sdrStopped (prsDrain step3) @?= Nothing
          assertBool
            ("expected s0, s1, s2 voices after runner backlog drain, got "
              <> show (ssVoices st))
            (all (\k -> M.member (VoiceKey k) (ssVoices st)) ["s0","s1","s2"])

  , testCase "owner divergence stops the runner drain and blocks later steps" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let badGraph = duplicateFirstTwoTemplates
                       (patternTemplates arpeggioSendReturn)
          divergedReason = SodHotSwapInstallFailed
                             (SasiDuplicateTemplateName (TemplateName "dup"))
          events =
            [ (SamplePos 0, PEHotSwap (SwapLabel "bad-graph") badGraph)
            , (SamplePos 1, PEVoiceOn (TemplateName "drone") (VoiceKey "v0") [])
            ]
          pat = droneVibrato { patternEvents = staticEvents events }
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  $ \owner -> do
                    step1 <- stepPatternSession pat producer queue0 owner
                    step2 <- stepPatternSession pat (prsState step1) (prsQueue step1) owner
                    status <- sessionOwnerStatus owner
                    pure (step1, step2, status)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (step1, step2, status) -> do
          sdrStopped (prsDrain step1) @?= Just divergedReason
          sdrRemaining (prsDrain step1) @?= 1
          case map sdiResult (sdrItems (prsDrain step1)) of
            [SessionOwnerDivergedNow
               (StepRuntimeFailed (SriHotSwapInstallFailed _))
               reason] ->
              reason @?= divergedReason
            other ->
              assertFailure ("expected drain to stop on hot-swap divergence, got: "
                             <> show other)
          sdrStopped (prsDrain step2) @?= Just divergedReason
          case map sdiResult (sdrItems (prsDrain step2)) of
            (SessionOwnerBlocked reason : _) ->
              reason @?= divergedReason
            other ->
              assertFailure ("expected later runner step to surface blocked items, got: "
                             <> show other)
          status @?= SessionOwnerDiverged divergedReason

  , testCase "runner step retrying backlog does not advance the cursor" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 1)
      let events = missingVoiceEventsAt [0, 1, 2]
          pat = droneVibrato { patternEvents = staticEvents events }
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  $ \owner -> do
                    step1 <- stepPatternSession pat producer queue0 owner
                    step2 <- stepPatternSession pat (prsState step1) (prsQueue step1) owner
                    pure (step1, step2)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (step1, step2) -> do
          perNextStart (prsEnqueue step1) @?= SamplePos 8
          perNextStart (prsEnqueue step2) @?= perNextStart (prsEnqueue step1)
          assertBool
            "step 1 should be backlogged after queue cap 1"
            (isBacklogged (prsState step1))
          map peiSamplePos (perItems (prsEnqueue step2))
            @?= [SamplePos 1, SamplePos 2]
  ]
