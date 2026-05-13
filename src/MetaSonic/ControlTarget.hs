{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.ControlTarget
-- Description : Shared symbolic control-target resolution.
--
-- This module owns the pure lookup shared by OSC dispatch and the
-- session runtime adapter. It resolves a symbolic template/control
-- target into the concrete runtime node index and control slot already
-- present in a compiled 'TemplateGraph'.
--
-- It intentionally lives at the top level, not under 'Bridge',
-- 'OSC', or 'Session', because none of those subsystems owns this
-- lookup contract.

module MetaSonic.ControlTarget
  ( ControlTarget (..)
  , ControlTargetIssue (..)
  , resolveControlTarget
  ) where

import           Control.DeepSeq            (NFData)
import           Data.List                  (find)
import           GHC.Generics               (Generic)

import           MetaSonic.Bridge.Compile   (RuntimeNode (..), rgNodes)
import           MetaSonic.Bridge.Source    (MigrationKey)
import           MetaSonic.Bridge.Templates (Template (..), TemplateGraph (..))
import           MetaSonic.Pattern          (ControlTag (..), TemplateName (..))
import           MetaSonic.Types            (NodeIndex)


-- | Concrete target accepted by the realtime control-write ABI.
data ControlTarget = ControlTarget
  { targetNodeIndex   :: !NodeIndex
  , targetControlSlot :: !Int
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Pure symbolic-resolution failures. Callers map these into their
-- own public issue vocabularies.
data ControlTargetIssue
  = CtiMissingTemplate !TemplateName
  | CtiUnknownNodeTag !TemplateName !MigrationKey
  | CtiInvalidControlSlot !TemplateName !MigrationKey !Int !Int
    -- ^ Template, node tag, requested slot, available slot count.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Resolve a symbolic @(template, node tag, control slot)@ target
-- against a compiled template graph.
resolveControlTarget
  :: TemplateGraph
  -> TemplateName
  -> ControlTag
  -> Either ControlTargetIssue ControlTarget
resolveControlTarget tg tname@(TemplateName name) (ControlTag key slot) = do
  tpl <-
    case find ((== name) . tplName) (tgTemplates tg) of
      Just x  -> Right x
      Nothing -> Left (CtiMissingTemplate tname)

  node <-
    case find ((== Just key) . rnMigrationKey) (rgNodes (tplGraph tpl)) of
      Just x  -> Right x
      Nothing -> Left (CtiUnknownNodeTag tname key)

  let controlCount = length (rnControls node)
  if slot < 0 || slot >= controlCount
     then Left (CtiInvalidControlSlot tname key slot controlCount)
     else Right ControlTarget
            { targetNodeIndex   = rnIndex node
            , targetControlSlot = slot
            }
