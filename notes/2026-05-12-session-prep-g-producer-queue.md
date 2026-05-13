# Session Prep G - Producer Queue And Arbitration Contract

Date: 2026-05-12

Status: draft decision artifact for review. This slice scopes the first
producer-ingress contract in front of the Prep F single-threaded
runtime owner. It is still not a concrete OSC, MIDI, Pattern, or UI
adapter, and it is not an audio-thread queue.

## Decision

Add a small Haskell-only bounded FIFO ingress layer for
`SessionCommand`s before they reach `stepSessionOwner`.

The v1 contract should:

1. Attach producer identity and a queue sequence number to every
   accepted command.
2. Preserve FIFO drain order across all producers.
3. Reject enqueue attempts explicitly when the queue is full.
4. Never silently drop or coalesce commands.
5. Drain commands into one `SessionOwner` by calling
   `stepSessionOwner` synchronously.
6. Stop draining when the owner reports a terminal divergence.
7. Surface structured per-command drain outcomes for logs, tests, and
   future producer feedback.
8. Keep concrete OSC/MIDI/Pattern/UI adapters out of scope.
9. Keep thread creation, STM, worker loops, and audio-thread queueing
   out of scope.

The goal is to make command ordering and backpressure explicit before
adding any real producer fan-in. Prep F made one owner; Prep G defines
how multiple logical producers will eventually target that owner without
inventing per-producer mutation paths.

## Why This Comes After Prep F

Prep F created the first scoped owner:

    withSessionOwner
      :: TemplateGraph
      -> SessionOwnerOptions
      -> (SessionOwner -> IO a)
      -> IO (Either SessionAdapterSetupIssue a)

    stepSessionOwner
      :: SessionOwner
      -> SessionCommand
      -> IO SessionOwnerStepResult

That owner is intentionally single-threaded. The source contract says
concurrent `stepSessionOwner` calls race on private `IORef`s and that
callers must serialize access.

Before wiring OSC, MIDI, Pattern, or UI directly to the owner, the
project needs a small arbitration contract:

- which command runs first when multiple producers submit commands;
- what happens when producers submit commands faster than the owner can
  drain them;
- how a terminal owner divergence is reported to later producers;
- whether producer identity survives into diagnostics;
- whether failed/admission-rejected commands consume ordering slots.

Those are session-layer questions, not audio-runtime questions. They
should be answered in Haskell before adding host-specific listeners or
threads.

## Recap: What Prep A-F Already Landed

Prep A added:

- `MetaSonic.Session.Command`: producer-agnostic `SessionCommand`,
  `SessionEvent`, `SessionIssue`, and `fromPatternEvent`;
- `MetaSonic.Session.Resolve`: pure `ResolveState` rebuild across graph
  replacement;
- `MetaSonic.Session.Report`: read-only lifecycle report shapes and
  readers.

Prep B added pure session state and admission:

    initialSessionState  :: TemplateGraph -> SessionState
    admitSessionCommand  :: SessionCommand -> SessionState -> SessionAdmissionResult
    applySessionCommit   :: SessionCommit -> SessionState -> SessionState
    commitGraphInstalled :: SwapLabel -> TemplateGraph -> SessionState
                         -> (SessionState, ResolveRebuildResult)

Prep C added checked plan/commit pairing:

    applyPlannedCommit
      :: SessionPlan
      -> SessionCommit
      -> SessionState
      -> Either SessionCommitIssue (SessionState, Maybe ResolveRebuildResult)

Prep D added the injected runtime adapter and single-step shell:

    stepSessionCommand
      :: Monad m
      => SessionRuntimeAdapter m
      -> SessionCommand
      -> SessionState
      -> m SessionStepResult

Prep E added the first real `RTGraph` adapter:

    newRTGraphAdapter
      :: Ptr RTGraph
      -> TemplateGraph
      -> RTGraphAdapterOptions
      -> IO (Either SessionAdapterSetupIssue (SessionRuntimeAdapter IO))

Prep F added the first owner around that adapter:

    withSessionOwner
      :: TemplateGraph
      -> SessionOwnerOptions
      -> (SessionOwner -> IO a)
      -> IO (Either SessionAdapterSetupIssue a)

    stepSessionOwner
      :: SessionOwner
      -> SessionCommand
      -> IO SessionOwnerStepResult

Prep G should not replace those contracts. It should sit above
`stepSessionOwner` and define owner-ingress ordering.

## Proposed Module

Add:

    MetaSonic.Session.Queue

