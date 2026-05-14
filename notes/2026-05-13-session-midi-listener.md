# Session MIDI Listener

This slice adds the first session-backed MIDI listener substrate above
`MetaSonic.Session.MIDIProducer`.

The listener consumes already-decoded `MIDIProducerEvent` values from
an injected source. It owns a bracketed worker thread, keeps
producer-local MIDI note state and control-coalescing state inside the
listener, and enqueues translated commands into a `SessionFanInHost`.
The source boundary is deliberately separated from hardware ownership.
The later
[Session MIDI PortMIDI Source](2026-05-13-session-midi-portmidi-source.md)
binds Q / PortMIDI input behind the same session-facing loop.

## Landed Scope

- `MetaSonic.Session.MIDIListener` defines `MIDIListenerSource`, where
  `Nothing` means end-of-input and a blocking read is interrupted by
  bracket teardown.
- `withSessionMIDIListener` and `withSessionMIDIListenerHooks` run one
  worker thread over the decoded source for the body lifetime.
- The worker decodes each event through `MIDIProducer`, advances
  listener-local `MIDIProducerState`, and keeps the state readable
  through `readSessionMIDIListenerState`. Producer options, including
  channel filtering, are stable for the listener bracket lifetime.
- `readSessionMIDIListenerState` and
  `readSessionMIDIListenerCoalescingStats` remain valid after the
  listener bracket exits, returning the final snapshots including any
  synchronous teardown flush effects.
- Repeated MIDI control writes are coalesced locally by
  `(VoiceKey, ControlTag)` before they enter fan-in. Non-control-write
  commands are fences; EOF, teardown, and the optional timed flush also
  drain pending controls. `readSessionMIDIListenerCoalescingStats`
  exposes the coalesced, accepted-flush, barrier-flush, and pending
  counts.
- A producer result with a non-empty control-write batch and an empty
  enqueue-result list means the batch was deferred into the local
  coalescer. The concrete enqueue results appear when a later fence,
  timed flush, EOF, or teardown flush submits the pending writes.
  During that window, `readSessionMIDIListenerState` reflects
  listener-local target state that fan-in and the runtime may not have
  received yet. EOF and teardown flushes report enqueue issues but do
  not call `smlhOnProducerResult`.
- If a fence needs to flush pending controls and that flush hits
  queue-full, the fence's own commands are not enqueued. The listener
  reports `SmliFenceDroppedForFlushFailure`, preserves the pending
  controls for retry, and keeps producer state at the pre-fence value.
- Listener hooks report every producer result plus explicit producer
  rejection, fan-in enqueue rejection, and dropped-fence issues.

## Still Out Of Scope

- Opening, polling, or bracketing PortMIDI devices at this listener
  slice. The later
  [Session MIDI PortMIDI Source](2026-05-13-session-midi-portmidi-source.md)
  covers the small Q / PortMIDI source wrapper.
- Aftertouch, MIDI clock, or channel remapping/splits.
- Release-phase CC fanout or coalescing outside the MIDI listener.
- Two-phase flush locking for the listener-local coalescer. The
  current single-`MVar` flush path stays in place until smoke output or
  a dedicated benchmark shows lock contention or pending buildup.
- Arbitration beyond FIFO producer order.
- Long-running supervision beyond the scoped listener and fan-in
  service brackets.

## Tests

The tests cover bracket cleanup while the decoded source is blocked,
explicit end-of-input worker exit, producer rejection with continued
processing of later events, note-on/note-off listener state
transitions, all-notes-off state clearing, queue-full state
retention, listener-local pitch-bend coalescing at an all-notes-off
fence, visible fence drops when the coalesced flush rejects, timed
control flush, pending-control flush on listener teardown, blocked-hook
teardown, and composition through a scoped
`MetaSonic.Session.FanInService` drain worker.
