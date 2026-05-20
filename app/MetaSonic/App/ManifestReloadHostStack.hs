{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadHostStack
-- Description : Production HostStackFactory for the stopped-audio host path.
--
-- This module composes the existing stopped-audio host reload
-- helpers ('reloadManifestStoppedAudioHostWithEvents') and a
-- producer-supplied open / close pair into a
-- 'HostStackFactory MR.ManifestReloadPlan ...' the supervisor
-- adapter can drive. It is the §219 slice 4 prerequisite the
-- supervisor design note named: defining what a "closeable /
-- reopenable host stack" is for the stopped-audio path, without
-- yet routing the existing 'reloadManifestHostWithStrategy' path
-- through 'reloadSupervised'.
--
-- The 'StoppedAudioHostStack' record bundles the per-active
-- 'ManifestReloadHostConfig' plus the plan currently installed on
-- that config. The 'StoppedAudioHostStackOps' record carries the
-- three IO actions a 'HostStackFactory' needs: open / close /
-- in-window-reload. 'realStoppedAudioInWindowReload' is the
-- production wiring for the in-window slot against the existing
-- helper. Open / close are left producer-supplied because the real
-- wiring (next slice) needs to choose between mirroring
-- 'withSessionFanInService' as imperative primitives versus
-- promoting it via a worker-thread bracket — that decision is its
-- own contract, parked behind this slice.
--
-- Tests inject fake @sahsoOpen@ / @sahsoClose@ / @sahsoInWindowReload@
-- and verify the factory composes with 'withHostStackSupervisorAdapter'
-- + 'reloadSupervised' across the seven scenarios named in the
-- supervisor §238 checklist (success, owner-setup failure recovery,
-- audio-restart recovery, listener/ingress-open recovery, rebuild
-- escalation, no overlapping stacks, async cleanup).
--
-- See notes/2026-05-14-k-host-reload-supervisor.md \xa7219 slice 4.
module MetaSonic.App.ManifestReloadHostStack
  ( StoppedAudioHostStack (..)
  , StoppedAudioHostStackOps (..)
  , StoppedAudioHostStackOpenIssue (..)
  , StoppedAudioHostStackIssue (..)
  , mkStoppedAudioHostStackFactory
  , realStoppedAudioInWindowReload
  , planToManifestReloadRequest
  ) where

import           Data.Bifunctor                              (first)

import           MetaSonic.App.ManifestReloadHost            (ManifestReloadHostConfig,
                                                              reloadManifestStoppedAudioHostWithEvents)
import           MetaSonic.App.ManifestReloadHost.Types      (ManifestReloadHostIssue)
import           MetaSonic.App.ManifestReloadOrchestration.Types
                                                             (HostStoppedAudioReloadIssue)
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                                             (HostStackFactory (..))
import           MetaSonic.Authoring.Manifest                (AuthoringManifestDoc)
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
-- ingress targets, and the event hook). @sahsInstalledPlan@ tracks
-- the plan currently installed on that config — the supervisor's
-- per-call @fallback@ refers to this value when the in-window
-- reload of a NEW plan fails and the supervisor needs to rebuild
-- against the plan that was running at reload entry.
data StoppedAudioHostStack target ingressIssue handle =
  StoppedAudioHostStack
    { sahsConfig        :: !(ManifestReloadHostConfig target ingressIssue handle)
    , sahsInstalledPlan :: !MR.ManifestReloadPlan
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


-- | Production in-window reload wiring against the existing
-- 'reloadManifestStoppedAudioHostWithEvents' helper.
--
-- This is the default value 'sahsoInWindowReload' carries in
-- production: drive the orchestrator against the stack's
-- 'ManifestReloadHostConfig', translating the supervisor's plan
-- argument into a 'ManifestReloadRequest' under the caller's
-- static 'ManifestResourcePolicy'.
--
-- Tests override this slot with a fake to pin specific failure
-- variants without staging real session-layer state.
realStoppedAudioInWindowReload
  :: AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> MR.ManifestResourcePolicy
  -> StoppedAudioHostStack target ingressIssue handle
  -> MR.ManifestReloadPlan
  -> IO (Either
          (HostStoppedAudioReloadIssue
            (ManifestReloadHostIssue ingressIssue))
          ())
realStoppedAudioInWindowReload doc catalog policy stack plan =
  reloadManifestStoppedAudioHostWithEvents
    (sahsConfig stack)
    doc
    catalog
    (planToManifestReloadRequest policy plan)


-- | Translate a 'ManifestReloadPlan' back into a
-- 'ManifestReloadRequest' suitable for
-- 'reloadManifestStoppedAudioHostWithEvents'. The supervisor's
-- 'plan' value is the source of truth for demo key + swap label;
-- the resource policy is a caller-supplied static, since plans
-- don't carry it after planning.
planToManifestReloadRequest
  :: MR.ManifestResourcePolicy
  -> MR.ManifestReloadPlan
  -> MR.ManifestReloadRequest
planToManifestReloadRequest policy plan = MR.ManifestReloadRequest
  { MR.mrrDemoKey        = MR.mrlpDemoKey plan
  , MR.mrrSwapLabel      = MR.mrlpSwapLabel plan
  , MR.mrrResourcePolicy = policy
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
  { hsfOpenStack = \plan ->
      fmap (first SahsiOpen) (sahsoOpen ops plan)
  , hsfCloseStack = sahsoClose ops
  , hsfInWindowReload = \stack plan ->
      fmap (first SahsiInWindow) (sahsoInWindowReload ops stack plan)
  }
