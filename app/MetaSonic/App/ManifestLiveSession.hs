{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}

-- |
-- Module      : MetaSonic.App.ManifestLiveSession
-- Description : Manifest-backed live session shell — Phase 8 v0.
--
-- The audible @--manifest-live-session MANIFEST.json DEMO@ entrypoint.
-- Unlike "MetaSonic.App.ManifestLiveReloadDemo" (a hardcoded two-shot
-- OLD\/NEW reload smoke), this is the first open-ended live consumer
-- of the manifest reload pipeline: it starts audio from a single
-- authored demo + manifest pair, opens OSC ingress, and runs a tiny
-- stdin command loop where the operator can trigger supervised
-- reloads to other catalog demos by typing @demo:KEY@ or
-- @demo KEY@ (single-token form).
--
-- It is intentionally narrow:
--
--   * Single active demo / template graph at any moment.
--   * No GUI toolkit. No new event streams (allocation, stale-command).
--   * No hardware-CI promotion. Tier-2 evidence by the dedicated
--     wrapper at
--     @tools/manifest_live_session_require_preserving_smoke.sh@.
--   * Default strategy is 'RequirePreserving' — safest-by-default.
--     Other strategies are opt-in via @--strategy STRATEGY@.
--   * The stdin protocol is not a real REPL. A small set of command
--     shapes is
--     parsed by 'parseLiveSessionCommand': 'LscReloadTo' (@demo:KEY@
--     colon form or @demo KEY@ single-token form), 'LscDemos'
--     (@demos@), 'LscControls' (@controls@), 'LscStatus' (empty line
--     or @status@), 'LscHelp' (@help@ \/ @?@), 'LscQuit' (@quit@ \/
--     @exit@ \/ EOF), and 'LscUnknown' for everything else. An
--     'LscUnknown' echoes the original input and prints the same
--     command vocabulary 'LscHelp' does, so a typo immediately tells
--     the operator what's accepted.
--
-- The session shell is the first real consumer of the supervisor
-- migration arc (slices 5.1–5.5). Until something concrete consumes
-- the supervised lifecycle interactively, every \"consumer-gated\"
-- decision downstream (resource\/allocation event streaming,
-- stale-command semantics, GUI bindings) is being made in the
-- abstract. This entrypoint is what those decisions get tested
-- against next.

module MetaSonic.App.ManifestLiveSession
  ( -- * Entry point
    runManifestLiveSession

    -- * Stdin command surface (pure, table-tested)
  , LiveSessionCommand (..)
  , parseLiveSessionCommand
  , renderLiveSessionCommandHelp
  , renderLiveSessionDemoList

    -- * Outcome state machine (pure, table-tested)
  , LiveSessionOutcome (..)
  , renderLiveSessionOutcome
  , SessionStep (..)
  , stepFromOutcome

    -- * Resource timeline (pure, table-tested observability projection)
    --
    -- A flat, derived projection of a 'SupervisedReloadOutcome' onto
    -- the resource consequences the operator should see (close /
    -- open / which plan is serving). The events come from the
    -- supervisor contract, not new instrumentation inside
    -- 'realOpen' / 'realClose'.
  , LiveSessionResourceEvent (..)
  , resourceTimelineForOutcome
  , renderLiveSessionResourceEvents

    -- * Supervisor event stream rendering (pure, table-tested)
    --
    -- Operator-facing wording for the observed
    -- 'SupervisedReloadEvent' stream emitted by
    -- 'reloadSupervisedWithEvents'. Co-exists with the derived
    -- 'renderLiveSessionResourceEvents' summary: the resource
    -- timeline says "what is now true", the supervisor events say
    -- "what happened, in order".
  , renderLiveSessionSupervisorEvents

    -- * Tracked-stack factory wrapper (exported for tests)
  , withTrackedFactory

    -- * Testable reload command core
    --
    -- 'runReloadWith' is the IO body that 'sessionLoop' dispatches
    -- to on an 'LscReloadTo'. It is parameterized over an
    -- injectable plan resolver so tests can exercise the
    -- catalog-lookup + planning failure paths and the supervisor-
    -- outcome IORef-mutation paths without staging a real manifest
    -- doc or catalog fixture. Production calls 'runReloadWith'
    -- through 'catalogPlanResolver' against the live doc + catalog.
  , ReloadResolver (..)
  , catalogPlanResolver
  , runReloadWith
  , runReloadWithSink
  ) where

import           Control.Exception              (finally, mask)
import           Control.Monad                  (when)
import           Control.Monad.IO.Class         (liftIO)
import qualified System.Console.Haskeline       as Haskeline
import           Data.Char                      (isSpace)
import           Data.IORef                     (IORef, modifyIORef',
                                                 newIORef, readIORef,
                                                 writeIORef)
import           Data.List                      (dropWhileEnd, find,
                                                 isPrefixOf)
import qualified Data.Map.Strict                as M
import qualified Data.Set                       as Set
import           System.Exit                    (ExitCode (..), die,
                                                 exitWith)
import           System.IO                      (BufferMode (..), hFlush,
                                                 hPutStrLn, hSetBuffering,
                                                 stderr, stdout)

import           MetaSonic.App.Demos            (Demo (..), demoTable,
                                                 demoManifestReloadCatalog)
import           MetaSonic.App.ManifestLiveCommon
                                                (autoStartTemplatesWith,
                                                 liveAudioOptions,
                                                 liveIngressTargetPolicy,
                                                 liveOSCListenerHooksForObservedWith,
                                                 liveReloadProducer,
                                                 planOrDie,
                                                 printAddressableSurfaceWith,
                                                 printIngressSnapshotWith,
                                                 printServiceSnapshotWith,
                                                 readManifestDocOrDie,
                                                 renderIngressSnapshot,
                                                 renderLiveReloadEvents,
                                                 renderOSCControls,
                                                 renderOSCControlsWith,
                                                 targetOrDie,
                                                 warnIfMissingVoicesWith)
import           MetaSonic.App.ManifestLiveValueCache
                                                (LiveValueCache,
                                                 emptyLiveValueCache,
                                                 recordAcceptedWrite,
                                                 renderValuesTable,
                                                 retainSurvivingControls)
import           MetaSonic.App.ManifestReloadOSCBinding
                                                (ManifestOSCControlBinding (..),
                                                 motControls)
