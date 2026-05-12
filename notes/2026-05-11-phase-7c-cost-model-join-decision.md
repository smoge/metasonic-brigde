# Phase 7.C Cost-Model Join Decision

Date: 2026-05-11

Status: decision artifact for the 7.C/7.A bridge slice. The join is
diagnostic only — it classifies each selected planner candidate
against measured cost-lab evidence, but produces no execution decision
and no runtime change.

## Decision

Add a small **shape-keyed join** between the selected planner
candidates (from `selectedFusionCandidates`) and the fusion cost lab
rows. Each selected candidate falls into exactly one of four classes:

| Class             | Predicate                                                                                                              |
|-------------------|------------------------------------------------------------------------------------------------------------------------|
| `covered`         | `fcMatchedShape /= Nothing`. A §4.B hand-written kernel already claims this exact shape.                               |
| `measured-win`    | Generated-eligible AND cost-lab has a row for this shape where the region-kernel variant beats the node-loop baseline. |
| `measured-loss`   | Generated-eligible AND cost-lab has a row for this shape where the region-kernel variant is ≥ the node-loop baseline.  |
| `needs-benchmark` | Generated-eligible AND no cost-lab row matches this shape.                                                             |

"Generated-eligible" is the user-visible label for **selected,
accepted, no §4.B match** — the candidates the Phase 7.D executor
could plausibly emit code for if profitability evidence existed.

## Shape Key

A candidate's **shape key** is its `fcMemberKinds` field — the ordered
list of `NodeKind` along the candidate, source to terminal sink. Two
candidates with the same shape key are considered identical for the
cost-model join even if their `NodeIndex` values differ.

The shape key intentionally excludes:

- per-instance parameter values (e.g. `Gain` amount, `LPF` cutoff);
- per-instance bus and buffer identities;
- region or template identity;
- consumer count and fanout (filtered out at the planner already —
  selected candidates have no fanout escape).

Including any of these would split shapes that should join (e.g.,
two `Sin → Gain → Out` chains with different frequencies are the
same shape for fusion planning).

A future refinement may add a small **feature axis** alongside the
shape key — `(hasResourceAtSource, sinkKind, totalLatency)` — for
shapes whose profitability genuinely differs along those axes. The
v1 join keys on `fcMemberKinds` alone and treats every other axis
as identifying noise.

## Inputs

| Source                                            | What it provides                              |
| ------------------------------------------------- | --------------------------------------------- |
| `selectedFusionCandidates` per survey row        | The candidates to classify                    |
| `collectFusionCostLabRows defaultOptions`        | Measured ns/sample per (family/member/variant) |
| Cost-lab row's recompiled `RuntimeGraph`          | The shape key for that row                    |

The cost-lab rows are already computed during snapshot runs (the
snapshot already calls `collectFusionCostLabRows`). Reusing them
for the join adds no measurement cost.

## Cost-Lab Side: Per-Row Shape Key

Each `LabRow` corresponds to one (family, member, variant) tuple
whose source is a `SynthGraph`. To derive the row's shape key, the
join re-compiles the member's `SynthGraph` (the same step the cost
lab already takes internally), runs the planner, and reads the
selected candidates' `fcMemberKinds`. A single cost-lab member can
contribute multiple shape keys if its graph contains multiple
selected candidates (e.g., a fanout-near-miss family has two outs
and two candidates).

For the v1 join the row's "fastest non-baseline variant" is
captured as a single ns/sample value:

- `fastestNonBaseline = min (regionKernel, rfused)`.

Speedup vs. node-loop baseline is `nodeLoopNs / fastestNonBaseline`.
A speedup > 1 is a measured win; ≤ 1 is a measured loss. If the
row is missing either the baseline or all non-baseline variants
(equivalence/compile failure), the row contributes nothing — the
shape stays `needs-benchmark` from the survey's perspective.

## Output Shape

