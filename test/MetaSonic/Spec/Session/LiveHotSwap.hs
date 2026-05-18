-- | Session Prep O: live-audio preserving hot-swap orchestration tests.
--
-- These tests do not start PortAudio. They pin the session-visible
-- failure policy with mock 'SessionRuntimeAdapter' results and pin
-- the producer-side live install protocol with deterministic fake
-- publish/wait/collect callbacks.
--
-- The two halves share cohort-local helpers
-- ('liveHotSwapFixture'/'runMockLiveHotSwap'/'assertObservedHotSwapPlan'
-- for the runtime-plan failure-policy cases, and
-- 'successfulFakeLiveProtocol'/'fakeMigrationStats'/'assertLiveProtocolFailure'
-- for the deterministic protocol cases) but stay one cohort because
-- they pin two halves of the same Prep O contract.
module MetaSonic.Spec.Session.LiveHotSwap
  ( sessionLiveHotSwapOrchestrationTests
  ) where

import           Control.Monad                      (forM_)
import           Data.IORef                         (modifyIORef', newIORef,
                                                     readIORef, writeIORef)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Templates         (TemplateGraph)
import           MetaSonic.Pattern                  (Pattern (..),
                                                     SwapLabel (..),
                                                     TemplateName (..),
                                                     VoiceKey (..))
import           MetaSonic.Pattern.Corpus           (hotSwapEdit,
                                                     hotSwapEditAfterTemplates)
import           MetaSonic.Session.AdapterIssue     (SessionAdapterSetupIssue (..))
import           MetaSonic.Session.Command          (HotSwapInstallMode (..),
                                                     SessionCommand (..))
import           MetaSonic.Bridge.FFI               (SwapMigrationStats (..))
import           MetaSonic.Session.RTGraphAdapter   (LiveHotSwapProtocol (..),
                                                     PreservingHotSwapExpectations (..),
                                                     runLiveHotSwapProtocol)
import           MetaSonic.Session.Resolve          (VoiceBinding (..),
                                                     rrrDropped)
import           MetaSonic.Session.Runtime          (SessionRuntimeAdapter (..),
                                                     SessionRuntimeIssue (..))
import           MetaSonic.Session.State            (SessionCommit (..),
                                                     SessionPlan (..),
                                                     SessionState,
                                                     applySessionCommit,
                                                     initialSessionState)
import           MetaSonic.Session.Step             (SessionStepResult (..),
                                                     stepSessionCommand)
import           MetaSonic.Spec.SessionShared       (compileTemplateGraphOrFail)

