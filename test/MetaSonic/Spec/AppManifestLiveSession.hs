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
import           Data.IORef                 (IORef, modifyIORef',
                                             newIORef, readIORef)
import           System.Exit                (ExitCode (..))
import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestLiveSession
                                            (LiveSessionCommand (..),
                                             LiveSessionOutcome (..),
                                             LiveSessionResourceEvent (..),
                                             ReloadResolver (..),
                                             SessionStep (..),
                                             parseLiveSessionCommand,
                                             renderLiveSessionCommandHelp,
                                             renderLiveSessionOutcome,
                                             renderLiveSessionResourceEvents,
                                             renderLiveSessionSupervisorEvents,
                                             resourceTimelineForOutcome,
                                             runReloadWith,
                                             stepFromOutcome,
                                             withTrackedFactory)
import           MetaSonic.App.ManifestOSCIngressOps
                                            (ManifestOSCIngressOpsIssue)
import           MetaSonic.App.ManifestReloadEvent
                                            (ManifestReloadEvent (..))
import           MetaSonic.App.ManifestReloadHost
                                            (ManifestReloadHostIssue (..))
import           MetaSonic.App.ManifestReloadOrchestration.Types
                                            (HostPreservingReloadIssue (..))
import           MetaSonic.App.ManifestReloadSupervisor
                                            (InWindowReloadOutcome (..),
                                             SupervisedReloadEvent (..),
                                             SupervisedReloadOutcome (..),
                                             SupervisorOps (..))
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                            (HostStackFactory (..))
import qualified MetaSonic.Session.ManifestReload as MR


appManifestLiveSessionTests :: TestTree
appManifestLiveSessionTests =
  testGroup "App manifest live session"
  [ testGroup "parseLiveSessionCommand"  parseLiveSessionCommandTests
  , testGroup "renderLiveSessionCommandHelp"
                                         renderLiveSessionCommandHelpTests
  , testGroup "stepFromOutcome"          stepFromOutcomeTests
  , testGroup "renderLiveSessionOutcome" renderLiveSessionOutcomeTests
  , testGroup "resourceTimelineForOutcome"
                                         resourceTimelineForOutcomeTests
  , testGroup "renderLiveSessionResourceEvents"
                                         renderLiveSessionResourceEventsTests
  , testGroup "renderLiveSessionSupervisorEvents"
                                         renderLiveSessionSupervisorEventsTests
  , testGroup "withTrackedFactory"       withTrackedFactoryTests
  , testGroup "runReloadWith"            runReloadWithTests
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
  , row "literal 'status' is LscStatus (same as <Enter>)"
      "status" LscStatus
  , row "demo:foo reloads to foo"
      "demo:foo" (LscReloadTo "foo")
  , row "demo:foo with leading + trailing whitespace trims"
      "  demo:foo  " (LscReloadTo "foo")
  , row "demo: with empty payload is unknown"
      "demo:" (LscUnknown "demo:")
  , row "demo: with whitespace-only payload is unknown"
      "demo:   " (LscUnknown "demo:   ")
  , row "internal whitespace in the demo key is preserved (colon form)"
      "demo:foo bar" (LscReloadTo "foo bar")
  , row "uppercase DEMO: prefix is unknown (case-sensitive)"
      "DEMO:foo" (LscUnknown "DEMO:foo")

  -- demo<space>KEY alias (single-token rule)
  , row "demo<space>KEY single-token form reloads to KEY"
      "demo foo" (LscReloadTo "foo")
  , row "demo<space>KEY with leading + trailing whitespace trims (outer)"
      "  demo foo  " (LscReloadTo "foo")
  , row "demo<space>KEY with multiple internal spaces still single-token"
      "demo   foo" (LscReloadTo "foo")
  , row "demo<space>KEY with extra trailing token is unknown (no silent absorption)"
      "demo foo bar" (LscUnknown "demo foo bar")
  , row "demo<space>KEY with empty payload (trailing space only) is unknown"
      "demo " (LscUnknown "demo ")
  , row "demo bare word (no space, no colon) is unknown"
      "demo" (LscUnknown "demo")
  , row "uppercase DEMO<space> prefix is unknown (case-sensitive)"
      "DEMO foo" (LscUnknown "DEMO foo")
  , row "literal 'help' is LscHelp"
      "help" LscHelp
  , row "literal '?' is LscHelp"
      "?" LscHelp
  , row "literal 'quit' is LscQuit"
      "quit" LscQuit
  , row "literal 'exit' is LscQuit"
      "exit" LscQuit
  , row "named commands tolerate leading + trailing whitespace"
      "  help  " LscHelp
  , row "named commands are case-sensitive (HELP is unknown)"
      "HELP" (LscUnknown "HELP")
  , row "named command with trailing token is unknown (help me does not parse)"
      "help me" (LscUnknown "help me")
  , row "arbitrary text is unknown"
      "hello world" (LscUnknown "hello world")
  , row "unknown command preserves the original (untrimmed) line"
      "  hello world  " (LscUnknown "  hello world  ")
  ]
  where
    row name input expected =
      testCase name $
        parseLiveSessionCommand input @?= expected