`--fusion-survey` gains one section, placed after the existing
"Phase 7.C planner verdicts" block:

```
─── Phase 7.C cost-model join ───
  selected=N  covered=A  measured-win=B  measured-loss=C  needs-benchmark=D

  Per-shape table (selected candidates only):
    kinds                          matched-shape     class           count  speedup
    KSinOsc → KGain → KOut         RSinGainOut       covered         …      n/a
    KBusIn → KLPF → KGain → KOut   RBusInLpfGainOut  covered         …      n/a
    KGain → KOut                   —                 needs-benchmark …      —
    KAdd → KOut                    —                 measured-win    …      1.4×
    KAdd → KLPF → KGain → KOut     —                 needs-benchmark …      —
```

`speedup` is reported only for `measured-win` and `measured-loss`
rows; `covered` rows display `n/a` (the §4.B hand-written kernel
is the path, not the generated executor); `needs-benchmark` rows
display `—`.

`--snapshot-check` gains pinned per-class counts: covered,
measured-win, measured-loss, needs-benchmark. The
needs-benchmark count is the Phase 7.D gate signal — when this
count is high relative to generated-eligible, the cost lab needs
new families before the executor lands.

## Why Not Just Use The Planner's Generated-Eligible Count

The Phase 7.C planner already reports a "generated-eligible" count
(commit `9441d9c`). That count answers "how many candidates would
the executor look at if it existed". The cost-model join answers a
different question: "of those, how many do we have evidence to
make a decision about". The two are intentionally orthogonal — the
planner is legality-only and the join is the profitability
diagnostic layer on top.

## Implementation Plan

In order, smallest commits first:

1. **Cost-lab shape index** in `MetaSonic.App.FusionCostLab`:
   add `costLabShapeIndex :: [LabRow] -> Map [NodeKind] ShapeSummary`
   where `ShapeSummary` carries `(baselineNs, fastestNs, speedup)`.
   The lookup re-runs the planner internally to derive shape keys
   per row.
2. **Selected candidate table** in `MetaSonic.App.Survey` (no
   cost-lab join yet): a compact section listing each unique shape
   in the survey's selected candidates with count, matched-shape,
   and a placeholder class column.
3. **Cost-lab join** layered onto the selected candidate table: the
   class column becomes one of the four real values; speedup is
   shown for measured rows.
4. **Snapshot pins** on the four per-class counts.

## Out Of Scope For This Slice

- A runtime executor or any C ABI change. The join is Haskell-only
  and read-only.
- Profitability decisions in the planner itself. The planner
  remains legality-only; the join lives entirely in the survey
  output and snapshot check.
- Shape-key refinement beyond `fcMemberKinds`. Adding a feature
  axis (e.g., `(sinkKind, latency)`) is deferred until the v1 join
  shows a shape whose profitability splits along that axis.
- Per-control-value or per-parameter profitability splits. Cost
  lab measurements average across parameter values within a
  member; the join inherits that simplification.
- Random/fuzz cost-lab rows. Today's cost lab is parametric +
  corpus only; expanding to fuzz rows is a separate cost-lab
  follow-up.

## Open Questions Deferred

- **Empty-baseline rows.** A cost-lab row whose node-loop variant
  failed equivalence but whose region-kernel/rfused variants
  succeeded yields no speedup. Today these rows are dropped from
  the index; an alternative is to surface them as
  `measurement-degraded`. Deferred until a real case appears.
- **Same-shape, different latency.** Two candidates with identical
  `fcMemberKinds` but different total `kindLatency` (none today,
  but a future kind could add latency to the chain) would join
  to the same cost-lab summary. The feature-axis refinement above
  addresses this when needed.
- **Multi-region same-shape.** A shape that appears across many
  regions today contributes many entries to the survey count
  column. The join treats all instances identically — which is
  fine for a planning-stage diagnostic, but the count column may
  want a "distinct sources" follow-up like the missed-shape table.
