# Fusion Kernel State And Reopen Criteria

Date: 2026-05-21

Status: documentation snapshot and future-reference note. This note
does **not** propose an immediate implementation slice. It records the
current fusion state and sketches one candidate shape for a future
reopening, so a future session can reopen the work from evidence
instead of from the vague feeling that "generated fusion exists, so we
should turn it on."

The short version:

- Hand-written region kernels are the proven production optimization.
- `RFused` scalar affine rewrites are real and integrated.
- Generated fusion is implemented as measurement / executor
  infrastructure, but remains read-only as an optimization policy.
- The next active development pressure should still come from Phase 8
  live-session / authoring workflow, not from more generated-fusion
  executor work.


## Why This Note Exists

The fusion story now spans a lot of artifacts:

- early strategy and lessons notes;
- the Phase 4.B / 4.C measurement note;
- `selectRegionKernels`;
- `RFused`;
- the Phase 7 generated-fusion plan;
- the fusion cost lab;
- the planner / cost-model join;
- the generated-program ABI;
- sample-major, block-major, and super-mode generated executors;
- the read-only profitability gate;
- the Phase 7.J gate closeout.

That is enough surface area that a future reader can easily mistake one
of these statements for another:

- "the generated executor exists";
- "generated output is bit-exact";
- "generated output is sometimes faster than node-loop";
- "the gate would choose generated for real graphs";
- "the runtime should turn generated fusion on."

Only the first three are true today, and only in narrow cases. The last
two are not true on the full survey corpus.

This note is the compact restart point: it says what is production,
what is diagnostic, what data was observed on 2026-05-21, and what
would have to change before generated fusion becomes an implementation
lane again.


## Vocabulary

`node-loop`

: The stripped baseline. Each runtime region executes nodes one by one.
  In the cost lab, this must mean "region kernels stripped back to
  `RNodeLoop`", not merely "compile with the normal compiler", because
  `compileRuntimeGraph` already selects §4.B kernels.

`region-kernel`

: A hand-written C++ fused body selected by `selectRegionKernels`. This
  is the current production fusion path.

`RFused`

: A compile-time input rewrite. A scalar producer such as a constant
  `Gain` or scalar `Add` can be elided into a consumer input as an
  `RFused` descriptor while the elided node remains addressable for
  controls and identity.

`generated fusion`

: A generated `FusionProgram`: a small op list loaded into a runtime
  program table and referenced by a region executor (`ExecGenerated`,
  `ExecGeneratedBlock`, or `ExecGeneratedSuper`).

`sample-major generated`

: The first generated executor. It interprets the generated program per
  sample.

`block-major generated`

: The same generated program, but dispatched with a block-major
  executor. It reduces some per-op dispatch overhead but still loses to
  existing paths on the current corpus.

`super-mode generated`

: The same generated program, but with a recognizer for very short
  fused shapes (`GainOut`, `AddGainOut`) that dispatches to a tight C++
  path and falls back to block-major for everything else.

`profitability gate`

: The read-only verdict function in
  `MetaSonic.App.ProfitabilityGate`. It decides whether generated
  should be preferred for a shape from measured evidence. Today no
  runtime path consumes that verdict.


## Production Fusion Today

The production compiler already performs two kinds of fusion.

### Hand-Written Region Kernels

`compileRuntimeGraph` forms runtime regions and then runs
`selectRegionKernels`. The selector scans each `RNodeLoop` region for
recognized contiguous shapes, splits the region around the match, and
tags the matched slice with a specific kernel executor. Longest-match
priority prevents a shorter prefix from stealing a longer sink-terminal
shape.

The current production kernel set is:

| Kernel             | Arity | Shape                              | Class       |
|--------------------|------:|------------------------------------|-------------|
| `RSawLpfGain`      | 3     | `SawOsc -> LPF -> Gain`            | buffer-term |
| `RSinGainOut`      | 3     | `SinOsc -> Gain -> sink`           | sink-term   |
| `RSawGainOut`      | 3     | `SawOsc -> Gain -> sink`           | sink-term   |
| `RNoiseGainOut`    | 3     | `NoiseGen -> Gain -> sink`         | sink-term   |
| `RSawLpfGainOut`   | 4     | `SawOsc -> LPF -> Gain -> sink`    | sink-term   |
| `RBusInLpfGainOut` | 4     | `BusIn -> LPF -> Gain -> sink`     | sink-term   |
| `RNoiseLpfGainOut` | 4     | `NoiseGen -> LPF -> Gain -> sink`  | sink-term   |

Here `sink` means either `KOut` or `KBusOut`. The sink-terminal
kernels are the strongest class because they remove per-node dispatch
and absorb bus accumulation plus `block_sink_peak` tracking. The
buffer-terminal `RSawLpfGain` still materializes a buffer for its
downstream consumer, so its measured benefit is weaker.

The kernel-add gate remains:

1. the missed shape recurs across multiple corpus sources;
2. `tools/rt_graph_bench.cpp` shows a real fused-vs-node-loop win;
3. stripped node-loop bit-equivalence holds;
4. stateful and invalid-input behavior matches the per-node baseline.

That gate is intentionally stricter than "the shape is easy to write."
The project pays long-term maintenance cost for each hand-written
kernel.

### `RFused`

`compileRuntimeGraphFused` layers `fuseRuntimeGraph` on top of the
normal compile. §4.B kernel selection happens first, so `RFused` does
not steal nodes already claimed by a region kernel.

The useful cases are scalar affine chains:

- constant `Gain`;
- scalar `Add` / bias;
- mixed affine chains such as `Gain -> Add -> Gain`.

`RFused` is production-relevant but narrow. It is not a general
replacement for region kernels or generated fusion.


## Generated Fusion Today

Generated fusion has real infrastructure:

- `FusionProgram` and `FusionOp` model a small generated program.
- The runtime has a generated-program table.
- Runtime regions can point at generated executors.
- Haskell loaders validate program references and scratch use before
  loading.
- C++ still range-checks direct ABI callers.
- The cost lab can compile, run, and measure generated variants.
- Snapshot checks pin generated exactness and row counts.

The v1 generated op set (`FusionOp`) is deliberately small — five ops:

- `OpLoadConst` (`scratch[i] := k`);
- `OpLoadInput` (`scratch[i] := <node output, port, current sample>`);
- `OpAdd` (`scratch[i] := a + b`);
- `OpMul` (`scratch[i] := a * b`);
- `OpSinkWrite` (write or accumulate into an output bus).

Control reads are **not** a separate op. They appear as a
`FusionSource` operand kind (`SrcControl`) usable from any arithmetic
or sink-write op; the interpreter caches the read at block start.
Constants likewise inline as `SrcConst` operands without needing a
separate `OpLoadConst`. This is why the op surface stays narrow even
as the operand vocabulary covers the cases a v1 generated suffix
needs.

The current generated path does **not** own stateful oscillators,
filters, envelopes, delay, smoothers, spectral nodes, plugin nodes,
buffer I/O, feedback, or general resource access. Most generated rows
are suffix-generation rows: an unowned prefix still runs as node-loop
and the generated program owns a trailing arithmetic / sink suffix.

Three generated executors exist for measurement:

| Variant              | Cost-lab name       | Purpose                                      |
|----------------------|---------------------|----------------------------------------------|
| `VarGenerated`       | `generated`         | sample-major interpreter                     |
| `VarGeneratedBlock`  | `generated-block`   | same program, block-major executor           |
| `VarGeneratedSuper`  | `generated-super`   | superinstruction recognizer plus fallback    |

Super-mode recognizes `GainOut` and `AddGainOut`; everything else
falls back to block-major. It is the best generated executor measured
so far, but that is not the same as being worth turning on.


## Current Data Snapshot

The following values were captured in this checkout on 2026-05-21 with:

```sh
stack exec -- metasonic-bridge --fusion-survey
stack exec -- metasonic-bridge --fusion-cost-lab --summary
stack exec -- metasonic-bridge --snapshot-check
```

Timing values are local measurements and should be refreshed before
future decisions. Counts, exactness, and gate verdicts are the more
important signals.

### Full Survey

`--fusion-survey` reported:

| Signal | Value |
|--------|------:|
| Graphs surveyed | 85 |
| Runtime nodes | 411 |
| Runtime regions | 108 |
| §4.B fused regions | 70 |
| Nodes in fused regions | 236 / 411 (57%) |
| §4.C elided nodes | 43 |
| §4.C `RFused` inputs | 37 |

Missed shape table:

| Shape | Missed | Sources | Status |
|-------|-------:|--------:|--------|
| `Add -> LPF -> Gain -> sink` | 2 | 2 | no-signal |
| `Pulse -> Gain -> sink` | 1 | 1 | no-signal |
| `Tri -> LPF -> Gain -> sink` | 1 | 1 | no-signal |
| `Pulse -> LPF -> Gain -> sink` | 1 | 1 | no-signal |

Covered shapes remain the actual production signal:

| Shape | Found | Claimed | Sources |
|-------|------:|--------:|--------:|
| `Saw -> Gain -> sink` | 23 | 23 | 14 |
| `BusIn -> LPF -> Gain -> sink` | 15 | 15 | 10 |
| `Sin -> Gain -> sink` | 6 | 6 | 6 |
| `Saw -> LPF -> Gain -> sink` | 6 | 6 | 6 |
| `Noise -> Gain -> sink` | 5 | 5 | 5 |
| `Noise -> LPF -> Gain -> sink` | 5 | 5 | 5 |

### Planner And Cost-Model Join

Phase 7.C planner verdicts on the full survey:

| Signal | Value |
|--------|------:|
| Candidates | 313 |
| Accepted | 197 |
| Rejected | 116 |
| Selected accepted | 87 |
| Selected generated-eligible | 27 |

Top rejection reasons:

| Reason | Count |
|--------|------:|
| `ReasonStatefulInterior` | 46 |
| `ReasonNonAdjacentDataflow` | 25 |
| `ReasonFanoutEscape` | 25 |
| `ReasonResourceMidChain` | 18 |
| `ReasonLatencyMidChain` | 2 |

Cost-model join:

| Class | Count |
|-------|------:|
| selected | 87 |
| covered by existing hand kernel | 60 |
| measured-win | 0 |
| measured-loss | 19 |
| needs-benchmark | 8 |

The important line is `measured-win=0`: there is no current
generated-eligible selected shape where the measurement clears the
diagnostic win threshold.

### Generated Profitability Gate

Phase 7.F gate on the full survey:

| Verdict | Count |
|---------|------:|
| total | 29 |
| prefer-generated | 0 |
| prefer-existing | 5 |
| needs-benchmark | 14 |
| unsupported | 0 |
| non-exact | 0 |
| covered-by-hand-kernel | 10 |

Phase 7.J gate by generated executor:

| Executor | Total | Prefer generated | Prefer existing | Needs benchmark | Unsupported | Non-exact | Covered by hand kernel |
|----------|------:|-----------------:|----------------:|----------------:|------------:|----------:|-----------------------:|
| generated | 29 | 0 | 5 | 14 | 0 | 0 | 10 |
| generated-block | 29 | 0 | 5 | 14 | 0 | 0 | 10 |
| generated-super | 29 | 0 | 5 | 14 | 0 | 0 | 10 |

That is the current policy answer: all generated executors are
read-only, and none is a production turn-on candidate on the full
survey.

### Cost Lab Summary

`--fusion-cost-lab --summary` reported 174 rows:

| Family | Rows |
|--------|-----:|
| `sink-chain` | 36 |
| `return-tail` | 6 |
| `fanout` | 6 |
| `corpus` | 48 |
| `add-chain` | 24 |
| `dynamic-gain` | 18 |
| `generated-tail-sweep` | 36 |

Generated diagnostics:

| Executor | Considered | Emitted | Unsupported | Exact | Non-exact | Median speedup | Max speedup | Wins >= 1.05x |
|----------|-----------:|--------:|------------:|------:|----------:|---------------:|------------:|--------------:|
| sample-major | 29 | 27 | 2 | 27 | 0 | 0.74x | 1.86x | 1 |
| block-major | 29 | 27 | 2 | 27 | 0 | 0.62x | 1.70x | 1 |
| super-mode | 29 | 27 | 2 | 27 | 0 | 0.90x | 2.46x | 2 |

Super-mode recognized 19 emitted rows:

| Shape bucket | Rows |
|--------------|-----:|
| `GainOut` | 18 |
| `AddGainOut` | 1 |
| fallback | 8 |

The cost lab does show that generated execution can be exact and can
win isolated rows. The gate still rejects production turn-on because
those wins either:

- are covered by an existing §4.B hand kernel;
- lose to a measured `RFused` / region-kernel peer;
- do not appear as a durable full-survey `PreferGenerated` signal.

### Snapshot Checks

`--snapshot-check` passed all 61 checks.

The snapshot corpus is smaller than the full survey. It currently pins
one `PreferGenerated` row, `KGain -> KOut`, across all three generated
executors:

| Snapshot executor | Prefer-generated count |
|-------------------|-----------------------:|
| sample-major | 1 |
| block-major | 1 |
| super-mode | 1 |

This is not enough to turn generated fusion on. The Phase 7.J closeout
already explains the discrepancy: the snapshot corpus has thinner peer
coverage than the wider `--fusion-survey` corpus. On the full survey,
the same shape is `PreferExisting` because a peer measurement beats the
generated path.


## What Is Proven

The proven production optimization is the hand-written region kernel
set:

- it is selected by the normal compiler;
- it has structural selection tests;
- it has stripped-baseline A/B render tests;
- its benchmark path is explicit (`just cpp-bench`);
- sink-terminal kernels have clear wins.

The stable measured hand-written-kernel conclusions from
`notes/2026-05-10-e-fusion-kernel-measurement-ab-tests.md` are:

| Shape | Median speedup in recorded bench |
|-------|---------------------------------:|
| `SawLpfGain` | about 1.15x |
| `SinGainOut` | about 1.89x |
| `SawLpfGainOut` | about 1.31x |
| `BusInLpfGainOut` | about 1.21x |
| `NoiseLpfGainOut` | about 1.24x |

The strongest qualitative result is not one numeric row. It is the
pattern: sink-terminal kernels reliably pay for themselves because
they absorb the sink's bus work; buffer-terminal fusion is weaker
because a buffer still has to be materialized.

`RFused` is also proven for its narrow job:

- scalar `Gain` and scalar `Add` chains collapse into fused inputs;
- elided nodes remain present and control-addressable;
- the fused loader handles `RFused` inputs explicitly;
- strict loaders reject `RFused` graphs rather than silently loading
  them incorrectly.

Generated fusion is proven as infrastructure:

- the ABI exists;
- generated programs can be loaded;
- generated output is bit-exact for emitted rows in the cost lab;
- three executor strategies can be compared;
- the gate can report whether generated would be preferred.

It is **not** proven as a production optimizer.


## What Is Not Implemented Or Not Justified

Generated fusion is not wired into production graph loading.

Missing or intentionally absent pieces:

- no planner-to-runtime production turn-on;
- no per-template policy that consumes `PreferGenerated`;
- no rollback story for a row whose generated path regresses;
- no replacement of §4.B hand kernels by generated programs;
- no generated ownership of oscillator/filter/envelope/delay/smooth
  state;
- no generated buffer/plugin/spectral/feedback path;
- no generated fanout duplication policy;
- no native codegen;
- no SIMD or packed instruction stream;
- no mature stateful generated lifecycle.

