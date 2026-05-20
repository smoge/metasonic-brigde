{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}

-- |
-- Module      : MetaSonic.App.ManifestLiveReloadDemo
-- Description : Experimental audible manifest reload demo.
--
-- This is the first opt-in audible consumer of the manifest reload
-- host strategy selector. It starts audio from one authored demo,
-- opens manifest-aware OSC ingress, waits for the operator to press
-- Enter, then reloads to another authored demo. The reload dispatch
-- splits on the host strategy:
--
-- * @StoppedAudioOnly@ routes through the supervised stack
--   ('reloadSupervised' + 'HostStackFactory' +
--   'realStoppedAudioHostStackOps') so a terminal in-window failure
--   triggers a rebuild from the captured fallback plan instead of
--   leaving the host without a live stack. This is the
--   @'LiveReloadSupervised' 'SfStoppedAudio'@ arm of
--   'selectLiveReloadRoute' and is driven by
--   'runSupervisedStoppedAudioLiveReload' below.
--
-- * @TryPreservingThenStoppedAudio@ routes through the supervised
--   stack with 'realTryPreservingHostStackOps' (composes preserving
--   + stopped-audio fallback under the existing
--   'preservingAllowsStoppedAudioFallback' gate). This is the
--   @'LiveReloadSupervised' 'SfTryPreserving'@ arm and is driven by
--   'runSupervisedTryPreservingLiveReload' below. A preserving
--   rejection that the gate does not admit produces a real
--   'SupervisedReloadRequestRejected' outcome — the stack stays
--   serving the fallback plan; the operator branch prints the
--   cause and prompts for cleanup without claiming a rebuild ran.
--
-- * @RequirePreserving@ routes through the supervised stack with
--   'realPreservingHostStackOps' (preserving-only — no
--   stopped-audio fallback composition). This is the
--   @'LiveReloadSupervised' 'SfRequirePreserving'@ arm and is
--   driven by 'runSupervisedRequirePreservingLiveReload' below.
--   Every 'InWindowReloadRejectedLiveFallback'-classified
--   preserving outcome (the four resume-ok variants) surfaces as
--   'SupervisedReloadRequestRejected' — no fallback is admitted,
--   the stack stays serving the previous plan. The operator
--   branch narrates the rejection cause without claiming a
--   rebuild or fallback ran.
--
-- The runtime preamble prints a @route:@ line so the operator can
-- see which path was selected. The routing decision itself is a
-- pure 'selectLiveReloadRoute :: ManifestReloadHostStrategy ->
-- LiveReloadRoute' selector, pinned by deterministic tests in
-- 'MetaSonic.Spec.AppManifestLiveReloadDemoRender' so a refactor
-- that silently shifts strategies between routes fails loudly.
--
-- The normal demo path is deliberately unchanged. This helper is for
-- integration friction: making the planner, service, audio lifecycle,
-- OSC ingress manager, and strategy selector run together under a real
-- audio stream without claiming that manifest reload is now the default
-- live path.

module MetaSonic.App.ManifestLiveReloadDemo
  ( runManifestLiveReloadDemo
  , LiveReloadRoute (..)
  , SupervisedFactoryFlavor (..)
  , selectLiveReloadRoute
  , renderLiveReloadRoute
  ) where

import           Control.Exception              (finally, mask)
import           Control.Monad                  (unless, void)
import           Data.IORef                     (modifyIORef', newIORef,
                                                 readIORef)
import qualified Data.Map.Strict                as M
import           System.Exit                    (die)
import           System.IO                      (BufferMode (..),
                                                 hFlush, hSetBuffering,
                                                 stdout)

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
                                                 requestFor,
                                                 targetOrDie,
                                                 warnIfMissingVoices)
import           MetaSonic.App.ManifestOSCIngressOps
                                                (ManifestOSCIngressOpsIssue,
                                                 manifestOSCIngressOps)
import           MetaSonic.App.ManifestOSCListener
                                                (ListenerConfig)
import           MetaSonic.App.ManifestReloadCli
                                                (renderManifestReloadHostStrategy,
                                                 renderStrategyOutcome)
import           MetaSonic.App.ManifestReloadHost
                                                (ManifestReloadHostConfig (..),
                                                 ManifestReloadHostStrategy (..),
                                                 reloadManifestHostWithStrategyWithEvents)
import           MetaSonic.App.ManifestReloadHostStack
                                                (RealReloadHostStackInputs (..),
                                                 ReloadHostStack (..),
                                                 StoppedAudioHostStackIssue,
                                                 mkStoppedAudioHostStackFactory,
                                                 realStoppedAudioHostStackOps)
import           MetaSonic.App.ManifestReloadPreservingHostStack
                                                (PreservingHostStackIssue,
                                                 mkPreservingHostStackFactory,
                                                 realPreservingHostStackOps)
import           MetaSonic.App.ManifestReloadTryPreservingHostStack
                                                (TryPreservingHostStackIssue,
                                                 mkTryPreservingHostStackFactory,
                                                 realTryPreservingHostStackOps)
import           MetaSonic.App.ManifestReloadSupervisor
                                                (SupervisedReloadOutcome (..),
                                                 reloadSupervised)
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                                (HostStackFactory (..),
                                                 withHostStackSupervisorAdapter)
import           MetaSonic.App.ManifestReloadIngress
                                                (ManifestReloadIngressOps (..),
                                                 ManifestReloadIngressSnapshot (..),
                                                 closeManifestReloadIngress,
                                                 newManifestReloadIngressManager,
                                                 readManifestReloadIngressManager)
