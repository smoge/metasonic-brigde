# Live-session MIDI values manual test — 2026-05-25

Status: passed for software ALSA / PortMIDI ingress via `sclang`.
Physical-controller and VMPK-GUI-specific behavior remain separate
watch items.

Manual software-device evidence for `--manifest-live-session
… --strategy try-preserving --midi-device 1` against
`examples/manifests/preserve-cutoff.json`, covering bound CC 74
acceptance, the carried-value semantics across a preserving
reload, and clean shutdown.

Driver script: [sc/live-session-midi-values.scd](../sc/live-session-midi-values.scd).
This run used the interactive helpers
(`~metaSonicSendInitialBatch.value` / `~metaSonicSendPostReload.value`)
from the SuperCollider IDE rather than the auto-firing routine, so
the transcript shows four `midi accept` lines rather than two — see
note (a) below.

## Invocation

```sh
stack exec -- metasonic-bridge \
  --session-osc-port 17011 \
  --manifest-live-session examples/manifests/preserve-cutoff.json \
  preserve-cutoff-dark \
  --strategy try-preserving \
  --midi-device 1
```

Reported route: `supervised (try-preserving; reloadSupervised +
HostStackFactory)`. ALSA stderr noise from PortAudio's device-table
probe is elided below.

## Evidence per item

### 1. Live session opened with `midi=on` on device 1

```
ingress: open demo=preserve-cutoff-dark ui-controls=1 osc-controls=1
        midi-cc=1 defaultVoice=v0 oscPort=17011 midi=on
addressable OSC surface:
  /v0/lpf/0  (name="cutoff", default=600.0, range=[200.0, 6000.0], cc=74)
```

### 2. Pre-reload CC 74 accepted, `source=accepted` on dark plan

`~metaSonicSendInitialBatch` sends CC 74 = 90 → 4310.236 inside
`[200.0, 6000.0]`:

```
midi accept: /v0/lpf/0 name="cutoff" value=4310.23622
> values
  values for preserve-cutoff-dark:
    /v0/lpf/0 name="cutoff" value=4310.23622 source=accepted
              default=600.0 range=[200.0, 6000.0] cc=74
```

### 3. Carried MIDI-written value survived the reload

`~metaSonicSendPostReload` sends CC 74 = 64 → 3122.834 _while
still on the dark plan_ (the helper name is historical — the
ordering that proves carry-across-reload requires this send to
happen pre-reload):

```
midi accept: /v0/lpf/0 name="cutoff" value=3122.834646
> demo:preserve-cutoff-bright
```

### 4. Preserving reload committed to `preserve-cutoff-bright`

```
supervised outcome: committed (new plan installed)
reload events:
  - preserving phase started
  - preserving phase committed
retired bindings:
  (none)
supervisor events:
  - in-window: started
  - in-window: committed
resource timeline:
  - in-window reload committed
  - serving plan: preserve-cutoff-bright
```

`try-preserving` committed on the preserving phase; no
stopped-audio fallback engaged.

### 5. Carried value survived across reload

```
> values
  values for preserve-cutoff-bright:
    /v0/lpf/0 name="cutoff" value=3122.834646 source=accepted
              default=2400.0 range=[200.0, 6000.0] cc=74
```

`default=2400.0` (vs the dark plan's 600.0) confirms the active
plan really did change to bright, while the MIDI-written value
3122.834 persisted as `source=accepted`.

### 6. Post-reload CC 74 accepted on the bright plan; values updated

```
midi accept: /v0/lpf/0 name="cutoff" value=4310.23622
> values
  values for preserve-cutoff-bright:
    /v0/lpf/0 name="cutoff" value=4310.23622 source=accepted
              default=2400.0 range=[200.0, 6000.0] cc=74
```

### 7. Status healthy, quit terminated cleanly

```
> status
  status:
    current plan demo: preserve-cutoff-bright
    fan-in:
      audio running: yes
      queue depth: 0
      owner status: SessionOwnerReady
      reload status: SessionFanInNormalOperation
      active voices: 1
    ingress:      open demo=preserve-cutoff-bright … midi=on
    last outcome: committed (new plan installed)

> quit

  Terminating session.
```

## Notes

(a) **Interactive vs. scripted flow.** The transcript came from
the SuperCollider IDE running the helper closures manually, not
from `sclang sc/live-session-midi-values.scd`. The latter would
fire `~metaSonicRunReplay` once (two CCs, 30 s apart) and would
not auto-exit unless `~metaSonicQuitWhenDone` is flipped to
`true`. The seven evidence items above are reproducible from
either flow; the interactive version gives finer control over
when each CC lands relative to the reload command.

(b) **CC scaling sanity.** With CC 74 mapped onto
`[200.0, 6000.0]` linearly: 90/127·5800+200 = 4310.236,
64/127·5800+200 = 3122.834. Matches the observed `value=` field
on every `midi accept`.

(c) **What this rules in.** `--manifest-live-session` with
`--midi-device` on this fixture: opens MIDI ingress, accepts
bound CC 74 against the planned `cutoff` control, commits a
`try-preserving` reload to a sibling demo on the same manifest,
carries `source=accepted` values across the reload, accepts
further CC writes against the new plan, reports a healthy
status, and exits cleanly on `quit`.

(d) **What this does not cover.** Physical controller behavior,
VMPK-GUI-specific behavior, the reject path (a different fixture,
e.g. `reject-preserving-delay-dark`), unbound CC rejection (the
optional `~metaSonicSendRejectedProbe` helper exists but was not
exercised in this run), `repair` after a terminal divergence, and
`set TAG V` UI writes. None of those are blocking for the seven
listed items.

## Cross-refs

- [sc/live-session-midi-values.scd](../sc/live-session-midi-values.scd)
  — driver script and replay instructions.
- [notes/2026-05-20-b-manifest-live-session-v0.md](2026-05-20-b-manifest-live-session-v0.md)
  — live-session shell design.
- [notes/2026-05-19-b-manifest-host-reload-smoke-runbook.md](2026-05-19-b-manifest-host-reload-smoke-runbook.md)
  — sibling runbook for the audible live-reload smokes.
- [notes/2026-05-25-i-live-app-manifest-reload-policy.md](2026-05-25-i-live-app-manifest-reload-policy.md)
  — live-app reload policy boundary; carried-value behavior
  exercised here is the substrate this policy sits on.
- [notes/2026-05-25-j-app-mode-surface-audit.md](2026-05-25-j-app-mode-surface-audit.md)
  — `--manifest-live-session` classified as P/op; this run is
  one of the operator confirmations behind that classification.
