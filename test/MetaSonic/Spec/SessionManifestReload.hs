-- | Pure manifest-driven session reload planner tests.
module MetaSonic.Spec.SessionManifestReload where

import           Control.Exception               (ErrorCall (..),
                                                  throwIO, try)
import           Data.IORef                      (modifyIORef', newIORef,
                                                  readIORef)
import qualified Data.Map.Strict                 as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Spec.SessionShared    (testProducer)
import           MetaSonic.Authoring.Manifest
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Pattern               (ControlTag (..),
                                                  SwapLabel (..),
                                                  VoiceKey (..),
                                                  TemplateName (..))
import           MetaSonic.Session.Arbitration
import           MetaSonic.Session.ManifestReload
import           MetaSonic.Session.ManifestReload.Construct
import           MetaSonic.Session.ManifestReload.Runtime
import           MetaSonic.Session.Command
import           MetaSonic.Session.FanIn
import           MetaSonic.Session.Owner
import           MetaSonic.Session.Queue         (ProducerKind (..),
                                                  SessionEnqueueIssue (..),
                                                  SessionEnqueueResult (..))
import           MetaSonic.Session.RTGraphAdapter
import           MetaSonic.Session.State
import           MetaSonic.Session.Step          (SessionStepResult (..))


sessionManifestReloadTests :: TestTree
sessionManifestReloadTests =
  testGroup "Session manifest reload planner"
  [ testCase "valid manifest + matching catalog yields catalog graph" $ do
      plan <- planOrFail validDoc validCatalog validRequest
      mrlpDemoKey plan @?= "demo"
      mrlpSwapLabel plan @?= SwapLabel "reload"
      mrlpTemplateGraph plan @?= validTemplateGraph
      raoHotSwapInstallTimeoutMs (mrlpAdapterOptions plan)
        @?= raoHotSwapInstallTimeoutMs defaultRTGraphAdapterOptions

  , testCase "unknown requested manifest demo rejects" $
      planManifestReload
        (AuthoringManifestDoc manifestSchemaVersion [otherManifest])
        validCatalog
        validRequest
        @?= Left (MriUnknownManifestDemo "demo")

  , testCase "unknown requested catalog demo rejects" $
      planManifestReload validDoc [] validRequest
        @?= Left (MriUnknownCatalogDemo "demo")

  , testCase "duplicate manifest demo keys reject" $
      planManifestReload
        (AuthoringManifestDoc manifestSchemaVersion
          [validManifest, validManifest])
        validCatalog
        validRequest
        @?= Left (MriDuplicateManifestDemo "demo")

  , testCase "duplicate catalog demo keys reject" $
      planManifestReload
        validDoc
        [validCatalogEntry, validCatalogEntry]
        validRequest
        @?= Left (MriDuplicateCatalogDemo "demo")

  , testCase "manifest/catalog mismatch rejects" $ do
      let requested = validManifest { mfControls = [] }
      planManifestReload
        (AuthoringManifestDoc manifestSchemaVersion [requested])
        validCatalog
        validRequest
        @?= Left (MriManifestMismatch "demo" requested validManifest)

  , testCase "manifest internal validation precedes manifest mismatch" $ do
      let requested = validManifest
            { mfTemplates =
                [ ManifestTemplate "voice" "voice"
                , ManifestTemplate "voice" "fx"
                ]
            }
      planManifestReload
        (AuthoringManifestDoc manifestSchemaVersion [requested])
        [validCatalogEntry { mrcManifest = validManifest }]
        validRequest
        @?= Left (MriDuplicateTemplateName (TemplateName "voice"))

  , testCase "empty manifest doc cannot plan a selected reload" $
      planManifestReload
        (AuthoringManifestDoc manifestSchemaVersion [])
        validCatalog
        validRequest
        @?= Left (MriUnknownManifestDemo "demo")

  , testCase "unsupported in-memory schema version rejects" $
      planManifestReload
        (AuthoringManifestDoc 99 [validManifest])
        validCatalog
        validRequest
        @?= Left (MriUnsupportedSchemaVersion 99)

  , testCase "duplicate template names in requested manifest reject" $ do
      let dupManifest = validManifest
            { mfTemplates =
                [ ManifestTemplate "voice" "voice"
                , ManifestTemplate "voice" "fx"
                ]
            }
          catalog = [ManifestReloadCatalogEntry "demo" dupManifest validTemplateGraph]
      planManifestReload
        (AuthoringManifestDoc manifestSchemaVersion [dupManifest])
        catalog
        validRequest
        @?= Left (MriDuplicateTemplateName (TemplateName "voice"))

  , testCase "unknown direct-Haskell template role rejects" $ do
      let roleManifest = validManifest
            { mfTemplates = [ManifestTemplate "voice" "sidechain"] }
          catalog = [ManifestReloadCatalogEntry "demo" roleManifest validTemplateGraph]
      planManifestReload
        (AuthoringManifestDoc manifestSchemaVersion [roleManifest])
        catalog
        validRequest
        @?= Left (MriUnknownTemplateRole "voice" "sidechain")

  , testCase "manifest template missing from catalog graph rejects" $ do
      let missingManifest = validManifest
            { mfTemplates =
                [ ManifestTemplate "voice" "voice"
                , ManifestTemplate "missing" "fx"
                ]
            }
          catalog =
            [ ManifestReloadCatalogEntry
                "demo"
                missingManifest
                voiceOnlyTemplateGraph
            ]
      planManifestReload
        (AuthoringManifestDoc manifestSchemaVersion [missingManifest])
        catalog
        validRequest
        @?= Left (MriCatalogMissingTemplate (TemplateName "missing"))

  , testCase "voice/fx role defaults produce per-template polyphony" $ do
      let policy = ManifestResourcePolicy
            { mrpVoicePolyphony    = 8
            , mrpFxPolyphony       = 2
            , mrpTemplateOverrides = M.empty
            }
          request = validRequest { mrrResourcePolicy = policy }
      plan <- planOrFail validDoc validCatalog request
      raoPerTemplatePolyphony (mrlpAdapterOptions plan) @?=
        M.fromList
          [ (TemplateName "voice", 8)
          , (TemplateName "fx", 2)
          ]

  , testCase "template override wins over role default" $ do
      let policy = ManifestResourcePolicy
            { mrpVoicePolyphony    = 8
            , mrpFxPolyphony       = 2
            , mrpTemplateOverrides =
                M.singleton (TemplateName "voice") 12
            }
          request = validRequest { mrrResourcePolicy = policy }
      plan <- planOrFail validDoc validCatalog request
      raoPerTemplatePolyphony (mrlpAdapterOptions plan) @?=
        M.fromList
          [ (TemplateName "voice", 12)
          , (TemplateName "fx", 2)
          ]

  , testCase "per-template polyphony map is order-insensitive and applies overrides" $ do
      let policy = ManifestResourcePolicy
            { mrpVoicePolyphony    = 8
            , mrpFxPolyphony       = 2
            , mrpTemplateOverrides =
                M.fromList
                  [ (TemplateName "voice", 12)
                  , (TemplateName "fx", 3)
                  ]
            }
          request = validRequest { mrrResourcePolicy = policy }
          reversedManifest = validManifest
            { mfTemplates = reverse (mfTemplates validManifest) }
          reversedDoc =
            AuthoringManifestDoc manifestSchemaVersion [reversedManifest]
          reversedCatalog =
            [ validCatalogEntry { mrcManifest = reversedManifest } ]
      planA <- planOrFail validDoc validCatalog request
      planB <- planOrFail reversedDoc reversedCatalog request
      let polyA =
            raoPerTemplatePolyphony (mrlpAdapterOptions planA)
          polyB =
            raoPerTemplatePolyphony (mrlpAdapterOptions planB)
          expected =
            [ (TemplateName "fx", 3)
            , (TemplateName "voice", 12)
            ]
      M.toAscList polyA @?= expected
      M.toAscList polyB @?= expected
      polyA @?= polyB

  , testCase "non-positive voice polyphony rejects" $ do
      let policy = validPolicy { mrpVoicePolyphony = 0 }
          request = validRequest { mrrResourcePolicy = policy }
      planManifestReload validDoc validCatalog request
        @?= Left
              (MriInvalidResourcePolicy
                (MrpiVoicePolyphonyNonPositive 0))

  , testCase "non-positive fx polyphony rejects" $ do
      let policy = validPolicy { mrpFxPolyphony = 0 }
          request = validRequest { mrrResourcePolicy = policy }
      planManifestReload validDoc validCatalog request
        @?= Left
              (MriInvalidResourcePolicy
                (MrpiFxPolyphonyNonPositive 0))

  , testCase "non-positive template override rejects" $ do
      let policy = validPolicy
            { mrpTemplateOverrides =
                M.singleton (TemplateName "fx") 0
            }
          request = validRequest { mrrResourcePolicy = policy }
      planManifestReload validDoc validCatalog request
        @?= Left
              (MriInvalidResourcePolicy
                (MrpiTemplateOverrideNonPositive (TemplateName "fx") 0))

  , testCase "control surface projects typed target metadata" $ do
      plan <- planOrFail validDoc validCatalog validRequest
      mrlpControlSurface plan @?=
        [ ManifestControlSurface
            { mcsDisplayName = "cutoff"
            , mcsControlTag  = ControlTag (MigrationKey "cutoff") 1
            , mcsDefault     = 1200.0
            , mcsRangeMin    = 200.0
            , mcsRangeMax    = 8000.0
            , mcsSmoothingHz = 20.0
            , mcsCC          = Just 74
            }
        , ManifestControlSurface
            { mcsDisplayName = "resonance"
            , mcsControlTag  = ControlTag (MigrationKey "resonance") 2
            , mcsDefault     = 0.8
            , mcsRangeMin    = 0.1
            , mcsRangeMax    = 4.0
            , mcsSmoothingHz = 15.0
            , mcsCC          = Nothing
            }
        ]

  , testCase "reload plan defaults to FIFO arbitration without ownership claims" $ do
      plan <- planOrFail validDoc validCatalog validRequest
      case mrlpControlSurface plan of
        surface : _ -> do
          let target = mcsControlTag surface
              command = CmdControlWrite (VoiceKey "v0") target 1800.0
              oscProducer = testProducer ProducerOSC "osc"
              midiProducer = testProducer ProducerMIDI "midi"
              afterOscWrite =
                recordAcceptedSessionCommand
                  (mrlpArbitrationPolicy plan)
                  oscProducer
                  command
          mrlpArbitrationPolicy plan @?= FifoOnly
          arbitrateSessionCommand
            (mrlpArbitrationPolicy plan)
            oscProducer
            command
            @?= ArbitrationAllowed
          afterOscWrite @?= FifoOnly
          arbitrateSessionCommand afterOscWrite midiProducer command
            @?= ArbitrationAllowed
        [] ->
          assertFailure "expected at least one projected control"

  , testCase "plan projects to hot-swap command" $ do
      plan <- planOrFail validDoc validCatalog validRequest
      manifestReloadCommand plan
        @?= CmdHotSwapPreservingOnly (SwapLabel "reload") validTemplateGraph

  , testCase "plan projects adapter policy into owner options" $ do
      let baseOptions = defaultSessionOwnerOptions
            { sooBuilderCapacity = 1024
            , sooMaxFrames       = 256
            , sooAdapterOptions  = defaultRTGraphAdapterOptions
                { raoDefaultPolyphony = 99
                }
            }
      plan <- planOrFail validDoc validCatalog validRequest
      let ownerOptions = manifestSessionOwnerOptions baseOptions plan
      sooBuilderCapacity ownerOptions @?= 1024
      sooMaxFrames ownerOptions @?= 256
      sooAdapterOptions ownerOptions @?= mrlpAdapterOptions plan

  , testCase "construction helper brackets fresh owner from plan" $ do
      plan <- planOrFail validDoc validCatalog validRequest
      result <-
        constructManifestSessionFromPlan
          plan
          defaultSessionOwnerOptions
          $ \owner -> do
              state <- sessionOwnerState owner
              status <- sessionOwnerStatus owner
              pure (ssGraph state, status)
      result @?= Right (validTemplateGraph, SessionOwnerReady)

  , testCase "manifest-built owner commits a real voice start" $ do
      plan <- planOrFail validDoc validCatalog validRequest
      result <-
        constructManifestSessionFromPlan
          plan
          defaultSessionOwnerOptions
          $ \owner -> do
              let cmd = CmdVoiceOn (TemplateName "voice") (VoiceKey "v0") []
              stepped <- stepSessionOwner owner cmd
              state <- sessionOwnerState owner
              status <- sessionOwnerStatus owner
              pure (stepped, state, status)
      case result of
        Left issue ->
          assertFailure ("expected manifest-built owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing), state, status) -> do
          assertBool
            "expected manifest-built owner state to contain started voice"
            (M.member (VoiceKey "v0") (ssVoices state))
          status @?= SessionOwnerReady
        Right other ->
          assertFailure
            ("expected manifest-built owner voice-start commit, got: "
             <> show other)

  , testCase "stopped-audio reload helper replaces host owner from plan" $ do
      plan <- planOrFail validDoc validCatalog validRequest
      result <-
        withSessionFanInHost
          voiceOnlyTemplateGraph
          defaultSessionFanInOptions
          $ \host -> do
              before <- readSessionFanInHost host
              reload <-
                reloadManifestSessionStoppedAudio
                  host
                  defaultSessionOwnerOptions
                  plan
              snapshotAfter <- readSessionFanInHost host
              pure (before, reload, snapshotAfter)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (before, Right report, snapshotAfter) -> do
          ssGraph (sfisOwnerState before) @?= voiceOnlyTemplateGraph
          msarrDemoKey report @?= "demo"
          msarrSwapLabel report @?= SwapLabel "reload"
          ssGraph (msarrOwnerState report) @?= validTemplateGraph
          msarrOwnerStatus report @?= SessionOwnerReady
          msarrListenersMustRestart report @?= True
          sfisQueueDepth snapshotAfter @?= 0
          sfisReloadStatus snapshotAfter @?= SessionFanInNormalOperation
          ssGraph (sfisOwnerState snapshotAfter) @?= validTemplateGraph
        Right (_, Left issue, _) ->
          assertFailure
            ("expected stopped-audio reload success, got: " <> show issue)

  , testCase "stopped-audio reload rejects when fan-in queue is not empty" $ do
      plan <- planOrFail validDoc validCatalog validRequest
      let producer = testProducer ProducerTest "reload"
          command = CmdVoiceOn (TemplateName "voice") (VoiceKey "v0") []
      result <-
        withSessionFanInHost
          voiceOnlyTemplateGraph
          defaultSessionFanInOptions
          $ \host -> do
              enqueued <- enqueueSessionFanInCommand producer command host
              reload <-
                reloadManifestSessionStoppedAudio
                  host
                  defaultSessionOwnerOptions
                  plan
              snapshot <- readSessionFanInHost host
              pure (enqueued, reload, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (enqueued, reload, snapshot) -> do
          case sfierResult enqueued of
            SessionEnqueued {} ->
              pure ()
            other ->
              assertFailure ("expected enqueue success, got: " <> show other)
          reload @?= Left (SfriQueueNotEmpty 1)
          sfisQueueDepth snapshot @?= 1
          sfisReloadStatus snapshot @?= SessionFanInNormalOperation
          ssGraph (sfisOwnerState snapshot) @?= voiceOnlyTemplateGraph

  , testCase "failed stopped-audio owner reload leaves host unavailable" $ do
      let producer = testProducer ProducerTest "reload"
          command = CmdVoiceOn (TemplateName "voice") (VoiceKey "v0") []
      result <-
        withSessionFanInHost
          voiceOnlyTemplateGraph
          defaultSessionFanInOptions
          $ \host -> do
              reload <-
                reloadSessionFanInHostOwnerStoppedAudio
                  host
                  duplicateTemplateGraph
                  defaultSessionOwnerOptions
              rejected <- enqueueSessionFanInCommand producer command host
              snapshot <- readSessionFanInHost host
              pure (reload, rejected, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Left (SfriOwnerSetupFailed _), rejected, snapshot) -> do
          sfierResult rejected @?=
            SessionEnqueueRejected producer command SeiSessionUnavailable
          sfisQueueDepth snapshot @?= 0
          sfisReloadStatus snapshot @?= SessionFanInReloadFailed
        Right (other, _, _) ->
          assertFailure
            ("expected owner setup failure, got: " <> show other)

  , testCase "audio start happy path transitions host to audio-running" $ do
      let ffi = SessionFanInAudioFFI
            { saffiStartAudio       = \_ _ _ -> pure 0
            , saffiWaitAudioStarted = \_ _ -> pure True
            , saffiStopAudio        = \_ -> pure ()
            }
      result <-
        withSessionFanInHost
          voiceOnlyTemplateGraph
          defaultSessionFanInOptions
          $ \host -> do
              start <-
                startSessionFanInHostAudioWith ffi host audioOpts
              snapshot <- readSessionFanInHost host
              pure (start, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Left issue, _) ->
          assertFailure
            ("expected audio start success, got: " <> show issue)
        Right (Right (), snapshot) -> do
          sfisAudioRunning snapshot @?= True
          sfisReloadStatus snapshot @?= SessionFanInNormalOperation

  , testCase "audio start when already running rejects" $ do
      let ffi = mockOkAudioFFI
      result <-
        withSessionFanInHost
          voiceOnlyTemplateGraph
          defaultSessionFanInOptions
          $ \host -> do
              first  <- startSessionFanInHostAudioWith ffi host audioOpts
              second <- startSessionFanInHostAudioWith ffi host audioOpts
              snapshot <- readSessionFanInHost host
              pure (first, second, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Right (), Left SfaiAudioAlreadyRunning, snapshot) ->
          sfisAudioRunning snapshot @?= True
        Right (other1, other2, _) ->
          assertFailure
            ("expected first=Right, second=AlreadyRunning, got: "
             <> show other1 <> " / " <> show other2)

  , testCase "audio start nonzero rc reports SfaiStartFailed" $ do
      let ffi = SessionFanInAudioFFI
            { saffiStartAudio       = \_ _ _ -> pure 42
            , saffiWaitAudioStarted = \_ _ ->
                assertFailure "wait should not run on start failure"
                  >> pure False
            , saffiStopAudio        = \_ ->
                assertFailure "stop should not run on start failure"
            }
      result <-
        withSessionFanInHost
          voiceOnlyTemplateGraph
          defaultSessionFanInOptions
          $ \host -> do
              start    <- startSessionFanInHostAudioWith ffi host audioOpts
              snapshot <- readSessionFanInHost host
              pure (start, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Left (SfaiStartFailed 42), snapshot) ->
          sfisAudioRunning snapshot @?= False
        Right (other, _) ->
          assertFailure
            ("expected SfaiStartFailed 42, got: " <> show other)

  , testCase "audio start ready timeout reports SfaiReadyTimeout and stops audio" $ do
      stopCounter <- newIORef (0 :: Int)
      let ffi = SessionFanInAudioFFI
            { saffiStartAudio       = \_ _ _ -> pure 0
            , saffiWaitAudioStarted = \_ _ -> pure False
            , saffiStopAudio        = \_ -> modifyIORef' stopCounter (+ 1)
            }
      result <-
        withSessionFanInHost
          voiceOnlyTemplateGraph
          defaultSessionFanInOptions
          $ \host -> do
              start    <- startSessionFanInHostAudioWith ffi host audioOpts
              snapshot <- readSessionFanInHost host
              pure (start, snapshot)
      stops <- readIORef stopCounter
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Left SfaiReadyTimeout, snapshot) -> do
          sfisAudioRunning snapshot @?= False
          stops @?= 1
        Right (other, _) ->
          assertFailure
            ("expected SfaiReadyTimeout, got: " <> show other)

  , testCase "audio stop without start rejects with SfaiAudioAlreadyStopped" $ do
      result <-
        withSessionFanInHost
          voiceOnlyTemplateGraph
          defaultSessionFanInOptions
          $ \host -> do
              stop     <- stopSessionFanInHostAudioWith mockOkAudioFFI host
              snapshot <- readSessionFanInHost host
              pure (stop, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Left SfaiAudioAlreadyStopped, snapshot) ->
          sfisAudioRunning snapshot @?= False
        Right (other, _) ->
          assertFailure
            ("expected SfaiAudioAlreadyStopped, got: " <> show other)

  , testCase "audio start then stop returns host to audio-stopped" $ do
      let ffi = mockOkAudioFFI
      result <-
        withSessionFanInHost
          voiceOnlyTemplateGraph
          defaultSessionFanInOptions
          $ \host -> do
              start    <- startSessionFanInHostAudioWith ffi host audioOpts
              afterStart <- readSessionFanInHost host
              stop     <- stopSessionFanInHostAudioWith ffi host
              afterStop  <- readSessionFanInHost host
              pure (start, afterStart, stop, afterStop)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Right (), afterStart, Right (), afterStop) -> do
          sfisAudioRunning afterStart @?= True
          sfisAudioRunning afterStop @?= False
        Right (s, _, t, _) ->
          assertFailure
            ("expected start=Right and stop=Right, got: "
             <> show s <> " / " <> show t)

  , testCase "reload rejected when audio is running" $ do
      plan <- planOrFail validDoc validCatalog validRequest
      let ffi = mockOkAudioFFI
      result <-
        withSessionFanInHost
          voiceOnlyTemplateGraph
          defaultSessionFanInOptions
          $ \host -> do
              start  <- startSessionFanInHostAudioWith ffi host audioOpts
              reload <-
                reloadManifestSessionStoppedAudio
                  host
                  defaultSessionOwnerOptions
                  plan
              snapshot <- readSessionFanInHost host
              pure (start, reload, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Right (), Left SfriAudioStillRunning, snapshot) -> do
          sfisAudioRunning snapshot @?= True
          sfisReloadStatus snapshot @?= SessionFanInNormalOperation
          ssGraph (sfisOwnerState snapshot) @?= voiceOnlyTemplateGraph
        Right (s, r, _) ->
          assertFailure
            ("expected start=Right and reload=SfriAudioStillRunning, got: "
             <> show s <> " / " <> show r)

  , testCase "exception during waitAudioStarted stops audio and reverts state" $ do
      stopCounter <- newIORef (0 :: Int)
      let ffi = SessionFanInAudioFFI
            { saffiStartAudio       = \_ _ _ -> pure 0
            , saffiWaitAudioStarted = \_ _ ->
                throwIO (ErrorCall "wait boom")
            , saffiStopAudio        = \_ -> modifyIORef' stopCounter (+ 1)
            }
      result <-
        withSessionFanInHost
          voiceOnlyTemplateGraph
          defaultSessionFanInOptions
          $ \host -> do
              outcome <-
                try
                  (startSessionFanInHostAudioWith ffi host audioOpts)
                  :: IO (Either ErrorCall
                                (Either SessionFanInAudioIssue ()))
              snapshot <- readSessionFanInHost host
              pure (outcome, snapshot)
      stops <- readIORef stopCounter
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Left _, snapshot) -> do
          sfisAudioRunning snapshot @?= False
          stops @?= 1
        Right (Right ok, _) ->
          assertFailure
            ("expected exception propagation, got: " <> show ok)

  , testCase "exception during startAudio reverts state without leaving audio running" $ do
      stopCounter <- newIORef (0 :: Int)
      let ffi = SessionFanInAudioFFI
            { saffiStartAudio       = \_ _ _ ->
                throwIO (ErrorCall "start boom")
            , saffiWaitAudioStarted = \_ _ ->
                assertFailure "wait should not run after start failure"
                  >> pure False
            , saffiStopAudio        = \_ -> modifyIORef' stopCounter (+ 1)
            }
      result <-
        withSessionFanInHost
          voiceOnlyTemplateGraph
          defaultSessionFanInOptions
          $ \host -> do
              outcome <-
                try
                  (startSessionFanInHostAudioWith ffi host audioOpts)
                  :: IO (Either ErrorCall
                                (Either SessionFanInAudioIssue ()))
              snapshot <- readSessionFanInHost host
              pure (outcome, snapshot)
      stops <- readIORef stopCounter
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Left _, snapshot) -> do
          sfisAudioRunning snapshot @?= False
          stops @?= 1
        Right (Right ok, _) ->
          assertFailure
            ("expected exception propagation, got: " <> show ok)

  , testCase "exception during stopAudio leaves audio marked running (fail-closed)" $ do
      let startOkFFI = mockOkAudioFFI
          stopBoomFFI = SessionFanInAudioFFI
            { saffiStartAudio       = \_ _ _ ->
                assertFailure "start should not run via stop FFI"
                  >> pure 0
            , saffiWaitAudioStarted = \_ _ ->
                assertFailure "wait should not run via stop FFI"
                  >> pure False
            , saffiStopAudio        = \_ ->
                throwIO (ErrorCall "stop boom")
            }
      result <-
        withSessionFanInHost
          voiceOnlyTemplateGraph
          defaultSessionFanInOptions
          $ \host -> do
              start <- startSessionFanInHostAudioWith startOkFFI host audioOpts
              outcome <-
                try
                  (stopSessionFanInHostAudioWith stopBoomFFI host)
                  :: IO (Either ErrorCall
                                (Either SessionFanInAudioIssue ()))
              snapshot <- readSessionFanInHost host
              pure (start, outcome, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Right (), Left _, snapshot) ->
          sfisAudioRunning snapshot @?= True
        Right (s, o, _) ->
          assertFailure
            ("expected start=Right, stop exception, got: "
             <> show s <> " / " <> show o)

  , testCase "cleanup stopAudio failure leaves audio-running flag set and reload rejects" $ do
      plan <- planOrFail validDoc validCatalog validRequest
      let ffi = SessionFanInAudioFFI
            { saffiStartAudio       = \_ _ _ -> pure 0
            , saffiWaitAudioStarted = \_ _ ->
                throwIO (ErrorCall "wait boom")
            , saffiStopAudio        = \_ ->
                throwIO (ErrorCall "cleanup stop boom")
            }
      result <-
        withSessionFanInHost
          voiceOnlyTemplateGraph
          defaultSessionFanInOptions
          $ \host -> do
              outcome <-
                try
                  (startSessionFanInHostAudioWith ffi host audioOpts)
                  :: IO (Either ErrorCall
                                (Either SessionFanInAudioIssue ()))
              afterStart <- readSessionFanInHost host
              reload <-
                reloadManifestSessionStoppedAudio
                  host
                  defaultSessionOwnerOptions
                  plan
              afterReload <- readSessionFanInHost host
              pure (outcome, afterStart, reload, afterReload)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Left _, afterStart, Left SfriAudioStillRunning, afterReload) -> do
          sfisAudioRunning afterStart @?= True
          sfisAudioRunning afterReload @?= True
          sfisReloadStatus afterReload @?= SessionFanInNormalOperation
          ssGraph (sfisOwnerState afterReload) @?= voiceOnlyTemplateGraph
        Right (o, _, r, _) ->
          assertFailure
            ("expected start exception, reload=SfriAudioStillRunning, got: "
             <> show o <> " / " <> show r)
  ]

