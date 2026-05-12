# Phase 8.H — Authoring Manifest Export v1

Date: 2026-05-12

Status: decision artifact for the 8.H closeout slice. The
slice adds a one-way, export-only JSON manifest derived
from `AuthoringReport`. After this slice, an external tool
(or the eventual session layer) can ask for a stable,
machine-readable view of a demo's authoring surface
without touching the compiler IR or the runtime ABI.

No `SynthGraph`, `TemplateGraph`, runtime ABI, IR, FFI,
planner, OSC grammar, or Brick TUI changes. The slice is
plain JSON over what Phase 8.G already projects.

## Scope

Four sites:

1. **Library schema module.** `MetaSonic.Authoring.Manifest`
   carries the JSON-shaped records, the projection
   `manifestFromReport :: String -> AuthoringReport ->
   AuthoringManifest` (the `String` is the demo key),
   and explicit `ToJSON` / `FromJSON` instances. The
   manifest includes `schemaVersion = 1` as a top-level
   field so future readers can refuse versions they do
   not understand.
2. **CLI export mode.** A new
   `--authoring-manifest [demo-key ...]` mode in
   `app/Main.hs` builds an `AuthoringManifestDoc` (one
   `schemaVersion` plus a list of per-demo manifests),
   encodes to pretty JSON, and writes to stdout. Demos
   without `demoAuthoring` are silently skipped — naming
   a metadata-less demo yields an empty `demos` list, not
   a failure. Script-friendly by design.
3. **Tests.** A new `authoringManifestTests` group in
   [test/Spec.hs](test/Spec.hs) covers projection shape,
   semantic JSON round-trip, schema-version rejection,
   and order stability. No exact-byte JSON pinning — that
   couples tests to whitespace / key-ordering choices the
   encoder might legitimately change.
4. **Docs.** README gains one short CLI example under
   diagnostics. ROADMAP marks 8.H complete (or partial)
   based on the outcome ladder below.

### Types

In [src/MetaSonic/Authoring/Manifest.hs](src/MetaSonic/Authoring/Manifest.hs):

    manifestSchemaVersion :: Int
    manifestSchemaVersion = 1

    data AuthoringManifest = AuthoringManifest
      { mfDemoKey   :: !String
      , mfTemplates :: ![ManifestTemplate]
      , mfBuses     :: ![ManifestBus]
      , mfControls  :: ![ManifestControl]
      }

    data ManifestTemplate = ManifestTemplate
      { mtName :: !String
      , mtRole :: !String       -- "voice" | "fx"
      }

    data ManifestBus = ManifestBus
      { mbName  :: !String
      , mbIndex :: !Int
      }

    data ManifestControl = ManifestControl
      { mcName        :: !String
      , mcDefault     :: !Double
      , mcRangeMin    :: !Double
      , mcRangeMax    :: !Double
      , mcSmoothingHz :: !Double
      , mcCC          :: !(Maybe Word8)
      , mcKey         :: !String  -- MigrationKey bytes
      , mcSlot        :: !Int
      }

    -- One per CLI invocation. Carries the schema version
    -- explicitly; decoders must refuse other versions.
    data AuthoringManifestDoc = AuthoringManifestDoc
      { docSchemaVersion :: !Int
      , docDemos         :: ![AuthoringManifest]
      }

The `mtRole` field is a string rather than a `TemplateRole`
enum so the JSON surface stays stable if a future slice
adds a new role variant. The library translation maps
`VoiceTemplate → "voice"` and `FxTemplate → "fx"`; unknown
strings reject on decode.

### Projection

    manifestFromReport :: String -> AuthoringReport
                       -> AuthoringManifest

Strict transcription of the existing `AuthoringReport`:
templates in declaration order, buses in
allocation-index order (already sorted by
`ensembleReport`), controls in declaration order. No
sorting, no deduplication.

### JSON codec

Explicit instances, not generic-derived. Reasons:

- The `aeson` library is in the Stackage snapshot
  (`aeson-2.2.4.1`), so no new transitive deps.
- Generic-derived `ToJSON` would default to record-field
  names (`mfTemplates`, `mtRole`, etc.). The wire shape
  should be user-readable (`templates`, `role`); explicit
  instances keep the wire shape under control without a
  field-name-stripping helper.
- `FromJSON` rejects unsupported `schemaVersion` values
  with a clear error message. Reading a version-2 doc
  with a version-1 decoder fails honestly rather than
  silently producing wrong data.
