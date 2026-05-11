# Phase 6.C.4 Follow-up — Minimal `RecordBufMono` (Design)

Date: 2026-05-11
Status: design / contract preflight; no code lands here. Bounds
the first audio-thread writer UGen and pins the questions a
writer introduces that the read-only kinds didn't have to face.
A `6.C.4-record-contract.md` note (or this note's section 8)
will pin the final shape before implementation; expect the
slicing in section 7 to be the first three commits after sign-off.

## 0. Anchors

This note assumes 6.C.4 has shipped:

- The buffer pool is keyed off `RTGraph`, not `RTGraphState` —
  buffers survive prepare_swap / publish_swap and `rt_graph_clear`
  (6.C.3b slice 1, commit 6dbe75c).
- `retireBuffer` + `collectRetiredBuffer` give the producer a
  live-safe lifecycle on top of the stopped-audio fast path
  (6.C.3b slice 2, commit 166a667).
- `Template.tplFootprint` and `RuntimeRegion.rrFootprint` carry
  `ResourceFootprint` (bus + buffer halves). The template-level
  precedence rule unions `BufWrite → BufRead` edges, and
  `compileTemplateGraph` rejects same-buffer `BufWrite / BufWrite`
  (6.C.4 slices 2–4, commits 3fcfdee / 05211f6 / 1a363b5).

The writer kind is the only piece left to make the 6.C surface
land — and the only piece that puts the audio thread on the
write side of the buffer slot. Everything else is wired.

## 1. What the kind is and is not

In scope (this design):

- A single new `NodeKind`: `KRecordBufMono`. Tag `21` (one past
  `KPlayBufMono = 20`).
- DSL builder
  `recordBufMono :: Buffer -> Connection -> Connection -> SynthM Connection`
  — input signal, loop_flag, and a pass-through output equal to
  the input (see §3 on pass-through rationale).
- Audio-thread sample-by-sample write into the slot's
  `samples` vector. Self-advancing write head, mono float32, no
  random-access write port.
- One-shot vs. loop, parameterized by a `PortSampleAccurate`
  `loop_flag` (mirrors `KPlayBufMono` exactly so the surface is
  symmetric).
- `inferEff (RecordBufMono buf _ _) = [BufWrite (bufferId buf)]`
  — picks up automatically through 6.C.4's precedence union.
- Compile-time rejection (already in 6.C.4 slice 4) of
  same-buffer writes from different templates.
- New invalid-write counter `buffer_invalid_write_count` for the
  same counter-confirmed-validation pattern that
  `buffer_invalid_read_count` powers on the read side.

Out of scope (do **not** open in this design):

- Random-access write (`BufWr` with an externally driven write
  head). Self-advancing is the minimum viable; a random-access
  variant can land later as a separate kind once a real use case
  asks for it.
- Multichannel records. Mono is the lifetime-contract minimum.
- Write-via-file / async write. The 6.C surface is resident
  storage only.
- A `loop_count` parameter, a `start_frame` parameter, or a
  write-rate parameter. Symmetric with `KPlayBufMono`'s
  `PortIgnored` `start_frame` would be tempting, but a writer
  with a configurable start frame raises the "what about
  partial overwrites" question that 6.C.4 deliberately
  postponed.
- A `record_run` gate. The kind always writes when it runs; a
  producer that wants to stop writing should retire the
  buffer (which the audio thread observes as `Retired`, falls
  into the invalid-write path, and ticks the invalid counter).

## 2. The audio-thread write path — what's new vs. the read kind

Writes mutate shared sample storage, which `KPlayBufMono` never
did. The four real questions:

### 2.1 Slot state observation

Same acquire-load of `slot.state` the read path does. A writer
that resolves a slot in state `Allocated` proceeds; `Retired` or
`Unallocated` lands in the invalid-write path (emit no
mutation, tick `buffer_invalid_write_count` per sample). The
kernel never *writes* outside `Allocated`, so a producer that
retires the slot mid-block stops seeing further mutations on
the very next block.

`PlayBufMonoState`'s frozen `buffer_id` pattern carries over to
`RecordBufMonoState`: resolve `controls[0]` once at
`init_node_state`, store on per-instance state, kernel never
re-reads `controls[0]` per block. Same `§6.C.2` contract; same
test idiom (a live-set_control regression test on slot 0).

### 2.2 Audio-thread storage write — what about resize?

`slot.samples` is a `std::vector<float>`. A `push_back` could
resize, which on the audio thread is forbidden. The writer
**must not** call any vector operation that can reallocate; it
indexes into the existing vector through `slot.samples.data()`
and writes by position only. `slot.samples.size()` is set at
`alloc` time (stopped audio) and never changes on the audio
thread — the same invariant as the read path. The write head
is bounded against `slot.samples.size()` exactly like
`PlayBufMono`'s playhead is bounded against `frame_count_d`.

### 2.3 Memory ordering between writer and reader

When a `RecordBufMono` and a `PlayBufMono` reference the same
buffer, today's intra-graph topological sort (E_r) plus today's
inter-template precedence (E_r at the template level) puts the
writer before the reader within the same block. So the
within-block sequencing is:

  writer kernel writes samples[0..N-1]
  reader kernel reads  samples[0..N-1]

Both kernels run on the same audio thread (process_graph is
single-threaded today — the worker pool is opt-in and is gated
to free-region dispatch only, §4.E.2.C1c, so cross-kernel
writes to the same buffer are not concurrent). No additional
fences are needed inside one block.

Across blocks, the writer's stores in block N are observable to
a kernel in block N+1 because there's a sequenced-before
relation through the audio thread's single linear execution and
the `process_graph` call boundary; the §6.C.3b
`buffer_retire_generation` `fetch_add(release)` at the top of
each block also serves as a synchronization point that
publishes any pending writes.

### 2.4 The worker-pool question

The §4.E.2.C1c worker pool currently dispatches **free-region
band** work items only. The dispatch eligibility check
(`process_schedule_band_serial` and the free-band predicates
in [Schedule.hs](../src/MetaSonic/Bridge/Compile/Schedule.hs))
runs over `rrFootprint`'s **buses**. As of 6.C.4 slice 2,
`rrFootprint` carries the full `ResourceFootprint`, but the
band-eligibility predicate has not been extended to consider
the buffer half yet — it only sees buses.

Today this is benign (no writer kind, only `BufRead` from
`KPlayBufMono`). With `RecordBufMono`:

- A region containing a `RecordBufMono` writing buffer N must
  not be dispatched in parallel with another region (in any
  template) reading buffer N. The 6.C.4 inter-template
  precedence handles this at the TEMPLATE scope; the
  intra-template REGION scope needs the same union to land in
  the band predicate.

The design takes the conservative path: extend
`process_schedule_band_serial`'s buffer-aware predicate so a
region containing a writer never lands in a parallel band.
This is the same shape as the existing live-bus-write barrier
predicate (§4.E.2.C1c "Barrier" bands).

Equivalent in code: add a helper
`regionHasBufferWriter :: RuntimeRegion -> Bool` (or fold
through the existing `regionHasLiveBus` shape) and consult it
in the same place the live-bus check fires. Conservative;
zero risk of a data race; matches the principle that v1 should
prove the read/write story rather than push for parallel writes.

If a future corpus shows the conservative serialization is too
costly, a follow-up can refine: a band containing a writer for
buffer N and a reader for buffer M (M ≠ N) is safe to parallelize.
This is exactly the buffer-disjointness analysis the bus side
already does; deferring it to a use case keeps v1 honest.

## 3. Pass-through output — yes or no

The read kind (`KPlayBufMono`) has one audio output. The writer
has a choice:

**Option A — no audio output.** The kind is a sink; routing it
to `out 0` is a compile error. Sink-only kinds exist
(`KOut`, `KBusOut`), so the precedent is set.

**Option B — pass-through output equal to the input.** The
recorded signal flows through unchanged, so a producer can
chain `recordBufMono buf sig (Param 1.0) >>= gain 0.5 >>= out 0`
without splitting the signal manually.

Decision: **B (pass-through)**. Reasons:

- Composes inline with the rest of the DSL. The producer can
  monitor while recording without adding a duplicating
  bus.
- Matches SuperCollider's `RecordBuf.ar` (which returns the
  recorded signal).
