## Phase 6.D — Second Spectral Kind Contract (KSpectralLpf)

Date: 2026-05-19

Status: pre-implementation contract. This is the "small design note"
the
[Phase 6.D latency follow-up decision](2026-05-11-e-phase-6d-latency-followup-decision.md)
asked for before a second spectral kind goes into the runtime. The
companion v1 contract for the first spectral kind is
[Phase 6.D minimal spectral kind](2026-05-11-d-phase-6d-spectral-design.md);
this note adopts the same shape and only resolves the questions the
v1 note explicitly left open for the next kind.

Read this before writing any runtime code. The intent is for the
implementation slice to mirror this note line-for-line, the same way
the freeze series mirrored its design.

## 0. Anchors

- The first spectral kind is `KSpectralFreeze` at tag `22`
  (`Types.hs:286 / 491`), declared latency `Just 1024`
  (`Types.hs:541-543`), `kindCapabilities` row
  `[CapStatefulOp, CapLatencyBearing]` (`Types.hs:649`),
  `inferEff = [Pure]`, scheduler Barrier via
  `isSpectralKind` / `regionHasSpectral`. State lives per-instance
  in `SpectralFreezeState` (input ring, output ring, FFT scratch,
  frozen Hermitian half).
- `KStaticPlugin` at tag `23` is the next assigned slot (Phase 6.E
  v1 shim). The next free tag is **`24`**.
- The pattern corpus already exposes `spectral-freeze-pad/texture`
  (`Pattern/Corpus.hs:339-378`), which exercises the freeze flag
  through the pattern contract and writes the only declared-latency
  row currently visible to `--corpus-survey`.
- The shared spectral helpers (Hann/WOLA tables, hop-boundary
  analysis/resynthesis machinery) all currently live inside
  `SpectralFreezeState` / `process_spectral_freeze`. No shared
  helper has been factored out yet — the freeze design explicitly
  deferred that until a second user materialized
  (`2026-05-11-d` §4).

## 1. Choice: `KSpectralLpf`

Pick `KSpectralLpf` as the second kind. It is the smallest *new*
DSP behavior that reuses every piece of the v1 windowing plumbing
unchanged — same N, same hop, same Hann window, same per-instance
state shape — and produces a result that is independently
checkable in two regimes: a no-op pass-through at maximum cutoff,
and a known band-rejection at moderate cutoff. The alternatives
considered and rejected for this slice:

- `KSpectralHpf`. Same plumbing, symmetric DSP shape. No reason to
  do both yet; doing one proves the infrastructure and the second
  follows mechanically.
- `KSpectralPitchShift`. Requires phase-vocoder bookkeeping (phase
  unwrapping, hop-ratio resampling). Too many new questions for a
  "prove reuse" slice.
- `KSpectralRobotVoice` / `KSpectralFreezePartial`. Both depend on
  knobs over the frozen spectrum and would be more natural after a
  shared helper exists.

The point of this kind is not the LPF itself — it is to surface
exactly which pieces of the freeze kernel are reusable when a
second consumer appears. That decision is recorded in §4 below.

## 2. Contract

| Property                  | Value                                            |
|---------------------------|--------------------------------------------------|
| Tag                       | `24` (first slot after `KStaticPlugin = 23`)    |
| Rate                      | `SampleRate`                                     |
| Audio arity               | `2` (signal_in, cutoff_hz)                       |
| Control arity             | `2` (default per audio input, per `UGenView`)    |
| Label                     | `"spectralLpf"`                                  |
| Effects                   | `inferEff (SpectralLpf _ _) = [Pure]`            |
| Caps                      | `[CapStatefulOp, CapLatencyBearing]`             |
| Latency                   | `kindLatency KSpectralLpf = Just 1024`           |
| Scheduler                 | Barrier (extends `isSpectralKind`)               |
| Window / N / hop          | Hann, N=1024, hop=256 — same as `KSpectralFreeze` |
| Multichannel              | Mono only (no change vs. v1)                     |
| Variable N / hop          | No (no change vs. v1)                            |

