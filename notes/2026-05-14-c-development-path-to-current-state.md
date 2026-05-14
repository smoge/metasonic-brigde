# Development Path To The Current State

Date: 2026-05-14

Status: long-form development history and design checkpoint. Current
checkout before this note was written: `7154cc1` (`update cabal file`).

This note is not a roadmap replacement. `ROADMAP.md` remains the current
status index, and the focused notes in this directory remain the
normative design records for each slice. This file is a narrative map:
how the project moved from its first Haskell/C++ bridge prototype to the
current compiler/runtime/authoring/session system, why the major
decisions were made, what implementation contracts now matter, and what
questions are still intentionally open.

Primary source material for this note:

- [ROADMAP.md](../ROADMAP.md) - current phase index and status.
- [README.md](../README.md) - current user-facing surface and command
  inventory.
- [Project path draft](drafts/2026-05-08-project-path.md) and
  [full arc through Phase 4.E](drafts/2026-05-08-project-state-full-arc-through-4e.md)
  - older history checkpoints that this note extends.
- [Phase 4 reasoning and work summary](2026-05-10-b-phase-4-reasoning-and-work-summary.md)
  - region, fusion, rate, and worker-dispatch rationale.
- [Phase 6.A-6.D state snapshot](2026-05-11-g-state-snapshot-phase-6-complete.md)
  - pattern, OSC, buffer, and spectral boundary.
- [Real project assessment](2026-05-11-m-real-project-assessment.md)
  - maturity checkpoint before Phase 7/8/session work.
- [Phase 7.J gate closeout](2026-05-12-g-phase-7j-gate-closeout.md)
  - current generated-fusion decision.
- [Phase 8.H authoring manifest](2026-05-12-m-phase-8h-authoring-manifest.md)
  - current authoring export boundary.
- [Session live-control rollup](2026-05-14-b-session-live-control-rollup.md),
  [coalescing note](2026-05-13-o-session-control-coalescing-arbitration.md),
  and
  [producer arbitration note](2026-05-14-a-session-producer-coexistence-arbitration.md)
  - current session/live-control state.

## Core Thesis

The project has kept one central shape from the beginning:

```text
Haskell DSL -> SynthGraph -> GraphIR -> RuntimeGraph -> C++ DSP Engine
```

Haskell owns graph meaning:

- source-level construction;
- validation;
- symbolic `NodeID` allocation;
- dense `NodeIndex` lowering;
- kind, rate, effect, latency, resource, and fusion metadata;
- template ordering;
- region formation;
- survey and planner diagnostics;
- authoring-layer elaboration;
- session-side symbolic command admission.

C++ owns execution:

- the realtime audio callback;
- dense node and region dispatch;
- per-instance DSP state;
- Q-backed oscillators, filters, envelopes, delays, smoothing, MIDI,
  and audio I/O;
- the server-global bus and buffer pools;
- voice allocation;
- realtime command queues;
- hot-swap installation;
- static plugin dispatch;
- the low-level ABI observed by Haskell.

That split is the main project identity. The audio thread should not
resolve symbolic names, discover topology, infer ordering, grow resource
pools on demand, or decide which graph fragments are safe to run. It
should execute a dense, prevalidated, compiler-derived runtime graph.

Two rules follow from that thesis:

1. `NodeID` is symbolic and compile-time only.
2. `NodeIndex` is dense, ordered, and crosses the ABI.

Most later design choices are consequences of preserving those rules
while making the system more useful.

## Stage 0 - Bridge Skeleton And Dense Runtime

The first commits were about proving that a Haskell-built graph could
cross into a C++ runtime and produce audio.

The early implementation surface was small:

- Stack and `package.yaml` wired the Haskell executable.
- `tinysynth/rt_graph.h` became the C ABI.
- `tinysynth/rt_graph.cpp` became the C++ runtime.
- `app/Main.hs` held the first demo runner.
- `vendor/q` and `vendor/infra` became required submodules.
- PortAudio/Q I/O produced actual realtime output.

The important early correction was moving from symbolic runtime lookup
to dense runtime indices. The local history records this explicitly in
the 2026-03-16 commit `b09a242`:

```text
Compile graphs to denser runtime indices; remove C++ runtime lookups
```

That commit is more important than its size suggests. It established
the ABI discipline that still holds: the Haskell compiler resolves the
symbolic graph, and C++ receives dense storage-order indices. Later
features such as live controls, fusion, hot-swap, generated programs,
and session state all depend on the fact that dense identities remain
stable and addressable.

Implementation implications that still matter:

- edit `package.yaml`, not the generated Cabal file, when Haskell/C++
  build metadata changes;
- keep Stack and CMake in sync when C++ sources, include paths, or
  libraries change;
