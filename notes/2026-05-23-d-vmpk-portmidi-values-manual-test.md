# VMPK / PortMIDI `values` Manual Test

Status: ready to run.

This note records the manual verification path for Phase 8h step 3c:
live-session `values` must update from real PortMIDI MIDI CC input,
not only from OSC or pure test seams.

## Purpose

Verify that a virtual MIDI controller can drive the manifest live
session through PortMIDI and that the operator-facing `values`
snapshot reflects accepted MIDI control writes.

The target manifest is:

```sh
examples/manifests/saw-noise-filter.json
```

The target controls are:

- CC 74 -> `/v0/lpf/0` cutoff
- CC 71 -> `/v0/lpf/1` q
- CC 7 -> `/v0/gain/0` level

## One-Time Setup

Install VMPK and ALSA tools if needed:

```sh
sudo dnf install vmpk alsa-utils
```

If VMPK does not expose a usable ALSA MIDI port on its own, load the
virtual MIDI driver:

```sh
sudo modprobe snd-virmidi
```

## Terminal A: Start VMPK

Start VMPK:

```sh
vmpk
```

In VMPK:

1. Open the MIDI connection/settings dialog.
2. Select an ALSA MIDI output port.
3. Prefer a port name that is easy to recognize in `aconnect -o` and
   `--midi-list`.
4. Open VMPK's controller/CC controls.
5. Prepare to send CC 74, CC 71, and CC 7.

Optional diagnostic:

```sh
aconnect -o
```

Confirm that VMPK has an output port.

## Terminal B: Find The PortMIDI Device

From the repository root:

```sh
stack exec -- metasonic-bridge --midi-list
```

Also inspect ALSA's view:

```sh
aconnect -o
```

Choose the PortMIDI device id that corresponds to VMPK's ALSA MIDI
output. Call that id `N`.

If the live session later aborts with:

```text
no input device for --midi-device N
```

then the selected id is wrong or VMPK is not exposing an input-readable
PortMIDI endpoint.

## Optional: bad-device-id check

Before the main run, confirm the startup-error renderer fires
end-to-end. Pick a device id absent from `--midi-list`, for example
`2147483647` (the canonical "never a real device" value across hosts):

```sh
stack exec -- metasonic-bridge --midi-device 2147483647 --session-osc-port 17005 --manifest-live-session examples/manifests/saw-noise-filter.json saw-filter-dark --strategy require-preserving
```

Expected: the process exits with

```text
no input device for --midi-device 2147483647
```

Not `ingress-open-failed`. That generic collapse would mean the
`projectInitialIngressFailure` seam in `runSupervised` didn't fire —
report it as a 3c regression rather than skipping the check.

## Optional: no-MIDI baseline

Run the same command **without** `--midi-device`:

```sh
stack exec -- metasonic-bridge --session-osc-port 17005 --manifest-live-session examples/manifests/saw-noise-filter.json saw-filter-dark --strategy require-preserving
```

Expected:

- the startup ingress line ends with `midi=off`
- no `midi accept` lines appear regardless of VMPK activity
- `values` shows defaults indefinitely

Confirms the `Nothing` branch of the combined ingress ops. Exit cleanly
with `quit` before the main run below.

## Terminal B: Start The Live Session

Use a fresh transcript path:

```sh
script -q /tmp/metasonic-live-session-8h-3c-vmpk.log -c 'stack exec -- metasonic-bridge --session-osc-port 17005 --midi-device N --manifest-live-session examples/manifests/saw-noise-filter.json saw-filter-dark --strategy require-preserving'
```

Replace `N` with the chosen PortMIDI device id.

At startup, confirm the live ingress line ends with `midi=on`. The same
command run without `--midi-device` should show `midi=off` (see the
no-MIDI baseline above). Both tokens are exercised by the renderer
tests in step 6a; the manual pass pins them against real PortMIDI.

## Baseline Values

In the live shell, run `controls` first to pin the addressable surface
the manifest declares — that confirms the expected `values` row count
matches what `saw-noise-filter.json` actually binds, so a missing row
later reads as a real failure rather than a manifest mismatch:

```text
controls
values
```

Expected baseline:

- `/v0/carrier/0` appears as the default pitch row.
- `/v0/lpf/0` cutoff has `source=default`.
- `/v0/lpf/1` q has `source=default`.
- `/v0/gain/0` level has `source=default`.

If `controls` does not list any of those addresses, stop and check the
manifest before proceeding — the manual pass is then waiting on a
manifest fix, not a 3c regression.

## Send MIDI CCs

From VMPK, send:

```text
CC 74 value 90
CC 71 value 40
CC 7  value 30
```

In the live shell, expect `midi accept` lines for:

- `/v0/lpf/0`
- `/v0/lpf/1`
- `/v0/gain/0`

Then run:

```text
values
```

Expected:

- cutoff is `source=accepted`
- q is `source=accepted`
- level is `source=accepted`
- displayed values are scaled into each manifest range, not shown as
  raw `0..127` CC values

## Preserving Reload Check

In the live shell:

```text
demo saw-filter-bright
values
```

Expected:

- the reload commits
- surviving controls retain the MIDI-written accepted values
- the `default=` column updates to the bright demo defaults

From VMPK, send another cutoff update:

```text
CC 74 value 64
```

Then run:

```text
values
```

Expected: `/v0/lpf/0` updates again with `source=accepted`.

## Reload Back

In the live shell:

```text
demo saw-filter-dark
values
```

Expected:

- the reload commits
- MIDI-written cutoff, q, and level values remain accepted for
  surviving tags
- the `default=` column returns to dark demo defaults

## Clean Exit

In the live shell:

```text
status
quit
```

## Pass Criteria

The pass is good if:

- startup succeeds with `--midi-device N`
- every VMPK CC produces a `midi accept` line
- `values` changes from `source=default` to `source=accepted`
- preserving reload keeps MIDI-written values for surviving controls
- `status` stays healthy
- the session exits cleanly
- the transcript is saved at
  `/tmp/metasonic-live-session-8h-3c-vmpk.log`

## After A Clean Pass

Convert the manual pass into hand-off:

- Add a findings entry to
  [notes/2026-05-21-b-live-session-operator-pass-playbook.md](2026-05-21-b-live-session-operator-pass-playbook.md)
  describing the run, the transcript path, and any observations
  worth retaining (e.g. ALSA stderr noise only if **worse** than the
  OSC-only baseline; otherwise it stays a pre-existing watch item).
- Flip
  [notes/2026-05-23-c-live-values-portmidi-ingress-design.md](2026-05-23-c-live-values-portmidi-ingress-design.md)
  status from `draft` to `closed` with pointers to the landed step
  commits and this transcript.
- Update `ROADMAP.md` to name the closed slice. Demote the
  operator-visible MIDI `values` residual to a hardware-verification
  follow-up (physical controller, beyond VMPK).

