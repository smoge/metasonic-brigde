/*

Repeatable sclang MIDI sender for the MetaSonic manifest live-session
values path.

Suggested MetaSonic side:

stack exec -- metasonic-bridge \
  --manifest-live-session examples/manifests/preserve-cutoff.json \
  preserve-cutoff-dark \
  --strategy try-preserving \
  --midi-device 1

Use `--midi-list` to confirm the PortMIDI input id. On the common
ALSA through route, sclang sends to "Midi Through Port-0" and MetaSonic
opens the matching input-capable PortMIDI device.

Live-session operator sequence while this runs:

  values
  demo:preserve-cutoff-bright
  values
  status
  quit

The script sends CC 74 / 71 / 7 first, waits for the reload window,
then sends another CC 74 so the post-reload path is visible too.

*/

(
~metaSonicMIDIDevice = "Midi Through";
~metaSonicMIDIPort = "Midi Through Port-0";
~metaSonicMIDIChannel = 0;

// Seconds between the initial CC batch and the post-reload CC.
// Increase this if you want more time to type `values` and `demo:...`.
~metaSonicReloadPause = 10.0;

// Set false when evaluating from an interactive SuperCollider IDE session.
~metaSonicQuitWhenDone = true;

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
    0.20.wait;
    ~metaSonicSendControl.value(71, 40, "q      -> /v0/lpf/1");
    0.20.wait;
    ~metaSonicSendControl.value(7, 30, "level  -> /v0/gain/0");
};

~metaSonicSendPostReload = {
    ~metaSonicSendControl.value(74, 64, "post-reload cutoff -> /v0/lpf/0");
};

~metaSonicRunReplay = {
    Routine({
        "MetaSonic MIDI replay: initial batch starting.".postln;
        ~metaSonicSendInitialBatch.value;

        (
            "MetaSonic MIDI replay: waiting "
            ++ ~metaSonicReloadPause
            ++ " seconds. Type live-session `values`, reload to "
            ++ "`preserve-cutoff-bright`, then `values` again."
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
