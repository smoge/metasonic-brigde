{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadTryPreservingHostStack
-- Description : Try-preserving (preserving-then-stopped-audio) supervised host-stack wiring.
--
-- The supervised counterpart to the direct-path
-- 'TryPreservingThenStoppedAudio' strategy implemented in
-- 'runReloadHostStrategyWithEvents'. Composes the preserving and
-- stopped-audio in-window helpers under a single 'HostStackFactory'
-- so the supervisor sees one in-window slot and one classified
-- 'InWindowReloadOutcome', while the slot internally:
--
--   1. runs 'realPreservingInWindowReload';
--   2. on a preserving 'InWindowReloadRejectedLiveFallback' whose
--      cause is fallback-eligible per
--      'preservingAllowsStoppedAudioFallback', emits
--      'MreFallbackAdmitted', runs 'realStoppedAudioInWindowReload'
--      against the same stack, and composes the outcome;
--   3. on a preserving 'InWindowReloadRejectedLiveFallback' whose
--      cause is /not/ fallback-eligible, emits
--      'MreFallbackDeclined' and surfaces the preserving cause as
--      a request-rejected outcome (stack stays serving the
--      fallback plan, no rebuild);
--   4. passes preserving 'InWindowReloadTerminal' through as a
--      terminal cause (supervisor closes + rebuilds).
--
-- The decision logic and the fallback-result composition are
-- factored into two pure helpers ('decideTryPreservingNext' and
-- 'composeFallbackOutcome') so the gate policy is testable as a
-- table against every 'HostPreservingReloadIssue' constructor
-- without staging real session state.
--
-- The open and close paths are reused unchanged from
-- "MetaSonic.App.ManifestReloadHostStack" — both preserving and
-- stopped-audio routes need the same audio-bearing lifecycle
-- (open service + audio + ingress; close in reverse). The
-- 'StoppedAudio'-prefixed names exposed by that module are
-- aliased here under neutral 'TryPreserving'-prefixed names.
--
-- Strategy-level events ('MreStrategyStarted',
-- 'MreStrategySucceeded', 'MreStrategyFailed') are NOT emitted
-- from this module — the route layer owns those, mirroring the
-- direct path's separation between
-- 'runReloadHostStrategyWithEvents' (which emits strategy frame
-- events) and the underlying phase actions (which emit phase
-- events). This module emits only the two fallback decision
-- events 'MreFallbackAdmitted' and 'MreFallbackDeclined' because
-- the decision is local to the in-window composition.
--
-- Routing: 'selectLiveReloadRoute' still maps
-- @TryPreservingThenStoppedAudio@ to the direct path. The flip
-- onto this factory lands in the step-4 slice, gated on tier-2
-- marker-clean runs per
-- notes\/2026-05-20-a-supervised-route-tier3-decision.md.
module MetaSonic.App.ManifestReloadTryPreservingHostStack
  ( -- * Types
    TryPreservingHostStack
  , TryPreservingHostStackOpenIssue
  , TryPreservingHostStackOps (..)
  , TryPreservingHostStackIssue (..)
  , TryPreservingInWindowIssue (..)
  , RealTryPreservingHostStackInputs
    -- * Pure cores (testable without IO)
  , TryPreservingNext (..)
  , decideTryPreservingNext
  , composeFallbackOutcome
    -- * Production wiring
  , realTryPreservingHostStackOps
  , realTryPreservingInWindowReload
  , mkTryPreservingHostStackFactory
  ) where

import           Data.Bifunctor                              (first)

import           MetaSonic.App.ManifestReloadEvent           (ManifestReloadEvent (..))
import           MetaSonic.App.ManifestReloadHost            (preservingAllowsStoppedAudioFallback)
import           MetaSonic.App.ManifestReloadHost.Types      (ManifestReloadHostIssue)
import           MetaSonic.App.ManifestReloadHostStack       (RealStoppedAudioHostStackInputs (..),
                                                              StoppedAudioHostStack (..),
                                                              StoppedAudioHostStackOpenIssue,
                                                              realClose, realOpen,
                                                              realStoppedAudioInWindowReload)
import           MetaSonic.App.ManifestReloadIngressTarget   (ManifestReloadIngressTarget,
                                                              ManifestReloadIngressTargetPolicy)
import           MetaSonic.App.ManifestReloadOrchestration.Types
                                                             (HostPreservingReloadIssue,
                                                              HostStoppedAudioReloadIssue)
import           MetaSonic.App.ManifestReloadPreservingHostStack
                                                             (realPreservingInWindowReload)
import           MetaSonic.App.ManifestReloadSupervisor      (InWindowReloadOutcome (..))
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                                             (HostStackFactory (..))
import qualified MetaSonic.Session.ManifestReload            as MR
import           MetaSonic.Session.Queue                     (ProducerId)


-- | Stack value the supervisor adapter threads through try-preserving
-- reloads. Same shape as 'StoppedAudioHostStack' (and as
-- 'PreservingHostStack'); the underlying value is just a newtype
-- around 'ManifestReloadHostConfig'.
type TryPreservingHostStack = StoppedAudioHostStack


-- | Open-time failure variants. Same shape as the stopped-audio
-- equivalent because the open path is shared.
type TryPreservingHostStackOpenIssue = StoppedAudioHostStackOpenIssue


-- | Inputs to 'realTryPreservingHostStackOps'. Aliased to the
-- stopped-audio inputs record because the open / close machinery is
-- route-agnostic.
type RealTryPreservingHostStackInputs = RealStoppedAudioHostStackInputs


-- | Discriminated cause for the try-preserving in-window slot.
--
-- Each constructor identifies a distinct supervisor branch:
--
--   * 'TpiwiPreservingFallbackDeclined' — preserving rejected with
--     a 'RejectedLiveFallback'-classified cause that is not
--     fallback-eligible. The stack is still safely serving the
--     fallback plan. Surfaces through
--     'SupervisedReloadRequestRejected'; no rebuild.
--   * 'TpiwiPreservingTerminal' — preserving classified the
--     outcome as 'InWindowReloadTerminal'. The supervisor closes
--     the stack and rebuilds from the captured fallback plan.
--   * 'TpiwiFallbackStoppedAudioFailed' — preserving rejection
--     admitted fallback; the subsequent stopped-audio in-window
--     reload itself failed terminally. Carries both halves so
--     escalation diagnostics preserve "what preserving did" AND
--     "what stopped-audio did" — mirror of the direct path's
--     'MrhsiFallbackStoppedAudioFailed'.
data TryPreservingInWindowIssue ingressIssue
  = TpiwiPreservingFallbackDeclined
      !(HostPreservingReloadIssue (ManifestReloadHostIssue ingressIssue))
  | TpiwiPreservingTerminal
      !(HostPreservingReloadIssue (ManifestReloadHostIssue ingressIssue))
  | TpiwiFallbackStoppedAudioFailed
      !(HostPreservingReloadIssue (ManifestReloadHostIssue ingressIssue))
      !(HostStoppedAudioReloadIssue (ManifestReloadHostIssue ingressIssue))
  deriving stock (Eq, Show)


-- | Producer-defined slots for the try-preserving host stack.
-- Mirrors 'StoppedAudioHostStackOps' / 'PreservingHostStackOps'
-- shape with the in-window slot returning the combined
-- 'TryPreservingInWindowIssue' cause.
data TryPreservingHostStackOps target ingressIssue handle =
  TryPreservingHostStackOps
    { tpahsoOpen
        :: !(MR.ManifestReloadPlan
              -> IO (Either
                      (TryPreservingHostStackOpenIssue ingressIssue)
                      (TryPreservingHostStack target ingressIssue handle)))
      -- ^ Build a fresh stack from the supplied plan. Same
      -- contract as the other two routes' open slots.
    , tpahsoClose
        :: !(TryPreservingHostStack target ingressIssue handle -> IO ())
      -- ^ Dispose a previously-opened stack. Best-effort under
      -- 'mask_' per the adapter contract.
    , tpahsoInWindowReload
        :: !(TryPreservingHostStack target ingressIssue handle
              -> MR.ManifestReloadPlan
              -> MR.ManifestReloadPlan
              -> IO (InWindowReloadOutcome
                      (TryPreservingInWindowIssue ingressIssue)))
      -- ^ Drive a try-preserving in-window reload against the
      -- currently-open stack. Internally runs preserving first
      -- and, on an admitted-fallback outcome, runs stopped-audio.
      -- The combined 'TryPreservingInWindowIssue' cause records
      -- which branch fired.
    }


-- | Unified factory error type. Mirrors
-- 'StoppedAudioHostStackIssue' / 'PreservingHostStackIssue'.
data TryPreservingHostStackIssue ingressIssue
  = TpahsiInWindow
      !(TryPreservingInWindowIssue ingressIssue)
    -- ^ In-window reload returned a classified non-Committed
    -- outcome. Carries the discriminated 'TryPreservingInWindow
    -- Issue' (see its Haddock for the three sub-branches).
  | TpahsiOpen !(TryPreservingHostStackOpenIssue ingressIssue)
    -- ^ The rebuild's 'tpahsoOpen' against the fallback plan
    -- failed; the supervisor escalates with both causes
    -- preserved.
  deriving stock (Eq, Show)


-- | Pure decision: given the classified preserving outcome, what
-- should the try-preserving in-window slot do next? The IO side
-- ('realTryPreservingInWindowReload') drives the decision but the
-- gate logic itself is pure and table-tested.
data TryPreservingNext ingressIssue
  = TpnCommitted
    -- ^ Preserving committed; no fallback needed.
  | TpnRunFallback
      !(HostPreservingReloadIssue (ManifestReloadHostIssue ingressIssue))
    -- ^ Preserving rejected with a fallback-eligible cause; run
    -- stopped-audio next. The cause is carried so the
    -- @MreFallbackAdmitted@ event payload and any subsequent
    -- 'TpiwiFallbackStoppedAudioFailed' payload have the right
    -- preserving issue.
  | TpnDeclineFallback
      !(HostPreservingReloadIssue (ManifestReloadHostIssue ingressIssue))
    -- ^ Preserving rejected with a 'RejectedLiveFallback' cause
    -- that is /not/ fallback-eligible per
    -- 'preservingAllowsStoppedAudioFallback'. Stack is still live;
    -- supervisor returns request-rejected.
  | TpnTerminal
      !(HostPreservingReloadIssue (ManifestReloadHostIssue ingressIssue))
    -- ^ Preserving failed terminally; supervisor closes + rebuilds.
  deriving stock (Eq, Show)


-- | Decide the next step from a preserving outcome.
--
-- The four 'HostPreservingReloadIssue' constructors classified as
-- 'InWindowReloadRejectedLiveFallback' by 'classifyPreservingOutcome'
-- (PlanRejected, QuiesceRejected, DrainRejected, ReloadRejected)
-- arrive here through the @RejectedLiveFallback@ arm. The
-- conservative 'preservingAllowsStoppedAudioFallback' gate then
-- decides whether to admit a stopped-audio fallback for each:
-- today only 'HpariReloadRejected' admits; the other three are
-- live-stack survivors but the direct path declines fallback
-- because there is no stronger guarantee for them. This module
-- preserves that direct-path policy verbatim — broadening the gate
-- would diverge from "preserve current behavior" and needs its
-- own decision slice.
decideTryPreservingNext
  :: InWindowReloadOutcome
       (HostPreservingReloadIssue (ManifestReloadHostIssue ingressIssue))
  -> TryPreservingNext ingressIssue
decideTryPreservingNext = \case
  InWindowReloadCommitted ->
    TpnCommitted
  InWindowReloadRejectedLiveFallback issue
    | preservingAllowsStoppedAudioFallback issue ->
        TpnRunFallback issue
    | otherwise ->
        TpnDeclineFallback issue
  InWindowReloadTerminal issue ->
    TpnTerminal issue


-- | Pure composition of a preserving issue + the stopped-audio
-- fallback's outcome into the final try-preserving outcome.
--
-- Stopped-audio cannot produce 'InWindowReloadRejectedLiveFallback'
-- by construction (audio stops before reinstall, no "old owner
-- still installed" branch). That arm is an internal contract
-- violation — surfaced as an 'error' rather than a silent
-- default — matching how
-- 'MetaSonic.App.ManifestReloadHostStack.runSupervisedStoppedAudioReload'
-- handles the same impossibility.
composeFallbackOutcome
  :: HostPreservingReloadIssue (ManifestReloadHostIssue ingressIssue)
  -> InWindowReloadOutcome
       (HostStoppedAudioReloadIssue (ManifestReloadHostIssue ingressIssue))
  -> InWindowReloadOutcome (TryPreservingInWindowIssue ingressIssue)
composeFallbackOutcome preservingIssue = \case
  InWindowReloadCommitted ->
    InWindowReloadCommitted
  InWindowReloadTerminal stoppedIssue ->
    InWindowReloadTerminal
      (TpiwiFallbackStoppedAudioFailed preservingIssue stoppedIssue)
  InWindowReloadRejectedLiveFallback _ ->
    error
      "composeFallbackOutcome: stopped-audio fallback produced \
      \InWindowReloadRejectedLiveFallback — contract violation \
      \(the stopped-audio path cannot return that variant)."


-- | Production in-window reload wiring for the try-preserving
-- lane. Composes 'realPreservingInWindowReload' with
-- 'realStoppedAudioInWindowReload' under the pure decision rule
-- 'decideTryPreservingNext'. Emits 'MreFallbackAdmitted' /
-- 'MreFallbackDeclined' for the fallback decision; the route layer
-- emits 'MreStrategy*'.
realTryPreservingInWindowReload
  :: Show ingressIssue
  => (ManifestReloadEvent (ManifestReloadHostIssue ingressIssue) -> IO ())
  -> ProducerId
  -> ManifestReloadIngressTargetPolicy
  -> TryPreservingHostStack ManifestReloadIngressTarget ingressIssue handle
  -> MR.ManifestReloadPlan
  -> MR.ManifestReloadPlan
  -> IO (InWindowReloadOutcome
          (TryPreservingInWindowIssue ingressIssue))
realTryPreservingInWindowReload onEvent producer policy stack fallback requested = do
  preservingOutcome <-
    realPreservingInWindowReload producer policy stack fallback requested
  case decideTryPreservingNext preservingOutcome of
    TpnCommitted ->
      pure InWindowReloadCommitted
    TpnRunFallback preservingIssue -> do
      onEvent (MreFallbackAdmitted preservingIssue)
      stoppedOutcome <-
        realStoppedAudioInWindowReload policy stack fallback requested
      pure (composeFallbackOutcome preservingIssue stoppedOutcome)
    TpnDeclineFallback preservingIssue -> do
      onEvent (MreFallbackDeclined preservingIssue)
      pure
        (InWindowReloadRejectedLiveFallback
          (TpiwiPreservingFallbackDeclined preservingIssue))
    TpnTerminal preservingIssue ->
      pure (InWindowReloadTerminal (TpiwiPreservingTerminal preservingIssue))


-- | Production wiring for 'TryPreservingHostStackOps' against live
-- session-layer primitives.
--
-- Open and close are reused from
-- "MetaSonic.App.ManifestReloadHostStack" unchanged. The in-window
-- slot drives 'realTryPreservingInWindowReload', which composes
-- the preserving + stopped-audio helpers under the
-- 'decideTryPreservingNext' policy.
--
-- The event sink is read off the inputs' 'rsahsiOnEvent' field so
-- 'MreFallbackAdmitted' / 'MreFallbackDeclined' reach the same
-- destination as the phase events. Strategy-frame events are not
-- emitted here.
realTryPreservingHostStackOps
  :: Show ingressIssue
  => ProducerId
  -> RealTryPreservingHostStackInputs ingressIssue handle
  -> TryPreservingHostStackOps ManifestReloadIngressTarget ingressIssue handle
realTryPreservingHostStackOps producer inputs = TryPreservingHostStackOps
  { tpahsoOpen           = realOpen inputs
  , tpahsoClose          = realClose
  , tpahsoInWindowReload =
      realTryPreservingInWindowReload
        (rsahsiOnEvent inputs)
        producer
        (rsahsiIngressTargetPolicy inputs)
  }


-- | Build a 'HostStackFactory' from a 'TryPreservingHostStackOps'
-- bundle so the supervisor adapter can drive it through
-- 'withHostStackSupervisorAdapter'. Mirrors
-- 'mkPreservingHostStackFactory' / 'mkStoppedAudioHostStackFactory'.
mkTryPreservingHostStackFactory
  :: TryPreservingHostStackOps target ingressIssue handle
  -> HostStackFactory
       MR.ManifestReloadPlan
       (TryPreservingHostStack target ingressIssue handle)
       (TryPreservingHostStackIssue ingressIssue)
mkTryPreservingHostStackFactory ops = HostStackFactory
  { hsfOpenStack      = fmap (first TpahsiOpen) . tpahsoOpen ops
  , hsfCloseStack     = tpahsoClose ops
  , hsfInWindowReload = \stack fallback requested ->
      fmap TpahsiInWindow
        <$> tpahsoInWindowReload ops stack fallback requested
  }
