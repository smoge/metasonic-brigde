# Session Live-Control Rollup

Status: recap of the last live-control session work, covering the local
commit range from `eff1e19` through `41d1d26`. The normative design
contracts remain the focused notes linked below; this file is a
navigation and handoff summary for what changed over the last hours.

## Scope

This session advanced the session layer along three connected tracks:

1. MIDI producer behavior became substantially more complete for live
   keyboard/controller use.
2. MIDI high-rate control handling gained a producer-local coalescing
   layer with observability.
3. Cross-producer coexistence gained an opt-in arbitration boundary and
   explicit service-backed routes for OSC, UI, and Pattern producers.

The queue and fan-in contracts stayed intentionally stable:
`MetaSonic.Session.Queue` remains a strict FIFO, and
`MetaSonic.Session.FanIn` remains the serialized enqueue/drain/snapshot
boundary. Coalescing and arbitration were added above those layers.

## MIDI Producer And Listener

The MIDI producer adapter now covers the live-control cases that were
blocking realistic manual smoke tests:

- all-notes-off reset semantics;
- channel filtering;
- pitch-bend mapping;
- pitch-bend replay when a note starts after the bend is already away
  from center;
- sustain pedal behavior, including deferred releases and retrigger
  ordering;
- manual smoke wording for note-on, note-off, CC 7, sustain, and
  pitch-bend.

Sustain is intentionally part of producer state, not queue state. A
note-off under sustain defers the `CmdVoiceOff`; sustain release flushes
the deferred releases. Retriggers emit `CmdVoiceOff` then `CmdVoiceOn`
with the same `VoiceKey`, which relies on downstream FIFO application
rather than command coalescing.

The detailed MIDI adapter contract lives in:

- [Session MIDI Producer Adapter](2026-05-13-session-midi-producer-adapter.md)
- [Session MIDI Listener](2026-05-13-session-midi-listener.md)

## Control Coalescing

The coalescing decision was kept producer-local. The queue and fan-in
were deliberately not changed to collapse commands.

For MIDI, the listener now owns a small control-write coalescer:

- repeated `CmdControlWrite` values merge by `(VoiceKey, ControlTag)`
  inside the listener worker;
- non-control commands act as fences and flush pending writes before the
  fence command is enqueued;
- timed and teardown flushes keep pending writes from being stranded;
- coalescing stats track overwritten writes, accepted flushes, barrier
  flushes, and pending count;
- dropped fence events caused by flush rejection are surfaced as
  `SmliFenceDroppedForFlushFailure`, not silently hidden.

The deterministic pressure probe deliberately pins the current
no-coalescing saturation contract: fan-in remains strict FIFO, queue
full remains queue-full, and rollback at the producer boundary remains
all-or-nothing for the tested batch.

The current deferral is also explicit: do not split the MIDI listener
flush lock into snapshot/enqueue/update phases until smoke output or a
dedicated contention benchmark shows caller-visible lock wait or pending
buildup.

The detailed coalescing contract lives in:

- [Session Control Coalescing And Arbitration](2026-05-13-session-control-coalescing-arbitration.md)

## Producer Arbitration

The coexistence policy was introduced as an opt-in layer above fan-in,
not as queue behavior.

The pure policy module now covers:

- `FifoOnly`, preserving existing behavior;
- `ProducerPriority`, where owner state updates only after accepted
  fan-in enqueue;
- `TargetClaim`, where an explicit producer claim blocks only the
  claimed `(VoiceKey, ControlTag)`;
- lifecycle and hot-swap commands bypassing v1 control arbitration.

The service-owned gateway then made that policy usable from concrete
producer paths:

- `MetaSonic.Session.ArbitrationGateway` gates individual commands
  before fan-in.
- `MetaSonic.Session.FanInService` can own an optional gateway.
- service policy rejections report `SfsiiArbitrationRejected`, distinct
  from queue pressure and drain-stop issues.
- raw service enqueue remains FIFO and bypasses the gateway by design;
  callers that enable a gateway must route producers through the
  explicit arbitrated helpers for consistent policy enforcement.

The gateway lock intentionally spans policy decision, fan-in enqueue,
and owner-state update so accepted ownership follows the same order as
commands admitted to fan-in. A two-phase split remains deferred until
contention evidence exists.

The detailed coexistence contract lives in:

- [Session Producer Coexistence And Arbitration](2026-05-14-session-producer-coexistence-arbitration.md)

## Concrete Arbitrated Paths

The landed explicit producer/listener paths are:

- `enqueueArbitratedOSCControlWrite`
- `withArbitratedSessionOSCListener`
- `enqueueArbitratedUIProducerIntent`
- `enqueueArbitratedPatternBlock`

All preserve FIFO behavior with default service options. A non-FIFO
policy is only active when the caller explicitly configures the
service-owned gateway.

OSC also gained a non-audio arbitration smoke:

- `--session-osc-arbitration-smoke`
- `just session-osc-arbitration-smoke`
- `just session-osc-arbitration-send-claimed`
- `just session-osc-arbitration-send-allowed`

The smoke exercises the opt-in OSC listener service path with a
`TargetClaim` policy and reports both listener-level and service-level
arbitration rejection counters. The allowed packet may drain as
`SiStaleVoice`; that is expected because the smoke is a policy-path
probe, not an audio-voice probe.

Pattern arbitration has one behavior that is intentionally different
from OSC and UI: one Pattern producer call can contain multiple events.
The arbitrated Pattern helper therefore halts on the first policy or
fan-in rejection, reports only attempted events, and keeps the rejected
event plus the unattempted tail as backlog for a later retry.

## Verification

Automated coverage now pins:

- MIDI all-notes-off, channel filter, pitch-bend, sustain, and smoke
  path behavior;
- MIDI coalescing at fences, timed flushes, teardown flushes, visible
  fence drops, and strict-FIFO saturation pressure;
- pure arbitration decisions and edge cases;
- gateway owner-update rules, including no owner update after fan-in
  rejection;
- service-owned policy rejection with no drain wake;
- OSC producer and listener arbitrated service paths;
- UI producer arbitrated service path;
- Pattern producer arbitrated service path, including mid-block
  halt-on-rejection and backlog retention.

The latest full Haskell suite run after the Pattern follow-up passed:

```text
just stack-test
All 928 tests passed
```

Manual smoke evidence also covered device-backed MIDI input and the OSC
arbitration path. The manual MIDI smoke output showed note-on/note-off
flowing through the service, visible unmapped-control reports, zero
queue depth at completion, and coalescing stats visible in the final
summary.

## Still Deferred

These are intentionally not the next implementation step unless new
evidence or a concrete user path requires them:

- queue-level coalescing;
- MIDI listener flush-lock two-phase optimization;
- arbitration gateway lock-span two-phase optimization;
- policy mutation API for live claim/release;
- voice-lifecycle ownership clearing;
- default non-FIFO arbitration policy;
- arbitrated Pattern runner/host wrappers;
- MIDI listener routing through the service-owned arbitration gateway.

The remaining live arbitration gap is MIDI. That path is more complex
than OSC, UI, or Pattern because the MIDI listener already owns producer
state, sustain state, pitch-bend state, coalescing buffers, and timed
flush behavior.
