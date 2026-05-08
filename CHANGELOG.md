# Changelog

This project does not have tagged releases yet. This changelog groups the
commit history through `afa4d0f` (2026-05-08) by architectural milestone rather
than listing every commit. It focuses on major behavior changes and design
decisions that future work should preserve.

## Current Head: 2026-05-08

MetaSonic Bridge is now a checked Haskell-to-C++ graph compiler and runtime
bridge:

- Haskell builds `SynthGraph`s, validates and lowers them, assigns dense
  runtime indices, forms regions, selects fusion opportunities, and loads the
  runtime through the FFI.
- C++ owns realtime execution: DSP state, buses, instances, MIDI voice
  allocation, realtime control queues, Q-backed kernels, and audio callback
  integration.
- The runtime supports multiple graph instances, multi-template send/return
  routing, release-then-free lifecycle, live MIDI control, scalar affine
  fusion, selected hand-written region kernels, and per-region dependency
  metadata for future scheduling.

Design decision: symbolic `NodeID`s remain compiler-only. Dense `NodeIndex`
values are the ABI and runtime identity.

## 2026-05-08: Region Scheduling Foundations

Major changes:

- Added per-region bus footprint metadata.
- Split region dependency views into:
  - bus-only precedence,
  - structural cross-region port dependencies,
  - combined region dependencies.
- Settled dynamic bus-control handling for future schedulers by marking live-bus
  regions as barrier regions.
- Added `regionHasLiveBus` and `isLiveBusKind`.
- Documented the scheduler contract before adding worker threads.
- Added the checked deterministic linear scheduler surface:
  `regionSchedule` and `scheduledRuntimeRegions`.
- Added the §4.E layered schedule representation:
  `ScheduleStep`, `FreeLayer`, `SharedWriteHazard`, and
  `layeredRegionSchedule`. Barriers remain pinned steps; non-barrier
  segments become stable topological free layers.
- Extended `--fusion-survey` schedule reporting with runnable-vs-reduction
  width columns:
  - per-graph: `runW`, `redW`, `haz`;
  - cross-template: `tplRunW`, `tplRedW`, `tplHaz`.

Design decisions:

- A future region scheduler must consume explicit dependency metadata; it should
  not infer ordering by re-reading node internals at runtime.
- `KBusIn`, `KOut`, and `KBusOut` are live-bus kinds and must stay on the
  barrier path because their bus controls can be changed dynamically.
- `KBusInDelayed` is not a live-bus barrier for same-block dependencies because
  it reads the previous block.
- `regionSchedule` remains the deterministic linear fallback. The layered
  representation is descriptive only; it does not authorize runtime
  parallelism.
- A non-zero `redW` / `tplRedW` is evidence for a later deterministic
  bus-reduction design, not something the current runtime may execute
  concurrently.

## 2026-05-07 to 2026-05-08: Region Kernels And Fusion Evidence

Major changes:

- Added runtime region kernel tags and region dispatch in the C++ executor.
- Implemented hand-written region kernels:
  - `RSawLpfGain`
  - `RSinGainOut`
  - `RSawLpfGainOut`
  - `RSawGainOut`
  - `RNoiseGainOut`
  - `RBusInLpfGainOut`
  - `RNoiseLpfGainOut`
- Made `KBusOut` a sink terminal alongside `KOut`.
- Added longest-match selection and support for both 3-node and 4-node kernels.
- Added stripped node-loop baselines for bit-equivalence tests, so a broken
  region kernel cannot pass by comparing against itself.
- Added `SinkAccumulator` and `drive_oscillator` as narrow C++ helpers for
  repeated sink-terminal boilerplate.
- Added `tools/rt_graph_bench.cpp` to compare fused kernels against node-loop
  execution.
- Added `--fusion-survey` and CLI/TUI reporting for selected region kernels,
  missed kernel opportunities, and coverage over demos plus a fixed corpus.
- Reorganized the survey corpus around `shape/`, `mod/`, `neg/`, and `ens/`
  categories with a separate `surveyShapeProbes` / `surveyEnsembleCorpus`
  split, and extended the opportunity scan into a ranked missed-shape table
  with `sources`, `status`, and `next` columns plus an explicit
  `missed ≥ 3 ∧ sources ≥ 3` candidate gate.
