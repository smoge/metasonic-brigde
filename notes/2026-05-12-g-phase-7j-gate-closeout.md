# Phase 7.J Generated-Executor Gate Closeout

Date: 2026-05-12

Status: decision artifact for the 7.J closeout slice. The slice
turns the analytical conclusion 7.I recorded — "super-mode
still does not justify a `PreferGenerated` row" — into computed
data. After this slice generated fusion is parked as a
read-only performance path, with the gate machinery able to
say, on demand, whether any of the three generated executors
*would* flip a verdict if it were wired in.

No new executor. No runtime turn-on. No new recognizer set, no
packed instructions, no native codegen. No planner emission
changes. The 7.I `VarGenerated`, `VarGeneratedBlock`,
`VarGeneratedSuper` rows already exist in the cost lab; this
slice only adds a per-variant view of the gate's existing
verdicts on those rows.

## Decision

Three small, paired changes:

1. **Parameterize the gate index by variant.** Add
   `costLabGateIndexFor :: Variant -> [LabRow] -> Map ShapeKey GateMeasurement`
   to [app/MetaSonic/App/FusionCostLab.hs](app/MetaSonic/App/FusionCostLab.hs).
   `costLabGateIndex = costLabGateIndexFor VarGenerated`
   preserves today's `--fusion-survey` numbers byte-for-byte.
   The parameter selects which executor row populates
   `gmGeneratorError`, `gmGeneratedExact`, and
   `gmGeneratedSpeedup`. `gmBestPeerSpeedup` is variant-
   independent (it reads `VarRegionKernel` / `VarRFused`) and
   stays unchanged.

2. **Add a gate-by-executor section to `--fusion-survey`.**
   A compact table printed below the existing 7.F gate output.
   Columns:
   `executor | total | prefer-generated | prefer-existing | needs-benchmark | unsupported | non-exact | covered-by-hand-kernel`.
   Rows: `sample-major`, `block-major`, `super-mode`. Re-uses
   the existing `evaluateGate` rules verbatim, only the index
   feeding `gateInputFor` changes.

3. **Pin structural facts at snapshot time.** Six new
   snapshot entries in
   [app/MetaSonic/App/SnapshotCheck.hs](app/MetaSonic/App/SnapshotCheck.hs):
     - sample-major / block-major / super-mode
       `prefer-generated` count is stable (pinned to the
       observed value — see below);
     - every executor reports `non-exact = 0` (correctness
       invariant; the bit-exact tests guarantee this, the gate
       column makes the guarantee visible);
     - gate row totals agree across executors (cross-executor
       sanity: every variant scans the same candidate set);
     - `prefer-generated` count agrees across all three
       executors (the recognizer-level differences between
       sample / block / super don't move the gate decision on
       the snapshot corpus).
   Win/loss splits, per-bucket medians, and speedup payloads
   stay unpinned per the bench-noise discipline.

## Scope discipline

What this slice does **not** do:

- It does not wire any generated executor into the
  planner / runtime turn-on path. `PreferGenerated` (if it
  ever happened) is still strictly read-only.
- It does not change the per-shape recognizer set. The 7.I
  v1 set (`GainOut`, `AddGainOut` plus structural fallback)
  is unchanged.
- It does not extend the `FusionProgram` ABI, the
  `RegionSpec` shape, or the C ABI surface.
- It does not modify the canonical 7.F gate numbers. The
  existing `--fusion-survey` "Phase 7.F generated
  profitability gate" section continues to read from
  `VarGenerated` rows; only the new section adds the
  alternative views.
- It does not change `evaluateGate`, `GateInput`,
  `GateRow`, or `GateCounts`. The rules are a load-bearing
  audit surface — the only thing that varies is which row
  populates the input.

## Outcome

The slice landed three findings:

1. **All three executors agree.** Sample-major, block-major,
   and super-mode produce the same `prefer-generated` count on
   the snapshot corpus. Recognizer-level differences move the
   measured speedup but do not move the gate verdict on any
   shape this corpus contains.