-- ---------------------------------------------------------------------------
-- renderLiveSessionCommandHelp
-- ---------------------------------------------------------------------------

-- | The command vocabulary is shared between three call sites — the
-- startup prompt, the @help@ dispatch arm, and the @LscUnknown@
-- rejection arm — so pinning its lines here guarantees that all
-- three surfaces stay in sync. If a future contributor adds, removes,
-- or renames a named command, these rows must change in lockstep
-- with the command vocabulary the operator sees.
renderLiveSessionCommandHelpTests :: [TestTree]
renderLiveSessionCommandHelpTests =
  [ testCase "renders six lines: header + five command rows" $
      length renderLiveSessionCommandHelp @?= 6

  , testCase "first line is the 'commands:' header (two-space indent)" $
      head renderLiveSessionCommandHelp @?= "  commands:"

  , testCase "exact body matches the documented vocabulary" $
      renderLiveSessionCommandHelp
        @?= [ "  commands:"
            , "    demo:KEY    supervised reload to catalog demo KEY"
            , "    demo KEY    same, single-token form (no internal whitespace)"
            , "    status      print current status (same as <Enter>)"
            , "    help        print commands (same as ?)"
            , "    quit        close session cleanly (same as exit, <Ctrl-D>)"
            ]
  ]


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
-- resourceTimelineForOutcome
-- ---------------------------------------------------------------------------

-- | The four supervisor outcomes each project to a fixed-shape
-- timeline. Tests pin the structural shape (which events fire, in
-- which order, and which plan is named) per outcome. The plan type
-- is the same 'StubPlan' alias used by 'runReloadWith' tests.
resourceTimelineForOutcomeTests :: [TestTree]
resourceTimelineForOutcomeTests =
  [ testCase "Committed: [InWindowReloadCommitted, ServingPlan requested]" $
      resourceTimelineForOutcome fallback requested
          (SupervisedReloadCommitted :: SupervisedReloadOutcome String)
        @?= [ LsreInWindowReloadCommitted
            , LsreServingPlan requested
            ]

  , testCase "RequestRejected: [RequestRejectedStackStayedLive, NoSupervisorRebuild, ServingPlan fallback]" $
      resourceTimelineForOutcome fallback requested
          (SupervisedReloadRequestRejected "live-fallback-cause")
        @?= [ LsreRequestRejectedStackStayedLive
            , LsreNoSupervisorRebuild
            , LsreServingPlan fallback
            ]

  , testCase "RejectedRecovered: [TerminalRecovering, ClosedPrevious, OpenedFallback, ServingPlan fallback]" $
      resourceTimelineForOutcome fallback requested
          (SupervisedReloadRejectedRecovered "in-window-cause")
        @?= [ LsreTerminalRecoveringFromFallback
            , LsreClosedPreviousStack
            , LsreOpenedFallbackStack
            , LsreServingPlan fallback
            ]

  , testCase "Escalated: [TerminalRecovering, ClosedPrevious, FallbackRebuildFailed, NoLiveStack]" $
      resourceTimelineForOutcome fallback requested
          (SupervisedReloadEscalated "in-window-cause" "rebuild-cause")
        @?= [ LsreTerminalRecoveringFromFallback
            , LsreClosedPreviousStack
            , LsreFallbackRebuildFailed
            , LsreNoLiveStack
            ]
  ]
  where
    fallback, requested :: StubPlan
    fallback  = 1
    requested = 2


