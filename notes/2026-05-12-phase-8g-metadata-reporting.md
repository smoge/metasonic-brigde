# Phase 8.G — Authoring Metadata Reporting

Date: 2026-05-12

Status: decision artifact for the 8.G closeout slice. The
slice surfaces the metadata that Phases 8.E (ensembles) and
8.F (named controls) record but that has, until now, been
invisible after authoring. The output target is textual:
`--inspect-only` and `--fusion-survey`, the two diagnostic
surfaces already used to read graphs cold. The Brick TUI
stays single-graph as it is today.

No `SynthGraph`, `TemplateGraph`, runtime ABI, IR, planner,
or compiler changes. The slice is read-only metadata
plumbing in the **app layer**.

## Scope

Five sites:

1. **App-level demo metadata carrier.** A new
   `DemoAuthoringMetadata` record on the demo model
   ([app/MetaSonic/App/Demos.hs](app/MetaSonic/App/Demos.hs))
   carries the per-demo authoring view: ensemble roles and
   named bus assignments from `AuthoredEnsemble`, named
   controls from Phase 8.F, and explicit template/voice
   names so survey row labels stay stable. The field is
   `Maybe`; legacy single-graph demos leave it `Nothing`.

2. **One small named-control demo.** Adds an authored
   single-template demo that exercises `control`,
   `ccControl`, and the smoother migration-key shape. The
   demo's job is to prove the metadata path end-to-end,
   not to demonstrate DSP cleverness.

3. **`--inspect-only` rendering.** After the existing
   compile summary, print a compact "Authoring metadata"
   block listing template roles, named buses + indices,
   named controls (name, default, range, smoothing Hz, CC
   binding, migration key, target slot). Suppressed when
   `demoAuthoring` is `Nothing` — no noise on legacy
   demos.

4. **`--fusion-survey` authoring section.** A small
   corpus-level summary block after the existing tables:
   demos with authoring metadata, total named buses, total
   named controls, CC-bound named-control count. Plus a
   short per-demo row for demos that carry metadata.

5. **Tests + snapshot pins.** Tests assert (a) the demo's
   reported metadata matches the underlying `SynthGraph` /
   `AuthoredEnsemble`, (b) the rendered text is stable
   enough to catch drift, (c) the send/return ensemble's
   bus index reports as `16`. Snapshot pins for the
   corpus-level counts.

### Types

In [app/MetaSonic/App/Demos.hs](app/MetaSonic/App/Demos.hs):

    data DemoAuthoringMetadata = DemoAuthoringMetadata
      { damTemplates :: ![DemoTemplateMetadata]
        -- per-template role + footprint view, in
        -- ensemble declaration order
      , damBuses     :: ![DemoBusMetadata]
        -- named bus → index, in stable allocation order
      , damControls  :: ![DemoNamedControlView]
        -- named controls, in declaration order
      }

    data DemoTemplateMetadata = DemoTemplateMetadata
      { dtmName :: !String
      , dtmRole :: !TemplateRole
      }

    data DemoBusMetadata = DemoBusMetadata
      { dbmName  :: !String
      , dbmIndex :: !Int
      }

    data DemoNamedControlView = DemoNamedControlView
      { dncName        :: !String
      , dncDefault     :: !Double
      , dncRange       :: !(Double, Double)
      , dncSmoothingHz :: !Double
      , dncCC          :: !(Maybe Word8)
      , dncKey         :: !MigrationKey
      , dncSlot        :: !Int
      }

The new `demoAuthoring :: Demo -> Maybe DemoAuthoringMetadata`
field hangs off `Demo`. Existing demos initialize it to
`Nothing` and rendering paths short-circuit on `Nothing`,
so adding the field does not produce noise on any of the
20+ pre-existing demos.

These types live in the app layer. They are **not**
exposed by `MetaSonic.Authoring` and they are **not**
visible to the compiler. Authoring constructs (a
`NamedControl`, an `AuthoredEnsemble`) populate these
records at demo-construction time; the reporting layer
reads them. Nothing rewrites a `SynthGraph`.

### Builder helpers

To keep demo-side metadata construction terse:

    ensembleMetadata
      :: Auth.AuthoredEnsemble -> DemoAuthoringMetadata
    -- Projects role + bus tables from an AuthoredEnsemble.
    -- Sets damControls = [].

    addNamedControl
      :: Auth.NamedControl
      -> DemoAuthoringMetadata
      -> DemoAuthoringMetadata
    -- Appends one control's metadata to damControls. The
    -- demo body captures the NamedControl in a let-binding
    -- (via runSynthWith) and threads it through this helper.

These are the only two app-side combinators 8.G needs;
adding more is 8.G+1 work.

### Demo: `named-control` (new)

A single-template demo that:

- declares one OSC-bound named control (`cutoff`) via
  `control`;
- declares one CC-bound named control (`vol`) via
  `ccControl`;
- routes a sawtooth voice through `lpf` keyed by `cutoff`
  and `gain` keyed by `vol`;
- writes to bus 0.

The graph is intentionally small — the value is in the
metadata path being exercised, not the patch. The demo
key is `"named-control"`; it shows up in `--help`, in the
demo table, and in `--fusion-survey`.