- Encoders always emit `schemaVersion = 1`, even if a
  caller constructs an `AuthoringManifestDoc` with a stale
  in-memory version field.
- `cc` is a required v1 key for every control. Plain
  controls encode it as JSON `null`; omitting the key
  rejects on decode.

### CLI surface

    metasonic-bridge --authoring-manifest             # all demos
    metasonic-bridge --authoring-manifest named-control
    metasonic-bridge --authoring-manifest send-return named-control

The mode is non-audio, like `--snapshot-check` and
`--fusion-survey`. Output is pretty-printed JSON
(`aeson-pretty`), one document on stdout, exit 0.

Demos without `demoAuthoring`: silently filtered out. An
all-empty selection still produces a valid document:

    { "schemaVersion": 1, "demos": [] }

This keeps scripts that pipe through `jq` happy.

## What this slice does not change

- **No import / reload.** Decoders exist only so tests
  can round-trip; nothing in the runtime reads a
  manifest at startup. Session reload is a separate
  slice.
- **No `SynthGraph` / `TemplateGraph` field.** The
  compiler IR stays free of authoring-level metadata.
- **No FFI surface.** Manifest export happens entirely
  on the Haskell side.
- **No new OSC grammar.** Manifests describe the same
  controls the existing dispatcher already resolves.
- **No graph serialization.** The manifest is not a
  patch save format. It does not capture the
  `SynthGraph` shape, only the authoring-surface
  metadata. Anyone who needs the lowered graph back can
  rebuild it from source.
- **No Brick TUI changes.**
- **No environment-aware fields.** No timestamps,
  hostname, or user info; manifests should be byte-stable
  across machines for the same in-repo demo.

## Test discipline

Tests live in `authoringManifestTests` in
[test/Spec.hs](test/Spec.hs):

- `manifestSchemaVersion = 1` (pinned), and the encoder
  always emits schema version 1.
- An inline `named-control` report (two named controls,
  one CC-bound) produces a manifest with 1 template, 2
  controls, 1 of which has `mcCC = Just 7`.
- An inline `send-return` ensemble produces a manifest
  with 2 templates and `ManifestBus "main-send" 16`.
- Semantic JSON round-trip: `decode . encode = pure` for
  every test manifest. Pin field-by-field, not by exact
  bytes; the encoder's whitespace/order choices are not
  load-bearing.
- A version-2 input rejects on decode with a non-empty
  error message.
- An input with a missing `schemaVersion` rejects.
- A `ManifestControl` input with a missing `cc` key
  rejects, while JSON `null` round-trips as `mcCC =
  Nothing`.
- Projection order is stable: templates and controls in
  declaration order, buses in allocation-index order.
- Unknown `role` strings reject on decode.

No corpus-level snapshot pin: the demo table lives in
`app/` and is not reachable from the library snapshot
tool. The same constraint that punted on 8.G corpus pins
applies here.

## Verification

- `stack test --test-arguments='--hide-successes'`
- `stack exec -- metasonic-bridge --snapshot-check`
- `stack exec -- metasonic-bridge --authoring-manifest`
  (produces valid JSON; can be piped through `jq` to
  verify shape interactively)
- `stack exec -- metasonic-bridge --authoring-manifest named-control`

No C++ test run needed.

## Outcome ladder

  1. Library module + CLI mode + tests + docs land.
     **Mark 8.H complete.** Point the next slice at
     session-layer scoping prep (command/event ADT, OSC
     resolve-state rebuild, buffer/plugin lifecycle).
  2. Library module + tests land but CLI mode does not
     ship in time. **Mark 8.H partial.** The library
     surface is what the session layer needs to consume;
     the CLI is a convenience.
  3. Tests cannot round-trip semantically (e.g., field
     ordering matters on the receiving end). **Stop the
     slice.** The point of the manifest is exactly
     stable read-back.

Case 1 is the target.

## Related artifacts

- [notes/2026-05-12-phase-8g-metadata-reporting.md](notes/2026-05-12-phase-8g-metadata-reporting.md)
  — 8.G closeout; the source of the `AuthoringReport`
  that 8.H translates.
- [src/MetaSonic/Authoring/Report.hs](src/MetaSonic/Authoring/Report.hs)
  — projection layer.
- [src/MetaSonic/Authoring.hs](src/MetaSonic/Authoring.hs)
  — `AuthoringMetadata`, `NamedControlMetadata`,
  `TemplateRole`, `MigrationKey` shape that the manifest
  ultimately describes.
