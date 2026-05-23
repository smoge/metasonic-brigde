-- |
-- Module      : MetaSonic.App.ManifestLiveIngressOps
-- Description : Combinator over OSC and optional MIDI ingress-ops for the
--               manifest live-session entrypoint.
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
-- issues). Production wiring specializes against
-- 'ManifestOSCIngressHandle' / 'ManifestMIDIIngressHandle PortMIDISource'
-- elsewhere; this module deliberately knows nothing about PortMIDI or
-- UDP. See @notes\/2026-05-23-c-live-values-portmidi-ingress-design.md@
-- for the surrounding 3c design.

module MetaSonic.App.ManifestLiveIngressOps
  ( -- * Bundled handle and issue
    LiveIngressHandle (..)
  , LiveIngressIssue (..)

    -- * Combinator
  , manifestLiveIngressOps
  ) where

import           MetaSonic.App.ManifestReloadIngress
                                                  (ManifestReloadIngressOps (..))


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
