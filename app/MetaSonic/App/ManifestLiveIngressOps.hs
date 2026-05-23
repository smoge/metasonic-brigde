{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : MetaSonic.App.ManifestLiveIngressOps
-- Description : Combinator over OSC and optional MIDI ingress-ops for the
--               manifest live-session entrypoint, plus production aliases
--               and operator-string renderers for the bundled handle and
--               issue types.
--
-- 'RealReloadHostStackInputs' is polymorphic in @(ingressIssue, handle)@
-- but each instance is single-typed. The live session needs to drive both
-- an OSC listener and (when @--midi-device@ is set) a manifest MIDI
-- ingress under the same supervisor lifecycle. This module composes two
-- 'ManifestReloadIngressOps' values into one, presenting a bundled handle
-- ('LiveIngressHandle') and bundled issue ('LiveIngressIssue') to the
-- supervisor.
--
-- The combinator is polymorphic in OSC and MIDI handle / issue types so
-- pure tests can substitute trivial stubs ('()' handles, tiny-sum
-- issues). The production aliases below specialize against
-- 'ManifestOSCIngressHandle' / 'ManifestMIDIIngressHandle PortMIDISource'
-- and the corresponding issue types so the live session can hand a
-- single specialized bundle to 'RealReloadHostStackInputs'. The
-- module deliberately knows nothing about UDP wire format or
-- PortMIDI device handling; it consumes the existing OSC and MIDI
-- adapters by reference. See
-- @notes\/2026-05-23-c-live-values-portmidi-ingress-design.md@ for
-- the surrounding 3c design.

module MetaSonic.App.ManifestLiveIngressOps
  ( -- * Bundled handle and issue
    LiveIngressHandle (..)
  , LiveIngressIssue (..)

    -- * Combinator
  , manifestLiveIngressOps

    -- * Production aliases
    --
    -- Specialize the polymorphic combinator types against the
    -- landed OSC and PortMIDI-backed MIDI adapters. The live-session
    -- entrypoint hands @RealReloadHostStackInputs@ these aliases;
    -- the polymorphic forms above stay available for tests.
  , LiveProdIngressHandle
  , LiveProdIngressIssue

    -- * Snapshot rendering
    --
    -- A live-session-only ingress-snapshot renderer that wraps the
    -- existing target summary ('renderIngressTargetSummary' in
    -- 'ManifestLiveCommon') and adds a @midi=on@ \/ @midi=off@
    -- marker derived from @'lihMIDI'@. The shared
    -- @renderIngressSnapshot@ is untouched for the demo \/ host-reload
    -- smoke callers that stay OSC-only.
  , renderLiveIngressSnapshot
  , renderLiveIngressSnapshotWith
  , printLiveIngressSnapshot
  , printLiveIngressSnapshotWith

    -- * Initial-open issue rendering
    --
    -- Operator-facing renderer for the bundled issue. Threaded
    -- through @runSupervised@'s @projectInitialIngressFailure@
    -- argument so the live-session entrypoint can @die@ with a
    -- targeted message on @--midi-device@ startup failures, instead
    -- of letting the shared @renderReloadHostStackOpenIssueTag@
    -- collapse the failure to @"ingress-open-failed"@.
  , renderLiveProdIngressIssue
  ) where

import           MetaSonic.App.ManifestLiveCommon (renderIngressTargetSummary)
import           MetaSonic.App.ManifestMIDIIngressOps
                                                  (ManifestMIDIIngressHandle,
                                                   ManifestMIDIIngressOpsIssue (..))
import           MetaSonic.App.ManifestMIDIPortMIDI
                                                  (ManifestMIDIPortMIDIError (..))
import           MetaSonic.App.ManifestOSCIngressOps
                                                  (ManifestOSCIngressHandle (..),
                                                   ManifestOSCIngressOpsIssue (..))
import           MetaSonic.App.ManifestOSCListener
                                                  (ListenerInfo (..),
                                                   ManifestOSCListenerOpenIssue (..))
import           MetaSonic.App.ManifestReloadIngress
                                                  (ManifestReloadIngressManager,
                                                   ManifestReloadIngressOps (..),
                                                   ManifestReloadIngressSnapshot (..),
                                                   readManifestReloadIngressManager)
import           MetaSonic.App.ManifestReloadIngressTarget
                                                  (ManifestReloadIngressTarget)
import           MetaSonic.Session.MIDIPortMIDI   (PortMIDISource)


-- | Bundled handle for the combined live ingress.
--
-- 'lihMIDI' is 'Maybe' so a live session started without
-- @--midi-device@ degrades cleanly to OSC-only without forking the
-- supervisor lifecycle. When 'lihMIDI' is 'Nothing' the combinator
-- behaves as a single-half OSC pass-through; when 'Just', both halves
-- are opened and closed in tandem.
data LiveIngressHandle oscHandle midiHandle = LiveIngressHandle
  { lihOSC  :: !oscHandle
  , lihMIDI :: !(Maybe midiHandle)
  }
  deriving (Eq, Show)


-- | Bundled open / close issue for the combined live ingress.
--
-- 'LiiOSC' carries the OSC half's issue type; 'LiiMIDI' carries the
-- MIDI half's. Reload-time supervisor escalation treats both arms
-- identically; startup-time live-session entrypoint code can render
-- the 'LiiMIDI' arm with operator-friendly device-id strings before
-- the supervisor's tag-collapse path runs.
data LiveIngressIssue oscIssue midiIssue
  = LiiOSC  !oscIssue
  | LiiMIDI !midiIssue
  deriving (Eq, Show)


-- | Compose an OSC 'ManifestReloadIngressOps' with an optional MIDI
-- 'ManifestReloadIngressOps'.
--
-- Open lifecycle:
--
--   * OSC's 'mrioOpenIngress' runs first. On @Left oscIssue@ the
--     combined open returns @Left (LiiOSC oscIssue)@ and the MIDI
--     half is never attempted.
--   * On @Right oscHandle@ with no MIDI ops, the combined open
--     returns @Right (LiveIngressHandle oscHandle Nothing)@.
--   * On @Right oscHandle@ with @Just midiOps@, MIDI's
--     'mrioOpenIngress' runs next. On @Left midiIssue@ the
--     combined open closes the just-opened OSC handle best-effort
--     (close result is discarded — the open failure dominates) and
--     returns @Left (LiiMIDI midiIssue)@. On @Right midiHandle@ the
--     combined open returns @Right (LiveIngressHandle oscHandle
--     (Just midiHandle))@.
--
-- Close lifecycle:
--
--   * When 'lihMIDI' is 'Nothing', the combined close delegates to
--     OSC's 'mrioCloseIngress' and returns its result (wrapped in
--     'LiiOSC' on @Left@).
--   * When 'lihMIDI' is 'Just', both closes are always attempted —
--     MIDI first (so the polling owner detaches before any source
--     close), OSC second (so the UDP socket is always released).
--     OSC close failure dominates: if OSC's close returns @Left@,
--     the combined close returns @Left (LiiOSC ...)@ regardless of
--     MIDI's close result. If OSC succeeds and MIDI failed, the
--     combined close returns @Left (LiiMIDI ...)@. If both succeed,
--     @Right ()@.
--
-- The OSC-dominates close rule means this combinator cannot rely on
-- the production MIDI close contract (which always returns
-- @Right ()@; cleanup failures surface via
-- 'mmioohOnSourceCloseFailed'). Production MIDI degenerates to the
-- OSC-only-determines-result case. The policy stays correct for stub
-- MIDI ops that report close failures.
manifestLiveIngressOps
  :: ManifestReloadIngressOps target oscIssue oscHandle
  -> Maybe (ManifestReloadIngressOps target midiIssue midiHandle)
  -> ManifestReloadIngressOps
       target
       (LiveIngressIssue oscIssue midiIssue)
       (LiveIngressHandle oscHandle midiHandle)
