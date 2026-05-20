{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadHostStack
-- Description : Production HostStackFactory for the stopped-audio host path.
--
-- This module composes a producer-supplied open / close pair plus
-- a plan-native in-window reload helper into a
-- 'HostStackFactory MR.ManifestReloadPlan ...' the supervisor
-- adapter can drive. It is the §219 slice 4 prerequisite the
-- supervisor design note named: defining what a "closeable /
-- reopenable host stack" is for the stopped-audio path, without
-- yet routing the existing 'reloadManifestHostWithStrategy' path
-- through 'reloadSupervised'.
--
-- The 'StoppedAudioHostStack' newtype wraps the per-active
-- 'ManifestReloadHostConfig'; plan ownership stays at the
-- supervisor's caller (threaded as @fallback@ on each call).
-- The 'StoppedAudioHostStackOps' record carries the three IO
-- actions a 'HostStackFactory' needs: open / close /
-- in-window-reload. 'realStoppedAudioInWindowReload' is the
-- production wiring for the in-window slot: it drives
-- 'orchestrateHostStoppedAudioReloadWithEvents' directly with
-- @hsaroPreparePlan@ overridden to @const (pure (Right plan))@,
-- so the supervisor's supplied plan is the source of truth at
-- the seam (no silent re-planning from doc/catalog/policy drift).
-- Open / close are left producer-supplied because the real
-- wiring (next slice) needs to choose between mirroring
-- 'withSessionFanInService' as imperative primitives versus
-- promoting it via a worker-thread bracket — that decision is its
-- own contract, parked behind this slice.
--
-- Tests inject fake @sahsoOpen@ / @sahsoClose@ / @sahsoInWindowReload@
-- and verify the factory composes with 'withHostStackSupervisorAdapter'
-- + 'reloadSupervised' across the seven slice-4 scenarios named in
-- the supervisor §238 checklist (success, owner-setup failure
-- recovery, audio-restart recovery, listener/ingress-open recovery,
-- rebuild escalation, no overlapping stacks, async cleanup) plus the
-- A→B→C→D! no-remembered-history regression.
--
-- See notes/2026-05-14-k-host-reload-supervisor.md \xa7219 slice 4.
module MetaSonic.App.ManifestReloadHostStack
  ( StoppedAudioHostStack (..)
  , StoppedAudioHostStackOps (..)
  , StoppedAudioHostStackOpenIssue (..)
  , StoppedAudioHostStackIssue (..)
  , mkStoppedAudioHostStackFactory
  , realStoppedAudioInWindowReload
  ) where

import           Data.Bifunctor                              (first)

import           MetaSonic.App.ManifestReloadHost            (ManifestReloadHostConfig (..),
                                                              manifestReloadHostOps)
import           MetaSonic.App.ManifestReloadHost.Types      (ManifestReloadHostIssue)
import           MetaSonic.App.ManifestReloadOrchestration   (orchestrateHostStoppedAudioReloadWithEvents)
import           MetaSonic.App.ManifestReloadOrchestration.Types
                                                             (HostStoppedAudioReloadIssue,
                                                              HostStoppedAudioReloadOps (..))
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                                             (HostStackFactory (..))
import           MetaSonic.Authoring.Manifest                (AuthoringManifestDoc (..),
                                                              manifestSchemaVersion)
import           MetaSonic.Session.FanIn                     (SessionFanInAudioIssue)
import           MetaSonic.Session.FanInService              (SessionFanInServiceSetupIssue)
import qualified MetaSonic.Session.ManifestReload            as MR


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


-- | Failures from 'sahsoOpen'. Mirrors the three resource-bearing
-- side effects the real wiring will perform (service setup, audio
-- start, listener/producer bracket open) so the supervisor's
-- 'SupervisedReloadEscalated' payload carries actionable diagnostics
-- when both the requested in-window reload AND the rebuild fail.
data StoppedAudioHostStackOpenIssue ingressIssue
  = SahsoiServiceSetupFailed !SessionFanInServiceSetupIssue
    -- ^ 'withSessionFanInService' / its imperative counterpart
    -- rejected the supplied template graph + service options.
  | SahsoiAudioStartFailed !SessionFanInAudioIssue
    -- ^ Audio FFI start returned a non-zero error after the
    -- service was constructed. The producer is responsible for
    -- disposing the service before returning this.
  | SahsoiIngressOpenFailed !ingressIssue
    -- ^ The listener/producer factory rejected the initial open.
    -- The producer is responsible for disposing the service +
    -- audio lifetime before returning this.
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
