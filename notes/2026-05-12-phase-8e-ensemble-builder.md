# Phase 8.E — Ensemble Builder v1

Date: 2026-05-12

Status: decision artifact for the 8.E closeout slice. The
slice adds the ensemble builder layer 8.D promised: a small
authoring monad that produces an ordered
`[(String, SynthGraph)]` plus deterministic bus assignments,
ready to feed straight into the existing
`compileTemplateGraph`. After this slice, authoring a
multi-template synth + FX patch no longer requires
hand-managing template name lists or hand-picking bus
indices.

No runtime, FFI, planner, or `Compile`/`Templates` changes.
The slice is purely elaboration. The ensemble builder
produces a value of the same shape `compileTemplateGraph`
already accepts; the only new behavior is *how* that value
is constructed at authoring time.

## Scope

All in [src/MetaSonic/Authoring.hs](src/MetaSonic/Authoring.hs).

### Types

    data AuthoredEnsemble = AuthoredEnsemble
      { aeTemplates :: [(String, SynthGraph)]
        -- in declaration order, ready for compileTemplateGraph
      , aeMetadata  :: AuthoringMetadata
      }

    data EnsembleOptions = EnsembleOptions
      { eoBusBase :: Int
        -- first bus assigned to a 'busNamed' call. Default 16,
        -- pinned by tests.
      }

    data TemplateRole = VoiceTemplate | FxTemplate

    data AuthoringMetadata = AuthoringMetadata
      { amRoles :: [(String, TemplateRole)]
        -- per-template role tag in declaration order
      , amBuses :: M.Map String Bus
        -- bus name → Bus assignment for every 'busNamed' call
      }

`aeTemplates` is the input shape `compileTemplateGraph`
already accepts; nothing about the compile pipeline changes.
`aeMetadata` is diagnostic only — it is *not* read by
`compileTemplateGraph` and does not affect the compiled
shape. Tests pin that contract explicitly.

### Builder API

    ensemble     ::                       EnsembleM () -> Either String AuthoredEnsemble
    ensembleWith :: EnsembleOptions -> EnsembleM () -> Either String AuthoredEnsemble

    busNamed :: String -> EnsembleM Bus
    voice    :: String -> SynthGraph -> EnsembleM ()
    fx       :: String -> SynthGraph -> EnsembleM ()

`ensemble` is `ensembleWith defaultEnsembleOptions`. The
`Either String` return is what surfaces authoring errors
(duplicate template names; potentially other declarative
issues a future slice adds). `SynthM` is **not** affected —
templates are still authored with `runSynth` and passed in
as ordinary `SynthGraph` values.

`busNamed "send"`:
- First call allocates a fresh `Bus` at `eoBusBase`, then
  `eoBusBase + 1`, and so on.
- Repeated calls with the *same name* return the same `Bus`
  (idempotent). This is how a `voice` and an `fx` agree on
  a shared send bus without threading an integer through
  both.

`voice` and `fx` differ only in the role tag they record in
`amRoles`. Both append to `aeTemplates` in declaration
order. Duplicate template names produce
`Left "ensemble: duplicate template name 'foo'"` at the
`ensemble` / `ensembleWith` level; `compileTemplateGraph`
also catches this downstream, but the authoring layer
surfaces it before the user reaches a compiler error.

### Defaults

    defaultEnsembleOptions :: EnsembleOptions
    defaultEnsembleOptions = EnsembleOptions { eoBusBase = 16 }

`eoBusBase = 16` is chosen so authored ensembles do not
collide with the common 0-15 hardware/explicit-bus range
typical patches use. The exact value is pinned by tests so
silent drift would fail the suite — the *value* is not load-
bearing, the *stability* of the choice is.

## What this slice does not change

- **No deterministic allocation across ensembles.** Bus
  indices are per-ensemble. If two `AuthoredEnsemble`s use
  `busNamed "send"`, they each start from `eoBusBase` and
  the names are not federated.
- **No `compileTemplateGraph` changes.** `aeTemplates` is
  declaration order; `compileTemplateGraph` continues to
  derive its own dependency-driven execution order via
  `tgPrecedence` and `tplFootprint`. The ensemble builder
  does not pre-sort templates.
- **No `SynthM` changes.** Templates are authored with the
  existing `runSynth` and passed in as ordinary
  `SynthGraph` values. The ensemble layer composes
  pre-built graphs; it does not nest builders.
- **No `NodeKind`, no FFI surface, no runtime changes.**
- **No named-control support.** Control naming is 8.F and
  needs a separate OSC/MIDI lookup contract.
- **No metadata-driven scheduling.** `TemplateRole` is a
  diagnostic tag. `compileTemplateGraph` does not see it.
  A future slice may use it for inspector output or
  ordering hints; this slice does not.

## Test discipline

