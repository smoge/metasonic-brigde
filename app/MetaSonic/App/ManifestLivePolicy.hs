{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.ManifestLivePolicy
-- Description : Pure live-app reload policy + runtime projection context.
--
-- This module is the first code slice from
-- @notes/2026-05-25-i-live-app-manifest-reload-policy.md@. It does not
-- wire 'MetaSonic.App.ManifestLiveSession.runManifestLiveSession' yet;
-- it only introduces the boundary:
--
--   * 'LiveAppReloadPolicy' is the *pure* policy record. The caller
--     constructs it — from CLI flags today, from a GUI form or config
--     file later. It declares the five axes named in the design note
--     (strategy resolver, ingress profile, arbitration profile,
--     resource policy), and carries the comparable sub-records the
--     supervisor lowers into 'RealReloadHostStackInputs'.
--
--   * 'LiveAppReloadContext' holds the runtime values that the
--     callback fields close over today inside
--     @runManifestLiveSession@: 'reloadEventsRef', 'audioEventsRef',
--     'lastRetiredRef', the line-discipline output sink, and the
--     ingress builder closure that takes a 'SessionFanInHost' and
--     returns a fresh ingress ops bundle. The context is intentionally
--     not part of the pure policy because the existing live session's
--     callbacks at @ManifestLiveSession.hs L1038–L1064@ capture refs
--     created at @L949–L972@, and any boundary that pretended those
--     callbacks were caller-supplied would either force the caller
--     into IO or duplicate the runtime state.
--
--   * 'projectLiveAppReloadPolicy' lowers @(policy, context)@ into a
--     concrete 'RealReloadHostStackInputs' typed for the production
--     ingress aliases 'LiveProdIngressIssue' / 'LiveProdIngressHandle'.
--     The strategy resolver is *not* read by the projector — strategy
--     selection picks which host stack factory to instantiate, which
--     happens above this projector. The resolver lives on the policy
--     for completeness (it is axis 1 from the note) and is consumed
--     directly by the caller.
--
-- The ingress builder in 'LiveAppReloadContext' takes the policy's
-- 'LiveIngressProfile' as its first argument so the projector can
-- partially-apply it before producing 'rrhsiBuildIngressOps'.
-- Without that signature the policy's 'lipOSCListenerConfig' and
-- 'lipMIDIDevice' would be silently ignored by the lowering, and the
-- caller would have to thread profile changes into the context
-- separately; the partial-application keeps the policy the single
-- source of truth for ingress shape.
--
-- The companion test 'MetaSonic.Spec.AppManifestLivePolicy' pins the
-- default projection against today's implicit
-- @runManifestLiveSession@ values and proves that flipping the
-- arbitration profile to 'TargetClaim' isolates the structural
-- change to 'sfsoArbitrationGatewayOptions'.

module MetaSonic.App.ManifestLivePolicy
  ( -- * Policy axes
    LiveStrategyResolver
  , LiveIngressProfile (..)
  , LiveArbitrationProfile (..)
  , defaultLiveArbitrationProfile
  , LiveResourcePolicy (..)
  , defaultLiveResourcePolicy

    -- * Pure policy
  , LiveAppReloadPolicy (..)
  , defaultLiveAppReloadPolicy
  , withLiveArbitrationGateway

    -- * Runtime projection context
  , LiveAppReloadContext (..)

    -- * Projector
  , projectLiveAppReloadPolicy
  ) where

import           Data.IORef                          (IORef, modifyIORef',
                                                      writeIORef)
import qualified Data.Map.Strict                     as M

import           MetaSonic.App.Demos                 (Demo)
import           MetaSonic.App.ManifestLiveCommon    (liveAudioOptions,
                                                      liveIngressTargetPolicy,
                                                      retiredVoiceKeyMap,
                                                      staleByReloadDrainHook)
import           MetaSonic.App.ManifestLiveIngressOps
                                                     (LiveProdIngressHandle,
                                                      LiveProdIngressIssue)
import           MetaSonic.App.ManifestReloadAudioEvent
                                                     (ManifestReloadAudioEvent)
import           MetaSonic.App.ManifestReloadEvent   (ManifestReloadEvent)
import           MetaSonic.App.ManifestReloadHost.Types
                                                     (ManifestReloadHostIssue,
                                                      ManifestReloadHostStrategy)
import           MetaSonic.App.ManifestReloadHostStack
                                                     (RealReloadHostStackInputs (..))
import           MetaSonic.App.ManifestReloadIngress (ManifestReloadIngressOps)
import           MetaSonic.App.ManifestReloadIngressTarget
                                                     (ManifestReloadIngressTarget,
                                                      ManifestReloadIngressTargetPolicy)
import           MetaSonic.OSC.Listen                (ListenerConfig)
import           MetaSonic.Pattern                   (VoiceKey)
import           MetaSonic.Session.ArbitrationGateway
                                                     (SessionArbitrationGatewayOptions,
                                                      defaultSessionArbitrationGatewayOptions)
import           MetaSonic.Session.FanIn             (SessionFanInAudioOptions,
                                                      SessionFanInHost,
                                                      defaultSessionFanInAudioFFI)
import           MetaSonic.Session.FanInService      (SessionFanInServiceHooks (..),
                                                      SessionFanInServiceOptions (..),
                                                      defaultSessionFanInServiceHooks,
                                                      defaultSessionFanInServiceOptions)
import           MetaSonic.Session.Owner             (SessionOwnerOptions,
                                                      defaultSessionOwnerOptions)
import           MetaSonic.Session.Resolve           (RetiredVoiceReason)


-- | Axis 1: strategy selection. A pure function from 'Demo' to the
-- 'ManifestReloadHostStrategy' to use for that demo's next reload.
-- Today's call site collapses this to @const strategy@ over the
-- single CLI-supplied strategy; future callers can supply a
-- per-demo table or a GUI-driven resolver without
-- @runManifestLiveSession@ growing a special case. The projector
-- does not consume the resolver — strategy selection picks the host
-- stack factory above the projector — so it is carried on the
-- policy for completeness.
type LiveStrategyResolver = Demo -> ManifestReloadHostStrategy

-- | Axis 2: ingress lifecycle. Today's live session always opens an
-- OSC half against a 'ListenerConfig' and conditionally opens a
-- MIDI half against a 'Maybe Int' device id, both carried as
-- @runManifestLiveSession@ arguments. The producer-side knobs
-- (producer options, listener hook composition) live in the
-- runtime context's @larcBuildIngressOps@ because they capture
-- runtime sinks; the policy carries the declarative shape only.
data LiveIngressProfile = LiveIngressProfile
  { lipOSCListenerConfig :: !ListenerConfig
  , lipMIDIDevice        :: !(Maybe Int)
  } deriving stock (Eq, Show)

-- | Axis 4: arbitration profile. 'Nothing' is today's implicit
-- behavior (no gateway, raw FIFO submission). 'Just' configures a
-- service-owned arbitration gateway whose policy survives across
-- reloads of the same session. Mutation of the policy *after*
-- gateway construction is not covered here — see the note's
-- non-goals for the use-case-gated mutation API.
newtype LiveArbitrationProfile = LiveArbitrationProfile
  { lapGatewayOptions :: Maybe SessionArbitrationGatewayOptions
  } deriving stock (Eq, Show)

-- | Today's implicit arbitration profile: no gateway, FIFO at the
-- service.
defaultLiveArbitrationProfile :: LiveArbitrationProfile
defaultLiveArbitrationProfile = LiveArbitrationProfile
  { lapGatewayOptions = Nothing
  }

-- | Axis 5: resource policy bundle. The comparable sub-records the
-- supervisor lowers into 'RealReloadHostStackInputs'. Each field
-- has an 'Eq' instance, so the projector test can assert
-- byte-equivalent structural equality without comparing function
-- fields. The non-Eq 'SessionFanInAudioFFI' stays hard-coded inside
-- the projector at 'defaultSessionFanInAudioFFI' because nothing
-- below it can be parameterized today; if a later use case needs
-- to override the FFI it earns its own field here.
data LiveResourcePolicy = LiveResourcePolicy
  { lrpAudioOptions        :: !SessionFanInAudioOptions
  , lrpOwnerOptions        :: !SessionOwnerOptions
  , lrpServiceOptions      :: !SessionFanInServiceOptions
  , lrpIngressTargetPolicy :: !ManifestReloadIngressTargetPolicy
  } deriving stock (Eq, Show)

-- | The default resource policy matches the values
-- @runManifestLiveSession@ currently hard-codes at
-- @ManifestLiveSession.hs L1043–L1047@.
defaultLiveResourcePolicy :: LiveResourcePolicy
defaultLiveResourcePolicy = LiveResourcePolicy
  { lrpAudioOptions        = liveAudioOptions
  , lrpOwnerOptions        = defaultSessionOwnerOptions
  , lrpServiceOptions      = defaultSessionFanInServiceOptions
  , lrpIngressTargetPolicy = liveIngressTargetPolicy
  }

-- | The pure live-app reload policy. Constructed by the caller; not
-- 'Eq' as a whole because 'larpStrategyResolver' is a function.
-- Tests compare the sub-records individually.
data LiveAppReloadPolicy = LiveAppReloadPolicy
  { larpStrategyResolver   :: LiveStrategyResolver
  , larpIngressProfile     :: !LiveIngressProfile
  , larpArbitrationProfile :: !LiveArbitrationProfile
  , larpResourcePolicy     :: !LiveResourcePolicy
  }

-- | Construct the policy that matches today's implicit
-- @runManifestLiveSession@ behavior from the CLI-supplied
-- strategy, OSC listener config, and optional MIDI device id.
-- The strategy resolver is @const strategy@ so every demo uses
-- the same supplied strategy.
defaultLiveAppReloadPolicy
  :: ManifestReloadHostStrategy
  -> ListenerConfig
  -> Maybe Int
  -> LiveAppReloadPolicy
defaultLiveAppReloadPolicy strategy cfg mMidiDevice = LiveAppReloadPolicy
  { larpStrategyResolver   = const strategy
  , larpIngressProfile     = LiveIngressProfile
      { lipOSCListenerConfig = cfg
      , lipMIDIDevice        = mMidiDevice
      }
  , larpArbitrationProfile = defaultLiveArbitrationProfile
  , larpResourcePolicy     = defaultLiveResourcePolicy
  }

-- | Override the arbitration profile on a live-app reload policy.
-- When the flag is 'True', 'larpArbitrationProfile' becomes
-- @'LiveArbitrationProfile' ('Just' 'defaultSessionArbitrationGatewayOptions')@:
-- the service-owned arbitration gateway is active with the default
-- 'FifoOnly' policy, which adds an admission-control + observability
-- pathway above the raw FIFO. When 'False', the policy is returned
-- unchanged, preserving today's no-gateway behavior.
--
-- This is the smallest opt-in surface for axis 4 of the live-app
-- reload policy. Richer arbitration shapes ('ProducerPriority',
-- 'TargetClaim' with a populated table) carry structured data and
-- wait for a config-file or GUI surface.
withLiveArbitrationGateway :: Bool -> LiveAppReloadPolicy -> LiveAppReloadPolicy
withLiveArbitrationGateway False policy = policy
withLiveArbitrationGateway True  policy = policy
  { larpArbitrationProfile = LiveArbitrationProfile
      { lapGatewayOptions = Just defaultSessionArbitrationGatewayOptions
      }
  }

-- | Runtime projection context. Holds the IORefs and sinks that
-- today's @runManifestLiveSession@ allocates in its body and that
-- the lowered callbacks close over. Not 'Eq' (IORefs and functions).
--
-- 'larcBuildIngressOps' is the runtime-resolved ingress builder
-- factory. It takes the policy's 'LiveIngressProfile' (so the
-- builder can read 'lipOSCListenerConfig' and 'lipMIDIDevice' when
-- constructing the OSC / MIDI ops bundle) and a just-opened
-- 'SessionFanInHost', and returns the fresh ingress ops bundle. In
-- production wiring this closes over the per-session sinks
-- ('recordAccepted', 'extPrintDyn'-shaped output) and producer
-- options; the projector partially-applies the policy's profile
-- before storing the resulting @SessionFanInHost -> ops@ in
-- 'rrhsiBuildIngressOps'. Test fixtures that do not need to
-- exercise ingress opening can install a factory that errors on
-- call.
data LiveAppReloadContext = LiveAppReloadContext
  { larcReloadEventsRef :: !(IORef
      [ManifestReloadEvent (ManifestReloadHostIssue LiveProdIngressIssue)])
  , larcAudioEventsRef  :: !(IORef
      [ManifestReloadAudioEvent (ManifestReloadHostIssue LiveProdIngressIssue)])
  , larcLastRetiredRef  :: !(IORef (M.Map VoiceKey RetiredVoiceReason))
  , larcExtPrint        :: !(String -> IO ())
  , larcBuildIngressOps :: !(LiveIngressProfile
      -> SessionFanInHost
      -> ManifestReloadIngressOps
           ManifestReloadIngressTarget
           LiveProdIngressIssue
           LiveProdIngressHandle)
  }

