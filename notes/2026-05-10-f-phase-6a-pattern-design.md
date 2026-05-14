# Phase 6.A — Pattern Layer Design

Date: 2026-05-10
Status: design only; bounds the in/out-of-scope before 6.A.2 (minimal
pattern corpus) or 6.A.3 (verification gate) lands code.

## Position in the roadmap

Phase 6.A is the first active sub-phase of the rewritten Phase 6 in
[ROADMAP.md](../ROADMAP.md). Phase 5 is closed as v1 complete with
§5.3.D and §5.4.C explicitly deferred until real-producer evidence
shows the friction. The pattern layer is the first such producer
candidate.

The project's load-bearing pattern is "descriptive measurement first,
runtime change later":

- §4.D propagated rate metadata before any block-rate executor.
- §4.E shipped a synthetic bench, a Haskell-loaded worker bench, and
  a recorded turn-on decision before enabling worker dispatch.
- §5.3.C built `--swap-bench` before deciding whether to extend
  §5.3.D.

6.A.1 sits in that same slot: a design note that bounds the work
before code lands.

## What 6.A is

A Haskell-side producer of:

1. Compiled `SynthGraph` / `TemplateGraph` payloads, eligible for the
   existing `loadTemplateGraph` / `hotSwapTemplateGraph` paths.
2. Timed control / hot-swap events expressible as the existing
   realtime control queue + `SwapGeneration` protocol.

The pattern layer compiles its output through the same `lowerGraph`
→ `compileRuntimeGraph` → FFI pipeline as any other producer. It does
not bypass §4 fusion / region selection, §5 swap protocol, or any
existing instrumentation.

## What 6.A is not

- **Not a runtime scheduler in Haskell.** A pattern producer may run
  its own clock thread to emit timed events. What it must not do is
  drive a per-block audio scheduler or own audio-thread state. Live
  events reach the audio thread only through the existing realtime
  control queue or the swap protocol — both already
  audio-thread-safe.
- **Not a new DSL layer.** Patterns build `SynthGraph`s through the
  existing `runSynth` builders. No parallel construction API; no
  syntactic sugar that competes with the source DSL.
- **Not a new audio-thread substrate.** Patterns add no `NodeKind`s,
  no FFI entry points, and no per-block audio-thread bookkeeping.
  All audio-thread state stays under the §2 spec/state model.
- **Not concert-grade.** 6.A is verification-first; ergonomic
  surface, event-timing precision beyond block boundaries, and live
  UX polish are explicitly out of scope until the corpus and
  verification gate settle.

This boundary matters because pattern systems pull strongly toward
live-scheduling and DSL territory. Naming the boundary up front lets
later reviewers reject scope creep on principle rather than taste.

## Corpus naturalness

The 6.A.2 corpus must hold to one rule:

> Shapes are chosen because they are natural for music-making.
> Coverage of fusion / parallelism / hot-swap gates is incidental,
> not a corpus design goal.

The §4.E freeze names the trap directly: a benchmark row added purely
to feed the bench is circular evidence. The pattern corpus is subject
to the same rule. If the corpus is engineered to satisfy the §4.B.x
gate or the §4.E worker-pool turn-on threshold, the resulting
"signal" proves nothing.

Concrete consequence: when 6.A.2 lands, every corpus entry should be
defensible as a real musical pattern, not as a fusion probe in
disguise. If a candidate row exists only to exercise an existing
survey or bench, it does not belong in the pattern corpus — it
belongs in `tools/rt_graph_bench.cpp` or the `--fusion-survey`
synthetic shapes, where its purpose is honest.

## Verification meaning

6.A.3 verification has two layers, and only the second one is the
actual gate:

(a) Existing surveys / benches run cleanly against pattern-generated
    artifacts. (Trivial.)

(b) Pattern-generated artifacts produce shapes the existing surveys
    and benches *already recognize*. The corpus exercises:

    - `--fusion-survey`'s ranked missed-shape table — do parked rows
      like Tri/Pulse/Add filtered tails or Add-rooted shapes move?
    - `--fusion-survey`'s edge-rate / producer-grouped opportunity
      headline — does the §4.D opportunity count grow beyond the
      current 4 producers / 4 kinds?
    - `--worker-bench`'s C1c / C1d-c partition — do any rows show
      best-c1d-worker-speedup beyond the current synthetic envelope?
    - `--swap-bench`'s producer / install / collect medians under
      pattern-driven swap rates rather than the current fixed
      single-shot battery.

Layer (b) is the gate that decides whether parked items move.
Layer (a) is a smoke test. 6.A.3 must report on both, with (b) as
the primary signal.

## Swap-bench under pattern load

`--swap-bench` was built (§5.3.C) against a fixed, deterministic
single-shot corpus: unchanged graph, tagged oscillator, tagged
biquad, lifecycle-only graph, fused graph, two-template ensemble.
Each row runs 11 reps in fresh handles.

When 6.A.2 / 6.A.3 land, patterns become a continuous source of
hot-swaps rather than discrete fixtures. That changes what the
swap-bench measures:

- **Cumulative producer cost** matters more than single-shot prepare
  / publish median. A pattern that swaps twice per second over a
  session shifts the relevant statistic from per-swap median to total
  producer-side wall time per minute.
- **Install-block distribution** becomes interesting. The current
  bench reports `blocks_to_install` as a counter that must equal an
  expected signature. Under pattern load that distribution may show a
  long tail the fixed corpus cannot.
- **Generation-tracking pressure** rises. `waitForSwapGeneration` and
  the `hotSwap*AndWait` helpers are documented as single-producer /
  single-collector v1 conveniences. A pattern that emits swaps faster
  than the audio thread installs them is the first workload that
  exercises the multi-producer attribution gap.

These are *outcomes to watch*, not bench changes to land in 6.A.
`--swap-bench` keeps its current shape; 6.A.3 just notes whether
pattern-driven runs surface friction the fixed corpus did not. If
friction shows up, the §5 deferrals (5.3.D blocking wait, 5.4.C
producer-side mapping helpers) become candidate work — but only with
this concrete signal, not in advance.

## Cross-phase couplings worth flagging

- **6.D / spectral may inform §4.D.** FFT windows are inherently
  block-structured. The 6.D corpus would be the first non-trivial
  block-rate consumer, which can grow §4.D's signal past its current
  4-producer floor. §4.D and 6.D are bidirectionally coupled: §4.D's
  executor waits on signal, and 6.D produces signal.
- **6.E / plugin hosting and 6.C / buffer I/O.** Most plugin formats
  want sample-buffer access. 6.E may force a 6.C revision rather than
  consume it as-is. This is why 6.C is "design pass" rather than
  "ship buffer I/O" in the rewritten Phase 6.

## Out of 6.A.1 scope

This note does not specify:

- The pattern API surface. That is a 6.A.2 / 6.A.3 design artifact;
  the existing prototype is one input but not the canonical answer.
- The corpus contents. That is 6.A.2's deliverable.
- The verification format. That is 6.A.3's deliverable, gated by the
  (b) layer above.

## Next concrete step

Land 6.A.2 (minimal pattern corpus) as a separate deliverable that
cites this note for its bounds. Do not start ergonomic / live-timing
work before 6.A.3's verification report exists.
