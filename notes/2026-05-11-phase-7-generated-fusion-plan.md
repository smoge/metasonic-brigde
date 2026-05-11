# Phase 7 Generated Fusion Plan

Status: design recommendation.
Date: 2026-05-11.

## Question

What is missing for MetaSonic to move from hand-written fusion kernels
and benchmark-only experiments to compiler-generated fusion that can be
used anywhere it is legal and measurably beneficial?

## Short Answer

This should be a new roadmap phase, not another small extension of
Phase 4.

Phase 4 proved the ingredients:

- region discovery;
- hand-written region kernels;
- scalar `RFused` lowering;
- corpus surveys;
- stripped node-loop equivalence tests;
- benchmark-gated kernel decisions.

What is still missing is a real compiler-generated fusion backend: a
compiler layer that can say, "this region is legal and profitable to
fuse; here is the fused program for it," without requiring a new
hardcoded C++ kernel for every shape.

Recommended roadmap name:

```text
Phase 7 - Compiler-Generated Fusion
```

## Current Fusion Mechanisms

The project already has two real fusion mechanisms:

1. `src/MetaSonic/Bridge/Compile/Fusion.hs`

   This performs compiler-generated `RFused` scalar affine rewrites.
   It elides single-consumer scalar `Gain` and `Add` chains while
   preserving dense node identity and control addressability.

2. `src/MetaSonic/Bridge/Compile/RegionKernels.hs`

   This selects known contiguous region shapes and tags them with
   hand-written runtime kernels such as `RSinGainOut`,
   `RSawLpfGainOut`, `RBusInLpfGainOut`, and
   `RNoiseLpfGainOut`.

The gap is not "no fusion exists." The gap is that whole-region
fusion is still selected from a fixed hand-written kernel set.

## What Is Missing

### 1. A first-class fusion IR

The compiler needs a representation for a generated fused region as
data, not only a `RegionKernel` tag.

Sketch:

```haskell
data FusionProgram = FusionProgram
  { fpMembers     :: [NodeIndex]
  , fpInputs      :: [...]
  , fpOps         :: [FusionOp]
  , fpOutputs     :: [...]
  , fpStateRefs   :: [...]
  , fpControlRefs :: [...]
  , fpEffects     :: ResourceFootprint
  , fpLatency     :: Maybe Int
  }
```

This representation becomes the compiler-owned description of what
the fused executor should run.

### 2. A legality model

"Fuse anywhere" cannot literally mean every graph. It must mean
"fuse anywhere the compiler can prove the result is legal."

The planner needs explicit rules for:

- pure/stateless nodes;
- stateful per-sample nodes;
- sink nodes;
- bus reads and bus writes;
- buffer reads and buffer writes;
- spectral nodes;
- plugin nodes;
- delay and feedback;
- control identity;
- resource footprints;
- declared latency;
- counters and diagnostics.

Initial rule of thumb:

- pure and simple stateful sample-rate chains may be eligible;
- sink-terminal chains are high-signal;
- buffer writers, spectral nodes, plugins, and feedback paths should
  be barriers at first.

### 3. A profitability model

Legality is not enough. The compiler should not fuse merely because it
can.

The planner needs a benefit estimate based on things like:

- node dispatches removed;
- intermediate buffers avoided;
- sink accumulation inlined;
- control reads collapsed;
- scratch/state overhead added;
- region size;
- block size;
- voice count;
- corpus recurrence;
- benchmarked speedup for similar shapes.

The model should remain explainable. A rule table calibrated by bench
data is a better starting point than opaque machine learning.

### 4. A generated execution target

The Haskell compiler cannot produce arbitrary optimized machine code
unless the project adds AOT code generation, a build step, or a JIT.
That is too much machinery for the first implementation.

Recommended v1 target:

- Haskell emits a compact fused-region program as data.
- The C++ runtime executes that program with a small fixed
  micro-op/interpreter backend.
- All scratch/state memory is allocated before realtime processing.
- Hand-written kernels remain as references and fast paths.

Later, if the interpreter is not enough, an AOT C++ or LLVM path can
be considered.

### 5. Runtime ABI support

The runtime boundary needs to carry more than `RegionKernel` tags.

Needed pieces:

- a fused-program table in `RuntimeGraph`;
- region entries that can reference `RNodeLoop`, a hand-written
  `RegionKernel`, or a generated `FusionProgramId`;