import           MetaSonic.App.ManifestReloadIngressTarget
                                                (ManifestReloadIngressTarget (..))
import           MetaSonic.App.ManifestReloadOSCBinding
                                                (ManifestOSCIngressTarget (..),
                                                 motDemoKey)
import           MetaSonic.Authoring.Manifest   (AuthoringManifestDoc)
import           MetaSonic.Session.FanIn        (SessionFanInSnapshot (..),
                                                 SessionFanInHost,
                                                 defaultSessionFanInAudioFFI,
                                                 startSessionFanInHostAudioWith,
                                                 stopSessionFanInHostAudioWith)
import           MetaSonic.Session.FanInService (defaultSessionFanInServiceHooks,
                                                 defaultSessionFanInServiceOptions,
                                                 readSessionFanInService,
                                                 sessionFanInServiceHost,
                                                 withSessionFanInService)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.OSCProducer  (defaultOSCProducerOptions)
import           MetaSonic.Session.Owner        (defaultSessionOwnerOptions)
import           MetaSonic.Session.State        (SessionState (..))


-- | Which live-reload path drives the audible reload demo for
-- a given strategy.
--
-- All three strategies now dispatch through the supervised
-- lifecycle: 'StoppedAudioOnly' uses
-- 'realStoppedAudioHostStackOps' (landed first, hardware-confirmed
-- 2026-05-20), 'TryPreservingThenStoppedAudio' uses
-- 'realTryPreservingHostStackOps' (composed preserving +
-- stopped-audio fallback), and 'RequirePreserving' uses
-- 'realPreservingHostStackOps' (preserving-only, no fallback
-- composition). All three migrations met the evidence bar in
-- @notes/2026-05-20-a-supervised-route-tier3-decision.md@.
-- 'LiveReloadDirect' is retained as an unused arm so that any
-- future non-supervised strategy can re-enter the dispatcher
-- without reshaping the type; today no constructor maps to it.
-- Selection is pure so it can be exercised by deterministic
-- tests without staging real audio.
data LiveReloadRoute
  = LiveReloadDirect
    -- ^ Drive 'reloadManifestHostWithStrategyWithEvents'
    -- against a 'ManifestReloadHostConfig' opened by this
    -- module. Currently unused — every strategy routes through
    -- the supervised lifecycle.
  | LiveReloadSupervised !SupervisedFactoryFlavor
    -- ^ Drive 'reloadSupervised' under
    -- 'withHostStackSupervisorAdapter'. The 'SupervisedFactoryFlavor'
    -- selects which HostStackFactory carries the in-window
    -- lifecycle.
  deriving stock (Eq, Show)


-- | Which supervised factory carries the in-window lifecycle for
-- a 'LiveReloadSupervised' route.
data SupervisedFactoryFlavor
  = SfStoppedAudio
    -- ^ 'realStoppedAudioHostStackOps'. The in-window slot can
    -- only produce 'InWindowReloadCommitted' or
    -- 'InWindowReloadTerminal'.
  | SfTryPreserving
    -- ^ 'realTryPreservingHostStackOps' (composes preserving +
    -- stopped-audio fallback). The in-window slot can produce
    -- all three 'InWindowReloadOutcome' variants, so the
    -- supervisor can return 'SupervisedReloadRequestRejected'
    -- for live-stack rejections that the fallback gate declines.
  | SfRequirePreserving
    -- ^ 'realPreservingHostStackOps' (preserving-only, no
    -- stopped-audio fallback). The in-window slot can produce
    -- all three 'InWindowReloadOutcome' variants; every
    -- 'InWindowReloadRejectedLiveFallback' classification
    -- becomes 'SupervisedReloadRequestRejected' because there
    -- is no fallback gate to admit any of them.
  deriving stock (Eq, Show)


-- | Pure selector mapping each strategy to the live-reload
-- path it dispatches through.
selectLiveReloadRoute :: ManifestReloadHostStrategy -> LiveReloadRoute
selectLiveReloadRoute strategy = case strategy of
  StoppedAudioOnly              -> LiveReloadSupervised SfStoppedAudio
  TryPreservingThenStoppedAudio -> LiveReloadSupervised SfTryPreserving
  RequirePreserving             -> LiveReloadSupervised SfRequirePreserving


-- | Run an experimental audible manifest reload demo.
--
-- The command starts from @oldDemo@, then reloads to @newDemo@ when the
-- operator presses Enter. OSC ingress is bound through the supplied
-- listener config. The helper auto-starts one instance per template so
-- authored demos are audible without a separate MIDI/UI voice source.
runManifestLiveReloadDemo
  :: ManifestReloadHostStrategy
  -> FilePath
  -> Demo
  -> Demo
  -> ListenerConfig
  -> IO ()
