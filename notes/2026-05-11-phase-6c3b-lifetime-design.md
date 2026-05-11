# Phase 6.C.3b — Buffer Lifetime Hardening (Design)

Date: 2026-05-11
Status: shipped (commits 6dbe75c slice 1; slice 2 in the
follow-up commit on this branch). The contract that landed
matches this note; Q-1..Q-5 resolutions are inlined in
section 5 below.

This note follows
[Phase 6.C.1 buffer I/O bounds](2026-05-10-phase-6c-buffer-io-design.md)
and [Phase 6.C.2 buffer I/O contract](2026-05-10-phase-6c2-buffer-io-contract.md),
both of which are now functionally complete on the read path
(6.C.3a shipped in commits c93dfa0 / 427c697 / 5592e69).
6.C.3b is the resource-lifetime hardening step that
6.D / 6.E / write kinds will all rely on; it is *not* a feature
phase.

## 1. What 6.C.3b is and is not

In scope:

- **Buffer ownership relocation.** Move the buffer pool + its
  two counters out of `RTGraphState` (the swappable inside-world)
  and onto the stable `RTGraph` handle, alongside `audio`,
  `control_queue`, `worker_pool`, `sample_rate`, `max_frames`,
  and `capacity` (see the §5.1.A/B world-boundary table in
  [the Phase 5 RCU note](2026-05-10-phase-5-rcu-hot-swap-design.md)).
- **Live-safe retire / collect.** A new
  `rt_graph_buffer_retire` + `rt_graph_buffer_collect_retired`
  pair that lets the producer remove a buffer while audio is
  running, modelled on the §5.3 generation-counter pattern
  already used for `RTGraphSwap`.
- **Tests.** A hot-swap survival test (slice 1) and a
  retire-mid-render → render → collect → realloc test (slice 2).

Out of scope (do **not** open these in 6.C.3b):

- `BufWrite` UGen kinds. The audio-thread write path is a
  separate design pass — it introduces a producer-vs-audio
  ownership inversion (the audio thread becomes a writer) that
  the read-only pool was deliberately avoiding.
- File I/O / async load. The current resident-table model is
  enough for 6.D and most of 6.E.
- Multichannel buffers. Mono is enough to make the lifetime
  contract work; channel-count is an orthogonal axis.
- Plugin hosting (6.E) and spectral processing (6.D). 6.C.3b
  lands first because both will lean on the lifetime contract.

After 6.C.3b lands the right question is "does 6.C need write
kinds, or is 6.D spectral the higher-signal next path?" —
answer that **after**, not now.

## 2. The ownership decision

The key call is: **where does the buffer pool live?**

The 6.C.3a v1 placed it on `RTGraphState` (the world body).
That was fine for v1 because the pool was construction-only
and `c_rt_graph_clear` legitimately wiped it. It is wrong for
6.C.3b because:

- A `rt_graph_prepare_swap_from_graph` + `rt_graph_publish_swap`
  cycle moves the old `RTGraphState` into the retire slot and
  installs a fresh one. The buffer pool on the old state is
  retired with it — meaning every buffer ID a producer
  allocated before the swap is implicitly invalidated by the
  swap. That violates the user-visible promise that buffers
  outlive graph replacement.
- The retire/collect pattern in §5.3 retires *graph state*
  (templates, instances, bus pool, schedule scratch). Adding
  a second, separately-retired buffer pool inside that state
  makes the retire surface non-uniform: the producer would
  have to reason about two distinct generation counters
  whose lifetimes interleave.

The proposal: **move the buffer pool to the stable `RTGraph`
handle.** Concretely, the eight or so lines on `RTGraphState`
(`std::array<BufferSlot, kMaxBuffers> buffers`,
`long long buffer_read_count`, `long long
buffer_invalid_read_count`, plus their accessors) move out
to `RTGraph`. The kernel reaches them through
`g.buffers[...]` instead of `world(g).buffers[...]`.

Consequences:

- `c_rt_graph_clear` no longer wipes the buffer pool.
  Producers that depended on that behavior (one test does,
  via the "alloc-after-loadTemplateGraph" idiom) get updated
  to alloc before the first `loadTemplateGraph`, or to
  explicitly `clearBuffer` what they need cleared. This is a
  behavior change worth a roadmap entry.
