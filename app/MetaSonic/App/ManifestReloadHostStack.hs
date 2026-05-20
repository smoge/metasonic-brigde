{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeApplications   #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadHostStack
-- Description : Production HostStackFactory for the stopped-audio host path.
--
-- This module composes the production open / close / in-window
-- primitives into a 'HostStackFactory MR.ManifestReloadPlan ...'
-- the supervisor adapter can drive. It is the §219 slice 4
-- prerequisite the supervisor design note named: defining what a
-- "closeable / reopenable host stack" is for the stopped-audio
-- path. The next slice (step 4) routes
-- 'reloadManifestHostWithStrategy' / @StoppedAudioOnly@ through
-- this factory + 'reloadSupervised'.
--
-- The 'StoppedAudioHostStack' newtype wraps the per-active
-- 'ManifestReloadHostConfig'; plan ownership stays at the
-- supervisor's caller (threaded as @fallback@ on each call).
-- The 'StoppedAudioHostStackOps' record carries the three IO
-- actions a 'HostStackFactory' needs: open / close /
-- in-window-reload.
--
-- 'realStoppedAudioHostStackOps' is the production wiring for
-- open / close. It opens the imperative
-- 'openSessionFanInServiceHooks' primitive (added in step 1 to
-- avoid promoting the bracket via a worker thread), projects the
-- ingress target from the plan, opens ingress, then starts audio
-- in that order; close runs in reverse. Partial-cleanup failures
-- during rollback are surfaced through
-- 'SahsoiPartialCleanupFailed' so the supervisor can escalate
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
  ( StoppedAudioHostStack (..)
  , StoppedAudioHostStackOps (..)
  , StoppedAudioHostStackOpenIssue (..)
  , StoppedAudioHostStackIssue (..)
  , mkStoppedAudioHostStackFactory
  , realStoppedAudioInWindowReload
  , RealStoppedAudioHostStackInputs (..)
  , realStoppedAudioHostStackOps
  ) where

import           Control.Exception                           (SomeException,
                                                              try)
import           Control.Monad                               (void)
import           Data.Bifunctor                              (first)
import           Data.Text                                   (Text)
import qualified Data.Text                                   as T

import           MetaSonic.App.ManifestReloadEvent           (ManifestReloadEvent)
import           MetaSonic.App.ManifestReloadHost            (ManifestReloadHostConfig (..),
                                                              manifestReloadHostOps)
import           MetaSonic.App.ManifestReloadHost.Types      (ManifestReloadHostIssue)
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
                                                             (HostStoppedAudioReloadIssue,
                                                              HostStoppedAudioReloadOps (..))
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                                             (HostStackFactory (..))
import           MetaSonic.Authoring.Manifest                (AuthoringManifestDoc (..),
                                                              manifestSchemaVersion)
import           MetaSonic.Session.FanIn                     (SessionFanInAudioFFI,
                                                              SessionFanInAudioIssue,
                                                              SessionFanInAudioOptions,
                                                              startSessionFanInHostAudioWith,
                                                              stopSessionFanInHostAudioWith)
import           MetaSonic.Session.FanInService              (SessionFanInService,
                                                              SessionFanInServiceHooks,
                                                              SessionFanInServiceOptions,
                                                              SessionFanInServiceSetupIssue,
                                                              closeSessionFanInService,
                                                              openSessionFanInServiceHooks,
                                                              sessionFanInServiceHost)
import qualified MetaSonic.Session.ManifestReload            as MR
import           MetaSonic.Session.Owner                     (SessionOwnerOptions)


-- | The runtime objects that constitute one active stopped-audio
-- host stack. Built fresh on each 'sahsoOpen'; torn down by
-- 'sahsoClose'. The supervisor adapter holds exactly one of these
-- in its IORef at any time.
--
-- @sahsConfig@ carries the live runtime references (the
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
newtype StoppedAudioHostStack target ingressIssue handle =
  StoppedAudioHostStack
    { sahsConfig :: ManifestReloadHostConfig target ingressIssue handle
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
                      (StoppedAudioHostStackOpenIssue ingressIssue)
                      (StoppedAudioHostStack target ingressIssue handle)))
      -- ^ Build a fresh stack from the supplied plan. Per the
      -- 'HostStackFactory' contract the producer must clean up any
      -- partial state before returning 'Left'; the supervisor
      -- adapter calls this only on the rebuild path against the
      -- captured fallback plan.
    , sahsoClose
        :: !(StoppedAudioHostStack target ingressIssue handle -> IO ())
      -- ^ Dispose a previously-opened stack: close ingress, stop
      -- audio, dispose the SessionFanInService and its host
      -- bracket. Best-effort; the supervisor adapter wraps the
      -- close path in 'mask_' so the atomic-take-then-close
      -- handoff is uninterruptible.
    , sahsoInWindowReload
        :: !(StoppedAudioHostStack target ingressIssue handle
              -> MR.ManifestReloadPlan
              -> IO (Either
                      (HostStoppedAudioReloadIssue
                        (ManifestReloadHostIssue ingressIssue))
                      ()))
      -- ^ Drive a stopped-audio in-window reload against the
      -- currently-open stack. Production wires
      -- 'realStoppedAudioInWindowReload'; tests can return any
      -- specific failure variant.
    }


