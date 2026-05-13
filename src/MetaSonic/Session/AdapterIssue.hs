{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.AdapterIssue
-- Description : Shared setup/install issue vocabulary for session adapters.
--
-- These issues describe construction-time and graph-install failures,
-- not producer admission rejection and not plan/commit handshake
-- mismatches. They live outside 'MetaSonic.Session.RTGraphAdapter' so
-- both the RTGraph adapter and the runtime outcome vocabulary can
-- carry structured setup details without a module cycle.

module MetaSonic.Session.AdapterIssue
  ( SessionAdapterSetupIssue (..)
  , SessionPrewarmIssue (..)
  ) where

import           Control.DeepSeq       (NFData)
import           GHC.Generics          (Generic)

import           MetaSonic.Pattern     (TemplateName)


data SessionPrewarmIssue
  = SpiInstanceAddFailed !Int
    -- ^ One-based prewarm attempt whose
    -- 'rt_graph_template_instance_add' call returned -1.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Setup/install failures before an adapter exists, or during a
-- constrained graph install executed by an existing adapter.
data SessionAdapterSetupIssue
  = SasiDuplicateTemplateName !TemplateName
  | SasiLoaderException !String
    -- ^ Exception text from the underlying graph loader.
  | SasiAutoSpawnTemplateIdMismatch !Int !Int
    -- ^ Expected template id, actual template id returned by the
    -- instrumented loader.
  | SasiAutoSpawnRowCountMismatch !Int !Int
    -- ^ Expected row count, actual row count returned by the
    -- instrumented loader.
  | SasiAutoSpawnMissing !TemplateName
  | SasiPrewarmFailed !TemplateName !SessionPrewarmIssue
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)
