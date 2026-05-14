# Manifest Reload Install Strategy

Date: 2026-05-14

Status: implemented for the v1 construction-time helper and owner/RTGraph
smoke coverage. This note remains the install-strategy design record for the
first runtime-facing manifest slice. The app-visible construction smoke is
covered by `2026-05-14-h-manifest-session-construction-smoke.md`.

## Decision

The first runtime-facing manifest slice is construction-time only.

V1 uses a `ManifestReloadPlan` to construct a new session owner with:

- `mrlpTemplateGraph` as the owner graph;
- `mrlpAdapterOptions` installed through `SessionOwnerOptions`;
- `mrlpControlSurface` available to later UI, OSC, MIDI, or policy code;
- `mrlpArbitrationPolicy = FifoOnly` unless a later explicit policy owner is
  introduced.

It should not claim to reload an already-running owner. The manifest plan is
the selected, validated startup shape for a new owner/session, not a live
mutation protocol.

## Why Construction-Time First

The planner answers which catalog graph the manifest refers to and which static
resource policy should be used. It does not answer the install-strategy
question for an existing owner.

Existing session code already has a clear construction path:

```text
TemplateGraph
  -> SessionOwnerOptions
  -> withSessionOwner
  -> stepSessionOwner
```

The manifest plan feeds that path directly. The landed smoke test proves the
planner output is consumable by the runtime owner without choosing live-reload
semantics.

By contrast, true reload of an existing owner has different correctness
contracts depending on strategy:

- stopped-audio clear/rebuild needs explicit interruption semantics;
- preserving hot-swap needs the existing §5.2 state-migration contract;
- live preserving hot-swap needs publish/wait/collect failure policy;
- teardown/rebuild needs host lifecycle and producer-drain policy.

Those strategies should remain separate, named choices.

## Pure Projection Helpers

The strategy-independent helpers are already the right shared surface:

```haskell
manifestReloadCommand
  :: ManifestReloadPlan
  -> SessionCommand

manifestSessionOwnerOptions
  :: SessionOwnerOptions
  -> ManifestReloadPlan
  -> SessionOwnerOptions
```

`manifestReloadCommand` produces `CmdHotSwap (mrlpSwapLabel plan)
(mrlpTemplateGraph plan)`. It does not say when the command should be stepped.
Construction-time v1 does not need to run that command to create the initial
owner, because the owner is already constructed with `mrlpTemplateGraph`.

`manifestSessionOwnerOptions` is a transformer, not a constructor. The caller
still owns builder capacity and max-frame policy. The plan's adapter options
replace the base adapter options entirely, because the manifest resource policy
is authoritative for template polyphony.

## V1 Construction Helper Shape

Do not call the v1 helper `withManifestSession`.

That name should remain available for a later API that actually owns a manifest
reload lifecycle. A construction-only helper should be named honestly, for
example:

```haskell
constructManifestSessionFromPlan
  :: ManifestReloadPlan
  -> SessionOwnerOptions
  -> (SessionOwner -> IO a)
  -> IO (Either SessionAdapterSetupIssue a)
```

The helper lives at the runtime boundary in the sibling module
`MetaSonic.Session.ManifestReload.Construct`. Keep
`MetaSonic.Session.ManifestReload` IO-free so the planner and projection
helpers remain cheap pure tests.

Current implementation:

```haskell
constructManifestSessionFromPlan plan baseOwnerOptions action =
  withSessionOwner
    (mrlpTemplateGraph plan)
    (manifestSessionOwnerOptions baseOwnerOptions plan)
    action
```

This helper brackets a fresh owner, but it does not reload, repair, migrate,
or interrupt an existing session.

The callback receives only `SessionOwner`, mirroring `withSessionOwner`.
Manifest-derived metadata such as `mrlpControlSurface` and
`mrlpArbitrationPolicy` remains the caller's responsibility to thread through
or close over.

## Non-Goals

V1 construction-time install must not implement:

- preserving hot-swap of a live owner;
- the §5.2 state-migration contract;
- audio-stream interruption semantics;
- failure recovery for partial installs;
- concurrent-session install or multi-producer install arbitration;
- background queue drain or producer lifecycle ownership;
- CLI manifest import that installs or reloads a runtime owner;
- app-level catalog selection beyond the built-in diagnostic catalog.

These are not rejected as future features. They are separate strategies with
different contracts.

## Later Install Strategies

### Stopped-Audio Reload

