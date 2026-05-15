-- | App-level tests for the device-backed OSC ingress-ops adapter.
module MetaSonic.Spec.AppManifestOSCIngressOps where

import           Control.Concurrent.MVar          (newEmptyMVar, putMVar,
                                                   takeMVar)
import           Data.IORef                       (newIORef, readIORef,
                                                   writeIORef)
import qualified Data.ByteString.Char8            as OBSC
import qualified Data.Map.Strict                  as M
import           System.Timeout                   (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestOSCIngressOps
import           MetaSonic.App.ManifestOSCListener
                                                  (ListenerInfo (..),
                                                   ManifestOSCListenerHooks (..),
                                                   ManifestOSCListenerOpenIssue (..),
                                                   defaultListenerConfig,
                                                   defaultManifestOSCListenerHooks)
import           MetaSonic.App.ManifestReloadIngress
                                                  (ManifestReloadIngressOps (..),
                                                   ManifestReloadIngressSnapshot (..),
                                                   closeManifestReloadIngress,
                                                   newManifestReloadIngressManager,
                                                   openFreshManifestReloadIngress,
                                                   readManifestReloadIngressManager)
import           MetaSonic.App.ManifestReloadBinding
                                                  (ManifestUIVoiceSelection (..))
import           MetaSonic.App.ManifestReloadIngressTarget
                                                  (ManifestReloadIngressTarget,
                                                   ManifestReloadIngressTargetPolicy (..),
                                                   manifestReloadIngressTargetFromPlan)
import           MetaSonic.Bridge.Source          (MigrationKey (..))
import           MetaSonic.Bridge.Templates       (TemplateGraph (..))
import           MetaSonic.Pattern                (ControlTag (..),
                                                   SwapLabel (..),
                                                   VoiceKey (..))
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy (..))
import           MetaSonic.Session.Command        (SessionCommand (..))
import           MetaSonic.Session.FanIn          (SessionFanInSnapshot (..),
                                                   defaultSessionFanInOptions,
                                                   readSessionFanInHost,
                                                   withSessionFanInHost)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.OSCProducer    (OSCProducerEnqueueResult (..),
                                                   defaultOSCProducerOptions)
import           MetaSonic.Session.RTGraphAdapter (defaultRTGraphAdapterOptions)
import           MetaSonic.Spec.Core              (sendUdpLoopback)


