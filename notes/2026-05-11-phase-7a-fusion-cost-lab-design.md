# Phase 7.A Fusion Cost Lab Design

Status: design recommendation.
Date: 2026-05-11.

## Question

Can MetaSonic automatically create many graphs, benchmark them, and
use the measurements to build a cost model for fusion decisions?

## Short Answer

Yes. This is useful enough to be a new tool and should be the first
slice of the generated-fusion phase.

Recommended placement:

```text
Phase 7.A - Fusion Cost Lab
```

Recommended implementation shape:

```text
app/MetaSonic/App/FusionCostLab.hs
```

The tool should live inside the repository, not as a separate external
application, because it needs direct access to:

- the Haskell graph compiler;
- existing survey corpus definitions;
- `RuntimeGraph` internals;
- FFI loading paths;
- C++ runtime counters;
- stripped node-loop baselines.

Possible command-line shape:

```text
metasonic-bridge --fusion-cost-lab
```

or, if the main executable becomes too crowded:

```text
metasonic-fusion-cost-lab
```

## Why This Is Useful

The repository already has three partial pieces:

1. `--fusion-survey`

   Finds recurring shapes and reports kernel coverage, but does not
   measure broad performance envelopes.

2. `tools/rt_graph_bench.cpp`

   Measures known synthetic rows, but does not automatically generate
   graph families from the compiler side.

3. `test/Spec.hs`

   Contains QuickCheck graph generation and fused/unfused equivalence
   tests, but those are test-oriented rather than cost-model-oriented.

The missing tool is one that can:

- generate many legal graphs;
- compile them into multiple execution variants;
- prove equivalence where possible;
- benchmark them;
- emit structured data;
- summarize which fusion classes are profitable.

This is the bridge between "fusion is theoretically possible" and
"fusion has measured benefit for this class of graph."

## Important Caveat

Do not rely on random graphs alone.

Random generation is useful for robustness and rejection testing, but
it can overrepresent shapes real users will not write and
underrepresent musically common patterns.

The tool should combine three inputs:

1. Real corpus

   Demos, pattern corpus rows, and survey ensembles.

2. Parametric generated families

   Controlled graph families with axes such as chain length, terminal
   type, fanout, voice count, and block size.

3. Random fuzz graphs

   Used mostly for equivalence, legality, and rejection testing.

Default-on compiler decisions should require real-corpus signal or a
clearly representative parametric family, not only random graph wins.

## Graph Families To Generate

Start with structured families:

```text
producer -> gain -> sink
producer -> lpf -> gain -> sink
producer -> hpf/bpf/notch -> gain -> sink
producer -> gain -> busOut
busIn -> lpf -> gain -> out
producer1 + producer2 -> lpf -> gain -> out
N parallel voices -> same sink bus
N voices -> send bus -> return tail
buffer-terminal chains
sink-terminal chains
fanout near-misses
audio-rate gain-control near-misses
block-latched cutoff modulation
```

Useful axes:

```text
producer kind: Sin, Saw, Tri, Pulse, Noise, BusIn
filter kind: LPF, HPF, BPF, Notch
terminal: Out, BusOut, buffer-terminal
block size: 64, 128, 256, 512, 1024
voice count: 1, 4, 16, 64
chain count: 1, 2, 4, 8, 16
control shape: scalar, block-latched, audio-rate
fanout: single-consumer, multi-consumer
resource shape: no bus, bus write, bus read, buffer read/write
```

## Variants To Benchmark

For each case, compare paired execution variants:

```text
node_loop
region_kernel
rfused
generated
```

Initial meanings:

- `node_loop`: `compileRuntimeGraph` plus stripped region kernels.
- `region_kernel`: normal `compileRuntimeGraph`.
- `rfused`: `compileRuntimeGraphFused`.
- `generated`: future generated-fusion compiler path.

Before generated fusion exists, the tool can still compare:

- node loop vs hand-written region kernels;
- node loop vs `RFused`;
- hand-written region kernels vs `RFused` where both apply.

## Output Format

The output should be machine-readable first. Pretty tables can come
later.

Recommended row format: JSONL or CSV.

Each row should include:

```text
case_id
family
features
variant
block_size
voice_count
nodes
regions
fused_regions
elided_nodes
rfused_inputs
sink_terminal
stateful_nodes
bus_reads
bus_writes
buffer_reads
buffer_writes
declared_latency
median_ns_per_sample
iqr_ns_per_sample
speedup_vs_node_loop
equivalence_status
counter_summary
```