The selected stopped-audio v1 contract is recorded in
`2026-05-14-i-manifest-reload-runtime-strategy.md`. It picks strict
quiescence and dispose-first fresh-owner construction, with a small helper
boundary: the host validates the `ManifestReloadPlan` ahead of time,
quiesces producers and listeners, drains the fan-in queue against the old
owner *while audio is still running* (because accepted producer commands
step through live realtime adapter entry points), verifies the queue is
empty and producer state is at rest, and *then* stops audio and calls the
helper. The helper rejects if the queue is not empty; otherwise it
disposes the old owner and constructs a new one. The host restarts audio
against the new owner and reopens listener/producer brackets bound to it.
The helper does not call `startAudio` / `stopAudio`, does not validate the
manifest, and does not touch listener threads. Manifest decode and
resource-policy rejection happen pre-admission, never post-dispose. A
failed reload (post-dispose construction failure) leaves the host with no
owner. Active voices terminate; stale control writes are rejected on next
enqueue; per-producer and per-listener bracket state is torn down and
recreated by the host.

An earlier sketch — "step `manifestReloadCommand` against an existing owner
after a policy for stopping the backend, draining producer work, stepping
the command, and restarting" — is intentionally not the v1. Stepping
`CmdHotSwap` against an existing owner is the preserving-hot-swap path, not
stopped-audio reload; bundling it under the stopped-audio name would have
quietly weakened the §5.2 preserving contract.

The i-note also pins two implementation prerequisites that the v1 helper
cannot invent itself. First, the fan-in admission decision must live in a
single serialized piece of state (one MVar holding queue + reload status),
because an IORef "fast path" split from the queue lock is a TOCTTOU race.
Second, the v1 needs an explicit reloadable owner lifetime primitive at
the `Owner.hs`/`FanIn.hs` layer: `withSessionOwner` is callback-scoped, so
a plain `IORef SessionOwner` would dangle once the outer bracket closed.
Either a new `withReloadableSessionOwner` bracket or a session-layer host
teardown/rebuild under a producer-facing indirection. The latter
converges with host teardown/rebuild and weakens the v1 thesis. See the
i-note for full details.

### Preserving Hot-Swap

A preserving strategy can use `manifestReloadCommand` through
`stepSessionOwner`, but only under the already established preserving
hot-swap contract:

- recompute preservation against current owner state at execution time;
- migrate compatible live voice slots and stateful DSP state;
- commit only after runtime migration is verified;
- treat post-publish uncertainty as owner divergence until repair exists.

Manifest reload should not weaken those rules.

### Host Teardown/Rebuild

A host-level rebuild strategy can destroy the old owner and construct a new one
from the manifest plan. That is different from construction-time v1 because it
must define what happens to external producers, queued commands, active voices,
audio device ownership, and user-visible failure.

## Implemented Smoke Coverage

The construction helper and smoke coverage have landed:

1. Build a valid `ManifestReloadPlan`.
2. Derive owner options with `manifestSessionOwnerOptions`.
3. Construct an owner with the plan's `mrlpTemplateGraph`.
4. Step one ordinary `CmdVoiceOn` and observe a committed owner state.

That test proves planner output can cross the existing owner/adapter boundary.
It does not start a live audio stream, depend on PortAudio, or claim reload
semantics.

The CLI now exposes the same construction-time boundary with:

```text
metasonic-bridge --manifest-session-smoke MANIFEST.json DEMO
```

That command reads an external manifest, plans against the built-in
authored-demo catalog, constructs a fresh owner, prints status, and exits. It
does not step `CmdHotSwap`, start audio, or reload an existing owner.

The existing pure tests should continue to cover:

- `manifestReloadCommand` projection;
- `manifestSessionOwnerOptions` preserving owner sizing while replacing
  adapter options;
- control-surface projection and FIFO arbitration default.

The `manifestReloadCommand` test should stay even though construction-time v1
does not step that command: stopped-audio reload and preserving hot-swap
strategies will consume the same projection later, so it is shared
infrastructure rather than v1-only code.

## Review Checklist

The landed helper and any future edits should continue to satisfy:

- The helper name does not imply live reload.
- The helper constructs a fresh owner from `mrlpTemplateGraph`.
- The helper applies `mrlpAdapterOptions` through `SessionOwnerOptions`.
- No `CmdHotSwap` is stepped implicitly during construction.
- No producer ownership or arbitration claims are introduced.
- Failure reporting is exactly `withSessionOwner` construction failure, not a
  new recovery policy.
