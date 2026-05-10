# Phase 6.B — OSC Control Surface Design

Date: 2026-05-10
Status: design only; bounds 6.B before any code lands.

This note plays the same role for 6.B that
[Phase 6.A pattern design](2026-05-10-phase-6a-pattern-design.md)
plays for 6.A: it fences the work before the contract or the
implementation lands.

## Position in the roadmap

Phase 6.B is the second active sub-phase of the rewritten
[Phase 6](../ROADMAP.md). 6.A (pattern layer) is structurally
complete; 6.B introduces the first *external* producer.

The 6.A.1 producer-vs-runtime boundary applies unchanged: 6.B is
a producer (receives OSC, emits realtime control / lifecycle /
swap events through the existing audio-thread-safe queue). It
does not own audio-thread state, introduces no new `NodeKind`s,
and does not drive a per-block scheduler.

The project's load-bearing pattern continues: "descriptive
measurement first, runtime change later." 6.B.1 is the bounds
note; 6.B.2 will be the contract + minimal handler module;
6.B.3 will be integration verification. No code lands until
6.B.2 is reviewed.

## What 6.B is

A small UDP listener that:

1. Binds a caller-configured UDP port.
2. Receives OSC packets and parses them as **single messages**
   with addresses and typed arguments.
3. Resolves each message to a target on the currently-loaded
   `TemplateGraph` using the symbolic identifier shape 6.A
   already established.
4. Writes the resolved targets through the existing realtime
   control queue (`rt_graph_realtime_set_control`,
   `rt_graph_realtime_reserve / _activate / _release`) and the
   §5.3 swap helpers.

The address space mirrors 6.A's symbolic identifiers:

```
/<voice-key>/<node-tag>/<slot>          control write
/<voice-key>/on/<template-name>         voice on (initial ctrls in args)
/<voice-key>/off                        voice off
/swap/<swap-label>                      (deferred to 6.B post-v1)
```

The address-to-target resolution is the §5.4.C producer-side
mapping problem made concrete (see "Where §5.4.C lands" below).

## What 6.B is not

- **Not OSC send.** Outbound OSC (reply, broadcast, status
  ping) is out of v1 scope. Receive only.
- **Not the full OSC spec.** Bundles with timetags, blob
  arguments, and exotic types stay deferred. v1 v1 covers
  `,f` (float) and `,i` (int) arguments, single messages, no
  bundles.
- **Not a discovery / auto-config layer.** No Bonjour, no
  ZeroConf, no automatic IP binding. The port is
  caller-configured at handler start.
- **Not a new audio-thread substrate.** 6.B adds no DSP, no
  region kernels, no per-block bookkeeping. OSC events flow
  through the existing realtime control queue.
- **Not a 6.A replacement.** 6.A is the deterministic *offline*
  pattern producer; 6.B is the *online* external producer. Both
  feed the realtime queue; they coexist as separate producers
  subject to the §5.3 single-producer / single-collector v1
  limitation.
- **Not a general-purpose OSC library.** v1 ships a minimal
  parser sized to the address / argument shapes named above.
  No fork/blob/symbol decoding beyond what the project uses.

## Architecture decision: Haskell-owned

OSC parsing, socket handling, and dispatch resolution live in
**Haskell**. Not C++.

