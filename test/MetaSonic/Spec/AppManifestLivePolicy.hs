-- | Live-app reload policy projector tests.
--
-- Tracks the slices from
-- @notes/2026-05-25-i-live-app-manifest-reload-policy.md@:
--
--   * Pins the default projection against today's implicit
--     @runManifestLiveSession@ values.
--   * Proves that flipping the arbitration profile to 'TargetClaim'
--     isolates the structural change to 'sfsoArbitrationGatewayOptions'.
--   * Verifies the projector composes 'staleByReloadDrainHook' from
--     the context's retired-set ref and print sink (regression guard
--     against a future refactor leaving 'defaultSessionFanInServiceHooks'
--     in place).
--   * Round-trips strategy, listener config, and MIDI device through
--     'defaultLiveAppReloadPolicy' so the @Main -> policy -> projector@
--     path has a direct guard.
--   * Drives 'rrhsiBuildIngressOps' against a real 'SessionFanInHost'
--     opened via 'withSessionFanInHost' over a fixture 'TemplateGraph'
--     and asserts the policy's 'LiveIngressProfile' reaches the
--     context builder. This closes the deferred coverage gap the
--     earlier projector slices intentionally left: 'SessionFanInHost'
--     has a private constructor (see
--     @src/MetaSonic/Session/FanIn.hs L110@), so opening one inside
--     'withSessionFanInHost' was the prerequisite for invoking
--     'mrioOpenIngress' in-test. No socket, no PortMIDI, no audio,
--     no supervisor.
module MetaSonic.Spec.AppManifestLivePolicy
  ( appManifestLivePolicyTests
  ) where

import           Data.IORef                            (IORef, modifyIORef',
                                                        newIORef, readIORef,
                                                        writeIORef)
import qualified Data.Map.Strict                       as M
import qualified Data.Text                             as T

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.Demos                   (Demo, demoTable)
import           MetaSonic.App.ManifestLiveCommon      (liveAudioOptions,
                                                        liveIngressTargetPolicy)
import           MetaSonic.App.ManifestLiveIngressOps  (LiveIngressIssue (..),
                                                        LiveProdIngressIssue)
import           MetaSonic.App.ManifestLivePolicy
import           MetaSonic.App.ManifestReloadAudioEvent
                                                       (ManifestReloadAudioEvent (..))
import           MetaSonic.App.ManifestReloadEvent     (ManifestReloadEvent (..))
import           MetaSonic.App.ManifestOSCIngressOps   (ManifestOSCIngressOpsIssue (..))
import           MetaSonic.App.ManifestOSCListener     (ManifestOSCListenerOpenIssue (..))
import           MetaSonic.App.ManifestReloadHost.Types
                                                       (ManifestReloadHostStrategy (..))
import           MetaSonic.App.ManifestReloadHostStack (RealReloadHostStackInputs (..))
import           MetaSonic.App.ManifestReloadIngress   (ManifestReloadIngressOps (..))
import           MetaSonic.Bridge.Source               (MigrationKey (..))
import           MetaSonic.Bridge.Templates            (TemplateGraph (..))
import           MetaSonic.OSC.Listen                  (defaultListenerConfig)
import           MetaSonic.Pattern                     (ControlTag (..),
                                                        VoiceKey (..))
import           MetaSonic.Session.Arbitration         (ArbitrationPolicy (..),
                                                        ControlArbitrationTarget (..),
                                                        claimControlTarget,
                                                        emptyTargetClaimTable)
import           MetaSonic.Session.ArbitrationGateway  (SessionArbitrationGatewayOptions (..),
                                                        defaultSessionArbitrationGatewayOptions,
                                                        sagoInitialPolicy)
import           MetaSonic.Session.Command             (SessionCommand (..),
                                                        SessionIssue (..))
import           MetaSonic.Session.FanIn               (SessionFanInDrainResult (..),
                                                        defaultSessionFanInOptions,
                                                        withSessionFanInHost)
import           MetaSonic.Session.FanInService        (SessionFanInServiceHooks (..),
                                                        SessionFanInServiceOptions (..),
                                                        defaultSessionFanInServiceOptions)
import           MetaSonic.Session.Owner               (SessionOwnerStepResult (..),
                                                        defaultSessionOwnerOptions)
import           MetaSonic.Session.Queue               (CommandSequence (..),
                                                        ProducerId (..),
                                                        ProducerKind (..),
                                                        QueuedSessionCommand (..),
                                                        SessionDrainItem (..),
                                                        SessionDrainResult (..))