import           MetaSonic.App.ManifestOSCIngressOps
                                                (ManifestOSCIngressHandle,
                                                 ManifestOSCIngressOpsIssue,
                                                 manifestOSCIngressOpsWithTargetHooks)
import           MetaSonic.App.ManifestOSCListener
                                                (ListenerConfig)
import           MetaSonic.App.ManifestReloadCli
                                                (planManifestReloadForDemo,
                                                 renderManifestReloadCliIssue,
                                                 renderManifestReloadHostStrategy,
                                                 renderPreservingHostStackIssueTag,
                                                 renderStoppedAudioHostStackIssueTag,
                                                 renderTryPreservingHostStackIssueTag)
import           MetaSonic.App.ManifestReloadEvent
                                                (ManifestReloadEvent)
import           MetaSonic.App.ManifestReloadHost
                                                (ManifestReloadHostConfig (..),
                                                 ManifestReloadHostIssue,
                                                 ManifestReloadHostStrategy (..))
import           MetaSonic.App.ManifestReloadHostStack
                                                (RealReloadHostStackInputs (..),
                                                 ReloadHostStack (..),
                                                 mkStoppedAudioHostStackFactory,
                                                 realStoppedAudioHostStackOps)
import           MetaSonic.App.ManifestReloadPreservingHostStack
                                                (mkPreservingHostStackFactory,
                                                 realPreservingHostStackOps)
import           MetaSonic.App.ManifestReloadTryPreservingHostStack
                                                (mkTryPreservingHostStackFactory,
                                                 realTryPreservingHostStackOps)
import           MetaSonic.App.ManifestReloadSupervisor
                                                (SupervisedReloadEvent (..),
                                                 SupervisedReloadOutcome (..),
                                                 SupervisorOps,
                                                 reloadSupervisedWithEvents)
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                                (HostStackFactory (..),
                                                 withHostStackSupervisorAdapter)
import           MetaSonic.App.ManifestReloadIngress
                                                (readManifestReloadIngressManager)
import           MetaSonic.App.ManifestReloadIngressTarget
                                                (ManifestReloadIngressTarget (..),
                                                 manifestReloadIngressTargetFromPlan)
import           MetaSonic.Authoring.Manifest   (AuthoringManifest (..),
                                                 AuthoringManifestDoc (..))
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.FanIn        (SessionFanInSnapshot (..),
                                                 defaultSessionFanInAudioFFI)
import           MetaSonic.Session.FanInService (defaultSessionFanInServiceHooks,
                                                 defaultSessionFanInServiceOptions,
                                                 readSessionFanInService)
import           MetaSonic.Session.OSCProducer  (defaultOSCProducerOptions)
import           MetaSonic.Session.Owner        (defaultSessionOwnerOptions)
import           MetaSonic.Session.State        (SessionState (..))


-- ============================================================================
-- Stdin command surface
-- ============================================================================

