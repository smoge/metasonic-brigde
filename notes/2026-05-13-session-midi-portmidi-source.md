# Session MIDI PortMIDI Source

This slice adds the first Q / PortMIDI-backed source for
`MetaSonic.Session.MIDIListener`.

The source is intentionally smaller than the existing live-MIDI demo
path. It owns only a polling handle over `q::midi_input_stream`, decodes
MIDI 1.0 note-on, note-off, and control-change messages into
`MIDIProducerEvent`s, and lets the Haskell session listener own the
worker thread. It does not touch `RTGraph`, `VoiceAllocator`, or the
runtime realtime queue.

## Landed Scope

- `tinysynth/session_midi_source.{h,cpp}` expose a C ABI for opening,
  closing, device-presence probing, and polling one supported decoded
  MIDI event.
- `MetaSonic.Session.MIDIPortMIDI` wraps that ABI with
  `withPortMIDISource`, `pollPortMIDISourceEvent`, and
  `portMIDIListenerSource`.
- The CLI exposes `--session-midi-smoke [SECONDS]`, a non-audio manual
  probe that wires this source through `MetaSonic.Session.MIDIListener`,
  `MetaSonic.Session.MIDIProducer`, and `MetaSonic.Session.FanInService`,
  then prints producer/drain activity.
- Missing, output-only, invalid, or failed-open device ids produce a
  valid idle source whose `portMIDISourceHasDevice` result is `False`.
  This keeps no-controller and headless hosts closeable.
- `portMIDIListenerSource` converts no-event polls into a small sleep
  and retry loop; it does not emit listener EOF by itself.

## Still Out Of Scope

- Pitch bend, aftertouch, MIDI clock, channel masks, sustain-pedal
  semantics, or all-notes-off synthesis.
- Producer arbitration beyond FIFO.
- Reusing or replacing the existing C++ `MetaSonic.Bridge.MidiDemo`
  live-runtime path.
- Long-running supervision beyond the scoped source/listener/fan-in
  service brackets.

## Tests

The tests use an invalid device id so they do not require MIDI
hardware. They cover idle closeable open behavior, no-event polling,
and composition with `MetaSonic.Session.MIDIListener` teardown.

Manual live-device coverage is intentionally outside automated CI:

```sh
stack exec -- metasonic-bridge --midi-list
stack exec -- metasonic-bridge --midi-device <input-id> --session-midi-smoke 10
```

The smoke command exits non-zero if it cannot open an input-capable
device or if no supported note/CC events produce drained session
commands during the selected time window.
