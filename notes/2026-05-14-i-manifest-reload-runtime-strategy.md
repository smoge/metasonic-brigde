# Manifest Reload Runtime Strategy

Date: 2026-05-14

Status: design note plus first non-audio helper slice. The
construction-time install boundary is recorded in
`2026-05-14-g-manifest-reload-install-strategy.md` and the app-visible
construction smoke in `2026-05-14-h-manifest-session-construction-smoke.md`.
This note pins the v1 reload contract; the landed implementation covers the
session-layer helper and diagnostic CLI smoke only.

Implemented in the first helper slice:

- `MetaSonic.Bridge.FFI.createRTGraph` / `destroyRTGraph` expose a structured
  manual RTGraph lifetime for higher-level reloadable owners.
- `MetaSonic.Session.Owner` exposes `SessionOwnerHandle`,
  `acquireSessionOwner`, and `releaseSessionOwner` so a longer-lived host can
  own multiple owner generations without dangling a callback-scoped
  `SessionOwner`.
- `MetaSonic.Session.FanIn` now serializes queue, reload status, and current
  owner generation in one `MVar`, rejects producer enqueues with
  `SeiReloadInProgress` during reload and `SeiSessionUnavailable` after
  post-dispose construction failure, and implements
  `reloadSessionFanInHostOwnerStoppedAudio`.
- `MetaSonic.Session.ManifestReload.Runtime.reloadManifestSessionStoppedAudio`
  takes a prevalidated `ManifestReloadPlan`, enforces the empty-queue
  admission rule, replaces the owner, and returns a
  "listeners/producers must restart" report. It does not call
  `startAudio` / `stopAudio`, validate manifests, drain queues, or touch
  listener brackets.
- `--manifest-stopped-audio-reload-smoke MANIFEST.json DEMO` reads an
  external manifest, plans against the built-in authored-demo catalog, creates
  an existing non-audio fan-in host, calls the stopped-audio reload helper,
  and prints queue, reload, and owner status. It does not start/stop audio or
  restart listener/producer brackets.

## Three Strategies

There are three honest answers to "reload an existing session from a new
manifest". They are different products, not internal variants.

### Stopped-Audio Clear/Rebuild

The host quiesces producers and listeners, drains the fan-in queue against
the old owner while audio is still running, verifies the queue is empty
and producer state is at rest, *then* stops audio and calls the reload
helper with a pre-validated `ManifestReloadPlan`. On success the host
restarts audio against the new owner and reopens listener/producer
brackets. The helper itself only swaps the owner under its reloadable
lifetime primitive.

