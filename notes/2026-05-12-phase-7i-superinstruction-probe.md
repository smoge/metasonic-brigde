# Phase 7.I Superinstruction Probe Decision

Date: 2026-05-12

Status: decision artifact for the first 7.I slice. The slice
adds a **third** generated execution path to the C++ runtime:
the same v1 op set, the same `FusionProgram` ABI, the same
generator, but the per-op interpreter swapped for a per-shape
recognizer that runs matched sequences as one tight C++ branch
and falls through to the block-major executor when no shape
matches. The point is to test whether a generated path can
become competitive with node-loop when the common tail is
executed without per-op dispatch at all.

No runtime turn-on. No FFI / ABI changes beyond a third
selector value. The sample-major and block-major executors stay
side-by-side as comparison baselines; the new variant lives in
the cost lab as `VarGeneratedSuper`. The slice is an
experiment, not a replacement.

## Decision

A third `process_fusion_program_super` function in
[tinysynth/rt_graph.cpp](tinysynth/rt_graph.cpp) inspects the
`FusionProgram`'s op sequence and dispatches to a recognized
shape kernel when one matches, otherwise calls into
`process_fusion_program_block`. The first two recognizers:

- **`GainOut`** — `OpMul scratch0 <a> <b>` followed by
  `OpSinkWrite bus (SrcScratch scratch0)`. Fused into a
  per-sample multiply-and-accumulate over the bus.
- **`AddGainOut`** — `OpAdd scratch0 <a> <b>`,
  `OpMul scratch1 (SrcScratch scratch0) <c>`,
  `OpSinkWrite bus (SrcScratch scratch1)`. Fused into a
  per-sample add-multiply-accumulate over the bus.

Construction-side `FusionProgram` ABI does not change — the
same `OpAdd` / `OpMul` / `OpSinkWrite` records the existing
executors already consume. The new executor reads the same
records, just matches their *shape* before executing.

Selection is per-region: the existing `generated_executor`
field on `RegionSpec` gains a third value `2 = super`. On the
cost-lab side, `VarGenerated` keeps using sample-major,
`VarGeneratedBlock` keeps using block-major, and the new
`VarGeneratedSuper` uses super-then-fallback dispatch. All
three variants share the same emitted programs and the same
equivalence machinery.

## Why Superinstructions Now

Phase 7.H's amortization curve is encouraging but
insufficient: block-major crosses ahead of sample-major at
owned size 4-5 and reaches `~0.41×` of node-loop at size 16.
Block-major is roughly 2.6× away from `measuredWinThreshold`
(`1.05×`). The dispatch model is *a* cost; it is not the only
one.

The next sharper question — can a generated path beat
node-loop at all? — needs an executor that pays as close to
zero dispatch as the FusionProgram ABI permits. A recognized
`GainOut` is a single C++ loop with one multiply, one bus
write per sample, and no scratch indirection. That is
essentially what a hand-written kernel does. If the
recognized path still loses to node-loop, the FusionProgram
ABI itself — not the dispatch loop — is the bottleneck, and
the next slice has to pivot (packed instruction stream,
native codegen, ABI redesign).

Two reasons to test this hypothesis before more invasive
changes:

1. Block-major already mostly removed per-sample dispatch
   *between* ops within a block. Superinstructions remove
   dispatch *between* recognized shapes entirely. They are
   the smallest remaining change that could plausibly close
   the gap.
2. The cost-lab corpus already contains the shapes that
   should benefit most: the `Gain → Out` and
   `Add → Gain → Out` tails dominate `generated-tail-sweep`
   and `add-chain`. We can measure on shapes that already
   exist in the corpus rather than hand-curating new
   benchmarks.

Neither runtime turn-on nor packed instructions help until
this question is answered. Packed instructions are an ABI
change; they should be justified by evidence about which
costs dominate. Adding stateful owned nodes (oscillator,
filter, env) widens the surface but does not change the
arithmetic-tail loss 7.G / 7.H demonstrated.

## Recognizer Sketch

Pseudo-code, ignoring bounds checks:

```text
process_fusion_program_super(g, inst, program, nframes,
                              writer_slot, mode):
  if program matches GainOut shape:
    a, b, bus = extract GainOut operands
    sink = SinkAccumulator::open(g, inst, bus,
                                 writer_slot, nframes, mode)
    for s in 0 .. nframes:
      sink.push(s, read(a, s) * read(b, s))
    sink.flush_to(inst)
    return
  if program matches AddGainOut shape:
    a, b, c, bus = extract AddGainOut operands
    sink = SinkAccumulator::open(g, inst, bus,
                                 writer_slot, nframes, mode)
    for s in 0 .. nframes:
      sink.push(s, (read(a, s) + read(b, s)) * read(c, s))
    sink.flush_to(inst)
    return
  // Fallback: not a recognized shape
  process_fusion_program_block(g, inst, program, nframes,
                                writer_slot, mode)
```

The recognizer runs at most O(small constant) ops to decide
matching, then the matched kernel executes the per-sample
work without scratch indirection. The fallback path is
identical to block-major.

## v1 Recognizer Set

Only two shapes recognized in v1:

1. `GainOut`: `[OpMul dst _ _, OpSinkWrite bus (SrcScratch dst)]`
   with `dst == 0` and program `scratch_slots == 1`.
2. `AddGainOut`: `[OpAdd dst0 _ _, OpMul dst1 (SrcScratch dst0) _, OpSinkWrite bus (SrcScratch dst1)]`
   with `dst0 == 0`, `dst1 == 1`, and program `scratch_slots == 2`.

Both shapes correspond to fusion outputs the generator
already emits today. Both end in `OpSinkWrite`; both have a
single accumulating sink (the existing
`SinkAccumulator::open` lifecycle is unchanged).

Longer recognized shapes (`MulAddOut`,
`AddGainAddGainOut`, etc.) are deliberately out of scope.
They are easy to add once the v1 probe reports a number; if
v1 reports a loss, longer shapes will not save it.

## Selection Mechanism

The existing `generated_executor` field on `RegionSpec` adds
a third value:

```text
generated_executor:
  0 = sample-major   (Phase 7.D)
  1 = block-major    (Phase 7.H)
  2 = super          (Phase 7.I, this slice)
```

`process_region` already routes on this field; the slice
adds one more branch. Haskell `RegionExec` gains a fourth
sibling constructor `ExecGeneratedSuper !FusionProgramId`.
The cost lab gains `VarGeneratedSuper` and a
`retargetGeneratedAsSuper` helper that flips
`ExecGenerated → ExecGeneratedSuper`, mirroring the existing
`retargetGeneratedAsBlock` from 7.H.

`compileRuntimeGraph` continues to emit `ExecNodeLoop` /
`ExecKernel`; no production graph emits
`ExecGeneratedSuper` outside the cost lab in this slice.

## Hard Exclusions

- **No runtime emission.** No production graph picks
  `ExecGeneratedSuper`. Cost-lab and snapshot only.
- **No new ops.** v1 op set still frozen.
- **No new shape recognizers beyond `GainOut` and
  `AddGainOut`.** Longer shapes deferred until v1 reports
  whether the approach works at all.
- **No stateful owned nodes.** Same as 7.G / 7.H.
- **No §4.B kernel replacement.** Hand-written kernels stay
  the path of record for matched shapes.
- **No `PreferGenerated` pin movement.** Super-mode may
  produce the first non-noise win; if so, the diagnostics
  surface it for human review. The slice does not authorize
  a turn-on.
- **No CLI knob to switch live audio between executors.** The
  selector is internal to the cost lab in v1.
- **No replacement of the sample-major or block-major
  executors.** All three paths ship; the A/B/C is the
  evidence.

## What Super-Mode Probably Costs

A non-obvious cost: the recognizer adds a per-region branch
even for programs that do not match. The fallback path
re-enters the block-major executor, paying one extra
function call and one shape-mismatch decision per block.
At long owned sizes, that overhead is negligible relative to
the per-sample work; at very short non-matching programs
it could be visible. The cost-lab will surface this.