sessionLiveHotSwapOrchestrationTests :: TestTree
sessionLiveHotSwapOrchestrationTests =
  testGroup "Session Prep O: live preserving hot-swap orchestration"
  [ testCase "publish rejection is a retryable runtime failure" $ do
      (st0, cmd, swapLabel, newGraph) <-
        liveHotSwapFixture "live-publish-rejected"
      (result, observedPlan) <-
        runMockLiveHotSwap st0 cmd SriHotSwapPublishRejected
      result @?= StepRuntimeFailed SriHotSwapPublishRejected
      assertObservedPreservingPlan observedPlan swapLabel newGraph

  , testCase "preserving-only publish rejection keeps preserving-only plan" $ do
      (st0, cmd, swapLabel, newGraph) <-
        liveHotSwapFixtureWith
          CmdHotSwapPreservingOnly
          "live-preserving-only-publish-rejected"
      (result, observedPlan) <-
        runMockLiveHotSwap st0 cmd SriHotSwapPublishRejected
      result @?= StepRuntimeFailed SriHotSwapPublishRejected
      assertObservedHotSwapPlan
        HotSwapPreservingOnly
        observedPlan
        swapLabel
        newGraph

  , testCase "install timeout maps to terminal install failure wrapper" $ do
      assertMockLiveInstallFailure
        "live-install-timeout"
        "preserving hot-swap install timed out"

  , testCase "retired-missing maps to terminal install failure wrapper" $ do
      assertMockLiveInstallFailure
        "live-retired-missing"
        "preserving hot-swap installed but retired swap was missing"

  , testCase "incomplete migration maps to terminal install failure wrapper" $ do
      assertMockLiveInstallFailure
        "live-incomplete-migration"
        "preserving hot-swap migration was incomplete"

  , testCase "preserving-only post-publish failures keep preserving-only plan" $ do
      let cases =
            [ ("timeout", "preserving hot-swap install timed out")
            , ( "retired-missing"
              , "preserving hot-swap installed but retired swap was missing"
              )
            , ( "incomplete-migration"
              , "preserving hot-swap migration was incomplete"
              )
            ]
      forM_ cases $ \(labelSuffix, message) ->
        assertMockPreservingOnlyLiveInstallFailure
          ("live-preserving-only-" <> labelSuffix)
          message

  , testCase "deterministic live protocol orders publish wait collect verify" $ do
      eventsRef <- newIORef []
      let record event =
            modifyIORef' eventsRef (<> [event])
          expectations =
            PreservingHotSwapExpectations
              { phsePreservedBindingCount = 2
              , phseExpectedStateCopyCount = 3
              }
          protocol = LiveHotSwapProtocol
            { lhpReadGeneration = do
                record "read-generation"
                pure 11
            , lhpAcquireSwap = do
                record "acquire"
                pure (Right "swap")
            , lhpPublishSwap = \swap -> do
                swap @?= "swap"
                record "publish"
                pure (Right ())
            , lhpWaitForGeneration = \priorGeneration timeoutMs -> do
                priorGeneration @?= 11
                timeoutMs @?= 250
                record "wait"
                pure True
            , lhpCollectRetiredStats = do
                record "collect"
                pure (Just (fakeMigrationStats 3 2))
            }
      result <- runLiveHotSwapProtocol protocol expectations 250
      result @?= Right ()
      events <- readIORef eventsRef
      events
        @?= [ "read-generation"
            , "acquire"
            , "publish"
            , "wait"
            , "collect"
            ]

  , testCase "deterministic live protocol maps post-publish failures" $ do
      let expectations =
            PreservingHotSwapExpectations
              { phsePreservedBindingCount = 2
              , phseExpectedStateCopyCount = 3
              }
      assertLiveProtocolFailure
        expectations
        "timeout"
        (\protocol -> protocol
          { lhpWaitForGeneration = \_ _ -> pure False
          })
        (SriHotSwapInstallFailed
          (SasiLoaderException "preserving hot-swap install timed out"))
      assertLiveProtocolFailure
        expectations
        "retired-missing"
        (\protocol -> protocol
          { lhpCollectRetiredStats = pure Nothing
          })
        (SriHotSwapInstallFailed
          (SasiLoaderException
            "preserving hot-swap installed but retired swap was missing"))
      assertLiveProtocolFailure
        expectations
        "incomplete-migration"
        (\protocol -> protocol
          { lhpCollectRetiredStats =
              pure (Just (fakeMigrationStats 2 2))
          })
        (SriHotSwapInstallFailed
          (SasiLoaderException
            "preserving hot-swap migration was incomplete"))
  ]

liveHotSwapFixture
  :: String
  -> IO (SessionState, SessionCommand, SwapLabel, TemplateGraph)
liveHotSwapFixture =
  liveHotSwapFixtureWith CmdHotSwap

liveHotSwapFixtureWith
  :: (SwapLabel -> TemplateGraph -> SessionCommand)
  -> String
  -> IO (SessionState, SessionCommand, SwapLabel, TemplateGraph)
liveHotSwapFixtureWith commandFor labelText = do
  newGraph <- compileTemplateGraphOrFail hotSwapEditAfterTemplates
  let oldGraph = patternTemplates hotSwapEdit
      binding  = VoiceBinding (VoiceKey "vLive") 3 (TemplateName "drone")
      st0      = applySessionCommit
                   (CommitVoiceStarted binding)
                   (initialSessionState oldGraph)
      label    = SwapLabel labelText
      cmd      = commandFor label newGraph
  pure (st0, cmd, label, newGraph)

