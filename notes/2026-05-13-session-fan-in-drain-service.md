# Session Fan-In Drain Service

This slice adds the first scoped background drain worker around
`MetaSonic.Session.FanIn`.

The service owns no new command semantics. It allocates a normal
`SessionFanInHost`, installs a successful-enqueue wakeup hook, and
starts one worker thread inside the same bracket. Each wake drains the
existing FIFO host with `drainSessionFanInHost`. Successful drains are
reported through hooks. A drain that stops because the owner diverged is
also reported, and the worker exits instead of retrying, repairing, or
respawning the session.

## Landed Scope

- `MetaSonic.Session.FanIn` now has optional host hooks. The default hook
  is a no-op, so direct `withSessionFanInHost` users keep caller-driven
  behavior.
- `MetaSonic.Session.FanInService` adds `withSessionFanInService`,
  `withSessionFanInServiceHooks`, `enqueueSessionFanInServiceCommand`,
  and `sessionFanInServiceHost`.
- Existing concrete producers can still target a `SessionFanInHost`.
  When they are given the service-owned host, successful enqueues wake
  the background drain worker.
- Tests cover bracket cleanup, wake-on-enqueue draining, OSC producer
  composition through the service-owned host, and divergence reporting
  with worker exit.

## Still Out Of Scope

- At this slice, MIDI/UI producer translation. The later
  [Session MIDI Producer Adapter](2026-05-13-session-midi-producer-adapter.md)
  covers already-decoded MIDI note/CC command translation, and the
  later
  [Session UI Producer Adapter](2026-05-13-session-ui-producer-adapter.md)
  covers already-decoded UI intent translation. Live PortMIDI
  listener/device ownership, GUI toolkit bindings, and manifest-driven
  session reload remain out of scope.
- OSC behavior beyond the landed symbolic control-write path.
- Arbitration beyond FIFO producer order.
- Producer-specific throttling or coalescing.
- Long-running supervision beyond the scoped bracket.
- Respawn, repair, or recovery after terminal owner divergence.
- A realtime command queue beyond the existing runtime ABI.
