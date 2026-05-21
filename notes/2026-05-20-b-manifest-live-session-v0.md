# Manifest Live Session v0 (Phase 8)

Date: 2026-05-20

Status: design + landed.

This is the Phase 8 / session-product integration kickoff slice: the
first real consumer of the manifest reload pipeline + supervisor
substrate that previous slices (§219 1.5–5.5) built up. Until this
slice landed, every consumer-gated decision downstream
(allocation-event streaming, stale-command semantics, GUI bindings)
was being made in the abstract. The session shell is the concrete
thing those decisions now have to be sound against.

## Why a new entrypoint

The existing `--manifest-live-reload-demo` command is structurally a
two-shot operator demo: it starts on `OLD`, waits for one Enter,
reloads to `NEW`, waits for another Enter, exits. That shape is
useful as a hardware-validation smoke for the supervised routes but
is not a "session" — there is no open-ended owner loop, no second
reload, no way to drive the supervisor's state machine across the
RejectedRecovered → next-reload transition.

The session shell answers that gap with the minimum viable
operator-interactive surface:

* startup imports an external manifest doc, validates the initial
  demo against the built-in catalog, projects ingress, opens the
  supervised stack, and enters a stdin command loop;
* `demo:KEY` triggers a supervised reload to `KEY` using the
  configured strategy;
* empty line (`<Enter>`) prints a status snapshot (current plan
  demo, audio running, ingress snapshot, last-reload outcome);
