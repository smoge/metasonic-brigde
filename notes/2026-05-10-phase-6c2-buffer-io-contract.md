# Phase 6.C.2 — Buffer I/O Contract

Date: 2026-05-10
Status: contract only; pins the v1 shape that 6.C.3a
implements. No code lands here.

This note follows
[Phase 6.C.1 buffer I/O bounds](2026-05-10-phase-6c-buffer-io-design.md).
6.C.1 settled what 6.C is and is not; this note pins the
exact Haskell types, C ABI signatures, kindSpec / ugenView /
inferEff rows, control vector, and error vocabulary that
6.C.3a will implement. Everything below is in scope for
6.C.3a unless explicitly tagged 6.C.3b.

## Settled choices recap (from 6.C.1)

S-1 mono-per-ID · S-2 `float32` · S-3 fixed-cap table ·
S-4 linear interpolation · S-5 two-step allocate + load ·
S-6 unloaded/freed ID emits zeros + invalid-read counter.

## Q-1..Q-5 decisions

- **Q-1. `MAX_BUFFERS = 64`.** Mirrors the bus pool's
  one-power-of-two cap convention; small enough to keep the
  fixed pool cheap, large enough that no v1 user will hit it.
  Re-evaluate if 6.D / 6.E forces it.
- **Q-2. Control vector for `KPlayBufMono`:**
  `[buffer_id, rate, start_frame, loop_flag]`.
  - `buffer_id`: integer-valued `double`; consulted at
    instance reset (i.e. at `c_rt_graph_instance_add` or via
    the realtime ABI in 6.C.3b). Casting/truncation
    semantics: `static_cast<int32_t>(round(...))`,
    out-of-range clamped to `-1` so the invalid-read path
    fires deterministically.
  - `rate`: playback rate as a multiplier (1.0 = forward,
    real-time; negative reserved for future reverse
    playback, **not** implemented in 6.C.3a — out-of-band
    values are clamped to `[0.0, ∞)`).
  - `start_frame`: floating-point frame index at which a
    fresh playhead begins. Read at instance reset.
  - `loop_flag`: integer-valued `double`. `0.0` = one-shot
    (silence after the last frame), `>= 0.5` = loop back to
    `start_frame`. Read on every read so live toggling works.
- **Q-3. Pattern / OSC coupling: deferred to a later
  sub-phase.** No `PEBufferLoad` / `PEBufferFree`
  `PatternEvent` constructor in v1; no `/buffer/*` reserved
  OSC path in v1. The 6.B reserved-words list
  ([Dispatch.Internal.hs](../src/MetaSonic/OSC/Dispatch/Internal.hs))
  stays unchanged. Set buffers up out-of-band via the
  Haskell IO surface before any pattern runs.
- **Q-4. 6.C.3a free: stopped-audio-only `clear`.** The
  6.C.3a C ABI exposes `rt_graph_buffer_clear` which is
  documented as **unsafe to call while the audio stream is
  running**. Documented contract; no runtime enforcement
  yet. Live-safe `retire / collect` lands in 6.C.3b with the
  §5.3 generation-counter pattern.
- **Q-5. Hot-swap survival test (deferred to 6.C.3b).**
  6.C.3a's hot-swap-equivalent test: allocate a buffer,
  build and load a `TemplateGraph` that references it,
  destroy the `RTGraph`, rebuild a fresh `RTGraph`,
  reload — and assert the buffer pool starts empty
  (i.e. *fresh-create* test, not survival across hot-swap).
  Real hot-swap survival via `rt_graph_prepare_swap` /
  `publish_swap` belongs in 6.C.3b once `retire / collect`
  exists.

## Haskell surface

### `MetaSonic.Bridge.Buffer` (new module)