manifestLiveIngressOps oscOps mMIDIOps = ManifestReloadIngressOps
  { mrioOpenIngress =
      \target -> do
        oscResult <- mrioOpenIngress oscOps target
        case oscResult of
          Left oscIssue ->
            pure (Left (LiiOSC oscIssue))
          Right oscHandle ->
            case mMIDIOps of
              Nothing ->
                pure (Right LiveIngressHandle
                  { lihOSC  = oscHandle
                  , lihMIDI = Nothing
                  })
              Just midiOps -> do
                midiResult <- mrioOpenIngress midiOps target
                case midiResult of
                  Left midiIssue -> do
                    -- Roll back the just-opened OSC half so the
                    -- supervisor receives a clean failure instead
                    -- of a half-open live ingress. The close
                    -- result is discarded — the open failure
                    -- dominates and a secondary close-failure
                    -- diagnostic here would only confuse the
                    -- operator-facing error.
                    _ <- mrioCloseIngress oscOps oscHandle
                    pure (Left (LiiMIDI midiIssue))
                  Right midiHandle ->
                    pure (Right LiveIngressHandle
                      { lihOSC  = oscHandle
                      , lihMIDI = Just midiHandle
                      })
  , mrioCloseIngress =
      \handle ->
        case (lihMIDI handle, mMIDIOps) of
          (Nothing, _) -> do
            oscResult <- mrioCloseIngress oscOps (lihOSC handle)
            pure (case oscResult of
              Right () -> Right ()
              Left oscIssue -> Left (LiiOSC oscIssue))
          (Just midiHandle, Just midiOps) -> do
            -- Always attempt both closes. MIDI first detaches the
            -- polling owner; OSC second releases the UDP socket
            -- regardless of the MIDI close outcome. OSC failure
            -- dominates so a successful MIDI close paired with an
            -- OSC failure surfaces as the OSC error.
            midiResult <- mrioCloseIngress midiOps midiHandle
            oscResult  <- mrioCloseIngress oscOps (lihOSC handle)
            pure $ case (oscResult, midiResult) of
              (Left oscIssue, _) ->
                Left (LiiOSC oscIssue)
              (Right (), Left midiIssue) ->
                Left (LiiMIDI midiIssue)
              (Right (), Right ()) ->
                Right ()
          (Just _midiHandle, Nothing) ->
            -- Shape mismatch: handle carries a MIDI half but the
            -- combinator was built without MIDI ops. This is a
            -- programming error — the handle could not have come
            -- from this combinator. Close OSC and ignore the MIDI
            -- half rather than crashing the supervisor; tests pin
            -- the well-formed cases.
            do oscResult <- mrioCloseIngress oscOps (lihOSC handle)
               pure (case oscResult of
                 Right () -> Right ()
                 Left oscIssue -> Left (LiiOSC oscIssue))
  }


