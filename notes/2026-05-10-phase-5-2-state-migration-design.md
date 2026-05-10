# Phase 5.2 — State Migration Design

Date: 2026-05-10
Status: 5.2.A/B/C implemented.
Scope: Phase 5.2.A–C (controls, DSP state, live-instance survival).
Companion: [2026-05-10-phase-5-rcu-hot-swap-design.md](2026-05-10-phase-5-rcu-hot-swap-design.md) §7.

Phase 5.1.A/B landed the swap protocol substrate and a real world
payload, but every install starts the new world with default node
state. A held note resets its envelope, an oscillator zeros its
phase, a filter loses its memory. This note pins how 5.2 closes that
gap without giving up the audio-thread invariants 5.1 established.

The companion design note left three sub-decisions open in §7:
identity, live-instance survival, bus-pool stability. This note records
the v1 choices now implemented by 5.2.A/B/C and writes down what the
migration pass is allowed to touch on the audio thread.

## 1. Decision: caller-supplied stable identity tags

Of the three options the parent note listed (caller tags / structural
alignment / explicit callback), Phase 5.2 picks **(a) caller-supplied
identity tags** as the v1 policy.

The reasoning:

- **(b) structural alignment** is too ambiguous as a first migration
  slice. The match predicate has to be soft enough to be useful (any
  topology edit changes node indices) and tight enough not to migrate
  state across semantically-different nodes that happen to share
  `(template_id, NodeIndex, NodeKind)`. There is no good way to
  decide where the cut point is from inside the runtime. It can land
  later as a fallback when no tag is set, but it should not be the
  first contract.
- **(c) explicit callback** moves the work to the producer, which has
  to read out old state and inject it into the new world. That
  requires a stable read-side ABI for every kind of DSP state plus a
  matching write-side ABI. It is more work for the producer than (a)
  and offers no migration that (a) cannot already express.
- **(a) caller-supplied tags** makes identity an explicit author
  decision, mirrors the SuperCollider Node-ID model in spirit (a
  stable handle, not a position), and is the smallest contract the
  Haskell side has to commit to: every `NodeIR` may carry an optional
  migration key, and the rest of the pipeline preserves it.

Structural alignment may return as a *fallback* after (a) is in
place, to handle untagged graphs gracefully. v1 does not promise
fallback behavior; untagged nodes simply do not migrate.

## 2. Identity model

A migration key is a stable, caller-chosen tag attached to a node at
source time. It survives every transformation in the pipeline:
`SynthGraph` → `GraphIR` → `RuntimeGraph` → `MetaDef::nodes[i]` on
the C++ side.

Properties:

- **Optional.** Untagged nodes are explicitly opted out of migration.
  This is important: a one-shot percussion graph does not need keys,
  and adding an opt-in cost (default reset) is safer than an opt-out
  cost (default migrate, with structural surprise).
- **Per-template scope.** Two nodes in different templates may share
  a key; templates are matched by `template_id` first. (Cross-template
  migration would require a separate template-identity policy and is
  out of scope.)
- **Unique within a template.** Duplicate keys in one template are a
  compile-time error on the Haskell path (`validateAndSort` rejects
  them). The C ABI setter also rejects duplicates so direct C/C++
  construction cannot bypass the uniqueness contract.
- **Opaque to the runtime.** The C++ side stores the key as a fixed
  16-byte array plus explicit length to avoid per-key heap storage in
  `NodeSpec`. The runtime never interprets it.
- **Byte-limited, not ASCII-limited.** The Haskell surface spells keys
  as `String`, then ships their UTF-8 byte sequence through the C ABI.
  v1 accepts 1..16 non-NUL bytes. Non-ASCII characters are allowed when
  their UTF-8 encoding fits that byte budget.

Tag origin (Haskell side):

- A new field `nodeMigrationKey :: !(Maybe MigrationKey)` on `NodeIR`,
  defaulted to `Nothing` for nodes the user has not tagged.
- A user-facing builder in `Bridge.Source` that lets callers set the
  tag on any `UGen` builder (e.g.
  `tagged "vox-osc" (sinOsc freq phase)`).