This is a deliberate departure from the MIDI precedent (which is
C++-owned via Q's typed MIDI stack), so the reasoning is worth
spelling out:

1. **Mirrors the 6.A producer boundary.** A pattern producer
   may run its own clock thread to emit timed events; an OSC
   producer is the same shape with a UDP socket in place of a
   clock. Both write through the realtime control queue, both
   are audio-thread-safe by construction. Putting OSC in
   Haskell makes the producer boundary uniform across pattern
   and external sources.
2. **OSC is a control plane, not a data plane.** MIDI is
   audio-rate input with sub-millisecond hardware timing; OSC
   is high-level command traffic with network jitter already
   baked in. A Haskell GC pause is absorbed by the realtime
   queue without harm.
3. **Smaller C++ surface.** No new realtime ABI entries, no
   vendored OSC library on the C++ side, no socket integration
   with the audio callback. The C++ runtime stays focused on
   DSP execution.
4. **Easier to test.** The parser is a pure function over byte
   buffers; the dispatcher is a pure function over
   `(ResolveState, OscMessage)`. Both test without FFI, audio,
   or sockets.

**Trade-off.** Haskell-side parsing adds latency relative to a
C++-owned listener — call it ~hundreds of microseconds, with GC
pauses adding tail jitter. Acceptable for v1 control-plane use
(filter sweeps, voice triggers, parameter automation). Revisit
only if a real workload demonstrates Haskell-side handling is
the wrong abstraction. The bench-first discipline applies: ship
the handler, time it under realistic load, then decide.

## Address-to-target resolution

The 6.B handler owns a resolution table mirroring the 6.A driver
responsibilities (§6.A.1 / §6.A.2):

- `VoiceKey → slot_id`
- `(template_id, NodeTag) → NodeIndex`
- Current `TemplateGraph` (replaced on hot-swap)

When an OSC message arrives:

1. Parse the address into `(voice-key, node-tag, slot)`.
2. Look up `VoiceKey → slot_id` in the table. Missing → log
   "unknown voice" and drop.
3. Look up `(template_id, NodeTag) → NodeIndex`. Missing → log
   "unknown node tag" and drop.
4. Validate `slot ∈ [0, controlCount)`. Out of range → log
   "invalid slot" and drop.
5. Write `(slot_id, node_index, slot, value)` via
   `rt_graph_realtime_set_control`.

The invariants are identical to the §6.A driver-stub
feasibility validator (`checkDriverFeasibility` in
`test/Spec.hs`); 6.B should reuse the same `DriverIssue` ADT
shape rather than reinventing the issue vocabulary.

### Where §5.4.C lands

The Phase 5 status note documents §5.4.C (producer-side
mapping helpers) as "deferred until a real caller hits the
friction. Phase 6.A is the first such producer candidate;
revisit these only if 6.A's corpus or 6.B's OSC surface
demonstrates concrete friction."

6.B is exactly that caller. The resolution table above is the
producer-side mapping helper §5.4.C deferred. If 6.B
implementation surfaces friction — re-resolution after
hot-swap, thread-safety across concurrent handlers, address
table compaction — that work either lands as part of 6.B or as
a focused §5.4.C slice. Naming the connection here means the
choice is made deliberately, not by drift.

## Realtime queue contract

6.B is a **single producer** mirroring §5.3's documented
single-producer / single-collector v1 limitation. The OSC handler
thread is the sole writer to the realtime control queue from
this surface; mixing OSC with another producer (e.g. a future
6.A pattern driver) is out of v1 scope.

If 6.B and 6.A both want to write concurrently, the project must
either:

- Land §5.3.D (blocking wait / serialization primitive), or
- Extend the queue contract to multi-producer (a real refactor).

Both are deferred until evidence appears. v1 says: one OSC
producer at a time, no concurrent pattern driver.

## Module shape (preview for 6.B.2)

When the implementation slice lands, the minimum surface is:

- `src/MetaSonic/OSC/Wire.hs` — pure binary parser. Exposes
  `parseMessage :: ByteString -> Either String OscMessage` plus
  the `OscMessage` ADT (`OscAddr`, `OscArg`).
- `src/MetaSonic/OSC/Dispatch.hs` — pure resolver. Exposes
  `dispatch :: ResolveState -> OscMessage -> Either DispatchIssue
  DispatchAction` and the `ResolveState` / `DispatchAction` ADTs.
- `app/MetaSonic/App/Osc.hs` — IO entry point. Exposes
  `runOscListen :: Int -> IO ()` (port → listener). Holds a
  resolution table behind an `IORef`, calls the realtime queue
  helpers from the library.

Tests live in `test/Spec.hs` as a new test group covering:

- Parse round-trip on hand-crafted byte sequences (the OSC 1.0
  spec gives plenty of examples).
- Dispatch resolution against a fixed `ResolveState` derived
  from the 6.A corpus (so we exercise the 6.A address shape
  end-to-end without standing up an actual socket).
- Negative cases mirroring 6.A's `DriverIssue`: unknown voice,
  unknown node tag, out-of-range slot.

No new executable subcommand in 6.B.2 — the listener entry point
ships as a library function so tests drive it directly; a
`--osc-listen` subcommand can land in 6.B.3 once the contract is
verified.

## Out of 6.B scope

- OSC send / reply / notification streams.
- Bundles with timetags.
- Argument types beyond `,f` and `,i`.
- Discovery, IP auto-binding, multicast.
- Multi-producer concurrency on the realtime queue.
- A general-purpose OSC library (a minimal parser only, sized
  to the address / argument shapes named above).
- Performance optimization (mmap, zero-copy ring buffers,
  worker pools). Baseline cost first; tune only on evidence.
- Pattern combinators (those are pure-6.A surface work, not
  6.B).

## Next concrete step

Land 6.B.2: the contract module (`MetaSonic.OSC.Wire`,
`MetaSonic.OSC.Dispatch`) plus the `runOscListen` IO entry
point, with the test-group shape above. Do not start ergonomic
or send-side work before 6.B.3 verification holds.
