# Path To Hot-Swap Reloading Running Graphs

Date: 2026-05-15

Status: design path note. This note does not change the current reload
contract. It records how the project moved from the landed
manifest/stopped-audio reload infrastructure toward manifest-driven
preserving hot-swap of audio-running graphs.

Implementation update: the preserving manifest reload path described here has
now landed through `CmdHotSwapPreservingOnly`,
`reloadManifestSessionPreservingHotSwap`, `HostPreservingReloadOps`,
`reloadManifestPreservingHost`, and the app-level
`reloadManifestHostWithStrategy` selector. The remaining gaps are concrete
operator-facing strategy selection, producer/listener binding policy for real
app ingress, device-backed smoke coverage, and longer-term resource/recovery
events.

## Summary

Preserving live hot-swap is already implemented at the runtime/adapter
layer. `preservingHotSwapPlan` in `MetaSonic.Session.RTGraphAdapter`
builds the migration plan, `LiveHotSwapProtocol` drives the
publish/wait/collect/verify ordering, and the live preserving path is
covered by `sessionLiveHotSwapOrchestrationTests` (Session Prep O) with
mock adapters. The gap is not the hot-swap primitive itself; it is the
concrete product/app path that exposes the manifest-derived
`CmdHotSwapPreservingOnly` strategy through real ingress and operator-facing
controls.

The manifest reload work moved toward running-graph hot-swap by building the
reload control plane: manifest validation, catalog matching, preserving-only
hot-swap command projection, fan-in ownership, reload admission, host
quiescence, ingress restart, and failure typing. Those are prerequisites for
any reload strategy.

The current stopped-audio path is not itself the hot-swap path. It must
remain a sibling strategy, not become live hot-swap by gradually removing
`stopAudio`. Preserving live hot-swap has a stricter contract: the audio
callback continues running, the new graph is published through the
prepared-swap protocol, the old generation retires, migration counters are
verified, and session state commits only after proof.

The preserving reload is therefore a named sibling path, not a mutation of
`reloadManifestSessionStoppedAudio`.

## Current Building Blocks

The project already has more substrate for this than the manifest reload
notes might suggest:

- `MetaSonic.Session.ManifestReload` validates manifest/catalog/resource
  policy and projects a `ManifestReloadPlan`.
- `manifestReloadCommand` projects that plan into
  `CmdHotSwapPreservingOnly`, so manifest reload cannot silently use the
  runtime clear/rebuild fallback.
- `MetaSonic.Session.RTGraphAdapter` already contains a preserving
  hot-swap implementation for eligible running graphs: build next world,
  publish, wait for generation retirement, collect retired swap stats,
  verify migration, and commit.
- `MetaSonic.Session.Owner` classifies terminal divergence after runtime
  hot-swap failures.
- `MetaSonic.Session.FanIn` serializes producer queue, owner, audio-running
  state, and reload status behind one lock.
- `MetaSonic.Session.FanInService` can quiesce/drain and resume its worker,
  which gives host orchestration an explicit handoff point.
- `MetaSonic.Session.ManifestReload.Runtime` provides
  `reloadManifestSessionPreservingHotSwap`, which submits the preserving-only
  command through the live fan-in path and reports the enqueue/drain/snapshot
  result.
- `MetaSonic.App.ManifestReloadOrchestration` provides
  `HostPreservingReloadOps`, the preserving sibling of the stopped-audio host
  sequence.
- `MetaSonic.App.ManifestReloadHost` wires both stopped-audio and preserving
  commands against real session pieces and exposes
  `reloadManifestHostWithStrategy` with `RequirePreserving`,
  `TryPreservingThenStoppedAudio`, and `StoppedAudioOnly`.

Those pieces mean the preserving manifest path does not need to invent a
new graph install substrate. The remaining work is to decide how concrete app
ingress and operator-facing commands expose those strategies.

## What Reuses From Stopped-Audio Scaffolding

The preserving manifest path does not start from scratch on the app side
either. The following stopped-audio-era pieces carry over as-is:

- `MetaSonic.App.ManifestReloadIngress` — the fresh-bracket close /
  resume / open-fresh policy is reload-primitive-agnostic. Both
  strategies need producer/listener ingress closed before the swap and
  reopened against the post-reload target.
- `MetaSonic.App.ManifestReloadSupervisor` — close-stack/open-stack
  rebuild sits above whichever primitive failed. A preserving attempt
  that escalates to terminal divergence routes to the same supervisor.
- `MetaSonic.Session.ManifestReload` plan validation, catalog matching,
  resource policy enforcement, and `manifestReloadCommand` projection to
  `CmdHotSwapPreservingOnly`.