```haskell
module MetaSonic.Bridge.Buffer
  ( -- * Identity
    Buffer
  , bufferId          -- :: Buffer -> Int

    -- * Allocation / load / clear (producer-side IO)
  , allocBuffer       -- :: Ptr RTGraph -> Int -> IO Buffer
  , loadBuffer        -- :: Ptr RTGraph -> Buffer
                      --   -> VS.Vector Float -> IO ()
  , clearBuffer       -- :: Ptr RTGraph -> Buffer -> IO ()
                      --   (stopped-audio-only; 6.C.3a)

    -- * Errors
  , BufferIssue (..)
  ) where
```

```haskell
newtype Buffer = Buffer { bufferId :: Int }
  deriving stock (Eq, Ord, Show)
```

`Buffer` is opaque to the DSL but its integer identity is
exposed (the `bufferId` accessor) because the `playBuf`
builder needs the raw integer to fill the `buffer_id`
control slot.

### `MetaSonic.Bridge.Source` additions

The new `UGen` constructor:

```haskell
| PlayBufMono
    !Buffer        -- the buffer to read
    !Connection    -- rate (typically a Param; an Audio edge works too)
    !Connection    -- start_frame
    !Connection    -- loop_flag
```

Builder:

```haskell
playBufMono
  :: Buffer
  -> Connection      -- rate
  -> Connection      -- start_frame
  -> Connection      -- loop_flag
  -> SynthM Connection
playBufMono buf rate start lp =
  insertNode "playBufMono" (PlayBufMono buf rate start lp)
```

(Builder uses the same `insertNode` / `insertNodeC` idiom as
the other source-rate kinds.)

### `ugenView` row

```haskell
PlayBufMono buf r s lp ->
  UGenView KPlayBufMono
           [r, s, lp]
           [ fromIntegral (bufferId buf)
           , connDefault r
           , connDefault s
           , connDefault lp
           ]
```

Audio arity: 3 inputs (`rate`, `start_frame`, `loop_flag` —
all valid as `Param` literals; the audio-arity / control-
arity asymmetry pattern is the same as `Gain` and `LPF`).
Control arity: 4 (`buffer_id`, `rate`, `start_frame`,
`loop_flag`). `buffer_id` is positional control slot 0.

### `kindSpec` row

```haskell
KPlayBufMono -> KindSpec 20 SampleRate 3 4 "playBufMono"
```

- Tag `20` — the next free integer after `KNotch = 19`.
- Rate floor `SampleRate` — the kernel writes one sample
  per audio-thread frame; a block-rate floor would alias.
- Audio arity `3` (`rate`, `start_frame`, `loop_flag`).
- Control arity `4` (`buffer_id` + the three input
  defaults).
- Label `"playBufMono"` — used by `insertNode`.

### `inferEff` case

```haskell
inferEff (PlayBufMono buf _ _ _) = [BufRead (bufferId buf)]
```

Wires the existing `BufRead !Int` constructor (already in
[Types.hs:705](../src/MetaSonic/Types.hs)) onto the new
kind. `busFootprint` in
[Templates.hs:130](../src/MetaSonic/Bridge/Templates.hs)
remains bus-only; the `BufRead` entry is correctly ignored
for template precedence in v1 (a `BufRead` alone induces no
ordering, per 6.C.1 decision 6).

### `dependencies` case

```haskell
dependencies (PlayBufMono _ r s lp) = deps [r, s, lp]
```

(`Audio` connections among `r` / `s` / `lp` contribute
structural edges; `Param` literals do not.)

## C ABI (additions to `tinysynth/rt_graph.h`)

