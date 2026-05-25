## Allocation and Resource Recovery Event Semantics

Date: 2026-05-25

Status: design note + implementation log. Scopes the last remaining
open lane from the
[ManifestReloadEvent Partial Coverage](2026-05-19-a-manifest-reload-event-partial-coverage.md)
closeout: "allocation / resource recovery events". The
[Stale Producer Command Semantics](2026-05-24-b-stale-producer-command-semantics.md)
note (closed end-to-end) and the
[Manifest Reload Preflight Event Semantics](2026-05-25-a-manifest-reload-preflight-event-semantics.md)
note (resolver-stage v1 closed in `2cc734a`/`93bb1e7`) set the
pattern: pin terminology, draw the state space, name a concrete
operator consumer, and frame the smallest first slice before adding
constructors.

**Slice 1 landed in `8b9fb8f`** — `ManifestReloadAudioEvent` brackets
the stopped-audio reload's two main audio boundaries
(`hsaroStopOldAudio` and `hsaroStartNewAudio`) with full
attempt/succeeded/failed triples, plus the listener-restart cleanup
boundary (`hsaroStopNewAudio`) with an attempt/succeeded pair only —
cleanup failures are silent at the `IO ()` level. Threaded through
`orchestrateHostStoppedAudioReloadWithEventsAndAudio` and rendered
as an `audio events:` block in the live-session shell between
`reload events:` and `retired bindings:`. Ready-timeout rides
inside the start-failure payload (`SfaiReadyTimeout` inside
`MraeStartFailed`) for v1 rather than emitting a separate event.
Require-preserving and preserving-success paths stay silent on the
family; try-preserving emits audio events when it admits the
stopped-audio fallback (`realTryPreservingInWindowReload` forwards
`onAudioEvent` into `realStoppedAudioInWindowReload`). The
[Manual live-session evidence: 2026-05-25 (stopped-audio)](#manual-live-session-evidence-2026-05-25-stopped-audio)
section below records the operator transcript.

## What resource/allocation failures are currently invisible?

Four concrete cases, ordered from "completely invisible" to "visible
only as a terminal outcome":

### 1. Graph allocation outcomes

A reload installs a new template graph through two structurally
different runtime paths:

* **Stopped-audio:**
  [`acquireSessionOwner`](../src/MetaSonic/Session/Owner.hs)
  builds a fresh owner against the new `TemplateGraph`, which
  allocates the `RTGraph` C struct, copies templates, sets
  polyphony, and pre-warms the per-template pool.
* **Preserving:** the hot-swap publish path in
  [`RTGraphAdapter`](../src/MetaSonic/Session/RTGraphAdapter.hs)
  (e.g. `lhpAcquireSwap` / `lhpPublishSwap`, returning
  `Either SessionRuntimeIssue …`) is what touches the runtime;
  [`applyPlannedCommit`](../src/MetaSonic/Session/State.hs#L179)
  is the *pure post-install state commit*, not the allocation
  step itself.

Each pathway performs several distinct runtime allocations: the
`RTGraph` C struct or its replacement template set, per-template
polyphony pool pre-warm, scratch buffers for the new schedule,
region kernel state. Failures at any of those steps surface as a
`Left SessionRuntimeIssue` (or the owner-acquire equivalent) from
the install op, and from there roll up into
`MrePreservingReloadRejected` / `MreStoppedAudioReloadRejected`.

What is invisible: the *sub-step boundary*. An operator who sees
`stopped-audio phase rejected: reload-failed (no owner)` cannot tell
whether the runtime template-set allocation succeeded and the pool
pre-warm failed, or vice versa. The strategy timeline collapses
everything between `MreStoppedAudioReloadStarted` and
`MreStoppedAudioReloadRejected` into one boundary.

### 2. Polyphony pool exhaustion

There are two distinct allocator paths here, and they have
different visibility stories:

* **Haskell manifest live-session path.** `CmdVoiceOn` flows
  through `admitSessionCommand` →
  [`runVoiceStart`](../src/MetaSonic/Session/RTGraphAdapter.hs#L697)
  which calls `c_rt_graph_realtime_reserve` /
  `c_rt_graph_realtime_activate`. Failures *do* reach Haskell as
  [`SessionRuntimeIssue`](../src/MetaSonic/Session/Runtime.hs#L89)
  values: `SriVoiceAllocationFailed` (reserve returned a negative
  slot) and `SriRealtimeQueueFull RtOpActivate` (activate enqueue
  refused). The fan-in drain folds them into `StepRuntimeFailed`
  and the producer sees the rejection. So allocation failure is
  *visible as an issue value*; what is missing is a dedicated
  event family that lets a consumer subscribe to allocation
  outcomes without having to walk the drain-result issue values.
* **C++ MIDI / `VoiceAllocator` path.**
  [`VoiceAllocator::note_on`](../tinysynth/voice_allocator.cpp)
  returns a `VoiceResult` whose `status` is one of `Started` /
  `PendingSteal` / `QueueFull` / `MapFailed`. This is used by the
  C++ MIDI demo and `MidiVoiceProcessor`, not by the manifest
  live session — the live session's `CmdVoiceOn` does not go
  through `VoiceAllocator::note_on`. The MIDI/allocator path's
  status is consumed entirely on the C++ side; it does not cross
  the FFI back to Haskell at all.

For the live-session lane this slice scopes, the first concern is
the Haskell path — surfacing `SriVoiceAllocationFailed` /
`SriRealtimeQueueFull` as a structured allocation-event family
rather than only as drain-result issue values. The C++
`VoiceAllocator` path is a separate concern that would require new
bidirectional FFI surface; it is deferred until a real consumer
asks for it.

### 3. Audio ready/not-ready transitions across reload

[`SessionFanInAudioIssue`](../src/MetaSonic/Session/FanIn.hs#L221)
already names the relevant failures:

* `SfaiStartFailed !Int` — `startAudio` FFI returned a nonzero
  status code.
* `SfaiReadyTimeout` — `startAudio` accepted but the runtime did
  not flip to audio-running within the configured ready timeout
  (the helper calls `stopAudio` to avoid an indeterminate state).
* `SfaiAudioAlreadyRunning` / `SfaiAudioAlreadyStopped` — admission
  rejections that protect the audio-running flag.

These issue types are carried in the *result value* of
`startSessionFanInAudio` / `stopSessionFanInAudio` but they do not
emit events of their own. A stopped-audio reload that:

1. Stops audio successfully,
2. Reinstalls the graph,
3. Calls `startAudio` and gets `SfaiStartFailed 12`,

surfaces today as one `MreStoppedAudioReloadRejected
(HsariAudioRestartFailed (SfaiStartFailed 12))`. The two
successful boundaries (audio-stopped, graph-reinstalled) are
invisible; the failure boundary is conflated with the strategy-level
rejection. The operator cannot tell from the transcript whether
the failure was upstream or downstream of the graph install.

This case has the clearest live-session consumer because the live
shell already has an `audio running: yes/no` line in
[`status`](../app/MetaSonic/App/ManifestLiveSession.hs)
output; an `audio events:` block during reload would compose
cleanly with that existing surface.

### 4. Operator-visible recovery progress

The supervisor already emits
[`SupervisedReloadEvent`](../app/MetaSonic/App/ManifestReloadSupervisor.hs#L160):
`SreInWindowStarted`, `SreInWindowCommitted`, `SreClosePreviousStarted`,
`SreClosePreviousSucceeded`, `SreFallbackOpenStarted`,
`SreFallbackOpenSucceeded`, `SreFallbackOpenFailed`, etc. The
live session prints those as `supervisor events:` lines after
the strategy timeline.

What is invisible: the *inner* recovery steps. A terminal-recovering
reload runs `sopsCloseStack` and `sopsOpenStack`; inside
`sopsOpenStack` it goes through the entire owner-acquire +
audio-start sequence again, and *that* sequence can fail again
mid-step (audio fails to restart, owner acquire fails after the
close already succeeded). Today those mid-step failures only
appear as a final `SreFallbackOpenFailed !e` or escalation issue.
Recovery *progress* — "close ok, owner acquire ok, audio start
in progress, audio start ok" — is not a thing the operator can
observe.

## Who is the first real consumer?

Same answer as the preflight lane:
[`runManifestLiveSession`](../app/MetaSonic/App/ManifestLiveSession.hs).
The reasons are unchanged — it is the real operator surface, it
already drives the supervisor and strategy paths, it already has
`reload events:` / `preflight events:` / `supervisor events:` /
`resource timeline:` blocks that any new event family would compose
into, and it already exposes an `audio running:` line whose
transitions are the natural anchor for case 3.

Secondary candidates (`--manifest-host-reload-smoke`,
`--manifest-live-reload-demo`) should follow, not lead, for the
same reason they were not the lead consumer in the preflight or
stale-command lanes: they are smoke surfaces and do not exercise
the full live-session lifecycle.

## Which layer owns the events?

This is the most consequential design question, because the four
cases each live at a different layer:

| Case                          | Owning layer                                                      | Existing infrastructure                                  |
|-------------------------------|-------------------------------------------------------------------|----------------------------------------------------------|
| 1. Graph allocation outcomes  | Owner (acquire) + RTGraphAdapter (preserving install)             | `SessionRuntimeIssue` values only                        |
| 2a. Haskell voice allocation  | RTGraphAdapter (`runVoiceStart`) → fan-in drain                   | `SriVoiceAllocationFailed` / `SriRealtimeQueueFull` only |
| 2b. C++ MIDI voice allocator  | C++ runtime → FFI (no Haskell channel today)                      | None on Haskell side                                     |
| 3. Audio ready/not-ready      | Fan-in (audio admission lock)                                     | `SessionFanInAudioIssue` values only                     |
| 4. Recovery progress (inner)  | Reload supervisor + reused fan-in / owner / adapter paths         | `SupervisedReloadEvent` (outer only)                     |

There is no single "owning layer" for the whole lane. The right
shape is one new event family **per layer that has unique
boundaries to report**, threaded through the existing
`*WithEvents` callback discipline so that consumers subscribe to
the ones they care about. Specifically:

* Case 3 (audio ready/not-ready) lives on the fan-in side: a
  `SessionFanInAudioEvent` family with `StartAudioAttempted`,
  `StartAudioSucceeded`, `StartAudioFailed !SessionFanInAudioIssue`,
  `WaitForReadyStarted`, `WaitForReadySucceeded`,
  `WaitForReadyTimedOut`, `StopAudioAttempted`,
  `StopAudioSucceeded`, `StopAudioFailed !SessionFanInAudioIssue`.
  The reload host wires the callback in the same way
  `*WithEvents` wires `mrhcOnEvent` today.
* Case 4 (recovery progress) is already partly served by
  `SupervisedReloadEvent`; what is missing is the *inner* events
  that fire during `sopsOpenStack`. Those should ride on the same
  callback the case-3 events ride on (the recovery path *is* the
  audio-start path running again).
* Case 1 (graph allocation outcomes) probably wants its own family
  on the reload-host layer because the sub-steps are reload-specific
  (compile new graph, install template, set polyphony, pre-warm
  pool). The taxonomy is large enough that folding it into the
  audio-event family would be a mistake.
* Case 2a (Haskell voice allocation) can ride on the fan-in /
  adapter layer's existing `SessionRuntimeIssue` flow; a v1 event
  family would expose `SriVoiceAllocationFailed` /
  `SriRealtimeQueueFull` as structured allocation events rather
  than only as drain-result issue values. Case 2b (the C++
  `VoiceAllocator` path) needs a new bidirectional FFI channel and
  is its own design lane; it should not block the cases above.

The naming convention should mirror the existing families:
`ManifestReloadEvent` → `ManifestPreflightEvent` →
`ManifestReloadAudioEvent` (case 3) →
`ManifestReloadGraphEvent` (case 1, later) →
`SessionVoiceAllocationEvent` (case 2a, after that) and a
separate C++-side surface for case 2b (much later).

## What is explicitly out of scope?

* **Compile-error / preflight events.** Closed in v1 (slice 1,
  `2cc734a` and the 2026-05-25 manual smoke in `93bb1e7`).
  Resolver-stage preflight is a separate event family from this
  lane.
* **Stale producer commands.** Closed end-to-end. The retired-
  bindings projection and stale-by-reload attribution path are
  independent of resource allocation.
* **Long-running supervisor escalation telemetry.** Cross-run
  bounded-retry observability is the next lane after this one,
  not part of it. Per-run supervisor events already exist.
* **Manifest / template compile.** The pure Haskell-side
  compile that `compileTemplateGraph` performs (lowering, region
  formation, schedule build into the dense `RuntimeGraph` *value*)
  runs before the reload-host hands off to the runtime. Its
  failures are caught by the planner and become `Left issue` in
  `planManifestReloadForDemo`, which is already covered by the
  resolver-stage preflight family. Runtime graph allocation,
  install, and per-template polyphony pre-warm in the owner /
  adapter are explicitly *in scope* for this lane (case 1 above);
  the boundary is "pure value produced by Haskell" vs "C runtime
  state allocated and installed".
* **GUI surfaces.** First consumer is the live-shell stdin sink,
  same as the preflight and stale-command lanes.
* **Refactoring the existing `SupervisedReloadEvent` /
  `ManifestReloadEvent` payloads.** Those work and have consumer
  tests; the new event families layer on top, they do not
  replace.
* **Polyphony pool exhaustion (case 2).** Both halves explicitly
  deferred from slice 1. Case 2a (the Haskell `runVoiceStart`
  allocation surface) is in scope for this lane but follows the
  audio-event slice; case 2b (the C++ `VoiceAllocator::note_on`
  path used by the MIDI demo) requires new bidirectional FFI
  surface and is a separate lane. Slice 1 can be served without
  touching either.

## What is the smallest first implementation slice?

Of the four cases, **case 3 (audio ready/not-ready transitions
across reload)** has the clearest live-session consumer and the
lowest implementation cost:

* The failure types (`SfaiStartFailed`, `SfaiReadyTimeout`) already
  exist as `SessionFanInAudioIssue` constructors.
* The boundaries are well-defined: `startAudio` call,
  ready-wait, success/failure, `stopAudio` symmetric pair.
* The existing live-session `audio running: yes` status line is
  the natural anchor — an `audio events:` block during reload
  composes with it directly.
* No new FFI surface, no C++ changes, no schema migration.

### Slice scope (as built in `8b9fb8f`)

1. `ManifestReloadAudioEvent` lives in
   `MetaSonic.App.ManifestReloadAudioEvent`, mirroring the layout
   of `MetaSonic.App.ManifestPreflightEvent`. The final v1
   constructor set brackets the two main audio-touching boundaries
   the stopped-audio op crosses (`hsaroStopOldAudio` and
   `hsaroStartNewAudio`) with full attempt / succeeded /
   `*Failed !SessionFanInAudioIssue` triples, and the
   listener-restart cleanup boundary (`hsaroStopNewAudio`,
   reached on `HsariListenerRestartFailed`) with just an
   attempt / succeeded pair — the cleanup slot is `IO ()` so
   failures are silent at the orchestrator boundary, and v1
   intentionally does not emit `MraeStopFailed` for the cleanup;
   a future slice can split the cleanup into its own constructors
   if a real consumer needs the distinction. Ready-timeout rides
   inside the start-failure payload (`SfaiReadyTimeout` inside
   `MraeStartFailed`) rather than emitting its own pair of
   constructors; that keeps the family small and pushes the wait
   detail into the existing issue value.
2. The callback is wired through
   `orchestrateHostStoppedAudioReloadWithEventsAndAudio`, a new
   entrypoint alongside the existing `*WithEvents` variant.
   Require-preserving and preserving-success paths emit no audio
   events; try-preserving forwards `onAudioEvent` into
   `realStoppedAudioInWindowReload` when the preserving phase
   rejects and the fallback gate admits, so the audio-event
   timeline matches the stopped-audio shape *only* when the
   fallback actually ran (`realTryPreservingInWindowReload` in
   `ManifestReloadTryPreservingHostStack`). Empty timelines —
   require-preserving, preserving-success, declined fallback,
   terminal preserving — render nothing.
3. The live shell renders an `audio events:` block in
   `runReloadWithSink` after `reload events:` and before
   `retired bindings:`. The block suppresses when empty so
   preserving reloads (and any other run that did not touch audio)
   do not print a dead header.
4. Ordered tests in `AppManifestLiveSession`:
   * Stopped-audio reload success path: timeline contains the
     stop and start brackets in order, and the block appears
     between `reload events:` and `retired bindings:`.
   * Audio-start failure path (synthesized via a fake FFI that
     returns nonzero from `startAudio`): timeline ends with
     `MraeStartFailed`, the strategy outcome is rejected, and the
     reload events block carries the matching strategy-level
     `HsariAudioRestartFailed`. The audio-event block surfaces the
     same payload one layer down.
5. Manual `--manifest-live-session` smoke recorded below as the
   [Manual live-session evidence: 2026-05-25 (stopped-audio)](#manual-live-session-evidence-2026-05-25-stopped-audio)
   section.

Slice follow-ups (not part of slice 1):

* The recovery path inside `sopsOpenStack` reuses the audio-start
  sequence and would naturally emit the same family; that wiring
  is deferred until a real consumer asks for cross-recovery
  audio-event visibility.
* Case 1 (graph allocation outcomes) wants a separate
  `ManifestReloadGraphEvent` family on the owner / adapter
  boundary; not started.
* Case 2a (the Haskell `runVoiceStart` allocation surface)
  would surface `SriVoiceAllocationFailed` /
  `SriRealtimeQueueFull` as structured events on the fan-in /
  adapter layer.
* Case 2b (the C++ `VoiceAllocator` path) waits for a real
  producer-facing consumer that justifies a new FFI channel.

## How this leaves the ROADMAP

After `8b9fb8f`, the ROADMAP's "Failure/event semantics across
compile and allocation/resource recovery" bullet is entirely
v1-covered for the live-session operator surface. Compile-error
surfacing v1 is covered by the preflight family; allocation/
resource recovery v1 is covered by the audio-event family. Two
follow-up slices remain explicitly consumer-gated and waiting for a
real driver — graph allocation outcomes (case 1, a future
`ManifestReloadGraphEvent` family on the owner/adapter boundary)
and voice allocation outcomes (case 2a, surfacing
`SriVoiceAllocationFailed` / `SriRealtimeQueueFull` as structured
events; case 2b stays deferred behind a new FFI channel).

## Manual live-session evidence: 2026-05-25 (stopped-audio)

The slice 1 runtime wiring was validated with a real
`--manifest-live-session` operator smoke driving a stopped-audio
reload between two valid demos.

Commands:

```sh
stack exec -- metasonic-bridge --authoring-manifest named-control send-return \
  > /tmp/metasonic-audio-events-smoke.json

printf 'demo:send-return\nstatus\nquit\n' \
  | stack exec -- metasonic-bridge \
      --manifest-live-session /tmp/metasonic-audio-events-smoke.json \
      named-control --strategy stopped-audio-only \
      2>&1 | grep -v "^ALSA lib" \
      | tee /tmp/metasonic-audio-events-smoke.log
```

The session opened the `named-control` plan with one voice. Typing
the known key `send-return` against `--strategy stopped-audio-only`
forced the stopped-audio route. The transcript shows the new
`audio events:` block rendered between `reload events:` and
`retired bindings:`, with the full stop-then-start bracket on the
audio side:

```text
Type a command, or <Enter> for status, 'help' for the command list, or <Ctrl-D> to exit:
>   preflight events:
    - preflight started: "send-return"
    - preflight succeeded: "send-return"

  supervised outcome: committed (new plan installed)
  reload events:
    - stopped-audio phase started
    - stopped-audio phase committed
  audio events:
    - audio stop attempted
    - audio stop succeeded
    - audio start attempted
    - audio start succeeded
  retired bindings:
    - all 1 voices retired by owner replacement
  supervisor events:
    - in-window: started
    - in-window: committed
  resource timeline:
    - in-window reload committed
    - serving plan: send-return
```

Status after the reload confirmed the new plan installed cleanly,
with audio still running and `last outcome` reading the same
committed-text from `LscStatus`:

```text
  status:
    current plan demo: send-return
      fan-in:
    audio running: yes
    queue depth: 0
    owner status: SessionOwnerReady
    reload status: SessionFanInNormalOperation
    active voices: 2
    ingress:           open demo=send-return ui-controls=0 osc-controls=0 midi-cc=0 defaultVoice=v0 oscPort=7001 midi=off
    last outcome:      committed (new plan installed)
```

Transcript: `/tmp/metasonic-audio-events-smoke.log`.

What the transcript pins:

* The `audio events:` block renders only when a stopped-audio
  reload runs (the preflight succeeded path proves the block is
  present alongside a committed strategy outcome).
* The block carries both halves of the audio bracket
  (`audio stop attempted` → `audio stop succeeded` →
  `audio start attempted` → `audio start succeeded`) so an
  operator can see which side of the install failed if the
  `audio start` half had reported a nonzero status.
* Ordering is stable: `reload events:` precedes `audio events:`
  precedes `retired bindings:`, mirroring the design's "between
  reload events and retired bindings" placement.
* `last outcome` continues to read the same committed-text it did
  before the slice landed, so `LscStatus` consumers are unaffected.

Require-preserving and preserving-success paths emit no audio
events by design; that contract is pinned by the slice 1 ordered
tests in `AppManifestLiveSession` and is not exercised by this
smoke. Try-preserving emits audio events only when the preserving
phase rejects and the fallback gate admits the stopped-audio
fallback (`realTryPreservingInWindowReload` forwards
`onAudioEvent` into the stopped-audio path); that scenario is
covered by the slice 1 tests too and is also not exercised by
this stopped-audio-only smoke.