Tests live in `authoringDslTests` in
[test/Spec.hs](test/Spec.hs) and pin **what the ensemble
builder produces**, not authoring-side surface ergonomics:

- `defaultEnsembleOptions` has `eoBusBase = 16`.
- `busNamed "send"` in a default-options ensemble produces
  `Bus 16`.
- A second `busNamed "send"` in the same ensemble returns
  the same `Bus 16` (idempotency).
- `busNamed "send"` then `busNamed "fxchain"` produces
  `Bus 16` and `Bus 17` (allocation order, not name order).
- `ensembleWith` with `eoBusBase = 100` produces `Bus 100`
  for the first allocation.
- A `voice "v" g >> voice "v" g'` block returns
  `Left "ensemble: duplicate template name 'v'"`.
- `aeTemplates` preserves declaration order: a
  `voice "first" >> fx "second"` block returns
  `aeTemplates = [("first", _), ("second", _)]` regardless
  of any internal accumulator strategy.
- `aeMetadata.amRoles` records `("first", VoiceTemplate)`
  before `("second", FxTemplate)` in declaration order.
- Compile round-trip: an ensemble whose two templates use
  the same `busNamed` handle (one `Auth.send`, one
  `Auth.returnBus`) compiles through
  `compileTemplateGraph` and produces:
    - the sender's `bfWrites` includes the allocated bus;
    - the receiver's `bfReads` includes the allocated bus;
    - `tgTemplates` orders the sender before the receiver
      (the standard §4.E precedence rule).
- Metadata-vs-compile separation: a `let withMeta = e {
  aeMetadata = ... }` rebind that changes only the
  metadata produces the same `compileTemplateGraph` output
  as the original. The metadata is not on the compiled
  path.

## Demo

The `send-return` demo's templates and bus index are
rewritten to flow through the ensemble builder:

    sendReturnEnsemble :: AuthoredEnsemble
    sendReturnEnsemble = either error id $ ensemble $ do
      sendBus <- busNamed "main-send"
      voice "voice" (sendReturnVoiceM sendBus)
      fx    "fx"    (sendReturnFxM    sendBus)

The compiled `TemplateGraph` is structurally equivalent to
8.D's: same per-template node counts, same `bfWrites` /
`bfReads` split (on the new ensemble-allocated bus, not the
hand-picked `7`), same writer-before-reader ordering. The
bus *number* changes from `7` to whatever the default
`eoBusBase` allocates (`16`); the bus *footprint shape*
stays identical.

## Verification

- `stack test --test-arguments='--hide-successes'`
- `stack exec -- metasonic-bridge --snapshot-check`
  (regression check: no snapshot pin moves; the authoring
  layer is below the cost-lab/gate machinery).
- `stack exec -- metasonic-bridge --fusion-survey send-return`
  to confirm the rewritten demo's footprint matches the
  expected `bfWrites = {16}` / `bfReads = {16}` split.

No C++ test run needed.

## What this enables (and what it doesn't)

After 8.E, a multi-template synth + FX patch is authored as
a single declarative block:

    ensemble $ do
      sendBus <- busNamed "main-send"
      voice "voice" (voiceTemplate sendBus)
      fx    "fx"    (fxTemplate    sendBus)

What 8.E still does **not** give the author:

- Named controls. `freq` / `gate` / `cutoff` still come in
  as bare `Connection` / `Param`. That is 8.F.
- Ensemble-of-ensembles or scoped sub-ensembles. The v1
  builder is a single flat scope. A future slice can add
  sub-scopes if a real patch needs them.
- Cross-template safety beyond what `compileTemplateGraph`
  already checks. The builder does not, for example,
  enforce that every named bus is both written and read.
  That is a diagnostic surface a future slice can add.

## Outcome ladder

  1. Builder, deterministic bus allocation, metadata,
     tests, and demo rewrite all land. **Mark 8.E
     complete.** Point 8.F at named controls.
  2. Builder and bus allocation land but the demo
     rewrite changes compile shape. **Stop the slice.**
     The "lower to existing `compileTemplateGraph` input"
     contract is broken.
  3. Builder lands but bus allocation is not deterministic
     across runs (e.g., depends on hash order). **Mark
     8.E partial.** The point of the layer is exactly the
     determinism.

Case 1 is the target.

## Related artifacts

- [notes/2026-05-12-phase-8d-routing-helpers.md](notes/2026-05-12-phase-8d-routing-helpers.md)
  — 8.D closeout; the `Bus` handle 8.E allocates against.
- [notes/2026-05-11-phase-8-authoring-dsl-design.md](notes/2026-05-11-phase-8-authoring-dsl-design.md)
  — overall Phase 8 design.
- [src/MetaSonic/Bridge/Templates.hs](src/MetaSonic/Bridge/Templates.hs)
  — `compileTemplateGraph` accepts `[(String, SynthGraph)]`
  unchanged.
