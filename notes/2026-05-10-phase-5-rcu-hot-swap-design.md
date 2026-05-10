# Phase 5 — RCU Hot-Swap Protocol

Date: 2026-05-10
Status: Phase 5.1.A/B implemented. State migration explicitly deferred.

This note pins the protocol for swapping a running MetaSonic graph
without a stop/start cycle. It records what the runtime does today,
what the target swap shape is, what crosses the audio-thread boundary
and what does not, and what state migration would have to commit to —
*after* the substrate is pinned. Phase 5.1.A first stood up the
publish / install / retire dance with an empty payload; Phase 5.1.B
moves the swappable runtime world into `RTGraphState` and makes
`RTGraphSwap` carry a real next-world payload.

## 1. Today: stop / rebuild semantics

The canonical "swap to a different graph" path is `rt_graph_clear`:

```cpp
void rt_graph_clear(RTGraph *g) {
  if (!g) return;
  stop_audio_stream(*g);    // joins the audio thread
  reset_to_default_state(*g);
}
```

`reset_to_default_state` clears every field that participates in
rendering — `defs`, `instances`, `server.output_buses`,
`contribution_storage`, all schedule snapshots, all per-block counters,
the realtime control queue indices — and reinstates a fresh template 0
+ instance 0. The handle survives; everything inside it is reset.

Concrete consequences:

- Audio is **stopped** for the whole rebuild — no fades, no audible
  continuity, just silence and a click on restart.
- The construction ABI (`rt_graph_template_*`, `rt_graph_*_set_default`,
  `rt_graph_template_connect`, `rt_graph_template_add_region`,
  `rt_graph_template_add_schedule_step`) is `[T:construction]` — safe
  *only* between `rt_graph_stop_audio` and the next `rt_graph_start_audio`.
  The audio thread cannot be running while these mutate the world the
  callback iterates.
- Per `Note [Thread safety contract]`, this is enforced by convention:
  callers obey it; tests run offline; the realtime control queue
  (Phase A.2) is the *only* sanctioned mutation path while audio is live.

State migration today is whatever the caller does explicitly: read
controls / phases out of the old graph before clear, write them into
the new one after. The runtime does not help.

## 2. Target: block-boundary swap

The goal is RCU-style: build a complete *next world* off-audio, hand it
to the runtime, have the audio thread atomically install it at the top
of the next `process_graph` block, and free the old world off-audio.
Audio never stops; the swap is heard as one block of state-reset
discontinuity at most (envelopes restart, oscillator phases reset,
filter memory zeros), and zero discontinuity once state migration lands.

Three timing constraints together pin the protocol:

1. **The install point is the top of `process_graph`.** Specifically,
   the audio thread first acquires any pending swap, then drains
   `control_queue`, then installs the acquired swap *between*
   `drain_control_queue` and `std::swap(server.output_buses,
   server.output_buses_prev)`. Acquiring the pending swap before the
   drain orders every queue write the producer made before
   `rt_graph_publish_swap`; those commands are applied against the old
   world before it retires. The bus ping-pong then runs against
   whichever world is now active.
2. **The audio thread does no allocation, no thread join, no
   destructor-running-during-block work.** The substrate uses fixed
   atomic pointer handoff slots; the producer reaps the old world.
3. **The producer never touches the live world.** It builds the next
   world in isolation off-audio and publishes a single pointer; the
   audio thread is the sole writer of the "active world" slot during
   `process_graph`.

## 3. World boundary — what swaps, what stays

| Field | Class | Swaps with the world? |
|------|------|------|
| `defs` (templates) | per-graph topology | yes |
| `instances` | per-graph voice pool | yes (initially: blank pool) |
| `server.output_buses` / `_prev` | per-graph bus pool sized by `defs` | yes |
| `contribution_storage` | sized from `defs` × polyphony | yes |
| `global_schedule_*`, `region_layer_work_items`, `global_schedule_bands` | per-world scratch rebuilt from `defs` × `instances` | yes, as pre-reserved scratch/capacity inside the world; contents are rebuilt by the next `process_graph` and not migrated |
| Per-block counters (`last_*`) | observation snapshots | reset on install; not migrated |
| `audio` (q_io stream) | thread / device handle | **stays** — keyed off the RTGraph handle |
| `control_queue` | SPSC ring between threads | **stays** — see §5 |
| `worker_pool` | thread pool resource | **stays** — pool size is a runtime decision, not a graph property |
| `sample_rate`, `max_frames` | block-shape invariants | **stay** — see §6 |
| `capacity` | initial reservation hint | **stays** |

Inside-the-world fields are what the off-audio prepare path populates;
outside-the-world fields belong to the RTGraph handle and outlive any
single graph.

## 4. Phase 5.1.A/B landing

The landed implementation has two layers:

- **5.1.A:** `RTGraphSwap` plus the publish / install / retire protocol
  with generation and pending/retired test counters.
