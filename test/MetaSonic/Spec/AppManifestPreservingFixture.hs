-- | Drift guard for the committed @preserve-cutoff@ manifest
-- fixture.
--
-- The fixture at @examples/manifests/preserve-cutoff.json@ is the
-- blessed operator input for the preserving manifest live-reload
-- path (see [smoke runbook](../notes/2026-05-19-b-manifest-host-reload-smoke-runbook.md)).
-- It must stay byte-identical to what
-- @stack exec -- metasonic-bridge --authoring-manifest
-- preserve-cutoff-dark preserve-cutoff-bright@ produces; otherwise
-- the runbook's command sequence silently desyncs from the
-- committed input and operators end up debugging a stale fixture.
--
-- The test reconstructs the same 'AuthoringManifestDoc' the CLI
-- builds from 'preserveCutoffDarkAuthoring' /
-- 'preserveCutoffBrightAuthoring' in 'MetaSonic.App.Demos', runs it
-- through the canonical 'encodeManifestDoc' encoder, and asserts
-- byte-equality against the on-disk file. Any drift (control
-- default change, smoothing change, migration key rename, schema
-- bump, formatter swap) fails this test before it can mislead an
-- operator.
module MetaSonic.Spec.AppManifestPreservingFixture
  ( appManifestPreservingFixtureTests
  ) where

import qualified Data.ByteString.Lazy           as BL
import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.Demos            (demoTable, demoKey,
                                                 demoAuthoring)
import           MetaSonic.Authoring.Manifest   (AuthoringManifestDoc (..),
                                                 encodeManifestDoc,
                                                 manifestFromReport,
                                                 manifestSchemaVersion)

fixturePath :: FilePath
fixturePath = "examples/manifests/preserve-cutoff.json"

appManifestPreservingFixtureTests :: TestTree
appManifestPreservingFixtureTests =
  testGroup "Operator UX: preserve-cutoff manifest fixture"
  [ testCase
      "examples/manifests/preserve-cutoff.json matches --authoring-manifest output"
      $ do
      -- Pull the same two demos the canonical operator command
      -- targets: `--authoring-manifest preserve-cutoff-dark
      -- preserve-cutoff-bright`. Look them up by key so a future
      -- reorder of demoTable doesn't silently drop one.
      darkDemo <- case lookupDemo "preserve-cutoff-dark" of
        Just d  -> pure d
        Nothing -> assertFailure "preserve-cutoff-dark demo missing from demoTable"
                   >> error "unreachable"
      brightDemo <- case lookupDemo "preserve-cutoff-bright" of
        Just d  -> pure d
        Nothing -> assertFailure "preserve-cutoff-bright demo missing from demoTable"
                   >> error "unreachable"
      darkReport <- case demoAuthoring darkDemo of
        Just r  -> pure r
        Nothing -> assertFailure "preserve-cutoff-dark has no authoring metadata"
                   >> error "unreachable"
      brightReport <- case demoAuthoring brightDemo of
        Just r  -> pure r
        Nothing -> assertFailure "preserve-cutoff-bright has no authoring metadata"
                   >> error "unreachable"

      -- Build the same AuthoringManifestDoc runAuthoringManifest
      -- builds (app/Main.hs:983), in the same demo order.
      let doc = AuthoringManifestDoc
            { docSchemaVersion = manifestSchemaVersion
            , docDemos =
                [ manifestFromReport "preserve-cutoff-dark"   darkReport
                , manifestFromReport "preserve-cutoff-bright" brightReport
                ]
            }
          generated = encodeManifestDoc doc

      onDisk <- BL.readFile fixturePath
      assertEqual
        ("Fixture " <> fixturePath <> " is out of date. Regenerate with:\n"
         <> "  stack exec -- metasonic-bridge --authoring-manifest "
         <> "preserve-cutoff-dark preserve-cutoff-bright "
         <> "> " <> fixturePath)
        generated
        onDisk
  ]
  where
    lookupDemo k = case filter ((== k) . demoKey) demoTable of
      [d] -> Just d
      _   -> Nothing
