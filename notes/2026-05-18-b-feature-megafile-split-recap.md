# Feature Megafile Split Recap

Date: 2026-05-18

Status: closure note for the ten-commit arc that split
`test/MetaSonic/Spec/Feature.hs` from a 2836-line parent into ten
focused `MetaSonic.Spec.Feature.*` submodules. The parent module is
deleted; the structural work is in a rest state. Final commit
`4bafb55`.

## Why

`MetaSonic.Spec.Feature` aggregated four roughly-independent surfaces:
static-plugin dispatch, authoring DSL / report / manifest export,
the per-kind capability table and survey-only fusion planner, and
the FusionProgram scaffold plus three generated-executor cohorts.
None of these depend on each other; the megafile just predated the
test-hygiene effort that already closed the FFI and Session arcs.

## Final structure

`test/MetaSonic/Spec/Feature.hs` has been deleted. The registered
`MetaSonic.Spec.Feature.*` test surface is:

| Module                                                | Group label                                            | Cases |
|-------------------------------------------------------|--------------------------------------------------------|-------|
| `MetaSonic.Spec.Feature.StaticPlugin`                 | `Phase 6.E slice 2: Identity dispatch`                 | 9     |
| `MetaSonic.Spec.Feature.AuthoringDSL`                 | `Phase 8.A: authoring DSL lowering`                    | 61    |
| `MetaSonic.Spec.Feature.AuthoringReport`              | `Phase 8.G: authoring metadata reporting`              | 10    |
| `MetaSonic.Spec.Feature.AuthoringManifest`            | `Phase 8.H: authoring manifest export`                 | 14    |
| `MetaSonic.Spec.Feature.Capability`                   | `Phase 7.B: kind capability table`                     | 5     |
| `MetaSonic.Spec.Feature.Planner`                      | `Phase 7.C: survey-only fusion planner`                | 8     |
| `MetaSonic.Spec.Feature.FusionProgramScaffold`        | `Phase 7.D: FusionProgram data-model scaffold`         | 7     |
| `MetaSonic.Spec.Feature.FusionProgramExecutor`        | `Phase 7.D: tiny executor bit-exact equivalence`       | 5     |
| `MetaSonic.Spec.Feature.FusionProgramBlockExecutor`   | `Phase 7.H: block-major executor bit-exact equivalence` | 3    |
| `MetaSonic.Spec.Feature.FusionProgramSuperExecutor`   | `Phase 7.I: super-mode executor bit-exact equivalence` | 4     |

Table totals 126 Feature cases. The full suite remains at 1141
tests; no test was deliberately added or removed.

## Design decisions worth recording

**No `FeatureShared` was introduced.** The three executor cohorts
all use the same render-and-peek scaffolding, but each landed
self-contained. The three modules are easier to read with their
fixtures inline than they would be with shared indirection, and
the promotion threshold (≥2 active consumers in a module that
couldn't keep the helper local) was never crossed without the test
also being a perfectly fine size for one file. Two cohort-private
helpers stayed local: `representativeUGen` in `Capability`, and the
`namedControlReport` / `sendReturnReport` fixtures in
`AuthoringManifest`.

**`PtrCFloat` was inlined to `Ptr CFloat`.** `MetaSonic.Spec.Core`
exports a `type PtrCFloat = Ptr CFloat` alias for the render
buffers in the parent. Each executor slice substituted the alias
inline instead of importing `Spec.Core` for one type synonym,
keeping the new modules free of `Spec.Core` dependency.

**Test-tree paths were preserved.** Each submodule keeps the same
top-level `testGroup` label, and the parent was not itself a Tasty
group. Selector paths that use labels like `Phase 7.B: kind
capability table`, `Phase 8.A: authoring DSL lowering`, or `Phase
7.H: block-major executor bit-exact equivalence` continue to work.
One label-substring caveat: `-p "block-major"` also matches the
super-mode `falls back to block-major` testCase, so the focused
selector for the block-major cohort uses `-p "block-major executor
bit-exact"`.

**One `TestTree` per submodule.** Each extracted module exports only
its cohort `TestTree`. The `Planner` cohort's six rejection-reason
predicates plus `runPlanner` stay inside the testGroup's
`where`-clause as in the parent.

**The parent was deleted, not retained as an aggregator.** Same
shape as the Session closure: `test/Spec.hs` already registers each
`TestTree` directly, the bare `MetaSonic.Spec.Feature` reference is
removed from `package.yaml`, `metasonic-bridge.cabal`, and
`test/Spec.hs`. The `rg` recheck confirmed only submodule
references remain after the final slice.

## Verification

Final `stack test` run after `4bafb55`: 1141 tests pass. Each
cohort was also verified through its focused selector immediately
before commit.

## Open follow-up

The three executor cohorts duplicate render boilerplate. Revisit a
narrow `Feature.FusionProgramShared` only if a fourth
executor-style cohort appears. Until then, the split is closed.
