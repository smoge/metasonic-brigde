# App-mode surface audit

Companion to the README operator-flow sync. Classifies every
`RunMode` constructor in `app/Main.hs` and every live-smoke
recipe in `justfile` so the older design-review risk — app-mode
sprawl with unclear retirement criteria — has a concrete answer
per mode. Nothing in ROADMAP is misleading today; this note is
the new home for retirement intent, not a correction.

The four categories used below:

- **P/op** — permanent user/operator command. Part of the
  intended long-term surface; do not retire.
- **P/diag** — permanent diagnostic. Stable regression / CI /
  inspection surface; do not retire.
- **T/proof** — temporary proof-of-mechanism smoke with a stated
  retirement condition. Lands the path; retires when the larger
  caller subsumes it.
- **HW/manual** — hardware-gated manual validation. Lives until
  a hardware-gated CI lane exists (ROADMAP currently gates that
  as future work).

A mode can be both T/proof and HW/manual (e.g. the device-backed
MIDI smoke); the retirement clock then runs against whichever
condition triggers first.

## `RunMode` classification

| Mode constructor                  | Flag                                          | Class               |
|-----------------------------------|-----------------------------------------------|---------------------|
| `AudioOnly`                       | *(default)* / `--audio-only`                  | P/op                |
| `InspectThenRun`                  | `--inspect`                                   | P/op                |
| `InspectOnly`                     | `--inspect-only`                              | P/op                |
| `OscListen`                       | `--osc-listen [PORT]`                         | P/op                |
| `ManifestLiveSession`             | `--manifest-live-session …`                   | P/op                |
| `MidiList`                        | `--midi-list`                                 | P/diag              |
| `PluginList`                      | `--plugin-list`                               | P/diag              |
| `FusionSurvey`                    | `--fusion-survey`                             | P/diag              |
| `WorkerBench`                     | `--worker-bench`                              | P/diag              |
| `SwapBench`                       | `--swap-bench`                                | P/diag              |
| `CorpusSurvey`                    | `--corpus-survey`                             | P/diag              |
| `FusionCostLab`                   | `--fusion-cost-lab [--summary]`               | P/diag              |
| `SnapshotCheck`                   | `--snapshot-check`                            | P/diag              |
| `AuthoringManifest`               | `--authoring-manifest`                        | P/diag              |
| `ManifestReloadDiagnostic`        | `--manifest-reload-plan DEMO`                 | P/diag              |
| `ManifestReloadFileDiagnostic`    | `--manifest-reload-plan-file …`               | P/diag              |
| `SessionMidiArbitrationSmoke`     | `--session-midi-arbitration-smoke`            | P/diag              |
| `ManifestSessionSmoke`            | `--manifest-session-smoke …`                  | T/proof             |
| `ManifestStoppedAudioReloadSmoke` | `--manifest-stopped-audio-reload-smoke …`     | T/proof             |
| `ManifestHostStrategyReloadSmoke` | `--manifest-host-reload-smoke STRATEGY …`     | T/proof + HW/manual |
| `ManifestLiveReloadDemo`          | `--manifest-live-reload-demo STRATEGY …`      | T/proof + HW/manual |
| `ManifestMIDIReloadSmoke`         | `--manifest-midi-reload-smoke …`              | T/proof + HW/manual |
| `SessionMidiSmoke`                | `--session-midi-smoke [SECONDS]`              | HW/manual           |
| `SessionOscArbitrationSmoke`      | `--session-osc-arbitration-smoke [SECONDS]`   | HW/manual           |

### Permanent-class notes

- `ManifestLiveSession` — strategic target; everything below feeds
  into it.
- `SessionMidiArbitrationSmoke` — scripted, exits non-zero on
  counter mismatch; CI-suitable as-is.

### Retirement conditions

- **`ManifestSessionSmoke`** — Live-session proves fresh-owner
  construction on the same fixtures end-to-end.
- **`ManifestStoppedAudioReloadSmoke`** — The supervised stack
  subsumes the direct `reloadManifestSessionStoppedAudio` helper
  for non-audio coverage.