- **5.1.B:** the swappable subset of `RTGraph` lives in
  `RTGraphState`, `RTGraph` holds `std::unique_ptr<RTGraphState>
  active`, and `RTGraphSwap` carries a prepared `RTGraphState`.
  Install moves the old active state into the collected swap's
  `retired_state` and moves the prepared state into `active`.

The producer can build a future world by constructing a separate
offline `RTGraph` with the existing construction ABI, then calling
`rt_graph_prepare_swap_from_graph(target, builder)` to move that
builder's world into the swap. This avoids cloning DSP state and avoids
duplicating every construction call for `RTGraphSwap`. The builder is
reset to the default empty world after the move.

What the substrate provides:

- `rt_graph_prepare_swap(g) -> RTGraphSwap *`: allocates a default
  empty next-world swap off-audio. Returns null if `g` is null.
- `rt_graph_prepare_swap_from_graph(target, builder) -> RTGraphSwap *`:
  moves `builder`'s swappable world into a swap for `target`. Requires
  distinct non-null handles with the same `max_frames` and no swap in
  flight on the builder.
- `rt_graph_cancel_swap(g, swap)`: frees an unpublished swap off-audio.
- `rt_graph_publish_swap(g, swap) -> int`: atomic CAS into a single
  pending slot. Returns 1 on success, 0 if a swap is already pending or
  retired-but-not-collected, or args are null. The audio thread acquires
  the pending swap at the top of the next `process_graph` block.
- `rt_graph_collect_retired_swap(g) -> RTGraphSwap *`: off-audio reap
  point. Returns a swap the audio thread has consumed, or null. The
  producer is contractually required to collect and dispose the retired
  swap after each publish; a new publish is rejected until collection.
- `rt_graph_test_swap_generation(g) -> int`: atomic number of installs
  the audio thread has performed. Pinned by tests and usable by the
  producer as a pollable "installed" signal.

## 5. Realtime control queue across a swap

The control queue ([Note [A.2: realtime control queue]]) carries
mutation commands targeted at instance slots / template ids in the
*currently active* world. A swap may invalidate those targets.

The substrate is conservative: `process_graph` acquires a pending swap
**before** draining `control_queue`, but installs that swap **after**
the drain. The acquire on `pending_swap` synchronizes with
`rt_graph_publish_swap`, so any commands the producer enqueued before
calling publish are visible to the queue drain and are applied to the
old world before it retires. Commands the producer enqueues *after*
publish should not target the old world's slots — those slots may not
exist (or may be at different indices) in the new world.

> Publish a swap → wait until `swap_generation` advances → resume
> enqueuing realtime commands against the new world.

The producer-side wait can be a poll on the test counter, or a future
`rt_graph_wait_swap_installed` that blocks on a condition variable
populated by the audio thread. v1 leaves this to the caller.

## 6. Audio-thread allocation invariants

The substrate preserves every existing allocation-free property:

- **`process_graph` allocates nothing.** The install path is one
  atomic exchange to acquire `pending_swap`, two `unique_ptr` moves,
  one atomic store to publish `retired_swap`, and one atomic generation
  increment. No vector growth, no `new`, no thread join, no destructor.
- **The retired-swap slot is one-deep.** Audio thread atomically
  stores into it after install. `rt_graph_publish_swap` holds a
  `swap_in_flight` guard from publish until collection, so a second
  publish is rejected while any previous swap is pending, installing,
  or retired-but-not-collected. A retired world is therefore never
  overwritten on the audio thread.
- **Pending-swap acquire orders the world payload.** The producer's
  release-store on `rt_graph_publish_swap` synchronizes-with the
  audio-thread's acquire-load before the queue drain, so any prep work
  the producer did to populate the swap is visible to the audio thread
  *as if* it had been done by the audio thread itself. Because the
  acquire happens before `drain_control_queue`, pre-publish queue writes
  are ordered into that drain as well. This is the same pattern the
  realtime control queue already uses.
- **No growth of the active world from the audio thread.** Per-block
  rebuilds (`build_global_schedule`, `build_region_layer_work_items`,
  `build_global_schedule_bands`) only `clear() + push_back` into
  pre-reserved space sized by off-audio capacity helpers. In 5.1.B
  those vectors move into the swappable `RTGraphState` as capacity-
  bearing scratch; the *new* world's capacity helpers must have already
  run off-audio before the audio thread sees the swap.
- **Sample rate / max_frames immutable.** Changing either would force
  reallocation of pre-sized buffers (output_buses, fused scratch,
  contribution_storage samples). The substrate forbids it; later slices
  enforce it as a publish precondition.

## 7. State migration — open, deferred

The substrate explicitly does not migrate state across a swap. Once the
protocol is pinned, migration policy is a separate decision with three
sub-questions:

### 7.1 Identity

