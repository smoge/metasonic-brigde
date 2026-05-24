# MetaSonic System Reading Guide

Status: guide / orientation. Snapshot as of 2026-05-24.

This note gives a practical reading order for learning the current
`metasonic-bridge` system from the source tree. It starts with the
compiler pipeline, then branches into authoring, live session, app
wiring, and runtime internals.

The canonical data-flow pipeline is:

```text
SynthGraph → GraphIR → RuntimeGraph → DSP Engine
 (Source)    (IR)      (Compile)      (FFI / rt_graph.cpp)
```

`MetaSonic.Types` is the shared vocabulary every stage speaks; it is
not itself a stage. `MetaSonic.Bridge.Validate` is a gate between
construction and lowering. `MetaSonic.Authoring` sits above the
pipeline as a transparent facade. `MetaSonic.Session.*` and
`MetaSonic.App.*` sit around it. The C++ `tinysynth` runtime sits
below the FFI boundary and executes dense precompiled graph data.

## Core Compiler Pipeline

Read these first, in order:

1. [README.md](../README.md) for the repository-level architecture.
2. [app/MetaSonic/App/Demos.hs](../app/MetaSonic/App/Demos.hs) for
   concrete built-in graphs and demo names. Read these before the
   `Types` vocabulary in step 3 so the abstract terms (`NodeID`,
   `Rate`, `Eff`) land against examples you have already seen.
3. [src/MetaSonic/Types.hs](../src/MetaSonic/Types.hs) for the shared
   vocabulary: `NodeID`, `NodeIndex`, `Rate`, `Eff`, `NodeKind`, and
   the canonical node-kind tag contract.
4. [src/MetaSonic/Bridge/Source.hs](../src/MetaSonic/Bridge/Source.hs)
   for the primitive graph-building surface.
5. [src/MetaSonic/Bridge/Validate.hs](../src/MetaSonic/Bridge/Validate.hs)
   for structural checks before lowering.
6. [src/MetaSonic/Bridge/IR.hs](../src/MetaSonic/Bridge/IR.hs) for the
   first compiler representation, where source-level `UGen` /
   `Connection` values become `NodeIR` / `InputConn` plus semantic
   annotations.
7. [src/MetaSonic/Bridge/Compile.hs](../src/MetaSonic/Bridge/Compile.hs)
   for the top-level runtime-graph compiler facade.
8. [src/MetaSonic/Bridge/FFI.hs](../src/MetaSonic/Bridge/FFI.hs) for
   marshaling dense runtime data across the Haskell/C++ boundary.
9. [tinysynth/rt_graph.h](../tinysynth/rt_graph.h) and
   [tinysynth/rt_graph.cpp](../tinysynth/rt_graph.cpp) for the C ABI
   and the actual DSP execution engine.

Keep the key identity distinction in mind while reading:

- `NodeID` is symbolic and compile-time only.
- `NodeIndex` is dense, ordered, and crosses the FFI boundary.

That distinction is one of the main system invariants.

## Compile Internals

After the facade in `MetaSonic.Bridge.Compile`, read the split
implementation modules under `src/MetaSonic/Bridge/Compile/`:

1. [Types.hs](../src/MetaSonic/Bridge/Compile/Types.hs) for dense
   runtime graph shapes, region types, inputs, kernels, and resource
   footprints.
2. [Dependencies.hs](../src/MetaSonic/Bridge/Compile/Dependencies.hs)
   for bus/resource dependency views and barrier policy.
3. [EdgeRates.hs](../src/MetaSonic/Bridge/Compile/EdgeRates.hs) for
   rate propagation along graph edges.
4. [Latency.hs](../src/MetaSonic/Bridge/Compile/Latency.hs) for
   latency accounting.
5. [Regions.hs](../src/MetaSonic/Bridge/Compile/Regions.hs) for
   region formation.
6. [Schedule.hs](../src/MetaSonic/Bridge/Compile/Schedule.hs) for
   region scheduling metadata.
7. [Fusion.hs](../src/MetaSonic/Bridge/Compile/Fusion.hs) for scalar
   affine fusion.
8. [RegionKernels.hs](../src/MetaSonic/Bridge/Compile/RegionKernels.hs)
   for fused-kernel selection.
9. [FusionProgram.hs](../src/MetaSonic/Bridge/Compile/FusionProgram.hs)
   for generated fusion-program execution data.

The design principle to track here is that all graph semantics, rate
inference, effect analysis, dense lowering, and ordering happen before
the FFI boundary. The C++ runtime should not rediscover graph structure
on the audio thread.

## Authoring Layer

Read [src/MetaSonic/Authoring.hs](../src/MetaSonic/Authoring.hs) after
the core pipeline, not before it.

The authoring layer is a transparent facade. It adds mono/stereo/channel
helpers, routing helpers, ensemble construction, and named controls, but
it lowers back to ordinary `SynthGraph` or `TemplateGraph` inputs. It is
not a second compiler.

Then read:

- [src/MetaSonic/Authoring/Manifest.hs](../src/MetaSonic/Authoring/Manifest.hs)
  for JSON manifest shape.
- [src/MetaSonic/Authoring/Report.hs](../src/MetaSonic/Authoring/Report.hs)
  for authoring metadata reports.

Useful companion note:

- [2026-05-11-l-phase-8-authoring-dsl-design.md](2026-05-11-l-phase-8-authoring-dsl-design.md)

## Session And Live Control

Read the session modules when you want to understand live graph ownership,
producer ingress, preserving hot-swap, OSC/MIDI/UI command flow, or
manifest reload behavior.

Suggested order:

1. [src/MetaSonic/Session/Command.hs](../src/MetaSonic/Session/Command.hs)
   for normalized producer intents.
2. [src/MetaSonic/Session/State.hs](../src/MetaSonic/Session/State.hs)
   for admission, planning, commits, and generation tracking.
3. [src/MetaSonic/Session/RTGraphAdapter.hs](../src/MetaSonic/Session/RTGraphAdapter.hs)
   for the runtime adapter boundary.
4. [src/MetaSonic/Session/Owner.hs](../src/MetaSonic/Session/Owner.hs)
   for caller-scoped graph ownership.
5. [src/MetaSonic/Session/Queue.hs](../src/MetaSonic/Session/Queue.hs)
   for bounded producer intent queues.
6. [src/MetaSonic/Session/FanIn.hs](../src/MetaSonic/Session/FanIn.hs)
   and [src/MetaSonic/Session/FanInService.hs](../src/MetaSonic/Session/FanInService.hs)
   for serialized command ingress and scoped draining.
7. [src/MetaSonic/Session/OSCProducer.hs](../src/MetaSonic/Session/OSCProducer.hs),
   [src/MetaSonic/Session/MIDIProducer.hs](../src/MetaSonic/Session/MIDIProducer.hs),
   and [src/MetaSonic/Session/UIProducer.hs](../src/MetaSonic/Session/UIProducer.hs)
   for concrete producer policies.
8. [src/MetaSonic/Session/OSCListener.hs](../src/MetaSonic/Session/OSCListener.hs),
   [src/MetaSonic/Session/MIDIListener.hs](../src/MetaSonic/Session/MIDIListener.hs),
   and [src/MetaSonic/Session/MIDIPortMIDI.hs](../src/MetaSonic/Session/MIDIPortMIDI.hs)
   for listener/source adapters.
9. [src/MetaSonic/Session/ManifestReload.hs](../src/MetaSonic/Session/ManifestReload.hs)
   and [src/MetaSonic/Session/ManifestReload/Runtime.hs](../src/MetaSonic/Session/ManifestReload/Runtime.hs)
   for manifest-derived reload planning and stopped-audio owner swap.

The producer/listener ingress flow above is one half of the session
layer. The other half is the Pattern-driven host stack, cross-producer
arbitration, and the narrow Prep B/C/D admission/adapter/commit shell.
Read these once the ingress flow is comfortable:

1. [src/MetaSonic/Session/Arbitration.hs](../src/MetaSonic/Session/Arbitration.hs)
   and [src/MetaSonic/Session/ArbitrationGateway.hs](../src/MetaSonic/Session/ArbitrationGateway.hs)
   for pure cross-producer arbitration policy and the opt-in fan-in
   gateway that applies it before commands reach the queue.
2. [src/MetaSonic/Session/AdapterIssue.hs](../src/MetaSonic/Session/AdapterIssue.hs),
   [src/MetaSonic/Session/Runtime.hs](../src/MetaSonic/Session/Runtime.hs),
   [src/MetaSonic/Session/Step.hs](../src/MetaSonic/Session/Step.hs),
   [src/MetaSonic/Session/Resolve.hs](../src/MetaSonic/Session/Resolve.hs),
   and [src/MetaSonic/Session/Report.hs](../src/MetaSonic/Session/Report.hs)
   for the narrow Prep B/C/D adapter contract (admission → adapter →
   commit single-step orchestration), pure OSC resolve-state rebuild
   for [preserving hot-swap](../test/MetaSonic/Spec/Session/PreservingHotSwap.hs),
   and diagnostics-only lifecycle snapshots.
3. [src/MetaSonic/Session/PatternProducer.hs](../src/MetaSonic/Session/PatternProducer.hs),
   [src/MetaSonic/Session/Host.hs](../src/MetaSonic/Session/Host.hs),
   and [src/MetaSonic/Session/Runner.hs](../src/MetaSonic/Session/Runner.hs)
   for the Pattern producer bridge and the scoped serialized
   Pattern-session host.

Useful companion notes:

- [2026-05-20-b-manifest-live-session-v0.md](2026-05-20-b-manifest-live-session-v0.md)
- [2026-05-20-c-compiler-runtime-to-live-system.md](2026-05-20-c-compiler-runtime-to-live-system.md)
- [2026-05-23-c-live-values-portmidi-ingress-design.md](2026-05-23-c-live-values-portmidi-ingress-design.md)
- [2026-05-23-d-vmpk-portmidi-values-manual-test.md](2026-05-23-d-vmpk-portmidi-values-manual-test.md)

