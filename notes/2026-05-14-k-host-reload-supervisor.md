# Manifest Reload Host Supervisor And Recovery Policy

Date: 2026-05-14

Status: design + supervisor primitive + real-host adapter +
real stopped-audio host wiring + preserving and try-preserving
supervised host-stacks + all three route flips onto the
supervisor (`StoppedAudioOnly`, `TryPreservingThenStoppedAudio`,
`RequirePreserving`) all landed. Nothing remains on the direct
`reloadManifestHostWithStrategy` path for the audible
`--manifest-live-reload-demo` command. The contract body below
remains the design record the implementation slices were
reviewed against; the "Implemented status" section immediately
below this header is the authoritative summary of what shipped.

This is the lifecycle-supervisor companion to
`2026-05-14-j-host-stopped-audio-manifest-reload-orchestration.md`. The
j-note pins the in-window orchestration sequence; this note pins the outer
recovery policy when an in-window operation fails terminally.

## Implemented status

Landed across the final-effective commits below in the §219
ordering, all under deterministic fake-IO test coverage (no
PortAudio, no real listeners, no live audio host). The table
is the final-effective shape — one row per landed change — so a
superseded intermediate commit (`2c89a0b`, the original
A→B→C regression test that was over-claiming coverage) does not
appear here; the corrected form lives in row 3 (`7b8a2c6`).

Rows 1–7 below describe the supervisor / adapter / host-stack
contract under the original @Either e ()@ in-window shape that
shipped through the StoppedAudioOnly hardware confirmation. Row 8
(`487fd5c`) generalizes that shape into a classified
'InWindowReloadOutcome' for the preserving / try-preserving
migration: the supervisor now recognizes a third
"request-rejected, stack still serving fallback" outcome distinct
from a terminal failure. References to @Left e@ inside rows 1–2
are historical and remain accurate as commit records — they are
not the current contract any new producer should implement
against.

Row 12 (`ad2c7e2`) renames the substrate types in
`MetaSonic.App.ManifestReloadHostStack` from route-prefixed
('StoppedAudio*') to neutral ('Reload*') names. References to
`StoppedAudioHostStack` / `StoppedAudioHostStackOpenIssue` /
`RealStoppedAudioHostStackInputs` / `Sahsoi*` constructors /
`rsahsi*` fields inside rows 7–11 are historical and accurate
as commit records — they are not the current types. The
current substrate names are `ReloadHostStack` /
`ReloadHostStackOpenIssue` / `RealReloadHostStackInputs` /
`Rhsoi*` / `rrhsi*`. Strategy-specific names
(`StoppedAudioHostStackOps`, `StoppedAudioHostStackIssue`,
`Sahsi*` constructors, and the `Preserving*` /
`TryPreserving*` counterparts) are unchanged.

