# Fusion Kernel Lessons

Date: 2026-05-08

This note records the practical decisions from the region-kernel work so the
next pass does not have to reconstruct them from commit history and review
threads.

## Current Position

Region fusion is worth continuing, but only where the survey and benchmarks
both justify the maintenance cost.

The strongest class is sink-terminal fusion: short linear chains ending in
`Out` or `BusOut`. These kernels remove per-node dispatch, skip intermediate
buffer traffic, and absorb bus accumulation plus `block_sink_peak` updates into
one loop.

Validated kernels:

- `RSinGainOut`
- `RSawGainOut`
- `RNoiseGainOut`
- `RSawLpfGainOut`
- `RBusInLpfGainOut`

Useful but less decisive:

- `RSawLpfGain`, because it is buffer-terminal and still has to materialize the
  gain output for downstream consumers.

Parked:

- `RNoiseLpfGainOut`, until the noise-rooted filtered-tail signal grows in real
  patches or corpus surveys.

## Evidence Threshold

A new stateful region kernel should clear both bars:

1. Survey recurrence: the missed shape appears repeatedly across realistic
   graphs, not only as a hand-authored fixture.
2. Runtime value: the benchmark shows a real fused-vs-node-loop win, not just
   bit-equivalence.

`RBusInLpfGainOut` cleared this bar:

- Survey before kernel: `BusIn -> LPF -> Gain -> sink` had 9 misses.
- Survey after kernel: all 9 were claimed, 0 missed.
- Corpus region-kernel coverage rose to roughly 67%.
- Benchmark: about 1.18x to 1.67x fused-vs-node-loop speedup, comparable to or
  better than the existing 4-node sink kernel band.
- Template path: the kernel is semantically aligned with cross-template
  send/return tails.

`RNoiseLpfGainOut` has not cleared the same bar:

- `Noise -> LPF -> Gain -> sink` remains at 3 missed cases.
- That is useful signal, but not enough to add another stateful-filter kernel
  while the real patch surface is still small.

## What To Fuse

Prefer:

- Contiguous chains.
- Single-use internal edges.
- Scalar gain controls.
- Sink terminals: `Out` or `BusOut`.
- Shapes that remove both dispatch and materialization.
- Shapes found by the survey in real or realistic graph topologies.

Good examples:

```text
SinOsc  -> Gain -> Out/BusOut
SawOsc  -> Gain -> Out/BusOut
Noise   -> Gain -> Out/BusOut
SawOsc  -> LPF  -> Gain -> Out/BusOut
BusIn   -> LPF  -> Gain -> Out/BusOut
```

Avoid for now:

- Audio-modulated `Gain` in region kernels.
- Multi-consumer producers or intermediates, unless the kernel explicitly
  materializes the externally visible buffer.
- Non-contiguous chains.
- Feedback paths.
- `Smooth`.
- Arbitrary large regions without a stronger descriptor, scheduling, or codegen
  story.

## Survey Discipline

The survey is now a decision tool, not just a diagnostic printout.

Keep these distinctions explicit:

- Shape probes versus real ensemble topologies.
- Noise-rooted filtered tails versus BusIn-rooted return tails.
- Sink-terminal candidates that have a kernel versus candidates that are still
  missed.
- Claimed branches, not whole-graph fusion percentage, as the most meaningful
  metric.

Do not merge different roots into one decision. The BusIn return-tail signal
and the Noise filtered-tail signal are separate families.

## Correctness Lessons

Use a stripped node-loop baseline whenever testing a region kernel. Comparing
two graphs that both carry the same region tag can let a broken fused kernel
match itself.

Stateful filters make "silence" paths non-trivial. For example, an invalid
`BusIn` source bus is not equivalent to skipping the region. The node-loop path
fills the BusIn output with zeros, then the LPF still advances its state over
those zeros. A fused kernel must do the same or it will diverge after any block
where the filter has non-zero history.

Control-identity tests must actually change the relevant control. For
`RBusInLpfGainOut`, that means:

- `busin.bus`
- `lpf.freq`
- `lpf.q`
- `gain.amount`
- output sink bus

For BusIn kernels, include both:

- a valid redirect to a different source bus, and
- a valid-silent or invalid source case after warming the filter state.

Template end-to-end coverage matters for BusIn-rooted kernels because their
real use case is cross-template routing.

## Abstraction Boundary

Full kernel codegen is still not justified.

The useful abstraction layer is narrow C++ helpers:

- `SinkAccumulator` for sink-terminal accumulation and peak tracking.
- `drive_oscillator` for oscillator producer loops.

The DSP body should stay hand-written until duplication becomes materially
worse. Five-plus kernels have not yet forced a descriptor DSL.

## Parallelization Implications

Fusion should cooperate with later parallel scheduling rather than fight it.

Expected future shape:

```text
Graph -> runtime regions -> selected fused kernels -> scheduler tasks
```

Rules to preserve:

- Fuse small hot linear chains inside a region.
- Parallelize across independent regions/templates, not within tiny chains.
- Preserve region dependency and bus read/write metadata; a scheduler will need
  it even when the region body is fused.
- Be careful with `Out` and `BusOut`: parallel execution likely needs
  deterministic per-thread or per-region bus accumulation followed by a
  reduction.

The §4.E.2c parallel-readiness survey (2026-05-08) sharpened this: across
the current corpus, intra-template region schedules show width 1 (barrier
dominated by `Out` / `BusOut`), and cross-template precedence width
reaches 2 in most send/return ensembles. The cross-template width is
/candidate/ parallelism, not directly schedulable — same-layer templates
can still write the same bus and would need either serialization or
per-worker accumulation with deterministic reduction. The empirical
takeaway: region-level worker threads are not worth implementing yet; if
§4.E continues later, the next design slice is template-level scheduling
with a deterministic shared-bus policy.

## Comment Policy

Do not broadly prune comments yet. The fusion layer is still young, and the
long comments are mostly carrying invariants, ABI contracts, and equivalence
arguments.

Trim or move comments only when:

- they are stale,
- they repeat nearby code without adding an invariant, or
- they are strategy/history that belongs in `notes/`.

Use American English spelling in new comments and notes.

## Recommended Next Moves

1. ~~Finish hardening `RBusInLpfGainOut` around zero/invalid source-bus
   behavior and the related control-identity tests, if that is not already
   committed.~~ Done.
2. ~~Update `notes/2026-05-08-fusion-strategy.md` to reflect the validated BusIn
   filtered kernel and the parked Noise filtered kernel.~~ Done; updated
   again at the `RNoiseLpfGainOut` landing to record the unparking and
   the new parked entries (Tri/Pulse/Add filtered tails).
3. ~~Keep `RNoiseLpfGainOut` parked until survey recurrence grows.~~
   Done: corpus expansion put the shape at `missed=4, sources=4` in the
   ranked missed-shape table, the kernel-add gate from
   `notes/2026-05-08-fusion-strategy.md` triggered, and the kernel landed with
   benchmark median ~1.25x. Tri/Pulse/Add filtered tails stayed
   singleton-source and remain parked.
4. Avoid a broad codegen pivot until another few kernels make the helper
   layer visibly insufficient. (Still active: the helper-layer cost has
   not yet outgrown hand-written bodies after the
   `RNoiseLpfGainOut` landing.)
5. The corpus-first → ranked-table → gate → benchmark loop is now
   evidence-complete. Don't add another kernel on speculation; wait
   for either real patch families or a different roadmap area to
   produce the next signal.
