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
import           MetaSonic.Session.ManifestReload.Construct
                                                   (constructManifestSessionFromPlan)
import           MetaSonic.Session.ManifestReload.Runtime
                                                   (ManifestStoppedAudioReloadReport (..),
                                                    reloadManifestSessionStoppedAudio)
import           MetaSonic.Session.FanIn           (SessionFanInReloadStatus (..),
                                                    SessionFanInSnapshot (..),
                                                    defaultSessionFanInOptions,
                                                    readSessionFanInHost,
                                                    withSessionFanInHost)
import           MetaSonic.Session.Owner          (SessionOwnerStatus (..),
                                                   defaultSessionOwnerOptions,
                                                   sessionOwnerState,
                                                   sessionOwnerStatus)
import           MetaSonic.Session.State          (SessionState (..))


appDemoCatalogTests :: TestTree
appDemoCatalogTests =
  testGroup "App demo manifest reload catalog"
  [ testCase "catalog includes only authored demos" $ do
      catalog <- catalogOrFail demoTable
      map mrcDemoKey catalog @?=
        [ "named-control"
        , "send-return"
        , "preserve-cutoff-dark"
        , "preserve-cutoff-bright"
        , "reject-preserving-smooth-dark"
        , "reject-preserving-smooth-bright"
        , "saw-filter-dark"
        , "saw-filter-bright"
        , "noise-filter-soft"
        , "noise-filter-sharp"
        ]

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
      preserveDark <- entryOrFail "preserve-cutoff-dark" catalog
      preserveBright <- entryOrFail "preserve-cutoff-bright" catalog
      templateNames (mrcTemplateGraph namedControl) @?= ["named-control"]
      templateNames (mrcTemplateGraph sendReturn) @?= ["voice", "fx"]
      templateNames (mrcTemplateGraph preserveDark) @?= ["drone"]
      templateNames (mrcTemplateGraph preserveBright) @?= ["drone"]

  , testCase "preserving demo pair manifests match their authoring reports" $ do
      catalog <- catalogOrFail demoTable
      preserveDark <- entryOrFail "preserve-cutoff-dark" catalog
      preserveBright <- entryOrFail "preserve-cutoff-bright" catalog
      mrcManifest preserveDark
        @?= manifestFromReport "preserve-cutoff-dark"
              preserveCutoffDarkAuthoring
      mrcManifest preserveBright
        @?= manifestFromReport "preserve-cutoff-bright"
              preserveCutoffBrightAuthoring

  , testCase "preserving demo pair plans through built-in catalog" $ do
      catalog <- catalogOrFail demoTable
      preserveDark <- entryOrFail "preserve-cutoff-dark" catalog
      preserveBright <- entryOrFail "preserve-cutoff-bright" catalog
      let doc = AuthoringManifestDoc
            manifestSchemaVersion
            (map mrcManifest catalog)
          planFor key = ManifestReloadRequest
            { mrrDemoKey        = key
            , mrrSwapLabel      = SwapLabel key
            , mrrResourcePolicy = defaultManifestResourcePolicy
            }
      case planManifestReload doc catalog (planFor "preserve-cutoff-dark") of
        Left issue ->
          assertFailure
            ("expected preserve-cutoff-dark plan, got: " <> show issue)
        Right plan ->
          mrlpTemplateGraph plan @?= mrcTemplateGraph preserveDark
      case planManifestReload doc catalog (planFor "preserve-cutoff-bright") of
        Left issue ->
          assertFailure
            ("expected preserve-cutoff-bright plan, got: " <> show issue)
        Right plan ->
          mrlpTemplateGraph plan @?= mrcTemplateGraph preserveBright

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

  , testCase "external manifest JSON constructs fresh owner through built-in catalog" $ do
      catalog <- catalogOrFail demoTable
      sendReturn <- entryOrFail "send-return" catalog
      let exportedDoc =
            AuthoringManifestDoc
              manifestSchemaVersion
              [mrcManifest sendReturn]
          request = ManifestReloadRequest
            { mrrDemoKey        = "send-return"
            , mrrSwapLabel      = SwapLabel "external-session-smoke"
            , mrrResourcePolicy = defaultManifestResourcePolicy
            }
      decodedDoc <-
        case decodeManifestDoc (encodeManifestDoc exportedDoc) of
          Left err  -> assertFailure ("expected decoded manifest: " <> err)
          Right doc -> pure doc
      plan <-
        case planManifestReload decodedDoc catalog request of
          Left issue ->
            assertFailure ("expected external manifest reload plan, got: " <> show issue)
          Right p ->
            pure p
      result <-
        constructManifestSessionFromPlan
          plan
          defaultSessionOwnerOptions
          $ \owner -> do
              state <- sessionOwnerState owner
              status <- sessionOwnerStatus owner
              pure (state, status)
      case result of
        Left issue ->
          assertFailure ("expected constructed owner, got: " <> show issue)
        Right (state, status) -> do
          ssGraph state @?= mrcTemplateGraph sendReturn
          status @?= SessionOwnerReady

  , testCase "external manifest JSON stopped-audio reload replaces fan-in owner through built-in catalog" $ do
      catalog <- catalogOrFail demoTable
      namedControl <- entryOrFail "named-control" catalog
      sendReturn <- entryOrFail "send-return" catalog
      let exportedDoc =
            AuthoringManifestDoc
              manifestSchemaVersion
              [mrcManifest sendReturn]
          request = ManifestReloadRequest
            { mrrDemoKey        = "send-return"
            , mrrSwapLabel      = SwapLabel "external-stopped-audio-smoke"
            , mrrResourcePolicy = defaultManifestResourcePolicy
            }
      decodedDoc <-
        case decodeManifestDoc (encodeManifestDoc exportedDoc) of
          Left err  -> assertFailure ("expected decoded manifest: " <> err)
          Right doc -> pure doc
      plan <-
        case planManifestReload decodedDoc catalog request of
          Left issue ->
            assertFailure ("expected external manifest reload plan, got: " <> show issue)
          Right p ->
            pure p
      result <-
        withSessionFanInHost
          (mrcTemplateGraph namedControl)
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
        Right (_, Left issue, _) ->
          assertFailure
            ("expected stopped-audio reload success, got: " <> show issue)
        Right (before, Right report, snapshotAfter) -> do
          ssGraph (sfisOwnerState before) @?= mrcTemplateGraph namedControl
          ssGraph (msarrOwnerState report) @?= mrcTemplateGraph sendReturn
          msarrDemoKey report @?= "send-return"
          msarrSwapLabel report @?= SwapLabel "external-stopped-audio-smoke"
          msarrOwnerStatus report @?= SessionOwnerReady
          msarrListenersMustRestart report @?= True
          sfisQueueDepth snapshotAfter @?= 0
          sfisReloadStatus snapshotAfter @?= SessionFanInNormalOperation
          ssGraph (sfisOwnerState snapshotAfter) @?= mrcTemplateGraph sendReturn
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