- `Bridge.FFI` ships the tag across the boundary at template
  construction time via a new C ABI entry
  `rt_graph_template_set_node_migration_key`, called immediately
  after the matching `rt_graph_template_add_node`.

The Haskell decision happens before any FFI call, so the tag is
embedded in the world payload before the producer ever touches a
swap.

## 3. Match predicate

When `rt_graph_prepare_swap_from_graph` builds a swap, it also builds
the migration plan off-audio. It walks the new world and, for every
tagged new node, looks up the matching old node in the target's
currently-active world. A match is committed into the plan only if
**all** of the following hold:

| Field | Reason |
|------|------|
| Same `template_id` | per-template scope |
| Same `migration_key` | identity |
| Same `NodeKind` | DSP state variant alternative must match |
| Same `controls.size()` | controls are copied slot-for-slot |
| Same output arity implied by `NodeKind` and same `max_frames` | output-buffer scratch is not migrated, but shape mismatch means the runtime representation changed |
| Same DSP state capability | the kind has an allocation-free migrator for the requested slice — see §5 |

If any of these mismatch, the new node falls back to default-init.
This is the v1 contract: a tag is a *request* to migrate, not a
guarantee. A user who renames a node's kind or changes its arity
gets default-init for that node and audible reset, not a silent
half-migration.

Mismatches are not errors — they are a routine consequence of editing
a graph. v1 surfaces them through plan counters on `RTGraphSwap`
before and after install; v1 does not fail publish because one tagged
node could not migrate.

`ArityMismatch` is a defensive skip reason in the current public ABI:
all supported `NodeKind` values have fixed control arity, so same-kind
control arity drift cannot be constructed through normal C/Haskell
builders today. It remains in the plan surface to pin the intended
behavior if a future kind or construction API makes same-kind arity
variation possible.

`sample_rate` is handle-owned in 5.2.A/B, not part of the prepared
world payload, and both old/new state run under the target handle's
rate after install. If a future change makes sample rate configurable
per prepared world, it must join this predicate before filter state is
copied.

## 4. Where migration runs

Migration runs **on the audio thread, during install, allocation-free**.

The alternative — producer-side off-audio migration before publish —
needs concurrent read access to the live old world while the audio
thread is mutating it. That requires either stopping audio (defeating
the point of hot swap) or freezing block writes in some new
synchronization primitive. Both are heavier than the audio-thread
copy.

The audio-thread approach is acceptable because:

- The match plan is **pre-built off-audio** when the producer prepares
  the swap. The plan is a flat
  `std::vector<MigrationCopy>` per template carrying
  `(old_template_id, old_node_index, new_node_index)` triples for
  every new node that has a tag and whose key resolves to an existing
  old node. Building the plan reads only old/new `NodeSpec` metadata:
  `kind`, control/output arity, and `migration_key`. Those fields are
  immutable from construction time forward and are *not* mutated by
  `process_graph`, so the producer can read them off-audio without
  racing the audio thread.
- The actual copy on the audio thread is per committed node and
  per matched instance slot. v1 slot matching is the slot-index rule
  from §6: old slot `k` and new slot `k` must both exist, have the
  same `template_id`, and be in a migratable state. 5.2.A copies only
  `controls` with same-size vector assignment into vectors already
  sized by `init_node_state` in the new world's prepare pass. 5.2.B
  adds per-kind DSP-state migrators only for kinds whose copy path is
  known not to allocate. 5.2.C copies slot lifecycle metadata once for
  the same slot match, independent of node-level migration keys.
- The cost is `O(N_tagged_nodes × N_instances)` per install, bounded
  by template size × polyphony cap. Same order as one block of
  rendering work; one extra block-equivalent of work at install time
  is the price of seamless swap. If a future workload makes this
  measurable, the migration plan can be reshaped (e.g. one big strided
  copy per template) without changing the contract.

The migration plan lives inside `RTGraphSwap` next to the prepared
`RTGraphState`. It is built by `rt_graph_prepare_swap_from_graph`
when both the target's old world and the source's new world are
visible to the producer. After install, the plan is irrelevant; it
travels with the swap into `retired_swap` and is freed off-audio when
the producer disposes it.

## 5. What gets migrated

