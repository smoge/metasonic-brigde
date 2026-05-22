# Phase 8d-a — KSmooth Default-Init Swap Baseline Harness

Date: 2026-05-22

Status: design note for a narrow roadmap-completeness exception. No
code lands on the strength of this note alone. Review against
`Demos.hs`, `preservingHotSwapNodeClass`, and the enumerated
`reject-preserving-smooth` reference set before opening the
implementation slice.

Companion to
[2026-05-21-b-live-session-operator-pass-playbook.md](2026-05-21-b-live-session-operator-pass-playbook.md)
(`## Evidence To Code` rubric, `0a0c98d`) and the Phase 8b closure
tag `phase-8b-repertoire-osc-validated`. The reject-path predecessor
is [2026-05-21-a-reject-path-operator-pressure-pass.md](2026-05-21-a-reject-path-operator-pressure-pass.md).

Primary source material:

| Topic | File | Symbol |
|-------|------|--------|
| Preserving-reload classification table | [RTGraphAdapter.hs](../src/MetaSonic/Session/RTGraphAdapter.hs) | `preservingHotSwapNodeClass` |
| Per-node migration validation | [RTGraphAdapter.hs](../src/MetaSonic/Session/RTGraphAdapter.hs) | `validateStatefulNode` |
| Hot-swap substrate status | [ROADMAP.md](../ROADMAP.md) | §5 "Hot Graph Replacement" |
| Reject-fixture authoring (current) | [Demos.hs](../app/MetaSonic/App/Demos.hs) | `rejectPreservingSmoothDarkAuthoring` / `dronePreserveSmoothDark` |
| Reject-fixture JSON (current) | [reject-preserving-smooth.json](../examples/manifests/reject-preserving-smooth.json) | (whole file) |
| Smoothed-control entrypoint | [Authoring.hs](../src/MetaSonic/Authoring.hs) | `control` (emits `KSmooth`) |
| Named-control demo (working precedent) | [Demos.hs](../app/MetaSonic/App/Demos.hs) | `namedControlGraph` / `namedControlAuthoring` |
| Phase 8b repertoire (working precedent) | [Demos.hs](../app/MetaSonic/App/Demos.hs) | `droneSawFilterDark` / `sawFilterDarkAuthoring` |
| Swap-bench precedent | [ROADMAP.md](../ROADMAP.md) | §5.3.C "Swap-bench instrumentation" |


## Why This Slice

This is a **roadmap-completeness exception**, not an Evidence To Code
promotion. No operator transcript opened it; the Phase 8b passes
explicitly avoided `Auth.control` / `KSmooth` precisely because
`KSmooth` is `PreserveUnsupported`. The slice exists because:

- ROADMAP §5 names `Env`, `Delay`, and `Smooth` state preservation as
  the remaining substrate work toward the universal "without audible
  glitches" claim.
- Any future preserving demo that uses smoothed controls
  (`Auth.control` / `ccControl`), a delay-based wet path (`KDelay`),
  or envelope articulation (`KEnv`) will hit this gap immediately.
- The gap is currently inferred from the classification table, not
  measured. The harness slice converts it from "known unsupported"
  into "measured artifact" so the eventual prewarm/copy slice has a
  before/after to point at.

The playbook's `Evidence To Code` rubric calls this a calibrated
exception. The opening design note must say so explicitly; this is
that note.


## Contract Change

> This slice weakens the old `KSmooth` preserving contract from
> "reject" to "commit with default-init state" so the artifact can be
> measured. That is intentional and bounded to `KSmooth`;
> unsupported-kind reject coverage is preserved by moving the reject
> fixture to `KDelay`.

`KSmooth` is the *only* kind whose contract changes in 8d-a. `KDelay`
and `KEnv` stay `PreserveUnsupported`. The post-8d-a substrate is:

| Kind | Pre-8d-a | Post-8d-a |
|------|----------|-----------|
| `KSmooth` | `PreserveUnsupported` (rejects) | `PreserveStatefulDefaultInit` (commits; state default-inits) |
| `KDelay` | `PreserveUnsupported` | unchanged |
| `KEnv` | `PreserveUnsupported` | unchanged |

The prewarm/copy that closes the artifact gap is **8d-b**, a separate
slice. 8d-a does not claim the artifact is fixed; it claims the
artifact is measurable.


## The Four Items

### 1. Classification change

Add a fourth constructor to `PreservingHotSwapNodeClass` in
`RTGraphAdapter.hs`:

- `PreserveStatefulDefaultInit` — participates in preserving swaps and
  validates against old nodes (key present, kind match, control-length
  match), but the C++ migration path default-inits the state instead
  of copying it.

