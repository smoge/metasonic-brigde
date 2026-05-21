-- | App-level manifest-target-aware OSC listener tests.
module MetaSonic.Spec.AppManifestOSCListener where

import           Control.Concurrent.MVar          (newEmptyMVar, putMVar,
                                                   takeMVar)
import qualified Data.ByteString.Char8            as OBSC
import qualified Data.Map.Strict                  as M
import           System.Timeout                   (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestOSCListener
import           MetaSonic.App.ManifestReloadOSCBinding
                                                  (manifestOSCIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadOSCIngress
                                                  (ManifestOSCIngressIssue (..))
import           MetaSonic.Bridge.Source          (MigrationKey (..))
import           MetaSonic.Bridge.Templates       (TemplateGraph (..))
import           MetaSonic.Pattern                (ControlTag (..),
                                                   SwapLabel (..),
                                                   VoiceKey (..))
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy (..))
import           MetaSonic.Session.Command        (SessionCommand (..))
import           MetaSonic.Session.FanIn          (SessionFanInEnqueueResult (..),
                                                   SessionFanInSnapshot (..),
                                                   defaultSessionFanInOptions,
                                                   readSessionFanInHost,
                                                   withSessionFanInHost)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.OSCProducer    (OSCProducerEnqueueResult (..),
                                                   defaultOSCProducerOptions)
import           MetaSonic.Session.Queue          (QueuedSessionCommand (..),
                                                   SessionEnqueueResult (..))
import           MetaSonic.Session.RTGraphAdapter (defaultRTGraphAdapterOptions)
import           MetaSonic.Spec.CoreShared              (sendUdpLoopback)


appManifestOSCListenerTests :: TestTree
appManifestOSCListenerTests =
  testGroup "App manifest OSC listener"
  [ testCase "bound control packet enqueues a CmdControlWrite" $ do
      let target = manifestOSCIngressTargetFromPlan validPlan
          expected =
            CmdControlWrite (VoiceKey "v0") cutoffTag 1500.0
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              received <- newEmptyMVar
              let hooks = ManifestOSCListenerHooks
                    { molhOnAccepted =
                        putMVar received
                    , molhOnIssue =
                        \_ -> pure ()
                    }
              withManifestOSCListener
                hooks
                defaultOSCProducerOptions
                target
                host
                (defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (liBoundPort info)
                      messageBytesV0CutoffFloat
                    timeout 1000000 (takeMVar received)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (OSCProducerEnqueueAttempted command enq)) -> do
          command @?= expected
          case sfierResult enq of
            SessionEnqueued queued ->
              qscCommand queued @?= expected
            other ->
              assertFailure ("expected enqueued, got: " <> show other)
        Right other ->
          assertFailure
            ("expected accepted producer result, got: " <> show other)

  , testCase "int control packet enqueues a CmdControlWrite" $ do
      let target = manifestOSCIngressTargetFromPlan validPlan
          expected =
            -- 400 lands inside cutoff's [200, 8000] range; the
            -- previous fixture used 42 which was implicitly accepted
            -- only because the OSC ingress did not yet enforce the
            -- manifest range. See
            -- notes/2026-05-21-d-manifest-osc-range-rejection.md.
            CmdControlWrite (VoiceKey "v0") cutoffTag 400.0
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              received <- newEmptyMVar
              let hooks = ManifestOSCListenerHooks
                    { molhOnAccepted =
                        putMVar received
                    , molhOnIssue =
                        \_ -> pure ()
                    }
              withManifestOSCListener
                hooks
                defaultOSCProducerOptions
                target
                host
                (defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (liBoundPort info)
                      messageBytesV0CutoffInt
                    timeout 1000000 (takeMVar received)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (OSCProducerEnqueueAttempted command _enq)) ->
          command @?= expected
        Right other ->
          assertFailure
            ("expected accepted producer result, got: " <> show other)

  , testCase "unknown control packet rejects and queue stays empty" $ do
      let target = manifestOSCIngressTargetFromPlan trimmedPlan
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              issueMV <- newEmptyMVar
              let hooks = ManifestOSCListenerHooks
                    { molhOnAccepted =
                        \_ -> pure ()
                    , molhOnIssue =
                        putMVar issueMV
                    }
              withManifestOSCListener
                hooks
                defaultOSCProducerOptions
                target
                host
                (defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (liBoundPort info)
                      messageBytesV0CutoffFloat
                    mIssue <- timeout 1000000 (takeMVar issueMV)
                    snapshot <- readSessionFanInHost host
                    pure (mIssue, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MoliManifestIssue (MoiiAddressIssue _)), snapshot) ->
          sfisQueueDepth snapshot @?= 0
        Right other ->
          assertFailure
            ("expected manifest address rejection, got: " <> show other)

  , testCase "malformed OSC path surfaces as a manifest decode issue" $ do
      let target = manifestOSCIngressTargetFromPlan validPlan
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              issueMV <- newEmptyMVar
              let hooks = ManifestOSCListenerHooks
                    { molhOnAccepted =
                        \_ -> pure ()
                    , molhOnIssue =
                        putMVar issueMV
                    }
              withManifestOSCListener
                hooks
                defaultOSCProducerOptions
                target
                host
                (defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (liBoundPort info)
                      messageBytesSingleSegment
                    mIssue <- timeout 1000000 (takeMVar issueMV)
                    snapshot <- readSessionFanInHost host
                    pure (mIssue, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MoliManifestIssue (MoiiDecodeFailed _)), snapshot) ->
          sfisQueueDepth snapshot @?= 0
        Right other ->
          assertFailure
            ("expected manifest decode rejection, got: " <> show other)

  , testCase "open/close handle cleanly tears down the listener thread" $ do
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              opened <-
                openManifestOSCListener
                  defaultManifestOSCListenerHooks
                  defaultOSCProducerOptions
                  (manifestOSCIngressTargetFromPlan validPlan)
                  host
                  (defaultListenerConfig 0)
              case opened of
                Left issue ->
                  assertFailure
                    ("expected listener open, got: " <> show issue)
                Right (handle, _info) -> do
                  closeManifestOSCListener handle
                  -- A second close is a no-op (idempotent).
                  closeManifestOSCListener handle
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right () ->
          pure ()

  , testCase "reopen with a different target changes accepted paths" $ do
      let firstTarget = manifestOSCIngressTargetFromPlan validPlan
          secondTarget = manifestOSCIngressTargetFromPlan volOnlyPlan
          expectedVol =
            -- 0.5 lands inside vol's [0, 1] range; the previous
            -- fixture used 1500.0 which was implicitly accepted only
            -- because the OSC ingress did not yet enforce the
            -- manifest range. See
            -- notes/2026-05-21-d-manifest-osc-range-rejection.md.
            CmdControlWrite (VoiceKey "v0") volTag 0.5
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              acceptedMV <- newEmptyMVar
              issueMV <- newEmptyMVar
              let hooks = ManifestOSCListenerHooks
                    { molhOnAccepted =
                        putMVar acceptedMV
                    , molhOnIssue =
                        putMVar issueMV
                    }

              -- Open against the original target: cutoff is bound.
              firstOpened <-
                openManifestOSCListener
                  hooks
                  defaultOSCProducerOptions
                  firstTarget
                  host
                  (defaultListenerConfig 0)
              (handle1, info1) <-
                case firstOpened of
                  Left issue ->
                    assertFailure
                      ("expected first listener open, got: " <> show issue)
                    >> error "unreachable"
                  Right pair ->
                    pure pair
              sendUdpLoopback (liBoundPort info1) messageBytesV0CutoffFloat
              firstResult <- timeout 1000000 (takeMVar acceptedMV)
              closeManifestOSCListener handle1

              -- Reopen against a target that only carries vol: cutoff
              -- now rejects, vol enqueues.
              secondOpened <-
                openManifestOSCListener
                  hooks
                  defaultOSCProducerOptions
                  secondTarget
                  host
                  (defaultListenerConfig 0)
              (handle2, info2) <-
                case secondOpened of
                  Left issue ->
                    assertFailure
                      ("expected second listener open, got: " <> show issue)
                    >> error "unreachable"
                  Right pair ->
                    pure pair

              sendUdpLoopback (liBoundPort info2) messageBytesV0CutoffFloat
              cutoffRejection <- timeout 1000000 (takeMVar issueMV)
              sendUdpLoopback (liBoundPort info2) messageBytesV0VolFloat
              volAccepted <- timeout 1000000 (takeMVar acceptedMV)
              closeManifestOSCListener handle2

              pure (firstResult, cutoffRejection, volAccepted)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right
          ( Just (OSCProducerEnqueueAttempted firstCmd _)
          , Just (MoliManifestIssue (MoiiAddressIssue _))
          , Just (OSCProducerEnqueueAttempted volCmd _)
          ) -> do
            firstCmd @?= CmdControlWrite (VoiceKey "v0") cutoffTag 1500.0
            volCmd @?= expectedVol
        Right other ->
          assertFailure
            ("expected first-accept / cutoff-reject / vol-accept, got: "
             <> show other)
  ]
  where
    validPlan = manifestPlanWith [cutoffControl, volControl]

    trimmedPlan = manifestPlanWith [volControl]

    volOnlyPlan = trimmedPlan

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

-- Hand-built OSC wire fixtures matching the manifest tag layout
-- (/v0/<tag>/<slot> with one numeric argument). The control surface
-- above uses slot 0.
messageBytesV0CutoffFloat :: OBSC.ByteString
messageBytesV0CutoffFloat =
  oscMessageBytes "/v0/cutoff/0" ",f" floatBytes1500

messageBytesV0CutoffInt :: OBSC.ByteString
messageBytesV0CutoffInt =
  -- 400 (0x190) lands inside cutoff's [200, 8000] range. Previously
  -- this fixture used 42, which was implicitly accepted only because
  -- the OSC ingress did not yet enforce the manifest range.
  oscMessageBytes "/v0/cutoff/0" ",i" intBytes400

messageBytesV0VolFloat :: OBSC.ByteString
messageBytesV0VolFloat =
  -- 0.5 lands inside vol's [0, 1] range. Previously this fixture
  -- used 1500.0; same reason as the int fixture above.
  oscMessageBytes "/v0/vol/0" ",f" floatBytesHalf

messageBytesSingleSegment :: OBSC.ByteString
messageBytesSingleSegment =
  -- This packet is supposed to be rejected at the parser layer for
  -- having only one path segment, so its float payload is never
  -- inspected against any manifest range. The value bytes here can
  -- be any well-formed float; we keep the original 1500.0 encoding.
  oscMessageBytes "/just-one-segment" ",f" floatBytes1500

oscMessageBytes :: String -> String -> OBSC.ByteString -> OBSC.ByteString
oscMessageBytes addr typeTag payload = OBSC.concat
  [ oscString (OBSC.pack addr)
  , oscString (OBSC.pack typeTag)
  , payload
  ]

oscString :: OBSC.ByteString -> OBSC.ByteString
oscString s =
  let n   = OBSC.length s
      pad = (4 - ((n + 1) `mod` 4)) `mod` 4
  in s `OBSC.append` OBSC.replicate (1 + pad) '\NUL'

floatBytes1500 :: OBSC.ByteString
floatBytes1500 = OBSC.pack ['\x44', '\xBB', '\x80', '\NUL']

-- | IEEE 754 single-precision encoding of 0.5 (= 0x3F000000).
floatBytesHalf :: OBSC.ByteString
floatBytesHalf = OBSC.pack ['\x3F', '\NUL', '\NUL', '\NUL']

-- | Big-endian 32-bit signed encoding of 400 (= 0x00000190).
intBytes400 :: OBSC.ByteString
intBytes400 = OBSC.pack ['\NUL', '\NUL', '\x01', '\x90']
