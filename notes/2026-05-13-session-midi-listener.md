# Session MIDI Listener

This slice adds the first session-backed MIDI listener substrate above
`MetaSonic.Session.MIDIProducer`.

The listener consumes already-decoded `MIDIProducerEvent` values from
an injected source. It owns a bracketed worker thread, keeps
producer-local MIDI note state inside the listener, and enqueues
translated commands into a `SessionFanInHost`. The source boundary is
deliberately hardware-free so tests and future PortMIDI/Q integration
can share the same session-facing loop.

## Landed Scope

- `MetaSonic.Session.MIDIListener` defines `MIDIListenerSource`, where
  `Nothing` means end-of-input and a blocking read is interrupted by
  bracket teardown.
- `withSessionMIDIListener` and `withSessionMIDIListenerHooks` run one
  worker thread over the decoded source for the body lifetime.
- The worker calls `enqueueMIDIProducerEvent` for each decoded event,
  advances listener-local `MIDIProducerState` from the producer result,
  and keeps the state readable through `readSessionMIDIListenerState`.
- Listener hooks report every producer result plus explicit producer
  rejection and fan-in enqueue rejection issues.

## Still Out Of Scope

- Opening, polling, or bracketing PortMIDI devices.
- Pitch bend, aftertouch, MIDI clock, channel masks, or sustain-pedal
  semantics.
- Release-phase CC fanout or producer-owned smoothing/coalescing.
- Arbitration beyond FIFO producer order.
- Long-running supervision beyond the scoped listener and fan-in
  service brackets.

## Tests

The tests cover bracket cleanup while the decoded source is blocked,
explicit end-of-input worker exit, producer rejection with continued
processing of later events, note-on/note-off listener state
transitions, queue-full state retention, blocked-hook teardown, and
composition through a scoped `MetaSonic.Session.FanInService` drain
worker.
