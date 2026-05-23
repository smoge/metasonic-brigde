-- |
-- Module      : MetaSonic.App.ManifestMIDIIngressOps
-- Description : Adapter from 'ManifestReloadIngressTarget' to
--               'ManifestReloadIngressOps' for the manifest MIDI path.
--
-- This module is the MIDI analogue of
-- 'MetaSonic.App.ManifestOSCIngressOps'. It produces a
-- 'ManifestReloadIngressOps' value that the ingress manager can drive
-- against the combined manifest target. 'mrioOpenIngress' opens a
-- decoded-event source through the caller-supplied bracket-shaped
-- factory and starts a 'ManifestMIDIListener' over the combined
-- target's MIDI projection (@mitMIDI target@). 'mrioCloseIngress'
-- stops the listener first (so the polling owner detaches before the
-- source closes), then releases the source.
--
-- Close-failure policy: source close happens AFTER the listener is
-- already stopped, so a failed source close leaves the handle with
-- a dead worker. To keep the ingress manager's state honest,
-- 'mrioCloseIngress' always reports a successful close to the
-- manager and surfaces source-close failures through the
-- adapter-level hook 'mmioohOnSourceCloseFailed'. From the
-- manager's perspective, a failed cleanup looks like a normal
-- close; the host that subscribed to the hook learns about the
-- cleanup failure and can decide whether to alert the operator or
-- attempt a fresh open later. The handle is not revivable from
-- this state; any continuation goes through a new openFresh cycle.
--
-- The factory is bracket-shaped because a real source (PortMIDI) owns
-- a device handle whose lifetime must be paired with a close action.
-- A test source backed by a 'Chan' can supply a trivial handle and a
-- no-op close so CI stays runnable without MIDI hardware. A production
-- PortMIDI factory wraps 'openPortMIDISource' /
-- 'closePortMIDISource' and yields 'portMIDIListenerSource'.

module MetaSonic.App.ManifestMIDIIngressOps
  ( -- * Source factory
    ManifestMIDISourceFactory (..)

    -- * Adapter handle
  , ManifestMIDIIngressHandle (..)

    -- * Adapter-level issue
  , ManifestMIDIIngressOpsIssue (..)

    -- * Adapter hooks
  , ManifestMIDIIngressOpsHooks (..)
  , defaultManifestMIDIIngressOpsHooks

    -- * Adapter
  , manifestMIDIIngressOps
  , manifestMIDIIngressOpsWithTargetHooks
  ) where

import           MetaSonic.App.ManifestMIDIListener
                                                  (ManifestMIDIListenerHandle,
                                                   ManifestMIDIListenerHooks,
                                                   closeManifestMIDIListener,
                                                   openManifestMIDIListener)
import           MetaSonic.App.ManifestReloadIngress
                                                  (ManifestReloadIngressOps (..))
import           MetaSonic.App.ManifestReloadIngressTarget
                                                  (ManifestReloadIngressTarget (..))
import           MetaSonic.Session.FanIn          (SessionFanInHost)
import           MetaSonic.Session.MIDIListener   (MIDIListenerSource)
import           MetaSonic.Session.MIDIProducer   (MIDIProducerOptions)


-- | Bracket-shaped factory for decoded-event sources.
--
-- 'mmsfOpenSource' allocates whatever resources the source needs (e.g.
-- a PortMIDI device) and returns a caller-typed source handle plus the
-- 'MIDIListenerSource' the listener will poll. 'mmsfCloseSource'
-- releases those resources; close failure surfaces through the
-- adapter-level 'mmioohOnSourceCloseFailed' hook (see the module
-- header for the rationale).
--
-- The handle type and issue type are caller-chosen so a PortMIDI
-- factory can use 'MetaSonic.Session.MIDIPortMIDI.PortMIDISource' as
-- its handle and the test factory can use a trivial unit handle.
data ManifestMIDISourceFactory issue source =
  ManifestMIDISourceFactory
    { mmsfOpenSource  :: !(IO (Either issue (source, MIDIListenerSource)))
    , mmsfCloseSource :: !(source -> IO (Either issue ()))
    }

-- | One opened MIDI ingress generation.
--
-- The handle owns both pieces: the caller-typed source handle (released
-- via 'mmsfCloseSource') and the listener worker (released via
-- 'closeManifestMIDIListener'). The close order is listener first,
-- source second, matching the PortMIDI single-consumer contract.
data ManifestMIDIIngressHandle source = ManifestMIDIIngressHandle
  { mmihSourceHandle :: !source
  , mmihListener     :: !ManifestMIDIListenerHandle
  }

instance Show source => Show (ManifestMIDIIngressHandle source) where
  show handle =
    "ManifestMIDIIngressHandle { mmihSourceHandle = "
    <> show (mmihSourceHandle handle)
    <> ", mmihListener = <handle> }"

-- | Adapter-level issue, parameterized on the caller-typed source
-- issue.
--
-- Only the open path can fail through the ingress-manager's return
-- type: per the close-failure policy in this module's header,
-- source-close failures are reported via the
-- 'mmioohOnSourceCloseFailed' hook so the ingress manager still
-- observes a successful close. If 'openManifestMIDIListener' ever
-- grows a failure shape, add a listener-open constructor here.
newtype ManifestMIDIIngressOpsIssue issue
  = MmioiSourceOpenFailed issue
  deriving (Eq, Show)

