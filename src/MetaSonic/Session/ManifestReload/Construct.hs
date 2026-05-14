-- |
-- Module      : MetaSonic.Session.ManifestReload.Construct
-- Description : Construction-time owner helper for manifest reload plans.
--
-- This module is the IO boundary for construction-time manifest session
-- setup. The pure planner stays in 'MetaSonic.Session.ManifestReload'.
--
-- See [notes/2026-05-14-g-manifest-reload-install-strategy.md].

module MetaSonic.Session.ManifestReload.Construct
  ( constructManifestSessionFromPlan
  ) where

import           MetaSonic.Session.AdapterIssue   (SessionAdapterSetupIssue)
import           MetaSonic.Session.ManifestReload (ManifestReloadPlan (..),
                                                   manifestSessionOwnerOptions)
import           MetaSonic.Session.Owner          (SessionOwner,
                                                   SessionOwnerOptions,
                                                   withSessionOwner)


-- | Bracket a fresh session owner from a validated manifest reload plan.
--
-- This is construction-time only. It does not reload an existing owner, step a
-- 'CmdHotSwap', migrate state, interrupt audio, or choose a recovery policy.
-- Manifest-derived metadata such as the control surface remains available to
-- callers through the plan they already hold.
constructManifestSessionFromPlan
  :: ManifestReloadPlan
  -> SessionOwnerOptions
  -> (SessionOwner -> IO a)
  -> IO (Either SessionAdapterSetupIssue a)
constructManifestSessionFromPlan plan baseOwnerOptions action =
  withSessionOwner
    (mrlpTemplateGraph plan)
    (manifestSessionOwnerOptions baseOwnerOptions plan)
    action