- The implementation cost is one `output_span` write per
  sample — same shape as the read kind, free.
- If the producer doesn't want the monitor signal, they can
  route the output to a Param-only bus or discard via `_ <- ...`
  in the DSL.

The pass-through output does **not** carry any buffer-write
side-effect on its own — the writing is the side effect; the
output is just the input forwarded. So the structural edge
`recordBufMono → gain → out` is a normal E_s edge, not an E_r
edge against the buffer.

## 4. Retire-while-writing

The §6.C.3b retire contract says: retired slots take the
invalid path on the next block, sample storage stays alive
until collect succeeds. The read kind takes that into the
invalid-read path. The write kind needs the same shape:

- Block M: kernel observes `Allocated`, captures `samples.data()`,
  writes samples[K..K+N-1].
- Producer retires buffer between blocks: state ← `Retired`,
  generation snapshot stamped on the slot.
- Block M+1: kernel observes `Retired` via acquire-load,
  takes the invalid-write path — does NOT touch
  `samples.data()`, ticks `buffer_invalid_write_count` per
  sample.
- Producer collects after block M+1's `process_graph` ticks
  the counter past the snapshot. Slot transitions to
  `Unallocated`; samples vector capacity preserved.

This is symmetric with the read kind. The retired slot is
unwritable just as it is unreadable. The kernel's write head
advances even in the invalid path (so the producer-visible
behavior of "the record kept running while retired" stays
sensible), but no storage is touched.

