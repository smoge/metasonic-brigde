# Saw-Preserving Audible Runbook

Date: 2026-05-16

Status: forward-looking runbook for the manual audible verification
of the `preserve-cutoff-dark` / `preserve-cutoff-bright` pair landed
earlier this session. Tests pass machine-side; this note covers what
to check by ear before treating the audible-preserving claim as
operator-confirmed.

## What this pair is

App-side preserving hot-swap demos backed by new graphs in
[app/MetaSonic/App/Demos.hs](../app/MetaSonic/App/Demos.hs):

- **`dronePreserveSawDark`** — saw @ 220 Hz → LPF cutoff 600 Hz →
  scalar gain 0.2 → out 0. Tagged `"carrier"` on the saw, `"lpf"` on
  the LPF.
- **`dronePreserveSawBright`** — same shape, LPF cutoff 2400 Hz.
- Both compile to a single `"drone"` template, share migration keys,
  and migrate cleanly under `try-preserving`.
- Both authoring reports declare one OSC control: display name
  `"cutoff"`, bound directly to `MigrationKey "lpf"` slot 0
  (KLPF cutoff input). Unsmoothed by design — KSmooth is
  `PreserveUnsupported` and would make the preserving reload reject.

The earlier `preserve-cutoff` / `preserve-vol` keys are gone; this
pair replaces them.

## Manifest export

Generate the doc that the live demo consumes:

```sh
stack exec -- metasonic-bridge --authoring-manifest \
  preserve-cutoff-dark preserve-cutoff-bright \
  > /tmp/preserve-saw-manifest.json
```

Both demos should appear with one control each: `name: "cutoff"`,
`key: "lpf"`, `slot: 0`, `smoothingHz: 0` (the zero is intentional —
flags the binding as direct/unsmoothed).

## Live demo invocation

```sh
stack exec -- metasonic-bridge \
  --session-osc-port 7001 \
  --manifest-live-reload-demo try-preserving \
  /tmp/preserve-saw-manifest.json \
  preserve-cutoff-dark \
  preserve-cutoff-bright
```

Expected printed surface before pressing Enter:

```
initial OSC surface:
  /<voice>/lpf/0  name="cutoff"
target OSC surface:
  /<voice>/lpf/0  name="cutoff"
...
addressable OSC surface:
  /v0/lpf/0  (name="cutoff")
```

## OSC sweep from a second terminal

```sh
# Pre-reload (dark, baseline 600 Hz LPF): brighten / dull
python3 tools/send_osc.py --port 7001 --address /v0/lpf/0 --value 400
python3 tools/send_osc.py --port 7001 --address /v0/lpf/0 --value 3000

# Press Enter in the demo terminal — preserving reload to bright.

# Post-reload (bright, baseline 2400 Hz LPF): same address works.
python3 tools/send_osc.py --port 7001 --address /v0/lpf/0 --value 600
python3 tools/send_osc.py --port 7001 --address /v0/lpf/0 --value 5000

# Press Enter to stop.
```

## What to listen / look for

- **Saw timbre changes audibly when sweeping `/v0/lpf/0`.** Saw has
  strong harmonics above 200 Hz, so cutoff sweeps in the 400–5000 Hz
  band are unambiguous by ear (unlike the previous sine-based pair,
  where 1500 → 3000 Hz LPF on a 220 Hz sine was effectively silent).
  **This sweep — before and after the reload — is the audible
  verification.** Pressing Enter alone preserves the live cutoff
  value by design (see below); the audible delta is what the OSC
  sweep produces, not what Enter produces.
- **Strategy outcome line reads** `success: preserving installed
  (audio kept, voices preserved)` — not the stopped-audio fallback.
- **No audio gap across the reload, and timbre is preserved.**
  The drone keeps playing through Enter at whatever cutoff was last
  written via OSC (or the dark baseline 600 Hz if no OSC writes
  arrived). The bright graph's 2400 Hz baseline does *not* take
  effect: the preserving migration copies the old live LPF control
  vector into the new node (see the `MigrationCopy` loop in
  `apply_migration` in `tinysynth/rt_graph.cpp`, which does the
  `std::copy(old_controls..., new_controls...)`;
  `copy_instance_lifecycle` is a sibling step that copies slot
  lifecycle fields, not control values), and the same
  `MigrationKey "lpf"` tag on both graphs makes the copy match. The audible check is the OSC sweep, not Enter.
- **`osc accept:` lines** print for every sent packet, before and
  after the reload, against `/v0/lpf/0`.
- **Post-reload fan-in** reports `active voices: 1` (the auto-spawn
  drone) and the addressable surface still lists `/v0/lpf/0`.

## What would indicate a regression

- `strategy outcome:` line classified as `preserving rejected (...),
  stopped-audio fallback installed` — preserving compatibility broke
  somewhere (graph shape, migration keys, or KSmooth crept in).
- `osc reject (manifest):` for `/v0/lpf/0` — manifest projection
  drifted; the addressable surface no longer matches the wire format.
- Audible click or silence across Enter — preserving migration
  failed in a way the strategy did not catch.
- No timbre change when sweeping `/v0/lpf/0` — the OSC control is
  not actually routed to KLPF slot 0 (e.g. someone wrapped it in
  Auth.control / KSmooth and broke the direct binding).

## Related machine-side coverage

- [test/MetaSonic/Spec/AppManifestOSCReloadE2E.hs](../test/MetaSonic/Spec/AppManifestOSCReloadE2E.hs) —
  `testCase "TryPreservingThenStoppedAudio commits MrhsrPreserving
  against demoTable-derived catalog with /v0/lpf/0 surface before
  and after"` pins: `Right MrhsrPreserving`, no `AudioStop`, voice
  survives, new graph installed, both ingress targets expose
  `/v0/lpf/0` with display name `"cutoff"`, and a post-reload UDP
  packet to the new listener accepts at the manifest layer.
- [test/MetaSonic/Spec/AppDemos.hs](../test/MetaSonic/Spec/AppDemos.hs) —
  catalog-list pinning, manifest projection, plan round-trip for the
  new keys.

## What this runbook does not cover

- **Smoothed authored controls across preserving reload.** KSmooth
  is `PreserveUnsupported` (RTGraphAdapter.hs `preservingHotSwapNodeClass`);
  a smoothed `cutoff` would have to wait until KSmooth becomes
  preservable, or a different smoother kind lands.
- **Stopped-audio fallback for this pair.** Should never fire here
  because the pair is preserving-compatible by construction; if you
  want to exercise the fallback path, use a shape-incompatible pair
  like `named-control` → `send-return`.
- **MIDI ingress.** Out of scope; this runbook is OSC-only.