Effects on derived predicates:

- `nodeKindSupportsPreservingHotSwap` returns `True` for the new
  class.
- The current `nodeKindNeedsStateCopy` predicate is used for two
  things at once: selecting nodes that must be migration-key /
  kind / control-shape validated in `validatePreservingTemplate`,
  *and* computing `phspExpectedStateCopyCount`, which
  `verifyPreservingMigrationCounts` later requires the C++
  `migration_state_copy_count` to match. For
  `PreserveStatefulDefaultInit` we want the first behavior but
  not the second: validation must still iterate, but no state
  copy will be performed.
- The implementation must therefore split or rename the
  predicate. Either:
  - introduce `nodeKindNeedsPreservingValidation` that returns
    `True` for the new class and is the gate
    `validatePreservingTemplate` filters on, plus
    `nodeKindNeedsStateCopy` that returns `False` for the new
    class and is the input to `phspExpectedStateCopyCount`;
  - or rename `nodeKindNeedsStateCopy` to make its narrower
    meaning explicit and add a separate validation gate.
  The expected-count predicate must only include
  `PreserveStateful` nodes; the validation-gate predicate must
  also include `PreserveStatefulDefaultInit` nodes.
- The Haskell preparation path must encode this distinction so the
  C++ migration path default-inits rather than counting / copying
  state for that node. `migration_state_copy_count` does not
  include default-init nodes, and `verifyPreservingMigrationCounts`
  expectations must agree with that.

`KSmooth` moves from `PreserveUnsupported` into the new class. No
other kind moves.


### 2. Reject fixture migration

The current `reject-preserving-smooth` fixture pins the supervisor
reject path (`SupervisedReloadRequestRejected` via
`validateStatefulNode → SriHotSwapWouldPreserveVoices`). That path
needs to stay pinned by a deterministic unsupported-kind fixture
after 8d-a; otherwise the whole rejected-live-fallback chain loses
its concrete coverage.

The migration:

- New: `reject-preserving-delay.json` plus matching `Demos.hs`
  entries (`dronePreserveDelayDark` / `dronePreserveDelayBright`,
  `rejectPreservingDelayDarkAuthoring`, etc.). `KDelay` stays
  `PreserveUnsupported`, so the reject path fires for the same
  structural reason.
