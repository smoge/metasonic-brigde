# Phase 6.A.3 — Pattern Corpus Survey Baseline

Date: 2026-05-10
Status: records the initial `--corpus-survey` run; subsequent runs
should compare against this baseline.

This note records what the layer-(b) verification gate (§6.A.1
verification meaning, interpretation (b)) actually surfaces when
the pattern corpus is run through the §4 survey machinery.

## How to reproduce

```sh
stack exec -- metasonic-bridge --corpus-survey
```

No audio, no TUI. Compiles each corpus row's initial template set
plus any `PEHotSwap` payload templates through
`compileRuntimeGraph` and `compileRuntimeGraphFused`, then prints
the sections below. Exits non-zero on any compile failure so a
partial baseline does not look valid to scripts or CI.

## Baseline run (2026-05-10)

### §4.B kernel coverage per (row, template)

| Row                  | Template                  | Nodes | Regs | §4.B-regs | Kernels               |
|----------------------|---------------------------|------:|-----:|----------:|-----------------------|
| drone-with-vibrato   | drone                     | 7     | 1    | 0         | —                     |
| arpeggio-send-return | voice                     | 4     | 1    | 0         | —                     |
| arpeggio-send-return | fx                        | 4     | 1    | 1         | `RBusInLpfGainOut`×1  |
| polyphonic-stab      | stab                      | 5     | 1    | 0         | —                     |
| hot-swap-edit        | drone                     | 3     | 1    | 0         | —                     |
| hot-swap-edit        | drone (swap:edit-cutoff)  | 3     | 1    | 0         | —                     |
| layered-ensemble     | bass                      | 5     | 1    | 0         | —                     |
| layered-ensemble     | pad                       | 6     | 1    | 0         | —                     |
| layered-ensemble     | fx                        | 4     | 1    | 1         | `RBusInLpfGainOut`×1  |

The `drone (swap:edit-cutoff)` row is the `PEHotSwap` payload from
`hotSwapEditEvents`. It is surveyed under a decorated template
label so that future drift in the swap payload's structural shape
surfaces here, not silently. Today the payload is structurally
identical to the initial graph (only LPF cutoff / Q defaults
differ), so the survey numbers match across the two `hot-swap-edit`
rows.

### §4.B kernel totals across the corpus

```
RBusInLpfGainOut: 2
```

The corpus exercises one kernel from the §4.B set, in two
distinct rows (arpeggio fx tail and ensemble fx tail). Other
kernels (`RSinGainOut`, `RSawGainOut`, `RNoiseGainOut`,
`RSawLpfGain`, `RSawLpfGainOut`, `RNoiseLpfGainOut`) don't fire on
the corpus.

### §4.B sink-shape contributions

**Claimed shapes.**
- `BusIn → LPF → Gain → sink` claimed in
  `arpeggio-send-return/fx` and `layered-ensemble/fx`.

**Missed shapes — no §4.B kernel exists for this shape.**
- `Sin → LPF → Gain → sink` from `drone-with-vibrato/drone`.

**Missed shapes — kernel exists but a precondition or longest-match
priority blocked the claim.**
- (none)

The Sin-rooted filtered-tail miss is the single new entry the
corpus contributes to the missed-shape table. Per the §4.B.x gate
(`missed ≥ 3 ∧ sources ≥ 3`), one source is not sufficient
recurrence to land a new kernel — the row stays parked as
single-source evidence, exactly as expected.

The polyphonic-stab and layered-ensemble bass / pad rows have
audio-modulated Gain (envelope-shaped), so the scan does not
classify their chains as missed sink shapes — the §4.B
precondition for "scalar gain" is the gate, and these rows fail
it. The corpus row design honestly documents this in its row 3 /
row 5 hypotheses.

### §4.D edge-rate opportunity producers

Zero. The surveyed-demo baseline (per `notes/2026-05-09-phase-4e-...`
and the 4D headline in `--fusion-survey`) is 4 producer nodes in 4
kinds. The pattern corpus contributes nothing.

This is the honest result. The corpus rows all wire envelope
outputs into Gain *audio* inputs (sample-accurate consumer), which
disqualifies the producing Env nodes from the opportunity scan.
Moving the §4.D signal would require either a corpus row with
explicit block-latched consumers, or growing the §4.D scan's
notion of "opportunity" — neither is in 6.A.3 scope.

## What this tells us

- **The corpus is well-formed.** Every row compiles cleanly, every
  hypothesis from the §6.A.2 design note matches the survey
  output. No compile failures, no surprises.
- **The corpus is not a §4.E worker-bench candidate.** Worker
  dispatch threshold work is out of scope for `--corpus-survey`
  (that's `--worker-bench`'s remit); a future 6.A.3 extension
  could pipe the corpus into `--worker-bench` to ask whether any
  row crosses the synthetic envelope, but the current run does
  not report on it.
- **The corpus does not yet move parked §4 rows.** The single new
  entry (`Sin → LPF → Gain → sink`) is below the `missed ≥ 3 ∧
  sources ≥ 3` recurrence threshold. The §4.B.x gate is correctly
  refusing to fire, exactly as the §6.A.1 corpus-naturalness rule
  predicts: the corpus is musical, not engineered to push the
  gate.

## Future runs

When the pattern corpus grows (6.A combinators, new rows added),
re-run `--corpus-survey` and diff against this baseline.
Significant signal:

- A second source for the Sin-rooted filtered tail (would put it
  at `missed ≥ 2 ∧ sources ≥ 2`, halfway to the gate).
- A new §4.D opportunity producer kind from a new row.
- A new claimed-shape entry from a kernel addition.
- A drop in claimed shapes from an unintended structural change.

The bench-style discipline applies: the report is evidence, not a
pass/fail. Compare medians and trends across corpus revisions, not
a single run.