The cost model is good enough to say "not yet." It is not yet a
production optimizer.


## Current Cost-Model Policy

The policy lives in `evaluateGate`:

1. `Unsupported` — generator declined to emit a program.
2. `NonExact` — generated diverged from `RNodeLoop`; hard correctness
   no.
3. `CoveredByHandKernel` — existing §4.B kernel already claims the
   shape; v1 does not replace hand kernels.
4. `NeedsBenchmark` — evidence is missing.
5. `PreferExisting` — generated lost to node-loop or to the best
   measured peer (`region-kernel` / `RFused`).
6. `PreferGenerated` — the only verdict that says "turn it on."

The measured-win threshold is `1.05x`. This keeps rows hovering just
above `1.0x` from becoming design decisions under benchmark noise.

Two details matter:

- `CoveredByHandKernel` intentionally blocks generated replacement of
  hand-written kernels in v1. If generated eventually beats a hand
  kernel by a large, stable margin, that should be a separate decision.
- `PreferGenerated` requires beating existing peers, not just beating
  node-loop. This is why a generated row can look attractive in
  isolation and still be the wrong production choice.


## Why Generated Fusion Is Parked

Generated fusion is parked for evidence reasons, not because the idea
is considered bad.

The current evidence says:

- sample-major and block-major generated execution usually lose;
- super-mode is better, but mostly on shapes that already have a hand
  kernel or an `RFused` peer;
- tail-length experiments do not show the generic interpreter
  amortizing into a win;
- the full survey reports `prefer-generated=0` for every generated
  executor;
- the one snapshot `PreferGenerated` row is explained by thinner peer
  coverage in the smaller snapshot corpus.

So the useful conclusion is:

> Generated fusion should stay as a lab / cost-model surface until real
> authored graphs create stable hot shapes that existing kernels and
> `RFused` do not already cover.


## Reopen Criteria

Generated fusion becomes an active implementation lane again only when
all of these are true:

1. A real authored / live-session corpus contains recurring hot shapes
   not already handled well by §4.B kernels or `RFused`.
2. The generated program for that shape is bit-exact against stripped
   `RNodeLoop`.
3. The generated executor beats node-loop by at least
   `measuredWinThreshold`.
4. The generated executor also beats the best existing peer
   (`region-kernel` or `RFused`), not just node-loop.
5. The win survives repeated runs and does not depend on one noisy
   microbench cell.
6. The turn-on is per-shape and auditable.
7. There is a rollback policy if a later corpus or executor change
   moves the verdict back to `PreferExisting`.

The most plausible future phase name is:

```text
Phase 7.K — Generated Fusion Runtime Turn-On
```

or, if the roadmap has moved beyond Phase 8 by then:

```text
Future Phase 9 — Production Fusion Selection
```

Do not start that phase with a generic executor rewrite. Start with a
single gate-approved shape.


## Possible Future Shape: Generated-Selected Specialized Kernels

If generated fusion becomes production-relevant later, one plausible
path is not a broader version of the current generic `FusionProgram`
interpreter. It is generated-selected specialized kernels.

In that model, the planner and generator still decide which region
candidate is legal and profitable, but the runtime does not interpret a
long generic op stream in the audio loop. Instead, the generated
artifact is a compact binding:

```text
planner selects candidate
-> generator classifies it as a known specialized shape
-> loader records shape id plus bound node/control/bus references
-> C++ runtime dispatches one tight precompiled loop
```

That is different from the current generic executor:

```text
program = OpLoadInput / OpAdd / OpMul / OpSinkWrite / ...
-> C++ interprets ops per sample, per block, or through super-mode
```

The specialized path would look like a small catalog of precompiled
C++ bodies selected by generated metadata. Early candidates, if the
evidence ever justifies them, would be narrow arithmetic / sink tails:

- `GainOut`;
- `AddGainOut`;
- `GainAddOut`;
- `AddGainAddOut`;
- other short sink tails that recur in real authored graphs and have
  no existing §4.B / `RFused` winner.

The "generated" part would be the planner-side binding of:

- shape identity;
- source node indices;
- control slots;
- sink bus indices;
- scratch requirements, if any;
- executor choice.

The arithmetic loop itself would still be ordinary precompiled C++.
This could plausibly approach hand-written kernel performance because
it removes generic op dispatch and avoids intermediate buffer
materialization. Mechanically, though, it is close to a hand-written
kernel selected by generated metadata. It should therefore obey the
same discipline:

1. add only shapes with corpus recurrence;
2. compare against stripped `RNodeLoop`;
3. prove bit-exact output;
4. preserve sink accumulation and `block_sink_peak` behavior;
5. preserve invalid-input and state-advance parity;
6. gate turn-on per shape;
7. keep the existing hand-written kernel as the peer until generated
   has repeatedly beaten it.

This route is more appropriate than native code generation or JIT as
the next generated-fusion reopening path. It is smaller, deterministic,
auditable, and fits the existing `--fusion-cost-lab` /
`evaluateGate` workflow. Native codegen should stay out of scope until
this smaller shape-specialization path has produced a real
`PreferGenerated` production candidate or clearly failed.

The reason this is not simply "write more hand kernels" is that the
planner / cost-lab / gate machinery can make the corpus-recurrence and
profitability decision per shape, while the C++ side stays a small
catalog of audited loops.


## What Should Come First

Before reopening generated fusion, the project should do more of the
work that creates meaningful optimization pressure:

1. Continue Phase 8 live-session / operator workflow.
2. Make authored manifests and session commands easier to use.
3. Grow the real graph corpus from musical examples, not only synthetic
   probes.
4. Use the survey to identify recurring hot shapes.
5. Prefer a new hand-written kernel when the shape is narrow,
   recurring, and clear enough to audit.
6. Re-run generated-fusion evidence after the corpus changes.

This ordering matters. Without real session pressure, generated fusion
work risks optimizing synthetic shapes that do not matter musically.


## Refresh Protocol Before Reopening

Before changing this decision, rerun at least:

```sh
stack exec -- metasonic-bridge --fusion-survey
stack exec -- metasonic-bridge --fusion-cost-lab --summary
stack exec -- metasonic-bridge --snapshot-check
```

For hand-written kernel work, also rerun:

```sh
just cpp-bench
```

If using the `just metasonic` wrapper, pass multi-word options as one
quoted recipe argument, for example:

```sh
just metasonic "--fusion-cost-lab --summary"
```

Decision checklist for a future reopening:

- Is `prefer-generated` non-zero on the **full** survey, not only the
  snapshot corpus?
- Which executor produced it?
- Does the row have a hand-kernel peer?
- Does it have an `RFused` peer?
- Is the win above `1.05x` and stable across reruns?
- Is `non-exact` still zero?
- Does the shape occur in real authored/session graphs?
- Is the proposed runtime turn-on per-shape?


## Related Artifacts

Source anchors (file-level links with symbol-named anchors; no line
numbers):

