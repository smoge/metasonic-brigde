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
                                             newIORef, readIORef,
                                             writeIORef)
import qualified Data.List                  as L
import qualified Data.Map.Strict            as M
import           System.Exit                (ExitCode (..))
import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestLiveSession
                                            (LiveSessionCommand (..),
                                             LiveSessionDivergedState (..),
                                             LiveSessionOutcome (..),
                                             LiveSessionResourceEvent (..),
                                             ReloadResolver (..),
                                             SessionStep (..),
                                             LiveStack,
                                             liveSessionCommandIsGatedWhileDiverged,
                                             liveSessionDivergedRefusal,
                                             parseLiveSessionCommand,
                                             printStatusWith,
                                             renderLiveSessionCommandHelp,
                                             renderLiveSessionDemoList,
                                             renderLiveSessionOutcome,
                                             renderLiveSessionResourceEvents,
                                             renderLiveSessionSupervisorEvents,
                                             resourceTimelineForOutcome,
                                             runReloadWith,
                                             runReloadWithSink,
                                             stepFromOutcome,
                                             withTrackedFactory)
import           MetaSonic.App.ManifestLiveIngressOps
                                            (LiveProdIngressIssue)
import           MetaSonic.App.ManifestPreflightEvent
                                            (PreflightRejectionReason (..))
import           MetaSonic.App.ManifestReloadAudioEvent
                                            (ManifestReloadAudioEvent (..))
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
import           MetaSonic.Bridge.Source    (MigrationKey (..))
import           MetaSonic.Bridge.Templates (TemplateGraph (..))
import           MetaSonic.Session.Arbitration (ArbitrationPolicy (..))
import           MetaSonic.Session.RTGraphAdapter (defaultRTGraphAdapterOptions)
import           MetaSonic.Pattern          (ControlTag (..),
                                             SwapLabel (..),
                                             TemplateName (..),
                                             VoiceKey (..))
import           MetaSonic.Session.FanIn    (SessionFanInAudioIssue (..))
import           MetaSonic.Session.Resolve  (RetiredVoiceBinding (..),
                                             RetiredVoiceReason (..),
                                             VoiceBinding (..))
import qualified MetaSonic.Session.ManifestReload as MR