-- | Failures from 'sahsoOpen'. Mirrors the five resource-bearing
-- side effects the production wiring performs (target projection,
-- service setup, ingress open, audio start, and partial-cleanup
-- rollback) so the supervisor's 'SupervisedReloadEscalated' payload
-- carries actionable diagnostics when both the requested in-window
-- reload AND the rebuild fail.
data StoppedAudioHostStackOpenIssue ingressIssue
  = SahsoiServiceSetupFailed !SessionFanInServiceSetupIssue
    -- ^ 'openSessionFanInService' (or its bracketed counterpart)
    -- rejected the supplied template graph + service options. No
    -- resources were acquired; no rollback is needed.
  | SahsoiAudioStartFailed !SessionFanInAudioIssue
    -- ^ Audio FFI start returned a non-zero error after the
    -- service and ingress were already constructed. The producer
    -- is responsible for disposing the service + ingress before
    -- returning this.
  | SahsoiIngressOpenFailed !ingressIssue
    -- ^ The listener/producer factory rejected the initial open.
    -- The producer is responsible for disposing the service
    -- before returning this.
  | SahsoiIngressTargetProjectionFailed !ManifestMIDIProjectionIssue
    -- ^ 'manifestReloadIngressTargetFromPlan' rejected the
    -- supplied plan (duplicate MIDI CC mapping in the projection
    -- table). No resources were acquired; no rollback is needed.
  | SahsoiPartialCleanupFailed
      !(StoppedAudioHostStackOpenIssue ingressIssue)
      !Text
    -- ^ A primary open failure triggered a rollback that itself
    -- failed (close-ingress returned 'Left', stop-audio threw,
    -- service close threw). Carries the primary issue plus a
    -- textual display of the rollback diagnostic. The supervisor
    -- must escalate to 'SupervisedReloadEscalated' on this — the
    -- stack is in an unknown partial state and a clean rebuild is
    -- the only safe recovery. The primary issue is never itself a
    -- 'SahsoiPartialCleanupFailed' (rollback failures from a
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
  | SahsiOpen !(StoppedAudioHostStackOpenIssue ingressIssue)
    -- ^ The rebuild's 'sahsoOpen' against the fallback plan
    -- failed; the supervisor escalates with both causes preserved.
  deriving stock (Eq, Show)


-- | Production in-window reload wiring, plan-native.
--
-- The supervisor's 'plan' argument is the source of truth: it has
-- already been validated by the caller. This helper drives the
-- existing 'orchestrateHostStoppedAudioReloadWithEvents' against
-- the stack's 'ManifestReloadHostConfig' with the orchestrator's
-- @hsaroPreparePlan@ slot overridden to
-- @const (pure (Right plan))@, so the orchestrator installs the
-- exact plan the supervisor handed in.
--
-- The naive shape that calls 'reloadManifestStoppedAudioHostWithEvents'
-- (which re-derives a plan from doc + catalog + the supplied
-- request) would let doc / catalog / static resource-policy drift
-- between the caller's validation step and the supervisor's
-- invocation: a plan validated at time T could be rejected at
-- T+1, or worse, silently swapped for a different demo. Going
-- through @hsaroPreparePlan = const (pure (Right plan))@ pins
-- "install this exact plan" at the seam.
--
-- The request value passed to the orchestrator is synthesized
-- from the plan for ergonomics (operator-facing event payloads
-- carry the demo key + swap label) but the orchestrator never
-- consults it for planning — the override short-circuits that.
-- The 'AuthoringManifestDoc' / catalog handed into
-- 'manifestReloadHostOps' are also unused after the override;
-- empty placeholders flow through to slots the supervisor never
-- forces.
--
-- Tests override 'sahsoInWindowReload' with a fake to pin
-- specific 'HostStoppedAudioReloadIssue' variants without
-- staging real session-layer state.
realStoppedAudioInWindowReload
  :: StoppedAudioHostStack target ingressIssue handle
  -> MR.ManifestReloadPlan
  -> IO (Either
          (HostStoppedAudioReloadIssue
            (ManifestReloadHostIssue ingressIssue))
          ())
realStoppedAudioInWindowReload stack plan =
  orchestrateHostStoppedAudioReloadWithEvents
    (mrhcOnEvent config)
    planNativeOps
    syntheticRequest
  where
    config = sahsConfig stack

    -- manifestReloadHostOps builds the orchestrator slot bundle
    -- using doc/catalog only inside hsaroPreparePlan; overriding
    -- that slot makes doc/catalog dead inputs, so empty
    -- placeholders flow safely through.
    planNativeOps =
      (manifestReloadHostOps config emptyDoc [])
        { hsaroPreparePlan = const (pure (Right plan))
        }

    -- Synthesized for event-payload ergonomics; not consulted by
    -- the overridden preparePlan slot.
    syntheticRequest = MR.ManifestReloadRequest
      { MR.mrrDemoKey        = MR.mrlpDemoKey plan
      , MR.mrrSwapLabel      = MR.mrlpSwapLabel plan
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
       (StoppedAudioHostStack target ingressIssue handle)
       (StoppedAudioHostStackIssue ingressIssue)
mkStoppedAudioHostStackFactory ops = HostStackFactory
  { hsfOpenStack      = fmap (first SahsiOpen) . sahsoOpen ops
  , hsfCloseStack     = sahsoClose ops
  , hsfInWindowReload = \stack plan ->
      fmap (first SahsiInWindow) (sahsoInWindowReload ops stack plan)
  }


-- | Producer-supplied inputs for the production
-- 'StoppedAudioHostStackOps'.
--
-- These are the dependencies the production helper cannot derive
-- from the supervisor's plan alone: the ingress ops bundle (OSC or
-- MIDI, with its own listener config baked in), the ingress target
-- projection policy, the audio FFI bundle, audio + service +
-- owner options, and the per-active event sink.
--
-- The supervisor adapter holds one of these for the lifetime of the
-- supervised process; the helper closes over them when building the
-- 'StoppedAudioHostStackOps' record. The 'target' parameter is
-- locked to 'ManifestReloadIngressTarget' because the projection
-- helper only knows about that type; the @ingressIssue@ and @handle@
-- parameters stay polymorphic so OSC and MIDI ingress factories can
-- both reuse the helper.
data RealStoppedAudioHostStackInputs ingressIssue handle =
  RealStoppedAudioHostStackInputs
    { rsahsiIngressOps
        :: !(ManifestReloadIngressOps ManifestReloadIngressTarget ingressIssue handle)
    , rsahsiIngressTargetPolicy
        :: !ManifestReloadIngressTargetPolicy
    , rsahsiAudioFFI
        :: !SessionFanInAudioFFI
    , rsahsiAudioOptions
        :: !SessionFanInAudioOptions
    , rsahsiOwnerOptions
        :: !SessionOwnerOptions
    , rsahsiServiceOptions
        :: !SessionFanInServiceOptions
    , rsahsiServiceHooks
        :: !SessionFanInServiceHooks
    , rsahsiOnEvent
        :: !(ManifestReloadEvent (ManifestReloadHostIssue ingressIssue) -> IO ())
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
-- primary issue is wrapped in 'SahsoiPartialCleanupFailed' with a
-- textual rollback diagnostic. The supervisor escalates on that
-- variant; a clean rebuild is the only safe recovery.
--
-- The in-window reload slot is wired to
-- 'realStoppedAudioInWindowReload' so the supervisor's supplied
-- plan is the source of truth (no silent re-planning).
realStoppedAudioHostStackOps
  :: Show ingressIssue
  => RealStoppedAudioHostStackInputs ingressIssue handle
  -> StoppedAudioHostStackOps ManifestReloadIngressTarget ingressIssue handle
realStoppedAudioHostStackOps inputs = StoppedAudioHostStackOps
  { sahsoOpen           = realOpen inputs
  , sahsoClose          = realClose
  , sahsoInWindowReload = realStoppedAudioInWindowReload
  }


-- | Forward open path for 'realStoppedAudioHostStackOps'.
realOpen
  :: Show ingressIssue
  => RealStoppedAudioHostStackInputs ingressIssue handle
  -> MR.ManifestReloadPlan
  -> IO (Either
          (StoppedAudioHostStackOpenIssue ingressIssue)
          (StoppedAudioHostStack ManifestReloadIngressTarget ingressIssue handle))
realOpen inputs plan =
  case manifestReloadIngressTargetFromPlan
         (rsahsiIngressTargetPolicy inputs)
         plan of
    Left projIssue ->
      pure (Left (SahsoiIngressTargetProjectionFailed projIssue))
    Right target -> do
      serviceResult <- openSessionFanInServiceHooks
        (rsahsiServiceHooks inputs)
        (MR.mrlpTemplateGraph plan)
        (rsahsiServiceOptions inputs)
      case serviceResult of
        Left issue ->
          pure (Left (SahsoiServiceSetupFailed issue))
        Right service -> do
          ingressResult <- mrioOpenIngress
            (rsahsiIngressOps inputs)
            target
          case ingressResult of
            Left issue ->
              rollbackIngressOpen
                (SahsoiIngressOpenFailed issue)
                service
            Right initialHandle -> do
              ingressManager <- newManifestReloadIngressManager
                (rsahsiIngressOps inputs)
                target
                initialHandle
              audioResult <- startSessionFanInHostAudioWith
                (rsahsiAudioFFI inputs)
                (sessionFanInServiceHost service)
                (rsahsiAudioOptions inputs)
              case audioResult of
                Left issue ->
                  rollbackAudioStart
                    (SahsoiAudioStartFailed issue)
                    service
                    ingressManager
                Right () ->
                  pure $ Right (mkStack inputs target service ingressManager)


-- | Build the 'StoppedAudioHostStack' value from a fully-acquired
-- resource set. Both 'mrhcOldIngressTarget' and 'mrhcNewIngressTarget'
-- carry the projection of the install-time plan; the supervisor
-- routing slice (step 4) is responsible for re-projecting both on
-- each subsequent in-window reload so a cached @newTarget@ cannot
-- drift away from the supervisor's current plan.
mkStack
  :: RealStoppedAudioHostStackInputs ingressIssue handle
  -> ManifestReloadIngressTarget
  -> SessionFanInService
  -> ManifestReloadIngressManager ManifestReloadIngressTarget ingressIssue handle
  -> StoppedAudioHostStack ManifestReloadIngressTarget ingressIssue handle
mkStack inputs target service ingressManager = StoppedAudioHostStack
  ManifestReloadHostConfig
    { mrhcService          = service
    , mrhcIngressManager   = ingressManager
    , mrhcOldIngressTarget = target
    , mrhcNewIngressTarget = target
    , mrhcAudioFFI         = rsahsiAudioFFI inputs
    , mrhcAudioOptions     = rsahsiAudioOptions inputs
    , mrhcOwnerOptions     = rsahsiOwnerOptions inputs
    , mrhcOnEvent          = rsahsiOnEvent inputs
    }


-- | Rollback path when ingress open fails. Only the service has
-- been opened, so cleanup closes just the service.
rollbackIngressOpen
  :: StoppedAudioHostStackOpenIssue ingressIssue
  -> SessionFanInService
  -> IO (Either (StoppedAudioHostStackOpenIssue ingressIssue) a)
rollbackIngressOpen primary service = do
  closeResult <- try @SomeException (closeSessionFanInService service)
  pure $ Left $ case closeResult of
    Left ex ->
      SahsoiPartialCleanupFailed
        primary
        (T.pack ("service close threw: " <> show ex))
    Right () ->
      primary


-- | Rollback path when audio start fails. Both ingress manager and
-- service must be closed; ingress manager close is itself Either,
-- so a 'Left' from it surfaces through the cleanup-display.
rollbackAudioStart
  :: Show ingressIssue
  => StoppedAudioHostStackOpenIssue ingressIssue
  -> SessionFanInService
  -> ManifestReloadIngressManager ManifestReloadIngressTarget ingressIssue handle
  -> IO (Either (StoppedAudioHostStackOpenIssue ingressIssue) a)
rollbackAudioStart primary service ingressManager = do
  result <- try @SomeException $ do
    ingressClosed <- closeManifestReloadIngress ingressManager
    closeSessionFanInService service
    pure ingressClosed
  pure $ Left $ case result of
    Left ex ->
      SahsoiPartialCleanupFailed
        primary
        (T.pack ("rollback threw: " <> show ex))
    Right (Left ingressErr) ->
      SahsoiPartialCleanupFailed
        primary
        (T.pack ("ingress close: " <> show ingressErr))
    Right (Right ()) ->
      primary


-- | Forward close path for 'realStoppedAudioHostStackOps'.
--
-- Reverse order: stop audio → close ingress → close service. Each
-- step's failure is best-effort (the supervisor adapter wraps the
-- whole close in @mask_@); a partial close is acceptable because
-- the supervisor will not reuse the stack. The audio-stop +
-- ingress-close 'Left' values are discarded here; if a future
-- contract needs to surface them, do so by extending the close
-- helper, not by adding a clean-close 'Either' channel that
-- existing callers would need to thread through.
realClose
  :: StoppedAudioHostStack ManifestReloadIngressTarget ingressIssue handle
  -> IO ()
realClose stack = do
  let config = sahsConfig stack
  _ <- stopSessionFanInHostAudioWith
         (mrhcAudioFFI config)
         (sessionFanInServiceHost (mrhcService config))
  void (closeManifestReloadIngress (mrhcIngressManager config))
  closeSessionFanInService (mrhcService config)
