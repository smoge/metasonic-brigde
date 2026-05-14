# Project State Snapshot — Phase 6.A–6.D Complete

Date: 2026-05-11
Snapshot commit: `3bfa7d2`

Pinned to the Phase 6 implementation boundary: 6.A pattern, 6.B
OSC, 6.C buffer I/O, and 6.D spectral all landed at the contract
level. 6.E plugin hosting remains open and is the natural seam to
Phase 7. Use `CHANGELOG.md` and `ROADMAP.md` for current-head
status; this note is intentionally tied to the 6.A–6.D boundary
so a later 6.E push doesn't dilute it.

This is a one-stop "where are we" reference, not a session recap.

## What This Crate Is

One layer of the larger MetaSonic pipeline. Job: compile a
Haskell-built signal graph into a dense runtime form and ship it
across an FFI boundary into a C++ DSP engine.

```
Haskell DSL → SynthGraph → GraphIR → RuntimeGraph → DSP Engine
   Source     Validate     IR        Compile        FFI → C++
```

The split between `metasonic-core`, `metasonic-bridge`, and
`tinysynth` is still explicitly temporary; do not design against
it. The pipeline reading order in [CLAUDE.md](../CLAUDE.md) is the
load-bearing contract.

## Tests

- Haskell: **600** pass (`stack test`).
- C++ standalone: **309** pass (`build-cpp/tinysynth_tests`).

Catch-drift properties exercised on every run:

- `ugenView` arities cross-checked against `kindSpec` for every `UGen`.
- `kindTag` agreement with the C++ side via `c_rt_graph_kind_supported`.
- `portInfo` totality across every `(NodeKind, port)` pair.
- §6.C: `BufWrite` rejection across templates *and* inside a single
  graph; writer-template polyphony clamped to 1 via Haskell loaders
  *and* the runtime C-ABI backstop.
- §6.D: counter-confirmed STFT pass-through, warmed-up impulse
  latency = N, freeze gate, hop-boundary latch.

## Phase 6 State by Sub-Phase

### 6.A — Pattern (closed)

`MetaSonic.Pattern` ships a streaming-style pattern surface plus
the `MetaSonic.Pattern.Corpus` reference set. The corpus is the
canonical "realistic patch shapes" surface that `--corpus-survey`
walks, including `spectral-freeze-pad` and the §6.B OSC patterns.

### 6.B — OSC (closed)

`MetaSonic.OSC.{Wire, Dispatch, Listen}` covers the wire format,
inbound dispatch, and a UDP listener. External-control smoke helpers
are wired through `--osc-listen`, `--midi-list`, `--midi-device`,
`midi-poly`, and the matching `just` recipes (commit `7f949e0`).
Full end-to-end tests cover the OSC path at every layer
(`oscWireAndDispatchTests`, `oscListenerTests`, `oscEndToEndTests`).

### 6.C — Buffer I/O (closed through §6.C.5 follow-up)

Producer-allocated `Buffer` resources survive `rt_graph_clear` and
hot-swap, with live-safe retire/collect.

Kinds shipped:

- `KPlayBufMono` (tag 20) — random-access read with frozen
  buffer id, loop / one-shot.
- `KRecordBufMono` (tag 21) — sample-by-sample write, pass-through
  audio output. The first audio-thread *writer* kind.

Resource model:

- `ResourceFootprint = ResourceFootprint { rfBuses, rfBuffers }` —
  carried by `Template.tplFootprint` and `RuntimeRegion.rrFootprint`.
- The §6.C.4 precedence union picks up `BufWrite → BufRead` on the
  same buffer; same-buffer `BufWrite / BufWrite` is rejected
  inter-template *and* intra-graph.
- §6.C.5: writer-template polyphony clamped to 1. Enforced
  declaratively in every Haskell loader (`loadRuntimeGraph`,
  `loadRuntimeGraphFused`, `loadTemplateGraph`,
  `loadTemplateGraphFused`) and as a runtime backstop on the
  public C ABI (`rt_graph_template_add_node`,
  `rt_graph_template_set_polyphony`). Either layer alone is
  sufficient; both together cover direct-C-ABI callers.

What's *not* in 6.C: random-access `BufWr`, multichannel records,
file I/O, async load, OSC `/buffer/*` control. The §6.C.4 design
note records the parked items.

### 6.D — Spectral (v1 contract complete)

One spectral kind end-to-end, plus a descriptive latency surface.

- `KSpectralFreeze` (tag 22). Fixed N=1024 / hop=256 STFT with a
  Hann window and overlap-add resynthesis. Two operating modes
  (pass-through / freeze) selected by a hop-latched `freeze_flag`.
  Per-instance state on `SpectralFreezeState` — nothing crosses
  a graph-instance boundary, so `inferEff = [Pure]` and the
  §6.C resource machinery does not apply.