* EOF (`<Ctrl-D>`) exits cleanly through the adapter's `finally
  closeOps`.

That is it. There is no real REPL, no command history, no
authoring surface, no GUI. The point of v0 is to expose every
supervisor outcome on a real session timeline so the operator can
observe what request-rejected / rejected-recovered / escalated
look like end-to-end, and so we can decide what the next consumer-
gated work should design against.

## Why `RequirePreserving` is the default

`RequirePreserving` is the safest-by-default of the three
supervised strategies: it never composes with stopped-audio
fallback, so a preserving rejection is always surfaced as
`SupervisedReloadRequestRejected` (live stack unchanged) and never
becomes a silent fall-back into stopped-audio. Operators who want
the more-aggressive `TryPreservingThenStoppedAudio` (admit
stopped-audio when preserving rejects with a fallback-eligible
cause) or `StoppedAudioOnly` (stop audio + reinstall every reload)
have to opt in explicitly via `--strategy STRATEGY`. The strategy
flag accepts the same name set the other manifest CLIs use:
`require-preserving`, `try-preserving`, `stopped-audio-only`.

## Outcome state machine

The stdin command loop's response to each supervisor outcome is
pinned by `stepFromOutcome` in `MetaSonic.App.ManifestLiveSession`,
table-tested as a deterministic projection from
`SupervisedReloadOutcome e` to `(LiveSessionOutcome, SessionStep)`:

| Supervisor outcome | Session outcome | Step | Operator narration |
|---|---|---|---|
| `Committed` | `LsoCommitted` | continue | current plan := requested; reads return new plan |
| `RequestRejected e` | `LsoRequestRejected` | continue | stack stays on previous plan; cause printed |
| `RejectedRecovered e` | `LsoRejectedRecovered` | continue | supervisor rebuilt from fallback; current plan unchanged from the caller's perspective; tracking IORef now points at the rebuilt stack |
| `Escalated e1 e2` | `LsoEscalated` | terminate (`ExitFailure 1`) | both halves printed to stdout; one diagnostic line to stderr; session exits nonzero |

Plus a session-local variant for operator-typed keys that do not
resolve in the catalog or fail to plan against the loaded manifest:
`LsoPlanRejected reason` — supervisor not invoked; continue
serving. This distinction matters because the session must NOT
terminate on a typo'd demo key; only on supervisor escalation.

## Tracking the active stack

The supervisor adapter holds an internal `IORef (Maybe stack)` but
does not expose it. The session shell needs read access for status
snapshots because the initial stack captured at startup is no
longer authoritative after a `RejectedRecovered` (the supervisor
has closed it and opened a fresh one). The session shell solves
this with `withTrackedFactory`, a small wrapper that mirrors
`hsfOpenStack` / `hsfCloseStack` writes into a caller-owned
`IORef (Maybe stack)`:

* `hsfOpenStack plan` returns `Right s` → write `Just s`;
* `hsfOpenStack plan` returns `Left e` → leave the ref alone (the
  failed open did not minted a fresh stack);
* `hsfCloseStack s` → clear the ref under `finally`, so the ref is
  emptied even if close throws.

`hsfInWindowReload` is NOT wrapped — the supervisor only swaps the
stack value on close-then-open (terminal in-window outcome), never
on in-window success or live-fallback rejection. Wrapping the
in-window slot would add overhead for no semantic effect.

The close-then-open window reads as `Nothing` momentarily. The
session's status renderer prints `"(no live stack)"` for that case
rather than crashing.

## v0 acceptance criteria

What this slice must prove for the entrypoint to count as the
first real consumer:

1. **Startup uses external manifest import + catalog validation.**
   `runManifestLiveSession` calls `readManifestDocOrDie` and
   `planOrDie` from `ManifestLiveCommon`; both `die` on failure at
   startup. Mid-run planning failures from operator commands use
   the `Either`-returning primitives so a typo'd `demo:KEY` does
   not kill the session.

2. **Initial stack opens with real audio and real ingress.** The
   supervised factory's `hsfOpenStack` runs the substrate's
   `realOpen` exactly as the live-reload-demo's three routes do.

3. **`demo:KEY` calls the supervised reload path.** `runReload`
   calls `reloadSupervised` against the operator's resolved plan
   with the current plan as fallback. The events captured during
   the reload (`MrePreservingReloadStarted`,
   `MrePreservingReloadCommitted`, etc.) are printed inline.

4. **Outcome line distinguishes committed / request-rejected /
   recovered / escalated.** `renderLiveSessionOutcome` is
   table-tested for each `LiveSessionOutcome` variant.

5. **Post-reload ingress still accepts writes.** Tier-2 wrapper
   sends `/v0/lpf/0 = 0.25` after the reload and asserts the
   `osc accept:` marker on the new value.

6. **Exit closes audio and releases the ingress port/device.**
   Tier-2 wrapper checks `session exit=0`, an `ss -lun` snapshot
   showing no UDP listener on the configured port, and an active
   Python `socket.bind` rebind probe.

All six are exercised end-to-end by
`tools/manifest_live_session_require_preserving_smoke.sh`, with
the same load-bearing negative marker the require-preserving
live-reload-demo wrapper carries: no `"stopped-audio phase"`
lines appear in the transcript, proving the require-preserving
session never composes with stopped-audio fallback.

## Deterministic test surface

Module `MetaSonic.Spec.AppManifestLiveSession` covers the pure
pieces without any live IO:

* **`parseLiveSessionCommand`** — 10 rows: empty + whitespace-only
  → `LscStatus`; `demo:foo`/`  demo:foo  ` → `LscReloadTo "foo"`;
  `demo:` and `demo:   ` → `LscUnknown`; internal whitespace inside
  the key preserved; case-sensitive prefix; arbitrary text →
  `LscUnknown` with the original line preserved.
* **`stepFromOutcome`** — 4 rows, one per `SupervisedReloadOutcome`
  variant; pins the continue/terminate decision and the
  outcome-tag.
* **`renderLiveSessionOutcome`** — 5 rows covering every
  `LiveSessionOutcome` variant including the `LsoPlanRejected
  reason` shape that the supervisor never produces.
* **`withTrackedFactory`** — 5 cases pinning the IORef-mirroring
  invariants: open writes on `Right`, leaves the ref alone on
  `Left`, close clears the ref under `finally` (verified with an
  intentionally-throwing `hsfCloseStack`), in-window does not
  touch the ref.

Total: 24 new test cases.

## What this slice did NOT do (at the time)

These bullets describe scope as the v0 slice landed on
2026-05-20. Some have since been closed by follow-up slices —
see "Follow-ups landed" below for the closed list and the
commit hashes. The bullets here stay in their original wording
so the v0 design rationale is recoverable.

Deliberately out of scope so the entrypoint can be the consumer
that informs each:

* **Resource/allocation event streaming.** Still consumer-gated
  per the v1-closeout note. The session shell has a `lastOutcomeRef`
  but no allocation-event timeline.
* **Stale-command semantics.** No producer-aware enqueue rejection;
  no `MrePreservingReloadEnqueueRejected` consumer surface beyond
  the `renderLiveReloadEvents` timeline that the live-reload-demo
  already prints. The first follow-up slice, limited to
  reload-window OSC rejection rendering and listener double-print
  cleanup, is scoped in
  [2026-05-20-d-stale-command-rejection-rendering.md](2026-05-20-d-stale-command-rejection-rendering.md).
* **GUI bindings.** Pure stdin; no MIDI control surface beyond
  what the manifest catalog already projects.
* **Hardware-CI promotion.** Tier-2 wrapper + the existing
  three-route wrappers cover the live device path; tier-3 stays
  deferred per `2026-05-20-a-supervised-route-tier3-decision.md`.
* **A second supervised route's wrapper for the session.** Only
  require-preserving gets a wrapper in v0. If operator demand grows
  for try-preserving or stopped-audio sessions, the wrapper
  pattern is mechanical to fan out (port 17005 + 17006); the
  marker shape is the same plus or minus the negative marker.

## Follow-ups landed

* **Stale-command rejection surface (2026-05-20):** producer-aware
  OSC reload-window rendering (`144901f` + `737b124`), then the
  internal preserving-queue rejection event
  (`MrePreservingReloadEnqueueRejected`) + CLI rendering in
  `5849efc`. Closes the second half of the original
  "Stale-command semantics" bullet above. Design note:
  [2026-05-20-d-stale-command-rejection-rendering.md](2026-05-20-d-stale-command-rejection-rendering.md).
* **Supervisor lifecycle event stream (2026-05-21):**
  `SupervisedReloadEvent` substrate (`d86a2df`), callback-safety
  guard so observer exceptions cannot bypass terminal cleanup
  (`ffaca33`), and the live-session `supervisor events:` block
  reading the observed stream alongside the existing derived
  `resource timeline:` summary (`6b8c08c`). Partially closes the
  original "Resource/allocation event streaming" bullet: the
  supervisor's own close/open lifecycle is now observed; finer
  resource/allocation detail INSIDE the in-window slot
  (open-stage subdivision, audio start/stop framing) is the
  next reach if a real-session transcript shows the current
  block is too abstract.
* **Reject-path tier-2 fan-out (2026-05-21):** companion wrapper
  `manifest_live_session_require_preserving_reject_smoke.sh`
  (`9b39fd2`) against the new `reject-preserving-smooth`
  fixture (`c19e0cc`). Pins the request-rejected operator
  narrative end-to-end (23 markers). The other supervised
  routes (try-preserving session, stopped-audio session) still
  do not have wrappers.

## Lane status after closeouts

Lane state after the closeouts above:

* **`RejectedRecovered` / `Escalated` real-session pressure —
  closed by 2026-05-21 spike.** The supervisor's terminal
  close + fallback-open path remains deterministic-unit-tested
  only. A short investigation spike walked
  `classifyPreservingOutcome`'s six terminal constructors and
  found that each one requires one of: compound resume-failure
  (primary AND resume both fail independently); an unexpected
  drain / protocol shape from the session owner (`StepCommitted
  _ Nothing`, `StepCommitMismatch`, `StepAdapterProtocolBug`,
  `StepControlAccepted`); an owner-divergence shape
  (`SessionOwnerDivergedNow` / `SessionOwnerBlocked`, which is
  where `SodBackendStopped` / `SodHotSwapInstallFailed` land);
  or a millisecond port-collision race against the close-reopen
  window. No clean musical fixture in the same family as
  `reject-preserving-smooth` puts the runtime in any of these
  Terminal-routed states. Both a port-collision tier-2 wrapper
  and a test-only `--force-terminal-on-next-reload` CLI flag
  were rejected (timing-flaky and production-flag-as-test-hook,
  respectively). Re-open only if a real operator session
  produces a terminal recovery transcript organically or if a
  deterministic non-racy resource trigger appears. Full
  analysis at
  [2026-05-21-a-reject-path-operator-pressure-pass.md](2026-05-21-a-reject-path-operator-pressure-pass.md)'s
  "Lane status after spike" section.
* **Finer in-window allocation/resource detail.** Pure
  conjectural until a transcript shows the current
  `supervisor events:` block is too coarse; document the gap
  if one shows up.
* **Try-preserving / stopped-audio session wrappers.** Same
  mechanical fan-out as the existing two wrappers; trigger
  is operator demand for those strategies.