-- ---------------------------------------------------------------------------
-- Production aliases
-- ---------------------------------------------------------------------------

-- | The bundled handle the live session hands to
-- @RealReloadHostStackInputs@: OSC half via 'ManifestOSCIngressHandle',
-- optional PortMIDI half via 'ManifestMIDIIngressHandle PortMIDISource'.
type LiveProdIngressHandle =
  LiveIngressHandle
    ManifestOSCIngressHandle
    (ManifestMIDIIngressHandle PortMIDISource)


-- | The bundled issue type for the production combinator. OSC
-- failures arrive as 'ManifestOSCIngressOpsIssue' (currently a
-- single 'MoioiOpenFailed' arm); MIDI failures arrive as
-- 'ManifestMIDIIngressOpsIssue ManifestMIDIPortMIDIError' (no input
-- device or PortMIDI open failure).
type LiveProdIngressIssue =
  LiveIngressIssue
    ManifestOSCIngressOpsIssue
    (ManifestMIDIIngressOpsIssue ManifestMIDIPortMIDIError)


-- ---------------------------------------------------------------------------
-- Snapshot rendering
-- ---------------------------------------------------------------------------

-- | Render the live-session ingress snapshot. Closed snapshots stay
-- @"closed"@; open snapshots produce
-- @"open demo=... ui-controls=... osc-controls=... midi-cc=...
-- defaultVoice=... oscPort=N midi=on\/off"@. The target summary is
-- byte-for-byte identical to the OSC-only @renderIngressSnapshot@
-- summary; only the trailing @midi=@ marker is new.
renderLiveIngressSnapshot
  :: ManifestReloadIngressSnapshot
       ManifestReloadIngressTarget
       LiveProdIngressHandle
  -> String