### 5.1 Controls (5.2.A — first slice)

For every planned node match and every slot-index-matched instance,
copy the per-instance `controls` vector from old to new, slot-by-slot.
Controls are the user-visible parameters (filter cutoff, oscillator
frequency, gain, bus index). Migrating them is the single biggest
perceptible win and is trivially allocation-free: `std::copy` writes
into same-size vectors that were already allocated by the new world's
prepare pass.

This does overwrite the builder-prepared controls for tagged nodes in
matched live slots. That is intentional: setting a migration key means
"preserve this node's live control surface across the swap." Untagged
nodes, unmatched nodes, and unmatched slots keep whatever the builder
prepared in the new world.

Non-finite values (NaN/Inf) are passed through; the C++ kernels
already sanitize per-block, so a pathological old value lands
harmlessly.

### 5.2 DSP state (5.2.B — second slice)

For every matched node where the `state` variant alternative agrees,
copy state only through a per-kind migrator that is proven
allocation-free for the current runtime representation. There is no
blanket `NodeState` variant assignment contract.

5.2.B is implemented for the copy-safe set below. The install loop
still copies controls for committed matches, then calls an explicit
per-kind state copier. Unsupported stateful kinds are rejected during
plan construction with `StateUnsupported`, so they are not
half-migrated by copying controls while resetting DSP state.

State is held in `std::variant<OscState, NoiseGenState, LPFState,
EnvState, DelayState, SmoothState, PulseOscState, HPFState, BPFState,
NotchState, std::monostate>`. Migration is per-alternative because
each carries different fields:

- **Copy-safe v1 candidates:** OscState, PulseOscState,
  NoiseGenState, LPFState, HPFState, BPFState, and NotchState. These
  states are stored directly in the variant alternative today, with no
  lazy `std::optional` payload. 5.2.B may migrate these first.
- **Lazy optional state, deferred until prewarm/custom copy:**
  EnvState, DelayState, and SmoothState contain optional q objects
  that are constructed lazily on first process. A new world produced
  by `init_node_state` leaves those optionals disengaged. Copying an
  old engaged optional into a new disengaged optional during install
  can allocate or run constructor work on the audio thread, so these
  kinds are not migrated by the first DSP-state slice.
- **Delay geometry:** DelayState's buffer geometry is derived from
  sanitized `controls[0]` (max delay time) and `sample_rate`, not
  from `max_frames` or the runtime delay-time control. A future delay
  migrator must either prewarm the new target off-audio with the exact
  same geometry and then copy buffer contents without allocation, or
  skip migration when geometry differs.

### 5.3 Output buffers (no migration)

`outputs` (per-node frame buffers) are scratch, regenerated each
block. The new world's `init_node_state` already sized them. They
are not migrated — the next block writes them fresh.

### 5.4 Bus pool (no migration; caller responsibility)

Server bus contents (`output_buses`, `output_buses_prev`) are not
migrated. v1 commits to the contract from §7.3 of the parent note:
the caller arranges bus indices to be stable across the swap. A
delayed feedback loop reading `bus 5` will see the new world's bus 5
zeroed for the first block (since the new `output_buses_prev` was
initialized to zeros at construction), then live audio from that
block onward.

A tighter contract — preserve `output_buses_prev` across swap — could
be added later as a new copy-step at install. v1 does not do it
because the new world's bus count may differ; reconciling is a
separate identity problem.

## 6. Live-instance survival and slot identity

Instances have their own identity problem, separate from node
identity. v1 strategy:

- **Slot-index identity.** If old instance slot `k` is Active or
  Releasing in the old world, and the new world has a slot at index
  `k` belonging to the same `template_id`, migrate per-node state
  for that slot. Otherwise the new slot starts default-init (or
  Available, depending on what the producer prepared).
- The producer is responsible for arranging the new world's instance
  pool so that surviving slots line up. The `prepare_swap_from_graph`
  flow gives producers a natural way to do this: instantiate the same
  templates in the same order, then set each new instance's controls
  via the existing realtime-set or template-default ABIs.
- Instance migration is tag-free in v1. An instance migration key
  could be added later; for now, slot index plus template id is the
  identity.

