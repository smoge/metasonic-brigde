# Phase 7.E Generated Suffix Targets Decision

Date: 2026-05-12

Status: decision artifact for the next 7.E slice. This slice keeps
the 7.D restrictions on the interpreter (v1 op set only — scalar
const, input read, add, multiply, sink write) and widens **what
the generator can target** by letting a generated program own a
contiguous *suffix* of a planner-selected candidate while the
remaining prefix nodes still run as node-loop. There is still no
profitability gate, no auto-selection, and no planner turn-on.

## Decision

A generated `FusionProgram` may claim a **contiguous suffix** of a
selected candidate. All nodes earlier than the suffix continue to
execute via the existing node-loop path; the generated program
reads their already-produced outputs through `SrcInput` ops.

This unlocks measuring shapes whose candidate body contains kinds
the interpreter cannot execute (stateful sources, filters,
buffer/plugin paths) without expanding the v1 op set. Concretely:
a candidate of `KPulseOsc → KGain → KOut` can have its
`[KGain, KOut]` tail compiled out while `KPulseOsc` keeps running
as node-loop. Same for `KTriOsc → KLPF → KGain → KOut`, where
both `KTriOsc` and `KLPF` stay node-loop and only `[KGain, KOut]`
is generated.

The suffix discipline is the smallest extension that exercises the
real generated-vs-node-loop boundary: the interpreter has to read
*another region member's* output, not just chain through its own
scratch slots.

## Why 7.E Suffix Now

Phase 7.D delivered:

- a runtime program ABI, `ExecGenerated FusionProgramId`, and a
  per-template `FusionProgram` table;
- a Haskell-side validator (scratch bounds, scratch
  read-before-write, node/control references, region program-id);
- a tiny C++ per-sample interpreter for the v1 op set;
- `VarGenerated` in `--fusion-cost-lab` with a narrow generator
  that handles `[KGain, KOut]` / `[KGain, KBusOut]` candidates
  exactly.

What that gave us is a verified executor surface plus two measured
generated rows (`dynamic-gain/gain-dyn-out` at ~0.66×,
`corpus/pattern/spectral-freeze/texture` at ~0.87×). Both are
bit-exact against node-loop but slower. We cannot tell from two
shapes whether the interpreter overhead dominates universally or
only on these particular cases, and we cannot widen further
without one of:

- adding stateful-source/filter ops to the interpreter (blocked by
  the 7.D hard exclusion list), or
- letting generated execution own only the *safe tail* of a longer
  candidate while the unsafe prefix stays node-loop.

7.E picks the second path. It stays inside the v1 op set, gives
the cost lab three to five more measurable generated rows, and
keeps `KSawOsc → KGain → KOut gain=dynamic` (the measured-profitable
shape from 7.C) available as a future planner-turn-on target
without that target being part of this slice.

## Generator Plan Change

Today `generateProgram :: RuntimeGraph -> FusionCandidate ->
Either String FusionProgram` returns only the program and bakes
in the assumption that `fcMembers` equals the slice the generator
owns. `patchForGenerated` then splits the host region using
`fcMembers` directly.

7.E changes the generator signature to return both the program
and the owned member slice:

```text
generateProgram
  :: RuntimeGraph
  -> FusionCandidate
  -> Either String (FusionProgram, [NodeIndex])
```

The returned `[NodeIndex]` is a contiguous suffix of `fcMembers`.
`patchForGenerated` uses *that* slice for region splitting, not
the full candidate. The prefix members (`fcMembers` minus the
owned suffix) stay in the pre-split region and continue to render
as node-loop. The owned suffix becomes its own one-region slice
with `ExecGenerated`.

A returned suffix equal to `fcMembers` reproduces today's behavior
exactly, so the existing `[KGain, KOut]` / `[KGain, KBusOut]`
rows do not change.

## v1 Op Set Stays Fixed

The interpreter does not gain ops in this slice. Specifically:

- No oscillator ops. `KPulseOsc`, `KTriOsc`, `KSawOsc`,
  `KSinOsc` stay in the node-loop prefix.
- No filter ops. `KLPF` stays in the node-loop prefix.
- No latency-bearing kinds in the generated tail.
- No bus-read ops beyond the sink write. The suffix can read its
  prefix's outputs (those are node outputs in the same region,
  exactly what `SrcInput` already encodes), but it cannot read a
  bus written by another region.
- No feedback or same-block self-reference.

This matches the 7.D exclusion list verbatim; the suffix rule only
changes where the boundary between generated and node-loop work
runs, not what the interpreter can do once it is inside the
generated half.

## First Measurement Targets

In order of how clean they are as test cases:

1. **`KPulseOsc → KGain → KOut`.** Prefix is one stateful source
   (`KPulseOsc`), suffix is `[KGain, KOut]`. Demonstrates the
   suffix discipline with a non-trivial prefix and a generated
   tail identical in shape to the 7.D rows. The point of measuring
   this is the suffix mechanism, not a new generated shape.
