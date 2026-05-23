-- | App-level tests for the manifest MIDI ingress-ops adapter.
--
-- The adapter is exercised through a 'Chan'-backed source factory so
-- CI never depends on PortMIDI hardware. The PortMIDI factory is a
-- thin production-side wrapper around the same shape and is covered
-- separately.
module MetaSonic.Spec.AppManifestMIDIIngressOps where

import           Control.Concurrent.Chan          (Chan, newChan, readChan,
                                                   writeChan)
import           Control.Concurrent.MVar          (newEmptyMVar, putMVar,
                                                   takeMVar)
import           Data.IORef                       (IORef, modifyIORef',
                                                   newIORef, readIORef,
                                                   writeIORef)
import qualified Data.Map.Strict                  as M
import           Data.Word                        (Word8)
import           System.Timeout                   (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestMIDIIngressOps
                                                  (ManifestMIDIIngressHandle (..),
                                                   ManifestMIDIIngressOpsHooks (..),
                                                   ManifestMIDIIngressOpsIssue (..),
                                                   ManifestMIDISourceFactory (..),
                                                   defaultManifestMIDIIngressOpsHooks,
                                                   manifestMIDIIngressOps,
                                                   manifestMIDIIngressOpsWithTargetHooks)
import           MetaSonic.App.ManifestMIDIListener
                                                  (ManifestMIDIListenerHooks (..),
                                                   defaultManifestMIDIListenerHooks)
import           MetaSonic.App.ManifestReloadBinding
                                                  (ManifestUIVoiceSelection (..))
import           MetaSonic.App.ManifestReloadIngress
                                                  (ManifestReloadIngressOps (..),
                                                   ManifestReloadIngressSnapshot (..),
                                                   closeManifestReloadIngress,
                                                   newManifestReloadIngressManager,
                                                   openFreshManifestReloadIngress,
                                                   readManifestReloadIngressManager)
import           MetaSonic.App.ManifestReloadIngressTarget
                                                  (ManifestReloadIngressTarget (..),
                                                   ManifestReloadIngressTargetPolicy (..),
                                                   manifestReloadIngressTargetFromPlan)
import           MetaSonic.App.ManifestReloadMIDIBinding
                                                  (ManifestMIDIControlBinding (..),
                                                   mmitControls)
import           MetaSonic.App.ManifestReloadMIDIIngress
                                                  (ManifestMIDIIngressIssue (..))
import           MetaSonic.Bridge.Source          (MigrationKey (..))
import           MetaSonic.Bridge.Templates       (TemplateGraph (..))
import           MetaSonic.Pattern                (ControlTag (..),
                                                   SwapLabel (..),
                                                   VoiceKey (..))
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy (..))
import           MetaSonic.Session.Command        (SessionCommand (..))
import           MetaSonic.Session.FanIn          (SessionFanInEnqueueResult (..),
                                                   defaultSessionFanInOptions,
                                                   withSessionFanInHost)
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.MIDIListener   (MIDIListenerSource (..))
import           MetaSonic.Session.MIDIProducer   (MIDIProducerEvent (..),
                                                   defaultMIDIProducerOptions)
import           MetaSonic.Session.Queue          (QueuedSessionCommand (..),
                                                   SessionEnqueueResult (..))
import           MetaSonic.Session.RTGraphAdapter (defaultRTGraphAdapterOptions)


