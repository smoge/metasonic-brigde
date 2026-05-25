## Manifest Reload Preflight Event Semantics

Date: 2026-05-25

Status: design note. Scopes the next open lane from the
[ManifestReloadEvent Partial Coverage](2026-05-19-a-manifest-reload-event-partial-coverage.md)
closeout: "compile-error events". The
[Stale Producer Command Semantics](2026-05-24-b-stale-producer-command-semantics.md)
note set the pattern: pin terminology, draw the state space, and
name a concrete operator consumer before adding constructors. This
note does the same for the preflight stage. It does **not** add
event constructors yet; it scopes what the first slice should add
and what the surrounding event timeline should look like.

## What gap are we closing?

`ManifestReloadEvent` currently covers the strategy phases once a
preserving or stopped-audio route has been chosen. The transitions
before route selection — catalog lookup, manifest target resolution,
plan validation, graph compile/plan diagnostics — are *not* a
separate event family. Today they surface in two structurally
different ways:

1. **Resolver-level failures (no event stream at all).** In
   [`ManifestLiveSession.runReloadWithSink`](../app/MetaSonic/App/ManifestLiveSession.hs)
   the `ReloadResolver` runs *before* the supervisor is invoked.
   `catalogPlanResolver` does the catalog lookup
   (`find demoKey == key`) and the `planManifestReloadForDemo` call;
   on failure it returns `Left reason :: Either String plan`. The
   live shell prints `reload rejected: <reason>` and writes
   `LsoPlanRejected reason` to `lastOutcomeRef`. The supervisor is
   never invoked, the `reloadEventsRef` stays empty, the
   `reload events:` block never renders. From a `ManifestReloadEvent`
   consumer's perspective, the failure is silent.

2. **Orchestrator-level plan-preparation failures (in-phase
   rejection event).** Once the supervisor *has* chosen a route and
   `hproPreparePlan` / `hsaroPreparePlan` runs, a failure surfaces as
   `MrePreservingReloadRejected (HpariPlanRejected issue)` /
   `MreStoppedAudioReloadRejected (HsariPlanRejected issue)`. The
   event timeline has already emitted `MrePreservingReloadStarted` /
   `MreStoppedAudioReloadStarted` by then, so the rejection looks
   like an in-phase failure. There is no separate
   "validation started" / "validation rejected" event preceding the
   phase-started event.

Both are real preflight failures — invalid demo key, missing
catalog entry, manifest target that the host cannot install, graph
plan diagnostics — but they neither share a vocabulary nor occupy a
consistent place in the event timeline. An operator-visible
`reload events:` block today cannot answer "did validation reject
this before route selection, or did the preserving phase reject the
plan after entry?" without reading source.

## Who is the first consumer?

[`runManifestLiveSession`](../app/MetaSonic/App/ManifestLiveSession.hs)
is the right first consumer for the same reasons it was the right
first consumer for the stale-command lane: it is the real operator
surface, it already drives both the resolver-level and supervisor
paths, and it already has the `reload events:` block that any new
preflight event family would compose into.

The two other candidates (`--manifest-host-reload-smoke`,
`--manifest-live-reload-demo`) are reasonable secondary consumers
but should not lead. `--manifest-host-reload-smoke` is a fake-audio
smoke that does not exercise the resolver-level path at all; its
preflight is whatever the CLI argument parser does. The
live-reload-demo is closer but is a single-step demo, not a
multi-reload operator surface, so the event-ordering story it can
prove is narrower.

Concretely the first consumer slice should print a
`preflight events:` block in `runReloadWithSink` *before* the
existing `reload events:` block, in the same shape as the
stale-command lane's `retired bindings:` block: a small ordered
list of bullets with a single leading constructor tag and any
inner issue tag. The block renders even on resolver-level failures
(where `reload events:` would be empty today) and on success (where
it documents that validation passed before the strategy ran).

## What should the event shape be?

Do not jump straight to constructors. First map the stages so the
event family lines up with real transitions, then ask which
transitions need a constructor at all. The reload pipeline today
goes:

```text
operator requests demo KEY
  ↓
resolver: catalog lookup (find demoKey == key)
  ↓
resolver: planManifestReloadForDemo (graph compile / plan diagnostics)
  ↓
supervisor: choose strategy route (preserving / stopped-audio / try-preserving)
  ↓
orchestrator: hproPreparePlan / hsaroPreparePlan (per-route plan validation)
  ↓
enter preserving or stopped-audio phase
```

The missing event surface sits across the first two arrows
(resolver layer) and arguably the fourth arrow (orchestrator-level
preflight). Five candidate stages to consider, in order:

1. **Validation started.** A bracketing "preflight begins" event,
   analogous to `MreStrategyStarted`. Carries the requested key /
   manifest target. Useful for timeline alignment; cheap to add.
2. **Catalog lookup rejected.** Demo key not in the loaded catalog.
   Today this is a `String` "no demo named …" from
   `catalogPlanResolver`. A structured event would carry the
   requested key.
3. **Manifest target invalid.** The target named by the catalog
   entry cannot be loaded / cannot be addressed. Distinct from
   "catalog miss" because the catalog *did* resolve.
4. **Plan compile/diagnostic rejected.** `planManifestReloadForDemo`
   returned `Left issue`. Today this is rendered by
   `renderManifestReloadCliIssue` into a `String`. A structured event
   would carry the issue payload, the same way
   `HpariPlanRejected !issue` does inside the orchestrator.