- Counter-confirmed tests: pre-roll silence, warmed-up impulse
  latency = N, sine reconstruction to unity, COLA / WOLA scale
  pinned, freeze-mode counter divergence, unfreeze recovery, and
  a hop-boundary latch test that exercises a 1-frame transition
  straddling the hop fi to prove the kernel reads `freeze_in[fi]`
  exactly at the hop boundary.
- `kindLatency :: NodeKind -> Maybe Int` accessor. Declarative
  only: no IR or scheduler pass consumes it today.
- `MetaSonic.Bridge.Compile.Latency` ships
  `declaredLatencyFootprint`, `nodeOutputLatencies`, and
  `inputLatencySkews`. Both `--corpus-survey` and
  `--fusion-survey` render the footprint and any uncompensated
  skew.
- Spectral regions become `Barrier`s in the schedule
  (`regionHasSpectral`), mirroring the §6.C.5 writer-region
  rule. Conservative — STFT kernels do bursty FFT work at hop
  boundaries, which is the wrong shape for the §4.E parallel-band
  equal-work assumption.
- Hann table and WOLA scale are namespace-scope constants so the
  audio thread never pays a lazy-init cost.

What's *not* in 6.D: a second spectral kind, spectrum-stream
types between kinds (SC's PV_* family), runtime-tunable N / hop,
multichannel STFT, latency compensation (the parked decision is
recorded at
[notes/2026-05-11-e-phase-6d-latency-followup-decision.md](2026-05-11-e-phase-6d-latency-followup-decision.md))
and block-rate region promotion.

### 6.E — Plugin Hosting (open)

Untouched. The natural next series is a design note that bounds
the contract (minimum first plugin kind, scratch ownership,
realtime/non-realtime boundary, error vocabulary, interaction
with `ResourceFootprint`) before any C++ kernel lands. Coupling
to §6.C is real — plugin-owned sample buffers will likely reuse
the existing pool — but no runtime work has happened yet.

## What This Boundary Settles

- **Resource model.** Bus + buffer. Both are integer-keyed,
  disjoint id spaces; spectral kinds extend compute capability
  without touching the resource model. Any further axis must
  add a new field to `ResourceFootprint` and rederive the
  precedence rules from there — no in-line extensions.
- **Producer / runtime split for shared resources.** Allocation
  happens producer-side (`allocBuffer`); lifecycle hooks
  (`retireBuffer` / `collectRetiredBuffer`) are explicit; the
  audio thread observes state through `std::atomic<BufferSlotState>`
  with acquire-load semantics. Any future shared resource follows
  this contract.
- **Single-writer-single-instance for buffer writers.** Two-sided
  Haskell + C ABI enforcement (§6.C.5). Lifting this is reserved
  for §6.C.5+ once a real ordering / mixdown primitive is
  designed.
- **Declarative latency surface.** `kindLatency` declares the
  steady-state pipeline latency a kind introduces; the
  descriptive analysis (`declaredLatencyFootprint`,
  `inputLatencySkews`) is the diagnostic. No compensation pass
  ships in 6.D; the corpus reports zero uncompensated skew, so
  the decision was made to keep compensation parked.
- **Counter-confirmed-validation pattern is now standard.** Every
  audio-thread kernel that touches shared state ships a
  diagnostic counter alongside it (`buffer_write_count`,
  `buffer_invalid_write_count`, `spectral_analysis_count`,
  `spectral_resynthesis_count`). Tests assert exact counter
  values, not just rendered audio.

## What's Parked / Deferred

Documented in their respective design notes:

- §4.D block-rate executor — the per-port `PortConsumptionRate`
  metadata is descriptive only; runtime block-rate execution is
  parked until corpus signal grows. 6.D did not change this.
- §4.E worker dispatch — substrate is in place but default-off;
  no representative workload yet justifies enabling it.
- Whole-region kernel codegen — explicitly indefinite defer;
  hand-written kernels plus narrow helpers is the working
  approach.
- §6.C.5+ lifting writer cardinality — requires an explicit
  ordering / mixdown primitive that does not exist yet.
- §6.D second spectral kind, spectrum-stream type, multichannel,
  variable N / hop — each is its own follow-up once a real use
  case asks.
- §6.D latency compensation — the descriptive surface ships;
  the compensating IR pass does not.

## How to Read This Snapshot

The snapshot is not a freeze — main keeps moving. Two ways the
snapshot stays useful:

- **Boundary marker.** If a later commit changes one of the
  invariants pinned above (resource axes, polyphony rule,
  declarative-latency posture, counter pattern), the snapshot is
  the version of those rules the §6.E design note can quote
  against.
- **Reference for the §6.E note.** §6.E's first job is to
  decide which of the §6.A–6.D contracts plugins inherit
  unchanged and which need extension. This note lists those
  contracts in one place.

If anything in here changes during 6.E or beyond, update the
relevant design note rather than amending the snapshot — the
6.C.4 / 6.C.5 / 6.D precedent stands.
