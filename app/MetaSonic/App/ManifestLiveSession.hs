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
--   * The stdin protocol is not a real REPL. Five command shapes
--     parsed by 'parseLiveSessionCommand': 'LscReloadTo' (@demo:KEY@
--     colon form or @demo KEY@ single-token form), 'LscStatus' (empty
--     line or @status@), 'LscHelp' (@help@ \/ @?@), 'LscQuit' (@quit@
--     \/ @exit@ \/ EOF), and 'LscUnknown' for everything else. An
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
  ) where

import           Control.Exception              (finally, mask)
import           Control.Monad                  (when)
import           Data.Char                      (isSpace)
import           Data.IORef                     (IORef, modifyIORef',
                                                 newIORef, readIORef,
                                                 writeIORef)
import           Data.List                      (dropWhileEnd, find,
                                                 isPrefixOf)
import qualified Data.Map.Strict                as M
import           System.Exit                    (ExitCode (..), die,
                                                 exitWith)
import           System.IO                      (BufferMode (..), hFlush,
                                                 hPutStrLn, hSetBuffering,
                                                 isEOF, stderr, stdout)

import           MetaSonic.App.Demos            (Demo (..), demoTable,
                                                 demoManifestReloadCatalog)
import           MetaSonic.App.ManifestLiveCommon
                                                (autoStartTemplates,
                                                 liveAudioOptions,
                                                 liveIngressTargetPolicy,
                                                 liveOSCListenerHooks,
                                                 liveReloadProducer,
                                                 planOrDie,
                                                 printAddressableSurface,
                                                 printIngressSnapshot,
                                                 printServiceSnapshot,
                                                 readManifestDocOrDie,
                                                 renderIngressSnapshot,
                                                 renderLiveReloadEvents,
                                                 renderOSCControls,
                                                 targetOrDie,
                                                 warnIfMissingVoices)
import           MetaSonic.App.ManifestOSCIngressOps
                                                (ManifestOSCIngressHandle,
                                                 ManifestOSCIngressOpsIssue,
                                                 manifestOSCIngressOps)
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
                                                (ManifestReloadIngressTarget)
