## --manifest-host-reload-smoke Operator Runbook

Date: 2026-05-19

Status: operator-facing runbook. Companion to
[ManifestReloadEvent Partial Coverage](2026-05-19-a-manifest-reload-event-partial-coverage.md),
which records the API shape and the consumer-gating decisions. This
note records what the smoke prints, how to read it, and the
known-good output for the fallback path. Not a design pin.

## Blessed operator flow: preserving live reload

The canonical preserving manifest live-reload path is a single
command sequence against a committed fixture:

```
stack exec -- metasonic-bridge --manifest-live-reload-demo \
    try-preserving examples/manifests/preserve-cutoff.json \
    preserve-cutoff-dark preserve-cutoff-bright
```

Expected outcome (full transcript and OSC packet flow in
[Cross-confirmation: live audio + real OSC](#cross-confirmation-live-audio--real-osc)):

- `strategy outcome:` reports `success: preserving installed
  (audio kept, voices preserved)` — no stopped-audio fallback.
- `reload events:` ends with `strategy succeeded: preserving
  installed (audio kept, voices preserved)`. No
  `preserving phase rejected` line, no fallback admission.
- `audio running: yes` and `active voices: 1` hold across the
  reload.
- OSC `/v0/lpf/0` is accepted both before (against the dark
  600 Hz baseline) and after (against the bright 2400 Hz
  baseline).

The fixture is regenerable byte-for-byte from the demo source
via `--authoring-manifest preserve-cutoff-dark
preserve-cutoff-bright` and drift-protected by
`MetaSonic.Spec.AppManifestPreservingFixture`. The host-reload
smoke (`--manifest-host-reload-smoke`) is the fake-audio CI
counterpart documented below; the live-reload command above is
the operator-facing path.

## Invocation

```
metasonic-bridge --manifest-host-reload-smoke STRATEGY MANIFEST.json DEMO
```

- `STRATEGY` is one of `require-preserving`,
  `try-preserving`, `stopped-audio-only`.
- `MANIFEST.json` is an authoring-surface manifest doc whose
  `demos[i]` matches the compiled catalog entry for `DEMO`. Generate
  with `metasonic-bridge --authoring-manifest DEMO` if you do not
  already have one.
- The smoke runs with a fake `SessionFanInAudioFFI` (no PortAudio
  device is opened), so it is safe to run in CI environments and
  prints `fake audio lifecycle: yes` to make the substitution
  visible. It is a diagnostic / operator-UX path, not a live audio
  demo — for live audio see `--manifest-live-reload-demo`.

## Reading the output

The smoke prints one pre-reload fan-in snapshot, the strategy
outcome, one post-reload fan-in snapshot, the ingress snapshot,
two operator-visible event timelines, and the selector command
projection. The two timelines:

- `reload events:` is the `ManifestReloadEvent` stream emitted by
  the orchestrator at every strategy / phase / recovery / fallback
  boundary. Each bullet is one transition; rejected and admitted
  lines render the typed kebab-case stage tag of the failure
  payload, with any nested cause inlined in the same line (e.g.
  `reload-rejected (old owner still installed)`). The same
  vocabulary is shared with the `--manifest-live-reload-demo`
  timeline so operators read one surface across both CLIs.
- `fake audio events:` is the captured call sequence against the
  fake audio FFI. On the try-preserving fallback path the
  stopped-audio phase stops old audio and starts new audio, so this
  block contains two `start` entries and one `stop`. That is the
  intended shape, not a leak.

`strategy result:` carries the same outcome as the final
`strategy succeeded:` / `strategy failed:` line in the reload-events
block, in the same typed prose form (e.g.
`success: preserving rejected (reload-rejected (old owner still installed)), stopped-audio fallback installed`).
The redundancy is deliberate: it gives operators a single-line
summary they can grep without scanning into the events block.

## Known-good fallback output (named-control, try-preserving)

Recorded against a single-demo `manifest.json` for `named-control`.
The initial owner is whatever catalog entry the smoke can pick that
is not the target — at this revision that is `send-return`. The
preserving path is rejected at the reload stage
(`reload-rejected (old owner still installed)`) because the smoke's
initial owner has no voices to migrate, the fallback is admitted,
and the stopped-audio phase commits cleanly. Captured on the
post-`f595542` tree, after the smoke-vocabulary standardization
slice retired the `Outer/Inner` show-parsed tags in favor of the
typed prose form.

```
Manifest host strategy reload smoke
  strategy: try-preserving
  initial demo: send-return
  target demo: named-control
  swap label: manifest:named-control
  fake audio lifecycle: yes (no PortAudio device opened)
  ...
  strategy result: success: preserving rejected (reload-rejected (old owner still installed)), stopped-audio fallback installed
  post-reload fan-in:
    queue depth: 0
    owner status: SessionOwnerReady
    reload status: SessionFanInNormalOperation
    audio running: yes
    graph installed: yes
    active voices: 0
  ingress: open demo=named-control ui-controls=2 osc-controls=2 midi-cc=1 defaultVoice=v0 oscPort=<ephemeral>
  reload events:
    - strategy started: try-preserving
    - preserving phase started
    - resume old ingress: started
    - resume old ingress: succeeded
    - preserving phase rejected: reload-rejected (old owner still installed)
    - fallback admitted: reload-rejected (old owner still installed)
    - stopped-audio phase started
    - stopped-audio phase committed
    - strategy succeeded: preserving rejected (reload-rejected (old owner still installed)), stopped-audio fallback installed
  fake audio events:
    - start channels=2 device=-1
    - ready timeoutMs=100
    - stop
    - start channels=2 device=-1
    - ready timeoutMs=100
  selector command projection: CmdHotSwapPreservingOnly manifest:named-control templates=1 (selector-controlled)
```

Two ordering notes that occasionally surprise readers:

- The `resume old ingress: started / succeeded` pair fires
  *before* `preserving phase rejected:` in the reload-events block.
  The orchestrator attempts to resume old ingress as part of
  surfacing a retryable preserving rejection; the rejection event
  is emitted with the resume already complete, not before it.
- The `oscPort` printed under `ingress:` is whatever ephemeral port
  the OS handed out, so it varies per run. The smoke's regression
  test asserts only that the port is non-zero after the swap.

## Cross-confirmation: live audio + real OSC

The host-reload smoke runs against a fake `SessionFanInAudioFFI`,
so it pins the orchestrator output without ever opening PortAudio.
The companion `--manifest-live-reload-demo` CLI is the live-audio
counterpart and, as of `f595542` / `aca37ed`, shares this runbook's
vocabulary character-for-character for `strategy outcome:`, the
`reload events:` block, and the combined ingress snapshot.

First end-to-end validation run, captured outside CI:

```
stack exec -- metasonic-bridge --manifest-live-reload-demo \
    try-preserving manifest.json named-control named-control
```

What the run confirmed about the live PortAudio/ALSA path that
the fake-audio smoke cannot:

- PortAudio start / wait / stop through `defaultSessionFanInAudioFFI`
  on ALSA. The device-probing warnings printed during start were
  harmless; the host reported `audio running: yes` and held it across
  the reload. The run did not independently verify audible output
  — only that the audio lifecycle returned success at each stage.
- Real UDP OSC ingress bound on `oscPort=7001`. Packets to
  `/v0/vol/1` and `/v0/cutoff/1` were accepted before the reload;
  `/v0/vol/1` was accepted again after the reload, proving the
  swapped target's OSC projection was live at the decode/route
  layer (not, again, that the resulting control writes were
  audibly applied).
- The typed `reload events:` block rendered character-for-character
  identically to the fake-audio smoke output above (same event order,
  same kebab-case stage tags, same `preserving rejected (...)` /
  `stopped-audio fallback installed` outcome line).
- `active voices: 1` before and after the reload, with `Enter` ending
  the demo in process exit 0 and no port held.

Notable: a `named-control → named-control` self-reload still took the
fallback path (`preserving rejected (reload-rejected (old owner still
installed)), stopped-audio fallback installed`). The reason is not a
missing migration key on the auto-spawned voice — the authored
controls do carry migration metadata. It is that `named-control`'s
authored controls route through `KSmooth` nodes (one per named
control, see `Saw → LPF[cutoff] → Gain[vol=CC10] → Out` in
`MetaSonic.App.Demos`), and `KSmooth` is `PreserveUnsupported` in
`MetaSonic.Session.RTGraphAdapter.preservingHotSwapNodeClass`. The
preserving command therefore cannot land state across the swap, the
orchestrator collapses to stopped-audio fallback, and the new voice
restarts from defaults.

The app already has a preserving-compatible demo pair that side-steps
this by binding the OSC cutoff control directly to `KLPF` rather than
threading it through a `KSmooth`:

- `preserve-cutoff-dark` — saw drone @ `LPF 600 Hz`, OSC at `/v0/lpf/0`.
- `preserve-cutoff-bright` — saw drone @ `LPF 2400 Hz`, same OSC
  surface.

That pair was driven manually against real audio on the post-`aca37ed`
tree, after the smoke-vocabulary slice. The run committed the
preserving phase without a stopped-audio fallback, held
`audio running: yes` and `active voices: 1` across the transition, and
accepted OSC at `/v0/lpf/0` against the auto-spawned voice both before
(`value=900.0`) and after (`value=2600.0`) the swap. As with the
fallback run, this validates the audio lifecycle and the OSC
decode/route layer only — audible output was not independently
verified.

The committed fixture at
[examples/manifests/preserve-cutoff.json](../examples/manifests/preserve-cutoff.json)
is the canonical input. Drive it through:

```
stack exec -- metasonic-bridge --manifest-live-reload-demo \
    try-preserving examples/manifests/preserve-cutoff.json \
    preserve-cutoff-dark preserve-cutoff-bright
```

The fixture is regenerable byte-for-byte with:

```
stack exec -- metasonic-bridge --authoring-manifest \
    preserve-cutoff-dark preserve-cutoff-bright \
    > examples/manifests/preserve-cutoff.json
```

`MetaSonic.Spec.AppManifestPreservingFixture` asserts the
on-disk file stays byte-identical to that command's output — a
silent drift between the demo source and the fixture fails
`just stack-test` before it can mislead an operator.

Observed transcript (ALSA device-probing warnings during start
omitted):

```
initial OSC surface:
  /<voice>/lpf/0  name="cutoff"
target OSC surface:
  /<voice>/lpf/0  name="cutoff"

initial fan-in:
  audio running: yes
  queue depth: 0
  owner status: SessionOwnerReady
  reload status: SessionFanInNormalOperation
  active voices: 1
ingress: open demo=preserve-cutoff-dark ui-controls=1 osc-controls=1 midi-cc=0 defaultVoice=v0 oscPort=7001
addressable OSC surface:
  /v0/lpf/0  (name="cutoff")

osc accept: CmdControlWrite voice=v0 tag=ControlTag {ctNodeTag = MigrationKey {unMigrationKey = "lpf"}, ctSlot = 0} value=900.0

strategy outcome: success: preserving installed (audio kept, voices preserved)
reload events:
  - strategy started: try-preserving
  - preserving phase started
  - preserving phase committed
  - strategy succeeded: preserving installed (audio kept, voices preserved)
post-reload fan-in:
  audio running: yes
  queue depth: 0
  owner status: SessionOwnerReady
  reload status: SessionFanInNormalOperation
  active voices: 1
OSC ingress: open demo=preserve-cutoff-bright ui-controls=1 osc-controls=1 midi-cc=0 defaultVoice=v0 oscPort=7001
addressable OSC surface:
  /v0/lpf/0  (name="cutoff")

osc accept: CmdControlWrite voice=v0 tag=ControlTag {ctNodeTag = MigrationKey {unMigrationKey = "lpf"}, ctSlot = 0} value=2600.0
```

OSC port `7001` rebinds cleanly after the process exits with code `0`,
so the run does not leak the listener. The fake-audio smoke and the
`MetaSonic.Spec.AppManifestOSCReloadE2E` end-to-end tests cover the
orchestrator's preserving branch on the CI side; the transcript above
is what an operator should see on the live path.

## Cross-confirmation: manual MIDI device smoke

Counterpart for the MIDI/device boundary. `--manifest-midi-reload-smoke`
opens a real PortMIDI input through `manifestPortMIDISourceFactory`,
prints the manifest's bound CC table for the selected demo, and
streams accepted / rejected events for a fixed window. It deliberately
does **not** start audio, install a hot-swap, or run reload semantics
— that surface stays on the live-reload demo above. This is the
hardware-gated equivalent of the OSC cross-confirmation: it proves
the manifest's MIDI projection routes through a real PortMIDI device.

The same blessed fixture exposes a MIDI binding on **CC 74** (GM2
"Brightness / Sound Controller 5", the standard filter-cutoff CC)
mapped to the same direct-to-`KLPF` write the OSC `/v<voice>/lpf/0`
address targets. Drive it through:

```
stack exec -- metasonic-bridge --manifest-midi-reload-smoke \
    examples/manifests/preserve-cutoff.json preserve-cutoff-dark \
    --midi-device N
```

Substitute `N` with an input-capable device id from
`stack exec -- metasonic-bridge --midi-list`. The default smoke
window is 10 seconds; use `--manifest-midi-smoke-seconds K` to
extend.

Expected output (device-table preamble varies per host; the
binding-table and accept lines do not):

```
Manifest MIDI device smoke.

  manifest path: examples/manifests/preserve-cutoff.json
  demo: preserve-cutoff-dark
  device: id=N name="..."
  window: 10 second(s)
  default MIDI voice: v0

  bound CC table:
    - cc=74 tag=lpf/0 name="cutoff" default=600.0 range=[200.0, 6000.0]

  no reload executed: this smoke exercises the open / decode /
  manifest CC routing path only.

  Send manifest-bound CCs now (and any other MIDI you want to
  observe routed through the ingress projection).
```

Send CC 74 on channel 1 with any byte value. The expected accept
line is:

```
  accept: CmdControlWrite voice=v0 tag=lpf/0 value=<scaled-cutoff-Hz>
```

`<scaled-cutoff-Hz>` lands in the `[200.0, 6000.0]` range scaled
from the 0–127 CC byte. Any other CC (e.g. 7) emits
`reject: unbound cc=7` — the manifest only binds CC 74 for this
demo. `preserve-cutoff-bright` shows the same row with
`default=2400.0`; the binding shape is identical because both
demos share the `cutoff` control declaration up to the default
value.

If `--midi-list` reports no input-capable device, the smoke exits
non-zero with an explanatory message. That is the only failure
condition: an empty event window is reported in the summary but
is **not** a failure, because a host without active MIDI traffic
is still a valid open of the manifest MIDI ingress.

Bound-CC drift on `preserve-cutoff-*` is regression-protected by
`MetaSonic.Spec.AppManifestPreservingFixture`: any change to the
demo's `rcCC` field — including dropping CC 74 — fails the
"preserve-cutoff manifest projects MIDI CC 74 on both demos"
test before it can mislead an operator reading this section.

### Loopback confirmation (ALSA Midi Through, 2026-05-20)

First end-to-end run of the section above, captured outside CI
against the ALSA Midi Through loopback rather than a hardware
controller. PortMIDI device id=1 (`name="Midi Through Port-0"`)
sits on ALSA seq port `14:0`; a 30-byte SMF carrying one CC 74
event (channel 1, value 100 = `0xB0 0x4A 0x64`) was injected via
`aplaymidi -p 14:0` after the smoke header printed. Verbatim
transcript:

```
Manifest MIDI device smoke.

  manifest path: examples/manifests/preserve-cutoff.json
  demo: preserve-cutoff-dark
  device: 1 (explicit)
  window: 6 second(s)
  default MIDI voice: v0

  bound CC table:
    - cc=74 tag=lpf/0 name="cutoff" default=600.0 range=[200.0, 6000.0]

  no reload executed: this smoke exercises the open / decode /
  manifest CC routing path only.

  Send manifest-bound CCs now (and any other MIDI you want to
  observe routed through the ingress projection).

  ingress: opened. Listening...
  accept: CmdControlWrite voice=v0 tag=lpf/0 value=4766.929133858268
  drain: items=1 queue_depth=0 stopped=Nothing

  summary:
    accepted: 1
    drained: 1
    enqueue-rejected: 0
    unbound-cc rejects: 0
    other ingress rejects: 0
    ignored non-CC events: 0
Manifest MIDI device smoke complete.
```

What the run confirmed about the real PortMIDI / ALSA path that
unit tests do not:

- `default MIDI voice:` line on a real device open matches the
  policy alignment from `6fa21ea`. The smoke header was
  `default MIDI voice: fx` before that commit and would have
  contradicted the `accept: ... voice=v0` line.
- Bound-CC table renders the fixture's CC 74 row exactly as this
  section promises, including the 600 Hz default for the dark
  variant and the `[200.0, 6000.0]` range. The bright variant's
  identical-shape promise (default = 2400.0) is implied by the
  byte-equal fixture test and was not re-verified on hardware.
- CC value scaling: 100/127 across `[200.0, 6000.0]` resolves to
  ≈ 4766.93, matching the printed accept value to within
  Double precision. The manifest layer is doing linear range
  scaling correctly.
- Single-event flow: `accept` then `drain: items=1`, summary
  reports `accepted: 1 drained: 1`. No rejects, no ignored
  events, exit code 0.

What this run did **not** verify, and what real-hardware
confirmation against a physical MIDI controller still owes:

- Multi-event behavior under sustained traffic (knob sweeps,
  rapid CC streams). Loopback injection from a static SMF file
  cannot exercise the per-event ingress drain timing the way a
  controller-held physical knob can.
- Channel filtering against a controller that defaults to a
  non-channel-1 transmit channel. The SMF used here is hard-
  coded to channel 1; the manifest's channel filter behavior
  is unit-tested but not yet hardware-confirmed.
- Real-hardware open path beyond the loopback driver. Q /
  PortMIDI's open against a hot-plugged USB MIDI device or a
  bus-detached interface is unexercised here.

The loopback confirmation is enough to declare the runbook's
accepted-event line empirically correct at the routing layer;
hardware-gated CI for the device-backed paths (the ROADMAP's
remaining open polish in this arc) is a separate question.

## Things this runbook deliberately does not cover

- Resource/allocation recovery event streaming. Still
  consumer-gated; see
  [ManifestReloadEvent Partial Coverage](2026-05-19-a-manifest-reload-event-partial-coverage.md)
  for the open work.
- The `--manifest-live-reload-demo` CLI's audio + interaction
  surface for the preserving strategies (`require-preserving` /
  `try-preserving`). The demo's own pre- / post-reload service
  snapshots, OSC accept log, and prompt flow live in its
  source; for the preserving paths this runbook captures only
  the shared-vocabulary slice (strategy outcome + reload events
  + ingress snapshot). The supervised stopped-audio path IS
  recorded end-to-end (snapshots + OSC accept log + prompt
  flow) in the "Supervised `StoppedAudioOnly` live-reload
  demo (slice 2)" section below; that's the route under active
  validation. Preserving will move under the same coverage
  shape only once the migration slice opens.
- Fixtures for non-preserving smoke targets. The preserving live-
  reload path has a committed fixture at
  [examples/manifests/preserve-cutoff.json](../examples/manifests/preserve-cutoff.json),
  regression-protected by
  `MetaSonic.Spec.AppManifestPreservingFixture`. Root
  `manifest.json` remains developer-local scratch — adding
  committed fixtures for other smoke targets (named-control,
  send-return, …) is its own decision per smoke entrypoint.

## Supervised `StoppedAudioOnly` live-reload demo (slice 2)

`--manifest-live-reload-demo stopped-audio-only` now routes
through the supervised lifecycle (factory + adapter +
`reloadSupervised` + `realStoppedAudioHostStackOps`), the same
machinery the `--manifest-host-reload-smoke` CLI uses. The
supervised route is hardware-confirmed once (transcript
below). `try-preserving` is now also supervised via a sibling
factory; see the next section. `require-preserving` remains
on the direct `reloadManifestHostWithStrategy` path; its
migration is its own slice and opens against the evidence bar
in
[2026-05-20-a-supervised-route-tier3-decision.md](2026-05-20-a-supervised-route-tier3-decision.md).

The routing decision is exposed as a pure
`selectLiveReloadRoute :: ManifestReloadHostStrategy ->
LiveReloadRoute` selector in
[`MetaSonic.App.ManifestLiveReloadDemo`](../app/MetaSonic/App/ManifestLiveReloadDemo.hs)
and pinned by three deterministic test cases in
`MetaSonic.Spec.AppManifestLiveReloadDemoRender`. Three
additional rendering tests pin the per-flavor `route:` strings
the tier-2 smoke wrappers grep on. Those tests verify the
routing and rendering /without/ staging real audio. The
audible behavior below stays manual.

### Manual run command

Either run the raw command directly:

```sh
stack exec -- metasonic-bridge --manifest-live-reload-demo \
  stopped-audio-only examples/manifests/preserve-cutoff.json \
  preserve-cutoff-dark preserve-cutoff-bright
```

(Substitute the two demo keys with any pair present in the
manifest), OR run the committed wrapper recipe which does
the same thing plus pre/post-reload OSC injection, post-exit
`ss` + active Python bind probes, and end-of-run marker
checks:

```sh
just manifest-supervised-live-smoke               # default port 17001
just manifest-supervised-live-smoke port=18001    # override port
```

The wrapper at `tools/manifest_supervised_live_smoke.sh`
exits 0 only if every acceptance marker from the table below
is observed. It is intentionally NOT a member of `just
check-offline` or any default CI gate — see the "Evidence
policy" subsection below for the tier classification.

### What the supervised live transcript must prove

The output proves the supervised route is live (not the direct
path) by these markers:

- `  strategy: stopped-audio-only`
- `  route: supervised (reloadSupervised + HostStackFactory)`
  — the new `route:` line is the load-bearing signal that the
  supervised lifecycle was selected. Its absence means the
  direct path ran.
- Initial OSC ingress opens on a non-zero port (audible via
  sending OSC to `preserve-cutoff-dark`'s control surface).
- After pressing Enter, the timeline includes the genuine
  orchestrator events: `stopped-audio phase started`,
  `stopped-audio phase committed`.
- `supervised outcome: committed (new plan installed)` — the
  supervised lifecycle's outcome line, distinct from the direct
  path's `strategy result:` wording.
- Post-reload OSC accepts on the `preserve-cutoff-bright`
  surface (e.g. `/v0/lpf/0` writes are routed).
- After the final Enter, audio stops and the OSC port is
  released (a subsequent invocation should bind cleanly).

### Real run transcript (2026-05-20)

Captured on a Fedora 41 host (Linux 6.17.10) with PipeWire +
wireplumber as the audio backend (PortAudio falls back through
ALSA's `default` PCM into PipeWire). The OSC port was bound on
`localhost:17001` via the `--session-osc-port 17001` override
so this run does not collide with the operator's everyday
`7001` workspace.

PortAudio prints a long block of `ALSA lib pcm_*` "Unknown PCM"
warnings during device enumeration before settling on the
default sink. Those are PortAudio probing every entry in the
host's `alsa.conf` and are noise, not failure — the demo's
`audio running: yes` line that follows them is the
load-bearing signal that the device actually opened. The ALSA
preamble is elided in the transcript below; everything else is
verbatim.

OSC was injected at both interactive prompts using `oscsend`
(liblo) so the transcript also proves the listener routes real
packets pre- and post-reload:

```text
oscsend localhost 17001 /v0/lpf/0 f 0.75   # before first Enter
oscsend localhost 17001 /v0/lpf/0 f 0.25   # before second Enter
```

```text
Manifest live reload demo (experimental).

  manifest path: examples/manifests/preserve-cutoff.json
  strategy: stopped-audio-only
  route: supervised (reloadSupervised + HostStackFactory)
  initial demo: preserve-cutoff-dark
  target demo: preserve-cutoff-bright
  normal demo path: unchanged
  ingress: manifest-aware OSC only

  initial OSC surface:
    /<voice>/lpf/0  name="cutoff"
  target OSC surface:
    /<voice>/lpf/0  name="cutoff"

  This path starts real audio and runs the manifest host
  strategy selector. It is still opt-in and experimental.

[...PortAudio ALSA enumeration warnings elided...]

  initial: auto-starting one instance per template...
    drone -> enqueued CmdVoiceOn (TemplateName {unTemplateName = "drone"}) (VoiceKey {unVoiceKey = "v0"}) []
  initial fan-in:
    audio running: yes
    queue depth: 0
    owner status: SessionOwnerReady
    reload status: SessionFanInNormalOperation
    active voices: 1
  ingress: open demo=preserve-cutoff-dark ui-controls=1 osc-controls=1 midi-cc=1 defaultVoice=v0 oscPort=17001
  addressable OSC surface:
    /v0/lpf/0  (name="cutoff")

  Audio is running. Send OSC to the initial surface,
  then press Enter to run the supervised reload.
  osc accept: CmdControlWrite voice=v0 tag=ControlTag {ctNodeTag = MigrationKey {unMigrationKey = "lpf"}, ctSlot = 0} value=0.75

  supervised outcome: committed (new plan installed)
  reload events:
    - stopped-audio phase started
    - stopped-audio phase committed
  post-reload: auto-starting one instance per template...
    drone -> enqueued CmdVoiceOn (TemplateName {unTemplateName = "drone"}) (VoiceKey {unVoiceKey = "v0"}) []
  post-reload fan-in:
    audio running: yes
    queue depth: 0
    owner status: SessionOwnerReady
    reload status: SessionFanInNormalOperation
    active voices: 1
  OSC ingress: open demo=preserve-cutoff-bright ui-controls=1 osc-controls=1 midi-cc=1 defaultVoice=v0 oscPort=17001
  addressable OSC surface:
    /v0/lpf/0  (name="cutoff")

  Send OSC to the surface for demo=preserve-cutoff-bright, then press Enter
  to stop audio and close ingress.
  osc accept: CmdControlWrite voice=v0 tag=ControlTag {ctNodeTag = MigrationKey {unMigrationKey = "lpf"}, ctSlot = 0} value=0.25
```

After the second Enter the demo exits and the wrapper runs
the post-exit probes. Those probes are not part of the demo's
own stdout — they are the wrapper's evidence that the
listener socket actually released:

```text
[wrapper] demo exit=0
[wrapper] ss snapshot: no UDP listener on port 17001
[wrapper] active bind probe: port 17001 rebound successfully
```

`ss -lun` is a passive snapshot of the kernel's UDP listener
table after the demo exits. The active bind probe is a fresh
Python process that calls
`socket.socket(AF_INET, SOCK_DGRAM).bind(('localhost', 17001))`
and exits 0 only on a successful bind — load-bearing because
an `oscsend` send does NOT prove the socket released (UDP
datagrams to an unbound port still succeed at the network
layer; the OS just drops them).

Acceptance checklist against the transcript and the wrapper
probe block above:

| # | Marker the run must prove | Source | Verbatim line / probe output |
|---|---|---|---|
| 1 | Supervised route selected | transcript | `route: supervised (reloadSupervised + HostStackFactory)` |
| 2 | Real audio + real OSC opened | transcript | `audio running: yes`, `oscPort=17001` |
| 3 | Pre-reload OSC accept | transcript | `osc accept: CmdControlWrite voice=v0 ... value=0.75` |
| 4 | Stopped-audio phase ran under the supervisor | transcript | `supervised outcome: committed (new plan installed)` + `stopped-audio phase started` / `stopped-audio phase committed` reload events |
| 5 | Post-reload ingress targets the new demo | transcript | `OSC ingress: open demo=preserve-cutoff-bright ... oscPort=17001`, then `osc accept: CmdControlWrite voice=v0 ... value=0.25` against the new surface |
| 6 | Cleanup releases resources | post-exit probe | `[wrapper] demo exit=0` + `[wrapper] ss snapshot: no UDP listener on port 17001` + `[wrapper] active bind probe: port 17001 rebound successfully` |

With this run on record, the §219 slice-4 routing has
transitioned from "needs hardware exercise" to
"hardware-confirmed once; hardware-gated CI still open" in
[ROADMAP.md](../ROADMAP.md) and
[notes/2026-05-14-k-host-reload-supervisor.md](2026-05-14-k-host-reload-supervisor.md).
Hardware-gated CI for this route is a separate slice and is
intentionally not opened here.

### Evidence policy

The supervised stopped-audio route's evidence stack is now
classified into three tiers. The same tiering is the gate for
migrating preserving / try-preserving onto the supervisor:

1. **Default deterministic checks.** Run everywhere, block
   normal commits / CI. In this repo: `just check-offline`
   (which runs `git diff --check` + `just stack-test` + `just
   cpp-test-offline`). The supervised route's
   routing/state-machine behavior is covered here through
   deterministic fake-IO tests (1216-case suite as of the
   §219 slice-4 close).

2. **Opt-in local live smoke.** A repeatable operator command
   that exercises real PortAudio / real UDP ingress / real
   OSC accept end-to-end against the committed
   preserve-cutoff fixture, with marker checks for each
   acceptance item the runbook names. Implemented as `just
   manifest-supervised-live-smoke` wrapping
   `tools/manifest_supervised_live_smoke.sh`. NOT a member of
   `check-offline`. Operators run this manually on a host
   with a working audio backend before promoting changes
   that touch the supervised path or before opening a
   preserving-migration slice.

3. **Hardware-backed CI (deferred, see decision below).** A
   dedicated lane that runs the live smoke on every
   relevant commit, on a machine with known audio + MIDI
   state. Strongest evidence; expensive to own. The repo's
   main CI is not yet shaped to run device-backed jobs;
   opening that lane is its own slice with its own design
   (hardware ownership, hot-plug assumptions, cleanup,
   timeouts, failure diagnosis). The current default-CI
   surface stays deterministic / offline.

The tier-3 CI-gating question is now answered in
[2026-05-20-a-supervised-route-tier3-decision.md](2026-05-20-a-supervised-route-tier3-decision.md):
tier 2 is sufficient to open the preserving / try-preserving
supervisor-migration slices, tier 3 is deferred (not
rejected), and the migration slice's evidence bar is
deterministic route tests plus a minimum of two marker-clean
tier-2 runs attached to the PR (two different hosts / audio
backends preferred when available). The reopen triggers for
tier 3 are listed in that note.

## Supervised `TryPreservingThenStoppedAudio` live-reload demo (slice 5)

`--manifest-live-reload-demo try-preserving` now routes
through the supervised lifecycle with a sibling factory:
`realTryPreservingHostStackOps` composes
`realPreservingInWindowReload` with
`realStoppedAudioInWindowReload` under the existing
`preservingAllowsStoppedAudioFallback` gate, and the
supervisor sees one classified in-window slot covering all
three `InWindowReloadOutcome` variants. The route flip landed
2026-05-20 alongside the two marker-clean tier-2 runs
recorded below.

Routing tests at
`MetaSonic.Spec.AppManifestLiveReloadDemoRender` pin
`selectLiveReloadRoute TryPreservingThenStoppedAudio` to
`LiveReloadSupervised SfTryPreserving` and pin
`renderLiveReloadRoute` for that flavor to
`supervised (try-preserving; reloadSupervised +
HostStackFactory)` — the tier-2 wrapper's marker-1 grep
depends on this exact string.

### Wrapper

`tools/manifest_supervised_try_preserving_live_smoke.sh`,
exposed as `just manifest-supervised-try-preserving-live-smoke`.
Parallel to the stopped-audio wrapper but distinct in three
ways:

* **Default port** is 17002 (vs 17001 for stopped-audio), so
  the two smokes can run in sequence without colliding and a
  stuck post-exit state on one port does not affect the
  other.
* **Artifact names** are
  `manifest-supervised-try-preserving-live-{transcript,probe}.txt`
  (vs the stopped-audio names), avoiding stale transcript
  confusion when both smokes run on the same workstation.
* **Marker checks 4b/4c** look for `preserving phase started`
  and `preserving phase committed` (the event renderings for
  `MrePreservingReloadStarted` / `MrePreservingReloadCommitted`)
  instead of the stopped-audio-phase markers. On the blessed
  preserve-cutoff fixture, preserving commits without
  fallback so no `MreStoppedAudioReload*` events fire.

Marker 1 looks for the specific try-preserving route string
above; the rest (audio + ingress + OSC accept + post-reload +
exit + ss + active bind probe) are identical to the
stopped-audio wrapper.

### Tier-2 evidence record (2026-05-20)

Two marker-clean runs of
`just manifest-supervised-try-preserving-live-smoke` on host
RME ADI-2 Pro / PipeWire, plus one no-regression confirmation
run of `just manifest-supervised-live-smoke` on the same host.
Transcripts + probe logs captured locally for the PR record
(not committed because the per-run timestamps differ
trivially):

* `try-preserving-run-1-transcript.txt` /
  `try-preserving-run-1-probe.txt` — 12/12 markers passed.
  Confirms one observation of the new route under
  marker-clean conditions.
* `try-preserving-run-2-transcript.txt` /
  `try-preserving-run-2-probe.txt` — 12/12 markers passed.
  Second observation, per the tier-3 decision note's "minimum
  two runs to count as evidence" rule.
* `stopped-audio-confirmation-transcript.txt` /
  `stopped-audio-confirmation-probe.txt` — 12/12 markers
  passed on the stopped-audio wrapper, confirming the
  shared-helper rename (`runSupervisedLiveReload` →
  `runSupervisedStoppedAudioLiveReload`) and the
  route-rendering change did not regress the stopped-audio
  path's acceptance markers.

Both routes share the same supervisor + adapter machinery, so
a regression in either would propagate; running both wrappers
in sequence is the operator gate before promoting any
shared-machinery change.
