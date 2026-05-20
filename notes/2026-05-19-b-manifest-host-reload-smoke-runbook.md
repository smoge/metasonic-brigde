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

## Things this runbook deliberately does not cover

- Resource/allocation recovery event streaming. Still
  consumer-gated; see
  [ManifestReloadEvent Partial Coverage](2026-05-19-a-manifest-reload-event-partial-coverage.md)
  for the open work.
- The `--manifest-live-reload-demo` CLI's audio + interaction
  surface beyond the cross-confirmation above. The demo's own
  pre- / post-reload service snapshots, OSC accept log, and prompt
  flow live in its source; this runbook captures only the
  shared-vocabulary slice (strategy outcome + reload events +
  ingress snapshot).
- Fixtures for non-preserving smoke targets. The preserving live-
  reload path has a committed fixture at
  [examples/manifests/preserve-cutoff.json](../examples/manifests/preserve-cutoff.json),
  regression-protected by
  `MetaSonic.Spec.AppManifestPreservingFixture`. Root
  `manifest.json` remains developer-local scratch — adding
  committed fixtures for other smoke targets (named-control,
  send-return, …) is its own decision per smoke entrypoint.
