# Phase 6.C — Buffer I/O Design Pass (bounds note)

Date: 2026-05-10
Status: design only; bounds 6.C before any contract or
implementation lands. v2 — revised after review.

This note plays the same role for 6.C that
[Phase 6.A pattern design](2026-05-10-phase-6a-pattern-design.md)
and [Phase 6.B OSC design](2026-05-10-phase-6b-osc-design.md)
played for their sub-phases: it fences the work and pins the
load-bearing decisions before any contract or code lands. The
ROADMAP explicitly flags 6.C as a "design pass" — this is that
pass's first instalment.

## Position in the roadmap

Phase 6.C is the third active sub-phase of the rewritten
[Phase 6](../ROADMAP.md). 6.A (patterns) and 6.B (OSC) are
structurally complete; 6.C introduces the first *resource*
beyond the bus pool — sample memory that is sharable across
templates and survives hot-swap.

The 6.A.1 producer-vs-runtime boundary still applies: buffer
**allocation, load, and free** are producer-side concerns (off
the audio thread); the audio thread only reads (and, later,
writes) already-resident samples. No new realtime ABI is
required for *reading* a resident buffer — that follows the
existing kernel pattern.

The project's load-bearing pattern continues: "descriptive
measurement first, runtime change later." 6.C.1 (this note) is
the bounds pass; 6.C.2 will be the contract; 6.C.3 will be the
minimal implementation, split into two slices (read first,
live-safe free second). No code lands until 6.C.2 is reviewed.

Coupling to 6.E is **explicit and bidirectional**: most plugin
formats want sample-buffer access, so the 6.C contract must
leave room for an external consumer that does not own the
buffer. The ROADMAP notes that 6.E may force a 6.C revision —
6.C.2 should therefore commit only to what 6.E cannot
plausibly displace.

## What 6.C is

A first-class **Buffer** resource: a producer-allocated,
audio-thread-visible chunk of float samples with a stable
integer identity that outlives any single graph load. The
audio-side surface in v1 is **read-only sample access** — a
new `NodeKind` analogous to SuperCollider's `PlayBuf` that
consumes a buffer ID (plus a small set of controls) and emits
a sample-rate audio edge.

Producer-side, v1 supports:

1. **Allocate** an empty buffer of a given frame count,
   returning a stable integer ID.
2. **Load samples in** from a Haskell-owned `Vector Float` (or
   equivalent contiguous byte source). File I/O — decoding
   WAV / AIFF / FLAC — is a separate later sub-phase, because
   it imports an external library's lifecycle and error
   vocabulary the project does not have yet.
3. **Clear / free** a buffer. v1 splits this in two: a
   construction-time / stopped-audio clear (cheap) lands in
   6.C.3a; live-safe retire/collect that the audio thread can
   tolerate lands in 6.C.3b. The §5.3 retire pattern is the
   model for the live-safe path.

That is the entire v1 surface. Every other capability —
recording, live overdub, multichannel interleave, multiple
sample formats, async file load, plugin sharing — is a later
sub-phase.

## What 6.C is **not**

- **Not a runtime allocator.** Audio-thread code does not call
  any allocation primitive. The audio thread reads a pointer
  + length pair the producer published before the block
  started.
- **Not a file I/O subsystem.** 6.C.3 ships with in-memory
  load only; the WAV / AIFF / FLAC pass is its own
  sub-phase, gated on whether 6.E's plugin format actually
  needs the same loader (avoid building two).
- **Not a write surface.** v1 audio-side kinds are read-only.
  Live recording (`RecordBuf` / `BufWr`) introduces
  reader-writer race questions, sample-accuracy questions
  about when the write completes, producer-side coordination
  questions, AND a precedence-extension question (see
  decision 6 below); defer until the read path is solid.
- **Not a delay-line replacement.** `KDelay` already owns a
  per-node `q::delay` ring buffer (see
  [src/MetaSonic/Bridge/Source.hs:861-882](../src/MetaSonic/Bridge/Source.hs)
  and the kernel in
  [tinysynth/rt_graph.cpp:4099-4180](../tinysynth/rt_graph.cpp)).
  That stays as is. Buffers are *shared* memory; delay lines
  are *per-instance* memory. The two have different identity,
  lifetime, and access patterns.
