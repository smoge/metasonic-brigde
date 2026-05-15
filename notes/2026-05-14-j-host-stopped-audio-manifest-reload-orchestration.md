# Host Stopped-Audio Manifest Reload Orchestration

Date: 2026-05-14

Status: design note only. This note refines the host-facing part of
`2026-05-14-i-manifest-reload-runtime-strategy.md`. The session-layer
owner replacement helper exists; the audio-running host orchestration
described here is not implemented yet.

## Summary

The stopped-audio manifest helper now proves the smallest session-layer
operation:

```text
prevalidated ManifestReloadPlan
  -> existing SessionFanInHost
  -> reloadManifestSessionStoppedAudio
  -> new owner generation installed, listeners/producers must restart
```

That is not yet an audio-running reload. A real app-side stopped-audio
reload needs a host command that owns the whole interruption window:

```text
validate plan
  -> quiesce producers/listeners
  -> drain accepted fan-in commands while audio is still live
  -> stop audio on the old owner
  -> call reloadManifestSessionStoppedAudio
  -> start audio on the new owner
  -> reopen listener/producer brackets with fresh worker state
```

The host command is deliberately outside `MetaSonic.Session.ManifestReload`.
The manifest helper does not know audio device policy, listener topology,
which producers are required, or how the UI should report terminal reload
failure.

## Why This Note Exists

`2026-05-14-i-manifest-reload-runtime-strategy.md` pins the runtime reload
contract and the helper boundary. It intentionally leaves two pieces open:

- the host command that quiesces ingress, drains, stops audio, calls the
  helper, restarts audio, and reopens ingress;
- the app-owned policy after `SfriOwnerSetupFailed`, because the helper is
  dispose-first and leaves the fan-in host with no owner after post-dispose
  construction failure.

This note pins those app-side decisions before any real start/stop audio
reload implementation lands.

## Current API Reality

The first implementation slice is enough for non-audio diagnostics:

