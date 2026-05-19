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

## Things this runbook deliberately does not cover

- Resource/allocation recovery event streaming. Still
  consumer-gated; see
  [ManifestReloadEvent Partial Coverage](2026-05-19-a-manifest-reload-event-partial-coverage.md)
  for the open work.
- A device-backed live reload. That path is
  `--manifest-live-reload-demo`, not this smoke; the smoke's fake
  audio FFI is intentional.
- A real committed fixture. `manifest.json` at the repo root is a
  developer-local scratch input; replacing it with a versioned
  fixture is a separate decision (and would mean nailing down
  which authoring manifest is the canonical smoke input).
