# Phase 4.E Worker Turn-On Decision

Date: 2026-05-09
Status: Decision recorded after the C1c bench slice; refreshed after
representative Haskell-loaded survey / bench data, corpus-evolution
worker-shape probes, and the C1d region-layer survey clarification.
Inputs:

- `2c737ce Benchmark global schedule worker dispatch`
- `notes/2026-05-09-phase-4e-worker-bench-interpretation.md`
- C1c correctness gates: C++ schedule-worker tests and Haskell T-9 corpus
  equivalence under `pool_size=3`
- `3c77d0e Survey corpus schedule worker width`
- `246ac6a Benchmark Haskell-loaded worker schedules`
- corpus-evolution slices:
  `sched/free-only-parallel-compute`,
  `sched/parallel-compute-before-master`,
  `sched/poly-voices-master-fx`, and
  `sched/parallel-fx-rack-master`

## Decision

Do **not** turn worker dispatch on by default.

Do **not** expose a public runtime switch yet.

Keep the worker schedule path under the test / bench ABI until both of
these are true:

- the dispatch primitive has a realtime-safe policy, not the current
  mutex / condition-variable join on the audio thread;
- representative graph benchmarks show speedup on real Haskell-loaded
  schedules, not only on synthetic C++ fixtures.

## Policy by path

| Path | Decision |
|------|----------|
| Legacy direct executor | Remains the default runtime path. |
| Global-schedule serial executor | Keep as opt-in test/reference path. |
| Sink-free Free-band worker dispatch | Keep test/bench gated. Positive signal exists only at enough width and work. |
| Direct-mode sink Free bands | Continue explicit serial fallback. |
| Reduction-mode sink Free bands | Keep test-only; do not promote. |
| Phase-D live-bus writer relaxation | Do not start yet. Bench data does not justify it. |

## Rationale

The bench shows a narrow positive envelope:

- `FreeCompute` width 2 loses at both block sizes.
- `FreeCompute` width 8 only wins at 512 frames.
- `FreeCompute` width 32 wins at 128 and 512 frames, topping out around
  2.12x in the measured run.

The same run shows no useful signal for reduction-backed sink work:

- `FreeSink` reduction-mode dispatch loses across the grid.
- `SendReturn` reduction-mode dispatch loses across the grid.
- Direct-mode sink cases correctly serialize; any small wins there are
  not worker-dispatch wins, as the counters show `parallel_bands=0` and
  `serialized_sink_bands=1`.

The current worker pool also still has a realtime-policy gap:
`ScheduleWorkerPool::run_parallel` is allocation-free during
`process_graph`, but it takes a mutex, wakes worker threads, and waits on
a condition variable from the audio thread. That is acceptable for the
current test/bench substrate and not acceptable as a default audio path.

## Representative-data refresh

The follow-up survey / bench work first showed that the fixed corpus
had no worker-dispatchable width. The corpus-evolution slice then added
two targeted Haskell-loaded probes:

- `sched/free-only-parallel-compute`: two independent sink-free compute
  chains, no bus sink, and extra live instances in `--worker-bench` so
  the C1c global-entry worker path is actually exercised;
- `sched/parallel-compute-before-master`: independent sink-free compute
  before a later master sink barrier. This proves the region-layer
  corpus can expose the target shape, but the current C1c global-entry
  dispatcher still does not parallelize that single-instance row.

A second corpus-evolution pass added less synthetic output-bearing rows:

- `sched/poly-voices-master-fx`: three independent synth voices feeding
  a shared master filter/sink;
- `sched/parallel-fx-rack-master`: three independent pre-master
  processing lanes feeding a shared master mix.

Those rows raise the region-layer signal and make C1d worth
investigating, but they still do not enter C1c worker dispatch because
C1c dispatches one global schedule entry at a time.

`stack exec -- metasonic-bridge --fusion-survey` now includes a fixed
corpus FreeLayer-width table for C1d region-layer candidates:

```text
graphs=62  bands=9  sf=9  sink=0  maxSfW=3  maxSinkW=0
maxWork=9  dirC1d=4  redC1d=0
```

Interpretation: the fixed corpus now contains width >= 2 sink-free
FreeLayer shapes inside single global schedule entries. This is a C1d
candidate signal, not proof that C1c can dispatch those rows. There are
still no reduction-mode sink-band candidates in the fixed corpus.

`stack exec -- metasonic-bridge --worker-bench` loads demos plus the
fixed corpus through the Haskell FFI path and compares legacy direct,
schedule-serial, pool direct, and pool reduction modes:

```text
cases=56  rows=224  worker_rows=112  worker_rows_with_parallel=2
parallel_bands=2  parallel_entries=6  serialized_sink_bands=0
best_parallel_worker_speedup=0.62x
```

Interpretation: the Haskell-loaded bench now enters the worker dispatch
path, but only for the intentionally multi-instance
`sched/free-only-parallel-compute` probe. That probe loses in both pool
modes in the measured run (`best_parallel_worker_speedup=0.62x`).
Rows that look faster while `parallel_bands=0` remain schedule-path
noise or serial-executor variance. Counter data, not speedup alone, is
the authority here.

## Next allowed work

The next runtime-parallelism work should be one of:

- C1d design note: decide whether a future executor should dispatch
  regions inside a single `FreeLayer` step. The survey now labels this
  as `dirC1d` / `redC1d` so it is not confused with C1c worker-dispatch
  evidence. The design must pin writer-slot assignment, per-band joins,
  lifecycle ownership, direct-mode sink fallback, and the equivalence
  tests before runtime code changes;
- corpus evolution: add or identify less synthetic Haskell-loaded demos
  with enough region-layer work to make C1d worth benchmarking. The
  first targeted probes prove the instrumentation can see the shape, but
  they are not a representative default-on basis;
- dispatch mechanics: prototype a realtime-safer worker wake/join
  strategy only after a later corpus refresh produces worker-dispatchable
  graph shapes that actually win, then rerun both the C++ synthetic grid
  and `--worker-bench`;
- policy prototype under the test ABI only, and only after representative
  rows actually enter worker dispatch: sink-free bands, no reduction,
  minimum width/work threshold, and full T-9 equivalence.

Do not make a public switch or default-on change until a later decision
record replaces this one. That successor record must define the
representative corpus and threshold explicitly; this note only records the
current negative decision. As of this refresh, worker dispatch is
observable from the Haskell-loaded corpus, but the only dispatched rows
are targeted probes and the measured parallel speedup is below 1.0x.
