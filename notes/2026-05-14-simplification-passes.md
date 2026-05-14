# Simplification Passes

Date: 2026-05-14

Status: implementation record for the four cleanup commits made after
the session/live-control note work:

- `daa94e9` - `Split Haskell test suite`
- `d95faa4` - `Deduplicate FFI graph loaders`
- `ab8057b` - `Factor biquad DSP helpers`
- `9ecf1a2` - `Extract fusion cost model vocabulary`

These were intentionally not feature slices. They were maintenance
passes over areas that had grown too large, repeated too much protocol
code, or put shared vocabulary in modules that were doing heavier work.
The goal was lower local complexity without changing runtime semantics.

## Summary

The cleanup reduced four different kinds of drag:

- test-suite navigation: `test/Spec.hs` was split into focused modules;
- FFI loader duplication: repeated graph-load passes were extracted into
  small protocol-preserving helpers;
- C++ DSP repetition: LPF/HPF/BPF/Notch now share the same biquad state,
  migration, and processing skeleton;
- Phase 7 app tooling coupling: cost-model vocabulary moved out of the
  benchmark runner into a small shared module.

The most important constraint across all four passes was preserving the
audit trail. Several review follow-ups restored or kept comments that
explain why the code is strict, what C ABI path a helper uses, and which
Phase 7 executor a diagnostic variant represents.

## 1. Haskell Test Suite Split

Commit: `daa94e9` (`Split Haskell test suite`)

Before this pass, `test/Spec.hs` carried almost the whole Haskell test
surface in one file. It had become difficult to locate the relevant
fixture, property, or phase-specific group without global search.

The split introduced:

- `test/MetaSonic/Spec/Core.hs` - graph fixtures, generators, lowering,
  rate, fusion, region, authoring, and broad compiler-side properties;
- `test/MetaSonic/Spec/FFI.hs` - runtime loading and C ABI smoke tests;
- `test/MetaSonic/Spec/Feature.hs` - feature/capability and planner
  surface checks;
- `test/MetaSonic/Spec/PatternOSCBuffer.hs` - pattern, OSC buffer, and
  driver-feasibility checks;
- `test/MetaSonic/Spec/Session.hs` - session/live-control tests;
- `test/MetaSonic/Spec/Driver.hs` - shared driver feasibility helper;
- `test/Spec.hs` - a small aggregator.

The important follow-up in this pass was moving
`checkDriverFeasibility` and `DriverIssue` into
`MetaSonic.Spec.Driver`. They were originally session-adjacent only by
accident; `PatternOSCBuffer` needed them too, and keeping them in
`Session` created a horizontal module edge. The extracted helper restored
the intended star shape: focused spec modules can share generic test
support without importing each other.

This pass deliberately did not split `Session.hs` further. It was still
large after the split, but the MIDI producer/listener groups were left as
a future carve-out because they were not needed to stabilize the first
test-suite modularization.

Mechanical result:

- `test/Spec.hs` became an aggregator instead of a 20k+ line test file.
- Test module ownership became visible in the file tree.
- `package.yaml` and the generated cabal metadata were updated to include
  the new test modules.

## 2. FFI Graph Loader Extraction

Commit: `d95faa4` (`Deduplicate FFI graph loaders`)

The graph loaders in `src/MetaSonic/Bridge/FFI.hs` had four near-copies
of the same protocol:

- single-template normal load;
- single-template fused load;
- multi-template normal load;
- multi-template fused load.

The pass extracted the genuinely shared parts while keeping the public
loader bodies readable as protocol scripts. The important helpers are:

- `prevalidateRuntimeGraph` - shared pre-clear schedule validation with
  loader-specific error prefixes;
- `ensureBuses` - shared bus allocation pass;
- `wireNormalSingle` and `wireNormalTemplate` - strict normal wiring;
- `wireNormalLenientSingle` and `wireNormalLenientTemplate` - fused-load
  normal wiring that skips `RFused` inputs;
- `wireFusedSingle` and `wireFusedTemplate` - fused-input override pass;
- `markElidedSingle` and `markElidedTemplate` - elided-node marking.

The split kept separate single/template helpers because the C ABIs are
intentionally different:

- single graph construction calls `c_rt_graph_add_node` and
  `c_rt_graph_set_control`;
- template construction calls `c_rt_graph_template_add_node` and
  `c_rt_graph_template_set_default`.

Trying to share those paths behind a flag would have hidden an important
runtime distinction. The extraction therefore only deduplicated the
parts with the same contract.

Review follow-ups tightened the result:

- loader names are passed through strict wiring helpers instead of being
  baked into helper error messages;
- the strict `RFused` failure comment was preserved near the shared
  error helper, because silently dropping a fused input would leave a
  consumer port unwired and produce wrong audio without an obvious load
  failure;
- the `loadRuntimeGraphFused` note's Pass 2b/2c labels were mirrored by
  comments at the helper call sites.

Mechanical result:

- `src/MetaSonic/Bridge/FFI.hs` dropped about 146 net lines in this
  pass.
- Loader bodies are shorter and still match their protocol notes
  one-to-one.
- The exact ABI separation between live controls and template defaults
  remains visible.

## 3. C++ Biquad DSP Helper Factoring

Commit: `ab8057b` (`Factor biquad DSP helpers`)

LPF, HPF, BPF, and Notch had four repeated C++ families:

- one state struct per filter, each with the same `filter`, `last_freq`,
  and `last_q` shape;
- one hot-swap migration case per filter, each copying the same fields;
- one process function per filter, each resolving the same inputs,
  applying the same sanitation, reconfiguring on block-latched
  frequency/Q changes, and iterating samples through the q filter.

