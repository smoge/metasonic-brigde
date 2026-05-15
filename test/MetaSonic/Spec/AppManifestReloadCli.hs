-- | App-level manifest reload CLI helper tests.
module MetaSonic.Spec.AppManifestReloadCli where

import qualified Data.ByteString.Lazy.Char8       as BL
import           Data.List                        (isInfixOf)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.Demos
import           MetaSonic.App.ManifestReloadCli
import           MetaSonic.App.ManifestReloadHost
                                                (ManifestReloadHostStrategy (..))
import           MetaSonic.Authoring.Manifest
import           MetaSonic.Session.ManifestReload


appManifestReloadCliTests :: TestTree
appManifestReloadCliTests =
  testGroup "App manifest reload CLI helpers"
  [ testCase "parses operator-visible host reload strategies" $ do
      parseManifestReloadHostStrategy "require-preserving"
        @?= Just RequirePreserving
      parseManifestReloadHostStrategy "try-preserving"
        @?= Just TryPreservingThenStoppedAudio
      parseManifestReloadHostStrategy "stopped-audio-only"
        @?= Just StoppedAudioOnly
      parseManifestReloadHostStrategy "maybe-preserving"
        @?= Nothing

  , testCase "stopped-audio smoke renders successful external manifest output" $ do
      targetDemo <- demoOrFail "send-return"
      catalog <- catalogOrFail demoTable
      sendReturnEntry <- entryOrFail "send-return" catalog
      let doc = AuthoringManifestDoc
            manifestSchemaVersion
            [mrcManifest sendReturnEntry]
      result <- runManifestStoppedAudioReloadSmokeWithDoc doc targetDemo
      case result of
        Left issue ->
          assertFailure
            ("expected stopped-audio smoke success, got: "
             <> renderManifestReloadCliIssue issue)
        Right smoke -> do
          let output = renderManifestStoppedAudioReloadSmoke smoke
          assertContains "Manifest stopped-audio reload smoke" output
          assertContains "  initial demo: named-control" output
          assertContains "  target demo: send-return" output
          assertContains "  pre-reload fan-in:" output
          assertContains "  post-reload fan-in:" output
          assertContains "    queue depth: 0" output
          assertContains "    graph installed: yes" output
          assertContains "  audio started: no" output
          assertContains "  audio stopped by helper: no" output
          assertContains "  listener restart executed: no" output
          assertContains
            "  command projection: CmdHotSwapPreservingOnly manifest:send-return templates=2 (not executed)"
            output

  , testCase "host strategy smoke renders explicit fallback outcome" $ do
      targetDemo <- demoOrFail "send-return"
      catalog <- catalogOrFail demoTable
      sendReturnEntry <- entryOrFail "send-return" catalog
      let doc = AuthoringManifestDoc
            manifestSchemaVersion
            [mrcManifest sendReturnEntry]
      -- The smoke host starts from an empty owner. Preserving-only
      -- reload therefore has no live bindings to migrate, so the
      -- explicit try-preserving strategy must take the stopped-audio
      -- fallback path.
      result <-
        runManifestHostStrategyReloadSmokeWithDoc
          TryPreservingThenStoppedAudio
          doc
          targetDemo
      case result of
        Left issue ->
          assertFailure
            ("expected host strategy smoke success, got: "
             <> renderManifestReloadCliIssue issue)
        Right output -> do
          assertContains "Manifest host strategy reload smoke" output
          assertContains "  strategy: try-preserving" output
          assertContains "  initial demo: named-control" output
          assertContains "  target demo: send-return" output
          assertContains
            "  strategy result: success: MrhsrStoppedAudioAfterPreservingRejected"
            output
          assertContains "    graph installed: yes" output
          assertContains "  ingress: open demo=send-return" output
          assertContains "  fake audio events:" output
          assertContains "    - start channels=2 device=-1" output
          assertContains "    - stop" output
          assertContains
            "  selector command projection: CmdHotSwapPreservingOnly manifest:send-return templates=2 (selector-controlled)"
            output

  , testCase "host strategy smoke renders stopped-audio-only outcome" $ do
      targetDemo <- demoOrFail "send-return"
      catalog <- catalogOrFail demoTable
      sendReturnEntry <- entryOrFail "send-return" catalog
      let doc = AuthoringManifestDoc
            manifestSchemaVersion
            [mrcManifest sendReturnEntry]
      result <-
        runManifestHostStrategyReloadSmokeWithDoc
          StoppedAudioOnly
          doc
          targetDemo
      case result of
        Left issue ->
          assertFailure
            ("expected stopped-audio-only host strategy smoke success, got: "
             <> renderManifestReloadCliIssue issue)
        Right output -> do
          assertContains "Manifest host strategy reload smoke" output
          assertContains "  strategy: stopped-audio-only" output
          assertContains "  strategy result: success: MrhsrStoppedAudio" output
          assertContains "    graph installed: yes" output
          assertContains "  ingress: open demo=send-return" output
          assertContains "  fake audio events:" output
          assertContains "    - start channels=2 device=-1" output
          assertContains "    - stop" output
          assertContains
            "  selector command projection: CmdHotSwapPreservingOnly manifest:send-return templates=2 (selector-controlled)"
            output

  , testCase "host strategy smoke renders preserving-required failure as diagnostic output" $ do
      targetDemo <- demoOrFail "send-return"
      catalog <- catalogOrFail demoTable
      sendReturnEntry <- entryOrFail "send-return" catalog
      let doc = AuthoringManifestDoc
            manifestSchemaVersion
            [mrcManifest sendReturnEntry]
      result <-
        runManifestHostStrategyReloadSmokeWithDoc
          RequirePreserving
          doc
          targetDemo
      case result of
        Left issue ->
          assertFailure
            ("expected host strategy smoke diagnostic output, got: "
             <> renderManifestReloadCliIssue issue)
        Right output -> do
          assertContains "  strategy: require-preserving" output
          assertContains "  strategy result: failed: MrhsiPreservingFailed" output
          assertContains "    graph installed: no" output
          assertContains "  ingress: open demo=named-control" output
          assertContains "  selector command projection:" output

  , testCase "missing manifest file reports read failure" $ do
      result <-
        readManifestReloadDocFile
          "/tmp/metasonic-bridge-step2-missing-dir/manifest.json"
      case result of
        Left issue ->
          assertContains
            "Failed to read manifest file '/tmp/metasonic-bridge-step2-missing-dir/manifest.json':"
            (renderManifestReloadCliIssue issue)
        Right _ ->
          assertFailure "expected missing manifest file to fail"

  , testCase "malformed manifest bytes report decode failure" $
      case decodeManifestReloadDocBytes "broken.json" (BL.pack "{") of
        Left issue ->
          assertContains
            "Failed to decode manifest file 'broken.json':"
            (renderManifestReloadCliIssue issue)
        Right _ ->
          assertFailure "expected malformed manifest JSON to fail"

  , testCase "unsupported manifest schema reports planning failure" $ do
      targetDemo <- demoOrFail "send-return"
      catalog <- catalogOrFail demoTable
      sendReturnEntry <- entryOrFail "send-return" catalog
      let doc = AuthoringManifestDoc
            (manifestSchemaVersion + 1)
            [mrcManifest sendReturnEntry]
      result <- runManifestStoppedAudioReloadSmokeWithDoc doc targetDemo
      case result of
        Left issue ->
          assertContains
            "Manifest reload planning failed: MriUnsupportedSchemaVersion"
            (renderManifestReloadCliIssue issue)
        Right _ ->
          assertFailure "expected unsupported manifest schema to fail"

  , testCase "missing requested manifest demo reports planning failure" $ do
      targetDemo <- demoOrFail "send-return"
      let doc = AuthoringManifestDoc manifestSchemaVersion []
      result <- runManifestStoppedAudioReloadSmokeWithDoc doc targetDemo
      case result of
        Left issue ->
          assertContains
            "Manifest reload planning failed: MriUnknownManifestDemo \"send-return\""
            (renderManifestReloadCliIssue issue)
        Right _ ->
          assertFailure "expected missing manifest demo to fail"
  ]

demoOrFail :: String -> IO Demo
demoOrFail key =
  case [ demo | demo <- demoTable, demoKey demo == key ] of
    [demo] -> pure demo
    []     -> assertFailure ("missing demo: " <> key)
    _      -> assertFailure ("duplicate demo: " <> key)

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

assertContains :: String -> String -> Assertion
assertContains needle haystack =
  assertBool
    ("expected output to contain " <> show needle <> "\n\noutput:\n" <> haystack)
    (needle `isInfixOf` haystack)
