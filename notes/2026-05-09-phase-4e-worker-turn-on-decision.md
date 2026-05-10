# Phase 4.E Worker Turn-On Decision

Date: 2026-05-09
Status: Decision recorded after the C1c bench slice; refreshed after
representative Haskell-loaded survey / bench data, corpus-evolution
worker-shape probes, the C1d region-layer survey clarification, the
post-atomic worker benchmark refresh, and the C1d-d instrumentation
slice (`969a0d3` C1d-c runtime, follow-up bench column wiring).
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
- `notes/2026-05-09-phase-4e-c1d-region-layer-dispatch-design.md`
- `e77868f Make worker dispatch lock-free on audio thread`

## Decision

Do **not** turn worker dispatch on by default.

Do **not** expose a public runtime switch yet.

Keep the worker schedule path under the test / bench ABI until both of
these are true:

- the post-realtime-safe-dispatch benchmarks show useful speedup on
  representative Haskell-loaded schedules;
- a successor decision record defines the representative corpus,
  minimum speedup threshold, and public/runtime switch policy.

## Policy by path

| Path | Decision |
|------|----------|
| Legacy direct executor | Remains the default runtime path. |
| Global-schedule serial executor | Keep as opt-in test/reference path. |
| C1c sink-free Free-band worker dispatch | Keep test/bench gated. Positive signal exists only at enough width and work. |
| C1d-c sink-free region-item dispatch | Keep test/bench gated. Synthetic shape wins at scale; Haskell-loaded rows barely cross 1.0x. |
| Direct-mode sink Free bands | Continue explicit serial fallback. |
| Reduction-mode sink Free bands | Keep test-only; do not promote. |
| Phase-D live-bus writer relaxation | Do not start yet. Bench data does not justify it. |

## Rationale

The bench shows a narrow positive envelope:

- `FreeCompute` width 2 loses at both block sizes.
- `FreeCompute` width 8 wins at both measured block sizes after the
  atomic dispatch pass, but remains workload-sensitive.
- `FreeCompute` width 32 wins at 128 and 512 frames, topping out around
  2.17x in the measured run.

The same run shows no useful signal for reduction-backed sink work:

- `FreeSink` reduction-mode dispatch loses across the grid.
- `SendReturn` reduction-mode dispatch loses across the grid.
- Direct-mode sink cases correctly serialize; any small wins there are
  not worker-dispatch wins, as the counters show `parallel_bands=0` and
  `serialized_sink_bands=1`.

