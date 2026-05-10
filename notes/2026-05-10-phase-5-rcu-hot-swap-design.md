# Phase 5 — RCU Hot-Swap Protocol

Date: 2026-05-10
Status: Phase 5.1.A/B, 5.2.A/B/C, 5.3.A/B/C, and 5.4.A/B implemented.
5.3.D (`rt_graph_wait_swap_installed`) is deferred — the 5.3.C bench
shows producer detection is microsecond-scale and not the bottleneck.
5.4.B turns template-id reorder into a publish failure rather than a
silent migration foot-gun.

This note pins the protocol for swapping a running MetaSonic graph
without a stop/start cycle. It records what the runtime did before the
swap substrate, what the target swap shape is, what crosses the
audio-thread boundary and what does not, and what state migration had
to commit to. Phase 5.1.A first stood up the publish / install / retire
dance with an empty payload; Phase 5.1.B moves the swappable runtime
world into `RTGraphState` and makes `RTGraphSwap` carry a real
next-world payload. Phase 5.2 adds caller-tagged state migration,
Phase 5.3.A/B/C wraps and measures the protocol for Haskell producers,
and Phase 5.4.B adds a template identity precondition.

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

The stop/rebuild path still does not migrate state. State migration is
provided by the hot-swap path described below; `rt_graph_clear` remains
a destructive reset.

## 2. Target: block-boundary swap

The goal is RCU-style: build a complete *next world* off-audio, hand it
to the runtime, have the audio thread atomically install it at the top
of the next `process_graph` block, and free the old world off-audio.
Audio never stops; the swap is heard as one block of discontinuity only
for state that the current migration policy deliberately leaves
default-initialized. Caller-tagged controls, copy-safe DSP state, and
slot lifecycle metadata are migrated by Phase 5.2.

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

## 4.1 Haskell producer helper landing

Phase 5.3.A/B wraps the C ownership protocol in
`MetaSonic.Bridge.FFI`:

- `hotSwapRuntimeGraph(target, capacity, maxFrames, rg)` and
  `hotSwapRuntimeGraphFused(target, capacity, maxFrames, rg)` build a
  temporary offline `RTGraph`, load the compiled `RuntimeGraph` into it,
  move its world into an `RTGraphSwap`, and publish that swap to the
  target.
- `hotSwapTemplateGraph` and `hotSwapTemplateGraphFused` do the same
  for `TemplateGraph`.
- `capacity` is the explicit builder pre-allocation hint passed to
  `withRTGraph`; the helper does not infer capacity from graph shape or
  node count. Producers should use the same sizing policy they used for
  the live target.
- The Haskell surface exports `BuilderCapacity`, `MaxFrames`,
  `TimeoutMs`, and `SwapGeneration` aliases to label adjacent integer
  roles. They document intent without changing the ABI; promote them to
  newtypes only if producer-side misuse becomes a real problem.
  `SwapGeneration` is a Haskell-side `Int`; the raw C counter remains
  `int`/`CInt` and is converted at the FFI wrapper boundary.
- If publish fails, the helper cancels the prepared swap before
  returning `False`. If publish succeeds, ownership moves to the C++
  runtime and the helper returns `True`.
- `collectRetiredSwapStats(target)` is the Haskell reap helper: it
  collects the installed retired swap if present, snapshots the Phase
  5.2 migration counters, disposes the old world off-audio, and returns
  `Nothing` when no retired swap is waiting.
- `waitForSwapGeneration(target, priorGeneration, timeoutMs)` polls the
  install-generation counter until it advances. Negative timeout waits
  indefinitely, zero performs one non-blocking poll, and positive values
  are milliseconds.
- `hotSwapRuntimeGraphAndWait`, fused/template siblings included, are
  the live-producer convenience path: capture the generation before
  publish, publish the prepared world, wait for install, collect stats,
  and return a result that distinguishes rejected publish from install
  timeout.
- The waited helpers are v1 single-producer/single-collector helpers.
  Their generation-before-publish check is attribution-safe only when no
  other producer can install a swap between the generation snapshot and
  this helper's publish.