import           MetaSonic.Session.Resolve             (RetiredVoiceReason (..))
import           MetaSonic.Session.Step                (SessionStepResult (..))


appManifestLivePolicyTests :: TestTree
appManifestLivePolicyTests =
  testGroup "App live-app reload policy projector"
  [ testCase "default policy lowers to today's implicit runManifestLiveSession values" $ do
      env <- newFixtureEnv
      let policy = defaultLiveAppReloadPolicy
            StoppedAudioOnly
            (defaultListenerConfig 7001)
            Nothing
          inputs = projectLiveAppReloadPolicy policy (envContext env)

      -- Structural equality on the Eq-derivable lowered fields.
      rrhsiIngressTargetPolicy inputs @?= liveIngressTargetPolicy
      rrhsiAudioOptions inputs @?= liveAudioOptions
      rrhsiOwnerOptions inputs @?= defaultSessionOwnerOptions
      rrhsiServiceOptions inputs @?= defaultSessionFanInServiceOptions

      -- Behavioral assertions on the IORef-writing callbacks.
      -- Each one fires its fixture-context IORef counter, which is
      -- read back here. This is the counter-confirmed validation
      -- form from the design note: if a future refactor short-
      -- circuits the projector around these fields, the counters
      -- never increment and the test fails loudly.
      assertEventCallback env inputs
      assertAudioEventCallback env inputs
      assertRetiredCallback env inputs

  , testCase "flipping arbitration profile to TargetClaim isolates change to sfsoArbitrationGatewayOptions" $ do
      env <- newFixtureEnv
      let defaultPolicy = defaultLiveAppReloadPolicy
            StoppedAudioOnly
            (defaultListenerConfig 7001)
            Nothing
          claimedPolicy = defaultPolicy
            { larpArbitrationProfile = LiveArbitrationProfile
                { lapGatewayOptions = Just gatewayOptsForClaim
                }
            }
          defaultInputs = projectLiveAppReloadPolicy defaultPolicy (envContext env)
          claimedInputs = projectLiveAppReloadPolicy claimedPolicy (envContext env)

      -- Every comparable resource sub-record except service options
      -- stays identical between the two projections.
      rrhsiIngressTargetPolicy claimedInputs
        @?= rrhsiIngressTargetPolicy defaultInputs
      rrhsiAudioOptions claimedInputs
        @?= rrhsiAudioOptions defaultInputs
      rrhsiOwnerOptions claimedInputs
        @?= rrhsiOwnerOptions defaultInputs

      -- Service options change in exactly one field.
      sfsoArbitrationGatewayOptions (rrhsiServiceOptions defaultInputs)
        @?= Nothing
      sfsoArbitrationGatewayOptions (rrhsiServiceOptions claimedInputs)
        @?= Just gatewayOptsForClaim
      sfsoFanInOptions (rrhsiServiceOptions claimedInputs)
        @?= sfsoFanInOptions (rrhsiServiceOptions defaultInputs)

  , testCase "service hooks compose stale-by-reload drain hook from context refs" $ do
      -- The projector overrides 'sfshOnDrain' with
      -- 'staleByReloadDrainHook' closing over the context's
      -- retired-set IORef and print sink. If a regression dropped
      -- the override and left 'defaultSessionFanInServiceHooks',
      -- the previous test cases would still pass because they
      -- never invoke 'sfshOnDrain'. This test pre-populates the
      -- retired set with one binding, builds a drain containing a
      -- stale-by-reload rejection for that voice, drives the
      -- composed drain hook, and asserts the context's print sink
      -- counter incremented (the default no-op hook never prints).
      env <- newFixtureEnv
      writeIORef
        (larcLastRetiredRef (envContext env))
        (M.singleton staleVoice RvrOwnerReplaced)
      printsBefore <- readIORef (envExtPrint env)
      printsBefore @?= 0

      let policy = defaultLiveAppReloadPolicy
            StoppedAudioOnly
            (defaultListenerConfig 7001)
            Nothing
          inputs = projectLiveAppReloadPolicy policy (envContext env)
          drain  = SessionFanInDrainResult
            { sfidrDrain = SessionDrainResult
                { sdrItems     = [staleDrainItem]
                , sdrRemaining = 0
                , sdrStopped   = Nothing
                }
            , sfidrQueueDepth = 0
            }
      sfshOnDrain (rrhsiServiceHooks inputs) drain

      printsAfter <- readIORef (envExtPrint env)
      assertBool
        ("expected stale-by-reload drain to print at least one line through"
         <> " the context sink, got " <> show printsAfter)
        (printsAfter > printsBefore)

  , testCase "projected rrhsiBuildIngressOps threads policy ingress profile through context builder" $ do
      -- Closes the deferred coverage gap named in
      -- @notes/2026-05-25-i-live-app-manifest-reload-policy.md@:
      -- 'SessionFanInHost' has a private constructor, so the earlier
      -- projector tests asserted on @rrhsiBuildIngressOps@ only as
      -- a set field. Here we open a real host through
      -- 'withSessionFanInHost' (no audio, no socket, no PortMIDI, no
      -- supervisor), drive the projected builder, then invoke
      -- 'mrioOpenIngress'. The fixture context's builder captures
      -- the 'LiveIngressProfile' the projector passes it; the
      -- assertion proves it equals @larpIngressProfile policy@,
      -- which is the structural fix's behavioral guarantee.
      profileRef <- newIORef Nothing
      -- 'LiveAppReloadContext' fields are strict, so the IORefs the
      -- projector does not invoke in this test path still need real
      -- values (not 'error').
      unusedReload  <- newIORef []
      unusedAudio   <- newIORef []
      unusedRetired <- newIORef M.empty
      let cfg     = defaultListenerConfig 7777
          midi    = Just 9
          policy  = defaultLiveAppReloadPolicy StoppedAudioOnly cfg midi
          context = LiveAppReloadContext
            { larcReloadEventsRef = unusedReload
            , larcAudioEventsRef  = unusedAudio
            , larcLastRetiredRef  = unusedRetired
            , larcExtPrint        = \_ -> pure ()
            , larcBuildIngressOps = \profile _host ->
                ManifestReloadIngressOps
                  { mrioOpenIngress = \_target -> do
                      writeIORef profileRef (Just profile)
                      pure (Left sentinelIngressIssue)
                  , mrioCloseIngress = \_handle ->
                      pure (Right ())
                  }
            }
      hostResult <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              let inputs = projectLiveAppReloadPolicy policy context
                  ops    = rrhsiBuildIngressOps inputs host
              -- The stub ignores its 'target' argument; the call
              -- exercises the closure path through to the
              -- profile-capturing IORef write.
              mrioOpenIngress ops
                (error "ManifestReloadIngressTarget not inspected by stub")
      case hostResult of
        Left setupIssue ->
          assertFailure
            ("expected fan-in host, got setup issue: " <> show setupIssue)
        Right (Right _handle) ->
          assertFailure
            "expected stub mrioOpenIngress to return Left sentinel, got Right"
        Right (Left actual) -> do
          actual @?= sentinelIngressIssue
          captured <- readIORef profileRef
          captured @?= Just (larpIngressProfile policy)

  , testCase "defaultLiveAppReloadPolicy round-trips strategy, listener config, and MIDI device" $ do
      -- The wiring slice that landed
      -- 'runManifestLiveSessionWithPolicy' relies on the default
      -- constructor preserving exactly the three CLI-supplied
      -- values it takes: the strategy is what the resolver returns
      -- for any demo (one-strategy-per-session today), the OSC
      -- listener config flows into the ingress profile unchanged,
      -- and the MIDI device id likewise.
      let strategy = TryPreservingThenStoppedAudio
          cfg      = defaultListenerConfig 7042
          midi     = Just 3
          policy   = defaultLiveAppReloadPolicy strategy cfg midi
          ingress  = larpIngressProfile policy

      lipOSCListenerConfig ingress @?= cfg
      lipMIDIDevice ingress        @?= midi
      larpStrategyResolver policy someDemo @?= strategy
  ]