runManifestLiveReloadDemo strategy manifestPath oldDemo newDemo listenerCfg = do
  -- Force line-buffered stdout so an operator wrapper script
  -- (e.g. tools/manifest_supervised_live_smoke.sh) sees the
  -- interactive prompts in real time. GHC's runtime defaults
  -- stdout to BlockBuffering when redirected to a file, which
  -- can hide the "press Enter" prompt inside a ~4 KB buffer
  -- and deadlock a wrapper that polls the file for that
  -- string. LineBuffering matches the interactive semantic of
  -- this command and removes the buffer-fill timing
  -- dependency.
  hSetBuffering stdout LineBuffering
  doc <- readManifestDocOrDie manifestPath
  catalog <- either die pure (demoManifestReloadCatalog demoTable)
  oldPlan <- planOrDie doc catalog oldDemo
  newPlan <- planOrDie doc catalog newDemo
  oldTarget <- targetOrDie oldPlan
  newTarget <- targetOrDie newPlan

  let route = selectLiveReloadRoute strategy

  putStrLn "Manifest live reload demo (experimental)."
  putStrLn ""
  putStrLn $ "  manifest path: " <> manifestPath
  putStrLn $ "  strategy: " <> renderManifestReloadHostStrategy strategy
  putStrLn $ "  route: " <> renderLiveReloadRoute route
  putStrLn $ "  initial demo: " <> demoKey oldDemo
  putStrLn $ "  target demo: " <> demoKey newDemo
  putStrLn "  normal demo path: unchanged"
  putStrLn "  ingress: manifest-aware OSC only"
  putStrLn ""
  renderOSCControls "initial OSC surface" oldTarget
  renderOSCControls "target OSC surface" newTarget
  putStrLn ""
  putStrLn "  This path starts real audio and runs the manifest host"
  putStrLn "  strategy selector. It is still opt-in and experimental."
  putStrLn ""
  hFlush stdout

  case route of
    LiveReloadSupervised SfStoppedAudio ->
      runSupervisedStoppedAudioLiveReload
        listenerCfg
        oldPlan newPlan
        oldTarget newTarget
        oldDemo newDemo
    LiveReloadSupervised SfTryPreserving ->
      runSupervisedTryPreservingLiveReload
        listenerCfg
        oldPlan newPlan
        oldTarget newTarget
        oldDemo newDemo
    LiveReloadSupervised SfRequirePreserving ->
      runSupervisedRequirePreservingLiveReload
        listenerCfg
        oldPlan newPlan
        oldTarget newTarget
        oldDemo newDemo
    LiveReloadDirect ->
      runDirectLiveReloadBody
        strategy
        listenerCfg
        doc catalog
        oldPlan newPlan
        oldTarget newTarget
        oldDemo newDemo


-- | Render a 'LiveReloadRoute' as the @route:@ line shown in the
-- demo preamble. The exact strings are pinned by deterministic
-- tests because operator tier-2 smoke wrappers grep on them.
renderLiveReloadRoute :: LiveReloadRoute -> String
renderLiveReloadRoute = \case
  LiveReloadDirect ->
    "direct (reloadManifestHostWithStrategy)"
  LiveReloadSupervised SfStoppedAudio ->
    "supervised (stopped-audio; reloadSupervised + HostStackFactory)"
  LiveReloadSupervised SfTryPreserving ->
    "supervised (try-preserving; reloadSupervised + HostStackFactory)"
  LiveReloadSupervised SfRequirePreserving ->
    "supervised (require-preserving; reloadSupervised + HostStackFactory)"


-- | Direct-path body extracted unchanged from the original
-- 'runManifestLiveReloadDemo' so the existing preserving and
-- try-preserving behavior is preserved verbatim.
runDirectLiveReloadBody
  :: ManifestReloadHostStrategy
  -> ListenerConfig
  -> AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> MR.ManifestReloadPlan
  -> MR.ManifestReloadPlan
  -> ManifestReloadIngressTarget
  -> ManifestReloadIngressTarget
  -> Demo
  -> Demo
  -> IO ()
runDirectLiveReloadBody strategy listenerCfg doc catalog
    oldPlan newPlan oldTarget newTarget _oldDemo newDemo = do

  result <-
    withSessionFanInService
      (MR.mrlpTemplateGraph oldPlan)
      defaultSessionFanInServiceOptions
      $ \service -> runWithService
          doc catalog oldPlan newPlan oldTarget newTarget service
  case result of
    Left issue ->
      die ("Manifest live reload demo setup failed: " <> show issue)
    Right () ->
      pure ()
  where
    runWithService doc catalog oldPlan newPlan oldTarget newTarget service = do
      let host = sessionFanInServiceHost service
          listenerHooks =
            liveOSCListenerHooks
          ops =
            manifestOSCIngressOps
              listenerHooks
              defaultOSCProducerOptions
              host
              listenerCfg
      opened <- mrioOpenIngress ops oldTarget
      case opened of
        Left issue ->
          die ("Initial OSC ingress open failed: " <> show issue)
        Right initialHandle -> do
          ingressManager <-
            newManifestReloadIngressManager ops oldTarget initialHandle
          let cleanup = do
                void (closeManifestReloadIngress ingressManager)
                void (stopSessionFanInHostAudioWith
                        defaultSessionFanInAudioFFI
                        host)
          (do
             startAudioOrDie host
             initialVoices <- autoStartTemplates "initial" service oldPlan
             warnIfMissingVoices service initialVoices
             printServiceSnapshot "initial fan-in" service
             printIngressSnapshot ingressManager
             printAddressableSurface service oldTarget
             putStrLn ""
             putStrLn "  Audio is running. Send OSC to the initial surface,"
             putStrLn "  then press Enter to reload."
             void getLine

             reloadEvents <- newIORef []
             let config = ManifestReloadHostConfig
                   { mrhcService =
                       service
                   , mrhcIngressManager =
                       ingressManager
                   , mrhcOldIngressTarget =
                       oldTarget
                   , mrhcNewIngressTarget =
                       newTarget
                   , mrhcAudioFFI =
                       defaultSessionFanInAudioFFI
                   , mrhcAudioOptions =
                       liveAudioOptions
                   , mrhcOwnerOptions =
                       defaultSessionOwnerOptions
                   , mrhcOnEvent =
                       \ev ->
                         modifyIORef' reloadEvents (<> [ev])
                   }
             outcome <-
               reloadManifestHostWithStrategyWithEvents
                 liveReloadProducer
                 strategy
                 config
                 doc
                 catalog
                 (requestFor newDemo)
             capturedEvents <- readIORef reloadEvents
             putStrLn ""
             putStrLn $ "  strategy outcome: " <> renderStrategyOutcome outcome
             putStrLn "  reload events:"
             mapM_ putStrLn (renderLiveReloadEvents capturedEvents)
             afterReload <- readSessionFanInService service
             postReloadVoices <- case outcome of
               Right _
                 | M.null (ssVoices (sfisOwnerState afterReload)) ->
                     autoStartTemplates "post-reload" service newPlan
               _ ->
                 pure []
             warnIfMissingVoices service postReloadVoices
             printServiceSnapshot "post-reload fan-in" service
             -- The strategy's failure paths can leave ingress in
             -- different states (closed, resumed on the old target, or
             -- open on the new target) so the snapshot is the source
             -- of truth for what the operator can actually address —
             -- the strategy 'outcome' alone is not enough.
             ingressSnapshot <-
               readManifestReloadIngressManager ingressManager
             putStrLn $
               "  OSC ingress: " <> renderIngressSnapshot ingressSnapshot
             case ingressSnapshot of
               MrisOpen liveTarget _ -> do
                 printAddressableSurface service liveTarget
                 putStrLn ""
                 putStrLn $
                   "  Send OSC to the surface for demo="
                   <> motDemoKey (mitOSC liveTarget)
                   <> ", then press Enter"
                 putStrLn "  to stop audio and close ingress."
               MrisClosed -> do
                 putStrLn
                   "  addressable OSC surface: (none — ingress is closed)"
                 putStrLn ""
                 putStrLn
                   "  Ingress is closed; OSC packets cannot be routed."
                 putStrLn "  Press Enter to stop audio."
             void getLine)
            `finally` cleanup