- `MetaSonic.Session.FanIn.reloadSessionFanInHostOwnerStoppedAudio` replaces
  the current owner under the fan-in host after checking `NormalOperation`,
  owner presence, and empty queue
  ([FanIn.hs](../src/MetaSonic/Session/FanIn.hs#L381)).
- `MetaSonic.Session.ManifestReload.Runtime.reloadManifestSessionStoppedAudio`
  wraps that lower-level helper for `ManifestReloadPlan`
  ([Runtime.hs](../src/MetaSonic/Session/ManifestReload/Runtime.hs#L61)).
- `SessionFanInService` owns a background drain worker over a
  `SessionFanInHost`, and exposes `sessionFanInServiceHost` for producers
  that still target the host directly
  ([FanInService.hs](../src/MetaSonic/Session/FanInService.hs#L21)).

The current public API is not enough for audio-running reload:

- `startAudio` and `stopAudio` require a `Ptr RTGraph`
  ([FFI.hs](../src/MetaSonic/Bridge/FFI.hs#L2412)).
- `SessionOwnerHandle` stores that pointer internally, but the fan-in host
  hides the current handle and exposes only snapshots and enqueue/drain/reload
  operations ([Owner.hs](../src/MetaSonic/Session/Owner.hs#L87)).
- `Main.runRealtimeBracket` starts/stops audio around a raw `Ptr RTGraph`,
  not around a `SessionFanInHost`
  ([Main.hs](../app/Main.hs#L1497)).

So the next runtime slice must add a narrow host-facing way to perform audio
lifecycle operations against the fan-in host's current owner. This should not
be an unrestricted "give me the raw RTGraph forever" escape hatch. The host
needs a scoped operation, or explicit `start`/`stop` helpers, that cannot race
with owner replacement.

## Host-Owned Objects

The future stopped-audio reload host owns more than the session helper:

- the current `SessionFanInHost` or `SessionFanInService`;
- the audio configuration: output channel count, device id, ready timeout,
  and any host-visible audio state;
- the listener/producers it opened, such as MIDI listener brackets, OSC
  listener brackets, Pattern runners, and UI producers;
- the wiring configuration needed to reopen those brackets after reload;
- the last known good manifest plan or startup graph, if the app wants a
  full host rebuild fallback after terminal reload failure;
- UI/reporting policy for "reload in progress", "reload failed with no
  owner", and "audio restart failed".

The session helper owns none of those. Its success signal
`msarrListenersMustRestart = True` means "the host must tear down old
listener/producer worker brackets and open fresh ones". It does not mean
"the helper restarted them".

## Quiescence Means More Than Queue Empty

The helper can observe only the fan-in queue. The host must observe or enforce
the rest.

For v1, host quiescence means:

- no listener thread can enqueue another command into this host;
- no UI control path can enqueue another command into this host;
- Pattern runners are stopped at a block/range boundary and have no backlog
  they still intend to submit;
- MIDI listener state is at rest: no active notes, no held sustain, no
  pending coalesced controls, no deferred note-offs, no pitch-bend replay
  that should affect a later note-on;
- OSC listener brackets have stopped reading packets or have been detached
  from this host;
- all accepted commands have been drained through the old owner while audio
  is still running.

Queue empty is the last observable condition, not the first. If the host
checks queue depth before closing ingress, a listener can enqueue immediately
after the check. Therefore the host sequence is:

```text
close or pause ingress first
  -> let listener finalizers flush their last producer-local commands
  -> drain accepted commands while the old audio callback is still live
  -> verify queue empty
```

`withSessionMIDIListenerHooksAndOptions` is the concrete reason this matters:
its finalizer kills reader/flusher workers and then calls
`flushPendingControls ... MIDIFlushEOF`
([MIDIListener.hs](../src/MetaSonic/Session/MIDIListener.hs#L241)). Closing
the listener can legitimately enqueue final control writes. Those writes must
be drained before audio stops.

## Required Host State Machine

The app command should be explicit enough that every failure branch has a
named state. A useful v1 shape is:

```text
Running old owner/audio/listeners
  -> PlanReady
  -> IngressQuiescing
  -> DrainingLive
  -> AudioStoppedOldOwnerStillInstalled
  -> OwnerReloadInProgress
  -> OwnerReloadedAudioStopped
  -> AudioRestarting
  -> ListenerRestarting
  -> Running new owner/audio/listeners
```

Failure states:

```text
PlanRejectedOldRunning
QuiesceRejectedOldRunning
DrainRejectedOldRunning
ReloadRejectedOldOwnerStopped
ReloadFailedNoOwner
AudioRestartFailedNewOwnerInstalled
ListenerRestartFailedNewOwnerInstalled
```

The names are not proposed public constructors. They are the invariants the
implementation should preserve and the test suite should be able to observe.

## Detailed Sequence

### 1. Preflight Plan Before Touching Runtime State

Decode the external manifest, build the app catalog, and call
`planManifestReload` before quiescing anything.

If plan validation fails, the current owner, audio stream, fan-in host, and
listener brackets remain untouched. This is a normal user-facing validation
failure, not a reload failure.

Preflight should also snapshot the host configuration needed for recovery:

- output channel count and device id;
- active listener specifications, such as OSC port and MIDI source choice;
- producer configuration, such as Pattern runner identity and UI producer
  identity;
- the previous known-good startup plan, if the app wants a full rebuild
  fallback.

### 2. Announce Reload Intent To The App Layer

Before closing listeners, the host should move its own command surface into
"reload pending":

- UI controls should stop accepting new command submissions;
- manual CLI commands should reject or defer new producer actions;
- any app-owned producer service should report a retryable reload state;
- user-facing status should say that input is quiescing, not that reload has
  already committed.

This app-level state is separate from `SessionFanInReloadInProgress`. The
fan-in reload status changes only inside the helper's admit/install window.
The app's reload-pending state covers the longer human-visible window while
listeners are being closed and queues are being drained.

### 3. Close Or Pause Listener/Producer Brackets

For v1, prefer closing brackets and reopening fresh brackets after success.
In-place reset is deliberately not part of this design.

Examples:

- close `withSessionMIDIListener...` brackets and let the finalizer flush
  pending coalesced controls;
- close `withSessionOSCListener...` brackets or detach the socket path from
  this host;
- stop Pattern runners at a deterministic boundary;
- disable UI producer submission until the new owner is audible and listener
  restart has completed.

The host must know which brackets are required. If a required listener cannot
close cleanly, abort before stopping audio and reopen or resume against the
old owner.

### 4. Drain While Audio Is Still Live

After ingress has closed, drain the fan-in host until `sfisQueueDepth == 0`.

This must happen before `stopAudio`. Accepted commands step through realtime
adapter calls such as `c_rt_graph_realtime_activate`; those calls assume the
old runtime backend is still serviceable. Draining after audio stops risks
committing pure session state against runtime work that will not be serviced
normally.

If using `SessionFanInService`, the orchestration command must avoid racing
the background drain worker. There are two reasonable implementation shapes:

1. Add a service-level quiesce/drain API that asks the worker to stop accepting
   wakeups, waits for any current drain to finish, then performs a final drain.
2. Close the service bracket as part of a larger host rebuild path, then use a
   new service for the new owner.

For the "preserve fan-in host, replace owner" strategy, option (1) is the
better fit. A host command that directly calls `drainSessionFanInHost` while
the service worker can also drain the same host may still serialize through
the same MVar, but it makes shutdown ordering and observability harder than
necessary. The testable invariant is that the service worker stops accepting
wakeups before the orchestration performs its final drain, so the worker
cannot re-pull commands after the host believes the queue is empty.

### 5. Verify Quiescence

The final pre-stop checks are:

- fan-in snapshot reports queue depth zero;
- owner status is still `SessionOwnerReady`;
- reload status is still `SessionFanInNormalOperation`;
- host-owned producer/listener state is at rest according to each producer's
  own diagnostics;
- no required listener is still running against the old owner.

If any check fails, abort before stopping audio. The old owner is still
installed and audio is still live, so the host can reopen or resume ingress.

### 6. Stop Audio

Only after quiescence and live drain succeed does the host stop audio on the
old owner's RTGraph.

This requires a host-facing audio API around the current fan-in owner. The
current code does not expose one. A future slice should add something like one
of these shapes:

```haskell
withSessionFanInHostCurrentRTGraph
  :: SessionFanInHost
  -> (Ptr RTGraph -> IO a)
  -> IO (Either SessionFanInReloadIssue a)

stopSessionFanInHostAudio
  :: SessionFanInHost
  -> SessionAudioOptions
  -> IO (Either SessionAudioIssue ())

startSessionFanInHostAudio
  :: SessionFanInHost
  -> SessionAudioOptions
  -> IO (Either SessionAudioIssue SessionAudioStartReport)
```

The second shape is safer because it keeps the raw pointer hidden and lets
the host module enforce "no owner replacement while audio lifecycle is using
the current owner".

### 7. Call The Reload Helper

With audio stopped:

```haskell
reloadManifestSessionStoppedAudio
  host
  baseOwnerOptions
  plan
```

Normal success means:

- the old owner has been released;
- the new owner is installed in the same fan-in host;
- the new owner status is `SessionOwnerReady`;
- `msarrListenersMustRestart = True`;
- audio is still stopped;
- no listener/producers have been reopened yet.

The host must not interpret success as "reload complete" until audio and
listener restart have also succeeded.

### 8. Restart Audio On The New Owner

Start audio against the newly installed owner's RTGraph, then wait for the
audio callback readiness signal using the same policy as the existing app
audio runners.

If audio start fails, do not reopen listener/producers. The new owner is
installed but audio is not running. The host can offer a retry-start command,
perform a full teardown/rebuild, or exit. It should not let producers enqueue
commands into a backend that is not servicing realtime work.

### 9. Reopen Listener/Producer Brackets

After audio readiness succeeds, reopen fresh listener and producer brackets:

- new MIDI listener worker state, not the old `MIDIProducerState`;
- new OSC listener bracket bound to the same port/configuration if that
  listener is required;
- new Pattern runner state from the app's chosen restart point;
- new UI producer binding to the current fan-in host/service.

The restart point for Pattern and UI producers is app policy. The session
helper does not infer it from the manifest.

If a required listener fails to reopen after audio starts, v1 should fail
closed:

```text
close any listeners already reopened
stop audio on the new owner
keep ingress disabled
report ListenerRestartFailedNewOwnerInstalled
```

Optional listeners can be reported as degraded if the app explicitly marks
them optional. Do not silently continue with half of the expected producer
surface missing.

## Failure Policy

### Plan Failure

Failure before the host enters reload-pending state. Old owner, audio, and
listeners continue running. Return a user-facing validation error.

### Quiesce Or Drain Failure

Failure before `stopAudio`. Old owner and audio are still live. Reopen or
resume listener brackets against the old owner and report a retryable reload
failure. Do not call the helper.

### `SfriReloadAlreadyInProgress`

Host orchestration bug or concurrent reload request. The helper rejected
before disposing the old owner. Since audio is already stopped by the time
this is observed, the host should restart audio against the old owner, reopen
listeners, and report an internal/concurrency failure.

### `SfriQueueNotEmpty n`

Host orchestration bug: the host failed to close ingress or failed to perform
the final live drain before stopping audio. The helper rejected before
disposing the old owner. Restart audio against the old owner, reopen
listeners, and report a retryable failure with the observed queue depth.

### `SfriNoOwner`

The host has already lost its owner or is still in `ReloadFailed` from an
earlier terminal failure. Do not try to restart audio through this fan-in
host. Escalate to full host teardown/rebuild or process-level failure.

### `SfriOwnerSetupFailed issue`

This is the critical dispose-first failure. The old owner has been released,
the new owner did not construct, and the fan-in host is left in
`SessionFanInReloadFailed`.

V1 policy:

- keep audio stopped;
- keep all listener/producers closed;
- reject or disable producer command submission;
- report `ReloadFailedNoOwner` with the setup issue;
- allow recovery only through an explicit app-level full host rebuild or
  process restart.

Do not reopen listeners. Do not pretend the old graph is still available.
Do not retry the same helper in place, because the current helper's failed
state has no `ReloadFailed -> ReloadInProgress` transition and no owner to
dispose.

If a future app wants automatic recovery, it should use an outer host
supervisor that can close the failed fan-in host bracket and build a fresh
host from a preserved previous plan or from the requested plan. That is host
teardown/rebuild, not in-place stopped-audio reload.

### Audio Restart Failure After Successful Owner Reload

The new owner exists, but audio is stopped. Keep ingress disabled and report
`AudioRestartFailedNewOwnerInstalled`. A manual retry-start command is
reasonable if it uses the same current-owner audio API and does not reopen
listeners until the callback reports ready.

### Listener Restart Failure After Successful Audio Restart

The new owner exists and audio may be running. If a required listener fails,
close any reopened listener brackets, stop audio, keep ingress disabled, and
report the failure. Optional listener degradation must be explicit in app
configuration, not implicit.

## Async Exception Discipline

The host orchestration should run under a mask across the critical ownership
transitions, restoring only around bounded waits where cancellation is part of
the app contract.

The important cleanup edges are:

- if an exception arrives after audio has stopped but before reload admission,
  restart audio against the old owner or close the whole host;
- if an exception arrives after helper success but before audio restart,
  keep ingress closed and leave the host in an audio-stopped new-owner state;
- if an exception arrives while reopening listeners after audio restart,
  close any reopened listeners and stop audio before surfacing the exception;
- if `SfriOwnerSetupFailed` has occurred, do not run cleanup that assumes an
  owner still exists.

This is app-level cleanup, not a session helper responsibility.

## Implementation Slices

The next runtime work should be split. Do not jump straight to "real reload"
in one patch.

1. Add a current-owner audio lifecycle seam for `SessionFanInHost` or a new
   host wrapper. Keep raw `Ptr RTGraph` scoped or hidden.
2. Add a host-level quiesce/drain contract for `SessionFanInService`, so the
   background drain worker and the reload command do not race conceptually.
3. Add a pure or fake-IO orchestration test harness with fake audio and fake
   listener brackets. Test the state machine before touching PortAudio.
4. Add the real stopped-audio host command using the current-owner audio seam.
5. Add a manual CLI smoke that starts audio only if the environment supports
   it; keep it separate from deterministic test gates.

## Test Checklist For The Future Host Command

Deterministic tests should cover:

- plan failure leaves the fake old audio/listener state running;
- quiesce failure aborts before stop-audio;
- listener finalizer enqueues a final command and the host drains it before
  stop-audio;
- successful path observes the order:
  `close ingress -> drain -> stop old audio -> reload -> start new audio ->
  reopen ingress`;
- `SfriQueueNotEmpty` after stop-audio restarts the old owner because
  admission rejected before disposal;
- `SfriOwnerSetupFailed` leaves the host with no owner, audio stopped, and
  listeners closed;
- audio restart failure leaves the new owner installed but ingress closed;
- listener reopen failure stops new audio and keeps ingress closed;
- async exception cleanup does not leak an audio-running old or new owner.

Device-backed tests should remain optional/manual until the host command can
be exercised without depending on a local PortAudio device.

## Non-Goals

This note does not propose:

- preserving live hot-swap;
- migration of active voices;
- migration of producer-local state;
- queue draining inside `reloadManifestSessionStoppedAudio`;
- in-place reset hooks for existing listener brackets;
- automatic fallback to the old owner after `SfriOwnerSetupFailed`;
- making manifest reload the default command path for current demos.

Those are separate strategies or later policy slices.