5. **Validation succeeded.** Bracketing "preflight passed" event,
   analogous to `MreStrategySucceeded`. Lets the operator see that
   validation cleared before the strategy lifecycle begins.

The relationship to the existing orchestrator-level
`HpariPlanRejected` / `HsariPlanRejected` matters: those are
*per-route* preflight rejections that the orchestrator already
emits as in-phase `MrePreservingReloadRejected` /
`MreStoppedAudioReloadRejected`. The cleanest split is:

* **Resolver-stage preflight** (before route selection) gets the
  new event family. This is the gap. Today it is a `String` in the
  live shell with no event at all.
* **Orchestrator-stage preflight** (inside a route, before phase
  body) keeps the existing in-phase rejection event but the live
  shell's render should make clear it is preflight-within-phase,
  not in-phase failure.

A v1 surface might be as small as three constructors covering the
resolver stage:

```text
MrePreflightStarted    -- bracket
MrePreflightRejected   -- catalog miss OR plan compile/diagnostic failure
MrePreflightSucceeded  -- bracket
```

with the rejection payload structured enough to distinguish
catalog-miss from plan-rejected. Whether to split rejection into
two constructors (`MrePreflightCatalogMissed` /
`MrePreflightPlanRejected`) or to fold both under one
`MrePreflightRejected` with a sum-typed reason is a v1 question
the first slice should answer, not this note. The shape that won
the stale-command lane was a single rejection constructor carrying
a richer projection rather than a constructor per reason; that is
a precedent worth following.

## What is explicitly out of scope?

* **Allocation / resource-recovery events.** Still the other open
  lane from the 2026-05-19 closeout. Graph-allocation outcomes,
  polyphony pool exhaustion, audio ready / not-ready transitions
  across reload, and operator-visible recovery progress are
  separately consumer-gated.
* **Stale producer commands.** Closed by the 2026-05-24 note and
  evidence transcript. Preflight events run before any producer
  command is admitted against the new graph; the two lanes do not
  intersect.
* **Long-running supervisor repair.** Cross-run escalation and
  bounded-retry observability remain outside per-run event scope.
* **Restructuring the orchestrator-level `HpariPlanRejected` /
  `HsariPlanRejected` payloads.** Those already work and have
  consumer tests; the new preflight family layers *on top of*, not
  *in place of*, the existing in-phase rejection events.
* **GUI surface.** The first consumer is the live-session stdin
  sink. CLI smoke renderers and other higher-level orchestrators
  can opt in later.
* **ALSA stderr noise, command-history persistence, physical VMPK
  confirmation.** Unrelated polish lanes. Do not bundle.

## First implementation slice

Following the stale-command precedent (slice 1 = type plumbing,
slice 2 = pure renderer, slice 3 = attribution semantics, slice
4 = runtime hookup), the first slice for this lane should be the
smallest end-to-end visible thing:

**Emit and render preflight rejection events for invalid
demo/catalog/manifest requests, with an ordered test proving the
preflight rejection event appears before any preserving /
stopped-audio phase event in the resulting timeline.**

Concretely:

1. Add a minimum preflight event surface (three constructors
   suggested above is the conservative starting point).
2. Wire `catalogPlanResolver` failures through to that event family
   before the supervisor is invoked, so the timeline carries a
   rejection event even on the resolver-level path that is silent
   today.
3. Render a `preflight events:` block in `runReloadWithSink` ahead
   of the existing `reload events:` block.
4. Add an ordered test (mirroring the
   `assertContainsInOrder` pattern in `AppManifestReloadCli`) that
   pins: on an unknown demo key, the operator output emits
   `preflight events:` containing the rejection bullet and the
   `reload events:` block has no strategy lifecycle bullets (the
   slice should choose explicitly whether the header is suppressed
   entirely on resolver-stage rejection or rendered with the
   existing `(none)` row from `renderLiveReloadEvents []`; the
   current `runReloadWithSink` short-circuits before the header on
   a resolver `Left`, so suppression is the lower-friction default).
5. Add a second ordered test for the success path: on a known demo
   key, `preflight events:` contains the started + succeeded
   bracketing bullets *before* `reload events:` shows the strategy
   started.

Then a manual smoke against `--manifest-live-session` driving an
unknown demo key, captured in this note as the
[Stale Producer Command Semantics](2026-05-24-b-stale-producer-command-semantics.md)
note captured its 2026-05-25 transcript.

The slice does **not** need to refactor the orchestrator-level
`HpariPlanRejected` / `HsariPlanRejected` plumbing. Those continue
to fire in-phase rejection events as they do today. A later slice
can decide whether to also bracket orchestrator-level preflight
under the new event family or to leave it as in-phase rejection.

## How this leaves the ROADMAP

The "Failure/event semantics across compile and allocation/resource
recovery" lane, after `036adb4` updated the wording, lists
compile-error surfacing and allocation/resource recovery streaming
as the two remaining surfaces. This note pins the compile-error
sub-lane to a concrete shape: a new resolver-stage preflight event
family, layered on top of the existing orchestrator-stage in-phase
rejection events, with the `--manifest-live-session` operator
surface as the first consumer and an ordered test proving the
preflight event precedes any strategy lifecycle event.
Allocation/resource-recovery streaming remains separately
consumer-gated.
