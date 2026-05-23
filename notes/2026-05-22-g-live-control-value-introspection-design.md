# Phase 8h - Live Control Value Introspection

Status: design note. No code lands on the strength of this note alone.

## Evidence

The 2026-05-22 rich-control operator pass promoted the standing
current-value watch item into a narrow design lane. The 8h label names
that evidence pass and this follow-on design lane together.

Primary transcript:

- `/tmp/metasonic-live-session-8h-rich-control-pass.log`

The pass used `examples/manifests/saw-noise-filter.json` on the
`require-preserving` route. It swept `/v0/lpf/0` (`cutoff`),
`/v0/lpf/1` (`q`), and `/v0/gain/0` (`level`), then reloaded
dark -> bright, bright -> dark, and same-demo dark -> dark. All
20 OSC writes were accepted; no OSC reject, reload-window reject, or
constructor leakage appeared; every status snapshot stayed healthy.

The remaining operator gap was specific: after repeated accepted OSC
writes, `status` and `controls` still showed only session health and
declared/default control metadata. They did not answer "what target
value is this live voice currently using?"

This is repeated friction, not a roadmap-completeness exception. The
same watch item appeared during earlier Phase 8 operator passes as a
candidate introspection lane, but 8h was the first pass that exercised
the exact richer-control moment where the missing readback became the
next useful question.

## Goal

Add a read-only live-session shell command:

```text
values
```

The command reports the last accepted control target values for active
voices on the current manifest plan.

It is a text-shell observability slice. It does not change DSP,
preserving reload behavior, OSC write semantics, MIDI device/scaling
behavior, or GUI bindings.

## Contract

`controls` remains the declared surface:

- pattern OSC addresses
- concrete active-voice OSC addresses
- manifest defaults
- ranges
- MIDI CC metadata

`values` is the live operator snapshot:

- one row per active voice x current manifest control
- concrete OSC address
- display name
- current target value
- value source
- default / range / CC metadata for context

Suggested rendering for the saw/noise fixture after the 8h final OSC
batch:

```text
  values for saw-filter-dark:
    /v0/carrier/0  name="pitch" value=220 source=default default=220.0 range=[55.0, 880.0]
    /v0/lpf/0      name="cutoff" value=1800 source=accepted default=600.0 range=[200.0, 6000.0] cc=74
    /v0/lpf/1      name="q" value=0.4 source=accepted default=0.7 range=[0.3, 4.0] cc=71
    /v0/gain/0     name="level" value=0.2 source=accepted default=0.2 range=[0.0, 0.5] cc=7
```

The value format should reuse the operator-facing compact number
format already used by OSC accept lines (`renderOperatorValue` in
`ManifestLiveCommon`), so `0.05` can render as `5e-2` consistently
with today's transcript.

## Meaning Of "Current"

This slice should report **current target values known to the live
session shell**, not sample-accurate DSP state.

It must not claim:

- current smoothed audio-rate `KSmooth` output
- raw C++ node/control memory readback
- MIDI device state or unobserved hardware position
- GUI widget state outside accepted command writes
- values accepted by a producer but rejected by the session fan-in

For v1, "current" means:

- manifest default when no accepted write for that voice/control is
  known in this live shell generation
- last `SessionEnqueued` `CmdControlWrite` value seen by the
  live-session accepted-write observer for that voice/control,
  regardless of ingress path
- retained accepted value across preserving reloads when the
  `ControlTag` survives on the new current plan

That is intentionally the same operator truth the transcript already
prints for OSC as `osc accept: ... value=...`, collected into a
queryable snapshot. The cache contract is ingress-agnostic: if MIDI or
UI ingress delivers an accepted `CmdControlWrite` through the same live
session shell, the value snapshot should update from that accepted
write too. "No MIDI device work" means no PortMIDI/device-state,
hardware-position, or MIDI scaling work in this slice; it does not mean
that accepted MIDI-origin control writes should be invisible forever.

## Implementation Shape

Keep the first slice app-local.

Add a small live-session value cache near
`app/MetaSonic/App/ManifestLiveSession.hs`:

```text
Map VoiceKey (Map ControlTag LiveControlValue)
```

where `LiveControlValue` carries at least the `Value` and a source
tag such as `accepted`. Manifest defaults do not need to be cached;
the renderer can derive `source=default` from the current plan when a
voice/control pair has no accepted entry.

Add a small accepted-write observer that records a successful
`CmdControlWrite` by `VoiceKey`, `ControlTag`, and numeric value.