### `--inspect-only` rendering

After `printTraceSummary` and `printFusionSummaryFor`, a
new helper `printAuthoringMetadata :: Demo -> IO ()` runs.
When `demoAuthoring demo = Just dam`, the helper emits:

    ─── Authoring metadata ───
    Templates:
      voice  (voice template)
      fx     (fx template)
    Named buses:
      main-send → 16
    Named controls:
      cutoff   default=1200.0  range=[200.0, 8000.0]  smooth=20.0  key=cutoff  slot=1
      vol      default=0.3     range=[0.0, 1.0]       smooth=20.0  cc=7 key=vol slot=1

When `demoAuthoring demo = Nothing`, nothing prints. This
keeps the inspector output unchanged for the 20+ pre-
existing demos.

### `--fusion-survey` authoring section

After `printSurveyTotals`, a new helper
`printAuthoringSurvey :: [Demo] -> IO ()` prints:

    ─── Authoring metadata totals ───
    demos with authoring metadata : 2
    total named templates         : 2
    total named buses             : 1
    total named controls          : 2
    CC-bound named controls       : 1
    ─── Per-demo authoring rows ───
    named-control   templates=1  buses=0  controls=2  cc-controls=1
    send-return     templates=2  buses=1  controls=0  cc-controls=0

The totals are computed deterministically from
`demoAuthoring` across the surveyed demo list. No bench
noise, no scheduling dependency — these are structural
counts.

## What this slice does not change

- **No `SynthGraph` or `TemplateGraph` field.** The
  compiler IR stays free of authoring-level metadata. If
  a future slice wants metadata on compiled output, that
  is a separate piece of work with its own ABI implications.
- **No FFI surface.** Named controls already lower to
  tagged `KSmooth` nodes whose `MigrationKey` the runtime
  already carries; nothing new crosses the language
  boundary.
- **No new OSC grammar.** Reporting is read-only and
  text-only. Custom OSC paths stay parked behind a
  routing-ownership contract.
- **No Brick TUI changes.** The Brick inspector remains
  single-graph; the multi-template story is "see the
  textual summary," same as today. A multi-template Brick
  view is a larger piece of work that 8.G should not
  block on.
- **No metadata persistence / export.** No JSON, no
  hot-swap state shape. The slice is read-only-at-runtime
  reporting only.

## Test discipline

Tests live in a new `authoringMetadataTests` group in
[test/Spec.hs](test/Spec.hs):

- The `named-control` demo's `demoAuthoring` projection
  matches the lowered graph: control names round-trip to
  the `MigrationKey`s actually present in the compiled
  `RuntimeGraph` (via `rnMigrationKey`); the CC binding's
  node maps to the right smoother.
- The `send-return` ensemble demo reports
  `damBuses = [("main-send", 16)]` and
  `damTemplates = [("voice", VoiceTemplate), ("fx",
  FxTemplate)]`.
- `printAuthoringMetadata` renders stable text for the
  two demos that carry metadata — fixed-line, no
  Map-iteration-order surprise.
- `printAuthoringSurvey`'s totals match the per-demo
  metadata for the full demo table.

Snapshot pins:

- corpus authoring-metadata count is stable
  (`demos with authoring metadata = 2` at slice close);
- total-named-controls = 2, CC-bound-controls = 1,
  total-named-buses = 1.

These are structural counts, not measurements, so they
will not move under bench noise.

## Verification

- `stack test --test-arguments='--hide-successes'`
- `stack exec -- metasonic-bridge --snapshot-check`
- `stack exec -- metasonic-bridge --fusion-survey`
- `stack exec -- metasonic-bridge --inspect-only named-control`
- `stack exec -- metasonic-bridge --inspect-only send-return`

No C++ test run needed.

## Outcome ladder

  1. App-level metadata carrier + one named-control demo
     + `--inspect-only` block + `--fusion-survey` section
     + tests + snapshot pins land. **Mark 8.G complete
     (textual surface).** Multi-template Brick stays
     listed as a non-goal for this slice; the next layer
     is session/ownership scoping or metadata
     persistence/export, whichever pulls harder.
  2. Carrier + demo land but `--inspect-only` and survey
     output drift from the underlying ensemble. **Mark
     8.G partial.** Reporting layer is exactly the value
     8.G claims to add.
  3. Reporting compiles but tests cannot pin its content
     because the rendering is order-unstable. **Stop the
     slice.** The contract is "the printed metadata
     matches the authoring source"; without stable
     rendering, that contract is empty.

Case 1 is the target.

## Related artifacts

- [notes/2026-05-12-phase-8e-ensemble-builder.md](notes/2026-05-12-phase-8e-ensemble-builder.md)
  — 8.E closeout; the source of the ensemble metadata
  this slice surfaces.
- [notes/2026-05-12-phase-8f-named-controls.md](notes/2026-05-12-phase-8f-named-controls.md)
  — 8.F closeout; the source of the named-control
  metadata this slice surfaces.
- [src/MetaSonic/Authoring.hs](src/MetaSonic/Authoring.hs)
  — `AuthoringMetadata`, `NamedControlMetadata` —
  read by the new demo-layer projections.
