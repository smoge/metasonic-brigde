# Manifest OSC Live Reload Operator Recap

Date: 2026-05-16

Status: operator recap after the first real run of
`--manifest-live-reload-demo try-preserving named-control send-return`
with audio actually heard. The FFI process-global serialization guard
landed earlier today (see
[2026-05-16-b](2026-05-16-b-ffi-serialization-guard-and-audible-osc-runbook.md))
is what made this validation pass possible — `stack test` is now
deterministic, and the demo itself starts and runs cleanly.

## Short version

The audible OSC reload path works end-to-end. Audio started, OSC
ingress accepted one targeted write that produced audible change,
the reload ran and printed its outcome, the post-reload surface
opened against the new manifest, and the demo exited cleanly when
asked to stop. The FFI lock did not disturb the operator path.

Three pieces of real operator friction surfaced and are worth fixing
before treating `--manifest-live-reload-demo` as the canonical live
reload entry. They are operator-UX problems in the demo CLI, not
contract problems in the manifest reload arc itself.

## What worked

- **FFI guard did not break the audible path.** Demo built, started,
  ran, and exited 0. No SIGABRT. No crashes in setup, reload, or
  teardown.
- **Audio actually started.** PortAudio opens after a flood of ALSA
  device-probing diagnostics on this host; eventually a device opens
  and the demo prints `audio running: yes`. The probing noise is not
  a metasonic problem.
- **Manifest validation succeeded.** Both `named-control` and
  `send-return` round-tripped through `--authoring-manifest`,
  validated against the compiled catalog, and the demo accepted the
  resulting JSON without complaint.
- **OSC ingress bound on the requested port.** The demo printed
  `OSC ingress: open demo=named-control osc-controls=2 oscPort=7001`
  and accepted one of the four packets sent to it.
- **One OSC write was accepted and the operator heard the change.**
  `/v0/cutoff/1` value `500.0` produced
  `osc accept: CmdControlWrite voice=v0 tag=ControlTag {ctNodeTag =
  MigrationKey {unMigrationKey = "cutoff"}, ctSlot = 1} value=500.0`,
  and a human listener confirmed audible behaviour change.
- **Three of four packets correctly rejected at the manifest layer.**
  `/auto-named-control/cutoff/1` and `/auto-named-control/vol/1`
  rejected as `MoiiDecodeFailed (DiIdentifierProfile
  "auto-named-control")`, `/not-a-real-control` rejected as
  `MoiiDecodeFailed (DiInvalidAddressFormat "/not-a-real-control")`.
- **Reload ran and reported its outcome.** Strategy reported
  `MrhsrStoppedAudioAfterPreservingRejected` — exactly the path
  predicted by the runbook for `named-control` → `send-return`
  (template shapes differ, so preserving rejects, stopped-audio
  takes over).
- **Post-reload state was consistent.** Audio came back running,
  two voices spawned (`voice` and `fx` per template), OSC ingress
  reopened against the new manifest:
  `OSC ingress: open demo=send-return osc-controls=0 oscPort=7001`.
- **Post-reload OSC packets correctly rejected.** Since
  `send-return` binds no OSC controls, every post-reload packet
  rejected at the manifest layer with the expected diagnostic
  shapes.
- **Clean shutdown.** Second Enter → audio stopped → ingress closed
  → process exit 0. No leaked threads, no zombie audio stream.

## What went wrong (operator friction)

### F-1: Strategy outcome prints a ~12KB `Show` dump

The line beginning `strategy outcome:` is a single line containing
the full `Show` of `MrhsrStoppedAudioAfterPreservingRejected`,
including the entire `TemplateGraph` for both `send-return`
templates, every `RuntimeNode`, every `RuntimeRegion`, every
`ResourceFootprint`, the full enqueue result, the full drain result
including a second copy of the same TemplateGraph, and the full
`SessionState` of the old owner with another copy of the
`named-control` graph.

Day-log Wave 5 explicitly refactored the OSC accept/reject hooks to
print one short line per event via `renderOSCAccept` /
`renderOSCIssue`. The strategy outcome did not get the same
treatment. In real operator use this single line is unreadable.

Fix shape: a `renderStrategyOutcome :: ... -> String` helper that
prints the strategy tag, the demo key, the swap label, the
high-level result classification, and a one-line summary of why
preserving was rejected when applicable. Drop the full graph dump.

### F-2: Addressable surface print is misleading

The demo prints the surface template `/<voice>/cutoff/1` and the
voice-key auto-spawn enqueue
`VoiceKey "auto-named-control"`, but neither matches what the OSC
ingress actually accepts. Three contributing issues:

1. **`<voice>` placeholder never gets filled in** because
   `ssVoices` is empty at print time (queue not yet drained — F-3).
2. **The enqueued voice-key `auto-named-control` is rejected by the
   OSC ingress** with `DiIdentifierProfile "auto-named-control"`.
   The identifier-profile validator likely doesn't admit names with
   hyphens. The demo picked a voice key the OSC ingress cannot
   reach.