-- ---------------------------------------------------------------------------
-- renderLiveSessionResourceEvents
-- ---------------------------------------------------------------------------

-- | The renderer is a flat per-event mapping; tests pin the
-- operator-facing line text per outcome so any wording drift gets
-- flagged. 'show' is the test-time plan-label projection;
-- production passes 'MR.mrlpDemoKey'.
renderLiveSessionResourceEventsTests :: [TestTree]
renderLiveSessionResourceEventsTests =
  [ testCase "Committed renders 2 lines naming the requested plan" $
      renderLiveSessionResourceEvents show
          (resourceTimelineForOutcome (1 :: StubPlan) 2
             (SupervisedReloadCommitted :: SupervisedReloadOutcome String))
        @?= [ "in-window reload committed"
            , "serving plan: 2"
            ]

  , testCase "RequestRejected renders 3 lines naming the fallback plan" $
      renderLiveSessionResourceEvents show
          (resourceTimelineForOutcome (1 :: StubPlan) 2
             (SupervisedReloadRequestRejected "cause"))
        @?= [ "request rejected; stack stayed live"
            , "no supervisor rebuild"
            , "serving plan: 1"
            ]

  , testCase "RejectedRecovered renders 4 lines spelling close/open and fallback plan" $
      renderLiveSessionResourceEvents show
          (resourceTimelineForOutcome (1 :: StubPlan) 2
             (SupervisedReloadRejectedRecovered "cause"))
        @?= [ "terminal in-window failure; recovering from fallback"
            , "closed previous stack"
            , "opened fallback stack"
            , "serving plan: 1"
            ]

  , testCase "Escalated renders 4 lines spelling close, rebuild failure, and no-live-stack" $
      renderLiveSessionResourceEvents show
          (resourceTimelineForOutcome (1 :: StubPlan) 2
             (SupervisedReloadEscalated "in-window" "rebuild"))
        @?= [ "terminal in-window failure; recovering from fallback"
            , "closed previous stack"
            , "fallback rebuild failed"
            , "serving plan: (no live stack)"
            ]
  ]


-- ---------------------------------------------------------------------------
-- renderLiveSessionSupervisorEvents
-- ---------------------------------------------------------------------------