audioOpts :: SessionFanInAudioOptions
audioOpts = SessionFanInAudioOptions
  { sfiaoOutputChannels = 2
  , sfiaoDeviceID       = -1
  , sfiaoReadyTimeoutMs = 100
  }

mockOkAudioFFI :: SessionFanInAudioFFI
mockOkAudioFFI = SessionFanInAudioFFI
  { saffiStartAudio       = \_ _ _ -> pure 0
  , saffiWaitAudioStarted = \_ _ -> pure True
  , saffiStopAudio        = \_ -> pure ()
  }

validRequest :: ManifestReloadRequest
validRequest = ManifestReloadRequest
  { mrrDemoKey        = "demo"
  , mrrSwapLabel      = SwapLabel "reload"
  , mrrResourcePolicy = validPolicy
  }

validPolicy :: ManifestResourcePolicy
validPolicy = defaultManifestResourcePolicy
  { mrpVoicePolyphony = 4
  }

validDoc :: AuthoringManifestDoc
validDoc =
  AuthoringManifestDoc manifestSchemaVersion [validManifest]

validCatalog :: [ManifestReloadCatalogEntry]
validCatalog =
  [validCatalogEntry]

validCatalogEntry :: ManifestReloadCatalogEntry
validCatalogEntry = ManifestReloadCatalogEntry
  { mrcDemoKey       = "demo"
  , mrcManifest      = validManifest
  , mrcTemplateGraph = validTemplateGraph
  }