3. **The "no active voices, OSC writes route nowhere" message is
   wrong.** Writes DO route — the manifest projection accepts any
   address whose voice-key is a valid identifier and whose
   tag/slot matches a bound control. `/v0/cutoff/1` accepted even
   though `ssVoices` was reported as empty.

An operator following the runbook with these prints in hand would
either send to the printed `auto-named-control` (rejected) or to
the literal `<voice>` (rejected) and would not know to try `v0`.
The OSC accept path worked, but only because I deliberately tried
`/v0/cutoff/1` after seeing the rejects.

Fix shape: pick a voice key that satisfies the OSC identifier
profile (e.g. `v0` instead of `auto-named-control`), surface that
key in both the auto-spawn enqueue and the addressable surface
print, and drop the misleading "OSC writes route nowhere" line.

### F-3: Snapshot-vs-queue-drain race in the initial surface

`initial: auto-starting one instance per template...` enqueues a
`CmdVoiceOn`, then prints `warning: no active voice observed after
auto-start` and `active voices: 0`. The drain hasn't happened yet,
so the snapshot sees zero voices. After the reload, the equivalent
section reports `active voices: 2` correctly, which suggests the
drain has had more wall time by then.

Fix shape: explicit `drain-then-snapshot` step before printing the
initial fan-in snapshot, or a small wait + retry. The reload-side
shape suggests the bug only bites the initial setup phase.

## Follow-up status

The three operator-UX issues above were addressed in focused
follow-up commits the same day. Treat the friction sections above as
historical context; the live demo CLI now matches them.

- **F-1** — fixed by `5d1d843` (introduces `renderStrategyRan` /
  `renderStrategyFailure` plus short `Hpari` / `Hsari` constructor
  classifiers, replacing the raw `show`) and refined by `359f1f1`
  (relabel `HpariReloadRejected` to its actually-shared meaning,
  "old owner still installed", rather than the narrower
  "graphs not preserving-compatible"). Pinned by `7bfaa83`, which
  makes the leaf renderers polymorphic in their issue payload so a
  show-based fallback regression is uncompilable, plus runtime
  assertions in
  [test/MetaSonic/Spec/AppManifestLiveReloadDemoRender.hs](../test/MetaSonic/Spec/AppManifestLiveReloadDemoRender.hs)
  covering every constructor against a probe payload that explicitly
  contains the banned `TemplateGraph` / `RuntimeNode` substrings.

- **F-2** and **F-3** — both fixed by `b84cf4c`. Voice-key
  generation moved to an OSC-safe policy (`v<index>` with `fx` as a
  special case so the 16-byte `isOscSafeIdentifier` cap is never
  hit); `autoStartTemplates` now returns the spawned keys; a new
  `waitForVoices` polls for the specific keys before the
  initial-fan-in snapshot is printed; and the misleading
  "OSC writes route nowhere" branch was replaced with text that is
  accurate when it does fire (writes accepted at the manifest layer,
  no audible target).

Live verification after the polish pass: initial fan-in reports
`active voices: 1` instead of `0`; the surface print emits
copy-pasteable concrete addresses (`/v0/cutoff/1`, `/v0/vol/1`);
`/v0/cutoff/1 = 600` accepts with `voice=v0` and was audibly heard;
the post-reload strategy outcome renders as one 135-character line
(`success: preserving rejected (reload-rejected (old owner still
installed)), stopped-audio fallback installed`) instead of the
~12000-character `Show` dump.

What's left from this recap is what the run itself couldn't prove,
not friction it surfaced — see "Recommended next steps" below.

## Comparison to the runbook expectations

Item-by-item against
[2026-05-16-b §What to capture / watch for](2026-05-16-b-ffi-serialization-guard-and-audible-osc-runbook.md):

| Expectation | Observed |
|---|---|
| Strategy outcome and audio continuity printed | Strategy outcome printed, but as the unreadable Show dump (F-1); audio continuity confirmed via fan-in snapshots |
| Stopped-audio fallback for `named-control` → `send-return` | Confirmed: `MrhsrStoppedAudioAfterPreservingRejected` |
| Old OSC addresses reject after reload — `osc reject (manifest): ...` | Confirmed, with exact diagnostic shapes |
| New OSC addresses accept and audible change | Confirmed audibly for one pre-reload packet; not testable post-reload because send-return binds no OSC controls (a known property of the chosen pair) |
| `osc accept: ...` short lines | Confirmed |
| No `SeiQueueFull` spam | Confirmed (no queue-full output) |

The note's claim that `AudioStop` is not surfaced as an
operator-facing event is also confirmed — no `AudioStop` line
appears in the log even though the stopped-audio path ran.

## Commands used

Generate manifest:

```sh
stack exec -- metasonic-bridge --authoring-manifest named-control send-return \
  > /tmp/metasonic-live-manifest.json
```

Run the demo (interactive, two Enters: first for reload, second to
stop):

```sh
stack exec -- metasonic-bridge \
  --session-osc-port 7001 \
  --manifest-live-reload-demo try-preserving \
  /tmp/metasonic-live-manifest.json \
  named-control \
  send-return
```