Suggested public surface:

    data ProducerKind
      = ProducerPattern
      | ProducerOSC
      | ProducerMIDI
      | ProducerUI
      | ProducerTest

    data ProducerId = ProducerId
      { producerKind :: !ProducerKind
      , producerName :: !Text
      }

    data QueuedSessionCommand = QueuedSessionCommand
      { qscSequence :: !CommandSequence
      , qscProducer :: !ProducerId
      , qscCommand  :: !SessionCommand
      }

    newtype CommandSequence = CommandSequence Word64

    data SessionCommandQueue

    data SessionQueueOptions = SessionQueueOptions
      { sqoCapacity :: !Int
      }

    defaultSessionQueueOptions :: SessionQueueOptions

    data SessionQueueSetupIssue
      = SqsiInvalidCapacity !Int

    data SessionEnqueueIssue
      = SeiQueueFull !Int

    data SessionEnqueueResult
      = SessionEnqueued !QueuedSessionCommand
      | SessionEnqueueRejected !ProducerId !SessionCommand !SessionEnqueueIssue

    data SessionDrainItem = SessionDrainItem
      { sdiQueued :: !QueuedSessionCommand
      , sdiResult :: !SessionOwnerStepResult
      }

    data SessionDrainResult = SessionDrainResult
      { sdrItems     :: ![SessionDrainItem]
      , sdrRemaining :: !Int
      , sdrStopped   :: !(Maybe SessionOwnerDivergence)
      }

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

The exact names can change during implementation, but the structure
should stay narrow: a bounded queue, typed producer identity, explicit
enqueue rejection, and a drain result that preserves every owner step
result.

## Queue Model

The queue is bounded FIFO.

`newSessionCommandQueue` validates capacity. Capacity must be positive.
The default should be conservative and test/demo oriented, for example
`128`; callers with known producer rates should choose explicitly.
Invalid capacity is a setup failure (`SessionQueueSetupIssue`), not an
enqueue failure.

Sequence numbers are per queue. They start at 0 at queue construction
and are not globally unique across queue lifetimes. If a future
multi-owner deployment needs globally unique diagnostics, it can add a
queue id without changing per-queue ordering semantics.

`enqueueSessionCommand`:

1. Receives a `ProducerId`, `SessionCommand`, and queue state.
2. If the queue length is already equal to capacity, returns
   `SessionEnqueueRejected producer command (SeiQueueFull capacity)`
   and leaves queue state unchanged.
3. Otherwise assigns the next monotonically increasing
   `CommandSequence`, appends the command to the tail, and returns
   `SessionEnqueued queuedCommand`.

Rejected commands do not consume sequence numbers.

`enqueueSessionCommand` returns the queue unconditionally because an
enqueue rejection does not invalidate it. On rejection, the returned
queue is unchanged. Callers continue threading the returned queue and
inspect `SessionEnqueueResult` separately; an outer `Either` would make
ordinary queue threading noisier without improving the contract.

The queue should not inspect `SessionCommand` for admission validity.
Admission still belongs to Prep B/D/F and happens only when the command
drains into the owner. This keeps enqueue cheap and producer-neutral.

## Drain Model

`drainSessionCommandQueue owner queue` is caller-driven and synchronous.
It is not a background worker.

For each queued item in FIFO order:

1. Call `stepSessionOwner owner (qscCommand item)`.
2. Append `SessionDrainItem item result` to the drain report.
3. If the result is `SessionOwnerDivergedNow _ reason`, stop draining
   immediately.
4. If the result is `SessionOwnerBlocked reason`, stop draining
   immediately.
5. Otherwise continue.

Commands already drained are removed from the returned queue. Commands
not yet drained remain in the returned queue in their original order.

`sdrStopped` is `Just reason` if the drain stopped because the owner
diverged during this drain or because the owner was already blocked.
It is `Nothing` only when the drain reaches the end of the queue without
encountering divergence or blocking.

Stopping on divergence is important. Once the owner is terminally
diverged, later commands must not keep producing repeated runtime calls
or misleading failure reports. The caller can inspect `sdrStopped` and
decide whether to discard the remaining commands, report them as
blocked, or preserve them for a future owner after explicit recovery
work exists.

The drain is unbounded in v1. A future concrete producer-loop slice can
add a bounded drain helper, for example a max-items parameter, without
breaking v1 callers; the current helper is the "drain everything"
variant.

## Producer Identity

Producer identity is diagnostic metadata, not authorization.

V1 should not add per-producer priorities, permissions, or independent
queues. All producers enter one FIFO stream. The identity survives so
future logs and events can say which producer submitted a command:

- pattern scheduler;
- OSC listener;
- MIDI bridge;
- UI interaction;
- test harness.

`ProducerKind` is a closed enum in v1. A future custom-producer adapter
can add another constructor, or the enum can grow a text-tagged custom
case, once a real external adapter needs it.

`producerName` is free-form diagnostic text. The queue does not validate
or normalize it, and it has no authorization meaning.

This also keeps the later "OSC/MIDI/Pattern arbitration" decision small:
it can map concrete sources onto `ProducerId` without changing the
owner or command vocabulary.

## Backpressure Policy

V1 uses explicit rejection on full queue.

No silent drop. No overwrite-oldest. No priority bypass. No control
coalescing.