DSL builder:

```haskell
spectralLpf
  :: Connection  -- signal input
  -> Connection  -- cutoff in Hz (sample-accurate at the C ABI;
                  --   kernel hop-latches internally, same shape as
                  --   freeze_flag in v1, see Q-1)
  -> SynthM Connection
```

Cutoff semantics for v1:

- Linear-magnitude bin mask: bins whose center frequency is
  `<= cutoff_hz` pass unchanged; bins above are multiplied by
  zero. Phase is preserved on the passed bins.
- Cutoff is hop-latched: the kernel reads `cutoff_hz` once per
  analysis hop and freezes the bin mask for the analysis +
  resynthesis at that hop. Sub-hop cutoff modulation is not a
  feature of v1; it would produce window-edge clicks anyway and
  is the kind of thing a future "smoothed cutoff" knob earns.
- Cutoff is clamped to `[0, SR/2]` at hop time. Out-of-range
  values do not crash; below 0 mutes, above Nyquist passes
  everything (no-op).

Explicitly **not** in v1 of this kind:

- Spectral rolloff curves (raised-cosine taper, Butterworth-shape
  bin envelope). Brick-wall is the only mode. Operators who want
  a softer rolloff use a time-domain `KLPF` in series or wait for
  a `KSpectralRolloffLpf` follow-up.
- Resonance / Q. Same reason.
- Per-bin gain envelopes. Different kind entirely.
- A `SpectrumConn` parallel to `Connection`. Same v1 deferral as
  the freeze design.

## 3. Per-instance state

A second per-instance struct with the same fields as
`SpectralFreezeState` minus the freeze-specific
`frozen_spectrum` / `frozen_valid`:

```cpp
struct SpectralLpfState {
  static constexpr int kN          = 1024;
  static constexpr int kHop        = 256;
  static constexpr int kOverlaps   = kN / kHop;   // 4

  std::array<float, kN>             input_ring{};
  std::array<float, kN + kHop>      output_ring{};
  std::array<float, 2 * kN>         spectrum_work{};
  int       input_write_head = 0;
  int       output_read_head = 0;
  long long samples_in       = 0;
  long long samples_out      = 0;
};
```

Per-voice memory: `kN * 4 + (kN+kHop) * 4 + 2*kN * 4 ≈ 16 KiB`,
vs. ~21 KiB for `KSpectralFreeze`. Same order of magnitude.

## 4. Shared helper decision

The freeze design (§4) said the shared analysis/resynthesis
machinery should be extracted **once a second user motivates it**.
This is that moment. The recommendation:

Do extract, narrowly. Specifically, factor out:

- The Hann window table (already a namespace-scope constant
  `kHannWindow` after freeze post-hardening, plus the matching
  `kSpectralResynthesisScale` WOLA constant — share, don't
  duplicate).
- A `process_stft_hop` static helper templated or
  function-pointer-parameterized on the per-hop spectrum
  transform. Signature shape (illustrative):
  `template <typename SpectrumOp> void process_stft_hop(StftState& s, SpectrumOp op)`
  where `StftState` is a base struct holding the rings + heads
  shared by `SpectralFreezeState` and `SpectralLpfState`.

Do **not** extract, in this slice:

- The freeze-specific spectrum storage (`frozen_spectrum`,
  `frozen_valid`). That stays in the freeze state.
- A general FFT-size knob. Both kinds still hardcode N=1024 /
  hop=256; extracting a runtime knob with one user remains a
  premature abstraction — the same reasoning that kept the
  freeze-side ring/head machinery inside its struct in v1.

The narrow extraction is what makes the LPF slice *prove*
infrastructure reuse: a third spectral kind should reuse the
helper without further refactoring. If `KSpectralLpf` ends up
re-implementing the rings + heads instead of using the shared
helper, the second-kind goal is not actually met and the slice
should be reopened.

Note: the freeze hop-boundary semantics (analysis runs at
`samples_in % hop == 0`, resynthesis runs at the same cadence)
must stay observably identical after refactoring. The freeze
counter tests already pin this — they continue to apply.

