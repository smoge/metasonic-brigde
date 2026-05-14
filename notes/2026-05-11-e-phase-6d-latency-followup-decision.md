# Phase 6.D — Latency Follow-up Decision

Date: 2026-05-11
Status: decision after the first `KSpectralFreeze` implementation and
the descriptive latency-footprint follow-up.

## Decision

Do not implement automatic latency compensation as the next runtime
slice.

Keep the new latency surface descriptive for now:

- `kindLatency KSpectralFreeze = Just 1024` records the inherent
  kernel latency.
- `declaredLatencyFootprint` reports compiled nodes that introduce
  inherent latency.
- `nodeOutputLatencies` propagates cumulative latency through a
  compiled graph.
- `inputLatencySkews` reports nodes whose dynamic inputs arrive with
  different cumulative latency.
- `--corpus-survey` prints declared-latency nodes and any
  uncompensated input-latency skew.

This gives the project a measurement surface without changing graph
semantics.

## Evidence

The current pattern corpus includes `spectral-freeze-pad`, which
exercises `KSpectralFreeze` through the 6.A pattern contract. A
`--corpus-survey` run reports:

```text
spectral-freeze-pad/texture: KSpectralFreeze@1=1024 samples
Uncompensated input-latency skew: (none)
```

The test suite also pins a synthetic dry/wet case:

```text
src -> spectralFreeze -> Add
src --------------------^
```

That graph reports one `KAdd` skew with inputs at 0 and 1024 samples.
So the diagnostic is capable of finding the compensation case, but
the real corpus does not currently demand an automatic fix.

## Why Compensation Stays Parked

Automatic compensation would not be a neutral compiler observation.
It would insert extra delay state or rewrite paths, which raises new
questions:

- where to insert the delay without changing control-path meaning;
- how to account for the inserted state in scheduling and resource
  descriptions;
- whether compensation should apply to every dynamic input or only to
  signal-like ports once the project grows a stronger signal/control
  distinction;
- how to expose opt-out behavior for intentionally phase-shifted
  patches;
- how hot-swap state migration treats inserted delay nodes.

Those questions are real, but they are not yet backed by corpus
pressure. A descriptive warning is the right stopping point.

## Next Runtime Direction

The next 6.D runtime implementation should be a second fixed-contract
spectral kind only after a small design note names the exact DSP
contract. The most natural candidate remains a frequency-domain
filter variant such as `KSpectralLpf`, because it reuses the fixed
N=1024 / hop=256 / Hann / mono machinery while proving whether shared
spectral infrastructure is worth extracting.

Before that implementation starts, add a short design note that
answers:

- whether it uses the same latency (`Just 1024`);
- whether it remains `[Pure]` and a scheduler Barrier;
- whether it reuses the `KSpectralFreeze` window constants or earns a
  shared helper;
- what deterministic tests prove pass-through / filtering behavior;
- whether the corpus needs a new row or can reuse
  `spectral-freeze-pad` with a second template.

## Reopen Gate For Compensation

Reopen latency compensation only when at least one of these becomes
true:

1. A real pattern/demo row reports `inputLatencySkews`.
2. A user-facing dry/wet spectral workflow needs phase alignment.
3. A second spectral kind makes parallel latent/non-latent routing
   common enough that warnings become noisy.

Until then, the latency pass remains an inspector/survey tool, not a
graph-rewriting pass.