The pass introduced one shared state template:

```cpp
template <class Filter>
struct BiquadFilterState {
  Filter filter{q::frequency{1000.0}, kDefaultSampleRate, 0.707};
  double last_freq = -1.0;
  double last_q = -1.0;
};
```

The concrete aliases remain explicit:

- `LPFState = BiquadFilterState<q::lowpass>`;
- `HPFState = BiquadFilterState<q::highpass>`;
- `BPFState = BiquadFilterState<q::bandpass_cpg>`;
- `NotchState = BiquadFilterState<q::notch>`.

The pass also added:

- `copy_biquad_filter_state` for hot-swap migration;
- `process_biquad_filter<State>` for shared block processing;
- `Note [Biquad filter processing semantics]`, consolidating the
  per-filter runtime contract.

Review follow-ups tightened the result:

- `BiquadFilterStateAccess` specializations restored kind-specific
  assertion messages (`"LPF node has non-LPF state"`, etc.) after the
  first extraction had collapsed them into a generic biquad assertion;
- the q-lib interface contract was documented at the template boundary:
  the filter type must be a q biquad alternative
  constructible/configurable from `(q::frequency, sample_rate, q)` and
  callable as `filter(float)`.

The pass deliberately did not fold the hand-written fused kernels into
this abstraction. Those kernels have shape-specific dataflow and
sink-writing contracts; the safe shared layer was the plain per-node
biquad family.

Mechanical result:

- `tinysynth/rt_graph.cpp` dropped 107 net lines in this pass.
- Filter behavior stayed block-latched and state-preserving: coefficient
  reconfiguration does not reset delay history.
- The hot-swap migration path now has one helper for the whole filter
  family.

## 4. Fusion Cost-Model Vocabulary Extraction

Commit: `9ecf1a2` (`Extract fusion cost model vocabulary`)

`FusionCostLab.hs` had become the owner of concepts that were no longer
cost-lab-specific. `Survey.hs`, `SnapshotCheck.hs`, and
`ProfitabilityGate.hs` all depended on it for shared vocabulary such as
shape keys, measured speedups, generated gate measurements, and variant
names.

The pass added `app/MetaSonic/App/FusionCostModel.hs` for the small
shared model:

- `Variant` and `variantName`;
- `ShapeKey`;
- `ShapeSummary`;
- `GateMeasurement`;
- `measuredWinThreshold`;
- `shapeKeyOf`.

The pass deliberately left the heavier behavior in `FusionCostLab.hs`:

- graph-family generation;
- benchmark collection;
- `LabRow`;
- `costLabShapeIndex`;
- `costLabGateIndex`;
- `costLabGateIndexFor`;
- generated-super classification.

That keeps the dependency direction clearer: pure gate logic and survey
diagnostics can depend on a small cost-model vocabulary module, while the
benchmark runner remains responsible for measurement rows and indexes.

One review correction restored the full `Variant` constructor Haddocks in
the new module. This matters because those comments anchor the variants
to Phase 7.D/7.H/7.I and explain which C++ dispatch path each generated
executor exercises:

- sample-major generated execution uses `process_fusion_program`;
- block-major execution uses `process_fusion_program_block`;
- super-mode recognizes `GainOut` and `AddGainOut` as a single
  per-sample loop and falls back to the block-major executor otherwise.

`FusionCostLab.hs` intentionally does not re-export the moved names. That
avoids blurring the reason for the extraction: callers that need shared
vocabulary should import `FusionCostModel`; callers that need benchmark
rows should import `FusionCostLab`.

Mechanical result:

- `FusionCostLab.hs` lost about 116 lines of shared vocabulary.
- `FusionCostModel.hs` is small and descriptive rather than a second
  app runner.
- `package.yaml` and generated cabal metadata include the new app module.

## Verification

Verification was run during the passes rather than deferred to the end:

- After the Haskell test split: `just stack-test` passed.
- After the FFI loader extraction: `just stack-test` passed.
- After the C++ biquad factoring:
  - `just cpp-test-offline` passed (`312/312`);
  - `just stack-test` passed (`928/928`);
  - full `just cpp-test` was not used as the final gate because the
    live audio/device tests hung in the PortAudio path.
- After the FusionCostModel extraction:
  - `just stack-test` passed (`928/928`);
  - `stack exec -- metasonic-bridge --snapshot-check` passed (`61/61`).

For the documentation pass that produced this note, only
`git diff --check` is needed.

## What Stayed Out Of Scope

Several possible cleanups were intentionally not bundled into these
commits:

- `Session.hs` is still large. A future `Session.MIDI` split would likely
  remove roughly 1.6kLOC of MIDI producer/listener scaffolding from the
  core session spec file, but it was not needed for the first test-suite
  split.
- Fused C++ region kernels remain explicit. Their contracts are too
  shape-specific for the plain biquad helper pass.
- `FusionCostLab` still owns row collection and cost-lab indexes. Moving
  those into the vocabulary module would have made the new module less
  clean, not more.
- Live audio/device C++ tests remain separate from the deterministic
  offline C++ gate because they depend on host audio behavior.

## Net Effect

The four passes did not change the compiler/runtime architecture. They
made existing boundaries easier to read:

- specs are organized by test domain;
- FFI graph loading is expressed as named protocol passes;
- q biquad-family DSP state and processing share one implementation
  skeleton;
- Phase 7 cost-model vocabulary no longer lives inside the benchmark
  runner.

The next useful simplification pass would be a targeted `Session.MIDI`
test split, but it should be done only when session test navigation
becomes the active bottleneck again.
