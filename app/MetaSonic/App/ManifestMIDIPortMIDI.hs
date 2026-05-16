-- |
-- Module      : MetaSonic.App.ManifestMIDIPortMIDI
-- Description : PortMIDI-backed source factory for the manifest MIDI
--               ingress-ops adapter.
--
-- This module is the production-side counterpart of the @Chan@-backed
-- test factory used in
-- 'MetaSonic.Spec.AppManifestMIDIIngressOps' and
-- 'MetaSonic.Spec.AppManifestMIDIReloadE2E'. It produces a
-- 'ManifestMIDISourceFactory' that:
--
-- * Opens a PortMIDI input handle via 'openPortMIDISource'.
-- * Verifies the handle reports an input-capable device with
--   'portMIDISourceHasDevice' before wrapping it as a
--   'MIDIListenerSource'. A valid 'PortMIDISource' can exist without
--   a backing device — see the 'openPortMIDISource' docstring — so
--   the @hasDevice == False@ case is distinct from a @Nothing@ open
--   failure.
-- * Reports both failure shapes as 'ManifestMIDIPortMIDIError' so the
--   manifest ingress-ops adapter surfaces them as
--   'MmioiSourceOpenFailed'. Successful close calls
--   'closePortMIDISource' and returns 'Right ()'.
--
-- Test coverage caveats: only the 'MmppNoInputDevice' branch is
-- deterministic in CI (via the invalid-device-id idiom that the
-- upstream PortMIDI suite uses). The 'Nothing'-open branch is not
-- reachable on standard hosts and remains covered only by this
-- factory's mapping code. The device-active success path is also
-- off CI and should land as a manual / device-backed smoke after
-- this slice.

module MetaSonic.App.ManifestMIDIPortMIDI
  ( ManifestMIDIPortMIDIError (..)
  , manifestPortMIDISourceFactory
  ) where

import           MetaSonic.App.ManifestMIDIIngressOps
                                                  (ManifestMIDISourceFactory (..))
import           MetaSonic.Session.MIDIPortMIDI   (PortMIDISource,
                                                   PortMIDISourceOptions,
                                                   closePortMIDISource,
                                                   openPortMIDISource,
                                                   portMIDIListenerSource,
                                                   portMIDISourceHasDevice)


-- | Reasons the PortMIDI factory could not produce a usable source.
--
-- 'MmppOpenFailed' covers a 'Nothing' return from
-- 'openPortMIDISource' — typically a C-level allocation failure
-- before any device probing.
--
-- 'MmppNoInputDevice' covers the case where the source handle was
-- allocated but 'portMIDISourceHasDevice' is 'False'. The factory
-- closes the idle handle before returning so callers never see a
-- live but unusable 'PortMIDISource'.
data ManifestMIDIPortMIDIError
  = MmppOpenFailed
  | MmppNoInputDevice
  deriving (Eq, Show)

-- | Build a 'ManifestMIDISourceFactory' that opens a PortMIDI input
-- handle on demand.
--
-- Each 'mmsfOpenSource' call probes for an input-capable device and
-- surfaces failure as 'ManifestMIDIPortMIDIError'; the corresponding
-- 'mmsfCloseSource' calls 'closePortMIDISource' and always reports
-- 'Right ()' because the underlying close has no failure shape.
manifestPortMIDISourceFactory
  :: PortMIDISourceOptions
  -> ManifestMIDISourceFactory ManifestMIDIPortMIDIError PortMIDISource
manifestPortMIDISourceFactory opts = ManifestMIDISourceFactory
  { mmsfOpenSource = do
      mSource <- openPortMIDISource opts
      case mSource of
        Nothing ->
          pure (Left MmppOpenFailed)
        Just source -> do
          hasDevice <- portMIDISourceHasDevice source
          if hasDevice
            then
              pure (Right (source, portMIDIListenerSource opts source))
            else do
              -- The handle is closeable per the upstream contract;
              -- close it now so the caller never holds an idle
              -- source it cannot use.
              closePortMIDISource source
              pure (Left MmppNoInputDevice)
  , mmsfCloseSource = \source -> do
      closePortMIDISource source
      pure (Right ())
  }
