# Phase 8d-b — KSmooth Preserving State Copy

Date: 2026-05-22

Status: closed. Implementation landed as `6f4128c`
(`Implement KSmooth preserving state copy`). First-run calibration
measured peak delta = 0 and RMS delta = 0 on the
`preserve-smooth-cutoff` fixture; pinned bounds carry a small
stability margin above zero. Both test suites green.

Cross-references the 8d-a design note for the substrate framing,
predicate split, and harness contract; does not restate them.

Companion to:

- [2026-05-22-c-ksmooth-swap-artifact-harness-design.md](2026-05-22-c-ksmooth-swap-artifact-harness-design.md) — 8d-a design note.
- 8d-a implementation: `bec7d2f` (`Add KSmooth default-init swap artifact baseline`).
- 8d-a design-note commit: `31a6d43`.
- 8d-b implementation: `6f4128c` (`Implement KSmooth preserving state copy`).
- 8d-b design-note commit: `72977cc`.

Primary source material touched by this slice:

| Topic | File | Symbol |
|-------|------|--------|
| C++ kind-eligibility table | [rt_graph.cpp](../tinysynth/rt_graph.cpp) | `node_kind_supports_state_migration` |
| C++ per-kind state copy | [rt_graph.cpp](../tinysynth/rt_graph.cpp) | `copy_supported_dsp_state` |
| C++ smoother state shape | [rt_graph.cpp](../tinysynth/rt_graph.cpp) | `SmoothState` (`Note [Per-node smooth state]`) |
| Q smoother field shape | [vendor/q/q_lib/include/q/fx/lowpass.hpp](../vendor/q/q_lib/include/q/fx/lowpass.hpp) | `dynamic_smoother` |
| C++ migration test shape | [tests/rt_graph_test.cpp](../tests/rt_graph_test.cpp) | `hot-swap migration: biquad filter state survives payload install` (model) |
| C++ unsupported-lazy-state test | [tests/rt_graph_test.cpp](../tests/rt_graph_test.cpp) | `hot-swap migration: unsupported lazy state skips without control copy` (kKindSmooth removed) |
| Haskell classification table | [src/MetaSonic/Session/RTGraphAdapter.hs](../src/MetaSonic/Session/RTGraphAdapter.hs) | `preservingHotSwapNodeClass` |
| Haskell artifact harness | [test/MetaSonic/Spec/Session/SwapArtifact.hs](../test/MetaSonic/Spec/Session/SwapArtifact.hs) | (whole module) |


## Why "state copy", not "prewarm"