-- | Project @(policy, context)@ into the concrete
-- 'RealReloadHostStackInputs' the host stack factories consume.
--
-- The projector reads the comparable sub-records out of the
-- policy's resource bundle, overlays the arbitration profile
-- onto the service options (the only structural change the
-- arbitration axis makes), composes the stale-by-reload drain
-- hook from the context's retired-set ref and print sink, and
-- threads the context's IORef-writing callbacks into the lifecycle
-- event fields. The audio FFI is hard-coded to
-- 'defaultSessionFanInAudioFFI' (see 'LiveResourcePolicy' note).
projectLiveAppReloadPolicy
  :: LiveAppReloadPolicy
  -> LiveAppReloadContext
  -> RealReloadHostStackInputs LiveProdIngressIssue LiveProdIngressHandle
projectLiveAppReloadPolicy policy ctx =
  RealReloadHostStackInputs
    { rrhsiBuildIngressOps     =
        larcBuildIngressOps ctx (larpIngressProfile policy)
    , rrhsiIngressTargetPolicy = lrpIngressTargetPolicy resource
    , rrhsiAudioFFI            = defaultSessionFanInAudioFFI
    , rrhsiAudioOptions        = lrpAudioOptions resource
    , rrhsiOwnerOptions        = lrpOwnerOptions resource
    , rrhsiServiceOptions      = serviceOpts
    , rrhsiServiceHooks        = serviceHooks
    , rrhsiOnEvent             = \ev ->
        modifyIORef' (larcReloadEventsRef ctx) (<> [ev])
    , rrhsiOnAudioEvent        = \ev ->
        modifyIORef' (larcAudioEventsRef ctx) (<> [ev])
    , rrhsiOnRetired           =
        writeIORef (larcLastRetiredRef ctx) . retiredVoiceKeyMap
    }
  where
    resource     = larpResourcePolicy policy
    arbitration  = larpArbitrationProfile policy
    serviceOpts  = (lrpServiceOptions resource)
      { sfsoArbitrationGatewayOptions = lapGatewayOptions arbitration
      }
    serviceHooks = defaultSessionFanInServiceHooks
      { sfshOnDrain =
          staleByReloadDrainHook
            (larcLastRetiredRef ctx)
            (larcExtPrint ctx)
      }
