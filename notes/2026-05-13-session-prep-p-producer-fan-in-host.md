# Session Prep P - Producer Fan-In Host

Date: 2026-05-13

Status: implemented generic command fan-in host. At Prep P, this slice
did not add concrete OSC/MIDI/UI protocol adapters, did not spawn a
background worker, did not define wall-clock scheduling, and did not
add a new audio-thread queue. Later follow-ups added the OSC
control-write producer/listener path, the scoped fan-in drain service,
and the first already-decoded MIDI note/CC producer adapter.

Prep G defined the bounded FIFO producer queue. Prep J proved a
serialized host shape for Pattern by hiding one owner plus producer and
queue state behind an `MVar`. Prep O made preserving hot-swap stable in
both stopped-audio and audio-running paths. Prep P is the first generic
fan-in boundary above those pieces.

## Decision

Add `MetaSonic.Session.FanIn` with one scoped host:

    withSessionFanInHost
      :: TemplateGraph
      -> SessionFanInOptions
      -> (SessionFanInHost -> IO a)
      -> IO (Either SessionFanInSetupIssue a)

The host owns:

- one scoped `SessionOwner`;
- one `SessionCommandQueue`;
- one `MVar` protecting queue state and every drain into the owner.

The public operations are:

    enqueueSessionFanInCommand
      :: ProducerId
      -> SessionCommand
      -> SessionFanInHost
      -> IO SessionFanInEnqueueResult

    drainSessionFanInHost
      :: SessionFanInHost
      -> IO SessionFanInDrainResult

    readSessionFanInHost
      :: SessionFanInHost
      -> IO SessionFanInSnapshot

Concrete producers now have a stable command target: translate their
protocol input into a `SessionCommand`, attach a `ProducerId`, enqueue
through the host, and let a caller or future worker decide when to
drain.

## Semantics

`enqueueSessionFanInCommand` takes the host lock, calls
`enqueueSessionCommand`, stores the returned queue, and reports both the
queue result and the new queue depth. Queue-full rejection is still
producer-visible and does not mutate the queue.

`drainSessionFanInHost` takes the same lock, calls
`drainSessionCommandQueue`, stores the returned queue, and reports the
drain result plus the remaining queue depth. The lock covers the whole
drain, including any preserving hot-swap publish/wait/collect/commit
sequence reached by `stepSessionOwner`.

Because the same lock also gates producer enqueue, producers can see
high enqueue latency while a slow drain runs. The worst v1 case is a
preserving hot-swap waiting up to `raoHotSwapInstallTimeoutMs` for the
audio thread to install the published swap. At Prep P, a later
background drain service or producer-side worker was the path to
bounding enqueue latency. The first scoped version of that follow-up is
recorded in
[Session Fan-In Drain Service](2026-05-13-session-fan-in-drain-service.md).

`readSessionFanInHost` takes the lock and returns queue depth, owner
state, and owner status. The raw queue and raw owner stay hidden.

The host lock is still not a transaction boundary. If an exception
escapes during a drain, `modifyMVar` can restore the Haskell queue
value but cannot roll back owner writes or C-runtime side effects that
already happened. This inherits the Prep F/J exception surface.

## Relation To Existing Pattern Host

`PatternSessionHost` remains useful because it owns
`PatternProducerState` and its deterministic cursor/backlog behavior.
`SessionFanInHost` is lower-level: it accepts already-formed
`SessionCommand`s from any producer identity.

A later slice can decide whether to route Pattern through the generic
fan-in host or keep the Pattern-specific host for caller-driven demos.
Prep P does not force that consolidation.

## Prep P Out Of Scope

- At this slice, OSC path parsing to `SessionCommand`; later covered
  for symbolic control writes by `MetaSonic.Session.OSCProducer` and
  `MetaSonic.Session.OSCListener`.
- At this slice, MIDI note/CC translation to `SessionCommand`; later
  covered for already-decoded note-on/off and CC events by
  `MetaSonic.Session.MIDIProducer`.
- UI command adapters.
- Background drain loops or lifecycle supervision.
- Cross-producer arbitration beyond the existing FIFO queue order.
- Producer-specific throttling, coalescing, or authorization.
- Repair/recovery after terminal owner divergence.

## Tests

The Prep P tests pin:

1. FIFO drain order across OSC and MIDI producer identities;
2. bounded queue rejection through the host;
3. concurrent producer enqueues receiving serialized sequence numbers;
4. divergence during drain leaving the unprocessed tail queued and the
   owner marked diverged.