2. **All three executors report `non-exact = 0`.** The bit-
   exact tests already guarantee this; the gate column makes
   it visible in the snapshot.

3. **The snapshot corpus produces one `prefer-generated`
   row — `KGain → KOut` — across all three executors.** This
   contradicts the 7.I writeup's claim that "super-mode
   produces no `PreferGenerated` row." The discrepancy is
   structural, not noise:

   - The 7.I claim was evaluated on the wider
     `--fusion-survey` corpus, which adds demo rows on top of
     `surveyShapeProbes <> surveyEnsembleCorpus`. On the wider
     corpus the same shape aggregates with peer measurements
     that beat the generated speedup (`gen=1.72× peer=2.06×
     → PreferExisting`) — that's the `KGain → KOut gain=const`
     row in `--fusion-survey`'s 7.F section.
   - The snapshot corpus's `surveyShapeProbes` member that
     produces `KGain → KOut` lacks the corresponding peer
     measurement, so the gate runs the `gen >= peer` branch
     against a different `gmBestPeerSpeedup` and lands on
     `PreferGenerated`.

   The fact that all three executors agree on this same row
   means **the recognizer set did not cause the
   `PreferGenerated`** — the underlying generator's
   sample-major output is what beats the peer; super-mode
   only widens the margin.

The pinned `expectedPreferGenerated = 1` records this. Future
slices that change the snapshot corpus or the cost-lab
generator coverage will trigger a deliberate decision instead
of silently moving the verdict.

## Why now, not later

Phase 7.I ended with an analytical claim and a follow-up
list. The list's top item is "park generated fusion as a
generic performance path." Parking it cleanly means turning
the analytical claim into one the snapshot can break if it
stops being true. Adding the gate-by-executor view is the
smallest change that does that: the gate machinery already
exists, the cost-lab rows already exist, and the variant
parameter is a few-line generalization of a function the
survey already calls.

Once that pin lands, future generated-executor work has a
clean trigger: a non-zero `prefer-generated` on any executor
column at snapshot time. Until then, the next implementation
lane is Phase 8.

## Outcome ladder

  1. Sample-major / block-major / super-mode all yield
     `prefer-generated = 0` on the snapshot corpus.
     **Park generated fusion.** Move to Phase 8.
  2. Super-mode yields `prefer-generated > 0` on a shape
     with no `RFused` peer where sample / block do not.
     **Extend recognizer set** toward that shape; do not
     turn on without a kernel slot comparison.
  3. All three executors yield `prefer-generated > 0` on the
     same shape (case 3 — the case we actually landed on).
     **Investigate the shape**, not the executor. The
     recognizer set is innocent here; the question is
     whether the snapshot corpus is missing a peer
     measurement the wider survey corpus has, or whether the
     gate is reading actionable signal that's been hidden by
     corpus dilution.

Case 3 is what the snapshot now reads. The slice still parks
generated fusion as a read-only path: the same shape
(`KGain → KOut gain=const`) is `PreferExisting` on the wider
`--fusion-survey` corpus, so turning the executor on would
not flip a real-world decision. But the slice's evidence
suggests the next investigation, if any, is a peer-coverage
audit on the snapshot corpus — not more executor work.

## Related artifacts

- [notes/2026-05-12-f-phase-7i-superinstruction-probe.md](notes/2026-05-12-f-phase-7i-superinstruction-probe.md)
  — 7.I decision artifact (super-mode probe).
- [notes/2026-05-12-c-phase-7f-profitability-gate.md](notes/2026-05-12-c-phase-7f-profitability-gate.md)
  — 7.F gate rules, priority order, and verdict ADT.
- [app/MetaSonic/App/ProfitabilityGate.hs](app/MetaSonic/App/ProfitabilityGate.hs)
  — unchanged in this slice; the rules surface stays exactly
  as 7.F shipped it.