For the existing live shell, wire the observer through the current
manifest OSC listener hook path:

- `ManifestOSCListenerHooks.molhOnAccepted`
- `OSCProducerEnqueueAttempted (CmdControlWrite voice tag value) result`
- only when `sfierResult result` is `SessionEnqueued _`

Keep that observer producer-neutral. If implementation exposes an
already-shared accepted-write seam upstream of OSC/MIDI/UI-specific
wrappers, prefer that seam. If any existing live MIDI/UI accepted-write
hook is already present in the same shell, wire it to the same observer
in this slice rather than deferring it solely because the 8h evidence
was OSC. If not, the first slice can still wire the currently opened
OSC path, but the helper and tests should make clear that `values` is
not intentionally OSC-only.

Do not update on:

- parse / manifest / range rejection
- reload-window rejection
- queue rejection
- command-level reload rejection

Add `LscValues` to the live-session command parser and help text.

Add `printValues` beside `printControls`:

- read the current `ManifestReloadPlan`
- project `ManifestReloadIngressTarget` from that plan
- read active voices from the live fan-in service snapshot
- render active voices x target OSC controls
- for missing cache entries, render the manifest default with
  `source=default`

On reload outcomes:

- committed preserving reload: keep cached values whose `ControlTag`
  exists in the new current plan; missing/new controls render defaults
- request-rejected: leave cache unchanged
- command-level plan rejection: leave cache unchanged
- close/reopen or fallback outcomes: reset cache to defaults unless a
  later implementation can prove retained values are still meaningful

The implementation can choose a stricter reset policy for non-preserving
strategies in the first slice; the evidence is from `require-preserving`.

## Tests

Add pure rendering tests, then a narrow live-session command test.

Suggested tests:

- `values` command appears in help.
- `values` with one active voice and no accepted writes renders
  manifest defaults with `source=default`.
- accepted control write updates the cache and renders
  `source=accepted`.
- the OSC accepted hook feeds the same producer-neutral updater rather
  than embedding OSC-specific cache logic.
- rejected/out-of-range/reload-window writes do not update the cache.
- preserving committed reload retains values for surviving tags and
  defaults newly introduced tags.
- request-rejected reload leaves values unchanged.
- no live stack or no active voices renders an explicit empty message,
  not a misleading table.

The tests should avoid real UDP/audio unless they are extending an
existing live smoke. Prefer pure helpers and the existing live-session
test seams.

## Non-Goals

- No C++ runtime readback API.
- No changes to `rt_graph_set_control` / realtime queue behavior.
- No MIDI device, hardware-position, or MIDI scaling work.
- No GUI widget state.
- No command history or readline work.
- No ALSA / PortAudio stderr suppression.
- No same-demo reload wording change.
- No KDelay / KEnv / KSmooth migration work.

## Open Questions To Resolve Before Code

1. **Cache location.** The first slice should prefer the app-local
   cache because the evidence is in the manifest live-session shell.
   If implementation pressure shows the same value snapshot is needed
   across OSC, MIDI, UI, and pattern producers, promote it into
   `SessionState` in a later slice.

2. **Non-preserving reload policy.** For `require-preserving`,
   surviving tags should retain accepted values. For stopped-audio or
   fallback rebuilds, resetting to defaults is safer unless the code
   can prove the runtime received equivalent retained values.

3. **Voice scope.** The evidence is one auto-started voice (`v0`).
   The data shape should be per voice, but the first operator pass only
   needs one voice. Do not add voice-selection UI.

4. **Wording.** The command should say `value` or `target` clearly
   enough that future readers do not mistake it for sample-accurate DSP
   readback. If the implementation uses `value`, keep the "target
   value" explanation in the help/test names.

## Validation Plan

1. Run the focused unit tests for parsing/rendering/cache update.
2. Run `just stack-test`.
3. Run a short manual live pass:

   ```sh
   script -q /tmp/metasonic-live-session-8h-values.log -c 'stack exec -- metasonic-bridge --session-osc-port 17004 --manifest-live-session examples/manifests/saw-noise-filter.json saw-filter-dark --strategy require-preserving'
   ```

4. In the session, run `values`, send OSC cutoff/q/level writes,
   run `values` again, reload dark -> bright, run `values`, reload
   bright -> dark, run `values`, then `quit`.
5. Confirm the values table matches the accepted OSC writes, reload
   health stays normal, and shutdown remains clean.