- **Not a bus replacement.** Buses are global, double-buffered,
  block-rate-visible, and live for the process. Buffers are
  named, sample-rate-addressable (random access by frame),
  and live for as long as the producer keeps them alive.

## What already exists that constrains 6.C

Three existing pieces of infrastructure already settled the
shape of "shared memory the audio thread reads"; 6.C inherits
their conventions rather than reinventing them.

### `Eff` already has `BufRead` / `BufWrite`

The `Eff` ADT in
[Types.hs:700-708](../src/MetaSonic/Types.hs) declares both
`BufRead !Int` and `BufWrite !Int` alongside `BusRead` /
`BusWrite`. 6.C does **not** add these — they were laid down
earlier as a placeholder. What 6.C does is wire them onto a
concrete `NodeKind` constructor (the v1 read kind), via
`inferEff` in `Bridge/Source.hs`, so a buffer-reading UGen
actually carries `BufRead n` in its `irEffects` set.

### Bus pool — the precedent for global shared float storage

The bus pool ([rt_graph.cpp Note "Bus pool double-buffering"]),
indexed by integer ID, double-buffered for feedback safety,
allocated up-front, addressed by `KBusOut` / `KBusIn` /
`KBusInDelayed`. Same shape decisions 6.C will make:

- Integer ID, decided producer-side, stable across templates.
- Storage outlives any individual template / instance.
- Audio thread only reads pointers the producer published.
- The runtime exposes a small C ABI for producer-side
  ensure / clear; the audio thread does not call it.

Differences 6.C must address:
- **Buses are zeroed every block.** Buffers must not be.
- **Buses are sized to the block.** Buffers are sized to
  whatever the producer asks for.
- **Buses are 1-channel.** Buffers are 1-channel too in v1
  (see settled decision S-1); multichannel is one buffer ID
  per channel.
- **Buses are pre-allocated to a fixed count.** Buffers also
  use a fixed-cap table in v1 (settled decision S-3) — the
  simplest workable shape that matches the existing bus
  precedent.

### Per-node ring buffer — the precedent for per-instance memory

`KDelay` allocates a `q::delay` at instance creation, sized by
a compile-time `max_time` field, and frees it at instance
removal. The lifetime is exactly the node's lifetime. 6.C
deliberately departs from this pattern — buffers are
*resources* with their own lifetime, not node state. Reuse the
allocation idiom (producer-side, off the audio thread); do not
reuse the lifetime tie.

### Hot-swap and the §5 retire pattern

Template hot-swap already solves "publish new state on the
audio thread without locking; clean up old state from the
producer side once the audio thread no longer sees it." The
same retire / collect dance applies to buffer free in 6.C.3b:
producer calls `rt_graph_buffer_retire`, audio thread
continues to read its current view, after the next block
boundary a producer-side collector calls
`rt_graph_buffer_collect_freed` and the storage is released.
No new RCU machinery; same generation-counter trick.

## Load-bearing decisions (settled by the existing architecture)

These follow directly from the bus / hot-swap precedents above
and do not need further justification — the contract in 6.C.2
should bake them in.

1. **Identity is an integer ID, producer-allocated.** Same as
   bus IDs and node indices. The DSL exposes a `Buffer`
   newtype handle that wraps the integer; what crosses the
   FFI is `int32_t buffer_id`. Allocation happens in `IO`
   against an `Ptr RTGraph` — **outside** the pure
   `SynthM` builder, mirroring `withRTGraph` and
   `loadTemplateGraph`. `SynthM` consumes an already-allocated
   `Buffer` handle as data; it does not allocate.

2. **Allocation, load, and free are producer-side IO.** No
   audio-thread allocation. No audio-thread file I/O. The
   audio thread reads through a pointer the producer
   published before the current block.

3. **Storage outlives template hot-swap.** Buffers are a
   process-lifetime resource pool, like buses. Templates may
   *reference* a buffer ID; storage is not tied to template
   identity. A hot-swap that drops a reference to a buffer
   does not free the buffer.

4. **Live-safe free uses the §5.3 retire pattern** — but only
   in 6.C.3b. 6.C.3a ships with either no free at all, or a
   construction-time / stopped-audio clear. Live retire/free
   is its own sub-step with its own tests.

5. **`Eff` already carries `BufRead` / `BufWrite`.** No type
   change; 6.C wires the existing constructors to a new
   `NodeKind` via `inferEff`. The runtime-graph `irEffects`
   set will start carrying `BufRead n`.

