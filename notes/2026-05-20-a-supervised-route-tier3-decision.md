# Supervised-route tier-3 (hardware-backed CI) decision

Status: decided 2026-05-20. Closes the open question stated in
the "Evidence policy" subsection of
[2026-05-19-b-manifest-host-reload-smoke-runbook.md](2026-05-19-b-manifest-host-reload-smoke-runbook.md):

> "do we require hardware-backed CI for the supervised path
> before moving more routes onto it, or is tier 2 enough?"

## Decision

Tier 2 (the opt-in `just manifest-supervised-live-smoke`
operator command, with all 12 marker checks passing) is
sufficient evidence to open the preserving and
try-preserving supervisor-migration slices.

Tier 3 (hardware-backed CI) is **deferred**, not rejected.
The reopen triggers are listed below.

### Update 2026-05-20: try-preserving migration landed against this bar

`TryPreservingThenStoppedAudio` migrated onto the supervised
stack via `realTryPreservingHostStackOps` (composes preserving
+ stopped-audio fallback under the existing
`preservingAllowsStoppedAudioFallback` gate). The evidence bar
was met by:

* `just check-offline` green at suite 1261 (deterministic
  route + classifier + composition tests including the pure
  `decideTryPreservingNext` / `composeFallbackOutcome` /
  `fallbackEventForDecision` tables);
* two marker-clean runs of the new
  `just manifest-supervised-try-preserving-live-smoke` wrapper
  on host RME ADI-2 Pro / PipeWire (run 1: 12/12; run 2: 12/12);
* one no-regression confirmation run of
  `just manifest-supervised-live-smoke` on the same host
  (12/12), covering the shared-helper rename and the route
  rendering change.

`RequirePreserving` remains on the direct path at the time of
the try-preserving migration; its migration is its own slice
and would land against the same bar. (Superseded — see the
next subsection.)

### Update 2026-05-20: require-preserving migration landed against this bar

`RequirePreserving` migrated onto the supervised stack via
`realPreservingHostStackOps` (preserving-only — no stopped-audio
fallback composition). Because there is no fallback gate, every
`InWindowReloadRejectedLiveFallback`-classified preserving
outcome surfaces as `SupervisedReloadRequestRejected` and the
stack stays serving the previous plan; terminal preserving
variants still drive the supervisor's close+rebuild path. The
evidence bar was met by:

* `just check-offline` green at suite 1262 (deterministic
  route + classifier coverage including the updated
  `selectLiveReloadRoute RequirePreserving` test and the new
  `renderLiveReloadRoute SfRequirePreserving` rendering test
  in `MetaSonic.Spec.AppManifestLiveReloadDemoRender`);
* two marker-clean runs of the new
  `just manifest-supervised-require-preserving-live-smoke`
  wrapper on host RME ADI-2 Pro / PipeWire (run 1: 13/13;
  run 2: 13/13). The wrapper adds a load-bearing NEGATIVE
  marker that no "stopped-audio phase" lines appear in the
  transcript, proving the require-preserving supervised path
  never composes with fallback;
* one no-regression confirmation run each of
  `just manifest-supervised-live-smoke` (12/12) and
  `just manifest-supervised-try-preserving-live-smoke`
  (12/12) on the same host, covering the new
  `SfRequirePreserving` arm of the dispatcher.

The supervisor migration arc is now complete: all three
`--manifest-live-reload-demo` strategies (`StoppedAudioOnly`,
`TryPreservingThenStoppedAudio`, `RequirePreserving`) dispatch
through the supervised lifecycle. Nothing remains on the
direct `reloadManifestHostWithStrategy` path for the audible
demo command.

## What this means in practice

For each new route migrated onto the supervisor:

1. **Deterministic coverage** — route-selection and outcome
   behavior must be covered by fake-IO tests in the existing
   default suite. The migration PR must include those tests
   and they must run under `just check-offline`.

2. **Marker-clean live smoke** — if the migration touches
   real host behavior (audio start/stop, ingress open/close,
   real plan install), the PR description must include a
   fresh transcript + probe-log pair from `just
   manifest-supervised-live-smoke` (or a migration-specific
   equivalent if the new route is not exercisable by the
   existing wrapper) showing every marker `[ok]`. Link or
   attach the artifacts; "ran it locally" without artifacts
   does not satisfy the bar.