Send OSC (in a second terminal):

```sh
# This accepted in the run:
python3 tools/send_osc.py --port 7001 --address /v0/cutoff/1 --value 500

# These rejected (the demo's printed surface template is misleading):
python3 tools/send_osc.py --port 7001 --address /auto-named-control/cutoff/1 --value 3000
python3 tools/send_osc.py --port 7001 --address /not-a-real-control --value 1
```

For a scripted run with timed Enters, drive stdin through a FIFO
opened read-write in the same shell to avoid blocking:

```sh
FIFO=$(mktemp -u /tmp/demo-stdin.XXXXXX); mkfifo "$FIFO"
exec 3<>"$FIFO"
stack exec -- metasonic-bridge ... < "$FIFO" > /tmp/demo.log 2>&1 &
# ... send packets, wait for log markers ...
echo "" >&3   # trigger reload
# ... send more packets ...
echo "" >&3   # stop
exec 3>&-
```

Doing `< "$FIFO"` from the demo or `exec 3>"$FIFO"` alone will
block at open time waiting for the other end; opening read-write
in the same process via `<>` is the only clean fix.

## What this run does not prove

- **Preserving hot-swap behaviour under audio.** The chosen pair
  (`named-control` → `send-return`) falls back to stopped-audio by
  design. A separate pass against a preserving-compatible pair
  would be needed to validate `MrhsrPreserving` audibly. The OSC
  preserving e2e test in
  [test/MetaSonic/Spec/AppManifestOSCReloadE2E.hs](../test/MetaSonic/Spec/AppManifestOSCReloadE2E.hs)
  uses `hotSwapEdit` / `hotSwapEditAfterTemplates` for this; a
  CLI-exposed pair on top of those would be the cleanest audible
  followup.
- **Post-reload OSC accept on the new surface.** `send-return`
  binds no OSC controls; every post-reload packet rejected as
  expected. Picking a target demo with OSC bindings (or extending
  `send-return` to bind one) would let the post-reload accept path
  be heard.
- **MIDI ingress in the live reload path.** Out of scope per the
  reload arc closeout.

## Recommended next steps

F-1, F-2, and F-3 are closed (see "Follow-up status" above). What
remains is what this run itself could not exercise:

1. **Add a preserving-compatible CLI pair** (or extend the existing
   pair) so a single demo invocation can also validate
   `MrhsrPreserving` audibly. The `named-control` → `send-return`
   pair is shape-incompatible by design and only hits the
   stopped-audio fallback. The OSC preserving e2e test in
   [test/MetaSonic/Spec/AppManifestOSCReloadE2E.hs](../test/MetaSonic/Spec/AppManifestOSCReloadE2E.hs)
   uses `hotSwapEdit` / `hotSwapEditAfterTemplates` for this; a
   CLI-exposed pair on top of those would be the cleanest audible
   followup.

2. **Add a target demo with OSC controls** so the post-reload accept
   path is exercisable end-to-end in one session. Currently
   `send-return` binds no OSC controls, so every post-reload packet
   correctly rejects but the audible-write-after-reload behaviour
   cannot be heard.

Neither touches the manifest reload arc contract; both are demo-CLI
content choices on top of a working pipeline.

## Operator artifacts

- `/tmp/metasonic-live-manifest.json` — the manifest used.
- `/tmp/osc-demo-shape.log` — first dry run, captures the
  end-to-end output shape.
- `/tmp/osc-demo-real.log` — second run with interleaved OSC
  packets and audible confirmation.

Both logs are scratch. The captured `osc accept` / `osc reject`
lines and the F-1/F-2/F-3 observations above are the durable
outputs of this pass.

## Related files

- [app/MetaSonic/App/ManifestLiveReloadDemo.hs](../app/MetaSonic/App/ManifestLiveReloadDemo.hs) —
  the demo entry. F-1 (strategy-outcome render), F-2 (voice key
  choice + addressable-surface print), and F-3 (drain-before-
  snapshot) all live in this module.
- [src/MetaSonic/App/ManifestReloadOSCIngress.hs](../src/MetaSonic/App/ManifestReloadOSCIngress.hs)
  (or sibling) — owns the `DiIdentifierProfile` decoder rejecting
  `auto-named-control`; useful reference for whatever voice-key
  rename satisfies F-2.
- [notes/2026-05-16-b-ffi-serialization-guard-and-audible-osc-runbook.md](2026-05-16-b-ffi-serialization-guard-and-audible-osc-runbook.md) —
  the runbook that this recap validates against.
- [notes/2026-05-16-a-manifest-midi-smoke-operator-recap.md](2026-05-16-a-manifest-midi-smoke-operator-recap.md) —
  sibling operator pass on the MIDI side.
- [notes/2026-05-15-d-manifest-reload-ingress-v1-closeout.md](2026-05-15-d-manifest-reload-ingress-v1-closeout.md) —
  v1 boundary; F-1/F-2/F-3 are explicitly inside the "operator UX
  polish based on manual smoke use" carve-out the closeout
  identifies as v1 polish, not v2 contract work.