The plain 5.3.A helpers intentionally do not wait for installation.
Offline tests drive one `rt_graph_process` block after publish;
realtime callers can either poll manually or use the 5.3.B waited
helpers so control producers know when it is safe to resume commands
against the new world.

### 4.2 Measurement landed: --swap-bench

5.3.C landed in two slices.

**5.3.C1 — scaffold.** `MetaSonic.App.SwapBench` plus a `--swap-bench`
mode on `metasonic-bridge`. One prepare+publish per row over a fixed
corpus: unchanged graph, tagged oscillator, tagged biquad,
lifecycle-only graph (Env + release → Releasing slot), fused graph,
two-template ensemble. Output is CSV-shaped with one row per case;
columns include prepare/publish time, install block count, collect
time, and the Phase 5.2 migration counters. No C++ change, no library
API change.

**5.3.C2 — repetition + counter assertion.** Each row now runs
`kSwapBenchRepeats = 11` times in a fresh `withRTGraph` handle so prior
runs cannot leak lifecycle state or pending swaps into a later run.
Timing is reported as min / median / max in nanoseconds; counters and
`blocks_to_install` are required to be **identical** across runs and to
match the row's expected signature. The bench aborts loudly on drift or
stable wrong counters, because counters remain the primary path-proof
signal — the timing summary is descriptive, the counters are the
contract.

**Observed envelope** (3 invocations × 11 repeats per row, host varies).
The medians are stable across consecutive bench invocations; the spread
between min and max is mostly first-iteration warm-up, not contention.

| row | committed / skipped / inst / state / lifecycle | prepare+publish median | collect median |
|---|---|---|---|
| `unchanged`        | 0 / 2 / 0 / 0 / 1 | ~4.9 µs | ~330 ns |
| `tagged-osc`       | 1 / 1 / 1 / 1 / 1 | ~4.7 µs | ~330 ns |
| `tagged-biquad`    | 1 / 2 / 1 / 1 / 1 | ~5.4 µs | ~380 ns |
| `lifecycle-only`   | 0 / 2 / 0 / 0 / 1 | ~4.6 µs | ~370 ns |
| `fused`            | 1 / 1 / 1 / 1 / 1 | ~4.9 µs | ~340 ns |
| `template` (×2)    | 0 / 4 / 0 / 0 / 2 | ~8.5 µs | ~490 ns |

`blocks_to_install` is `1` in every row, every run (66 measurements per
invocation). Install is reliably synchronous on the next process call
under the offline driver.

The producer cost is dominated by graph load into the offline builder
(`hotSwap*` walks `rgNodes` and emits one FFI call per node, plus the
controls and the migration-key setter). Migration counters do not
materially change the median timing — `tagged-biquad` is the most
expensive single-template row only because it has one extra node.
Collect-side cost is sub-microsecond for every row; six FFI reads plus
one cancel.

**Decision: still defer `rt_graph_wait_swap_installed`.** The bench
makes two things visible:

1. The producer-side cost is microseconds, not milliseconds. There is
   no measurement gap a C-side blocking wait would close.
2. `blocks_to_install` is 1 in every row under the offline driver. In a
   realtime producer, a C-side wait could at most reduce producer
   notification granularity; it would not make the audio thread install
   before a block boundary. No current measurement shows that the 1 ms
   `threadDelay` in `waitForSwapGeneration` is the limiting factor.

A C-side wait may still be justified later if either (a) producers
under heavy load report measurable polling jitter, or (b) realtime
callers need a `wait_swap_installed_or_timeout` primitive that integrates
with their existing control-thread synchronization. Neither has been
demonstrated yet. The next Phase 5 work that *might* prompt it is
producer-side bus identity / template renumbering — questions about
*what* the producer wants to do after install, not about *whether* the
producer can tell that install happened.

### 4.3 Phase 5.4.B template identity precondition

