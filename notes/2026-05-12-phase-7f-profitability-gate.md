# Phase 7.F Read-Only Profitability Gate Decision

Date: 2026-05-12

Status: decision artifact for the first 7.F slice. The slice
lands a **read-only** gate: a per-shape verdict that says whether
generated execution would be a win on today's measurements. It
does **not** turn generated execution on at runtime, change any
runtime ABI, or move any kernel selection from hand-written to
generated. The gate's purpose is to formalize the safety rule and
prove out the verdict surface against current evidence before
anything starts emitting `FusionProgram`s by policy.

## Decision

The first 7.F slice adds a verdict function over the existing
cost-model join: given a planner-selected candidate, the
generator's coverage of it, and the cost-lab measurements for the
matching shape, classify the row as one of a small set of
verdicts. The verdicts and their reasons appear in
`--fusion-survey` as a new "Phase 7.F generated profitability
gate" section and are pinned in snapshot.

Nothing in the runtime, FFI, or loader changes. The cost lab's
`VarGenerated` variant continues to measure rows; the verdict is
a pure function on the rows the cost lab already produces.

## Why Read-Only First

Current evidence as of 2026-05-12:

- `--fusion-cost-lab`: 88 rows total. Generated considered 22,
  emitted 19, unsupported 3, exact 19, non-exact 0. Generated
  speedup vs node-loop: 1 win (>= 1.05x), 18 losses; median
  ~0.75x. Generated delta vs best non-generated peer
  (region-kernel / RFused): 1 above zero, 18 below; median
  ~-0.28x.
- `--fusion-survey`: selected=82, covered=58, measured-win=0,
  measured-loss=17, needs-benchmark=7. (Survey corpus is wider
  than the cost-lab corpus, hence the different totals.)

An honest gate run today against this data should say:

- almost everywhere: **do not auto-generate**;
- no stable policy basis yet for: **auto-generate**;
- a small remainder: **needs benchmark data**.

That outcome by itself is what the gate is for. The compiler /
runtime team needs a single source-of-truth answer to "would
turning generated on improve this shape?" The cost-lab JSONL and
the survey cost-model-join already carry the raw numbers, but
there is no formal rule that turns those numbers into a yes /
no / not-yet verdict. Without the rule, the existence of
`ExecGenerated` is easy to mistake for readiness.

A runtime turn-on switch on top of a gate that today picks
nothing would just be dead policy code. Build the verdict
surface first, watch what it says, then revisit runtime turn-on
once the verdict actually picks something.

## Gate Rules

The verdict for a planner-selected candidate is decided by these
rules, applied in order. The first matching rule wins; later
rules do not run.

1. **Unsupported.** If the generator declined to emit a program
   for this candidate (`generateProgram` returned `Left _`),
   verdict is `Unsupported`. Reason carries the decline bucket
   from the cost-lab diagnostic (`not implemented yet`, etc.).
2. **NonExact.** If a generated program was emitted but its
   measured output diverged from `RNodeLoop` (`lrEquivalence /=
   EqExact`), verdict is `NonExact`. This is a correctness bug,
   not a profitability decision; the gate must surface it as a
   hard no even if the measured speedup were favorable.
3. **CoveredByHandKernel.** If the candidate's `fcMatchedShape`
   is `Just _` (a §4.B hand-written kernel claims this shape),
   verdict is `CoveredByHandKernel` in v1. Hand-written kernels
   are not automatically replaced by generated programs in this
   slice. A future slice may relax this rule when the generated
   path is faster *and* the gate has accumulated enough
   measurements to trust the comparison; today it stays
   audit-only.
4. **NeedsBenchmark.** If there is no cost-lab row matching the
   candidate's shape key (the cost lab has not measured this
   shape), verdict is `NeedsBenchmark`. The fix is corpus growth,
   not a gate change.
5. **PreferExisting.** If the generated row's measured speedup
   relative to node-loop is below `measuredWinThreshold` (1.05x)
   or below the best non-generated peer's speedup (the better of
   `VarRegionKernel` and `VarRFused`, when measured), verdict is
   `PreferExisting`. The peer comparison is what stops the gate
   from approving a generated row that beats node-loop but loses
   to an existing region-kernel.
6. **PreferGenerated.** Otherwise: generated is bit-exact, the
   shape is not §4.B-covered, the cost lab has a measurement, and
   the measured speedup beats both node-loop and every measured
   non-generated peer. This is the only verdict that says "turn
   it on."