- Used survey data to add `RSawGainOut`, `RNoiseGainOut`, and
  `RBusInLpfGainOut`. After the corpus expansion the ranked table promoted
  `Noise → LPF → Gain → sink` past the gate (`missed=4, sources=4`) and
  `RNoiseLpfGainOut` was unparked; benchmark median ~1.25x cleared the
  sink-kernel win threshold.
- Tri/Pulse/Add filtered-tail shapes (`SinkAddLpfGain` was added to the
  classifier so the Add probe is formally visible) remain parked as
  singleton-source `no-signal` rows in the same scan; no kernel was added
  on speculation.

Design decisions:

- Sink-terminal kernels are the strongest proven region-kernel class because
  they remove dispatch, avoid intermediate materialization, and absorb bus
  accumulation plus peak tracking.
- Buffer-terminal kernels can still help, but they are less decisive because
  they often still need to materialize an externally visible output buffer.
- New stateful/filter region kernels should clear a gate: repeated survey
  recurrence, benchmark win, stripped-baseline bit-equivalence, and edge-case
  parity with the node-loop path.
- Full generated region-kernel codegen is deferred. The current evidence favors
  hand-written DSP bodies plus narrow helpers.
- Optimization must preserve control identity: nodes may be elided from
  dispatch, but their `NodeIndex` and controls remain addressable.

## 2026-05-07: Scalar Affine Fusion

Major changes:

- Added `RFused` inputs, fused input descriptors, and `rnElided` nodes.
- Implemented scalar `Gain` fusion for single-use edges.
- Extended fusion through chains of scalar `Gain`.
- Added scalar `Add` / bias fusion.
- Composed scalar Gain and Add into affine chain rewrites.
- Added fused-aware FFI loaders.
- Added bit-equivalence, control-identity, and property-based fused-vs-baseline
  tests.
- Added the `--fused` demo option for normal app use.

Design decisions:

- Cheap single-input algebra should be exhausted before larger region codegen
  work.
- Fusion uses compiler-visible facts such as consumer counts, input shapes, and
  region membership rather than runtime graph inspection.
- Scalar affine fusion and region kernels must coordinate: when a region kernel
  claims a member node, scalar fusion steps aside.

## 2026-05-07: Runtime Regions And Use Metadata

Major changes:

- Lifted runtime regions into the FFI/runtime data model.
- Added region indices, region kernel tags, and region overlay support.
- Added per-node output-use classification.
- Added consumer counts used by fusion safety gates.
- Relaxed region compatibility for compile-rate nodes.

Design decisions:

- Region metadata is first-class runtime data, not a debug-only compiler view.
- Region members keep their node state and `NodeIndex`; fused region kernels
  reuse existing runtime nodes instead of inventing anonymous state.
- Region selection must preserve deterministic order and explicit fallback to
  node-loop dispatch.

## 2026-05-07: Live MIDI And Voice Control

Major changes:

- Added a C++ `VoiceAllocator` over the realtime instance ABI.
- Added `MidiVoiceProcessor` to translate MIDI 1.0 events into voice allocator
  actions.
- Wired per-voice CC and pitch-bend dispatch.
- Added `Smooth` based on `q::dynamic_smoother` for de-zippered control input.
- Added a `cc` builder that auto-inserts `Smooth` at control ingress.
- Added a live-MIDI demo path and Haskell wrapper.
- Vendored required Q MIDI files and patched integration issues.
- Hardened live-MIDI no-device behavior and FFI exception boundaries.

Design decisions:

- Live event dispatch and voice management stay in C++.
- Haskell compiles structure and control mappings; it does not run the live MIDI
  event loop.
- Realtime voice activation uses explicit reserve / prepare / activate steps.
- The `Reserved` slot state is for the queued realtime path, not ordinary
  offline graph construction.

## 2026-05-06 to 2026-05-07: Realtime Instance Pool And Control Queue

Major changes:

- Replaced optional graph instances with a fixed-shape instance pool.
- Added atomic slot states.
- Added SPSC control queue storage and audio-thread draining.
- Added realtime reserve / prepare / activate ABI.
- Split bus-pool growth out of `rt_graph_instance_set_control` into
  `rt_graph_ensure_bus`.
- Removed direct instance bus-reading ABI.
- Preserved vector capacity on state reuse and cleared inactive output buffers
  to avoid stale data.
- Documented the C ABI thread-safety contract.

Design decisions:

- The audio thread should not allocate or perform general construction work.
- `Reserved` slots are invisible to the audio schedule until activation.
- Bus-pool growth is an explicit non-audio-thread operation.

## 2026-05-06: Multi-Instance And Multi-Template Runtime

Major changes:

- Split immutable template data from per-instance state:
  - `MetaDef` / node specs,
  - `GraphInstance` / node instance state.
- Allowed one template to host many independent instances.
- Added server-global bus pool support.
- Added `TemplateGraph` and multi-template runtime loading.
- Derived inter-template execution order from bus write/read footprints.
- Added cross-template send/return demo.
- Added release-then-free lifecycle and polyphonic lifecycle stress tests.

Design decisions:

- The runtime executes templates in compiler-provided order; it does not compute
  template precedence itself.
- Cross-template ordering is dataflow-derived, not manually grouped.
- Release should let envelopes finish before reclaiming an instance; hard free
  remains available for stealing under pressure.

## 2026-05-06: Buses, Delay, Rate Metadata, And Lifecycle DSP

Major changes:

- Implemented `BusOut` and `BusIn` with effect-induced ordering edges.
- Added `BusInDelayed` backed by a double-buffered bus pool for block-bounded
  feedback.
- Added per-node fractional `Delay`.
- Added rate propagation across the IR.
- Added bus-aware generators and continuity tests.
- Added echo-loop, instance-isolation, and envelope-release coverage.

Design decisions:

- Live bus reads create same-block ordering constraints.
- Delayed bus reads intentionally break same-block cycles by reading the
  previous block.
- Feedback is allowed only where the delay semantics make it explicit.

## 2026-05-06: Test Suite And Haskell/C++ Contract Hardening

Major changes:

- Added Haskell structural and property tests.
- Added machine-checked kind tag agreement between Haskell and C++.
- Added C++ doctest-based runtime tests.
- Added end-to-end FFI smoke tests and region invariant coverage.
- Centralized Haskell node metadata with `KindSpec` and `UGenView`.
- Widened control values from `Float` to `Double` across the FFI.
- Unified the source DSL so combinators return `Connection`.
- Fixed NoiseGen DC offset and expanded DSP edge-case coverage.

Design decisions:

- Haskell and C++ tag drift must be detected by tests, not by manual review.
- Per-kind facts should live in table-shaped metadata, with behavior derived
  from those tables where practical.
- Tests are part of the ABI contract because this repository crosses a language
  boundary.

## 2026-04 to 2026-05: DSP Node Surface

Major changes:

- Reworked `SinOsc` around Q phase iteration.
- Added bandlimited oscillator support:
  - `SawOsc`
  - `PulseOsc`
  - `TriOsc`
- Added `NoiseGen`.
- Added biquad filters:
  - `LPF`
  - `HPF`
  - `BPF`
  - `Notch`
- Added `Env` ADSR support.
- Added initial oscillator phase controls.
- Unified oscillator state management with `std::variant`.
- Hardened parameter sanitation across kernels.
- Added demos such as ring modulation, vibrato FM, envelope pluck, filtered
  noise, and intermodulation.

Design decisions:

- Q is the DSP primitive library, but MetaSonic owns graph topology, scheduling,
  and ABI contracts.
- q_lib state should be preserved where possible; reconfigure coefficients and
  parameters without reconstructing state unless reset is intended.
- Pathological control values should be sanitized consistently at the runtime
  boundary.

## 2026-04: Inspectability And C++ Tooling

Major changes:

- Added a Brick-based TUI inspector for graph compilation stages.
- Added CLI selection of demo graphs and inspector modes.
- Moved bridge modules under `MetaSonic.Bridge`.
- Added CMake/clangd tooling and moved C++ runtime code under `tinysynth`.
- Added `rt_graph_smoke`.
- Updated README usage instructions for demos and inspection.

