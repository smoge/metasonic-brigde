{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadIngress
-- Description : Fresh-bracket ingress manager for host manifest reload.
--
-- The stopped-audio reload orchestration closes listener/producer
-- ingress before draining and stopping audio. On retryable failures it
-- must reopen the old producer surface; on success it must open fresh
-- producer/listener brackets for the new owner. This module models
-- that host-owned policy without reviving a quiesced
-- 'SessionFanInService' worker in place.

module MetaSonic.App.ManifestReloadIngress
  ( ManifestReloadIngressOps (..)
  , ManifestReloadIngressManager
  , ManifestReloadIngressSnapshot (..)
  , newManifestReloadIngressManager
  , readManifestReloadIngressManager
  , closeManifestReloadIngress
  , resumeManifestReloadIngress
  , openFreshManifestReloadIngress
  ) where

import           Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)


-- | Host-supplied opener/finalizer pair for one ingress generation.
--
-- A handle can represent a set of running listener brackets, a service
-- wrapper, producer workers, or any app-owned bundle that can be closed
-- and reopened. Expected operational failures should be represented as
-- 'Left'. Unexpected exceptions are allowed to propagate; 'modifyMVar'
-- preserves the previous manager state if that happens.
data ManifestReloadIngressOps target issue handle =
  ManifestReloadIngressOps
    { mrioOpenIngress  :: !(target -> IO (Either issue handle))
      -- ^ Open a fresh ingress generation for the supplied target.
    , mrioCloseIngress :: !(handle -> IO (Either issue ()))
      -- ^ Close one previously opened ingress generation.
    }

-- | Mutable host-owned ingress state.
data ManifestReloadIngressManager target issue handle =
  ManifestReloadIngressManager
    { mrimOps   :: !(ManifestReloadIngressOps target issue handle)
    , mrimState :: !(MVar (ManifestReloadIngressState target handle))
    }

data ManifestReloadIngressState target handle
  = ManifestReloadIngressClosed
  | ManifestReloadIngressOpen !target !handle

-- | Observable snapshot for tests and host diagnostics.
data ManifestReloadIngressSnapshot target handle
  = MrisClosed
  | MrisOpen !target !handle
  deriving stock (Eq, Show)

-- | Construct a manager around an already-running ingress generation.
newManifestReloadIngressManager
  :: ManifestReloadIngressOps target issue handle
  -> target
  -> handle
  -> IO (ManifestReloadIngressManager target issue handle)
newManifestReloadIngressManager ops target handle = do
  state <- newMVar (ManifestReloadIngressOpen target handle)
  pure ManifestReloadIngressManager
    { mrimOps =
        ops
    , mrimState =
        state
    }

-- | Read the current ingress generation without exposing mutation.
readManifestReloadIngressManager
  :: ManifestReloadIngressManager target issue handle
  -> IO (ManifestReloadIngressSnapshot target handle)
readManifestReloadIngressManager manager =
  toSnapshot <$> readMVar (mrimState manager)

-- | Close the current ingress generation, if one is open.
--
-- On close failure, the previous open state is retained. This keeps the
-- manager conservative: a failed finalizer has not proved that ingress
-- is safely closed, so callers should not continue toward stop-audio.
closeManifestReloadIngress
  :: ManifestReloadIngressManager target issue handle
  -> IO (Either issue ())
closeManifestReloadIngress manager =
  modifyMVar (mrimState manager) $ \state ->
    case state of
      ManifestReloadIngressClosed ->
        pure (ManifestReloadIngressClosed, Right ())
      ManifestReloadIngressOpen target handle -> do
        result <- mrioCloseIngress (mrimOps manager) handle
        pure $ case result of
          Right () ->
            (ManifestReloadIngressClosed, Right ())
          Left issue ->
            (ManifestReloadIngressOpen target handle, Left issue)

-- | Reopen old ingress after a retryable failure.
--
-- If ingress is still open, this is a no-op. If it has been closed,
-- the manager opens a fresh generation for the supplied target.
resumeManifestReloadIngress
  :: ManifestReloadIngressManager target issue handle
  -> target
  -> IO (Either issue ())
resumeManifestReloadIngress manager target =
  modifyMVar (mrimState manager) $ \state ->
    case state of
      ManifestReloadIngressOpen openTarget handle ->
        pure (ManifestReloadIngressOpen openTarget handle, Right ())
      ManifestReloadIngressClosed -> do
        result <- mrioOpenIngress (mrimOps manager) target
        pure $ case result of
          Right handle ->
            (ManifestReloadIngressOpen target handle, Right ())
          Left issue ->
            (ManifestReloadIngressClosed, Left issue)

-- | Open a fresh ingress generation for the supplied target.
--
-- If a generation is still open, it is closed first. Close failure
-- keeps that existing generation installed and prevents a duplicate
-- listener/producer surface from being opened.
openFreshManifestReloadIngress
  :: ManifestReloadIngressManager target issue handle
  -> target
  -> IO (Either issue ())
openFreshManifestReloadIngress manager target =
  modifyMVar (mrimState manager) $ \state -> do
    closeResult <- closeState state
    case closeResult of
      Left (keptState, issue) ->
        pure (keptState, Left issue)
      Right () -> do
        result <- mrioOpenIngress (mrimOps manager) target
        pure $ case result of
          Right handle ->
            (ManifestReloadIngressOpen target handle, Right ())
          Left issue ->
            (ManifestReloadIngressClosed, Left issue)
  where
    closeState ManifestReloadIngressClosed =
      pure (Right ())
    closeState state@(ManifestReloadIngressOpen _target handle) = do
      result <- mrioCloseIngress (mrimOps manager) handle
      pure $ case result of
        Right () ->
          Right ()
        Left issue ->
          Left (state, issue)

toSnapshot
  :: ManifestReloadIngressState target handle
  -> ManifestReloadIngressSnapshot target handle
toSnapshot ManifestReloadIngressClosed =
  MrisClosed
toSnapshot (ManifestReloadIngressOpen target handle) =
  MrisOpen target handle
