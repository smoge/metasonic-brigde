# Phase 7.H Block-Major Generated Executor Decision

Date: 2026-05-12

Status: decision artifact for the first 7.H slice. The slice
adds a **second** generated execution path to the C++ runtime:
the same v1 op set, the same `FusionProgram` ABI, the same
generator, but the per-sample dispatch loop swapped to a
per-op dispatch loop. The point is to test whether dispatch
overhead — not arithmetic — is what makes 7.G's amortization
curve trend the wrong way.

No runtime turn-on. No FFI / ABI changes beyond a small selector
flag. The current sample-major executor stays as the comparison
baseline; the block-major variant lives in the cost lab as
`VarGeneratedBlock`. The slice is an experiment, not a
replacement.

## Decision

A second `process_fusion_program_block` function in
[tinysynth/rt_graph.cpp](tinysynth/rt_graph.cpp) executes each
`FusionOp` once per block instead of once per sample. The op
loop is the outer loop; the inner loop scans samples. Each
non-sink op fills a per-program scratch buffer of size
`scratch_slots × nframes` rather than the current
`scratch_slots × 1`. The sink op then drains the last scratch
slot to the bus in one pass.

Construction-side `FusionProgram` ABI does not change — the same
`OpAdd` / `OpMul` / `OpSinkWrite` records the existing executor
already consumes. The new executor reads the same records, just
with a different loop nest.

Selection between the two executors is per-region: a region
that has a generated program also carries a one-byte (or
equivalent) selector indicating sample-major vs block-major
dispatch. On the cost-lab side, `VarGenerated` keeps using
sample-major; a new `VarGeneratedBlock` variant uses
block-major. The two variants share the same emitted programs
and the same equivalence machinery.

## Why Block-Major Now

Phase 7.G's amortization curve is monotonically downward:
generated speedup vs node-loop drops from ~0.79× at owned size
2 to ~0.25× at size 16. That shape is consistent with
**dispatch overhead scaling linearly with owned-op count**,
not with arithmetic dominating. Two reasons to test the
hypothesis:

1. The v1 interpreter's per-sample inner loop is exactly the
   thing node-loop avoids. Node-loop runs each compute kernel
   in a tight per-block loop, paying its dispatch cost once per
   block. The generated executor pays it once per sample. On
   short tails the per-sample dispatch is barely visible; on
   long tails the difference adds up.
2. Block-major changes nothing about the op set, the generator,
   the ABI, or the program data. It is the cheapest A/B test
   the architecture supports. If it doesn't help, the next
   experiment (superinstructions, packed instruction stream,
   native codegen) is much more invasive — and 7.H's evidence
   tells us where to focus.

Neither runtime turn-on nor wider shape coverage helps until
this question is answered. A `PreferGenerated` row on the
existing executor would just mean "this synthetic ran fast
during one bench run"; pinning that would chase noise. Adding
oscillator / filter / state ops to an executor that already
loses on pure arithmetic adds lifecycle complexity to a slow
hot path.

## Block-Major Dispatch Sketch

Pseudo-code, ignoring bounds checks:

```text
process_fusion_program_block(g, inst, program, nframes,
                              writer_slot, mode):
  scratch[scratch_slots][nframes]  // per-program, block-sized
  for op in program.ops:
    if op is OpAdd / OpMul / OpLoadConst / OpLoadInput:
      for s in 0 .. nframes:
        scratch[op.dst][s] = compute_op_at_sample(s, op,
                                                  scratch, inst)
    elif op is OpSinkWrite:
      sink = SinkAccumulator::open(g, inst, op.dst,
                                   writer_slot, nframes, mode)
      for s in 0 .. nframes:
        sink.push(s, read_source(op.src1, scratch, inst, s))
      sink.flush_to(inst)
```

The non-sink op loop is the per-sample work the current
executor already performs; only the loop order changes. Sink
writes drain the last scratch slot to the bus in one pass and
keep the existing `SinkAccumulator` lifecycle.

## Scratch Sizing

The current executor allocates `kMaxScratchSlots = 64` floats
on the stack per call. Block-major needs
`kMaxScratchSlots × nframes`. At the default `kBlockFrames`
the cost lab uses today (64 frames) this is 64 × 64 = 4096
floats = 16 KiB on the stack. At 256 frames it would be 64 KiB
— still fine on a desktop thread but already near the limit on
realtime-audio stack sizes (Linux 8 KiB default for realtime
threads can be tighter).

v1 picks the pragmatic answer: **stack-allocate
`scratch[kMaxScratchSlots][kMaxBlockFrames]` with
`kMaxBlockFrames = 256`**. Programs called with
`nframes > kMaxBlockFrames` silent-fall-through to the existing
sample-major executor (or no-op, matching the existing
`scratch_slots > kMaxScratchSlots` policy). The cost lab runs
at 64 frames so it always exercises the block-major path; a
future audio caller with longer blocks would either chunk or
fall through.

A future slice can revisit the buffer source (thread-local
heap, world-scoped pool, per-template buffer) if either bound
becomes a real constraint. v1 keeps it boring: fixed bound,
fall-through above it.

## Selection Mechanism

Construction-side ABI gains a small selector — either an extra
`int` on the program record (`executor_kind`: 0 = sample-major,
1 = block-major) or a parallel `executor` field on
`RegionSpec`. The Haskell side picks the selector per region
via a new constructor on `RegionExec`:

