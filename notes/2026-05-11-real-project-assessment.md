# Is MetaSonic Still A Proof Of Concept?

Date: 2026-05-11

Status: project-maturity assessment. This is not a roadmap replacement;
it is a narrative checkpoint answering whether the bridge has crossed
from proof-of-concept into a real, practical system, and what still
keeps it from being a finished real-world application.

## Short Answer

MetaSonic is no longer just a proof-of-concept.

It is not a finished product, and it is not yet a polished musical
environment. But the core architecture is now real enough to carry
future work: the compiler/runtime boundary is explicit, key contracts
are machine-checked, live MIDI and OSC producers exist, shared buffers
have a lifecycle and resource model, spectral latency is declared and
surveyed, hot-swap has a working RCU substrate, and the project has
started making implementation decisions from measured corpus evidence
rather than from hopeful design sketches.

A proof-of-concept proves that an idea can work. This project now
proves something stronger: the idea can be extended while preserving
ahead-of-time guarantees.

## What The Project Is About

The central idea is not "a Haskell wrapper around a C++ synth" and it
is not "a clone of SuperCollider." The project is about a stronger
compile-time contract for live audio.

The working split is:

```text
Haskell DSL -> SynthGraph -> GraphIR -> RuntimeGraph -> C++ DSP Engine
```

Haskell owns structure:

- graph construction;
- validation;
- symbolic-to-dense lowering;
- rate propagation;
- effect/resource analysis;
- template ordering;
- region formation;
- schedule metadata;
- producer-side bindings.

C++ owns execution:

- per-instance DSP state;
- realtime audio callback;
- dense node/region dispatch;
- buses;
- buffers;
- voice allocation;
- MIDI input;
- realtime control queue;
- hot-swap install;
- plugin process callbacks.

The point of the split is that the audio thread should never have to
guess. It should not resolve symbolic names, discover topology,
allocate because a control write targeted a new bus, or decide at
runtime which templates must precede which other templates. Those
decisions are compiler work.

That is the project identity:

> user-facing musical producers create intent; Haskell compiles that
> intent into dense, ordered, resource-aware graphs; C++ executes them
> without symbolic runtime lookup.

## History Of The Project

### 1. The first proof: a compiled graph can run

The earliest meaningful milestone was simply getting a Haskell-built
synth graph to lower into a C++ runtime graph and produce audio. At
that stage the system was closer to a normal proof-of-concept:

- a small source DSL;
- a handful of node kinds;
- dense runtime nodes;
- a C ABI crossing;
- a simple processing loop.

The idea was real, but the contract was still fragile. Adding a node
kind could drift between Haskell and C++; unsupported constructors or
arity mismatches could hide until runtime; testing was not yet broad
enough to make future changes feel safe.

### 2. Phase 0.5: turning the boundary into a contract

Phase 0.5 was the first move away from "demo that works" and toward
"system that can survive growth."

It added:

- machine-checked `kindTag` agreement between Haskell and C++;
- a real Haskell test suite around validation, lowering, region
  invariants, and FFI smoke behavior;
- a documented node-add procedure;
- table-shaped per-kind metadata through `kindSpec` and `ugenView`;
- fewer scattered per-kind clauses, more derivations.

This was important because it changed the failure mode. Before that,
the project could silently drift. After that, new node kinds and ABI
changes had to pass structural checks.

This was the first sign the project was not merely interested in
audio output. It was interested in preserving compiler/runtime
agreement.

### 3. Phase 1: enough DSP vocabulary to be musically meaningful

Phase 1 built out the node registry:

- oscillators: sine, saw, pulse, triangle, noise;
- filters: low-pass, high-pass, band-pass, notch;
- arithmetic: gain and add;
- sinks: out and bus out;
- bus reads: live and delayed;
- envelope;
- delay;
- smoothing.

