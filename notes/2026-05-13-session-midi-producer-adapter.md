# Session MIDI Producer Adapter

This slice adds the first Haskell-only MIDI producer adapter above
`MetaSonic.Session.FanIn`.

The adapter consumes already-decoded MIDI events. It does not open a
PortMIDI device, own a listener thread, define a live clock, claim
broader channel policy beyond producer-local filtering, or arbitrate
against OSC beyond the existing FIFO fan-in queue.

## Landed Scope

- `MetaSonic.Session.MIDIProducer` defines decoded note-on, note-off,
  control-change, pitch-bend, and all-notes-off events for the session
  path.
- `decodeMIDISessionCommands` translates note-on into `CmdVoiceOn`,
  note-off into `CmdVoiceOff`, velocity-zero note-on into note-off, and
  mapped CC into deterministic `CmdControlWrite` fanout over active
  MIDI notes. Mapped pitch-bend emits per-channel frequency control
  writes for active notes, and non-centered bend state is replayed into
  later note-on initial controls on that channel. Sustain-pedal CC 64
  defers note-off commands while held and emits deterministic releases
  when the pedal comes up. Sustained retriggers emit a `CmdVoiceOff`
  and `CmdVoiceOn` with the same `VoiceKey`; correctness depends on the
  runtime applying queued commands in FIFO order rather than coalescing
  them. All-notes-off emits deterministic `CmdVoiceOff` commands for
  active notes and can target either every producer-local note or only
  notes on one MIDI channel.
- `MIDIProducerOptions` carries the target template plus optional
  frequency, gate, and velocity initial-control targets and explicit CC
  and pitch-bend mappings. It also carries an optional zero-based
  channel allow-list; default options are omni. The filter is intended
  to be stable for the producer/listener lifetime; use producer-local
  all-notes-off before narrowing policy while notes are active.
- `MIDIProducerState` keeps producer-local note bookkeeping from
  `(channel, note)` to stable session `VoiceKey`s, plus non-centered
  per-channel pitch-bend state for note-on replay and sustain-pedal
  deferred note-offs.
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
- Aftertouch, MIDI clock, or channel remapping/splits.
- Release-phase CC fanout or producer-owned smoothing/coalescing.
- Arbitration beyond FIFO producer order.
- Long-running supervision beyond the scoped fan-in service.

## Tests

The tests cover note-on/off translation, velocity-zero release,
configured initial controls, deterministic CC fanout, pitch-bend control
binding, empty pitch-bend fanout, per-channel pitch-bend replay for
later note-on, sustain-pedal deferral/release and retrigger behavior,
invalid data and unmapped CC/pitch-bend rejection, channel filtering
including the empty allow-list, deterministic all-notes-off
translation, successful `ProducerMIDI` enqueue attribution, queue-full
state retention for note starts, sustain release, and all-notes-off,
and composition through a scoped
`MetaSonic.Session.FanInService` drain worker.