3. **Minimum two successful runs** — a single pass is not
   enough. The wrapper drives one reload event, so a
   transient device acquisition succeeding once is not
   strong evidence about the next operator's cold start.
   Two runs on the same host are the minimum. Two runs on
   different hosts or different audio backends are stronger
   and preferred when a second machine is available.

## Why tier 2 is enough for now

- The default suite already pins route selection,
  state-machine outcomes, partial-cleanup paths, and OSC
  ingress-target projection. The deterministic lane catches
  regressions in everything the runtime can observe without
  a device.
- Tier 2 covers what the deterministic lane cannot —
  real PortAudio start/stop, real UDP bind/release, real
  plan install, real OSC accept — and it covers them with
  explicit marker checks mapped to acceptance items, not
  just process exit code 0.
- The supervisor's responsibility is to **sequence** the
  open / install / close / release calls correctly; the
  underlying calls themselves are the same calls every
  other audio path already makes and that operators already
  exercise daily through the non-reload demos. Tier 2
  validates the sequencing on real hardware end-to-end.
- The cost of opening tier 3 right now is large and
  off-topic. The §219 arc's bottleneck is supervisor route
  coverage, not test infrastructure. A device-backed CI
  lane (hardware ownership, hot-plug behavior, cleanup,
  timeouts, failure diagnosis, false-fail triage) is its
  own slice and is not on the critical path for preserving
  migration.

## When tier 3 reopens

This decision is contingent. The preserving migration
should not relitigate the policy on its review; instead,
land a follow-up note that reverses or tightens this one
if any of the following land:

- **Coverage hole observed.** A reproducible failure
  surfaces in tier 2 that the deterministic suite missed
  and that cannot be retro-pinned with a fake-IO test.
  Strongest trigger — proves the deterministic lane has a
  gap that only an automated device-backed lane can catch.
- **Route count outgrows the operator.** The supervised
  footprint grows past ~three routes (today's three:
  stopped-audio, try-preserving, require-preserving). A
  fourth supervised route added to the
  `--manifest-live-reload-demo` dispatcher would push the
  per-PR operator burden to four marker-clean smokes in
  sequence on shared-machinery changes, which is the
  threshold where "operators run N smokes per PR" becomes
  infeasible and CI must take it over.
- **Timing-sensitive marker failures appear.** A supervised
  route's marker checks start failing intermittently in a
  way that traces to device timing rather than logic —
  e.g., a cold-vs-warm-start flake, a re-run that passes
  with no code change, or marker order varying across runs.
  This failure mode is most plausible on supervised paths
  that install a plan with audio running (require-preserving /
  try-preserving), but the trigger here is the **observed
  flake**, not the path category — all three audible
  supervised routes (stopped-audio, try-preserving,
  require-preserving) are explicitly unlocked by this
  decision and do not by themselves fire this trigger. If a
  timing-sensitive failure does appear on any supervised
  route, "one operator ran it once" loses statistical power
  and the regression class needs automated re-runs across
  cold / warm starts.
- **Operator-reported regression that tier 2 caught but
  the PR author skipped.** Process failure. The fix is to
  remove the opt-in and make tier 2 mandatory in CI for
  the affected route, not to add ceremony at the PR level.

## What this note replaces

- The runbook's "Evidence policy" subsection no longer
  needs the "(still undecided)" wording on tier 3 or the
  "should land before the preserving migration slice
  opens, not during its review" qualifier on the migration
  gate. Both are now answered here.
- [ROADMAP.md](../ROADMAP.md) §3824's "tier 3
  (hardware-backed CI) is undecided" and "gated on ... a
  written tier-3 decision" phrasing is also satisfied by
  this note.

## What this note does *not* unlock

- Resource/allocation recovery events. Still
  consumer-gated; nothing here changes that.
- Skipping deterministic tests for the migration. Still
  required.
- Hardware-CI as an off-slate item. Deferred is not
  rejected; if one of the reopen triggers fires, designing
  the lane becomes its own slice with its own design (the
  hot-plug / ownership / timeout questions still need
  answers, this note just doesn't pay them today).