## App And CLI Wiring

Read [app/Main.hs](../app/Main.hs) when you want to understand how the
library pieces are exposed as commands.

Useful entry points:

- [app/MetaSonic/App/Demos.hs](../app/MetaSonic/App/Demos.hs) for
  built-in demo graph definitions.
- [app/MetaSonic/App/ManifestLiveSession.hs](../app/MetaSonic/App/ManifestLiveSession.hs)
  for the open-ended manifest live session shell.
- [app/MetaSonic/App/ManifestLiveCommon.hs](../app/MetaSonic/App/ManifestLiveCommon.hs)
  for shared live-session rendering, ingress setup, and value snapshots.
- [app/MetaSonic/App/ManifestLiveIngressOps.hs](../app/MetaSonic/App/ManifestLiveIngressOps.hs)
  for combined live ingress behavior.
- [app/MetaSonic/App/ManifestOSCIngressOps.hs](../app/MetaSonic/App/ManifestOSCIngressOps.hs)
  and [app/MetaSonic/App/ManifestMIDIIngressOps.hs](../app/MetaSonic/App/ManifestMIDIIngressOps.hs)
  for manifest-targeted OSC/MIDI projection.

The wider `ManifestReload*` family in [app/MetaSonic/App/](../app/MetaSonic/App/)
is deliberately not enumerated here. Start from the entry points above
and follow imports: the host stack, supervisor, orchestration, and
per-source binding modules are all reachable that way.

Useful companion note:

- [2026-05-21-c-interacting-with-metasonic-tutorial.md](2026-05-21-c-interacting-with-metasonic-tutorial.md)

## Runtime And C++ Side

After the Haskell FFI module, read:

1. [tinysynth/rt_graph.h](../tinysynth/rt_graph.h) for the public C ABI.
2. [tinysynth/rt_graph.cpp](../tinysynth/rt_graph.cpp) for node storage,
   graph loading, runtime processing, preserving install behavior, and
   DSP state.
3. [tinysynth/rt_graph_plugins.h](../tinysynth/rt_graph_plugins.h) and
   [tinysynth/rt_graph_plugins.cpp](../tinysynth/rt_graph_plugins.cpp)
   for static plugin registration. Concrete plugins live under
   [tinysynth/plugins/](../tinysynth/plugins/).
4. [tinysynth/voice_allocator.h](../tinysynth/voice_allocator.h),
   [tinysynth/voice_allocator.cpp](../tinysynth/voice_allocator.cpp),
   [tinysynth/midi_demo.h](../tinysynth/midi_demo.h),
   [tinysynth/midi_demo.cpp](../tinysynth/midi_demo.cpp), and the
   `tinysynth/*midi*` source files for voice allocation and
   MIDI-specific runtime behavior. The [tinysynth/q_io/](../tinysynth/q_io/)
   subdirectory holds the q_io shim layer.

The C++ side should already receive dense ordered graph data. If a
runtime path needs symbolic graph lookup on the audio thread, treat that
as a design smell.

## Tests As Reading Material

The tests are the best way to see what the repo treats as contractual.

Start with:

- [test/Spec.hs](../test/Spec.hs) for the test suite entry point.
- `test/MetaSonic/Spec/Core*` for structural compiler invariants.
- `test/MetaSonic/Spec/FFI*` for Haskell/C++ boundary behavior.
- `test/MetaSonic/Spec/Feature/*` for authoring, planner, fusion, and
  plugin feature slices.
- `test/MetaSonic/Spec/Session/*` for session ownership, fan-in,
  producer, reload, and hot-swap behavior.
- `test/MetaSonic/Spec/App*` (top-level alongside `Spec/Session/`) for
  the manifest-reload and live-ingress App-layer slices that mirror
  modules under [app/MetaSonic/App/](../app/MetaSonic/App/).
- [tests/rt_graph_test.cpp](../tests/rt_graph_test.cpp) for C++ runtime
  behavior the Haskell tests cannot observe directly.

## Related Artifacts

| File | Symbol / anchor | Why read it |
| --- | --- | --- |
| [README.md](../README.md) | Architecture, Authoring layer, Session preparation APIs | Repository-level map |
| [ROADMAP.md](../ROADMAP.md) | Design Principles | Current system invariants |
| [src/MetaSonic/Types.hs](../src/MetaSonic/Types.hs) | Note [Pipeline reading order] | Canonical short pipeline |
| [src/MetaSonic/Bridge/Compile.hs](../src/MetaSonic/Bridge/Compile.hs) | module header | Compile facade and split-module map |
| [src/MetaSonic/Authoring.hs](../src/MetaSonic/Authoring.hs) | module header | Authoring layer contract |
| [app/Main.hs](../app/Main.hs) | `RunMode`, CLI dispatch | Command entry point |
