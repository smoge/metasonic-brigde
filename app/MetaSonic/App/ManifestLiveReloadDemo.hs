{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}

-- |
-- Module      : MetaSonic.App.ManifestLiveReloadDemo
-- Description : Experimental audible manifest reload demo.
--
-- This is the first opt-in audible consumer of the manifest reload
-- host strategy selector. It starts audio from one authored demo,
-- opens manifest-aware OSC ingress, waits for the operator to press
-- Enter, then reloads to another authored demo through
-- 'reloadManifestHostWithStrategy'.
--
-- The normal demo path is deliberately unchanged. This helper is for
-- integration friction: making the planner, service, audio lifecycle,
-- OSC ingress manager, and strategy selector run together under a real
-- audio stream without claiming that manifest reload is now the default
-- live path.

module MetaSonic.App.ManifestLiveReloadDemo
  ( runManifestLiveReloadDemo
  , LiveReloadRoute (..)
  , selectLiveReloadRoute
  ) where

import           Control.Concurrent             (threadDelay)
import           Control.Exception              (finally, mask)
import           Control.Monad                  (forM, forM_, unless, void)
import           Data.IORef                     (modifyIORef', newIORef,
                                                 readIORef)
import qualified Data.Map.Strict                as M
import qualified Data.Set                       as S
import qualified Data.Text                      as T
import           System.Exit                    (die)
import           System.IO                      (hFlush, stdout)
import           System.Timeout                 (timeout)

import           MetaSonic.App.Demos            (Demo (..), demoTable,
                                                 demoManifestReloadCatalog)
import           MetaSonic.App.ManifestOSCIngressOps
                                                (ManifestOSCIngressHandle (..),
                                                 ManifestOSCIngressOpsIssue,
                                                 manifestOSCIngressOps)
import           MetaSonic.App.ManifestOSCListener
                                                (ManifestOSCListenerHooks (..),
                                                 ManifestOSCListenerIssue (..),
                                                 ListenerConfig,
                                                 ListenerInfo (..),
                                                 defaultManifestOSCListenerHooks)
import           MetaSonic.App.ManifestReloadBinding
                                                (ManifestUIVoiceSelection (..),
                                                 muitControls,
                                                 muitDemoKey,
                                                 muitVoiceSelection)
import           MetaSonic.App.ManifestReloadMIDIBinding
                                                (mmitControls)
import           MetaSonic.App.ManifestReloadCli
                                                (planManifestReloadForDemo,
                                                 readManifestReloadDocFile,
                                                 renderManifestReloadCliIssue,
                                                 renderManifestReloadHostStrategy,
                                                 renderSmokeReloadEvent,
                                                 renderStrategyOutcome)
import           MetaSonic.App.ManifestReloadEvent
                                                (ManifestReloadEvent)
import           MetaSonic.App.ManifestReloadHost
                                                (ManifestReloadHostConfig (..),
                                                 ManifestReloadHostIssue,
                                                 ManifestReloadHostStrategy (..),
                                                 reloadManifestHostWithStrategyWithEvents)
import           MetaSonic.App.ManifestReloadHostStack
                                                (RealStoppedAudioHostStackInputs (..),
                                                 StoppedAudioHostStack (..),
                                                 StoppedAudioHostStackIssue,
                                                 mkStoppedAudioHostStackFactory,
                                                 realStoppedAudioHostStackOps)
import           MetaSonic.App.ManifestReloadSupervisor
                                                (SupervisedReloadOutcome (..),
                                                 reloadSupervised)
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                                (HostStackFactory (..),
                                                 withHostStackSupervisorAdapter)
import           MetaSonic.App.ManifestReloadIngress
                                                (ManifestReloadIngressManager,
                                                 ManifestReloadIngressOps (..),
                                                 ManifestReloadIngressSnapshot (..),
                                                 closeManifestReloadIngress,
                                                 newManifestReloadIngressManager,
                                                 readManifestReloadIngressManager)
