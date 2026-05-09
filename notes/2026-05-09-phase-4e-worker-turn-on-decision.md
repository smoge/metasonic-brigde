# Phase 4.E Worker Turn-On Decision

Date: 2026-05-09
Status: Decision recorded after the C1c bench slice.
Inputs:

- `2c737ce Benchmark global schedule worker dispatch`
- `notes/2026-05-09-phase-4e-worker-bench-interpretation.md`
- C1c correctness gates: C++ schedule-worker tests and Haskell T-9 corpus
  equivalence under `pool_size=3`

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

## Next allowed work

The next runtime-parallelism work should be one of:

- benchmark representativeness: add Haskell-loaded schedule-worker bench
  cases or report the real corpus distribution of Free-band widths and
  per-band work;
- dispatch mechanics: prototype a realtime-safer worker wake/join
  strategy and rerun the same bench grid;
- policy prototype under the test ABI only: sink-free bands, no
  reduction, minimum width/work threshold, and full T-9 equivalence.

Do not make a public switch or default-on change until a later decision
record replaces this one.
