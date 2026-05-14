# Phase 7.D Runtime Program ABI and Tiny Executor Decision

Date: 2026-05-12

Status: decision artifact for the first 7.D slice. This slice is
strictly ABI plus executor equivalence. No planner integration, no
profitability gate, no automatic selection. The end of this slice
is "one hand-authored generated program can be loaded, dispatched,
and proven equivalent to `RNodeLoop`."

## Decision

Generated execution is a **fourth runtime path**, distinct from
node-loop, hand-written region kernels, and `RFused`. The C++
runtime gains a generated-program table and a small interpreter
that walks per-sample ops; the Haskell loader hands C++ a program
id per region that wants the generated path.

Hand-written `RegionKernel` values stay exactly as they are. They
are an enumeration with mirrored C++ tags, no payload. Squeezing a
`FusionProgramId` into a new `RegionKernel` constructor would
either smuggle a payload through `kernelTag` or hide a new
dispatch mode behind an enum that the C++ side reads as "another
hand-written kernel." Both are sharp-edged. Instead, region
dispatch widens explicitly to three cases.

## Why 7.D Now

Phase 7.C delivered:

- a survey-only planner (`MetaSonic.Bridge.Planner`) that selects
  legal sink-terminal fusion candidates;
- a cost-model join that classifies each candidate as `covered` /
  `measured-win` / `measured-loss` / `needs-benchmark`;
- cost-lab coverage for `add-chain` and `dynamic-gain` families,
  with the first cleanly-measured-profitable generated-eligible
  shape (`KSawOsc → KGain → KOut gain=dynamic`, ~1.14× over
  node-loop on the existing region-kernel/RFused path).

What the project does **not** have:

- a way to execute a planner-selected candidate. Today the planner
  produces verdicts that nothing consumes.
- a fourth cost-lab variant for measuring generated programs
  against the existing three.

7.D builds the executor surface so the second gap can close. The
first gap stays open through this slice: the planner remains
diagnostic-only and no production graph picks generated execution.

## Three-Way Region Dispatch

A `RuntimeRegion` currently carries `rrKernel :: RegionKernel`,
which the C++ side reads to pick between `RNodeLoop` and a
hand-written kernel. 7.D widens region dispatch to:

```text
RegionExec
  = ExecNodeLoop
  | ExecKernel    RegionKernel    -- existing hand-written path
  | ExecGenerated FusionProgramId -- new generated-program path
```

Implementation note: a small `RegionExec` selector is cleaner than
adding a `Maybe FusionProgramId` alongside the existing
`rrKernel`. The selector encodes "exactly one path is chosen per
region" structurally; a parallel `Maybe` would invite a hidden
invariant ("when generated id is `Just`, kernel must be
`RNodeLoop`") that future code could easily violate.

The C++ side dispatches in the same shape: existing
`kernelTag` continues to identify hand-written kernels; the
generated path uses a separate program-id lookup. The two never
mix.

## v1 Op Set

The interpreter handles five primitive operations:

| Op             | Purpose                                                  |
| -------------- | -------------------------------------------------------- |
| Scalar / const | Emit a literal `Double` into a scratch slot.             |
| Input read     | Read a sample from another node's output buffer.         |
| Add            | Sum two operand sources into a scratch slot.             |
| Multiply       | Multiply two operand sources into a scratch slot.        |
| Sink write     | Write or accumulate a sample to an output bus.           |

Sources for any reading op are one of:

- a literal constant;
- a previous node's output port (the same edge an `RFrom`
  represents in the runtime graph today);
- a control read (constant per render block);
- a scratch slot written by an earlier op in the same program.

This subset is intentionally narrow. It is what a generated
`KSawOsc → KGain → KOut gain=dynamic` chain compiled out would
need: read the saw output, read the modulator output, multiply,
write to the sink. No stateful sources, no filters, no
multi-stage feedback, no buffer or plugin paths.

## Out of Scope For This Slice

Hard exclusions:

- **No stateful source nodes.** Oscillators with phase
  accumulators, noise generators with PRNG state, and any kind
  with `CapStatefulOp` lower to per-kind dispatch outside the
  generated program. The generated program reads their **outputs**
  via input-read ops; it never reproduces the state machine.
- **No filters.** Biquads stay hand-written. They are stateful and
  their fused form needs more than scalar arithmetic in v1.
- **No declared latency.** A kind with `CapLatencyBearing`
  (`KSpectralFreeze` today) cannot appear in a generated program.
  Latency reconciliation is a downstream slice.
- **No bus reads beyond the sink write.** `KBusIn` /
  `KBusInDelayed` are out; the generated path reads only outputs
  of nodes in its own region.
- **No buffer or plugin paths.** `KPlayBufMono`,
  `KRecordBufMono`, `KSpectralFreeze`, `KStaticPlugin` cannot
  appear in a generated program.
