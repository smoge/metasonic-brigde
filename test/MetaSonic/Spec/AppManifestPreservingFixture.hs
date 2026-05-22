-- | Drift guard for the committed preserving manifest fixtures.
--
-- Three on-disk fixtures live under @examples/manifests/@ and are
-- referenced from runbooks, operator smokes, and the Phase 8b
-- live-session repertoire:
--
--   * @preserve-cutoff.json@ — the blessed happy-path input for
--     the preserving manifest live-reload path
--     (see [smoke runbook](../notes/2026-05-19-b-manifest-host-reload-smoke-runbook.md)).
--   * @reject-preserving-smooth.json@ — a reject-eligible sibling
--     used by the operator-pressure pass to exercise the
--     'SupervisedReloadRequestRejected' branch deterministically
--     (KSmooth on the gain path makes the active voice
--     preserve-unsupported).
--   * @saw-noise-filter.json@ — the Phase 8b Tier 1 repertoire,
--     four single-template drone demos in two preserving-compatible
--     pairs (saw / noise) with multi-control surfaces (pitch /
--     cutoff / q / level). See
--     [notes/2026-05-22-a-live-session-repertoire-design.md](../notes/2026-05-22-a-live-session-repertoire-design.md).
--
-- Each must stay byte-identical to what
-- @stack exec -- metasonic-bridge --authoring-manifest DARK BRIGHT@
-- produces for the corresponding demo pair; otherwise the runbook /
-- smoke command sequence silently desyncs from the committed input
-- and operators end up debugging a stale fixture.
--
-- For each fixture the test reconstructs the same
-- 'AuthoringManifestDoc' the CLI builds from the in-Haskell
-- authoring reports, runs it through the canonical
-- 'encodeManifestDoc' encoder, and asserts byte-equality against
-- the on-disk file. Any drift (control default change, smoothing
-- change, migration key rename, schema bump, formatter swap) fails
-- this test before it can mislead an operator. The MIDI CC / key /
-- slot decode assertion sits alongside each byte-eq test so the
-- two together pin: the source-of-truth has the binding, the file
-- on disk encodes it, and the decoder round-trips it.
module MetaSonic.Spec.AppManifestPreservingFixture
  ( appManifestPreservingFixtureTests
  ) where

import qualified Data.ByteString.Lazy           as BL
import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.Demos            (demoTable, demoKey,
                                                 demoAuthoring)
import           MetaSonic.App.ManifestMIDIReloadSmoke
                                                 (smokeIngressTargetPolicy)
import           MetaSonic.App.ManifestReloadIngressTarget
                                                 (ManifestReloadIngressTargetPolicy (..))
import           MetaSonic.Authoring.Manifest   (AuthoringManifest (..),
                                                 AuthoringManifestDoc (..),
                                                 ManifestControl (..),
                                                 decodeManifestDoc,
                                                 encodeManifestDoc,
                                                 manifestFromReport,
                                                 manifestSchemaVersion)
import           MetaSonic.App.ManifestReloadBinding
                                                 (ManifestUIVoiceSelection (..))
import           MetaSonic.Pattern              (VoiceKey (..))

fixturePath :: FilePath
fixturePath = "examples/manifests/preserve-cutoff.json"

rejectFixturePath :: FilePath
rejectFixturePath = "examples/manifests/reject-preserving-smooth.json"