The following did not carry over as direct reuse; they are now implemented as
separate preserving-specific siblings:

- `MetaSonic.App.ManifestReloadOrchestration` — the
  `HostStoppedAudioReloadOps` 9-slot record encodes dispose-first shape
  (quiesce / drain / stop-audio / reload-stopped / restart-audio /
  reopen). `HostPreservingReloadOps` has a different shape: prepare plan,
  quiesce ingress, drain, preserving reload, resume service, and reopen either
  old or fresh ingress without stopping audio or replacing the owner.
- `reloadManifestSessionStoppedAudio` is the inner primitive; the
  preserving sibling is `reloadManifestSessionPreservingHotSwap`.

The following are now landed:

- A preserving-only command mode (`CmdHotSwapPreservingOnly` /
  `HotSwapPreservingOnly`) that refuses runtime clear/rebuild fallback.
- `reloadManifestSessionPreservingHotSwap`, which projects a validated plan
  through the live preserving command path.
- `HostPreservingReloadOps` and real app wiring in
  `MetaSonic.App.ManifestReloadHost`.
- A strategy selector at the app layer that dispatches to preserving or
  stopped-audio and routes only retryable preserving rejection into explicit
  stopped-audio fallback. The selector does not fall back after preserving has
  changed the live owner.

## Strategy Boundary

There are three reload products:

1. **Stopped-audio manifest reload.** The host quiesces producers/listeners,
   drains accepted commands while audio is still live, stops audio, swaps
   the owner, restarts audio, and reopens ingress.

2. **Preserving live hot-swap manifest reload.** The host keeps audio
   running and submits a manifest-derived `CmdHotSwapPreservingOnly` through
   the preserving runtime path. The operation succeeds only if the graph is
   migration-eligible and the retired generation proves complete migration.

3. **Full host teardown/rebuild.** The host closes the whole stack and
   rebuilds from a manifest plan, usually with an audible gap and new
   producer/listener brackets.

The preserving path should not be described as "v2 stopped-audio reload".
It has different admission, failure, and recovery rules. The implemented shape
keeps separate named entry points for stopped-audio and preserving reload, then
adds a higher-level strategy selector over those entry points.

## What The Stopped-Audio Work Contributes

The stopped-audio path is still valuable for live hot-swap because it forced
several policy decisions that the preserving path also needs:

- manifest validation happens before the reload window;
- reload attempts are owned by a host-level command, not hidden inside the
  runtime adapter;
- producer/listener ingress is a first-class resource;
- queue admission and reload status are serialized with the owner;
- terminal failures are explicit and recover through a supervisor, not
  through ad hoc partial repair;
- diagnostic CLI and test harnesses can exercise reload policy without
  depending on a physical audio device.

The important lesson is architectural, not procedural: manifest reload needs
an app-owned control plane around the graph install primitive. For
stopped-audio, the primitive is owner replacement. For preserving hot-swap,
the primitive is `CmdHotSwapPreservingOnly` through the live preserving
adapter.

## What It Does Not Contribute

The stopped-audio helper does not solve these preserving-hot-swap questions:

- whether every template in the manifest-derived graph is migration-eligible;
- whether active voices can survive the manifest shape change;
- whether a removed template or renamed control should reject, drop voices,
  or require a stopped-audio fallback;
- whether producer-local state such as MIDI note ownership or OSC bindings
  can remain valid after the new manifest installs;
- whether stale queued commands against the old control surface should drain
  before, after, or never during preserving reload;
- how to surface post-publish failures when audio keeps running but the owner
  must diverge;
- how a user chooses preserving vs stopped-audio vs teardown when preserving
  is unsupported.

Those must be answered directly. Reusing stopped-audio terminology would hide
the hard parts.

## Landed Preserving Manifest Contract

The preserving manifest reload starts from a prevalidated
`ManifestReloadPlan`, just like the stopped-audio helper. The plan is then
projected to `CmdHotSwapPreservingOnly` and submitted through the current
owner while audio continues running.

The landed v1 operation has this shape:

1. Validate/import manifest outside the live reload attempt.
2. Build a `ManifestReloadPlan` against the current catalog.
3. Close/fence producer ingress by quiescing the app ingress manager.
4. Drain accepted service work and require a clean handoff.
5. Submit `CmdHotSwapPreservingOnly` through the fan-in/owner path.
6. Let the real adapter check preserving eligibility, publish the prepared
   swap, wait for audio-generation retirement, collect retired migration stats,
   and verify migration.