- Counters become RTGraph-lifetime, not RTGraphState-lifetime.
  The "ticks per kernel-per-sample" semantics are unchanged;
  only the reset cadence changes (handle-lifetime instead of
  state-lifetime).
- The §5.3 retire/collect protocol for buffers becomes a
  completely separate generation counter from the one for
  `RTGraphSwap`. That is correct: they retire different
  resources at different cadences, and tangling them would
  couple buffer churn to graph churn.

Alternatives considered and rejected:

- *Migrate the buffer pool across a swap.* That requires the
  swap-prepare path to know about buffers, which couples a
  topology operation to a resource operation. Not worth the
  complexity for an "always survives" promise.
- *Make buffer IDs swap-scoped.* That breaks
  `loadTemplateGraph`'s idempotent re-load model — the same
  graph re-loaded in a new world would refer to stale IDs.
- *Leave the pool on state, gate retire on swap.* Mixes
  lifetime axes; the buffer pool becomes harder to reason
  about than either ownership extreme.

## 3. Retire semantics — pinned narrowly

The §5.3 generation-counter pattern hands us the skeleton.
For buffers specifically:

- `rt_graph_buffer_retire(g, buffer_id) -> int`: flips the
  slot from `Allocated` to `Retired`. From the next block
  onward, every PlayBufMono kernel that resolved this slot
  at its own instance-reset time takes the invalid-read
  path (emit zero, tick `buffer_invalid_read_count`). Returns
  0 on success, -1 if the slot is out of range / not
  currently allocated. Callable while audio is running —
  this is the whole point of the new entry point.
- `rt_graph_buffer_collect_retired(g, buffer_id) -> int`:
  off-audio reap. Returns 0 if the slot is now genuinely
  reusable (a process_graph block has run since the retire,
  so any audio-thread pointer the kernel cached has been
  released), -1 if the slot is not retired, and a sentinel
  (`-2`?) if the audio thread might still hold a reference.
  The producer is contractually required to call this before
  reusing the slot.

Critically:

- A retired slot's `samples` vector **must not be resized
  or freed by `retire` itself.** The audio thread may still
  be inside a `process_graph` call that captured
  `slot->samples.data()` at the top of the block; the
  pointer must remain valid until the next block-end. Only
  `collect` may resize / free.
- A retired slot is **not reusable for a new `allocBuffer`
  until collect succeeds.** `allocBuffer` skips slots in
  state `Allocated | Retired`; it only picks `Unallocated`.
- `clearBuffer` stays **stopped-audio-only.** It is the
  "I know audio is not running, just reset" fast path and
  remains in the wrapper for symmetry; its docstring gets
  tightened to point at `retireBuffer` for the live case.

This gives three slot states (`Unallocated`, `Allocated`,
`Retired`) — currently it's a single `allocated` bool.
That's the only state-machine change; everything else is
ABI-shape.

Why "tick `buffer_invalid_read_count` on retired reads": it
keeps the existing counter-confirmed validation pattern
(see [feedback_counter_confirmed_validation.md]) intact. A
retired buffer's silence is the same observable as an
unallocated one — which is exactly what the producer wants
to see post-retire.

## 4. Implementation slicing

Two commits, in order, with the survival test gating slice 1.

### Slice 1: ownership relocation, no semantic change

- Move the `buffers` array + two counters from `RTGraphState`
  to `RTGraph`.
- Update `world(g).buffers` → `g.buffers` at every kernel
  / ABI site. The Haskell FFI wrappers do not change.
- Drop the buffer-pool wipe from `c_rt_graph_clear`. Add a
  test that confirms the pool survives `c_rt_graph_clear`.
- Update the existing "alloc-after-loadTemplateGraph"
  comment in test/Spec.hs (the idiom is now unnecessary;
  alloc-before-load also works).
- **Hot-swap survival test.** Build a one-template graph
  referencing `Buffer 0` with a constant fill; allocate the
  buffer; load + render one block, assert the constant.
  Run `prepare_swap_from_graph` + `publish_swap` against a
  second offline graph that *also* references `Buffer 0`;
  render one block after the install, assert the constant
  *still*. Counter-confirm: `buffer_read_count` ticks across
  the swap.

Slice 1 ships with zero new producer-visible APIs. It is
pure structural rework + one test.

### Slice 2: live-safe retire / collect

