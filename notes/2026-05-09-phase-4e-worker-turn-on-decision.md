# Phase 4.E Worker Turn-On Decision

Date: 2026-05-09
Status: Decision recorded after the C1c bench slice; refreshed after
representative Haskell-loaded survey / bench data.
Inputs:

- `2c737ce Benchmark global schedule worker dispatch`
- `notes/2026-05-09-phase-4e-worker-bench-interpretation.md`
- C1c correctness gates: C++ schedule-worker tests and Haskell T-9 corpus
  equivalence under `pool_size=3`
- `3c77d0e Survey corpus schedule worker width`
- `246ac6a Benchmark Haskell-loaded worker schedules`

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

The follow-up survey / bench work closes the earlier
"representative graph data" open item.

`stack exec -- metasonic-bridge --fusion-survey` now includes a fixed
corpus schedule-width table for C1c worker-gate shape:

```text
graphs=58  bands=4  sf=4  sink=0  maxSfW=1  maxSinkW=0
maxWork=1  dirC1c=0  redC1c=0
```

Interpretation: the current fixed corpus has no width >= 2 free-band
shape that passes either direct-mode or reduction-mode C1c candidate
criteria. The only free bands are sink-free, width 1, and single-node
work.

`stack exec -- metasonic-bridge --worker-bench` loads demos plus the
fixed corpus through the Haskell FFI path and compares legacy direct,
schedule-serial, pool direct, and pool reduction modes:

```text
cases=52  rows=208  worker_rows=104  worker_rows_with_parallel=0
parallel_bands=0  parallel_entries=0  serialized_sink_bands=0
best_parallel_worker_speedup=0.00x
```

Interpretation: the Haskell-loaded bench never enters the worker
dispatch path on the current demo + corpus set. Any row where
`sched-pool3-*` appears faster than legacy is therefore schedule-path
noise or serial-executor variance, not evidence that workers are paying
off. Counter data, not speedup alone, is the authority here.

## Next allowed work

The next runtime-parallelism work should be one of:

- corpus evolution: add or identify real Haskell-loaded graphs with
  width >= 2 sink-free Free bands before doing more worker policy work;
- dispatch mechanics: prototype a realtime-safer worker wake/join
  strategy only if a later corpus refresh produces worker-dispatchable
  graph shapes, then rerun both the C++ synthetic grid and
  `--worker-bench`;
- policy prototype under the test ABI only, and only after representative
  rows actually enter worker dispatch: sink-free bands, no reduction,
  minimum width/work threshold, and full T-9 equivalence.

Do not make a public switch or default-on change until a later decision
record replaces this one. That successor record must define the
representative corpus and threshold explicitly; this note only records the
current negative decision. As of this refresh, the threshold is not merely
unmet; the representative Haskell-loaded path has zero worker-dispatched
bands.
