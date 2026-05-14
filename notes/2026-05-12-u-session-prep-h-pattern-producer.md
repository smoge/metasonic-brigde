# Session Prep H - Pattern Producer Bridge

Date: 2026-05-12

Status: draft decision artifact. This slice scopes the first concrete
producer bridge above the Prep G bounded queue. It is still not a
thread-safe fan-in layer, background scheduler, OSC/MIDI/UI adapter,
audio-thread queue, or preserving hot-swap implementation.

## Decision

Add a small Haskell-only Pattern producer bridge that converts
`PatternEvent`s into `SessionCommand`s and enqueues them into
`MetaSonic.Session.Queue`.

The v1 contract should:

1. Use `fromPatternEvent` as the only event-to-command translation.
2. Attach `ProducerId ProducerPattern name` to every enqueued command.
3. Preserve `expandPattern` order within each produced block.
4. Preserve sample-position and original `PatternEvent` metadata in
   the enqueue report for diagnostics.
5. Stop on the first full-queue rejection.
6. Store the rejected event plus the remaining not-yet-enqueued events
   as producer backlog.
7. Retry backlog before generating a new pattern range.
8. Never silently drop, coalesce, or reorder pattern events.
9. Keep thread creation, clocks, block callbacks, and background drain
   loops out of scope.

The goal is to give Prep G's queue one real producer while keeping the surface
pure and deterministic. Pattern is the cheapest first bridge because
`MetaSonic.Pattern` already has deterministic `expandPattern` and Prep A already
has `fromPatternEvent`.

## Why Pattern Comes First

Prep G introduced the producer queue:

    newSessionCommandQueue
      :: SessionQueueOptions
      -> Either SessionQueueSetupIssue SessionCommandQueue

    enqueueSessionCommand
      :: ProducerId
      -> SessionCommand
      -> SessionCommandQueue
      -> (SessionCommandQueue, SessionEnqueueResult)

    drainSessionCommandQueue
      :: SessionOwner
      -> SessionCommandQueue
      -> IO (SessionCommandQueue, SessionDrainResult)

That queue pins ordering and backpressure but has no concrete producer.

Pattern is the right first producer because:

- `PatternEvent` is already the symbolic producer vocabulary from
  Phase 6.A.
- `fromPatternEvent` already maps every `PatternEvent` constructor into
  the shared `SessionCommand` vocabulary.
- `expandPattern` is pure and deterministic for a `SampleRange`.
- The pattern corpus already tests event order, voice lifecycle, and
  control-target feasibility.
- No socket, MIDI port, thread, clock, or callback lifetime is needed
  to validate the bridge.

OSC and MIDI should wait. They add external IO, listener lifetime, threading,
and backpressure surfaces that are easier to reason about after one pure
producer has exercised the queue contract.

Preserving hot-swap should also wait. It has a different failure surface:
active-voice migration, slot preservation, resolve-state rebuild, and
failed-install recovery. Prep H should not mix that work with producer ingress.

## Recap: Existing Contracts Used Here

`MetaSonic.Pattern` provides:

    data Pattern = Pattern
      { patternTemplates :: !TemplateGraph
      , patternEvents    :: SampleRange -> [(SamplePos, PatternEvent)]
      }

    expandPattern :: Pattern -> SampleRange -> [(SamplePos, PatternEvent)]

    data PatternEvent
      = PEVoiceOn      !TemplateName !VoiceKey ![(ControlTag, Value)]
      | PEVoiceOff     !VoiceKey
      | PEControlWrite !VoiceKey !ControlTag !Value
      | PEHotSwap      !SwapLabel !TemplateGraph

`MetaSonic.Session.Command` provides:

    fromPatternEvent :: PatternEvent -> SessionCommand

`MetaSonic.Session.Queue` provides:

    data ProducerKind = ProducerPattern | ...

    data ProducerId = ProducerId
      { producerKind :: !ProducerKind
      , producerName :: !Text
      }

    enqueueSessionCommand
      :: ProducerId
      -> SessionCommand
      -> SessionCommandQueue
      -> (SessionCommandQueue, SessionEnqueueResult)

Prep H should depend on those contracts rather than introducing a
parallel event grammar.

