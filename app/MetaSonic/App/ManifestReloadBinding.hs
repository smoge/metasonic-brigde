-- |
-- Module      : MetaSonic.App.ManifestReloadBinding
-- Description : Pure ingress binding projections for manifest reload.
--
-- This module turns the pure manifest reload plan into app-facing
-- ingress target data. It deliberately does not open GUI widgets,
-- OSC sockets, MIDI devices, or session fan-in resources.
--
-- Only the UI-side projection has landed here. OSC address targets
-- and MIDI CC routing targets are separate producer-specific follow-up
-- projections.

module MetaSonic.App.ManifestReloadBinding
  ( ManifestUIVoiceSelection (..)
  , ManifestUIControlValueSource (..)
  , ManifestUIControlBinding (..)
  , ManifestUIIngressTarget (..)
  , manifestUIIngressTargetFromPlan
  ) where

import qualified Data.Map.Strict                  as M
import           Data.Word                        (Word8)

import           MetaSonic.Pattern                (ControlTag, VoiceKey)
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy)
import qualified MetaSonic.Session.ManifestReload as MR


-- | Host policy for resolving UI control writes to a session voice.
--
-- The manifest control surface names controls, but session commands
-- target @(VoiceKey, ControlTag)@. The host keeps that selection
-- policy outside the manifest.
data ManifestUIVoiceSelection = ManifestUIVoiceSelection
  { muvsFocusedVoice :: !(Maybe VoiceKey)
    -- ^ Current operator-selected voice, if any.
  , muvsDefaultVoice :: !VoiceKey
    -- ^ Fallback voice used for unfocused writes.
  } deriving (Eq, Show)

-- | Where a UI binding's current value came from during target
-- projection.
data ManifestUIControlValueSource
  = MuicRetainedValue
    -- ^ The tag survived reload and a caller-supplied last-write cache
    -- supplied its current value.
  | MuicManifestDefault
    -- ^ The tag was new to this projection, so its manifest default
    -- became the current value.
  deriving (Eq, Show)

-- | One UI-facing control binding derived from a manifest control row.
data ManifestUIControlBinding = ManifestUIControlBinding
  { muicDisplayName :: !String
  , muicControlTag  :: !ControlTag
  , muicDefault     :: !Double
  , muicCurrent     :: !Double
  , muicValueSource :: !ManifestUIControlValueSource
  , muicRangeMin    :: !Double
  , muicRangeMax    :: !Double
  , muicSmoothingHz :: !Double
  , muicCC          :: !(Maybe Word8)
  } deriving (Eq, Show)

-- | UI ingress target for one manifest reload plan.
--
-- This is the first concrete shape for @mrhcNewIngressTarget@: still
-- pure data, but no longer an opaque sentinel. A real GUI or app host
-- can turn this into widgets, callbacks, and producer bindings.
data ManifestUIIngressTarget = ManifestUIIngressTarget
  { muitDemoKey           :: !String
  , muitVoiceSelection    :: !ManifestUIVoiceSelection
  , muitControls          :: ![ManifestUIControlBinding]
  , muitArbitrationPolicy :: !ArbitrationPolicy
  } deriving (Eq, Show)

-- | Project a validated manifest reload plan into a UI ingress target.
--
-- Surviving tags retain their caller-supplied last-written value.
-- Controls with no retained value use the manifest default. Tags that
-- were present in the old value map but are not present in the new
-- plan are absent from the target.
manifestUIIngressTargetFromPlan
  :: ManifestUIVoiceSelection
  -> M.Map ControlTag Double
  -> MR.ManifestReloadPlan
  -> ManifestUIIngressTarget
manifestUIIngressTargetFromPlan voiceSelection retainedValues plan =
  ManifestUIIngressTarget
    { muitDemoKey =
        MR.mrlpDemoKey plan
    , muitVoiceSelection =
        voiceSelection
    , muitControls =
        map projectControl (MR.mrlpControlSurface plan)
    , muitArbitrationPolicy =
        MR.mrlpArbitrationPolicy plan
    }
  where
    projectControl control =
      let tag = MR.mcsControlTag control
          (current, source) =
            case M.lookup tag retainedValues of
              Just value ->
                (value, MuicRetainedValue)
              Nothing ->
                (MR.mcsDefault control, MuicManifestDefault)
      in ManifestUIControlBinding
           { muicDisplayName =
               MR.mcsDisplayName control
           , muicControlTag =
               tag
           , muicDefault =
               MR.mcsDefault control
           , muicCurrent =
               current
           , muicValueSource =
               source
           , muicRangeMin =
               MR.mcsRangeMin control
           , muicRangeMax =
               MR.mcsRangeMax control
           , muicSmoothingHz =
               MR.mcsSmoothingHz control
           , muicCC =
               MR.mcsCC control
           }