- Audible continuity: explicitly broken. The user hears a gap.
- Substrate: the C ABI exposes `rt_graph_start_audio` /
  `rt_graph_stop_audio`, but those entry points take a `Ptr RTGraph`,
  output channel count, and device id
  ([FFI.hs:2397-2401](../src/MetaSonic/Bridge/FFI.hs#L2397-L2401)) — device
  policy that today lives at the app
  ([Main.hs:1456](../app/Main.hs#L1456)). V1 does not move that policy into
  the session layer. The reloadable owner lifetime primitive and serialized
  admission point have landed; host-level recovery after post-dispose
  construction failure remains policy owned by the host.
- Correctness risk: low at the session layer, conditional on the host
  quiescing producers, draining the queue live, and then stopping audio
  before calling the helper. The helper itself does not migrate live state
  and does not touch the audio device.
- Policy burden: small at the helper, real at the host. The helper enforces
  one precondition (queue empty) and reports one completion signal
  ("listeners must restart"); the host owns audio stop/restart, producer
  quiescence, listener restart, and post-failure recovery.

### Preserving Live Hot-Swap

Compute migration eligibility against the current owner, publish a
`CmdHotSwap` through `stepSessionOwner`, wait for the audio generation to
retire, verify the retired-stat / migration outcome, and either commit or
diverge.

- Audible continuity: preserved when migration is eligible.
- Substrate: §5.2 state-migration contract, generation wait, retired-stat
  verification, divergence-after-publish policy. All already implemented for
  hand-built `CmdHotSwap`; manifest projection feeds the same machinery.
- Correctness risk: high. The preserving contract is the strictest of the
  three. A weakened version is worse than no version.
- Policy burden: large. Migration eligibility for manifest-derived graphs is
  a separate analysis from the existing per-edit case.

### Host Teardown/Rebuild

The app-level host disposes its `SessionOwner`, any per-producer queues, the
FanIn service, listeners, and audio device, then reconstructs the whole
stack from the new manifest.

- Audible continuity: broken, like stopped-audio, but at a higher layer.
- Substrate: nothing manifest-specific; this is "stop the program and start a
  new one" minus process restart.
- Correctness risk: low at the session layer, but the host has to define
  producer reconnection, device reopen, and listener restart by hand.
- Policy burden: lives in the app, not in the session layer.

## Decision: Stopped-Audio Reload As V1

Stopped-audio clear/rebuild is the right first runtime reload. It is the
strategy with the lowest correctness risk that still gives the session layer
a defined contract, rather than pushing the work to the app or to live
migration.

A stopped-audio v1 should not be named "the" reload. It is one of three. The
helper should be named honestly, for example
`reloadManifestSessionStoppedAudio` rather than `reloadManifestSession`. The
unqualified name remains reserved for a future policy that owns all three
strategies behind a single interface, if that ever exists.

## V1 Contract: Failure Behavior

The implementation can wait. The contract cannot. Each axis below picks a
side and commits.

### Queued Producer Commands

Require the queue to be empty at admission. Reject the reload if it is not.
The helper does not drive drain itself.

Why not drain-as-part-of-reload: the helper has no producer registry and no
way to stop new enqueues during a drain that it is itself driving. Any
"close ingress, then drain" sequence either (a) leaves a window where the
helper waits for producers it cannot quiesce, or (b) silently bundles
producer-quiescence policy into the session layer. Both push policy into
the helper that the host already has to own.

Why not silent clear: producers advance local state on accepted enqueue.
[MIDIProducer.hs:271-294](../src/MetaSonic/Session/MIDIProducer.hs#L271-L294)
mutates `mpsActiveNotes` when a note-on is accepted;
[PatternProducer.hs:216-229](../src/MetaSonic/Session/PatternProducer.hs#L216-L229)
advances `ppsNextStart`/`ppsBacklog` when a block is accepted. Dropping
already-accepted queued commands leaves producers believing the commands
committed while the new owner never sees them. That is invariant violation,
not back-pressure, and the producer-local state shapes have no rollback
hook.

The v1 admission sequence is therefore:

```text
[host] validates ManifestReloadPlan.
[host] drives producers and listeners to quiescence.
[host] drains the fan-in queue against the old owner while audio is
       still running.                       [accepted commands commit live]
[host] verifies the queue is empty and producer state is at rest.
[host] stops audio.
[host] calls reload with the pre-validated plan.

1. reload acquires the fan-in lock; under the lock:
   - if reload status != NormalOperation, release, return
     ReloadAlreadyInProgress;
   - if the queue is non-empty, release, return ReloadQueueNotEmpty;
   - otherwise, transition status to ReloadInProgress, release.
2. reload disposes the old owner, constructs the new owner.
                                          [no lock held during construction]
3. reload acquires the lock briefly, installs the new owner reference,
   transitions to NormalOperation (or ReloadFailed), releases.

[host] restarts audio against the new owner's RTGraph.
[host] reopens listener/producer brackets bound to the new owner.
```

Drain happens before stop-audio for a concrete reason: accepted producer
commands step through realtime adapter calls that expect the live audio
callback. `runVoiceStart` commits after `c_rt_graph_realtime_activate`
returns
([RTGraphAdapter.hs:680](../src/MetaSonic/Session/RTGraphAdapter.hs#L680));
control writes and voice stops go through sibling realtime entry points
with the same shape. Stepping those against a stopped backend leaves the
runtime queue without its normal servicing path. Drain is therefore a live
operation that must finish before the host calls `stopAudio`.

The helper does not call `startAudio` / `stopAudio`. It assumes audio is
stopped on entry and remains stopped until the host restarts it after the
call returns. The session layer never sees the device id or output channel
count.

Producers attempting to enqueue between step 1's release and step 3 take
the lock, observe `ReloadInProgress`, and reject. The reload-in-progress
rejection variant exists for that narrow window only; the precondition
window (queue non-empty at admission) is the host's problem, surfaced as a
distinct rejection on the reload helper itself, not on producer enqueue.

`ReloadFailed` is a distinct terminal state because the post-failure host
has no owner installed (see "Old-Owner Survival"). Producers reading that
state see a different rejection than the in-progress one; the host has no
path back to `NormalOperation` without an explicit construction retry by
the app.

Implementation note: there is no IORef fast path for the reload-state
check. An admission decision split between an unlocked `readIORef` and a
later `takeMVar` is a TOCTTOU race — a producer can read `NormalOperation`,
then reload admits, then the producer takes the queue lock and enqueues
during the reload window. The serialized decision point must be one piece
of state. The simplest correct shape is a single
`MVar SessionFanInHostState` containing the queue, the reload status, and
(see "Owner Lifetime") the current owner reference. Enqueue, drain, and
reload all serialize through the same MVar. Construction work itself runs
unlocked between admission and commit, so producers block on the lock only
for the brief admit/commit windows.

### Active Voices

Terminate. Stopped-audio reload makes no audible-continuity promise, so the
contract should be the simpler one: when audio stops, every active voice
ends, and the new owner starts with an empty `ssVoices`. No retired-stat
collection, no migration table, no voice-key reuse policy.

Voice keys may be re-issued by future producers against the new owner; their
identity is local to the new session, not preserved across reload.

### Stale Controls

Drop. Control writes that arrived before the reload was admitted are either
already stepped or rejected through the queue-full path. Control writes
targeting `ControlTag`s that no longer exist in the new control surface are
rejected by ordinary owner validation — there is no manifest-specific repair.

Producers may discover stale tags only after their next enqueue; that is the
producer's responsibility. Manifest reload does not migrate control state.

### Producer-Local State After Reload

Producers and listeners persist state that outlives the owner.
[MIDIListener.hs:273-278](../src/MetaSonic/Session/MIDIListener.hs#L273-L278)
keeps a `MIDIListenerWorkerState` carrying active notes, pitch bends,
sustain pedal status, and pending control coalescing entries; the producer
state inside it (`mpsActiveNotes`, `mpsPitchBends`, `mpsDeferredNoteOffs`)
references `VoiceKey`s that the new owner has never heard of. After a
reload, the new owner has empty `ssVoices`, so:

- a subsequent note-on for a channel/note already in `mpsActiveNotes` is
  rejected by the producer with `MpiNoteAlreadyActive`, even though the
  new owner would happily start the voice;
- a subsequent note-off for that pair sends `CmdVoiceOff` for a
  `VoiceKey` the new owner does not have;
- deferred sustain-release note-offs target retired voice keys;
- pending coalesced CC writes target retired voice/control pairs.

V1 stopped-audio reload does not have a "reset every listener and producer
state" mechanism, and inventing one would touch every producer/listener
module. The contract is strict quiescence, end-to-end:

- the host quiesces every producer and listener before calling reload —
  no active notes, no held sustain, no pending pitch bends, no in-flight
  coalesced CCs, and an empty fan-in queue. The session layer cannot
  observe most of those, so it does not try to.
- the reload helper enforces the only precondition it can observe (queue
  empty) and rejects otherwise; see "Queued Producer Commands".
- on successful reload, the helper returns a "listeners and producer state
  must be restarted" signal. The host tears down each existing
  `MIDIListener`, `OSCListener`, `Pattern` runner, and UI producer bracket
  bound to the old owner, and opens new brackets bound to the new owner.
  This is bracket-level restart, not in-place state reset:
  [MIDIListener.hs:241-262](../src/MetaSonic/Session/MIDIListener.hs#L241-L262)
  forks reader/flusher threads inside a single `bracket`, with no in-place
  reset hook. "Fresh state" therefore means new bracket entries (new
  threads, new worker state); the existing bracket cannot keep its threads
  and adopt a new owner.
- the helper does not iterate over producers; it has no producer registry
  to iterate over.

This is the part of v1 that is not "owner is replaced under the existing
host." Listener and producer *configuration and wiring decisions* persist
(the app knows it still wants MIDI ingress on the same source, OSC on the
same port, the same Pattern shape, etc.), but the concrete worker brackets
and worker state are torn down and recreated by the host before and after
the reload call. The framing under "Why Not Host Teardown/Rebuild First"
should be read with that qualification: the *fan-in host and its
reloadable owner slot* persist across reload; listener worker brackets
and the audio device handle do not.

This is more work for the host than a "magic reload" would be. That is the
trade. A helper that promised to drain ingress, quiesce producers, and
reset listener state would be inventing policy the host has to own anyway,
and getting it wrong silently. Strict quiescence makes the host's
responsibility visible and the helper's contract small.

### Resource Allocation Failures

The helper takes a pre-validated `ManifestReloadPlan`. Manifest decode,
catalog matching, role validation, and resource-policy rejection all run
in `planManifestReload` before the helper is ever called — pre-admission,
pre-quiescence, pre-dispose. If the plan is invalid, the host learns about
it before paying the cost of quiescing producers, draining the queue, or
stopping audio, and the old owner is undisturbed.

Inside the reload window, the only resource failure the helper can produce
is `withSessionOwner` returning `SessionAdapterSetupIssue` after the old
owner has already been disposed — i.e., the new RTGraph or adapter fails
to construct. The helper reports that failure once and exits the reload
window in the `ReloadFailed` state.

Audio restart failure is not a session-layer failure mode under v1. The
host calls `startAudio` against the new RTGraph after the helper returns;
any audio restart failure surfaces in the host, with the new owner
already constructed and installed.

The helper does not attempt a fallback to the previous graph, because by
the time construction is attempted, the old owner is already gone (see
below).

### Old-Owner Survival After Failed Reload

V1 picks dispose-first.

```text
[host] validates plan via planManifestReload         [may fail; old owner intact]
[host] quiesces producers/listeners
[host] drains fan-in queue against the old owner     [audio still running]
[host] verifies queue empty and producer state at rest
[host] stops audio

helper:
  admit reload                                       [may reject; old owner intact]
    -> dispose old owner
    -> construct new owner from plan                 [may fail; ReloadFailed]
    -> install new owner reference
  exit reload window

[host] restarts audio against the new owner          [may fail; new owner intact]
[host] reopens listener/producer brackets bound to the new owner
```

Pre-admission rejections (invalid plan, queue non-empty,
`ReloadAlreadyInProgress`) leave the old owner intact and audible work
unaffected. Plan validation happens before the host pays any audio cost;
a queue-not-empty rejection after stop-audio is a host-side bug (host
failed to verify quiescence) rather than a normal path — the host should
restart audio against the still-installed old owner.

If construction fails after the old owner has been disposed, the host is
left with no session owner; the helper returns a failure value, and the
host decides whether to retry construction from the same plan, fall back
to a previous plan, or exit. None of those decisions live in the session
layer.

The alternative — construct-new-alongside-old, swap-on-success — is the
right answer for an eventual live or preserving strategy. It doubles peak
resource use, requires a concurrent-owner invariant that nothing in the
current session code expresses, and asks the session layer to choose between
two owners on failure. V1 should not buy any of that.

This is a binding choice. Future strategies that need old-owner survival are
not "v2 of stopped-audio reload"; they are different reload strategies under
their own names.

## What V1 Does Not Try To Be

- preserving migration of voices, control state, or DSP state across reload;
- atomicity inside the audio callback (audio is stopped, so the question
  does not apply);
- audio device or audio-config ownership — the helper does not call
  `startAudio` / `stopAudio` and does not know the output channel count or
  device id;
- listener thread orchestration — the helper does not start, stop, or
  reset listener brackets;
- producer-facing repair beyond the queue-rejection signal and the
  "listeners must restart" completion signal;
- automatic reset of per-producer or per-listener state — the host owns
  that step;
- manifest validation inside the reload window — the helper takes a
  pre-validated `ManifestReloadPlan`;
- multi-owner or multi-host orchestration;
- partial reload — reload is whole-owner only;
- manifest hot-edit — manifest is the input, not a stream of deltas;
- catalog selection beyond the built-in authored-demo catalog;
- recovery of the previous owner on failure.

## Why Not Preserving Hot-Swap First

The preserving migration contract already exists for hand-built
`CmdHotSwap`. Reusing it for manifest reload requires:

- migration eligibility analysis against manifest-derived graphs, which is
  not the same as the per-edit case the existing contract was designed for;
- a stronger divergence-after-publish policy, because manifest reload
  changes more than one node at a time;
- coordination with producers whose commands targeted the old control
  surface, which manifest reload may invalidate wholesale.

Each of those is a separate design question. Bundling them into the first
reload slice is how the §5.2 contract gets quietly weakened.

## Why Not Host Teardown/Rebuild First

Host teardown/rebuild is honest and may be the right long-term answer for
app-level manifest import. It does not need a session-layer design note,
because the session layer's job is then only to expose construction.

The reason it is not v1 is that host teardown/rebuild disposes the fan-in
host along with everything else, which means producer/listener/queue
*types and wiring decisions* are reconstructed from scratch by the app. A
stopped-audio reload inside the session layer means the app keeps its
*fan-in host and its reloadable owner slot* in place; only the owner
inside the host is replaced. Listener worker brackets and the audio
device handle still come down (audio is stopped, listener brackets are
torn down to reset state — see "Producer-Local State After Reload" — and
both are reopened by the host afterward), but the producer wiring around
the fan-in host stays intact across reload.

### Owner Lifetime: The Prerequisite That A Mutable Slot Does Not Solve

`withSessionOwner`
([Owner.hs:154-166](../src/MetaSonic/Session/Owner.hs#L154-L166))
is callback-scoped. The `SessionOwner` it produces is only valid inside the
callback, because the owner handle is released when the callback returns.
Storing that `SessionOwner` in an `IORef` or `MVar` and then returning from
`withSessionOwner` would yield a dangling reference: the slot points at an
owner whose `RTGraph` has already been released.

A plain mutable slot of `SessionOwner` is therefore not enough. The reload
helper cannot dispose the old owner by closing its bracket and then open a
new bracket inside the slot, because the slot's lifetime is longer than any
single `withSessionOwner` call.

V1 needed an explicit reloadable owner lifetime abstraction. Two honest
shapes were available:

1. **`withReloadableSessionOwner`.** A new bracket that manually owns the
   `withRTGraph` lifetime via `mask`/`bracket` primitives rather than as a
   continuation. It exposes a `ReloadableSessionOwner` handle holding the
   serialized state described under "Queued Producer Commands". The reload
   operation runs `bracket`-style cleanup on the current owner and then
   constructs a fresh owner under the same outer mask, swapping the handle
   atomically. The outer bracket releases whichever owner is current at
   teardown.

2. **Session-layer host teardown/rebuild.** The fan-in host is itself
   rebuilt under the hood: the existing `withSessionFanInHost` bracket
   closes (releasing the current owner), and a new `withSessionFanInHost`
   bracket opens with the new graph, while the producer-facing handle the
   app holds is a stable indirection that re-points at the new host. This
   is structurally close to "Host Teardown/Rebuild" at a higher layer,
   except it stays inside the session module — but it requires the same
   indirection on the producer-facing side.

(1) was the more honest shape for stopped-audio reload because it keeps a
single host lifetime over multiple owner generations and matches the v1
admission/commit sequence above. The landed slice implements that shape
without adding a public `withReloadableSessionOwner` wrapper:

- `MetaSonic.Bridge.FFI` exposes `createRTGraph` / `destroyRTGraph`, keeping
  `withRTGraph` as the default scoped API while making manual ownership
  available to higher-level brackets.
- `MetaSonic.Session.Owner` exposes an abstract `SessionOwnerHandle` with
  `acquireSessionOwner`, `releaseSessionOwner`, and
  `sessionOwnerHandleOwner`. The plain `withSessionOwner` path now delegates
  to that handle and still presents the same callback-scoped API.
- `MetaSonic.Session.FanIn` owns the current `SessionOwnerHandle` inside one
  `SessionFanInHostState` MVar together with the queue and reload status. The
  host bracket releases whichever owner generation is current at teardown.
- `reloadSessionFanInHostOwnerStoppedAudio` performs the dispose-first
  replacement under that host lifetime. It masks the dispose/acquire/install
  sequence so asynchronous interruption cannot strand the host in the
  admitted reload window or leak a newly acquired owner.

The reloadable lifetime therefore lives where the contract needs it: at the
fan-in host boundary. `Owner.hs` exposes only the small manual handle needed
by that host; callers that do not need replacement continue to use
`withSessionOwner`.

## Open Implementation Questions

Closed by the first helper slice:

- lifetime shape: the fan-in host owns a replaceable `SessionOwnerHandle`
  generation under one serialized state MVar;
- enqueue rejection shape: producers now see `SeiReloadInProgress` during the
  admitted reload window and `SeiSessionUnavailable` after a dispose-first
  construction failure leaves the host with no owner;
- command surface: manifest-specific stopped-audio reload lives in
  `MetaSonic.Session.ManifestReload.Runtime`, while the lower-level owner swap
  remains on `MetaSonic.Session.FanIn`;
- completion signal: the manifest helper returns
  `msarrListenersMustRestart = True`, leaving listener/producer bracket
  restart to the host.
- diagnostic CLI smoke: `--manifest-stopped-audio-reload-smoke` exercises the
  helper without pretending to be an audio-running reload path.

Still open for host integration:

- a host command that performs the whole stop window: quiesce producers and
  listeners, drain while audio is live, stop audio, call the helper, restart
  audio, and reopen producer/listener brackets;
- an app-owned recovery policy after `SfriOwnerSetupFailed`, since the helper
  intentionally leaves the host with no owner after post-dispose construction
  failure.

## Review Checklist

The landed helper and any future host integration should still satisfy:

- the helper name spells out the strategy (`StoppedAudio` or equivalent);
- the contract above is the contract — no silent weakening of any of the
  six axes (queued commands, active voices, stale controls, producer-local
  state, resource failure, old-owner survival);
- the helper takes a pre-validated `ManifestReloadPlan`; manifest decode,
  catalog matching, and resource-policy validation run before admission,
  never post-dispose;
- the helper does not call `startAudio` / `stopAudio` and does not touch
  any device handle; the host drains the fan-in queue while audio is
  still running, *then* stops audio, calls the helper, and restarts audio
  after — drain must precede stop-audio because accepted commands step
  through live realtime adapter entry points;
- a reloadable owner lifetime primitive exists at the `Owner.hs`/`FanIn.hs`
  layer before the reload helper, not invented inside it;
- the fan-in admission decision lives in one serialized piece of state —
  no IORef fast paths split from the queue lock;
- reload requires the queue to be empty at admission; it does not drive
  drain, does not wait for drain, and does not silently discard accepted
  commands;
- producer-state quiescence is the host's responsibility; the helper does
  not inspect producer-local state and does not iterate over producers;
- the reload helper signals "listeners and producer state must be
  restarted" on success; "restart" means new listener brackets bound to
  the new owner, not in-place state reset;
- producers can distinguish "reload in progress" from "host has no owner",
  and the reload helper distinguishes "queue not empty" from "already in
  progress" at admission;
- a failed reload leaves the host with no owner, not a half-installed one;
- preserving and teardown remain separate, named strategies with their
  own notes.
