{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadPreservingHostStack
-- Description : Preserving-aware host-stack wiring + classification policy.
--
-- Companion to "MetaSonic.App.ManifestReloadHostStack" — same shape,
-- different in-window slot. The stopped-audio module's @realOpen@ /
-- @realClose@ are reused unchanged because they spin up a
-- 'SessionFanInService' + audio + ingress against a plan and tear
-- them down in reverse, which is what the supervisor needs on both
-- initial open and terminal-failure rebuild regardless of route. The
-- preserving lane adds:
--
--   * A new ops record 'PreservingHostStackOps' whose in-window slot
--     returns @InWindowReloadOutcome (HostPreservingReloadIssue ...)@
--     rather than the stopped-audio one.
--   * 'classifyPreservingOutcome' — the policy function that maps
--     each of the 10 'HostPreservingReloadIssue' constructors to one
--     of the three 'InWindowReloadOutcome' variants. The policy
--     decision is documented inline.
--   * 'realPreservingInWindowReload' — production wiring that
--     re-projects old + new ingress targets on every call (mirroring
--     'realStoppedAudioInWindowReload') and overrides the
--     orchestrator's @hproPreparePlan@ with the supervisor's
--     supplied plan.
--   * 'mkPreservingHostStackFactory' — smart constructor producing a
--     'HostStackFactory' the supervisor adapter can drive directly.
--
-- This module is consumed by
-- "MetaSonic.App.ManifestReloadTryPreservingHostStack", which
-- composes 'realPreservingInWindowReload' with
-- 'realStoppedAudioInWindowReload' under the existing
-- 'preservingAllowsStoppedAudioFallback' gate and is the factory
-- that @--manifest-live-reload-demo try-preserving@ now drives.
-- 'realPreservingInWindowReload' is not exposed as a standalone
-- CLI route today — preserving-without-fallback would correspond
-- to @RequirePreserving@, which stays on the direct path until
-- its own migration slice opens.
module MetaSonic.App.ManifestReloadPreservingHostStack
  ( -- * Types
    --
    -- The substrate stack value 'ReloadHostStack', its open-issue ADT
    -- 'ReloadHostStackOpenIssue', and the production-input record
    -- 'RealReloadHostStackInputs' live in
    -- "MetaSonic.App.ManifestReloadHostStack" because the open / close
    -- lifecycle is route-agnostic. Import them from there.
    PreservingHostStackOps (..)
  , PreservingHostStackIssue (..)
    -- * Classification policy
  , classifyPreservingOutcome
    -- * Production wiring
  , realPreservingHostStackOps
  , realPreservingInWindowReload
  , mkPreservingHostStackFactory
  ) where

import           Data.Bifunctor                              (first)

import           MetaSonic.App.ManifestReloadHost            (ManifestReloadHostConfig (..),
                                                              manifestPreservingReloadHostOps)
import           MetaSonic.App.ManifestReloadHost.Types      (ManifestReloadHostIssue (..))
import           MetaSonic.App.ManifestReloadHostStack       (RealReloadHostStackInputs (..),
                                                              ReloadHostStack (..),
                                                              ReloadHostStackOpenIssue,
                                                              realClose, realOpen)
import           MetaSonic.App.ManifestReloadIngressTarget   (ManifestReloadIngressTarget,
                                                              ManifestReloadIngressTargetPolicy,
                                                              manifestReloadIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadOrchestration   (orchestrateHostPreservingReloadWithEvents)
import           MetaSonic.App.ManifestReloadOrchestration.Types
                                                             (HostPreservingReloadIssue (..),
                                                              HostPreservingReloadOps (..))
import           MetaSonic.App.ManifestReloadSupervisor      (InWindowReloadOutcome (..))
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                                             (HostStackFactory (..))
import           MetaSonic.Authoring.Manifest                (AuthoringManifestDoc (..),
                                                              manifestSchemaVersion)
import qualified MetaSonic.Session.ManifestReload            as MR
import           MetaSonic.Session.Queue                     (ProducerId)


-- | Producer-defined slots for the preserving host stack. Mirrors
-- 'MetaSonic.App.ManifestReloadHostStack.StoppedAudioHostStackOps'
-- shape; only the in-window slot's classification machinery differs.
-- The stack value, the open-issue ADT, and the production-input
-- record are reused unchanged from
-- "MetaSonic.App.ManifestReloadHostStack" because the open / close
-- lifecycle is route-agnostic.
data PreservingHostStackOps target ingressIssue handle =
  PreservingHostStackOps
    { pahsoOpen
        :: !(MR.ManifestReloadPlan
              -> IO (Either
                      (ReloadHostStackOpenIssue ingressIssue)
                      (ReloadHostStack target ingressIssue handle)))
      -- ^ Build a fresh stack from the supplied plan. Same contract
      -- as the stopped-audio open: 'Right' means the stack is ready
      -- to serve commands; 'Left' means construction failed
      -- terminally and the producer is responsible for cleaning up
      -- any partial state before returning. Used both on initial
      -- open and on the supervisor's rebuild path against the
      -- captured fallback plan.
    , pahsoClose
        :: !(ReloadHostStack target ingressIssue handle -> IO ())
      -- ^ Dispose a previously-opened stack. Same best-effort
      -- contract as the stopped-audio close: the adapter wraps
      -- this in @mask_@ so the atomic-take-then-close handoff is
      -- uninterruptible.
    , pahsoInWindowReload
        :: !(ReloadHostStack target ingressIssue handle
              -> MR.ManifestReloadPlan
              -> MR.ManifestReloadPlan
              -> IO (InWindowReloadOutcome
                      (HostPreservingReloadIssue
                        (ManifestReloadHostIssue ingressIssue))))
      -- ^ Drive a preserving in-window reload against the
      -- currently-open stack. Takes the @fallback@ plan (the
      -- plan the stack is currently running) followed by the
      -- @requested@ plan. The fallback is forwarded so the
      -- producer can re-derive plan-dependent state at the
      -- reload boundary (e.g. project the currently-bound
      -- ingress target from the fallback) rather than reading
      -- a cached field on the stack.
      --
      -- Unlike the stopped-audio slot, this one classifies the
      -- 'HostPreservingReloadIssue' result into one of the three
      -- 'InWindowReloadOutcome' variants via
      -- 'classifyPreservingOutcome'. The four "resume-ok"
      -- variants (PlanRejected, QuiesceRejected, DrainRejected,
      -- ReloadRejected) become 'InWindowReloadRejectedLiveFallback'
      -- — the stack is still serving the fallback plan and the
      -- supervisor short-circuits without close/rebuild. Everything
      -- else (Terminal drain/reload, ResumeFailed, IngressRestart
      -- Failed) becomes 'InWindowReloadTerminal' and triggers
      -- the supervisor's close + rebuild path.
    }


-- | Unified factory error type. Mirrors 'StoppedAudioHostStackIssue'
-- shape so the supervisor's 'SupervisedReloadEscalated' payload
-- preserves both halves.
data PreservingHostStackIssue ingressIssue
  = PahsiInWindow
      !(HostPreservingReloadIssue
          (ManifestReloadHostIssue ingressIssue))
    -- ^ In-window reload returned a classified non-Committed
    -- outcome. Carries the 'HostPreservingReloadIssue' cause for
    -- either branch:
    --
    -- * Wrapped inside 'SupervisedReloadRequestRejected' when the
    --   classifier produced 'InWindowReloadRejectedLiveFallback'
    --   (stack still serving fallback plan; no rebuild ran).
    -- * Wrapped inside 'SupervisedReloadRejectedRecovered' or
    --   'SupervisedReloadEscalated' when the classifier produced
    --   'InWindowReloadTerminal' (supervisor closed the stack and
    --   rebuilt from the captured fallback plan).
    --
    -- 'mkPreservingHostStackFactory' uses the same 'PahsiInWindow'
    -- constructor for both branches via @fmap PahsiInWindow <$>
    -- pahsoInWindowReload@: the outer @<$>@ lifts through 'IO' and
    -- the inner 'fmap' lifts through the 'Functor' instance on
    -- 'InWindowReloadOutcome', so the cause-payload constructor
    -- tag is route-uniform and the supervisor's outcome variant
    -- communicates the branch.
  | PahsiOpen !(ReloadHostStackOpenIssue ingressIssue)
    -- ^ The rebuild's 'pahsoOpen' against the fallback plan
    -- failed; the supervisor escalates with both causes preserved.
  deriving stock (Eq, Show)


-- | Policy: map a 'HostPreservingReloadIssue' returned by
-- 'orchestrateHostPreservingReloadWithEvents' to an
-- 'InWindowReloadOutcome' the supervisor can act on.
--
-- The supervisor classifier answers "is the current stack still
-- safely serving the fallback plan?" — a different question from
-- 'preservingAllowsStoppedAudioFallback' (which decides whether to
-- run a stopped-audio fallback after a preserving rejection). The
-- two policies share the structural insight that the orchestrator
-- can leave the stack in three observable states after failure
-- (intact, resumed-clean, broken / unknown), but the classifier
-- here is broader: any case where the resume succeeded and the old
-- owner / ingress is back to its pre-reload state is
-- 'RejectedLiveFallback'.
--
-- The 10 'HostPreservingReloadIssue' constructors classify as:
--
-- * 'HpariPlanRejected' → 'RejectedLiveFallback'. @hproPreparePlan@
--   failed before any lifecycle step ran; stack is bit-identical
--   to pre-reload.
-- * 'HpariQuiesceRejected' → 'RejectedLiveFallback'. Quiesce
--   failed but the orchestrator's resume-after-failure path
--   succeeded in reopening old ingress.
-- * 'HpariDrainRejected' → 'RejectedLiveFallback'. Drain reported
--   retryable, then service + old ingress resumed cleanly.
-- * 'HpariReloadRejected' → 'RejectedLiveFallback'. Preserving
--   command rejected without replacing or stopping the old owner;
--   old ingress resumed cleanly. This is the canonical case
--   'preservingAllowsStoppedAudioFallback' uses to permit a
--   stopped-audio fallback in the direct path.
-- * 'HpariQuiesceRejectedResumeFailed' → 'Terminal'. Quiesce
--   failed AND the subsequent resume-old-ingress also failed;
--   ingress is broken.
-- * 'HpariDrainRejectedResumeFailed' → 'Terminal'. Same shape as
--   above but the drain step was the original failure.
-- * 'HpariReloadRejectedResumeFailed' → 'Terminal'. Preserving
--   rejection followed by a failed resume; old owner state
--   unclear and ingress is broken.
-- * 'HpariDrainFailedTerminal' → 'Terminal'. Drain reported
--   terminal up front; the orchestrator did not even attempt
--   resume.
-- * 'HpariReloadFailedTerminal' → 'Terminal'. Preserving command
--   reached a terminal owner/service state — the live graph may
--   already have been mutated.
-- * 'HpariIngressRestartFailed' → 'Terminal'. Preserving command
--   succeeded but reopening the new ingress failed; the new
--   owner is installed without serving ingress.
classifyPreservingOutcome
  :: HostPreservingReloadIssue issue
  -> InWindowReloadOutcome (HostPreservingReloadIssue issue)
classifyPreservingOutcome issue =
  case issue of
    HpariPlanRejected{} ->
      InWindowReloadRejectedLiveFallback issue
    HpariQuiesceRejected{} ->
      InWindowReloadRejectedLiveFallback issue
    HpariDrainRejected{} ->
      InWindowReloadRejectedLiveFallback issue
    HpariReloadRejected{} ->
      InWindowReloadRejectedLiveFallback issue

    HpariQuiesceRejectedResumeFailed{} ->
      InWindowReloadTerminal issue
    HpariDrainRejectedResumeFailed{} ->
      InWindowReloadTerminal issue
    HpariDrainFailedTerminal{} ->
      InWindowReloadTerminal issue
    HpariReloadRejectedResumeFailed{} ->
      InWindowReloadTerminal issue
    HpariReloadFailedTerminal{} ->
      InWindowReloadTerminal issue
    HpariIngressRestartFailed{} ->
      InWindowReloadTerminal issue


-- | Production in-window reload wiring for the preserving lane.
-- Mirrors 'realStoppedAudioInWindowReload's structural guarantees:
--
-- 1. /Plan-native/: the @requested@ plan supplied by the supervisor
--    is the source of truth. The helper drives
--    'orchestrateHostPreservingReloadWithEvents' with
--    @hproPreparePlan@ overridden to @const (pure (Right requested))@,
--    so the orchestrator never silently re-plans from doc / catalog.
--
-- 2. /Target-fresh/: both 'mrhcOldIngressTarget' and
--    'mrhcNewIngressTarget' are re-projected from the @(fallback,
--    requested)@ pair on every call, then patched into a fresh
--    'ManifestReloadHostConfig' before the orchestrator runs. The
--    stack value's cached projection from open-time is never
--    consulted.
--
-- Projection failure surfaces as a synthesized 'HpariPlanRejected'
-- classified through 'classifyPreservingOutcome' as
-- 'RejectedLiveFallback' — no lifecycle step ran, so the stack is
-- still serving the fallback plan and no rebuild is needed.
realPreservingInWindowReload
  :: ProducerId
  -> ManifestReloadIngressTargetPolicy
  -> ReloadHostStack ManifestReloadIngressTarget ingressIssue handle
  -> MR.ManifestReloadPlan
  -> MR.ManifestReloadPlan
  -> IO (InWindowReloadOutcome
          (HostPreservingReloadIssue
            (ManifestReloadHostIssue ingressIssue)))
realPreservingInWindowReload producer policy stack fallback requested =
  case manifestReloadIngressTargetFromPlan policy requested of
    Left _projIssue ->
      pure $ classifyPreservingOutcome $ HpariPlanRejected
        (MrhiPlanning
          (MR.MriUnknownManifestDemo (MR.mrlpDemoKey requested)))
    Right newTarget ->
      case manifestReloadIngressTargetFromPlan policy fallback of
        Left _projIssue ->
          pure $ classifyPreservingOutcome $ HpariPlanRejected
            (MrhiPlanning
              (MR.MriUnknownManifestDemo (MR.mrlpDemoKey fallback)))
        Right oldTarget ->
          let baseConfig = rhsConfig stack
              freshConfig = baseConfig
                { mrhcOldIngressTarget = oldTarget
                , mrhcNewIngressTarget = newTarget
                }
          in liftOrchestratorResult <$>
               orchestrateHostPreservingReloadWithEvents
                 (mrhcOnEvent freshConfig)
                 (planNativeOps freshConfig)
                 syntheticRequest
  where
    liftOrchestratorResult = \case
      Right () -> InWindowReloadCommitted
      Left issue -> classifyPreservingOutcome issue

    -- manifestPreservingReloadHostOps consults doc/catalog only
    -- inside hproPreparePlan; overriding that slot makes both
    -- empty placeholders safe.
    planNativeOps c =
      (manifestPreservingReloadHostOps producer c emptyDoc [])
        { hproPreparePlan = const (pure (Right requested))
        }

    syntheticRequest = MR.ManifestReloadRequest
      { MR.mrrDemoKey        = MR.mrlpDemoKey requested
      , MR.mrrSwapLabel      = MR.mrlpSwapLabel requested
      , MR.mrrResourcePolicy = MR.defaultManifestResourcePolicy
      }

    emptyDoc = AuthoringManifestDoc
      { docSchemaVersion = manifestSchemaVersion
      , docDemos         = []
      }


-- | Production wiring for 'PreservingHostStackOps' against live
-- session-layer primitives.
--
-- Open and close are reused from
-- "MetaSonic.App.ManifestReloadHostStack" unchanged. The in-window
-- slot drives 'realPreservingInWindowReload', which classifies
-- 'HostPreservingReloadIssue' outcomes through
-- 'classifyPreservingOutcome'.
realPreservingHostStackOps
  :: Show ingressIssue
  => ProducerId
  -> RealReloadHostStackInputs ingressIssue handle
  -> PreservingHostStackOps ManifestReloadIngressTarget ingressIssue handle
realPreservingHostStackOps producer inputs = PreservingHostStackOps
  { pahsoOpen           = realOpen inputs
  , pahsoClose          = realClose
  , pahsoInWindowReload =
      realPreservingInWindowReload producer (rrhsiIngressTargetPolicy inputs)
  }


-- | Build a 'HostStackFactory' from a 'PreservingHostStackOps'
-- bundle so the supervisor adapter can drive it through
-- 'withHostStackSupervisorAdapter'. Mirrors
-- 'mkStoppedAudioHostStackFactory'; the only structural difference
-- is the 'InWindowReloadOutcome'-bearing in-window slot.
mkPreservingHostStackFactory
  :: PreservingHostStackOps target ingressIssue handle
  -> HostStackFactory
       MR.ManifestReloadPlan
       (ReloadHostStack target ingressIssue handle)
       (PreservingHostStackIssue ingressIssue)
mkPreservingHostStackFactory ops = HostStackFactory
  { hsfOpenStack      = fmap (first PahsiOpen) . pahsoOpen ops
  , hsfCloseStack     = pahsoClose ops
  , hsfInWindowReload = \stack fallback requested ->
      fmap PahsiInWindow
        <$> pahsoInWindowReload ops stack fallback requested
  }
