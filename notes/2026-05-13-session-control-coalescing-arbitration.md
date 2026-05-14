# Session Control Coalescing And Arbitration

Status: MIDI listener-local coalescing landed. The shared queue and
fan-in service remain strict FIFO; OSC, UI, and Pattern coalescing are
still design-only. Cross-producer ownership and takeover policy is
tracked separately in
[Session Producer Coexistence And Arbitration](2026-05-14-session-producer-coexistence-arbitration.md).

The session fan-in path now has real high-rate control producers:
OSC symbolic control writes, MIDI CC, MIDI pitch-bend, UI control
writes, and future Pattern automation can all target the same bounded
FIFO queue. That makes queue pressure an operational risk, but the
fan-in queue is the load-bearing contract across the producer family:
if enqueue succeeds, the drained stream contains that command in FIFO
order. Coalescing belongs at producer worker boundaries, before fan-in,
so `MetaSonic.Session.Queue` and `MetaSonic.Session.FanIn` can remain
strict FIFO.

## Current Contract

- `MetaSonic.Session.Queue` is FIFO. It assigns sequence numbers on
  enqueue, rejects full queues explicitly, and never silently drops,
  coalesces, or reorders commands.
- `MetaSonic.Session.FanIn` serializes enqueue/drain access around that
  queue and inherits the same FIFO semantics.
- Producer adapters preserve their own state on enqueue failure, so a
  full queue is observable backpressure rather than an implicit
  producer-side drop.
- A shared queue-level coalescer would make successful enqueue
  ambiguous: a command could be accepted but later disappear into a
  merged value. That would invalidate the existing fan-in tests and
  producer rollback assumptions.
- Some existing producer behavior depends on FIFO order. In particular,
  MIDI sustained retriggers emit `CmdVoiceOff` followed by `CmdVoiceOn`
  with the same `VoiceKey`; correctness depends on the owner applying
  both commands in order.

## Command Classes

Every command except `CmdControlWrite` is a fence:

- `CmdVoiceOn`
- `CmdVoiceOff`
- `CmdHotSwap`

Voice lifecycle commands and hot-swap commands are not coalescible.
They also force a producer-local flush before the fence command itself
is enqueued. That includes MIDI all-notes-off releases,
sustain-pedal releases, and sustained retrigger stop/start pairs. The
retrigger pair does not need a special carve-out: it contains a
`CmdVoiceOff` followed by a `CmdVoiceOn`, and both commands are fences.

The only coalescing candidate is repeated `CmdControlWrite` to the same
target within one producer worker:

```text
Map (VoiceKey, ControlTag) Value
```

`ProducerId` is implicit because the buffer lives inside exactly one
producer worker. Diagnostics can still report the producer identity, but
the merge boundary is the producer, not a shared global table.

For those writes, last-write-wins can be musically acceptable for
continuous controls such as MIDI CC, pitch-bend, OSC sliders, and UI
sliders. That rule is not automatically safe across producers, because
OSC, MIDI, UI, and Pattern may represent different user intents even
when they hit the same control target.

## Producer-Local Shape

The safe shape is:

```text
producer decode -> producer-local coalesce buffer -> flush -> fan-in FIFO -> drain
```

The producer-local buffer is:

```text
Map (VoiceKey, ControlTag) Value
```

The rules are:

- `CmdControlWrite vk ct v` updates pending state with
  `insert (vk, ct) v pending`.
- Updating an already-pending key increments the producer-local
  coalesced counter.
- Any non-`CmdControlWrite` command is a fence. The producer worker
  flushes pending control writes in deterministic key order, enqueues
  the fence command, then continues.
- If a fence-triggered flush is rejected, the fence command is not
  submitted; a source that needs it must retry with a later event. The
  producer worker must surface that drop explicitly, preserve the
  pending controls, and keep producer state at the pre-fence value.
- The fan-in queue does not learn about coalescing, barriers, or
  producer-specific policy. It remains a strict FIFO of commands that
  producers actually submit.
- Cross-producer ordering remains whatever the existing fan-in FIFO
  observes from separate enqueue calls; no producer can coalesce another
  producer's command.
- Keep Pattern events non-coalesced by default. Pattern timing is
  authored data, not just controller noise.

This keeps the first policy narrow: it reduces repeated writes from one
source while preserving every existing fan-in and queue invariant.

The MIDI listener v1 uses a hybrid cadence: fence flushes,
EOF/teardown flushes, and a conservative 20 ms timed flush by default.
Deterministic tests can disable the timed flush and force the whole
burst to drain at a later fence. Other producers should choose their
cadence from measurement without changing the shared FIFO contract.

