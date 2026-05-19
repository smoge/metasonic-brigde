-- | App-level manifest reload CLI helper tests.
module MetaSonic.Spec.AppManifestReloadCli where

import qualified Data.ByteString.Lazy.Char8       as BL
import           Data.Char                        (isDigit)
import           Data.List                        (isInfixOf, stripPrefix)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.Demos
import           MetaSonic.App.ManifestOSCListener
                                                (defaultListenerConfig,
                                                 lcPort,
                                                 liBoundPort)
import           MetaSonic.OSC.Listen           (withListenerSocket)
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
          -- Combined ingress target is wired: the rendered snapshot
          -- shows ui-controls, osc-controls, and midi-cc counts
          -- alongside the demo key, instead of a single UI count.
          assertContains "ui-controls=" output
          assertContains "osc-controls=" output
          assertContains "midi-cc=" output
          -- The reload-events timeline is wired through the host's
          -- @mrhcOnEvent@ hook. Try-preserving against an empty owner
          -- must run preserving → reject → admit → stopped-audio →
          -- commit → succeed; assert the events block carries each of
          -- those transitions.
          assertContainsInOrder
            [ "  reload events:"
            , "    - strategy started: try-preserving"
            , "    - preserving phase started"
            , "    - preserving phase rejected: Hpari"
            , "    - fallback admitted: Hpari"
            , "    - stopped-audio phase started"
            , "    - stopped-audio phase committed"
            , "    - strategy succeeded: MrhsrStoppedAudioAfterPreservingRejected"
            , "  fake audio events:"
            ]
            output
          -- Strategy frame brackets the run; no fallback-declined event
          -- should fire on the admitted-fallback path.
          assertNotContains "    - fallback declined" output
          assertNotContains "    - strategy failed" output

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
          -- Stopped-audio-only is the simplest event timeline: no
          -- preserving phase, no fallback admission, just the
          -- stopped-audio bracket plus the strategy frame.
          assertContainsInOrder
            [ "  reload events:"
            , "    - strategy started: stopped-audio-only"
            , "    - stopped-audio phase started"
            , "    - stopped-audio phase committed"
            , "    - strategy succeeded: MrhsrStoppedAudio"
            , "  fake audio events:"
            ]
            output
          assertNotContains "    - preserving phase" output
          assertNotContains "    - fallback admitted" output
          assertNotContains "    - strategy failed" output

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
          -- Require-preserving against an empty owner rejects in the
          -- preserving phase and surfaces a strategy failure. There is
          -- no fallback step.
          assertContainsInOrder
            [ "  reload events:"
            , "    - strategy started: require-preserving"
            , "    - preserving phase started"
            , "    - preserving phase rejected: Hpari"
            , "    - strategy failed: MrhsiPreservingFailed"
            , "  fake audio events:"
            ]
            output
          assertNotContains "    - fallback" output
          assertNotContains "    - stopped-audio phase" output
          assertNotContains "    - strategy succeeded" output

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

  , testCase "manifest/catalog mismatch reports a focused control diff" $ do
      targetDemo <- demoOrFail "named-control"
      catalog <- catalogOrFail demoTable
      namedControlEntry <- entryOrFail "named-control" catalog
      let catalogManifest = mrcManifest namedControlEntry
          requestedManifest = catalogManifest
            { mfControls =
                [ if mcName c == "vol"
                     then c { mcCC = Just 7 }
                     else c
                | c <- mfControls catalogManifest
                ]
            }
          doc =
            AuthoringManifestDoc manifestSchemaVersion [requestedManifest]
      result <- runManifestStoppedAudioReloadSmokeWithDoc doc targetDemo
      case result of
        Left issue -> do
          let output = renderManifestReloadCliIssue issue
          assertContains
            "manifest for demo 'named-control' does not match the compiled authoring catalog"
            output
          assertContains
            "JSON-only edits do not remap the built-in demo"
            output
          assertContains
            "control vol cc: manifest=7 catalog=10"
            output
          assertNotContains "AuthoringManifest {" output
        Right _ ->
          assertFailure "expected manifest/catalog mismatch to fail"

  , testCase "strategy smoke opens real OSC ingress and reports a bound port" $ do
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
            ("expected strategy smoke success, got: "
             <> renderManifestReloadCliIssue issue)
        Right output -> do
          assertContains "oscPort=" output
          -- Bound port must be a non-zero integer, proving a real UDP
          -- listener was bound (port 0 would be the unbound sentinel).
          let port = extractOscPort output
          assertBool
            ("expected positive oscPort, got: " <> show port
             <> " in output:\n" <> output)
            (port > 0)

  , testCase "preserving reload swaps real OSC ingress to a bound port on the new target" $ do
      -- TryPreservingThenStoppedAudio falls back to stopped-audio in
      -- the smoke (no live bindings to migrate), so the manager runs
      -- closeOld + openFresh against real ops. The final snapshot
      -- reflects the post-reload listener's bound port — concrete
      -- evidence that the ingress swap landed.
      targetDemo <- demoOrFail "send-return"
      catalog <- catalogOrFail demoTable
      sendReturnEntry <- entryOrFail "send-return" catalog
      let doc = AuthoringManifestDoc
            manifestSchemaVersion
            [mrcManifest sendReturnEntry]
      result <-
        runManifestHostStrategyReloadSmokeWithDoc
          TryPreservingThenStoppedAudio
          doc
          targetDemo
      case result of
        Left issue ->
          assertFailure
            ("expected strategy smoke success, got: "
             <> renderManifestReloadCliIssue issue)
        Right output -> do
          assertContains
            "  strategy result: success: MrhsrStoppedAudioAfterPreservingRejected"
            output
          assertContains "  ingress: open demo=send-return" output
          assertContains "oscPort=" output
          let port = extractOscPort output
          assertBool
            ("expected positive oscPort after reload, got: " <> show port)
            (port > 0)

  , testCase "strategy smoke releases its OSC port before returning" $ do
      -- After the smoke completes, the same UDP port must be
      -- re-bindable. This regression-protects the cleanup path: if the
      -- runner left its ingress manager open, the listener would still
      -- hold the socket and the second bind would fail with EADDRINUSE.
      targetDemo <- demoOrFail "send-return"
      catalog <- catalogOrFail demoTable
      sendReturnEntry <- entryOrFail "send-return" catalog
      let doc = AuthoringManifestDoc
            manifestSchemaVersion
            [mrcManifest sendReturnEntry]
      port <- pickFreePort
      let fixedCfg = (defaultListenerConfig 0) { lcPort = port }
      result <-
        runManifestHostStrategyReloadSmokeWithListenerConfig
          fixedCfg
          StoppedAudioOnly
          doc
          catalog
          targetDemo
      case result of
        Left issue ->
          assertFailure
            ("expected strategy smoke success on fixed port "
             <> show port
             <> ", got: "
             <> renderManifestReloadCliIssue issue)
        Right _output ->
          -- The smoke has returned; if cleanup ran, the port is free.
          withListenerSocket fixedCfg $ \(_sock, info) ->
            liBoundPort info @?= port

  , testCase "strategy smoke surfaces real OSC bind failure cleanly" $ do
      -- Occupy a UDP port for the test scope, then force the smoke to
      -- bind on the same port. The initial open inside the runner must
      -- surface MrciOSCIngressOpenFailed without falling back silently
      -- to a fake handle.
      targetDemo <- demoOrFail "send-return"
      catalog <- catalogOrFail demoTable
      sendReturnEntry <- entryOrFail "send-return" catalog
      let doc = AuthoringManifestDoc
            manifestSchemaVersion
            [mrcManifest sendReturnEntry]
      withListenerSocket (defaultListenerConfig 0) $ \(_sock, info) -> do
        let busyPort = liBoundPort info
            busyCfg  = (defaultListenerConfig 0) { lcPort = busyPort }
        result <-
          runManifestHostStrategyReloadSmokeWithListenerConfig
            busyCfg
            StoppedAudioOnly
            doc
            catalog
            targetDemo
        case result of
          Left issue ->
            assertContains
              "Manifest reload smoke OSC ingress open failed:"
              (renderManifestReloadCliIssue issue)
          Right output ->
            assertFailure
              ("expected real OSC bind failure, got success:\n" <> output)
  ]

