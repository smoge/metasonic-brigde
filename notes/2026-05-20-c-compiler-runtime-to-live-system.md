# From Compiler/Runtime Prototype To Live System

Date: 2026-05-20

Status: narrative checkpoint and blog-post seed. Current checkout while
writing: `96e3b95` (`Add --manifest-live-session to
--session-osc-port help`).

This note steps back from the phase-by-phase roadmap and describes the
larger arc: where MetaSonic started, what stayed constant, what changed,
and what the recent manifest live session work says about the direction of
the project. It is not a replacement for `ROADMAP.md`, the focused design
notes, or the test evidence. It is a higher-level story that can become a
blog post once the wording is polished.

Primary source material:

- [README.md](../README.md) - current architecture and user-facing surface.
- [ROADMAP.md](../ROADMAP.md) - phase status, design principles, and
  deferred lanes.
- [Development path to the current state](2026-05-14-c-development-path-to-current-state.md)
  - long-form history through the compiler/runtime/authoring/session
  system.
- [Is MetaSonic still a proof of concept?](2026-05-11-m-real-project-assessment.md)
  - maturity checkpoint before the later manifest-live-session work.
- [Manifest live session v0](2026-05-20-b-manifest-live-session-v0.md)
  - the first open-ended live consumer of the manifest reload supervisor.

## Short Version

MetaSonic started as a bridge: can Haskell describe a synth graph, lower it
into dense runtime data, and have C++ execute it in a realtime audio
callback?

It is now becoming a contract-driven live music system where authoring,
manifests, OSC/MIDI/UI ingress, reload policy, runtime state migration,
and operator feedback all sit on top of the same core split:

```text
Haskell owns meaning. C++ owns execution.
```

The project is not trying to become a dynamic runtime graph interpreter.
It is trying to make live audio feel flexible while keeping the runtime
simple, dense, and prevalidated.

That is the main through-line:

```text
Haskell DSL -> SynthGraph -> GraphIR -> RuntimeGraph -> C++ DSP Engine
```

The user and producer layers can become more musical, but they should not
move structural responsibility back into the audio thread.

## The Original Shape

The first meaningful milestone was ordinary and important: a graph built in
Haskell could cross the FFI boundary and produce sound in C++.

At that point, the system was close to a normal proof of concept:

- a small Haskell source DSL;
- a handful of node kinds;
- a C ABI in `tinysynth/rt_graph.h`;
- a C++ runtime in `tinysynth/rt_graph.cpp`;
- a demo runner in `app/Main.hs`;
- PortAudio/Q producing realtime audio.

The early danger was equally ordinary: if the C++ runtime had to resolve
symbolic graph facts at audio time, the whole system would drift toward the
same dynamic machinery MetaSonic was trying to avoid. The durable correction
was dense runtime lowering. `NodeID` remained symbolic and compile-time.
`NodeIndex` became dense, ordered, and ABI-facing.

That decision is still load-bearing. Buses, buffers, template ordering,
region formation, fusion, hot-swap, plugin dispatch, and manifest reloads
all depend on the runtime receiving pre-resolved identities rather than
discovering structure while audio is running.

## The Rule That Stayed Constant

The project has grown a lot, but its central rule has not changed.

Haskell owns graph meaning:

- source-level construction;
- validation;
- symbolic-to-dense lowering;
- rate propagation;
- effect and resource analysis;
- latency metadata;
- template ordering;
- region formation;
- survey and planner diagnostics;
- authoring-layer elaboration;
- manifest validation and symbolic command admission.

C++ owns execution:

- the realtime audio callback;
- dense node and region dispatch;
- per-instance DSP state;
- Q-backed oscillators, filters, envelopes, delays, smoothing, MIDI, and
  audio I/O;
- bus and buffer pools;
- voice allocation;
- realtime control queues;
- hot-swap installation;
- static plugin process callbacks;
- low-level ABI backstops.

The audio thread should not resolve symbolic names, infer topology, grow
resource pools because a command mentioned a new object, decide which
template precedes another template, or choose whether a graph fragment is
safe to fuse. Those are compiler-side responsibilities.

This is why "Haskell compiler plus C++ runtime" is not just an
implementation detail. It is the product shape. The more live the system
becomes, the more important the split becomes.

## What The Split Buys

Four consequences fall out of putting graph meaning on the Haskell side
and execution on the C++ side. They are not features; they are properties
the rest of the project keeps inheriting.