The goal is to make later decisions traceable:

```text
This fusion class wins when it removes a sink terminal and at least
N dispatches, but not when it is buffer-terminal with only one
expensive filter.
```

## Cost Model Shape

Do not start with machine learning.

Start with an explainable model:

```text
estimated_benefit =
  dispatches_removed * dispatch_cost
+ sink_writes_inlined * sink_cost
+ buffers_not_materialized * buffer_cost
+ rfused_inputs_removed * input_resolve_cost
- fused_executor_overhead
- extra_scratch_cost
```

Calibrate the coefficients from measured rows.

The first useful model can be a simple rule table:

```text
sink-terminal 3+ node chain: usually profitable
buffer-terminal 3-node filter chain: borderline
single scalar RFused chain: profitable only if it composes
audio-rate control fusion: defer
spectral/buffer-writer/plugin nodes: barrier
```

Every rule should point back to measured rows.

## Step-by-Step Plan

### 1. Add this design note

The note defines graph generation, equivalence, benchmarking, and
cost-model data collection before runtime generated fusion lands.

### 2. Add roadmap Phase 7

Add:

```text
Phase 7 - Compiler-Generated Fusion And Cost Model
```

The first sub-phase should be:

```text
7.A Fusion Cost Lab
```

This comes before the generated-fusion executor.

### 3. Hoist graph generation out of tests

`test/Spec.hs` already contains useful graph generation for fused and
unfused equivalence properties.

Do not keep all of that trapped in the test file forever.

Create a reusable module, for example:

```text
src/MetaSonic/App/FusionCostLab/GraphGen.hs
```

or:

```text
src/MetaSonic/Bridge/Analysis/GraphGen.hs
```

Keep deterministic family generation separate from QuickCheck fuzzing.

### 4. Add feature extraction

Create a pass that takes a `RuntimeGraph` and emits
`FusionCaseFeatures`.

It should reuse existing compiler facts:

- region count;
- kernel claims;
- `RFused` count;
- resource footprints;
- declared latency;
- sink-terminal classification;
- bus and buffer read/write footprint;
- consumer counts;
- stateful kind counts.

### 5. Add the benchmark runner

Implement a Haskell-side offline runner using the existing FFI path,
similar in spirit to `WorkerBench` and `SwapBench`.

It should render paired variants in one process, with warmup and
repeated timed runs.

Use the same principles as `tools/rt_graph_bench.cpp`:

- release build;
- median over repeated runs;
- paired baseline/fused comparison;
- readback sink so output cannot be optimized away;
- reproducibility header with CPU/thread/scheduler info.

### 6. Add equivalence gates

Before trusting timing rows, compare output buses between variants.

For v1, avoid nondeterministic noise cases unless the runtime gains a
deterministic seed/reset hook. Separate runtime handles currently
produce different `NoiseGen` streams, which can hide fusion bugs.

### 7. Emit JSONL or CSV

Example command:

```sh
stack exec -- metasonic-bridge --fusion-cost-lab --families sink,return,fanout --format jsonl
```

### 8. Add summary mode

Example command:

```sh
stack exec -- metasonic-bridge --fusion-cost-lab --summary
```

Example summary:

```text
family                   rows  median speedup  p25/p75  recommendation
sin-gain-out             64    1.45x           ...      profitable
saw-lpf-gain-buffer      64    1.04x           ...      do not auto-fuse
busin-lpf-gain-out       64    1.31x           ...      profitable
add-lpf-gain-out         64    1.08x           ...      needs generated backend test
```

### 9. Feed `--fusion-survey`

Eventually, `--fusion-survey` should move beyond:

```text
candidate: benchmark
```

and report:

```text
candidate: profitable by cost model
candidate: rejected, estimated win below threshold
candidate: unknown, no measured family
```

### 10. Only then implement generated fusion

The generated-fusion planner should consume this model.

Sketch:

```haskell
shouldFuse :: FusionFeatures -> CostModel -> FusionDecision
```

Possible decisions:

```text
Fuse
DoNotFuse
NeedsBenchmark
Illegal
```

## Recommendation

Build this tool before implementing the generated-fusion runtime
executor.

The goal is not to prove that the compiler can be clever. The goal is
to create an evidence loop where the compiler can say:

```text
This graph is legal to fuse, this fusion has a measured benefit class,
and this is why the runtime should use it.
```

That is the missing bridge between the current hand-written-kernel
world and a real compiler-generated fusion system.