## Proposed Module

Add:

    MetaSonic.Session.PatternProducer

Suggested public surface:

    data PatternProducerOptions = PatternProducerOptions
      { ppoProducerName :: !Text
      , ppoBlockFrames  :: !Int
      }

    defaultPatternProducerOptions :: PatternProducerOptions

    data PatternProducerState

    data PatternProducerIssue
      = PpiInvalidBlockFrames !Int

    data PatternEnqueueItem = PatternEnqueueItem
      { peiSamplePos :: !SamplePos
      , peiEvent     :: !PatternEvent
      , peiCommand   :: !SessionCommand
      , peiResult    :: !SessionEnqueueResult
      }

    data PatternEnqueueResult = PatternEnqueueResult
      { perItems      :: ![PatternEnqueueItem]
      , perBacklogged :: !Int
      , perNextStart  :: !SamplePos
      }

    data PatternEnqueueOutcome = PatternEnqueueOutcome
      { peoState  :: !PatternProducerState
      , peoQueue  :: !SessionCommandQueue
      , peoResult :: !PatternEnqueueResult
      }

    newPatternProducerState
      :: PatternProducerOptions
      -> Either PatternProducerIssue PatternProducerState

    enqueuePatternBlock
      :: Pattern
      -> PatternProducerState
      -> SessionCommandQueue
      -> PatternEnqueueOutcome

    isBacklogged
      :: PatternProducerState
      -> Bool

The exact names can change during implementation, but the shape should
stay narrow: a hidden producer state, one block/range enqueue function,
explicit result rows, and no owner or runtime dependency.

Returning a named outcome record rather than a 3-tuple keeps call sites
readable once a future scripted runner composes producer, queue, and
drain in one loop. The cost is one extra type definition; the
ergonomics pay off the first time a caller binds the three fields.

`defaultPatternProducerOptions` should use:

    ppoProducerName = "pattern"

The default block size only needs to be positive and conservative for
tests/demos. Production callers with a real timing model should choose
`ppoBlockFrames` explicitly.

`peiCommand` and the command embedded inside `peiResult`
(`SessionEnqueued`'s `QueuedSessionCommand` or `SessionEnqueueRejected`'s
`SessionCommand` argument) carry the same value. This duplication is
intentional: callers that only need the command for logs do not have to
destructure the result, and a future change to either side does not
silently drift.

## Producer State Model

`PatternProducerState` should be pure and hidden.

The v1 internal state should track:

- the next sample position to generate from the `Pattern`;
- the configured `ProducerId`;
- the block size in frames;
- a backlog of `(SamplePos, PatternEvent)` entries that were generated
  but not accepted by the queue because enqueue stopped on a full
  queue.

The initial state starts at `SamplePos 0` with an empty backlog.

Backlog is bounded by at most one expanded block. The §Cursor And
Backlog Invariant ensures a new range is only generated when backlog
is empty, so the producer never accumulates more events than one
`ppoBlockFrames` range produced. Prolonged queue pressure pauses the
producer; it does not grow backlog without bound.

For a fixed `Pattern`, a fixed initial `PatternProducerState`, and a
fixed `SessionCommandQueue`, `enqueuePatternBlock` is deterministic.
Tests can rely on this without seeding randomness; `expandPattern` is
pure and the producer state has no internal nondeterminism.

`ppoBlockFrames` must be positive. Invalid block size is a setup issue:

    PpiInvalidBlockFrames n

Do not represent invalid block size as an enqueue result. That follows
the setup-vs-runtime issue discipline from Prep E, Prep F, and Prep G.

## Enqueue Semantics

`enqueuePatternBlock pattern state queue` is caller-driven and
synchronous. It does not create a thread and does not drain the queue.

The function should:

1. If the producer has backlog, try to enqueue backlog first.
2. If the call started with backlog, stop after retrying that backlog,
   even if the backlog fully drains. New range generation waits for the
   next `enqueuePatternBlock` call.
3. If the call started with empty backlog, generate the next range:

       [nextStart, nextStart + ppoBlockFrames)

   using `expandPattern`.
4. Convert each `PatternEvent` to `SessionCommand` using
   `fromPatternEvent`.
