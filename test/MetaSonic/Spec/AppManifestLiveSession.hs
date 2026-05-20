{-# LANGUAGE TypeApplications #-}

-- | Deterministic coverage for the manifest live session shell's
-- pure surface: the stdin command parser, the supervisor-outcome →
-- session-outcome state machine, the outcome renderer, and the
-- 'withTrackedFactory' wrapper that mirrors the supervisor adapter's
-- active stack into a caller-owned 'IORef' for status reads.
--
-- The session loop itself runs interactive IO against real audio and
-- a real OSC port; that path is covered by the tier-2 wrapper at
-- @tools/manifest_live_session_require_preserving_smoke.sh@.
module MetaSonic.Spec.AppManifestLiveSession
  ( appManifestLiveSessionTests
  ) where

import           Control.Exception          (SomeException, try)
import           Data.IORef                 (newIORef, readIORef)
import           System.Exit                (ExitCode (..))
import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestLiveSession
                                            (LiveSessionCommand (..),
                                             LiveSessionOutcome (..),
                                             SessionStep (..),
                                             parseLiveSessionCommand,
                                             renderLiveSessionOutcome,
                                             stepFromOutcome,
                                             withTrackedFactory)
import           MetaSonic.App.ManifestReloadSupervisor
                                            (InWindowReloadOutcome (..),
                                             SupervisedReloadOutcome (..))
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                            (HostStackFactory (..))


appManifestLiveSessionTests :: TestTree
appManifestLiveSessionTests =
  testGroup "App manifest live session"
  [ testGroup "parseLiveSessionCommand" parseLiveSessionCommandTests
  , testGroup "stepFromOutcome"         stepFromOutcomeTests
  , testGroup "renderLiveSessionOutcome" renderLiveSessionOutcomeTests
  , testGroup "withTrackedFactory"       withTrackedFactoryTests
  ]


-- ---------------------------------------------------------------------------
-- parseLiveSessionCommand
-- ---------------------------------------------------------------------------

parseLiveSessionCommandTests :: [TestTree]
parseLiveSessionCommandTests =
  [ row "empty line is status"
      "" LscStatus
  , row "whitespace-only line is status"
      "   \t  " LscStatus
  , row "demo:foo reloads to foo"
      "demo:foo" (LscReloadTo "foo")
  , row "demo:foo with leading + trailing whitespace trims"
      "  demo:foo  " (LscReloadTo "foo")
  , row "demo: with empty payload is unknown"
      "demo:" (LscUnknown "demo:")
  , row "demo: with whitespace-only payload is unknown"
      "demo:   " (LscUnknown "demo:   ")
  , row "internal whitespace in the demo key is preserved"
      "demo:foo bar" (LscReloadTo "foo bar")
  , row "uppercase DEMO: prefix is unknown (case-sensitive)"
      "DEMO:foo" (LscUnknown "DEMO:foo")
  , row "arbitrary text is unknown"
      "quit" (LscUnknown "quit")
  , row "unknown command preserves the original (untrimmed) line"
      "  hello world  " (LscUnknown "  hello world  ")
  ]
  where
    row name input expected =
      testCase name $
        parseLiveSessionCommand input @?= expected


-- ---------------------------------------------------------------------------
-- stepFromOutcome
-- ---------------------------------------------------------------------------

stepFromOutcomeTests :: [TestTree]
stepFromOutcomeTests =
  [ testCase "Committed → LsoCommitted + continue" $
      stepFromOutcome (SupervisedReloadCommitted :: SupervisedReloadOutcome ())
        @?= (LsoCommitted, SsContinue)

  , testCase "RequestRejected → LsoRequestRejected + continue (carries cause; session keeps serving)" $
      stepFromOutcome (SupervisedReloadRequestRejected "some-cause")
        @?= (LsoRequestRejected, SsContinue)

  , testCase "RejectedRecovered → LsoRejectedRecovered + continue (supervisor rebuilt; session keeps serving on the rebuilt stack)" $
      stepFromOutcome (SupervisedReloadRejectedRecovered "in-window-cause")
        @?= (LsoRejectedRecovered, SsContinue)

  , testCase "Escalated → LsoEscalated + Terminate ExitFailure 1" $
      stepFromOutcome (SupervisedReloadEscalated "in-window" "rebuild")
        @?= (LsoEscalated, SsTerminate (ExitFailure 1))
  ]


-- ---------------------------------------------------------------------------
-- renderLiveSessionOutcome
-- ---------------------------------------------------------------------------

renderLiveSessionOutcomeTests :: [TestTree]
renderLiveSessionOutcomeTests =
  [ testCase "Committed renders the operator-facing label" $
      renderLiveSessionOutcome LsoCommitted
        @?= "committed (new plan installed)"

  , testCase "RequestRejected names the live-fallback semantics" $
      renderLiveSessionOutcome LsoRequestRejected
        @?= "request-rejected (stack still on previous plan)"

  , testCase "RejectedRecovered names the rebuild semantics" $
      renderLiveSessionOutcome LsoRejectedRecovered
        @?= "rejected-recovered (rebuilt from fallback)"

  , testCase "Escalated names the terminal state" $
      renderLiveSessionOutcome LsoEscalated
        @?= "escalated (no live stack)"

  , testCase "PlanRejected embeds the reason verbatim" $
      renderLiveSessionOutcome (LsoPlanRejected "demo \"missing\" not in catalog")
        @?= "plan-rejected (demo \"missing\" not in catalog)"
  ]


-- ---------------------------------------------------------------------------
-- withTrackedFactory
-- ---------------------------------------------------------------------------

-- | Minimal toy stack value the tests use to observe IORef writes.
data ToyStack = ToyStack !Int
  deriving (Eq, Show)


-- | Build a fake 'HostStackFactory' that returns a deterministic
-- stack value on open, runs an arbitrary IO action on close, and
-- does not exercise the in-window slot (the loop's in-window calls
-- are not what 'withTrackedFactory' covers).
fakeFactory
  :: IO (Either String ToyStack)
  -> (ToyStack -> IO ())
  -> HostStackFactory String ToyStack String
fakeFactory openAction closeAction = HostStackFactory
  { hsfOpenStack      = const openAction
  , hsfCloseStack     = closeAction
  , hsfInWindowReload = \_ _ _ ->
      pure (InWindowReloadCommitted :: InWindowReloadOutcome String)
  }


withTrackedFactoryTests :: [TestTree]
withTrackedFactoryTests =
  [ testCase "open writes the stack into the tracking IORef on Right" $ do
      ref <- newIORef Nothing
      let factory = withTrackedFactory
            (fakeFactory (pure (Right (ToyStack 7))) (const (pure ())))
            ref
      result <- hsfOpenStack factory "plan"
      result @?= Right (ToyStack 7)
      tracked <- readIORef ref
      tracked @?= Just (ToyStack 7)

  , testCase "open leaves the IORef alone on Left" $ do
      ref <- newIORef (Just (ToyStack 42))
      let factory = withTrackedFactory
            (fakeFactory (pure (Left "boom")) (const (pure ())))
            ref
      result <- hsfOpenStack factory "plan"
      result @?= Left "boom"
      tracked <- readIORef ref
      tracked @?= Just (ToyStack 42)

  , testCase "close clears the IORef after a successful close" $ do
      ref <- newIORef (Just (ToyStack 7))
      let factory = withTrackedFactory
            (fakeFactory (error "open not called") (const (pure ())))
            ref
      hsfCloseStack factory (ToyStack 7)
      tracked <- readIORef ref
      tracked @?= Nothing

  , testCase "close clears the IORef even if hsfCloseStack throws" $ do
      ref <- newIORef (Just (ToyStack 7))
      let factory = withTrackedFactory
            (fakeFactory
              (error "open not called")
              (\_ -> error "close failed"))
            ref
      attempt <- try @SomeException (hsfCloseStack factory (ToyStack 7))
      case attempt of
        Left _  -> pure ()
        Right _ -> assertFailure "expected hsfCloseStack to rethrow"
      tracked <- readIORef ref
      tracked @?= Nothing

  , testCase "in-window reload does NOT touch the tracking IORef" $ do
      ref <- newIORef (Just (ToyStack 7))
      let factory = withTrackedFactory
            (fakeFactory (error "open not called")
                         (\_ -> error "close not called"))
            ref
      _ <- hsfInWindowReload factory (ToyStack 7) "old" "new"
      tracked <- readIORef ref
      tracked @?= Just (ToyStack 7)
  ]