The most important shift was not just the node count. It was the
runtime state model. Oscillator phase, filters, envelopes, delays,
smoothing state, and noise state all became per-node/per-instance
state living in the C++ runtime. Q supplies the DSP primitives, but
MetaSonic owns the graph shape and dispatch model.

At the end of this phase, the project could describe recognizable
subtractive instruments, not just toy graphs.

### 4. Phase 2: from one graph to templates and instances

Phase 2 changed the runtime model from "one graph is the whole engine"
to "compiled graphs are templates that can have instances."

The big pieces:

- `MetaDef` for immutable template/spec data;
- `GraphInstance` for per-instance state;
- slot reuse;
- server-global bus pool;
- live bus reads and delayed bus reads;
- multi-template runtime;
- compile-time template precedence from bus/resource effects;
- release-then-free lifecycle.

This is where the project started becoming more than a DSP graph
executor. It became a small audio runtime with an instance model.

The declined "groups" decision also mattered. Instead of importing
SuperCollider's manual runtime ordering model, the project chose
compiler-derived ordering from effect/resource annotations. That
decision still shapes everything after it.

### 5. Phase 3: realtime producers and live MIDI

Phase 3 made the runtime playable:

- `VoiceAllocator` maps musical note events onto runtime instance
  reserve/activate/release/remove operations;
- `MidiVoiceProcessor` translates MIDI 1.0 note, CC, and pitch-bend
  events through Q's typed MIDI stack;
- the realtime control queue gives a single producer path into the
  live runtime;
- `Smooth` is inserted at control ingress to avoid zippering;
- the `midi-poly` demo plays a polyphonic MetaSonic instrument from
  an external MIDI controller.

This is a major product-maturity line. A proof-of-concept can render
offline or play a canned patch. A real instrument needs external
input, voice lifecycle, and live control. Phase 3 put those in place.

The project is still not a polished instrument, but after Phase 3 it
is no longer purely offline or purely synthetic.

### 6. Phase 4: regions, fusion, rate metadata, and measurement gates

Phase 4 made the compiler more serious.

It added:

- region formation over runtime nodes;
- hand-written region kernels selected by longest-match priority;
- scalar Gain/Add single-input fusion through `RFused` inputs;
- rate metadata carried into the runtime graph;
- per-port consumption metadata;
- survey tooling for fusion coverage and rate distributions;
- region-level parallelism substrate and worker benchmarks.

Just as important, Phase 4 established an evidence discipline:

- do not add kernels just because a shape is imaginable;
- require corpus recurrence before kernel expansion;
- benchmark fused vs. unfused paths;
- keep worker dispatch default-off unless representative workloads
  actually justify it;
- do not mistake descriptive width metrics for safe execution
  parallelism.

This is a practical-system trait. A proof-of-concept usually adds the
next cool optimization. This project started declining optimizations
when the evidence did not support them.

### 7. Phase 5: hot graph replacement

Phase 5 added a real hot-swap substrate:

- RCU-style pending/installed/retired world swap;
- prepare/publish/install/collect lifecycle;
- state migration through caller-tagged keys and slot identity;
- Haskell helper wrappers for producer ergonomics;
- swap-bench instrumentation;
- template identity preconditions.

The hot-swap story is not "finished" in the product sense. Some state
types still default-init across swaps, and there is no polished
authoring workflow for live patch edits. But the important substrate
exists: a producer can build a next world off-audio and publish it for
block-boundary install without stopping the audio handle.

This moves the project closer to a live system rather than a compile
and-run demo.

### 8. Phase 6: stressing the boundary

Phase 6 started as "extended DSP and ecosystem." In practice, it has
become the boundary-stress phase. Each sub-phase tests a different
kind of real-world pressure on the architecture.

#### 6.A: Pattern corpus

The pattern layer introduced symbolic timed events and a realistic
corpus without adding new C++ runtime substrate. That was the right
first move: use Haskell to produce real shapes, then feed those shapes
through the existing surveys.

6.A gave the project a better way to ask:

- what graph shapes occur naturally?
- which fusion kernels matter?
- whether block-rate opportunities are growing;
- whether worker dispatch has a real workload;
- whether hot-swap friction is hypothetical or observable.

The key maturity point is that patterns are treated as producers of
compiled graphs/events, not as a new audio-thread scheduler.

#### 6.B: OSC control

OSC is the first external control surface beyond MIDI. It added:

- pure OSC wire parsing;
- pure address dispatch;
- identifier validation;
- a bracketed UDP listener;
- end-to-end loopback verification;
- `--osc-listen` CLI wrapper.

The design deliberately keeps OSC on the producer/control side. The
audio thread sees dense control writes through the existing realtime
queue, not OSC strings or symbolic names.

That is exactly the project principle in action.

#### 6.C: Buffer I/O

Buffer I/O made shared resource identity real.

The project now has:

- producer-allocated buffer handles;
- resident mono float32 buffer storage;
- `PlayBufMono` reads with frozen buffer id;
- live-safe retire/collect;
- `ResourceFootprint` with bus and buffer halves;
- buffer write/read precedence;
- `RecordBufMono` as the first audio-thread writer;
- same-buffer writer rejection across templates and inside graphs;
- writer-template polyphony clamped to one from both Haskell loaders
  and C++ ABI backstops.

This is a major move from proof-of-concept to real system. Shared
mutable sample data is where many audio runtimes accumulate subtle
bugs. MetaSonic now has an explicit resource model, lifecycle model,
and conservative writer-safety rule.

#### 6.D: Spectral processing and declared latency

Spectral processing added a new kind of DSP workload:

- fixed-size STFT;
- hop-latched freeze gate;
- per-instance spectral state;
- declared latency through `kindLatency`;
- descriptive latency footprint and skew analysis;
- survey output for declared-latency nodes;
- conservative schedule barrier classification.

The important part is that the project did not immediately add a
latency-compensation pass. It first made latency visible, then used
corpus evidence to decide compensation could stay parked.

Again, this is the practical-system pattern: expose the contract,
measure the need, defer the machinery until it is justified.

#### 6.E: Static plugin hosting

Plugin hosting is open, but the first cut has started:

- `KStaticPlugin` tag and Haskell/C++ surface;
- build-linked plugin registry;
- `identity` reference plugin metadata;
- `--plugin-list`;
- deterministic skeleton behavior;
- design note that explicitly excludes LV2/VST/CLAP/dynamic loading
  from the first slice.

This is the right scope. Real plugin hosting can easily swallow the
project. The static Identity shim is a contract test for hosting,
not a premature product claim.

## Why It Is Already More Than A Proof Of Concept

### 1. It has real contracts, not just working code

The project has many explicit contracts:

- Haskell/C++ kind tag agreement;
- dense `NodeIndex` crossing the FFI, symbolic `NodeID` staying on the
  compiler side;
- effect-induced ordering;
- bus and buffer resource footprints;
- no symbolic audio-thread lookup;
- frozen resource ids for buffer/plugin metadata controls;
- declared latency via `kindLatency`;
- single-writer-single-instance for buffer writers;
- single-producer realtime queue semantics.

Those contracts are not only written down. Many are pinned by tests.

### 2. It has real external control paths

MIDI and OSC are not just planned. They exist:

- MIDI drives polyphonic voice allocation;
- CC and pitch-bend reach per-voice controls;
- OSC packets can update a live graph through a bracketed UDP listener;
- CLI entrypoints exist for listing MIDI devices and listening for OSC.

That is already a practical interaction surface, even if it is still
developer-facing.

### 3. It has shared-resource semantics

Buffers survive clear and hot-swap. Retire/collect is live-safe.
Writers are conservatively restricted. The compiler knows buffer
read/write hazards. This is infrastructure a real application needs.

### 4. It has measurement discipline

The project now has surveys, benches, counters, and decision notes.
It records why some attractive work is parked:

- worker dispatch default-off;
- block-rate execution parked;
- latency compensation parked;
- whole-region codegen deferred;
- extra fusion kernels gated;
- plugin hosting narrowed.

That ability to say "not yet" is a sign of engineering maturity.

### 5. It has regression depth

The tests are not just smoke tests. They check:

- graph structural invariants;
- lowering and dense index contracts;
- C ABI support;
- FFI render paths;
- buffer read/write counters;
- spectral analysis/resynthesis counters;
- OSC parsing/listening/end-to-end behavior;
- MIDI allocator/processor behavior;
- schedule metadata and worker execution equivalence.

Counter-confirmed validation is especially important. Many tests do
not merely assert output samples; they assert the runtime path taken.

## How Close Is It To A Real-World Practical Application?

It is close to being a real engine substrate. It is not yet close to
being a polished end-user application.

Those are different bars.

### Already practical as an engine substrate

The bridge can already support serious internal development:

- write graphs in Haskell;
- compile and run them;
- play a polyphonic instrument from MIDI;
- control a live graph from OSC;
- route across templates through buses;
- use resident buffers;
- record into buffers;
- run a fixed spectral freeze;
- hot-swap worlds at block boundaries;
- survey graph shapes and optimization opportunities.

For a developer-musician comfortable with this repo, the system is
usable as an experimental live-audio engine today.

### Not yet practical as a user-facing application

It is missing the layer that turns engine substrate into product:

- a coherent session model;
- a user-facing composition/pattern API;
- stable project files or patch files;
- an external packaging story;
- install/build documentation for non-maintainers;
- stable CLI workflows for common musical tasks;
- a GUI or TUI that acts as an instrument/control surface rather than
  only an inspector;
- real-world example pieces or performance patches;
- long-running reliability testing;
- error reporting intended for users, not only developers;
- a clear story for combining MIDI, OSC, pattern, and hot-swap
  producers at the same time.

The missing parts are not mostly "more DSP." They are product and
workflow integration.

## What Is Missing Technically

### 1. Session and producer model

The project now has several producers:

- MIDI;
- OSC;
- pattern corpus/events;
- Haskell hot-swap helpers;
- plugin registry / static plugin surface.

What does not yet exist is one coherent session model that says how
these producers coexist:

- who owns the active `RTGraph`;
- who owns voice mappings;
- how OSC resolve state updates after hot-swap;
- how pattern-driven voice lifecycle coordinates with MIDI;
- whether there is a single producer thread or a fan-in queue;
- how conflicts are reported;
- how a user saves/restores the state of a live session.

This is probably the most important missing real-application design.

### 2. Authoring surface

The Haskell DSL is powerful enough for development, but not yet a
complete musical authoring surface. The pattern corpus proves that
musical shapes can be represented. It does not yet offer a polished
way to compose, edit, repeat, transform, and perform those shapes.

Phase 7 should probably focus here before chasing more runtime power.

### 3. User-level diagnostics

The internal diagnostics are strong. User-level diagnostics are still
thin.

A real application needs:

- clear startup checks;
- actionable device/plugin/buffer errors;
- "doctor" output;
- survey snapshot checks;
- readable failed-dispatch logs;
- plugin contract validation;
- external MIDI/OSC smoke tools that do not require reading source.

The recently added offline check and plugin-list tooling are a good
start, but not the full operator story.

### 4. Packaging and deployment

The repo builds locally, but a real-world application needs a stable
environment story:

- dependency installation;
- Q and infra submodules;
- PortAudio/PortMIDI availability;
- platform-specific device behavior;
- reproducible C++/Haskell builds;
- CI split between deterministic and live-audio checks.

The `just check-offline` split is the right direction. It should
eventually become the default CI contract.

### 5. Runtime hardening under long sessions

The runtime has good unit and integration coverage. It still needs
long-duration confidence:

- repeated hot-swaps under audio;
- long MIDI/OSC sessions;
- buffer retire/realloc churn;
- spectral freeze over extended runs;
- device disconnect/reconnect behavior;
- stress tests for the realtime queue;
- memory and thread cleanup under failure paths.

This does not mean the current runtime is weak. It means product-level
runtime confidence needs different tests than commit-level correctness.

### 6. Plugin hosting beyond the static shim

The current 6.E path is intentionally narrow. To become practical as a
plugin host, the project would still need:

- real plugin dispatch for the static Identity reference;
- call/error counters;
- parameter layout;
- plugin latency declaration beyond kind-level constants;
- plugin resource effects;
- plugin state migration or explicit no-migration rules;
- eventually a decision about LV2/VST3/CLAP/AU or a deliberate
  decision not to support them.

That should come after the static contract is proven, not before.

### 7. Deferred engine features with clear gates

Several engine features remain parked:

- sample-accurate connected control inputs;
- block-rate execution;
- latency compensation;
- worker dispatch default-on;
- multichannel buffers and spectral processing;
- random-access buffer writes;
- same-buffer multi-writer mixdown/ordering;
- whole-region kernel codegen.

These should stay gated. They are not missing because the project is
immature. They are missing because the project has learned not to add
runtime complexity without a real workload.

## The Real-World Gap In One Sentence

MetaSonic is already a real compiler/runtime substrate, but it is not
yet a real user-facing musical application.

The next level is not "more features." The next level is coherence:

- one session model;
- one producer story;
- one authoring path;
- one operator/tooling path;
- one packaging/check path.

## Recommended Path From Here

### Step 1: Finish the narrow 6.E static plugin slice

Complete only the bounded work:

- real Identity plugin dispatch;
- process call/error counters;
- plugin registry/metadata checks;
- documented decision about whether kind-level metadata is enough or
  whether per-plugin metadata needs a new compiler representation.

Do not continue into external plugin APIs yet.

### Step 2: Write a project-direction note

This assessment answers "is it real yet?" A follow-up direction note
should answer "what should it become next?"

Candidate title:

```text
notes/2026-05-11-project-direction-after-phase-6.md
```

That note should decide whether Phase 7 is primarily:

- a musical authoring/session layer;
- a runtime-hosting layer;
- a plugin-hosting layer;
- a tooling/productization layer.

My recommendation: Phase 7 should be session + authoring first.

### Step 3: Refresh the roadmap framing

`ROADMAP.md` still frames Phase 6 as if only 6.A were active. That is
now stale. Phase 6 should be reframed as:

```text
Phase 6 - Boundary Stress And Ecosystem Contracts
```

The phase should say that 6.A-6.D are closed at the contract level and
6.E is the open final boundary test.

### Step 4: Promote one practical workflow

Pick one workflow and make it good end-to-end. For example:

1. start a MetaSonic session;
2. load a pattern-backed instrument;
3. play it from MIDI;
4. adjust it from OSC;
5. hot-swap one template;
6. record/play a buffer;
7. inspect/survey what happened.

That would turn the engine substrate into a visible application story.

### Step 5: Keep deferrals honest

Do not reopen parked engine features because they are interesting.
Reopen them when the promoted workflow produces evidence:

- latency skew that needs compensation;
- block-rate ports that save real work;
- worker bands with enough weight;
- plugin resources that require richer `ResourceFootprint`;
- multi-writer buffers with a real musical use case.

## Final Assessment

MetaSonic has crossed the line from proof-of-concept to early real
system.

It has:

- a coherent compiler/runtime split;
- real external control;
- real shared-resource contracts;
- live runtime substrate;
- measurable scheduling/fusion surfaces;
- strong regression tests;
- an evidence-gated roadmap.

It lacks:

- a coherent end-user workflow;
- a session model;
- polished authoring;
- packaging;
- user-level diagnostics;
- long-session validation;
- a complete plugin story.

That is a good place to be. The project is no longer trying to prove
that the architecture can work. It is now deciding what kind of
practical system should be built on top of that architecture.