-- | Adapter-level hooks.
--
-- 'mmioohOnSourceCloseFailed' fires when the factory's
-- 'mmsfCloseSource' returns 'Left' after the listener has already
-- been stopped. The handle cannot be revived from this state; the
-- ingress manager observes a successful close so its state stays
-- honest, and the hook lets the host decide how to handle the
-- partial-cleanup failure (operator alert, retry on a fresh source,
-- escalate to stopped-audio).
newtype ManifestMIDIIngressOpsHooks issue = ManifestMIDIIngressOpsHooks
  { mmioohOnSourceCloseFailed :: issue -> IO ()
  }

defaultManifestMIDIIngressOpsHooks :: ManifestMIDIIngressOpsHooks issue
defaultManifestMIDIIngressOpsHooks = ManifestMIDIIngressOpsHooks
  { mmioohOnSourceCloseFailed =
      \_ -> pure ()
  }

-- | Build a 'ManifestReloadIngressOps' with a fixed
-- 'ManifestMIDIListenerHooks'. Backwards-compatible wrapper around
-- 'manifestMIDIIngressOpsWithTargetHooks'; callers that do not need
-- per-generation hook metadata keep their existing call site
-- unchanged.
--
-- See 'manifestMIDIIngressOpsWithTargetHooks' for the open / close
-- lifecycle, the source-factory contract, and the close-failure
-- policy.
manifestMIDIIngressOps
  :: ManifestMIDIListenerHooks
  -> ManifestMIDIIngressOpsHooks issue
  -> MIDIProducerOptions
  -> SessionFanInHost
  -> ManifestMIDISourceFactory issue source
  -> ManifestReloadIngressOps
       ManifestReloadIngressTarget
       (ManifestMIDIIngressOpsIssue issue)
       (ManifestMIDIIngressHandle source)
manifestMIDIIngressOps listenerHooks =
  manifestMIDIIngressOpsWithTargetHooks (const listenerHooks)


-- | Build a 'ManifestReloadIngressOps' that opens a fresh MIDI
-- source + listener pair on each call and releases them on close.
-- The listener hooks are built from the just-projected target on
-- every 'mrioOpenIngress' so callers can render or observe against
-- the current generation's binding metadata
-- (@'MetaSonic.App.ManifestReloadMIDIBinding.mmitControls'@) rather
-- than the metadata captured at construction time.
--
-- This is the MIDI analogue of
-- 'MetaSonic.App.ManifestOSCIngressOps.manifestOSCIngressOpsWithTargetHooks'.
-- The Phase 8h step 3c live-session pass needs the per-target form
-- so accept-line rendering survives a preserving reload that swaps
-- one CC binding for another (see
-- @notes\/2026-05-23-c-live-values-portmidi-ingress-design.md@).
--
-- Adapter hooks, producer options, the fan-in host, and the source
-- factory are captured at construction time; the source factory is
-- consulted per open so a preserving reload can replace the device
-- handle as part of the close-old\/open-fresh cycle.
manifestMIDIIngressOpsWithTargetHooks
  :: (ManifestReloadIngressTarget -> ManifestMIDIListenerHooks)
  -> ManifestMIDIIngressOpsHooks issue
  -> MIDIProducerOptions
  -> SessionFanInHost
  -> ManifestMIDISourceFactory issue source
  -> ManifestReloadIngressOps
       ManifestReloadIngressTarget
       (ManifestMIDIIngressOpsIssue issue)
       (ManifestMIDIIngressHandle source)
manifestMIDIIngressOpsWithTargetHooks listenerHooksFor adapterHooks opts host factory =
  ManifestReloadIngressOps
    { mrioOpenIngress =
        \target -> do
          opened <- mmsfOpenSource factory
          case opened of
            Left issue ->
              pure (Left (MmioiSourceOpenFailed issue))
            Right (sourceHandle, listenerSource) -> do
              listener <-
                openManifestMIDIListener
                  (listenerHooksFor target)
                  opts
                  (mitMIDI target)
                  host
                  listenerSource
              pure (Right ManifestMIDIIngressHandle
                { mmihSourceHandle =
                    sourceHandle
                , mmihListener =
                    listener
                })
    , mrioCloseIngress =
        \handle -> do
          -- Listener first: stops the polling owner so the source
          -- close has no live consumer. PortMIDI's source is
          -- single-consumer and requires this ordering; trivial test
          -- sources tolerate either order.
          closeManifestMIDIListener (mmihListener handle)
          closeResult <- mmsfCloseSource factory (mmihSourceHandle handle)
          case closeResult of
            Right () ->
              pure (Right ())
            Left issue -> do
              -- The listener is already stopped, so the handle is
              -- not revivable. Tell the manager the close
              -- succeeded (so its state goes to 'MrisClosed') and
              -- surface the cleanup failure through the hook for
              -- host-level handling. See this module's header for
              -- the policy rationale.
              mmioohOnSourceCloseFailed adapterHooks issue
              pure (Right ())
    }
