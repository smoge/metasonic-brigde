# Phase 8f - Graceful Session Shutdown Fade

Date: 2026-05-22

Status: closed. Implementation landed as `ad26139`
(`Implement Phase 8f host-stack close fade`). Live verification ran
the design note's two shutdown-only recipes against the same fixture
families that promoted the lane:

- `/tmp/metasonic-live-session-shutdown-only-after-fade.log`
  (`preserve-smooth-cutoff` / `preserve-smooth-cutoff-dark`).
- `/tmp/metasonic-live-session-shutdown-saw-after-fade.log`
  (`saw-noise-filter` / `saw-filter-dark`).

Both exited cleanly (`COMMAND_EXIT_CODE=0`, `Terminating session.`
present) and the operator heard no `quit` snap on either fixture.
The 10 ms host-stack close fade resolves the observed shutdown
artifact on this host. Findings entry: see the
[playbook](2026-05-21-b-live-session-operator-pass-playbook.md)
"Phase 8f host-stack close fade clears the shutdown snap" pass.

Residual risk: host-/device-specific teardown could still vary, since
the verification covers exactly one PortAudio host + output device
configuration. The slice does not claim cross-device click-free
shutdown — only that on this operator's pairing the snap is gone.

Companion to:

- [2026-05-21-b-live-session-operator-pass-playbook.md](2026-05-21-b-live-session-operator-pass-playbook.md)
  (`## Evidence To Code` rubric).
- [2026-05-22-e-scripted-operator-evidence-harness-design.md](2026-05-22-e-scripted-operator-evidence-harness-design.md)
  (8e closeout; the scripted runner surfaced the first shutdown snap).


## Why This Lane Opens

The shutdown snap has now crossed the playbook's repeated-friction
threshold.

Evidence:

| Pass | Transcript | Playbook record | Shape | Result |
|------|------------|-----------------|-------|--------|
| 8e scripted smooth-cutoff pass | `/tmp/metasonic-live-session-scripted-smooth-cutoff.log` | 8e scripted Findings entry (`7582ae6`) | full scripted smooth-cutoff pass, preserving reload clean | snap heard at final `quit` |
| Pass A shutdown-only smooth-cutoff isolation | `/tmp/metasonic-live-session-shutdown-only.log` | shutdown-only isolation Findings entry (`f4034f7`) | `status`, wait, `quit`; no reload, no OSC | snap reproduced at final `quit`; cause isolated to shutdown / teardown |
| Independent shutdown-only saw pass | `/tmp/metasonic-live-session-shutdown-saw.log` | independent saw shutdown-only Findings entry (`9b57dfa`) | `status`, wait, `quit` on `saw-noise-filter.json` / `saw-filter-dark`; no reload, no OSC | snap reproduced at final `quit` |

The important shift is the third row. The first two observations were
the same fixture family and the same shutdown moment, so the playbook
kept the snap as a watch item. The saw/noise shutdown-only pass is an
independent fixture family with a different live graph shape, and it
reproduced the same end-of-session artifact. This is no longer KSmooth
pressure, and it is no longer a single isolated shutdown report. It is
ordinary live-session `quit` behavior.

The lane is therefore:

> Avoid the audible snap on clean final session shutdown.


## What This Is, And Is Not

| Is | Is not |
|----|--------|
| A final-session-close polish lane for `quit` / `exit` / EOF | A preserving hot-swap lane |
| A short output fade/mute before stream close | A new voice-release or envelope system |
| An operator-audible improvement for live sessions | An offline proof of click-free audio |
| A narrow close-path change with tests around routing and ramp math | A broad rewrite of audio lifecycle semantics |

The reload boundary has already been validated separately: 8d-b
KSmooth state copy produced a clean preserving reload in the
smooth-cutoff pass. The artifact here happens with no reload and no
OSC, so this note must not reopen KSmooth, KDelay, KEnv, or preserving
state migration.


## Source Seams

