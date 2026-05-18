-- | Phase 8.G: authoring metadata reporting tests.
--
-- Pins the projection contract from authoring metadata to the
-- inspector's report shape: empty/Nothing inputs render to no lines,
-- 'ensembleReport' faithfully reflects 'amRoles' and 'amBuses', and
-- 'cc'-built smoothed controls report their MIDI bindings, scaling
-- ranges, and runtime 'KSmooth' state.
module MetaSonic.Spec.Feature.AuthoringReport
  ( authoringReportTests
  ) where

import           Data.List                 (sort)

import           Test.Tasty
import           Test.Tasty.HUnit

import qualified MetaSonic.Authoring       as Auth
import           MetaSonic.Authoring.Report
import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.IR       (lowerGraph)
import           MetaSonic.Bridge.Source
import           MetaSonic.Types           (NodeKind (..))

authoringReportTests :: TestTree
authoringReportTests =
  testGroup "Phase 8.G: authoring metadata reporting"
  [ testCase "emptyAuthoringReport renders to no lines" $
      renderAuthoringReport (Just emptyAuthoringReport) @?= []

  , testCase "Nothing renders to no lines" $
      renderAuthoringReport Nothing @?= []

  , testCase "ensembleReport projects amRoles and amBuses" $ do
      -- Two voices sharing one named bus through the
      -- existing ensemble builder. The projection should
      -- preserve declaration order for templates and
      -- index-sorted order for buses.
      let g = runSynth $ do
            s <- sinOsc 440 0
            _ <- out 0 s
            pure ()
          result = Auth.ensemble $ do
            shared <- Auth.busNamed "shared"
            _      <- Auth.busNamed "second"
            Auth.voice "voice" g
            Auth.fx    "fx"    g
            -- referenced so 'shared' is allocated first
            let _ = shared
            pure ()
      ae <- case result of
        Left err -> assertFailure err >> error "unreachable"
        Right a  -> pure a
      let r = ensembleReport ae
      arTemplates r @?=
        [ ReportedTemplate "voice" Auth.VoiceTemplate
        , ReportedTemplate "fx"    Auth.FxTemplate
        ]
      arBuses r @?=
        [ ReportedBus "shared" 16
        , ReportedBus "second" 17
        ]
      arControls r @?= []

  , testCase "addReportedControl projects NamedControlMetadata" $ do
      let Right cname = Auth.controlName "cutoff"
          Right rng   = Auth.controlRange 200 8000
          (nc, _) = runSynthWith $
            Auth.controlWith
              (Auth.defaultControlOptions { Auth.coSmoothingHz = 25.0 })
              cname 1200 rng
          r = addReportedControl nc emptyAuthoringReport
      arControls r @?=
        [ ReportedControl
            { rcName        = "cutoff"
            , rcDefault     = 1200
            , rcRange       = (200, 8000)
            , rcSmoothingHz = 25.0
            , rcCC          = Nothing
            , rcKey         = MigrationKey "cutoff"
            , rcSlot        = 1
            }
        ]

  , testCase "addReportedControl preserves declaration order" $ do
      let Right nameA = Auth.controlName "a"
          Right nameB = Auth.controlName "b"
          Right rng   = Auth.controlRange 0 1
          ((a, b), _) = runSynthWith $ do
            ca <- Auth.control nameA 0.1 rng
            cb <- Auth.control nameB 0.2 rng
            pure (ca, cb)
          r = addReportedControl b
            $ addReportedControl a emptyAuthoringReport
      map rcName (arControls r) @?= ["a", "b"]

  , testCase "ccControl-derived ReportedControl records the CC binding" $ do
      let Right cname = Auth.controlName "vol"
          Right rng   = Auth.controlRange 0 1
          (nc, _, _) = runSynthCCs $ Auth.ccControl 7 cname 0.3 rng
          r = addReportedControl nc emptyAuthoringReport
      case arControls r of
        [c] -> rcCC c @?= Just 7
        _   -> assertFailure "expected one ReportedControl"

  , testCase "report controls round-trip to compiled MigrationKeys" $ do
      -- End-to-end: a graph built from two named controls
      -- compiles into KSmooth nodes carrying the same
      -- MigrationKeys the report records. If a slice
      -- silently broke the tagged-smoother contract this
      -- would catch it.
      let Right cutoffName = Auth.controlName "cutoff"
          Right volName    = Auth.controlName "vol"
          Right cutoffRng  = Auth.controlRange 200 8000
          Right volRng     = Auth.controlRange 0 1
          ((cutoff, vol), sg) = runSynthWith $ do
            c   <- Auth.control      cutoffName 1200 cutoffRng
            v   <- Auth.ccControl  7 volName    0.3  volRng
            osc <- sawOsc 220 0
            f   <- lpf osc (Auth.controlConnection c) (Param 0.7)
            g   <- gain f  (Auth.controlConnection v)
            _   <- out 0 g
            pure (c, v)
          report =
              addReportedControl vol
            $ addReportedControl cutoff emptyAuthoringReport
          reportedKeys = sort
            [ unMigrationKey (rcKey c) | c <- arControls report ]
      reportedKeys @?= ["cutoff", "vol"]
      case lowerGraph sg >>= compileRuntimeGraph of
        Left err -> assertFailure err
        Right rt -> do
          let smoothKeys = sort
                [ unMigrationKey k
                | n <- rgNodes rt
                , rnKind n == KSmooth
                , Just k <- [rnMigrationKey n]
                ]
          smoothKeys @?= reportedKeys

  , testCase "send-return ensemble report reports bus 16 and the voice/fx pair" $ do
      -- Pins the bus-allocation determinism in the
      -- reporting projection: the ensemble builder
      -- allocates from eoBusBase=16, and the report
      -- preserves the (name, index) pair.
      let g = runSynth $ do
            s <- sinOsc 440 0
            _ <- out 0 s
            pure ()
          result = Auth.ensemble $ do
            sendBus <- Auth.busNamed "main-send"
            Auth.voice "voice" g
            Auth.fx    "fx"    g
            let _ = sendBus
            pure ()
      ae <- case result of
        Left err -> assertFailure err >> error "unreachable"
        Right a  -> pure a
      let r = ensembleReport ae
      arTemplates r @?=
        [ ReportedTemplate "voice" Auth.VoiceTemplate
        , ReportedTemplate "fx"    Auth.FxTemplate
        ]
      arBuses r    @?= [ ReportedBus "main-send" 16 ]
      arControls r @?= []

  , testCase "renderAuthoringReport on a named-control report is stable" $ do
      -- Pin the exact line output. Drift here either
      -- means the renderer changed (deliberately) or the
      -- underlying metadata changed shape; both should
      -- force a deliberate test update.
      let Right cutoffName = Auth.controlName "cutoff"
          Right volName    = Auth.controlName "vol"
          Right cutoffRng  = Auth.controlRange 200 8000
          Right volRng     = Auth.controlRange 0 1
          ((cutoff, vol), _) = runSynthWith $ do
            c <- Auth.control     cutoffName 1200 cutoffRng
            v <- Auth.ccControl 10 volName   0.3  volRng
            pure (c, v)
          report = (addReportedControl vol
                  $ addReportedControl cutoff emptyAuthoringReport)
            { arTemplates =
                [ ReportedTemplate "named-control" Auth.VoiceTemplate ]
            }
      renderAuthoringReport (Just report) @?=
        [ ""
        , "  ─── Authoring metadata ───"
        , "  Templates:"
        , "    named-control  (voice template)"
        , "  Named controls:"
        , "    cutoff  default=1200.0  range=[200.0, 8000.0]"
          <> "  smooth=20.0  key=cutoff  slot=1"
        , "    vol  default=0.3  range=[0.0, 1.0]"
          <> "  smooth=20.0  cc=10  key=vol  slot=1"
        ]

  , testCase "renderAuthoringReport on a send-return ensemble report is stable" $ do
      let g = runSynth $ do
            s <- sinOsc 440 0
            _ <- out 0 s
            pure ()
          result = Auth.ensemble $ do
            sendBus <- Auth.busNamed "main-send"
            Auth.voice "voice" g
            Auth.fx    "fx"    g
            let _ = sendBus
            pure ()
      ae <- case result of
        Left err -> assertFailure err >> error "unreachable"
        Right a  -> pure a
      renderAuthoringReport (Just (ensembleReport ae)) @?=
        [ ""
        , "  ─── Authoring metadata ───"
        , "  Templates:"
        , "    voice  (voice template)"
        , "    fx  (fx template)"
        , "  Named buses:"
        , "    main-send → 16"
        ]
  ]
