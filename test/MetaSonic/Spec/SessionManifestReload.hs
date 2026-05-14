-- | Pure manifest-driven session reload planner tests.
module MetaSonic.Spec.SessionManifestReload where

import qualified Data.Map.Strict                 as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Authoring.Manifest
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Pattern               (SwapLabel (..),
                                                  TemplateName (..))
import           MetaSonic.Session.ManifestReload
import           MetaSonic.Session.RTGraphAdapter


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

  , testCase "control metadata survives into the plan" $ do
      plan <- planOrFail validDoc validCatalog validRequest
      mrlpControlSurface plan @?= mfControls validManifest
  ]

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
