-- |
-- Module      : MetaSonic.App.ManifestReloadOSCBinding
-- Description : Pure OSC ingress projection for manifest reload.
--
-- This module turns a 'ManifestReloadPlan' into an OSC address namespace
-- derived deterministically from 'ManifestControlSurface'. The
-- projection is pure: it opens no sockets, decodes no packets, and
-- knows nothing about listener lifecycle.
--
-- The projection preserves the existing OSC contract that the
-- 'VoiceKey' rides in the path prefix
-- (@/<voice>/<node-tag>/<slot>@) — it only validates the tag part of an
-- incoming write against the current manifest's control surface. New
-- tags appear, removed tags reject, and a surviving tag's path remains
-- stable across reloads because the path tail is a pure function of the
-- tag.

module MetaSonic.App.ManifestReloadOSCBinding
  ( -- * Projected target
    ManifestOSCControlBinding (..)
  , ManifestOSCIngressTarget (..)
  , manifestOSCIngressTargetFromPlan

    -- * Validation
  , ManifestOSCAddressIssue (..)
  , validateOSCControlTag

    -- * Address rendering helpers
  , renderManifestOSCAddressTail
  , renderManifestOSCAddressPattern
  ) where

import           Data.Word                        (Word8)

import           MetaSonic.Bridge.Source          (unMigrationKey)
import           MetaSonic.Pattern                (ControlTag (..))
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy)
import qualified MetaSonic.Session.ManifestReload as MR


-- | One OSC-facing control binding derived from a manifest control row.
--
-- The binding carries the metadata that diagnostic tools and an OSC
-- consumer need to describe and validate the address namespace. It
-- does not own VoiceKey policy; the OSC path supplies that.
data ManifestOSCControlBinding = ManifestOSCControlBinding
  { mocbControlTag  :: !ControlTag
  , mocbDisplayName :: !String
  , mocbDefault     :: !Double
  , mocbRangeMin    :: !Double
  , mocbRangeMax    :: !Double
  , mocbCC          :: !(Maybe Word8)
  } deriving (Eq, Show)

-- | OSC ingress target for one manifest reload plan.
--
-- This is the OSC sibling of 'ManifestUIIngressTarget'. The control
-- list preserves manifest order so diagnostics can render the surface
-- the way the author wrote it. Tag lookup is linear; the surface is
-- small in practice.
data ManifestOSCIngressTarget = ManifestOSCIngressTarget
  { motDemoKey           :: !String
  , motControls          :: ![ManifestOSCControlBinding]
  , motArbitrationPolicy :: !ArbitrationPolicy
  } deriving (Eq, Show)

-- | Project a validated manifest reload plan into an OSC ingress target.
--
-- Surviving tags are present, new tags appear, tags absent from the
-- new manifest are absent from the target. No VoiceKey is encoded in
-- the target because OSC always reads it from the path.
manifestOSCIngressTargetFromPlan
  :: MR.ManifestReloadPlan
  -> ManifestOSCIngressTarget
manifestOSCIngressTargetFromPlan plan =
  ManifestOSCIngressTarget
    { motDemoKey =
        MR.mrlpDemoKey plan
    , motControls =
        map projectControl (MR.mrlpControlSurface plan)
    , motArbitrationPolicy =
        MR.mrlpArbitrationPolicy plan
    }
  where
    projectControl control = ManifestOSCControlBinding
      { mocbControlTag =
          MR.mcsControlTag control
      , mocbDisplayName =
          MR.mcsDisplayName control
      , mocbDefault =
          MR.mcsDefault control
      , mocbRangeMin =
          MR.mcsRangeMin control
      , mocbRangeMax =
          MR.mcsRangeMax control
      , mocbCC =
          MR.mcsCC control
      }

-- | Module-level rejection raised before an OSC write is forwarded to
-- the session.
--
-- Tags that were removed by reload and tags that never existed both
-- surface through 'MoaiUnknownControl'.
newtype ManifestOSCAddressIssue
  = MoaiUnknownControl ControlTag
  deriving (Eq, Show)

-- | Validate a decoded 'ControlTag' against the current OSC target.
--
-- A successful match returns the binding so callers can use its
-- metadata (e.g. range/default) for diagnostics. An unknown tag returns
-- 'MoaiUnknownControl'.
validateOSCControlTag
  :: ControlTag
  -> ManifestOSCIngressTarget
  -> Either ManifestOSCAddressIssue ManifestOSCControlBinding
validateOSCControlTag tag target =
  case filter ((tag ==) . mocbControlTag) (motControls target) of
    binding : _ ->
      Right binding
    [] ->
      Left (MoaiUnknownControl tag)

-- | The OSC path tail (no leading slash, no voice segment) for a
-- 'ControlTag'.
--
-- A real OSC client sends @/<voice>/<node-tag>/<slot>@ — this helper
-- produces the @<node-tag>/<slot>@ part. Useful for documentation and
-- diagnostic output; OSC packet decoding does not consume this.
renderManifestOSCAddressTail :: ControlTag -> String
renderManifestOSCAddressTail (ControlTag mkey slot) =
  unMigrationKey mkey <> "/" <> show slot

-- | The full OSC address pattern for a 'ControlTag' with a literal
-- @<voice>@ placeholder.
--
-- Example: @ControlTag (MigrationKey "cutoff") 1@ renders as
-- @\/<voice>\/cutoff\/1@.
renderManifestOSCAddressPattern :: ControlTag -> String
renderManifestOSCAddressPattern tag =
  "/<voice>/" <> renderManifestOSCAddressTail tag