-- | Supervised live-reload body for 'StoppedAudioOnly'. Mirrors
-- the direct-path body's interactive shape (preamble auto-start,
-- snapshot prints, Enter prompts, post-reload snapshot prints,
-- cleanup) but uses the production
-- 'realStoppedAudioHostStackOps' + factory + adapter +
-- 'reloadSupervised' lifecycle instead of opening the
-- 'SessionFanInService' / ingress manager / audio FFI by hand.
--
-- Exception-safety: an outer 'mask' covers the gap between
-- 'hsfOpenStack' returning @Right initialStack@ and
-- 'withHostStackSupervisorAdapter' installing its bracket. The
-- outer 'restore' is threaded inside the adapter callback so the
-- interactive blocking calls ('getLine', 'reloadSupervised')
-- run interruptible while still being covered by the adapter's
-- @finally closeOps@ — a throw at any point closes the active
-- stack before propagating.
--
-- Snapshot reads after 'reloadSupervised' returns are only safe
-- on 'SupervisedReloadCommitted' (the same 'initialStack' value
-- now runs the new plan). On 'SupervisedReloadRejectedRecovered'
-- the original 'initialStack' has been closed by the supervisor's
-- rebuild and post-reload snapshot reads against the closed
-- stack would race against the just-released owner; the
-- supervised body therefore branches and prints the outcome
-- diagnostics for the non-committed cases instead of attempting
-- to address them as if they were live.
--
-- The 'ManifestReloadIngressTarget' parameters mirror the
-- direct path's signature so the dispatcher in
-- 'runManifestLiveReloadDemo' can call either route with the
-- same arguments. Only @oldTarget@ is consulted directly here
-- (for the pre-reload addressable-surface print); @newTarget@
-- is re-projected fresh inside 'realStoppedAudioInWindowReload'
-- from @newPlan@ at the reload boundary, so the parameter is
-- intentionally unused. Likewise @_newDemo@ is unused — the
-- request payload is synthesized from @newPlan@ inside the
-- helper.
runSupervisedStoppedAudioLiveReload
  :: ListenerConfig
  -> MR.ManifestReloadPlan
  -> MR.ManifestReloadPlan
  -> ManifestReloadIngressTarget
  -> ManifestReloadIngressTarget
  -> Demo
  -> Demo
  -> IO ()