State and lifecycle migration in Phase 5.2 are keyed by `template_id`.
That works as long as `defs[template_id]` refers to the same semantic
template across old and new worlds. If a producer accidentally reorders
templates in the new world — say `[("a", g1), ("b", g2)]` becomes
`[("b", g2), ("a", g1)]` — the runtime would happily migrate template
0's live state into the new world's `template_id = 0`, which now
belongs to a different semantic template. The structural shape would
match (same node count, same kinds, same arities for many corpora), so
the migration plan would commit and the audible result would be a
state cross-talk that's hard to debug.

5.4.B turns this into a publish failure:

- `MetaDef::identity` is a fixed 16-byte token, same shape as the
  Phase 5.2 node migration key. It is set off-audio via
  `rt_graph_template_set_identity(g, template_id, key, key_len)` on
  the construction path and is reset by `reset_to_default_state` along
  with the rest of the template metadata.
- `rt_graph_prepare_swap_from_graph` adds a precondition: walk
  `target->active->instances`, and for every Active or Releasing slot,
  if both old and new `defs[slot.template_id]` carry an identity, the
  tokens must match. On any mismatch the function returns `nullptr`
  before allocating a swap or building a migration plan.
- Empty identities on either side are treated as opt-out. Single-
  template legacy callers that never set an identity, and producers
  who haven't adopted 5.4.B yet, see the previous behavior — the
  precondition is graceful so adoption can be incremental.
- Templates without a live slot are not checked. A renumber that
  happens before any voice is active is not observable through
  migration anyway, and rejecting on a dormant pool would block legal
  rebuilds.

Haskell side: `loadTemplateGraph` and `loadTemplateGraphFused` ship
`tplName` through the new ABI as the per-template identity. Names that
exceed 16 UTF-8 bytes or contain NUL fail during the pre-clear
validation gate with a clear diagnostic; that is a load contract, not
a runtime contract, so the error is surfaced as a Haskell `IOError`
rather than a silent untagged template that publishes anyway. Because
validation happens before `c_rt_graph_clear`, a bad next graph does
not erase the currently loaded graph.

The single-template `loadRuntimeGraph[Fused]` path deliberately does
not set an identity. v1 keeps single-template flows permissive: the
flat graph has only `template_id 0` and the rejection rule has nothing
to reject against. If a future caller wants identity for the flat
path, the same setter applies — the runtime treats template 0
uniformly.

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

The producer-side wait is currently a poll on the install-generation
counter. A future `rt_graph_wait_swap_installed` could block on a
condition variable populated by the audio thread, but that is deferred
until 5.3.C measurement proves the polling helper is inadequate.

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
- **5.2.A/B/C — State migration policy.** Caller-supplied migration
  tags are implemented for control and copy-safe DSP state; slot-index
  lifecycle migration preserves live instance state where old and new
  worlds agree.
- **5.3.A/B — Producer ergonomics.** Haskell hot-swap helpers build
  offline worlds, publish them, optionally wait by polling the install
  generation, and collect migration stats.
- **5.3.C — Swap-bench instrumentation.** Done. Measured prepare,
  publish-to-install, collect, and migration-counter behavior before
  adding any C-side blocking wait primitive.
- **5.3.D — Optional wait primitive.** Deferred. Only add
  `rt_graph_wait_swap_installed` if 5.3.C data or a real producer shows
  polling is insufficient.
- **5.4.A — Producer identity after install.** Done as
  [notes/2026-05-10-phase-5-4-producer-identity-after-install-design.md](2026-05-10-phase-5-4-producer-identity-after-install-design.md).
  Node retargeting remains producer-owned, bus identity remains numeric
  and caller-owned, and template identity is selected as the runtime
  precondition gap.
- **5.4.B — Template identity precondition.** Next proposed runtime
  slice. Store per-template identity tokens and reject prepare when
  live old slots would migrate across mismatched template tokens.

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
  installed"? (Current helper: poll the install-generation counter.
  5.3.C measured the helper path and did not justify a C-side
  `rt_graph_wait_swap_installed` primitive. Keep deferred until a real
  producer shows polling is insufficient.)
- **Q5.** Does the swap need to preserve the realtime control queue
  contents across publish? (Substrate: yes, by ordering — drain runs
  before install. The queue ring is graph-handle-owned and outlives
  the world.)