To migrate per-node state (oscillator phase, filter memory, envelope
position, delay buffer contents), the runtime needs a stable identity
that survives recompilation. Today every `NodeIndex` is a dense
per-template ordinal that changes whenever the template's node list
changes; `(template_id, NodeIndex)` is *not* stable across rebuilds
unless the user takes care to keep them aligned.

Options:

- **(a) Caller-supplied identity tags.** The Haskell side annotates
  each `NodeIR` with a `MigrationKey` (a string or symbolic tag); the
  C++ side migrates state from old slot → new slot when keys match.
- **(b) Structural alignment.** If `(template_id, NodeIndex, NodeKind)`
  matches between old and new for slot *i*, migrate. Simpler, but
  brittle under any topology edit.
- **(c) Explicit caller migration callback.** Hot-swap calls a producer
  callback before retiring the old world; the callback reads what it
  wants out of the old state and pushes into the new one via
  `rt_graph_template_set_default` / future state-injection ABI.

(a) is the SuperCollider-style answer (NodeID-as-handle), (b) is the
auto-magic answer, (c) is the "do it yourself" answer. The substrate
takes no position; the migration slice picks one.

### 7.2 Live instances across the swap

If the old world has live instances (a held MIDI note, a sustaining
envelope), the migration slice has to decide:

- Are live instances released at swap (envelope cuts, audible click)?
- Are live instances re-instantiated in the new world by `template_id`
  match (assumes templates are aligned by ID)?
- Are live instances released-then-reactivated by some user-supplied
  policy?

The substrate makes no live instances survive — the new world starts
with whatever instance pool the producer populated. v2's migration
slice is where this lives.

### 7.3 Bus pool sizing

The new world's bus pool is sized by its `defs`. If the new pool has
fewer buses than the old, in-flight bus reads from a delayed feedback
loop see zeros for one block. If more, the new buses start at zero.
Both are acceptable; the design just needs to commit to "bus indices
are stable across a swap" (caller responsibility) so feedback delay
loops don't shift content.

## 8. Phased plan

- **5.1.A — Swap protocol substrate.** `RTGraphSwap` with
  empty payload, four ABI entries, `swap_generation` test counter,
  block-boundary install, off-audio retire/reap. Tests pin the dance.
  No DSP behavior change.
- **5.1.B — World payload migration.** Move the swappable subset of
  `RTGraph` into a `RTGraphState` struct that lives behind a `unique_ptr`
  inside `RTGraph`. This includes the schedule scratch vectors
  (`global_schedule`, `region_layer_work_items`, `global_schedule_bands`)
  as pre-reserved world-local capacity, even though their contents are
  rebuilt each block and never migrated. Rewrite the audio path to read
  through `g.active->...`. `RTGraphSwap` carries an `RTGraphState`.
  A publish actually replaces the world; tests prove byte-equivalence
  with a separately rebuilt graph.
- **5.2 — State migration policy.** Pick one of §7.1 (a)/(b)/(c), wire
  it into the install path, define live-instance survival, lift bus-pool
  stability into a publish precondition.
- **5.3 — Producer ergonomics.** `rt_graph_wait_swap_installed`,
  `--swap-bench` for measuring publish-to-install latency,
  Haskell-side `loadRuntimeGraphSwap` that reuses `RTGraphState`-shaped
  capacity.

## 9. What this design is *not*

- It is **not** a runtime parallelism story. Phase 4.E is frozen; the
  swap protocol does not depend on or revive worker dispatch.
- It is **not** a SynthDef-replacement-on-Node story. SuperCollider's
  Node-level swap (`/n_replace`) is finer-grained than what's
  described here; it requires per-node identity and per-instance
  preservation that 5.2 has to solve before this gets there.
- It is **not** a multi-version coexistence story. The substrate
  installs the new world atomically; the old one retires. Running two
  graph versions simultaneously is out of scope.

## 10. Open questions tracked here, decided later

- **Q1.** Should `worker_pool` size travel with the swap? (Today: no,
  it's a handle property. If a future graph wants more workers, that's
  a separate `rt_graph_test_set_worker_pool_size` call.)
- **Q2.** Should `sample_rate` be allowed to change at swap time? (Today:
  no, the substrate forbids it. Allowing it would require resampling
  the in-flight live audio block and reallocating every per-frame
  buffer. Probably never worth it.)
- **Q3.** Should publish-while-pending queue or fail? (Substrate: fail.
  The producer can poll until pending clears, then republish. A bounded
  queue can be added later if a use case demands it.)
- **Q4.** What's the producer-side blocking primitive for "wait until
  installed"? (Substrate: poll the atomic test counter. Future
  ergonomics slice picks a real primitive.)
- **Q5.** Does the swap need to preserve the realtime control queue
  contents across publish? (Substrate: yes, by ordering — drain runs
  before install. The queue ring is graph-handle-owned and outlives
  the world.)
