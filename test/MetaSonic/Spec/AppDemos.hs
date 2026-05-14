-- | App demo catalog adapter tests.
module MetaSonic.Spec.AppDemos where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.Demos
import           MetaSonic.Authoring.Manifest
import           MetaSonic.Bridge.Templates       (Template (..),
                                                   TemplateGraph (..))
import           MetaSonic.Pattern                (SwapLabel (..))
import           MetaSonic.Session.ManifestReload


appDemoCatalogTests :: TestTree
appDemoCatalogTests =
  testGroup "App demo manifest reload catalog"
  [ testCase "catalog includes only authored demos" $ do
      catalog <- catalogOrFail demoTable
      map mrcDemoKey catalog @?= ["named-control", "send-return"]

  , testCase "catalog filters unauthored demo rows directly" $ do
      let unauthored = Demo
            { demoKey       = "legacy"
            , demoLabel     = "Legacy"
            , demoBody      = SingleGraph simpleGraph
            , demoAuthoring = Nothing
            }
          authored = Demo
            { demoKey       = "named-control"
            , demoLabel     = "Named Control"
            , demoBody      = SingleGraph namedControlGraph
            , demoAuthoring = Just namedControlAuthoring
            }
      catalog <- catalogOrFail [unauthored, authored]
      map mrcDemoKey catalog @?= ["named-control"]

  , testCase "catalog manifests derive from demo authoring reports" $ do
      catalog <- catalogOrFail demoTable
      namedControl <- entryOrFail "named-control" catalog
      sendReturn <- entryOrFail "send-return" catalog
      mrcManifest namedControl
        @?= manifestFromReport "named-control" namedControlAuthoring
      mrcManifest sendReturn
        @?= manifestFromReport "send-return" sendReturnAuthoring

  , testCase "catalog graphs preserve app demo template names" $ do
      catalog <- catalogOrFail demoTable
      namedControl <- entryOrFail "named-control" catalog
      sendReturn <- entryOrFail "send-return" catalog
      templateNames (mrcTemplateGraph namedControl) @?= ["named-control"]
      templateNames (mrcTemplateGraph sendReturn) @?= ["voice", "fx"]

  , testCase "catalog output is consumable by manifest reload planner" $ do
      catalog <- catalogOrFail demoTable
      sendReturn <- entryOrFail "send-return" catalog
      let doc = AuthoringManifestDoc
            manifestSchemaVersion
            (map mrcManifest catalog)
          request = ManifestReloadRequest
            { mrrDemoKey        = "send-return"
            , mrrSwapLabel      = SwapLabel "app-catalog"
            , mrrResourcePolicy = defaultManifestResourcePolicy
            }
      case planManifestReload doc catalog request of
        Left issue ->
          assertFailure ("expected manifest reload plan, got: " <> show issue)
        Right plan ->
          mrlpTemplateGraph plan @?= mrcTemplateGraph sendReturn

  , testCase "external manifest JSON plans through built-in catalog" $ do
      catalog <- catalogOrFail demoTable
      sendReturn <- entryOrFail "send-return" catalog
      let exportedDoc =
            AuthoringManifestDoc
              manifestSchemaVersion
              [mrcManifest sendReturn]
          request = ManifestReloadRequest
            { mrrDemoKey        = "send-return"
            , mrrSwapLabel      = SwapLabel "external-json"
            , mrrResourcePolicy = defaultManifestResourcePolicy
            }
      decodedDoc <-
        case decodeManifestDoc (encodeManifestDoc exportedDoc) of
          Left err  -> assertFailure ("expected decoded manifest: " <> err)
          Right doc -> pure doc
      case planManifestReload decodedDoc catalog request of
        Left issue ->
          assertFailure ("expected external manifest reload plan, got: " <> show issue)
        Right plan -> do
          mrlpDemoKey plan @?= "send-return"
          mrlpTemplateGraph plan @?= mrcTemplateGraph sendReturn
  ]

catalogOrFail :: [Demo] -> IO [ManifestReloadCatalogEntry]
catalogOrFail demos =
  case demoManifestReloadCatalog demos of
    Right catalog -> pure catalog
    Left err ->
      assertFailure ("expected app demo catalog, got: " <> err)

entryOrFail
  :: String
  -> [ManifestReloadCatalogEntry]
  -> IO ManifestReloadCatalogEntry
entryOrFail key catalog =
  case [ entry | entry <- catalog, mrcDemoKey entry == key ] of
    [entry] -> pure entry
    []      -> assertFailure ("missing catalog entry: " <> key)
    _       -> assertFailure ("duplicate catalog entry: " <> key)

templateNames :: TemplateGraph -> [String]
templateNames graph =
  map tplName (tgTemplates graph)
