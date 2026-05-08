# Project State Snapshot — Phase 4.D Infra Complete

Date: 2026-05-08
Snapshot commit: `be1dede`
Snapshot tag: `phase-4d--infra-complete` (annotated, local only)

This note is intentionally pinned to the Phase 4.D boundary. Later commits may
advance `HEAD`; in this checkout, §4.E layered schedule work landed after this
snapshot. Use `CHANGELOG.md` and `draft/ROADMAP.md` for current-head status.

This note captures the state of `metasonic-bridge` at the boundary between
the §4.B kernel-add loop / §4.D descriptive surveys and the upcoming §4.E
layered-schedule work. It is meant as a one-stop "where are we" reference,
not a session recap.

## What This Crate Is

One layer of the larger MetaSonic pipeline. Job: compile a Haskell-built
signal graph into a dense runtime form and ship it across an FFI boundary
into a C++ DSP engine.

```
Haskell DSL → SynthGraph → GraphIR → RuntimeGraph → DSP Engine
   Source     Validate     IR        Compile        FFI → C++
```

The repo split (`metasonic-core`, `metasonic-bridge`, `tinysynth`) is
explicitly temporary. Don't design against it.

## Pipeline Status

All seven pipeline stages are wired and exercised by tests:

1. `Types.hs` — shared vocabulary; `NodeID` (symbolic) vs `NodeIndex` (dense).
   Now also carries `PortInfo` / `PortConsumptionRate` for §4.D.2.
2. `Bridge/Source.hs` — user-facing DSL.
3. `Bridge/Validate.hs` — pre-compile gate.
4. `Bridge/IR.hs` — `lowerGraph`; rate + effect annotation.
5. `Bridge/Compile.hs` — `formRegions` + `compileRuntimeGraph` (the
   `NodeID → NodeIndex` step). Now re-exports `Compile/EdgeRates.hs`.
6. `Bridge/Templates.hs` — `compileTemplateGraph`; per-template
   `BusFootprint`, precedence DAG.
7. `Bridge/FFI.hs` — the only Haskell module that crosses the C ABI.

Visualization (`Visualize/TUI.hs`, `Visualize/Trace.hs`) is observability,
not part of compilation.

## Tests

- Haskell: 288 tests pass (`stack test`) at the snapshot boundary.
- C++: 223 tests pass (`ctest` in `build-cpp/`).

Properties of note that catch drift:
- `ugenView` arities cross-checked against `kindSpec` for every UGen.
- `kindTag` agreement with the C++ side via `c_rt_graph_kind_supported`.
- §4.D.2: `portInfo` totality across every `(NodeKind, port)` pair.

## Region Kernels (sink-terminal)

Landed kernels, all under the kernel-add gate
(missed ≥ 3 ∧ sources ≥ 3 in survey, sink-terminal range, bit-equivalent
under the C++ scalar reference, edge-case parity):

- `RSinGainOut`
- `RSawGainOut`
- `RNoiseGainOut`
- `RSawLpfGainOut`
- `RBusInLpfGainOut`
- `RNoiseLpfGainOut` (last to land; ~1.25× median, PRNG-cadence pinned)

Parked under the same gate, deliberately:

- `RTriGainOut`, `RPulseGainOut` — single-source corpus signal.
- `Add`-rooted variants — visible to `SinkAddLpfGain` classifier but no
  benchmark gate yet.

The kernel-add loop is closed. No more kernels without fresh evidence
from the survey.

## Survey Infrastructure

`--fusion-survey` now reports:

- **Ranked missed-shape table** — covered / candidate / no-signal status,
  next-action column. Uses `scanSinkShapes` and `SinkAddLpfGain`.
- **Rate distribution** (§4.D.1) — per-node output rate counts. Result:
  100% `SampleRate` on the current corpus, which is why §4.D.1 was a
  *negative* result and runtime block-rate work is parked.
- **Edge-rate distribution** (§4.D.2) — per-port consumption metadata via
  `PortInfo` / `PortConsumptionRate`
  (`PortSampleAccurate` / `PortBlockLatched` / `PortInitOnly` /
  `PortIgnored`). Producer-grouped headline avoids over-counting when one
  producer feeds both block-latched and sample-accurate ports.
- **Schedule width** and **cross-template (precedence-DAG) width**
  (`tplLayerW`). Note: layer width is *not* directly schedulable
  parallelism — same-layer templates writing the same bus still need
  serialization.
- **Sink-terminal opportunity scan** (the original §4.B feed).

The survey corpus is split into shape / mod / neg / ens families
(`surveyShapeProbes`, `surveyEnsembleCorpus`). Add probes there, not to
demo `SynthGraph`s.

## Methodology, Validated

The descriptive-first → decide-later pattern has now been used three times
(§4.B kernel gate, §4.D.1 rate carry, §4.D.2 edge-rate survey) and each
time produced an evidence-driven decision rather than a guessed one. §4.E
should follow the same shape.

## Known Limitations / Parked Work

- Per-node output rate is too coarse for block-latch optimization
  (§4.D.1 result). Runtime block-rate execution is parked.
- Deterministic bus reduction is not designed yet; same-layer writers to a
  shared bus must still serialize at runtime.
- Tri / Pulse / Add singleton kernel candidates remain parked; revisit
  only if corpus signal grows.
- Repo split is temporary; abstractions should not assume it persists.

## Next Slice — §4.E Layered Schedule

Snapshot-time next slice:

No runtime parallelism yet. Plan:

1. Keep `regionSchedule` as the deterministic linear fallback.
2. Add a layer/step representation (barriers + free layers).
3. Surface shared-write hazards explicitly.
4. Extend `--fusion-survey` to distinguish "parallel width runnable
   without reduction" from "width that needs deterministic reduction."

Deterministic bus reduction is a separate later slice. Runtime parallelism
comes only after both of the above.

Post-snapshot status: this §4.E layered-schedule slice later landed; the next
§4.E decision is deterministic bus reduction design, still before runtime
parallelism.

Explicitly not next: more kernels, kernel codegen, runtime block-rate work.

## Pointers

- `notes/2026-05-08-project-path.md` — 9-stage history of MetaSonic.
- `notes/blog-post-metasonic-path.md` — architectural thesis essay.
- `notes/fusion-strategy.md` — sink-terminal fusion notes.
- `notes/2026-05-08-fusion-kernel-lessons.md` — what the kernel-add loop
  taught us.
- `notes/2026-05-08-phase-4d2-handoff.md` — §4.D.2 entry point used to
  open this slice.
- `CHANGELOG.md`, `draft/ROADMAP.md` — canonical project-side docs.
