-- |
-- Module      : MetaSonic.App.ManifestReloadIngressTarget
-- Description : Combined manifest ingress target bundling UI/OSC/MIDI projections.
--
-- This module is the concrete answer to the binding-policy note's
-- sub-question \"who derives @mrhcNewIngressTarget@?\". It composes the
-- three landed per-producer projections — UI, OSC, MIDI — into a single
-- target value that the orchestrator can pass to a fresh open. It opens
-- no GUI, sockets, or devices.
--
-- The bundle is built by a pure function over 'ManifestReloadPlan' plus
-- the host policy inputs the manifest does not own (UI voice selection,
-- UI retained value map, MIDI default voice). Construction can fail
-- because the MIDI projection rejects duplicate CC numbers; the failure
-- is surfaced unchanged so the caller can route it back through the
-- orchestrator's ingress-restart issue path.

module MetaSonic.App.ManifestReloadIngressTarget
  ( ManifestReloadIngressTargetPolicy (..)
  , ManifestReloadIngressTarget (..)
  , manifestReloadIngressTargetFromPlan
  ) where

import           Data.Map.Strict                  (Map)

import           MetaSonic.App.ManifestReloadBinding
                                                  (ManifestUIIngressTarget,
                                                   ManifestUIVoiceSelection,
                                                   manifestUIIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadMIDIBinding
                                                  (ManifestMIDIIngressTarget,
                                                   ManifestMIDIProjectionIssue,
                                                   manifestMIDIIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadOSCBinding
                                                  (ManifestOSCIngressTarget,
                                                   manifestOSCIngressTargetFromPlan)
import           MetaSonic.Pattern                (ControlTag, Value, VoiceKey)
import qualified MetaSonic.Session.ManifestReload as MR


-- | Host policy inputs that the manifest does not own.
--
-- @mritpUIVoiceSelection@ feeds the UI projection's voice resolution;
-- @mritpUIRetainedValues@ seeds the UI projection's last-written cache
-- across reloads; @mritpMIDIDefaultVoice@ is the producer-configured
-- voice that every MIDI CC write targets. OSC carries no host-policy
-- input — its 'VoiceKey' rides in the wire path.
data ManifestReloadIngressTargetPolicy =
  ManifestReloadIngressTargetPolicy
    { mritpUIVoiceSelection :: !ManifestUIVoiceSelection
    , mritpUIRetainedValues :: !(Map ControlTag Value)
    , mritpMIDIDefaultVoice :: !VoiceKey
    } deriving (Eq, Show)

-- | Combined ingress target carried as @mrhcNewIngressTarget@ for a
-- preserving (or stopped-audio) reload.
--
-- All three producer surfaces are projected from the same plan, so
-- they share a demo key and arbitration policy by construction. The
-- per-target records remain the source of truth for shape, range,
-- voice policy, and routing; this record only bundles them.
data ManifestReloadIngressTarget = ManifestReloadIngressTarget
  { mitUI   :: !ManifestUIIngressTarget
  , mitOSC  :: !ManifestOSCIngressTarget
  , mitMIDI :: !ManifestMIDIIngressTarget
  } deriving (Eq, Show)

-- | Project a validated manifest reload plan into a combined ingress
-- target.
--
-- UI and OSC projections are total; MIDI rejects duplicate CC numbers
-- in the same manifest. A duplicate-CC error here means the
-- orchestrator cannot open a fresh target against the new plan and
-- should surface the failure rather than open a partial surface.
manifestReloadIngressTargetFromPlan
  :: ManifestReloadIngressTargetPolicy
  -> MR.ManifestReloadPlan
  -> Either ManifestMIDIProjectionIssue ManifestReloadIngressTarget
manifestReloadIngressTargetFromPlan policy plan = do
  midi <-
    manifestMIDIIngressTargetFromPlan
      (mritpMIDIDefaultVoice policy)
      plan
  Right ManifestReloadIngressTarget
    { mitUI =
        manifestUIIngressTargetFromPlan
          (mritpUIVoiceSelection policy)
          (mritpUIRetainedValues policy)
          plan
    , mitOSC =
        manifestOSCIngressTargetFromPlan plan
    , mitMIDI =
        midi
    }