appManifestMIDIIngressOpsTests :: TestTree
appManifestMIDIIngressOpsTests =
  testGroup "App manifest MIDI ingress ops"
  [ testCase "openFresh swaps MIDI ingress between targets" $ do
      -- Drive the listener through real CC events on each generation:
      -- target A binds CC 7, target B remaps "vol" to CC 11. Old CC
      -- on the new generation must reject; new CC must accept.
      let targetA = projectOrFail planA
          targetB = projectOrFail planB

      acceptedMV <- newEmptyMVar
      issueMV    <- newEmptyMVar
      let hooks = ManifestMIDIListenerHooks
            { mmlhOnAccepted =
                putMVar acceptedMV
            , mmlhOnIssue =
                putMVar issueMV
            }

      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              factoryState <- newSourceFactoryState
              let factory = chanSourceFactory factoryState
                  ops =
                    manifestMIDIIngressOps
                      hooks
                      defaultManifestMIDIIngressOpsHooks
                      defaultMIDIProducerOptions
                      host
                      factory

              -- Open A and drive CC 7 → accepts.
              openedA <- mrioOpenIngress ops targetA
              handleA <-
                case openedA of
                  Left issue ->
                    assertFailure
                      ("expected initial open, got: " <> show issue)
                    >> error "unreachable"
                  Right h ->
                    pure h
              writeFactoryEvent factoryState
                (Just (MIDIProducerControlChange 0 volCC 127))
              acceptedAResult <-
                timeout 1000000 (takeMVar acceptedMV)

              manager <-
                newManifestReloadIngressManager ops targetA handleA

              -- Reload to B and drive CC 7 → rejects, CC 11 → accepts.
              reloadResult <- openFreshManifestReloadIngress manager targetB
              reloadResult @?= Right ()

              writeFactoryEvent factoryState
                (Just (MIDIProducerControlChange 0 volCC 127))
              oldRejectedResult <-
                timeout 1000000 (takeMVar issueMV)

              writeFactoryEvent factoryState
                (Just (MIDIProducerControlChange 0 11 127))
              acceptedBResult <-
                timeout 1000000 (takeMVar acceptedMV)

              _ <- closeManifestReloadIngress manager
              opens <- readIORef (factoryStateOpens factoryState)
              closes <- readIORef (factoryStateCloses factoryState)
              pure
                ( acceptedAResult
                , oldRejectedResult
                , acceptedBResult
                , opens
                , closes
                )

      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (acceptedA, rejectedOld, acceptedB, opens, closes) -> do
          assertEnqueuedCommand
            "first generation cutoff path"
            (CmdControlWrite defaultVoice volTag 1.0)
            acceptedA
          case rejectedOld of
            Just _ ->
              pure ()
            Nothing ->
              assertFailure
                "expected old-CC rejection on new generation"
          assertEnqueuedCommand
            "second generation vol path"
            (CmdControlWrite defaultVoice volTag 1.0)
            acceptedB
          opens @?= 2   -- initial + openFresh on reload
          closes @?= 2  -- closeOld during openFresh + final cleanup

  , testCase "source open failure surfaces as MmioiSourceOpenFailed" $ do
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              factoryState <- newSourceFactoryState
              writeIORef (factoryStateOpenFailure factoryState)
                (Just "synthetic")
              let factory = chanSourceFactory factoryState
                  ops =
                    manifestMIDIIngressOps
                      defaultManifestMIDIListenerHooks
                      defaultManifestMIDIIngressOpsHooks
                      defaultMIDIProducerOptions
                      host
                      factory
              mrioOpenIngress ops (projectOrFail planA)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Left (MmioiSourceOpenFailed "synthetic")) ->
          pure ()
        Right other ->
          assertFailure
            ("expected MmioiSourceOpenFailed, got: " <> show other)

  , testCase "source close failure fires the hook and reports a clean close to the ingress manager" $ do
      -- Regression: when source close fails after the listener was
      -- already stopped, the handle has a dead worker. The adapter
      -- must NOT return Left (which would tell the manager to
      -- retain a now-stale MrisOpen state). Instead it fires the
      -- adapter-level close hook with the source issue and tells
      -- the manager the close succeeded so the manager goes
      -- MrisClosed honestly.
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              factoryState <- newSourceFactoryState
              writeIORef (factoryStateCloseFailure factoryState)
                (Just "synthetic-close")
              closeIssueRef <- newIORef Nothing
              let opsHooks = ManifestMIDIIngressOpsHooks
                    { mmioohOnSourceCloseFailed =
                        writeIORef closeIssueRef . Just
                    }
                  factory = chanSourceFactory factoryState
                  ops =
                    manifestMIDIIngressOps
                      defaultManifestMIDIListenerHooks
                      opsHooks
                      defaultMIDIProducerOptions
                      host
                      factory
              opened <- mrioOpenIngress ops (projectOrFail planA)
              handleA <-
                case opened of
                  Left issue ->
                    assertFailure
                      ("expected initial open, got: " <> show issue)
                    >> error "unreachable"
                  Right h ->
                    pure h
              manager <-
                newManifestReloadIngressManager ops (projectOrFail planA) handleA
              closeResult <- closeManifestReloadIngress manager
              snapshot <- readManifestReloadIngressManager manager
              hookIssue <- readIORef closeIssueRef
              pure (closeResult, snapshot, hookIssue)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (closeResult, snapshot, hookIssue) -> do
          closeResult @?= Right ()
          case snapshot of
            MrisClosed ->
              pure ()
            MrisOpen _ _ ->
              assertFailure
                "expected MrisClosed after source-close failure"
          hookIssue @?= Just "synthetic-close"

  , testCase "openFresh failure leaves manager closed and surfaces MmioiSourceOpenFailed" $ do
      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              factoryState <- newSourceFactoryState
              let factory = chanSourceFactory factoryState
                  ops =
                    manifestMIDIIngressOps
                      defaultManifestMIDIListenerHooks
                      defaultManifestMIDIIngressOpsHooks
                      defaultMIDIProducerOptions
                      host
                      factory
              openedA <- mrioOpenIngress ops (projectOrFail planA)
              handleA <-
                case openedA of
                  Left issue ->
                    assertFailure
                      ("expected initial open, got: " <> show issue)
                    >> error "unreachable"
                  Right h ->
                    pure h
              manager <-
                newManifestReloadIngressManager ops (projectOrFail planA) handleA
              -- Flip the factory into open-failure mode before
              -- attempting the fresh open.
              writeIORef (factoryStateOpenFailure factoryState)
                (Just "next-open-fails")
              reloadResult <-
                openFreshManifestReloadIngress manager (projectOrFail planB)
              snapshot <- readManifestReloadIngressManager manager
              pure (reloadResult, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (reloadResult, snapshot) -> do
          reloadResult @?= Left (MmioiSourceOpenFailed "next-open-fails")
          case snapshot of
            MrisClosed ->
              pure ()
            MrisOpen _ _ ->
              assertFailure
                "expected manager closed after openFresh failure"

  , testCase "manifestMIDIIngressOpsWithTargetHooks installs fresh hooks per open" $ do
      -- Each generation's hooks carry a generation-specific MVar. If
      -- the builder were called once at construction time (the old
      -- constant-hooks shape), the B generation would inherit A's
      -- hooks and the B-specific MVar would never receive. Driving a
      -- CC through both generations and seeing each MVar receive
      -- exactly its own generation's accept proves the builder ran
      -- per open with the current target.
      let targetA = projectOrFail planA
          targetB = projectOrFail planB

      acceptedAMV <- newEmptyMVar
      acceptedBMV <- newEmptyMVar

      let hooksWriting mv = ManifestMIDIListenerHooks
            { mmlhOnAccepted = putMVar mv
            , mmlhOnIssue    = \_ -> pure ()
            }

          -- Dispatch on the target's MIDI binding shape rather than
          -- target equality, which is not exposed at this layer.
          builder target =
            case map mmcbCC (mmitControls (mitMIDI target)) of
              [7]  -> hooksWriting acceptedAMV
              [11] -> hooksWriting acceptedBMV
              _    -> defaultManifestMIDIListenerHooks

      result <-
        withSessionFanInHost
          (TemplateGraph [] M.empty)
          defaultSessionFanInOptions
          $ \host -> do
              factoryState <- newSourceFactoryState
              let factory = chanSourceFactory factoryState
                  ops =
                    manifestMIDIIngressOpsWithTargetHooks
                      builder
                      defaultManifestMIDIIngressOpsHooks
                      defaultMIDIProducerOptions
                      host
                      factory

              openedA <- mrioOpenIngress ops targetA
              handleA <-
                case openedA of
                  Left issue ->
                    assertFailure
                      ("expected initial open, got: " <> show issue)
                    >> error "unreachable"
                  Right h ->
                    pure h

              writeFactoryEvent factoryState
                (Just (MIDIProducerControlChange 0 volCC 127))
              ackA <- timeout 1000000 (takeMVar acceptedAMV)

              manager <-
                newManifestReloadIngressManager ops targetA handleA
              reloadResult <-
                openFreshManifestReloadIngress manager targetB
              reloadResult @?= Right ()

              -- Generation B's binding remaps vol to CC 11 (see
              -- planB above). Sending CC 7 on this generation would
              -- reject; sending CC 11 must accept and fire B's hook.
              writeFactoryEvent factoryState
                (Just (MIDIProducerControlChange 0 11 127))
              ackB <- timeout 1000000 (takeMVar acceptedBMV)

              _ <- closeManifestReloadIngress manager
              pure (ackA, ackB)

      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (ackA, ackB) -> do
          assertEnqueuedCommand
            "generation A accept routed through A-specific hook"
            (CmdControlWrite defaultVoice volTag 1.0)
            ackA
          assertEnqueuedCommand
            "generation B accept routed through fresh B-specific hook"
            (CmdControlWrite defaultVoice volTag 1.0)
            ackB
  ]