In all verdicts, "generated speedup" means
`lrSpeedupVsBase` for the `VarGenerated` row of the same
(family, member). "Peer speedup" means the same field on the
matching `VarRegionKernel` / `VarRFused` rows. All comparisons
use the same float arithmetic discipline the rest of the cost-lab
join uses.

## Coverage Boundaries

Hard exclusions for this slice:

- **No runtime emission.** No production graph picks
  `ExecGenerated` based on the gate. The loader, FFI, and
  template-loading paths stay unchanged.
- **No automatic replacement of §4.B kernels.** Rule 3
  `CoveredByHandKernel` is non-negotiable in v1.
- **No win-loss split pinned in snapshot.** Like 7.D / 7.E, the
  generated win/loss number flaps with bench noise around the
  1.05x threshold and stays unpinned. The pinned signals are
  deterministic counts (total rows, unsupported, non-exact,
  covered-by-hand-kernel, occurrence coverage) and the
  needs-benchmark backlog.
- **No CLI knob to override the gate.** The gate is a function;
  callers consume verdicts. Per-shape override is a Phase 8 or
  later concern.
- **No multi-instance / multi-template aggregation.** Each
  planner-selected candidate gets a verdict in isolation. A real
  ensemble may have N instances of the same template hitting the
  same shape — the gate reports the verdict per shape, not per
  instance.

## What's In the Survey Surface

The new `--fusion-survey` section reports:

- Per-verdict counts (`prefer-generated`, `prefer-existing`,
  `needs-benchmark`, `unsupported`, `non-exact`,
  `covered-by-hand-kernel`).
- Per-shape table with the candidate's shape, member label,
  verdict, reason, generated speedup vs node-loop, best
  non-generated peer speedup, and delta. Sorted so
  `PreferGenerated` rows (if any) come first.
- A one-line summary at the top that surfaces the read-only
  `prefer-generated = N` signal for human review before any
  runtime turn-on policy consumes it.

## Snapshot Pins

The pinned counts from this slice:

- total gate rows;
- needs-benchmark count (today's signal from the survey
  cost-model join);
- unsupported count if surfaced;
- non-exact count (today: 0; surfacing as a pin lets a
  correctness regression fail snapshot before it ships).
- occurrence count matching the planner's selected candidates.

Generated win/loss split, `prefer-generated`, deltas, and
percentile speedups stay unpinned. They flap with bench noise;
snapshot is for invariants that move only when intent moves.

## Verification Target

Slice is done when:

- a verdict function exists, callable from the survey;
- `--fusion-survey` prints the Phase 7.F section with counts and
  per-shape rows;
- snapshot pins lock the deterministic counts;
- the ROADMAP entry for 7.F is updated from "future" to "first
  read-only gate landed; no runtime turn-on";
- nothing in the runtime, loader, or FFI changes.

## Open Questions Deferred

- **Runtime turn-on policy.** Once the gate exists and the
  generator path becomes faster on at least one shape that the
  gate would approve, a future slice will wire `PreferGenerated`
  into the loader. The wiring needs a separate decision about how
  the runtime carries gate verdicts (per-template metadata vs.
  recomputed from cost-lab metadata) and how a turn-on rollback
  works if a downstream change regresses a row.
- **Per-instance aggregation.** A multi-instance ensemble may
  want a single verdict averaged or worst-cased across instances;
  this slice reports per-shape and leaves aggregation to the
  consumer.
- **Trust radius for stale measurements.** The gate consults the
  cost lab's current run. If a downstream change lands without
  re-running the lab, the gate's view goes stale silently. A
  future slice may want a freshness flag on cost-lab rows; not
  this one.
- **Relaxing rule 3 for measured-faster generated.** If a
  generated row beats its §4.B hand-written peer by a clearly
  meaningful margin (e.g. 1.5x+) and the gate has measured it
  consistently across runs, a future slice may demote
  `CoveredByHandKernel` to `PreferGenerated` for those shapes.
  v1 keeps the hand-written kernels untouched.
- **What "shape key" includes.** The 7.C cost-model join already
  uses `shapeKeyOf` with `fcMemberKinds` and `fcGainAmountModes`.
  The gate uses the same key today. If a future feature axis
  (latency, fanout, etc.) becomes a profitability lever, the key
  widens — and the gate's verdict ordering may need to be revised
  to match.
