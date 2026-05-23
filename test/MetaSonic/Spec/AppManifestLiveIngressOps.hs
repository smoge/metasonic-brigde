-- | Pure tests for 'MetaSonic.App.ManifestLiveIngressOps'.
--
-- The combinator is exercised against stub
-- 'ManifestReloadIngressOps' values that record open / close events
-- in a shared IORef. No PortMIDI, no UDP, no fan-in host — the goal
-- is to pin the open / close ordering, the rollback path, and the
-- close-failure dominance policy. Live-shell wiring of the
-- combinator against production OSC / MIDI ops is a later 3c step.
module MetaSonic.Spec.AppManifestLiveIngressOps
  ( appManifestLiveIngressOpsTests
  ) where

import           Data.IORef                       (IORef, modifyIORef',
                                                   newIORef, readIORef,
                                                   writeIORef)
import qualified Data.Map.Strict                  as M

import           Test.Tasty       (TestTree, testGroup)
import           Test.Tasty.HUnit (assertFailure, testCase, (@?=))

import           MetaSonic.App.ManifestLiveIngressOps
                                                  (LiveIngressHandle (..),
                                                   LiveIngressIssue (..),
                                                   manifestLiveIngressOps,
                                                   renderLiveIngressSnapshot,
                                                   renderLiveIngressSnapshotWith,
                                                   renderLiveProdIngressIssue)
import           MetaSonic.App.ManifestMIDIIngressOps
                                                  (ManifestMIDIIngressOpsIssue (..))
import           MetaSonic.App.ManifestMIDIPortMIDI
                                                  (ManifestMIDIPortMIDIError (..))
import           MetaSonic.App.ManifestOSCIngressOps
                                                  (ManifestOSCIngressOpsIssue (..))
import           MetaSonic.App.ManifestOSCListener
                                                  (ListenerInfo (..),
                                                   ManifestOSCListenerOpenIssue (..))
import           MetaSonic.App.ManifestReloadBinding
                                                  (ManifestUIIngressTarget (..),
                                                   ManifestUIVoiceSelection (..))
import           MetaSonic.App.ManifestReloadIngress
                                                  (ManifestReloadIngressOps (..),
                                                   ManifestReloadIngressSnapshot (..))
import           MetaSonic.App.ManifestReloadIngressTarget
                                                  (ManifestReloadIngressTarget (..))
import           MetaSonic.App.ManifestReloadMIDIBinding
                                                  (ManifestMIDIIngressTarget (..))
import           MetaSonic.App.ManifestReloadOSCBinding
                                                  (ManifestOSCIngressTarget (..))
import           MetaSonic.Pattern                (VoiceKey (..))
import           MetaSonic.Session.Arbitration    (ArbitrationPolicy (..))


appManifestLiveIngressOpsTests :: TestTree
appManifestLiveIngressOpsTests =
  testGroup "App manifest live ingress ops (Phase 8h step 3c)"
  [ testGroup "manifestLiveIngressOps (step 3)"  combinatorTests
  , testGroup "renderLiveIngressSnapshot (step 6a)"
              renderLiveIngressSnapshotTests
  , testGroup "renderLiveProdIngressIssue (step 6a)"
              renderLiveProdIngressIssueTests
  ]


-- ---------------------------------------------------------------------------
-- Combinator behavior (step 3)
-- ---------------------------------------------------------------------------

