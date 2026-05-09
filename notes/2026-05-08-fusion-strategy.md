# Fusion Strategy Notes

Date: 2026-05-08

## Current Answer

Sink-terminal kernels are worth keeping and expanding.

The strongest observed fusion wins are shapes that absorb `Out` or `BusOut`
into the fused loop. They remove both an extra per-node dispatch and the
separate bus accumulation / `block_sink_peak` update.

Observed benchmark pattern:

- `SinGainOut`: strongest case, about 1.3x to 1.9x.
- `SawLpfGainOut`: still useful, about 1.3x.
- `SawLpfGain`: borderline and noisy because it does not absorb the sink and
  the biquad cost dominates.

Practical rule: prioritize sink-terminal fusion over buffer-terminal fusion.

## What To Fuse

Fuse short, contiguous, single-consumer chains where the fused kernel removes
dispatch and avoids unnecessary intermediate buffers.

Good candidates:

- Chains ending in `Out` or `BusOut`.
- Cheap DSP before the sink, where dispatch overhead is meaningful.
- Linear chains with single-use internal edges.
- Scalar controls, not audio-rate modulation.
- Shapes where the terminal sink can be absorbed into the kernel.

Concrete examples:

```text
SinOsc -> Gain -> Out/BusOut
SawOsc -> LPF -> Gain -> Out/BusOut
TriOsc/PulseOsc -> Gain -> Out/BusOut
Osc -> scalar shaping -> Out/BusOut
```

## What Not To Fuse Yet

Avoid subgraphs where the fused kernel would have to preserve externally visible
intermediate buffers or rebuild complex dynamic behavior.

Avoid for now:

- Nodes with multiple consumers, unless the kernel materializes the needed
  output buffer.
- Audio-modulated `Gain` in the current kernels.
- Non-contiguous chains.
- Chains crossing `BusIn` / `BusInDelayed` reads.
- Feedback paths.
- `Smooth`, which remains explicitly off-limits.
- Large arbitrary regions without a descriptor or codegen story.

Buffer-terminal fusion is only worth adding when it is common or enables a
larger sink-terminal fusion later.

## Expected Behavior On Complex Graphs

Complex graphs will likely show partial fusion, not whole-graph fusion.

Expected pattern:

- Linear demo chains should fuse well.
- Cross-template sends ending in `BusOut` should benefit from sink-terminal
  fusion.
- Additive synths can fuse independent branches if topo order keeps each branch
  contiguous.
- Fanout often blocks sink-terminal fusion because producer or gain consumer
  counts exceed one.
- Shared modulators block current gates when they increase `rnConsumerCount` or
  introduce audio-rate modulation.
- Larger regions may contain several eligible chains, but only contiguous
  subchains get claimed.

Important metric: how many hot sink-terminal branches were claimed, not whether
the whole graph fused.

## Parallelization Implications

Fusion should help a future region-level scheduler by producing coarser useful
work units:

```text
Graph -> runtime regions -> selected fused kernels -> future scheduler tasks
```

Positive:

- Fused sink-terminal regions become natural scheduler units.
- Independent branches can be scheduled across threads at the region/template
  level.
- Small linear chains should not be split across worker threads; fusing them is
  better than scheduling each node.

Tradeoffs:

- Fusion reduces internal parallelism inside a fused chain, but these chains are
  too small for useful intra-chain parallelism anyway.
- `Out` and `BusOut` write into shared bus pools. A parallel scheduler will need
  deterministic bus handling, likely per-thread or per-region accumulation
  buffers followed by a reduction.
- Fusion must preserve metadata about region dependencies and bus reads/writes.
  The scheduler will need that information even if the DSP body is fused.

Likely future rule: fuse small hot linear chains inside a region, then
parallelize across independent regions/templates.

### Empirical survey result (2026-05-08, §4.E.2c)

The `--fusion-survey` parallel-readiness section now reports per-graph and
cross-template schedule width for the current corpus. The picture:

- Intra-template region width is 1 across every surveyed graph. Region
  schedules are barrier-dominated by `Out` / `BusOut`; free segments
  collapse to single regions before a barrier. There is no useful
  intra-template region parallelism in the current corpus.
- Cross-template precedence width is non-trivial in send/return
  ensembles. Most multi-template demos and corpus ensembles measure
  template precedence width 2 (parallel voices feeding a shared fx,
  voice feeding parallel fx, stereo voice pairs). One or two land at
  width 1 (pure chain).

Important qualifier: template precedence width is candidate cross-template
surface area, not directly schedulable parallelism. Two templates at the
same precedence layer may still both write the same bus (no
read-after-write between them, but a write-write conflict on shared
state). A threaded runtime would have to either serialize those writers
or give each worker its own accumulation buffer and reduce
deterministically before the next barrier.

What this means for the roadmap:

- Region-level worker threads are not worth implementing yet. The
  surveyed corpus has nothing for them to do.
