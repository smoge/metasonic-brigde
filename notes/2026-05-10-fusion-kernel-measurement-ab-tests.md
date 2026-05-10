# Fusion Kernel Measurement A/B Tests

Date: 2026-05-10
Status: records completed Phase 4.B / 4.C measurement work.

This note documents the empirical results behind the hand-written
fusion kernels and fused-input A/B tests.

The short version is:

- The C++ microbench compares the same hand-built graph in two modes:
  `node-loop` and `fused`.

- The correctness tests compare the fused path against a stripped node-loop
  baseline, not against another graph that already carries the same kernel tag.

- Sink-terminal kernels are the stable win. They remove per-node dispatch and
  absorb bus accumulation plus `block_sink_peak` tracking.

- Buffer-terminal fusion is useful but weaker because the downstream consumer
  still needs a materialized buffer.


## What Was Measured

The benchmark entry-point is:

```sh
just cpp-bench
```

That configures `build-cpp-release/` as `RelWithDebInfo` with
`METASONIC_BUILD_TESTS=OFF`, builds `rt_graph_bench`, then runs it.
The benchmark lives in `tools/rt_graph_bench.cpp`.

For the Phase 4.B section, the harness builds each shape by hand
through the C ABI and registers the same region ranges in both modes:

- `node-loop`: every region is tagged `RegionKernel::NodeLoop`, so
  `process_instance` dispatches each member through `dispatch_node`.

- `fused`: the eligible range carries the matching `RegionKernel` tag,
  so `process_instance` calls the hand-written fused kernel directly.

That isolates kernel body cost from graph construction, Haskell lowering, and
region-overlay overhead. The nodes, controls, ranges, voice counts, and bus
setup are otherwise the same.

Measurement settings from the run below:

- CPU: `13th Gen Intel(R) Core(TM) i9-13900H`
- Hardware threads: `14`
- OS: `Linux 6.17.10-100 x86_64`
- Scheduler: `SCHED_OTHER`
- Sample rate: `48000`
- Warmup blocks: `64`
- Repeat runs: `5`
- Blocks: `64`, `128`, `512`
- Voice counts: `1`, `8`, `32`
- Reported value: median `ns/sample`
- Speedup: `node-loop ns/sample / fused ns/sample`

The harness drains the output bus into a volatile sink after rendering so the
compiler cannot delete the work. It also removes the auto-created instance
before spawning voices so the requested voice count is exact.

## Bench Shapes

The measured hand-written shapes are:

| Shape             | Kernel             | Class           | Details                                                                                       |
|-------------------|--------------------|-----------------|-----------------------------------------------------------------------------------------------|
| `SawLpfGain`      | `RSawLpfGain`      | buffer-terminal | `[SawOsc, LPF, Gain]`; trailing `Out` remains a separate node-loop region.                    |
| `SinGainOut`      | `RSinGainOut`      | sink-terminal   | `[SinOsc, Gain, Out]`; accumulates into bus and updates `block_sink_peak` inline.             |
| `SawLpfGainOut`   | `RSawLpfGainOut`   | sink-terminal   | `[SawOsc, LPF, Gain, Out]`; combines LPF state update with sink accumulation.                 |
| `BusInLpfGainOut` | `RBusInLpfGainOut` | sink-terminal   | `[BusIn, LPF, Gain, Out]`; bench reads unwritten bus; both paths filter zeros, same loop work |
| `NoiseLpfGainOut` | `RNoiseLpfGainOut` | sink-terminal   | `[NoiseGen, LPF, Gain, Out]`; both paths pull one PRNG sample per output sample.              |

`BusInLpfGainOut` is deliberately not a real-signal bench row. It
keeps the source bus valid but silent so the row isolates per-node
dispatch versus the fused loop. The real-signal behavior is pinned by
the A/B tests below.

The matrix does not currently include dedicated rows for `RSawGainOut`
or `RNoiseGainOut`. Those kernels are covered by structural and render
A/B tests, but not by this benchmark table.