appManifestOSCIngressOpsTests :: TestTree
appManifestOSCIngressOpsTests =
  testGroup "App manifest OSC ingress ops"
  [ testCase "openFresh swaps device-backed OSC ingress between targets" $ do
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              acceptedMV <- newEmptyMVar
              issueMV    <- newEmptyMVar
              let hooks = ManifestOSCListenerHooks
                    { molhOnAccepted =
                        putMVar acceptedMV
                    , molhOnIssue =
                        putMVar issueMV
                    }
                  ops =
                    manifestOSCIngressOps
                      hooks
                      defaultOSCProducerOptions
                      host
                      (defaultListenerConfig 0)
                  targetA = projectedTarget planA
                  targetB = projectedTarget planB

              -- Open initial target (cutoff + vol).
              openedA <- mrioOpenIngress ops targetA
              initialHandle <-
                case openedA of
                  Left issue ->
                    assertFailure
                      ("expected initial open, got: " <> show issue)
                    >> error "unreachable"
                  Right h ->
                    pure h
              manager <-
                newManifestReloadIngressManager ops targetA initialHandle

              -- Cutoff packet is accepted on target A.
              sendUdpLoopback
                (liBoundPort (moihInfo initialHandle))
                cutoffPacket
              cutoffAcceptedA <- timeout 1000000 (takeMVar acceptedMV)

              -- Swap to target B (vol-only).
              reloadResult <- openFreshManifestReloadIngress manager targetB
              reloadResult @?= Right ()

              snapshot <- readManifestReloadIngressManager manager
              (target', handle') <-
                case snapshot of
                  MrisOpen t h ->
                    pure (t, h)
                  MrisClosed ->
                    assertFailure
                      "expected open ingress after reload"
                    >> error "unreachable"

              -- Cutoff path now rejects at the manifest layer.
              sendUdpLoopback
                (liBoundPort (moihInfo handle'))
                cutoffPacket
              cutoffRejectedB <- timeout 1000000 (takeMVar issueMV)

              -- Vol path is accepted on target B.
              sendUdpLoopback
                (liBoundPort (moihInfo handle'))
                volPacket
              volAcceptedB <- timeout 1000000 (takeMVar acceptedMV)

              -- Final queue snapshot should reflect exactly two
              -- accepted writes: cutoff on A and vol on B.
              fanInSnapshot <- readSessionFanInHost host

              -- Tear down before returning so the bracket closes cleanly.
              _ <- closeManifestReloadIngress manager

              pure
                ( cutoffAcceptedA
                , cutoffRejectedB
                , volAcceptedB
                , target'
                , fanInSnapshot
                )
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (acceptedA, rejectedB, acceptedB, _target', snapshot) -> do
          case acceptedA of
            Just (OSCProducerEnqueueAttempted cmdA _) ->
              cmdA @?= CmdControlWrite (VoiceKey "v0") cutoffTag 1500.0
            other ->
              assertFailure
                ("expected cutoff accepted on A, got: " <> show other)
          case rejectedB of
            Just _ ->
              pure ()
            Nothing ->
              assertFailure "expected cutoff rejection on B"
          case acceptedB of
            Just (OSCProducerEnqueueAttempted cmdB _) ->
              cmdB @?= CmdControlWrite (VoiceKey "v0") volTag 1500.0
            other ->
              assertFailure
                ("expected vol accepted on B, got: " <> show other)
          sfisQueueDepth snapshot @?= 2

  , testCase "openFresh failure leaves manager closed and surfaces MoioiOpenFailed" $ do
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              let realOps =
                    manifestOSCIngressOps
                      defaultManifestOSCListenerHooks
                      defaultOSCProducerOptions
                      host
                      (defaultListenerConfig 0)
                  targetA = projectedTarget planA
                  targetB = projectedTarget planB

              openedA <- mrioOpenIngress realOps targetA
              initialHandle <-
                case openedA of
                  Left issue ->
                    assertFailure
                      ("expected initial open, got: " <> show issue)
                    >> error "unreachable"
                  Right h ->
                    pure h

              -- Inject a failing open via a wrapper while keeping the
              -- real close so the existing handle can be torn down.
              failNextOpen <- newIORef True
              let injectingOps = ManifestReloadIngressOps
                    { mrioOpenIngress =
                        \target -> do
                          shouldFail <- readIORef failNextOpen
                          if shouldFail
                            then do
                              writeIORef failNextOpen False
                              pure
                                (Left
                                  (MoioiOpenFailed
                                    (MoloiBindFailed "synthetic")))
                            else mrioOpenIngress realOps target
                    , mrioCloseIngress =
                        mrioCloseIngress realOps
                    }

              manager <-
                newManifestReloadIngressManager
                  injectingOps
                  targetA
                  initialHandle

              reloadResult <- openFreshManifestReloadIngress manager targetB
              snapshot <- readManifestReloadIngressManager manager
              pure (reloadResult, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (reloadResult, snapshot) -> do
          reloadResult
            @?= Left (MoioiOpenFailed (MoloiBindFailed "synthetic"))
          case snapshot of
            MrisClosed ->
              pure ()
            MrisOpen _ _ ->
              assertFailure
                "expected manager closed after openFresh failure"

  , testCase "openFresh failure does not leave the fan-in queue dirty" $ do
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              let realOps =
                    manifestOSCIngressOps
                      defaultManifestOSCListenerHooks
                      defaultOSCProducerOptions
                      host
                      (defaultListenerConfig 0)
                  targetA = projectedTarget planA
                  targetB = projectedTarget planB

              openedA <- mrioOpenIngress realOps targetA
              initialHandle <-
                case openedA of
                  Left issue ->
                    assertFailure
                      ("expected initial open, got: " <> show issue)
                    >> error "unreachable"
                  Right h ->
                    pure h

              failNextOpen <- newIORef True
              let injectingOps = ManifestReloadIngressOps
                    { mrioOpenIngress =
                        \target -> do
                          shouldFail <- readIORef failNextOpen
                          if shouldFail
                            then do
                              writeIORef failNextOpen False
                              pure
                                (Left
                                  (MoioiOpenFailed
                                    (MoloiBindFailed "synthetic")))
                            else mrioOpenIngress realOps target
                    , mrioCloseIngress =
                        mrioCloseIngress realOps
                    }

              manager <-
                newManifestReloadIngressManager
                  injectingOps
                  targetA
                  initialHandle
              _ <- openFreshManifestReloadIngress manager targetB
              readSessionFanInHost host
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right snapshot ->
          sfisQueueDepth snapshot @?= 0
  ]

projectedTarget :: MR.ManifestReloadPlan -> ManifestReloadIngressTarget
projectedTarget plan =
  case manifestReloadIngressTargetFromPlan defaultPolicy plan of
    Right target ->
      target
    Left issue ->
      error
        ("test setup: combined target projection failed: " <> show issue)

defaultPolicy :: ManifestReloadIngressTargetPolicy
defaultPolicy = ManifestReloadIngressTargetPolicy
  { mritpUIVoiceSelection =
      ManifestUIVoiceSelection
        { muvsFocusedVoice =
            Nothing
        , muvsDefaultVoice =
            VoiceKey "v0"
        }
  , mritpUIRetainedValues =
      M.empty
  , mritpMIDIDefaultVoice =
      VoiceKey "fx"
  }

planA :: MR.ManifestReloadPlan
planA = manifestPlanWith [cutoffControl, volControl]

planB :: MR.ManifestReloadPlan
planB = manifestPlanWith [volControl]

manifestPlanWith :: [MR.ManifestControlSurface] -> MR.ManifestReloadPlan
manifestPlanWith controls = MR.ManifestReloadPlan
  { MR.mrlpDemoKey =
      "demo"
  , MR.mrlpSwapLabel =
      SwapLabel "reload"
  , MR.mrlpTemplateGraph =
      TemplateGraph [] M.empty
  , MR.mrlpAdapterOptions =
      defaultRTGraphAdapterOptions
  , MR.mrlpControlSurface =
      controls
  , MR.mrlpArbitrationPolicy =
      FifoOnly
  }

cutoffControl :: MR.ManifestControlSurface
cutoffControl = MR.ManifestControlSurface
  { MR.mcsDisplayName =
      "cutoff"
  , MR.mcsControlTag =
      cutoffTag
  , MR.mcsDefault =
      1200.0
  , MR.mcsRangeMin =
      200.0
  , MR.mcsRangeMax =
      8000.0
  , MR.mcsSmoothingHz =
      30.0
  , MR.mcsCC =
      Nothing
  }

volControl :: MR.ManifestControlSurface
volControl = MR.ManifestControlSurface
  { MR.mcsDisplayName =
      "vol"
  , MR.mcsControlTag =
      volTag
  , MR.mcsDefault =
      0.3
  , MR.mcsRangeMin =
      0.0
  , MR.mcsRangeMax =
      1.0
  , MR.mcsSmoothingHz =
      30.0
  , MR.mcsCC =
      Nothing
  }

cutoffTag :: ControlTag
cutoffTag =
  ControlTag (MigrationKey "cutoff") 0

volTag :: ControlTag
volTag =
  ControlTag (MigrationKey "vol") 0

cutoffPacket :: OBSC.ByteString
cutoffPacket = oscMessageBytes "/v0/cutoff/0"

volPacket :: OBSC.ByteString
volPacket = oscMessageBytes "/v0/vol/0"

oscMessageBytes :: String -> OBSC.ByteString
oscMessageBytes addr = OBSC.concat
  [ oscString (OBSC.pack addr)
  , oscString (OBSC.pack ",f")
  , floatBytes1500
  ]

oscString :: OBSC.ByteString -> OBSC.ByteString
oscString s =
  let n   = OBSC.length s
      pad = (4 - ((n + 1) `mod` 4)) `mod` 4
  in s `OBSC.append` OBSC.replicate (1 + pad) '\NUL'

floatBytes1500 :: OBSC.ByteString
floatBytes1500 = OBSC.pack ['\x44', '\xBB', '\x80', '\NUL']