- keep the C ABI in `tinysynth/rt_graph.h`, its implementation in
  `tinysynth/rt_graph.cpp`, and the Haskell boundary in
  `src/MetaSonic/Bridge/FFI.hs`;
- never let the C++ runtime regain symbolic graph-solving
  responsibility.

## Stage 1 - Compiler Pipeline And Inspectability

The project then stopped being just a demo runner and became a staged
compiler.

The pipeline was split into modules that still define the reading order:

1. `src/MetaSonic/Types.hs`
2. `src/MetaSonic/Bridge/Source.hs`
3. `src/MetaSonic/Bridge/Validate.hs`
4. `src/MetaSonic/Bridge/IR.hs`
5. `src/MetaSonic/Bridge/Compile.hs` and its sibling modules
6. `src/MetaSonic/Bridge/Templates.hs`
7. `src/MetaSonic/Bridge/FFI.hs`

The roles clarified at this point:

- `SynthM` builds `SynthGraph`s.
- `UGen` describes primitive source-level nodes.
- `Connection` is either a constant or an edge from another node.
- `out` is terminal and returns `SynthM ()`, not a reusable signal.
- routing is graph structure (`BusOut`, `BusIn`, `BusInDelayed`), not
  hidden runtime state.

The Brick TUI inspector (`--inspect`, `--inspect-only`) was also a
major design decision. It made the compiler pipeline visible stage by
stage. That mattered because once buses, effects, region formation, and
fusion entered the system, debugging by reading source graphs alone was
too weak. The inspector and textual summaries became observability
tools for the compiler contract.

The durable decision from this stage: do not hide structural facts in
runtime side effects if they can be represented in the compiler input.
The compiler must be able to see routing, ordering, and resource use.

## Stage 2 - Q-Backed DSP Surface

The DSP vocabulary grew around Cycfi Q, but Q was kept as a kernel and
I/O substrate rather than the owner of graph semantics.

The runtime added:

- oscillators: `KSinOsc`, `KSawOsc`, `KPulseOsc`, `KTriOsc`;
- `KNoiseGen`;
- biquads: `KLPF`, `KHPF`, `KBPF`, `KNotch`;
- arithmetic: `KGain`, `KAdd`;
- sinks: `KOut`, `KBusOut`;
- reads: `KBusIn`, `KBusInDelayed`;
- `KEnv`;
- `KDelay`;
- `KSmooth`;
- later: `KPlayBufMono`, `KRecordBufMono`, `KSpectralFreeze`,
  `KStaticPlugin`.

The implementation lesson was that a UGen is not just a DSP function.
It is a compiler/runtime contract change. Adding a kind requires changes
across:

- `NodeKind` and `kindSpec` in `src/MetaSonic/Types.hs`;
- `UGen`, `ugenView`, and the user-facing builder in
  `src/MetaSonic/Bridge/Source.hs`;
- C++ `NodeKind` tag decoding in `tinysynth/rt_graph.cpp`;
- node configuration and state;
- the processing function;
- `process_graph` or region dispatch if needed;
- tests that catch tag, arity, metadata, and runtime behavior drift.

The runtime state model became increasingly explicit. Oscillator phase,
noise generator state, filter memory, envelope state, delay buffers, and
smoother state all live per node per graph instance on the C++ side,
not in Haskell. Runtime state is commonly held behind `std::variant`
and accessed through safe dispatch such as `std::get_if`.

Another load-bearing principle emerged here: reconfigure stateful Q
objects when controls change, but do not reconstruct state unless a
reset is intended. Filter coefficient changes should preserve filter
history. Oscillator and delay state should persist across blocks. That
principle later shaped hot-swap migration and the list of state kinds
that can or cannot be preserved today.

## Stage 3 - Tests, Metadata Tables, And ABI Drift Guards

As the node set grew, drift became the main risk. The project responded
by turning more contract facts into tables and tests.

The Haskell side now centralizes per-kind metadata in `kindSpec`:

- numeric tag;
- default rate;
- audio arity;
- control arity;
- display label.

`ugenView` in `Bridge.Source` maps each `UGen` constructor to the
corresponding kind, inputs, and controls. Many older per-kind pattern
matches were replaced by derivations from these tables:

- `kindTag`;
- `inferRate`;
- `inferEff` where possible;
- `inferKind`;
- `lowerInputs`;
- `extractControls`;
- dependency extraction.

The C++ runtime exposes tag-support queries through the ABI, and the
Haskell test suite checks that every Haskell `NodeKind` tag is
recognized by the C++ side. Tests also cross-check `kindSpec` and
`ugenView` arities, dense lowering, region invariants, FFI smoke
behavior, and many C++-only edge cases.