import           MetaSonic.Authoring.Manifest   (AuthoringManifestDoc)
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
-- 'LscQuit' is parsed (as @quit@
-- or @exit@) AND synthesized by the read loop on 'isEOF', so a
-- @<Ctrl-D>@ press and a typed @quit@ produce the same outcome.
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
-- prefix-of-a-prefix surprises): @help@, @?@, @quit@, @exit@, and
-- @status@ each parse to their respective constructor; an input
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
  , "    status      print current status (same as <Enter>)"
  , "    help        print commands (same as ?)"
  , "    quit        close session cleanly (same as exit, <Ctrl-D>)"
  ]


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

  let inputs = RealReloadHostStackInputs
        { rrhsiBuildIngressOps     = \host ->
            manifestOSCIngressOps
              liveOSCListenerHooks
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
  -> IO ()
runSupervised
    causeLabel factory doc catalog initialPlan initialTarget
    trackedStackRef currentPlanRef lastOutcomeRef reloadEventsRef = do
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
                autoStartTemplates "initial" initialService initialPlan
              warnIfMissingVoices initialService initialVoices
              printServiceSnapshot "initial fan-in" initialService
              printIngressSnapshot initialIngress
              printAddressableSurface initialService initialTarget
              putStrLn ""
              hFlush stdout
              sessionLoop
                causeLabel
                supOps
                doc catalog
                trackedStackRef
                currentPlanRef
                lastOutcomeRef
                reloadEventsRef
        pure ()


-- | Read-parse-dispatch loop. Returns when the user hits EOF or a
-- reload outcome maps to 'SsTerminate'.
sessionLoop
  :: (e -> String)
  -> SupervisorOps MR.ManifestReloadPlan e
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> IORef (Maybe LiveStack)
  -> IORef MR.ManifestReloadPlan
  -> IORef (Maybe LiveSessionOutcome)
  -> IORef [LiveEvent]
  -> IO ()
sessionLoop causeLabel supOps doc catalog trackedStackRef currentPlanRef lastOutcomeRef reloadEventsRef = do
  putStrLn "Type a command, or <Enter> for status, 'help' for the command list, or <Ctrl-D> to exit:"
  hFlush stdout
  done <- isEOF
  if done
    then do
      putStrLn ""
      putStrLn "  (EOF; closing session.)"
    else do
      line <- getLine
      let cmd = parseLiveSessionCommand line
      step <- dispatch cmd
      case step of
        SsContinue -> do
          putStrLn ""
          sessionLoop causeLabel supOps doc catalog trackedStackRef
                      currentPlanRef lastOutcomeRef reloadEventsRef
        SsTerminate code -> do
          putStrLn ""
          putStrLn "  Terminating session."
          exitWith code
  where
    dispatch = \case
      LscQuit ->
        pure (SsTerminate ExitSuccess)
      LscStatus -> do
        printStatus trackedStackRef currentPlanRef lastOutcomeRef
        pure SsContinue
      LscHelp -> do
        mapM_ putStrLn renderLiveSessionCommandHelp
        pure SsContinue
      LscUnknown raw -> do
        putStrLn ("  unknown command: " <> show raw)
        mapM_ putStrLn renderLiveSessionCommandHelp
        pure SsContinue
      LscReloadTo key ->
        runReloadWith
          (catalogPlanResolver doc catalog)
          MR.mrlpDemoKey
          causeLabel
          autoStartIfStackIsEmpty
          supOps
          currentPlanRef
          lastOutcomeRef
          reloadEventsRef
          key

    -- | Post-reload voice auto-start. Fires on
    -- 'SupervisedReloadCommitted' and
    -- 'SupervisedReloadRejectedRecovered' through 'runReloadWith's
    -- 'onLiveStackChanged' hook. Checks whether the active stack's
    -- owner has zero live voices; if so, enqueues one 'CmdVoiceOn'
    -- per template on the supplied plan (matching the two-shot demo's
    -- post-reload-auto-start pattern). For 'require-preserving' the
    -- owner is preserved across the reload so 'ssVoices' is
    -- non-empty and this is a no-op; for 'stopped-audio-only',
    -- 'try-preserving' falling back to stopped-audio, and the
    -- 'RejectedRecovered' close-then-reopen path, the substrate's
    -- 'realOpen' produces a service + audio + ingress with no
    -- voices, and the auto-start gives the operator back an
    -- audible surface.
    autoStartIfStackIsEmpty livePlan = do
      mStack <- readIORef trackedStackRef
      case mStack of
        Nothing ->
          -- Reads as @(no live stack)@ in status; the supervisor's
          -- bracket has not yet rewritten the tracking IORef. Skip
          -- auto-start rather than fight the close-then-open window.
          pure ()
        Just stack -> do
          let service = mrhcService (rhsConfig stack)
          snapshot <- readSessionFanInService service
          when (M.null (ssVoices (sfisOwnerState snapshot))) $ do
            voices <-
              autoStartTemplates "post-reload" service livePlan
            warnIfMissingVoices service voices


-- | Injectable plan resolver: given an operator-typed @demo:KEY@
-- payload, return either a rendered rejection reason
-- (command-level reject, session keeps serving) or the requested
-- plan. Parameterized so the testable IO core
-- ('runReloadWith') does not need a real
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


-- | One supervised reload attempt driven by an operator-typed key.
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
runReloadWith resolver planLabel causeLabel onLiveStackChanged supOps currentPlanRef lastOutcomeRef reloadEventsRef key =
  case resolvePlan resolver key of
    Left reason -> do
      putStrLn ("  reload rejected: " <> reason)
      writeIORef lastOutcomeRef (Just (LsoPlanRejected reason))
      pure SsContinue
    Right requestedPlan -> do
      fallbackPlan <- readIORef currentPlanRef
      writeIORef reloadEventsRef []
      -- Supervisor event stream is local to this reload — it
      -- describes the supervisor's close/open lifecycle for this
      -- one call. We allocate the ref inside the case so a stale
      -- list from a previous reload cannot leak into the next
      -- render. 'safeEmit' inside 'reloadSupervisedWithEvents'
      -- guards the supervisor's cleanup invariants against any
      -- exception this callback might throw (ffaca33).
      supervisorEventsRef <- newIORef []
      out <- reloadSupervisedWithEvents
               (\ev -> modifyIORef' supervisorEventsRef (++ [ev]))
               supOps fallbackPlan requestedPlan
      events <- readIORef reloadEventsRef
      supervisorEvents <- readIORef supervisorEventsRef
      putStrLn ""
      let (lso, step) = stepFromOutcome out
      putStrLn $
        "  supervised outcome: " <> renderLiveSessionOutcome lso
      putStrLn "  reload events:"
      mapM_ putStrLn (renderLiveReloadEvents events)
      -- Observed supervisor-layer timeline: what the supervisor
      -- actually did to the host stack around the in-window slot
      -- (in-window start/outcome + close-previous + fallback-open).
      -- The derived 'resource timeline:' block below stays as the
      -- compact "what is now true" summary; this block is the
      -- "what happened, in order" narrative read from
      -- 'reloadSupervisedWithEvents'.
      putStrLn "  supervisor events:"
      mapM_ (putStrLn . ("    - " <>))
            (renderLiveSessionSupervisorEvents supervisorEvents)
      writeIORef lastOutcomeRef (Just lso)
      when (lso == LsoCommitted) $
        writeIORef currentPlanRef requestedPlan
      -- Cause lines first so the operator sees the failure detail
      -- adjacent to the supervised outcome name. The 'causeLabel'
      -- projection is route-specific (see 'runManifestLiveSession');
      -- it must NOT call 'show' on a value that recursively carries
      -- 'TemplateGraph' / 'RuntimeNode' state, or the operator
      -- transcript reverts to the F-1 leak shape this slice fixed.
      case out of
        SupervisedReloadCommitted ->
          pure ()
        SupervisedReloadRequestRejected cause ->
          putStrLn ("  cause: " <> causeLabel cause)
        SupervisedReloadRejectedRecovered cause ->
          putStrLn ("  in-window cause: " <> causeLabel cause)
        SupervisedReloadEscalated inWindow rebuild -> do
          putStrLn ("  in-window cause: " <> causeLabel inWindow)
          putStrLn ("  rebuild cause:   " <> causeLabel rebuild)
          hPutStrLn stderr
            "live session escalated: no live stack remains."
      -- Resource timeline before 'onLiveStackChanged' so the
      -- operator reads close/open/serving-plan consequences
      -- contiguously with the outcome + cause section, ahead of
      -- any noisy "post-reload: auto-starting ..." output the
      -- hook may produce.
      let timeline =
            resourceTimelineForOutcome fallbackPlan requestedPlan out
      putStrLn "  resource timeline:"
      mapM_ (putStrLn . ("    - " <>))
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
printStatus
  :: IORef (Maybe LiveStack)
  -> IORef MR.ManifestReloadPlan
  -> IORef (Maybe LiveSessionOutcome)
  -> IO ()
printStatus trackedStackRef currentPlanRef lastOutcomeRef = do
  putStrLn ""
  putStrLn "  status:"
  currentPlan <- readIORef currentPlanRef
  putStrLn $
    "    current plan demo: " <> MR.mrlpDemoKey currentPlan
  mStack <- readIORef trackedStackRef
  case mStack of
    Nothing ->
      putStrLn "    audio running:     (no live stack)"
    Just stack -> do
      let service = mrhcService (rhsConfig stack)
          ingress = mrhcIngressManager (rhsConfig stack)
      printServiceSnapshot "    fan-in" service
      ingressSnapshot <- readManifestReloadIngressManager ingress
      putStrLn $
        "    ingress:           " <> renderIngressSnapshot ingressSnapshot
  mLast <- readIORef lastOutcomeRef
  case mLast of
    Nothing ->
      putStrLn "    last outcome:      (none yet)"
    Just lso ->
      putStrLn $ "    last outcome:      " <> renderLiveSessionOutcome lso
