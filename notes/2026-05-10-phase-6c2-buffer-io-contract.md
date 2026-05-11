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

The pure identity type and the IO wrapper live in **separate
modules** to keep the import graph acyclic — see
[FFI.hs](../src/MetaSonic/Bridge/FFI.hs)'s existing
`MetaSonic.Bridge.Source` import.

### `MetaSonic.Types` (existing module, additions)

```haskell
-- Added alongside the existing NodeID / NodeIndex / Eff
-- vocabulary. Pure data; no IO, no FFI.
newtype Buffer = Buffer { bufferId :: Int }
  deriving stock    (Eq, Ord, Show, Generic)
  deriving anyclass (NFData)
```

The DSL imports `Buffer` from `MetaSonic.Types`. `Source.hs`
puts `Buffer` inside the `PlayBufMono` `UGen` constructor;
that does not introduce any new dependency since
`MetaSonic.Types` is already an upstream of `Source.hs`.

### `MetaSonic.Bridge.Buffer` (new module — IO wrapper only)

```haskell
module MetaSonic.Bridge.Buffer
  ( -- * Allocation / load / clear (producer-side IO)
    allocBuffer    -- :: Ptr RTGraph -> Int -> IO Buffer
  , loadBuffer     -- :: Ptr RTGraph -> Buffer -> [Float] -> IO ()
  , clearBuffer    -- :: Ptr RTGraph -> Buffer -> IO ()
                   --   (stopped-audio-only; 6.C.3a)
    -- * Errors
  , BufferIssue (..)
  ) where

import           Control.Exception     (Exception, throwIO)
import           Foreign.Marshal.Array (withArray)
import           MetaSonic.Bridge.FFI  (RTGraph)
import           MetaSonic.Types       (Buffer (..))
```

The new module imports `MetaSonic.Bridge.FFI` for `RTGraph`
and the raw C entry points; it sits **downstream** of FFI in
the import graph. `Source.hs` continues to import only
`MetaSonic.Types` (for `Buffer`), so the proposed split
breaks no existing module-graph constraint.

`loadBuffer` takes a plain `[Float]` and marshals it on the
fly with `Foreign.Marshal.Array.withArray`. This avoids
introducing a `vector` dependency for one call site — the
test corpus uses 256-sample tables where the cost of going
through a list is negligible. If a future caller needs to
load multi-MB sample data, switching to a `ForeignPtr Float`
or adding `vector` to [package.yaml](../package.yaml) is a
one-line change to this module.

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

### `portInfo` row (required for totality)

The `portInfo` totality property in
[test/Spec.hs](../test/Spec.hs) iterates
`[minBound..maxBound]` over `NodeKind` and asserts that every
declared audio input has a `Just` entry. With audio arity 3,
`KPlayBufMono` needs three rows:

```haskell
KPlayBufMono -> case i of
  0 -> Just (PortInfo PortSampleAccurate "rate")
  1 -> Just (PortInfo PortIgnored        "start_frame")
  2 -> Just (PortInfo PortSampleAccurate "loop_flag")
  _ -> Nothing
```

- **`rate`** is read every sample (the playhead advances by
  `rate` per frame), so `PortSampleAccurate`.
- **`start_frame`** is read once at instance reset via
  `rnControls[2]` and never resolved in the audio loop. An
  `RFrom` wired into port 1 would be silently dropped —
  the exact precedent set by oscillator `phase`. Marked
  `PortIgnored` so the §4.D.2 survey excludes it from
  opportunity counts and the §4.B/§4.D code paths handle
  it consistently with the oscillator family.
- **`loop_flag`** is checked at the playback-position
  boundary every sample (live toggling on / off must work),
  so `PortSampleAccurate`.

This pattern mirrors `KPulseOsc` (port 1 = `phase`,
`PortIgnored`) and validates against the existing pinned-
classification test set without needing a new pinned row.

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
  deriving anyclass (NFData, Exception)