## Current Bench Rows

Captured with `just cpp-bench` on 2026-05-10.

| Shape             | Block | Voices | Node-loop ns/sample | Fused ns/sample | Speedup |
|-------------------|------:|-------:|--------------------:|----------------:|--------:|
| `SawLpfGain`      |    64 |      1 |               13.66 |           11.80 |   1.16x |
| `SawLpfGain`      |   128 |      1 |               13.11 |           11.48 |   1.14x |
| `SawLpfGain`      |   512 |      1 |               12.56 |           11.19 |   1.12x |
| `SawLpfGain`      |    64 |      8 |               13.89 |           12.16 |   1.14x |
| `SawLpfGain`      |   128 |      8 |               13.68 |           12.03 |   1.14x |
| `SawLpfGain`      |   512 |      8 |                8.13 |            6.94 |   1.17x |
| `SawLpfGain`      |    64 |     32 |                8.74 |            7.27 |   1.20x |
| `SawLpfGain`      |   128 |     32 |                8.33 |            7.12 |   1.17x |
| `SawLpfGain`      |   512 |     32 |                8.17 |            7.09 |   1.15x |
| `SinGainOut`      |    64 |      1 |                2.48 |            1.38 |   1.80x |
| `SinGainOut`      |   128 |      1 |                2.14 |            1.18 |   1.81x |
| `SinGainOut`      |   512 |      1 |                1.89 |            1.00 |   1.89x |
| `SinGainOut`      |    64 |      8 |                2.38 |            1.96 |   1.22x |
| `SinGainOut`      |   128 |      8 |                2.74 |            1.33 |   2.07x |
| `SinGainOut`      |   512 |      8 |                2.32 |            1.15 |   2.02x |
| `SinGainOut`      |    64 |     32 |                2.79 |            1.38 |   2.02x |
| `SinGainOut`      |   128 |     32 |                2.42 |            1.23 |   1.97x |
| `SinGainOut`      |   512 |     32 |                2.16 |            1.25 |   1.73x |
| `SawLpfGainOut`   |    64 |      1 |               11.16 |            8.50 |   1.31x |
| `SawLpfGainOut`   |   128 |      1 |               10.79 |            8.04 |   1.34x |
| `SawLpfGainOut`   |   512 |      1 |                9.91 |            7.41 |   1.34x |
| `SawLpfGainOut`   |    64 |      8 |                9.70 |            7.08 |   1.37x |
| `SawLpfGainOut`   |   128 |      8 |                8.85 |            6.46 |   1.37x |
| `SawLpfGainOut`   |   512 |      8 |                8.11 |            6.34 |   1.28x |
| `SawLpfGainOut`   |    64 |     32 |                8.76 |            6.73 |   1.30x |
| `SawLpfGainOut`   |   128 |     32 |                8.29 |            6.38 |   1.30x |
| `SawLpfGainOut`   |   512 |     32 |                8.03 |            6.42 |   1.25x |
| `BusInLpfGainOut` |    64 |      1 |                8.47 |            7.01 |   1.21x |
| `BusInLpfGainOut` |   128 |      1 |                7.84 |            6.56 |   1.20x |
| `BusInLpfGainOut` |   512 |      1 |                7.61 |            6.28 |   1.21x |
| `BusInLpfGainOut` |    64 |      8 |                7.60 |            5.78 |   1.32x |
| `BusInLpfGainOut` |   128 |      8 |                7.31 |            5.92 |   1.23x |
| `BusInLpfGainOut` |   512 |      8 |                6.92 |            6.08 |   1.14x |
| `BusInLpfGainOut` |    64 |     32 |                7.63 |            6.02 |   1.27x |
| `BusInLpfGainOut` |   128 |     32 |                7.41 |            5.99 |   1.24x |
| `BusInLpfGainOut` |   512 |     32 |                7.10 |            5.87 |   1.21x |
| `NoiseLpfGainOut` |    64 |      1 |                7.86 |            6.31 |   1.25x |
| `NoiseLpfGainOut` |   128 |      1 |                7.59 |            6.18 |   1.23x |
| `NoiseLpfGainOut` |   512 |      1 |                7.36 |            6.21 |   1.19x |
| `NoiseLpfGainOut` |    64 |      8 |                7.85 |            6.18 |   1.27x |
| `NoiseLpfGainOut` |   128 |      8 |                8.00 |            6.46 |   1.24x |
| `NoiseLpfGainOut` |   512 |      8 |                7.72 |            6.31 |   1.22x |
| `NoiseLpfGainOut` |    64 |     32 |                8.21 |            6.44 |   1.27x |
| `NoiseLpfGainOut` |   128 |     32 |                7.97 |            6.35 |   1.25x |
| `NoiseLpfGainOut` |   512 |     32 |                7.68 |            6.39 |   1.20x |