The MIDI listener currently holds its listener-state `MVar` while a
pending-control flush submits each command to fan-in. That keeps the
implementation simple and correct, and the smoke-facing diagnostics now
make pressure visible through queue depth, pending count, accepted flush
count, and dropped-fence count. Do not split flush into a two-phase
snapshot/enqueue/update path unless manual smoke or a dedicated
contention benchmark shows this critical section matters.

## Observability

Coalescing must not hide backpressure. Keep producer-local and queue
metrics separate:

Producer-local counters:

- `coalesced_count`: pending control writes overwritten by later values;
- `flushed_count`: coalesced control writes accepted by fan-in;
- `barrier_flush_count`: flushes forced by fence commands.

Queue counters remain unchanged:

- `SeiQueueFull`;
- queue depth snapshots such as `sfisQueueDepth`.

A queue-full rejection means the queue is too small or the consumer is
too slow. A high coalesced/flushed ratio means one producer is emitting
more intermediate control values than the rest of the session can use.
Mixing those signals would obscure both.

## Test Plan

Implementation tests should live at producer-worker or producer-wrapper
level, not by weakening fan-in tests:

- FIFO preservation: emit pending control writes followed by a fence and
  observe flushed control writes before the fence.
- Same-producer same-target control writes collapse to the latest value
  within one flush window, with `coalesced_count == n - 1`.
- Different-target control writes are not collapsed.
- Cross-producer same-target writes are not collapsed; two producers
  still produce two fan-in commands in observed enqueue order.
- Barrier flush: pending control write plus `CmdVoiceOff vk` drains as
  `[CmdControlWrite vk ct v, CmdVoiceOff vk]`.
- Barrier failure: pending control writes that hit queue-full preserve
  pending state and report an explicit dropped-fence issue instead of
  silently swallowing the fence.
- Sustained MIDI retrigger drains as its stop/start pair with no
  coalescing of either fence.
- Queue-full counters and producer-local coalescing counters remain
  distinguishable.

## Measurement Before Implementation

Before extending behavior beyond MIDI, measure whether the current
strict FIFO fills under a realistic high-rate control stream, for
example pitch-bend at 100 Hz across 16 active voices plus normal note
traffic. If the queue does not fill, the right outcome is to keep this
note as the policy record for other producers and defer implementation.
If it does fill, the measurement gives the next coalescer a concrete
throughput target and a regression benchmark.

Current deterministic coverage is separate from that realistic-rate
gate. `Session MIDI producer adapter / pressure probe: high-rate
pitch-bend fills strict FIFO queue` seeds 16 active MIDI notes, sends
nine pitch-bend events through a 128-slot fan-in queue, and observes
144 control-write attempts, 128 `SessionEnqueued` results, 16
`SeiQueueFull 128` rejections, and 128 drained FIFO items. This is a
contract regression for the current no-coalescing saturation behavior,
not a real-hardware throughput claim or a substitute for the
implementation-gating measurement. A later coalescer must keep this
probe passing or replace it with a documented contract change.

That saturation probe showed queue pressure under its no-drain burst
setup, so those counts became the target for the first MIDI
producer-local coalescer:

- Input burst: nine pitch-bend events across 16 active voices.
- Current strict-FIFO output: 144 generated writes, 128 queued writes,
  16 queue-full rejections.
- MIDI listener-local coalesced output for the same burst, with timed
  flush disabled and an all-notes-off fence: 16 flushed writes, one
  latest value per `(VoiceKey, ControlTag)`, and
  `coalesced_count == 128`.

If the later realistic-rate measurement does not produce queue
pressure, defer implementation and leave this note as the policy record
plus saturation regression. If it does produce queue pressure, use the
measured stream and the saturation target above to choose the smallest
flush cadence that reduces queue submissions without weakening fan-in
FIFO or fence semantics.

## Open Questions

- Whether non-MIDI producers should use the MIDI listener's hybrid
  fence/EOF/teardown/timed cadence or a source-specific cadence.
- Whether the MIDI listener's flush path needs a two-phase MVar
  optimization after real contention evidence exists.
- Whether UI sliders should opt into the same producer-local policy as
  MIDI CC/pitch-bend.
- Whether Pattern automation eventually needs an explicit
  authoring-level "continuous control" marker before it can opt in.
- Whether a later owner-aware policy should arbitrate across producers
  only after the
  [Session Producer Coexistence And Arbitration](2026-05-14-session-producer-coexistence-arbitration.md)
  contract is implemented with explicit configuration and diagnostics.