**Failures move earlier.** A planning rejection, an arity drift between
the Haskell `kindSpec` row and the C++ dispatch tag, a manifest that
names a demo the catalog does not bind: all of these surface in the
compiler, the test suite, or the planner before any audio runs. The
audio thread does not get to fail in those ways because the audio thread
does not get to decide them.

**The audio thread stays boring.** The realtime callback dispatches a
dense schedule against preallocated state. It does not resolve symbolic
names, grow resource pools, decide template order, or evaluate
fusion-safety. Each of those decisions has a deterministic answer at
compile time, and the test suite pins those answers. The audio thread's
job is to be fast, predictable, and dumb.

**Live reloads can be recoverable because plans are explicit.** The
supervisor primitive only works because the "fallback plan" and the
"requested plan" are first-class values, captured at reload entry, that
can be re-installed independently. If plans were implicit in some live
runtime topology, "go back to the previous one" would not be a
well-defined operation. The recovery model is a direct dividend of the
plans-are-values rule.

**Authoring can get nicer without making runtime semantics fuzzy.** The
authoring layer elaborates into ordinary `SynthGraph` / `TemplateGraph`
values that the existing compiler validates. Sugar can grow at the
authoring layer without changing what the runtime sees or how fusion,
ordering, and resource analysis reason about it. The user-facing surface
can keep getting more ergonomic; the audio thread's contract does not
drift.

## How The Prototype Became A System

The growth path has been less about adding isolated features and more
about turning implicit assumptions into explicit contracts.

### 1. DSP Vocabulary Became A Compiler/Runtime Contract

The early node set grew into a real subtractive synthesis vocabulary:
oscillators, noise, filters, arithmetic, envelopes, delay, smoothing, bus
reads/writes, buffers, spectral processing, and static plugins.

But the important lesson was that a UGen is not "just a DSP function."
Adding a kind crosses the whole bridge:

- `NodeKind` and `kindSpec` on the Haskell side;
- source-level `UGen` constructors and views;
- validation and lowering behavior;
- FFI layout;
- C++ tag decoding;
- C++ node configuration and per-node state;
- dispatch in the runtime processing path;
- tests that catch tag, arity, metadata, and behavior drift.

That changed the project from "can we make sound?" to "can we safely grow
the language of sound?"

### 2. The Runtime Became Stateful Without Becoming Symbolic

Once filters, envelopes, delays, smoothers, buffers, voices, and plugins
entered the system, the runtime had to own real state. That state belongs
in C++, close to the audio callback. The compiler should describe where
state exists and how it is addressed; it should not try to simulate runtime
state in Haskell.

The key distinction is that runtime state does not imply runtime graph
semantics. Filter memory, oscillator phase, delay lines, voice slots,
buffers, and plugin state are dynamic. The graph identities, ordering,
rates, effects, and resource policy are still compiled.

That distinction made later preserving reloads possible. A live reload can
try to keep compatible runtime state only because the compiler/runtime
contract gives both sides stable identities and explicit metadata.

### 3. Templates And Resources Replaced Manual Runtime Ordering

The project then moved from "one graph is the engine" to a multi-template
model: immutable template definitions, graph instances, bus pools,
compile-time inter-template precedence, and release-then-free lifecycles.

This is one of the places where MetaSonic most clearly diverges from a
SuperCollider-style mental model. Instead of asking the user to manage
groups and node order at runtime, MetaSonic tries to compute safe ordering
from graph structure and effect/resource annotations.

That choice makes the compiler more responsible, but it removes a whole
class of runtime superstition. The user should not have to remember that a
reader must be placed after a writer if the compiler can prove that from
the bus footprint.

### 4. Regions, Fusion, And Performance Became Evidence-Gated

The project also explored optimization: region overlays, hand-written
fused kernels, affine Gain/Add chain fusion, generated program ABI
experiments, block-major and superinstruction probes, and cost-lab
tooling.

Crucially, this work did not turn into "turn on every clever runtime
idea." Region-level parallelism is present as a tested substrate but
remains default-off. Generated fusion has an ABI and executor experiments,
but broad turn-on remains behind measurement and cost-model evidence.
The project is willing to build measurement tools before expanding the
runtime, and is not chasing cleverness for its own sake.

### 5. Phase 6 Extended The Edges Of The System

Pattern, OSC, buffers, spectral processing, and plugins made the system
look less like a closed compiler exercise and more like a real audio
environment.

The same rule held:

- patterns produce structured session intent, not audio-thread schedule
  magic;
