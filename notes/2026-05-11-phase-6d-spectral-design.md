# Phase 6.D — Spectral Processing (Design)

Date: 2026-05-11
Status: design / contract preflight; no code lands here. Bounds
the first spectral kind and the infrastructure it forces into
existence. The first three implementation commits (slicing in
§7) start only after this note is signed off. Mirrors the
6.C.4 / 6.C.4-follow-up precedent: bound the new
infrastructure, land one minimal kind that exercises it
end-to-end, then add useful kinds in subsequent series.

## 0. Anchors

This note assumes the project state after §6.C.5 follow-up
(commit `f787248`):

- The rate lattice already names `BlockRate`
  ([Types.hs:542](../src/MetaSonic/Types.hs#L542)) as a
  first-class rate, but no `NodeKind` currently produces it
  ([Types.hs:529](../src/MetaSonic/Types.hs#L529)). §4.D's
  empirical signal stays small (4 sample-rate producer nodes
  across 4 kinds in the surveyed corpus); the runtime
  block-rate execution path is parked.
- `PortConsumptionRate` ([Types.hs:585](../src/MetaSonic/Types.hs#L585))
  describes destination-side read policy per kind / port.
  `PortBlockLatched` covers biquad freq/q; `PortInitOnly` is
  reserved but unused; `PortIgnored` covers oscillator phase;
  everything else is `PortSampleAccurate`.
- Resource ordering is bus + buffer
  (`ResourceFootprint = ResourceFootprint { rfBuses, rfBuffers }`);
  no third resource axis exists today.
- The C++ runtime is single-threaded by default; §4.E's worker
  dispatch is test-gated. Region scheduling already classifies
  writer regions as Barriers (§6.C.5).
- `vendor/q/q_lib/include/q/fft/fft.hpp` provides
  `q::fft<N, T>(T*)` / `q::ifft<N, T>(T*)` on power-of-two N
  with interleaved real/imag in place. N is a compile-time
  template parameter, not a runtime knob.

This note is also bounded by what 6.D is *not* doing first:

- No spectrum-streaming type between kinds (SC's PV_* model).
  A spectral chain still expresses its DSP as nested time-domain
  in/out at the graph level; the windowing is internal to a
  single kind.
- No variable / runtime window size. The first kind hardcodes
  N=1024.
- No latency-compensated routing. Latency is *declared*; no
  pass consumes it yet.
- No block-rate region promotion. The 6.D kind is sample-rate
  in / sample-rate out at the graph interface (windowing
  internal). §4.D's executor stays parked.

## 1. What the kind is and is not

### In scope (this design)

- **One new `NodeKind`: `KSpectralFreeze`.** Tag `22` (one past
  `KRecordBufMono = 21`).
- DSL builder
  `spectralFreeze :: Connection -> Connection -> SynthM Connection`
  — signal input, freeze flag, signal output.
- Audio-thread STFT with overlap-add resynthesis. Fixed
  parameters: N=1024 samples, hop=256 (75% overlap),
  Hann window, mono float32.
- Two operating modes selected by `freeze_flag` (the kernel
  internally samples the flag at hop boundaries; the port
  itself stays `PortSampleAccurate`, see §2.4 / Q-1):
  - **pass-through** (`freeze_flag < 0.5`): output is the input
    delayed by N samples in steady state. Verifies the
    analysis/synthesis plumbing is invertible to within
    numerical noise.
  - **freeze** (`freeze_flag >= 0.5`): the last-completed
    window's magnitude/phase is held; resynthesis continues
    from the frozen spectrum, no new input is consumed for
    analysis. Releasing the freeze resumes analysis.
- `inferEff (SpectralFreeze _ _) = [Pure]`. The kind owns its
  own ring buffers; nothing crosses an instance boundary.
- A **declared latency** of N samples, surfaced via a new
  `kindLatency :: NodeKind -> Maybe Int` accessor. `Nothing`
  means "no inherent latency"; `Just k` means "output port 0
  is the input delayed by k samples in steady state". The
  Haskell side records it; no pass consumes it yet.

### Out of scope (do **not** open in this design)

- Any second spectral kind (e.g. spectral LPF, robot voice,
  pitch shift, stretching). Each is its own follow-up once the
  infrastructure proves itself with freeze.
- A spectrum-stream type (`SpectrumConn` parallel to
  `Connection`). Spectral kinds today take audio in and emit
  audio out; intermediate spectra never leave the instance.
  This is the largest architectural decision deferred, and is
  the explicit pre-condition for a SC-style PV_* family.
- Runtime-tunable N / hop. The first kind hardcodes
  N=1024 / hop=256. A second kind with a different N is fine
  (different `NodeKind`); a single kind with runtime N is not.
- Multichannel STFT. Mono first, same precedent as 6.C.
- Latency compensation. The latency value is declared but no
  scheduler / IR pass consumes it; downstream paths just see
  the input delayed by N samples, exactly as they would today
  with a `KDelay` of the same length.
- Block-rate region promotion. The kind is `SampleRate` at the
  graph interface. The internal hop-granular work is hidden in
  the C++ kernel.
- `--fusion-survey` integration. Spectral kinds do not fuse
  with anything in 6.D's first cut.

## 2. The four real questions

### 2.1 Window ownership

Two viable choices:

- **Per-instance state on `NodeInstanceState`** (chosen).
  Each `KSpectralFreeze` instance carries its own input ring
  buffer, output ring buffer, spectrum store, and head
  pointers in a new `SpectralFreezeState` added to the
  `NodeState` variant. Mirrors `PlayBufMonoState` /
  `RecordBufMonoState` precedent.
- **Pool-allocated FFT scratch on `RTGraph`** (rejected for
  v1). Allocate one scratch buffer per FFT size on the graph
  handle; kernels temp-borrow it. Saves memory when a graph
  has many spectral nodes that don't run concurrently; costs
  a coordination layer (who owns the borrow, how is concurrent
  worker-thread access serialized) that 6.D doesn't yet need.
  6.D worker-thread interaction is the §4.E parallel-band
  question, and we keep it conservative: spectral regions are
  Barriers in v1 (see §3 below).

Per-instance state is the lower-disruption choice and matches
the resource model the rest of the codebase already uses. The
memory footprint per voice is bounded:

```
input_ring   : N float            = 4 KiB     (N=1024)
output_ring  : (N + hop) float    = 5 KiB
spectrum     : 2*N float (interleaved real/imag) = 8 KiB
frozen_spec  : 2*(N/2+1) float    = 4 KiB
window_lut   : N float, static    (one copy per kind, not per instance)
total        : ~21 KiB per live voice + 4 KiB shared
```

Acceptable. SuperCollider's `FFT` ugen is in the same
ballpark.

### 2.2 Block boundary vs. window boundary

The audio thread sees blocks of `nframes` samples (typically
64..512). The FFT operates on N samples with a hop of `hop`.
The window boundary is unrelated to the block boundary.

The kernel:

1. On entry, copies `nframes` samples from `input_in` into the
   input ring at the current write head.
2. Walks any whole hops that have crossed during this block:
   for each `i` where `(write_head - last_analysis_head) % hop
   == 0`, run analysis (apply window, FFT, optionally store
   frozen spectrum).
3. Walks any whole hops that need resynthesis: for each
   resynthesis hop boundary crossed, run IFFT + window + add
   into the output ring.
4. Reads `nframes` samples out of the output ring into
   `signal_out`.

The number of hops per block is `floor((nframes + hop - 1) /
hop)` worst-case (typically 0, 1, or 2 at common block sizes).
The cost per-sample is bounded: `O(N log N) / hop` per
analysis hop amortizes to `O((N log N) / hop) /
samples-between-hops` = `O((N log N) / hop)` per sample,
which at N=1024 / hop=256 is roughly `1024 * 10 / 256 ≈ 40`
FLOPS/sample for the FFT alone. That's well within sample-rate
budget on contemporary hardware.

### 2.3 Latency contract

The output is the input delayed by N samples (pass-through
mode) — strictly correct for an STFT with COLA-summing window:
the IFFT of a hop pulls the entire reconstructed window, but
samples within the most recent hop only become "complete" once
all overlapping windows have contributed.

Three places this matters:

1. **Test surface.** Steady-state latency is provable in two
   independent shapes:
   - **Pre-roll silence:** frames `0..N-1` of the output
     are below numerical noise on any non-pathological
     input. No complete overlap windows have been summed,
     so output is by construction zero.
   - **Warmed-up impulse:** the kernel is fed silence for
     at least `2N` frames (enough to flush the analysis
     ring through one full COLA cycle), an impulse is
     injected at frame `2N`, and the impulse must emerge at
     frame `3N` in the output — that is, the injection
     position plus the declared N-sample latency. Injecting
     at frame 0 instead would make the impulse land on the
     edge of the very first analysis window, where Hann
     weighting is zero and pre-roll has no overlapping
     contribution, so the impulse would be attenuated by
     alignment rather than by latency. Warming up
     decouples the latency assertion from startup
     transients; it is the actual test slice 2 ships.
2. **Documentation.** `KSpectralFreeze` advertises its latency
   as N (= 1024) samples through a new
   `kindLatency :: NodeKind -> Maybe Int` query. `Nothing`
   means "no inherent latency"; `Just k` means "output port 0
   is the input delayed by k samples". The runtime kernels
   don't read this; downstream IR passes that need to
   compensate latency in a future series do.
3. **Why not just declare zero.** Declaring zero latency on a
   kind that is provably N-delayed creates the kind of silent
   miswire the codebase tries to prevent. Even with no
   consumer today, `kindLatency` is correctly populated for
   `KSpectralFreeze` so the next consumer (probably a future
   "latency compensation" pass in §6.D.1 or later) inherits a
   correct value rather than a placeholder.

### 2.4 Frozen state semantics

When `freeze_flag` crosses 0.5 → 1, the next analysis hop is
the last one that updates `frozen_spec`. From that hop forward
the analysis side is suspended (no input is read into the
analysis ring); resynthesis continues to pull `frozen_spec`,
applying a fresh window and adding into the output ring on
each hop. When `freeze_flag` crosses 1 → 0, analysis resumes
on the next hop; the input ring's content from before the
unfreeze is still there (the kernel never stops *filling* the
input ring, only stops *consuming* it) so the freeze release
is a one-hop transient, not a discontinuity.

Open question Q-1 (§9): how often the kernel actually
*reads* `freeze_flag`. The kernel internally latches the flag
at hop boundaries — once per hop is enough, since analysis
runs on hop boundaries — but **the port metadata stays
`PortSampleAccurate` for v1**. The two are independent:

- `PortConsumptionRate` is a *fusion-survey hint* about
  destination-side reads, defined in
  [Types.hs:548–580](../src/MetaSonic/Types.hs#L548-L580).
  Its three non-default classifications (`PortBlockLatched`,
  `PortInitOnly`, `PortIgnored`) refer to specific runtime
  behaviors: `PortBlockLatched` in particular means "read only
  at sample 0 of each host audio block"
  ([Types.hs:591–597](../src/MetaSonic/Types.hs#L591-L597)).
  A *hop* is not a host block — hop boundaries land at
  arbitrary positions inside a block, depending on the
  monotonic sample counter mod hop. Classifying
  `freeze_flag` as `PortBlockLatched` would mis-describe the
  read pattern to every survey consumer.
- The right long-term move is a new
  `PortHopLatched` / `PortWindowLatched` policy that
  fusion-survey can interpret correctly. v1 doesn't ship it:
  the only consumer of the metadata today is the survey, and
  the survey overcounting one block-rate opportunity is the
  *conservative* error direction (a sample-accurate port can
  never silently downgrade a block-rate decision).
- For v1: port 1 is `PortSampleAccurate` so the metadata
  matches the C ABI contract (the kernel may read the
  per-sample `freeze_flag` buffer), and the kernel
  *internally* hop-latches by reading `freeze_flag[hop_start]`
  once per analysis hop. Hop-aware hysteresis can be added
  later under a real use case without renaming the port.

## 3. ResourceFootprint interaction

Spectral kinds do not introduce a new resource axis. The
input ring, output ring, and spectrum store are all
per-instance, never shared, never observable from outside the
kind. So:

- `inferEff (SpectralFreeze _ _) = [Pure]` — same as
  `KSinOsc`, `KGain`, `KLPF`.
- `resourceFootprint` (and `regionResourceFootprint`) get
  nothing new from a `KSpectralFreeze` node.
- The §6.C.4 precedence union sees a `KSpectralFreeze` as
  having zero outgoing ordering edges (other than the
  structural `RFrom` ones), exactly like any oscillator.

This is the easy-to-state property of the design: **spectral
kinds extend the runtime's compute capability, not its
resource model.** A future spectrum-streaming family would
change this — a `KSpectralFreeze` connected to a downstream
`KSpectralLpf` through a shared FFT chain would be a new
shared resource, requiring at minimum a `SpecRead` /
`SpecWrite` Eff axis (or a re-use of bus/buffer machinery on
yet another id space). 6.D explicitly defers that.

### Scheduler interaction

Spectral kernels do bursty, irregular work (zero, one, or two
FFTs per block depending on hop alignment). The conservative
choice: in v1, a region containing any spectral kind is a
Barrier — same precedent as §6.C.5 used for buffer writers.
The §4.E parallel-band dispatch path is test-gated anyway, so
the cost of being conservative here is zero in current
defaults. A future audit can lift the restriction once
benchmarks show concurrent spectral nodes are common and the
worker thread budget covers the burst.

Decision pinned: `isSpectralKind` / `regionHasSpectral`
predicates added in slice 2, consulted from
`regionsToSegments` in `Bridge.Compile.Schedule`. Same shape
as `isBufferWriterKind` / `regionHasBufferWriter` (§6.C.5
commit `2448d33`).

## 4. Why this kind first

`KSpectralFreeze` is the smallest *useful* first spectral
kind. The trivial alternative — a `KSpectralIdentity` that
just rounds-trips through the FFT — would exercise the same
infrastructure but produce no DSP value, and asking what
counts as "the kernel is correct" reduces to asking whether
the FFT pair is invertible, which is testable against
`q::fft` directly without a new `NodeKind`.

Freeze, by contrast:

- Exercises the **analysis side** (you must keep
  `frozen_spec` consistent across hops).
- Exercises the **resynthesis side** (you must continue to
  produce output after the analysis side is suspended).
- Exercises the **flag responsiveness** (Q-1) — a real
  user-facing knob.
- Has a clean **pass-through mode** that's directly testable
  against the input.
- Is a meaningful DSP primitive — many sound-design corpus
  pieces use spectral freeze, so the kind earns its keep
  immediately.

The follow-up after 6.D first lands will likely be a second
spectral kind that picks up the same infrastructure (probably
`KSpectralLpf`, exercising frequency-domain filtering — a
different freq-domain operation but the same windowing
plumbing). The slicing in §7 is sized so that follow-up
becomes mechanical: extract the analysis/resynthesis ring
machinery into a reusable helper once the second kind motivates
it (the §6.C precedent: PlayBufMono first, RecordBufMono
follow-up surfaced the shared `BufferSlot` machinery only after
the second user existed).

## 5. The 5 (+1) sites

Per `CLAUDE.md`'s checklist for a new kind:

| # | File                         | Edit                                                          |
|---|------------------------------|---------------------------------------------------------------|
| 1 | `Types.hs`                   | `KSpectralFreeze` constructor on `NodeKind`                   |
| 2 | `Types.hs`                   | `kindSpec` row: `KindSpec 22 SampleRate 2 2 "spectralFreeze"` — tag 22, SampleRate, audio arity 2 (signal, freeze_flag), control arity 2 (defaults for the same two inputs, per the `UGenView` contract in [Source.hs:1167](../src/MetaSonic/Bridge/Source.hs#L1167)) |
| 3 | `Bridge/Source.hs`           | `UGen` constructor `SpectralFreeze !Connection !Connection`    |
| 4 | `Bridge/Source.hs`           | `ugenView` row: audio inputs `[sig_in, freeze_in]`, control defaults `[connDefault sig_in, connDefault freeze_in]` — both lengths 2, matching `ksAudioArity` and `ksControlArity` |
| 5 | `Bridge/Source.hs`           | builder `spectralFreeze :: Connection -> Connection -> SynthM Connection` |
| 6 | `Bridge/Source.hs`           | `inferEff (SpectralFreeze _ _) = [Pure]` — needed because the constructor takes no resource id, so the default fall-through would apply; written out for explicitness |
| 7 | `Types.hs` (new accessor)    | `kindLatency :: NodeKind -> Maybe Int` returning `Just 1024` for `KSpectralFreeze`, `Nothing` for everything else |
| 8 | `Types.hs` (`portInfo`)      | port 0 → `PortInfo PortSampleAccurate "signal_in"`, port 1 → `PortInfo PortSampleAccurate "freeze_flag"` — both sample-accurate at the C ABI; the kernel internally hop-latches `freeze_flag`. See §2.4 / Q-1 for why this is not `PortBlockLatched`. |

C++ side (`tinysynth/rt_graph.cpp`):

- `NodeKind::SpectralFreeze = 22` (entry in enum + `kind_from_tag`).
- `SpectralFreezeState` struct on the `NodeState` variant:

```cpp
struct SpectralFreezeState {
  static constexpr int kN          = 1024;
  static constexpr int kHop        = 256;
  static constexpr int kOverlaps   = kN / kHop;   // 4

  // Pre-zeroed at configure_node; reset never reallocates.
  std::array<float, kN>             input_ring{};
  std::array<float, kN + kHop>      output_ring{};
  std::array<float, 2 * kN>         spectrum_work{};   // FFT scratch (real/imag interleaved)
  std::array<float, 2 * (kN/2 + 1)> frozen_spectrum{}; // last analysis hop, frozen mode
  int  input_write_head     = 0;
  int  output_read_head     = 0;
  long long samples_in      = 0;  // monotonic; hop boundaries are samples_in % kHop == 0
  long long samples_out     = 0;
  bool frozen_valid         = false;
};
```

- `configure_spec` row for `KSpectralFreeze`: 2 default
  controls (one per audio input — signal default, freeze
  default), 2 input refs. Matches Haskell's `ksControlArity =
  2` so the per-spec defaults vector ships across the FFI at
  the right size.
- `init_node_state` row: zero-initialize the arrays.
- `process_spectral_freeze` kernel: see §2.2 for the four-step
  outline.
- Static `kHannWindow` const array (size kN), computed at
  `init_node_state` or via a `constexpr` helper.

A new design Note `[Spectral kernel: per-instance window
ownership]` lives in `rt_graph.cpp` alongside the state
struct, mirroring the `Note [Per-node RecordBufMono state]`
precedent.

## 6. Tests

Same counter-confirmed-validation discipline as the buffer
kinds. Add a new counter on `RTGraph`:

- `spectral_analysis_count` — incremented by exactly one each
  time `process_spectral_freeze` runs an analysis FFT.
- `spectral_resynthesis_count` — incremented by exactly one
  each time the kernel runs an IFFT.

The counters let tests assert "this block hit exactly N FFTs"
in addition to checking the audio output. Without that pin a
silent path that produces correct-by-luck output (e.g. a
write-through that bypasses FFT entirely) would pass.

Tests (in `recordBufMonoSkeletonTests` style, new
`spectralFreezeTests` group):

1. `inferEff produces Pure` — pins effect classification.
2. `kindSpec / portInfo / kindLatency agree on shape` —
   `ksTag = 22`, `ksRate = SampleRate`, `ksAudioArity = 2`,
   `ksControlArity = 2`, `ksLabel = "spectralFreeze"`,
   `kindLatency KSpectralFreeze = Just 1024`, both
   `portInfo` rows `PortSampleAccurate` (see §2.4 / Q-1 for
   why the freeze flag is sample-accurate at the port even
   though the kernel hop-latches it internally).
3. `pre-roll is silent` — frames `0..N-1` of the output are
   all below 1e-3 in magnitude on any non-pathological input
   (no overlapping windows have completed yet).
4. `warmed-up impulse emerges N samples later` — feed
   silence for `2N` frames (priming the analysis ring with
   one full window before the impulse), inject an impulse
   at frame `2N`, render `4N` frames total. The impulse
   must appear at frame `3N` (= injection frame + N
   samples of pipeline latency) within numerical noise.
   A frame-0 injection is *not* used: with causal startup
   and a Hann window, frame 0 lands on a window edge with
   no overlapping pre-roll contributions, so the impulse is
   attenuated by alignment rather than by latency. Warming
   up first decouples the latency assertion from startup
   transients. Counter-confirmed: `analysis_count` and
   `resynthesis_count` advance by the steady-state hop math
   over the rendered window.
5. `pass-through reconstructs a sine wave (steady state)` —
   feed a 440 Hz sine for `4N` frames, skip the first `2N`
   (startup transient + one COLA-complete window), assert
   the remaining window has peak abs ≈ 1.0 within
   numerical noise and the expected number of zero
   crossings.
6. `freeze halts analysis but continues resynthesis` —
   freeze the flag at frame F, feed silence after frame F,
   expect the output past frame F + N to keep producing the
   frozen content (decaying through the overlap window or
   stationary, depending on the resynthesis approach).
7. `analysis_count and resynthesis_count match hop math` —
   render exactly H hop-worth of frames, expect analysis_count
   == H and resynthesis_count == H in pass-through.
8. `analysis_count freezes when freeze_flag is on` — render
   while flag = 1; analysis_count must stay constant.
9. `spectral region is a Barrier` — walks `segmentByBarrier`,
   asserts the spectral kind never lands in a `FreeSegment`
   (mirrors the §6.C.5 buffer-writer barrier test).
10. `latency accessor exposes 1024 for KSpectralFreeze` —
    `kindLatency KSpectralFreeze @?= Just 1024`,
    `kindLatency KSinOsc @?= Nothing`.

## 7. Implementation slicing

Three commits, each keeping `stack test` green. Same
no-intentionally-red-CI rule as §6.C.4 follow-up
(commit `39539bb` precedent).

### Slice 1 — Haskell surface + green C++ skeleton

Haskell side:

- `KSpectralFreeze` in `NodeKind`, `kindSpec` row
  (`KindSpec 22 SampleRate 2 2 "spectralFreeze"`).
- `kindLatency :: NodeKind -> Maybe Int` accessor added
  with `KSpectralFreeze -> Just 1024`, all other kinds
  returning `Nothing`.
- `UGen` constructor `SpectralFreeze`, `ugenView` row,
  `inferEff` case, `dependencies` case, `portInfo` row.
- `spectralFreeze` DSL builder, exported.

C++ side (just enough to keep every existing test green —
particularly the `kind_supported` / `kind_from_tag` /
`portInfo` properties):

- `NodeKind::SpectralFreeze = 22`, `kind_from_tag` row.
- `SpectralFreezeState` added to the `NodeState` variant.
- `configure_spec`, `init_node_state` rows.
- Stub `process_spectral_freeze` that emits zeros on output
  port 0 and never advances any counters. The kind compiles,
  loads, and runs; the kernel is a no-op until slice 2.
- New counters `spectral_analysis_count` /
  `spectral_resynthesis_count` plus
  `rt_graph_test_spectral_analysis_count` /
  `_resynthesis_count` accessors.

Slice-1 tests: `inferEff = [Pure]`, `kindSpec` shape,
`kindLatency` accessor, `kind_supported` extended through tag
22, `portInfo` extended through `KSpectralFreeze`. Slice-2's
delay test is not added yet — there's no real kernel to
verify. **No test is intentionally red.**

### Slice 2 — Real STFT kernel + writer-style barrier

- Replace stub with the real four-step kernel from §2.2:
  ring fills, hop-boundary analysis, hop-boundary
  resynthesis, ring reads.
- `regionHasSpectral` / `isSpectralKind` predicates in
  `Bridge.Compile.Dependencies`; consulted in
  `Bridge.Compile.Schedule.regionsToSegments` so spectral
  regions are Barriers.
- Counters tick once per FFT / IFFT call.

Slice-2 tests: pre-roll silence (#4), impulse delay (#3),
sine reconstruction (#5), counter math in pass-through (#7),
spectral-region Barrier (#9), latency accessor (#10).

### Slice 3 — Freeze mode + freeze tests

- Wire the `freeze_flag` into the kernel. Hop-boundary
  read of the flag selects between the "store new spectrum
  into `frozen_spectrum`" path (flag off) and the
  "preserve `frozen_spectrum`, suspend input drain" path
  (flag on).
- Freeze on/off transition tests (#6, #8).

After slice 3: total tests ≈ 580 + 10 = 590 Haskell, 308 C++
unchanged (the new tests are Haskell-driven; the C++ doctest
side gets no new tags beyond the slice-1 `kind_supported`
update).

## 8. What this does NOT unblock

- **Plugin hosting (§6.E).** Spectral kinds use q's
  templated FFT, not an external library. External-FFT plugins
  are §6.E territory.
- **Spectrum-stream graphs (SC's PV_* chains).** Would require
  a parallel `Connection` type for spectra. Bigger lift; the
  freeze prototype is intentionally self-contained.
- **§4.D block-rate execution.** The kernel runs at sample
  rate at the graph interface; the hop-granular internal work
  is invisible to the IR / scheduler. The §4.D survey signal
  is unchanged.
- **Latency-compensated scheduling.** `kindLatency` is
  declared but no IR pass consumes it. A future routing pass
  that inserts compensation delays on parallel paths will need
  it; 6.D ships the value, not the consumer.
- **Multichannel / variable N / variable hop / non-Hann
  window.** All explicitly out of scope; new kinds add them.
- **Pitch shifting / time stretching.** Different kinds with
  different windowing; share infrastructure once it exists,
  not before.

## 9. Open questions / Q-deferrals

Q-1. **`freeze_flag` consumption policy** (settled for v1).
The kernel internally reads `freeze_flag` once per analysis
hop. The C-ABI port metadata is `PortSampleAccurate` because
that's the only existing classification that honestly
describes "the kernel may read every sample of the input
buffer" — `PortBlockLatched` specifically refers to host
audio blocks (sample 0 of `nframes`), not hop boundaries,
and overloading it would silently mis-describe the read
pattern to fusion-survey consumers. A future
`PortHopLatched` / `PortWindowLatched` classification can
replace this once survey consumers learn the new contract;
v1 stays on the conservative existing axis.

Q-2. **Window choice.** Hann is default for v1. Other COLA
windows (Hamming, Blackman) buy specific spectral leakage
trade-offs but don't change the kind's contract. Adding them
is a per-kind knob or per-kind variant; the design note picks
Hann to keep the slice 2 implementation single-pathed.

Q-3. **FFT magnitude scaling.** `q::fft` is unnormalized
forward / 1/N inverse. The kernel applies the standard
1/window_sum COLA normalization on the IFFT side so a
pass-through 1.0 input produces a 1.0 output. Pinned in slice
2; this note records the convention so a reviewer doesn't
need to derive it.

Q-4. **Frozen-mode envelope decay.** When `frozen_spectrum` is
held and resynthesis continues, the COLA sum produces a
stationary tone (every hop adds the same windowed spectrum,
summing to the same value at every output sample). That's the
intended freeze semantic; a "decaying freeze" needs an
amplitude envelope on the frozen spectrum, which is a future
parameter, not v1.

Q-5. **Per-instance memory.** ~21 KiB per voice (§2.1). With
a default polyphony of 8 that's 168 KiB per spectral template
— acceptable. A future tunable would let callers reduce this
when only one voice is needed; 6.D doesn't ship the knob.

Q-6. **N=1024 vs. N=2048.** 1024 at 48 kHz is 21 ms of
latency, which is high for some use cases. Higher N improves
freeze fidelity for low-frequency content. The first kind
picks 1024 as the smaller-cost default; a second kind with
N=2048 (different `NodeKind`, separate state size) lands when
a use case justifies it.

## 10. Test plan summary

After slice 3 (~10 new tests, all Haskell-driven through the
FFI):

- Total: ~590 Haskell, 308 C++.
- New counters in test surface: `spectral_analysis_count`,
  `spectral_resynthesis_count`.
- C ABI surface added: two counter accessors. No new
  producer-side entry points (spectral kinds have no off-audio
  control surface beyond the existing per-control defaults).
- DSL surface added: `spectralFreeze` (one builder), no new
  IO surface.

If anything in this design changes during implementation, the
§6.C.3b precedent stands: update *this* note alongside the
code, do not let the doc drift.
