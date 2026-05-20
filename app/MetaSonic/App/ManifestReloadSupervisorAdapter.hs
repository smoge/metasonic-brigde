{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TupleSections      #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadSupervisorAdapter
-- Description : Real-host adapter seam for the manifest reload supervisor.
--
-- The supervisor primitive in
-- 'MetaSonic.App.ManifestReloadSupervisor' is generic over the plan
-- and error types; it knows nothing about what a host \"stack\"
-- actually is. This module pins the production seam: a small
-- 'HostStackFactory' that owns close / open of a producer-defined
-- stack value, plus an in-window reload op against an already-open
-- stack. 'withHostStackSupervisorAdapter' threads these through an
-- 'IORef'-backed active-stack reference and exposes the result as
-- a 'SupervisorOps' the supervisor can drive.
--
-- This slice ships the seam and exercises it through deterministic
-- fake tests only. Routing the real stopped-audio host reload
-- through 'reloadSupervised' lands in a separate slice; the
-- production 'HostStackFactory' against
-- 'MetaSonic.App.ManifestReloadHost' is parked behind that wiring
-- decision.
--
-- See notes\/2026-05-14-k-host-reload-supervisor.md \xa7164
-- (\"Layering And Module Placement\") and \xa7219 implementation slices.
module MetaSonic.App.ManifestReloadSupervisorAdapter
  ( HostStackFactory (..)
  , withHostStackSupervisorAdapter
  ) where

import           Control.Exception (finally, mask, mask_)
import           Data.Foldable     (for_)
import           Data.IORef        (IORef, atomicModifyIORef', newIORef,
                                    readIORef, writeIORef)

import           MetaSonic.App.ManifestReloadSupervisor
                                   (SupervisorOps (..))


-- | Producer-owned interface to a closeable / reopenable host stack.
--
-- The adapter does not look inside @stack@; the producer decides
-- whether it carries a @SessionFanInService@ + ingress manager +
-- audio FFI bundle, a test recorder, or anything else. The contract
-- on each slot is documented per field.
data HostStackFactory plan stack e = HostStackFactory
  { hsfOpenStack       :: !(plan -> IO (Either e stack))
    -- ^ Construct a fresh stack from the supplied plan. @Right
    -- stack@ means the new stack is ready to serve commands;
    -- @Left e@ means construction failed terminally and no
    -- partial state remains (the implementation is responsible
    -- for cleanup before returning @Left@). Used only on the
    -- supervisor's rebuild path against the captured fallback
    -- plan.
  , hsfCloseStack      :: !(stack -> IO ())
    -- ^ Dispose a previously-opened stack. Best-effort: the
    -- adapter calls @hsfCloseStack@ exactly once per opened
    -- stack and treats its return value as terminal. Throws
    -- propagate per the §238 #9 cleanup invariant — the adapter
    -- ensures @hsfCloseStack@ ran before any exception from the
    -- in-window op escapes 'withHostStackSupervisorAdapter'.
  , hsfInWindowReload  :: !(stack -> plan -> IO (Either e ()))
    -- ^ Drive a stopped-audio in-window reload against an
    -- already-open stack. @Right ()@ means the same stack is now
    -- running the requested plan (the reload mutated the stack
    -- in place; the supervisor does not need to close-then-open).
    -- @Left e@ means terminal in-window failure: the supervisor
    -- closes this stack and rebuilds from the captured fallback
    -- plan via 'hsfCloseStack' + 'hsfOpenStack'.
  }


-- | Bracket a 'SupervisorOps' built from a 'HostStackFactory' and an
-- already-open initial stack.
--
-- The adapter owns an @IORef (Maybe stack)@ tracking the active
-- stack. The transitions are:
--
-- - successful in-window: ref unchanged; the same stack value now
--   runs the new plan (per the @hsfInWindowReload@ contract);
-- - failed in-window (returned @Left e@): the supervisor calls
--   'sopsCloseStack' (which empties the ref via 'hsfCloseStack')
--   and then 'sopsOpenStack' on the fallback plan (which refills
--   the ref via 'hsfOpenStack');
-- - exception thrown by 'sopsInWindowReload': the supervisor's
--   'Control.Exception.onException' wrapper invokes
--   'sopsCloseStack' before propagation; the adapter's
--   'sopsCloseStack' is idempotent on a 'Nothing' ref so the
--   continuation-finally cleanup below does not double-close.
--
-- The continuation runs inside a 'finally' that closes whichever
-- stack is still in the ref at the end. This catches the case
-- where the continuation returns normally but a previous
-- in-window throw left the ref empty (no-op) and the case where
-- the supervisor never failed and the original stack is still
-- live (closed here).
--
-- The entire setup runs under an outer 'mask'; only the
-- continuation @k supOps@ is 'restore'd to the caller's masking
-- state. Without the outer mask, an async exception landing
-- between @newIORef (Just initialStack)@ and the 'finally'
-- installation would leak @initialStack@: the caller has already
-- opened it and handed it to us, but no bracket is yet in place
-- to dispose it. With the mask, queued async exceptions can only
-- fire inside @restore (k supOps)@ — at which point 'finally'
-- is fully installed and @closeOps@ runs as the cleanup.
withHostStackSupervisorAdapter
  :: HostStackFactory plan stack e
  -> stack
  -> (SupervisorOps plan e -> IO a)
  -> IO a
withHostStackSupervisorAdapter factory initialStack k = mask $ \restore -> do
  stackRef <- newIORef (Just initialStack)

  let closeOps = closeActiveStack factory stackRef

      -- Async-exception safety: the window between "hsfOpenStack
      -- returns Right newStack" and "writeIORef stackRef (Just
      -- newStack)" must be uninterruptible. Without the inner
      -- mask, an async exception landing there would lose the
      -- only handle to a freshly built stack (the ref still
      -- reads Nothing and the finally below no-ops). The inner
      -- 'mask' nests safely inside the outer one — when openOps
      -- is invoked from within the outer 'restore' (i.e. from
      -- the continuation k), @restore'@ here returns to the
      -- caller's original masking state, so the producer's
      -- hsfOpenStack still runs at whatever state the caller
      -- had (typically Unmasked) and its own internal
      -- bracket/finally on partial allocation continues to
      -- work.
      openOps plan = mask $ \restore' -> do
        result <- restore' (hsfOpenStack factory plan)
        case result of
          Left e ->
            pure (Left e)
          Right newStack -> do
            writeIORef stackRef (Just newStack)
            pure (Right ())

      inWindowOps plan = do
        mStack <- readIORef stackRef
        case mStack of
          Nothing ->
            -- The supervisor invariant is that an in-window
            -- reload runs only against a live stack. Hitting
            -- this branch means the supervisor was driven out
            -- of contract (e.g. an open failure left the ref
            -- empty and the caller still requested an
            -- in-window). Surface it as an error rather than
            -- silently succeed with no stack to mutate.
            ioError $ userError $
              "withHostStackSupervisorAdapter: in-window reload " <>
              "requested with no active stack. This is a " <>
              "supervisor contract violation — sopsInWindowReload " <>
              "must only run while the previous open() succeeded."
          Just stack ->
            hsfInWindowReload factory stack plan

      supOps = SupervisorOps
        { sopsInWindowReload = inWindowOps
        , sopsCloseStack     = closeOps
        , sopsOpenStack      = openOps
        }

  restore (k supOps) `finally` closeOps


-- | Idempotent close: take the stack out of the ref atomically,
-- then dispose it via 'hsfCloseStack'. Both steps run under
-- 'mask_' so an async exception cannot land between the take and
-- the close — that window would otherwise drop the only handle
-- to a half-disposed stack (ref now @Nothing@, hsfCloseStack
-- never ran). Calling this on an already-empty ref is a no-op,
-- so the 'finally' guard in 'withHostStackSupervisorAdapter'
-- does not double-close a stack the supervisor already disposed.
--
-- 'hsfCloseStack' itself runs masked; if it uses interruptible
-- primitives internally (e.g. @takeMVar@ to drain a worker), it
-- remains its responsibility to handle interrupts cleanly. The
-- adapter's contract is only that the take-from-ref and the
-- start-of-close form one atomic step from the async-exception
-- perspective.
closeActiveStack
  :: HostStackFactory plan stack e
  -> IORef (Maybe stack)
  -> IO ()
closeActiveStack factory stackRef = mask_ $ do
  mStack <- atomicModifyIORef' stackRef (Nothing,)
  for_ mStack (hsfCloseStack factory)