-- | One line of operator input parsed into a session command.
--
-- The parser is intentionally tiny: it recognizes a handful of
-- named commands plus two reload shapes (@demo:KEY@ and
-- @demo KEY@), and treats everything else as 'LscUnknown'.
-- 'LscQuit' is parsed (as @quit@ or @exit@), and the read loop
-- treats Haskeline's @getInputLine@ returning @Nothing@ (EOF /
-- @<Ctrl-D>@) the same way it treats @LscQuit@, so a @<Ctrl-D>@
-- press and a typed @quit@ produce the same outcome.
--
-- Whitespace policy: leading and trailing whitespace is trimmed
-- before pattern-matching. An empty or whitespace-only line is
-- 'LscStatus' — operator-typed Enter on an empty prompt should
-- answer \"what am I running and is the control surface alive?\",
-- not be a silent no-op. A @demo:KEY@ where @KEY@ trims to empty is
-- 'LscUnknown' (rejected as malformed). Internal whitespace inside
-- the key is preserved (catalog lookup will either find it or
-- return not-found; both are valid command-level rejects, not
-- parser failures).
--
-- Named commands are matched on the exact trimmed token (no
-- prefix-of-a-prefix surprises): @demos@, @controls@, @status@,
-- @help@, @?@, @quit@, and @exit@ each parse to their respective
-- constructor; an input
-- like @help me@ falls through to 'LscUnknown' because it does not
-- equal any of the recognized tokens.
--
-- Two reload syntaxes are supported, and they have intentionally
-- different whitespace semantics:
--
-- * @demo:KEY@ — the colon form. Trims outer whitespace; preserves
--   internal whitespace inside the key (so @demo:foo bar@ resolves
--   to the catalog key @\"foo bar\"@). This is the historical form.
-- * @demo KEY@ — the space form. Single-token only: @demo foo@
--   accepts; @demo foo bar@ rejects as 'LscUnknown' rather than
--   silently absorbing the trailing token. Use the colon form for
--   any key that genuinely contains internal whitespace.
data LiveSessionCommand
  = LscReloadTo !String
    -- ^ @demo:KEY@ or @demo KEY@. The key string is the trimmed
    -- payload (with the colon form's internal whitespace preserved,
    -- and the space form's single-token rule already enforced).
  | LscDemos
    -- ^ The literal @demos@. Lists manifest demo keys and marks the
    -- current serving plan.
  | LscControls
    -- ^ The literal @controls@. Reprints the current OSC control
    -- surface so the operator does not have to scroll back to the
    -- startup preamble.
  | LscValues
    -- ^ The literal @values@. Phase 8h: prints the last accepted
    -- control target values for active voices on the current plan
    -- (defaults shown for controls the session has not yet observed
    -- an accepted write for). Read-only; never reads back DSP state.
  | LscStatus
    -- ^ Empty line, whitespace-only line, or the literal @status@.
  | LscHelp
    -- ^ The literal @help@ or @?@. Prints the command vocabulary
    -- and stays in the session.
  | LscQuit
    -- ^ The literal @quit@ or @exit@. Also synthesized by the read
    -- loop on EOF (@<Ctrl-D>@) so all three terminate the session
    -- through the same code path.
  | LscUnknown !String
    -- ^ Anything else; original (untrimmed) line preserved for
    -- the help echo.
  deriving stock (Eq, Show)


-- | Parse a single line of operator input into a 'LiveSessionCommand'.
-- Pure; table-tested.
parseLiveSessionCommand :: String -> LiveSessionCommand
parseLiveSessionCommand line =
  case trimmed of
    ""       -> LscStatus
    "status" -> LscStatus
    "demos"  -> LscDemos
    "controls" -> LscControls
    "values" -> LscValues
    "help"   -> LscHelp
    "?"      -> LscHelp
    "quit"   -> LscQuit
    "exit"   -> LscQuit
    s | "demo:" `isPrefixOf` s ->
        let key = trim (drop 5 s)
        in if null key
             then LscUnknown line
             else LscReloadTo key
      | "demo " `isPrefixOf` s ->
        -- Single-token rule: split the payload on whitespace and
        -- accept only the exactly-one-token shape. Empty payload
        -- ('demo ' with nothing after) and multi-token payload
        -- ('demo foo bar') both reject as malformed so trailing
        -- tokens cannot be silently absorbed into the key.
        case words (drop 5 s) of
          [k] -> LscReloadTo k
          _   -> LscUnknown line
      | otherwise ->
        LscUnknown line
  where
    trimmed = trim line
    trim    = dropWhile isSpace . dropWhileEnd isSpace


-- | The session-shell command vocabulary as a list of ready-to-print
-- lines (each carrying its own indent). Used both by the startup
-- prompt and the @help@ command so the two surfaces are guaranteed
-- to stay in sync; also reused by the unknown-command rejection so
-- a typo prints the same vocabulary the operator would have read
-- from @help@.
--
-- The first line is the @commands:@ header (two-space indent);
-- subsequent lines are the per-command rows (four-space indent),
-- aligned by the longest left-hand token.
renderLiveSessionCommandHelp :: [String]
renderLiveSessionCommandHelp =
  [ "  commands:"
  , "    demo:KEY    supervised reload to catalog demo KEY"
  , "    demo KEY    same, single-token form (no internal whitespace)"
  , "    demos       list manifest demo keys (marks current)"
  , "    controls    print current OSC control surface"
  , "    values      print last accepted control values per active voice"
  , "    status      print current status (same as <Enter>)"
  , "    help        print commands (same as ?)"
  , "    quit        close session cleanly (same as exit, <Ctrl-D>)"
  ]


-- | Render the loaded manifest's demo keys, marking the currently
-- serving plan. Kept pure so the command's operator surface can be
-- pinned without running a live session.
renderLiveSessionDemoList :: String -> [String] -> [String]
renderLiveSessionDemoList current keys =
  "  demos:" : case keys of
    [] -> ["    (none)"]
    _  -> map renderKey keys
  where
    renderKey key
      | key == current = "    * " <> key <> " (current)"
      | otherwise      = "      " <> key


-- ============================================================================
-- Outcome state machine
-- ============================================================================

-- | What happened on the most recent reload attempt.
--
-- Distinguishes /command-level/ rejections (operator typed a key
-- that does not resolve to a catalog demo, or planning failed
-- against the loaded manifest) from /supervisor/ outcomes (the
-- four 'SupervisedReloadOutcome' variants). This matters because
-- the session must terminate on supervisor escalation but only
-- reject the command (continue serving) on a planning failure.
data LiveSessionOutcome
  = LsoCommitted
  | LsoRequestRejected
  | LsoRejectedRecovered
  | LsoEscalated
  | LsoPlanRejected !String
  deriving stock (Eq, Show)


renderLiveSessionOutcome :: LiveSessionOutcome -> String
renderLiveSessionOutcome = \case
  LsoCommitted ->
    "committed (new plan installed)"
  LsoRequestRejected ->
    "request-rejected (stack still on previous plan)"
  LsoRejectedRecovered ->
    "rejected-recovered (rebuilt from fallback)"
  LsoEscalated ->
    "escalated (no live stack)"
  LsoPlanRejected reason ->
    "plan-rejected (" <> reason <> ")"


-- | Continue the session loop, or terminate with an exit code.
-- Only 'LsoEscalated' terminates today.
data SessionStep
  = SsContinue
  | SsTerminate !ExitCode
  deriving stock (Eq, Show)


-- | Pure projection from a supervisor outcome to a
-- 'LiveSessionOutcome' + 'SessionStep'. Table-tested.
stepFromOutcome
  :: SupervisedReloadOutcome e
  -> (LiveSessionOutcome, SessionStep)
stepFromOutcome = \case
  SupervisedReloadCommitted ->
    (LsoCommitted, SsContinue)
  SupervisedReloadRequestRejected _ ->
    (LsoRequestRejected, SsContinue)
  SupervisedReloadRejectedRecovered _ ->
    (LsoRejectedRecovered, SsContinue)
  SupervisedReloadEscalated _ _ ->
    (LsoEscalated, SsTerminate (ExitFailure 1))


-- ============================================================================
-- Resource timeline
-- ============================================================================

-- | One step of the operator-facing /resource consequence/ of a
-- supervised reload attempt. 'reloadSupervised's contract pins down
-- what happens to the host stack and which plan is serving on each
-- 'SupervisedReloadOutcome' constructor:
--
--   * 'SupervisedReloadCommitted' — no close, no reopen; the
--     requested plan is serving.
--   * 'SupervisedReloadRequestRejected' — no close, no reopen; the
--     entry-time fallback plan is still serving.
--   * 'SupervisedReloadRejectedRecovered' — previous stack was
--     closed, a fresh stack opened on the fallback plan.
--   * 'SupervisedReloadEscalated' — previous stack closed, fallback
--     rebuild failed; no live stack remains.
--
-- The events here are a flat projection of that contract into lines
-- the live session can print so the operator can see /what the
-- supervisor did with the host stack/ in addition to the classified
-- outcome name. They are pure consequences derivable from the
-- outcome value; they are not new runtime telemetry from inside
-- 'realOpen' / 'realClose'.
data LiveSessionResourceEvent plan
  = LsreInWindowReloadCommitted
  | LsreRequestRejectedStackStayedLive
  | LsreNoSupervisorRebuild
  | LsreTerminalRecoveringFromFallback
  | LsreClosedPreviousStack
  | LsreOpenedFallbackStack
  | LsreFallbackRebuildFailed
  | LsreServingPlan !plan
  | LsreNoLiveStack
  deriving stock (Eq, Show)


-- | Pure projection from the entry-time fallback plan, the
-- requested plan, and the supervisor outcome to the resource
-- timeline the operator should see. The fallback plan is the one
-- already serving at reload entry (read from 'currentPlanRef' in
-- 'runReloadWith'); the requested plan is the operator's reload
-- target.
resourceTimelineForOutcome
  :: plan
  -> plan
  -> SupervisedReloadOutcome e
  -> [LiveSessionResourceEvent plan]
resourceTimelineForOutcome fallback requested = \case
  SupervisedReloadCommitted ->
    [ LsreInWindowReloadCommitted
    , LsreServingPlan requested
    ]
  SupervisedReloadRequestRejected _ ->
    [ LsreRequestRejectedStackStayedLive
    , LsreNoSupervisorRebuild
    , LsreServingPlan fallback
    ]
  SupervisedReloadRejectedRecovered _ ->
    [ LsreTerminalRecoveringFromFallback
    , LsreClosedPreviousStack
    , LsreOpenedFallbackStack
    , LsreServingPlan fallback
    ]
  SupervisedReloadEscalated _ _ ->
    [ LsreTerminalRecoveringFromFallback
    , LsreClosedPreviousStack
    , LsreFallbackRebuildFailed
    , LsreNoLiveStack
    ]


-- | Render a resource timeline as one line per event. The plan
-- label projection is operator-facing: production passes
-- 'MR.mrlpDemoKey'; tests can pass 'show' against a stub plan.
renderLiveSessionResourceEvents
  :: (plan -> String)
  -> [LiveSessionResourceEvent plan]
  -> [String]
renderLiveSessionResourceEvents planLabel = map render
  where
    render = \case
      LsreInWindowReloadCommitted ->
        "in-window reload committed"
      LsreRequestRejectedStackStayedLive ->
        "request rejected; stack stayed live"
      LsreNoSupervisorRebuild ->
        "no supervisor rebuild"
      LsreTerminalRecoveringFromFallback ->
        "terminal in-window failure; recovering from fallback"
      LsreClosedPreviousStack ->
        "closed previous stack"
      LsreOpenedFallbackStack ->
        "opened fallback stack"
      LsreFallbackRebuildFailed ->
        "fallback rebuild failed"
      LsreServingPlan plan ->
        "serving plan: " <> planLabel plan
      LsreNoLiveStack ->
        "serving plan: (no live stack)"


-- | Render the observed 'SupervisedReloadEvent' stream as one line
-- per event. Operator-facing wording: each line names the
-- supervisor stage and outcome ("started" / "committed" /
-- "rejected-live-fallback" / "terminal" / "succeeded" / "failed")
-- without embedding the carried error payload — the per-outcome
-- cause is still shown by the dedicated @cause:@ line above the
-- resource timeline, so duplicating it on every event line would
-- only add noise.
--
-- Payload-free by construction: the renderer matches on the
-- constructor and ignores carried payloads (the F-1 leak guard
-- structurally; no @show@ on @e@ values reaches the operator
-- transcript).
renderLiveSessionSupervisorEvents
  :: [SupervisedReloadEvent e]
  -> [String]
renderLiveSessionSupervisorEvents = map render
  where
    render = \case
      SreInWindowStarted              -> "in-window: started"
      SreInWindowCommitted            -> "in-window: committed"
      SreInWindowRejectedLiveFallback _ ->
                                         "in-window: rejected-live-fallback"
      SreInWindowTerminal _           -> "in-window: terminal"
      SreClosePreviousStarted         -> "close previous stack: started"
      SreClosePreviousSucceeded       -> "close previous stack: succeeded"
      SreFallbackOpenStarted          -> "fallback open: started"
      SreFallbackOpenSucceeded        -> "fallback open: succeeded"
      SreFallbackOpenFailed _         -> "fallback open: failed"


-- ============================================================================
-- Tracked-stack factory wrapper
-- ============================================================================

-- | Wrap a 'HostStackFactory' so 'hsfOpenStack' and 'hsfCloseStack'
-- additionally maintain an external 'IORef (Maybe stack)' the
-- session shell uses to address the /currently live/ stack for
-- status reads.
--
-- The supervisor adapter holds its own internal active-stack
-- 'IORef' but does not expose it; the session shell needs read
-- access to the active stack value because the initial stack
-- captured at startup is no longer authoritative after a
-- 'SupervisedReloadRejectedRecovered' (the supervisor has closed
-- it and opened a fresh one). This wrapper mirrors every open /
-- close into a caller-owned 'IORef' so status reads stay correct
-- across recovery.
--
-- The 'hsfInWindowReload' slot is intentionally NOT wrapped — the
-- supervisor only swaps the stack value on close-then-open
-- (terminal in-window outcome), never on in-window success or
-- live-fallback rejection.
--
-- Concurrency: the session shell is single-threaded (one operator,
-- serialized stdin commands). The 'finally' on close ensures the
-- IORef is cleared even if 'hsfCloseStack' throws. The window
-- between 'hsfCloseStack' completing and 'hsfOpenStack' returning
-- reads as 'Nothing' — the status renderer prints
-- @\"(no live stack)\"@ for that case rather than crashing.
withTrackedFactory
  :: HostStackFactory plan stack e
  -> IORef (Maybe stack)
  -> HostStackFactory plan stack e
withTrackedFactory f ref = f
  { hsfOpenStack  = \plan -> do
      result <- hsfOpenStack f plan
      case result of
        Right s -> do
          writeIORef ref (Just s)
          pure (Right s)
        Left e ->
          pure (Left e)
  , hsfCloseStack = \s ->
      hsfCloseStack f s `finally` writeIORef ref Nothing
  }


-- ============================================================================
-- Entry point + session loop
-- ============================================================================

-- | The session loop's stack-and-issue-specialized substrate: every
-- supervised route's stack value is structurally the same newtype,
-- so the loop reads service\/ingress off it polymorphically only
-- in the @e@ (issue) parameter.
type LiveStack =
  ReloadHostStack
    ManifestReloadIngressTarget
    ManifestOSCIngressOpsIssue
    ManifestOSCIngressHandle


type LiveEvent =
  ManifestReloadEvent (ManifestReloadHostIssue ManifestOSCIngressOpsIssue)


-- | Run a manifest-backed live session shell.
--
-- Opens audio + OSC ingress against @manifest@ + @initialDemo@
-- through the supervised lifecycle picked by @strategy@, then
-- reads operator commands on stdin until EOF / supervisor
-- escalation.
runManifestLiveSession
  :: ManifestReloadHostStrategy
  -> FilePath
  -> Demo
  -> ListenerConfig
  -> IO ()
runManifestLiveSession strategy manifestPath initialDemo listenerCfg = do
  hSetBuffering stdout LineBuffering
  doc <- readManifestDocOrDie manifestPath
  catalog <- either die pure (demoManifestReloadCatalog demoTable)
  initialPlan <- planOrDie doc catalog initialDemo
  initialTarget <- targetOrDie initialPlan

  putStrLn "Manifest live session (Phase 8 v0)."
  putStrLn ""
  putStrLn $ "  manifest path: " <> manifestPath
  putStrLn $ "  strategy:      " <> renderManifestReloadHostStrategy strategy
  putStrLn $ "  route:         " <> renderRoute strategy
  putStrLn $ "  initial demo:  " <> demoKey initialDemo
  putStrLn ""
  renderOSCControls "initial OSC surface" initialTarget
  putStrLn ""
  mapM_ putStrLn renderLiveSessionCommandHelp
  putStrLn ""
  hFlush stdout

  reloadEventsRef <- newIORef []
  trackedStackRef <- newIORef Nothing
  currentPlanRef  <- newIORef initialPlan
  lastOutcomeRef  <- newIORef Nothing
  valueCacheRef   <- newIORef emptyLiveValueCache

  -- Phase 8j: indirect operator-output sink.
  --
  -- The listener hook closure (in 'rrhsiBuildIngressOps' below)
  -- captures whichever output function is in scope at construction
  -- time, but the Haskeline 'getExternalPrint' action only exists
  -- inside 'runInputT' — and 'runInputT' has to wrap 'sessionLoop'
  -- itself (where 'getInputLine' lives). To bridge those two scopes
  -- without lifting 'withHostStackSupervisorAdapter' over 'InputT',
  -- the listener hook reads the sink from an IORef and 'runSupervised'
  -- swaps it from 'putStrLn' to Haskeline's 'extPrint' for the
  -- duration of the line-editor session.
  --
  -- Before / after the InputT bracket the sink is plain 'putStrLn',
  -- which is correct: no operator edit buffer exists at those moments.
  -- Inside the bracket the sink is Haskeline-aware and async output
  -- redraws the prompt instead of corrupting the typed-but-unsubmitted
  -- text. See @notes/2026-05-22-h-live-session-tty-line-discipline-design.md@.
  extPrintRef <- newIORef putStrLn
  let extPrintDyn s = do
        f <- readIORef extPrintRef
        f s

  -- Phase 8h: producer-neutral accepted-write observer for the
  -- live-session value cache. Wired through the OSC accepted hook
  -- here; identical updater shape would receive MIDI/UI accepted
  -- writes if a producer-neutral seam is added later.
  let recordAccepted voice tag value =
        modifyIORef' valueCacheRef (recordAcceptedWrite voice tag value)

  let inputs = RealReloadHostStackInputs
        { rrhsiBuildIngressOps     = \host ->
            manifestOSCIngressOpsWithTargetHooks
              (\target ->
                 liveOSCListenerHooksForObservedWith
                   target recordAccepted extPrintDyn)
              defaultOSCProducerOptions
              host
              listenerCfg
        , rrhsiIngressTargetPolicy = liveIngressTargetPolicy
        , rrhsiAudioFFI            = defaultSessionFanInAudioFFI
        , rrhsiAudioOptions        = liveAudioOptions
        , rrhsiOwnerOptions        = defaultSessionOwnerOptions
        , rrhsiServiceOptions      = defaultSessionFanInServiceOptions
        , rrhsiServiceHooks        = defaultSessionFanInServiceHooks
        , rrhsiOnEvent             =
            \ev -> modifyIORef' reloadEventsRef (<> [ev])
        }

  -- Per-route 'causeLabel' projections. Each renderer is
  -- structurally payload-free at every depth (see the F-1 leak
  -- guard in 'AppManifestLiveSessionRender'); replacing 'show' here
  -- would re-introduce the 13 KB 'ManifestPreservingHotSwapReport'
  -- transcript dump that the 2026-05-21-a operator pressure pass
  -- surfaced.
  case strategy of
    StoppedAudioOnly -> do
      let factory = withTrackedFactory
            (mkStoppedAudioHostStackFactory
              (realStoppedAudioHostStackOps inputs))
            trackedStackRef
      runSupervised
        renderStoppedAudioHostStackIssueTag
        factory
        doc catalog
        initialPlan initialTarget
        trackedStackRef
        currentPlanRef
        lastOutcomeRef
        reloadEventsRef
        valueCacheRef
        extPrintRef
        extPrintDyn

    TryPreservingThenStoppedAudio -> do
      let factory = withTrackedFactory
            (mkTryPreservingHostStackFactory
              (realTryPreservingHostStackOps liveReloadProducer inputs))
            trackedStackRef
      runSupervised
        renderTryPreservingHostStackIssueTag
        factory
        doc catalog
        initialPlan initialTarget
        trackedStackRef
        currentPlanRef
        lastOutcomeRef
        reloadEventsRef
        valueCacheRef
        extPrintRef
        extPrintDyn

    RequirePreserving -> do
      let factory = withTrackedFactory
            (mkPreservingHostStackFactory
              (realPreservingHostStackOps liveReloadProducer inputs))
            trackedStackRef
      runSupervised
        renderPreservingHostStackIssueTag
        factory
        doc catalog
        initialPlan initialTarget
        trackedStackRef
        currentPlanRef
        lastOutcomeRef
        reloadEventsRef
        valueCacheRef
        extPrintRef
        extPrintDyn
  where
    renderRoute s =
      "supervised (" <> renderManifestReloadHostStrategy s
        <> "; reloadSupervised + HostStackFactory)"


-- | Inner driver: open the initial stack, install the supervisor
-- adapter, run the session loop inside the adapter callback so the
-- adapter's @finally closeOps@ covers exit / async exception paths.
runSupervised
  :: (e -> String)
  -> HostStackFactory MR.ManifestReloadPlan LiveStack e
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> MR.ManifestReloadPlan
  -> ManifestReloadIngressTarget
  -> IORef (Maybe LiveStack)
  -> IORef MR.ManifestReloadPlan
  -> IORef (Maybe LiveSessionOutcome)
  -> IORef [LiveEvent]
  -> IORef LiveValueCache
  -> IORef (String -> IO ())
  -> (String -> IO ())
  -> IO ()
runSupervised
    causeLabel factory doc catalog initialPlan initialTarget
    trackedStackRef currentPlanRef lastOutcomeRef reloadEventsRef
    valueCacheRef extPrintRef extPrintDyn = do
  mask $ \restore -> do
    openResult <- restore (hsfOpenStack factory initialPlan)
    case openResult of
      Left issue ->
        die ("Live session initial open failed: " <> causeLabel issue)
      Right initialStack -> do
        let initialService = mrhcService (rhsConfig initialStack)
            initialIngress = mrhcIngressManager (rhsConfig initialStack)
        _outcome <-
          withHostStackSupervisorAdapter factory initialStack $
            \supOps -> restore $ do
              initialVoices <-
                autoStartTemplatesWith extPrintDyn "initial" initialService initialPlan
              warnIfMissingVoicesWith extPrintDyn initialService initialVoices
              printServiceSnapshotWith extPrintDyn "initial fan-in" initialService
              printIngressSnapshotWith extPrintDyn initialIngress
              printAddressableSurfaceWith extPrintDyn initialService initialTarget
              extPrintDyn ""
              hFlush stdout
              -- Phase 8j: open Haskeline for the operator command
              -- loop. The IORef swap means every operator-facing
              -- sink (including the OSC listener's accept-line
              -- printer) routes through Haskeline's 'extPrint'
              -- while this bracket is open, so async output cannot
              -- corrupt the operator's in-progress edit buffer.
              --
              -- The 'finally' restore is load-bearing: 'sessionLoop'
              -- calls 'exitWith' on quit, which throws past
              -- 'runInputT'\'s return point. Without 'finally', the
              -- IORef would still point at Haskeline's 'extPrint'
              -- during teardown / finalizers — any OSC packet that
              -- lands in that tail window would print through a
              -- torn-down terminal. The 'finally' guarantees the
              -- sink is back to 'putStrLn' before the supervisor's
              -- 'closeOps' (and any post-loop listener output) runs.
              let settings =
                    Haskeline.defaultSettings
                      { Haskeline.historyFile = Nothing }
              Haskeline.runInputT settings (do
                rawExtPrint <- Haskeline.getExternalPrint
                -- Haskeline's 'getExternalPrint'-returned action does
                -- NOT append a newline (verified empirically: it
                -- renders as "hello" then redraws the prompt on the
                -- same line). Every '*With' sink in this slice passes
                -- logical lines without '\n', matching 'putStrLn'\'s
                -- contract — so we wrap once here and propagate the
                -- newline-appending shape to both the IORef-backed
                -- listener path and the in-loop dispatch path.
                let extPrint s = rawExtPrint (s <> "\n")
                liftIO (writeIORef extPrintRef extPrint)
                sessionLoop
                  causeLabel
                  supOps
                  doc catalog
                  trackedStackRef
                  currentPlanRef
                  lastOutcomeRef
                  reloadEventsRef
                  valueCacheRef
                  extPrint)
                `finally` writeIORef extPrintRef putStrLn
        pure ()


-- | Read-parse-dispatch loop. Returns when the user hits EOF or a
-- reload outcome maps to 'SsTerminate'.
--
-- Phase 8j: input is read via Haskeline's 'getInputLine' inside an
-- already-open 'runInputT' bracket (opened by 'runManifestLiveSession').
-- The @extPrint@ action passed in is the 'getExternalPrint'-returned
-- IO function — every operator-facing line goes through it so async
-- OSC output cannot interleave with an in-progress edit buffer.
sessionLoop
  :: (e -> String)
  -> SupervisorOps MR.ManifestReloadPlan e
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> IORef (Maybe LiveStack)
  -> IORef MR.ManifestReloadPlan
  -> IORef (Maybe LiveSessionOutcome)
  -> IORef [LiveEvent]
  -> IORef LiveValueCache
  -> (String -> IO ())
  -> Haskeline.InputT IO ()
sessionLoop causeLabel supOps doc catalog trackedStackRef currentPlanRef
            lastOutcomeRef reloadEventsRef valueCacheRef extPrint = loop
  where
    prompt =
      "Type a command, or <Enter> for status, 'help' for the command list, or <Ctrl-D> to exit:\n> "

    loop = do
      mLine <- Haskeline.getInputLine prompt
      case mLine of
        Nothing -> liftIO $ do
          extPrint ""
          extPrint "  (EOF; closing session.)"
        Just line -> do
          let cmd = parseLiveSessionCommand line
          step <- liftIO (dispatch cmd)
          case step of
            SsContinue -> do
              liftIO (extPrint "")
              loop
            SsTerminate code -> liftIO $ do
              extPrint ""
              extPrint "  Terminating session."
              exitWith code

    dispatch = \case
      LscQuit ->
        pure (SsTerminate ExitSuccess)
      LscStatus -> do
        printStatusWith extPrint trackedStackRef currentPlanRef lastOutcomeRef
        pure SsContinue
      LscDemos -> do
        printDemosWith extPrint doc catalog currentPlanRef
        pure SsContinue
      LscControls -> do
        printControlsWith extPrint trackedStackRef currentPlanRef
        pure SsContinue
      LscValues -> do
        printValuesWith extPrint trackedStackRef currentPlanRef valueCacheRef
        pure SsContinue
      LscHelp -> do
        mapM_ extPrint renderLiveSessionCommandHelp
        pure SsContinue
      LscUnknown raw -> do
        extPrint ("  unknown command: " <> show raw)
        mapM_ extPrint renderLiveSessionCommandHelp
        pure SsContinue
      LscReloadTo key ->
        runReloadWithSink extPrint
          (catalogPlanResolver doc catalog)
          MR.mrlpDemoKey
          causeLabel
          onPlanChange
          supOps
          currentPlanRef
          lastOutcomeRef
          reloadEventsRef
          key

    -- | Post-reload hook called on 'SupervisedReloadCommitted' and
    -- 'SupervisedReloadRejectedRecovered'. Does two jobs:
    --
    --   * Auto-start a voice if the new stack's owner has no live
    --     voices (the existing 'autoStartIfStackIsEmpty' behavior).
    --
    --   * Reconcile the Phase 8h value cache against the new plan.
    --     For preserving reloads the cache survives; entries whose
    --     'ControlTag' no longer exists on the new target are
    --     dropped. For stopped-audio / rebuild outcomes the owner
    --     was disposed and re-opened — the previous cache entries
    --     refer to a dead graph, so reset to empty.
    onPlanChange livePlan = do
      mStack <- readIORef trackedStackRef
      case mStack of
        Nothing ->
          -- Supervisor bracket has not rewritten the tracking IORef
          -- yet; same posture as the legacy
          -- 'autoStartIfStackIsEmpty' early return.
          pure ()
        Just stack -> do
          let service = mrhcService (rhsConfig stack)
          snapshot <- readSessionFanInService service
          let voicesAlive = ssVoices (sfisOwnerState snapshot)
          if M.null voicesAlive
            then do
              -- Owner was rebuilt or auto-started fresh; cached
              -- values reference the disposed graph. Reset before
              -- auto-starting so the new voices render as
              -- @source=default@ in the next 'values' call.
              writeIORef valueCacheRef emptyLiveValueCache
              voices <-
                autoStartTemplatesWith extPrint "post-reload" service livePlan
              warnIfMissingVoicesWith extPrint service voices
            else
              -- Owner survived (preserving path). Retain accepted
              -- values whose tag still exists on the new target;
              -- drop entries for retired tags.
              case manifestReloadIngressTargetFromPlan
                     liveIngressTargetPolicy livePlan of
                Right newTarget -> do
                  let survivingTags =
                        Set.fromList
                          (map mocbControlTag (motControls (mitOSC newTarget)))
                      survivingVoices =
                        M.keysSet voicesAlive
                  modifyIORef' valueCacheRef
                    (retainSurvivingControls survivingVoices survivingTags)
                Left _ ->
                  -- Target projection failed; leave the cache
                  -- alone. The operator will see the projection
                  -- failure on the next 'controls' call.
                  pure ()

-- (The former 'autoStartIfStackIsEmpty' helper is replaced by
-- 'onPlanChange' above, which keeps the auto-start behavior and adds
-- the Phase 8h value-cache reconciliation. The two responsibilities
-- share the same stack/voice snapshot so they have to read it once
-- and branch on whether the owner survived.)


-- | Injectable plan resolver: given a parsed reload key, return
-- either a rendered rejection reason (command-level reject,
-- session keeps serving) or the requested plan. Layer-boundary
-- note: the parser owns surface syntax (the two reload forms),
-- the resolver owns key lookup — it sees only the normalized key
-- string, never the colon-vs-space spelling. Parameterized so the
-- testable IO core ('runReloadWith') does not need a real
-- 'AuthoringManifestDoc' + catalog fixture; tests construct a
-- stub resolver and a stub plan type.
newtype ReloadResolver plan = ReloadResolver
  { resolvePlan :: String -> Either String plan
  }


-- | Production plan resolver: catalog lookup against 'demoTable',
-- then 'planManifestReloadForDemo' against the loaded doc +
-- catalog. The rejection reason is the rendered CLI issue (for
-- planning failures) or a short \"no demo named …\" string (for
-- catalog misses).
catalogPlanResolver
  :: AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> ReloadResolver MR.ManifestReloadPlan
catalogPlanResolver doc catalog = ReloadResolver $ \key ->
  case find (\d -> demoKey d == key) demoTable of
    Nothing ->
      Left ("no demo named " <> show key <> " in catalog")
    Just demo ->
      case planManifestReloadForDemo doc catalog demo of
        Left issue ->
          Left (renderManifestReloadCliIssue issue)
        Right plan ->
          Right plan


-- | One supervised reload attempt driven by a parsed reload key.
-- Distinguishes planning failures (command-level reject; keep
-- serving) from supervisor outcomes. Always overwrites
-- 'lastOutcomeRef' so 'LscStatus' reads the most recent attempt.
-- Parameterized over a 'ReloadResolver' so tests can inject a stub.
--
-- @onLiveStackChanged@ fires on outcomes that may have left the
-- active stack with a freshly-opened owner and no voices:
--
--   * 'SupervisedReloadCommitted' — the owner may have been
--     replaced (stopped-audio strategy, or try-preserving falling
--     back to stopped-audio); preserving keeps voices, so the
--     hook should be a no-op for require-preserving in practice.
--     Called with the @requested@ plan, which is now the current
--     plan.
--   * 'SupervisedReloadRejectedRecovered' — the supervisor closed
--     the broken stack and rebuilt via the substrate's @realOpen@,
--     which opens service + audio + ingress but does not enqueue
--     any 'CmdVoiceOn'. Called with the @fallback@ plan, which is
--     now the current plan.
--
-- The hook is NOT called on 'SupervisedReloadRequestRejected'
-- (stack unchanged), 'SupervisedReloadEscalated' (session
-- terminates), or on a command-level 'LsoPlanRejected' (supervisor
-- not invoked). Production uses the hook to do the post-reload
-- voice auto-start; tests pass @const (pure ())@.
runReloadWith
  :: ReloadResolver plan
  -> (plan -> String)
  -> (e -> String)
  -> (plan -> IO ())
  -> SupervisorOps plan e
  -> IORef plan
  -> IORef (Maybe LiveSessionOutcome)
  -> IORef [LiveEvent]
  -> String
  -> IO SessionStep
runReloadWith =
  runReloadWithSink putStrLn


-- | Phase 8j: sink-taking variant. Every operator-facing line
-- (reload rejection, supervised outcome, reload events, supervisor
-- events, cause lines, resource timeline) routes through @output@.
-- The stderr escalation line keeps using 'hPutStrLn stderr'
-- unchanged: it is a non-operator surface and is not subject to the
-- Haskeline edit-buffer corruption mechanism the 8j lane addresses.
runReloadWithSink
  :: (String -> IO ())
  -> ReloadResolver plan
  -> (plan -> String)
  -> (e -> String)
  -> (plan -> IO ())
  -> SupervisorOps plan e
  -> IORef plan
  -> IORef (Maybe LiveSessionOutcome)
  -> IORef [LiveEvent]
  -> String
  -> IO SessionStep
runReloadWithSink output resolver planLabel causeLabel onLiveStackChanged supOps currentPlanRef lastOutcomeRef reloadEventsRef key =
  case resolvePlan resolver key of
    Left reason -> do
      output ("  reload rejected: " <> reason)
      writeIORef lastOutcomeRef (Just (LsoPlanRejected reason))
      pure SsContinue
    Right requestedPlan -> do
      fallbackPlan <- readIORef currentPlanRef
      writeIORef reloadEventsRef []
      supervisorEventsRef <- newIORef []
      out <- reloadSupervisedWithEvents
               (\ev -> modifyIORef' supervisorEventsRef (++ [ev]))
               supOps fallbackPlan requestedPlan
      events <- readIORef reloadEventsRef
      supervisorEvents <- readIORef supervisorEventsRef
      output ""
      let (lso, step) = stepFromOutcome out
      output $
        "  supervised outcome: " <> renderLiveSessionOutcome lso
      output "  reload events:"
      mapM_ output (renderLiveReloadEvents events)
      output "  supervisor events:"
      mapM_ (output . ("    - " <>))
            (renderLiveSessionSupervisorEvents supervisorEvents)
      writeIORef lastOutcomeRef (Just lso)
      when (lso == LsoCommitted) $
        writeIORef currentPlanRef requestedPlan
      case out of
        SupervisedReloadCommitted ->
          pure ()
        SupervisedReloadRequestRejected cause ->
          output ("  cause: " <> causeLabel cause)
        SupervisedReloadRejectedRecovered cause ->
          output ("  in-window cause: " <> causeLabel cause)
        SupervisedReloadEscalated inWindow rebuild -> do
          output ("  in-window cause: " <> causeLabel inWindow)
          output ("  rebuild cause:   " <> causeLabel rebuild)
          hPutStrLn stderr
            "live session escalated: no live stack remains."
      let timeline =
            resourceTimelineForOutcome fallbackPlan requestedPlan out
      output "  resource timeline:"
      mapM_ (output . ("    - " <>))
            (renderLiveSessionResourceEvents planLabel timeline)
      case out of
        SupervisedReloadCommitted ->
          onLiveStackChanged requestedPlan
        SupervisedReloadRejectedRecovered _ ->
          onLiveStackChanged fallbackPlan
        SupervisedReloadRequestRejected _ ->
          pure ()
        SupervisedReloadEscalated _ _ ->
          pure ()
      pure step


-- | Read the active stack via the tracking IORef and print the
-- snapshot the operator typed Enter for.
-- | Phase 8j sink-taking variant. Every operator-facing line routes
-- through @output@ (typically Haskeline's 'getExternalPrint' action).
printStatusWith
  :: (String -> IO ())
  -> IORef (Maybe LiveStack)
  -> IORef MR.ManifestReloadPlan
  -> IORef (Maybe LiveSessionOutcome)
  -> IO ()
printStatusWith output trackedStackRef currentPlanRef lastOutcomeRef = do
  output ""
  output "  status:"
  currentPlan <- readIORef currentPlanRef
  output $
    "    current plan demo: " <> MR.mrlpDemoKey currentPlan
  mStack <- readIORef trackedStackRef
  case mStack of
    Nothing ->
      output "    audio running:     (no live stack)"
    Just stack -> do
      let service = mrhcService (rhsConfig stack)
          ingress = mrhcIngressManager (rhsConfig stack)
      printServiceSnapshotWith output "    fan-in" service
      ingressSnapshot <- readManifestReloadIngressManager ingress
      output $
        "    ingress:           " <> renderIngressSnapshot ingressSnapshot
  mLast <- readIORef lastOutcomeRef
  case mLast of
    Nothing ->
      output "    last outcome:      (none yet)"
    Just lso ->
      output $ "    last outcome:      " <> renderLiveSessionOutcome lso


-- | Phase 8j sink-taking variant of the demos-list printer.
printDemosWith
  :: (String -> IO ())
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> IORef MR.ManifestReloadPlan
  -> IO ()
printDemosWith output doc catalog currentPlanRef = do
  currentPlan <- readIORef currentPlanRef
  mapM_ output $
    renderLiveSessionDemoList
      (MR.mrlpDemoKey currentPlan)
      [ key
      | manifest <- docDemos doc
      , let key = mfDemoKey manifest
      , any ((== key) . MR.mrcDemoKey) catalog
      ]


-- | Phase 8j sink-taking variant of the controls reprint.
printControlsWith
  :: (String -> IO ())
  -> IORef (Maybe LiveStack)
  -> IORef MR.ManifestReloadPlan
  -> IO ()
printControlsWith output trackedStackRef currentPlanRef = do
  currentPlan <- readIORef currentPlanRef
  let currentDemoKey = MR.mrlpDemoKey currentPlan
  output ""
  case manifestReloadIngressTargetFromPlan
         liveIngressTargetPolicy currentPlan of
    Left issue ->
      output $
        "  controls for " <> currentDemoKey
        <> ": unavailable: ingress projection failed: " <> show issue
    Right target -> do
      renderOSCControlsWith
        output ("controls for " <> currentDemoKey <> " (pattern)") target
      mStack <- readIORef trackedStackRef
      case mStack of
        Nothing ->
          output
            "  addressable OSC surface: (no live stack)"
        Just stack ->
          printAddressableSurfaceWith
            output (mrhcService (rhsConfig stack)) target


-- | Phase 8j sink-taking variant of the 'values' command. Defaults
-- render with @source=default@ for any control the live session has
-- not yet observed an accepted write for. Read-only; never reads
-- back DSP state.
printValuesWith
  :: (String -> IO ())
  -> IORef (Maybe LiveStack)
  -> IORef MR.ManifestReloadPlan
  -> IORef LiveValueCache
  -> IO ()
printValuesWith output trackedStackRef currentPlanRef valueCacheRef = do
  currentPlan <- readIORef currentPlanRef
  let currentDemoKey = MR.mrlpDemoKey currentPlan
  output ""
  case manifestReloadIngressTargetFromPlan
         liveIngressTargetPolicy currentPlan of
    Left issue ->
      output $
        "  values for " <> currentDemoKey
        <> ": unavailable: ingress projection failed: " <> show issue
    Right target -> do
      mStack <- readIORef trackedStackRef
      case mStack of
        Nothing ->
          output $
            "  values for " <> currentDemoKey <> ": (no live stack)"
        Just stack -> do
          snapshot <-
            readSessionFanInService (mrhcService (rhsConfig stack))
          cache <- readIORef valueCacheRef
          let voices   = M.keys (ssVoices (sfisOwnerState snapshot))
              bindings = motControls (mitOSC target)
          mapM_ output
            (renderValuesTable currentDemoKey voices bindings cache)