import           MetaSonic.App.ManifestReloadIngressTarget
                                                (ManifestReloadIngressTarget (..),
                                                 ManifestReloadIngressTargetPolicy (..),
                                                 manifestReloadIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadOSCBinding
                                                (ManifestOSCControlBinding (..),
                                                 ManifestOSCIngressTarget (..),
                                                 motControls,
                                                 renderManifestOSCAddressPattern)
import           MetaSonic.Authoring.Manifest   (AuthoringManifestDoc)
import           MetaSonic.Bridge.Templates     (Template (..),
                                                 TemplateGraph (..))
import           MetaSonic.Bridge.Source        (MigrationKey (..))
import           MetaSonic.Pattern              (ControlTag (..),
                                                 SwapLabel (..),
                                                 TemplateName (..),
                                                 VoiceKey (..))
import           MetaSonic.Session.Command      (SessionCommand (..))
import           MetaSonic.Session.FanIn        (SessionFanInAudioOptions (..),
                                                 SessionFanInEnqueueResult (..),
                                                 SessionFanInSnapshot (..),
                                                 SessionFanInHost,
                                                 defaultSessionFanInAudioFFI,
                                                 startSessionFanInHostAudioWith,
                                                 stopSessionFanInHostAudioWith)
import           MetaSonic.Session.FanInService (SessionFanInService,
                                                 defaultSessionFanInServiceHooks,
                                                 defaultSessionFanInServiceOptions,
                                                 enqueueSessionFanInServiceCommand,
                                                 readSessionFanInService,
                                                 sessionFanInServiceHost,
                                                 withSessionFanInService)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.OSCProducer  (OSCProducerEnqueueResult (..),
                                                 defaultOSCProducerOptions)
import           MetaSonic.Session.Owner        (defaultSessionOwnerOptions)
import           MetaSonic.Session.Queue        (ProducerId (..),
                                                 ProducerKind (..),
                                                 QueuedSessionCommand (..),
                                                 SessionEnqueueResult (..))
import           MetaSonic.Session.State        (SessionState (..))


-- | Which live-reload path drives the audible reload demo for
-- a given strategy.
--
-- 'StoppedAudioOnly' now goes through the supervised stack
-- (factory + adapter + 'reloadSupervised'), the same lifecycle
-- the @--manifest-host-reload-smoke@ CLI smoke uses. Preserving
-- and 'TryPreservingThenStoppedAudio' stay on the existing
-- direct path until the supervised stopped-audio route has
-- accumulated hardware exercise. Selection is pure so it can
-- be exercised by deterministic tests without staging real
-- audio.
data LiveReloadRoute
  = LiveReloadDirect
    -- ^ Drive 'reloadManifestHostWithStrategyWithEvents'
    -- against a 'ManifestReloadHostConfig' opened by this
    -- module. Used for 'RequirePreserving' and
    -- 'TryPreservingThenStoppedAudio'.
  | LiveReloadSupervised
    -- ^ Drive 'reloadSupervised' under
    -- 'withHostStackSupervisorAdapter' against a stack opened
    -- by 'realStoppedAudioHostStackOps'. Used for
    -- 'StoppedAudioOnly'.
  deriving stock (Eq, Show)


-- | Pure selector mapping each strategy to the live-reload
-- path it dispatches through.
selectLiveReloadRoute :: ManifestReloadHostStrategy -> LiveReloadRoute
selectLiveReloadRoute strategy = case strategy of
  StoppedAudioOnly              -> LiveReloadSupervised
  RequirePreserving             -> LiveReloadDirect
  TryPreservingThenStoppedAudio -> LiveReloadDirect


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
    LiveReloadSupervised ->
      runSupervisedLiveReload
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


renderLiveReloadRoute :: LiveReloadRoute -> String
renderLiveReloadRoute = \case
  LiveReloadDirect     -> "direct (reloadManifestHostWithStrategy)"
  LiveReloadSupervised ->
    "supervised (reloadSupervised + HostStackFactory)"


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
runSupervisedLiveReload
  :: ListenerConfig
  -> MR.ManifestReloadPlan
  -> MR.ManifestReloadPlan
  -> ManifestReloadIngressTarget
  -> ManifestReloadIngressTarget
  -> Demo
  -> Demo
  -> IO ()
runSupervisedLiveReload listenerCfg oldPlan newPlan oldTarget _newTarget
    _oldDemo _newDemo = do
  reloadEvents <- newIORef []
  let buildIngressOps host =
        manifestOSCIngressOps
          liveOSCListenerHooks
          defaultOSCProducerOptions
          host
          listenerCfg
      inputs = RealStoppedAudioHostStackInputs
        { rsahsiBuildIngressOps     = buildIngressOps
        , rsahsiIngressTargetPolicy = liveIngressTargetPolicy
        , rsahsiAudioFFI            = defaultSessionFanInAudioFFI
        , rsahsiAudioOptions        = liveAudioOptions
        , rsahsiOwnerOptions        = defaultSessionOwnerOptions
        , rsahsiServiceOptions      = defaultSessionFanInServiceOptions
        , rsahsiServiceHooks        = defaultSessionFanInServiceHooks
        , rsahsiOnEvent             =
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
        let initialService = mrhcService (sahsConfig initialStack)
            initialIngressManager =
              mrhcIngressManager (sahsConfig initialStack)
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


readManifestDocOrDie :: FilePath -> IO AuthoringManifestDoc
readManifestDocOrDie path = do
  result <- readManifestReloadDocFile path
  case result of
    Left issue ->
      die (renderManifestReloadCliIssue issue)
    Right doc ->
      pure doc

planOrDie
  :: AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> Demo
  -> IO MR.ManifestReloadPlan
planOrDie doc catalog demo =
  case planManifestReloadForDemo doc catalog demo of
    Left issue ->
      die (renderManifestReloadCliIssue issue)
    Right plan ->
      pure plan

targetOrDie :: MR.ManifestReloadPlan -> IO ManifestReloadIngressTarget
targetOrDie plan =
  case manifestReloadIngressTargetFromPlan liveIngressTargetPolicy plan of
    Left issue ->
      die ("Manifest live reload ingress target projection failed: "
           <> show issue)
    Right target ->
      pure target

requestFor :: Demo -> MR.ManifestReloadRequest
requestFor demo = MR.ManifestReloadRequest
  { MR.mrrDemoKey =
      demoKey demo
  , MR.mrrSwapLabel =
      SwapLabel (demoKey demo)
  , MR.mrrResourcePolicy =
      MR.defaultManifestResourcePolicy
  }

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

-- | Pick an OSC-safe voice key for an auto-spawned template.
--
-- The OSC dispatch layer caps voice keys at 16 bytes (see
-- 'isOscSafeIdentifier'); the previous "auto-<name>" scheme rejected
-- as 'DiIdentifierProfile' for template names longer than 11
-- characters (e.g. "auto-named-control" is 18 bytes). Policy:
--
--   * Template literally named "fx" keeps "fx" as its voice key
--     (already a valid identifier and operator-meaningful).
--   * Everything else gets "v<index>" where index counts non-"fx"
--     templates in declaration order.
--
-- Both shapes satisfy 'isOscSafeIdentifier' for any input.
autoVoiceKeyPolicy :: String -> Int -> VoiceKey
autoVoiceKeyPolicy name nonFxIndex
  | name == "fx" = VoiceKey "fx"
  | otherwise    = VoiceKey ("v" <> show nonFxIndex)

-- | Pair every template with the voice key it will be auto-spawned
-- under. Preserves declaration order so the policy's "v<index>" tracks
-- the operator-visible ordering in the addressable surface print.
assignAutoVoiceKeys :: [Template] -> [(Template, VoiceKey)]
assignAutoVoiceKeys = go 0
  where
    go _   []     = []
    go idx (t:ts)
      | tplName t == "fx" =
          (t, autoVoiceKeyPolicy (tplName t) idx) : go idx ts
      | otherwise =
          (t, autoVoiceKeyPolicy (tplName t) idx) : go (idx + 1) ts

-- | Enqueue one 'CmdVoiceOn' per template using the OSC-safe key
-- policy from 'autoVoiceKeyPolicy', and return the keys the caller
-- should wait for and surface. The wait is no longer inline so callers
-- can decide between 'waitForVoices' and proceeding immediately.
autoStartTemplates
  :: String
  -> SessionFanInService
  -> MR.ManifestReloadPlan
  -> IO [VoiceKey]
autoStartTemplates label service plan = do
  let templates = tgTemplates (MR.mrlpTemplateGraph plan)
  case templates of
    [] -> do
      putStrLn $ "  " <> label <> ": no templates to auto-start."
      pure []
    _ -> do
      putStrLn $
        "  " <> label <> ": auto-starting one instance per template..."
      forM (assignAutoVoiceKeys templates) $ \(tpl, voice) -> do
        let name = tplName tpl
            cmd = CmdVoiceOn (TemplateName name) voice []
        enq <- enqueueSessionFanInServiceCommand
                 liveReloadProducer
                 cmd
                 service
        putStrLn $
          "    " <> name <> " -> " <> renderEnqueue enq
        pure voice

-- | Wait (up to 1s) for every named key to appear in 'ssVoices'.
-- Returns True if all keys arrived, False on timeout. Replaces the
-- old 'waitForAnyVoice' which could not distinguish "the voice I
-- auto-spawned arrived" from "some other voice exists" — the
-- downstream surface printer needs the specific keys to be live
-- before snapshotting.
waitForVoices :: [VoiceKey] -> SessionFanInService -> IO Bool
waitForVoices []   _       = pure True
waitForVoices want service =
  maybe False id <$> timeout 1000000 loop
  where
    wantSet = S.fromList want
    loop = do
      snapshot <- readSessionFanInService service
      let have = M.keysSet (ssVoices (sfisOwnerState snapshot))
      if wantSet `S.isSubsetOf` have
        then pure True
        else threadDelay 10000 >> loop

-- | Wait for the supplied auto-spawned voice keys and emit a single
-- warning line if any failed to arrive in time. The list is the
-- caller-tracked truth (from 'autoStartTemplates'), not 'ssVoices' —
-- so the warning names exactly which keys didn't show up.
warnIfMissingVoices :: SessionFanInService -> [VoiceKey] -> IO ()
warnIfMissingVoices _       []   = pure ()
warnIfMissingVoices service want = do
  ready <- waitForVoices want service
  unless ready $ do
    snapshot <- readSessionFanInService service
    let have    = M.keysSet (ssVoices (sfisOwnerState snapshot))
        missing = [ k | k <- want, not (S.member k have) ]
    putStrLn $
      "    warning: auto-started voices did not all arrive in time; missing="
      <> show (map unVoiceKey missing)

printServiceSnapshot :: String -> SessionFanInService -> IO ()
printServiceSnapshot label service = do
  snapshot <- readSessionFanInService service
  putStrLn $ "  " <> label <> ":"
  putStrLn $ "    audio running: "
          <> if sfisAudioRunning snapshot then "yes" else "no"
  putStrLn $ "    queue depth: " <> show (sfisQueueDepth snapshot)
  putStrLn $ "    owner status: " <> show (sfisOwnerStatus snapshot)
  putStrLn $ "    reload status: " <> show (sfisReloadStatus snapshot)
  putStrLn $ "    active voices: "
          <> show (M.size (ssVoices (sfisOwnerState snapshot)))

printIngressSnapshot
  :: ManifestReloadIngressManager
       ManifestReloadIngressTarget
       ManifestOSCIngressOpsIssue
       ManifestOSCIngressHandle
  -> IO ()
printIngressSnapshot manager = do
  snapshot <- readManifestReloadIngressManager manager
  putStrLn $ "  ingress: " <> renderIngressSnapshot snapshot

-- | Mirrors @renderSmokeIngressSnapshot@ in
-- 'MetaSonic.App.ManifestReloadCli' so the host-reload-smoke and
-- the live-reload-demo report the combined ingress projection in
-- the same shape (UI / OSC / MIDI counts + defaultVoice + bound
-- OSC port). The underlying 'ManifestReloadIngressTarget' carries
-- all three slices regardless of which CLI is reading it.
renderIngressSnapshot
  :: ManifestReloadIngressSnapshot
       ManifestReloadIngressTarget
       ManifestOSCIngressHandle
  -> String
renderIngressSnapshot snapshot =
  case snapshot of
    MrisClosed ->
      "closed"
    MrisOpen target handle ->
      "open demo="
      <> muitDemoKey (mitUI target)
      <> " ui-controls="
      <> show (length (muitControls (mitUI target)))
      <> " osc-controls="
      <> show (length (motControls (mitOSC target)))
      <> " midi-cc="
      <> show (length (mmitControls (mitMIDI target)))
      <> " defaultVoice="
      <> unVoiceKey
           (muvsDefaultVoice (muitVoiceSelection (mitUI target)))
      <> " oscPort="
      <> show (liBoundPort (moihInfo handle))

renderOSCControls :: String -> ManifestReloadIngressTarget -> IO ()
renderOSCControls label target = do
  putStrLn $ "  " <> label <> ":"
  case motControls (mitOSC target) of
    [] ->
      putStrLn "    (no OSC controls)"
    controls ->
      forM_ controls renderOne
  where
    renderOne binding =
      putStrLn $
        "    " <> renderManifestOSCAddressPattern (mocbControlTag binding)
        <> "  name=\"" <> mocbDisplayName binding <> "\""

-- | Print the concrete OSC addresses the operator can send packets to
-- right now. The address surface is voices × bound CC controls — the
-- 'renderOSCControls' table above prints the pattern with a literal
-- @\<voice\>@ placeholder; this resolves the placeholder against the
-- voices that are actually live in 'ssVoices'.
--
-- Empty voice set is rare in practice because the caller is expected
-- to have just run 'warnIfMissingVoices' against the keys returned by
-- 'autoStartTemplates'. If it still happens, surface a true statement
-- — writes are still accepted at the manifest layer, but they have no
-- audible target until a voice is live for them to drive.
printAddressableSurface
  :: SessionFanInService
  -> ManifestReloadIngressTarget
  -> IO ()
printAddressableSurface service target = do
  snapshot <- readSessionFanInService service
  let voices = M.keys (ssVoices (sfisOwnerState snapshot))
      bindings = motControls (mitOSC target)
  case (voices, bindings) of
    ([], _) ->
      putStrLn
        "  addressable OSC surface: (no live voices; manifest writes are accepted but have no audible target)"
    (_, []) ->
      putStrLn
        "  addressable OSC surface: (manifest binds no OSC controls)"
    _ -> do
      putStrLn "  addressable OSC surface:"
      forM_ voices $ \voice ->
        forM_ bindings $ \binding ->
          putStrLn $
            "    " <> renderConcreteOSCAddress voice (mocbControlTag binding)
            <> "  (name=\"" <> mocbDisplayName binding <> "\")"

renderConcreteOSCAddress :: VoiceKey -> ControlTag -> String
renderConcreteOSCAddress voice (ControlTag (MigrationKey key) slot) =
  "/" <> unVoiceKey voice <> "/" <> key <> "/" <> show slot

renderEnqueue :: SessionFanInEnqueueResult -> String
renderEnqueue result =
  case sfierResult result of
    SessionEnqueued queued ->
      "enqueued " <> show (qscCommand queued)
    SessionEnqueueRejected _producer cmd issue ->
      "rejected " <> show cmd <> " issue=" <> show issue

-- | Render the per-run reload-event timeline as a compact bullet
-- list, mirroring the @--manifest-host-reload-smoke@ surface so
-- operators read the same vocabulary in both CLIs.
renderLiveReloadEvents
  :: [ManifestReloadEvent
        (ManifestReloadHostIssue ManifestOSCIngressOpsIssue)]
  -> [String]
renderLiveReloadEvents events =
  case events of
    [] ->
      ["    (none)"]
    _ ->
      map renderSmokeReloadEvent events

liveOSCListenerHooks :: ManifestOSCListenerHooks
liveOSCListenerHooks = defaultManifestOSCListenerHooks
  { molhOnAccepted =
      \accepted -> putStrLn ("  " <> renderOSCAccept accepted)
  , molhOnIssue =
      \issue -> putStrLn ("  " <> renderOSCIssue issue)
  }

renderOSCAccept :: OSCProducerEnqueueResult -> String
renderOSCAccept result = case result of
  OSCProducerDecodeRejected issue ->
    "osc reject (decode): " <> show issue
  OSCProducerEnqueueAttempted cmd enqueue ->
    case sfierResult enqueue of
      SessionEnqueued _ ->
        "osc accept: " <> renderCommand cmd
      SessionEnqueueRejected _producer _cmd issue ->
        "osc enqueue-reject: " <> renderCommand cmd
        <> " issue=" <> show issue

renderOSCIssue :: ManifestOSCListenerIssue -> String
renderOSCIssue issue = case issue of
  MoliParseFailure msg ->
    "osc reject (parse): " <> msg
  MoliManifestIssue manifestIssue ->
    "osc reject (manifest): " <> show manifestIssue
  MoliEnqueueRejected cmd queueIssue ->
    "osc enqueue-reject: " <> renderCommand cmd
    <> " issue=" <> show queueIssue

renderCommand :: SessionCommand -> String
renderCommand cmd = case cmd of
  CmdControlWrite voice tag value ->
    "CmdControlWrite voice=" <> unVoiceKey voice
    <> " tag=" <> show tag
    <> " value=" <> show value
  CmdVoiceOn (TemplateName name) voice _args ->
    "CmdVoiceOn template=" <> name <> " voice=" <> unVoiceKey voice
  _ ->
    show cmd

liveIngressTargetPolicy :: ManifestReloadIngressTargetPolicy
liveIngressTargetPolicy = ManifestReloadIngressTargetPolicy
  { mritpUIVoiceSelection =
      ManifestUIVoiceSelection
        { muvsFocusedVoice =
            Nothing
        , muvsDefaultVoice =
            VoiceKey "v0"
        }
  , mritpUIRetainedValues =
      M.empty
  , mritpMIDIDefaultVoice =
      VoiceKey "fx"
  }

liveReloadProducer :: ProducerId
liveReloadProducer =
  ProducerId ProducerUI (T.pack "manifest-live-reload-demo")

liveAudioOptions :: SessionFanInAudioOptions
liveAudioOptions = SessionFanInAudioOptions
  { sfiaoOutputChannels =
      2
  , sfiaoDeviceID =
      -1
  , sfiaoReadyTimeoutMs =
      1000
  }
