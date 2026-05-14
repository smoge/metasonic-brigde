# Manifest-Driven Session Reload And Resource Policy

Date: 2026-05-14

Status: implemented for the pure planner, diagnostic external JSON input, and
v1 construction-time session setup. This note remains the design record for
`MetaSonic.Session.ManifestReload`; runtime install strategy is covered by
`2026-05-14-g-manifest-reload-install-strategy.md`.

It defines the boundary for a pure planner that validates an authoring
manifest, chooses a caller-supplied graph/catalog entry, and derives session
resource policy before any live-owner reload, hot-swap protocol, or FFI path is
touched.

## Decision

Start manifest-driven session reload as a planning problem, not as a runtime
reload feature.

The Phase 8.H manifest is a stable description of the authoring surface:
templates, roles, named buses, named controls, ranges, CC bindings,
migration keys, and control slots. It is not a `SynthGraph`, not a
`TemplateGraph`, and not a save file for the lowered graph.

Therefore a reload request needs two inputs:

1. A decoded `AuthoringManifestDoc` that says what authoring surface the user
   or tool is asking for.
2. A caller-owned catalog that says which demo/session entries can actually
   rebuild the `TemplateGraph` and which manifest each entry is expected to
   expose.

The manifest can select and validate a catalog entry. It cannot reconstruct
that entry.

## Why This Comes First

The repo already has:

- export-only authoring manifests (`MetaSonic.Authoring.Manifest`);
- authoring reports that can be projected into manifests;
- pure session command/state admission;
- a runtime owner and RTGraph adapter that can install a known
  `TemplateGraph`;
- producer fan-in and optional arbitration.

The planner slice now provides the contract between authoring metadata and
session runtime policy. Jumping directly to a `--load-manifest` or
`withManifestSession` API would still mix three questions:

- Which graph should this manifest refer to?
- What resource policy should the session apply?
- How should a live owner install or hot-swap that graph?

The implemented planner answers only the first two questions, purely.

## Non-Goals

- No manifest import CLI that installs, reloads, or owns a session. The
  external-manifest CLI path is diagnostic only: it decodes JSON, plans, and
  prints the plan without touching a runtime owner.
- No runtime owner changes inside the pure planner.
- No `RTGraph` allocation or `withSessionOwner` wrapper inside the pure
  planner.
- No C++ runtime, FFI, OSC, or MIDI changes.
- No attempt to infer or rebuild a graph from JSON.
- No session file format.
- No manifest-owned arbitration policy yet.
- No state-preserving hot-swap policy changes.

## Planner Shape

The planner module lives at:

```haskell
MetaSonic.Session.ManifestReload
```

The module exposes a small pure API:

```haskell
planManifestReload
  :: AuthoringManifestDoc
  -> [ManifestReloadCatalogEntry]
  -> ManifestReloadRequest
  -> Either ManifestReloadIssue ManifestReloadPlan
```

Current data model:

```haskell
data ManifestReloadCatalogEntry = ManifestReloadCatalogEntry
  { mrcDemoKey          :: !String
  , mrcManifest         :: !AuthoringManifest
  , mrcTemplateGraph    :: !TemplateGraph
  }

data ManifestReloadRequest = ManifestReloadRequest
  { mrrDemoKey          :: !String
  , mrrSwapLabel        :: !SwapLabel
  , mrrResourcePolicy   :: !ManifestResourcePolicy
  }

data ManifestResourcePolicy = ManifestResourcePolicy
  { mrpVoicePolyphony   :: !Int
  , mrpFxPolyphony      :: !Int
  , mrpTemplateOverrides :: !(Map TemplateName Int)
  }

data ManifestReloadPlan = ManifestReloadPlan
  { mrlpDemoKey           :: !String
  , mrlpSwapLabel         :: !SwapLabel
  , mrlpTemplateGraph     :: !TemplateGraph
  , mrlpAdapterOptions    :: !RTGraphAdapterOptions
  , mrlpControlSurface    :: ![ManifestControlSurface]
  , mrlpArbitrationPolicy :: !ArbitrationPolicy
  }
```