Summary from this run:

| Shape             | Min speedup | Median speedup | Max speedup |
|-------------------|------------:|---------------:|------------:|
| `SawLpfGain`      |       1.12x |          1.15x |       1.20x |
| `SinGainOut`      |       1.22x |          1.89x |       2.07x |
| `SawLpfGainOut`   |       1.25x |          1.31x |       1.37x |
| `BusInLpfGainOut` |       1.14x |          1.21x |       1.32x |
| `NoiseLpfGainOut` |       1.19x |          1.24x |       1.27x |

The row pattern matches the decision we made earlier:

- `SinGainOut` is the strongest measured sink-terminal case.
- `SawLpfGainOut`, `BusInLpfGainOut`, and `NoiseLpfGainOut` sit in the
  sink-kernel win range.
- `SawLpfGain` still wins, but its value is less decisive because it
  cannot absorb the sink and the LPF dominates the loop cost.
- Block size has a small effect on the speedup ratio. Per-voice
  dispatch overhead dominates the win more than per-block overhead;
  voices=1 cells aren't systematically the fastest or slowest band.

## Run-to-Run Variance

The first version of this note recorded an earlier `just cpp-bench`
capture from the same day on the same laptop. That capture was real,
and most of its conclusions still hold. The qualitative ordering was
the same in both captures, and per-shape medians moved by no more than
`0.07x`:

| Shape             | Earlier median | Rerun median | Delta |
|-------------------|---------------:|-------------:|------:|
| `SawLpfGain`      |          1.22x |        1.15x | 0.07x |
| `SinGainOut`      |          1.92x |        1.89x | 0.03x |
| `SawLpfGainOut`   |          1.31x |        1.31x | 0.00x |
| `BusInLpfGainOut` |          1.23x |        1.21x | 0.02x |
| `NoiseLpfGainOut` |          1.26x |        1.24x | 0.02x |

The part that did not hold was the stronger interpretation of several
small-block / 1-voice peaks:

- `SawLpfGain` at `(block=64, voices=1)` reported `1.74x`.
- `SawLpfGainOut` at `(block=64, voices=1)` reported `1.82x`.
- `NoiseLpfGainOut` at `(block=64, voices=1)` reported `1.72x`.

The rerun table above brought those cells back into the surrounding
per-shape band. The table was rechecked by parsing all 45 rows:
each speedup rounds to `node-loop ns/sample / fused ns/sample`, and
the summary table matches the row min / median / max values.

I also checked for a code-change explanation. At the rerun point, the
tracked benchmark/runtime/test files had no uncommitted diff, including
`tools/rt_graph_bench.cpp`, `tinysynth/rt_graph.cpp`,
`tinysynth/rt_graph.h`, the Haskell compile/types/tests, `CMakeLists.txt`,
and `justfile`. `git log` showed no relevant tracked change between the
two note captures. The changed result should therefore be treated as
same-machine measurement variance plus an overconfident first
interpretation, not as new DSP or benchmark semantics.