2. **`KTriOsc → KLPF → KGain → KOut`** (optional in this slice).
   Prefix is `[KTriOsc, KLPF]`, suffix is `[KGain, KOut]`. First
   shape with a filter in the prefix; tests that "prefix node-loop
   work" generalizes past sources. Skippable if the corpus does
   not contain this shape already.

`KSawOsc → KGain → KOut gain=dynamic` is the measured-profitable
shape from 7.C and is the natural turn-on target later, but it is
**not** what 7.E is for. It will fall out of the same suffix
mechanism once we want to compare it against the existing
hand-written kernel for that family.

## Diagnostics, Not Decisions

7.E adds a compact generated-specific summary to the cost lab
output:

- **unsupported / emitted** — how many planner-selected
  candidates the generator declined vs accepted, with a one-line
  reason bucket for declines.
- **exact / non-exact** — how many emitted programs matched
  node-loop bit-for-bit vs failed equivalence (the latter should
  always be zero outside of bugs).
- **generated speedup vs node-loop** — already measured today;
  keep it.
- **delta vs best non-generated path** — generated speedup minus
  `max(region-kernel, RFused)` speedup, per row. Negative is the
  expected sign today.

This summary is diagnostic-only. No planner decision, no auto
turn-on, no profitability gate. It exists so the next slice can
look at three to five generated rows and decide whether the
interpreter is the bottleneck, or specific kernels are.

## Out of Scope For This Slice

Hard exclusions (delta against 7.D):

- **No new ops.** v1 op set is frozen for 7.E.
- **No profitability gate.** Generated execution stays opt-in;
  `--fusion-cost-lab` measures it but no production graph picks
  it.
- **No planner integration past candidate selection.** The planner
  still emits candidates; the cost lab still calls
  `generateProgram` on them and discards the rest.
- **No multi-region programs.** The suffix lives inside one host
  region.
- **No KSawOsc-specific shapes as the goal.** They may fall out,
  but they are not the verification target.
- **No relaxation of the equivalence test.** Generated suffix rows
  still have to match node-loop bit-for-bit.

## Verification Target

The slice is done when:

- The cost lab has at least one measured generated row that owns
  a suffix shorter than its host candidate (i.e., the
  `KPulseOsc → KGain → KOut` row exists with prefix node-loop
  work and suffix generated work, and the row is bit-exact
  against node-loop).
- The generator returns the owned suffix explicitly and
  `patchForGenerated` uses that slice rather than `fcMembers`.
- Snapshot pins reflect the new emitted-row count and class
  movement; the existing two generated rows remain bit-exact.
- A diagnostic generated-summary block appears in the cost-lab
  output.

No new C++ work. No FFI change. No planner change beyond consuming
the new generator signature.

## Implementation Plan

In order, smallest commits first:

1. **Decision note** (this artifact).
2. **Generator plan refactor.** Change `generateProgram` to
   return `(FusionProgram, [NodeIndex])`. Update
   `patchForGenerated` to use the returned slice. Existing
   `[KGain, KOut]` / `[KGain, KBusOut]` rows return the full
   `fcMembers` and stay byte-identical.
3. **Add source-prefix generated measurements.** Extend the
   generator to recognize `KPulseOsc → KGain → KOut` as a
   candidate that yields the `[KGain, KOut]` suffix with the
   `KPulseOsc` prefix kept as node-loop. Optionally add
   `KTriOsc → KLPF → KGain → KOut` if the corpus already has it.
4. **Generated-variant diagnostics.** Add the compact summary
   described above to the cost lab output. Diagnostic-only.
5. **Snapshot pins + ROADMAP.** Pin generated emitted-row count,
   exactness, and class-count movement. Update `ROADMAP.md` 7.E
   entry to "measured suffix-generation, no turn-on."

## Open Questions Deferred

- **Multi-region suffixes.** A generated program that owns the
  tail of one region and the head of an adjacent region requires
  a separate decision about how cross-region inputs are read.
  Stays deferred from 7.D for the same reason.
- **Suffix length policy.** The generator could in principle pick
  the longest legal suffix per candidate, or the shortest, or
  some cost-model-weighted choice. 7.E picks the longest legal
  suffix that the v1 op set can express; if the diagnostics show
  this is the wrong rule, the policy moves into 7.F or later.
- **Mixed prefix/suffix region scheduling.** Today the prefix
  stays in one region and the suffix becomes its own region.
  Other splittings (e.g. node-loop prefix interleaved with the
  generated tail inside one C++ region) are not part of this
  slice; they would change the §4.E.2 contribution accounting.
- **Interpreter overhead vs op-set width.** 7.E does not answer
  whether interpreter dispatch cost or the lack of fused ops
  dominates today's slower generated rows. A future slice can
  use the diagnostic delta to decide whether to add ops (4.B-style
  fused multiply-add, dedicated `KGain` op) or improve dispatch
  (packed instruction stream, branchless tail).