```c
// [T:construction] Allocate a buffer of `frames` mono float32
// samples. Returns the assigned 0-based buffer ID on success,
// or -1 if the pool is full (>= MAX_BUFFERS allocated). The
// underlying storage is zero-initialised; load samples in
// with rt_graph_buffer_load_f32.
//
// Construction-only: must run before rt_graph_start_audio.
int rt_graph_buffer_alloc(RTGraph *g, int frames);

// [T:construction] Copy `frame_count` float32 samples from
// `samples` into buffer `buffer_id`, starting at frame 0.
// Returns the number of frames written, or:
//   -1 if buffer_id is out of range or unallocated,
//   -2 if frame_count > the buffer's allocated frame count.
//
// Construction-only: must run before rt_graph_start_audio.
int rt_graph_buffer_load_f32(
    RTGraph *g,
    int buffer_id,
    const float *samples,
    int frame_count);

// [T:construction] Release `buffer_id` and zero its slot.
// UNSAFE to call while audio is running — the audio thread
// may still be reading from this slot. 6.C.3a documents
// this as a construction / stopped-audio operation; live
// retire/collect lands in 6.C.3b.
//
// Returns 0 on success, -1 if buffer_id is out of range or
// already unallocated.
int rt_graph_buffer_clear(RTGraph *g, int buffer_id);

// [T:read-only] Phase §6.C.3a test surface: total number of
// successful sample reads performed by KPlayBufMono kernels
// since g was created. Counts one tick per kernel-per-sample
// (not per-block). Returns 0 if no block has run yet, or if
// g is null.
long long rt_graph_test_buffer_read_count(const RTGraph *g);

// [T:read-only] Phase §6.C.3a test surface: total number of
// reads against an invalid buffer_id (out of range or
// unallocated) by KPlayBufMono kernels since g was created.
// These reads emit zeros; the counter is the only way to
// distinguish "kernel emitted zeros because no buffer" from
// "kernel didn't run at all." Returns 0 if no block has run
// yet, or if g is null.
long long rt_graph_test_buffer_invalid_read_count(
    const RTGraph *g);
```

Naming conventions follow the existing `rt_graph_*` /
`rt_graph_test_*` style. `MAX_BUFFERS = 64`, defined in
`rt_graph.cpp` as an internal constant (not exposed in the
header — same pattern as the bus-pool cap).

## C++ side (additions to `tinysynth/rt_graph.cpp`)

- `enum NodeKind`: append `KPlayBufMono = 20`.
- A `BufferSlot` struct (internal): `{ std::vector<float>
  samples; bool allocated; }`. The world / `RTGraph` carries
  a `std::array<BufferSlot, MAX_BUFFERS>`.
- `configure_node` case for `KPlayBufMono`: reads
  `buffer_id`, `start_frame` once at reset; initialises
  per-instance kernel state `{ float playhead_pos; }`.
- `process_play_buf_mono(...)`: linear-interpolates samples
  from the resolved buffer at the current `playhead_pos`,
  advances by `rate` per sample, applies the `loop_flag`
  branch at the buffer end, increments the read counter on
  each valid sample, increments the invalid-read counter
  and emits zero on each sample where `buffer_id` does not
  resolve.
- `rt_graph_add_node` case for tag `20`.
- `process_graph` case dispatching `KPlayBufMono` →
  `process_play_buf_mono`.

## Error vocabulary

C ABI return codes (already drafted in the ABI section):

| Function                       | Code   | Meaning                                |
|--------------------------------|-------:|----------------------------------------|
| `rt_graph_buffer_alloc`        | `-1`   | pool full (≥ MAX_BUFFERS allocated)    |
| `rt_graph_buffer_load_f32`     | `-1`   | `buffer_id` out of range / unallocated |
| `rt_graph_buffer_load_f32`     | `-2`   | `frame_count` exceeds buffer size      |
| `rt_graph_buffer_clear`        | `-1`   | `buffer_id` out of range / unallocated |

Haskell-side `BufferIssue` ADT (mirrors the issue patterns
in `MetaSonic.OSC.Dispatch`, `MetaSonic.Bridge.Templates`):

```haskell
data BufferIssue
  = BiPoolFull         -- alloc returned -1
  | BiUnknownBufferId  !Int  -- load / clear returned -1
  | BiFrameCountExceedsBuffer !Int !Int
                       -- requested, capacity
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)
```