This changed the failure mode. Before these tests, tag or arity drift
could survive until a runtime path happened to exercise it. Afterward,
adding a node without updating the sibling metadata sites became a
test failure.

The design justification was pragmatic: table-shaped metadata is not
beautiful for its own sake. It reduces the number of places that can
silently disagree between Haskell and C++.

## Stage 4 - Instances, Templates, Buses, And Lifecycle

The next major shift was from "one compiled graph is the whole engine"
to "a compiled graph is an immutable template that can have many
instances."

The runtime split:

- `MetaDef`: immutable per-template spec data;
- `GraphInstance`: per-instance state and control overrides.

That enabled:

- many instances of one template;
- independent oscillator/filter/envelope/delay state per voice;
- slot reuse;
- release-then-free lifecycle;
- per-instance control writes;
- a server-global bus pool;
- cross-instance and cross-template routing.

`TemplateGraph` then made multi-template patches compiler-owned. Each
template gets a `BusFootprint`:

- buses it writes;
- buses it reads live;
- buses it reads delayed.

The compiler derives a precedence DAG from those footprints. A template
that writes a bus precedes a template that reads that bus live.
Delayed reads intentionally do not add same-block ordering edges. The
C++ runtime executes templates in the order the compiler provides; it
does not recompute that graph.

This is where the project rejected SuperCollider-style mutable groups
as a default primitive. Groups usually solve ordering, routing, and
lifecycle. MetaSonic chose to derive ordering from graph/resource
structure instead. The current roadmap keeps groups declined unless a
concrete workflow cannot be expressed through templates, buses, voice
allocation, and release lifecycle.

Important implementation details:

- `KBusIn` reads the current block and therefore induces ordering.
- `KBusInDelayed` reads the previous block and breaks same-block cycles.
- `KOut` and `KBusOut` are effects, not pure outputs.
- bus pool scope is server/global, not per instance;
- release-then-free lets envelopes finish before slots are reclaimed;
- hard remove remains available for deliberate cuts and voice stealing.

## Stage 5 - Realtime Activation, Voice Allocation, And MIDI

Once templates and instances existed, the system needed live control
without letting the audio callback become a graph constructor.

The realtime ABI introduced:

- fixed-shape instance pools;
- atomic slot state;
- queued reserve/prepare/activate flow;
- an SPSC control queue drained at the top of processing;
- explicit bus-pool growth outside the audio callback;
- queue reset on clear;
- recovery behavior for queue-full and allocation failure.

The important state-machine clarification was that `Reserved` is
exclusively for the queued realtime path. Offline construction can go
straight to active. The audio thread may activate prepared work; it
must not become a general constructor.

The C++ live-control layer then added:

- `VoiceAllocator`;
- `MidiVoiceProcessor`;
- Q typed-MIDI integration;
- per-voice CC and pitch-bend dispatch;
- cached control inheritance into later note starts;
- `KSmooth` auto-insertion at control ingress;
- live MIDI demo hardening for no-device and FFI exception boundaries.

This phase made the system playable. It also made control identity
load-bearing: if later fusion elides a node from dispatch, the node
must remain addressable by `NodeIndex` because MIDI and control paths
may still target it.

## Stage 6 - Regions, RFused, Hand-Written Kernels, And Measurement

Phase 4 moved the compiler from dense per-node execution toward
region-sized work while preserving the dense ABI contract.

### Region Overlay

`formRegions` produces contiguous runtime regions with rate and
dependency metadata. The runtime receives this overlay through the FFI.
`RuntimeRegion` now carries:

- dense region index;
- member node indices;
- region rate;
- execution selector;
- resource footprint.

Originally the selector was effectively a `RegionKernel`. Phase 7 later
widened it to `RegionExec`:

- `ExecNodeLoop`;
- `ExecKernel RegionKernel`;
- `ExecGenerated FusionProgramId`;
- `ExecGeneratedBlock FusionProgramId`;
- `ExecGeneratedSuper FusionProgramId`.

The backward-compatible `rrKernel` accessor still projects generated
regions as `RNodeLoop`, so code that needs generated variants must read
`rrExec` directly.

### RFused Affine Rewrites

The first optimization track was not whole-region codegen. It was
single-input algebraic fusion:

- scalar `KGain` single-edge fusion;
- chained scalar `KGain` fusion;
- scalar `KAdd` / bias fusion;
- mixed gain/add affine chains.

The compiler elides a single-consumer producer from dispatch by
absorbing its work into the consumer input read. The node remains in
`rgNodes` with `rnElided = True`; its `NodeIndex` and controls remain
addressable. The runtime evaluates fused inputs live, so control
changes to elided nodes still affect output.

The design reason was simple: optimization must not destroy the
control surface.

### Hand-Written Region Kernels