The 8d-a design note used "prewarm/custom-copy" as a loose label
inherited from ROADMAP §5 ("an allocation-free prewarm / custom-copy
slice"). The actual 8d-b fix is **real state migration**: copy the
three `SmoothState` fields (`smoother`, `last_base_freq`, `last_sps`)
from the old node's variant payload to the new node's variant
payload during the audio-thread install loop. No warmup, no replay,
no synthetic resynthesis. The slice should be named to match what it
does. Note title, commit message, and test/group renames all use
"state copy."


## Preflight verdict (recap)

`q::dynamic_smoother` is five POD `float` fields with compiler-default
copy assignment ([lowpass.hpp:219-260](../vendor/q/q_lib/include/q/fx/lowpass.hpp)).
`SmoothState` wraps it in `std::optional<>` plus two scalar memos
([rt_graph.cpp:675-679](../tinysynth/rt_graph.cpp)). End-to-end
trivially copyable; the slice is a small implementation.


## Scope

### C++ — three edits in `rt_graph.cpp`

1. Move `case NodeKind::Smooth:` out of the `return false` arm of
   `node_kind_supports_state_migration` and into the `return true`
   arm beside the oscillator / biquad / bus kinds.
2. Add a `case NodeKind::Smooth:` to `copy_supported_dsp_state`
   modeled on the oscillator copy pattern: `std::get_if<SmoothState>`
   on both sides, assign all three fields, return
   `StateMigrationResult::Copied`.
3. Remove `NodeKind::Smooth:` from the `Unsupported` bundle in
   `copy_supported_dsp_state`.

### C++ tests — split the existing unsupported-lazy-state test

`tests/rt_graph_test.cpp` currently iterates `{kKindDelay, kKindSmooth}`
together in the unsupported-state test at line 9186. The split:

- The loop reduces to `{kKindDelay}` only. `kKindDelay` remains the
  fixture's unsupported-kind anchor.
- A new sibling `TEST_CASE("hot-swap migration: smooth state survives
  payload install")` is added beside the oscillator / noise / biquad
  tests (line 9034 / 9089 / 9133). Shape modeled on the biquad test
  at line 9133:
  - Build an old-world graph with one tagged `kKindSmooth` node.
  - Build a swap payload with the same shape.
  - Render the old graph for a few blocks so the smoother's IIR
    state diverges from initial seed.
  - Publish the swap, install at the next block boundary.
  - Render the post-swap graph and an "uninterrupted expected"
    reference graph for the same number of blocks.
  - Assert the post-swap render matches the uninterrupted reference
    (sample-level, or near-equal within IEEE tolerance).
  - Assert `rt_graph_swap_migration_state_copy_count(retired) == 1`.

### Haskell — one edit + one cleanup in `RTGraphAdapter.hs`

1. Move `KSmooth -> PreserveStatefulDefaultInit` to
   `KSmooth -> PreserveStateful` in `preservingHotSwapNodeClass`.
2. **Retire `PreserveStatefulDefaultInit`.** After KSmooth moves
   out, the class has zero members. Removing it is cheaper than
   keeping an empty hook. When a future slice opens for `KDelay` or
   `KEnv` and the same "validate-but-default-init" shape is wanted,
   re-adding the class is a few lines.

   This retirement affects:
   - `data PreservingHotSwapNodeClass` — remove the constructor.
   - `nodeKindSupportsPreservingHotSwap` — remove the arm.
   - `nodeKindNeedsPreservingValidation` — remove the arm.
   - `nodeKindNeedsStateCopy` — remove the arm.
   - The classification table header comment (the "DefaultInit class
     is deliberately admitted..." paragraph) — drop.

   GHC's exhaustive case-match check enforces all four edits land
   together.

### Haskell tests — assertion flip and rename

`SwapArtifact.hs` (the artifact harness):

- Test group rename:
  - 8d-a: `"Phase 8d-a: KSmooth swap artifact baseline"` /
    `"KSmooth default-init preserving swap has measurable
    post-install artifact"`.
  - 8d-b: `"Phase 8d-b: KSmooth swap artifact bounded"` /
    `"KSmooth preserving swap post-install artifact stays within
    state-copy bound"`.
- `stateCopies @?= 2` → `stateCopies @?= 3`. Comment enumerates
  carrier (KSawOsc) + LPF (KLPF) + smoother (KSmooth).
- Assertion flip on the gap metrics:
  - Remove `>= kMinimumPeakGap` and `>= kMinimumRmsGap` assertions
    (the gap should close, not exist).
  - Add `<= kSmallPeakBound` and `<= kSmallRmsBound` assertions.
    These are the post-state-copy upper bounds.
  - **Keep** `<= kRunawayPeakBound` and `<= kRunawayRmsBound` as
    regression guards. The two-bound shape stays, but the pair is
    now `(small_bound, runaway_bound)` instead of
    `(minimum_gap, runaway_bound)`.
- Remove `kMinimumPeakGap` and `kMinimumRmsGap` constants. Add
  `kSmallPeakBound` and `kSmallRmsBound` constants. Both are seeded
  from the first 8d-b run with a small stability margin (not the
  exact observed value) so platform-float variance and minor IIR
  noise floor don't flake the assertion. Pinned in the fixture,
  documented inline.
- Update the threshold preamble comment to point at 8d-b's design
  note plus 8d-a's, and keep the "don't loosen before checking
  semantics" rule.

`RTGraphAdapterHotSwap.hs` (the adapter-level test):

- Rename `"preserving-only hot-swap admits KSmooth default-init
  active voice"` → `"preserving-only hot-swap migrates KSmooth
  active voice"`. Drop the "default-init" language; the smoother now
  migrates.
- Keep the test's existing assertion shape (commit, voice binding
  retained, post-swap control write accepted). Sample-level
  continuity stays the load-bearing assertion in the artifact
  harness and the new C++ runtime test; the adapter test does not
  need to duplicate it.

### Fixtures — no changes

- `examples/manifests/preserve-smooth-cutoff.json`: structure
  unchanged. The same fixture that produced a measurable artifact
  in 8d-a now produces a bounded one.
- `examples/manifests/reject-preserving-delay.json`: unchanged.
  KDelay stays `PreserveUnsupported`.
- Drift-guard byte-equality tests and CC-pin tests are unaffected.


## Out Of Scope

- **`KDelay` and `KEnv`.** They stay `PreserveUnsupported`. Each
  needs its own slice; this is *not* a "Phase 8d-b extends to all
  three" change.
- **Warmup / replay strategies.** Not a real migration. This slice
  does direct state copy only.
- **Bus content migration.** Still caller-owned per ROADMAP §5.4.
- **Live audio capture.** Offline-driver path is sufficient.
- **FFT or spectral analysis.** Time-domain peak/RMS continues to
  be the harness metric.
- **New FFI surface.** Existing `c_rt_graph_read_bus`,
  `c_rt_graph_process`, `collectRetiredSwapStats`,
  `smsStateCopyCount`, `hotSwapTemplateGraph`,
  `readSwapGeneration` cover everything.


## Open Questions To Resolve Before Code

- **Empirical `small_bound` seeding.** First 8d-b harness run will
  produce a real number; the pinned constant takes that number plus
  a small stability margin (not the exact observed value), so
  platform-float variance doesn't flake the test on otherwise-clean
  runs. If the first run surprises (much larger than the predicted
  ~float-precision noise floor), inspect the copy path before
  growing the margin — the design note's "don't relax bounds before
  checking semantics" rule applies symmetrically here.
- **C++ "uninterrupted expected" reference graph construction.**
  The biquad test's pattern is the model; verify the same shape
  works for `kKindSmooth` (in particular, that the smoother's lazy
  construction-on-first-process behavior doesn't introduce a
  block-boundary discontinuity in the reference graph that the
  swap path doesn't reproduce).
- **`stateCopies` count in the adapter test.** After the smoother
  migrates, the adapter test should not need to assert the count
  directly — it relies on the harness for that. But if any existing
  adapter-test arm checks state-copy counts, it must update to
  match the new contract.


## Verification

1. `just cpp-test` — 323/323 passed. The new
   `hot-swap migration: smooth state survives payload install` test
   asserts `state_copy_count == 2` (sine source + smoother) and a
   sample-for-sample match against the never-swapped reference. The
   unsupported-lazy-state test still passes with `kKindDelay` only.
2. `just stack-test` — 1394/1394 passed. The harness's
   `stateCopies @?= 3` and `<= kSmallPeakBound` /
   `<= kSmallRmsBound` assertions all hold; calibration observed
   peak delta = 0, RMS delta = 0.
3. `git diff --check` — clean.

One commit, same shape as 8d-a's `bec7d2f`.


## Sequencing After 8d-b

| Slice | Status | Notes |
|-------|--------|-------|
| 8d-a | Closed (`bec7d2f`) | Default-init baseline measured |
| **8d-b** (this note) | Closed (`6f4128c`) | KSmooth state copy; harness flipped to bounded; calibration observed 0/0 |
| Later: `KDelay` slice | Not open | Would re-introduce `PreserveStatefulDefaultInit` if same shape applies |
| Later: `KEnv` slice | Not open | Hardest state shape (multi-segment state machine) |

Neither Delay nor Env should be smuggled into 8d-b. Each needs its
own opening — by evidence or by a fresh roadmap-completeness
exception, named explicitly.