5. Enqueue with:

       ProducerId ProducerPattern ppoProducerName

6. Append one `PatternEnqueueItem` per attempted event to the report.
7. Continue while enqueue succeeds.
8. Stop immediately on the first `SessionEnqueueRejected`.
9. Store the rejected event and all remaining not-yet-attempted events
   as backlog.

The returned queue is whatever `enqueueSessionCommand` returned for the
last attempted event. On rejection this is the unchanged full queue, as
defined by Prep G.

Rejected and backlogged events do not consume queue sequence numbers.
This is inherited from `enqueueSessionCommand`, but Prep H should test
the interaction because a producer backlog bug could otherwise skip or
duplicate command sequence numbers.

Across consecutive `enqueuePatternBlock` calls, retried backlog events
appear before any newly generated range. Combined with the cursor's
once-per-range advance, the producer emits one contiguous
sample-position-ordered stream regardless of how many backpressure
pauses occurred along the way.

A call must not mix backlog recovery with new range generation. This
keeps the producer observable as one of two modes per call: retry
existing backlog, or generate one fresh time range. A future scripted
runner can call the function again immediately after backlog clears if
it wants to fill remaining queue capacity.

`perNextStart` is the producer's cursor after the call. It is exposed
for caller observability without leaking the hidden state: callers can
log progress, decide when to stop calling, or pair `perNextStart` with
the `Pattern`'s known end-of-events sample position to detect
exhaustion.

`isBacklogged` exposes the one scheduling-relevant bit of hidden
producer state without exposing backlog contents. A caller-driven runner
can use it to know whether the next enqueue call will retry existing
events instead of generating a fresh range.

## Cursor And Backlog Invariant

The bridge must not lose or duplicate events across full-queue retries.

The invariant:

- generated events are either accepted into the queue or retained for
  later retry in backlog;
- the event that caused a full-queue rejection is both reported in
  `perItems` and retained in backlog, so reporting it does not consume
  or drop it;
- backlog is always retried before a new pattern range is generated;
- a new range is generated only when backlog is empty;
- the next-start cursor advances once per generated range, not once per
  successful enqueue.

That last point is important. If a block range is generated and enqueue
stops halfway through, the producer must remember the remainder as
backlog. It must not regenerate the same range on the next call. The
cursor has already advanced to the next range when the original range
was generated; later backlog retry calls must not advance it again.

## Time Model

Prep H does not define a realtime clock.

`ppoBlockFrames` is a deterministic block-size parameter for expanding
one `SampleRange` per call. It is not tied to the audio callback, host
buffer size, or wall-clock time.

The `SamplePos` attached to each `PatternEnqueueItem` is diagnostic
metadata and preserves the original event position. `SessionCommand`
does not carry sample time; the existing session owner executes drained
commands synchronously when the caller chooses to drain the queue.

A later live-pattern runner can decide when to call
`enqueuePatternBlock` and when to drain. That later runner owns clock
alignment, lookahead, latency, and end-of-pattern behavior.

## Hot-Swap Events

`PEHotSwap` maps through `fromPatternEvent` to `CmdHotSwap`.

Prep H should not add special hot-swap handling. At the Prep H slice,
runtime policy was still owned by Prep E/F:

- empty-session and drop-all constrained installs can commit;
- swaps that would preserve live voices were rejected by the real
  adapter as non-terminal runtime failures until the later preserving
  path landed;
- failed installs can make the owner diverge.

Pattern producer backlog must treat `PEHotSwap` like any other event:
it may enqueue, be rejected by a full queue, or remain backlogged. The
producer bridge does not inspect graph contents.

## Backpressure Policy

Full queue means explicit stop and backlog.

Do not:

- drop old events;
- drop the newly rejected event;
- coalesce control writes;
- let hot-swap bypass the queue;
- prioritize voice-off over voice-on;
- skip ahead to newer pattern ranges.

Those policies may become useful later, but they would change ordering
semantics and need their own design and tests. V1 should preserve the
Pattern event stream exactly.

## State And Threading Model

The producer bridge is pure.