| # | Commit | Slice content |
|---|--------|---------------|
| 1 | `f34522e` (earlier, pre-session) | §219 slice 1.5 baseline: `MetaSonic.App.ManifestReloadSupervisor` primitive — `SupervisorOps plan e` with `sopsInWindowReload` / `sopsCloseStack` / `sopsOpenStack`, `reloadSupervised` capturing `fallback` as a per-call local. Outcome variants `SupervisedReloadCommitted | SupervisedReloadRejectedRecovered e | SupervisedReloadEscalated e e`. 9 fake-IO test cases in `MetaSonic.Spec.AppManifestReloadSupervisor`. |
| 2 | `ef6bd80` | §238 #9 cleanup invariant: `reloadSupervised` wraps `sopsInWindowReload` in `onException sopsCloseStack` so a throw from the in-window op closes the still-live previous stack before propagating. Two paired tests pin the change (throw during in-window closes the live stack; normal `Left e` recovery does not double-fire the wrapper). |
| 3 | `7b8a2c6` | §238 #2 regression: A→B→C→D! "no remembered history" test. Two committed reloads then a failed third reload; the rebuild target must be the plan running at this reload's entry (C), not earlier history (B or A). Belt-and-suspenders against a future "previousGood" history-accumulation refactor. Supersedes an intermediate `2c89a0b` that named the same case but only exercised the simpler "one-step-back" property. |
| 4 | `8892eb4` | §219 next-layer-outward: new module `MetaSonic.App.ManifestReloadSupervisorAdapter` with `HostStackFactory plan stack e` (3 slots: open / close / in-window) and `withHostStackSupervisorAdapter`, an `IORef`-backed bracket that exposes a `SupervisorOps` the supervisor can drive. 6 fake-IO test cases covering close-before-open, fallback rebuild, escalation, and active-stack-ref bookkeeping. |
| 5 | `5616d9a` | Async-exception windows in the adapter halves: `openOps` now `mask $ \restore -> ...` so the "Right newStack → writeIORef" publication is uninterruptible; `closeActiveStack` now `mask_` so the "atomicModifyIORef → hsfCloseStack" handoff is atomic. Three new tests: two `getMaskingState` observations + one `forkIO`/`throwTo` injection test asserting no minted stack id is left without a matching close on the recovery path. |
| 6 | `d990c33` | Outer setup-window mask: `withHostStackSupervisorAdapter factory initialStack k = mask $ \restore -> do ... ; restore (k supOps) `finally` closeOps`. Closes the §103 window between `newIORef (Just initialStack)` and the `finally` install where an async exception would have leaked the already-open initialStack. New test pins that `restore` correctly hands the caller's masking state to the continuation. |
| 7 | `514812c` | §219 slice 4 (partial): production `HostStackFactory` shape for the stopped-audio path. New module `MetaSonic.App.ManifestReloadHostStack`: `StoppedAudioHostStack` newtype around `ManifestReloadHostConfig` (no stack-level plan field — caller owns currentPlan externally), `StoppedAudioHostStackOps` with injectable open / close / in-window-reload slots, `StoppedAudioHostStackOpenIssue` (service / audio / ingress causes), unified `StoppedAudioHostStackIssue` sum, `realStoppedAudioInWindowReload` driving `orchestrateHostStoppedAudioReloadWithEvents` with `hsaroPreparePlan = const (pure (Right plan))` so the supervisor's supplied plan is the source of truth at the seam, `mkStoppedAudioHostStackFactory` smart constructor. 8 fake-IO test cases (the 7 named in §219 slice 4 plus an A→B→C→D! factory-layer regression). Supersedes intermediate `e0e4fb7` whose `sahsInstalledPlan` field would have silently drifted across successful in-window reloads, and whose `realStoppedAudioInWindowReload` re-derived plans via `preparePlan` rather than installing the supervisor's plan directly. |
| 8 | `487fd5c` | §219 slice 5 step 1 (preserving migration prep): classify the in-window outcome. New type `InWindowReloadOutcome e = InWindowReloadCommitted \| InWindowReloadRejectedLiveFallback e \| InWindowReloadTerminal e` replaces the `Either e ()` return on `SupervisorOps.sopsInWindowReload`, `HostStackFactory.hsfInWindowReload`, and `StoppedAudioHostStackOps.sahsoInWindowReload`. `SupervisedReloadOutcome` gains `SupervisedReloadRequestRejected e` — the new short-circuit branch where the supervisor returns without invoking `sopsCloseStack` / `sopsOpenStack` because the stack is still serving the fallback plan. `reloadSupervised` body becomes a three-way case; the `onException sopsCloseStack` wrap is unchanged (synchronous exceptions are still terminal, distinct from `InWindowReloadTerminal` which drives the close-then-rebuild path under the supervisor's own sequencing). A `Functor` instance + `inWindowOutcomeFromEither` shim lifts the stopped-audio orchestrator's `Either` result into the new shape — by construction stopped-audio cannot produce `RejectedLiveFallback` (audio stops before reinstall, so there is no "old owner still installed" branch); preserving / try-preserving producers must classify their failures manually. Two new pinning tests (supervisor + adapter "in-window rejected-live-fallback returns RequestRejected and skips close/open"). Suite goes to 1218 cases. No live behavior change for the stopped-audio route; the classified shape opens the door for the row 9 preserving-aware producer. |
| 9 | `a441009` (extended by `be8eb8d` + `4e58322`) | §219 slice 5 step 2: preserving-aware supervised host-stack. New module `MetaSonic.App.ManifestReloadPreservingHostStack` with `PreservingHostStackOps`, `PreservingHostStackIssue`, `realPreservingHostStackOps`, `realPreservingInWindowReload`, `mkPreservingHostStackFactory`, and `classifyPreservingOutcome`. The classifier maps the 10 `HostPreservingReloadIssue` constructors: the four resume-ok variants (PlanRejected / QuiesceRejected / DrainRejected / ReloadRejected) → `RejectedLiveFallback`; the six terminal / resume-failed / ingress-restart-failed variants → `Terminal`. Open and close are reused from `MetaSonic.App.ManifestReloadHostStack` via newly-exported `realOpen` / `realClose`. Tests: 10-row policy table over every constructor; factory-composition table across all four supervisor branches; A→B→C→D! regression; direct-integration test for `realPreservingInWindowReload` that observes the orchestrator's event stream and asserts both that the planning-rejection failure mode is absent (override-removed regression) AND that the downstream `ManifestPreservingHotSwapReport` carries the requested plan's demoKey + swapLabel (fallback-swap regression). The `be8eb8d` follow-up added the direct-integration test + shared the stopped-audio fixtures; the `4e58322` follow-up strengthened the test to catch fallback-swap by extracting the report identity from the rejection event. Suite: 1216 → 1235. No live behavior change; selectLiveReloadRoute unchanged. |
| 10 | `8833898` (extended by `2bb36d9`) | §219 slice 5 step 3: try-preserving supervised host-stack. New module `MetaSonic.App.ManifestReloadTryPreservingHostStack` composing `realPreservingInWindowReload` with `realStoppedAudioInWindowReload` under the existing `preservingAllowsStoppedAudioFallback` gate. Three pure cores: `decideTryPreservingNext` (which next step from a preserving outcome), `composeFallbackOutcome` (stopped-audio result + preserving issue → final outcome), and `fallbackEventForDecision` (which `MreFallback{Admitted,Declined}` event to emit per decision). The IO function `realTryPreservingInWindowReload` is a thin shell over the pure cores plus `mapM_ onEvent` for the fallback event. Three-variant `TryPreservingInWindowIssue` (`TpiwiPreservingFallbackDeclined`, `TpiwiPreservingTerminal`, `TpiwiFallbackStoppedAudioFailed`). The `2bb36d9` follow-up fixed an asymmetry where `TpnTerminal` emitted no event — the direct strategy emits `MreFallbackDeclined` for both live-stack-not-eligible AND terminal preserving outcomes; the supervised path now matches. Tests: 11-row `decideTryPreservingNext` table, 2-row `composeFallbackOutcome` table, 4-row `fallbackEventForDecision` table, 6-branch factory composition + A→D! regression. Suite: 1235 → 1258. No live behavior change; selectLiveReloadRoute unchanged. |
| 11 | `ed3409f` (+ tier-2 evidence 2026-05-20) | §219 slice 5 step 4: route `--manifest-live-reload-demo try-preserving` through the supervised stack. `LiveReloadRoute` gains a `SupervisedFactoryFlavor` parameter (`SfStoppedAudio` / `SfTryPreserving`); `selectLiveReloadRoute TryPreservingThenStoppedAudio` flips to `LiveReloadSupervised SfTryPreserving`. `runSupervisedLiveReload` renamed `runSupervisedStoppedAudioLiveReload` so the name no longer lies; new `runSupervisedTryPreservingLiveReload` sibling wires `realTryPreservingHostStackOps` + `mkTryPreservingHostStackFactory` and has a real operator branch for `SupervisedReloadRequestRejected` (preserving rejected without admitting fallback; stack stays serving fallback plan). `renderLiveReloadRoute` exported + pinned by three rendering tests so the tier-2 wrapper marker-1 grep cannot silently break. `RequirePreserving` stays direct. New tier-2 wrapper `tools/manifest_supervised_try_preserving_live_smoke.sh` + `just manifest-supervised-try-preserving-live-smoke` recipe with distinct artifact names + default port 17002; marker 4b/4c swap `stopped-audio phase started/committed` for `preserving phase started/committed`. The stopped-audio wrapper's marker 1 also updated to match the new `(stopped-audio;` flavor tag in the route rendering. Tier-2 evidence captured 2026-05-20 on host RME ADI-2 Pro / PipeWire: two marker-clean runs of the try-preserving wrapper + one no-regression run of the stopped-audio wrapper, all 12/12. Suite: 1258 → 1261. |
| 12 | `ad2c7e2` | Substrate naming neutralization. The substrate stack value, its open-issue ADT, and the production-input record in `MetaSonic.App.ManifestReloadHostStack` were route-prefixed (`StoppedAudioHostStack` / `StoppedAudioHostStackOpenIssue` / `RealStoppedAudioHostStackInputs`) because they landed in the stopped-audio slice first; after rows 9–10 the preserving and try-preserving modules carried `type Preserving... = StoppedAudio...` / `type TryPreserving... = StoppedAudio...` aliases purely to document the role. Renamed substrate: `StoppedAudioHostStack` → `ReloadHostStack` (field `sahsConfig` → `rhsConfig`), `StoppedAudioHostStackOpenIssue` → `ReloadHostStackOpenIssue` (constructors `Sahsoi*` → `Rhsoi*`), `RealStoppedAudioHostStackInputs` → `RealReloadHostStackInputs` (fields `rsahsi*` → `rrhsi*`). Strategy-specific names kept verbatim: `StoppedAudioHostStackOps` / `StoppedAudioHostStackIssue` / `Sahsi*` constructors and their `Preserving*` / `TryPreserving*` counterparts. Aliases dropped from the companion modules; substrate types now imported directly from `MetaSonic.App.ManifestReloadHostStack` and that module's export list is reorganized into substrate / shared open-close / stopped-audio strategy sections. Pure rename — no behavior change, no test changes. Suite stays at 1261. |
| 13 | `99f3110` (+ tier-2 evidence 2026-05-20) | §219 slice 5 step 5: route `--manifest-live-reload-demo require-preserving` through the supervised stack. Completes the supervisor migration arc — all three `--manifest-live-reload-demo` strategies now dispatch through the supervised lifecycle; nothing remains on the direct `reloadManifestHostWithStrategy` path. `LiveReloadRoute` gains a `SfRequirePreserving` flavor; `selectLiveReloadRoute RequirePreserving` flips to `LiveReloadSupervised SfRequirePreserving`. New `runSupervisedRequirePreservingLiveReload` body wires `realPreservingHostStackOps` + `mkPreservingHostStackFactory` (preserving-only — NO stopped-audio fallback composition; this is the structural difference from try-preserving). Because there is no fallback gate, every `InWindowReloadRejectedLiveFallback`-classified preserving outcome (the four resume-ok variants: PlanRejected, QuiesceRejected, DrainRejected, ReloadRejected) surfaces as `SupervisedReloadRequestRejected` and the stack stays serving the previous plan; terminal preserving variants still drive the supervisor's close+rebuild path. `renderLiveReloadRoute` gains the `"supervised (require-preserving; ...)"` rendering pinned by a new test. New tier-2 wrapper `tools/manifest_supervised_require_preserving_live_smoke.sh` + `just manifest-supervised-require-preserving-live-smoke` recipe at default port 17003 (vs 17001 stopped-audio, 17002 try-preserving). The wrapper checks 12 positive markers plus a load-bearing NEGATIVE marker (`check_absent_marker`) asserting the transcript contains no "stopped-audio phase" lines — proves the require-preserving supervised path never composes with stopped-audio fallback. Tier-2 evidence captured 2026-05-20 on host RME ADI-2 Pro / PipeWire: two marker-clean runs of the new wrapper (13/13 each) plus one no-regression run each of the stopped-audio and try-preserving wrappers (12/12 each). Suite: 1261 → 1262 (one new rendering test). |

Test count: the supervisor lane contributes 13 cases in
`MetaSonic.Spec.AppManifestReloadSupervisor` (nine pre-session
baseline + A→B→C→D! regression + the exception/no-double-fire
pair + row 8's "in-window rejected-live-fallback returns
RequestRejected and skips close/open"), 11 cases in
`MetaSonic.Spec.AppManifestReloadSupervisorAdapter` (six
structural + two `getMaskingState` + one throwTo injection +
one outer-restore passthrough + row 8's "in-window
rejected-live-fallback keeps the same stack: no close, no
reopen"), 8 cases of factory composition in
`MetaSonic.Spec.AppManifestReloadHostStack` (success + three
named in-window failure-recovery shapes + rebuild escalation +
no-overlapping-stacks transition invariant + async cleanup +
A→B→C→D! factory-layer regression), 6 cases of
`realStoppedAudioHostStackOps` partial-cleanup paths (forward
success, ingress-open Left, audio-start Left with clean
rollback, audio-start Left with ingress-close-Left surfacing
`RhsoiPartialCleanupFailed`, ingress-close-throws-during-
rollback still runs service close, audio-stop-throws-during-
realClose still runs ingress + service close — the last two
pin the §7d3da25 exception-safety fix), and 1 case for
`realStoppedAudioInWindowReload`'s plan-native short-circuit.
39 lane cases in total at the row-8 close.

Rows 9–11 (preserving + try-preserving + route flip) add the
following spec modules:

* `MetaSonic.Spec.AppManifestReloadPreservingHostStack` — 17
  cases: 10-row `classifyPreservingOutcome` policy table, 5
  factory-composition cases, A→D! regression, and the
  `realPreservingInWindowReload` direct-integration test that
  observes the orchestrator's event stream for both
  override-removed and fallback-swap regressions.
* `MetaSonic.Spec.AppManifestReloadTryPreservingHostStack` —
  23 cases: 11-row `decideTryPreservingNext` table, 2-row
  `composeFallbackOutcome` table, 4-row
  `fallbackEventForDecision` table, 6-branch factory
  composition + A→D! regression.
* `MetaSonic.Spec.AppManifestLiveReloadDemoRender` — 4
  rendering tests for `renderLiveReloadRoute` across the
  four route variants (direct, supervised stopped-audio,
  supervised try-preserving, supervised require-preserving;
  the fourth added in row 13); three
  `selectLiveReloadRoute` pin tests pinning each strategy's
  route mapping (the third updated in row 13 to
  `RequirePreserving → LiveReloadSupervised SfRequirePreserving`).

Total suite at the row-11 close (`ed3409f`): 1261 cases.
Row 12 (`ad2c7e2`) is a pure rename and adds no tests; suite
stays at 1261. Row 13 (`99f3110`) adds one new
`renderLiveReloadRoute SfRequirePreserving` test and updates
one existing `selectLiveReloadRoute RequirePreserving` test
in place; suite goes to 1262.

§238 test-checklist coverage: 11/11 — all 9 originally listed
plus the two additions explicitly named by the design ("A→B→C
regression" and "async exception during recovery closes any
partial stack before surfacing").

### What remains

§219 slices 4 ("real stopped-audio host command using the
supervisor as its outer wrapper") and 5 (manual CLI smoke
against a working device, opened as opt-in tier-2 wrappers
and gated by the 2026-05-20 tier-3 decision note) are both
landed; see rows 7–13 above and the tier-2 evidence record
in [2026-05-19-b-manifest-host-reload-smoke-runbook.md](2026-05-19-b-manifest-host-reload-smoke-runbook.md).
All three `--manifest-live-reload-demo` strategies now
dispatch through the supervised lifecycle. Slices 1 and 3
from the supervisor's dependency list (j-note slices 1 and 2)
are independently landed in the session layer:
`startSessionFanInHostAudio` / `stopSessionFanInHostAudio` on
`SessionFanInHost`, and `quiesceAndDrainSessionFanInService`
on `SessionFanInService`.
`reloadManifestSessionStoppedAudio` lives in
`MetaSonic.Session.ManifestReload.Runtime`.

`MetaSonic.App.ManifestReloadHostStack` has shipped both the
production `HostStackFactory` shape AND the open / close
half against the live session-layer primitives. Per row 12
the substrate types are route-agnostic; the stopped-audio
strategy lives in the same module under route-prefixed
names:

- `ReloadHostStack target ingressIssue handle` newtype
  around `ManifestReloadHostConfig` (no stack-level plan
  field; the supervisor's caller owns currentPlan externally).
  Route-agnostic — every supervised route threads the same
  value through the supervisor adapter.
- `ReloadHostStackOpenIssue ingressIssue` — substrate
  open-time failure ADT covering five real-failure causes
  (service setup, audio start, ingress open,
  ingress-target-projection, partial-cleanup-failed).
  Also route-agnostic; threads through every route's open slot.
- `StoppedAudioHostStackOps target ingressIssue handle` with
  injectable open / close / in-window-reload slots, plus a
  unified `StoppedAudioHostStackIssue` sum that threads
  through `HostStackFactory`'s @e@. Stopped-audio-specific;
  preserving and try-preserving have analogous
  `PreservingHostStackOps` / `TryPreservingHostStackOps`
  records in their companion modules.
- `realStoppedAudioInWindowReload` — plan-native, target-fresh
  production wiring. Drives
  `orchestrateHostStoppedAudioReloadWithEvents` with
  `hsaroPreparePlan = const (pure (Right requested))` so the
  supervisor's supplied plan is the source of truth at the
  seam, and re-projects both `mrhcOldIngressTarget` and
  `mrhcNewIngressTarget` from the `(fallback, requested)`
  plans so target selection cannot drift across a long
  reload sequence (the contract was extended end-to-end:
  `SupervisorOps.sopsInWindowReload :: plan -> plan -> ...`,
  `HostStackFactory.hsfInWindowReload :: stack -> plan ->
  plan -> ...`, `realStoppedAudioInWindowReload :: policy ->
  stack -> plan -> plan -> ...`).
- `realStoppedAudioHostStackOps` + `RealReloadHostStackInputs`
  — production open / close against `openSessionFanInService`,
  the ingress-ops factory (per-host so OSC/MIDI listener
  closures bind to the freshly-opened host on each rebuild),
  and `startSessionFanInHostAudioWith`. Exception-hardened:
  `realOpen` brackets every acquired resource under
  `mask` + `onException`, `realClose` and `rollbackAudioStart`
  both attempt every owned cleanup step and surface the
  strongest/first diagnostic so a throw mid-cleanup cannot
  skip later finalizers.
- `mkStoppedAudioHostStackFactory` — smart constructor
  producing the `HostStackFactory` the supervisor adapter
  drives directly.
- 15 cases in `MetaSonic.Spec.AppManifestReloadHostStack`:
  eight factory-composition scenarios (the seven named in
  §219 slice 4's scope plus an A→B→C→D! factory-layer
  regression against the no-remembered-history invariant),
  six production-helper partial-cleanup paths (including the
  two cleanup-regression tests that pin the exception-safety
  fix from §7d3da25), and one direct integration test for
  `realStoppedAudioInWindowReload`'s plan-native
  short-circuit (asserts no `MrhiPlanning` when running
  against empty doc / catalog).

Slice 4 closed with commit `93e755c` (routing) and `ff9c412`
(handoff hardening + partial-cleanup preservation): the
`StoppedAudioOnly` CLI strategy now dispatches through
`runManifestSupervisedStoppedAudioReloadSmokeWithListenerConfig`,
which inlines the same supervised lifecycle that
`MetaSonic.App.ManifestReloadHostStack.runSupervisedStoppedAudioReload`
exposes at the library layer (the CLI inlines so it can read
the pre-reload ingress snapshot off the original initial stack
/inside the adapter callback/ before `reloadSupervised` runs —
the read is covered by the adapter's `finally closeOps`).
The supervised route is hardware-confirmed once: a 2026-05-20
manual run of `--manifest-live-reload-demo stopped-audio-only`
against `examples/manifests/preserve-cutoff.json` opened real
PortAudio + real OSC ingress, accepted OSC writes on
`/v0/lpf/0` both pre- and post-reload, committed the
supervised reload with the expected
`stopped-audio phase started` / `stopped-audio phase
committed` event pair, and released the OSC port cleanly on
exit; full transcript at
[notes/2026-05-19-b-manifest-host-reload-smoke-runbook.md](2026-05-19-b-manifest-host-reload-smoke-runbook.md).
Hardware-backed CI for this route is deferred (not rejected)
by
[2026-05-20-a-supervised-route-tier3-decision.md](2026-05-20-a-supervised-route-tier3-decision.md);
that note also lists the reopen triggers that would put
tier 3 back on the slate. `TryPreservingThenStoppedAudio`
has since migrated onto the supervisor against the same
bar (row 11 above; tier-2 evidence captured 2026-05-20),
and `RequirePreserving` followed in row 13 (tier-2 evidence
captured 2026-05-20: two marker-clean runs of the new
require-preserving wrapper plus one no-regression run each
of the stopped-audio and try-preserving wrappers). The
supervisor migration arc is now complete; the
`--manifest-live-reload-demo` command no longer dispatches
through the direct `reloadManifestHostWithStrategy` path
for any strategy.

The error surface uses a narrow
`SupervisedStoppedAudioReloadResult` (committed / recovered /
escalated, parameterized over `StoppedAudioHostStackIssue`)
so the supervisor's rebuild causes flow through the result
rather than collapsing into the older
`ManifestReloadHostStrategyIssue` shape. Initial-open failures
that hit the helper's partial-cleanup-also-failed path
surface through a dedicated
`MrciSupervisedPartialCleanupFailed` CLI issue variant so the
operator sees both the primary cause AND the rollback
diagnostic — the helper's "host stack may be in an unknown
state" signal is not silently flattened back to the primary
cause.

Both the library entry and the CLI inline path are
exception-safe across the open-to-adapter handoff: the
'mask' begins before `hsfOpenStack` runs, and the outer
'restore' is used inside the adapter callback around
`readManifestReloadIngressManager` / `reloadSupervised` so
the adapter's `finally closeOps` covers a throw at any point
after the initial stack is in hand.

Resource/allocation recovery events stay parked behind a
real consumer per the
[Manifest Reload Ingress v1 Closeout](2026-05-15-d-manifest-reload-ingress-v1-closeout.md);
the supervisor's escalation outcome (`SupervisedReloadEscalated`)
is the consumer hook waiting for that wiring decision.

## Summary

A future stopped-audio manifest reload command will sometimes fail
terminally: either the session helper's dispose-first construction fails
(`SfriOwnerSetupFailed`), or audio fails to restart on the new owner, or
listener restart fails after audio is back. None of those leave the host
with a usable live state.

The right place for "what happens after terminal failure" is not inside
`reloadManifestSessionStoppedAudio` and not inside the in-window host
command. It is an outer supervisor that owns exactly one active
host/audio/listener stack and one rebuild fallback target.

## Why This Note Exists

The j-note enumerates the in-window failure paths and says, for the worst
case, "allow recovery only through an explicit app-level full host rebuild
or process restart." That is correct but not enough. It does not say:

- whether the rebuild target is the failed requested plan or the previous
  known-good plan;
- whether automatic recovery is allowed at all, or always requires user
  intervention;
- how many recovery attempts are permitted before escalation;
- what other failure surfaces (audio restart, listener restart) the same
  supervisor should cover;
- where the supervisor lives in the module layering, and what the session
  layer does and does not know about it.

The next implementation step ("design the outer supervisor; then build the
current-owner audio seam against it") needs those decisions pinned first.

## Scope

The supervisor covers:

- `SfriOwnerSetupFailed` after `reloadManifestSessionStoppedAudio` has
  disposed the old owner;
- audio restart failure against a newly installed owner;
- listener-restart failure after audio is running again on the new owner;
- terminal `SessionFanInReloadFailed` state on the existing fan-in host;
- future, similarly terminal failures of any other host-orchestrated
  reload operation.

It does NOT cover:

- in-window orchestration steps — those live in the j-note;
- the session-layer reload helper contract — that lives in the i-note;
- preserving hot-swap recovery — a different strategy with its own
  contract;
- divergence-during-step recovery for the existing single-owner step
  shell — that already has its own handling.

## Binding Invariants

These are the recovery rules. Implementation must preserve them; the test
suite must be able to observe them.

1. **Rebuild only from the plan running at reload entry.** When the
   supervisor recovers, it never retries construction from the plan that
   just failed. The failed plan is rejected back to the user; recovery
   uses the `currentPlan` value captured at the moment the failed reload
   was admitted — by construction, the plan the supervisor was running
   end-to-end immediately before the user's request. The supervisor does
   not maintain a separate "previously good" history field; the rebuild
   target is a per-reload local, not accumulated state.

2. **A `ReloadFailed` fan-in host is closed, not retried.** Recovery means
   closing the current `withSessionFanInHost` bracket and opening a fresh
   one. The supervisor does not invent a `ReloadFailed → NormalOperation`
   transition; the in-place state machine remains untouched.

3. **Bounded automatic recovery: one attempt.** If rebuilding against the
   captured fallback plan also fails, the supervisor escalates to
   process-level failure or explicit user intervention. No retry loops, no
   deeper history, no exponential backoff against the same plan.

4. **Exactly one active stack at a time.** The supervisor owns one
   `SessionFanInHost` (or service wrapper), one audio lifetime, and one
   listener/producer set, with no concurrent overlap during transitions.
   Construction of a replacement stack happens only after the previous one
   is closed.

5. **Small state machine.** The supervisor's externally observable state
   is effectively `RunningKnownGood plan | RecoveringOrFailed reason`. It
   does not enumerate partial host states
   (audio-stopped-new-owner-installed, listener-half-reopened, etc.).
   Partial states live inside the in-window command from the j-note; the
   supervisor only sees the terminal result of that command.

## State Sketch

```text
RunningKnownGood currentPlan
  on reload(newPlan):
    fallback := currentPlan          -- captured at reload entry
    in-window orchestration (per j-note)
      success     -> RunningKnownGood newPlan
                       [fallback discarded; newPlan is the new currentPlan]
      terminal    -> RecoveringOrFailed reason
                       attempt rebuild from fallback
                         success -> RunningKnownGood fallback
                         failure -> escalate
```

`fallback` is a per-reload local, captured at reload entry from the
plan currently running. It is released either when the reload succeeds
(the new plan replaces it as `currentPlan`) or when escalation happens.
There is no separate stable "previously known-good" field that the
supervisor accumulates across reloads — that would lag a step behind
and silently lose the most recently committed plan after a later
failure (e.g., A → B succeeds, then B → C fails: the user must come
back to B, not to A).

A reload that crosses the helper's success boundary but fails later in
audio restart or listener restart is treated by the in-window command as
a terminal in-window failure (see j-note); the supervisor enters the
rebuild path against the same captured `fallback`.

## Failure Surfaces

### `SfriOwnerSetupFailed`

The fan-in host enters `SessionFanInReloadFailed` with no owner. The
supervisor closes that host bracket, opens a fresh `withSessionFanInHost`
against the captured `fallback`, runs audio/listener restart against
the new host. If the fresh host's construction or audio/listener restart
fails, escalate.

### Audio restart failure after successful owner reload

The new owner is installed in the same fan-in host; audio is stopped.
The supervisor treats this as terminal for the supervised stack: close
listeners (already closed), stop accepting commands, close the fan-in host
bracket, rebuild against the captured `fallback`. The new owner
constructed successfully, but the host could not return to a live state
— the recovery shape is the same as `SfriOwnerSetupFailed`.

### Listener restart failure after successful audio restart

The new owner is installed and audio is running. The supervisor closes
any reopened listeners, stops audio, closes the fan-in host, rebuilds
against the captured `fallback`. As above, the recovery shape is
uniform: close the supervised stack, build a fresh one from the
captured fallback plan.

### Terminal escalation

Escalation is reported, not silenced. The supervisor's terminal state must
include enough information for the host to log it, surface it to the user,
and (if appropriate) exit nonzero or hand off to a process supervisor. The
supervisor itself does not call `System.Exit.die`; that is the
entry-point's choice.

## Layering And Module Placement

The supervisor lives in `app/` (or under a `MetaSonic.Session.HostSupervisor`
module if it grows session-layer reusability — but as long as it knows
about listeners and audio configuration, it is an app concern).

The supervisor depends on:

- `reloadManifestSessionStoppedAudio` (session layer);
- a future current-owner audio lifecycle seam on `SessionFanInHost`
  (slice 1 from j-note's implementation list);
- the app's listener/producer bracket factories;
- the app's plan/catalog input source.

The session layer remains unaware of the supervisor. `SessionFanInHost`
does not know whether a supervisor is wrapping it; it just exposes its
terminal `ReloadFailed` state for the supervisor to observe.

## Sketched API Shape (not committed; superseded by the landed contract)

> **Forward note.** The sketch below is the pre-implementation
> proposal from 2026-05-14. The landed contract diverged on the
> result shape: there is no outer `Either SupervisedReloadFailure
> SupervisedReloadOutcome` wrapper, and after row 8 (`487fd5c`)
> the outcome surface is the four-variant
> `SupervisedReloadOutcome e = Committed | RequestRejected e |
> RejectedRecovered e | Escalated e e` plus the classified
> `InWindowReloadOutcome e` driving it. Read the sketch as
> design history, not as the current API.

```haskell
data SupervisedSession

data SupervisedReloadOutcome
  = SupervisedReloadCommitted      -- requested plan now running
  | SupervisedReloadRejectedRecovered
      -- requested plan rejected; supervisor recovered to the
      -- fallback plan that was running at reload entry
      ManifestReloadPlan
      SupervisedReloadRejection
  deriving (Eq, Show)

data SupervisedReloadFailure
  = SupervisorRebuildAlsoFailed
      SupervisedReloadRejection -- original
      SupervisedReloadRejection -- rebuild
  deriving (Eq, Show)

reloadSupervised
  :: SupervisedSession
  -> ManifestReloadPlan
  -> IO (Either SupervisedReloadFailure SupervisedReloadOutcome)
```

The constructor names are placeholders. The important properties are:

- `Right SupervisedReloadCommitted` means the requested plan is running;
- `Right SupervisedReloadRejectedRecovered` means the requested plan was
  rejected but the supervisor recovered to the captured fallback (the
  plan that was running at reload entry) — the host is still running,
  just not on the user's requested plan;
- `Left SupervisorRebuildAlsoFailed` means escalation: both the requested
  plan and the rebuild attempt failed, and the supervisor cannot keep the
  host running.

## Implementation Slices

Insert the supervisor before the audio-running host command:

1. Add the current-owner audio lifecycle seam for `SessionFanInHost`
   (already slice 1 in the j-note's list).
2. **Add the supervisor.** Pure or fake-IO orchestration test harness
   first, with injectable failure points at owner construction, audio
   restart, and listener restart. No PortAudio. This is the new slice 1.5.
3. Add the host-level quiesce/drain contract for `SessionFanInService`
   (already slice 2 in the j-note's list).
4. Add the real stopped-audio host command, using the supervisor as its
   outer wrapper.
5. Add the manual CLI smoke that requires a working device.

Ordering rationale: the supervisor calls the audio seam, so the seam
exists first; but the supervisor must exist before the real host command,
because the host command's failure paths terminate in the supervisor.

## Test Checklist

Deterministic tests should cover, against a fake-IO orchestration:

- successful reload commits the requested plan as the new `currentPlan`;
  no per-reload state survives;
- two consecutive successful reloads (A → B → C) leave the supervisor
  running C with no remembered A; a later failed reload from C falls
  back to C, not to A or B (regression test for the "previousGood lags"
  bug the earlier sketch had);
- `SfriOwnerSetupFailed` triggers rebuild from the fallback captured at
  reload entry; the failed plan is reported as rejected;
- successful rebuild after `SfriOwnerSetupFailed` leaves the supervisor
  in `RunningKnownGood fallback` where `fallback` is the plan that was
  running when the failed reload was admitted;
- rebuild that also fails escalates with a value that names both the
  original failure and the rebuild failure;
- audio-restart-after-owner-success failure follows the same rebuild path
  as `SfriOwnerSetupFailed`;
- listener-restart-after-audio-success failure follows the same rebuild
  path;
- no test path produces concurrent fan-in hosts, two audio streams, or
  two listener sets;
- async exception during recovery closes any partial stack before
  surfacing.

Device-backed tests stay manual until the supervisor and host command are
exercisable without a real PortAudio device.

## Non-Goals

- using the failed plan as a future reload's fallback;
- multi-step history of plans accumulated across reloads (the supervisor
  holds only `currentPlan`; the per-reload `fallback` is a local, not
  stable state);
- automatic retry beyond the single rebuild attempt;
- supervising independent producer subsystems separately from the main
  fan-in host;
- supervising preserving hot-swap recovery — that is a different
  strategy and its supervisor would have a different state machine.

These are deliberate omissions to keep the recovery surface small and
testable.