```

The `Exception` instance comes via `deriving anyclass` —
`BufferIssue` already has `Show`, which is the only
superclass `Exception` requires. `allocBuffer` /
`loadBuffer` / `clearBuffer` throw `BufferIssue` via
`Control.Exception.throwIO` on failure (matching the
existing FFI helpers' `IO` style — see e.g. how
`loadTemplateGraph` reacts to a non-zero RC). No `Either`
shaping at the FFI layer; the producer is expected to wrap
calls in a higher-level layer if it needs that.

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

Revised after review: type surface lands first so the
existing tag-agreement / `kind_supported` / `ugenView`
arity / `portInfo` totality tests act as a tripwire when the
C++ side has not caught up.

1. **Haskell type surface first.** Add `Buffer` newtype to
   `MetaSonic.Types`; add `KPlayBufMono` to `NodeKind`;
   `kindSpec` row; `PlayBufMono` `UGen` constructor;
   `ugenView` / `inferEff` / `dependencies` / `portInfo`
   cases; `playBufMono` builder in `Source.hs`. Expect
   `kind_supported` / tag-agreement tests to fail until step
   2 lands — useful as a cross-check that the C++ side did
   not silently drift.
2. **C++ kind skeleton.** `NodeKind::PlayBufMono = 20`,
   `kind_from_tag` row, `configure_spec` audio-input refs
   and controls (4: `buffer_id`, `rate`, `start_frame`,
   `loop_flag`), `NodeState` field for `playhead_pos`, and
   a stub `process_play_buf_mono` that emits zeros and
   increments the invalid-read counter unconditionally.
   After this step the tag-agreement test passes; the E2E
   test does not.
3. **Buffer pool ABI.** `MAX_BUFFERS = 64` constant,
   `BufferSlot { std::vector<float> samples; bool
   allocated; }` on `RTGraph`, the three producer entry
   points (`alloc`, `load_f32`, `clear`) and the two test
   counters (`rt_graph_test_buffer_read_count`,
   `rt_graph_test_buffer_invalid_read_count`). No kernel
   change yet.
4. **Haskell FFI + IO wrapper.** Low-level
   `c_rt_graph_buffer_*` imports in
   `MetaSonic.Bridge.FFI`; new module
   `MetaSonic.Bridge.Buffer` with `allocBuffer`,
   `loadBuffer`, `clearBuffer`, `BufferIssue`. Marshal
   `[Float]` via `Foreign.Marshal.Array.withArray`. Add
   `MetaSonic.Bridge.Buffer` to `package.yaml`
   `exposed-modules`.
5. **Actual kernel body** in `process_play_buf_mono`:
   resolve buffer ID from control 0; initialise
   `playhead_pos` from `start_frame` at instance reset
   (`configure_node`); clamp negative `rate` to 0;
   linear-interpolate samples; loop to `start_frame` when
   `loop_flag >= 0.5` else go silent past the last frame;
   emit zero + invalid-counter on unresolved IDs;
   valid-counter per valid sample.
6. **Tests in this order:**
   - **a.** Tag support / `kind_supported` round-trip
     (automatic via the existing iteration).
   - **b.** `ugenView` arity totality (automatic).
   - **c.** `portInfo` totality (automatic — the test
     iterates `[minBound..maxBound]`).
   - **d.** FFI wrapper unit tests: alloc returns ID 0;
     alloc twice returns IDs 0, 1; alloc past 64 raises
     `BiPoolFull`; load with too many frames raises
     `BiFrameCountExceedsBuffer`; load against an unknown
     ID raises `BiUnknownBufferId`.
   - **e.** End-to-end: load a 256-frame sine table, build
     `playBufMono buf (Param 1.0) (Param 0) (Param 0) → out 0`,
     render one block, compare bus-0 output to the loaded
     samples within linear-interpolation tolerance;
     counter-confirm `rt_graph_test_buffer_read_count > 0`.
   - **f.** Invalid-ID render: build a graph that references
     an unallocated `Buffer 99`, render, assert bus-0 is
     all zeros AND
     `rt_graph_test_buffer_invalid_read_count > 0`.
   - **g.** Clear-then-render: alloc + load + clear, then
     render, same invalid-ID assertions.
7. Update `ROADMAP.md`: mark 6.C.2 done and 6.C.3a as
   shipped. Commit.

Step ordering is deliberate: get the type / ABI surface in
**before** the kernel body, so a regression at step 5 fails
loud (counter mismatch on a fresh test) instead of silent
(correct output for the wrong reason).
