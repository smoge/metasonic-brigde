## Core Megafile Split Recap

Date: 2026-05-18

Status: closure note for the thirteen-commit arc that split
`test/MetaSonic/Spec/Core.hs` from a 5181-line parent into twelve
focused `MetaSonic.Spec.Core.*` submodules plus the shared
`MetaSonic.Spec.CoreShared` helper module. The parent module is
retained as a 216-line aggregator owning the residual `unitTests`
testGroup; the structural work is in a rest state. Final commit
`ffb158c`.

## Why

`MetaSonic.Spec.Core` accumulated four roughly-independent surfaces:
the residual `unitTests` parent (demo-graph mini-groups, scattered
testCases, C ABI tag agreement, edge graphs), eleven cohort
test-groups spanning §4.B–§4.E and Phase 4.D rate metadata, the
QuickCheck `properties` tree with ~20 `prop*` predicate functions,
plus a load of shared fixtures, generators, and OSC wire helpers.
None of the cohorts depend on each other; the megafile just predated
the test-hygiene effort that already closed the FFI, Session, and
Feature arcs. Splitting also keeps GHC's module graph honest — each
cohort's imports now reflect what it actually exercises.

## Final structure

`test/MetaSonic/Spec/Core.hs` survives as the residual aggregator.
The extracted `MetaSonic.Spec.Core.*` test surface is:

| Module                                     | Group label                                  | Cases |
|--------------------------------------------|----------------------------------------------|-------|
| `MetaSonic.Spec.Core.NodeIndex`            | `node-index resolution: Connection → NodeID → NodeIndex` | 3 |
| `MetaSonic.Spec.Core.MigrationKeys`        | `migration keys`                             | 5     |
| `MetaSonic.Spec.Core.CCBuilder`            | `cc builder: auto-records CCSpec + auto-inserts Smooth` | 6 |
| `MetaSonic.Spec.Core.Dependencies`         | `dependencies (Source-level UGen → [NodeID])` | 6    |
| `MetaSonic.Spec.Core.BusRouting`           | `Bus routing (BusIn/BusOut and E_r edges)`   | 6     |
| `MetaSonic.Spec.Core.TemplateGraph`        | `TemplateGraph (inter-template ordering)`    | 22    |
| `MetaSonic.Spec.Core.RatePropagation`      | `Rate propagation`                           | 14    |
| `MetaSonic.Spec.Core.FusionAlgebra`        | `Phase 4.C: fusion algebra`                  | 22    |
| `MetaSonic.Spec.Core.SelectRegionKernels`  | `Phase 4.B: selectRegionKernels`             | 36    |
| `MetaSonic.Spec.Core.RegionScheduling`     | `Phase 4.E: region scheduling`               | 30    |
| `MetaSonic.Spec.Core.RateMetadata`         | `Phase 4.D: rate metadata`                   | 14    |
| `MetaSonic.Spec.Core.Properties`           | `Properties`                                 | 24    |

The table totals 188 extracted cases. `unitTests` retains its
residual ~17 cases (4 demo-graph mini-groups, the C-ABI tag
agreement groups for `NodeKind` and `RegionKernel`, the `Edge graphs`
group, 4 scattered structural testCases for ringmod/fm/checkDeps/
cycle, and the `kindTag is injective` pin). The full suite remains
at 1141 tests; no test was deliberately added or removed.

`MetaSonic.Spec.CoreShared` was extracted as the prep slice (commit
`6438062`) ahead of the cohort moves. It owns:

- Graph fixtures: `simpleGraph`, `chainGraph`, `fanOutGraph`, `sawGraph`,
  `noiseLpfGraph`, `ringModGraph`, `fmGraph`, `divergentLayerGraph`,
  the `demoGraphs` table, `emptyGraph_`, `silentOutGraph`,
  `disconnectedGraph`, `missingDepGraph`, `cycleGraph`.
- Generators: `genWellFormedGraph`, `shrinkSynthGraph`, `genFusableRenderableGraph`,
  `Op` data type with `interpret` / `interpretConnections`, the
  `Note [Generator avoids E_r cycles]` comment.
- Helpers: `kindHistogram`, `nodesByKind`, `ugenKind`, `rateOfFirst`,
  `assertDenseIndices`, `assertTopoOrder`,
  `runtimeGraphBuilderCapacity`, `templateGraphBuilderCapacity`,
  the `PtrCFloat` type alias.
- OSC wire fixtures: `oscString`, `be4`, `floatBytes1500`,
  `intBytes42`, the canonical `/fx0/lpf/0`, `/fx0/outgain/0`,
  `/v0/lpf/0`, `/swap/lpf/0` byte fixtures, `sendUdpLoopback`.

## Line-count trajectory

The parent line-count path was:

| Checkpoint                                          | Parent lines |
|-----------------------------------------------------|--------------|
| Before `6438062` (CoreShared prep slice)            | 5181         |
| After `6438062` (CoreShared landed)                 | 4262         |
| After `b333d9c` (CCBuilder + NodeIndex + MigrationKeys, day-1 cohorts) | 4262 |
| After `f424cbe` (TemplateGraph)                     | 3422 (approx)|
| After `a8e1016` (RatePropagation)                   | 3208         |
| After `5bb9e59` (FusionAlgebra)                     | 2643         |
| After `fa78261` (SelectRegionKernels)               | 1822         |
| After `2e47b1d` (RegionScheduling)                  | 982          |
| After `c4824e6` (RateMetadata)                      | 606          |
| After `ffb158c` (Properties; final)                 | 216          |