------------------------------------------------------------
-- Test source factory
------------------------------------------------------------

-- | Mutable state behind the Chan-backed factory: the shared event
-- channel, an open/close counter for assertions, and optional one-shot
-- failure injection.
data SourceFactoryState = SourceFactoryState
  { factoryStateEvents       :: !(Chan (Maybe MIDIProducerEvent))
  , factoryStateOpens        :: !(IORef Int)
  , factoryStateCloses       :: !(IORef Int)
  , factoryStateOpenFailure  :: !(IORef (Maybe String))
  , factoryStateCloseFailure :: !(IORef (Maybe String))
  }

newSourceFactoryState :: IO SourceFactoryState
newSourceFactoryState = do
  ch <- newChan
  opens <- newIORef 0
  closes <- newIORef 0
  openFailure <- newIORef Nothing
  closeFailure <- newIORef Nothing
  pure SourceFactoryState
    { factoryStateEvents =
        ch
    , factoryStateOpens =
        opens
    , factoryStateCloses =
        closes
    , factoryStateOpenFailure =
        openFailure
    , factoryStateCloseFailure =
        closeFailure
    }

writeFactoryEvent
  :: SourceFactoryState
  -> Maybe MIDIProducerEvent
  -> IO ()
writeFactoryEvent state =
  writeChan (factoryStateEvents state)

