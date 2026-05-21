{-# LANGUAGE DeriveFunctor      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadSupervisor
-- Description : Outer recovery policy for stopped-audio manifest reload.
--
-- Implements the binding invariants from
-- notes/2026-05-14-k-host-reload-supervisor.md: capture the plan
-- running at reload entry as a per-call fallback, attempt the
-- in-window reload, and on terminal failure close the current stack
-- and rebuild from that fallback. One bounded recovery attempt. If
-- the rebuild also fails, escalate; never retry against the failed
-- requested plan.
--
-- The supervisor is generic over both the plan and the failure type
-- so the pure/fake harness can exercise the state machine without
-- touching PortAudio, listeners, or the real fan-in host. The eventual
-- audio-running host command (j-note slice 4) wires real
-- 'SupervisorOps' against the landed audio seam, the in-window
-- orchestrator, and listener bracket factories.

module MetaSonic.App.ManifestReloadSupervisor
  ( SupervisorOps (..)
  , SupervisedReloadOutcome (..)
  , InWindowReloadOutcome (..)
  , inWindowOutcomeFromEither
  , reloadSupervised

    -- * Operator-visible supervisor lifecycle events
    --
    -- A small stream of events the supervisor emits as it crosses
    -- the in-window / close-previous / fallback-open boundaries.
    -- Mirrors the 'ManifestReloadEvent' pattern at the orchestration
    -- layer: 'reloadSupervised' delegates to 'reloadSupervisedWithEvents'
    -- with 'noSupervisedReloadEvents' so silent callers stay quiet.
  , SupervisedReloadEvent (..)
  , noSupervisedReloadEvents
  , reloadSupervisedWithEvents
  ) where

import           Control.Exception (SomeAsyncException, SomeException,
                                    catch, fromException, onException,
                                    throwIO)


-- | Classified outcome of one in-window reload attempt.
--
-- The supervisor drives different recovery behavior per variant:
--
--   * 'InWindowReloadCommitted' — no recovery; the new plan is live.
--   * 'InWindowReloadRejectedLiveFallback' — no recovery; the
--     producer guarantees the old owner / ingress is still installed
--     and the stack is safely running the fallback plan. The
--     supervisor does NOT close-then-rebuild.
--   * 'InWindowReloadTerminal' — recovery; the stack may be in an
--     unknown state. The supervisor closes it and rebuilds from the
--     captured fallback plan.
--
-- The producer is responsible for classifying its failure into the
-- right variant. The stopped-audio path can only produce 'Committed'
-- or 'Terminal' by construction (audio stops before the reinstall, so
-- there is no "old owner is still installed" branch). Preserving and
-- try-preserving paths produce all three: plain preserving rejection
-- with a resumed old ingress maps to 'RejectedLiveFallback', terminal
-- preserving failures (post-install errors, ingress restart failures)
-- map to 'Terminal'.
data InWindowReloadOutcome e
  = InWindowReloadCommitted
  | InWindowReloadRejectedLiveFallback !e
  | InWindowReloadTerminal !e
  deriving stock (Eq, Show, Functor)

-- | Lift a binary success/failure result into the classified
-- 'InWindowReloadOutcome' shape by treating every 'Left' as
-- 'InWindowReloadTerminal'. The stopped-audio path uses this because
-- by construction it cannot produce 'InWindowReloadRejectedLiveFallback'
-- — audio stops before reinstall, so there is no \"old owner still
-- installed\" branch to surface. Preserving / try-preserving paths
-- must classify their failures manually instead of going through this
-- shim.
inWindowOutcomeFromEither :: Either e () -> InWindowReloadOutcome e
inWindowOutcomeFromEither (Left e)   = InWindowReloadTerminal e
inWindowOutcomeFromEither (Right ()) = InWindowReloadCommitted

-- | Injected slots the supervisor drives. The supervisor itself does
-- no IO beyond sequencing these.
data SupervisorOps plan e = SupervisorOps
  { sopsInWindowReload :: !(plan -> plan -> IO (InWindowReloadOutcome e))
    -- ^ Attempt the in-window reload against the currently active
    -- stack. Takes the @fallback@ plan (the previously-current plan;
    -- the one the stack is currently running) followed by the
    -- @requested@ plan. The fallback is threaded through so the
    -- producer can re-derive any plan-dependent state at the reload
    -- boundary (e.g. project the current ingress target from the
    -- fallback rather than reading a cached field on the stack).
    --
    -- See 'InWindowReloadOutcome' for the classification the
    -- producer must apply.
  , sopsCloseStack     :: !(IO ())
    -- ^ Dispose the current host/audio/listener stack. Invoked exactly
    -- once before rebuild on the 'InWindowReloadTerminal' path. Not
    -- invoked on 'InWindowReloadRejectedLiveFallback' (the stack is
    -- still live and serving the fallback plan).
  , sopsOpenStack      :: !(plan -> IO (Either e ()))
    -- ^ Construct a fresh stack from the supplied plan. Used only on
    -- the rebuild path; invoked with the captured fallback plan, never
    -- the failed requested plan.
  }

-- | Result of one supervised reload call.
data SupervisedReloadOutcome e
  = SupervisedReloadCommitted
    -- ^ Requested plan installed end-to-end.
  | SupervisedReloadRequestRejected !e
    -- ^ Requested plan was rejected; the stack is still running the
    -- fallback plan with the old owner / ingress intact. No
    -- close/rebuild occurred. The payload describes the in-window
    -- rejection (e.g. a plain preserving-reload rejection that
    -- resumed old ingress).
  | SupervisedReloadRejectedRecovered !e
    -- ^ Requested plan failed terminally; rebuild from the captured
    -- fallback plan succeeded. The host is running the previous plan
    -- again. The payload describes the in-window failure that
    -- triggered recovery.
  | SupervisedReloadEscalated !e !e
    -- ^ Requested plan failed terminally and the rebuild from the
    -- fallback plan also failed. The host has no live stack. Payload
    -- is (in-window failure, rebuild failure) in that order.
  deriving stock (Eq, Show)

-- | One operator-visible transition in a supervised reload run.
--
-- The events bracket each stage the supervisor actually enters; the
-- existing 'SupervisedReloadOutcome' summarizes the final state,
-- but consumers that want a live timeline of /what the supervisor
-- did to the host stack/ — close-then-open vs. stack-stayed-live —
-- read the event stream instead of inferring from the outcome.
--
-- Each constructor names a specific boundary:
--
--   * Lifecycle (4 constructors): the in-window attempt entry plus
--     each of the three classified return shapes. Exactly one of
--     'SreInWindowCommitted' / 'SreInWindowRejectedLiveFallback' /
--     'SreInWindowTerminal' fires per call, immediately after
--     'SreInWindowStarted'.
--
--   * Recovery (5 constructors): the close-previous + fallback-open
--     pair the supervisor runs after 'SreInWindowTerminal'. Each
--     started/succeeded pair is interleaved so a consumer can tell
--     /which/ stage of the recovery failed if an exception
--     propagates mid-recovery (see the close-throws and open-throws
--     contract documented on the constructors below).
--
-- The 'onException' close that fires when 'sopsInWindowReload'
-- itself throws (the §238 leak-prevention path) is intentionally
-- silent: that close runs from inside an exception handler, the
-- supervised call never returns a classified outcome, and emitting
-- events from the handler risks masking the original exception.
data SupervisedReloadEvent e
  = SreInWindowStarted
    -- ^ About to call 'sopsInWindowReload'. Fires exactly once per
    -- supervised reload, before any classified outcome is known.
  | SreInWindowCommitted
    -- ^ 'sopsInWindowReload' returned 'InWindowReloadCommitted'.
    -- The supervised call returns 'SupervisedReloadCommitted'
    -- next; no close-previous / fallback-open events will fire.
  | SreInWindowRejectedLiveFallback !e
    -- ^ 'sopsInWindowReload' returned
    -- 'InWindowReloadRejectedLiveFallback'. The supervised call
    -- returns 'SupervisedReloadRequestRejected' next; no
    -- close-previous / fallback-open events will fire (the stack
    -- is still live and serving the fallback plan).
  | SreInWindowTerminal !e
    -- ^ 'sopsInWindowReload' returned 'InWindowReloadTerminal'.
    -- The recovery path runs next: 'SreClosePreviousStarted' will
    -- fire, then either 'SreClosePreviousSucceeded' followed by the
    -- fallback-open pair, or the close exception propagates.
  | SreClosePreviousStarted
    -- ^ About to call 'sopsCloseStack' on the recovery path. If
    -- the close throws, this is the LAST event emitted by this
    -- call and the exception propagates without
    -- 'SreClosePreviousSucceeded' / fallback-open events. Consumers
    -- can rely on the structural rule: 'SreClosePreviousStarted'
    -- without a matching 'SreClosePreviousSucceeded' means
    -- "close threw; supervisor bailed without attempting rebuild".
  | SreClosePreviousSucceeded
    -- ^ 'sopsCloseStack' returned cleanly. The supervisor proceeds
    -- to the fallback open.
  | SreFallbackOpenStarted
    -- ^ About to call 'sopsOpenStack' against the captured fallback
    -- plan. If the open throws, this is the LAST event emitted by
    -- this call (no 'SreFallbackOpenSucceeded' /
    -- 'SreFallbackOpenFailed'). 'sopsOpenStack' is required by
    -- contract to clean up any partial state internally before
    -- propagating.
  | SreFallbackOpenSucceeded
    -- ^ 'sopsOpenStack' returned 'Right ()'. The supervised call
    -- returns 'SupervisedReloadRejectedRecovered' next.
  | SreFallbackOpenFailed !e
    -- ^ 'sopsOpenStack' returned 'Left _'. The supervised call
    -- returns 'SupervisedReloadEscalated' next; the host has no
    -- live stack.
  deriving stock (Eq, Show)

-- | A 'SupervisedReloadEvent' callback that discards every event.
-- The default for 'reloadSupervised', kept so callers that have not
-- opted in to the event stream stay silent. Polymorphic in @e@ so
-- the same constant works at every instantiation.
noSupervisedReloadEvents :: SupervisedReloadEvent e -> IO ()
noSupervisedReloadEvents _ = pure ()

-- | Drive a single supervised reload attempt.
--
-- The @fallback@ argument is the plan running at reload entry — by
-- construction, the plan the supervisor was running end-to-end
-- immediately before the user's request. The supervisor captures it
-- once at the start of this call; if the in-window reload commits,
-- the fallback is discarded; if anything fails, rebuild targets the
-- fallback, never the @requested@ plan.
--
-- The supervisor performs at most one rebuild attempt. If both the
-- requested reload and the rebuild fail, the call returns
-- 'SupervisedReloadEscalated' without further retries.
--
-- Equivalent to @'reloadSupervisedWithEvents' 'noSupervisedReloadEvents'@.
-- New callers that want operator-visible lifecycle events should
-- call 'reloadSupervisedWithEvents' directly.
reloadSupervised
  :: SupervisorOps plan e
  -> plan
  -> plan
  -> IO (SupervisedReloadOutcome e)
reloadSupervised = reloadSupervisedWithEvents noSupervisedReloadEvents

-- | 'reloadSupervised' with a typed event callback. The callback
-- receives one 'SupervisedReloadEvent' per boundary the supervisor
-- crosses (see the constructor Haddock on 'SupervisedReloadEvent'
-- for the per-outcome shape).
--
-- The callback is invoked synchronously on the supervisor's IO
-- thread; long-running work in the callback delays the supervisor.
-- The expected use is to write the event into an 'IORef' / channel
-- for downstream rendering.
--
-- Exception safety contract for the callback:
--
-- * Synchronous exceptions thrown by 'onEvent' are /caught and
--   suppressed/ by 'safeEmit'. The supervisor's terminal close +
--   fallback-open contract on the recovery path must not depend on
--   an observer's exception behavior; a rendering callback that
--   throws cannot bypass cleanup of the previous stack or short-
--   circuit the rebuild attempt.
-- * Asynchronous exceptions (e.g. 'UserInterrupt', 'ThreadKilled',
--   the various 'AsyncException' constructors) are /re-thrown/ so
--   process-level shutdown signals reach the runtime.
-- * The trade-off: callback bugs that produce synchronous
--   exceptions silently drop events. Consumers should be
--   'IORef'-style sinks ('modifyIORef'' / channel writes) that do
--   not throw in normal operation; debug a missing event by
--   instrumenting the callback, not by adding exception handling
--   here.
reloadSupervisedWithEvents
  :: (SupervisedReloadEvent e -> IO ())
  -> SupervisorOps plan e
  -> plan
  -> plan
  -> IO (SupervisedReloadOutcome e)
reloadSupervisedWithEvents onEvent ops fallback requested = do
  -- §238 test-checklist invariant: an exception during the in-window
  -- reload must not leak the still-live previous stack. 'onException'
  -- runs 'sopsCloseStack' when 'sopsInWindowReload' throws (sync or
  -- async) and then rethrows; on a normal classified return it does
  -- not fire, so the explicit close on the recovery path below is
  -- not double-called. The onException close is intentionally
  -- /silent/ on the event stream: it runs from inside an exception
  -- handler, the call never returns a classified outcome, and
  -- emitting events from the handler risks masking the original
  -- exception.
  emit SreInWindowStarted
  attempt <- sopsInWindowReload ops fallback requested
                `onException` sopsCloseStack ops
  case attempt of
    InWindowReloadCommitted -> do
      emit SreInWindowCommitted
      pure SupervisedReloadCommitted
    InWindowReloadRejectedLiveFallback rejectErr -> do
      -- The producer guarantees the stack is still serving the
      -- fallback plan; no close/open runs. The CLI surfaces this
      -- without claiming a rebuild happened.
      emit (SreInWindowRejectedLiveFallback rejectErr)
      pure (SupervisedReloadRequestRejected rejectErr)
    InWindowReloadTerminal originalErr -> do
      -- Recovery path. Event emissions here flow through 'emit'
      -- (via 'safeEmit') so a callback that throws at
      -- 'SreInWindowTerminal' or 'SreClosePreviousStarted' cannot
      -- bypass the close + fallback-open below; the §238 invariant
      -- holds independently of the observer.
      --
      -- 'sopsCloseStack' itself is best-effort: if it throws,
      -- 'SreClosePreviousStarted' has been emitted but
      -- 'SreClosePreviousSucceeded' is not; the exception escapes
      -- without a rebuild attempt and the caller is responsible
      -- for process-level escalation. The new stack constructed by
      -- 'sopsOpenStack' is required by contract to clean up any
      -- partial state internally before propagating.
      emit (SreInWindowTerminal originalErr)
      emit SreClosePreviousStarted
      sopsCloseStack ops
      emit SreClosePreviousSucceeded
      emit SreFallbackOpenStarted
      rebuild <- sopsOpenStack ops fallback
      case rebuild of
        Right () -> do
          emit SreFallbackOpenSucceeded
          pure (SupervisedReloadRejectedRecovered originalErr)
        Left rebuildErr -> do
          emit (SreFallbackOpenFailed rebuildErr)
          pure (SupervisedReloadEscalated originalErr rebuildErr)
  where
    emit = safeEmit onEvent

-- | Run an event callback with cleanup-safety: synchronous
-- exceptions are suppressed so they cannot bypass the supervisor's
-- recovery-path contract, but asynchronous exceptions
-- ('UserInterrupt', 'ThreadKilled', etc.) are re-thrown so
-- process-level shutdown signals are not silently swallowed.
--
-- The discriminator is structural: 'SomeAsyncException' is the
-- runtime tag the RTS uses for thread-targeted exceptions, so
-- matching on it via 'fromException' covers every async shape
-- without needing to enumerate constructors.
--
-- Internal to 'reloadSupervisedWithEvents'; the only call site is
-- the local 'emit' binding. Kept top-level (and unexported) so the
-- 'where'-bound lambda does not need a let-bound type signature to
-- restrict the rank of the 'onEvent' argument.
safeEmit
  :: (SupervisedReloadEvent e -> IO ())
  -> SupervisedReloadEvent e
  -> IO ()
safeEmit onEvent ev = onEvent ev `catch` handler
  where
    handler :: SomeException -> IO ()
    handler e = case fromException e :: Maybe SomeAsyncException of
      Just _  -> throwIO e  -- async (UserInterrupt etc.) — propagate
      Nothing -> pure ()    -- sync callback bug — suppress