6. **Template precedence is *not* yet buffer-aware.**
   `busFootprint` in
   [Templates.hs:130-135](../src/MetaSonic/Bridge/Templates.hs)
   only matches `BusRead` / `BusWrite`; `BufRead` /
   `BufWrite` are pattern-skipped today. For v1 (read-only)
   this is *correct and sufficient*: a `BufRead` on its own
   does not induce an ordering between templates — two
   templates that both read the same buffer have no
   write-then-read dependency, so no precedence edge is
   warranted. If/when `BufWrite` becomes a real UGen, the
   precedence machinery must grow a separate
   `ResourceFootprint` (or extend `BusFootprint` with buffer
   fields) so a writer template precedes any reader template
   on the same buffer ID. That is a 6.C.3b+ concern, not a
   v1 concern.

## Settled v1 contract choices (will be baked into 6.C.2)

The bounds note no longer defers these. They are the
lowest-risk choices that match the existing bus/runtime
simplicity; revisit only when 6.D or 6.E puts real pressure
on them.

- **S-1. Channel layout: mono-per-ID.** One buffer ID is one
  channel of `float32` samples. Multichannel sample data is
  modelled as multiple buffer IDs in parallel. Mirrors the
  bus convention. Easier ABI, easier kernel, easier test
  surface. Revisit if 6.D / 6.E forces interleaved
  multichannel.

- **S-2. Numeric type: `float32` only.** Matches bus storage,
  matches the audio callback's native format, simplest C
  ABI. Tagged-storage / `double` support is not a problem
  this project is currently solving.

- **S-3. Maximum count: fixed-cap table, allocated up-front.**
  A `MAX_BUFFERS`-style cap (concrete number decided in
  6.C.2 — start small, perhaps 64). Dynamic growth needs a
  free-list and reallocation policy nobody has asked for
  yet.

- **S-4. Interpolation policy: linear only.** Same kernel as
  `q::delay`'s fractional read. Cubic / Hermite is a future
  `NodeKind` if a use case appears; not a per-call flag.

- **S-5. Two-step allocate + load.** `allocBuffer frames ->
  Buffer` returns a handle; `loadBuffer buf samples` copies
  samples into it. More flexible than a one-shot
  `makeBuffer frames samples`, leaves room for a future
  in-place reload, and mirrors how SC / Csound / Pd shape
  the surface. Cost is one extra call per buffer at startup
  — negligible.

- **S-6. Unloaded / freed ID policy: emit zeros, increment
  invalid-read counter.** Decided in line with O-7 in the
  prior draft. The counter goes on the existing
  `rt_graph_test_*` introspection surface.

## Open contract questions for 6.C.2 (deliberately deferred)

These remain open and are 6.C.2's job to pin down. Each is
either small enough that the contract pass can decide it, or
contingent on a question the user has not yet answered.

- **Q-1.** Concrete cap for `MAX_BUFFERS`. 64 feels right;
  bus pool's cap is a useful anchor.
- **Q-2.** Initial `KPlayBufMono` control vector. Recommended:
  `[buffer_id, rate, start_frame, loop_flag]` per the
  implementation recommendation. The `buffer_id` slot is
  read once at instance reset; per-block playback state is
  internal kernel state, not a control.
- **Q-3.** Pattern / OSC coupling. v1 punts: buffers are set
  up out-of-band before any pattern runs, and no
  `/buffer/load` OSC address is reserved. Decision is
  effectively settled but should be written down in 6.C.2 so
  6.B's reserved-words list stays honest.
- **Q-4.** Whether 6.C.3a ships with **no** free at all
  (force the user to keep buffers for the process lifetime)
  or with a stopped-audio-only free (`rt_graph_buffer_clear`,
  documented unsafe under live audio). I lean toward
  stopped-audio-only — the unsafe-when-live disclaimer is
  cheap and the test path is straightforward.
- **Q-5.** Exact test gate for "buffer survives hot-swap." A
  reload test is straightforward; a true template hot-swap
  test needs a §5.3-style swap that drops and re-adds a
  template referencing the same buffer ID.

## Implementation plan (revised per recommendation)