`allocBuffer` / `loadBuffer` / `clearBuffer` throw
`BufferIssue` via `Control.Exception.throwIO` on failure
(matching the existing FFI helpers' `IO` style — see
e.g. how `loadTemplateGraph` reacts to a non-zero RC). No
`Either` shaping at the FFI layer; the producer is expected
to wrap calls in a higher-level layer if it needs that.

## Cross-checks (existing test properties cover these)

The Haskell ↔ C++ tag-agreement property in
[test/Spec.hs](../test/Spec.hs) (the
`c_rt_graph_kind_supported`-based test) iterates
`[minBound..maxBound]` via the derived `Bounded` instance on
`NodeKind`, so adding `KPlayBufMono` automatically extends
the assertion. The `ugenView` arity property
(`ugenView arities match kindSpec for every UGen`) likewise
extends. Neither test needs explicit changes for 6.C.3a — but
both must continue to pass.

## What 6.C.3a will NOT include (deferred to 6.C.3b)

- No `rt_graph_buffer_retire` / `rt_graph_buffer_collect_freed`.
- No live-safe free (the documented `_clear` is enough for
  v1 fresh-create tests).
- No hot-swap survival test (the fresh-create test in Q-5 is
  the 6.C.3a stand-in).
- No `KBufRd` kind (no phasor UGen yet).
- No write kinds, no precedence extension for `BufWrite`.
- No multichannel, no file I/O, no async load.

## Implementation order for 6.C.3a

1. Add `BufferSlot` storage to the C++ `RTGraph` (header +
   .cpp) and the read/invalid-read counters. Make
   `rt_graph_kind_supported(20) == 1` after wiring
   `KPlayBufMono` into `kind_from_tag`. No process_graph
   change yet — fail fast if a graph tries to use the new
   kind.
2. Add `rt_graph_buffer_alloc` / `_load_f32` / `_clear`.
   Standalone C++ test: alloc, load, read back via a debug
   accessor (or skip — only Haskell tests need to verify).
3. Add `KPlayBufMono` to `NodeKind`, `kindSpec` row, `UGen`
   `PlayBufMono` constructor, `ugenView` / `inferEff` /
   `dependencies` cases, `playBufMono` builder.
4. Add the C++ `process_play_buf_mono` kernel and wire it
   into `process_graph` + `configure_node` +
   `rt_graph_add_node`. Read counter ticks on each valid
   sample; invalid-read counter ticks on each sample where
   `buffer_id` doesn't resolve.
5. Add the Haskell FFI bindings (`MetaSonic.Bridge.FFI`) for
   the four new C entry points + the two counters.
6. Add `MetaSonic.Bridge.Buffer` (the new module) with
   `Buffer`, `allocBuffer`, `loadBuffer`, `clearBuffer`,
   `BufferIssue`.
7. Add the end-to-end test in `test/Spec.hs`: alloc a
   buffer, load a sine table of 256 frames, build a graph
   `playBufMono buf (Param 1.0) (Param 0) (Param 1) → out 0`,
   render one block, assert the bus-0 output matches the
   loaded samples to within linear-interpolation tolerance.
   Counter-confirm via `rt_graph_test_buffer_read_count > 0`.
8. Add the invalid-ID test: build a graph with a
   `PlayBufMono` whose `Buffer` references a never-allocated
   ID (e.g. by constructing `Buffer 99` directly via a
   test-only constructor, or by clearing the buffer before
   render). Assert bus-0 is all zeros AND
   `rt_graph_test_buffer_invalid_read_count > 0`.
9. Update `package.yaml` (`exposed-modules`) + `CMakeLists.txt`
   (no new files, but the .cpp / .h changes need a rebuild).
10. Update `ROADMAP.md` to mark 6.C.2 done and 6.C.3a as the
    current task. Commit.

Step ordering is deliberate: get the data-plane storage and
counters in **before** the kernel, so a regression at step 4
fails loud (counter mismatch) instead of silent (correct
output for the wrong reason).