Likely contributors to the variance:

- Both captures ran under `SCHED_OTHER` on the same `13th Gen Intel(R)
  Core(TM) i9-13900H` laptop, with no CPU pinning, scheduler priority
  bump, or thermal/frequency control.
- Each cell reports only the median of 5 repeats; the harness does not
  print spread, so a row can look cleaner than the underlying samples.
- Node-loop and fused timings are measured in separate graph builds and
  timed loops, so a brief scheduler or CPU-frequency perturbation can
  move one side of the ratio more than the other.
- The `(block=64, voices=1)` cells have the shortest absolute timed
  workload in the grid, so fixed overheads and host jitter have the
  largest relative effect there.
- The 64 warmup blocks at the smallest cell cover only about 4096
  sample frames. That may leave CPU frequency, cache state, and branch
  predictor state less settled than in the larger cells.
- The kernel side plausibly benefits more from hot instruction-cache
  state than the per-node dispatch path does, so a cold or interrupted
  small cell can briefly make the ratio look better than its steady
  value.

The decision-relevant signal is stable: sink-terminal kernels stay in a
winning band, `SinGainOut` remains the strongest measured sink case,
and `SawLpfGain` remains a weaker buffer-terminal win. Treat isolated
single-cell speedups outside the median band as suggestive rather than
load-bearing unless a future pinned bench records spread and repeats.

## Survey Gate Details

The benchmark was not the first filter. New stateful kernels were
gated by survey recurrence first:

- `RBusInLpfGainOut` was selected after `BusIn -> LPF -> Gain -> sink`
  appeared as 9 missed instances across 6 distinct send/return
  topologies.
- `RNoiseLpfGainOut` stayed parked while the signal was 3 misses
  across 3 graphs, then landed after corpus expansion promoted it to
  `missed=4, sources=4`.
- Tri-rooted, Pulse-rooted, and Add-rooted filtered tails stayed
  parked because each was a singleton-source signal.

The kernel-add gate that held up was:

1. The missed shape must recur across multiple sources in `--fusion-survey`.
2. The C++ bench must show a fused-vs-node-loop win in the sink-kernel band.
3. Stripped-baseline bit-equivalence must hold.
4. Stateful and invalid-input paths must match the per-node baseline.

## Structural Tests

The Haskell `selectRegionKernels` tests pin the compiler side before any FFI
render comparison:

- `[SawOsc, LPF, Gain, Out]` tags the whole 4-node region as
  `RSawLpfGainOut`; longest-match priority prevents the 3-node
  `RSawLpfGain` prefix from claiming first.
- `[SawOsc, LPF, Gain, BusOut]` also tags as `RSawLpfGainOut`; `Out` and
  `BusOut` are both sink terminals.
- `[SawOsc, LPF, Gain, Add, Out]` tags only the 3-node prefix as
  `RSawLpfGain`; the terminal consumer is not a sink.
- Audio-modulated `Gain`, multi-consumer `SawOsc`, and multi-consumer
  `LPF` block the saw-rooted kernels.
- `[SawOsc, Gain, Out]` and `[SawOsc, Gain, BusOut]` tag as `RSawGainOut`.
- `[NoiseGen, Gain, Out]` and `[NoiseGen, Gain, BusOut]` tag as
  `RNoiseGainOut`.
- `[BusIn, LPF, Gain, Out]` and `[BusIn, LPF, Gain, BusOut]` tag as
  `RBusInLpfGainOut`.
- Multi-consumer `BusIn`, audio-modulated `Gain`, and non-sink terminals block
  `RBusInLpfGainOut`.
- `[NoiseGen, LPF, Gain, Out]` and `[NoiseGen, LPF, Gain, BusOut]` tag as
  `RNoiseLpfGainOut`.
- Multi-consumer `NoiseGen`, multi-consumer `LPF`, audio-modulated
  `Gain`, and non-sink terminals block `RNoiseLpfGainOut`.
