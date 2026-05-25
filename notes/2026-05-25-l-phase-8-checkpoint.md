# Phase 8 checkpoint — 2026-05-25

Natural pause point for the live-session / live-app reload policy
arc. The next lane is C++-runtime work (§4.E.2 deterministic bus
reduction execution); this note exists so that lane starts with
an unambiguous "what is closed, what is gated" reference instead
of having to reconstruct it from `git log`.

## Commit range

`71476d8` → `9a2f9dc` (12 commits):

| Commit    | Subject |
|-----------|---------|
| `71476d8` | Add design note scoping the live-app manifest reload policy owner |
| `94ef215` | Add live-app reload policy projector |
| `012781b` | Wire runManifestLiveSession through LiveAppReloadPolicy |
| `92a1137` | Doc-sync Current decision + policy note for the live-app policy boundary |
| `d112a53` | Cover rrhsiBuildIngressOps profile threading with a real-host fixture |
| `e457cfa` | Doc-sync policy boundary as coverage-closed after d112a53 |
| `721f50d` | Bucket Phase 8 app test list for reviewability |
| `7110c8f` | Sync README operator flow docs |
| `1e6ac2c` | Document app modes and add MIDI replay script |
| `d1909b4` | Refine live-session MIDI replay script |
| `a428381` | Record live-session MIDI values manual pass |
| `9a2f9dc` | Sync roadmap to MIDI values manual pass |

## What landed

- **Live-app reload policy boundary**
  (`MetaSonic.App.ManifestLivePolicy`): pure
  `LiveAppReloadPolicy` record, runtime `LiveAppReloadContext`,
  `projectLiveAppReloadPolicy`, and the policy-native
  `runManifestLiveSessionWithPolicy` entrypoint. `Main` now
  constructs an explicit policy and routes through it; the older
  `runManifestLiveSession` stays as a thin compatibility wrapper.
- **Policy boundary test coverage**: `AppManifestLivePolicy`
  spec covers the behavioral surface, including a real-host
  `withSessionFanInHost` fixture proving the policy's ingress
  profile actually reaches the context builder
  (`rrhsiBuildIngressOps` threading).
- **Documentation alignment**: ROADMAP "Current decision"
  paragraph + the i-note both describe the boundary as the
  landed shape and name every gated future feature. README
  command table extended to the current operator commands;
  three-bucket "Operator flows" section folded into the CLI
  area; "intentionally absent" paragraph rewritten to match the
  landed/gated split.
- **App-mode surface audit** (j-note): classified every
  `RunMode` constructor + `justfile` live-smoke wrapper as P/op
  / P/diag / T/proof / HW/manual with explicit retirement
  conditions; `--manifest-host-reload-smoke` reclassified as
  opt-in (binds real UDP) and the lower-level non-audio
  substrate probes (`--session-midi-smoke`,
  `--session-osc-arbitration-smoke`) reclassified as pure
  HW/manual rather than T/proof (live-session is real-audio and
  is not a drop-in for them).
- **Software ALSA / PortMIDI live-session evidence**: the
  repeatable [sc/live-session-midi-values.scd](../sc/live-session-midi-values.scd)
  replay script + the [k-note](2026-05-25-k-live-session-midi-values-manual-test.md)
  durable manual pass: `midi=on` open on device 1, bound CC 74
  accepted with `source=accepted`, preserving reload to
  `preserve-cutoff-bright` committed, MIDI-written value
  survived across reload (`default=2400.0` confirms plan change,
  value persists), post-reload CC accepted on the new plan,
  healthy status, clean quit.

## What is closed

- **Live-app reload policy boundary as a behavioral surface.**
  The boundary exists, is constructed by `Main`, is exercised
  by a real-host fixture, and is documented as the seam GUI
  consumers will eventually plug into.
- **Software ALSA / PortMIDI live-session `values` semantics.**
  Bound CC acceptance, carried-value persistence across a
  preserving reload, and clean shutdown are confirmed end-to-end
  on this fixture via a repeatable sclang replay script.
- **Documentation surface for the current substrate.** README,
  ROADMAP, and the supporting notes are mutually consistent
  about what's landed and what's gated. No drift to chase.

## What remains gated

Gated on a concrete caller (no speculative implementation):

- **GUI policy producer.** The boundary lands, but no GUI
  constructs a `LiveAppReloadPolicy` yet.
- **Dynamic per-reload resolver use.** Today's resolver is
  consulted once against the initial demo.
- **Live arbitration opt-in** via the policy's existing
  `LiveArbitrationProfile` field.
- **Runtime resource overrides.**
- **Arbitration policy mutation** (claim release / owner
  clearing).
- **Graph allocation event family**
  (`ManifestReloadGraphEvent`).
- **Voice allocation event family**
  (`SessionVoiceAllocationEvent`).

Gated on hardware:

- **Physical-controller confirmation** for the same
  `hasDevice == True` operator boundary.
- **VMPK-GUI-specific behavior** on the same boundary.
- **Hardware-gated CI lane** for the five `justfile`
  live-smoke wrappers and the audible reload smokes.

These categories are mirrored in ROADMAP's "Current decision"
paragraph and in the residual-watch language above the §4.E.2
work; no rewording needed.

## Next lane recommendation

**§4.E.2 deterministic bus reduction execution.** The committed
design note
[notes/2026-05-08-b-deterministic-bus-reduction-design.md](2026-05-08-b-deterministic-bus-reduction-design.md)
(commit `9637005`) pins the writer-slot-keyed contribution
contract, the global block schedule shape, the banded view
(Barrier vs FreeLayer), and the phased plan A → B → C0 → C → D
with I-4 strong in v1. The contract is ahead of the C++
implementation; the next slice should be a read-only scoping
pass over the design note + current C++
`build_global_schedule` / `build_global_schedule_bands` /
`ScheduleWorkerPool` code + the Haskell lowering and tests, then
a precisely-named slice — not implementation-first.

This lane is intentionally outside the live-session / policy
scope. Session-policy context should not pollute it; treat the
checkpoint as the separator.

## Cross-refs

- [notes/2026-05-08-b-deterministic-bus-reduction-design.md](2026-05-08-b-deterministic-bus-reduction-design.md)
  — §4.E.2 design contract; primary input for the next lane.
- [notes/2026-05-25-i-live-app-manifest-reload-policy.md](2026-05-25-i-live-app-manifest-reload-policy.md)
  — live-app reload policy boundary design.
- [notes/2026-05-25-j-app-mode-surface-audit.md](2026-05-25-j-app-mode-surface-audit.md)
  — app-mode classification + retirement criteria.
- [notes/2026-05-25-k-live-session-midi-values-manual-test.md](2026-05-25-k-live-session-midi-values-manual-test.md)
  — software ALSA / PortMIDI manual evidence.
- [ROADMAP.md](../ROADMAP.md) "Current decision" paragraph —
  authoritative list of gated future work, mirrored above.