5.2.A needs this slot-index identity immediately for control
migration; otherwise "per-instance controls migrate" has no defined
source/destination relation. 5.2.C extends the same slot match to the
slot state plus lifecycle fields (`block_lifecycle_active`,
`block_state_at_start`, `silent_blocks`, `block_sink_peak`) and richer
live-voice survival tests.

This deliberately does not solve the problem of "this voice should
survive, but its slot moved." That is a higher-level allocator
decision and is out of scope.

What v1 does on a slot mismatch:

- Old slot Active + no new slot at same index → audible cut on
  install. (Equivalent to today's stop/rebuild silence, but only for
  that one voice rather than the whole graph.)
- Old slot Active + new slot Available → no migration; new slot
  stays Available; voice cut.
- Old slot Active + new slot Active, same template → migrate
  controls + state per §5.
- Old slot Active + new slot Active, different template → no
  migration; new world plays whatever the new template defines for
  that slot. The voice is effectively replaced.

## 7. Match predicate failures and observability

A migration plan built off-audio may discover mismatches before the
audio thread runs install. The plan records each mismatch as one of:

- `MissingTag` — new node has no key (skipped by design).
- `KeyNotFound` — new key has no match in the old world.
- `DuplicateKey` — duplicate key in a template; Haskell rejects this
  before load, and the C ABI setter rejects it for direct callers.
- `KindMismatch` — key matches but `NodeKind` differs.
- `ArityMismatch` — controls / outputs size differ.
- `StateUnsupported` — node matches, but the selected migration slice
  has no allocation-free migrator for this kind's DSP state.

The audio thread does not consume the mismatch list — it just iterates
the committed plan entries and records install counters. Plan
mismatches surface to tests and to the producer through `RTGraphSwap`
accessor entries:

- `rt_graph_swap_migration_committed_count(swap)`
- `rt_graph_swap_migration_skipped_count(swap)`
- `rt_graph_swap_migration_skipped_reason(swap, i)` (test surface)
- `rt_graph_swap_migration_instance_copy_count(swap)` (test surface,
  written by the audio thread during install)
- `rt_graph_swap_migration_state_copy_count(swap)` (test surface,
  written by the audio thread during install)
- `rt_graph_swap_migration_lifecycle_copy_count(swap)` (test surface,
  written by the audio thread during install)

This gives the producer a way to verify migration intent matched
reality before disposing the swap.

## 8. Allocation invariants on the install path

Phase 5.1.B already makes install allocation-free (two `unique_ptr`
moves, atomic stores, no destructor on the audio thread). Phase 5.2
must preserve this:

- The migration plan is allocated **off-audio** during prepare. It
  travels with `RTGraphSwap` and outlives install.
- The 5.2.A audio-thread install loop is `O(N_copies)` same-size
  vector assignments for controls only. That path is allocation-free
  because the new world was initialized off-audio and the vector
  capacity already covers the control arity.
- The 5.2.B audio-thread install loop must call explicit per-kind
  state migrators, not `std::variant::operator=` blindly. A kind is
  migratable only if its copy path is known not to allocate into the
  already-initialized target state. EnvState, DelayState, and
  SmoothState are excluded until their targets can be prewarmed
  off-audio or copied through a custom no-allocation representation.
- The 5.2.C lifecycle copy is scalar slot metadata only: atomic
  `SlotState` store plus `silent_blocks`, `block_sink_peak`,
  `block_lifecycle_active`, and `block_state_at_start`. It does not
  allocate and does not inspect node-level migration keys.
- Mismatch handling is silent skip — the plan records the skip
  off-audio; install only branches on slot state/template agreement
  and the committed plan entries.

If any kind's state ever grows a path that allocates on copy
(unlikely, but worth pinning), 5.2 either reshapes that kind's state
or excludes it from migration. The match predicate in §3 is the
extension point: a kind can be removed from the migratable set by
returning false from a per-kind capability function.

## 9. Phased plan inside 5.2