runSupervisedStoppedAudioLiveReload listenerCfg oldPlan newPlan oldTarget _newTarget
    _oldDemo _newDemo = do
  reloadEvents <- newIORef []
  let buildIngressOps host =
        manifestOSCIngressOps
          liveOSCListenerHooks
          defaultOSCProducerOptions
          host
          listenerCfg
      inputs = RealReloadHostStackInputs
        { rrhsiBuildIngressOps     = buildIngressOps
        , rrhsiIngressTargetPolicy = liveIngressTargetPolicy
        , rrhsiAudioFFI            = defaultSessionFanInAudioFFI
        , rrhsiAudioOptions        = liveAudioOptions
        , rrhsiOwnerOptions        = defaultSessionOwnerOptions
        , rrhsiServiceOptions      = defaultSessionFanInServiceOptions
        , rrhsiServiceHooks        = defaultSessionFanInServiceHooks
        , rrhsiOnEvent             =
            \ev -> modifyIORef' reloadEvents (<> [ev])
        }
      ops     = realStoppedAudioHostStackOps inputs
      factory = mkStoppedAudioHostStackFactory ops
  mask $ \restore -> do
    openResult <- restore (hsfOpenStack factory oldPlan)
    case openResult of
      Left issue ->
        die
          ("Supervised initial open failed: "
            <> renderSupervisedIssue issue)
      Right initialStack -> do
        let initialService = mrhcService (rhsConfig initialStack)
            initialIngressManager =
              mrhcIngressManager (rhsConfig initialStack)
        _outcome <-
          withHostStackSupervisorAdapter factory initialStack $
            \supOps -> restore $ do
              initialVoices <-
                autoStartTemplates "initial" initialService oldPlan
              warnIfMissingVoices initialService initialVoices
              printServiceSnapshot "initial fan-in" initialService
              printIngressSnapshot initialIngressManager
              printAddressableSurface initialService oldTarget
              putStrLn ""
              putStrLn "  Audio is running. Send OSC to the initial surface,"
              putStrLn "  then press Enter to run the supervised reload."
              void getLine
              out <- reloadSupervised supOps oldPlan newPlan
              capturedEvents <- readIORef reloadEvents
              putStrLn ""
              putStrLn $
                "  supervised outcome: " <> renderSupervisedOutcomeShort out
              putStrLn "  reload events:"
              mapM_ putStrLn (renderLiveReloadEvents capturedEvents)
              case out of
                SupervisedReloadCommitted -> do
                  -- The same 'initialStack' now runs the new plan;
                  -- snapshots off it are still valid.
                  afterReload <-
                    readSessionFanInService initialService
                  postReloadVoices <-
                    if M.null (ssVoices (sfisOwnerState afterReload))
                      then autoStartTemplates
                             "post-reload"
                             initialService
                             newPlan
                      else pure []
                  warnIfMissingVoices initialService postReloadVoices
                  printServiceSnapshot
                    "post-reload fan-in"
                    initialService
                  ingressSnapshot <-
                    readManifestReloadIngressManager initialIngressManager
                  putStrLn $
                    "  OSC ingress: "
                      <> renderIngressSnapshot ingressSnapshot
                  case ingressSnapshot of
                    MrisOpen liveTarget _ -> do
                      printAddressableSurface initialService liveTarget
                      putStrLn ""
                      putStrLn $
                        "  Send OSC to the surface for demo="
                          <> motDemoKey (mitOSC liveTarget)
                          <> ", then press Enter"
                      putStrLn
                        "  to stop audio and close ingress."
                    MrisClosed -> do
                      putStrLn
                        "  addressable OSC surface: \
                        \(none — ingress is closed)"
                      putStrLn
                        "  Ingress is closed; press Enter to stop \
                        \audio."
                  void getLine
                SupervisedReloadRequestRejected _cause ->
                  -- Unreachable for the stopped-audio supervised
                  -- route: 'realStoppedAudioInWindowReload' cannot
                  -- produce 'InWindowReloadRejectedLiveFallback'.
                  -- The preserving migration will lift this route
                  -- selector to a path that *can* produce the
                  -- variant; at that point this branch needs a
                  -- real "the request was rejected, stack still on
                  -- fallback plan" operator narrative.
                  error
                    "ManifestLiveReloadDemo: supervised stopped-audio \
                    \route produced SupervisedReloadRequestRejected — \
                    \contract violation."
                SupervisedReloadRejectedRecovered cause -> do
                  putStrLn ""
                  putStrLn
                    "  The supervised reload failed in-window and was \
                    \rebuilt"
                  putStrLn
                    "  from the fallback plan. The host is running the \
                    \previous"
                  putStrLn "  plan again. In-window cause:"
                  putStrLn ("    " <> renderSupervisedIssue cause)
                  putStrLn ""
                  putStrLn "  Press Enter to stop audio and exit."
                  void getLine
                SupervisedReloadEscalated inWindow rebuild -> do
                  putStrLn ""
                  putStrLn
                    "  The supervised reload escalated: both the \
                    \in-window"
                  putStrLn
                    "  reload AND the rebuild from the fallback failed."
                  putStrLn "  In-window cause:"
                  putStrLn ("    " <> renderSupervisedIssue inWindow)
                  putStrLn "  Rebuild cause:"
                  putStrLn ("    " <> renderSupervisedIssue rebuild)
                  putStrLn ""
                  putStrLn
                    "  No live stack remains; press Enter to exit."
                  void getLine
        -- '_outcome' is intentionally not destructured beyond
        -- what the interactive body already printed; the
        -- bracket's finalizer is what closes the active stack
        -- on exit.
        pure ()
  where
    renderSupervisedOutcomeShort = \case
      SupervisedReloadCommitted ->
        "committed (new plan installed)"
      SupervisedReloadRequestRejected _ ->
        "request-rejected (stack still on fallback plan)"
      SupervisedReloadRejectedRecovered _ ->
        "rejected-recovered (rebuilt from fallback)"
      SupervisedReloadEscalated _ _ ->
        "escalated (no live stack)"

    renderSupervisedIssue
      :: StoppedAudioHostStackIssue ManifestOSCIngressOpsIssue
      -> String
    renderSupervisedIssue =
      -- Compact one-line tag. Mirrors what the CLI smoke uses
      -- in 'renderSupervisedHostStackIssue' but kept local to
      -- avoid pulling rendering helpers across module
      -- boundaries.
      show


-- | Supervised live-reload body for 'TryPreservingThenStoppedAudio'.
-- Mirrors 'runSupervisedStoppedAudioLiveReload' but wires
-- 'realTryPreservingHostStackOps' + 'mkTryPreservingHostStackFactory',
-- which compose 'realPreservingInWindowReload' with
-- 'realStoppedAudioInWindowReload' under the
-- 'preservingAllowsStoppedAudioFallback' gate. The supervisor sees
-- a single classified in-window slot; the gate decision and the
-- fallback composition happen inside the slot.
--
-- 'SupervisedReloadRequestRejected' is a real reachable outcome
-- here (unlike the stopped-audio route): when preserving rejects
-- with a live-stack cause that is not fallback-eligible, the
-- stack stays on the fallback plan and the supervisor returns
-- request-rejected. The operator branch below prints that
-- explicitly so the timeline reads correctly.
runSupervisedTryPreservingLiveReload
  :: ListenerConfig
  -> MR.ManifestReloadPlan
  -> MR.ManifestReloadPlan
  -> ManifestReloadIngressTarget
  -> ManifestReloadIngressTarget
  -> Demo
  -> Demo
  -> IO ()