The drop from 4262 → 216 came over twelve commits today. Each
commit was a single cohort extraction plus the registration tweaks;
`stack test` cleared all 1141 tests after every step.

## Design decisions worth recording

**The parent was kept, not deleted.** Unlike the Session and Feature
closures, `MetaSonic.Spec.Core` retains a meaningful residual:
`unitTests` aggregates the demo-graph fixture invariants, the C ABI
tag agreement groups, the `Edge graphs` group, and a handful of
scattered structural testCases (ringmod / fm / checkDeps /
cycle / kindTag injectivity). These are too small and too
mutually-related to make sensible standalone modules — splitting
each into its own file would create five-line modules. Core.hs
therefore serves as both the entrypoint that owns `unitTests` and
the import surface for the twelve extracted cohorts.

**`MetaSonic.Spec.Core.Properties` exports `properties` under its
original name.** `test/Spec.hs` imports it directly rather than
re-routing through Core.hs. The `testGroup "Properties"` shell is
preserved at the same depth under the `MetaSonic` root, so Tasty
selector paths (`-p "/Properties/"` and friends) are unchanged.
Property predicates (`propDenseIndices`, `propTopoOrder`,
`propBijection`, etc.) and the region-rate refinement helpers
(`checkRuntimeRegionRefinement`, `takeRuntimeChunk`) live in the
new module; nothing was promoted to `CoreShared` because the
predicates are property-tree-private.

**`CoreShared` holds shared fixtures and helpers for cohorts that
need them.** Three of the twelve cohort modules currently import it
(`RatePropagation`, `RegionScheduling`, `Properties`); the rest are
self-contained because their fixtures are either kind-table walks
(`Capability`-style enumeration over `[minBound .. maxBound]`) or
small inline graphs that don't reach for the shared
`demoGraphs` / generator surface. Promoting helpers here (rather than
keeping them in Core.hs alongside `unitTests`) means a cohort that
needs the generator or a demo fixture can pull just the shared
surface without dragging the residual `unitTests` tree into its
dependency graph.

**Two oversized testGroups were split mid-extraction.** The
"Rate propagation" testGroup in the parent secretly contained the
§4.C fusion-algebra tests; the §4.B `selectRegionKernels` group
similarly trailed into mixed §4.B/§4.C content. The rate-propagation
extraction carved off the actual rate tests into
`MetaSonic.Spec.Core.RatePropagation` (14 cases) and left the
fusion-algebra material under a transitional "Phase 4.C: fusion
algebra" header in the parent, which was lifted out one commit
later into `MetaSonic.Spec.Core.FusionAlgebra` (22 cases). Same
shape for the region-scheduling and selectRegionKernels split.

**Test-tree paths were preserved.** Each submodule keeps the same
top-level `testGroup` label, and `unitTests` is the parent that
aggregates them. Selector paths that previously hit
`MetaSonic.Unit tests.Rate propagation.<case>` still work
unchanged, both because the submodule re-aggregates under the same
label and because the parent `unitTests` testGroup wraps everything
the same way.

**One `TestTree` per submodule.** Each extracted module exports only
its cohort `TestTree`. The `RegionScheduling` cohort is the
exception: it owns four sibling testGroups (§4.E.1 footprints /
§4.E.2a planner / §4.E.2b loaders / §4.E.2c stats) under a single
parent `"Phase 4.E: region scheduling"` testGroup, since they all
consume the same `regionBusPrecedence` / `regionStructuralPrecedence`
/ `regionDependencies` surface and decomposing further would mean
four tiny modules.

**LambdaCase pragmas were dropped where they became unused.** Each
extracted module is checked for actual `\case` use; the pragma was
left in `RegionScheduling.hs` (one consumer in the loader-preservation
test) and removed everywhere else. The parent `Core.hs` no longer
needs it either.

## Hygiene tail (P1 / P2 / P3)

Three small fixes landed alongside the cohort work:

- `53fe9dc`: register `MetaSonic.Spec.AppManifestLiveReloadDemoRender`
  in `package.yaml`. The module was imported by `test/Spec.hs` and
  the file existed, but it was missing from `other-modules`; GHC
  fired `-Wmissing-home-modules` twice per clean build. Cabal
  regenerated by hpack on next build.
- `68a8c49`: trim trailing blank line from
  `test/MetaSonic/Spec/Feature/Planner.hs:172`. The Feature split
  landed it with `\n\n`; `git diff --check HEAD~20..HEAD` had been
  carrying the flag across the recent history.
- `b1d4f50`: tighten the Session recap table (parent column was
  three characters wider than the longest module name) and restore
  the space after "Prep O:" that the alignment pass dropped on the
  `LiveHotSwap` row.

## Verification

Final `stack test` after `ffb158c`: 1141 tests pass. Each cohort
was also verified through `stack test` immediately before its
commit; no commit landed with a failing or unbuilt step.

## Open follow-up

The four demo-graph mini-groups inside `unitTests` all index over
`demoGraphs` with the same `case lowerGraph g >>= ...` boilerplate
shape. They could collapse into a single helper if the pattern
grows to a fifth row. Until then, the split is closed and Core.hs
is small enough to keep as the entrypoint.
