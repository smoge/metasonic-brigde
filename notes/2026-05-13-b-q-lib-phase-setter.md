# q_lib Phase Setter Patch

Date: 2026-05-13

Status: local submodule patch plus parent runtime adoption.

q_lib submodule commit: `48f04dc6226a9688a715f858ea85575c38d36542`

## Context

`tinysynth/rt_graph.cpp` needs to set an oscillator's initial phase when a
graph is loaded. The oscillator state stores a `q::phase_iterator`, which owns
both accumulated phase and frequency step.

Before this slice, q_lib exposed two nearby operations:

- `phase_iterator::set(freq, sps)`, which updates the per-sample frequency
  step and intentionally leaves accumulated phase alone.
- `phase_iterator::operator=(phase)`, which is not a phase-only assignment for
  this use. It rebuilds iterator state in a way that is easy to misuse when the
  runtime wants to preserve the already configured frequency step.

The runtime therefore wrote directly to `phase_iterator::_phase`. That was
clear locally, but brittle: if q_lib changes the iterator internals, MetaSonic
would break at a private-field access point instead of depending on a named
operation.

## Decision

Patch `vendor/q` to expose the missing operation on `q::phase_iterator`:

```cpp
constexpr void set_phase(phase p);
constexpr phase current_phase() const;
```

`set_phase` updates only `_phase`. It deliberately does not touch `_step`.
`current_phase` is the matching read side, used by the focused q_lib test and
available for future inspection code that should not read `_phase` directly.

Then update `tinysynth/rt_graph.cpp` so `set_osc_initial_phase` calls:

```cpp
iter->set_phase(q::frac_to_phase(frac));
```

The runtime note at the call site now documents the semantic split:
`set(freq, sps)` is for frequency-step updates, while `set_phase` is for
initial phase assignment that preserves the current step.

## Why Patch The Submodule

Copying q_lib headers into `tinysynth/` would fork the dependency inside the
parent tree and make include order, local edits, and upstream refreshes harder
to reason about. Keeping the change in `vendor/q` preserves one canonical q_lib
copy in this checkout.

The parent repository records the exact q_lib commit through the submodule
gitlink. This slice records `48f04dc6` from `vendor/q`. That is the correct
mechanism for a local dependency patch, with one operational caveat: the
referenced q_lib commit must be available wherever the parent commit is
consumed.

## Verification

The q_lib patch adds `vendor/q/test/phase.cpp` and wires it into
`vendor/q/test/CMakeLists.txt`. The test pins the contract:

- `set_phase` stores the requested phase.
- `set_phase` preserves the existing `_step`.

Verification run for this slice:

- focused q test compile and run:
  `c++ -std=c++20 -Ivendor/q/q_lib/include -Ivendor/infra/include vendor/q/test/phase.cpp -o /tmp/metasonic-q-phase-test`
  followed by `/tmp/metasonic-q-phase-test`;
- `git diff --check` for the parent runtime/note changes;
- `git -C vendor/q diff --check` for the q_lib patch;
- `just cpp-test-offline`, which passed 310/310 deterministic C++ tests.

The full live-audio C++ suite is intentionally not the commit gate for this
change in a headless environment; the offline split covers this runtime
semantics change without depending on audio hardware.