It does not enforce thread safety. A future concrete fan-in layer may
wrap `PatternProducerState` and `SessionCommandQueue` in `MVar`, `STM`,
or another owner-specific serialization mechanism. Prep H should not
choose that mechanism.

The bridge also does not call `stepSessionOwner` directly. The intended
composition remains:

    Pattern -> PatternProducer -> SessionCommandQueue -> SessionOwner

This keeps producer generation, queueing/backpressure, and runtime
execution independently testable.

## Event Semantics

Prep H should not widen `SessionEvent`.

`PatternEnqueueResult` is enough for this slice:

- each attempted sample position;
- each original `PatternEvent`;
- the translated `SessionCommand`;
- the enqueue result;
- the number of pending backlogged events after the call.

Future producer-facing event work can translate `PatternEnqueueResult`
and `SessionDrainResult` into a broader event stream after a concrete
runner exists.

## Non-Goals

Session Prep H must not add:

- OSC, MIDI, or UI adapters;
- a thread-safe queue wrapper;
- a background drain loop;
- a realtime clock;
- audio callback scheduling;
- latency/lookahead policy;
- event coalescing;
- per-producer priority;
- preserving hot-swap;
- manifest reload;
- recovery after terminal owner divergence;
- new C ABI or C++ code.

## Implementation Series

Recommended commit shape:

1. **Decision note.** Land this note after review.
2. **Pattern producer type surface.** Add
   `MetaSonic.Session.PatternProducer`, options, hidden state,
   setup issue, enqueue item/result types, and module export in
   `package.yaml`.
3. **Pattern producer state construction.** Add
   `defaultPatternProducerOptions` and `newPatternProducerState`.
   Validate positive block size and initialize cursor/backlog.
4. **Pattern block enqueue.** Implement backlog-first enqueue,
   range expansion through `expandPattern`, translation through
   `fromPatternEvent`, full-queue stop, and backlog retention.
5. **Tests.** Pin:
   - default options use a positive block size and a Pattern producer
     identity;
   - invalid block size rejects at construction;
   - empty block advances cursor and enqueues nothing;
   - first `droneVibrato` block enqueues the expected `PEVoiceOn` as
     `CmdVoiceOn`;
   - same-sample corpus events preserve order;
   - every `PatternEvent` constructor maps through `fromPatternEvent`;
   - full queue stops at the first rejected event;
   - rejected event plus remaining generated events become backlog;
  - next call retries backlog before generating a new range —
    structurally verified by asserting that `perNextStart` is identical
    between a partial-rejection call and the immediately following
    backlog-retry call, `perBacklogged` decreases on the retry, and no
    newly generated range appears in the retry call's `perItems`;
   - rejected/backlogged events do not consume queue sequence numbers;
   - producer identity is `ProducerPattern` and preserves the
     configured producer name;
   - across two consecutive calls (one partial-backlog, one drain +
     retry), `perItems` from both calls in order forms one contiguous
     sample-position-ordered stream;
   - integration smoke: Pattern producer enqueue ->
     `drainSessionCommandQueue` -> `SessionOwner` commits one real
     voice.
6. **Roadmap sync.** Mark only Pattern producer bridge v1 as landed.
   Keep OSC/MIDI/UI adapters, thread-safe fan-in, background drain
   loops, preserving hot-swap, and recovery semantics gated.

## Verification

Minimum verification after implementation:

    just stack-test

No C++ verification is required unless the implementation changes C++
sources, headers, package C++ source lists, or the C ABI. Prep H should
be Haskell-only.

## Next Slice After Prep H

After Prep H, choose one of:

1. **Single-threaded scripted session runner.** Compose
   `PatternProducerState`, `SessionCommandQueue`, and `SessionOwner`
   into an explicit caller-driven offline/demo loop. This still should
   not add threads.
2. **Concrete OSC or MIDI producer bridge.** Use the Pattern bridge as
   the reference for producer identity, backpressure, and result
   reporting, then add one IO-facing adapter.
3. **Preserving hot-swap decision note.** Scope active-voice migration,
   slot preservation, resolve-state rebuild, failed-install recovery,
   and what it means for queued stale commands.

Do not combine these. A runner, an IO producer, and preserving hot-swap
each have different ownership and failure surfaces.
