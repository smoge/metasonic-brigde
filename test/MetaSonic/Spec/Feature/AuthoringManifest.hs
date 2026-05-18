-- | Phase 8.H: authoring manifest export tests.
--
-- Pins the JSON manifest export pipeline: schema version, encoder
-- determinism, decode round-tripping, named-control / send-return
-- ensemble fixtures, and the schemaVersion-bump rejection contract.
-- The 'namedControlReport' and 'sendReturnReport' fixtures stay
-- cohort-private to this module.
module MetaSonic.Spec.Feature.AuthoringManifest
  ( authoringManifestTests
  ) where

import qualified Data.ByteString.Lazy.Char8 as BL
import           Data.Maybe                (isJust)

import           Test.Tasty
import           Test.Tasty.HUnit

import qualified MetaSonic.Authoring       as Auth
import           MetaSonic.Authoring.Manifest
import           MetaSonic.Authoring.Report
import           MetaSonic.Bridge.Source

------------------------------------------------------------
-- Phase 8.H: authoring manifest export
------------------------------------------------------------

-- Builds a small named-control report inline so the
-- tests do not depend on the demo table (which lives in
-- app/, not the library).
namedControlReport :: AuthoringReport
namedControlReport =
  let Right cname  = Auth.controlName "cutoff"
      Right vname  = Auth.controlName "vol"
      Right crng   = Auth.controlRange 200 8000
      Right vrng   = Auth.controlRange 0 1
      ((cutoff, vol), _) = runSynthWith $ do
        c <- Auth.control     cname 1200 crng
        v <- Auth.ccControl 10 vname 0.3  vrng
        pure (c, v)
  in (addReportedControl vol
    $ addReportedControl cutoff emptyAuthoringReport)
       { arTemplates =
           [ ReportedTemplate "named-control" Auth.VoiceTemplate ]
       }

-- A two-template ensemble with one named bus, mirroring
-- the in-tree send-return demo.
sendReturnReport :: AuthoringReport
sendReturnReport =
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
  in case result of
       Right ae -> ensembleReport ae
       Left err -> error err

