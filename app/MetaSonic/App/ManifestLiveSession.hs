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
-- reloads to other catalog demos by typing @demo:KEY@.
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
--   * The stdin protocol is not a real REPL. Only three command
--     shapes ('LscReloadTo', 'LscStatus', 'LscUnknown') plus 'LscQuit'
--     on EOF. Everything else prints a one-line help string and
--     continues serving.
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

    -- * Outcome state machine (pure, table-tested)
  , LiveSessionOutcome (..)
  , renderLiveSessionOutcome
  , SessionStep (..)
  , stepFromOutcome

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
                                                 renderManifestReloadHostStrategy)
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
                                                (SupervisedReloadOutcome (..),
                                                 SupervisorOps,
                                                 reloadSupervised)
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                                (HostStackFactory (..),
                                                 withHostStackSupervisorAdapter)
import           MetaSonic.App.ManifestReloadIngress
                                                (readManifestReloadIngressManager)
import           MetaSonic.App.ManifestReloadIngressTarget
                                                (ManifestReloadIngressTarget)
import           MetaSonic.Authoring.Manifest   (AuthoringManifestDoc)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.FanIn        (defaultSessionFanInAudioFFI)
import           MetaSonic.Session.FanInService (defaultSessionFanInServiceHooks,
                                                 defaultSessionFanInServiceOptions)
import           MetaSonic.Session.OSCProducer  (defaultOSCProducerOptions)
import           MetaSonic.Session.Owner        (defaultSessionOwnerOptions)


-- ============================================================================
-- Stdin command surface
-- ============================================================================

-- | One line of operator input parsed into a session command.
--
-- The parser is intentionally tiny: it recognizes three shapes and
-- treats everything else as 'LscUnknown'. 'LscQuit' is not parsed —
-- it is emitted by the read loop when 'isEOF' returns 'True'.
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
data LiveSessionCommand
  = LscReloadTo !String
    -- ^ @demo:KEY@. The key string is the trimmed payload after
    -- the @demo:@ prefix.
  | LscStatus
    -- ^ Empty line or whitespace-only.
  | LscQuit
    -- ^ EOF on stdin. Not emitted by 'parseLiveSessionCommand';
    -- the read loop synthesizes it on 'isEOF'.
  | LscUnknown !String
    -- ^ Anything else; original (untrimmed) line preserved for
    -- the help echo.
  deriving stock (Eq, Show)


-- | Parse a single line of operator input into a 'LiveSessionCommand'.
-- Pure; table-tested.
parseLiveSessionCommand :: String -> LiveSessionCommand
parseLiveSessionCommand line =
  case trimmed of
    "" ->
      LscStatus
    s | "demo:" `isPrefixOf` s ->
        let key = trim (drop 5 s)
        in if null key
             then LscUnknown line
             else LscReloadTo key
      | otherwise ->
        LscUnknown line
  where
    trimmed = trim line
    trim    = dropWhile isSpace . dropWhileEnd isSpace


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
  putStrLn "  Stdin commands:"
  putStrLn "    demo:KEY    supervised reload to catalog demo KEY"
  putStrLn "    <Enter>     print current status"
  putStrLn "    <Ctrl-D>    exit cleanly"
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

  case strategy of
    StoppedAudioOnly -> do
      let factory = withTrackedFactory
            (mkStoppedAudioHostStackFactory
              (realStoppedAudioHostStackOps inputs))
            trackedStackRef
      runSupervised
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
  :: Show e
  => HostStackFactory MR.ManifestReloadPlan LiveStack e
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
    factory doc catalog initialPlan initialTarget
    trackedStackRef currentPlanRef lastOutcomeRef reloadEventsRef = do
  mask $ \restore -> do
    openResult <- restore (hsfOpenStack factory initialPlan)
    case openResult of
      Left issue ->
        die ("Live session initial open failed: " <> show issue)
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
  :: Show e
  => SupervisorOps MR.ManifestReloadPlan e
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> IORef (Maybe LiveStack)
  -> IORef MR.ManifestReloadPlan
  -> IORef (Maybe LiveSessionOutcome)
  -> IORef [LiveEvent]
  -> IO ()
sessionLoop supOps doc catalog trackedStackRef currentPlanRef lastOutcomeRef reloadEventsRef = do
  putStrLn "Type a command, or <Enter> for status, or <Ctrl-D> to exit:"
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
          sessionLoop supOps doc catalog trackedStackRef
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
      LscUnknown raw -> do
        putStrLn ("  unknown command: " <> show raw)
        putStrLn "  expected one of: demo:KEY  |  <Enter>  |  <Ctrl-D>"
        pure SsContinue
      LscReloadTo key ->
        runReloadWith
          (catalogPlanResolver doc catalog)
          supOps
          currentPlanRef
          lastOutcomeRef
          reloadEventsRef
          key


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
runReloadWith
  :: Show e
  => ReloadResolver plan
  -> SupervisorOps plan e
  -> IORef plan
  -> IORef (Maybe LiveSessionOutcome)
  -> IORef [LiveEvent]
  -> String
  -> IO SessionStep
runReloadWith resolver supOps currentPlanRef lastOutcomeRef reloadEventsRef key =
  case resolvePlan resolver key of
    Left reason -> do
      putStrLn ("  reload rejected: " <> reason)
      writeIORef lastOutcomeRef (Just (LsoPlanRejected reason))
      pure SsContinue
    Right requestedPlan -> do
      fallbackPlan <- readIORef currentPlanRef
      writeIORef reloadEventsRef []
      out <- reloadSupervised supOps fallbackPlan requestedPlan
      events <- readIORef reloadEventsRef
      putStrLn ""
      let (lso, step) = stepFromOutcome out
      putStrLn $
        "  supervised outcome: " <> renderLiveSessionOutcome lso
      putStrLn "  reload events:"
      mapM_ putStrLn (renderLiveReloadEvents events)
      writeIORef lastOutcomeRef (Just lso)
      when (lso == LsoCommitted) $
        writeIORef currentPlanRef requestedPlan
      case out of
        SupervisedReloadCommitted ->
          pure step
        SupervisedReloadRequestRejected cause -> do
          putStrLn ("  cause: " <> show cause)
          pure step
        SupervisedReloadRejectedRecovered cause -> do
          putStrLn ("  in-window cause: " <> show cause)
          pure step
        SupervisedReloadEscalated inWindow rebuild -> do
          putStrLn ("  in-window cause: " <> show inWindow)
          putStrLn ("  rebuild cause:   " <> show rebuild)
          hPutStrLn stderr
            "live session escalated: no live stack remains."
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
