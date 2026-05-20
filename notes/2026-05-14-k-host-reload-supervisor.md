# Manifest Reload Host Supervisor And Recovery Policy

Date: 2026-05-14

Status: design + supervisor primitive + real-host adapter landed.
Real stopped-audio host wiring (§219 slice 4) is the next step.
The contract body below remains the design record the
implementation slices were reviewed against; the "Implemented
status" section immediately below this header is the
authoritative summary of what shipped.

This is the lifecycle-supervisor companion to
`2026-05-14-j-host-stopped-audio-manifest-reload-orchestration.md`. The
j-note pins the in-window orchestration sequence; this note pins the outer
recovery policy when an in-window operation fails terminally.

## Implemented status

Landed across six commits in the §219 ordering, all under
deterministic fake-IO test coverage (no PortAudio, no real
listeners, no live audio host):

| # | Commit | Slice content |
|---|--------|---------------|
| 1 | `f34522e` (earlier, pre-session) | §219 slice 1.5 baseline: `MetaSonic.App.ManifestReloadSupervisor` primitive — `SupervisorOps plan e` with `sopsInWindowReload` / `sopsCloseStack` / `sopsOpenStack`, `reloadSupervised` capturing `fallback` as a per-call local. Outcome variants `SupervisedReloadCommitted | SupervisedReloadRejectedRecovered e | SupervisedReloadEscalated e e`. 9 fake-IO test cases in `MetaSonic.Spec.AppManifestReloadSupervisor`. |
| 2 | `ef6bd80` | §238 #9 cleanup invariant: `reloadSupervised` wraps `sopsInWindowReload` in `onException sopsCloseStack` so a throw from the in-window op closes the still-live previous stack before propagating. Two paired tests pin the change (throw during in-window closes the live stack; normal `Left e` recovery does not double-fire the wrapper). |
| 3 | `7b8a2c6` | §238 #2 regression: A→B→C→D! "no remembered history" test. Two committed reloads then a failed third reload; the rebuild target must be the plan running at this reload's entry (C), not earlier history (B or A). Belt-and-suspenders against a future "previousGood" history-accumulation refactor. |
| 4 | `8892eb4` | §219 next-layer-outward: new module `MetaSonic.App.ManifestReloadSupervisorAdapter` with `HostStackFactory plan stack e` (3 slots: open / close / in-window) and `withHostStackSupervisorAdapter`, an `IORef`-backed bracket that exposes a `SupervisorOps` the supervisor can drive. 6 fake-IO test cases covering close-before-open, fallback rebuild, escalation, and active-stack-ref bookkeeping. |
| 5 | `5616d9a` | Async-exception windows in the adapter halves: `openOps` now `mask $ \restore -> ...` so the "Right newStack → writeIORef" publication is uninterruptible; `closeActiveStack` now `mask_` so the "atomicModifyIORef → hsfCloseStack" handoff is atomic. Three new tests: two `getMaskingState` observations + one `forkIO`/`throwTo` injection test asserting no minted stack id is left without a matching close on the recovery path. |
| 6 | `d990c33` | Outer setup-window mask: `withHostStackSupervisorAdapter factory initialStack k = mask $ \restore -> do ... ; restore (k supOps) `finally` closeOps`. Closes the §103 window between `newIORef (Just initialStack)` and the `finally` install where an async exception would have leaked the already-open initialStack. New test pins that `restore` correctly hands the caller's masking state to the continuation. |

Test count: the supervisor lane contributes 11 cases in
`MetaSonic.Spec.AppManifestReloadSupervisor` (including the
A→B→C→D! regression and the exception/no-double-fire pair) and 10
cases in `MetaSonic.Spec.AppManifestReloadSupervisorAdapter`
(six structural + two `getMaskingState` + one throwTo injection
+ one outer-restore passthrough). Both modules are wired into
`test/Spec.hs` and the package.yaml test-component
`other-modules`. Total suite at this lane's close: 1194 cases.

§238 test-checklist coverage: 11/11 — all 9 originally listed
plus the two additions explicitly named by the design ("A→B→C
regression" and "async exception during recovery closes any
partial stack before surfacing").

### What remains

§219 slice 4 ("Add the real stopped-audio host command, using
the supervisor as its outer wrapper") and slice 5 (manual CLI
smoke against a working device) have not been started. Slices 1
and 3 from the supervisor's dependency list (j-note slices 1
and 2) are independently landed in the session layer:
`startSessionFanInHostAudio` / `stopSessionFanInHostAudio` on
`SessionFanInHost`, and `quiesceAndDrainSessionFanInService` on
`SessionFanInService`. `reloadManifestSessionStoppedAudio` (the
helper the supervisor's in-window reload will call) also lives
in `MetaSonic.Session.ManifestReload.Runtime`.

The slice-4 wiring step is therefore: implement a production
`HostStackFactory ManifestReloadPlan SomeError` against the
real `SessionFanInService` + ingress manager + audio FFI
bundle, build `withHostStackSupervisorAdapter` over it, and
route the existing `reloadManifestHostWithStrategy` /
`reloadManifestStoppedAudioHost` paths through
`reloadSupervised`. Resource/allocation recovery events stay
parked behind a real consumer per the
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

## Sketched API Shape (not committed)

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
