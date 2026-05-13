# Session Prep J - Thread-Safe Pattern Host

Date: 2026-05-13

Status: draft decision artifact. This slice adds the first serialized
host boundary above Prep F/G/H/I. It is still not a background session
service, concrete OSC/MIDI/UI producer adapter, realtime command queue,
or preserving hot-swap implementation.

## Decision

Add `MetaSonic.Session.Host`. Export one scoped Pattern host:

    withPatternSessionHost
      :: TemplateGraph
      -> PatternSessionHostOptions
      -> (PatternSessionHost -> IO a)
      -> IO (Either PatternSessionHostSetupIssue a)

and two synchronous operations:

    stepPatternSessionHost
      :: Pattern
      -> PatternSessionHost
      -> IO PatternRunnerStepResult

    readPatternSessionHost
      :: PatternSessionHost
      -> IO PatternSessionHostSnapshot

The host owns:

- a scoped `SessionOwner`;
- one `PatternProducerState`;
- one `SessionCommandQueue`;
- one `MVar` protecting the producer/queue state and every owner step
  reached through this host.

The v1 contract is deliberately small:

1. Validate Pattern producer and queue options before allocating the
   runtime owner.
2. Allocate the runtime owner with `withSessionOwner`.
3. Hide the owner and mutable state behind `PatternSessionHost`.
4. Run each `stepPatternSessionHost` as one whole Prep I runner step
   under the host lock.
5. Carry the returned producer and queue state forward internally.
6. Expose a snapshot that reads backlog, owner state, and owner status
   while holding the same lock.
7. Do not spawn a thread, create a clock, add a background drain loop,
   or choose OSC/MIDI/UI arbitration policy.

## Why This Slice Now

Prep F explicitly says `SessionOwner` is single-threaded and callers
must serialize access. Prep G and Prep H deliberately kept the queue
and Pattern producer pure so their ordering/backpressure semantics
could be tested before choosing a concurrency primitive. Prep I then
proved the producer/queue/owner composition as a caller-driven step.

Prep J chooses the smallest serialization mechanism that composes those
contracts: an `MVar` around the existing state and owner path. This
answers the immediate ownership question for Haskell callers without
turning the project into a long-running session supervisor.

This is the point where concrete producers can start sharing a single
host safely, but the concrete adapters remain separate slices. The
host defines the lock boundary first; OSC/MIDI/UI can later decide how
they submit work through it.

## Setup Surface

`PatternSessionHostOptions` groups the already-landed option records:

    data PatternSessionHostOptions = PatternSessionHostOptions
      { pshoProducerOptions :: !PatternProducerOptions
      , pshoQueueOptions    :: !SessionQueueOptions
      , pshoOwnerOptions    :: !SessionOwnerOptions
      }

Setup failures preserve their source:

    data PatternSessionHostSetupIssue
      = PshsiPatternProducer !PatternProducerIssue
      | PshsiQueue !SessionQueueSetupIssue
      | PshsiOwner !SessionAdapterSetupIssue

This keeps producer/queue validation distinct from runtime owner
construction. It also avoids allocating an `RTGraph` for option errors
that can be rejected purely.

## Step Semantics

`stepPatternSessionHost pat host` is exactly:

1. take the host lock;
2. call `stepPatternSession pat producer queue owner`;
3. store `prsState` and `prsQueue` back into the host;
4. release the lock and return the unchanged `PatternRunnerStepResult`.

Concurrent callers therefore observe a serialized sequence of whole
runner steps. They cannot race `PatternProducerState`, cannot interleave
queue updates, and cannot call the hidden `SessionOwner` outside the
host lock.

The returned report remains the Prep I report. Backlog is still visible
through `prsEnqueue` and `isBacklogged (prsState r)`. The host snapshot
adds a lock-protected read side for callers that want current backlog,
owner state, and owner status after several hosted steps.

## Out Of Scope

- Background worker or drain loop.
- Wall-clock scheduling.
- OSC/MIDI/UI listener integration.
- Cross-producer arbitration beyond the existing FIFO queue order.
- Realtime C ABI queue changes.
- Preserving hot-swap or failed-install recovery.
- Returning or exposing the raw `SessionOwner`.

## Testing

The Prep J tests pin:

1. construction failures from producer options, queue options, and owner
   setup;
2. one hosted Pattern step committing a voice and exposing a ready
   snapshot;
3. backlog carry across repeated hosted calls without caller-owned
   producer/queue state;
4. two concurrent Haskell callers sharing one host and observing
   serialized Pattern cursors plus coherent owner state.