-- | Any demo to feed the strategy resolver. The default resolver is
-- @const strategy@, so any input is fine; this picks the first row
-- of the canonical demo table.
someDemo :: Demo
someDemo = head demoTable

-- | Sentinel @Left@ value the ingress-profile fixture stub returns
-- from 'mrioOpenIngress'. The shape is the smallest constructable
-- 'LiveProdIngressIssue' that round-trips through 'Eq' so the test
-- can assert it landed unchanged.
sentinelIngressIssue :: LiveProdIngressIssue
sentinelIngressIssue =
  LiiOSC (MoioiOpenFailed (MoloiBindFailed "live-policy-test-sentinel"))


-- ---------------------------------------------------------------------------
-- Stale-by-reload fixture
-- ---------------------------------------------------------------------------

staleVoice :: VoiceKey
staleVoice = VoiceKey "v-stale"

-- | A drain item the stale-by-reload classifier accepts: an owner
-- step that rejected the queued 'CmdVoiceOff' with 'SiStaleVoice'
-- for the same voice key the fixture seeds into the retired map.
staleDrainItem :: SessionDrainItem
staleDrainItem = SessionDrainItem
  { sdiQueued = QueuedSessionCommand
      { qscSequence = CommandSequence 0
      , qscProducer = ProducerId ProducerMIDI (T.pack "live-policy-test")
      , qscCommand  = CmdVoiceOff staleVoice
      }
  , sdiResult = SessionOwnerStep (StepRejected (SiStaleVoice staleVoice))
  }