This is deliberately conservative. A full queue is a producer-facing
flow-control event, not a session-state mutation. Later slices may add
domain-specific policies such as coalescing high-rate control writes,
but those policies need tests that prove they do not reorder voice
start/stop or hot-swap semantics.

## State And Threading Model

Prep G defines ordering semantics, not thread safety.

The proposed queue type can be a pure data structure. Like
`SessionOwner`, it does not need to enforce multi-threaded producer
serialization in v1. A future concrete producer fan-in layer can wrap
the queue in `MVar`, `TQueue`, `STM`, or another host-specific
mechanism after the semantics are pinned.

This distinction is intentional:

- Prep F owns runtime state but requires serialized calls.
- Prep G defines what serialized ingress means.
- A later concrete fan-in slice can decide how real threads serialize
  against this queue.

Do not add a background drain loop in this slice. A loop introduces
lifetime, exception, cancellation, and shutdown semantics that belong
with long-running session supervision.

## Relationship To Existing Queues

The C++ `rt_graph_realtime_*` queue remains the audio-thread handoff
for concrete runtime operations such as reserve, activate, release, and
control write.

Prep G's queue is above that layer. It queues producer intents
(`SessionCommand`) before admission and runtime execution. It must not
be described as realtime-safe, lock-free, or audio-thread-visible.

The two queues have different jobs:

- producer queue: order producer intents before `stepSessionOwner`;
- realtime ABI queue: transfer already-admitted runtime operations to
  the audio engine.

## Event Semantics

Prep G should not widen `SessionEvent` yet.

The drain result is enough for library callers and tests:

- each queued command;
- its producer identity;
- its owner step result;
- whether the drain stopped because the owner diverged or was already
  blocked.

Future producer-facing event work can translate `SessionDrainResult`
into broader events once concrete OSC/MIDI/UI behavior is known. Avoid
committing to a public event stream before the first real producer
adapter uses it.

## Non-Goals

Session Prep G must not add:

- a C++ session object;
- new C ABI;
- an audio-thread queue;
- a worker thread or background drain loop;
- STM/TQueue/MVar producer fan-in;
- concrete OSC, MIDI, Pattern, or UI adapters;
- control-write coalescing;
- priorities;
- per-producer queues;
- preserving hot-swap;
- manifest reload;
- recovery after terminal owner divergence;
- long-running owner supervision.

## Implementation Series

Recommended commit shape:

1. **Decision note.** Land this note after review.
2. **Queue types and module export.** Add
   `MetaSonic.Session.Queue`, producer identity types, bounded queue
   state, enqueue issue/result types, and drain result types. Add the
   module to `package.yaml`.
3. **Bounded enqueue implementation.** Implement queue construction,
   FIFO enqueue, capacity validation, sequence assignment, and
   explicit full-queue rejection. Keep the structure pure.
4. **Owner drain helper.** Implement `drainSessionCommandQueue` against
   `stepSessionOwner`, removing drained commands and stopping on
   `SessionOwnerDivergedNow` or `SessionOwnerBlocked`.
5. **Tests.** Pin:
   - default options are positive and conservative;
   - invalid capacity rejects;
   - FIFO order across mixed producers;
   - sequence numbers are monotonic and rejected commands do not
     consume them;
   - full queue leaves state unchanged and reports `SeiQueueFull`;
   - drain preserves producer identity in each `SessionDrainItem`;
   - admission rejection drains as a non-terminal owner step;
   - control-write acceptance drains without owner state mutation;
   - divergence-causing command stops the drain and leaves later
     queued commands in order;
   - after a divergence-causing command stops the drain, a mock adapter
     call counter shows the call count equals the number of
     `SessionDrainItem`s, not the number of originally enqueued
     commands;
   - already-diverged owner returns blocked and drains no further
     commands.
6. **Roadmap sync.** Mark only producer queue/ingress semantics landed.
   Keep concrete OSC/MIDI/Pattern fan-in, thread-safe queue wrappers,
   background drain loops, preserving hot-swap, manifest reload, and
   recovery semantics gated.

## Verification

Minimum verification after implementation:

    just stack-test

No C++ verification is required unless the implementation changes C++
sources, headers, package C++ source lists, or the C ABI. Prep G should
be Haskell-only and should reuse the Prep F owner and existing Prep E
adapter.

## Next Slice After Prep G

After Prep G, there are two defensible next directions:

1. **Concrete producer bridge.** Pick one real producer path, probably
   Pattern first because `fromPatternEvent` already exists, and map it
   into the queue with producer identity and explicit backpressure.
2. **Preserving hot-swap decision.** With owner and queue semantics in
   place, scope active-voice migration, resolve-state rebuild, slot
   preservation, and failed-install recovery.

Do not do both in one slice. Concrete producer fan-in and preserving
hot-swap have different failure surfaces and different tests.
