# Session Control Coalescing And Arbitration

Status: design note only. No queue, producer, or runtime behavior changes
land in this slice.

The session fan-in path now has real high-rate control producers:
OSC symbolic control writes, MIDI CC, MIDI pitch-bend, UI control
writes, and future Pattern automation can all target the same bounded
FIFO queue. That makes queue pressure an operational risk, but changing
drop/coalescing behavior is a cross-producer semantic decision rather
than a MIDI-only optimization.

## Current Contract

- `MetaSonic.Session.Queue` is FIFO. It assigns sequence numbers on
  enqueue, rejects full queues explicitly, and never silently drops,
  coalesces, or reorders commands.
- `MetaSonic.Session.FanIn` serializes enqueue/drain access around that
  queue and inherits the same FIFO semantics.
- Producer adapters preserve their own state on enqueue failure, so a
  full queue is observable backpressure rather than an implicit
  producer-side drop.
- Some existing producer behavior depends on FIFO order. In particular,
  MIDI sustained retriggers emit `CmdVoiceOff` followed by `CmdVoiceOn`
  with the same `VoiceKey`; correctness depends on the owner applying
  both commands in order.

## Command Classes

These commands are not coalescible:

- `CmdVoiceOn`
- `CmdVoiceOff`
- `CmdHotSwap`

Voice lifecycle commands are ordering barriers. That includes
MIDI all-notes-off releases, sustain-pedal releases, and sustained
retrigger stop/start pairs. Coalescing or reordering them can change
which voice exists, whether a stale `VoiceKey` is valid, or which graph
owns a control target after hot-swap.

The only obvious coalescing candidate is repeated `CmdControlWrite` to
the same target:

```text
(ProducerId, VoiceKey, ControlTag)
```

For those writes, last-write-wins can be musically acceptable for
continuous controls such as MIDI CC, pitch-bend, OSC sliders, and UI
sliders. That rule is not automatically safe across producers, because
OSC, MIDI, UI, and Pattern may represent different user intents even
when they hit the same control target.

## First Policy Candidate

A first implementation should avoid global cross-producer arbitration.
If coalescing is added, start with an explicit producer-local or
producer-opted-in control-write coalescer:

- Key coalescing by `(ProducerId, VoiceKey, ControlTag)`.
- Only coalesce `CmdControlWrite`.
- Treat `CmdVoiceOn`, `CmdVoiceOff`, and `CmdHotSwap` as barriers that
  flush any pending control write for affected voices or graphs before
  they pass.
- Preserve normal FIFO ordering between different producers.
- Keep Pattern events non-coalesced by default; Pattern timing is
  authored data, not just controller noise.

This keeps the first policy narrow: it reduces repeated writes from one
source while avoiding the stronger claim that two producers targeting
the same control can be merged.

## Observability

Coalescing must not hide backpressure. A future implementation should
report separate counters or hooks for at least:

- queue-full rejections;
- control writes accepted into the coalescer;
- control writes replaced by a later write;
- control writes flushed into the real fan-in queue;
- barrier-forced flushes.

Those counters should be distinct because queue-full means the session
could not accept work, while coalescing means a configured policy
accepted a newer value over an older one.

## Test Plan

Before implementation, tests should pin:

- FIFO preservation for `CmdVoiceOn`, `CmdVoiceOff`, and `CmdHotSwap`.
- Same-producer same-target `CmdControlWrite` collapse to the latest
  value only.
- Different-target control writes are not collapsed.
- Different-producer same-target writes are not collapsed in v1.
- Voice lifecycle and hot-swap commands flush or fence pending control
  writes before the barrier command proceeds.
- MIDI sustained retrigger remains a stop/start pair with the same
  `VoiceKey` and is never coalesced.
- Queue-full and coalesced/drop counters remain distinguishable.

## Open Questions

- Whether the coalescer should live as a wrapper around
  `SessionFanInHost` or as a separate producer-side helper.
- Whether UI sliders should opt into the same producer-local policy as
  MIDI CC/pitch-bend.
- Whether Pattern automation eventually needs an explicit
  authoring-level "continuous control" marker before it can opt in.
- Whether a later owner-aware policy should coalesce across producers
  only after an explicit priority/arbitration table exists.