-- | One pinned-output test per 'SupervisedReloadOutcome' covering
-- the observed event stream the supervisor emits. The expected
-- event sequences mirror what 'AppManifestReloadSupervisor's
-- "withEvents" tests pin on the supervisor side; this group pins
-- the operator wording the live session renders from that
-- sequence.
--
-- Cause payloads in 'SreInWindowRejectedLiveFallback' /
-- 'SreInWindowTerminal' / 'SreFallbackOpenFailed' are
-- intentionally absent from the rendered lines — they are still
-- shown by the @cause:@ line in 'runReloadWith', so embedding
-- them on the event lines too would duplicate noise (the F-1
-- leak guard structurally holds because the renderer matches on
-- the constructor and discards the payload regardless of @e@).
renderLiveSessionSupervisorEventsTests :: [TestTree]
renderLiveSessionSupervisorEventsTests =
  [ testCase "Committed renders [in-window: started, in-window: committed]" $
      renderLiveSessionSupervisorEvents
          ([ SreInWindowStarted
           , SreInWindowCommitted
           ] :: [SupervisedReloadEvent String])
        @?= [ "in-window: started"
            , "in-window: committed"
            ]

  , testCase "RequestRejected renders [in-window: started, in-window: rejected-live-fallback]" $
      renderLiveSessionSupervisorEvents
          ([ SreInWindowStarted
           , SreInWindowRejectedLiveFallback "live-fallback-cause"
           ] :: [SupervisedReloadEvent String])
        @?= [ "in-window: started"
            , "in-window: rejected-live-fallback"
            ]

  , testCase "RejectedRecovered renders the six-step terminal+close+open sequence" $
      renderLiveSessionSupervisorEvents
          ([ SreInWindowStarted
           , SreInWindowTerminal "in-window-cause"
           , SreClosePreviousStarted
           , SreClosePreviousSucceeded
           , SreFallbackOpenStarted
           , SreFallbackOpenSucceeded
           ] :: [SupervisedReloadEvent String])
        @?= [ "in-window: started"
            , "in-window: terminal"
            , "close previous stack: started"
            , "close previous stack: succeeded"
            , "fallback open: started"
            , "fallback open: succeeded"
            ]

  , testCase "Escalated renders the six-step sequence ending in fallback open: failed" $
      renderLiveSessionSupervisorEvents
          ([ SreInWindowStarted
           , SreInWindowTerminal "in-window-cause"
           , SreClosePreviousStarted
           , SreClosePreviousSucceeded
           , SreFallbackOpenStarted
           , SreFallbackOpenFailed "rebuild-cause"
           ] :: [SupervisedReloadEvent String])
        @?= [ "in-window: started"
            , "in-window: terminal"
            , "close previous stack: started"
            , "close previous stack: succeeded"
            , "fallback open: started"
            , "fallback open: failed"
            ]
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


-- ---------------------------------------------------------------------------
-- runReloadWith
-- ---------------------------------------------------------------------------

-- | Stub plan type used by the fake-IO loop tests. The session
-- module's 'runReloadWith' does not inspect the plan — it just
-- passes the value through to 'sopsInWindowReload' — so any
-- type works here. An @Int@ keeps the IORef assertions readable.
type StubPlan = Int


-- | Synthesize a 'LiveEvent' the fake supOps can stuff into the
-- session's reloadEventsRef so the test can verify
-- (a) the events list is reset before each reload, and
-- (b) the post-reload events shown to the operator come from the
--     current call's supOps run, not from a prior call.
syntheticEvent
  :: Int
  -> ManifestReloadEvent
       (ManifestReloadHostIssue ManifestOSCIngressOpsIssue)
syntheticEvent tag =
  -- 'MreFallbackDeclined' is the most ergonomic constructor: it
  -- carries one issue payload that we can identify via show. The
  -- session module ignores the structure of the events list (it
  -- only renders / counts them) so any 'ManifestReloadEvent'
  -- works.
  MreFallbackDeclined
    (HpariPlanRejected
      (MrhiPlanning
        (MR.MriUnknownManifestDemo ("synthetic-event-" <> show tag))))


-- | Build a 'SupervisorOps' whose 'sopsInWindowReload' returns a
-- fixed outcome and stuffs a synthetic event into the events
-- ref so the test can verify event-reset behavior. The other two
-- slots ('sopsCloseStack', 'sopsOpenStack') are intentionally
-- left as @error@: 'runReloadWith' on the 'RejectedLiveFallback'
-- and 'Committed' arms must not invoke them — the supervisor's
-- own logic decides when to call them, and 'runReloadWith' just
-- consumes the resulting 'SupervisedReloadOutcome'. If a refactor
-- of 'runReloadWith' (or 'reloadSupervised') ever introduces a
-- spurious open/close call from inside the session module, these
-- tests will fail loudly with the @error@ message.
fakeSupOpsWithOutcome
  :: IORef [LiveEvent]
  -> InWindowReloadOutcome String
  -> Int
  -> SupervisorOps StubPlan String
fakeSupOpsWithOutcome eventsRef outcome tag = SupervisorOps
  { sopsInWindowReload = \_fallback _requested -> do
      modifyIORef' eventsRef (<> [syntheticEvent tag])
      pure outcome
  , sopsCloseStack     =
      assertFailure "fakeSupOpsWithOutcome: sopsCloseStack called unexpectedly"
  , sopsOpenStack      = \_ ->
      assertFailure "fakeSupOpsWithOutcome: sopsOpenStack called unexpectedly"
  }


-- | Local alias matching the session module's internal
-- 'LiveEvent' type — kept local to the test so we do not export
-- it from the production module.
type LiveEvent =
  ManifestReloadEvent (ManifestReloadHostIssue ManifestOSCIngressOpsIssue)


-- | Helper: spin up the four IORefs 'runReloadWith' needs and pin
-- the initial state explicitly. Tests then call 'runReloadWith'
-- and assert post-state.
withSessionRefs
  :: StubPlan
  -> ([LiveEvent]
      -> IORef StubPlan
      -> IORef (Maybe LiveSessionOutcome)
      -> IORef [LiveEvent]
      -> IO a)
  -> IO a
withSessionRefs initialPlan k = do
  let preExistingEvents = [syntheticEvent 999]
  currentPlanRef <- newIORef initialPlan
  lastOutcomeRef <- newIORef Nothing
  eventsRef      <- newIORef preExistingEvents
  k preExistingEvents currentPlanRef lastOutcomeRef eventsRef


-- | Default no-op for 'runReloadWith's 'onLiveStackChanged' hook.
-- Tests that do not care about the hook pass this; the
-- "onLiveStackChanged hook fires on the right outcomes" test
-- below builds a recording closure instead.
noHook :: StubPlan -> IO ()
noHook _ = pure ()


-- | A stub resolver that maps a fixed key → @Right plan@ and
-- everything else → @Left reason@.
stubResolver :: String -> StubPlan -> ReloadResolver StubPlan
stubResolver okKey okPlan = ReloadResolver $ \key ->
  if key == okKey
    then Right okPlan
    else Left ("stub-resolver: no plan for key " <> show key)


-- | A stub resolver that always rejects (used for the
-- planning-failure case that is independent of the catalog).
stubAlwaysReject :: String -> ReloadResolver StubPlan
stubAlwaysReject reason = ReloadResolver (const (Left reason))


runReloadWithTests :: [TestTree]
runReloadWithTests =
  [ testCase "bad demo key → LsoPlanRejected, SsContinue, currentPlan unchanged, supOps NOT called" $ do
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef -> do
        let -- supOps that asserts it was never called
            blockingSupOps :: SupervisorOps StubPlan String
            blockingSupOps = SupervisorOps
              { sopsInWindowReload = \_ _ ->
                  assertFailure "supOps should not be called on a command-level reject"
              , sopsCloseStack = assertFailure "close should not be called"
              , sopsOpenStack  = \_ -> assertFailure "open should not be called"
              }
            resolver = stubResolver "good" 42
        step <- runReloadWith
                  resolver
                  show
                  show
                  noHook
                  blockingSupOps
                  currentPlanRef
                  lastOutcomeRef
                  eventsRef
                  "bad-key"
        step @?= SsContinue
        plan <- readIORef currentPlanRef
        plan @?= 1
        outcome <- readIORef lastOutcomeRef
        case outcome of
          Just (LsoPlanRejected _) -> pure ()
          other ->
            assertFailure $
              "expected Just (LsoPlanRejected ...); got " <> show other

  , testCase "planning failure (resolver returns Left) → LsoPlanRejected, SsContinue, supOps NOT called" $ do
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef -> do
        let blockingSupOps :: SupervisorOps StubPlan String
            blockingSupOps = SupervisorOps
              { sopsInWindowReload = \_ _ ->
                  assertFailure "supOps should not be called on a planning failure"
              , sopsCloseStack = assertFailure "close should not be called"
              , sopsOpenStack  = \_ -> assertFailure "open should not be called"
              }
            resolver = stubAlwaysReject "manifest does not name this demo"
        step <- runReloadWith
                  resolver
                  show
                  show
                  noHook
                  blockingSupOps
                  currentPlanRef
                  lastOutcomeRef
                  eventsRef
                  "any-key"
        step @?= SsContinue
        plan <- readIORef currentPlanRef
        plan @?= 1
        outcome <- readIORef lastOutcomeRef
        case outcome of
          Just (LsoPlanRejected reason) ->
            assertBool
              ("rejection reason should contain the resolver's text; got: " <> reason)
              ("manifest does not name this demo" `elem` words reason
               || reason == "manifest does not name this demo")
          other ->
            assertFailure $
              "expected Just (LsoPlanRejected ...); got " <> show other

  , testCase "Committed → LsoCommitted, SsContinue, currentPlan := requested, events reset" $ do
      withSessionRefs 1 $ \prior currentPlanRef lastOutcomeRef eventsRef -> do
        let resolver = stubResolver "next" 2
            supOps   =
              fakeSupOpsWithOutcome eventsRef InWindowReloadCommitted 7
        step <- runReloadWith
                  resolver
                  show
                  show
                  noHook
                  supOps
                  currentPlanRef
                  lastOutcomeRef
                  eventsRef
                  "next"
        step @?= SsContinue
        plan <- readIORef currentPlanRef
        plan @?= 2   -- currentPlan updated to requested
        outcome <- readIORef lastOutcomeRef
        outcome @?= Just LsoCommitted
        events <- readIORef eventsRef
        events @?= [syntheticEvent 7]
        -- the pre-existing events list must NOT remain in the ref
        assertBool
          "event reset: pre-existing events should be cleared before sopsInWindowReload runs"
          (events /= prior)

  , testCase "RequestRejected → LsoRequestRejected, SsContinue, currentPlan unchanged" $ do
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef -> do
        let resolver = stubResolver "next" 2
            outcome  = InWindowReloadRejectedLiveFallback "live-fallback-cause"
            supOps   = fakeSupOpsWithOutcome eventsRef outcome 8
        step <- runReloadWith
                  resolver
                  show
                  show
                  noHook
                  supOps
                  currentPlanRef
                  lastOutcomeRef
                  eventsRef
                  "next"
        step @?= SsContinue
        plan <- readIORef currentPlanRef
        plan @?= 1   -- unchanged: request was rejected
        readIORef lastOutcomeRef >>= (@?= Just LsoRequestRejected)

  , testCase "Terminal in-window outcome → LsoRejectedRecovered, SsContinue, currentPlan unchanged" $ do
      -- Note: 'runReloadWith' alone does not see the supervisor's
      -- close-then-rebuild path; the supervisor wraps a Terminal
      -- in-window outcome plus a successful rebuild into
      -- 'SupervisedReloadRejectedRecovered' before
      -- 'runReloadWith' returns. The fake supOps here simulates
      -- that compound outcome directly so we can pin the
      -- session's response to it.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef -> do
        -- A real fake supOps that returns 'RejectedRecovered'
        -- would have to drive the supervisor's logic; here we
        -- short-circuit by overriding 'sopsInWindowReload' to
        -- terminal AND providing close+open stubs the supervisor
        -- can run.
        let resolver = stubResolver "next" 2
            supOps = SupervisorOps
              { sopsInWindowReload = \_ _ -> do
                  modifyIORef' eventsRef (<> [syntheticEvent 9])
                  pure (InWindowReloadTerminal "terminal-cause")
              , sopsCloseStack = pure ()
              , sopsOpenStack  = const (pure (Right ()))
              }
        step <- runReloadWith
                  resolver
                  show
                  show
                  noHook
                  supOps
                  currentPlanRef
                  lastOutcomeRef
                  eventsRef
                  "next"
        step @?= SsContinue
        plan <- readIORef currentPlanRef
        plan @?= 1   -- unchanged: rebuild was from fallback
        readIORef lastOutcomeRef >>= (@?= Just LsoRejectedRecovered)

  , testCase "Escalated → LsoEscalated, SsTerminate (ExitFailure 1), currentPlan unchanged" $ do
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef -> do
        let resolver = stubResolver "next" 2
            -- Drive the supervisor's escalation by failing BOTH
            -- the in-window reload (terminal) AND the subsequent
            -- rebuild open.
            supOps = SupervisorOps
              { sopsInWindowReload = \_ _ -> do
                  modifyIORef' eventsRef (<> [syntheticEvent 10])
                  pure (InWindowReloadTerminal "in-window-cause")
              , sopsCloseStack = pure ()
              , sopsOpenStack  = const (pure (Left "rebuild-cause"))
              }
        step <- runReloadWith
                  resolver
                  show
                  show
                  noHook
                  supOps
                  currentPlanRef
                  lastOutcomeRef
                  eventsRef
                  "next"
        step @?= SsTerminate (ExitFailure 1)
        plan <- readIORef currentPlanRef
        plan @?= 1
        readIORef lastOutcomeRef >>= (@?= Just LsoEscalated)

  , testCase "two reloads in a row: second reload's events ref does NOT carry the first's events" $ do
      -- Belt-and-suspenders for the event-reset behavior. Run
      -- two reloads back-to-back through the same IORefs; the
      -- second reload's eventsRef snapshot must contain only the
      -- second call's synthetic event, not the first's.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef -> do
        let resolver = stubResolver "next" 2
            supOpsFirst  =
              fakeSupOpsWithOutcome eventsRef InWindowReloadCommitted 11
            supOpsSecond =
              fakeSupOpsWithOutcome eventsRef InWindowReloadCommitted 12
        _ <- runReloadWith resolver show show noHook supOpsFirst
               currentPlanRef lastOutcomeRef eventsRef "next"
        eventsAfterFirst <- readIORef eventsRef
        eventsAfterFirst @?= [syntheticEvent 11]
        _ <- runReloadWith resolver show show noHook supOpsSecond
               currentPlanRef lastOutcomeRef eventsRef "next"
        eventsAfterSecond <- readIORef eventsRef
        eventsAfterSecond @?= [syntheticEvent 12]
        assertBool
          "second reload's events ref must not contain the first reload's tag"
          (syntheticEvent 11 `notElem` eventsAfterSecond)

  , testCase "onLiveStackChanged fires on Committed (with requested plan), Recovered (with fallback plan), and NOT on RequestRejected / PlanRejected / Escalated" $ do
      -- Production uses this hook to enqueue CmdVoiceOn against
      -- whichever plan the active stack is now running. For the
      -- require-preserving happy path the owner is preserved so
      -- the production hook short-circuits on the empty-voice
      -- check, but the contract here is the firing pattern: the
      -- two outcomes that may have produced a freshly-opened
      -- owner (Committed and RejectedRecovered) call the hook;
      -- the other three outcomes do not.
      hookCallsRef <- newIORef ([] :: [StubPlan])
      let recordingHook livePlan =
            modifyIORef' hookCallsRef (<> [livePlan])
          resolver = stubResolver "next" 2
      -- 1. PlanRejected: bad key, no supervisor call. Hook NOT
      --    called.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef -> do
        let blockingSupOps :: SupervisorOps StubPlan String
            blockingSupOps = SupervisorOps
              { sopsInWindowReload = \_ _ ->
                  assertFailure "supOps must not be called on PlanRejected"
              , sopsCloseStack = assertFailure "close must not be called"
              , sopsOpenStack  = \_ ->
                  assertFailure "open must not be called"
              }
        _ <- runReloadWith resolver show show recordingHook blockingSupOps
               currentPlanRef lastOutcomeRef eventsRef "bad-key"
        pure ()
      readIORef hookCallsRef >>= (@?= ([] :: [StubPlan]))

      -- 2. Committed: hook called with the requested plan.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef -> do
        let supOps =
              fakeSupOpsWithOutcome eventsRef InWindowReloadCommitted 100
        _ <- runReloadWith resolver show show recordingHook supOps
               currentPlanRef lastOutcomeRef eventsRef "next"
        pure ()
      readIORef hookCallsRef >>= (@?= [2])  -- requestedPlan == 2

      -- 3. RequestRejected: stack unchanged, hook NOT called.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef -> do
        let supOps =
              fakeSupOpsWithOutcome eventsRef
                (InWindowReloadRejectedLiveFallback "live-fallback")
                101
        _ <- runReloadWith resolver show show recordingHook supOps
               currentPlanRef lastOutcomeRef eventsRef "next"
        pure ()
      -- Hook list still just [2] from the Committed test above.
      readIORef hookCallsRef >>= (@?= [2])

      -- 4. RejectedRecovered: stack was rebuilt on the fallback
      --    plan; hook called with the fallback plan (== 1 here).
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef -> do
        let supOps = SupervisorOps
              { sopsInWindowReload = \_ _ -> do
                  modifyIORef' eventsRef (<> [syntheticEvent 102])
                  pure (InWindowReloadTerminal "terminal-cause")
              , sopsCloseStack = pure ()
              , sopsOpenStack  = const (pure (Right ()))
              }
        _ <- runReloadWith resolver show show recordingHook supOps
               currentPlanRef lastOutcomeRef eventsRef "next"
        pure ()
      readIORef hookCallsRef >>= (@?= [2, 1])  -- recovered with fallback (1)

      -- 5. Escalated: session terminating, no live stack, hook
      --    NOT called.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef -> do
        let supOps = SupervisorOps
              { sopsInWindowReload = \_ _ -> do
                  modifyIORef' eventsRef (<> [syntheticEvent 103])
                  pure (InWindowReloadTerminal "in-window-cause")
              , sopsCloseStack = pure ()
              , sopsOpenStack  = const (pure (Left "rebuild-cause"))
              }
        _ <- runReloadWith resolver show show recordingHook supOps
               currentPlanRef lastOutcomeRef eventsRef "next"
        pure ()
      readIORef hookCallsRef >>= (@?= [2, 1])  -- unchanged from step 4
  ]
