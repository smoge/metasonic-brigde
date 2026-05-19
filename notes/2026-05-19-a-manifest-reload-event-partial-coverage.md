## ManifestReloadEvent Partial Coverage

Date: 2026-05-19

Status: doc-sync note. Records what the `ManifestReloadEvent` arc
(commits `8b644dc`, `b294c7d`, `c56cb64`) actually covers, so the
former ROADMAP entry for "Failure/event semantics across compile,
allocation, install, and stale producer commands" can stop reading
as fully gated. This note does not redefine the event contract; the
per-event semantics are documented in the module header of
[ManifestReloadEvent](../app/MetaSonic/App/ManifestReloadEvent.hs)
and the orchestrator wiring contract is in
[Host Stopped-Audio Manifest Reload Orchestration](2026-05-14-j-host-stopped-audio-manifest-reload-orchestration.md)
and
[Manifest Reload Host Supervisor And Recovery Policy](2026-05-14-k-host-reload-supervisor.md).

## What landed

`ManifestReloadEvent issue` in
`MetaSonic.App.ManifestReloadEvent` is the per-transition timeline
that runs alongside the existing terminal `Either` returned by the
host strategy. Fourteen constructors, grouped:

- **Strategy lifecycle.** `MreStrategyStarted`,
  `MreStrategySucceeded`, `MreStrategyFailed` — bracket every run
  and carry the resolved `ManifestReloadHostStrategy` plus the
  existing structured `ManifestReloadHostStrategyRan` /
  `ManifestReloadHostStrategyIssue` payloads.
- **Preserving reload phase.** `MrePreservingReloadStarted`,
  `MrePreservingReloadCommitted`,
  `MrePreservingReloadRejected (HostPreservingReloadIssue issue)`
  — fires for `RequirePreserving` and the first half of
  `TryPreservingThenStoppedAudio`.
- **Stopped-audio reload phase.** `MreStoppedAudioReloadStarted`,
  `MreStoppedAudioReloadCommitted`,
  `MreStoppedAudioReloadRejected (HostStoppedAudioReloadIssue issue)`
  — fires for `StoppedAudioOnly` and the fallback half of
  `TryPreservingThenStoppedAudio`.
- **Resume-old-ingress recovery.** `MreResumeOldIngressStarted`,
  `MreResumeOldIngressSucceeded`, `MreResumeOldIngressFailed issue`
  — surface the retryable resume sub-step inside either phase.
- **Fallback admission.** `MreFallbackAdmitted` /
  `MreFallbackDeclined`, each carrying the triggering
  `HostPreservingReloadIssue`.

Wiring lives in
`MetaSonic.App.ManifestReloadOrchestration`
(`orchestrateHostStoppedAudioReloadWithEvents`,
`orchestrateHostPreservingReloadWithEvents`) and
`MetaSonic.App.ManifestReloadHost`
(`reloadManifestStoppedAudioHostWithEvents`,
`reloadManifestPreservingHostWithEvents`,
`reloadManifestHostWithStrategyWithEvents`,
`runReloadHostStrategyWithEvents`). The legacy entrypoints delegate
to the `*WithEvents` variants with `noManifestReloadEvents`, so
library/host callers that have not opted in stay silent and the
`Either` contract is unchanged.

The first concrete operator-visible consumer is the
`--manifest-host-reload-smoke STRATEGY MANIFEST.json DEMO` CLI in
[ManifestReloadCli](../app/MetaSonic/App/ManifestReloadCli.hs). The
smoke captures the per-run event stream into
`mshsReloadEvents` and renders a compact `reload events:` block
beside the existing `fake audio events:` block, with one bullet per
transition and the leading constructor tag of any payload (so the
line stays single-row even when the inner failure carries nested
issues). Tests in
[AppManifestReloadCli](../test/MetaSonic/Spec/AppManifestReloadCli.hs)
assert the timeline order via `assertContainsInOrder` for the
preserving-failure, stopped-audio-only, and try-preserving
fallback paths, so the seam is regression-protected end-to-end.

## What is still open

The original ROADMAP bullet covered four surfaces: compile,
allocation, install, and stale producer commands. The install /
reload-strategy timeline is now covered; the other surfaces are not.

- **Compile-error events.** Catalog / manifest validation failures
  (planner stage) are carried by the existing phase-rejection
  events as `HpariPlanRejected` / `HsariPlanRejected` payloads when
  the host has already chosen a preserving or stopped-audio phase.
  There is still no separate preflight event family for "validation
  started", "validation rejected", or compile/catalog diagnostics
  before a reload phase begins.
- **Allocation / resource recovery events.** The
  `2026-05-15-d` closeout explicitly named this as a non-goal for
  v1, gated on a concrete consumer: graph-allocation outcomes,
  polyphony pool exhaustion, audio ready / not-ready transitions
  across reload, and operator-visible recovery progress are still
  not exposed as an event stream. `ManifestReloadEvent` does not
  bridge this gap — it covers the strategy timeline, not the
  underlying resource lifecycle.
- **Stale producer commands.** Commands that survive a swap with
  no remapping target (control writes to bindings that vanished,
  voice keys whose templates were retired, etc.) currently
  surface through producer-local rejection paths and the existing
  `submitManifest*` consumer issue types. There is no
  reload-scoped event class for "command dropped because the
  binding was retired by this reload".
- **Long-running observability beyond a single reload.** The
  ADT is per-run; the host supervisor's bounded-retry / escalation
  contract in
  [Manifest Reload Host Supervisor And Recovery Policy](2026-05-14-k-host-reload-supervisor.md)
  is not yet wired to emit cross-run events.

These remain consumer-gated. The shape should be picked when a real
operator UI or higher-level orchestrator asks for it; speculatively
designing the event surface ahead of that consumer was rejected in
the v1 closeout for the same reason it remains rejected now.

## How to read the ROADMAP after this note

The line "Failure/event semantics across compile, allocation,
install, and stale producer commands" should now read as: install /
reload-strategy timeline landed via `ManifestReloadEvent`; compile,
allocation, and stale-command semantics still open, still
consumer-gated.
