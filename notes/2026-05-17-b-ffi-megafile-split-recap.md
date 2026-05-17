# FFI Megafile Split Recap

Date: 2026-05-17

Status: closure note for the ten-commit arc that split
`test/MetaSonic/Spec/FFI.hs` from a 3914-line megafile into ten
focused submodules plus a small parent. The structural work is in
a rest state; this note records the final shape, the design
decisions worth preserving, and one open follow-up.

## Why

The parent file had grown to 3914 lines with ten conceptually
distinct test cohorts living inside one `crossCuttingTests`
testGroup plus a long tail of free-standing phase test trees. The
practical pain was diagnostic: a single bus-routing or fused-render
regression scrolled the same monolithic file regardless of which
cohort failed, and reviewers landing on any one section had to page
past the others. The arc was a mechanical split, not a redesign.

## Final structure

`test/MetaSonic/Spec/FFI.hs` is now 788 lines and contains:

- The four cross-cutting opener tests: `SinOsc(440)` round-trip,
  `Gain(SinOsc, 0.5)`, `Env(gate=1)`, and the `2×N frames matches
  one 2N block` state-continuity check. These stay together because
  they form the floor that every other FFI test implicitly assumes.
- The shared helpers used by the extracted submodules — `compileBoth`,
  `t9CorpusGraphs`, `t9CorpusTemplates`, `readGlobalSchedule`,
  `expectedGlobalRG`, `expectedGlobalTG`, `processAndReadBuses`,
  `readBus`, the corpus `SynthGraph`s (`filteredSawGraph`,
  `envPluckGraph`, …) and `TemplateGraph`s (`sendReturnLiveTG`,
  `sendReturnDelayedTG`, `threeTemplateChainTG`).
- `stripRegionKernels` — see "Design decisions" below.

Each submodule exports exactly one `TestTree`:

| Module                                  | Group label                                          | Cases                       |
|-----------------------------------------|------------------------------------------------------|-----------------------------|
| `MetaSonic.Spec.FFI.C0a`                | `Phase 4.E.2.C0a: layer-aware loader metadata`       | 44 (with C0a-local helpers) |
| `MetaSonic.Spec.FFI.C0b`                | `Phase 4.E.2.C0b: per-block global schedule`         | 9                           |
| `MetaSonic.Spec.FFI.C0c`                | `Phase 4.E.2.C0c/C1a: global-schedule banded serial executor` | 35                |
| `MetaSonic.Spec.FFI.C0d`                | `Phase 4.E.2.C0d: global-schedule runnable bands`    | 5                           |
| `MetaSonic.Spec.FFI.C1c`                | `Phase 4.E.2.C1c-c: worker-schedule equivalence`     | 32                          |
| `MetaSonic.Spec.FFI.T9`                 | `T-9: direct ≡ reduction`                            | 90                          |
| `MetaSonic.Spec.FFI.HotSwap`            | `End-to-end FFI: hot-swap`                           | 11                          |
| `MetaSonic.Spec.FFI.BusRouting`         | `End-to-end FFI: bus routing primitives`             | 7                           |
| `MetaSonic.Spec.FFI.TemplateLifecycle`  | `End-to-end FFI: template ensemble and lifecycle`    | 8                           |
| `MetaSonic.Spec.FFI.FusedRender`        | `End-to-end FFI: fused render parity`                | 33 (with 4 private helpers) |

Full suite remains at 1141 tests; no test was lost or added during
the arc.

## Design decisions worth recording

**`stripRegionKernels` stays in the parent.** Both
`TemplateLifecycle` and `FusedRender` import it. Promoting it to
`MetaSonic.Spec.Core` (where the QC generators `genFusableRenderableGraph`
and `shrinkSynthGraph` already live) or to a small `FFI.Helpers`
module is plausible, but I chose to defer that until a third
consumer appears. Bundling the helper-placement question into a
mechanical extraction commit would have made the arc less
bisectable.

**Test-tree path drift accepted at extraction time.** The hot-swap,
bus-routing, template-lifecycle, and fused-render cases used to
print under `MetaSonic.End-to-end FFI.<case>`; they now print under
`MetaSonic.End-to-end FFI: <slice>.<case>`. The group labels were
deliberately prefixed with the original `End-to-end FFI:` so the
relationship to the parent group stays discoverable, but Tasty
selector patterns referring to the old nested path will need
updating. CI greps for "End-to-end FFI" are unaffected.

**One `TestTree` per submodule, where-clause-local helpers.**
Each submodule exports only its top-level `TestTree` (C0a was
trimmed to match this convention in the same commit it landed —
its four helpers were submodule-local and stayed unexported). The
`sizeOfFloat = 4 :: Int` binding lives in the submodule's
where-clause, mirroring the parent's pattern. Private helper
functions used only by one cohort migrated with the cohort; helpers
used by two or more cohorts stayed in the parent.

**No section-comment dead anchors in the parent.** When a cohort
left, its leading section comment left with it. The parent does not
carry breadcrumb comments pointing at the extracted submodules;
`git log -- test/MetaSonic/Spec/FFI.hs` is the authoritative history.

## Open follow-up

The `stripRegionKernels` placement is the one outstanding decision.
Two cases to revisit it:

- A third consumer needs it. Then promoting to a shared module is
  forced, not optional.
- A future slice that touches both `TemplateLifecycle` and
  `FusedRender` lands a related change. At that point moving
  `stripRegionKernels` to `MetaSonic.Spec.Core` alongside
  `genFusableRenderableGraph` becomes a one-line follow-up commit
  rather than a cross-cutting refactor.

Until one of those triggers, the helper stays where two submodules
already know to find it.