Recognizer correctness: shape recognition reads structural
fields (`op.kind`, `op.dst`, `op.src.kind`, `op.src.idx_a`)
and rejects on the first mismatch. The first miss
guarantees the fallback runs the exact same program the
block-major executor would have. The equivalence test
covers both the matched and fallback paths.

## Verification Target

Slice is done when:

- the super-mode executor exists and equivalence-tests
  bit-exact against `RNodeLoop` on at least:
  `Gain → Out` (recognized), `Add → Gain → Out`
  (recognized), and one longer `generated-tail-sweep` member
  (fallback path);
- `--fusion-cost-lab` reports a `generated-super` variant
  alongside `generated` and `generated-block` for every
  cost-lab member;
- the per-owned-op-size diagnostic compares all three
  variants side-by-side on `generated-tail-sweep`, with
  recognized vs fallback counts visible;
- snapshot pins lock the new variant's structural counts
  (row count, emitted, unsupported = 0, non-exact = 0,
  recognized count, fallback count);
- nothing in the runtime turn-on path or planner policy
  changes.

The answer the slice produces is **whether super-mode crosses
above `1.0×` against node-loop on recognized shapes**. The
three possible outcomes:

1. **Still below `1.0×`.** Generic generated fusion does not
   beat node-loop for arithmetic tails even with dispatch
   removed. The next slice pivots away from the
   FusionProgram interpreter approach (packed native
   kernels, or generated fusion is parked entirely).
2. **Above `1.0×` but below hand kernels.** Super-mode is a
   middle path between node-loop and hand-written kernels.
   Keep it read-only; future slices may extend the
   recognizer set or pin a `PreferGenerated` row only on
   recognized shapes.
3. **Stable non-kernel `PreferGenerated` rows.** Super-mode
   produces the first measured win against node-loop on
   shapes that have no §4.B kernel today. The next slice
   wires the gate to consume `VarGeneratedSuper`.

## Snapshot Pins

Pinned (deterministic):

- new cost-lab variant row count (= corpus size, mirroring
  the other generated variants);
- generated-super emitted count;
- generated-super unsupported count
  (should equal generated-unsupported by construction);
- generated-super non-exact count (= 0; correctness
  tripwire);
- generated-super recognized count (deterministic: depends
  only on the generator output);
- generated-super fallback count (= emitted - recognized);
- generated-tail-sweep generated-super emitted (= 6);
- generated-tail-sweep generated-super non-exact (= 0).

Intentionally **not pinned**:

- per-bucket speedups under any variant;
- delta between sample-major, block-major, and super-mode;
- win/loss split.

All of those flap with bench noise. The slice's value is the
diagnostic delta the cost-lab prints, not a numeric pin on
it.

## Open Questions Deferred

- **Longer recognized shapes.** `MulAddOut`,
  `AddGainAddGainOut`, and longer tails are deferred until
  v1 reports whether `GainOut` / `AddGainOut` can win at all.
- **Packed instruction stream.** Reducing per-op decode
  overhead by laying out `FusionOp` records contiguously is
  orthogonal to superinstructions. If 7.I shows the
  interpreter loop body is the bottleneck (not dispatch),
  packed instructions become the next slice.
- **Native codegen.** LLVM/cranelift codegen is the most
  invasive option. 7.I is the gate that decides whether the
  evidence justifies it.
- **Runtime turn-on.** Until the slice produces a
  consistently-faster super-mode row on a real shape, the
  loader does not gain a knob to pick super-mode at runtime.
- **Stateful recognizers.** Once oscillator / filter / env
  nodes enter the v1 op set (deferred from 7.H), the
  recognizer set widens to `SinGainOut`, `SawLpfGainOut`,
  etc. Those overlap with existing §4.B hand kernels; the
  scope decision happens then.
- **Mixed executor regions.** A single graph could in
  principle have one region using sample-major and another
  using super-mode. The cost-lab keeps it one-or-the-other
  per row; multi-region mixing is out of scope.