- OSC resolves symbolic control paths before writing commands;
- buffers have explicit lifecycle and resource contracts;
- spectral kinds declare latency and stay visible to planning;
- static plugins are registered, bounded, cataloged, and tested across the
  Haskell/C++ boundary.

The recent `oneTapDelayPlugin` work is a good example. It was not just
"add a delay plugin." It forced catalog rows, bounds checks, per-instance
state, latency accessors, runtime registry agreement, and Haskell-side
audio/state tests to line up.

### 6. Phase 8 Turned Authoring Into A Transparent Layer

The authoring layer is where the project starts to become nicer to use.
`MetaSonic.Authoring` adds typed channels, lifted helpers, routing helpers,
ensembles, named controls, reports, and manifest export.

The important boundary is that authoring does not become a second compiler.
It elaborates down to ordinary `SynthGraph` and `TemplateGraph` values.
All ordering, resource, latency, fusion, migration, and runtime loading
still flow through the existing compiler pipeline.

That is the right product direction: make patches shorter and safer
without hiding the generated graph from the tools that prove it is safe.

## The Recent Turn: From Demo Smokes To A Session Product

The manifest reload supervisor work is where the system starts feeling
like an actual live application rather than a collection of validated
subsystems. Before the live session shell, the supervisor migration arc
brought all three audible reload routes (stopped-audio, try-preserving,
require-preserving) onto a single recovery primitive with tier-2 evidence
on real hardware. Substantial work, but still infrastructure. Every
operator path was two-shot: start on one plan, reload once, observe, exit.

`--manifest-live-session` changes the pressure on the design. It opens a
manifest-backed plan, starts audio, opens ingress, keeps serving, and lets
the operator type commands:

```text
demo:KEY   supervised reload to KEY
<Enter>    print current status
<Ctrl-D>   exit cleanly
```

That looks small, but it changes what the next design questions mean.
Consumer-gated questions are no longer abstract:

- What should stale-command rejection look like to an operator?
- What resource/allocation recovery events are useful after escalation?
- What should a GUI bind to?
- What does "request rejected but the previous stack is still live" look
  like in a real session?
- What evidence threshold is enough before a route belongs in CI?

The session shell is not a polished product. It is the first honest
consumer that makes those questions concrete.

## One Reload, End To End

The clearest way to see what the compiler/runtime split actually does is
to follow one operator-typed `demo:KEY` command through the system.
Imagine a live session running on the `preserve-cutoff-dark` plan; the
operator types `demo:preserve-cutoff-bright` and presses Enter.

```text
authoring manifest
  -> manifest catalog validation
  -> ManifestReloadPlan
  -> ingress target projection
  -> supervised reload request
  -> in-window orchestration  (Haskell sequences; C++ keeps executing)
  -> classified outcome       (Committed / RequestRejected /
                               RejectedRecovered / Escalated)
  -> current plan + operator status line
```

Step by step:

1. **Stdin parse.** `parseLiveSessionCommand` (pure Haskell) reads
   `demo:preserve-cutoff-bright\n` and produces `LscReloadTo
   "preserve-cutoff-bright"`. The audio thread is unaware that anything
   was typed.

2. **Catalog lookup.** Haskell resolves the key against the in-process
   `demoTable`. A missing key becomes `LsoPlanRejected` immediately; the
   session prints a one-line rejection and keeps serving. The C++ runtime
   is still executing the dense schedule for `preserve-cutoff-dark`,
   unchanged.

3. **Planning.** `planManifestReloadForDemo doc catalog demo` validates
   the manifest against the catalog and produces a static
   `ManifestReloadPlan`: a validated template graph, control surface
   bindings, arbitration policy. A validation failure here is also a
   command-level reject; the audio thread still never hears about it.

4. **Ingress target projection.** `manifestReloadIngressTargetFromPlan`
   computes the OSC / MIDI / UI surface the new plan would expose. A
   duplicate CC mapping or a malformed control binding rejects here.
   Pre-supervisor, pre-audio-side.

5. **Supervised reload request.** `reloadSupervised` is invoked with the
   captured-at-entry fallback plan (still `preserve-cutoff-dark`) and the
   new requested plan (`preserve-cutoff-bright`). The fallback is a
   per-reload local, not history accumulated.