runSupervisedTryPreservingLiveReload listenerCfg oldPlan newPlan oldTarget _newTarget
    _oldDemo _newDemo = do
  reloadEvents <- newIORef []
  let buildIngressOps host =
        manifestOSCIngressOps
          liveOSCListenerHooks
          defaultOSCProducerOptions
          host
          listenerCfg
      inputs = RealReloadHostStackInputs
        { rrhsiBuildIngressOps     = buildIngressOps
        , rrhsiIngressTargetPolicy = liveIngressTargetPolicy
        , rrhsiAudioFFI            = defaultSessionFanInAudioFFI
        , rrhsiAudioOptions        = liveAudioOptions
        , rrhsiOwnerOptions        = defaultSessionOwnerOptions
        , rrhsiServiceOptions      = defaultSessionFanInServiceOptions
        , rrhsiServiceHooks        = defaultSessionFanInServiceHooks
        , rrhsiOnEvent             =
            \ev -> modifyIORef' reloadEvents (<> [ev])
        }
      -- Reuse the same producer identity the direct path passes
      -- to 'reloadManifestHostWithStrategyWithEvents' so the
      -- preserving hot-swap's enqueue is admitted under the same
      -- producer-kind regardless of which route is selected.
      -- Today plans use 'FifoOnly' so this is mostly diagnostic,
      -- but it matters once manifest arbitration grows beyond
      -- FIFO; a route-flip should not silently change which
      -- producer enqueued the hot-swap command.
      ops     = realTryPreservingHostStackOps liveReloadProducer inputs
      factory = mkTryPreservingHostStackFactory ops
  mask $ \restore -> do
    openResult <- restore (hsfOpenStack factory oldPlan)
    case openResult of
      Left issue ->
        die
          ("Supervised initial open failed: "
            <> renderSupervisedIssue issue)
      Right initialStack -> do
        let initialService = mrhcService (rhsConfig initialStack)
            initialIngressManager =
              mrhcIngressManager (rhsConfig initialStack)
        _outcome <-
          withHostStackSupervisorAdapter factory initialStack $
            \supOps -> restore $ do
              initialVoices <-
                autoStartTemplates "initial" initialService oldPlan
              warnIfMissingVoices initialService initialVoices
              printServiceSnapshot "initial fan-in" initialService
              printIngressSnapshot initialIngressManager
              printAddressableSurface initialService oldTarget
              putStrLn ""
              putStrLn "  Audio is running. Send OSC to the initial surface,"
              putStrLn "  then press Enter to run the supervised reload."
              void getLine
              out <- reloadSupervised supOps oldPlan newPlan
              capturedEvents <- readIORef reloadEvents
              putStrLn ""
              putStrLn $
                "  supervised outcome: " <> renderSupervisedOutcomeShort out
              putStrLn "  reload events:"
              mapM_ putStrLn (renderLiveReloadEvents capturedEvents)
              case out of
                SupervisedReloadCommitted -> do
                  -- Same stack value, new plan running. Snapshot
                  -- reads off the original stack are safe whether
                  -- the commit came from preserving or from the
                  -- stopped-audio fallback path (both leave the
                  -- stack live).
                  afterReload <-
                    readSessionFanInService initialService
                  postReloadVoices <-
                    if M.null (ssVoices (sfisOwnerState afterReload))
                      then autoStartTemplates
                             "post-reload"
                             initialService
                             newPlan
                      else pure []
                  warnIfMissingVoices initialService postReloadVoices
                  printServiceSnapshot
                    "post-reload fan-in"
                    initialService
                  ingressSnapshot <-
                    readManifestReloadIngressManager initialIngressManager
                  putStrLn $
                    "  OSC ingress: "
                      <> renderIngressSnapshot ingressSnapshot
                  case ingressSnapshot of
                    MrisOpen liveTarget _ -> do
                      printAddressableSurface initialService liveTarget
                      putStrLn ""
                      putStrLn $
                        "  Send OSC to the surface for demo="
                          <> motDemoKey (mitOSC liveTarget)
                          <> ", then press Enter"
                      putStrLn
                        "  to stop audio and close ingress."
                    MrisClosed -> do
                      putStrLn
                        "  addressable OSC surface: \
                        \(none — ingress is closed)"
                      putStrLn
                        "  Ingress is closed; press Enter to stop \
                        \audio."
                  void getLine
                SupervisedReloadRequestRejected cause -> do
                  -- Preserving rejected the request with a cause
                  -- that 'preservingAllowsStoppedAudioFallback'
                  -- declined (PlanRejected, QuiesceRejected, or
                  -- DrainRejected after a successful resume). The
                  -- stack is still serving the fallback plan;
                  -- snapshots off 'initialService' are safe but
                  -- the new plan never installed.
                  afterReject <-
                    readSessionFanInService initialService
                  putStrLn ""
                  putStrLn
                    "  The supervised reload was rejected without \
                    \mutating"
                  putStrLn
                    "  the live stack. The host is still running the \
                    \previous"
                  putStrLn "  plan. Cause:"
                  putStrLn ("    " <> renderSupervisedIssue cause)
                  printServiceSnapshot
                    "post-reject fan-in"
                    initialService
                  ingressSnapshot <-
                    readManifestReloadIngressManager initialIngressManager
                  putStrLn $
                    "  OSC ingress: "
                      <> renderIngressSnapshot ingressSnapshot
                  -- ssVoices read is best-effort for parity with
                  -- the committed branch; we do not auto-restart
                  -- because the old owner was never replaced.
                  unless (M.null (ssVoices (sfisOwnerState afterReject)))
                    (pure ())
                  putStrLn ""
                  putStrLn
                    "  Press Enter to stop audio and exit."
                  void getLine
                SupervisedReloadRejectedRecovered cause -> do
                  putStrLn ""
                  putStrLn
                    "  The supervised reload failed in-window and was \
                    \rebuilt"
                  putStrLn
                    "  from the fallback plan. The host is running the \
                    \previous"
                  putStrLn "  plan again. In-window cause:"
                  putStrLn ("    " <> renderSupervisedIssue cause)
                  putStrLn ""
                  putStrLn "  Press Enter to stop audio and exit."
                  void getLine
                SupervisedReloadEscalated inWindow rebuild -> do
                  putStrLn ""
                  putStrLn
                    "  The supervised reload escalated: both the \
                    \in-window"
                  putStrLn
                    "  reload AND the rebuild from the fallback failed."
                  putStrLn "  In-window cause:"
                  putStrLn ("    " <> renderSupervisedIssue inWindow)
                  putStrLn "  Rebuild cause:"
                  putStrLn ("    " <> renderSupervisedIssue rebuild)
                  putStrLn ""
                  putStrLn
                    "  No live stack remains; press Enter to exit."
                  void getLine
        pure ()
  where
    renderSupervisedOutcomeShort = \case
      SupervisedReloadCommitted ->
        "committed (new plan installed)"
      SupervisedReloadRequestRejected _ ->
        "request-rejected (stack still on fallback plan)"
      SupervisedReloadRejectedRecovered _ ->
        "rejected-recovered (rebuilt from fallback)"
      SupervisedReloadEscalated _ _ ->
        "escalated (no live stack)"

    renderSupervisedIssue
      :: TryPreservingHostStackIssue ManifestOSCIngressOpsIssue
      -> String
    renderSupervisedIssue = show


