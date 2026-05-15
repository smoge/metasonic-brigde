-- |
-- Module      : MetaSonic.App.ManifestOSCIngressOps
-- Description : Adapter from 'ManifestReloadIngressTarget' to
--               'ManifestReloadIngressOps' for device-backed OSC.
--
-- This module is step 2 of device-backed OSC: it produces an
-- 'ManifestReloadIngressOps' value that the ingress manager can drive
-- against the combined manifest target. 'mrioOpenIngress' binds a real
-- UDP listener through 'openManifestOSCListener' against the OSC
-- projection (@mitOSC target@); 'mrioCloseIngress' closes the listener
-- handle.
--
-- Only the OSC slice is wired here. UI and MIDI projections still ride
-- inside the same 'ManifestReloadIngressTarget' for future steps; the
-- ops value carries them through unchanged.

module MetaSonic.App.ManifestOSCIngressOps
  ( ManifestOSCIngressHandle (..)
  , ManifestOSCIngressOpsIssue (..)
  , manifestOSCIngressOps
  ) where

import           MetaSonic.App.ManifestOSCListener
                                                  (ListenerConfig,
                                                   ListenerInfo,
                                                   ManifestOSCListenerHandle,
                                                   ManifestOSCListenerHooks,
                                                   ManifestOSCListenerOpenIssue,
                                                   closeManifestOSCListener,
                                                   openManifestOSCListener)
import           MetaSonic.App.ManifestReloadIngress
                                                  (ManifestReloadIngressOps (..))
import           MetaSonic.App.ManifestReloadIngressTarget
                                                  (ManifestReloadIngressTarget (..))
import           MetaSonic.Session.FanIn          (SessionFanInHost)
import           MetaSonic.Session.OSCProducer    (OSCProducerOptions)


-- | One opened OSC ingress generation.
--
-- 'moihListener' owns the UDP socket and listener thread.
-- 'moihInfo' is retained for diagnostics so callers (and snapshots)
-- can see the bound port without re-querying the socket.
data ManifestOSCIngressHandle = ManifestOSCIngressHandle
  { moihListener :: !ManifestOSCListenerHandle
  , moihInfo     :: !ListenerInfo
  }

-- | Adapter-level issue.
--
-- Today this only wraps an open failure from the underlying listener.
-- Close is always reported as success because
-- 'closeManifestOSCListener' has no failure shape — it signals the
-- worker and waits for cleanup.
newtype ManifestOSCIngressOpsIssue
  = MoioiOpenFailed ManifestOSCListenerOpenIssue
  deriving (Eq, Show)

-- | Build a 'ManifestReloadIngressOps' that opens and closes a
-- device-backed OSC listener for the OSC projection of the supplied
-- combined target.
--
-- Listener hooks, producer options, fan-in host, and the listener
-- bind configuration are captured at construction time. Each open
-- reuses these so a preserving reload can reopen against the same
-- bind config — operators stay pointed at one UDP port across
-- reloads when @lcPort@ is non-zero; with @lcPort = 0@ the kernel
-- picks a new ephemeral port per open.
manifestOSCIngressOps
  :: ManifestOSCListenerHooks
  -> OSCProducerOptions
  -> SessionFanInHost
  -> ListenerConfig
  -> ManifestReloadIngressOps
       ManifestReloadIngressTarget
       ManifestOSCIngressOpsIssue
       ManifestOSCIngressHandle
manifestOSCIngressOps hooks opts host cfg = ManifestReloadIngressOps
  { mrioOpenIngress =
      \target -> do
        result <-
          openManifestOSCListener
            hooks
            opts
            (mitOSC target)
            host
            cfg
        case result of
          Left issue ->
            pure (Left (MoioiOpenFailed issue))
          Right (listener, info) ->
            pure (Right ManifestOSCIngressHandle
              { moihListener =
                  listener
              , moihInfo =
                  info
              })
  , mrioCloseIngress =
      \handle -> do
        closeManifestOSCListener (moihListener handle)
        pure (Right ())
  }