## 5. Tests

Same counter-confirmed-validation discipline as freeze. Add **one
new counter pair** mirroring the freeze pair:

- `spectral_lpf_analysis_count` — incremented once per analysis
  FFT inside `process_spectral_lpf`.
- `spectral_lpf_resynthesis_count` — incremented once per IFFT.

Keep them separate from the freeze counters so a single test can
assert "this graph hit N freeze FFTs and M lpf FFTs" without
counter contamination across kinds.

Test cases (new `spectralLpfTests` group, mirroring
`spectralFreezeTests`):

1. `inferEff KSpectralLpf yields [Pure]`.
2. `kindSpec / portInfo / kindLatency agree on shape`:
   `ksTag = 24`, `ksRate = SampleRate`, `ksAudioArity = 2`,
   `ksControlArity = 2`, `ksLabel = "spectralLpf"`,
   `kindLatency KSpectralLpf = Just 1024`, both ports
   `PortSampleAccurate`.
3. `pre-roll is silent` — frames `0..N-1` of the output are
   below 1e-3 (no completed COLA window yet). Same shape as
   freeze test #3.
4. `warmed-up impulse with cutoff = SR/2 emerges N samples
   later within numerical noise` — proves the brick-wall mask
   at Nyquist is a true no-op modulo windowing. Same warm-up
   protocol as freeze impulse-delay.
5. `warmed-up sine well below cutoff passes within numerical
   noise` — feed a 110 Hz sine, set cutoff to 4 kHz, skip the
   first `2N` frames (startup), assert peak amplitude within
   epsilon of 1.0 and zero crossings match. Steady-state
   pass-band behavior.
6. `warmed-up sine well above cutoff is attenuated below an
   epsilon` — feed a 4 kHz sine, set cutoff to 500 Hz, skip
   startup, assert peak amplitude below 1e-2 in steady state.
   Steady-state stop-band behavior.
7. `cutoff is hop-latched` — toggle cutoff between 8 kHz and
   100 Hz on a sub-hop frame boundary; the kernel's first
   post-toggle analysis hop must use the toggled value, but
   no analysis FFT may fire mid-hop. Counter-confirmed by
   `spectral_lpf_analysis_count` advancing exactly once
   across the toggle.
8. `analysis_count and resynthesis_count match hop math` —
   render H hops worth of frames, assert both counters equal H.
9. `spectral region is a Barrier (extends isSpectralKind)` —
   walks `segmentByBarrier`, asserts an LPF-containing region
   never lands in a `FreeSegment`. Mirrors the freeze test #9.
10. `kindLatency accessor` —
    `kindLatency KSpectralLpf @?= Just 1024`,
    plus the pre-existing
    `kindLatency KSinOsc @?= Nothing` row still holds.
11. `shared-helper smoke` — a graph containing **both**
    `spectralFreeze` and `spectralLpf` on disjoint voices
    renders correctly; both counter pairs advance
    independently. This is the test that catches the
    extraction in §4 silently breaking one kind while leaving
    the other intact.

## 6. Corpus / survey

Recommendation: **second template inside the existing
`spectral-freeze-pad` row**, not a new row.

Rationale:

- `spectralFreezePadTemplates` is already a list of `(name, graph)`
  pairs (`Pattern/Corpus.hs:346-347`). Adding a second template
  `("lpf-bed", spectralLpfBedGraph)` keeps the change to one row
  type and one corpus list, and lets the same `--corpus-survey`
  run report declared latencies for both kinds side-by-side.
- The freeze-pad row's purpose is to provide the only non-trivial
  declared-latency surface for the survey. A second spectral kind
  in the same row strengthens that surface without forcing
  decisions about what "an LPF row" would do in pattern terms.
- `shape/spectral-freeze-tail` continues to fire on the existing
  template; a `shape/spectral-lpf-tail` is not added in this
  slice — the survey aggregate's purpose is "find anything with
  declared latency at all", and a duplicate row reading the same
  declaration is not new information.