A subtler case: producer retires mid-block while the kernel is
already inside a `process_graph` call writing the slot. By the
same argument as the read side: the captured pointer is valid
through the rest of this block (retire never resizes or frees
samples), the next block's acquire-load sees `Retired` and goes
invalid-path, collect waits for the generation tick past the
snapshot. No new ordering requirement.

## 5. Counters

Two new counters on `RTGraph`, both `long long`:

- `buffer_write_count` — ticks once per kernel-per-sample on
  every successful write to a buffer slot.
- `buffer_invalid_write_count` — ticks once per kernel-per-
  sample on every write attempt against an unresolved /
  retired / unallocated slot.

Same shape as the read counters; same test-surface accessors
(`rt_graph_test_buffer_write_count`,
`rt_graph_test_buffer_invalid_write_count`). The
counter-confirmed-validation pattern is what keeps the
retire-during-write test honest (the user-visible test:
"output silence + invalid-write counter ticks" rather than
just "output silence").

## 6. DSL surface

```haskell
recordBufMono
  :: Buffer
  -> Connection      -- audio input (the signal to record)
  -> Connection      -- loop_flag (0.0 = one-shot, >= 0.5 = loop)
  -> SynthM Connection
```

Returns the pass-through audio signal (same as the input).
Builder uses the same `insertNodeC` idiom as the rest of the
source-rate kinds.

### `kindSpec` row

```haskell
KRecordBufMono ->
  KindSpec 21 SampleRate 2 3 "recordBufMono"
```

- Tag `21` — next free after `KPlayBufMono = 20`.
- Rate floor `SampleRate` — sample-by-sample writes.
- Audio arity `2` (`signal_in`, `loop_flag`).
- Control arity `3` (`buffer_id`, `signal_in_default`, `loop_default`).

### `portInfo` row

```haskell
KRecordBufMono -> case i of
  0 -> Just (PortInfo PortSampleAccurate "signal_in")
  1 -> Just (PortInfo PortSampleAccurate "loop_flag")
  _ -> Nothing
```

Both ports are `PortSampleAccurate` — `signal_in` because we're
recording every sample, and `loop_flag` for the same
live-toggle reason the read kind has it sample-accurate.

### `inferEff` case

```haskell
inferEff (RecordBufMono buf _ _) = [BufWrite (bufferId buf)]
```

The 6.C.4 precedence union picks this up automatically:
inter-template `RecordBufMono → PlayBufMono` on the same buffer
becomes a precedence edge; the intra-graph E_r rule in
`Bridge.Validate` needs to learn the same shape (see §7 slice 1).

## 7. Implementation slicing