combinatorTests :: [TestTree]
combinatorTests =
  [ testCase "MIDI absent: open opens OSC only; lihMIDI = Nothing" $ do
      logRef <- newIORef []
      osc <- newStub "osc" logRef
      let combined =
            manifestLiveIngressOps
              (stubOps osc)
              (Nothing :: Maybe (ManifestReloadIngressOps () String ()))
      result <- mrioOpenIngress combined ()
      log_ <- readIORef logRef
      log_ @?= ["open-osc"]
      case result of
        Right h ->
          lihMIDI h @?= Nothing
        Left issue ->
          assertFailure ("expected Right, got: " <> show issue)

  , testCase "MIDI absent: close delegates to OSC only" $ do
      logRef <- newIORef []
      osc <- newStub "osc" logRef
      let combined =
            manifestLiveIngressOps
              (stubOps osc)
              (Nothing :: Maybe (ManifestReloadIngressOps () String ()))
      handle <- expectRight (mrioOpenIngress combined ())
      closeResult <- mrioCloseIngress combined handle
      closeResult @?= Right ()
      log_ <- readIORef logRef
      log_ @?= ["open-osc", "close-osc"]

  , testCase "MIDI present: open order is OSC first, then MIDI" $ do
      logRef <- newIORef []
      osc <- newStub "osc" logRef
      midi <- newStub "midi" logRef
      let combined =
            manifestLiveIngressOps (stubOps osc) (Just (stubOps midi))
      result <- mrioOpenIngress combined ()
      log_ <- readIORef logRef
      log_ @?= ["open-osc", "open-midi"]
      case result of
        Right h ->
          case lihMIDI h of
            Just () ->
              pure ()
            Nothing ->
              assertFailure "expected lihMIDI = Just (..)"
        Left issue ->
          assertFailure ("expected Right, got: " <> show issue)

  , testCase "OSC open fails: MIDI is never attempted; returns LiiOSC" $ do
      logRef <- newIORef []
      osc <- newStub "osc" logRef
      midi <- newStub "midi" logRef
      setOpenIssue osc "no-osc"
      let combined =
            manifestLiveIngressOps (stubOps osc) (Just (stubOps midi))
      result <- mrioOpenIngress combined ()
      log_ <- readIORef logRef
      log_ @?= ["open-osc-fail"]
      result @?= Left (LiiOSC "no-osc")

  , testCase "MIDI open fails: rolls back OSC best-effort; returns LiiMIDI" $ do
      logRef <- newIORef []
      osc <- newStub "osc" logRef
      midi <- newStub "midi" logRef
      setOpenIssue midi "no-midi"
      let combined =
            manifestLiveIngressOps (stubOps osc) (Just (stubOps midi))
      result <- mrioOpenIngress combined ()
      log_ <- readIORef logRef
      log_ @?= ["open-osc", "open-midi-fail", "close-osc"]
      result @?= Left (LiiMIDI "no-midi")

  , testCase "Close order: MIDI first, OSC second" $ do
      logRef <- newIORef []
      osc <- newStub "osc" logRef
      midi <- newStub "midi" logRef
      let combined =
            manifestLiveIngressOps (stubOps osc) (Just (stubOps midi))
      handle <- expectRight (mrioOpenIngress combined ())
      closeResult <- mrioCloseIngress combined handle
      closeResult @?= Right ()
      log_ <- readIORef logRef
      log_ @?= ["open-osc", "open-midi", "close-midi", "close-osc"]

  , testCase "Both close clean: combined returns Right ()" $ do
      logRef <- newIORef []
      osc <- newStub "osc" logRef
      midi <- newStub "midi" logRef
      let combined =
            manifestLiveIngressOps (stubOps osc) (Just (stubOps midi))
      handle <- expectRight (mrioOpenIngress combined ())
      closeResult <- mrioCloseIngress combined handle
      closeResult @?= Right ()

  , testCase "Close failures: OSC failure dominates over MIDI failure" $ do
      logRef <- newIORef []
      osc <- newStub "osc" logRef
      midi <- newStub "midi" logRef
      let combined =
            manifestLiveIngressOps (stubOps osc) (Just (stubOps midi))
      handle <- expectRight (mrioOpenIngress combined ())
      setCloseIssue osc "osc-bad"
      setCloseIssue midi "midi-bad"
      closeResult <- mrioCloseIngress combined handle
      log_ <- readIORef logRef
      -- Both closes attempted in MIDI-first order, OSC error wins.
      log_ @?= ["open-osc", "open-midi", "close-midi-fail", "close-osc-fail"]
      closeResult @?= Left (LiiOSC "osc-bad")

  , testCase "Close failures: MIDI failure reported when OSC closes clean" $ do
      logRef <- newIORef []
      osc <- newStub "osc" logRef
      midi <- newStub "midi" logRef
      let combined =
            manifestLiveIngressOps (stubOps osc) (Just (stubOps midi))
      handle <- expectRight (mrioOpenIngress combined ())
      setCloseIssue midi "midi-bad"
      closeResult <- mrioCloseIngress combined handle
      log_ <- readIORef logRef
      log_ @?= ["open-osc", "open-midi", "close-midi-fail", "close-osc"]
      closeResult @?= Left (LiiMIDI "midi-bad")
  ]