`mrlpControlSurface` is the typed projection described in
[Control Surface](#control-surface). `mrlpArbitrationPolicy` defaults to
`FifoOnly`: a manifest can expose controls to a UI, OSC, MIDI, or later
policy layer without claiming ownership of those controls.

The implementation preserves the intended separation:

- `ManifestReloadCatalogEntry` supplies the real graph.
- `AuthoringManifestDoc` supplies the external/user-facing selection.
- `ManifestResourcePolicy` supplies session allocation policy.
- `ManifestReloadPlan` is the value runtime integration turns into
  `CmdHotSwap` and/or owner/adapter options.

## Catalog Responsibility

The catalog is intentionally outside the manifest. In the app today, this would
likely be derived from the demo table: the app knows both the graph and the
optional `AuthoringReport`. A future product host could derive it from a project
registry, plugin workspace, or compiled-in patch table.

The library planner should not import `app/MetaSonic/App/Demos.hs`. The app can
adapt its own demo rows into catalog entries and call the planner.

Each catalog entry should include an expected manifest derived from the same
source as export:

```haskell
manifestFromReport demoKey report
```

`mrcManifest` is not a free-form compatibility override. It must describe the
same catalog entry as `mrcTemplateGraph`: the app or host building the catalog
is responsible for deriving both from one source of truth, and the planner must
still verify that every template named by the manifest exists in `tgTemplates`.

That lets the planner compare the requested manifest entry against what the
current binary can rebuild. If the JSON came from an older version, changed
source, or a different catalog, the planner rejects before runtime.

## Validation Rules

The pure planner tests pin these rules:

- `docSchemaVersion` must equal `manifestSchemaVersion` for manually
  constructed docs. JSON decoding already rejects unsupported versions, but the
  planner should defend its direct Haskell API too.
- Duplicate demo keys in the manifest document reject.
- Duplicate demo keys in the catalog reject.
- Requested demo key missing from the manifest document rejects.
- Requested demo key missing from the catalog rejects.
- The manifest entry for the requested demo must match the catalog entry's
  expected manifest.
- An empty manifest document is valid data but cannot plan a selected reload.
- Template names in the requested manifest must be unique.
- Every template name in the requested manifest must exist in the selected
  catalog graph's `tgTemplates`.
- Template roles must be known direct-Haskell values too: `"voice"` or `"fx"`.
  JSON decoding already rejects unknown role strings, but the planner should
  not trust manually constructed `AuthoringManifest` values.
- Template roles are validation metadata. They do not cause graph
  reconstruction or graph rewriting.
- Manifest controls preserve their metadata into the plan's control surface:
  name, default, range, smoothing, CC binding, migration key, and slot.
- The first planner projects manifest `mcKey` and `mcSlot` directly into the
  existing `ControlTag` shape. It does not yet validate `mcSlot >= 0`; if that
  becomes necessary, add a targeted `MriInvalidControlSlot` issue before
  runtime integration.

The current implementation compares `AuthoringManifest` values exactly for the
requested demo. If diagnostics become too coarse, add field-specific issue
constructors later. Do not loosen validation silently.

Suggested issue vocabulary:

```haskell
data ManifestReloadIssue
  = MriUnsupportedSchemaVersion !Int
  | MriDuplicateManifestDemo !String
  | MriDuplicateCatalogDemo !String
  | MriUnknownManifestDemo !String
  | MriUnknownCatalogDemo !String
  | MriManifestMismatch !String !AuthoringManifest !AuthoringManifest
  | MriDuplicateTemplateName !TemplateName
  | MriCatalogMissingTemplate !TemplateName
  | MriUnknownTemplateRole !String !String
  | MriInvalidResourcePolicy !ManifestResourcePolicyIssue

data ManifestResourcePolicyIssue
  = MrpiVoicePolyphonyNonPositive !Int
  | MrpiFxPolyphonyNonPositive !Int
  | MrpiTemplateOverrideNonPositive !TemplateName !Int
```

## Resource Policy

Resource policy should start with template polyphony because the existing
runtime adapter already has a concrete hook:

```haskell
RTGraphAdapterOptions
  { raoPerTemplatePolyphony :: Map TemplateName Int
  , raoDefaultPolyphony     :: Int
  , raoHotSwapInstallTimeoutMs :: Int
  }
```

The manifest gives each template a role:

- `"voice"` templates use `mrpVoicePolyphony`;
- `"fx"` templates use `mrpFxPolyphony`;
- explicit `mrpTemplateOverrides` win over role defaults.

The planner produces deterministic `RTGraphAdapterOptions`:

- every template in the manifest gets one per-template polyphony entry;
- overrides are applied by `TemplateName`;
- non-positive policy values reject before runtime;
- `raoDefaultPolyphony` remains a conservative fallback, not the primary
  policy carrier.

`raoHotSwapInstallTimeoutMs` is not manifest-derived in this planner. Keep it on
the downstream runtime/owner configuration path and copy the runtime default
into `mrlpAdapterOptions` for the pure plan. A later runtime integration slice
can decide whether reload requests need an explicit timeout override.

Do not infer polyphony from active MIDI notes, pattern density, current voice
count, or runtime capacity in this first slice. Those are live-session policy
questions. The manifest reload planner is a static planning pass.

## Control Surface

The plan should carry the manifest controls forward without assigning producer
ownership yet.

The projection is intentionally close to the manifest row, but converts the raw
migration-key string and slot into the existing typed `ControlTag`:

```haskell
data ManifestControlSurface = ManifestControlSurface
  { mcsDisplayName :: !String
  , mcsControlTag  :: !ControlTag
  , mcsDefault     :: !Double
  , mcsRangeMin    :: !Double
  , mcsRangeMax    :: !Double
  , mcsSmoothingHz :: !Double
  , mcsCC          :: !(Maybe Word8)
  }
```

`mcsControlTag` carries the `MigrationKey` plus control slot needed by
session commands. The important boundary is that control metadata is visible to
a later UI, OSC, MIDI, or arbitration policy without mutating the queue or owner
defaults.

Because the projection emits `ControlTag`, this planner is the update point if
`ControlTag` later grows a more structured target identity. That coupling is
intentional for now: downstream session code can consume the plan without
rebuilding tags from raw strings and slots.

Do not implement `ManifestOwnership` in the first pass. The current producer
arbitration design keeps FIFO as the default and requires an explicit policy
owner before rejecting another producer's writes. A manifest can later become
that policy source, but the reload planner should not silently claim targets.
For now the plan carries `FifoOnly`; accepted writes under that policy do not
record owner claims.

## Runtime Integration

The strategy-independent projections have landed:

```text
ManifestReloadPlan
  -> SessionOwnerOptions / RTGraphAdapterOptions
  -> CmdHotSwap swapLabel templateGraph
```

The construction-time helper now uses the plan to build a fresh owner through
`MetaSonic.Session.ManifestReload.Construct`. It does not step `CmdHotSwap` or
claim live reload semantics.

The diagnostic external input path has also landed:

```text
metasonic-bridge --manifest-reload-plan-file MANIFEST.json DEMO
```

It reads `MANIFEST.json` as an `AuthoringManifestDoc`, validates the selected
demo against the built-in authored-demo catalog, and prints the same plan as
`--manifest-reload-plan`. It deliberately stops before owner allocation,
command enqueue, or any install/reload strategy.

Future product/runtime layers must still decide whether a reload entrypoint is:

- construction-time only;
- a stopped-audio clear/rebuild install;
- a preserving hot-swap through the existing live protocol;
- or a higher-level host operation that tears down and rebuilds the owner.

Those choices remain out of the planner. The plan value must stay useful to
any of them.

## Implemented Test Coverage

`test/MetaSonic/Spec/SessionManifestReload.hs` now covers:

- valid manifest + matching catalog yields a plan with the catalog graph;
- unknown requested manifest demo rejects;
- unknown requested catalog demo rejects;
- duplicate manifest demo keys reject;
- duplicate catalog demo keys reject;
- manifest/catalog mismatch rejects;
- empty manifest doc cannot plan a selected reload;
- manifest template missing from the catalog graph rejects;
- voice/fx role defaults produce expected `raoPerTemplatePolyphony`;
- template override wins over role default;
- non-positive role defaults or overrides reject;
- control metadata survives into the plan;
- `manifestReloadCommand` projects a plan to `CmdHotSwap`;
- `manifestSessionOwnerOptions` replaces adapter options while preserving
  owner sizing;
- `constructManifestSessionFromPlan` brackets a fresh owner from a plan;
- a manifest-built owner can commit an ordinary `CmdVoiceOn` through the real
  owner/RTGraph adapter path.
- external manifest JSON exported by `--authoring-manifest` can decode and
  plan against the built-in authored-demo catalog.

The runtime-facing tests are intentionally construction-time smoke tests. They
do not start live audio or claim reload semantics.

## Review Checklist

For future runtime or CLI integration, the design should still satisfy:

- The manifest does not reconstruct a graph.
- The catalog is caller-supplied.
- The planner is pure and deterministic.
- Resource-policy rejection happens before runtime.
- FIFO producer behavior remains unchanged by default.
- External manifest CLI input remains diagnostic-only.
- The plan contains enough information for a later owner/hot-swap adapter but
  does not choose that runtime path itself.
