-- |
-- Module      : MetaSonic.App.ManifestReloadUIIngress
-- Description : UI producer binding over a projected manifest UI target.
--
-- This module turns a 'ManifestUIIngressTarget' into a real UI producer
-- binding: it accepts already-decoded UI write inputs, validates the
-- control against the projection, resolves the session voice from the
-- target's voice-selection policy, and forwards the write through the
-- existing 'MetaSonic.Session.UIProducer' fan-in path.
--
-- It deliberately does not open a GUI toolkit, decode user gestures,
-- drain the fan-in host, or persist the retained-value map. The retain
-- store is returned by every call so the caller can pass it back to
-- 'manifestUIIngressTargetFromPlan' on the next reload.

module MetaSonic.App.ManifestReloadUIIngress
  ( -- * Inputs
    ManifestUIIngressInput (..)

    -- * Outcomes
  , ManifestUIIngressIssue (..)
  , ManifestUIIngressResult (..)

    -- * Operations
  , submitManifestUIIngress
  , resolveManifestUIVoiceKey
  ) where

import           Data.Map.Strict                  (Map)
import qualified Data.Map.Strict                  as M
import           Data.Maybe                       (fromMaybe)

import           MetaSonic.App.ManifestReloadBinding
                                                  (ManifestUIControlBinding (..),
                                                   ManifestUIIngressTarget (..),
                                                   ManifestUIVoiceSelection (..))
import           MetaSonic.Pattern                (ControlTag, Value, VoiceKey)
import           MetaSonic.Session.FanIn          (SessionFanInEnqueueResult (..),
                                                   SessionFanInHost)
import           MetaSonic.Session.Queue          (SessionEnqueueResult (..))
import           MetaSonic.Session.UIProducer     (UIProducerEnqueueResult (..),
                                                   UIProducerIntent (..),
                                                   UIProducerOptions,
                                                   enqueueUIProducerIntent)


-- | One UI write request against a projected control surface.
--
-- The caller supplies the projected 'ControlTag' (typically from a
-- 'ManifestUIControlBinding' it is already showing) plus the new value.
-- VoiceKey is not part of the input: it is resolved from the target's
-- voice-selection policy at submission time.
data ManifestUIIngressInput = ManifestUIIngressInput
  { muiiControlTag :: !ControlTag
  , muiiValue      :: !Value
  } deriving (Eq, Show)

-- | Module-level rejection produced before the UI producer is called.
--
-- Tags that were removed by reload and tags that never existed both
-- surface through 'MuiiUnknownControl'.
newtype ManifestUIIngressIssue
  = MuiiUnknownControl ControlTag
  deriving (Eq, Show)

-- | Outcome of one 'submitManifestUIIngress' call.
--
-- 'muirOutcome' distinguishes a module-side rejection (the tag is not
-- in the projection) from the UI producer's own result, which may itself
-- be a producer-shape rejection or a fan-in enqueue attempt. The
-- updated 'muirRetainedValues' is the next retain map: the previous map
-- with the written tag inserted iff the fan-in queue actually accepted
-- the command.
data ManifestUIIngressResult = ManifestUIIngressResult
  { muirOutcome        :: !(Either ManifestUIIngressIssue UIProducerEnqueueResult)
  , muirRetainedValues :: !(Map ControlTag Value)
  } deriving (Eq, Show)

-- | Resolve a session voice key from a UI voice-selection policy.
--
-- Focused voice wins when present; otherwise the policy's default voice
-- is used. The default is non-optional in 'ManifestUIVoiceSelection', so
-- this resolution is total.
resolveManifestUIVoiceKey :: ManifestUIVoiceSelection -> VoiceKey
resolveManifestUIVoiceKey selection =
  fromMaybe (muvsDefaultVoice selection) (muvsFocusedVoice selection)

-- | Submit one UI write through the producer fan-in path.
--
-- The retain map is updated only on a successful fan-in enqueue. A
-- module-side rejection, a non-finite-value rejection inside the UI
-- producer, or a fan-in queue-rejected outcome all leave the map
-- unchanged so the caller can replay or surface the failure without
-- losing the previously-known value for the tag.
submitManifestUIIngress
  :: UIProducerOptions
  -> ManifestUIIngressTarget
  -> Map ControlTag Value
  -> ManifestUIIngressInput
  -> SessionFanInHost
  -> IO ManifestUIIngressResult
submitManifestUIIngress opts target retained input host =
  case lookupControlBinding tag target of
    Nothing ->
      pure ManifestUIIngressResult
        { muirOutcome =
            Left (MuiiUnknownControl tag)
        , muirRetainedValues =
            retained
        }
    Just _binding -> do
      let voiceKey = resolveManifestUIVoiceKey (muitVoiceSelection target)
          intent   = UIControlWrite voiceKey tag (muiiValue input)
      producerResult <- enqueueUIProducerIntent opts intent host
      pure ManifestUIIngressResult
        { muirOutcome =
            Right producerResult
        , muirRetainedValues =
            applyRetainOnSuccess tag (muiiValue input) retained producerResult
        }
  where
    tag = muiiControlTag input

lookupControlBinding
  :: ControlTag
  -> ManifestUIIngressTarget
  -> Maybe ManifestUIControlBinding
lookupControlBinding tag target =
  case filter ((tag ==) . muicControlTag) (muitControls target) of
    binding : _ ->
      Just binding
    [] ->
      Nothing

applyRetainOnSuccess
  :: ControlTag
  -> Value
  -> Map ControlTag Value
  -> UIProducerEnqueueResult
  -> Map ControlTag Value
applyRetainOnSuccess tag value retained producerResult =
  case producerResult of
    UIProducerRejected _issue ->
      retained
    UIProducerEnqueueAttempted _cmd enqueue
      | enqueueAccepted enqueue ->
          M.insert tag value retained
      | otherwise ->
          retained

enqueueAccepted :: SessionFanInEnqueueResult -> Bool
enqueueAccepted result =
  case sfierResult result of
    SessionEnqueued {} ->
      True
    SessionEnqueueRejected {} ->
      False
