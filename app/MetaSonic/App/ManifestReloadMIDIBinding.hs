-- |
-- Module      : MetaSonic.App.ManifestReloadMIDIBinding
-- Description : Pure MIDI CC ingress projection for manifest reload.
--
-- This module turns a 'ManifestReloadPlan' into a MIDI CC routing
-- table derived deterministically from 'ManifestControlSurface'.
-- Controls whose @mcsCC@ is 'Just' produce a binding; controls with
-- @mcsCC = Nothing@ are absent from the MIDI surface. Duplicate CC
-- numbers across the surface are rejected at projection time.
--
-- The projection is pure: it opens no PortMIDI devices, decodes no
-- packets, and knows nothing about device or listener lifecycle.
-- 'VoiceKey' is host policy — the projection carries a caller-supplied
-- default voice rather than inheriting one from the manifest.

module MetaSonic.App.ManifestReloadMIDIBinding
  ( -- * Projected target
    ManifestMIDIControlBinding (..)
  , ManifestMIDIIngressTarget (..)
  , manifestMIDIIngressTargetFromPlan

    -- * Projection rejection
  , ManifestMIDIProjectionIssue (..)

    -- * Validation
  , ManifestMIDIAddressIssue (..)
  , validateMIDICC
  ) where

import           Data.List                        (foldl')
import           Data.Map.Strict                  (Map)
import qualified Data.Map.Strict                  as M
import           Data.Word                        (Word8)

import           MetaSonic.Pattern                (ControlTag, Value, VoiceKey)
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy)
import qualified MetaSonic.Session.ManifestReload as MR


-- | One MIDI-facing control binding derived from a manifest control row.
--
-- Carries the CC number and the value-scaling range used to map the
-- 7-bit MIDI value into the symbolic 'Value' the session expects.
data ManifestMIDIControlBinding = ManifestMIDIControlBinding
  { mmcbControlTag  :: !ControlTag
  , mmcbDisplayName :: !String
  , mmcbCC          :: !Word8
  , mmcbDefault     :: !Value
  , mmcbRangeMin    :: !Value
  , mmcbRangeMax    :: !Value
  } deriving (Eq, Show)

-- | MIDI CC ingress target for one manifest reload plan.
--
-- The CC routing table is a strict map keyed by CC number; the control
-- list mirrors manifest order for diagnostics. 'mmitDefaultVoice' is
-- the producer-configured voice every CC write targets, per the v1
-- binding-policy decision that MIDI has no path-supplied 'VoiceKey'.
data ManifestMIDIIngressTarget = ManifestMIDIIngressTarget
  { mmitDemoKey           :: !String
  , mmitDefaultVoice      :: !VoiceKey
  , mmitControls          :: ![ManifestMIDIControlBinding]
  , mmitCCRoutes          :: !(Map Word8 ManifestMIDIControlBinding)
  , mmitArbitrationPolicy :: !ArbitrationPolicy
  } deriving (Eq, Show)

-- | Projection-time rejection.
--
-- 'MmpiDuplicateCC' carries the CC number plus the colliding
-- 'ControlTag' values in manifest order so the operator can locate the
-- offending rows. The projection refuses to silently shadow one route
-- with another.
newtype ManifestMIDIProjectionIssue
  = MmpiDuplicateCC (Word8, [ControlTag])
  deriving (Eq, Show)

-- | Project a validated manifest reload plan into a MIDI ingress target.
--
-- Only controls with @mcsCC = Just cc@ contribute to the routing table.
-- Surviving CC mappings appear, new CC mappings appear, CC mappings
-- that disappear from the new manifest are absent from the target. A
-- CC number bound to more than one tag in the same manifest is a hard
-- rejection — the caller decides how to surface it.
manifestMIDIIngressTargetFromPlan
  :: VoiceKey
  -> MR.ManifestReloadPlan
  -> Either ManifestMIDIProjectionIssue ManifestMIDIIngressTarget
manifestMIDIIngressTargetFromPlan defaultVoice plan = do
  let controls = concatMap projectControl (MR.mrlpControlSurface plan)
  routes <- buildRoutes controls
  Right ManifestMIDIIngressTarget
    { mmitDemoKey =
        MR.mrlpDemoKey plan
    , mmitDefaultVoice =
        defaultVoice
    , mmitControls =
        controls
    , mmitCCRoutes =
        routes
    , mmitArbitrationPolicy =
        MR.mrlpArbitrationPolicy plan
    }
  where
    projectControl control =
      case MR.mcsCC control of
        Nothing ->
          []
        Just cc ->
          [ ManifestMIDIControlBinding
              { mmcbControlTag =
                  MR.mcsControlTag control
              , mmcbDisplayName =
                  MR.mcsDisplayName control
              , mmcbCC =
                  cc
              , mmcbDefault =
                  MR.mcsDefault control
              , mmcbRangeMin =
                  MR.mcsRangeMin control
              , mmcbRangeMax =
                  MR.mcsRangeMax control
              }
          ]

    buildRoutes =
      foldl' insertRoute (Right M.empty)

    insertRoute acc binding = do
      routes <- acc
      case M.lookup (mmcbCC binding) routes of
        Nothing ->
          Right (M.insert (mmcbCC binding) binding routes)
        Just existing ->
          Left
            (MmpiDuplicateCC
              ( mmcbCC binding
              , [mmcbControlTag existing, mmcbControlTag binding]
              ))

-- | Module-level rejection raised before a MIDI CC write is forwarded
-- to the session.
--
-- CC numbers that were removed by reload and CC numbers that never
-- existed both surface through 'MmaiUnknownCC'.
newtype ManifestMIDIAddressIssue
  = MmaiUnknownCC Word8
  deriving (Eq, Show)

-- | Validate a CC number against the current MIDI target.
--
-- A successful match returns the binding so the consumer can scale the
-- 7-bit value through the binding's range. An unknown CC returns
-- 'MmaiUnknownCC'.
validateMIDICC
  :: Word8
  -> ManifestMIDIIngressTarget
  -> Either ManifestMIDIAddressIssue ManifestMIDIControlBinding
validateMIDICC cc target =
  case M.lookup cc (mmitCCRoutes target) of
    Just binding ->
      Right binding
    Nothing ->
      Left (MmaiUnknownCC cc)
