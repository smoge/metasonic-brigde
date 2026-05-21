-- |
-- Module      : MetaSonic.App.ManifestReloadOSCIngress
-- Description : OSC ingress consumer over a projected manifest OSC target.
--
-- This module turns a 'ManifestOSCIngressTarget' into a real OSC consumer
-- binding: it accepts already-received 'OscMessage' values, decodes them
-- through the existing 'MetaSonic.OSC.Dispatch.Internal' parser, validates
-- the decoded 'ControlTag' against the projection, and forwards accepted
-- messages through 'MetaSonic.Session.OSCProducer' into the session
-- fan-in host.
--
-- It deliberately does not open a UDP socket, manage a listener thread,
-- or drain the fan-in host. The 'VoiceKey' is whatever the OSC address
-- supplies — the projection only validates the tag part.

module MetaSonic.App.ManifestReloadOSCIngress
  ( ManifestOSCIngressIssue (..)
  , ManifestOSCIngressResult (..)
  , submitManifestOSCMessage
  ) where

import           MetaSonic.App.ManifestReloadOSCBinding
                                                  (ManifestOSCAddressIssue,
                                                   ManifestOSCControlBinding (..),
                                                   ManifestOSCIngressTarget,
                                                   validateOSCControlTag)
import           MetaSonic.OSC.Dispatch.Internal  (DispatchIssue,
                                                   SymbolicControlWrite (..),
                                                   decodeSymbolicControlWrite)
import           MetaSonic.OSC.Wire               (OscMessage)
import           MetaSonic.Pattern                (ControlTag)
import           MetaSonic.Session.FanIn          (SessionFanInHost)
import           MetaSonic.Session.OSCProducer    (OSCProducerEnqueueResult,
                                                   OSCProducerOptions,
                                                   enqueueOSCControlWrite)


-- | OSC ingress rejection raised before the OSC producer is called.
--
-- 'MoiiDecodeFailed' surfaces a parser-side rejection (malformed
-- address, missing argument, etc.). 'MoiiAddressIssue' surfaces a
-- projection-side rejection (the decoded 'ControlTag' is not in the
-- current target — removed-by-reload or never-existed).
-- 'MoiiValueOutOfRange' surfaces a value-domain rejection: the tag
-- exists in the current target, but the supplied value lies outside
-- the manifest's declared @[rangeMin, rangeMax]@ for that tag (NaN
-- is rendered the same way). The fields are @tag@, @value@,
-- @rangeMin@, @rangeMax@. See
-- @notes/2026-05-21-d-manifest-osc-range-rejection.md@.
data ManifestOSCIngressIssue
  = MoiiDecodeFailed     !DispatchIssue
  | MoiiAddressIssue     !ManifestOSCAddressIssue
  | MoiiValueOutOfRange  !ControlTag !Double !Double !Double
  deriving (Eq, Show)

-- | Outcome of one 'submitManifestOSCMessage' call.
--
-- A 'Left' covers module-side rejections (parser or projection); a
-- 'Right' carries the underlying OSC producer's result, which may
-- itself be a queue-full rejection inside the fan-in host.
newtype ManifestOSCIngressResult = ManifestOSCIngressResult
  { moirOutcome :: Either ManifestOSCIngressIssue OSCProducerEnqueueResult
  } deriving (Eq, Show)

-- | Submit one already-received OSC message through the producer
-- fan-in path.
--
-- Three layers of validation run before the producer is invoked: the
-- shared symbolic OSC decoder parses the @\/<voice>\/<tag>\/<slot>@
-- grammar, the projection rejects tags absent from the current
-- manifest, and the manifest's declared @[rangeMin, rangeMax]@ for
-- the matched tag rejects out-of-range values (NaN included; all NaN
-- comparisons evaluate 'False', so an explicit 'isNaN' arm is part of
-- the predicate). Accepted messages are forwarded unchanged through
-- 'enqueueOSCControlWrite'; the decoder runs again inside the producer
-- — acceptable in v1 for code clarity. See
-- @notes/2026-05-21-d-manifest-osc-range-rejection.md@.
submitManifestOSCMessage
  :: OSCProducerOptions
  -> ManifestOSCIngressTarget
  -> OscMessage
  -> SessionFanInHost
  -> IO ManifestOSCIngressResult
submitManifestOSCMessage opts target msg host =
  case decodeSymbolicControlWrite msg of
    Left issue ->
      pure (ManifestOSCIngressResult (Left (MoiiDecodeFailed issue)))
    Right (SymbolicControlWrite _voiceKey tag value) ->
      case validateOSCControlTag tag target of
        Left addrIssue ->
          pure (ManifestOSCIngressResult (Left (MoiiAddressIssue addrIssue)))
        Right binding
          | let lo = mocbRangeMin binding
                hi = mocbRangeMax binding
          , isNaN value || value < lo || value > hi ->
              pure (ManifestOSCIngressResult
                     (Left (MoiiValueOutOfRange tag value lo hi)))
          | otherwise -> do
              producerResult <- enqueueOSCControlWrite opts msg host
              pure (ManifestOSCIngressResult (Right producerResult))
