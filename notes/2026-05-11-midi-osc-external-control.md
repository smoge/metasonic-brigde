# MIDI and OSC External Control Smoke Tests

Date: 2026-05-11

## Scope

This note documents how to drive MetaSonic from an external OSC sender or MIDI
controller/simulator. These are live/manual smoke paths. CI should continue to
prefer deterministic checks:

- OSC: Haskell UDP loopback/listener tests.
- MIDI: C++ `MidiVoiceProcessor` synthetic-event tests and `rt_midi_demo`
  no-device lifecycle tests.

## Build

```sh
just stack-build
```

For C++ MIDI regression coverage:

```sh
just cpp-build
ctest --test-dir build-cpp --output-on-failure -R "rt_midi_demo|MidiVoiceProcessor"
```

## OSC Loopback

The OSC listener is a self-contained demo graph:

```text
SinOsc 440 Hz -> tagged "outgain" Gain -> Out 0
```

It binds UDP on loopback only (`127.0.0.1`) and accepts one v1 control address:

```text
/v0/outgain/0 ,f <amount>
```

Start MetaSonic:

```sh
just osc-listen 7000
```

Send a control packet from another terminal:

```sh
just osc-send 0.1
just osc-send 0.8
just osc-send 0.0
```

Equivalent direct command:

```sh
python3 tools/send_osc.py --port 7000 --address /v0/outgain/0 --value 0.3
```

If liblo tools are installed, the same packet is:

```sh
oscsend 127.0.0.1 7000 /v0/outgain/0 f 0.3
```

Current limitation: the listener intentionally binds only to loopback. A LAN
control surface should add an explicit `--osc-bind-host` flag rather than
changing the default.

## MIDI Device Selection

List the devices that Q / PortMIDI can see:

```sh
just midi-list
```

The printed `id=` values are accepted by the live polyphonic MIDI demo:

```sh
just midi-poly-device 3
```

The default path remains:

```sh
just midi-poly
```

which opens device id `0`.

The `midi-poly` mapping is:

- Note on: allocate/activate one voice.
- Note off or note-on velocity 0: release the matching voice.
- CC 7: smoothed master volume in `[0, 1]`.
- Pitch bend: oscillator frequency bend, +/-2 semitones.
- Channel mask: omni (`0xFFFF`) in the CLI demo.

No-device hosts are valid smoke environments: the MIDI session still opens,
reports no connected device internally, keeps counters at zero, and remains
silent until closed.

## MIDI Hardware Controller

1. Plug in the controller.
2. Run `just midi-list`.
3. Pick an input-capable device id (`inputs` greater than zero).
4. Run `just midi-poly-device N`.
5. Play notes, move CC 7, and use pitch bend.

If the controller does not appear, verify the OS MIDI stack first. On Linux,
that usually means ALSA sequencer support is missing or inaccessible.

## MIDI Virtual Controller on Linux

One practical local loopback is ALSA's virtual raw MIDI driver:

```sh
sudo modprobe snd-virmidi midi_devs=1
aconnect -l
just midi-list
```

Then run MetaSonic against the input-capable virtual device id:

```sh
just midi-poly-device N
```

Use a virtual keyboard or MIDI sender such as VMPK, `sendmidi`, or another
sequencer program to send notes, CC 7, and pitch bend to the corresponding
virtual port. The exact connection command depends on the sender, but the rule
is simple: MetaSonic opens the PortMIDI input id printed by `just midi-list`;
the simulator must send into that same virtual MIDI endpoint.

## Recommended Test Split

Use these as the normal gates:

```sh
just stack-test
ctest --test-dir build-cpp --output-on-failure -R "rt_midi_demo|MidiVoiceProcessor"
```

Use these only as manual live smoke checks:

```sh
just osc-listen 7000
just osc-send 0.3
just midi-list
just midi-poly-device N
```

Reason: OSC loopback is deterministic enough for automated tests, but external
MIDI depends on host devices, ALSA/PortMIDI state, and user-space virtual MIDI
programs. Keep those as explicit live checks instead of making CI depend on
machine-local hardware.