The original C1c worker pool had a realtime-policy gap:
`ScheduleWorkerPool::run_parallel` was allocation-free during
`process_graph`, but it took a mutex, woke worker threads, and waited on
a condition variable from the audio thread. The follow-up dispatch pass
removed that audio-thread mutex/cv path and replaced it with atomic
generation + completion counters. That makes the dispatch substrate
safe with respect to audio-thread locks/allocation. The post-atomic
bench refresh improves the sink-free compute envelope, but it does not
change the default-off policy: the only Haskell-loaded dispatched row
that wins is still a targeted probe, not representative default-on
evidence.

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
best_worker_speedup=2.06x  best_parallel_worker_speedup=1.42x
```

Interpretation: the Haskell-loaded bench now enters the worker dispatch
path, but only for the intentionally multi-instance
`sched/free-only-parallel-compute` probe. After the atomic dispatch
pass, that targeted row is positive (`sched-pool3-direct` 1.42x,
`sched-pool3-reduce` 1.32x). Rows that look faster while
`parallel_bands=0` remain schedule-path noise or serial-executor
variance. Counter data, not speedup alone, is the authority here.

## Next allowed work

The next runtime-parallelism work should be one of:

- C1d substrate implementation, only in the phases described by the C1d
  design note: allocation-free metadata/introspection, serial
  region-item equivalence, sink-free parallel region items, then bench
  and decision refresh. Do not start with worker dispatch directly;
- corpus evolution: add or identify less synthetic Haskell-loaded demos
  with enough region-layer work to make C1d worth benchmarking. The
  first targeted probes prove the instrumentation can see the shape, but
  they are not a representative default-on basis;
- benchmark refresh: done for the atomic dispatch pass. Repeat only
  after C1d changes, corpus changes, or pool-policy changes;
- policy prototype under the test ABI only, and only after representative
  rows actually enter worker dispatch: sink-free bands, no reduction,
  minimum width/work threshold, and full T-9 equivalence.

Do not make a public switch or default-on change until a later decision
record replaces this one. That successor record must define the
representative corpus and threshold explicitly; this note only records the
current negative decision. As of this refresh, worker dispatch is
observable from the Haskell-loaded corpus, but the only dispatched rows
are targeted probes. One targeted row now measures above 1.0x, which is
good evidence for continuing C1d investigation, but not enough evidence
for a public switch or default-on policy.

## C1d-d instrumentation refresh

C1d-c (sink-free region-item parallel dispatch) shipped behind the
existing test/bench switches in `969a0d3`. C1d-d adds bench
instrumentation only — no runtime policy change. After C1d-d:

- `--worker-bench` columns extended with `c1d_parallel_entries` and
  `c1d_parallel_items`; summary now reports
  `worker_rows_with_c1d_parallel`, `c1d_parallel_entries`,
  `c1d_parallel_items`, and `best_c1d_worker_speedup`.
- `tools/rt_graph_bench.cpp` exposes the same per-row counters and adds
  one dedicated synthetic shape, `RegionItems`: a single instance with
  N parallel sink-free Saw→LPF→Gain chains in one FreeLayer step. C1c
  band-level dispatch never fires there (band has one entry), so any
  worker speedup is unambiguously C1d-c.

### How to read the bench output

The counters partition every row into one of three categories. A
positive default-on argument has to come from one of the first two; the
third is noise that no policy decision can rest on.

| Row class | Counter signature | What a non-1.00x speedup means |
|-----------|-------------------|--------------------------------|
| **C1c band-level dispatch** | `parallel_bands > 0` | Multi-entry Free band dispatched across instances. |
| **C1d-c region-item dispatch** | `parallel_bands == 0` ∧ `c1d_parallel_entries > 0` | Single-entry Free band with multi-region sink-free items dispatched at item granularity. |
| **Schedule/serial noise** | both counters zero | Schedule-executor overhead, serial-executor variance, or measurement noise. Not evidence either way. |

### Post-C1d-d numbers

`stack exec -- metasonic-bridge --worker-bench` (median of 3, 32 timed
blocks at 256 frames) summary:

```text
cases=56  rows=224  worker_rows=112
worker_rows_with_parallel=2     parallel_bands=2     parallel_entries=6
worker_rows_with_c1d_parallel=6 c1d_parallel_entries=6 c1d_parallel_items=16
best_worker_speedup=1.94x
best_parallel_worker_speedup=1.39x   (C1c band-level)
best_c1d_worker_speedup=1.03x        (C1d-c region-item)
```

C1c rows (parallel_bands > 0):

- `sched/free-only-parallel-compute` pool3-direct: 1.25x.
- `sched/free-only-parallel-compute` pool3-reduce: 1.30x.

C1d-c rows (c1d_parallel_entries > 0):

- `sched/parallel-compute-before-master` pool3-direct: 0.94x (loss).
- `sched/parallel-compute-before-master` pool3-reduce: 0.92x (loss).
- `sched/poly-voices-master-fx`         pool3-direct: 1.12x.
- `sched/poly-voices-master-fx`         pool3-reduce: 1.07x.
- `sched/parallel-fx-rack-master`       pool3-direct: 1.14x.
- `sched/parallel-fx-rack-master`       pool3-reduce: 1.06x.

The Haskell-loaded C1d-c envelope is narrower than C1c's: best 1.14x
on a single targeted probe, with one row losing. The reductive variant
loses uniformly relative to direct on the C1d-c rows, suggesting the
join-fold path is not paying for itself when the band is already
sink-free.

`just cpp-bench` `RegionItems` rows (synthetic, single instance, N
parallel sink-free chains) confirm the C1d-c substrate scales with
width and block size when the region body is heavy enough:

| voices | block | best mode        | speedup |
|-------:|------:|------------------|--------:|
|      2 |   128 | sched-pool2-direct | 0.73x |
|      2 |   512 | sched-pool2-reduce | 0.98x |
|      8 |   128 | sched-pool3-direct | 1.54x |
|      8 |   512 | sched-pool4-direct | 1.89x |
|     32 |   128 | sched-pool4-direct | 2.00x |
|     32 |   512 | sched-pool4-direct | 2.20x |

`parallel_bands == 0` and `c1d_parallel_entries == 1` on every
RegionItems pool row, confirming the synthetic win is pure C1d-c.

### Decision unchanged

The instrumentation now distinguishes C1c, C1d-c, and noise per row, so
future bench runs cannot conflate them. The substrate is real on the
synthetic side. The Haskell-loaded corpus does not yet have a C1d-c row
above the C1c best, and the C1d-c best is barely above the noise floor.
A representative default-on basis still does not exist.

The next allowed step is corpus expansion only if a real demo or use
case demands a single-instance, multi-region sink-free FreeLayer shape
with enough region-body work to put C1d-c near or above the synthetic
envelope. Adding such a shape purely to feed the bench, without a
load-bearing user, would be circular evidence and is not authorized by
this record. Do not change default-on policy without a successor
decision record that names the corpus and threshold.