Rename of the row is **not** in scope: `spectral-freeze-pad`
remains the row key. If a future slice grows several spectral
kinds into a real "spectral-textures" cohort, the rename happens
then, not preemptively.

A `spectralLpfBedGraph` proposal (illustrative, not
prescriptive):

```haskell
spectralLpfBedGraph = runSynth $ do
  carrier <- tagged "carrier" (sawOsc (Param 110.0) (Param 0.0))
  filtered <- tagged "lpf"    (spectralLpf carrier (Param 800.0))
  shaped   <- tagged "outgain" (gain filtered (Param 0.35))
  out 0 shaped
```

A sawtooth into a spectral LPF makes a difference audible without
a freeze flag in play. Final shape pinned in the implementation
slice.

## 7. Sites

Per the new-kind checklist in [AGENTS.md §Haskell/C++ Boundary](../AGENTS.md).
The pattern mirrors the freeze series exactly; deltas vs. freeze
are noted in the right-most column where relevant.

| # | File                         | Edit                                                                                                                |
|---|------------------------------|---------------------------------------------------------------------------------------------------------------------|
| 1 | `Types.hs`                   | `KSpectralLpf` constructor on `NodeKind`                                                                            |
| 2 | `Types.hs`                   | `kindSpec` row: `KindSpec 24 SampleRate 2 2 "spectralLpf"`                                                          |
| 3 | `Types.hs`                   | `kindLatency` row: `KSpectralLpf -> Just 1024`                                                                       |
| 4 | `Types.hs`                   | `kindCapabilities` row: `[CapStatefulOp, CapLatencyBearing]` (same as freeze)                                        |
| 5 | `Types.hs` (`portInfo`)      | port 0 → `PortInfo PortSampleAccurate "signal_in"`, port 1 → `PortInfo PortSampleAccurate "cutoff_hz"` (hop-latch is internal — same Q-1 reasoning as freeze) |
| 6 | `Bridge/Source.hs`           | `UGen` constructor `SpectralLpf !Connection !Connection`                                                            |
| 7 | `Bridge/Source.hs`           | `ugenView` row: audio inputs `[sig_in, cutoff_in]`, control defaults `[connDefault sig_in, connDefault cutoff_in]`  |
| 8 | `Bridge/Source.hs`           | builder `spectralLpf :: Connection -> Connection -> SynthM Connection`                                              |
| 9 | `Bridge/Source.hs`           | `inferEff (SpectralLpf _ _) = [Pure]` (explicit, same reason as freeze)                                              |
| 10| `Bridge/Source.hs`           | `dependencies` case: `SpectralLpf sigIn cf -> deps [sigIn, cf]`                                                      |
| 11| `Bridge.Compile.Dependencies`| extend `isSpectralKind` to return `True` for `KSpectralLpf`                                                          |
| 12| `tinysynth/rt_graph.cpp`     | `NodeKind::SpectralLpf = 24` (enum + `kind_from_tag`)                                                                |
| 13| `tinysynth/rt_graph.cpp`     | `SpectralLpfState` struct (see §3); add to `NodeState` variant                                                       |
| 14| `tinysynth/rt_graph.cpp`     | `configure_spec`, `init_node_state` rows                                                                              |
| 15| `tinysynth/rt_graph.cpp`     | shared helper extraction (see §4) + `process_spectral_lpf` using it; freeze migrates to the helper in the same slice |
| 16| `tinysynth/rt_graph.cpp`     | `spectral_lpf_analysis_count` / `_resynthesis_count` counters + `rt_graph_test_spectral_lpf_*` accessor definitions  |
| 17| `tinysynth/rt_graph.h`       | declare `rt_graph_test_spectral_lpf_analysis_count` and `rt_graph_test_spectral_lpf_resynthesis_count` next to their freeze siblings at lines 890 / 900 |
| 18| `src/MetaSonic/Bridge/FFI.hs`| add `c_rt_graph_test_spectral_lpf_analysis_count` and `c_rt_graph_test_spectral_lpf_resynthesis_count` foreign imports next to their freeze siblings (current line ranges 162-163 and 1417-1422); export from the module so the test surface can see them |
| 19| `Pattern/Corpus.hs`          | extend `spectralFreezePadTemplates` with the second template (see §6)                                                |