Design decisions:

- The compiler pipeline should be inspectable as a first-class developer tool.
- C++ runtime work needs both Stack integration and an independent CMake path.

## 2026-04: Source DSL And Routing Semantics

Major changes:

- Made `out` a terminal sink returning `SynthM ()`.
- Separated routing roles in the source `UGen` representation.
- Added `busOut` and `busIn` for intermediate signal routing.
- Cleaned up source type definitions and app messaging.

Design decisions:

- Sinks are side effects in the graph builder; they should not pretend to
  produce reusable signal values.
- Routing nodes should be explicit graph nodes, not hidden runtime side effects.

## 2026-03: Project Foundation

Major changes:

- Created the initial Haskell/C++ bridge.
- Added Stack/package metadata and Q/infra submodules.
- Added the C ABI and C++ runtime skeleton.
- Added realtime audio output through Q/PortAudio.
- Compiled Haskell graphs to dense runtime indices.
- Removed runtime symbolic lookups from the audio path.
- Added early README, architecture notes, roadmap notes, and blog integration.
- Added the Hakyll blog and deployment workflow.

Design decisions:

- The bridge shape is:

  ```text
  Haskell DSL -> SynthGraph -> GraphIR -> RuntimeGraph -> C++ DSP runtime
  ```

- Dense runtime indices are required for audio-thread performance and ABI
  simplicity.
- Documentation and narrative notes are useful, but source-level contracts and
  tests are the durable authority.

## Design Decisions To Preserve

- Keep the Haskell/C++ boundary explicit: Haskell owns graph meaning; C++ owns
  realtime execution.
- Keep `NodeID` and `NodeIndex` distinct.
- Keep runtime execution deterministic unless a later scheduler has an explicit
  deterministic reduction plan.
- Preserve node control identity across fusion.
- Gate new region kernels with survey evidence, benchmarks, and
  stripped-baseline equivalence tests.
- Treat live bus regions as scheduler barriers until a more precise dynamic-bus
  policy is implemented.
- Prefer narrow helpers over broad codegen until duplication becomes a real
  maintenance problem.
- Keep `package.yaml` and CMake in sync when changing C++ runtime sources.

## Likely Next Work

- Mechanically split the large `MetaSonic.Bridge.Compile` module while keeping
  the public facade stable.
- Design deterministic bus reduction for shared output-bus writes before
  adding runtime worker threads. The current survey now distinguishes
  immediately runnable width (`runW` / `tplRunW`) from width gated on
  reduction (`redW` / `tplRedW`).
- Continue using `--fusion-survey` and `rt_graph_bench` before adding kernels.
  Tri/Pulse/Add filtered-tail kernels are gated on multi-source recurrence;
  no kernel work is currently justified.
- §4.D landed as descriptive infrastructure (no runtime behavior
  change). §4.D.1 carried the IR-propagated `rnRate` into
  `RuntimeNode` and added a survey rate-distribution section; the
  100% `SampleRate` result confirmed that per-node *output* rate
  alone is too coarse to license block-rate regions on practical
  graphs (not that rate inference is broken — `propagateRates`
  is coherent). §4.D.2 added per-kind / per-port consumption
  metadata (`PortConsumptionRate` / `PortInfo` / `portInfo` in
  `MetaSonic.Types`; helpers in
  `MetaSonic.Bridge.Compile.EdgeRates`) and a producer-grouped
  opportunity headline that qualifies a sample-rate producer
  only when every active consumer port is non-sample-accurate.
  Empirical signal: 4 sample-rate producer nodes across 4
  distinct kinds out of 235 `RFrom` edges. Decision: preserve
  the metadata, park a runtime block-rate execution path until
  the signal grows.
- §4.E should continue incrementally. The layer / step representation and
  survey split are now in place; the next slice is deterministic bus reduction
  design. Runtime parallelism remains later, after the reduction policy and
  benchmark harness can prove where it is worth enabling.
- Tri/Pulse/Add filtered-tail kernels remain parked on
  multi-source recurrence; no kernel work is currently justified.