| Topic | File | Symbol |
|-------|------|--------|
| Live session `quit` dispatch | [ManifestLiveSession.hs](../app/MetaSonic/App/ManifestLiveSession.hs) | `sessionLoop` / `LscQuit` |
| Final host-stack close path | [ManifestReloadHostStack.hs](../app/MetaSonic/App/ManifestReloadHostStack.hs) | `realClose` |
| Fan-in host audio stop state machine | [FanIn.hs](../src/MetaSonic/Session/FanIn.hs) | `stopSessionFanInHostAudioWith` |
| FFI audio stop wrapper | [FFI.hs](../src/MetaSonic/Bridge/FFI.hs) | `stopAudio` / `c_rt_graph_stop_audio` |
| Runtime stream stop | [rt_graph.cpp](../tinysynth/rt_graph.cpp) | `stop_audio_stream` / `rt_graph_stop_audio` |
| Realtime callback output mapping | [rt_graph.cpp](../tinysynth/rt_graph.cpp) | `GraphAudioStream::process` |


## Implementation Shape

### Preferred cut: explicit graceful final stop

Do not silently change every `rt_graph_stop_audio` call into a faded
stop. The current stop primitive is used in more contexts than final
session close, including stopped-audio reload paths and cleanup after
startup failures. This lane's evidence is specifically about clean
final `quit`, so the first implementation should make that distinction
visible in the API.

Preferred shape:

1. Add a C++ stop-with-fade entry point, for example
   `rt_graph_stop_audio_fade(RTGraph *g, int fade_ms)`.
2. Keep `rt_graph_stop_audio` behavior unchanged for existing callers.
3. Expose a Haskell wrapper such as `stopAudioFade`.
4. Add a fan-in helper that uses the same fail-closed state transition
   as `stopSessionFanInHostAudioWith`, but calls the fade stop
   function.
5. Use the graceful helper only from the final `realClose` path in
   `ManifestReloadHostStack`.
6. Leave stopped-audio reload stops (`manifestReloadHostOps`
   `hsaroStopOldAudio` / `hsaroStopNewAudio`) on the ordinary stop
   path unless separate evidence says reload stop/start also needs a
   fade.

That split keeps the behavior scoped to the confirmed operator
pressure and avoids smuggling a latency change into reload substrate.

### Runtime fade mechanics

The fade should live at the output-stream boundary, not in the graph:

- `GraphAudioStream::process` already owns the final copy from server
  output buses to hardware output channels.
- Applying a gain ramp there catches every graph, every bus mapping,
  and every node kind without mutating voice, control, or DSP state.
- The callback stays realtime-safe: scalar math and atomics only; no
  locks, no allocations, no Haskell calls, no logging.

One concrete shape:

- `GraphAudioStream` stores a small atomic shutdown-fade state:
  requested/active flag, total frames, remaining frames, done flag.
- `request_shutdown_fade(fade_ms)` computes the frame count from the
  device sample rate captured at stream construction. Start with a
  fixed 10 ms fade; if the device rate is unavailable, fall back to a
  conservative frame count derived from the stream sample rate already
  passed to `q::audio_stream`.
- Each callback processes the graph normally, copies output buses
  normally, then multiplies the copied output by a linear gain ramp
  from current gain toward zero.
- Once remaining frames reaches zero, subsequent callback output is
  silence and the done flag is set.
- The control thread waits a bounded interval for the done flag
  (`fade_ms` plus a small scheduling margin), then calls the existing
  stream `stop()` and resets the stream. If no callback arrives during
  the wait, the stop still completes rather than hanging shutdown.

This is output mute, not graph mutation. It should not clear voices,
reset controls, alter owner state, or affect preserving migration
counts.


## Open Questions To Resolve Before Code

- **Default fade duration.** The note's working default is 10 ms. That
  sits in the ordinary short de-click range (roughly 5-20 ms): long
  enough to remove an abrupt discontinuity, short enough that `quit`
  still feels immediate. The implementation slice should either keep
  10 ms and name that rationale in code, or change it with a concrete
  reason from the actual runtime path.
- **Fade curve.** Linear is the simplest first cut and is likely
  sufficient at 10 ms. At 48 kHz, 10 ms is 480 samples; the first gain
  step from 1.0 to approximately 0.998 is tiny, and the derivative
  discontinuity at fade start should be inaudible in this use. A
  half-cosine or equal-power ramp is also defensible if the helper
  stays simple. Pick one deliberately; do not leave the curve implicit
  in ad hoc arithmetic.