| Topic | Source file | Symbol / anchor |
|-------|-------------|-----------------|
| Region kernel contract | [RegionKernels.hs](../src/MetaSonic/Bridge/Compile/RegionKernels.hs) | `Note [Region kernel selection]` |
| Region kernel selector | [RegionKernels.hs](../src/MetaSonic/Bridge/Compile/RegionKernels.hs) | `selectRegionKernels` |
| Normal runtime compile | [Compile.hs](../src/MetaSonic/Bridge/Compile.hs) | `compileRuntimeGraph` |
| Fused runtime compile | [Compile.hs](../src/MetaSonic/Bridge/Compile.hs) | `compileRuntimeGraphFused` |
| RFused scalar rewrite | [Fusion.hs](../src/MetaSonic/Bridge/Compile/Fusion.hs) | `fuseRuntimeGraph` |
| Generated program type | [FusionProgram.hs](../src/MetaSonic/Bridge/Compile/FusionProgram.hs) | `FusionProgram` |
| Generated op type | [FusionProgram.hs](../src/MetaSonic/Bridge/Compile/FusionProgram.hs) | `FusionOp` |
| Planner verdicts | [Planner.hs](../src/MetaSonic/Bridge/Planner.hs) | `planRuntimeGraph` |
| Cost-lab variants | [FusionCostModel.hs](../app/MetaSonic/App/FusionCostModel.hs) | `Variant` |
| Win threshold | [FusionCostModel.hs](../app/MetaSonic/App/FusionCostModel.hs) | `measuredWinThreshold` |
| Profitability verdicts | [ProfitabilityGate.hs](../app/MetaSonic/App/ProfitabilityGate.hs) | `GateVerdict` |
| Gate policy | [ProfitabilityGate.hs](../app/MetaSonic/App/ProfitabilityGate.hs) | `evaluateGate` |
| Generated graph patching | [FusionCostLab.hs](../app/MetaSonic/App/FusionCostLab.hs) | `patchForGenerated` |
| Gate index by executor | [FusionCostLab.hs](../app/MetaSonic/App/FusionCostLab.hs) | `costLabGateIndexFor` |
| Super-mode classifier | [FusionCostLab.hs](../app/MetaSonic/App/FusionCostLab.hs) | `classifyFusionSuper` |
| C++ super executor | [rt_graph.cpp](../tinysynth/rt_graph.cpp) | `process_fusion_program_super` |
| C++ kernel bench | [rt_graph_bench.cpp](../tools/rt_graph_bench.cpp) | `rt_graph_bench` |

Core implementation:

- `src/MetaSonic/Bridge/Compile/RegionKernels.hs`
- `src/MetaSonic/Bridge/Compile/Fusion.hs`
- `src/MetaSonic/Bridge/Compile/FusionProgram.hs`
- `src/MetaSonic/Bridge/Planner.hs`
- `app/MetaSonic/App/FusionCostLab.hs`
- `app/MetaSonic/App/FusionCostModel.hs`
- `app/MetaSonic/App/ProfitabilityGate.hs`
- `tinysynth/rt_graph.cpp`
- `tools/rt_graph_bench.cpp`

Decision and measurement notes:

- `notes/2026-05-08-d-fusion-kernel-lessons.md`
- `notes/2026-05-08-e-fusion-strategy.md`
- `notes/2026-05-10-e-fusion-kernel-measurement-ab-tests.md`
- `notes/2026-05-11-j-phase-7-generated-fusion-plan.md`
- `notes/2026-05-11-k-phase-7a-fusion-cost-lab-design.md`
- `notes/2026-05-11-p-phase-7b-capability-metadata-decision.md`
- `notes/2026-05-11-q-phase-7c-planner-decision.md`
- `notes/2026-05-11-r-phase-7c-cost-model-join-decision.md`
- `notes/2026-05-12-a-phase-7d-runtime-program-abi.md`
- `notes/2026-05-12-b-phase-7e-generated-suffix-targets.md`
- `notes/2026-05-12-c-phase-7f-profitability-gate.md`
- `notes/2026-05-12-d-phase-7g-generated-tail-sweep.md`
- `notes/2026-05-12-e-phase-7h-block-major-executor.md`
- `notes/2026-05-12-f-phase-7i-superinstruction-probe.md`
- `notes/2026-05-12-g-phase-7j-gate-closeout.md`


## Final Decision

Do not implement generated-fusion runtime turn-on now.

Keep:

- hand-written region kernels as the production optimization path;
- `RFused` for scalar affine rewrites;
- generated fusion as a measurement and future-cost-model path.

Reopen generated fusion only when real corpus evidence produces a
stable, bit-exact, peer-beating `PreferGenerated` row on the full
survey.