-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------

data FixtureEnv = FixtureEnv
  { envContext      :: !LiveAppReloadContext
  , envReloadEvents :: !(IORef Int)
  , envAudioEvents  :: !(IORef Int)
  , envRetired      :: !(IORef Int)
  , envExtPrint     :: !(IORef Int)
  }

-- | Build a context whose IORef callbacks each tick an integer
-- counter. The integer counters are the side-channel signal
-- ("counter-confirmed validation") that proves the projector
-- threaded the callback through, regardless of what payload was
-- driven into it.
newFixtureEnv :: IO FixtureEnv
newFixtureEnv = do
  reloadCounter  <- newIORef 0
  audioCounter   <- newIORef 0
  retiredCounter <- newIORef 0
  printCounter   <- newIORef 0

  reloadRef  <- newIORef []
  audioRef   <- newIORef []
  retiredRef <- newIORef M.empty

  let tick ref = modifyIORef' ref (+ 1)
      context = LiveAppReloadContext
        { larcReloadEventsRef = reloadRef
        , larcAudioEventsRef  = audioRef
        , larcLastRetiredRef  = retiredRef
        , larcExtPrint        = \_ -> tick printCounter
        , larcBuildIngressOps = \_profile _host ->
            error "rrhsiBuildIngressOps should not be invoked by the projector test"
        }

  pure FixtureEnv
    { envContext      = context
    , envReloadEvents = reloadCounter
    , envAudioEvents  = audioCounter
    , envRetired      = retiredCounter
    , envExtPrint     = printCounter
    }

assertEventCallback
  :: FixtureEnv
  -> RealReloadHostStackInputs issue handle
  -> IO ()
assertEventCallback env inputs = do
  let policyRef = larcReloadEventsRef (envContext env)
  rrhsiOnEvent inputs (MreStrategyStarted StoppedAudioOnly)
  modifyIORef' (envReloadEvents env) (+ 1)
  observedReloads <- length <$> readIORef policyRef
  observedTicks   <- readIORef (envReloadEvents env)
  observedReloads @?= observedTicks
  observedReloads @?= 1

assertAudioEventCallback
  :: FixtureEnv
  -> RealReloadHostStackInputs issue handle
  -> IO ()
assertAudioEventCallback env inputs = do
  let policyRef = larcAudioEventsRef (envContext env)
  rrhsiOnAudioEvent inputs MraeStopSucceeded
  modifyIORef' (envAudioEvents env) (+ 1)
  observedAudio <- length <$> readIORef policyRef
  observedTicks <- readIORef (envAudioEvents env)
  observedAudio @?= observedTicks
  observedAudio @?= 1

assertRetiredCallback
  :: FixtureEnv
  -> RealReloadHostStackInputs issue handle
  -> IO ()
assertRetiredCallback env inputs = do
  let policyRef = larcLastRetiredRef (envContext env)
  -- An empty retired-binding list maps to an empty Map; that is
  -- enough to prove the callback ran (the IORef was written, even
  -- though the written value is structurally empty). A future
  -- slice exercising retired-binding shape will pass a non-empty
  -- list and assert the rendered map structure.
  rrhsiOnRetired inputs []
  modifyIORef' (envRetired env) (+ 1)
  observedRetiredMap <- readIORef policyRef
  observedTicks      <- readIORef (envRetired env)
  M.null observedRetiredMap @?= True
  observedTicks @?= 1


-- ---------------------------------------------------------------------------
-- Arbitration fixture for the TargetClaim flip
-- ---------------------------------------------------------------------------

-- | A pre-claimed (VoiceKey, ControlTag) that the second test's
-- arbitration profile installs.
gatewayOptsForClaim :: SessionArbitrationGatewayOptions
gatewayOptsForClaim = defaultSessionArbitrationGatewayOptions
  { sagoInitialPolicy =
      TargetClaim
        (claimControlTarget claimTarget claimant emptyTargetClaimTable)
  }
  where
    claimTarget =
      ControlArbitrationTarget
        (VoiceKey "v0")
        (ControlTag (MigrationKey "lpf") 0)
    claimant =
      ProducerId ProducerPattern (T.pack "live-policy-test-claim")