tier1FixturePath :: FilePath
tier1FixturePath = "examples/manifests/saw-noise-filter.json"

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

  , testCase
      "preserve-cutoff manifest projects MIDI CC 74 on both demos"
      $ do
      -- Pins the MIDI ingress surface the --manifest-midi-reload-smoke
      -- runbook entry promises: both preserve-cutoff-* manifests
      -- expose exactly one 'cutoff' control with mcCC = Just 74 and
      -- migration key "lpf"/slot 0. Reads the on-disk fixture
      -- (decoded through the same FromJSON path the smoke CLI uses)
      -- rather than projecting from the demo source, so a stale
      -- fixture would surface here AND in the byte-equal test above.
      -- The two together pin: the source-of-truth has the binding,
      -- the file on disk encodes it, and the decoder round-trips it.
      raw <- BL.readFile fixturePath
      doc <- case decodeManifestDoc raw of
        Right d  -> pure d
        Left err -> assertFailure
                      ("failed to decode " <> fixturePath <> ": " <> err)
                    >> error "unreachable"
      let demoCC name =
            case [ mfControls m
                 | m <- docDemos doc, mfDemoKey m == name
                 ] of
              [[c]] -> Just (mcCC c, mcKey c, mcSlot c)
              _     -> Nothing
      demoCC "preserve-cutoff-dark"
        @?= Just (Just 74, "lpf", 0)
      demoCC "preserve-cutoff-bright"
        @?= Just (Just 74, "lpf", 0)

  , testCase
      "examples/manifests/reject-preserving-smooth.json matches --authoring-manifest output"
      $ do
      -- Parallel byte-equality drift guard for the
      -- reject-eligible fixture. Same reasoning as the
      -- preserve-cutoff test above: KSmooth makes the active
      -- voice preserve-unsupported, but the on-disk JSON has no
      -- way to express that — it just declares the control
      -- contract. If 'rejectPreservingSmooth*Authoring' changes
      -- (control rename, default shift, schema bump, formatter
      -- swap) but the JSON does not, the operator-pressure
      -- runbook silently desyncs from the committed input.
      darkDemo <- case lookupDemo "reject-preserving-smooth-dark" of
        Just d  -> pure d
        Nothing -> assertFailure "reject-preserving-smooth-dark demo missing from demoTable"
                   >> error "unreachable"
      brightDemo <- case lookupDemo "reject-preserving-smooth-bright" of
        Just d  -> pure d
        Nothing -> assertFailure "reject-preserving-smooth-bright demo missing from demoTable"
                   >> error "unreachable"
      darkReport <- case demoAuthoring darkDemo of
        Just r  -> pure r
        Nothing -> assertFailure "reject-preserving-smooth-dark has no authoring metadata"
                   >> error "unreachable"
      brightReport <- case demoAuthoring brightDemo of
        Just r  -> pure r
        Nothing -> assertFailure "reject-preserving-smooth-bright has no authoring metadata"
                   >> error "unreachable"

      let doc = AuthoringManifestDoc
            { docSchemaVersion = manifestSchemaVersion
            , docDemos =
                [ manifestFromReport "reject-preserving-smooth-dark"
                    darkReport
                , manifestFromReport "reject-preserving-smooth-bright"
                    brightReport
                ]
            }
          generated = encodeManifestDoc doc

      onDisk <- BL.readFile rejectFixturePath
      assertEqual
        ("Fixture " <> rejectFixturePath <> " is out of date. Regenerate with:\n"
         <> "  stack exec -- metasonic-bridge --authoring-manifest "
         <> "reject-preserving-smooth-dark reject-preserving-smooth-bright "
         <> "> " <> rejectFixturePath)
        generated
        onDisk

  , testCase
      "reject-preserving-smooth manifest projects MIDI CC 74 on both demos"
      $ do
      -- Same control contract as preserve-cutoff: one 'cutoff'
      -- control per demo, CC 74, migration key "lpf"/slot 0. The
      -- reject fixture exists to exercise the supervisor-rejection
      -- path, NOT to alter the ingress contract — pinning the
      -- decoded CC/key/slot guards against an accidental
      -- "let's bind a different control while we're here" drift.
      raw <- BL.readFile rejectFixturePath
      doc <- case decodeManifestDoc raw of
        Right d  -> pure d
        Left err -> assertFailure
                      ("failed to decode " <> rejectFixturePath <> ": " <> err)
                    >> error "unreachable"
      let demoCC name =
            case [ mfControls m
                 | m <- docDemos doc, mfDemoKey m == name
                 ] of
              [[c]] -> Just (mcCC c, mcKey c, mcSlot c)
              _     -> Nothing
      demoCC "reject-preserving-smooth-dark"
        @?= Just (Just 74, "lpf", 0)
      demoCC "reject-preserving-smooth-bright"
        @?= Just (Just 74, "lpf", 0)

  , testCase
      "examples/manifests/saw-noise-filter.json matches --authoring-manifest output"
      $ do
      -- Byte-equality drift guard for the Phase 8b Tier 1
      -- repertoire fixture. Same shape as the two guards above
      -- but covers four demos in one file: saw-filter-dark,
      -- saw-filter-bright, noise-filter-soft, noise-filter-sharp.
      -- If any of the four authoring records drifts (control
      -- rename, default shift, CC reassignment, range edit,
      -- migration-key/slot change) without the JSON being
      -- regenerated, the live-session repertoire silently
      -- desyncs from the committed fixture and operators see a
      -- stale control surface in the manifest live session.
      let demoKeys =
            [ "saw-filter-dark"
            , "saw-filter-bright"
            , "noise-filter-soft"
            , "noise-filter-sharp"
            ]
      manifests <- mapM lookupReportManifest demoKeys
      let doc = AuthoringManifestDoc
            { docSchemaVersion = manifestSchemaVersion
            , docDemos         = manifests
            }
          generated = encodeManifestDoc doc

      onDisk <- BL.readFile tier1FixturePath
      assertEqual
        ("Fixture " <> tier1FixturePath <> " is out of date. Regenerate with:\n"
         <> "  stack exec -- metasonic-bridge --authoring-manifest "
         <> unwords demoKeys
         <> " > " <> tier1FixturePath)
        generated
        onDisk

  , testCase
      "--manifest-midi-reload-smoke policy targets the same voice as the UI/OSC default"
      $ do
      -- Pins the smoke's printed "default MIDI voice:" line and
      -- the accepted CmdControlWrite voice= line against the
      -- runbook's blessed-flow promise (v0). An earlier policy
      -- hardcoded mritpMIDIDefaultVoice = VoiceKey "fx", which
      -- mismatched every voice-only template (including the
      -- preserve-cutoff fixture). The two ingress paths should
      -- target the same voice on the same demo unless an
      -- explicit per-demo resolver lands; this test fails if
      -- that hardcode flips back to "fx" or to anything other
      -- than the UI default.
      let policy = smokeIngressTargetPolicy
          uiDefault = muvsDefaultVoice (mritpUIVoiceSelection policy)
      mritpMIDIDefaultVoice policy @?= VoiceKey "v0"
      mritpMIDIDefaultVoice policy @?= uiDefault
  ]
  where
    lookupDemo k = case filter ((== k) . demoKey) demoTable of
      [d] -> Just d
      _   -> Nothing

    -- Look up a demo by key, require it carries authoring metadata,
    -- and project its manifest entry the same way runAuthoringManifest
    -- does. Asserts on the IO side so individual fixture tests stay
    -- linear rather than nesting one Maybe-case per demo.
    lookupReportManifest k = do
      demo <- case lookupDemo k of
        Just d  -> pure d
        Nothing -> assertFailure (k <> " demo missing from demoTable")
                   >> error "unreachable"
      report <- case demoAuthoring demo of
        Just r  -> pure r
        Nothing -> assertFailure (k <> " has no authoring metadata")
                   >> error "unreachable"
      pure (manifestFromReport k report)
