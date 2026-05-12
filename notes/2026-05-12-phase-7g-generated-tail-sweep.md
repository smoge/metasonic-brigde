# Phase 7.G Generated-Owned Tail Sweep Decision

Date: 2026-05-12

Status: decision artifact for the first 7.G slice. The slice
answers one question: **can generated execution win when it owns
a longer stateless compute tail, or is the tiny interpreter
itself too expensive for any tail to amortize?** No runtime
turn-on, no FFI / ABI changes, no new node kinds in the
interpreter beyond what 7.D already supports.

## Decision

The generator widens from "own only `[KGain, sink]`" to "own a
contiguous stateless compute tail ending in a sink": any
suffix made of `KAdd` and `KGain` nodes followed by `KOut` /
`KBusOut`. The interpreter still uses the v1 op set
(`OpLoadConst`, `OpLoadInput`, `OpAdd`, `OpMul`, `OpSinkWrite`)
with scratch slots for owned intermediates. External inputs to
the tail (whatever the prefix produced) stay as `SrcInput`;
constants and control reads remain as today.

A new synthetic cost-lab family `generated-tail-sweep` measures
break-even by owned-node count: length 2, 3, 5, 8, 16. The
family is intentionally synthetic — the point is to isolate the
interpreter-cost vs amortization curve from the noise of
real-world prefixes (oscillators, filters, etc.).

The gate's `NeedsBenchmark` verdict refines into a small reason
set so the diagnostic table can distinguish "we measured the
suffix but no full-candidate timing" from "we never measured
this shape at all."

## Why Tail Sweep Now

Phase 7.F's corrected gate now reports
`prefer-generated=0  prefer-existing=2  needs-benchmark=15` on
the live `--fusion-survey` corpus. The previous 10-vs-7 split
came from generated timings borrowing the owned-suffix's
measurement for the whole candidate, masking the real evidence
gap. With suffix-only timings:

- Only **2 rows** have direct measured generated evidence
  against a full-candidate shape (both lose to node-loop).
- **15 rows** sit in `NeedsBenchmark` — either the cost lab
  measured a different suffix, or the generator declined the
  full shape, or no measurement exists at all.
- The remaining 11 are `Unsupported` (1), `CoveredByHandKernel`
  (10), or `NonExact` (0).

So the project today cannot answer "would generated be a win on
a longer chain?" with evidence — the data does not exist. 7.G
generates that data without expanding what the interpreter can
*do*, just what shapes the generator can *own*.

`KAdd` plus `KGain` plus a sink is exactly the v1 interpreter's
expressive range. Every other op the survey's
`NeedsBenchmark` set wants (`KEnv`, `KDelay`, `KSmooth`,
oscillators, filters) carries state or lifecycle semantics; the
interpreter cannot run them in this slice and we are deliberately
not asking it to.

## Scope Boundaries

Hard exclusions:

- **No oscillators.** `KSinOsc`, `KSawOsc`, `KTriOsc`,
  `KPulseOsc`, `KNoiseGen` stay in the node-loop prefix (or are
  not present in 7.G synthetic graphs at all).
- **No filters.** `KLPF` / `KBPF` stay in the node-loop prefix.
- **No `KEnv` / `KDelay` / `KSmooth`.** All stateful or
  buffered; the v1 op set cannot represent them.
- **No bus reads beyond the sink write.** `KBusIn` /
  `KBusInDelayed` are still forbidden inside generated
  programs.
- **No new interpreter ops.** v1 op set frozen. Owned compute
  is exactly the closure of `OpAdd`, `OpMul`, and
  `OpSinkWrite` over `SrcInput` / `SrcConst` / `SrcScratch`.
- **No runtime emission, no FFI change, no §4.B kernel
  replacement.** Strictly cost-lab and gate diagnostics.
- **No CLI knob to override the gate.** Same as 7.F.
- **No `PreferGenerated` snapshot pin.** The slice may produce
  a positive `PreferGenerated` signal on synthetic long tails,
  but that value is read-only and noise-sensitive. A human
  reviews any positive signal before runtime turn-on; snapshot
  pins only the deterministic structural counts.

## Generator Generalization

Today's `generateProgram` recognizes only `[KGain, KOut]`-
ending candidates and emits a fixed two-op program. The new
generator walks the candidate's owned-suffix members and emits
ops kind by kind:

- `KGain n` → `OpMul (scratchSlot) (input n[0]) (input n[1])`
  (signal × amount, same as today).
- `KAdd n` → `OpAdd (scratchSlot) (input n[0]) (input n[1])`.
- `KOut n` / `KBusOut n` → `OpSinkWrite (busIndex) (scratch
  feeding-node) (sinkPolicy)`.

Scratch slot assignment is one per owned non-sink node, in
emission order. Inputs to a non-sink op that are themselves
owned nodes become `SrcScratch`; inputs from outside the
owned slice remain `SrcInput`.

The decline path stays explicit: any owned-suffix node whose
`NodeKind` is not in `{KGain, KAdd, KOut, KBusOut}` aborts the
generator with a clear bucket so the cost-lab diagnostic and
the gate's `Unsupported` verdict surface why.

## Synthetic Tail Family

A new `FamilyGeneratedTailSweep` with these fixed members:

