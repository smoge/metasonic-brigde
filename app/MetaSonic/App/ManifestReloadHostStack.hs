{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE RankNTypes         #-}
{-# LANGUAGE TypeApplications   #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadHostStack
-- Description : Substrate stack + stopped-audio strategy for supervised manifest reloads.
--
-- This module hosts two things:
--
--   1. The /substrate/ — 'ReloadHostStack' (one active host stack),
--      'ReloadHostStackOpenIssue' (open-time failure ADT), and
--      'RealReloadHostStackInputs' (producer-supplied inputs for the
--      live open\/close path), plus 'realOpen' \/ 'realClose'. All
--      route-agnostic, reused by every supervised route's production
--      ops bundle.
--   2. The /stopped-audio strategy/ — the route-specific
--      'StoppedAudioHostStackOps' \/ 'StoppedAudioHostStackIssue',
--      'realStoppedAudioInWindowReload', 'realStoppedAudioHostStackOps',
--      'mkStoppedAudioHostStackFactory', and the
--      'runSupervisedStoppedAudioReload' entry point.
--
-- The §219 slice-4 design note required defining what a
-- \"closeable \/ reopenable host stack\" is; the substrate types here
-- answer that. Routing landed in commits @93e755c@ (CLI smoke) and
-- @905edd5@ (audible @--manifest-live-reload-demo@), and was
-- hardware-confirmed once on 2026-05-20 (full transcript in the
-- runbook at @notes/2026-05-19-b-manifest-host-reload-smoke-
-- runbook.md@). The @StoppedAudioOnly@ strategy dispatches through
-- 'mkStoppedAudioHostStackFactory' + 'reloadSupervised' in both
-- operator-facing entrypoints. @TryPreservingThenStoppedAudio@ uses
-- the sibling
-- "MetaSonic.App.ManifestReloadTryPreservingHostStack" factory,
-- which composes the preserving in-window helper with
-- 'realStoppedAudioInWindowReload' under the existing
-- 'preservingAllowsStoppedAudioFallback' gate.
-- @RequirePreserving@ uses
-- "MetaSonic.App.ManifestReloadPreservingHostStack" directly
-- (preserving-only — no fallback composition). All three
-- @--manifest-live-reload-demo@ strategies now dispatch through
-- the supervisor; the original migration evidence bar lives in
-- @notes/2026-05-20-a-supervised-route-tier3-decision.md@.
--
-- 'realStoppedAudioHostStackOps' is the production wiring for
-- open / close. It opens the imperative
-- 'openSessionFanInServiceHooks' primitive (added in step 1 to
-- avoid promoting the bracket via a worker thread), projects the
-- ingress target from the plan, opens ingress, then starts audio
-- in that order; close runs in reverse. Partial-cleanup failures
-- during rollback are surfaced through
-- 'RhsoiPartialCleanupFailed' so the supervisor can escalate
-- rather than reuse a partially-cleaned stack.
--
-- 'realStoppedAudioInWindowReload' is the production wiring for
-- the in-window slot: it drives
-- 'orchestrateHostStoppedAudioReloadWithEvents' directly with
-- @hsaroPreparePlan@ overridden to @const (pure (Right plan))@,
-- so the supervisor's supplied plan is the source of truth at
-- the seam (no silent re-planning from doc/catalog/policy drift).
--
-- Tests inject fake @sahsoOpen@ / @sahsoClose@ / @sahsoInWindowReload@
-- and verify the factory composes with 'withHostStackSupervisorAdapter'
-- + 'reloadSupervised' across the seven slice-4 scenarios named in
-- the supervisor §238 checklist (success, owner-setup failure
-- recovery, audio-restart recovery, listener/ingress-open recovery,
-- rebuild escalation, no overlapping stacks, async cleanup) plus the
-- A→B→C→D! no-remembered-history regression. A separate test group
-- exercises 'realStoppedAudioHostStackOps' against fake ingress ops
-- + audio FFI to pin the partial-cleanup paths.
--
-- See notes/2026-05-14-k-host-reload-supervisor.md \xa7219 slice 4.
module MetaSonic.App.ManifestReloadHostStack
  ( -- * Substrate (shared across all supervised routes)
    --
    -- These three types describe \"one active host stack\" and the
    -- inputs needed to spin one up. They are route-agnostic: every
    -- supervised route (stopped-audio, preserving, try-preserving)
    -- threads the same value through the supervisor adapter and uses
    -- the same production-input record. The strategy-specific
    -- machinery lives in companion modules and reuses these.
    ReloadHostStack (..)
  , ReloadHostStackOpenIssue (..)
  , RealReloadHostStackInputs (..)
    -- * Shared open\/close
    --
    -- The open and close paths are route-agnostic — they spin up a
    -- fresh @SessionFanInService@ + audio + ingress against a plan,
    -- and tear them down in reverse. Every supervised route needs
    -- that lifecycle on initial open and on terminal-failure rebuild;
    -- only the in-window slot differs.
  , realOpen
  , realClose
    -- * Stopped-audio strategy
  , StoppedAudioHostStackOps (..)
  , StoppedAudioHostStackIssue (..)
  , mkStoppedAudioHostStackFactory
  , realStoppedAudioInWindowReload
  , realStoppedAudioHostStackOps
    -- * Supervised stopped-audio entry
  , SupervisedStoppedAudioReloadResult (..)
  , runSupervisedStoppedAudioReload
  ) where

import           Control.Exception                           (SomeException,
                                                              mask,
                                                              onException,
                                                              throwIO, try)
import           Control.Monad                               (void)
import           Data.Bifunctor                              (first)
import           Data.Foldable                               (for_)
import           Data.Maybe                                  (catMaybes,
                                                              listToMaybe)
import           Data.Text                                   (Text)
import qualified Data.Text                                   as T

import           MetaSonic.App.ManifestReloadEvent           (ManifestReloadEvent)
import           MetaSonic.App.ManifestReloadHost            (ManifestReloadHostConfig (..),
                                                              manifestReloadHostOps)
import           MetaSonic.App.ManifestReloadHost.Types      (ManifestReloadHostIssue (..))
import           MetaSonic.App.ManifestReloadIngress         (ManifestReloadIngressManager,
                                                              ManifestReloadIngressOps (..),
                                                              closeManifestReloadIngress,
                                                              newManifestReloadIngressManager)
import           MetaSonic.App.ManifestReloadIngressTarget   (ManifestReloadIngressTarget,
                                                              ManifestReloadIngressTargetPolicy,
                                                              manifestReloadIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadMIDIBinding     (ManifestMIDIProjectionIssue)
import           MetaSonic.App.ManifestReloadOrchestration   (orchestrateHostStoppedAudioReloadWithEvents)
import           MetaSonic.App.ManifestReloadOrchestration.Types
                                                             (HostStoppedAudioReloadIssue (..),
                                                              HostStoppedAudioReloadOps (..))
import           MetaSonic.App.ManifestReloadSupervisor      (InWindowReloadOutcome (..),
                                                              SupervisedReloadOutcome (..),
                                                              inWindowOutcomeFromEither,
                                                              reloadSupervised)
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                                             (HostStackFactory (..),
                                                              withHostStackSupervisorAdapter)
import           MetaSonic.Authoring.Manifest                (AuthoringManifestDoc (..),
                                                              manifestSchemaVersion)
import           MetaSonic.Session.FanIn                     (SessionFanInAudioFFI,
                                                              SessionFanInAudioIssue,
                                                              SessionFanInAudioOptions,
                                                              SessionFanInHost,
                                                              startSessionFanInHostAudioWith,
                                                              stopSessionFanInHostAudioFadeWith)
import           MetaSonic.Session.FanInService              (SessionFanInService,
                                                              SessionFanInServiceHooks,
                                                              SessionFanInServiceOptions,
                                                              SessionFanInServiceSetupIssue,
                                                              closeSessionFanInService,
                                                              openSessionFanInServiceHooks,
                                                              sessionFanInServiceHost)
import qualified MetaSonic.Session.ManifestReload            as MR
import           MetaSonic.Session.Owner                     (SessionOwnerOptions)
import           MetaSonic.Session.Resolve                   (RetiredVoiceBinding)


-- | The runtime objects that constitute one active supervised host
-- stack. Built fresh on each open; torn down on close. The
-- supervisor adapter holds exactly one of these in its IORef at any
-- time. This type is route-agnostic — every supervised route
-- (stopped-audio, preserving, try-preserving) threads the same
-- 'ReloadHostStack' value through the adapter; only the in-window
-- slot's behavior varies.
--
-- @rhsConfig@ carries the live runtime references (the
-- 'SessionFanInService', the ingress manager, the audio FFI, the
-- ingress targets, and the event hook).
--
-- Note that this record carries NO @currentPlan@-style field. The
-- supervisor's contract is that the caller of 'reloadSupervised'
-- threads @currentPlan@ externally — passing it as @fallback@ on
-- each call, capturing the @requested@ plan as the new
-- @currentPlan@ on success. Tracking a plan field on the stack
-- itself would either silently drift (if not updated after a
-- successful in-window reload) or duplicate state the caller
-- already owns; either way it would mislead a routing slice that
-- read the stack for the next fallback. Keep plan ownership at
-- the caller and rebuilds use whichever plan the supervisor was
-- told to remember.
newtype ReloadHostStack target ingressIssue handle =
  ReloadHostStack
    { rhsConfig :: ManifestReloadHostConfig target ingressIssue handle
    }


-- | Open / close / in-window-reload primitives, supplied as
-- injectable IO so:
--
-- - production wiring can plug 'withSessionFanInService' +
--   'newManifestReloadIngressManager' +
--   'startSessionFanInHostAudio' (or their imperative
--   equivalents in a future slice);
-- - tests can plug fakes that simulate side effects and inject
--   specific failure modes without staging real session-layer
--   state.
--
-- The in-window reload slot is also injectable so tests can pin
-- the specific 'HostStoppedAudioReloadIssue' variants
-- ('HsariReloadFailedNoOwner', 'HsariAudioRestartFailed',
-- 'HsariListenerRestartFailed') without needing the real helper
-- to fail at exactly those points. Production callers wire
-- 'realStoppedAudioInWindowReload' into this slot.
data StoppedAudioHostStackOps target ingressIssue handle =
  StoppedAudioHostStackOps
    { sahsoOpen
        :: !(MR.ManifestReloadPlan
              -> IO (Either
                      (ReloadHostStackOpenIssue ingressIssue)
                      (ReloadHostStack target ingressIssue handle)))
      -- ^ Build a fresh stack from the supplied plan. Per the
      -- 'HostStackFactory' contract the producer must clean up any
      -- partial state before returning 'Left'; the supervisor
      -- adapter calls this only on the rebuild path against the
      -- captured fallback plan.
    , sahsoClose
        :: !(ReloadHostStack target ingressIssue handle -> IO ())
      -- ^ Dispose a previously-opened stack: close ingress, stop
      -- audio, dispose the SessionFanInService and its host
      -- bracket. Best-effort; the supervisor adapter wraps the
      -- close path in 'mask_' so the atomic-take-then-close
      -- handoff is uninterruptible.
    , sahsoInWindowReload
        :: !(ReloadHostStack target ingressIssue handle
              -> MR.ManifestReloadPlan
              -> MR.ManifestReloadPlan
              -> IO (InWindowReloadOutcome
                      (HostStoppedAudioReloadIssue
                        (ManifestReloadHostIssue ingressIssue))))
      -- ^ Drive a stopped-audio in-window reload against the
      -- currently-open stack. Takes the @fallback@ plan (the
      -- plan the stack is currently running) followed by the
      -- @requested@ plan. Production wires
      -- 'realStoppedAudioInWindowReload' (which uses the
      -- fallback to re-project 'mrhcOldIngressTarget' fresh on
      -- every call); tests can return any specific failure
      -- variant.
      --
      -- Stopped-audio cannot produce
      -- 'InWindowReloadRejectedLiveFallback' by construction —
      -- audio stops before the reinstall, so there is no \"old
      -- owner still installed\" branch. Production uses
      -- 'inWindowOutcomeFromEither' to lift the orchestrator's
      -- @Either e ()@ result; the @Left@ side always becomes
      -- 'InWindowReloadTerminal'. Tests that want to cover the
      -- 'RejectedLiveFallback' branch should target the
      -- preserving / try-preserving paths instead, where the
      -- classification is real.
    }


-- | Failures from the substrate open path ('realOpen', driven by
-- the route's open slot — e.g. 'sahsoOpen' for stopped-audio,
-- 'pahsoOpen' for preserving). Mirrors the five resource-bearing
-- side effects the production wiring performs (target projection,
-- service setup, ingress open, audio start, and partial-cleanup
-- rollback) so the supervisor's 'SupervisedReloadEscalated' payload
-- carries actionable diagnostics when both the requested in-window
-- reload AND the rebuild fail. Route-agnostic — every supervised
-- route's open issue threads through this ADT.
data ReloadHostStackOpenIssue ingressIssue
  = RhsoiServiceSetupFailed !SessionFanInServiceSetupIssue
    -- ^ 'openSessionFanInService' (or its bracketed counterpart)
    -- rejected the supplied template graph + service options. No
    -- resources were acquired; no rollback is needed.
  | RhsoiAudioStartFailed !SessionFanInAudioIssue
    -- ^ Audio FFI start returned a non-zero error after the
    -- service and ingress were already constructed. The producer
    -- is responsible for disposing the service + ingress before
    -- returning this.
  | RhsoiIngressOpenFailed !ingressIssue
    -- ^ The listener/producer factory rejected the initial open.
    -- The producer is responsible for disposing the service
    -- before returning this.
  | RhsoiIngressTargetProjectionFailed !ManifestMIDIProjectionIssue
    -- ^ 'manifestReloadIngressTargetFromPlan' rejected the
    -- supplied plan (duplicate MIDI CC mapping in the projection
    -- table). No resources were acquired; no rollback is needed.
  | RhsoiPartialCleanupFailed
      !(ReloadHostStackOpenIssue ingressIssue)
      !Text
    -- ^ A primary open failure triggered a rollback that itself
    -- failed (close-ingress returned 'Left', stop-audio threw,
    -- service close threw). Carries the primary issue plus a
    -- textual display of the rollback diagnostic. The supervisor
    -- must escalate to 'SupervisedReloadEscalated' on this — the
    -- stack is in an unknown partial state and a clean rebuild is
    -- the only safe recovery. The primary issue is never itself a
    -- 'RhsoiPartialCleanupFailed' (rollback failures from a
    -- rollback are folded into the outer cleanup-display text).
  deriving stock (Eq, Show)


-- | Unified factory error type. Threads through 'HostStackFactory'
-- as its @e@ parameter so both halves (open failures and in-window
-- failures) reach the supervisor's outcome variants through one
-- ADT.
data StoppedAudioHostStackIssue ingressIssue
  = SahsiInWindow
      !(HostStoppedAudioReloadIssue
          (ManifestReloadHostIssue ingressIssue))
    -- ^ In-window reload failed terminally; the supervisor will
    -- close the stack and attempt a rebuild from the captured
    -- fallback plan.
  | SahsiOpen !(ReloadHostStackOpenIssue ingressIssue)
    -- ^ The rebuild's 'sahsoOpen' against the fallback plan
    -- failed; the supervisor escalates with both causes preserved.
  deriving stock (Eq, Show)


-- | Production in-window reload wiring, plan-native + target-fresh.
--
-- Two structural guarantees at this seam, both load-bearing for the
-- supervisor contract:
--
-- 1. /Plan-native/: the @requested@ plan handed in by the supervisor
--    is the source of truth. The helper drives
--    'orchestrateHostStoppedAudioReloadWithEvents' with
--    @hsaroPreparePlan@ overridden to @const (pure (Right requested))@,
--    so the orchestrator installs the exact plan the supervisor
--    validated — no silent re-planning from doc / catalog / static
--    resource-policy drift between validation and invocation.
--
-- 2. /Target-fresh/: both 'mrhcOldIngressTarget' and
--    'mrhcNewIngressTarget' are re-projected here from the
--    @fallback@ and @requested@ plans respectively, then patched
--    into a fresh 'ManifestReloadHostConfig' before the orchestrator
--    runs. The stack value's cached projection from open-time is
--    never consulted. This keeps target selection plan-derived at
--    every reload boundary, so a long sequence of in-window reloads
--    (A → B → C → D, ...) cannot accumulate a stale @newTarget@ from
--    an earlier reload that no longer matches the currently-running
--    plan.
--
-- Projection failure on @requested@ surfaces as
-- @HsariReloadFailedNoOwner (MrhiPlanning (MriUnknownManifestDemo ...))@-shaped
-- equivalent via the orchestrator's prepare slot — but since the
-- override here short-circuits the orchestrator's planner, projection
-- failure on @requested@ instead surfaces by failing the projection
-- /before/ the orchestrator runs, encoded as
-- @HsariReloadFailedNoOwner (MrhiPlanning (MriUnknownManifestDemo demoKey))@
-- via a synthesized planning rejection on the requested demo key.
-- Projection failure on @fallback@ is treated as an impossible
-- case (the fallback was already running, so its projection was
-- validated at open time); if it ever happens it surfaces the same
-- way for diagnostic uniformity.
--
-- The request value passed to the orchestrator is synthesized
-- from the plan for ergonomics (operator-facing event payloads
-- carry the demo key + swap label) but the orchestrator never
-- consults it for planning — the override short-circuits that.
-- The 'AuthoringManifestDoc' / catalog handed into
-- 'manifestReloadHostOps' are also unused after the override;
-- empty placeholders flow through to slots the supervisor never
-- forces.
realStoppedAudioInWindowReload
  :: ManifestReloadIngressTargetPolicy
  -> ReloadHostStack ManifestReloadIngressTarget ingressIssue handle
  -> MR.ManifestReloadPlan
  -> MR.ManifestReloadPlan
  -> IO (InWindowReloadOutcome
          (HostStoppedAudioReloadIssue
            (ManifestReloadHostIssue ingressIssue)))
realStoppedAudioInWindowReload policy stack fallback requested =
  case manifestReloadIngressTargetFromPlan policy requested of
    Left _projIssue ->
      pure
        (InWindowReloadTerminal
          (HsariReloadFailedNoOwner
            (MrhiPlanning
              (MR.MriUnknownManifestDemo (MR.mrlpDemoKey requested)))))
    Right newTarget ->
      case manifestReloadIngressTargetFromPlan policy fallback of
        Left _projIssue ->
          pure
            (InWindowReloadTerminal
              (HsariReloadFailedNoOwner
                (MrhiPlanning
                  (MR.MriUnknownManifestDemo (MR.mrlpDemoKey fallback)))))
        Right oldTarget ->
          let baseConfig = rhsConfig stack
              freshConfig = baseConfig
                { mrhcOldIngressTarget = oldTarget
                , mrhcNewIngressTarget = newTarget
                }
          in inWindowOutcomeFromEither
               <$> orchestrateHostStoppedAudioReloadWithEvents
                     (mrhcOnEvent freshConfig)
                     (planNativeOps freshConfig)
                     syntheticRequest
  where
    -- manifestReloadHostOps builds the orchestrator slot bundle
    -- using doc/catalog only inside hsaroPreparePlan; overriding
    -- that slot makes doc/catalog dead inputs, so empty
    -- placeholders flow safely through.
    planNativeOps c =
      (manifestReloadHostOps c emptyDoc [])
        { hsaroPreparePlan = const (pure (Right requested))
        }

    -- Synthesized for event-payload ergonomics; not consulted by
    -- the overridden preparePlan slot.
    syntheticRequest = MR.ManifestReloadRequest
      { MR.mrrDemoKey        = MR.mrlpDemoKey requested
      , MR.mrrSwapLabel      = MR.mrlpSwapLabel requested
      , MR.mrrResourcePolicy = MR.defaultManifestResourcePolicy
      }

    emptyDoc = AuthoringManifestDoc
      { docSchemaVersion = manifestSchemaVersion
      , docDemos         = []
      }


-- | Build a 'HostStackFactory' from a fully-specified ops bundle.
-- The supervisor adapter drives this directly through
-- 'withHostStackSupervisorAdapter'.
mkStoppedAudioHostStackFactory
  :: StoppedAudioHostStackOps target ingressIssue handle
  -> HostStackFactory
       MR.ManifestReloadPlan
       (ReloadHostStack target ingressIssue handle)
       (StoppedAudioHostStackIssue ingressIssue)
mkStoppedAudioHostStackFactory ops = HostStackFactory
  { hsfOpenStack      = fmap (first SahsiOpen) . sahsoOpen ops
  , hsfCloseStack     = sahsoClose ops
  , hsfInWindowReload = \stack fallback requested ->
      fmap SahsiInWindow
        <$> sahsoInWindowReload ops stack fallback requested
  }


-- | Producer-supplied inputs for the substrate 'realOpen' /
-- 'realClose' path, reused by every supervised route's production
-- ops bundle ('realStoppedAudioHostStackOps',
-- 'realPreservingHostStackOps', 'realTryPreservingHostStackOps').
--
-- These are the dependencies the production helper cannot derive
-- from the supervisor's plan alone: the ingress ops bundle (OSC or
-- MIDI, with its own listener config baked in), the ingress target
-- projection policy, the audio FFI bundle, audio + service +
-- owner options, and the per-active event sink.
--
-- The supervisor adapter holds one of these for the lifetime of the
-- supervised process; the helper closes over them when building the
-- route-specific ops record. The 'target' parameter is locked to
-- 'ManifestReloadIngressTarget' because the projection helper only
-- knows about that type; the @ingressIssue@ and @handle@ parameters
-- stay polymorphic so OSC and MIDI ingress factories can both reuse
-- the helper.
data RealReloadHostStackInputs ingressIssue handle =
  RealReloadHostStackInputs
    { rrhsiBuildIngressOps
        :: !(SessionFanInHost
              -> ManifestReloadIngressOps ManifestReloadIngressTarget ingressIssue handle)
      -- ^ Build the ingress ops bundle against the just-opened
      -- 'SessionFanInHost'. Production OSC / MIDI ingress ops
      -- close over the host (the listener thread forwards to it),
      -- so they must be re-built fresh on every 'realOpen' — the
      -- supervisor opens a new service on each rebuild, and the
      -- old host is gone by then. The factory makes that
      -- per-stack lifetime explicit.
    , rrhsiIngressTargetPolicy
        :: !ManifestReloadIngressTargetPolicy
    , rrhsiAudioFFI
        :: !SessionFanInAudioFFI
    , rrhsiAudioOptions
        :: !SessionFanInAudioOptions
    , rrhsiOwnerOptions
        :: !SessionOwnerOptions
    , rrhsiServiceOptions
        :: !SessionFanInServiceOptions
    , rrhsiServiceHooks
        :: !SessionFanInServiceHooks
    , rrhsiOnEvent
        :: !(ManifestReloadEvent (ManifestReloadHostIssue ingressIssue) -> IO ())
    , rrhsiOnRetired
        :: !([RetiredVoiceBinding] -> IO ())
      -- ^ Phase 8h step 3e v1 slice 4: forwarded into
      -- 'mrhcOnRetired' on the per-stack 'ManifestReloadHostConfig'
      -- and from there into the orchestrator's
      -- 'hproOnRetired' / 'hsaroOnRetired' hooks. Fires *before*
      -- ingress reopens so producers reaching the just-installed
      -- owner are attributed by the live shell's drain hook against
      -- the latest retired set. Construction sites that do not need
      -- the snapshot should set this to @\\_ -> pure ()@.
    }


-- | Production wiring for 'StoppedAudioHostStackOps' against live
-- session-layer primitives.
--
-- Open order: project ingress target → 'openSessionFanInService'
-- → 'mrioOpenIngress' → 'newManifestReloadIngressManager' →
-- 'startSessionFanInHostAudioWith'. Close order is the reverse.
--
-- Partial-cleanup contract: if a primary open failure triggers
-- rollback (close-ingress / stop-audio / close-service) and the
-- rollback itself fails (returns 'Left', throws, or both), the
-- primary issue is wrapped in 'RhsoiPartialCleanupFailed' with a
-- textual rollback diagnostic. The supervisor escalates on that
-- variant; a clean rebuild is the only safe recovery.
--
-- The in-window reload slot is wired to
-- 'realStoppedAudioInWindowReload' so the supervisor's supplied
-- plan is the source of truth (no silent re-planning).
realStoppedAudioHostStackOps
  :: Show ingressIssue
  => RealReloadHostStackInputs ingressIssue handle
  -> StoppedAudioHostStackOps ManifestReloadIngressTarget ingressIssue handle
realStoppedAudioHostStackOps inputs = StoppedAudioHostStackOps
  { sahsoOpen           = realOpen inputs
  , sahsoClose          = realClose
  , sahsoInWindowReload =
      realStoppedAudioInWindowReload (rrhsiIngressTargetPolicy inputs)
  }


-- | Forward open path used by every supervised route's production
-- ops bundle (wired through 'sahsoOpen' / 'pahsoOpen' / 'tpahsoOpen').
--
-- Exception-safety: every acquired resource is wrapped in an
-- 'onException' handler before the next step runs, so an
-- exception (sync or async) from a downstream allocation closes
-- every still-owned upstream resource. The outer 'mask' is the
-- gate that makes the post-acquisition / pre-handler windows
-- unobservable to async exceptions — without it, an async
-- exception landing between @openSessionFanInServiceHooks@
-- returning @Right service@ and the outer @onException@ being
-- installed would leak the service. 'restore' is used around the
-- blocking IO calls so the caller's masking state is preserved
-- inside the long-running operations themselves.
--
-- Note: the small window between @mrioOpenIngress@ returning
-- @Right initialHandle@ and @newManifestReloadIngressManager@
-- wrapping it can still drop the raw handle on async interrupt
-- (the ops bundle exposes no standalone handle-close primitive,
-- only the manager-level close). This matches the existing demo
-- path's contract; closing that gap would require extending
-- 'ManifestReloadIngressOps' with a raw-handle close.
realOpen
  :: Show ingressIssue
  => RealReloadHostStackInputs ingressIssue handle
  -> MR.ManifestReloadPlan
  -> IO (Either
          (ReloadHostStackOpenIssue ingressIssue)
          (ReloadHostStack ManifestReloadIngressTarget ingressIssue handle))
realOpen inputs plan = mask $ \restore ->
  case manifestReloadIngressTargetFromPlan
         (rrhsiIngressTargetPolicy inputs)
         plan of
    Left projIssue ->
      pure (Left (RhsoiIngressTargetProjectionFailed projIssue))
    Right target -> do
      serviceResult <- restore $ openSessionFanInServiceHooks
        (rrhsiServiceHooks inputs)
        (MR.mrlpTemplateGraph plan)
        (rrhsiServiceOptions inputs)
      case serviceResult of
        Left issue ->
          pure (Left (RhsoiServiceSetupFailed issue))
        Right service ->
          openIngressAndStartAudio restore inputs target service
            `onException` closeSessionFanInService service


-- | Inner half of 'realOpen'. Runs with the outer 'mask' active so
-- the @onException@ handlers it installs cannot race against an
-- async exception landing after a resource is acquired but
-- before the handler is in scope.
openIngressAndStartAudio
  :: Show ingressIssue
  => (forall a. IO a -> IO a)
  -> RealReloadHostStackInputs ingressIssue handle
  -> ManifestReloadIngressTarget
  -> SessionFanInService
  -> IO (Either
          (ReloadHostStackOpenIssue ingressIssue)
          (ReloadHostStack ManifestReloadIngressTarget ingressIssue handle))
openIngressAndStartAudio restore inputs target service = do
  let ingressOps = rrhsiBuildIngressOps
        inputs
        (sessionFanInServiceHost service)
  ingressResult <- restore $ mrioOpenIngress ingressOps target
  case ingressResult of
    Left issue ->
      rollbackIngressOpen
        (RhsoiIngressOpenFailed issue)
        service
    Right initialHandle -> do
      ingressManager <- newManifestReloadIngressManager
        ingressOps
        target
        initialHandle
      let withIngressCleanup body =
            body
              `onException` void (closeManifestReloadIngress ingressManager)
      withIngressCleanup $ do
        audioResult <- restore $ startSessionFanInHostAudioWith
          (rrhsiAudioFFI inputs)
          (sessionFanInServiceHost service)
          (rrhsiAudioOptions inputs)
        case audioResult of
          Left issue ->
            rollbackAudioStart
              (RhsoiAudioStartFailed issue)
              service
              ingressManager
          Right () ->
            pure $ Right (mkStack inputs target service ingressManager)


-- | Build the 'ReloadHostStack' value from a fully-acquired
-- resource set. Both 'mrhcOldIngressTarget' and 'mrhcNewIngressTarget'
-- carry the projection of the install-time plan; the supervisor
-- routing slice (step 4) is responsible for re-projecting both on
-- each subsequent in-window reload so a cached @newTarget@ cannot
-- drift away from the supervisor's current plan.
mkStack
  :: RealReloadHostStackInputs ingressIssue handle
  -> ManifestReloadIngressTarget
  -> SessionFanInService
  -> ManifestReloadIngressManager ManifestReloadIngressTarget ingressIssue handle
  -> ReloadHostStack ManifestReloadIngressTarget ingressIssue handle
mkStack inputs target service ingressManager = ReloadHostStack
  ManifestReloadHostConfig
    { mrhcService          = service
    , mrhcIngressManager   = ingressManager
    , mrhcOldIngressTarget = target
    , mrhcNewIngressTarget = target
    , mrhcAudioFFI         = rrhsiAudioFFI inputs
    , mrhcAudioOptions     = rrhsiAudioOptions inputs
    , mrhcOwnerOptions     = rrhsiOwnerOptions inputs
    , mrhcOnEvent          = rrhsiOnEvent inputs
    , mrhcOnRetired        = rrhsiOnRetired inputs
    }


-- | Rollback path when ingress open fails. Only the service has
-- been opened, so cleanup closes just the service.
rollbackIngressOpen
  :: ReloadHostStackOpenIssue ingressIssue
  -> SessionFanInService
  -> IO (Either (ReloadHostStackOpenIssue ingressIssue) a)
rollbackIngressOpen primary service = do
  closeResult <- try @SomeException (closeSessionFanInService service)
  pure $ Left $ case closeResult of
    Left ex ->
      RhsoiPartialCleanupFailed
        primary
        (T.pack ("service close threw: " <> show ex))
    Right () ->
      primary


-- | Rollback path when audio start fails. Both ingress manager
-- and service must be closed; both are attempted regardless of
-- whether an earlier step failed, so a throw from
-- 'closeManifestReloadIngress' cannot leave the service open.
-- The strongest / first diagnostic is surfaced through
-- 'RhsoiPartialCleanupFailed'. Priority order: ingress-close
-- threw, then ingress-close returned 'Left', then service-close
-- threw. If both succeeded, the original 'primary' issue is
-- returned untouched.
rollbackAudioStart
  :: Show ingressIssue
  => ReloadHostStackOpenIssue ingressIssue
  -> SessionFanInService
  -> ManifestReloadIngressManager ManifestReloadIngressTarget ingressIssue handle
  -> IO (Either (ReloadHostStackOpenIssue ingressIssue) a)
rollbackAudioStart primary service ingressManager = do
  ingressResult <- try @SomeException
    (closeManifestReloadIngress ingressManager)
  serviceResult <- try @SomeException
    (closeSessionFanInService service)
  pure $ Left $ case (ingressResult, serviceResult) of
    (Right (Right ()), Right ()) ->
      primary
    (Left ex, _) ->
      RhsoiPartialCleanupFailed
        primary
        (T.pack ("ingress close threw: " <> show ex))
    (Right (Left ingressErr), _) ->
      RhsoiPartialCleanupFailed
        primary
        (T.pack ("ingress close: " <> show ingressErr))
    (_, Left ex) ->
      RhsoiPartialCleanupFailed
        primary
        (T.pack ("service close threw: " <> show ex))


-- | Forward close path used by every supervised route's production
-- ops bundle (wired through 'sahsoClose' / 'pahsoClose' / 'tpahsoClose').
--
-- Reverse order: stop audio → close ingress → close service.
-- Every step is attempted regardless of whether an earlier step
-- threw. The audio-stop + ingress-close 'Left' return values are
-- still swallowed (the adapter has no Either channel to consume
-- them), but exceptions are captured per step so a throw from
-- one step cannot skip the later ones. After all steps run, the
-- first exception encountered is re-thrown — the supervisor
-- adapter wraps the close in @mask_@ and treats the throw as a
-- terminal cleanup failure, which matches the §238 #9 "close
-- before propagation" invariant.
realClose
  :: ReloadHostStack ManifestReloadIngressTarget ingressIssue handle
  -> IO ()
realClose stack = do
  let config = rhsConfig stack
      service = mrhcService config
  audioEx <- attemptUnit $ void $ stopSessionFanInHostAudioFadeWith
    (mrhcAudioFFI config)
    kRealCloseFadeMs
    (sessionFanInServiceHost service)
  ingressEx <- attemptUnit $ void $
    closeManifestReloadIngress (mrhcIngressManager config)
  serviceEx <- attemptUnit $ closeSessionFanInService service
  for_ (listToMaybe (catMaybes [audioEx, ingressEx, serviceEx])) throwIO
  where
    attemptUnit :: IO () -> IO (Maybe SomeException)
    attemptUnit action = do
      r <- try @SomeException action
      pure $ case r of
        Left ex  -> Just ex
        Right () -> Nothing

-- | Phase 8f: linear output fade applied on the host-stack close
-- path to avoid the audible snap that an abrupt callback teardown
-- produces. 'realClose' is the close slot every supervised
-- production route wires through (stopped-audio, preserving, try-
-- preserving) and is also invoked for terminal reload recovery via
-- 'hsfCloseStack'; the fade therefore covers each of those teardowns.
-- In-window reload stop ('hsaroStopOldAudio' / 'hsaroStopNewAudio')
-- remains on the ordinary stop path so reload sequencing is
-- unaffected.
--
-- Sized in the short de-click range — long enough to round the
-- discontinuity, short enough that close still feels immediate.
kRealCloseFadeMs :: Int
kRealCloseFadeMs = 10


-- | Outcome of one supervised stopped-audio manifest reload
-- attempt.
--
-- This is a narrow projection of the supervisor's generic
-- 'SupervisedReloadOutcome' specialized to the
-- 'StoppedAudioHostStackIssue' error surface. Keeping the type
-- narrow at the CLI seam preserves the rebuild cause through
-- the result rather than folding it into a one-shot
-- @Either ManifestReloadHostStrategyIssue ()@ shape that would
-- discard which half (in-window vs rebuild) drove the outcome.
data SupervisedStoppedAudioReloadResult ingressIssue
  = SsasrrCommitted
    -- ^ Requested plan installed end-to-end through the
    -- in-window path; no rebuild needed.
  | SsasrrRebuildRecovered
      !(StoppedAudioHostStackIssue ingressIssue)
    -- ^ Requested plan's in-window reload failed terminally;
    -- the rebuild from the fallback plan succeeded. The host
    -- is now running the fallback plan again. Payload is the
    -- in-window failure that triggered recovery.
  | SsasrrEscalated
      !(StoppedAudioHostStackIssue ingressIssue)
      !(StoppedAudioHostStackIssue ingressIssue)
    -- ^ Both the in-window reload and the rebuild from the
    -- fallback plan failed. The host has no live stack.
    -- Payload is (in-window failure, rebuild failure) in that
    -- order so the supervisor's escalation diagnostics are
    -- preserved through the result.
  deriving stock (Eq, Show)


-- | Drive one supervised stopped-audio manifest reload attempt
-- end-to-end against live session-layer primitives.
--
-- Owns the full stack lifecycle: opens the initial stack via
-- 'mkStoppedAudioHostStackFactory'+'realStoppedAudioHostStackOps'
-- against the supplied @fallback@ plan, brackets it under
-- 'withHostStackSupervisorAdapter', runs 'reloadSupervised'
-- against the @(fallback, requested)@ plan pair, and closes
-- the stack on exit (the adapter's bracket-style cleanup runs
-- whichever stack is active when the continuation exits, even
-- on async exception).
--
-- The initial stack is opened against the @fallback@ plan
-- because the supervisor's contract is that the supplied
-- fallback is the "currently-running plan" at reload entry. If
-- the initial open itself fails (projection-issue, service
-- setup, ingress open, audio start, or a partial-cleanup
-- rollback), the failure surfaces as 'Left' before the
-- supervisor even runs — wrapped in
-- 'StoppedAudioHostStackIssue' for shape uniformity with the
-- supervised path's rebuild issues.
runSupervisedStoppedAudioReload
  :: Show ingressIssue
  => RealReloadHostStackInputs ingressIssue handle
  -> MR.ManifestReloadPlan  -- ^ fallback (currently-running plan)
  -> MR.ManifestReloadPlan  -- ^ requested (new plan)
  -> IO (Either
          (StoppedAudioHostStackIssue ingressIssue)
          (SupervisedStoppedAudioReloadResult ingressIssue))
runSupervisedStoppedAudioReload inputs fallback requested = mask $ \restore -> do
  -- Outer 'mask': closes the async-exception window between
  -- 'hsfOpenStack' returning @Right initialStack@ and
  -- 'withHostStackSupervisorAdapter' installing its own
  -- bracket. Without it, an async exception landing there would
  -- leak the just-opened stack — the helper acquired
  -- session / ingress / audio but no finalizer is in scope yet
  -- to dispose them.
  --
  -- 'restore' is used around the blocking calls so the
  -- caller's masking state is preserved /inside/ them:
  --   * 'hsfOpenStack' itself uses 'mask' + 'restore'
  --     internally (via 'realOpen'); we restore here so its
  --     internal pattern works as designed.
  --   * 'reloadSupervised' is invoked inside the adapter
  --     callback under 'restore' so the supervisor's
  --     'onException' wrappers can fire on async interrupts
  --     and the inner blocking IO is interruptible.
  let ops     = realStoppedAudioHostStackOps inputs
      factory = mkStoppedAudioHostStackFactory ops
  openResult <- restore (hsfOpenStack factory fallback)
  case openResult of
    Left issue ->
      pure (Left issue)
    Right initialStack -> do
      outcome <-
        withHostStackSupervisorAdapter factory initialStack $
          \supOps -> restore (reloadSupervised supOps fallback requested)
      pure $ Right $ case outcome of
        SupervisedReloadCommitted ->
          SsasrrCommitted
        SupervisedReloadRequestRejected _ ->
          -- Unreachable: the stopped-audio path's
          -- 'realStoppedAudioInWindowReload' never produces
          -- 'InWindowReloadRejectedLiveFallback' (audio stops before
          -- reinstall, so there is no "old owner still installed"
          -- branch to surface). If a future change wires a producer
          -- that *can* return that variant through this entrypoint,
          -- this branch should grow a proper 'SupervisedStoppedAudio
          -- ReloadResult' constructor instead of staying an 'error' —
          -- the supervisor's classified contract is not the place to
          -- silently collapse it.
          error
            "runSupervisedStoppedAudioReload: stopped-audio path \
            \produced SupervisedReloadRequestRejected — contract \
            \violation (the path cannot produce \
            \InWindowReloadRejectedLiveFallback by construction)."
        SupervisedReloadRejectedRecovered e ->
          SsasrrRebuildRecovered e
        SupervisedReloadEscalated e1 e2 ->
          SsasrrEscalated e1 e2