-- | Pull the numeric value following @oscPort=@ out of the smoke's
-- rendered output. The renderer emits @oscPort=<digits>@ followed by
-- whitespace or end-of-line. Returns 0 if the substring is missing or
-- the value is not a digit string.
extractOscPort :: String -> Int
extractOscPort output =
  case scanForSuffix "oscPort=" output of
    Nothing ->
      0
    Just suffix ->
      case takeWhile isDigit suffix of
        []     -> 0
        digits -> read digits

-- | Find the first occurrence of @needle@ in @haystack@ and return the
-- text that immediately follows it. 'Nothing' if @needle@ is absent.
scanForSuffix :: String -> String -> Maybe String
scanForSuffix _ [] = Nothing
scanForSuffix needle s@(_ : rest) =
  case stripPrefix needle s of
    Just suffix -> Just suffix
    Nothing     -> scanForSuffix needle rest

-- | Bind a UDP socket on an ephemeral port, learn the OS-allocated
-- port number, and release the socket. Racy in principle — the port
-- could be taken before the caller rebinds — but adequate for a
-- single-test scenario inside one process.
pickFreePort :: IO Int
pickFreePort =
  withListenerSocket (defaultListenerConfig 0) $ \(_sock, info) ->
    pure (liBoundPort info)

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

assertNotContains :: String -> String -> Assertion
assertNotContains needle haystack =
  assertBool
    ("expected output not to contain " <> show needle <> "\n\noutput:\n" <> haystack)
    (not (needle `isInfixOf` haystack))

assertContainsInOrder :: [String] -> String -> Assertion
assertContainsInOrder needles haystack =
  go haystack needles
  where
    go _ [] =
      pure ()
    go remaining (needle : rest) =
      case scanForSuffix needle remaining of
        Nothing ->
          assertFailure
            ("expected output to contain "
             <> show needle
             <> " after the previous timeline entry\n\nremaining output:\n"
             <> remaining
             <> "\n\nfull output:\n"
             <> haystack)
        Just suffix ->
          go suffix rest