- **`ManifestHostStrategyReloadSmoke`** — A script-friendly
  policy/native harness covers all three strategies with real
  ingress and the same event assertions this smoke pins.
  Live-session is real-audio and is **not** a drop-in replacement
  for this fake-audio all-strategy probe — until such a harness
  exists, treat this smoke as the de-facto non-audio all-strategy
  runner. (Binds real UDP today — moved to the opt-in bucket in
  README.)
- **`ManifestLiveReloadDemo`** — Live-session is treated as the
  canonical audible reload entrypoint (the v0 note already calls
  live-session its open-ended counterpart). Both are real-audio,
  so live-session is a defensible drop-in.
- **`ManifestMIDIReloadSmoke`** — Live-session with `--midi-device`
  audibly covers manifest MIDI ingress against the same fixtures
  (e.g. `preserve-cutoff.json` CC 74 → KLPF).
- **`SessionMidiSmoke`** — Migrate to a hardware-gated CI lane
  that preserves the non-audio PortMIDI → producer → listener →
  fan-in probe shape. Live-session with `--midi-device` is a
  stronger operator path but is real-audio + manifest-driven and
  is **not** a drop-in replacement for this lower-level substrate
  health check.
- **`SessionOscArbitrationSmoke`** — Migrate to a hardware-gated
  CI lane that preserves the non-audio UDP → listener →
  arbitration → fan-in probe shape. Live-session opt-in via
  `LiveArbitrationProfile` will exercise the rejection path
  audibly but is **not** a drop-in for this lower-level non-audio
  arbitration probe.

## `justfile` live-smoke wrappers

All five live-smoke recipes (`manifest-supervised-live-smoke`,
`manifest-supervised-try-preserving-live-smoke`,
`manifest-supervised-require-preserving-live-smoke`,
`manifest-live-session-require-preserving-smoke`,
`manifest-live-session-require-preserving-reject-smoke`) are
**HW/manual**. They are intentionally not members of
`check-offline` or any default CI gate (the recipes themselves
say so). Each carries acceptance markers verified by its wrapper
script under `tools/`.

Retirement condition for the wrapper layer is collective: once a
hardware-gated CI lane lands (ROADMAP gates this with the rest of
the audible-smoke + PortMIDI-device-open work), these recipes
migrate from `justfile` into that lane and the audible markers
become the lane's success criteria. Until then they stay as
operator-runnable regression confirmations.

The five recipes do not need individual retirement criteria —
they are the same shape pinned against different supervised host
stacks (`realStoppedAudio…` / `realTryPreserving…` /
`realPreserving…`) and against the two shells (live-reload-demo
two-shot vs live-session open-ended, accept and reject branches).

## What this audit does not change

- No ROADMAP edit. The "Current decision" paragraph already
  describes the substrate honestly; it does not promise any of
  the T/proof modes are permanent.
- No `app/Main.hs` edit. Help-text wording is accurate against
  what each mode does today.
- No retirement happens here. The T/proof modes stay until their
  larger caller actually subsumes them; this note records the
  intent so the next slice that adds a live-session feature
  knows which legacy mode is the one to retire alongside it.

## Cross-refs

- [README operator flows](../README.md#operator-flows) — the
  three-bucket runtime guidance this classification underwrites.
- [notes/2026-05-20-b-manifest-live-session-v0.md](2026-05-20-b-manifest-live-session-v0.md)
  — calls live-session the open-ended counterpart of
  `--manifest-live-reload-demo`; primary input to the T/proof
  retirement criteria above.
- [notes/2026-05-25-i-live-app-manifest-reload-policy.md](2026-05-25-i-live-app-manifest-reload-policy.md)
  — `LiveArbitrationProfile` is the field through which the two
  arbitration smokes eventually retire.
- [notes/2026-05-19-b-manifest-host-reload-smoke-runbook.md](2026-05-19-b-manifest-host-reload-smoke-runbook.md)
  — acceptance markers shared by the `justfile` live-smoke
  recipes.
- ROADMAP "Current decision" paragraph at
  [ROADMAP.md:4275](../ROADMAP.md) — list of gated future work
  the HW/manual lane retirement depends on.