- Add the `Retired` state to the slot.
- Add `rt_graph_buffer_retire` + `rt_graph_buffer_collect_retired`
  to the C ABI; matching `c_rt_graph_buffer_*` foreign imports
  in [Bridge/FFI.hs](../src/MetaSonic/Bridge/FFI.hs); matching
  `retireBuffer` / `collectRetiredBuffers` in
  [Bridge/Buffer.hs](../src/MetaSonic/Bridge/Buffer.hs).
- Add an `RTGraphState`-style generation counter for buffer
  retires so `collect` can prove "a block has run since the
  retire." Simplest viable shape: a single
  `buffer_retire_generation` atomic on `RTGraph`,
  incremented by the audio thread at the top of every
  `process_graph` call, snapshotted by `retire`, and
  re-checked by `collect`. The slot itself carries the
  snapshot.
- Tighten `clearBuffer`'s docstring to point at `retireBuffer`
  for the live case.
- **Retire-mid-render test.** Allocate two buffers with
  distinguishable fills. Build a graph referencing `Buffer 0`.
  Render block 1 → assert the fill. Call `retireBuffer 0`.
  Render block 2 → assert zeros + invalid-read counter
  ticks. Call `collectRetiredBuffers` → confirm `Buffer 0`
  is now reusable. Re-`allocBuffer` → confirm we get ID 0
  back with a fresh empty fill. Counter-confirm read /
  invalid totals.

Slice 2 ships two new entry points and one new error
constructor (`BiCollectStillLive` or similar — to be
pinned in the 6.C.3b.contract note).

## 5. Q-1..Q-5 resolutions (settled during 6.C.3b slice 2)

Q-1. **One-deep vs. queue-deep retire slot.** Settled:
   per-slot generation, no queue. A producer that retires
   three buffers in a row stamps three separate snapshots,
   one per slot, and must `collectRetiredBuffer` each id
   individually. A bulk `collectAllRetiredBuffers` helper
   was not added — only one v1 consumer (the test suite)
   exercises retire, and a list-fold inside the producer is
   cheap. Add the bulk helper if/when a real consumer asks.

Q-2. **`collect` blocking vs. non-blocking.** Settled:
   non-blocking. `collectRetiredBuffer` returns
   `BiCollectStillLive` if the audio thread has not crossed
   a block boundary since retire; the producer retries
   after driving one more `c_rt_graph_process`. The
   `collectRetiredSwapStats`-style blocking helper was not
   added — tests are clean enough with explicit
   render-and-retry, and a generic "wait for one block" is
   producer-side trivia.

Q-3. **Pattern / OSC coupling.** Settled: still deferred.
   No `PEBufferRetire` `PatternEvent` constructor, no
   `/buffer/retire` reserved OSC path. Same rationale as
   6.C.2's deferral on load/free: a separate concern that
   needs its own reserved-words discussion.

Q-4. **Does `clearBuffer` go away once `retireBuffer`
   exists?** Settled: **kept**, documented as the
   stopped-audio fast path. `clearBuffer` now refuses to
   touch a `Retired` slot (mapped to `BiUnknownBufferId` —
   the C ABI conflates "not Allocated" cases for the
   stopped-audio path) so the two APIs do not silently
   interfere.

Q-5. **Retire generation counter on the Haskell side.**
   Settled: hidden inside the wrapper. `collectRetiredBuffer`
   returns `IO ()` and throws `BiCollectStillLive` on the
   not-yet-safe case; no `BufferRetireGeneration` newtype
   was added to the public surface. The C-side counter is
   only observable through `BiCollectStillLive`'s
   wait-and-retry semantics, which matches the v1 goal of
   keeping the API minimal.

## 6. What 6.C.3b will NOT include

Recap, since it's the easiest part of a design pass to drift
on:

- No `BufWrite`, no audio-thread write path.
- No file I/O, no async load, no `loadBufferFromFile`.
- No multichannel, no stereo helpers.
- No template-precedence extension for `BufRead` (still bus-only,
  same as 6.C.1 settled).
- No pattern / OSC coupling for retire.
- No reverse playback, no negative-rate kernel work.

These all stay deferred. After 6.C.3b lands the v1 buffer story
is done; the next decision is 6.C.4 (writes) vs. 6.D (spectral).