The second optimization track was a fixed set of hand-written C++
region kernels:

- `RSawLpfGain`;
- `RSinGainOut`;
- `RSawLpfGainOut`;
- `RSawGainOut`;
- `RNoiseGainOut`;
- `RBusInLpfGainOut`;
- `RNoiseLpfGainOut`.

The sink-terminal kernels are the strong class because they remove
node dispatch and inline sink accumulation / peak tracking. The
buffer-terminal shape is useful but less decisive because the biquad
cost dominates dispatch savings.

Kernels are selected by longest-match priority and measured against a
stripped node-loop baseline. The project deliberately did not add every
imaginable kernel. The kernel-add gate requires:

1. recurring shape signal in `--fusion-survey`;
2. benchmark win over stripped node-loop;
3. bit-equivalence against the stripped baseline;
4. edge-case parity, including invalid-input and stateful paths.

This gate is why some candidates landed and others stayed parked. It
also taught a broader rule: a faster-looking path is not enough. Tests
need both output equivalence and counters or metadata proving the path
actually ran.

### Rate Metadata

Rate propagation was preserved into runtime nodes, but the first survey
showed the corpus was effectively all `SampleRate` by output rate. That
was not a failure of propagation; it showed that output rate alone is
too coarse for block-latched optimization.

The follow-up added per-port consumption metadata:

- `PortSampleAccurate`;
- `PortBlockLatched`;
- `PortInitOnly`;
- `PortIgnored`.

This lets the compiler ask how the destination port consumes an input.
For example, filter frequency and Q are block-latched in the current
runtime, while signal ports remain sample-accurate. The current signal
is too small to justify a block-rate executor, so the metadata remains
descriptive.

### Region-Level Parallelism

Phase 4.E built substantial scheduling substrate:

- per-region resource footprints;
- deterministic linear fallback;
- layered schedule representation;
- shared-write hazard reporting;
- deterministic bus-reduction storage;
- global schedule ABI;
- serial schedule executor;
- test-gated worker dispatch;
- C1d region work items;
- synthetic and Haskell-loaded worker benches.

The decision was negative for default-on parallelism. Synthetic shapes
can show worker wins when width and block work are high enough, but the
representative corpus does not justify a public switch. Phase 4.E is
therefore frozen as test/bench-gated. The infrastructure remains useful
for introspection, deterministic reduction, future hot-swap world
scratch, and recognizing a real workload if one appears.

## Stage 7 - Hot Graph Replacement

Phase 5 added the hot-swap substrate. The goal was to replace a running
runtime world without stopping the target audio handle, while preserving
state where the current implementation can do so safely.

The runtime protocol:

- build a separate offline `RTGraph`;
- prepare a swap payload from that world;
- publish it to the live runtime;
- install at a block boundary;
- retire the old world;
- collect retired swap stats off-audio.

The swappable state lives behind `RTGraph::active`, and the Haskell FFI
exposes helpers such as `hotSwapRuntimeGraph`,
`hotSwapRuntimeGraphFused`, `hotSwapTemplateGraph`, and
`hotSwapTemplateGraphFused`.

State migration v1 uses:

- caller-supplied migration keys on nodes;
- slot-index identity for live instances;
- copy-safe DSP state for oscillators, noise, and biquads;
- live-slot lifecycle metadata.

Env, Delay, Smooth, spectral, plugin, and other complex states remain
unsupported for preserving migration unless a later custom-copy or
prewarm path is designed. Unsupported preserving swaps reject
non-terminally in session adapters rather than silently resetting live
voices.

Template identity also became explicit. Template names load as fixed
identity tokens; mismatched live templates can reject a swap before
install. That prevents semantically different templates from inheriting
state solely because they occupy the same numeric slot.

Open hot-swap questions:

- allocation-free migration for Env, Delay, and Smooth;
- richer producer-side mapping helpers from migration keys to new
  `NodeIndex` values;
- session-level respawn/reset policy for unsupported preserving swaps;
- stronger attribution if multiple producers publish swaps
  concurrently.

## Stage 8 - Pattern, OSC, Buffers, Spectral, And Plugins

Phase 6 stressed the compiler/runtime boundary with more realistic
ecosystem features.

### Pattern Corpus

`MetaSonic.Pattern` and `MetaSonic.Pattern.Corpus` introduced a
deterministic producer-side corpus. The intent was not to add a Haskell
runtime scheduler. Pattern rows produce natural graph and event shapes
that existing surveys can inspect:

- kernel coverage;
- rate opportunity;
- schedule width;
- hot-swap shapes;
- later spectral/plugin/authoring examples.

This matters because Phase 4 and 5 had several gates waiting for real
musical surface area instead of synthetic benchmark rows.

### OSC Control

OSC entered as a Haskell-side control producer:

- pure wire parsing;
- pure symbolic dispatch;
- bracketed UDP listener;
- end-to-end loopback test;
- `--osc-listen` CLI demo.

The ownership decision was deliberate. OSC is a control plane, not an
audio data plane. Haskell can parse and resolve symbolic control paths,
then send dense control writes through the existing runtime path. The
audio callback stays insulated from socket timing and GC pauses.

### Buffer I/O

Buffers made resource identity real. The v1 model added:

- producer-allocated `Buffer` handles;
- fixed-cap C++ buffer pool;
- `KPlayBufMono` for mono playback;
- live-safe retire/collect;
- `KRecordBufMono` for sample-by-sample writing and pass-through;
- `ResourceFootprint = buses + buffers`;
- compile-time precedence over `BufWrite -> BufRead`;
- rejection of same-buffer multiple writers;
- writer-template polyphony clamp in Haskell and C++.

The important decision is that resource axes must be explicit. Buses
and buffers are disjoint namespaces inside `ResourceFootprint`. Any new
resource family should add a field and rederive precedence rather than
smuggling extra behavior through existing bus rules.

### Spectral Freeze

`KSpectralFreeze` became the first spectral kind:

- fixed N=1024, hop=256 STFT;
- Hann/WOLA constants precomputed outside the audio thread;
- pass-through and freeze modes;
- hop-latched freeze flag;
- declared latency via `kindLatency`;
- descriptive latency footprint and input-skew reports;
- barrier scheduling classification.

The slice deliberately did not add spectrum-stream types, variable
window sizes, multichannel STFT, or latency compensation. One
well-tested spectral kind was enough to prove the contract and surface
latency metadata.

### Static Plugin Hosting

`KStaticPlugin` is the first plugin-hosting surface. The first concrete
plugin is the build-linked `Identity` plugin:

- two audio inputs;
- one audio output;
- frozen `plugin_id` control;
- zero declared latency;
- pure effects;
- C++ `PluginSpec::process` dispatch;
- audio-thread counters for calls and invalid plugin calls.

The follow-up metadata decision chose a Haskell-side per-plugin catalog
while keeping one `KStaticPlugin` `NodeKind`. That preserves a narrow
C++ dispatch path while allowing plugin-specific arity, latency, and
effects to feed Haskell validation and resource analysis.

No dynamic plugin formats are in scope yet. LV2/VST3/CLAP, discovery,
plugin-owned UI, MIDI-in plugins, parameter layout, and plugin state
migration remain future work after a second static plugin proves which
metadata is actually load-bearing.

## Stage 9 - Generated Fusion And Cost Modeling

Phase 7 was the answer to a tempting question: should the project move
from hand-written region kernels to compiler-generated fusion?

The answer became evidence-first rather than yes-by-default.

The tools and IR now include:

- `--fusion-cost-lab`;
- per-kind fusion capability metadata;
- a survey-only planner in `MetaSonic.Bridge.Planner`;
- selected-candidate and cost-model join summaries;
- `FusionProgram` data in
  `src/MetaSonic/Bridge/Compile/FusionProgram.hs`;
- a per-template generated program table in `RuntimeGraph`;
- generated region selectors in `RegionExec`;
- sample-major, block-major, and super-mode C++ executors;
- gate-by-executor diagnostics;
- snapshot pins for structural facts.

The generated-program v1 op set is deliberately tiny:

- scalar read;
- input read;
- add;
- multiply;
- sink write.

The generated path proved the ABI and equivalence discipline. It did
not prove a runtime turn-on policy. Measurements showed that generic
generated executors usually lose to node-loop or to existing peers
(`RFused` or hand-written kernels). Super-mode can win on recognized
small shapes, but those wins are either already covered by hand-written
kernels or beaten by an existing peer.

The 7.J closeout is the current decision point:

- generated fusion is parked as a read-only performance path;
- the gate can report whether any executor would prefer generated;
- the snapshot corpus currently has one `PreferGenerated` row because
  its peer coverage is thinner than the wider survey corpus;
- the wider survey still reports no durable runtime turn-on signal;
- no planner emission, runtime switch, recognizer expansion, or ABI
  widening is authorized by current evidence.

The broader design lesson is important: the existence of a generated
executor does not imply readiness. Legality, equivalence, peer
comparison, and repeatable profitability all have to line up.

## Stage 10 - Authoring DSL And Manifest Export

Phase 8 moved upward, toward user-facing patch construction, while
preserving the compiler as the semantic authority.

The boundary is strict:

- authoring helpers elaborate to ordinary `SynthGraph` and
  `TemplateGraph` values;
- `Source`, `Templates`, `Validate`, `IR`, and `Compile` remain the
  meaning of the graph;