validManifest :: AuthoringManifest
validManifest = AuthoringManifest
  { mfDemoKey = "demo"
  , mfTemplates =
      [ ManifestTemplate "voice" "voice"
      , ManifestTemplate "fx" "fx"
      ]
  , mfBuses =
      [ ManifestBus "main-send" 16 ]
  , mfControls =
      [ ManifestControl
          { mcName        = "cutoff"
          , mcDefault     = 1200.0
          , mcRangeMin    = 200.0
          , mcRangeMax    = 8000.0
          , mcSmoothingHz = 20.0
          , mcCC          = Just 74
          , mcKey         = "cutoff"
          , mcSlot        = 1
          }
      , ManifestControl
          { mcName        = "resonance"
          , mcDefault     = 0.8
          , mcRangeMin    = 0.1
          , mcRangeMax    = 4.0
          , mcSmoothingHz = 15.0
          , mcCC          = Nothing
          , mcKey         = "resonance"
          , mcSlot        = 2
          }
      ]
  }

otherManifest :: AuthoringManifest
otherManifest =
  validManifest { mfDemoKey = "other" }

validTemplateGraph :: TemplateGraph
validTemplateGraph =
  compileTemplateGraphOrError
    [ ("voice", simpleGraph)
    , ("fx", simpleGraph)
    ]

voiceOnlyTemplateGraph :: TemplateGraph
voiceOnlyTemplateGraph =
  compileTemplateGraphOrError [("voice", simpleGraph)]

duplicateTemplateGraph :: TemplateGraph
duplicateTemplateGraph =
  validTemplateGraph
    { tgTemplates =
        case tgTemplates validTemplateGraph of
          tpl : rest ->
            tpl : tpl : rest
          [] ->
            []
    }

simpleGraph :: SynthGraph
simpleGraph = runSynth $ do
  s <- sinOsc 440.0 0.0
  _ <- out 0 s
  pure ()

compileTemplateGraphOrError :: [(String, SynthGraph)] -> TemplateGraph
compileTemplateGraphOrError rows =
  case compileTemplateGraph rows of
    Right tg -> tg
    Left err -> error ("compileTemplateGraph failed: " <> err)

planOrFail
  :: AuthoringManifestDoc
  -> [ManifestReloadCatalogEntry]
  -> ManifestReloadRequest
  -> IO ManifestReloadPlan
planOrFail doc catalog request =
  case planManifestReload doc catalog request of
    Right plan -> pure plan
    Left issue ->
      assertFailure ("expected manifest reload plan, got: " <> show issue)