- Retire `reject-preserving-smooth.json` and its `Demos.hs` entries.
- Update every site referencing the old fixture key. Enumerated
  before-code grep (see [Open questions](#open-questions-to-resolve-before-code)).

The "smooth voice rejects" guarantee is replaced by "delay voice
rejects." The supervisor-reject coverage is preserved; the
unsupported-kind it picks on is just different.


### 3. New smooth preserving fixture

A new fixture that *exercises* smoothing, analogous to
`preserve-cutoff` but with `Auth.control`-routed cutoff:

- Two single-template drone demos, e.g. `preserve-smooth-cutoff-dark`
  / `preserve-smooth-cutoff-bright`.
- Voice graph: `sawOsc → lpf → gain → out`, but the LPF cutoff is
  driven through `Auth.control` (which emits a `KSmooth` node on the
  cutoff control path).
- After 8d-a, this fixture's preserving reload **commits** rather
  than rejects — the harness measures the artifact at the commit
  boundary.
- The fixture didn't exist before because it couldn't commit. It is
  the third new artifact in 8d-a, not just measurement code.

Working precedent: `namedControlGraph` already uses `Auth.control` /
`Auth.controlConnection` in [Demos.hs](../app/MetaSonic/App/Demos.hs).
Same shape, narrowed to one control for the preserving fixture.


### 4. Offline artifact harness

Extends the `--swap-bench` / offline-driver pattern. Measures audio
samples around the swap install boundary against a per-fixture
threshold pair.

Window contract:

- **Block-aligned.** The C++ side installs at a block boundary
  deterministically (per ROADMAP §5.3.C: *"install reliably one block
  on the offline driver"*). The harness window aligns with that
  known-stable event.
- **Width.** One audio block before the install + one audio block
  after. Wider windows average the transient away; narrower windows
  miss it.
- **Metrics.** Time-domain peak delta and RMS over the post-install
  window. FFT is *not* in 8d-a; revisit only if time-domain numbers
  prove insufficient on the post-8d-b re-measurement.

Threshold policy (two-bound, no exact floats):

- **8d-a baseline** assertion:
  - `artifact >= minimum_gap` — proves the gap exists (the swap
    really did default-init and produced a discontinuity).
  - `artifact <= runaway_bound` — guards against a regression that
    makes the artifact worse than baseline.
- **8d-b post-prewarm** assertion (lands later):
  - `artifact <= small_bound` — proves the prewarm/copy closed the
    gap.

`minimum_gap`, `runaway_bound`, and `small_bound` are chosen
empirically from the first harness run; pinned values are
documented in the fixture, not in code comments. Avoids
platform-float-drift brittleness while still catching real
regressions.


## Out Of Scope

8d-a deliberately does *not* touch:

- **`KDelay` / `KEnv`.** They stay `PreserveUnsupported`. Adding
  them to `PreserveStatefulDefaultInit` at the same time would
  smuggle three contract changes into one slice while only proving
  one of them. Each gets its own slice if/when opened.
- **The prewarm/copy logic itself.** That's 8d-b, after the harness
  produces a baseline number that 8d-b can point at.
- **Live audio capture.** No output-capture path exists. Offline
  measurement matches the prior pattern (`--swap-bench`,
  `--fusion-survey`).
- **FFT or frequency-domain analysis.** Time-domain peak/RMS is the
  cheap version; defer FFT until evidence shows it's needed.
- **Bus content migration.** Buses remain caller-owned per
  ROADMAP §5.4.
- **Multi-control smoothing.** The new fixture uses one smoothed
  control (cutoff). Extending to multi-control smoothed voices is
  a future concern.
- **GUI / current-value introspection / command history / ALSA
  noise.** Still candidate lanes from the operator-pass playbook;
  not opened by this slice.


## Open Questions To Resolve Before Code

Concrete grep / verify steps:

- **Enumerate `reject-preserving-smooth` references before edit.**
  Today's grep finds matches in:
  - `app/MetaSonic/App/Demos.hs` (4 authoring/control definitions
    plus 2 `demoTable` entries; ~lines 555-603 and 845-852)
  - `examples/manifests/reject-preserving-smooth.json` (the fixture
    itself)
  - `test/MetaSonic/Spec/AppDemos.hs` (catalog list)
  - `test/MetaSonic/Spec/AppManifestLiveSession.hs` (demos list)
  - `test/MetaSonic/Spec/AppManifestPreservingFixture.hs` (byte-eq
    drift guard + the CC pin test)
  - `notes/2026-05-20-b-manifest-live-session-v0.md` (reference)
  - `notes/2026-05-21-a-reject-path-operator-pressure-pass.md`
    (operator-pass note — this *is* the reject path it pressures)
  - `notes/2026-05-21-c-interacting-with-metasonic-tutorial.md`
    (tutorial reference)

  The notes references are historical operator-pass artifacts and
  must not be retroactively rewritten — they record what happened,
  not what's current. The code/test/fixture references migrate to
  `reject-preserving-delay`.

- **Operator-pass note (`2026-05-21-a`) status.** That note pressed
  the reject path against `reject-preserving-smooth`. After 8d-a,
  the equivalent pass would press against `reject-preserving-delay`.
  Whether to add a Findings-style continuation or leave the
  historical note untouched is a write-time decision; do not rewrite
  the original.

- **Migration-path channel.** The Haskell preparation path must make
  the default-init distinction visible to the runtime migration plan.
  Confirm where the existing `PreserveStateful` state-copy expectation
  translates to migration behavior in `tinysynth/rt_graph.cpp`; the
  `PreserveStatefulDefaultInit` arm hooks in at the same preparation /
  verification seam without requiring the C++ audio thread to know the
  Haskell classification name.

- **Threshold seeding values.** `minimum_gap`, `runaway_bound`, and
  `small_bound` are picked from the first harness run; the 8d-a
  design does not pre-commit specific numbers. The note that pins
  them lives in the fixture file alongside the captured value.

- **Test count delta.** Adding the harness fixture and re-pointing
  the drift guard will move the test count; the slice's commit
  message records the before/after.


## Sequencing Within 8d

| Slice | Scope | Deliverable |
|-------|-------|-------------|
| **8d-a** (this note) | Classification + reject migration + smooth fixture + harness | Measurable artifact baseline |
| **8d-b** | `KSmooth` prewarm/copy on the C++ migration path | Harness numbers tighten; same fixture, different pin |
| (later) | `KDelay` slice (parallel shape to 8d-a + 8d-b) | Only if opened by evidence or further roadmap-completeness reasoning |
| (later) | `KEnv` slice (hardest state shape) | Same gating |

Delay and Env are explicitly not implicit follow-ons of 8d. Each
needs its own opening note and its own evidence-or-completeness
justification.