appManifestLiveSessionTests :: TestTree
appManifestLiveSessionTests =
  testGroup "App manifest live session"
  [ testGroup "parseLiveSessionCommand"  parseLiveSessionCommandTests
  , testGroup "renderLiveSessionCommandHelp"
                                         renderLiveSessionCommandHelpTests
  , testGroup "renderLiveSessionDemoList"
                                         renderLiveSessionDemoListTests
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
  , testGroup "supervision diverged surface (2026-05-25-f slice 1)"
                                         supervisionDivergedTests
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
  , row "literal 'demos' is LscDemos"
      "demos" LscDemos
  , row "literal 'controls' is LscControls"
      "controls" LscControls
  , row "literal 'values' is LscValues (Phase 8h)"
      "values" LscValues
  , row "uppercase 'VALUES' is unknown (case-sensitive)"
      "VALUES" (LscUnknown "VALUES")
  , row "'values' with trailing token is unknown"
      "values now" (LscUnknown "values now")
  , row "'values' tolerates leading + trailing whitespace"
      "  values  " LscValues
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
  , row "demos with trailing token is unknown"
      "demos now" (LscUnknown "demos now")
  , row "controls with trailing token is unknown"
      "controls now" (LscUnknown "controls now")
  , row "arbitrary text is unknown"
      "hello world" (LscUnknown "hello world")
  , row "unknown command preserves the original (untrimmed) line"
      "  hello world  " (LscUnknown "  hello world  ")

  -- set TAG VALUE (Phase 8h step 3d). TAG is the manifest @key/slot@
  -- path tail an operator copies from the @controls@ output, not the
  -- human display @name@. The fixture uses @lpf/0@ (the cutoff
  -- control's key in @saw-noise-filter.json@) so the tests describe
  -- what an operator actually types.
  , row "set key/slot value parses as LscUISet"
      "set lpf/0 1500" (LscUISet lpf0 1500)
  , row "set tolerates leading + trailing whitespace"
      "  set lpf/0 1500  " (LscUISet lpf0 1500)
  , row "set parses negative values"
      "set lpf/0 -1.5" (LscUISet lpf0 (-1.5))
  , row "set parses fractional values (different key + slot)"
      "set lpf/1 0.7" (LscUISet (mkTag "lpf" 1) 0.7)
  , row "set with missing value is unknown"
      "set lpf/0" (LscUnknown "set lpf/0")
  , row "set with empty payload is unknown"
      "set " (LscUnknown "set ")
  , row "set without slot separator is unknown"
      "set lpf 1500" (LscUnknown "set lpf 1500")
  , row "set with non-numeric slot is unknown"
      "set lpf/x 1500" (LscUnknown "set lpf/x 1500")
  , row "set with negative slot is unknown"
      "set lpf/-1 1500" (LscUnknown "set lpf/-1 1500")
  , row "set with empty key is unknown"
      "set /0 1500" (LscUnknown "set /0 1500")
  , row "set with non-numeric value is unknown"
      "set lpf/0 abc" (LscUnknown "set lpf/0 abc")
  , row "set with too many tokens is unknown"
      "set lpf/0 1500 extra" (LscUnknown "set lpf/0 1500 extra")
  , row "uppercase 'SET' prefix is unknown (case-sensitive)"
      "SET lpf/0 1500" (LscUnknown "SET lpf/0 1500")
  ]
  where
    row name input expected =
      testCase name $
        parseLiveSessionCommand input @?= expected

    lpf0 = mkTag "lpf" 0
    mkTag k slot = ControlTag (MigrationKey k) slot


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
  [ testCase "renders ten lines: header + nine command rows" $
      length renderLiveSessionCommandHelp @?= 10

  , testCase "first line is the 'commands:' header (two-space indent)" $
      take 1 renderLiveSessionCommandHelp @?= ["  commands:"]

  , testCase "exact body matches the documented vocabulary" $
      renderLiveSessionCommandHelp
        @?= [ "  commands:"
            , "    demo:KEY    supervised reload to catalog demo KEY"
            , "    demo KEY    same, single-token form (no internal whitespace)"
            , "    demos       list manifest demo keys (marks current)"
            , "    controls    print current OSC control surface"
            , "    values      print last accepted control values per active voice"
            , "    set TAG V   write UI control TAG to V (TAG=path from controls)"
            , "    status      print current status (same as <Enter>)"
            , "    help        print commands (same as ?)"
            , "    quit        close session cleanly (same as exit, <Ctrl-D>)"
            ]
  ]


-- ---------------------------------------------------------------------------
-- renderLiveSessionDemoList
-- ---------------------------------------------------------------------------

renderLiveSessionDemoListTests :: [TestTree]
renderLiveSessionDemoListTests =
  [ testCase "marks the current demo and preserves manifest order" $
      renderLiveSessionDemoList
        "preserve-cutoff-dark"
        [ "preserve-cutoff-dark"
        , "preserve-cutoff-bright"
        , "reject-preserving-delay-dark"
        ]
        @?= [ "  demos:"
            , "    * preserve-cutoff-dark (current)"
            , "      preserve-cutoff-bright"
            , "      reject-preserving-delay-dark"
            ]

  , testCase "empty manifest demo list renders an explicit placeholder" $
      renderLiveSessionDemoList "missing" []
        @?= [ "  demos:"
            , "    (none)"
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

  , testCase "Escalated → LsoEscalated + SsContinue (supervision v1: keep loop alive)" $
      -- Supervision v1 (2026-05-25-f, commit landing this slice):
      -- escalation no longer terminates the session. The session
      -- enters the diverged state instead; 'runReloadWithSink'
      -- writes the two causes into 'divergedStateRef', and the
      -- dispatch gate refuses live-stack-needing commands until a
      -- future slice introduces an explicit repair pathway.
      stepFromOutcome (SupervisedReloadEscalated "in-window" "rebuild")
        @?= (LsoEscalated, SsContinue)
  ]


-- ---------------------------------------------------------------------------
-- renderLiveSessionOutcome
-- ---------------------------------------------------------------------------

renderLiveSessionOutcomeTests :: [TestTree]
renderLiveSessionOutcomeTests =
  [ testCase "Committed renders the operator-facing label" $
      renderLiveSessionOutcome LsoCommitted
        @?= "committed (new plan installed)"

  , testCase "CommittedSameDemo distinguishes a same-demo reload from a new-plan install" $
      renderLiveSessionOutcome LsoCommittedSameDemo
        @?= "committed (same demo reloaded)"

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
       (ManifestReloadHostIssue LiveProdIngressIssue)
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
  ManifestReloadEvent (ManifestReloadHostIssue LiveProdIngressIssue)

-- | Local alias for the audio-event timeline ref. Same pin as
-- 'LiveEvent' (production threads the live-shell issue type all the
-- way down) so tests can assert on rendered output that depends on
-- 'Show' for the issue payload.
type LiveAudioEvent =
  ManifestReloadAudioEvent (ManifestReloadHostIssue LiveProdIngressIssue)


-- | Helper: spin up the five IORefs 'runReloadWith' needs and pin
-- the initial state explicitly. Tests then call 'runReloadWith'
-- and assert post-state.
--
-- Phase 8h step 3e v1 slice 4: also produces the
-- 'lastRetiredRef' that 'runReloadWith' clears at the start of
-- each call and populates from the commit-event payload on success.
-- Tests that do not exercise the stale-by-reload path can ignore
-- the ref; tests that do exercise it can pre-seed it with a
-- snapshot to simulate a prior commit.
withSessionRefs
  :: StubPlan
  -> ([LiveEvent]
      -> IORef StubPlan
      -> IORef (Maybe LiveSessionOutcome)
      -> IORef [LiveEvent]
      -> IORef [LiveAudioEvent]
      -> IORef (M.Map VoiceKey RetiredVoiceReason)
      -> IORef (Maybe LiveSessionDivergedState)
      -> IO a)
  -> IO a
withSessionRefs initialPlan k = do
  let preExistingEvents = [syntheticEvent 999]
  currentPlanRef   <- newIORef initialPlan
  lastOutcomeRef   <- newIORef Nothing
  eventsRef        <- newIORef preExistingEvents
  audioEventsRef   <- newIORef []
  lastRetiredRef   <- newIORef M.empty
  divergedStateRef <- newIORef Nothing
  k preExistingEvents currentPlanRef lastOutcomeRef eventsRef
    audioEventsRef lastRetiredRef divergedStateRef


-- | Default no-op for 'runReloadWith's 'onLiveStackChanged' hook.
-- Tests that do not care about the hook pass this; the
-- "onLiveStackChanged hook fires on the right outcomes" test
-- below builds a recording closure instead.
noHook :: StubPlan -> IO ()
noHook _ = pure ()


-- | A stub resolver that maps a fixed key → @Right plan@ and
-- everything else → a 'MprrPlanRejected' synthetic rejection. The
-- mismatched-key path mirrors a planner-style rejection rather than
-- a catalog miss; tests that need the catalog-miss path build the
-- 'MprrCatalogMissed' reason inline.
stubResolver :: String -> StubPlan -> ReloadResolver StubPlan
stubResolver okKey okPlan = ReloadResolver $ \key ->
  if key == okKey
    then Right okPlan
    else Left (MprrPlanRejected
                 ("stub-resolver: no plan for key " <> show key))


-- | A stub resolver that always rejects with a planner-style reason
-- (used for the planning-failure case that is independent of the
-- catalog). Wraps the caller's text into 'MprrPlanRejected' so the
-- existing 'String'-keyed call sites keep working.
stubAlwaysReject :: String -> ReloadResolver StubPlan
stubAlwaysReject reason =
  ReloadResolver (const (Left (MprrPlanRejected reason)))


runReloadWithTests :: [TestTree]
runReloadWithTests =
  [ testCase "bad demo key → LsoPlanRejected, SsContinue, currentPlan unchanged, supOps NOT called" $ do
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
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
                  audioEventsRef
                  lastRetiredRef
                  divergedStateRef
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
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
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
                  audioEventsRef
                  lastRetiredRef
                  divergedStateRef
                  "any-key"
        step @?= SsContinue
        plan <- readIORef currentPlanRef
        plan @?= 1
        outcome <- readIORef lastOutcomeRef
        case outcome of
          Just (LsoPlanRejected reason) ->
            assertBool
              ("rejection reason should contain the resolver's text; got: " <> reason)
              ("manifest does not name this demo" `L.isInfixOf` reason)
          other ->
            assertFailure $
              "expected Just (LsoPlanRejected ...); got " <> show other

  , testCase "Committed → LsoCommitted, SsContinue, currentPlan := requested, events reset" $ do
      withSessionRefs 1 $ \prior currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
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
                  audioEventsRef
                  lastRetiredRef
                  divergedStateRef
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

  , testCase "Committed same-demo (planLabel fallback == requested) → LsoCommittedSameDemo, supervisor still runs, currentPlan written, hook still fires with requested plan" $ do
      -- Phase 8k operator-polish: a same-demo reload still goes
      -- through the full supervised path (in-window reload event,
      -- value-cache retention, post-reload hook); only the
      -- operator-facing outcome wording is refined so the status
      -- line stops saying "new plan installed" when nothing about
      -- the demo identity changed.
      withSessionRefs 1 $ \prior currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        hookCallsRef <- newIORef ([] :: [StubPlan])
        let recordingHook livePlan =
              modifyIORef' hookCallsRef (<> [livePlan])
            -- Initial plan is 1; resolver maps "same" → 1 too, so
            -- 'planLabel' (show, here) is identical for fallback
            -- and requested → triggers the same-demo refinement.
            resolver = stubResolver "same" 1
            supOps   =
              fakeSupOpsWithOutcome eventsRef InWindowReloadCommitted 13
        step <- runReloadWith
                  resolver
                  show
                  show
                  recordingHook
                  supOps
                  currentPlanRef
                  lastOutcomeRef
                  eventsRef
                  audioEventsRef
                  lastRetiredRef
                  divergedStateRef
                  "same"
        step @?= SsContinue
        -- currentPlanRef is still written through (idempotent for
        -- same-demo, but load-bearing if the doc was edited
        -- between reloads — the new plan structure must replace
        -- the old one even when the demo key is unchanged).
        plan <- readIORef currentPlanRef
        plan @?= 1
        readIORef lastOutcomeRef >>= (@?= Just LsoCommittedSameDemo)
        -- Post-reload hook fires with the requested plan, exactly
        -- as it does for cross-demo Committed.
        readIORef hookCallsRef >>= (@?= [1])
        -- supOps' in-window reload was actually invoked: the
        -- synthetic event tagged 13 is present and the pre-existing
        -- events list was cleared.
        events <- readIORef eventsRef
        events @?= [syntheticEvent 13]
        assertBool
          "event reset: pre-existing events should be cleared before sopsInWindowReload runs (same-demo)"
          (events /= prior)

  , testCase "RequestRejected → LsoRequestRejected, SsContinue, currentPlan unchanged" $ do
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
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
                  audioEventsRef
                  lastRetiredRef
                  divergedStateRef
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
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
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
                  audioEventsRef
                  lastRetiredRef
                  divergedStateRef
                  "next"
        step @?= SsContinue
        plan <- readIORef currentPlanRef
        plan @?= 1   -- unchanged: rebuild was from fallback
        readIORef lastOutcomeRef >>= (@?= Just LsoRejectedRecovered)

  , testCase "Escalated → LsoEscalated, SsContinue, currentPlan unchanged, divergedStateRef populated (supervision v1)" $ do
      -- Supervision v1 (2026-05-25-f): escalation keeps the loop
      -- alive. 'stepFromOutcome SupervisedReloadEscalated' now
      -- returns 'SsContinue'; the runtime records the two
      -- 'causeLabel'-rendered cause strings into
      -- 'divergedStateRef' so subsequent 'status' reads can render
      -- a 'no live stack: repair required' block.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
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
                  audioEventsRef
                  lastRetiredRef
                  divergedStateRef
                  "next"
        step @?= SsContinue
        plan <- readIORef currentPlanRef
        plan @?= 1
        readIORef lastOutcomeRef >>= (@?= Just LsoEscalated)
        -- The two causes are rendered through the test's 'show'
        -- 'causeLabel' projection, so the rendered strings are
        -- "\"in-window-cause\"" and "\"rebuild-cause\"" (the
        -- 'show'-quoted form, matching what the operator would
        -- have seen in the immediate 'reload events:' bullets).
        readIORef divergedStateRef >>= (@?=
          Just (LiveSessionDivergedState
                  (show ("in-window-cause" :: String))
                  (show ("rebuild-cause"   :: String))))

  , testCase "two reloads in a row: second reload's events ref does NOT carry the first's events" $ do
      -- Belt-and-suspenders for the event-reset behavior. Run
      -- two reloads back-to-back through the same IORefs; the
      -- second reload's eventsRef snapshot must contain only the
      -- second call's synthetic event, not the first's.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        let resolver = stubResolver "next" 2
            supOpsFirst  =
              fakeSupOpsWithOutcome eventsRef InWindowReloadCommitted 11
            supOpsSecond =
              fakeSupOpsWithOutcome eventsRef InWindowReloadCommitted 12
        _ <- runReloadWith resolver show show noHook supOpsFirst
               currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef "next"
        eventsAfterFirst <- readIORef eventsRef
        eventsAfterFirst @?= [syntheticEvent 11]
        _ <- runReloadWith resolver show show noHook supOpsSecond
               currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef "next"
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
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        let blockingSupOps :: SupervisorOps StubPlan String
            blockingSupOps = SupervisorOps
              { sopsInWindowReload = \_ _ ->
                  assertFailure "supOps must not be called on PlanRejected"
              , sopsCloseStack = assertFailure "close must not be called"
              , sopsOpenStack  = \_ ->
                  assertFailure "open must not be called"
              }
        _ <- runReloadWith resolver show show recordingHook blockingSupOps
               currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef "bad-key"
        pure ()
      readIORef hookCallsRef >>= (@?= ([] :: [StubPlan]))

      -- 2. Committed: hook called with the requested plan.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        let supOps =
              fakeSupOpsWithOutcome eventsRef InWindowReloadCommitted 100
        _ <- runReloadWith resolver show show recordingHook supOps
               currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef "next"
        pure ()
      readIORef hookCallsRef >>= (@?= [2])  -- requestedPlan == 2

      -- 3. RequestRejected: stack unchanged, hook NOT called.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        let supOps =
              fakeSupOpsWithOutcome eventsRef
                (InWindowReloadRejectedLiveFallback "live-fallback")
                101
        _ <- runReloadWith resolver show show recordingHook supOps
               currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef "next"
        pure ()
      -- Hook list still just [2] from the Committed test above.
      readIORef hookCallsRef >>= (@?= [2])

      -- 4. RejectedRecovered: stack was rebuilt on the fallback
      --    plan; hook called with the fallback plan (== 1 here).
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        let supOps = SupervisorOps
              { sopsInWindowReload = \_ _ -> do
                  modifyIORef' eventsRef (<> [syntheticEvent 102])
                  pure (InWindowReloadTerminal "terminal-cause")
              , sopsCloseStack = pure ()
              , sopsOpenStack  = const (pure (Right ()))
              }
        _ <- runReloadWith resolver show show recordingHook supOps
               currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef "next"
        pure ()
      readIORef hookCallsRef >>= (@?= [2, 1])  -- recovered with fallback (1)

      -- 5. Escalated: session terminating, no live stack, hook
      --    NOT called.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        let supOps = SupervisorOps
              { sopsInWindowReload = \_ _ -> do
                  modifyIORef' eventsRef (<> [syntheticEvent 103])
                  pure (InWindowReloadTerminal "in-window-cause")
              , sopsCloseStack = pure ()
              , sopsOpenStack  = const (pure (Left "rebuild-cause"))
              }
        _ <- runReloadWith resolver show show recordingHook supOps
               currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef "next"
        pure ()
      readIORef hookCallsRef >>= (@?= [2, 1])  -- unchanged from step 4

  , testCase "Phase 8h step 3e v1 slice 2/3: runReloadWithSink emits 'retired bindings:' block immediately after 'reload events:' on a commit with retired payload" $ do
      -- Caller-level coverage for the wiring in 'runReloadWithSink'.
      -- The pure helpers in 'AppManifestLiveCommonRetiredBindings'
      -- already pin the renderer/extractor; this test makes sure a
      -- future edit to 'runReloadWithSink' cannot silently drop the
      -- block while leaving the helpers intact.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        outputRef <- newIORef ([] :: [String])
        let captureOutput s =
              modifyIORef' outputRef (<> [s])
            leadRetired =
              RetiredVoiceBinding
                (VoiceBinding (VoiceKey "lead/1") 0 (TemplateName "saw_lead"))
                RvrTemplateGone
            -- Inject a real commit event with a non-empty
            -- retired-binding payload so the extractor in
            -- 'runReloadWithSink' returns 'Just [leadRetired]' and
            -- the wiring prints the corresponding block.
            commitEvent :: LiveEvent
            commitEvent = MrePreservingReloadCommitted [leadRetired]
            supOps :: SupervisorOps StubPlan String
            supOps = SupervisorOps
              { sopsInWindowReload = \_ _ -> do
                  modifyIORef' eventsRef (<> [commitEvent])
                  pure InWindowReloadCommitted
              , sopsCloseStack =
                  assertFailure "sopsCloseStack should not run on a commit"
              , sopsOpenStack  = \_ ->
                  assertFailure "sopsOpenStack should not run on a commit"
              }
            resolver = stubResolver "next" (2 :: StubPlan)
        step <- runReloadWithSink
                  captureOutput
                  resolver
                  show
                  show
                  noHook
                  supOps
                  currentPlanRef
                  lastOutcomeRef
                  eventsRef
                  audioEventsRef
                  lastRetiredRef
                  divergedStateRef
                  "next"
        step @?= SsContinue
        output <- readIORef outputRef
        let block label = elemIndex' label output
        case (block "  reload events:", block "  retired bindings:") of
          (Just rev, Just ret)
            | ret > rev -> pure ()
            | otherwise ->
                assertFailure $
                  "expected 'retired bindings:' after 'reload events:' but got reload@"
                  <> show rev <> " retired@" <> show ret
                  <> "\nfull output:\n" <> unlines output
          (Nothing, _) ->
            assertFailure $
              "missing 'reload events:' header in captured output:\n"
              <> unlines output
          (_, Nothing) ->
            assertFailure $
              "missing 'retired bindings:' header in captured output:\n"
              <> unlines output

        -- The retired-binding row must actually render with the
        -- voice key and reason; the renderer test pins the shape
        -- but the caller could in principle pass an empty list to
        -- the renderer instead of the real payload.
        let retiredRow =
              "    - voice \"lead/1\" template \"saw_lead\""
                <> " reason: template-gone"
        assertBool
          ("expected retired-binding row in output:\n" <> unlines output)
          (retiredRow `elem` output)

  , testCase "Phase 8h step 3e v1 slice 4: runReloadWithSink preserves a retired snapshot published by the orchestrator hook before ingress reopen (race-fix)" $ do
      -- The race fix moved snapshot publishing from
      -- 'runReloadWithSink' (which runs *after* the supervisor
      -- returns) into the orchestrator's 'hproOnRetired' /
      -- 'hsaroOnRetired' hook (which fires *before* ingress
      -- reopens). This test bypasses the real orchestrator with a
      -- stub 'SupervisorOps', so it simulates the hook by writing
      -- the IORef inside 'sopsInWindowReload' — the same moment in
      -- the timeline the production orchestrator does. The
      -- assertion then confirms 'runReloadWithSink' does *not*
      -- clobber the snapshot after the commit event renders, so a
      -- subsequent producer drain attributes correctly.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        let leadRetired =
              RetiredVoiceBinding
                (VoiceBinding (VoiceKey "lead/1") 0 (TemplateName "saw_lead"))
                RvrTemplateGone
            commitEvent :: LiveEvent
            commitEvent = MrePreservingReloadCommitted [leadRetired]
            simulateOrchestratorHook = do
              -- Mirrors what 'rrhsiOnRetired' does in production
              -- before 'finishOk' emits the commit event.
              writeIORef lastRetiredRef
                (M.fromList [(VoiceKey "lead/1", RvrTemplateGone)])
            supOps :: SupervisorOps StubPlan String
            supOps = SupervisorOps
              { sopsInWindowReload = \_ _ -> do
                  simulateOrchestratorHook
                  modifyIORef' eventsRef (<> [commitEvent])
                  pure InWindowReloadCommitted
              , sopsCloseStack =
                  assertFailure "sopsCloseStack should not run on a commit"
              , sopsOpenStack  = \_ ->
                  assertFailure "sopsOpenStack should not run on a commit"
              }
            resolver = stubResolver "next" (2 :: StubPlan)
        _ <- runReloadWith
               resolver show show noHook supOps
               currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef "next"
        snapshot <- readIORef lastRetiredRef
        snapshot @?= M.fromList [(VoiceKey "lead/1", RvrTemplateGone)]

  , testCase "Phase 8h step 3e v1 slice 4: runReloadWithSink clears lastRetiredRef at reload start even when no commit fires" $ do
      -- If the supervisor rejects the request, no commit event is
      -- emitted and 'retiredBindingsFromEvents' returns 'Nothing'.
      -- The snapshot must still be cleared at reload start so a
      -- stale set from a *prior* commit cannot mis-attribute drains
      -- against the now-rejected attempt.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        -- Pre-seed the snapshot with a prior commit's retired set.
        writeIORef lastRetiredRef
          (M.fromList [(VoiceKey "pad/A", RvrOwnerReplaced)])
        let supOps :: SupervisorOps StubPlan String
            supOps = SupervisorOps
              { sopsInWindowReload = \_ _ -> do
                  modifyIORef' eventsRef (<> [syntheticEvent 42])
                  pure (InWindowReloadRejectedLiveFallback "rejected")
              , sopsCloseStack =
                  assertFailure "sopsCloseStack should not run on a RejectedLiveFallback"
              , sopsOpenStack  = \_ ->
                  assertFailure "sopsOpenStack should not run on a RejectedLiveFallback"
              }
            resolver = stubResolver "next" (2 :: StubPlan)
        _ <- runReloadWith
               resolver show show noHook supOps
               currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef "next"
        snapshot <- readIORef lastRetiredRef
        snapshot @?= M.empty

  , testCase "Phase 8h step 3e v1 slice 4: rrhsiOnRetired fired but reload then fails late -> lastRetiredRef is rolled back to empty (no-commit cleanup)" $ do
      -- The orchestrator's 'hproOnRetired' / 'hsaroOnRetired' hook
      -- fires *before* the audio-restart / ingress-reopen steps,
      -- which can still fail. When they do, no commit event is
      -- emitted, but the hook has already published the retired
      -- set. Without the no-commit rollback in 'runReloadWithSink',
      -- subsequent stale drains would attribute against a reload
      -- that did not commit. This test simulates that pattern: the
      -- fake 'sopsInWindowReload' both publishes the snapshot
      -- (mirroring the orchestrator hook) and returns a terminal
      -- rejection (mirroring a later orchestration failure). After
      -- 'runReloadWithSink' returns, the snapshot must be empty.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        let leadRetired =
              RetiredVoiceBinding
                (VoiceBinding (VoiceKey "lead/1") 0 (TemplateName "saw_lead"))
                RvrTemplateGone
            simulateOrchestratorHook =
              writeIORef lastRetiredRef
                (M.fromList [(VoiceKey "lead/1", RvrTemplateGone)])
            supOps :: SupervisorOps StubPlan String
            supOps = SupervisorOps
              { sopsInWindowReload = \_ _ -> do
                  -- Hook fires first (analogous to the
                  -- orchestrator calling rrhsiOnRetired between
                  -- the reload op and ingress reopen)…
                  simulateOrchestratorHook
                  -- …then ingress reopen fails, so no commit
                  -- event is emitted.
                  pure (InWindowReloadTerminal "ingress-reopen-failed")
              , sopsCloseStack = pure ()
              , sopsOpenStack  = const (pure (Left "rebuild-cause"))
              }
            resolver = stubResolver "next" (2 :: StubPlan)
        -- Quiet the stderr escalation line that fires on
        -- 'SupervisedReloadEscalated'; it's not part of this
        -- assertion.
        _ <- try @SomeException $ runReloadWith
               resolver show show noHook supOps
               currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef "next"
        snapshot <- readIORef lastRetiredRef
        snapshot @?= M.empty
        -- And the payload we attempted to publish was non-empty,
        -- so the assertion is meaningful (not vacuously testing
        -- against the at-start clear).
        leadRetired `seq` pure ()

  , testCase "Phase 8h step 3e v2 slice 1: unknown key emits preflight rejection block and does NOT call supervisor" $ do
      -- The resolver-stage preflight slice closes the gap where a
      -- resolver-Left used to print only 'reload rejected: <text>'
      -- with no operator-visible event timeline. The new contract:
      -- a 'preflight events:' block always renders, even on the
      -- short-circuit Left path, and the supervisor is still not
      -- invoked.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        outputRef <- newIORef ([] :: [String])
        let captureOutput s =
              modifyIORef' outputRef (<> [s])
            blockingSupOps :: SupervisorOps StubPlan String
            blockingSupOps = SupervisorOps
              { sopsInWindowReload = \_ _ ->
                  assertFailure
                    "supOps should not be called on resolver-stage rejection"
              , sopsCloseStack =
                  assertFailure
                    "sopsCloseStack should not run on resolver-stage rejection"
              , sopsOpenStack  = \_ ->
                  assertFailure
                    "sopsOpenStack should not run on resolver-stage rejection"
              }
            -- Catalog-miss style rejection: 'MprrCatalogMissed'
            -- with no planner-detail string.
            resolver = ReloadResolver $ \_ ->
              Left MprrCatalogMissed :: Either PreflightRejectionReason StubPlan
        step <- runReloadWithSink
                  captureOutput
                  resolver
                  show
                  show
                  noHook
                  blockingSupOps
                  currentPlanRef
                  lastOutcomeRef
                  eventsRef
                  audioEventsRef
                  lastRetiredRef
                  divergedStateRef
                  "unknown"
        step @?= SsContinue
        output <- readIORef outputRef
        -- Preflight header must be present.
        assertBool
          ("missing 'preflight events:' header in captured output:\n"
           <> unlines output)
          ("  preflight events:" `elem` output)
        -- Started + rejected bullets must both appear, in that
        -- order, with the catalog-miss reason label.
        let startedRow  = "    - preflight started: \"unknown\""
            rejectedRow = "    - preflight rejected: \"unknown\""
                            <> " (catalog-missed)"
            started  = elemIndex' startedRow  output
            rejected = elemIndex' rejectedRow output
        case (started, rejected) of
          (Just iStarted, Just iRejected)
            | iRejected > iStarted -> pure ()
            | otherwise ->
                assertFailure $
                  "expected preflight rejected after started but got "
                  <> "started@" <> show iStarted
                  <> " rejected@" <> show iRejected
                  <> "\nfull output:\n" <> unlines output
          _ ->
            assertFailure $
              "missing started/rejected bullets in output:\n"
              <> unlines output
        -- The 'reload events:' block must NOT render on a
        -- resolver-stage rejection — the supervisor never ran, so
        -- there is no strategy lifecycle to report. (The slice
        -- preserves the existing short-circuit; the alternative
        -- contract of rendering with '(none)' is rejected because
        -- it implies a strategy was selected.)
        assertBool
          ("'reload events:' header should not render on "
           <> "resolver-stage rejection but found it; output:\n"
           <> unlines output)
          (not ("  reload events:" `elem` output))
        -- Outcome must be 'LsoPlanRejected' carrying the legacy
        -- catalog-miss text (with the requested key) so 'status'
        -- reads continue to identify which key was rejected. The
        -- preflight bullet above carries the short structured label;
        -- the legacy outcome string is preserved verbatim.
        outcome <- readIORef lastOutcomeRef
        case outcome of
          Just (LsoPlanRejected reason) ->
            reason @?= "no demo named \"unknown\" in catalog"
          other ->
            assertFailure $
              "expected Just (LsoPlanRejected "
              <> "\"no demo named \\\"unknown\\\" in catalog\"); got "
              <> show other

  , testCase "Phase 8h step 3e v2 slice 1: known key emits preflight started/succeeded BEFORE reload events" $ do
      -- The success-path ordering contract: 'preflight events:' is
      -- always rendered ahead of 'reload events:' so the operator
      -- transcript reads top-down through the lifecycle (preflight
      -- → strategy lifecycle → retired bindings).
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        outputRef <- newIORef ([] :: [String])
        let captureOutput s =
              modifyIORef' outputRef (<> [s])
            supOps :: SupervisorOps StubPlan String
            supOps =
              fakeSupOpsWithOutcome eventsRef InWindowReloadCommitted 7
            resolver = stubResolver "next" (2 :: StubPlan)
        step <- runReloadWithSink
                  captureOutput
                  resolver
                  show
                  show
                  noHook
                  supOps
                  currentPlanRef
                  lastOutcomeRef
                  eventsRef
                  audioEventsRef
                  lastRetiredRef
                  divergedStateRef
                  "next"
        step @?= SsContinue
        output <- readIORef outputRef
        let block label = elemIndex' label output
        case (block "  preflight events:", block "  reload events:") of
          (Just pre, Just rel)
            | pre < rel -> pure ()
            | otherwise ->
                assertFailure $
                  "expected 'preflight events:' before 'reload events:' "
                  <> "but got preflight@" <> show pre
                  <> " reload@" <> show rel
                  <> "\nfull output:\n" <> unlines output
          (Nothing, _) ->
            assertFailure $
              "missing 'preflight events:' header in captured output:\n"
              <> unlines output
          (_, Nothing) ->
            assertFailure $
              "missing 'reload events:' header in captured output:\n"
              <> unlines output
        -- Started + succeeded bullets must both appear with the key.
        let startedRow   = "    - preflight started: \"next\""
            succeededRow = "    - preflight succeeded: \"next\""
        assertBool
          ("missing preflight started bullet:\n" <> unlines output)
          (startedRow `elem` output)
        assertBool
          ("missing preflight succeeded bullet:\n" <> unlines output)
          (succeededRow `elem` output)

  , testCase "Phase 8h step 3e v2 slice 2: stopped-audio reload renders 'audio events:' block between 'reload events:' and 'retired bindings:' with the full stop/start timeline" $ do
      -- Caller-level coverage for the wiring in 'runReloadWithSink'.
      -- The fake supOps stuffs synthetic audio events into the
      -- shared ref the same way the production stopped-audio
      -- orchestrator does via 'rrhsiOnAudioEvent', and emits a
      -- commit event with a non-empty retired payload so the
      -- 'retired bindings:' block also renders. The assertion
      -- pins the relative order of the three blocks and the
      -- per-bullet timeline shape.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        outputRef <- newIORef ([] :: [String])
        let captureOutput s =
              modifyIORef' outputRef (<> [s])
            leadRetired =
              RetiredVoiceBinding
                (VoiceBinding (VoiceKey "lead/1") 0 (TemplateName "saw_lead"))
                RvrOwnerReplaced
            commitEvent :: LiveEvent
            commitEvent = MreStoppedAudioReloadCommitted [leadRetired]
            -- Full success-path audio timeline the stopped-audio
            -- orchestrator emits: stop attempt + success then
            -- start attempt + success.
            audioTimeline :: [LiveAudioEvent]
            audioTimeline =
              [ MraeStopAttempted
              , MraeStopSucceeded
              , MraeStartAttempted
              , MraeStartSucceeded
              ]
            supOps :: SupervisorOps StubPlan String
            supOps = SupervisorOps
              { sopsInWindowReload = \_ _ -> do
                  modifyIORef' eventsRef (<> [commitEvent])
                  modifyIORef' audioEventsRef (<> audioTimeline)
                  pure InWindowReloadCommitted
              , sopsCloseStack =
                  assertFailure "sopsCloseStack should not run on a commit"
              , sopsOpenStack  = \_ ->
                  assertFailure "sopsOpenStack should not run on a commit"
              }
            resolver = stubResolver "next" (2 :: StubPlan)
        step <- runReloadWithSink
                  captureOutput
                  resolver
                  show
                  show
                  noHook
                  supOps
                  currentPlanRef
                  lastOutcomeRef
                  eventsRef
                  audioEventsRef
                  lastRetiredRef
                  divergedStateRef
                  "next"
        step @?= SsContinue
        output <- readIORef outputRef
        let block label = elemIndex' label output
        -- Block ordering: reload events -> audio events -> retired bindings.
        case ( block "  reload events:"
             , block "  audio events:"
             , block "  retired bindings:"
             ) of
          (Just rev, Just aud, Just ret)
            | rev < aud && aud < ret -> pure ()
            | otherwise ->
                assertFailure $
                  "expected order reload events < audio events < retired bindings,"
                  <> " got reload@" <> show rev
                  <> " audio@" <> show aud
                  <> " retired@" <> show ret
                  <> "\nfull output:\n" <> unlines output
          (Nothing, _, _) ->
            assertFailure $
              "missing 'reload events:' header in output:\n" <> unlines output
          (_, Nothing, _) ->
            assertFailure $
              "missing 'audio events:' header in output:\n" <> unlines output
          (_, _, Nothing) ->
            assertFailure $
              "missing 'retired bindings:' header in output:\n" <> unlines output
        -- Per-bullet timeline: the four success-path rows must
        -- appear in declared order under the header.
        let stopAttemptedRow  = "    - audio stop attempted"
            stopSucceededRow  = "    - audio stop succeeded"
            startAttemptedRow = "    - audio start attempted"
            startSucceededRow = "    - audio start succeeded"
            bulletIxs =
              [ elemIndex' stopAttemptedRow  output
              , elemIndex' stopSucceededRow  output
              , elemIndex' startAttemptedRow output
              , elemIndex' startSucceededRow output
              ]
        case sequence bulletIxs of
          Nothing ->
            assertFailure $
              "one or more audio-event bullets missing; got "
              <> show bulletIxs
              <> "\nfull output:\n" <> unlines output
          Just ixs ->
            assertBool
              ("audio-event bullets must be in declared order; got "
               <> show ixs
               <> "\nfull output:\n" <> unlines output)
              (ixs == L.sort ixs)

  , testCase "Phase 8h step 3e v2 slice 2: an audio-start failure surfaces as MraeStartFailed and the reload outcome is rejected" $ do
      -- Simulates the production 'HsariAudioRestartFailed' branch:
      -- the orchestrator runs stop OK, then start fails. The audio
      -- timeline truncates at 'MraeStartFailed'; the supervisor
      -- classifies the outcome as terminal and the live session
      -- records a rejection. The renderer must surface the failure
      -- payload (we rely on 'Show' for the issue, matching what
      -- production does for the strategy-level 'HsariAudioRestart
      -- Failed' line).
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        outputRef <- newIORef ([] :: [String])
        let captureOutput s =
              modifyIORef' outputRef (<> [s])
            failedIssue :: ManifestReloadHostIssue LiveProdIngressIssue
            failedIssue =
              MrhiAudio (SfaiStartFailed 12)
            audioTimeline :: [LiveAudioEvent]
            audioTimeline =
              [ MraeStopAttempted
              , MraeStopSucceeded
              , MraeStartAttempted
              , MraeStartFailed failedIssue
              ]
            supOps :: SupervisorOps StubPlan String
            supOps = SupervisorOps
              { sopsInWindowReload = \_ _ -> do
                  modifyIORef' audioEventsRef (<> audioTimeline)
                  -- Stopped-audio terminal failure rebuilds; the
                  -- supervisor's terminal branch is the closest
                  -- analogue to a real audio-restart failure
                  -- without dragging the full host stack into the
                  -- fixture.
                  pure (InWindowReloadTerminal "audio-restart-failed")
              , sopsCloseStack  = pure ()
              , sopsOpenStack   = const (pure (Right ()))
              }
            resolver = stubResolver "next" (2 :: StubPlan)
        step <- runReloadWithSink
                  captureOutput
                  resolver
                  show
                  show
                  noHook
                  supOps
                  currentPlanRef
                  lastOutcomeRef
                  eventsRef
                  audioEventsRef
                  lastRetiredRef
                  divergedStateRef
                  "next"
        step @?= SsContinue
        output <- readIORef outputRef
        -- Header must be present and the failure bullet must
        -- include the issue payload's 'Show' rendering.
        assertBool
          ("missing 'audio events:' header in output:\n" <> unlines output)
          ("  audio events:" `elem` output)
        let startFailedRow =
              "    - audio start failed: " <> show failedIssue
        assertBool
          ("missing 'audio start failed' bullet with issue payload "
           <> show failedIssue <> ":\n" <> unlines output)
          (startFailedRow `elem` output)
        -- The recovered outcome (terminal in-window, rebuild OK)
        -- is what 'runReloadWithSink' records when stopped-audio
        -- fails terminally and the rebuild from the fallback plan
        -- succeeds.
        outcome <- readIORef lastOutcomeRef
        case outcome of
          Just LsoRejectedRecovered -> pure ()
          other ->
            assertFailure $
              "expected Just LsoRejectedRecovered; got " <> show other

  , testCase "Phase 8h step 3e v2 slice 2: a preserving reload (empty audio timeline) suppresses the 'audio events:' header entirely" $ do
      -- The block is suppressed when no audio events fire so a
      -- preserving reload's transcript does not carry a dead
      -- header. The supOps here mirrors the slice 2 retired-
      -- bindings test but does NOT push any audio events.
      withSessionRefs 1 $ \_ currentPlanRef lastOutcomeRef eventsRef audioEventsRef lastRetiredRef divergedStateRef -> do
        outputRef <- newIORef ([] :: [String])
        let captureOutput s =
              modifyIORef' outputRef (<> [s])
            commitEvent :: LiveEvent
            commitEvent = MrePreservingReloadCommitted []
            supOps :: SupervisorOps StubPlan String
            supOps = SupervisorOps
              { sopsInWindowReload = \_ _ -> do
                  modifyIORef' eventsRef (<> [commitEvent])
                  pure InWindowReloadCommitted
              , sopsCloseStack =
                  assertFailure "sopsCloseStack should not run on a commit"
              , sopsOpenStack  = \_ ->
                  assertFailure "sopsOpenStack should not run on a commit"
              }
            resolver = stubResolver "next" (2 :: StubPlan)
        step <- runReloadWithSink
                  captureOutput
                  resolver
                  show
                  show
                  noHook
                  supOps
                  currentPlanRef
                  lastOutcomeRef
                  eventsRef
                  audioEventsRef
                  lastRetiredRef
                  divergedStateRef
                  "next"
        step @?= SsContinue
        output <- readIORef outputRef
        assertBool
          ("'audio events:' header must not render when the "
           <> "timeline is empty (preserving / pre-audio failure)"
           <> "; output:\n" <> unlines output)
          (not ("  audio events:" `elem` output))
  ]
  where
    elemIndex' needle =
      lookupIx 0
      where
        lookupIx _ [] = Nothing
        lookupIx i (x : xs)
          | x == needle = Just (i :: Int)
          | otherwise   = lookupIx (i + 1) xs


-- | Supervision v1 (2026-05-25-f, slice 1): the diverged-state
-- surface. Three concerns are pinned by this group: the
-- per-command gate policy ('liveSessionCommandIsGatedWhileDiverged'),
-- the operator-facing refusal text ('liveSessionDivergedRefusal'),
-- and the 'printStatusWith' render block that appears when
-- @divergedStateRef@ is populated.
supervisionDivergedTests :: [TestTree]
supervisionDivergedTests =
  [ testCase "gate policy: reload, set, controls, values are gated; status, demos, help, quit are not" $ do
      -- Pin the per-command gate table. If a future slice adds a
      -- repair-style command, this assertion forces an explicit
      -- decision about whether it belongs in the gated set rather
      -- than letting it slip through silently.
      liveSessionCommandIsGatedWhileDiverged (LscReloadTo "next") @?= True
      liveSessionCommandIsGatedWhileDiverged
        (LscUISet
           (ControlTag (MigrationKey "lpf") 0)
           1500.0)                                       @?= True
      liveSessionCommandIsGatedWhileDiverged LscControls @?= True
      liveSessionCommandIsGatedWhileDiverged LscValues   @?= True
      liveSessionCommandIsGatedWhileDiverged LscStatus   @?= False
      liveSessionCommandIsGatedWhileDiverged LscDemos    @?= False
      liveSessionCommandIsGatedWhileDiverged LscHelp     @?= False
      liveSessionCommandIsGatedWhileDiverged LscQuit     @?= False

  , testCase "refusal text is three lines naming the divergence and the available commands" $ do
      -- The exact wording matters because it is what the operator
      -- sees on every gated keystroke. Pin it so a copy-edit drift
      -- in the future has to update the test deliberately.
      liveSessionDivergedRefusal @?=
        [ "  no live stack: repair required."
        , "  this command is unavailable while the session is diverged."
        , "  available commands: status, demos, help, quit."
        ]

  , testCase "printStatusWith renders 'no live stack: repair required' block when divergedStateRef is populated" $ do
      -- 'trackedStackRef' is 'Nothing' (the supervisor's
      -- 'hsfCloseStack' finally already cleared it after
      -- escalation), so 'status' takes the (no live stack) path
      -- for the audio line; the new block sits between that line
      -- and 'last outcome:'.
      outputRef <- newIORef ([] :: [String])
      let captureOutput s =
            modifyIORef' outputRef (<> [s])
      trackedStackRef  <- newIORef (Nothing :: Maybe LiveStack)
      currentPlanRef   <- newIORef (mkPlan "fallback")
      lastOutcomeRef   <- newIORef (Just LsoEscalated)
      divergedStateRef <- newIORef
        (Just (LiveSessionDivergedState
                "\"in-window-cause\""
                "\"rebuild-cause\""))
      printStatusWith
        captureOutput
        trackedStackRef
        currentPlanRef
        lastOutcomeRef
        divergedStateRef
      output <- readIORef outputRef
      let block label = elemIndex' label output
      assertBool
        ("missing '  no live stack:     repair required' header in:\n"
         <> unlines output)
        ("    no live stack:     repair required" `elem` output)
      assertBool
        ("missing in-window cause row in:\n" <> unlines output)
        ("      in-window cause: \"in-window-cause\"" `elem` output)
      assertBool
        ("missing rebuild cause row in:\n" <> unlines output)
        ("      rebuild cause:   \"rebuild-cause\"" `elem` output)
      -- The block appears between (no live stack) and last outcome.
      case ( block "    audio running:     (no live stack)"
           , block "    no live stack:     repair required"
           , block "    last outcome:      escalated (no live stack)") of
        (Just iAudio, Just iBlock, Just iOutcome)
          | iAudio < iBlock && iBlock < iOutcome -> pure ()
          | otherwise ->
              assertFailure $
                "expected order (no live stack) < diverged block < last outcome; "
                <> "got audio@" <> show iAudio
                <> " block@"   <> show iBlock
                <> " outcome@" <> show iOutcome
                <> "\nfull output:\n" <> unlines output
        _ ->
          assertFailure $
            "could not locate all three anchors in output:\n"
            <> unlines output

  , testCase "printStatusWith does NOT render the diverged block when divergedStateRef is Nothing" $ do
      -- Symmetric guarantee: never-opened sessions and ordinary
      -- post-reload status reads must not show the divergence
      -- header.
      outputRef <- newIORef ([] :: [String])
      let captureOutput s =
            modifyIORef' outputRef (<> [s])
      trackedStackRef  <- newIORef (Nothing :: Maybe LiveStack)
      currentPlanRef   <- newIORef (mkPlan "fallback")
      lastOutcomeRef   <- newIORef (Nothing :: Maybe LiveSessionOutcome)
      divergedStateRef <- newIORef Nothing
      printStatusWith
        captureOutput
        trackedStackRef
        currentPlanRef
        lastOutcomeRef
        divergedStateRef
      output <- readIORef outputRef
      assertBool
        ("unexpected 'no live stack: repair required' header in:\n"
         <> unlines output)
        (not ("    no live stack:     repair required" `elem` output))
  ]
  where
    elemIndex' needle =
      lookupIx 0
      where
        lookupIx _ [] = Nothing
        lookupIx i (x : xs)
          | x == needle = Just (i :: Int)
          | otherwise   = lookupIx (i + 1) xs

    mkPlan demoKey = MR.ManifestReloadPlan
      { MR.mrlpDemoKey           = demoKey
      , MR.mrlpSwapLabel         = SwapLabel demoKey
      , MR.mrlpTemplateGraph     = TemplateGraph [] M.empty
      , MR.mrlpAdapterOptions    = defaultRTGraphAdapterOptions
      , MR.mrlpControlSurface    = []
      , MR.mrlpArbitrationPolicy = FifoOnly
      }