- **No feedback.** All input-read ops reference nodes that
  produced their output earlier in the same render block (no
  same-block self-reference).
- **No planner integration.** Selecting which regions use
  generated execution is not part of 7.D. The first slice loads a
  hand-authored program for a hand-crafted region; the planner
  stays diagnostic.
- **No profitability gate, no automatic generated-eligible
  emission, no turn-on.** The `--fusion-cost-lab` cost-model join
  classifies the new path's measurements as one variant among
  many; no policy uses those measurements yet.
- **No `KSawOsc → KGain → KOut gain=dynamic` as a production
  target.** It is the obvious shape to measure once the executor
  exists, but landing it in 7.D would mix architecture
  verification with shape-specific kernel work.

## Verification Target

The slice is done when a single hand-authored generated program
renders the same buffer as `RNodeLoop` on a chosen graph. The
chosen graph should be small enough that the program is also
hand-authored — likely a multiply-to-out or scalar-gain-to-out
shape.

Equivalence is bit-exact under the same float arithmetic
discipline `--fusion-cost-lab` already uses for its variant
comparisons. If a divergence appears, the executor is wrong, not
the test target.

This verification lives in `test/Spec.hs` as one new test, not in
the cost lab. The cost lab gains a fourth variant in a later
slice once the executor is known correct.

## Implementation Plan

In order, smallest commits first:

1. **Decision note** (this artifact).
2. **Haskell data model scaffold.** Pure types in
   `MetaSonic.Bridge.Compile.Types` (or a new
   `MetaSonic.Bridge.Compile.FusionProgram`) for
   `FusionProgramId`, `FusionProgram`, `FusionOp`, source operands,
   sink output policy. Small structural unit tests only. No
   planner change, no runtime change, no FFI change.
3. **`RuntimeGraph` / `RuntimeRegion` carrying.** Widen region
   dispatch via a `RegionExec` selector (or equivalent). Extend
   `RuntimeGraph` with a program table.
   `compileRuntimeGraph` continues to emit `ExecNodeLoop` /
   `ExecKernel`; no graph emits `ExecGenerated` yet.
4. **C ABI shape.** Construction-only entry points in
   `tinysynth/rt_graph.h` / `.cpp`. Adds a program to a template,
   appends ops to that program, registers a region that uses a
   program id. Load-time allocation only; no audio-thread alloc.
5. **Tiny C++ interpreter.** Per-sample op loop in
   `rt_graph.cpp`. Handles the v1 op set against the same
   per-region buffers the hand-written kernels use. Sink-peak
   update logic mirrors the existing kernels'.
6. **Haskell loader wiring.** Teach `loadRuntimeGraph` /
   `loadRuntimeGraphFused` to push the program table before
   registering generated regions. Unchanged behavior for graphs
   with no generated programs.
7. **Hand-authored equivalence test.** One test graph plus one
   hand-authored generated program covering the same region.
   Assert bit-exact equivalence with the `RNodeLoop` path under
   the existing test infrastructure.
8. **Cost-lab fourth variant.** `VarGenerated` in
   `--fusion-cost-lab`. Requires a small planner-or-hand-authored
   path that produces a generated program for measurable rows.
   This slice ships only after the executor is verified; the
   first measurement target is `KSawOsc → KGain → KOut
   gain=dynamic` because it is the cleanest measured-profitable
   shape outside §4.B today.

## Open Questions Deferred

- **Op encoding density.** A `data FusionOp = OpAdd … |
  OpMul … | …` ADT compiles to a per-op tag plus payload. For v1
  this is fine. A future high-throughput interpreter may want a
  packed instruction stream; the encoding choice does not affect
  the ABI today because the C ABI takes "append this op" calls,
  not a serialized byte buffer.
- **Multi-region programs.** The program currently lives per
  region. A program that spans two adjacent regions (the natural
  next step after a single sink-terminal chain) needs a separate
  decision about how cross-region inputs are read; deferred.
- **Float arithmetic discipline.** Bit-exact equivalence with
  `RNodeLoop` requires the interpreter to do its multiplies and
  adds in the same order the node-loop path does. The first
  hand-authored program will keep that order trivially; if a
  future generated program needs to reorder for performance, the
  equivalence test relaxes to "within tolerance" and the
  reordering is documented.
- **Scratch slot indexing.** A 2-op program can use one scratch
  slot; longer programs need more. The first slice can fix the
  scratch-slot count per program at load time; a future slice may
  want per-block reuse analysis.
- **Sink-peak accumulation across writers.** When two writers
  contribute to the same bus (one hand-kernel, one generated),
  the writer-slot-keyed contribution machinery from §4.E.2
  applies. v1 picks regions where a single writer (generated)
  owns the bus end to end; the cross-writer case stays parked
  until it appears in a real graph.