6. **In-window orchestration.** For the require-preserving route,
   `realPreservingInWindowReload` re-projects fresh old / new ingress
   targets from the plan pair, then drives the orchestrator: quiesce
   ingress, drain accepted commands, install the new preserving owner,
   resume ingress. The C++ runtime is still on the audio thread,
   executing the previous plan's dense schedule the entire time. It does
   not pause, it does not "ask" the supervisor anything.

7. **Classification.** The orchestrator returns a
   `HostPreservingReloadIssue` (or success). `classifyPreservingOutcome`
   maps it to one of three `InWindowReloadOutcome` variants. The
   supervisor lifts that into a four-variant `SupervisedReloadOutcome`
   (Committed / RequestRejected / RejectedRecovered / Escalated).

8. **Operator-facing outcome.** `stepFromOutcome` projects to
   `(LiveSessionOutcome, SessionStep)`. The session updates `currentPlanRef`
   only on Committed; on RequestRejected the previous plan stays the
   live one; on RejectedRecovered the supervisor has already closed the
   broken stack and rebuilt from the captured fallback (the tracking
   IORef points at the rebuilt stack); on Escalated the session exits
   non-zero.

9. **Runtime state.** Whichever outcome lands, the C++ runtime either
   keeps executing the previous dense stack (request-rejected), installs
   the requested dense stack (committed), or closes the broken stack and
   opens a fresh fallback stack (rejected-recovered). The audio callback
   never sees a partial graph, a symbolic name, or a question about
   ordering.