- the C++ runtime does not learn authoring-level constructs;
- inspector, survey, and FFI loading still see the primitive graph.

The first surface added:

- `Mono`;
- `Stereo`;
- `Channels`;
- channel-wise lifted UGens;
- stereo/channel output helpers;
- `pan2`, `balance`, `spread`, `mixN`;
- explicit `send` / `returnBus` over a `Bus` handle;
- ensemble builders with deterministic bus allocation;
- named controls;
- CC-bound controls;
- authoring report rendering;
- authoring manifest JSON export.

`MetaSonic.Authoring.Report` projects templates, named buses, and
named controls. `MetaSonic.Authoring.Manifest` serializes that report
as schema-versioned JSON through `--authoring-manifest`.

What this did not do:

- no parser;
- no external language;
- no separate compiler;
- no hidden runtime allocation;
- no graph save/import format;
- no runtime manifest reload.

The design justification was that practical patches need a better
surface than hand-wired mono connections and bus numbers, but the
project should not create a second semantic path. Authoring is
elaboration, not runtime behavior.

## Stage 11 - Session Layer And Live-Control Integration

The current newest work is the session layer. It is not a numbered
roadmap phase yet, but it is the active product-facing direction.

The session layer sits above the compiler and runtime. It normalizes
producer intent, validates symbolic commands, owns or references an
`RTGraph`, and serializes command application. It is library code, not
a daemon.

The landed module surface includes:

- `MetaSonic.Session.Command`;
- `MetaSonic.Session.Resolve`;
- `MetaSonic.Session.Report`;
- `MetaSonic.Session.State`;
- `MetaSonic.Session.Runtime`;
- `MetaSonic.Session.Step`;
- `MetaSonic.Session.RTGraphAdapter`;
- `MetaSonic.Session.Owner`;
- `MetaSonic.Session.Queue`;
- `MetaSonic.Session.PatternProducer`;
- `MetaSonic.Session.Runner`;
- `MetaSonic.Session.Host`;
- `MetaSonic.Session.FanIn`;
- `MetaSonic.Session.FanInService`;
- `MetaSonic.Session.OSCProducer`;
- `MetaSonic.Session.OSCListener`;
- `MetaSonic.Session.MIDIProducer`;
- `MetaSonic.Session.MIDIListener`;
- `MetaSonic.Session.MIDIPortMIDI`;
- `MetaSonic.Session.UIProducer`;
- `MetaSonic.Session.Arbitration`;
- `MetaSonic.Session.ArbitrationGateway`.

The narrow waist is `SessionCommand`:

- `CmdVoiceOn`;
- `CmdVoiceOff`;
- `CmdControlWrite`;
- `CmdHotSwap`.

`SessionCommand` is producer-agnostic. Pattern, OSC, MIDI, UI, and
future producers converge on the same command vocabulary instead of
growing parallel runtime mutation paths.

The state path is deliberately staged:

1. pure admission decides whether a command is valid;
2. the runtime adapter performs the requested action;
3. a checked commit mutates session state only if it corresponds to
   the admitted plan;
4. owner divergence is terminal until a repair protocol exists.

This plan/commit handshake prevents a later runtime fact from being
applied to the wrong symbolic session state.

### Queue And Fan-In

`MetaSonic.Session.Queue` is a bounded Haskell-side producer-intent
FIFO. It carries producer identity and per-queue sequence numbers. It
does not silently drop, coalesce, or reorder accepted commands.

`MetaSonic.Session.FanIn` serializes enqueue, drain, and snapshot
access around that queue and owner. `FanInService` adds a scoped
background drain worker. Successful enqueues wake one FIFO drain;
divergence terminates the worker; teardown has bounded kill fallback
for blocked hooks.

The FIFO property is load-bearing because accepted command visibility
is the shared contract between producers and the owner.

### Pattern Producer

`MetaSonic.Session.PatternProducer` expands one pattern range at a
time, converts `PatternEvent` values through `fromPatternEvent`, and
retains bounded backlog when the fan-in queue is full. The runner and
host layers compose that with a session owner in caller-driven and
thread-safe forms.

### Preserving Hot-Swap

The session adapter uses the Phase 5 runtime swap substrate for a
narrow preserving swap path:

- build an offline next world;
- publish it;
- for stopped-audio owners, force scripted install with a zero-frame
  process step;
- for live audio, wait for swap generation to advance;
- collect retired migration stats;
- verify expected migration counters;
- commit only after proof.

Supported oscillator/filter voices can preserve bindings and state
through that path. Unsupported stateful graphs reject non-terminally
before pretending to preserve state.

### OSC, MIDI, And UI Producers

OSC ingress is now split into reusable pieces:

- symbolic control-write decoder;
- session `OSCProducer`;
- session `OSCListener`;
- host-based FIFO path;
- service-owned arbitrated path when configured.

MIDI ingress is Haskell-side above an injected decoded source:

- note-on/off;
- velocity-zero note-off;
- CC;
- pitch-bend;
- pitch-bend replay into later notes;
- sustain-pedal deferral/release;
- all-notes-off;
- default-omni channel filtering;
- PortMIDI/Q decoded source;
- `--session-midi-smoke [SECONDS]`.

UI ingress exists as an adapter for already-decoded UI intents. It is
not a GUI toolkit binding yet.

### Coalescing And Arbitration

The current queue remains strict FIFO. Coalescing is producer-local.
MIDI listener-local coalescing merges repeated control writes by
`(VoiceKey, ControlTag)` before fan-in, flushes at fences, and reports
coalesced writes, accepted flushes, barrier flushes, pending count, and
fence drops. Non-control commands are fences.

Cross-producer arbitration is also above fan-in, not inside the queue.
The pure policy surface includes:

- `FifoOnly`;
- producer priority;
- target claim.

`ArbitrationGateway` rejects before enqueue, so denied commands do not
consume queue capacity or sequence numbers. `FanInService` can own an
optional gateway, but raw service enqueue remains FIFO by design.

Concrete opt-in arbitrated paths now exist for:

- OSC producer/listener;
- UI producer;
- Pattern producer.

MIDI live arbitration remains the main open gap because that path
already owns note state, sustain state, pitch-bend state, channel
filtering, coalescing buffers, and timed flush behavior.

## Cross-Cutting Decisions

Several project decisions recur across phases.

### Dense Identity Beats Convenience

Keeping `NodeID` symbolic and `NodeIndex` dense costs some translation
work, but it keeps the audio thread simple. Every optimization that
elides, fuses, schedules, or swaps nodes has to preserve enough dense
identity for live controls and migration.

### Metadata Tables Beat Scattered Clauses

`kindSpec`, `ugenView`, `kindCapabilities`, `kindLatency`, `portInfo`,
static plugin catalog rows, and resource footprints all reflect the
same preference: make contract facts inspectable and testable. The
tables are not perfect, especially for plugin-specific metadata, but
they make drift visible.

### Compiler-Derived Ordering Beats Manual Runtime Ordering

Template precedence, region dependencies, bus and buffer footprints,
and schedule layers all follow from graph/resource structure. Manual
groups remain declined because they would move responsibility back to
runtime mutation.

### Evidence Gates Beat Attractive Optimizations

Kernel expansion, block-rate execution, worker dispatch, generated
fusion, and coalescing all use some form of "measure first, then widen"
discipline. This has repeatedly produced negative decisions:

- block-rate execution parked;
- worker dispatch default-off;
- generated fusion read-only;
- queue-level coalescing rejected;
- arbitrary plugin work parked;
- latency compensation deferred.

Those negative decisions are progress. They keep the system from
growing runtime complexity without workload evidence.

### Producer Policies Stay Above Shared FIFO

The session queue and fan-in path guarantee accepted commands appear in
FIFO order. MIDI coalescing and cross-producer arbitration therefore
live above fan-in. This preserves the shared queue contract while still
allowing producer-specific pressure relief and ownership policy.

### Notes Are Design Artifacts

The repo now uses `notes/` as a durable design log. Focused notes
record scope, non-goals, implementation sequence, tests, and deferred
work. This is valuable because many decisions are intentionally
negative or conditional; a roadmap checkbox alone would not preserve
the reasoning.

## Current Checkout Shape

As of this note, the project is best described as:

```text
checked graph compiler
  -> dense RuntimeGraph / TemplateGraph
  -> region overlay + resource footprints
  -> selected RFused rewrites
  -> selected hand-written region kernels
  -> read-only generated-fusion experiments
  -> C++ runtime with instances, buses, buffers, MIDI, plugins, hot-swap
  -> authoring facade and manifest export
  -> session command/fan-in/producers/adapters
```

Important command surfaces:

- `--inspect` / `--inspect-only`;
- `--fusion-survey`;
- `--worker-bench`;
- `--swap-bench`;
- `--corpus-survey`;
- `--fusion-cost-lab [--summary]`;
- `--snapshot-check`;
- `--authoring-manifest`;
- `--plugin-list`;
- `--osc-listen`;
- `--midi-list`;
- `--session-midi-smoke`;
- `--session-osc-arbitration-smoke`.

Important runtime files:

- `tinysynth/rt_graph.h`;
- `tinysynth/rt_graph.cpp`;
- `tinysynth/voice_allocator.*`;
- `tinysynth/midi_voice_processor.*`;
- `tinysynth/session_midi_source.*`;
- `tinysynth/rt_graph_plugins.*`;
- `tinysynth/plugins/identity.cpp`.