- **5.2.A — Tag plumbing + slot-index controls migration.** Done in
  the first implementation slice.
  - `nodeMigrationKey` on `NodeIR`; `tagged` builder in `Bridge.Source`;
    plumbing through `validateAndSort`, `lowerGraph`,
    `compileRuntimeGraph`, `loadRuntimeGraph`.
  - C++: `migration_key` field on `NodeSpec`; ABI entry to set it; storage
    in `MetaDef::nodes[i]`; duplicate keys rejected in the setter so
    direct C/C++ callers cannot bypass Haskell validation.
  - Off-audio migration plan built in `prepare_swap_from_graph`: walk
    new world, look up each tag in old world, record committed
    copies and skip reasons.
  - Audio-thread install loop: copies per-instance `controls` for
    every matched node and slot-index-matched instance.
  - Tests: held-control survives swap (counter-confirmed via match
    count); untagged node defaults; tag clash rejected at compile
    time; runtime setter rejects duplicates and NUL-bearing keys while
    accepting opaque non-NUL bytes.
- **5.2.B — DSP state migration.** Done for the copy-safe v1 set.
  - Per-kind migrators for copy-safe state only: oscillator phase,
    pulse state, noise generator, and biquad filter memories.
  - Per-kind capability flag so adding a kind cannot accidentally
    enable migration of an unsafe state.
  - Tests: oscillator phase continues across swap; filter memory
    survives swap; unsupported Env/Delay/Smooth state reports skip
    rather than allocating or half-migrating.
- **5.2.C — Live-instance lifecycle survival.** Done.
  - Reuse the 5.2.A slot-index identity and add copying for
    slot state, `block_lifecycle_active`, `block_state_at_start`,
    `silent_blocks`, and `block_sink_peak` for slots where old and
    new agree on `(template_id, state ∈ {Active, Releasing})`.
  - Tests: Active slot copies are counter-confirmed; Releasing slots
    keep silence-window progress across install; missing new slots do
    not inherit old lifecycle state.
- **5.2.D — Optional, deferred:** structural-alignment fallback for
  untagged nodes. Only landed if a real workload demands it; v1 omits
  it on purpose.

## 10. What 5.2 deliberately does *not* do

- **No SuperCollider `/n_replace` semantics.** v1 swaps the whole
  template ensemble at once. Per-node replacement inside a running
  template is a different protocol.
- **No bus-content preservation across swap.** Caller pins bus index
  identity; bus storage starts fresh.
- **No template-id renumbering.** New world's `template_id` for a
  given semantic template must match old world's. Renaming /
  reordering templates is a separate identity problem.
- **No producer-side migration.** All migration runs on the audio
  thread at install. Producer's job is to publish a well-formed plan.
- **No lazy optional DSP-state migration in v1.** Env, Delay, and
  Smooth need either off-audio prewarming or custom no-allocation
  copy support before they can migrate.
- **No structural-alignment fallback.** Untagged nodes get
  default-init; they do not silently migrate by index match.
- **No multi-version coexistence.** Same as parent note §9.

## 11. Open questions

- **Q1.** Should the migration plan record `KeyNotFound` only, or
  also `KeyDiscarded` (old key in the old world that has no
  destination in the new)? The first is enough to debug producer
  intent; the second is useful for tooling. Lean: record both at the
  test surface, expose only "skipped count" through the public ABI.
- **Q2.** Does the bus-pool sizing change between worlds count as a
  publish precondition (rejects with mismatched bus count) or a
  caller responsibility (proceeds with new sizing, caller handles)?
  The parent note §7.3 leaves this open. Lean: caller responsibility
  in v1, runtime asserts only when migration would reach beyond the
  new world's bus count.
- **Q3.** Should `prepare_swap_from_graph` accept a separate
  `MigrationPolicy` enum (Strict, Permissive, Disabled) or always run
  the standard match predicate? Lean: always run; opt-out is
  per-node via not setting a tag.
- **Q4.** Should bus-content preservation (`output_buses_prev`) join
  the install copy for delayed feedback continuity? v1 deliberately
  leaves bus storage fresh after install; preserving it requires a
  bus-count reconciliation rule.
- **Q5.** Should Env, Delay, and Smooth gain prewarm/custom-copy
  migrators? v1 keeps their DSP state default-init because their
  current optional q payloads can allocate when engaged. A later slice
  can make them copy-safe by constructing the target payloads
  off-audio before publish.