-- | One-shot failure injection: pops the configured failure if any,
-- and resets the slot so subsequent opens/closes succeed.
takeOneShot :: IORef (Maybe a) -> IO (Maybe a)
takeOneShot ref = do
  cur <- readIORef ref
  case cur of
    Just _ ->
      writeIORef ref Nothing
    Nothing ->
      pure ()
  pure cur

chanSourceFactory
  :: SourceFactoryState
  -> ManifestMIDISourceFactory String ()
chanSourceFactory state = ManifestMIDISourceFactory
  { mmsfOpenSource = do
      failure <- takeOneShot (factoryStateOpenFailure state)
      case failure of
        Just msg ->
          pure (Left msg)
        Nothing -> do
          modifyIORef' (factoryStateOpens state) (+ 1)
          let listenerSource =
                MIDIListenerSource (readChan (factoryStateEvents state))
          pure (Right ((), listenerSource))
  , mmsfCloseSource = \() -> do
      failure <- takeOneShot (factoryStateCloseFailure state)
      case failure of
        Just msg ->
          pure (Left msg)
        Nothing -> do
          modifyIORef' (factoryStateCloses state) (+ 1)
          pure (Right ())
  }

------------------------------------------------------------
-- Helpers and fixtures
------------------------------------------------------------

assertEnqueuedCommand
  :: String
  -> SessionCommand
  -> Maybe SessionFanInEnqueueResult
  -> Assertion
assertEnqueuedCommand label expected mResult =
  case mResult of
    Just enq ->
      case sfierResult enq of
        SessionEnqueued queued ->
          qscCommand queued @?= expected
        other ->
          assertFailure
            (label <> ": expected enqueued, got: " <> show other)
    Nothing ->
      assertFailure (label <> ": timed out waiting for acceptance")

projectOrFail :: MR.ManifestReloadPlan -> ManifestReloadIngressTarget
projectOrFail plan =
  case manifestReloadIngressTargetFromPlan policy plan of
    Right target ->
      target
    Left issue ->
      error ("test setup: combined target projection failed: " <> show issue)

policy :: ManifestReloadIngressTargetPolicy
policy = ManifestReloadIngressTargetPolicy
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
      defaultVoice
  }

planA :: MR.ManifestReloadPlan
planA = manifestPlanWith [cutoffControl, volControl]

planB :: MR.ManifestReloadPlan
planB = manifestPlanWith
  [ cutoffControl
  , volControl { MR.mcsCC = Just 11 }
  ]

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
      ControlTag (MigrationKey "cutoff") 0
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
      Just volCC
  }

volTag :: ControlTag
volTag = ControlTag (MigrationKey "vol") 0

volCC :: Word8
volCC = 7

defaultVoice :: VoiceKey
defaultVoice = VoiceKey "fx"