Important Haskell app/tooling modules:

- `app/MetaSonic/App/Survey.hs`;
- `app/MetaSonic/App/FusionCostLab.hs`;
- `app/MetaSonic/App/ProfitabilityGate.hs`;
- `app/MetaSonic/App/SnapshotCheck.hs`;
- `app/MetaSonic/App/WorkerBench.hs`;
- `app/MetaSonic/App/SwapBench.hs`;
- `app/MetaSonic/App/CorpusSurvey.hs`;
- `app/MetaSonic/App/SessionMidiSmoke.hs`;
- `app/MetaSonic/App/SessionOscArbitrationSmoke.hs`.

The latest recorded session rollup says the full Haskell suite passed
after the Pattern arbitration follow-up:

```text
just stack-test
All 928 tests passed
```

This note does not replace fresh verification before code changes. It
records the state and reasoning at the documentation layer.

## Current Open Questions

The following are open by design, not forgotten.

### Runtime And DSP

- Sample-accurate connected control inputs. Current connected controls
  are mostly block-latched or ignored by port policy.
- Block-rate executor. Per-port metadata exists, but corpus signal is
  still too small.
- Region-level worker dispatch. Substrate exists; default-on policy
  waits for a real workload with counter-confirmed shape and enough
  block cost.
- Env/Delay/Smooth state migration. Current preserving hot-swap support
  is narrower than the full "without audible glitches" phrase.
- Buffer writer cardinality. Same-buffer multiple writers remain
  rejected until an ordering/mixdown primitive exists.
- Buffer ecosystem: file I/O, async loading, multichannel buffers,
  random-access writers, and OSC buffer controls.
- Spectral ecosystem: second spectral kind, spectrum stream types,
  multichannel STFT, runtime-tunable N/hop, and latency compensation.
- Static plugins beyond `Identity`; plugin parameter layout, state
  migration, dynamic loading, plugin-owned UI, MIDI-in plugins, and
  resource-bearing plugin rows.

### Compiler And Optimization

- Generated-fusion peer coverage. The snapshot corpus and wider survey
  disagree on one gate row because peer measurements differ.
- Generated-fusion turn-on policy. No current evidence authorizes it.
- Packed instructions, native codegen, or broader superinstructions.
  All remain gated by a specific measured gap.
- Broader shape-key feature axes in the cost model, once measurements
  show profitability splits by sink kind, latency, resource use, or
  state class.

### Authoring And Session

- Manifest import/reload. Export exists; reload/resource allocation
  does not.
- GUI toolkit binding. UI producer adapter exists for decoded intents;
  there is no concrete toolkit integration.
- Broader OSC grammar beyond symbolic control writes.
- Broader MIDI behavior: channel remapping/splits, MIDI clock,
  aftertouch, long-running device supervision, and policy mutation.
- MIDI routing through service-owned arbitration. OSC/UI/Pattern have
  explicit opt-in paths; MIDI remains gated.
- Arbitration policy mutation API, release/timeout semantics, and
  voice-lifecycle ownership clearing.
- Queue-level coalescing. Explicitly rejected for now; producer-local
  coalescing is the model.
- Two-phase MIDI listener flush locking and two-phase arbitration
  gateway locking. Both wait for contention evidence.
- Session-level respawn/replacement-binding policy for preserving swaps
  that cannot use runtime migration.
- Runtime divergence repair. Current owner divergence is terminal.

## How To Use This Note

For a new node kind, read the tag contract in `Types.hs`,
`Bridge.Source`, `FFI.hs`, `tinysynth/rt_graph.h`, and
`tinysynth/rt_graph.cpp` first.

For optimization work, start from the Phase 4 and Phase 7 notes:
kernel gates, RFused identity preservation, generated-fusion gate
results, and snapshot pins are more authoritative than an intuition
that a shape "should be faster."

For runtime policy work, start from the Phase 5 hot-swap notes, Phase
4.E worker decision, and the session prep notes. Most unsafe-looking
complexity in the current code is there because the project chose to
prove state transitions explicitly instead of hiding them in a runtime
manager.

For user-facing work, start from Phase 8 and session notes. The current
direction is not another low-level runtime push by default. It is a
more practical authoring/session/control surface that continues to feed
the existing compiler and runtime contracts.

The shortest accurate summary of the whole path is:

MetaSonic started as a Haskell-to-C++ audio bridge, became a checked
compiler for dense realtime graphs, grew into a multi-instance
server-like runtime with MIDI, buses, buffers, hot-swap, plugins, and
measurement tools, then added an authoring facade and session fan-in
layer so real producers can control that runtime without weakening the
ahead-of-time guarantees.