-- | Supervised live-reload body for 'RequirePreserving'. Mirrors
-- 'runSupervisedTryPreservingLiveReload' but wires
-- 'realPreservingHostStackOps' + 'mkPreservingHostStackFactory'
-- (preserving-only; no stopped-audio fallback composition).
--
-- 'SupervisedReloadRequestRejected' is the canonical operator
-- outcome on a rejected preserving reload here: every preserving
-- failure that 'classifyPreservingOutcome' classifies as
-- 'InWindowReloadRejectedLiveFallback' (the four resume-ok
-- variants: PlanRejected, QuiesceRejected, DrainRejected,
-- ReloadRejected) surfaces as request-rejected because there is
-- no fallback gate to admit any of them. The terminal preserving
-- variants (ResumeFailed, DrainFailedTerminal,
-- ReloadFailedTerminal, IngressRestartFailed) still drive the
-- supervisor's close-then-rebuild path through
-- 'SupervisedReloadRejectedRecovered' /
-- 'SupervisedReloadEscalated'.
--
-- The shape of the operator narration matches the try-preserving
-- body's: snapshot reads off the original stack are safe on
-- commit and on request-rejected (stack still live on the
-- previous plan); the rejected-recovered / escalated branches
-- describe the supervisor's rebuild path the same way.
runSupervisedRequirePreservingLiveReload
  :: ListenerConfig
  -> MR.ManifestReloadPlan
  -> MR.ManifestReloadPlan
  -> ManifestReloadIngressTarget
  -> ManifestReloadIngressTarget
  -> Demo
  -> Demo
  -> IO ()
