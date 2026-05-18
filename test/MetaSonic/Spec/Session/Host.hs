-- | Session Prep J: serialized Pattern session host tests.
--
-- Covers 'withPatternSessionHost' setup-failure surfacing, single
-- hosted step + snapshot, backlog carry across repeated calls, and
-- whole-step serialization under concurrent callers. Only
-- 'duplicateFirstTwoTemplates' comes from "MetaSonic.Spec.SessionShared";
-- the rest is direct session-module surface.
module MetaSonic.Spec.Session.Host
  ( sessionHostTests
  ) where

import qualified Data.Map.Strict           as M
import           Control.Concurrent        (forkIO, newEmptyMVar, putMVar,
                                            takeMVar)
import           Data.List                 (sort)
import           System.Timeout            (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source            (MigrationKey (..))
import           MetaSonic.Pattern
import           MetaSonic.Pattern.Corpus
import           MetaSonic.Session.AdapterIssue     (SessionAdapterSetupIssue (..))
import           MetaSonic.Session.Host
import           MetaSonic.Session.Owner
import           MetaSonic.Session.PatternProducer
import           MetaSonic.Session.Queue
import           MetaSonic.Session.RTGraphAdapter
import           MetaSonic.Session.Runner           (prsDrain, prsEnqueue)
import           MetaSonic.Session.State            (ssVoices)
import           MetaSonic.Spec.SessionShared       (duplicateFirstTwoTemplates)

sessionHostTests :: TestTree
sessionHostTests = testGroup "Session Prep J: Pattern session host"
  [ testCase "host construction surfaces owned component failures" $ do
      let graph = patternTemplates droneVibrato
          invalidProducerOpts = defaultPatternSessionHostOptions
            { pshoProducerOptions =
                defaultPatternProducerOptions { ppoBlockFrames = 0 }
            }
          invalidQueueOpts = defaultPatternSessionHostOptions
            { pshoQueueOptions = SessionQueueOptions 0
            }
          duplicated = duplicateFirstTwoTemplates
                         (patternTemplates arpeggioSendReturn)
      badProducer <- withPatternSessionHost
                       graph
                       invalidProducerOpts
                       (\_ -> pure ())
      badProducer @?=
        Left (PshsiPatternProducer (PpiInvalidBlockFrames 0))

      badQueue <- withPatternSessionHost
                    graph
                    invalidQueueOpts
                    (\_ -> pure ())
      badQueue @?= Left (PshsiQueue (SqsiInvalidCapacity 0))

      badOwner <- withPatternSessionHost
                    duplicated
                    defaultPatternSessionHostOptions
                    (\_ -> pure ())
      badOwner @?=
        Left (PshsiOwner (SasiDuplicateTemplateName (TemplateName "dup")))

  , testCase "host step commits a Pattern voice and exposes a snapshot" $ do
      result <- withPatternSessionHost
                  (patternTemplates droneVibrato)
                  defaultPatternSessionHostOptions
                  $ \host -> do
                    step <- stepPatternSessionHost droneVibrato host
                    snapshot <- readPatternSessionHost host
                    pure (step, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected Pattern session host, got: " <> show issue)
        Right (step, snapshot) -> do
          sdrRemaining (prsDrain step) @?= 0
          sdrStopped (prsDrain step) @?= Nothing
          assertBool
            "host snapshot should report no backlog after one clean step"
            (not (pshsBacklogged snapshot))
          pshsOwnerStatus snapshot @?= SessionOwnerReady
          assertBool
            ("expected v0 voice in hosted owner state, got "
              <> show (ssVoices (pshsOwnerState snapshot)))
            (M.member (VoiceKey "v0") (ssVoices (pshsOwnerState snapshot)))

  , testCase "host carries Pattern backlog across repeated calls" $ do
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
          ownerOpts = defaultSessionOwnerOptions
            { sooAdapterOptions = defaultRTGraphAdapterOptions
                { raoPerTemplatePolyphony =
                    M.singleton (TemplateName "stab") 3
                }
            }
          hostOpts = defaultPatternSessionHostOptions
            { pshoProducerOptions =
                defaultPatternProducerOptions { ppoBlockFrames = 8 }
            , pshoQueueOptions =
                SessionQueueOptions 1
            , pshoOwnerOptions =
                ownerOpts
            }
      result <- withPatternSessionHost
                  (patternTemplates polyphonicStab)
                  hostOpts
                  $ \host -> do
                    step1 <- stepPatternSessionHost pat host
                    step2 <- stepPatternSessionHost pat host
                    step3 <- stepPatternSessionHost pat host
                    snapshot <- readPatternSessionHost host
                    pure (step1, step2, step3, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected Pattern session host, got: " <> show issue)
        Right (step1, step2, step3, snapshot) -> do
          perBacklogged (prsEnqueue step1) @?= 2
          perBacklogged (prsEnqueue step2) @?= 1
          perBacklogged (prsEnqueue step3) @?= 0
          assertBool
            "host should clear backlog after the third serialized step"
            (not (pshsBacklogged snapshot))
          assertBool
            ("expected s0, s1, s2 voices after hosted backlog drain, got "
              <> show (ssVoices (pshsOwnerState snapshot)))
            (all
              (\k -> M.member (VoiceKey k) (ssVoices (pshsOwnerState snapshot)))
              ["s0", "s1", "s2"])

  , testCase "concurrent host callers serialize whole Pattern steps" $ do
      let events =
            [ ( SamplePos 0
              , PEVoiceOn (TemplateName "drone") (VoiceKey "v0") []
              )
            , ( SamplePos 8
              , PEVoiceOn (TemplateName "drone") (VoiceKey "v1") []
              )
            ]
          pat = droneVibrato { patternEvents = staticEvents events }
          ownerOpts = defaultSessionOwnerOptions
            { sooAdapterOptions = defaultRTGraphAdapterOptions
                { raoPerTemplatePolyphony =
                    M.singleton (TemplateName "drone") 2
                }
            }
          hostOpts = defaultPatternSessionHostOptions
            { pshoProducerOptions =
                defaultPatternProducerOptions { ppoBlockFrames = 8 }
            , pshoQueueOptions =
                SessionQueueOptions 4
            , pshoOwnerOptions =
                ownerOpts
            }
      result <- withPatternSessionHost
                  (patternTemplates droneVibrato)
                  hostOpts
                  $ \host -> do
                    done <- newEmptyMVar
                    let worker =
                          stepPatternSessionHost pat host >>= putMVar done
                    _ <- forkIO worker
                    _ <- forkIO worker
                    mStep1 <- timeout 1000000 (takeMVar done)
                    mStep2 <- timeout 1000000 (takeMVar done)
                    snapshot <- readPatternSessionHost host
                    pure (mStep1, mStep2, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected Pattern session host, got: " <> show issue)
        Right (Just step1, Just step2, snapshot) -> do
          sort (map (perNextStart . prsEnqueue) [step1, step2])
            @?= [SamplePos 8, SamplePos 16]
          assertBool
            ("expected v0 and v1 voices after concurrent hosted steps, got "
              <> show (ssVoices (pshsOwnerState snapshot)))
            (all
              (\k -> M.member (VoiceKey k) (ssVoices (pshsOwnerState snapshot)))
              ["v0", "v1"])
        Right other ->
          assertFailure ("timed out waiting for concurrent hosted steps: "
                         <> show other)
  ]