| Sub-phase | Output                                                                                       |
|-----------|----------------------------------------------------------------------------------------------|
| 6.C.1     | This bounds note. No code.                                                                   |
| 6.C.2     | Short contract note: Haskell `Buffer` / `BufferId` types, C ABI signatures, kindSpec/ugenView row for `KPlayBufMono`, control vector, error vocab. Bakes in S-1..S-6. Pins Q-1..Q-5 explicitly. Reviewed before 6.C.3a. |
| 6.C.3a    | Resident mono buffer read. Implements: `Buffer`/`BufferId` types; C ABI `rt_graph_buffer_alloc`, `rt_graph_buffer_load_f32`, `rt_graph_buffer_clear` (non-live-safe), `rt_graph_test_buffer_read_count`, `rt_graph_test_buffer_invalid_read_count`; fixed-cap C++ buffer pool; one `NodeKind` (`KPlayBufMono`, tag `20`) with a self-advancing playhead; controls `[buffer_id, rate, start_frame, loop_flag]`. End-to-end test: load a sine table, play it, assert the bus output; counter-confirmed. Invalid/unloaded ID emits zeros + increments invalid-read counter. |
| 6.C.3b    | Lifetime hardening. Live-safe retire/collect (§5.3-pattern). Buffer survives at least one reload / hot-swap-style template replacement. Test invalid/freed ID behaviour explicitly. Only then expose freer high-level helpers. |
| 6.C.4     | (Conditional) Multichannel, file I/O, or write kinds — whichever 6.D / 6.E forces first. A 6.C `BufWrite` UGen will require the precedence machinery to grow buffer awareness (see decision 6 above); that is a known cost, not a surprise. |

6.C.4 deliberately stays open. The 6.E coupling is real; this
project does not get to design 6.C in isolation from plugin
hosting. If 6.E starts before 6.C.4, treat 6.C.3 + 6.E's
requirements as a co-design.

## Choice of first read kind: `KPlayBufMono` over `KBufRd`

`KPlayBufMono` carries its own playhead and self-advances at
the configured rate. `KBufRd` would consume an external phasor
input — but the project has no phasor / ramp UGen yet, so
testing `KBufRd` in isolation would require adding one first.
`KPlayBufMono` gives the smallest possible end-to-end test:
load a buffer, set rate, expect samples. A `KBufRd` kind can
land later when a phasor exists (most plausibly as part of a
spectral or granular sub-phase in 6.D).

## Minimum test gate (6.C.3a)

Before treating 6.C.3a as shipped, **all** of the following
must hold:

1. Haskell / C++ kind-tag contract includes `KPlayBufMono`
   (kindSpec ↔ ABI tag round-trips, per the existing tag-
   agreement property in `test/Spec.hs`).
2. `kindSpec` / `ugenView` arity property passes for
   `KPlayBufMono` (existing property in `test/Spec.hs`).
3. Allocate a buffer, load known samples (e.g., one cycle of
   a sine table at 256 frames), run `playBuf -> out`, read
   bus 0, assert the output matches the loaded samples to
   within interpolation tolerance.
4. The `rt_graph_test_buffer_read_count` counter proves the
   kernel actually read the buffer, not silently emitted
   matching zeros (the counter-confirmed-validation pattern
   the project already uses for the §4.E executor path).
5. Invalid / unloaded buffer ID: a `playBuf` referencing an
   un-allocated ID emits all zeros AND increments
   `rt_graph_test_buffer_invalid_read_count`.
6. (Deferred to 6.C.3b) Buffer survives at least one
   reload / hot-swap-style graph replacement.

## Coupling and rollback notes

- **Plugin hosting (6.E)** may force a buffer revision; the
  v1 surface deliberately stays small so revision cost is
  contained.
- **Pattern producer (6.A)** is not affected. No
  `PEBufferLoad` event in v1.
- **OSC listener (6.B)** is not affected. No `/buffer/*`
  reserved address in v1.
- **Hot-swap (§5.3 / §5.4)** is not affected by 6.C.3a. The
  6.C.3b retire path consumes the existing generation-
  counter pattern but does not extend it.
- **§4.B / §4.C kernel fusion** is unaffected by 6.C.3a:
  `KPlayBufMono` is a source kind with no audio inputs and
  no obvious fusion peer. If a `BufRd -> Gain -> Out`
  fusion opportunity emerges (similar to `RSawGainOut`), it
  is a §4.B follow-up, not a 6.C blocker.