- **Control-thread wait bound.** The graceful stop should wait for the
  callback to finish the fade, but it must not hang shutdown if the
  backend stops producing callbacks. The implementation should pin the
  bound formula explicitly, for example `fade_ms + one or two output
  block durations + a small scheduling margin`, then fall back to the
  existing `stop()` path on expiry.
- **Testing seam.** Prefer a small pure ramp helper if it keeps C++
  tests deterministic without broadening the public ABI. If the helper
  stays private inside `rt_graph.cpp`, use the narrowest existing
  `rt_graph_test`-style hook that can prove the ramp math. Do not add
  a user-facing API only to test a private fade helper.


## Tests

### C++ deterministic tests

Avoid device-dependent live-audio assertions in CI. The unit-tested
piece should be the ramp math / state machine, not PortAudio capture.

Recommended coverage:

- A pure helper or small stream-local helper applies a fade ramp to
  one block of sample buffers.
- First sample remains near the incoming value when the fade begins;
  final sample reaches zero by the end of the fade window.
- Multi-channel buffers receive the same gain curve.
- Continuing after fade completion produces zero output.
- Re-requesting or requesting with zero/negative duration behaves
  deterministically.

If the helper is kept private inside `rt_graph.cpp`, test it through a
small internal test hook only if that matches existing `rt_graph_test`
style. Do not expose a broad public ABI just for the test.

### Haskell routing tests

Tests should pin the lifecycle decision, not audio samples:

- Final `realClose` uses the graceful stop path when audio is running.
- Stopped-audio reload stop paths continue to use the ordinary stop
  path.
- The fan-in audio-running flag is still cleared only after the chosen
  stop action returns successfully.
- If graceful stop throws, close remains fail-closed: the exception is
  surfaced and the state is not falsely marked safe.

Existing fake `SessionFanInAudioFFI` / host-stack tests are the right
place to assert those call traces.


## Verification

Offline:

```sh
just cpp-test
just stack-test
```

Live, audio-paired:

1. Re-run shutdown-only smooth-cutoff:

   ```sh
   script -q /tmp/metasonic-live-session-shutdown-only-after-fade.log -c 'stack exec -- metasonic-bridge --session-osc-port 17004 --manifest-live-session examples/manifests/preserve-smooth-cutoff.json preserve-smooth-cutoff-dark --strategy require-preserving'
   ```

2. Inside: `status`, listen a few seconds, `quit`.
3. Re-run shutdown-only saw:

   ```sh
   script -q /tmp/metasonic-live-session-shutdown-saw-after-fade.log -c 'stack exec -- metasonic-bridge --session-osc-port 17004 --manifest-live-session examples/manifests/saw-noise-filter.json saw-filter-dark --strategy require-preserving'
   ```

4. Inside: `status`, listen a few seconds, `quit`.

Success criteria:

- Both transcripts exit with command exit code 0.
- The session still prints `Terminating session.`.
- The final `quit` no longer produces the audible snap.
- No reload behavior is claimed by this verification pass.


## Out Of Scope

- No reload-boundary fade.
- No KDelay / KEnv / KSmooth state migration work.
- No envelope or voice-release redesign.
- No live-audio capture harness.
- No CI integration for the audio-paired pass.
- No operator-configurable fade length in this slice.
- No general pass-runner expansion.


## Sequencing

| Slice | Status | Notes |
|-------|--------|-------|
| Phase 8f design | Closed | Evidence cleared repeated-friction threshold |
| Phase 8f implementation | Closed (`ad26139`) | Host-stack close fade; ordinary stop unchanged; live verification clean on both shutdown-only fixtures |
| Later: reload stop fade | Not open | Only if reload-specific stopped-audio passes produce snap pressure |
| Later: configurable fade length | Not open | Only if fixed fade causes practical friction |

Keep the first implementation slice small. The value is not a new
audio-lifecycle architecture; it is removing one confirmed click at
the end of ordinary live-session use.