Row counts (existing-test parity check): tests grow by ~11 from
this kind (§5). Each row in the §6 corpus update inherits the
existing per-template survey machinery; no new survey wiring is
needed.

## 8. What this does NOT unblock

- Variable / runtime N or hop. Same parking as freeze.
- Multichannel STFT. Same parking.
- A `SpectrumConn` for chained spectral kinds. Same parking.
- Block-rate region promotion. The kind is `SampleRate` at the
  graph interface; hop-granular work stays internal.
- Latency compensation. `kindLatency KSpectralLpf = Just 1024`
  is descriptive; no IR pass consumes it. Reopen gate per
  [2026-05-11-e §"Reopen Gate For Compensation"](2026-05-11-e-phase-6d-latency-followup-decision.md);
  a second latency-bearing kind does not by itself satisfy the
  reopen gate (the existing dry/wet skew test already triggers
  the diagnostic on a synthetic shape — what's missing is a
  real corpus pattern with mixed latent/non-latent paths).
- Plugin hosting. `KStaticPlugin` (§6.E) is the next adjacent
  kind by tag, not by domain.

## 9. Open questions / Q-deferrals

Q-1. **Port classification for `cutoff_hz`.** Same as freeze
Q-1: `PortSampleAccurate` is the only honest existing
classification for "the kernel reads this buffer per sample
internally even if it only acts on hop boundaries". A future
`PortHopLatched` policy would let fusion-survey treat hop-latched
ports specifically; pinning it now would mean designing a
classification with two users before the survey has a consumer
for it. Defer to the same future slice that promotes
`PortHopLatched`.

Q-2. **Rolloff curve.** Brick-wall is the v1 pick because it
admits a yes/no spec ("bins above cutoff are zero") and is
deterministically testable. A musical rolloff is a third
spectral kind, not a knob on this one.

Q-3. **Stereo / multichannel.** Mono only. Bringing the
freeze-precedent forward: stereo is a different kind once it
matters, not a parameter on this one.

Q-4. **Cutoff in bins vs. Hz.** Hz is more operator-natural and
matches the time-domain `KLPF`. The kernel converts at hop
time via `int cutoff_bin = round(cutoff_hz * kN / sample_rate)`,
clamped to `[0, kN/2 + 1)`. Sample rate is the runtime sample
rate, not a constant; it is already available to spectral
kernels (used implicitly by freeze for COLA normalization).

Q-5. **Helper extraction risk.** The §4 extraction touches the
existing freeze kernel in the same slice that lands the new
kind. Mitigation: the freeze counter tests stay in place and
must continue to pass byte-equivalent output across the
refactor. The rule is: do not declare the helper extraction
done on a freeze counter or audio regression even if every new
`lpf` test passes — a path swap that produces correct-by-luck
output for one kind while breaking another is exactly what the
counter-confirmed test discipline (originally pinned by the
§6.C buffer-kind series and the §6.D freeze series) is there
to catch.

## 10. Review checklist before implementing

- [ ] §1 still the right second kind, or has corpus pressure
      shifted toward a different DSP shape?
- [ ] §2 contract values agree with the latest `Types.hs`
      (tag, arity, label conventions). Tag `24` still free
      (no `KStaticPlugin` follow-up has claimed it).
- [ ] §4 extraction scope still narrow — only the helper that
      both kinds need, no speculative knobs.
- [ ] §6 row recommendation still preferred over a new corpus
      row (revisit if a separate `spectral-textures` cohort
      becomes plausible by implementation time).
- [ ] §7 sites table still mirrors the new-kind checklist in
      [AGENTS.md §Haskell/C++ Boundary](../AGENTS.md).