```text
RegionExec
  = ExecNodeLoop
  | ExecKernel    RegionKernel
  | ExecGenerated FusionProgramId
  | ExecGeneratedBlock FusionProgramId  -- new in 7.H
```

The new constructor is intentionally a sibling, not a payload
on the existing one. Sample-major and block-major dispatch
through different functions on the C++ side; the selector
should encode that structurally so a future executor (e.g.
superinstructions) is a third sibling rather than a hidden
flag.

`compileRuntimeGraph` continues to emit `ExecNodeLoop` /
`ExecKernel`; no graph emits `ExecGeneratedBlock` outside the
cost lab in this slice. The cost-lab's `loadForVariant` builds
the executor-block region patch for `VarGeneratedBlock` rows
the same way it builds the sample-major patch for `VarGenerated`
rows today.

## v1 Op Set Stays Frozen

No new ops in this slice. The block-major executor reads the
same `OpLoadConst` / `OpLoadInput` / `OpAdd` / `OpMul` /
`OpSinkWrite` the sample-major executor does. The generator
emits the same program for both variants. The only thing that
changes is which C++ function consumes the record.

This is deliberate: 7.H tests *dispatch model*, holding op set
and generator constant. Mixing in superinstructions or native
codegen would confound the result.

## Hard Exclusions

- **No runtime emission.** No production graph picks
  `ExecGeneratedBlock`. Cost-lab and snapshot only.
- **No new node kinds in the interpreter.** v1 op set frozen.
- **No stateful owned nodes.** Oscillators, filters, env,
  delay, smooth still excluded — same as 7.G.
- **No §4.B kernel replacement.** Hand-written kernels stay
  the path of record for matched shapes.
- **No `PreferGenerated` pin movement.** Block-major may
  produce the first non-noise `PreferGenerated` row; if so,
  the existing 7.F tripwire surfaces it for human review. The
  slice does not authorize a turn-on.
- **No CLI knob to switch live audio between executors.** The
  selector is internal to the cost lab in v1.
- **No replacement of the sample-major executor.** Both paths
  ship; the A/B is the evidence.

## What Block-Major Probably Costs

A non-obvious cost: scratch grows from
`kMaxScratchSlots` floats (256 B) to
`kMaxScratchSlots × kMaxBlockFrames` floats (~64 KiB at the
proposed bound). Stack pressure is real on realtime threads.
The cost-lab harness runs with default thread stacks, so it
won't see the issue, but anyone who later tries to wire
block-major into the audio thread needs to revisit the buffer
strategy first.

Bench noise: each op's inner loop has tighter cache behavior
than the sample-major version (scratch slot for op K is
contiguous over the block), so even at low owned-op counts the
block-major variant may flap by a few percent against
sample-major. This is the same bench-noise discipline 7.E /
7.F / 7.G use — pin structural counts only, surface speedups
in diagnostics only.

## Verification Target

Slice is done when:

- the block-major executor exists and equivalence-tests
  bit-exact against `RNodeLoop` on at least:
  `Gain → Out`, `Add → Gain → Out`, and one
  `generated-tail-sweep` member (e.g. `tail-8-mixed`);
- `--fusion-cost-lab` reports a `generated-block` variant
  alongside `generated` for every cost-lab member;
- the per-owned-op-size diagnostic compares the two variants
  side-by-side, isolated on `generated-tail-sweep`;
- snapshot pins lock the new variant's structural counts
  (row count, emitted, unsupported = 0, non-exact = 0,
  tail-sweep emitted = 6, tail-sweep exact);
- nothing in the runtime turn-on path or planner policy
  changes.

The answer the slice produces is the amortization curve for
the block-major executor. If it bends upward (slope flatter
or reverses), 7.H is evidence that dispatch model is the
bottleneck and the next slice tightens block-major further. If
it stays monotonically downward, dispatch model is not the
bottleneck either — the next experiment shifts to
superinstructions or packed native kernels per op.

## Snapshot Pins

Pinned (deterministic):

- new cost-lab variant row count
  (= corpus size × 1 = 28 generated-block rows today, mirroring
  generated-considered);
- generated-block emitted count;
- generated-block unsupported count
  (should equal generated-unsupported by construction;
  whichever executor the row routes through, the generator
  produces the same program);
- generated-block non-exact count (= 0; correctness tripwire);
- generated-tail-sweep generated-block emitted (= 6);
- generated-tail-sweep generated-block non-exact (= 0).

Intentionally **not pinned**:

- per-bucket speedups under any variant;
- delta between sample-major and block-major executors;
- win/loss split.

All of those flap with bench noise. The slice's value is the
diagnostic delta the cost-lab prints, not a numeric pin on it.

## Open Questions Deferred

- **Live-audio turn-on.** Until the slice produces a
  consistently-faster block-major row on a real shape, the
  loader does not gain a knob to pick block-major at runtime.
- **Buffer source.** Stack-allocated scratch survives v1 by
  bounding `kMaxBlockFrames`. A real audio integration would
  want a thread-local or instance-scoped buffer; deferred.
- **Superinstructions / packed native kernels.** If
  block-major also loses on long tails, the next slice picks
  one of these two. 7.H is the gate that decides which.
- **Removing the sample-major executor.** Once a faster path
  is proven, the slower one becomes a regression target. v1
  ships both forever; a future slice may collapse them.
- **Mixed executor regions.** A single graph could in
  principle have one region using sample-major and another
  using block-major. The cost-lab keeps it one-or-the-other
  per row; multi-region mixing is out of scope.