| Length | Kinds                                    | Owned by gen   |
| ------ | ---------------------------------------- | -------------- |
| 2      | `KGain → KOut`                           | both           |
| 3a     | `KGain → KGain → KOut`                   | all three      |
| 3b     | `KAdd  → KGain → KOut`                   | all three      |
| 5      | `KAdd  → KGain → KAdd → KGain → KOut`    | all five       |
| 8      | mixed `Add` / `Gain` ending in `Out`     | all eight      |
| 16     | mixed `Add` / `Gain` ending in `Out`     | all sixteen    |

Lengths are picked to bracket the amortization curve. The
length-2 row replicates the existing `gain-out` measurement so
the new family overlaps the 7.D / 7.E baseline; longer rows
probe how far the per-sample interpreter has to spread
dispatch-overhead before it beats node-loop.

Inputs feeding the tail are simple constants and scratch chains
inside the graph — no oscillator state, no filter coefficients.
The point is to compare interpreter throughput against
node-loop throughput on the same arithmetic, not to model a
real DSP voice.

## Gate Gap Reason Split

Today `NeedsBenchmark` is opaque. 7.G refines it into:

- `NeedsBenchmarkNoGenerated` — cost lab has peer measurements
  but no generated row for this shape (e.g., the candidate is
  a full chain whose suffix the generator measured separately).
- `NeedsBenchmarkNoPeer` — generated measured, no exact peer
  measurement to compare against.
- `NeedsBenchmarkNoMeasurement` — neither generated nor peers
  measured.

The verdict is still a single `NeedsBenchmark` tag for tally
purposes; the reason payload differentiates them in the per-
shape table and survey-only output. Snapshot pins continue to
count the combined `NeedsBenchmark` total (deterministic) and
do not pin the sub-split (it moves with cost-lab corpus
changes, which 7.G is explicitly making).

## Owned-Size Diagnostics

Generated-variant diagnostics gain two per-owned-op bucket views:

```
=== generated variant diagnostics (Phase 7.G) ===
  considered: N  emitted: M  exact: M  unsupported: K  non-exact: 0
  by owned-op count (all emitted rows; rows / median speedup vs node-loop):
    size= 2  rows=…
  generated-tail-sweep by owned-op count (rows / median speedup vs node-loop):
    size= 2  rows=1
    size= 3  rows=2
    size= 5  rows=1
    size= 8  rows=1
    size=16  rows=1
=== end generated diagnostics ===
```

Each bucket reports the median generated speedup vs node-loop.
The all-emitted view shows the current corpus mix; the
`generated-tail-sweep` view isolates the synthetic amortization
probe. Stderr-only, diagnostic, no caller consumes the bucket
map. This is more useful than another flat win/loss count because
the entire point of the slice is the amortization curve.

## Snapshot Pins

Pinned (deterministic, bench-noise-free):

- new family row count (`generated-tail-sweep`, e.g. 6 members
  × 4 variants = 24 rows);
- generated emitted count for the family;
- generated unsupported count for the family (should be 0 —
  every member is generator-supported by construction);
- generated exact count for the family (= emitted, modulo a
  correctness bug);
- generated owned-tail lengths for the family
  (`[2, 3, 3, 5, 8, 16]`);
- gate's combined `NeedsBenchmark` total (whatever the new
  number is post-corpus growth);
- gate's occurrence-count invariant (sum of per-verdict counts
  matches selected-candidates total).

Intentionally **not pinned**:

- `prefer-generated` — read-only and intentionally unpinned.
  Locking a number would chase bench noise; any positive signal
  still needs human review before a runtime turn-on policy can use
  it.
- per-bucket speedups in the owned-size diagnostic — same
  reason.
- win/loss split.

## Verification Target

Slice is done when:

- the generator emits programs for all six
  `generated-tail-sweep` members and they are bit-exact;
- the synthetic family is reachable from
  `--fusion-cost-lab --summary`;
- the owned-size diagnostic prints under
  `--fusion-cost-lab`;
- the gate's `NeedsBenchmark` reason split is visible in the
  per-shape table under `--fusion-survey`;
- snapshot pins cover the new structural counts;
- nothing in the runtime / FFI / loader changes.

The answer ("generated wins above N owned ops" or "generated
still loses even on a length-16 stateless tail") is **the
output** of the slice, not an entry condition. The slice ships
either way; the ROADMAP entry records which way it went.

## Open Questions Deferred

- **Executor redesign if even length-16 loses.** If the
  amortization curve is flat or non-existent, the next slice is
  not "more shapes" but a packed instruction stream,
  superinstructions (`GainOut`, `AddGainOut`, `MulAddOut`,
  ...), or block-loop generation. That decision waits on 7.G's
  evidence.
- **Minimum owned-op planner policy.** If generated wins only
  at length ≥ N, a later slice may add a planner-side floor on
  owned-op count before `PreferGenerated` is allowed. v1 of
  the gate has no policy knobs; this would be a Phase 7.H
  concern at earliest.
- **State-bearing extensions.** `KEnv`, oscillators, filters,
  `KDelay`, `KSmooth` all need either new ops or new
  lifecycle plumbing in the interpreter. None of those touch
  this slice. Deferred until 7.G's break-even answer is known.
- **Real-corpus integration of the wider tail generator.** The
  synthetic family is the evidence-gathering tool; a future
  slice may add real-corpus graphs that exercise long stateless
  tails (e.g., FM-modulator chains, additive partials). Not
  this slice.
- **`KBusOut`-terminated long tails.** Today the synthetic family
  is `KOut`-terminated only. Adding `KBusOut` is a one-line
  generator change and would double the row count; the slice
  picks `KOut`-only to keep the row count small. A later slice
  may add `KBusOut` if the diagnostic value warrants it.
