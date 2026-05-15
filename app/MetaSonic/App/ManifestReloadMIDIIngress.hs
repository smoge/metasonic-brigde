-- |
-- Module      : MetaSonic.App.ManifestReloadMIDIIngress
-- Description : MIDI CC ingress consumer over a projected manifest MIDI target.
--
-- This module turns a 'ManifestMIDIIngressTarget' into a no-device
-- MIDI CC consumer: it accepts already-decoded CC inputs, validates
-- the byte ranges, looks the CC up in the projection, scales the
-- 7-bit value through the binding's range, and forwards the resulting
-- 'CmdControlWrite' through the session fan-in with the producer
-- identity 'midiProducerId'.
--
-- It deliberately does not open PortMIDI devices, run a listener
-- thread, route CC writes to active notes (the existing 'MIDIProducer'
-- 'controlChange' path does that), or drain the fan-in host. CC writes
-- target the producer-configured default voice that the projection
-- carries — per the v1 binding-policy decision that MIDI CCs have no
-- caller-supplied 'VoiceKey'.

module MetaSonic.App.ManifestReloadMIDIIngress
  ( -- * Inputs
    ManifestMIDICCInput (..)

    -- * Outcomes
  , ManifestMIDIIngressIssue (..)
  , ManifestMIDIIngressResult (..)

    -- * Operations
  , submitManifestMIDICCEvent
  ) where

import qualified Data.Set                         as S
import           Data.Word                        (Word8)

import           MetaSonic.App.ManifestReloadMIDIBinding
                                                  (ManifestMIDIAddressIssue,
                                                   ManifestMIDIControlBinding (..),
                                                   ManifestMIDIIngressTarget (..),
                                                   validateMIDICC)
import           MetaSonic.Pattern                (Value)
import           MetaSonic.Session.Command        (SessionCommand (..))
import           MetaSonic.Session.FanIn          (SessionFanInEnqueueResult,
                                                   SessionFanInHost,
                                                   enqueueSessionFanInCommand)
import           MetaSonic.Session.MIDIProducer   (MIDIChannelFilter (..),
                                                   MIDIProducerOptions (..),
                                                   midiProducerId)


-- | One decoded MIDI CC event submitted against a projected MIDI target.
--
-- 'mmciChannel' is carried for diagnostics and future per-channel
-- routing; v1 does not use it for voice selection. 'mmciCC' is the
-- 7-bit CC number that the projection's CC route table is keyed by.
-- 'mmciValue' is the 7-bit CC payload byte.
data ManifestMIDICCInput = ManifestMIDICCInput
  { mmciChannel :: !Word8
  , mmciCC      :: !Word8
  , mmciValue   :: !Word8
  } deriving (Eq, Show)

-- | Module-level rejection produced before the fan-in is called.
--
-- 'MmiiInvalidChannel' covers channel bytes outside @[0, 15]@;
-- 'MmiiInvalidDataByte' covers CC numbers or payload bytes outside
-- @[0, 127]@; 'MmiiChannelFiltered' covers channels rejected by the
-- producer's 'mpoChannelFilter' allow-list policy; 'MmiiAddressIssue'
-- covers projection rejection (the CC is not bound by the current
-- manifest).
data ManifestMIDIIngressIssue
  = MmiiInvalidChannel !Word8
  | MmiiInvalidDataByte !Word8
  | MmiiChannelFiltered !Word8
  | MmiiAddressIssue !ManifestMIDIAddressIssue
  deriving (Eq, Show)

-- | Outcome of one 'submitManifestMIDICCEvent' call.
--
-- 'Left' covers module-side rejections (byte-range or projection); a
-- 'Right' carries the fan-in enqueue attempt, which may itself be a
-- queue-rejected result.
newtype ManifestMIDIIngressResult = ManifestMIDIIngressResult
  { mmirOutcome :: Either ManifestMIDIIngressIssue SessionFanInEnqueueResult
  } deriving (Eq, Show)

-- | Submit one decoded MIDI CC event through the producer fan-in path.
--
-- Channel and data bytes are validated first; the producer's
-- 'mpoChannelFilter' allow-list policy is then applied so that a host
-- configured with 'MIDIChannelAllowList' does not silently let
-- manifest CC writes from filtered channels reach the fan-in. Bound
-- CC numbers produce a 'CmdControlWrite' targeting the target's
-- default voice, with the 7-bit payload linearly scaled through the
-- binding's @[mmcbRangeMin, mmcbRangeMax]@ range.
submitManifestMIDICCEvent
  :: MIDIProducerOptions
  -> ManifestMIDIIngressTarget
  -> ManifestMIDICCInput
  -> SessionFanInHost
  -> IO ManifestMIDIIngressResult
submitManifestMIDICCEvent opts target input host
  | mmciChannel input > 15 =
      pure (rejection (MmiiInvalidChannel (mmciChannel input)))
  | mmciCC input > 127 =
      pure (rejection (MmiiInvalidDataByte (mmciCC input)))
  | mmciValue input > 127 =
      pure (rejection (MmiiInvalidDataByte (mmciValue input)))
  | not (channelAccepted (mpoChannelFilter opts) (mmciChannel input)) =
      pure (rejection (MmiiChannelFiltered (mmciChannel input)))
  | otherwise =
      case validateMIDICC (mmciCC input) target of
        Left addrIssue ->
          pure (rejection (MmiiAddressIssue addrIssue))
        Right binding -> do
          let cmd = CmdControlWrite
                      (mmitDefaultVoice target)
                      (mmcbControlTag binding)
                      (scaleCCValue binding (mmciValue input))
          enqueueResult <-
            enqueueSessionFanInCommand (midiProducerId opts) cmd host
          pure (ManifestMIDIIngressResult (Right enqueueResult))
  where
    rejection issue =
      ManifestMIDIIngressResult (Left issue)

channelAccepted :: MIDIChannelFilter -> Word8 -> Bool
channelAccepted channelFilter ch =
  case channelFilter of
    MIDIChannelOmni ->
      True
    MIDIChannelAllowList accepted ->
      S.member ch accepted

scaleCCValue :: ManifestMIDIControlBinding -> Word8 -> Value
scaleCCValue binding value =
  let x = fromIntegral value / 127.0
  in mmcbRangeMin binding + x * (mmcbRangeMax binding - mmcbRangeMin binding)