runSupervisedRequirePreservingLiveReload listenerCfg oldPlan newPlan oldTarget _newTarget
    _oldDemo _newDemo = do
  reloadEvents <- newIORef []
  let buildIngressOps host =
        manifestOSCIngressOps
          liveOSCListenerHooks
          defaultOSCProducerOptions
          host
          listenerCfg
      inputs = RealReloadHostStackInputs
        { rrhsiBuildIngressOps     = buildIngressOps
        , rrhsiIngressTargetPolicy = liveIngressTargetPolicy
        , rrhsiAudioFFI            = defaultSessionFanInAudioFFI
        , rrhsiAudioOptions        = liveAudioOptions
        , rrhsiOwnerOptions        = defaultSessionOwnerOptions
        , rrhsiServiceOptions      = defaultSessionFanInServiceOptions
        , rrhsiServiceHooks        = defaultSessionFanInServiceHooks
        , rrhsiOnEvent             =
            \ev -> modifyIORef' reloadEvents (<> [ev])
        }
      -- Same producer identity as the direct path's
      -- 'reloadManifestHostWithStrategyWithEvents' call so the
      -- preserving hot-swap's enqueue is admitted under the same
      -- producer-kind regardless of which route is selected.
      ops     = realPreservingHostStackOps liveReloadProducer inputs
      factory = mkPreservingHostStackFactory ops
  mask $ \restore -> do
    openResult <- restore (hsfOpenStack factory oldPlan)
    case openResult of
      Left issue ->
        die
          ("Supervised initial open failed: "
            <> renderSupervisedIssue issue)
      Right initialStack -> do
        let initialService = mrhcService (rhsConfig initialStack)
            initialIngressManager =
              mrhcIngressManager (rhsConfig initialStack)
        _outcome <-
          withHostStackSupervisorAdapter factory initialStack $
            \supOps -> restore $ do
              initialVoices <-
                autoStartTemplates "initial" initialService oldPlan
              warnIfMissingVoices initialService initialVoices
              printServiceSnapshot "initial fan-in" initialService
              printIngressSnapshot initialIngressManager
              printAddressableSurface initialService oldTarget
              putStrLn ""
              putStrLn "  Audio is running. Send OSC to the initial surface,"
              putStrLn "  then press Enter to run the supervised reload."
              void getLine
              out <- reloadSupervised supOps oldPlan newPlan
              capturedEvents <- readIORef reloadEvents
              putStrLn ""
              putStrLn $
                "  supervised outcome: " <> renderSupervisedOutcomeShort out
              putStrLn "  reload events:"
              mapM_ putStrLn (renderLiveReloadEvents capturedEvents)
              case out of
                SupervisedReloadCommitted -> do
                  afterReload <-
                    readSessionFanInService initialService
                  postReloadVoices <-
                    if M.null (ssVoices (sfisOwnerState afterReload))
                      then autoStartTemplates
                             "post-reload"
                             initialService
                             newPlan
                      else pure []
                  warnIfMissingVoices initialService postReloadVoices
                  printServiceSnapshot
                    "post-reload fan-in"
                    initialService
                  ingressSnapshot <-
                    readManifestReloadIngressManager initialIngressManager
                  putStrLn $
                    "  OSC ingress: "
                      <> renderIngressSnapshot ingressSnapshot
                  case ingressSnapshot of
                    MrisOpen liveTarget _ -> do
                      printAddressableSurface initialService liveTarget
                      putStrLn ""
                      putStrLn $
                        "  Send OSC to the surface for demo="
                          <> motDemoKey (mitOSC liveTarget)
                          <> ", then press Enter"
                      putStrLn
                        "  to stop audio and close ingress."
                    MrisClosed -> do
                      putStrLn
                        "  addressable OSC surface: \
                        \(none — ingress is closed)"
                      putStrLn
                        "  Ingress is closed; press Enter to stop \
                        \audio."
                  void getLine
                SupervisedReloadRequestRejected cause -> do
                  -- Preserving rejected the request with a
                  -- live-stack-survivor cause. There is no
                  -- fallback gate for require-preserving, so the
                  -- supervisor returns request-rejected for every
                  -- resume-ok preserving variant. The stack is
                  -- still serving the previous plan; snapshot reads
                  -- are safe.
                  afterReject <-
                    readSessionFanInService initialService
                  putStrLn ""
                  putStrLn
                    "  The supervised reload was rejected without \
                    \mutating"
                  putStrLn
                    "  the live stack. The host is still running the \
                    \previous"
                  putStrLn "  plan. Cause:"
                  putStrLn ("    " <> renderSupervisedIssue cause)
                  printServiceSnapshot
                    "post-reject fan-in"
                    initialService
                  ingressSnapshot <-
                    readManifestReloadIngressManager initialIngressManager
                  putStrLn $
                    "  OSC ingress: "
                      <> renderIngressSnapshot ingressSnapshot
                  unless (M.null (ssVoices (sfisOwnerState afterReject)))
                    (pure ())
                  putStrLn ""
                  putStrLn
                    "  Press Enter to stop audio and exit."
                  void getLine
                SupervisedReloadRejectedRecovered cause -> do
                  putStrLn ""
                  putStrLn
                    "  The supervised reload failed in-window and was \
                    \rebuilt"
                  putStrLn
                    "  from the fallback plan. The host is running the \
                    \previous"
                  putStrLn "  plan again. In-window cause:"
                  putStrLn ("    " <> renderSupervisedIssue cause)
                  putStrLn ""
                  putStrLn "  Press Enter to stop audio and exit."
                  void getLine
                SupervisedReloadEscalated inWindow rebuild -> do
                  putStrLn ""
                  putStrLn
                    "  The supervised reload escalated: both the \
                    \in-window"
                  putStrLn
                    "  reload AND the rebuild from the fallback failed."
                  putStrLn "  In-window cause:"
                  putStrLn ("    " <> renderSupervisedIssue inWindow)
                  putStrLn "  Rebuild cause:"
                  putStrLn ("    " <> renderSupervisedIssue rebuild)
                  putStrLn ""
                  putStrLn
                    "  No live stack remains; press Enter to exit."
                  void getLine
        pure ()
  where
    renderSupervisedOutcomeShort = \case
      SupervisedReloadCommitted ->
        "committed (new plan installed)"
      SupervisedReloadRequestRejected _ ->
        "request-rejected (stack still on previous plan)"
      SupervisedReloadRejectedRecovered _ ->
        "rejected-recovered (rebuilt from fallback)"
      SupervisedReloadEscalated _ _ ->
        "escalated (no live stack)"

    renderSupervisedIssue
      :: PreservingHostStackIssue ManifestOSCIngressOpsIssue
      -> String
    renderSupervisedIssue = show


startAudioOrDie
  :: SessionFanInHost
  -> IO ()
startAudioOrDie host = do
  started <-
    startSessionFanInHostAudioWith
      defaultSessionFanInAudioFFI
      host
      liveAudioOptions
  case started of
    Left issue ->
      die ("Manifest live reload audio start failed: " <> show issue)
    Right () ->
      pure ()

-- trigger recompile
-- t
-- t
-- t
