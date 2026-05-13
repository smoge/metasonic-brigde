# Session MIDI Smoke Device Selection

This note records the operational path for the session MIDI smoke
command added after the `MetaSonic.Session.MIDIPortMIDI` source slice.
It is a manual live-device probe, not a deterministic CI test.

## Historical Symptom

Before the auto-selection follow-up, running the default smoke command
could fail like this:

```sh
just session-midi-smoke 10
```

```text
Session MIDI smoke.

  path: PortMIDI/Q -> Session.MIDIListener -> FanInService
  graph: tagged carrier/envelope/velocity/level voice template
  device: default (Q id 0)
  window: 10 second(s)

No input-capable MIDI device opened. Use --midi-list and --midi-device N to select a real input.
```

That meant the smoke command itself ran correctly, but Q / PortMIDI's
default device id `0` was not an input-capable MIDI device on that
machine.

The current command now enumerates the Q / PortMIDI device table and
auto-selects the first row whose `inputs > 0` when `--midi-device` is
omitted.

## Correct Manual Flow

The default smoke command is now the first thing to try:

```sh
just session-midi-smoke 10
```

It prints the auto-selected device as:

```text
device: auto id=<id> name="<device-name>"
```

For explicit selection, list the devices first:

```sh
just midi-list
```

Pick a row with `inputs > 0`, then run the smoke command with that id:

```sh
just session-midi-smoke-device <id> 10
```

For example:

```sh
just session-midi-smoke-device 2 10
```

During the smoke window, send a note-on, note-off, and optionally CC 7.
The command prints producer and drain activity. It exits non-zero if it
cannot open an input-capable device, observes no supported MIDI note/CC
events, or observes events that never drain into session commands.

## If No Input Device Appears

If `just midi-list` shows no row with `inputs > 0`, the problem is
below the session layer: Q / PortMIDI is not seeing an input-capable
device from the host MIDI backend. On Linux, check the ALSA sequencer
setup and any virtual MIDI bridge used to expose the controller.

## Explicit Selection Still Matters

Auto-selection intentionally picks the first input-capable row. Use
`just session-midi-smoke-device <id> 10` when multiple controllers are
visible and the first one is not the device under test.