runMockLiveHotSwap
  :: SessionState
  -> SessionCommand
  -> SessionRuntimeIssue
  -> IO (SessionStepResult, Maybe SessionPlan)
runMockLiveHotSwap st cmd issue = do
  observedPlanRef <- newIORef Nothing
  let adapter = SessionRuntimeAdapter $ \plan -> do
        writeIORef observedPlanRef (Just plan)
        pure (Left issue)
  result <- stepSessionCommand adapter cmd st
  observedPlan <- readIORef observedPlanRef
  pure (result, observedPlan)

assertMockLiveInstallFailure :: String -> String -> Assertion
assertMockLiveInstallFailure labelText message = do
  (st0, cmd, swapLabel, newGraph) <- liveHotSwapFixture labelText
  let issue = SriHotSwapInstallFailed (SasiLoaderException message)
  (result, observedPlan) <- runMockLiveHotSwap st0 cmd issue
  result @?= StepRuntimeFailed issue
  assertObservedPreservingPlan observedPlan swapLabel newGraph

assertMockPreservingOnlyLiveInstallFailure :: String -> String -> Assertion
assertMockPreservingOnlyLiveInstallFailure labelText message = do
  (st0, cmd, swapLabel, newGraph) <-
    liveHotSwapFixtureWith CmdHotSwapPreservingOnly labelText
  let issue = SriHotSwapInstallFailed (SasiLoaderException message)
  (result, observedPlan) <- runMockLiveHotSwap st0 cmd issue
  result @?= StepRuntimeFailed issue
  assertObservedHotSwapPlan
    HotSwapPreservingOnly
    observedPlan
    swapLabel
    newGraph

assertObservedPreservingPlan
  :: Maybe SessionPlan
  -> SwapLabel
  -> TemplateGraph
  -> Assertion
assertObservedPreservingPlan observedPlan expectedLabel expectedGraph =
  assertObservedHotSwapPlan
    HotSwapAllowRebuild
    observedPlan
    expectedLabel
    expectedGraph

assertObservedHotSwapPlan
  :: HotSwapInstallMode
  -> Maybe SessionPlan
  -> SwapLabel
  -> TemplateGraph
  -> Assertion
assertObservedHotSwapPlan expectedMode observedPlan expectedLabel expectedGraph =
  case observedPlan of
    Just (PlanHotSwap mode label graph rebuild) -> do
      mode @?= expectedMode
      label @?= expectedLabel
      graph @?= expectedGraph
      rrrDropped rebuild @?= []
    other ->
      assertFailure ("expected preserving PlanHotSwap, got: " <> show other)

assertLiveProtocolFailure
  :: PreservingHotSwapExpectations
  -> String
  -> (LiveHotSwapProtocol IO String -> LiveHotSwapProtocol IO String)
  -> SessionRuntimeIssue
  -> Assertion
assertLiveProtocolFailure expectations labelText patch expectedIssue = do
  let protocol = patch (successfulFakeLiveProtocol labelText)
  result <- runLiveHotSwapProtocol protocol expectations 250
  result @?= Left expectedIssue

successfulFakeLiveProtocol :: String -> LiveHotSwapProtocol IO String
successfulFakeLiveProtocol labelText = LiveHotSwapProtocol
  { lhpReadGeneration =
      pure 11
  , lhpAcquireSwap =
      pure (Right ("swap-" <> labelText))
  , lhpPublishSwap =
      const (pure (Right ()))
  , lhpWaitForGeneration =
      \_ _ -> pure True
  , lhpCollectRetiredStats =
      pure (Just (fakeMigrationStats 3 2))
  }

fakeMigrationStats :: Int -> Int -> SwapMigrationStats
fakeMigrationStats stateCopies lifecycleCopies = SwapMigrationStats
  -- The live protocol verifier currently inspects only state and
  -- lifecycle copy counts; the other counters stay explicit so a
  -- future verifier change has a visible test fixture to revisit.
  { smsCommittedCount = 0
  , smsSkippedCount = 0
  , smsInstanceCopyCount = 0
  , smsStateCopyCount = stateCopies
  , smsLifecycleCopyCount = lifecycleCopies
  }