-- ---------------------------------------------------------------------------
-- Snapshot rendering (step 6a)
-- ---------------------------------------------------------------------------
--
-- The polymorphic 'renderLiveIngressSnapshotWith' lets tests
-- substitute trivial @oscHandle@ / @midiHandle@ types (the
-- production 'PortMIDISource' is opaque). A stub extractor returns
-- a fixed 'ListenerInfo' so the rendered @oscPort=@ pin is stable.

renderLiveIngressSnapshotTests :: [TestTree]
renderLiveIngressSnapshotTests =
  [ testCase "MrisClosed renders as 'closed'" $
      renderLiveIngressSnapshot MrisClosed @?= "closed"

  , testCase "MrisOpen with lihMIDI = Nothing renders midi=off" $
      renderLiveIngressSnapshotWith
        stubOSCExtractor
        (MrisOpen
          sampleTarget
          LiveIngressHandle
            { lihOSC  = ()
            , lihMIDI = Nothing :: Maybe ()
            })
        @?= "open demo=demo ui-controls=1 osc-controls=1 midi-cc=0"
            <> " defaultVoice=v0 oscPort=17005 midi=off"

  , testCase "MrisOpen with lihMIDI = Just _ renders midi=on" $
      renderLiveIngressSnapshotWith
        stubOSCExtractor
        (MrisOpen
          sampleTarget
          LiveIngressHandle
            { lihOSC  = ()
            , lihMIDI = Just ()
            })
        @?= "open demo=demo ui-controls=1 osc-controls=1 midi-cc=0"
            <> " defaultVoice=v0 oscPort=17005 midi=on"

  ]
  where
    stubOSCExtractor () = ListenerInfo { liBoundPort = 17005 }


-- ---------------------------------------------------------------------------
-- Initial-open issue rendering (step 6a)
-- ---------------------------------------------------------------------------

renderLiveProdIngressIssueTests :: [TestTree]
renderLiveProdIngressIssueTests =
  [ testCase "OSC bind failure renders the operator-facing string" $
      renderLiveProdIngressIssue
        Nothing
        (LiiOSC (MoioiOpenFailed (MoloiBindFailed "address already in use")))
        @?= "OSC ingress open failed: bind failed: address already in use"

  , testCase "MIDI no-input-device with Just N pins the device id in the string" $
      renderLiveProdIngressIssue
        (Just 3)
        (LiiMIDI (MmioiSourceOpenFailed MmppNoInputDevice))
        @?= "no input device for --midi-device 3"

  , testCase "MIDI PortMIDI open failure with Just N pins the device id" $
      renderLiveProdIngressIssue
        (Just 5)
        (LiiMIDI (MmioiSourceOpenFailed MmppOpenFailed))
        @?= "PortMIDI open failed for --midi-device 5"

  , testCase "MIDI no-input-device with Nothing renders (unset) (totality fallback)" $
      -- Guards against a regression to a fromJust-style partial
      -- pattern. The MIDI arm is unreachable when --midi-device is
      -- unset, but the renderer must stay total at the type level.
      renderLiveProdIngressIssue
        Nothing
        (LiiMIDI (MmioiSourceOpenFailed MmppNoInputDevice))
        @?= "no input device for --midi-device (unset)"
  ]


