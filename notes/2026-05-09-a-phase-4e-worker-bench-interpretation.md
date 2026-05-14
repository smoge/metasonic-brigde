# Phase 4.E Worker Bench Interpretation

Date: 2026-05-09
Status: Bench slice interpreted. Refreshed after the atomic worker
dispatch primitive. Decision recorded separately.
Source command:

```sh
just cpp-bench
stack exec -- metasonic-bridge --worker-bench
```

Build mode: `RelWithDebInfo`, `METASONIC_BUILD_TESTS=OFF`.
Initial commit under test: `2c737ce Benchmark global schedule worker
dispatch`.

Post-atomic refresh: after `e77868f` replaced the audio-thread
mutex/condition-variable dispatch path with atomic generation +
completion counters.

## Bench surface

The new schedule-worker section covers three synthetic runtime
shapes:

- `FreeCompute`: sink-free `SawOsc -> LPF -> Gain` Free-band work.
- `FreeSink`: a deliberately Free sink-terminal `SinOsc -> Gain -> Out`
  band. Haskell normally keeps sink regions on the barrier path; this
  fixture exercises the C1c runtime gate directly.
- `SendReturn`: N sender voices write bus 1 in a Free band, followed by
  a live reader barrier that consumes bus 1 and writes bus 0.

Each row compares:

- legacy direct executor,
- global-schedule serial direct executor,
- global schedule plus worker pools of size 2, 3, and 4,
- direct and reduction variants where relevant.

The bench also reports the C1c counters:

- `parallel_bands`,
- `parallel_entries`,
- `serialized_sink_bands`.

## Counter check

The counters match the intended gates:

- `FreeCompute`: pool modes report `parallel_bands=1`,
  `parallel_entries=voices`, and `serialized_sink_bands=0`.
- `FreeSink` direct: pool modes report no parallel work and
  `serialized_sink_bands=1`.
- `FreeSink` reduction: pool modes report one parallel band with
  `parallel_entries=voices`.
- `SendReturn` direct: the sender sink band serializes, so no parallel
  work and `serialized_sink_bands=1`.
- `SendReturn` reduction: the sender band dispatches in parallel and
  folds before the reader barrier.

That means the timing rows are measuring the intended code paths, not
idle workers.

## Results by shape

### FreeCompute

This is the only shape with a real positive signal.

Observed best pool rows:

| block | voices | best pool row | speedup |
|-------|--------|---------------|---------|
| 128   | 2      | pool2 reduce  | 0.71x   |
| 512   | 2      | pool3 reduce  | 0.84x   |
| 128   | 8      | pool4 direct  | 1.43x   |
| 512   | 8      | pool3 direct  | 1.74x   |
| 128   | 32     | pool4 direct  | 2.06x   |
| 512   | 32     | pool4 reduce  | 2.17x   |

Interpretation:

- Width 2 loses hard; worker wake/join overhead dominates.
- Width 8 now wins at both measured block sizes after the atomic
  dispatch pass, with the strongest row at 512 frames.
- Width 32 wins at both block sizes, with the strongest result at
  512 frames.
- Reduction mode is roughly comparable for sink-free compute because this
  row measures reduction-mode plumbing only: `FreeCompute` has no sink
  slots to fold, so there is no contribution reduction work in the timed
  path.

Working crossover from the post-atomic run:

- Do not parallelize width 2.
- Treat width 8 as the first plausible synthetic sink-free threshold,
  still sensitive to block size, pool size, and DSP weight.
- Width 32 has enough independent compute work to amortize the current
  worker dispatch overhead.

### FreeSink

Direct mode behaves correctly: it serializes the sink Free band. The
direct pool rows are near the serial rows, with `serialized_sink_bands=1`.

Reduction-mode sink dispatch loses across the measured grid. The best
reduction rows stay below 1.0x; the large 32-voice / 512-frame case
reaches only about 0.93x after the atomic dispatch pass. Small cases
are much worse because the worker
wakeup plus contribution-buffer/fold path overwhelms the tiny sink
kernel.

Interpretation:

- Parallelizing sink-terminal work through reduction is not justified by
  current data.
- The reduction infrastructure is correct and test-covered, but it is
  not performance-positive for this class yet.

### SendReturn

Direct mode also serializes the sender sink band, as intended. Some small
direct rows show near-1.0 noise-level wins, but the counters confirm they
are not worker-dispatch wins.

Reduction-mode sender dispatch loses across the grid. The best measured
reduction rows are still below 1.0x, topping out around 0.92x in the
512-frame / 32-voice case.

Interpretation:

- The join-before-reader invariant is covered by tests, but the bench
  does not justify turning on reduction-backed send/return parallelism.
- This is evidence against starting Phase-D live-bus writer relaxation
  immediately.

## Overall interpretation

The post-atomic worker path has a useful but still narrow performance
envelope:

- Positive signal: sink-free compute Free bands with enough width and
  enough per-entry sample work.
- Negative signal: narrow bands, sink/reduction bands, and send/return
  bands.
- The atomic dispatch refresh moves the synthetic sink-free crossover
  lower than the original mutex/cv run, but it does not make
  sink-bearing reduction or send/return dispatch positive.

## Haskell-loaded post-atomic refresh

`stack exec -- metasonic-bridge --worker-bench` after the atomic
dispatch pass reported:

```text
cases=56  rows=224  worker_rows=112  worker_rows_with_parallel=2
parallel_bands=2  parallel_entries=6  serialized_sink_bands=0
best_worker_speedup=2.06x  best_parallel_worker_speedup=1.42x
```

Counter interpretation:

- The only counter-confirmed parallel row is still the targeted
  `corpus:sched/free-only-parallel-compute` probe.
- That row is now positive in the measured run:
  `sched-pool3-direct` reaches 1.42x and `sched-pool3-reduce`
  reaches 1.32x.
- Rows with `parallel_bands=0` remain serial-path variance, even when
  their speedup column is above 1.0x.
- The C1d region-layer candidate rows still do not enter C1c worker
  dispatch because C1c dispatches whole global schedule entries, not
  the independent regions inside one `FreeLayer` step.

The current implementation should stay gated. A future turn-on policy
would need at least:

- sink-free bands only,
- a minimum band width and/or block-size/DSP-cost threshold,
- no reduction-backed live-bus writer relaxation,
- more representative Haskell-loader corpus data before public exposure.
