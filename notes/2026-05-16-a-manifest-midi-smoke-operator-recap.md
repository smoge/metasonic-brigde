# Manifest MIDI Smoke Operator Recap

Date: 2026-05-16

Status: operator recap after the first real MIDI-controller pass and
the follow-up `d61bec4` polish commit. This note explains what the
manifest JSON is, what the manual smoke tested, what the hardware run
proved, and what the next validation step is.

## Short version

The manifest MIDI smoke is an operator validation pass for one narrow
boundary:

```text
generated authoring manifest
-> compiled demo catalog validation
-> manifest MIDI CC projection
-> real PortMIDI input
-> CmdControlWrite enqueue
-> fan-in service drain
```

It does not start audio, run reload, or make manifest reload the
default live path.

The current `named-control` demo binds `vol` to CC 10. That binding is
in source code, not just in JSON:

```haskell
vol <- Auth.ccControl 10 volName 0.3 volRng
```

## What the JSON file is

`--authoring-manifest` emits a JSON snapshot of the authored surface of
one or more compiled demos:

- demo key;
- templates and template roles;
- named buses;
- named controls;
- defaults and ranges;
- smoothing rate;
- optional MIDI CC binding;
- migration key and control slot.

For the current `named-control` demo, the generated manifest says:

```json
{
  "name": "vol",
  "default": 0.3,
  "rangeMin": 0,
  "rangeMax": 1,
  "smoothingHz": 20,
  "cc": 10,
  "key": "vol",
  "slot": 1
}
```

The important contract: the manifest is a catalog snapshot, not a
free-form runtime remapping file. The planner validates the JSON
against the compiled demo catalog. If the JSON says `cc: 10` but the
compiled demo says `cc: 7`, planning must fail.

That is why editing only `manifest.json` was rejected. The correct fix
was to change the `named-control` source binding to CC 10, update the
tests, and regenerate the manifest.

For operator use, prefer generating the file into `/tmp`:

```sh
stack exec -- metasonic-bridge --authoring-manifest named-control \
  > /tmp/metasonic-named-control-manifest.json
```

The root `manifest.json` is useful as a local scratch file while
testing, but it should not be treated as durable source of truth.

## Commands used for the MIDI smoke

Generate the manifest:

```sh
stack exec -- metasonic-bridge --authoring-manifest named-control \
  > /tmp/metasonic-named-control-manifest.json
```

Validate the JSON against the compiled catalog before touching
hardware:

```sh
stack exec -- metasonic-bridge \
  --manifest-reload-plan-file /tmp/metasonic-named-control-manifest.json \
  named-control
```

List MIDI devices:

```sh
stack exec -- metasonic-bridge --midi-list
```

Run the manual hardware smoke:

```sh
stack exec -- metasonic-bridge \
  --manifest-midi-reload-smoke /tmp/metasonic-named-control-manifest.json \
  named-control \
  --midi-device 3 \
  --manifest-midi-smoke-seconds 30
```

The device id is host-local. In the first working run, the useful
device was `--midi-device 3`.

## What the first hardware run proved

The device-backed output showed:

- the manifest loaded from JSON;
- the `named-control` plan matched the compiled catalog;
- the real PortMIDI device opened;
- the bound table printed `cc=10 tag=vol/1 name="vol"`;
- CC 10 produced accepted `CmdControlWrite voice=fx tag=vol/1`
  events;
- the 7-bit MIDI value scaled into the manifest range `[0.0, 1.0]`;
- CC 20 rejected as `unbound cc=20`;
- pitch-bend was ignored as a non-CC event, which is expected in v1.

That is the core success condition for the manual MIDI smoke. It proves
the real hardware path reaches the manifest MIDI ingress projection.

## What went wrong in the first run

The first run eventually produced many lines like:

```text
enqueue-reject: command=CmdControlWrite ... issue=SeiQueueFull 128
```

That was smoke-runner friction, not a MIDI routing failure.

The original smoke used a raw `SessionFanInHost`. It accepted and
enqueued CC writes, but no background service drained the queue during
the 30-second window. A fast controller sweep could therefore fill the
128-command queue.