Three commits, in order. **No commit intentionally leaves
`stack test` red** — slice 1 lands the Haskell surface *plus*
the minimal C++ tag/state/skeleton needed to keep the
tag-agreement and `kind_supported` properties green. Slice 2
then fills in the real kernel body. Slice 3 adds end-to-end
tests. This departs from the 6.C.3a precedent that landed
Haskell first with a known-red tag test in between — that
pattern is useful as a tripwire but it forces every reviewer
to read a red CI and decide whether the red is expected, which
is friction we can avoid here.

### Slice 1 — Haskell surface + minimal C++ skeleton

Haskell side:

- `KRecordBufMono` in `NodeKind`, `kindSpec` row, `inferEff`
  case, `dependencies` case, `portInfo` row, `UGen`
  constructor.
- `recordBufMono` DSL builder.
- Extend `Bridge.Validate.busEdges` to also pair `BufWrite`
  with `BufRead` on the same buffer id (intra-graph E_r at
  the buffer scope). Same shape as the existing pairing, same
  exclusion of `BufReadDelayed`.
- Add the `BufWrite` case to `runtimeNodeResourceFootprint`
  so intra-template region precedence picks up the writer too.
- `compileTemplateGraph`'s slice-4 check fires automatically
  when two templates use `recordBufMono` on the same buffer.

C++ side, just enough to keep the tag/agreement test green:

- `NodeKind::KRecordBufMono = 21`, `kind_from_tag` row,
  `configure_spec` row matching Haskell's `KindSpec 21
  SampleRate 2 3 "recordBufMono"`.
- `RecordBufMonoState { int buffer_id; long long write_head; }`
  added to the `NodeState` variant, `init_node_state` resolves
  `controls[0]` once at reset.
- Stub `process_record_buf_mono` kernel that emits zero on the
  pass-through output and ticks `buffer_invalid_write_count`
  unconditionally — same pattern as the §6.C.3a stub before
  the real kernel landed.
- Two new counters (`buffer_write_count`,
  `buffer_invalid_write_count`) on `RTGraph`, plus the
  `rt_graph_test_buffer_write_count` /
  `_invalid_write_count` accessors.

After slice 1: every existing test still passes; the
tag-agreement / `kind_supported` / `portInfo` / `ugenView`
arity properties all extend through `KRecordBufMono` because
both sides agree. An end-to-end record-then-playback test
does **not** exist yet — that's slice 3's job — but no test
is intentionally red.

### Slice 2 — Real `process_record_buf_mono` kernel

Replaces slice 1's zero-output stub with the actual write path:

- `process_record_buf_mono` kernel: acquire-load `slot.state`,
  invalid path on anything except `Allocated`, write
  `signal_in[fi]` into `samples[write_head]`, increment
  `write_head`, loop back to 0 when wrapping past
  `samples.size()` if `loop_flag >= 0.5` else stop writing
  (invalid path) at end. Mirror the read kernel's structure
  one-for-one. Pass-through output is `signal_in[fi]`
  unconditionally.
- Add the `regionHasBufferWriter` predicate and consult it in
  `process_schedule_band_serial` — a region with a writer
  never lands in a parallel band (conservative).

Slice 2 stays test-green by either keeping the stub coverage
tests from slice 1 valid (stub asserts the invalid path; real
kernel still hits the invalid path on unallocated slots), or by
adding a single end-to-end "write one block, read it back"
test inline if the stub's tests no longer apply. Goal: never
intentionally red.

### Slice 3 — tests

The end-to-end coverage the writer needs:

- **Record-then-playback**, single block, single template: a
  graph with `noise → recordBufMono buf signal (Param 1.0) →
  ignore` followed by a second template `playBufMono buf
  (Param 1.0) (Param 0) (Param 1.0) → out 0`. Render two
  blocks: block 1 writes; block 2 reads back what was written
  within a 1e-5 tolerance. Counter-confirmed:
  `buffer_write_count == nframes` after block 1,
  `buffer_read_count == nframes` after block 2.

- **Retire-during-write**: alloc buffer, build a single
  template `noise → recordBufMono buf signal (Param 1.0)`,
  render block 1 (assert write counter ticks), call
  `retireBuffer`, render block 2 (assert write counter does
  NOT tick; invalid-write counter ticks `nframes`), call
  `collectRetiredBuffer`, succeeds. Re-alloc, confirm fresh
  storage (record one block of constant signal, read it back,
  it matches).

- **Same-buffer cross-template `BufWrite`**: a template that
  uses `recordBufMono buf …` and another that does the same on
  the same buffer. Compile must fail with the slice 4
  diagnostic naming both templates.

- **Loop wrap**: a 4-frame buffer, `recordBufMono`
  loop_flag=1.0, render 8 samples of an ascending counter
  signal `[0, 1, 2, ..., 7]`. The buffer's final contents
  should be `[4, 5, 6, 7]` (the second pass overwrote the
  first). Counter-confirmed: 8 valid writes.

- **One-shot boundary**: same 4-frame buffer, loop_flag=0.0,
  8 input samples. Final buffer contents `[0, 1, 2, 3]`;
  4 valid writes + 4 invalid writes.

- **Live set_control on slot 0 does not retarget**: the
  same regression test that pinned `PlayBufMono`'s frozen
  buffer_id, applied to `RecordBufMono`.

## 8. Open questions to settle in the contract note

Q-1. **`init_node_state` defaults for the write head.** Symmetric
   with `PlayBufMono`'s `start_frame`: should there be a
   `start_frame` control for the writer too (recorded with
   `PortIgnored`)? Default in this design: **no**, write_head
   starts at 0. Adding it is cheap; pin in the contract note
   if a real use case asks.

Q-2. **`loop_flag = 0` past-the-end behavior.** Today's design:
   stop writing, tick `buffer_invalid_write_count` per sample.
   Alternative: stop writing silently, do not tick the
   invalid counter (since the kernel did run — it just had
   nothing left to do). Default: **tick invalid**, so the
   test surface can prove "kernel ran but wrote nothing"
   distinctly from "kernel didn't run."

Q-3. **Conservative band-serialization vs. buffer-disjoint
   parallelism.** Today's design: any region containing a
   writer is barrier-bound. Lifting this to "writer for
   buffer N is safe to parallelize with reader/writer for
   buffer M ≠ N" is a follow-up if a corpus needs it. Default:
   **conservative**, lift later.

Q-4. **Counters reset on `c_rt_graph_clear`?** The §6.C.3b
   slice 1 decision: the buffer pool survives clear, so
   counters also survive. Symmetric for the write counters.
   No new policy.

Q-5. **DSL pass-through type.** The proposed signature returns
   `SynthM Connection` carrying the input signal. The
   alternative is `SynthM ()` (sink-only), which forces a
   producer who wants to monitor to use a bus split.
   Default: **Connection** — see §3.

## 9. What this does NOT unblock

- **6.D spectral.** Block-rate FFT / windowing has its own
  scheduling story; record/playback on a contiguous buffer
  doesn't help. Spectral lands after 6.C is closed.
- **6.E plugin hosting.** Plugin-owned buffers will use the
  same pool, but plugin lifecycle is an external story —
  separate phase.
- **Same-buffer `BufWrite / BufWrite` lifting.** Still
  rejected at every scope after 6.C.5: across templates
  (§6.C.4), inside one graph (§6.C.5 commit 2), and at
  runtime via the polyphony=1 clamp on writer templates
  (§6.C.5 commit 1). v1 buffer writers are a single-writer,
  single-template-instance resource. Lifting that constraint
  needs an explicit ordering / mixdown primitive — the
  implicit "input declaration order" is the trap §6.C.4
  declined to pin.
- **File I/O, async load, multichannel.** All explicitly
  deferred in 6.C.4's bounds.

## 10. Test plan summary

Counter-confirmed assertions in every test, mirroring the
read-side discipline. A regression that emits silent zeros
through the wrong code path cannot pass either the value or
the counter check.

After slice 3:

- Total tests: 558 + ~6 new = ~564.
- New counters in test surface: `buffer_write_count`,
  `buffer_invalid_write_count`.
- C ABI surface added: two counter accessors, no new
  producer-side entry points (writes only happen through the
  audio thread).
- DSL surface added: `recordBufMono` (one builder), no new
  IO surface — record IS the side effect.

If anything in this design changes during implementation,
update this note (the §6.C.3b precedent) rather than letting
the doc drift.