- If §4.E continues toward execution work later, the next design slice
  is template-level scheduling with a deterministic shared-bus policy,
  not region-level worker scheduling.
- Useful tangential work first: expand the corpus with realistic
  multi-voice / parallel-fx ensembles that could expose actual free
  region width; only add new region kernels when survey + bench
  justify them; consider static-bus annotations later if barrier
  regions prove too conservative.

## Filtered-Kernel Decisions (2026-05-08)

Recording each kernel-add decision so the rationale is preserved when
the survey signal moves on.

Validated, in-tree:

- `RBusInLpfGainOut` — `[KBusIn, KLPF, KGain, /sink/]`. Selected after
  `--fusion-survey` showed 9 missed instances across 6 distinct send/return
  topologies (3 multi-template ensembles + single-graph variants).
  Benchmark sits at 1.18x–1.67x, in the sink-kernel win range. The
  invalid-`busin.bus` path runs the LPF on zeros (matching `process_busin`
  + `process_lpf`'s zero-fill + state-advance behavior) rather than
  short-circuiting; freezing the IIR state on invalid bus diverged on the
  next valid block.

- `RNoiseLpfGainOut` — `[KNoiseGen, KLPF, KGain, /sink/]`. Unparked
  after the post-corpus-expansion ranked missed-shape table promoted
  the shape to `candidate` (`missed=4, sources=4`, in the proven
  sink-terminal family). Tri/Pulse/Add filtered tails stayed
  `no-signal` (singleton sources) and were not implemented. Benchmark
  lands at 1.13x–1.64x across the bench cells (median ~1.25x), in
  the sink-kernel win range. Strongest at small block sizes; expected
  shrink toward 1.13x at block=512 / voices=1, mirroring the BusIn
  shape. The PRNG-cadence parity with the per-node baseline (one
  `noisegen->noise()` call per output sample, in the same order
  `process_noisegen` would have used) is the load-bearing
  bit-equivalence pin.

Parked:

- Tri-rooted filtered tail (`[KTriOsc, KLPF, KGain, /sink/]`) —
  ranked-table `no-signal` at `missed=1, sources=1` after the
  shape-probe corpus added a single tri-rooted entry. Wait for either
  multi-source recurrence (more demos/corpus families using tri) or
  a real patch that motivates it.
- Pulse-rooted filtered tail (`[KPulseOsc, KLPF, KGain, /sink/]`) —
  same status as the tri variant: `missed=1, sources=1`,
  `no-signal/grow-corpus`. Pulse is also a less-validated DSP family
  in the existing kernel set (no `RPulseGainOut`), so a filtered-tail
  kernel here would land before its 3-node sibling.
- Add-rooted post-mix filtered tail (`[KAdd, KLPF, KGain, /sink/]`)
  — `missed=1, sources=1` from the single `shape/add-saw-noise-lpf-
  gain-out` probe. The classifier added `SinkAddLpfGain` so the
  shape is visible to the formal scan; corpus growth would need to
  produce additional Add-rooted patch families before the gate
  triggers.

Gate for future filtered kernels (updated 2026-05-08 after the
RNoiseLpfGainOut landing — the loop closed end-to-end and the
thresholds below held up):

1. The shape recurs across multiple distinct topologies in
   `--fusion-survey`'s ranked missed-shape table. Concrete threshold:
   `missed ≥ 3 ∧ sources ≥ 3`. The `sources` column counts distinct
   `srDemo` strings; multi-template ensembles count as one source
   even if several templates contribute the same shape. Three misses
   from one synthetic graph is weaker signal than three misses from
   three independent patch families.
2. The benchmark speedup lands in the sink-kernel win range across
   the bench cells, roughly 1.2x–1.9x. Smaller wins than
   `RSawLpfGainOut`'s ~1.3x deserve skepticism; the kernel pays
   ongoing maintenance cost forever. The cells most sensitive to
   per-block dispatch overhead (small block size) carry the
   strongest signal; large blocks with single voices produce the
   smallest speedups and shouldn't be the deciding cells.
3. Stripped-baseline bit-equivalence holds across structural
   variants (Out and BusOut sinks, control-write coverage, stateful-
   filter edge cases). For PRNG-state producers, the equivalence
   pin extends to PRNG cadence parity.
4. The kernel handles the same edge cases as the per-node baseline
   sample-for-sample, including invalid-input paths that nominally
   look like "no work this block." Skipping the loop on invalid
   input is almost always wrong because it desynchronizes stateful
   filters.

Empirical record of the loop (post-step-2 corpus expansion through
RNoiseLpfGainOut landing):

```text
corpus expansion → ranked table → kernel-add gate → benchmark → land
```

The loop produced a single justified kernel (`RNoiseLpfGainOut`)
and explicitly parked three plausible-but-unjustified shapes
(Tri/Pulse/Add). That's the discipline working as intended: a
kernel was added because the data justified it, not because the
next shape was mechanically easy.