Commit `d61bec4` changed the smoke to run through
`SessionFanInService`. Accepted commands are now drained while the
smoke is listening, and the summary prints both accepted and drained
counts.

After `d61bec4`, a fast sweep should produce accepted write lines plus
`drain: items=...` lines, not sustained `SeiQueueFull 128` spam.

## Expected output after the fix

The next MIDI smoke should still show:

```text
bound CC table:
  - cc=10 tag=vol/1 name="vol" default=0.3 range=[0.0, 1.0]
```

When sending CC 10:

```text
accept: CmdControlWrite voice=fx tag=vol/1 value=...
drain: items=... queue_depth=... stopped=Nothing
```

When sending CC 20:

```text
reject: unbound cc=20
```

At the end:

```text
summary:
  accepted: ...
  drained: ...
  enqueue-rejected: 0
  unbound-cc rejects: ...
```

`enqueue-rejected` does not have to be zero in every possible hardware
scenario, but sustained `SeiQueueFull 128` during an ordinary knob
sweep would mean the operator smoke is still not draining fast enough
for the test surface.

## Why the smoke matters

CI already tests the manifest MIDI logic with deterministic in-memory
sources. CI cannot reliably open the user's actual MIDI controller.

This manual smoke exists because it exercises the production PortMIDI
branch:

- device enumeration;
- device id selection;
- real PortMIDI open;
- decoded controller traffic;
- manifest-bound CC routing;
- manifest-layer rejection of unbound CCs;
- clean source/listener close.

It is an operator validation pass for the device boundary. It is not a
new architecture slice.

## What this does not prove

The smoke does not prove:

- audible control changes;
- live graph reload;
- preserving hot-swap;
- stopped-audio fallback;
- MIDI note ownership;
- pitch-bend support in the manifest path;
- default application behavior.

All of those belong to other paths.

## Next step

First rerun the MIDI smoke after `d61bec4` and confirm that the queue
drains during fast CC 10 sweeps:

```sh
stack exec -- metasonic-bridge --authoring-manifest named-control \
  > /tmp/metasonic-named-control-manifest.json

stack exec -- metasonic-bridge \
  --manifest-midi-reload-smoke /tmp/metasonic-named-control-manifest.json \
  named-control \
  --midi-device 3 \
  --manifest-midi-smoke-seconds 30
```

If that feels usable, do not add more MIDI plumbing immediately. Move
to the existing audible manifest live reload demo and validate the
broader path with OSC first:

```sh
stack exec -- metasonic-bridge --authoring-manifest named-control send-return \
  > /tmp/metasonic-live-manifest.json

stack exec -- metasonic-bridge \
  --session-osc-port 7001 \
  --manifest-live-reload-demo try-preserving \
  /tmp/metasonic-live-manifest.json \
  named-control \
  send-return
```

OSC is the right first audible reload validation because it avoids MIDI
device selection and controller event-rate noise. The goal is to test
the full audible integration path:

```text
manifest plan
-> SessionFanInService with audio running
-> manifest-aware OSC ingress
-> reloadManifestHostWithStrategy
-> close old ingress
-> open fresh ingress
-> audible owner behavior
```

The normal demo path remains unchanged. `--manifest-live-reload-demo`
is still an explicit, experimental operator mode.

## Related files

- `app/MetaSonic/App/Demos.hs`: `named-control` CC 10 binding.
- `app/MetaSonic/App/ManifestMIDIReloadSmoke.hs`: manual MIDI smoke
  runner and service-drain polish.
- `app/MetaSonic/App/ManifestReloadCli.hs`: concise manifest/catalog
  mismatch diagnostics.
- `test/MetaSonic/Spec/Feature.hs`: authoring manifest expectations.
- `test/MetaSonic/Spec/AppManifestReloadCli.hs`: mismatch diagnostic
  regression test.
- `notes/2026-05-15-d-manifest-reload-ingress-v1-closeout.md`: v1
  scope and non-goals.