-- ---------------------------------------------------------------------------
-- Renderer fixtures
-- ---------------------------------------------------------------------------

sampleTarget :: ManifestReloadIngressTarget
sampleTarget = ManifestReloadIngressTarget
  { mitUI =
      ManifestUIIngressTarget
        { muitDemoKey           = "demo"
        , muitVoiceSelection    =
            ManifestUIVoiceSelection
              { muvsFocusedVoice = Nothing
              , muvsDefaultVoice = VoiceKey "v0"
              }
        , muitControls          = [error "muitControls element never read"]
        , muitArbitrationPolicy = FifoOnly
        }
  , mitOSC =
      ManifestOSCIngressTarget
        { motDemoKey           = "demo"
        , motControls          = [error "motControls element never read"]
        , motArbitrationPolicy = FifoOnly
        }
  , mitMIDI =
      ManifestMIDIIngressTarget
        { mmitDemoKey           = "demo"
        , mmitDefaultVoice      = VoiceKey "v0"
        , mmitControls          = []
        , mmitCCRoutes          = M.empty
        , mmitArbitrationPolicy = FifoOnly
        }
  }


-- ---------------------------------------------------------------------------
-- Stub ManifestReloadIngressOps
-- ---------------------------------------------------------------------------

-- | One stub half. The label distinguishes log entries
-- ("open-osc" / "open-midi" / etc.) when both halves share a log ref.
-- The two failure IORefs are one-shot: the next open / close consumes
-- the value and the slot resets to 'Nothing'.
data Stub = Stub
  { stubLabel      :: !String
  , stubLog        :: !(IORef [String])
  , stubOpenIssue  :: !(IORef (Maybe String))
  , stubCloseIssue :: !(IORef (Maybe String))
  }

newStub :: String -> IORef [String] -> IO Stub
newStub label logRef = do
  openIssue  <- newIORef Nothing
  closeIssue <- newIORef Nothing
  pure Stub
    { stubLabel      = label
    , stubLog        = logRef
    , stubOpenIssue  = openIssue
    , stubCloseIssue = closeIssue
    }

setOpenIssue :: Stub -> String -> IO ()
setOpenIssue s msg =
  writeIORef (stubOpenIssue s) (Just msg)

setCloseIssue :: Stub -> String -> IO ()
setCloseIssue s msg =
  writeIORef (stubCloseIssue s) (Just msg)

stubOps :: Stub -> ManifestReloadIngressOps () String ()
stubOps stub = ManifestReloadIngressOps
  { mrioOpenIngress = \() -> do
      mIssue <- takeOneShot (stubOpenIssue stub)
      case mIssue of
        Just msg -> do
          appendLog stub ("open-" <> stubLabel stub <> "-fail")
          pure (Left msg)
        Nothing -> do
          appendLog stub ("open-" <> stubLabel stub)
          pure (Right ())
  , mrioCloseIngress = \() -> do
      mIssue <- takeOneShot (stubCloseIssue stub)
      case mIssue of
        Just msg -> do
          appendLog stub ("close-" <> stubLabel stub <> "-fail")
          pure (Left msg)
        Nothing -> do
          appendLog stub ("close-" <> stubLabel stub)
          pure (Right ())
  }
  where
    appendLog s entry =
      modifyIORef' (stubLog s) (++ [entry])

    takeOneShot ref = do
      cur <- readIORef ref
      writeIORef ref Nothing
      pure cur


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

expectRight :: Show e => IO (Either e a) -> IO a
expectRight action = do
  result <- action
  case result of
    Right a ->
      pure a
    Left issue ->
      assertFailure ("expected Right, got: " <> show issue)
        >> error "unreachable"