renderLiveIngressSnapshot =
  renderLiveIngressSnapshotWith moihInfo


-- | Polymorphic core of 'renderLiveIngressSnapshot'. The OSC-info
-- extractor argument lets pure tests substitute trivial @oscHandle@
-- and @midiHandle@ types (the production 'PortMIDISource' is opaque
-- and cannot be constructed in-language). Production wiring passes
-- 'moihInfo' to recover the bound port from a real OSC handle.
renderLiveIngressSnapshotWith
  :: (oscHandle -> ListenerInfo)
  -> ManifestReloadIngressSnapshot
       ManifestReloadIngressTarget
       (LiveIngressHandle oscHandle midiHandle)
  -> String
renderLiveIngressSnapshotWith extractOSCInfo snapshot = case snapshot of
  MrisClosed ->
    "closed"
  MrisOpen target handle ->
    "open " <> renderIngressTargetSummary target
    <> " oscPort="
    <> show (liBoundPort (extractOSCInfo (lihOSC handle)))
    <> " midi="
    <> midiMarker (lihMIDI handle)
  where
    midiMarker Nothing  = "off"
    midiMarker (Just _) = "on"


-- | Print the live-session ingress snapshot to stdout via
-- @putStrLn@. Mirrors 'printIngressSnapshot' in
-- "MetaSonic.App.ManifestLiveCommon"; the sink-taking variant
-- 'printLiveIngressSnapshotWith' is the live-session-friendly form.
printLiveIngressSnapshot
  :: ManifestReloadIngressManager
       ManifestReloadIngressTarget
       LiveProdIngressIssue
       LiveProdIngressHandle
  -> IO ()
printLiveIngressSnapshot =
  printLiveIngressSnapshotWith putStrLn


-- | Sink-taking variant of 'printLiveIngressSnapshot'. The live
-- session passes Haskeline's external-print sink so async snapshot
-- prints redraw under an in-progress edit buffer.
printLiveIngressSnapshotWith
  :: (String -> IO ())
  -> ManifestReloadIngressManager
       ManifestReloadIngressTarget
       LiveProdIngressIssue
       LiveProdIngressHandle
  -> IO ()
printLiveIngressSnapshotWith output manager = do
  snapshot <- readManifestReloadIngressManager manager
  output ("  ingress: " <> renderLiveIngressSnapshot snapshot)


-- ---------------------------------------------------------------------------
-- Initial-open issue rendering
-- ---------------------------------------------------------------------------

-- | Operator-facing renderer for a 'LiveProdIngressIssue'. The
-- @Maybe Int@ device id (the @optMidiDevice@ value at startup)
-- threads through so the MIDI arms can name the device the
-- operator selected. The @Nothing@ totality fallback exists so the
-- function stays total even if a future caller decides to render
-- a MIDI failure without a configured device id.
--
-- See the @\"Renderer seam for startup-time abort\"@ section in the
-- 3c design note.
renderLiveProdIngressIssue
  :: Maybe Int
  -> LiveProdIngressIssue
  -> String
renderLiveProdIngressIssue mDevice = \case
  LiiOSC (MoioiOpenFailed (MoloiBindFailed msg)) ->
    "OSC ingress open failed: bind failed: " <> msg
  LiiMIDI (MmioiSourceOpenFailed MmppNoInputDevice) ->
    "no input device for --midi-device " <> renderDeviceId mDevice
  LiiMIDI (MmioiSourceOpenFailed MmppOpenFailed) ->
    "PortMIDI open failed for --midi-device " <> renderDeviceId mDevice
  where
    renderDeviceId =
      maybe "(unset)" show