- `fuseRuntimeGraph` defers to claimed region kernels. The member
  `Gain` stays live instead of being elided by the scalar fused-input
  pass, preserving the control slot that the hand-written kernel
  reads.
- `selectRegionKernels` is idempotent.

These tests are structural, not performance measurements. They prevent
the bench and render tests from accidentally measuring a graph that no
longer claims the intended kernel.

## Render A/B Discipline

The critical test helper is `stripRegionKernels` in `test/Spec.hs`.
`compileRuntimeGraph` already runs region-kernel selection. Without
stripping, an "unfused" render of a matching graph would still
dispatch through the kernel, and a broken fused kernel could pass by
matching itself.

The honest A/B shape is:

1. Compile the baseline graph.
2. Replace every runtime region kernel tag with `RNodeLoop`.
3. Compile the fused graph through `compileRuntimeGraphFused`.
4. Assert the fused compile actually did something (`RFused`, `rnElided`, or a
   non-`RNodeLoop` region).
5. Render both paths through the FFI.
6. Compare every bus written by `Out` or `BusOut`, sample-for-sample.

The comparison is bit-strict. Approximate float comparison is not the contract,
because the fused bodies intentionally preserve the same operation order,
sanitization, and `float` casts as the per-node kernels.

## Named A/B Render Cases

The named A/B battery includes:

- `chain`: `SinOsc -> Gain -> Out`.
- Fanout: one `SinOsc` feeds two scalar `Gain` nodes that write different
  buses.
- `SawOsc -> LPF -> scalar Gain -> Out`.
- Sink-terminal `BusOut` variants for `SinOsc -> Gain`, `SawOsc -> LPF
  -> Gain`, `SawOsc -> Gain`, `NoiseGen -> Gain`, and `NoiseGen -> LPF
  -> Gain`.
- `BusIn -> LPF -> Gain -> Out` with an in-graph bus writer so the
  test uses a real signal, not silence.
- `BusIn -> LPF -> Gain -> BusOut`.
- `NoiseGen -> LPF -> Gain -> Out`.
- `NoiseGen -> LPF -> Gain -> BusOut`.
- Ring-mod case where the audio-modulated `Gain` stays dispatched but a later
  scalar output gain fuses.
- FM carrier case where a scalar gain fuses into the carrier frequency
  input and a scalar output gain fuses into `Out`.
- Scalar `Gain` chains of length 2 and 3, preserving source-to-sink
  scale order.
- Scalar `Add` bias on either port.
- Mixed affine chains: `Gain -> Add`, `Add -> Gain`, and `Gain -> Add
  -> Gain`.

The property test extends the same A/B contract to random deterministic
fusable graphs. It covers that fusion actually triggers in the generated
cases, strips region kernels from the baseline, renders 64 frames, and compares
all written buses.

## Kernel Control Identity Tests

The control-identity tests are A/B render tests with live control
writes after load:

- `RSinGainOut`: changes `sin.freq` to `330`, `gain.amount` to `0.3`,
  and `out.bus` to `2`; then compares the redirected bus against the
  stripped node-loop baseline. Peak sanity: about `0.3`.
- `RSawLpfGainOut`: changes `saw.freq` to `220`, `lpf.freq` to `1500`,
  `lpf.q` to `6`, `gain.amount` to `0.3`, and `out.bus` to `2`; then
  compares the redirected bus. Peak sanity: non-silent, `> 0.05`.
- `RBusInLpfGainOut`: builds two source writers, a 440 Hz sine on bus `5` and a
  220 Hz saw on bus `6`; changes `busin.bus` from `5` to `6`, `lpf.freq` to
  `1500`, `lpf.q` to `6`, `gain.amount` to `0.3`, and `out.bus` to `2`; then
  compares the redirected sink bus. This proves the fused kernel reads
  `busin.controls[0]` live each block.