authoringManifestTests :: TestTree
authoringManifestTests =
  testGroup "Phase 8.H: authoring manifest export"
  [ testCase "manifestSchemaVersion is 1" $
      manifestSchemaVersion @?= 1

  , testCase "encoder always emits schemaVersion 1" $ do
      let doc = AuthoringManifestDoc 99 []
      case decodeManifestDoc (encodeManifestDoc doc) of
        Right d  -> docSchemaVersion d @?= manifestSchemaVersion
        Left err -> assertFailure err

  , testCase "named-control manifest has 1 template, 2 controls, 1 CC-bound" $ do
      let m = manifestFromReport "named-control" namedControlReport
      mfDemoKey m @?= "named-control"
      length (mfTemplates m) @?= 1
      length (mfBuses m)     @?= 0
      length (mfControls m)  @?= 2
      let ccBound = [ c | c <- mfControls m, isJust (mcCC c) ]
      length ccBound @?= 1
      map mcCC ccBound @?= [Just 10]

  , testCase "send-return manifest has 2 templates and main-send bus 16" $ do
      let m = manifestFromReport "send-return" sendReturnReport
      mfDemoKey m @?= "send-return"
      map (\t -> (mtName t, mtRole t)) (mfTemplates m) @?=
        [ ("voice", "voice")
        , ("fx",    "fx")
        ]
      mfBuses m @?= [ ManifestBus "main-send" 16 ]
      mfControls m @?= []

  , testCase "projection preserves declaration order" $ do
      let m  = manifestFromReport "named-control" namedControlReport
          names = map mcName (mfControls m)
      names @?= ["cutoff", "vol"]

  , testCase "JSON round-trip preserves named-control manifest" $ do
      let doc = AuthoringManifestDoc
            { docSchemaVersion = manifestSchemaVersion
            , docDemos =
                [ manifestFromReport "named-control" namedControlReport ]
            }
      case decodeManifestDoc (encodeManifestDoc doc) of
        Right d  -> d @?= doc
        Left err -> assertFailure $
          "expected round-trip, got decode error: " <> err

  , testCase "JSON round-trip preserves send-return manifest" $ do
      let doc = AuthoringManifestDoc
            { docSchemaVersion = manifestSchemaVersion
            , docDemos =
                [ manifestFromReport "send-return" sendReturnReport ]
            }
      case decodeManifestDoc (encodeManifestDoc doc) of
        Right d  -> d @?= doc
        Left err -> assertFailure $
          "expected round-trip, got decode error: " <> err

  , testCase "JSON round-trip preserves all ManifestControl fields" $ do
      -- Pin every per-control field through encode/decode so a
      -- regression that silently drops 'rangeMax' or 'slot'
      -- (e.g. a generic-derived instance) would fail.
      let m       = manifestFromReport "named-control" namedControlReport
          doc     = AuthoringManifestDoc manifestSchemaVersion [m]
      case decodeManifestDoc (encodeManifestDoc doc) of
        Left err -> assertFailure err
        Right d  -> case docDemos d of
          [m'] -> mfControls m' @?= mfControls m
          _    -> assertFailure "expected one demo entry"

  , testCase "FromJSON rejects unsupported schemaVersion" $ do
      let badDoc = BL.pack
            "{ \"schemaVersion\": 2, \"demos\": [] }"
      case decodeManifestDoc badDoc of
        Left _   -> pure ()
        Right _  -> assertFailure "expected schemaVersion=2 to reject"

  , testCase "FromJSON rejects missing schemaVersion" $ do
      let badDoc = BL.pack "{ \"demos\": [] }"
      case decodeManifestDoc badDoc of
        Left _   -> pure ()
        Right _  -> assertFailure "expected missing schemaVersion to reject"

  , testCase "FromJSON rejects ManifestControl missing cc field" $ do
      let badDoc = BL.pack $
            "{ \"schemaVersion\": 1, \"demos\": ["
            <> "{ \"demo\": \"d\""
            <> ", \"templates\": []"
            <> ", \"buses\": []"
            <> ", \"controls\": ["
            <> "    { \"name\": \"cutoff\""
            <> "    , \"default\": 1200"
            <> "    , \"rangeMin\": 200"
            <> "    , \"rangeMax\": 8000"
            <> "    , \"smoothingHz\": 20"
            <> "    , \"key\": \"cutoff\""
            <> "    , \"slot\": 1"
            <> "    }"
            <> "  ]"
            <> "} ] }"
      case decodeManifestDoc badDoc of
        Left _   -> pure ()
        Right _  -> assertFailure "expected missing cc field to reject"

  , testCase "FromJSON rejects unknown template role" $ do
      let badDoc = BL.pack $
            "{ \"schemaVersion\": 1, \"demos\": ["
            <> "{ \"demo\": \"d\""
            <> ", \"templates\": ["
            <> "    { \"name\": \"t\", \"role\": \"sidechain\" }"
            <> "  ]"
            <> ", \"buses\": []"
            <> ", \"controls\": []"
            <> "} ] }"
      case decodeManifestDoc badDoc of
        Left _   -> pure ()
        Right _  -> assertFailure "expected unknown role to reject"

  , testCase "empty docDemos round-trips" $ do
      let doc = AuthoringManifestDoc manifestSchemaVersion []
      case decodeManifestDoc (encodeManifestDoc doc) of
        Right d  -> d @?= doc
        Left err -> assertFailure err

  , testCase "manifest CC field preserves Nothing through round-trip" $ do
      let Right cname = Auth.controlName "cutoff"
          Right rng   = Auth.controlRange 200 8000
          (cutoff, _) = runSynthWith $ Auth.control cname 1200 rng
          r           = addReportedControl cutoff emptyAuthoringReport
          m           = manifestFromReport "cutoff-only" r
          doc         = AuthoringManifestDoc manifestSchemaVersion [m]
      case decodeManifestDoc (encodeManifestDoc doc) of
        Left err -> assertFailure err
        Right d  -> case docDemos d of
          [m'] -> case mfControls m' of
            [c]  -> mcCC c @?= Nothing
            _    -> assertFailure "expected one control"
          _    -> assertFailure "expected one demo entry"
  ]