7. Commit the new `SessionState` only after verification succeeds.
8. Resume the fan-in service.
9. Reopen old ingress after retryable rejection, or open fresh ingress for the
   same live owner after success.

The crucial difference from stopped-audio: audio is not stopped, the owner is
not disposed, and the pure session state is not committed until the
post-publish migration proof succeeds.

## Admission Rules

The preserving path should be strict at first.

Landed v1 admission:

- accept only whole-owner manifest plans that project to
  `CmdHotSwapPreservingOnly`;
- require the fan-in queue to be cleanly drained after ingress is quiesced;
- submit through `CmdHotSwapPreservingOnly`, so unsupported preserving shapes
  reject instead of clearing/rebuilding;
- reject if the current owner is already diverged;
- reject if the plan would require session-level respawn or reset semantics;
- reject if the new graph includes unsupported stateful migration shapes;
- reject if current live voices cannot be mapped to the new graph without
  violating the existing preserving migration contract.

The last three bullets are not new eligibility rules. A manifest-driven
reload is preserving-eligible iff the new template graph satisfies the
same predicate `preservingHotSwapPlan` already enforces for command-level
`CmdHotSwap`: template-name identity, template-ID identity, migration
keys on stateful nodes, and slot identity for preserved voices. The
manifest-layer probe wraps that predicate against the validated plan; it
does not implement parallel rules.

The implementation keeps fallback explicit. `RequirePreserving` reports the
preserving result directly. `TryPreservingThenStoppedAudio` falls back only
from the plain retryable preserving rejection path; post-install failures such
as fresh-ingress failure or terminal divergence do not fall back because the
live owner may already have changed.

## Queue And Producer Ordering

Preserving reload cannot ignore queued commands. The queue may contain
commands built against the old control surface.

There are three possible policies:

1. Require an empty queue before preserving manifest reload.
2. Fence the queue: drain everything accepted before the reload, then submit
   reload, then reopen producer ingress.
3. Allow reload to sit in FIFO order with other commands.

For manifest reload, the safest v1 is either (1) or (2). Policy (3) is too
easy to misread because producer commands after the manifest reload may target
bindings that only exist in the old manifest.

The stopped-audio host already established a useful pattern: quiesce
producer/listener ingress, drain accepted work, then enter the reload window.
The preserving version can reuse that host discipline, but it should not stop
audio and should not call the stopped-audio owner-swap helper.

## Binding And Control Surface Rebuild

Running-graph hot-swap is not only DSP migration. The user-facing control
surface can change when the manifest changes.

The preserving path must define what happens to:

- OSC voice bindings;
- MIDI note ownership;
- UI control handles;
- Pattern producer references;
- named controls whose migration keys remain stable;
- named controls whose names or slots disappear;
- active voices whose template remains but whose controls changed;
- active voices whose template disappears.

The likely v1 rule should be conservative:

- preserving reload can keep active voices only when template identity,
  voice key, and required migration/control metadata still line up;
- removed or incompatible active voices make preserving reload unsupported;
- stale producer bindings are rebuilt only after successful commit;
- producer/listener brackets that cannot rebuild cleanly reject the reload or
  force a stopped-audio/teardown path.

That is stricter than what an interactive UI may eventually want, but it is
the right starting point for correctness.

## Failure Classification

The preserving path inherits the live hot-swap failure split:

- **Pre-publish rejection** is retryable. The old owner is still installed
  and live. The host can reopen ingress and continue.
- **Publish rejection** can be retryable if the adapter proves ownership did
  not transfer.
- **Post-publish timeout** is terminal owner divergence until a repair
  protocol exists.
- **Retired swap missing** is terminal owner divergence.
- **Incomplete migration stats** are terminal owner divergence.
- **Commit mismatch or adapter protocol bug** is terminal divergence.
- **Binding rebuild failure after a successful graph commit** is an app-level
  failure: the audio graph may be live, but producer/listener ingress must
  remain closed or the supervisor must rebuild.

This is stricter than stopped-audio failure handling because audio continues
running through the attempt. Once a prepared swap is published, the owner
cannot pretend the old graph is definitely still the active runtime truth.

## Suggested API Direction

A narrow session-layer function could look conceptually like this:

```haskell
reloadManifestSessionPreservingHotSwap
  :: SessionFanInHost
  -> ManifestReloadPlan
  -> IO (Either ManifestPreservingReloadIssue ManifestPreservingReloadReport)
```

It should not decode JSON or choose a catalog. It should take a validated
plan and operate on the current owner.

The issue type should distinguish at least:

- planning not accepted by this strategy;
- queue not empty or queue not fenced;
- no owner;
- owner already diverged;
- audio not running, if v1 requires live audio;
- preserving migration unsupported;
- runtime pre-publish rejection;
- runtime post-publish divergence;
- binding rebuild required/failed, if that responsibility lands at this
  layer.

The report should include:

- old/new graph identity or demo key;
- whether active voices migrated;
- retired generation/migration stats if available;
- whether producer/listener bindings must rebuild;
- the projected `CmdHotSwap` label.

If the app owns binding rebuild, the session report should explicitly say
"bindings must rebuild" rather than doing it implicitly.

## Host-Level Strategy Selector

The app now has a strategy selector with this policy shape:

```text
prefer preserving
  -> if eligible, run preserving live hot-swap
  -> if preserving rejects before changing the live owner, optionally fall
     back to stopped-audio
  -> if stopped-audio disallowed, reject with a clear reason
```

The landed selector is deliberately conservative. It falls back only from the
plain retryable preserving rejection shape (`HpariReloadRejected`), where the
old owner is still installed and old ingress has resumed. It does not fall
back from drain/quiesce failures, terminal preserving failures, or
fresh-ingress failure after a preserving install. New parallel fallback
vocabulary is not needed.

The selector sits above the individual implementations. It does not erase
their names or merge their failure types too early.

For example:

- preserving unsupported: "this manifest requires stopped-audio reload";
- preserving post-publish divergence: "audio-running hot-swap failed after
  publish; supervisor rebuild required";
- stopped-audio owner setup failure: "new owner construction failed; rebuild
  previous known-good stack or restart";
- teardown rebuild failure: "no live stack remains".

Those are different user-facing events.

## Implementation Slices

A safe path from current code to running-graph manifest reload:

1. **Document and sync current state.** Landed for the stopped-audio host
   path; this note has been updated again after the preserving host path and
   selector landed.

2. **Preserving-only command and runtime coverage.** Landed as
   `CmdHotSwapPreservingOnly`, `HotSwapPreservingOnly`, and tests that reject
   clear/rebuild fallback.

3. **Session helper.** Landed as
   `reloadManifestSessionPreservingHotSwap`, with enqueue/drain/snapshot
   reporting and tests for success and rejection.

4. **Host preserving orchestration.** Landed as `HostPreservingReloadOps`,
   fake-IO tests, real app wiring, and host tests for preserving success,
   retryable rejection, terminal drain, and fresh-ingress failure.

5. **Strategy selector.** Landed as `reloadManifestHostWithStrategy`, with
   explicit `RequirePreserving`, `TryPreservingThenStoppedAudio`, and
   `StoppedAudioOnly` modes. The selector reports which strategy ran and
   preserves both causes when explicit fallback fails.

6. **Concrete binding rebuild policy.** Still open. The app-level host wiring
   opens a fresh ingress generation for the same live owner, but concrete
   OSC/MIDI/UI producer/listener binding rebuild policy is not yet exposed as
   a product path.

7. **Manual live smoke.** Still open. Expose an explicit audio/device-backed
   smoke for the strategy selector only after concrete ingress policy is
   chosen. Keep it out of default test gates.

## Non-Goals For The First Preserving Manifest Slice

Do not include these in the first preserving manifest implementation:

- automatic migration of arbitrary stateful nodes;
- session-level respawn for unsupported preserving shapes;
- partial manifest reload;
- fuzzy matching of renamed templates or controls;
- producer-local state migration beyond explicit binding rebuild;
- silent fallback to stopped-audio reload;
- making manifest reload the default live demo path;
- changing the existing stopped-audio helper semantics.

## Review Checklist For Future Changes

Future preserving manifest reload patches should preserve these constraints:

- it must not call `stopAudio`;
- it must not call `reloadManifestSessionStoppedAudio`;
- it must project through `CmdHotSwapPreservingOnly` or an equivalent
  preserving-only command;
- it must preserve the existing publish/wait/collect/verify/commit ordering;
- it must reject unsupported migration shapes before publish;
- it must classify post-publish failures as terminal divergence;
- it must not reopen producer/listener ingress if bindings failed to rebuild;
- it must keep stopped-audio fallback explicit and visible to the caller;
- it must include deterministic tests that prove audio-running preserving
  ordering without relying on a local device.

## Bottom Line

The project is going in the right direction for hot-swap reload of running
graphs because it is building the reload control plane without weakening the
existing preserving hot-swap contract.

The live-preserving strategy is now a sibling strategy that consumes the same
manifest plan and projects it through the existing preserving hot-swap
machinery. The next work is to expose that landed strategy through concrete
app ingress and operator-facing commands without making silent fallback or
default live-reload claims.
