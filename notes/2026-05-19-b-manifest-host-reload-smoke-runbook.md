## --manifest-host-reload-smoke Operator Runbook

Date: 2026-05-19

Status: operator-facing runbook. Companion to
[ManifestReloadEvent Partial Coverage](2026-05-19-a-manifest-reload-event-partial-coverage.md),
which records the API shape and the consumer-gating decisions. This
note records what the smoke prints, how to read it, and the
known-good output for the fallback path. Not a design pin.

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

What the run confirmed against real hardware that the
fake-audio smoke cannot:

- PortAudio start / wait / stop through `defaultSessionFanInAudioFFI`
  on ALSA. The device-probing warnings printed during start were
  harmless; the host reported `audio running: yes` and held it across
  the reload.
- Real UDP OSC ingress bound on `oscPort=7001`. Packets to
  `/v0/vol/1` and `/v0/cutoff/1` were accepted before the reload;
  `/v0/vol/1` was accepted again after the reload, proving the
  swapped target's OSC projection was live.
- The typed `reload events:` block rendered character-for-character
  identically to the fake-audio smoke output above (same event order,
  same kebab-case stage tags, same `preserving rejected (...)` /
  `stopped-audio fallback installed` outcome line).
- `active voices: 1` before and after the reload, with `Enter` ending
  the demo in process exit 0 and no port held.

Notable: a `named-control → named-control` self-reload still took the
fallback path (`preserving rejected (reload-rejected (old owner still
installed)), stopped-audio fallback installed`). The reason is the
same as the fake-audio smoke's fallback: the live demo's auto-spawned
initial voice carries no migration metadata the preserving command
can land against, so the orchestrator collapses to stopped-audio
fallback. A true `MrhsrPreserving` outcome on real audio still
requires an OLD/NEW pair whose live controls share migration keys
(the `hotSwapEdit` shape from the test suite) on a manifest that
exposes them. The runbook does not pin a known-good output for that
path because it has not been driven through the live demo manually
yet; the fake-audio smoke covers the orchestrator branch.

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
- A real committed fixture. `manifest.json` at the repo root is a
  developer-local scratch input; replacing it with a versioned
  fixture is a separate decision (and would mean nailing down
  which authoring manifest is the canonical smoke input).
- A known-good output for the true preserving path on real audio.
  Would require a manifest exposing an OLD/NEW pair with shared
  migration keys on a live control; not pinned yet.