- C++ structs for ops, input refs, state refs, control refs, and
  output policy;
- preallocated scratch storage;
- executor counters;
- validation that no audio-thread allocation is required.

### 6. Survey and rejection diagnostics

Before generated fusion becomes runtime behavior, the compiler should
be able to explain its decisions.

The survey should report:

- candidate region;
- generated program shape;
- expected benefit;
- reason accepted;
- reason rejected;
- equivalent existing hand-written kernel, if any;
- benchmark status for the shape family.

This preserves the current project discipline: corpus first, survey
second, runtime change third.

## Step-by-Step Plan

### Phase 7.A - Fusion Contract Note

Write the design note before implementation.

Define:

- what generated fusion means;
- what equivalence means;
- what remains handled by hand-written kernels;
- what is out of scope;
- which node kinds are v1 eligible;
- which effects force barriers;
- which diagnostics must exist before enabling runtime behavior.

Recommended v1 eligibility:

- allow: `KGain`, `KAdd`, simple source/filter/gain/sink shapes
  already proven by region kernels;
- consider: `KSinOsc`, `KSawOsc`, `KNoiseGen`, `KLPF`, `KHPF`,
  `KBPF`, `KNotch`;
- defer: buffers, spectral nodes, plugin nodes, delay feedback,
  multi-output fusion, latency compensation.

### Phase 7.B - Add Fusion Capability Metadata

Add compiler-visible capability metadata per `NodeKind`.

Sketch:

```haskell
data FusionCapability
  = FusionPureSample
  | FusionStatefulSample
  | FusionSink
  | FusionBarrier FusionBarrierReason
```

This should live near existing kind metadata, not inside one-off
survey code.

### Phase 7.C - Add `FusionProgram` IR

Introduce the Haskell-side generated fusion representation.

Do not execute it yet. Build it, pretty-print it, and test that it
describes the intended regions.

### Phase 7.D - Survey-Only Planner

Extend `--fusion-survey` or add a sibling tool that reports generated
fusion candidates.

It should print:

- accepted candidates;
- rejected candidates;
- rejection reason;
- estimated benefit;
- matching hand-written kernel, if any.

### Phase 7.E - Runtime ABI Skeleton

Add the C/Haskell boundary for generated fused programs, starting with
a tiny safe subset.

First supported ops can be:

- scalar read;
- input read;
- add;
- multiply;
- sink write.

This overlaps with `RFused`, which is useful because it gives a
low-risk equivalence target.

### Phase 7.F - Generated Executor For Current Kernel Shapes

Teach the planner to generate programs equivalent to the current
hand-written kernels:

- `SinOsc -> Gain -> sink`;
- `SawOsc -> Gain -> sink`;
- `NoiseGen -> Gain -> sink`;
- `SawOsc -> LPF -> Gain -> sink`;
- `BusIn -> LPF -> Gain -> sink`;
- `NoiseGen -> LPF -> Gain -> sink`.

Keep the hand-written kernels as references.

Tests should assert:

- node-loop output equals generated-fusion output;
- generated-fusion output equals hand-written-kernel output where
  applicable;
- counters distinguish which executor ran.

### Phase 7.G - Profitability Gate

Do not enable generated fusion globally until it has a gate.

Possible rules:

- must remove at least N dispatches;
- must remove at least one intermediate audio-rate edge;
- must inline a sink terminal;
- must match a recurrent corpus shape;
- must beat node loop by a threshold in bench data.

### Phase 7.H - Opt-In Runtime Flag

Start behind a separate opt-in mode.

Possible command-line shape:

```text
--generated-fusion
```

The dispatch preference can be:

1. hand-written kernel if explicitly better;
2. generated fusion if legal and profitable;
3. normal node loop fallback.

### Phase 7.I - Expand Carefully

Only after the first generated backend is stable, expand to harder
cases:

- multiple sinks;
- shared subexpressions;
- stateful envelopes;
- delay-like state;
- block-rate controls;
- latency-aware fused regions;
- buffer readers;
- plugin nodes.

Keep buffer writers, spectral nodes, and plugin hosting as barriers
until diagnostics and equivalence tests are strong enough.

## Recommendation

Make this a new Phase 7.

The next implementation should not start by making the runtime clever.
It should start with a design note, fusion capability metadata,
`FusionProgram` IR, and survey-only candidate reporting.

The generated runtime executor should come only after legality,
diagnostics, and cost evidence exist.
