/*

Repeatable sclang MIDI sender for the MetaSonic manifest live-session
values path.

Run order:

1. In terminal A, confirm the PortMIDI input id:

stack exec -- metasonic-bridge --midi-list

2. In terminal A, start the live session. Use the input-capable id from
   step 1 as `--midi-device`; the common ALSA through input is often 1.

stack exec -- metasonic-bridge \
  --manifest-live-session examples/manifests/preserve-cutoff.json \
  preserve-cutoff-dark \
  --strategy try-preserving \
  --midi-device 1

3. Wait until terminal A prints `midi=on`.

4. In terminal B, run this script:

sclang sc/live-session-midi-values.scd

5. In terminal A, type these live-session commands while the script runs:

  values
  demo:preserve-cutoff-bright
  values
  wait for the second `midi accept` line
  values
  status
  quit

The script sends one bound CC 74 before the reload, waits for the reload
window, then sends another bound CC 74 after reload. The expected result is
two `midi accept` lines for `/v0/lpf/0`, with `values` showing
`source=accepted` before and after the preserving reload.

On the common ALSA through route, sclang sends to "Midi Through Port-0" and
MetaSonic opens the matching input-capable PortMIDI device.

Optional rejected-CC check, after this script has initialized:

  ~metaSonicSendRejectedProbe.value;

For preserve-cutoff.json this sends CC 71 and CC 7, which should print
`midi reject (cc-unbound)` because only CC 74 is bound.

Quick interactive sequence after evaluating this file in the SuperCollider IDE:

  ~metaSonicSendInitialBatch.value;
  values
  demo:preserve-cutoff-bright
  values
  ~metaSonicSendPostReload.value;
  values
  status
  quit

*/

(
~metaSonicMIDIDevice = "Midi Through";
~metaSonicMIDIPort = "Midi Through Port-0";
~metaSonicMIDIChannel = 0;

// Seconds between the initial CC and the post-reload CC.
// Keep this long enough to type `values`, `demo:...`, and another `values`.
~metaSonicReloadPause = 30.0;

// Leave false for SuperCollider IDE use so the interpreter stays open.
// Set true for command-line `sclang sc/live-session-midi-values.scd`
// when you want sclang to exit after the replay.
~metaSonicQuitWhenDone = false;

MIDIClient.init;

"Available MIDI destinations:".postln;
MIDIClient.destinations.do { |destination, index|
    (
        "  "
        ++ index
        ++ ": "
        ++ destination.device
        ++ " / "
        ++ destination.name
        ++ " uid="
        ++ destination.uid
    ).postln;
};

~metaSonicMIDIOut = MIDIOut.newByName(
    ~metaSonicMIDIDevice,
    ~metaSonicMIDIPort
);
~metaSonicMIDIOut.latency = 0;

~metaSonicSendControl = { |cc, value, label|
    (
        "send "
        ++ label
        ++ " channel="
        ++ ~metaSonicMIDIChannel
        ++ " cc="
        ++ cc
        ++ " value="
        ++ value
    ).postln;
    ~metaSonicMIDIOut.control(~metaSonicMIDIChannel, cc, value);
};

~metaSonicSendInitialBatch = {
    ~metaSonicSendControl.value(74, 90, "cutoff -> /v0/lpf/0");
};

~metaSonicSendPostReload = {
    ~metaSonicSendControl.value(74, 64, "post-reload cutoff -> /v0/lpf/0");
};

~metaSonicSendRejectedProbe = {
    ~metaSonicSendControl.value(71, 40, "expected reject: q / CC 71");
    0.20.wait;
    ~metaSonicSendControl.value(7, 30, "expected reject: level / CC 7");
};

~metaSonicRunReplay = {
    Routine({
        "MetaSonic MIDI replay: initial bound CC starting.".postln;
        ~metaSonicSendInitialBatch.value;

        (
            "MetaSonic MIDI replay: waiting "
            ++ ~metaSonicReloadPause
            ++ " seconds. In the live session: type `values`, reload to "
            ++ "`preserve-cutoff-bright`, then type `values` again. "
            ++ "Wait for the next `midi accept` before the final `values`."
        ).postln;
        ~metaSonicReloadPause.wait;

        "MetaSonic MIDI replay: post-reload update starting.".postln;
        ~metaSonicSendPostReload.value;

        "MetaSonic MIDI replay: done.".postln;
        ~metaSonicQuitWhenDone.if({ 0.exit });
    }).play(SystemClock);
};

~metaSonicRunReplay.value;
)