- `RNoiseLpfGainOut`: changes `lpf.freq` to `1500`, `lpf.q` to `6`,
  `gain.amount` to `0.3`, and `out.bus` to `2`; then compares the redirected
  bus. This simultaneously pins fresh control reads, LPF block-rate latch
  parity, and PRNG cadence parity.

## Stateful Edge Case: Invalid BusIn

`RBusInLpfGainOut` had a load-bearing near miss: an invalid `busin.bus` must
not short-circuit the whole kernel.

The per-node baseline behaves like this:

1. `process_busin` fills the BusIn output buffer with zeros when the source bus
   is invalid.
2. `process_lpf` still runs over those zeros and advances IIR state.
3. `process_gain` and `process_out` still run over the LPF response.

The fused kernel must do the same. The regression test renders four blocks:

1. Valid bus, warming the LPF on a 220 Hz sine.
2. Valid bus again, continuing to warm state.
3. Invalid bus `-1`, which should filter zeros and advance state.
4. Valid bus again, where any state freeze from block 3 would surface.

Every block is compared against the stripped node-loop baseline.
Blocks 1 and 2 must also have peak `> 0.05`, proving the filter had
non-zero history before the invalid-bus block.

## Template Path A/B

The multi-template A/B test covers the real send/return path:

- Template `voice`: `SinOsc 440 -> BusOut 5`.
- Template `fx`: `BusIn 5 -> LPF 1500 4 -> Gain 0.6 -> Out 0`.
- The compiled `fx` template must claim `RBusInLpfGainOut`.
- The baseline strips kernels per template while keeping the same
  `TemplateGraph` shape.
- Both paths render through `loadTemplateGraph`.
- Bus `0` must be bit-identical and non-silent (`peak > 0.05`).

This is stronger than a single-graph approximation because it
exercises the same cross-template loader and shared bus pool that
motivated the kernel.

## Direct C++ Fused-Input A/B Tests

`tests/rt_graph_test.cpp` contains hand-written C ABI graphs for the
Step 4.C single-scale fused-input resolver:

- Unfused graph: `SinOsc(440) -> Gain(0.5) -> Out(0)`.
- Fused graph: the same nodes and direct connections, but node `1` (`Gain`) is
  marked elided and `Out` port `0` gets a fused scale input:
  `SinOsc.out0 * Gain.controls[0]`.
- The original direct `Gain -> Out` input is intentionally still
  present. The resolver must prefer the fused input when it exists.
- The unfused and fused samples are required to be bit-identical.

The direct C++ tests also cover:

- Changing the elided `Gain` control after fused wiring: scale `0.5`
  renders peak about `0.5`, scale `0.25` renders peak about `0.25`,
  and sample-wise ratio is `2:1` wherever the source is non-trivial.
- Recycled instance slots grow `fused_scratch` on reuse. Without that,
  a slot that became `Available` before fused inputs were registered
  would reuse an empty scratch buffer and render silence.
- Out-of-range fused refs are rejected as no-ops. Bad destination
  ports, source nodes, source ports, scale nodes, scale controls, and
  elided-node indexes must not create a stale fused override that
  mutes a valid direct input.

## Measurement Conclusions

The measurements justify keeping the current hand-written kernel layer
narrow:

- Sink-terminal kernels are real wins and map directly to common graph shapes.
- The win comes from removing dispatch and skipping intermediate
  buffers, but also from absorbing sink bookkeeping (`output_buses`
  write and `block_sink_peak`).
- Stateful producers and filters are safe only because the tests pin
  exact cadence and state advancement.
- The survey gate matters: it kept singleton filtered tails parked and
  let `RNoiseLpfGainOut` land only after recurrence plus benchmark
  evidence.
- Codegen is still not justified. The helper layer (`SinkAccumulator`,
  oscillator driver, and hand-written LPF latch code) has not become more
  expensive than the maintenance cost of a descriptor DSL.