The shape of that walkthrough is the contract: every decision lives in
Haskell, the runtime receives a fully-formed dense schedule (or
doesn't), and recoverability falls out of plans being first-class values
that can be captured and re-installed.

A SuperCollider-style equivalent would have to encode many of these
decisions as server-side operations against a live tree. The runtime
surface would grow each time the language did. Here, the runtime grows
only when a new DSP kernel needs to exist, and even then, the kernel-add
gate forces a measurement, a kindSpec row, a tag, and a Haskell/C++ drift
test before it lands.

## Current Maturity

The project is past proof-of-concept, but not finished. The substrate is
in place; the hard questions are no longer about whether sound can be
generated. They are about how a musician sees, controls, and recovers a
live session.

It has:

- a real compiler/runtime boundary;
- a meaningful DSP vocabulary;
- machine-checked Haskell/C++ drift guards;
- dense runtime execution;
- multi-template instances;
- resource-aware ordering;
- buffer and spectral contracts;
- static plugin dispatch;
- live MIDI and OSC ingress;
- preserving hot-swap for eligible cases;
- supervised reload recovery;
- manifest-backed live sessions;
- deterministic offline tests and opt-in live hardware smokes.

It does not yet have:

- a polished user-facing composition environment;
- a GUI session surface;
- broad plugin hosting beyond static in-tree plugins;
- hardware-backed CI for device paths;
- a final stale-command policy visible in the live session;
- allocation/resource event streaming surfaced to an operator;
- a general runtime fusion turn-on policy.

That is the right kind of incomplete. The remaining gaps are product /
workflow and operator semantics, not proof that the compiler/runtime
idea works.

## Where It Is Going

The strongest path from here is not "more runtime cleverness first." It is
session and authoring coherence: making the system pleasant to use without
moving any structural responsibility back into the audio thread.

The live session shell is now the design pressure. Every next slice gets
judged against it, not against an abstract architecture diagram. The
parked lanes from earlier -- generated fusion, hardware-backed CI,
resource/allocation event streaming -- were parked because no concrete
consumer needed them yet. The session shell is the first one that might,
and the design decisions it surfaces are concrete in a way they were not
two months ago.

The most likely next slices, in rough priority order:

- **Stale-command rejection rendering.** The session already accepts OSC
  writes during a hot-swap window. The current accept-line print does not
  distinguish "accepted pre-reload" from "accepted but rejected at enqueue
  time during the swap." A small operator-facing line for the latter is
  the cleanest consumer-driven next slice.
- **Resource/allocation recovery events.** Now that the operator can hit
  a real `SupervisedReloadEscalated` path, a per-attempt allocation
  summary becomes useful evidence rather than abstract telemetry.
- **Targeted tier-2 fan-out.** If the require-preserving session adopts,
  the other two strategies get session wrappers on the same shape. Until
  then, one wrapper is enough.
- **GUI or richer control binding.** Only after the stdin shell proves
  what the operator semantics should be. The session shell exists to
  answer that question before a GUI tries to.

The practical direction is the same one the project has had since the
dense-lowering decision: build the smallest real consumer that keeps the
compiler/runtime guarantees intact, and let that consumer drive what
comes next.

## What This Is Not

The shape of what MetaSonic is becoming is easier to see in contrast to
what it is explicitly not.

- **Not a DAW.** No timeline, no clip arrangement, no mixing surface, no
  recording. The session is a live engine, not an editor.
- **Not a SuperCollider clone.** Server-side ordering primitives (group
  reparenting, head/tail/before/after) are intentionally absent; ordering
  is decided at compile time and the runtime executes it. The cultural
  ancestry is there; the design choice is the opposite.
- **Not a dynamic graph interpreter.** The runtime does not analyze
  dependencies, infer topology, or evaluate symbolic names. It executes
  whatever dense schedule the Haskell side compiled.
- **Not a plugin host first.** Static in-tree plugins exist as a
  registered, bounded, cataloged surface. VST/AU/LV2 hosting is not on
  the slate; if it lands, it lands through the same contract every other
  node kind does.
- **Not a GUI-first project.** The first operator surface is a stdin
  shell because the question "what should the operator see?" is itself
  open. A GUI binds to a settled answer, not the other way around.

These are not deferrals. They are shape decisions. A different choice on
any of them would push structural responsibility back into the audio
thread, which is the one place this project keeps choosing not to put it.

## Supplement: Chronological Change History

This is not a complete commit log. It is the chronological path of the
architecture: the changes that explain how a Haskell-to-C++ bridge became
the current compiler/runtime/session system.

1. **Bridge skeleton and dense runtime.** The first useful system was a
   Haskell graph builder, a C ABI in `tinysynth/rt_graph.h`, a C++ runtime
   in `tinysynth/rt_graph.cpp`, and a demo runner. The important correction
   was dense runtime lowering: symbolic `NodeID`s stayed on the Haskell
   side, while dense `NodeIndex` values crossed the ABI.

2. **Boundary hardening.** As soon as the node set grew, drift became the
   main risk. The project added `kindSpec` tables, `UGen` views, tag/arity
   checks, FFI smoke tests, and C++ support assertions so a new runtime kind
   had to be accepted by both sides of the bridge.

3. **DSP vocabulary and per-instance state.** The runtime gained the
   subtractive vocabulary: oscillators, noise, filters, gain/add, envelopes,
   delays, smoothing, buses, buffers, spectral nodes, and static plugins.
   The state model moved into C++ per-node/per-instance storage, while graph
   meaning stayed compiled.

4. **Templates, instances, and buses.** The runtime moved from one graph to
   immutable templates plus live instances. `MetaDef` / `GraphInstance`,
   slot reuse, server-global buses, live and delayed bus reads, and
   release-then-free lifecycle made it a small audio runtime rather than a
   single graph executor.

5. **Compiler-derived resource ordering.** Multi-template routing forced a
   decision: import manual server-side ordering, or compute precedence from
   effects and bus footprints. The project chose compiler-derived ordering.
   That declined a SuperCollider-style group model as a runtime primitive.

6. **Realtime producers and live control.** MIDI, voice allocation, the
   realtime control queue, per-voice CC/pitch-bend, and automatic smoothing
   made the system playable. This was the first line where the project
   became an instrument host rather than only an audio compiler.

7. **Regions, fusion, and measurement discipline.** Region overlays,
   hand-written fused kernels, affine Gain/Add fusion, region-worker
   experiments, generated-program ABI work, and the fusion cost lab all
   explored performance. The main decision was restraint: runtime
   parallelism and broad generated fusion remain evidence-gated.

8. **Phase 6 edges: pattern, OSC, buffers, spectral, plugins.** The system
   gained structured producers and resource-bearing extensions without
   moving semantics into the runtime. Patterns become session intent, OSC
   resolves symbolic paths before enqueue, buffers carry lifecycle and
   resource policy, spectral nodes declare latency, and static plugins get
   catalog rows plus Haskell/C++ registry tests.

9. **Authoring as transparent elaboration.** Phase 8 made patch authoring
   more pleasant through typed channel wrappers, lifted helpers, routing,
   ensembles, named controls, reports, and manifest export. The boundary
   stayed strict: authoring elaborates to ordinary `SynthGraph` /
   `TemplateGraph` values, then the existing compiler remains the authority.

10. **Session substrate.** Session commands, checked plan/commit semantics,
    runtime adapters, a single-threaded owner, queues, fan-in services, OSC
    and MIDI producers/listeners, UI producers, and preserving hot-swap gave
    the project a controlled live-command layer. This made "live" a
    library-owned protocol instead of scattered demo code.

11. **Manifest reload planning.** Authoring manifests became operational:
    a decoded manifest can be validated against a catalog, projected into a
    `ManifestReloadPlan`, and turned into OSC/MIDI/UI ingress targets. The
    plan became the value that connects authoring, session control, and
    runtime reload policy.

12. **Reload supervisor and three audible strategies.** Stopped-audio,
    preserving, and try-preserving reloads converged on one supervisor
    primitive with four outcomes: committed, request-rejected,
    rejected-recovered, and escalated. Tier-2 live smokes confirmed the
    strategies locally, while hardware-backed CI stayed deferred.

13. **Manifest live session.** `--manifest-live-session` is the first
    open-ended consumer of that whole stack. It starts from a manifest-backed
    plan, opens audio and ingress, accepts `demo:KEY` reload commands, prints
    status, and keeps serving. This is the current inflection point: future
    stale-command, allocation-event, GUI, and hardware-policy decisions now
    have a real session timeline to answer to.

The broad arc is simple:

```text
single graph -> dense ABI -> stateful runtime -> templates and resources
             -> live producers -> reload supervisor -> live session
```

## Blog Post Jump-Off

Possible title:

> From Synth Graph Compiler To Live Audio System

Alternative titles:

- Why MetaSonic Keeps The Audio Thread Boring
- Haskell For Meaning, C++ For Sound
- Turning A Compiler/Runtime Prototype Into A Live Instrument

Possible hook:

> The first version of MetaSonic answered a narrow question: can a Haskell
> graph compile into a C++ audio callback? The current version answers a
> more interesting one: how far can a live music system go while keeping
> graph meaning out of the audio thread?

### Spine: the human arc

The blog version should be less phase-heavy than this note. The durable
engineering record below keeps the phase names; the public narrative
should hang off four lines and let everything else attach to them:

```text
First we made sound.
Then we made the boundary safe.
Then we made the runtime real.
Now we are making the system usable without giving up the boundary.
```

Map the outline directly onto that spine:

**First we made sound.**
- The initial bridge: Haskell graph in, C++ audio out.

**Then we made the boundary safe.**
- The first hard rule: dense indices cross the ABI; symbolic names do
  not enter the audio thread.
- Growing without drifting: node metadata, tests, FFI guards.

**Then we made the runtime real.**
- From one graph to a runtime: templates, instances, buses, voices, MIDI,
  resources.
- Optimization with evidence: regions, fusion, worker paths, and why most
  clever runtime work stays gated.
- Authoring without a second compiler: higher-level patch syntax that
  still lowers to transparent graphs.

**Now we are making the system usable without giving up the boundary.**
- The live session turn: manifests, supervised reloads, preserving
  state, and the new `--manifest-live-session`.
- The next question: not "can it make sound?" but "can it be a useful
  live instrument while preserving the contract?"

The walkthrough section ("One Reload, End To End") in the durable note
above is the single piece of concrete material the blog post most needs.
Lead with it, or place it at the inflection point between the "runtime
real" and "system usable" arcs, depending on whether the public reader
needs to see how the contract pays off before they care about why it
matters.

### Core argument

1. A live audio system does not need to be dynamically symbolic in order
   to be flexible.
2. MetaSonic puts symbolic structure, ordering, resources, rates, and
   migration policy on the compiler side.
3. The runtime stays dense and strict, but still owns the realtime state
   that must live near the audio callback.
4. The newest work is not another DSP node or benchmark. It is the first
   manifest-backed live session, which forces the infrastructure to serve
   an operator across multiple reloads.

### Phrases worth keeping

- "The audio thread should execute decisions, not make them."
- "Runtime state is dynamic; runtime graph meaning is not."
- "The authoring layer is ergonomic, not semantic."
- "The live session shell is small on purpose. It is a consumer, not a
  framework."
- "The project is past proof-of-concept; the remaining work is product
  coherence."

### Claims to avoid overstating

- Do not call reloads seamless in the general case. Some routes preserve
  state; others intentionally stop audio or rebuild.
- Do not imply generated fusion is the default runtime path. It remains
  evidence-gated.
- Do not imply hardware-backed CI exists. Device paths are still covered
  by opt-in tier-2 smokes, with tier 3 deferred.
- Do not imply Phase 8 authoring is a new compiler. It elaborates into the
  existing compiler pipeline.
