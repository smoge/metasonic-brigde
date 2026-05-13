# Session MIDI Producer Adapter

This slice adds the first Haskell-only MIDI producer adapter above
`MetaSonic.Session.FanIn`.

The adapter consumes already-decoded MIDI events. It does not open a
PortMIDI device, own a listener thread, define a live clock, claim
pitch-bend or channel policy, or arbitrate against OSC beyond the
existing FIFO fan-in queue.

## Landed Scope

- `MetaSonic.Session.MIDIProducer` defines decoded note-on, note-off,
  and control-change events for the session path.
- `decodeMIDISessionCommands` translates note-on into `CmdVoiceOn`,
  note-off into `CmdVoiceOff`, velocity-zero note-on into note-off, and
  mapped CC into deterministic `CmdControlWrite` fanout over active
  MIDI notes.
- `MIDIProducerOptions` carries the target template plus optional
  frequency, gate, and velocity initial-control targets and explicit CC
  mappings.
- `MIDIProducerState` keeps producer-local note bookkeeping from
  `(channel, note)` to stable session `VoiceKey`s.
- `enqueueMIDIProducerEvent` submits generated commands to a
  `SessionFanInHost` with `ProducerMIDI` identity and advances producer
  state only after every generated enqueue succeeds.

## Still Out Of Scope

- Opening, polling, or bracketing PortMIDI devices.
- At this producer-adapter slice, a session-backed MIDI listener
  thread. The later
  [Session MIDI Listener](2026-05-13-session-midi-listener.md) covers
  the decoded-source worker; PortMIDI device ownership remains out of
  scope.
- Pitch bend, aftertouch, MIDI clock, channel masks, or sustain-pedal
  semantics.
- Release-phase CC fanout or producer-owned smoothing/coalescing.
- Arbitration beyond FIFO producer order.
- Long-running supervision beyond the scoped fan-in service.

## Tests

The tests cover note-on/off translation, velocity-zero release,
configured initial controls, deterministic CC fanout, invalid data and
unmapped-CC rejection, successful `ProducerMIDI` enqueue attribution,
queue-full state retention, and composition through a scoped
`MetaSonic.Session.FanInService` drain worker.
