## Supervision v1 Slice 2 — Repair Lifecycle Transcript Smoke

Date: 2026-05-25

Status: evidence note. Records the operator-facing transcript that
slice 2 of the supervision lane produces when the operator drives a
failed `repair` followed by a successful `repair` after the
supervisor escalated. Companion to the design note
[Long-Running Owner Supervision and Terminal-Divergence Recovery](2026-05-25-f-long-running-owner-supervision-recovery.md)
and the slice 1 transcript
[Supervision v1 Slice 1 — Operator Transcript Smoke](2026-05-25-g-supervision-slice-1-smoke.md).
Slice 2 itself landed as `511eabd` with the doc-sync `dad620f`.

## What this smoke proves

Slice 1 left the operator with the session alive but no gesture to
leave divergence. Slice 2 added the explicit `repair` command and
the `ldsLastRepairFailure` field on `LiveSessionDivergedState`. The
slice 2 contract (from the doc-string at
[ManifestLiveSession.hs L586–L612](../app/MetaSonic/App/ManifestLiveSession.hs#L586-L612))
is:

1. `repair` while not diverged is a one-line refusal and a no-op on
   the supervisor.
2. `repair` while diverged calls `sopsOpenStack` against the
   currently-serving plan through the supervisor adapter.
3. On `Right`: `divergedStateRef` is cleared, the same post-open
   hook that recovered reloads use runs against the current plan,
   `currentPlanRef` is unchanged (the operator never asked for a
   new key).
4. On `Left`: divergence is preserved, the rendered cause is
   recorded into `ldsLastRepairFailure`, the post-open hook does
   NOT run, and `status` then renders a new
   `last repair attempt failed:` row beneath the existing
   in-window / rebuild rows.

(1) is pinned by the unit test at
[AppManifestLiveSession.hs:1805](../test/MetaSonic/Spec/AppManifestLiveSession.hs#L1805);
(2)–(4) are pinned by the three further unit tests at
[L1841](../test/MetaSonic/Spec/AppManifestLiveSession.hs#L1841),
[L1884](../test/MetaSonic/Spec/AppManifestLiveSession.hs#L1884),
and [L1936](../test/MetaSonic/Spec/AppManifestLiveSession.hs#L1936).
This note adds a contiguous operator-facing transcript that walks
the full failure-then-success lifecycle through the real
`reloadSupervisedWithEvents` + `runReloadWithSink` +
`dispatchLiveSessionRepair` + `printStatusWith` surfaces, with a
single `SupervisorOps` value living across all three opens (one
rebuild + two repairs) so the test mirrors the production session
loop's lifecycle rather than swapping ops mid-run.

## What this smoke does *not* prove

The substrate is stubbed for the same reason slice 1's smoke
stubbed it: reproducing the deliberate
in-window-terminal-plus-failed-fallback-open path against real
PortAudio + OSC ingress would need external state to change in a
narrow window between `sopsCloseStack` and `sopsOpenStack`. The
supervisor, the dispatch helper, the status renderer, and the
session-loop integration of `dispatchLiveSessionRepair` are
unchanged production code; only `SupervisorOps` is stubbed.

Two scope notes specific to slice 2:

* `trackedStackRef` stays `Nothing` throughout the transcript. The
  smoke uses a stubbed `sopsOpenStack` that does not go through the
  supervisor adapter's `withTrackedFactory` wrapper, so the
  wrapper-side update of the tracking ref is out of scope here.
  That is why the final `status` after the successful `repair`
  still shows `audio running:     (no live stack)` — in production
  the wrapper would have written `Just s` into the ref and `status`
  would render the fan-in / ingress snapshot instead. The wrapper
  itself is covered by the `withTrackedFactory` test group above
  in the same file.

* The post-open hook in production reads `trackedStackRef` to
  auto-start one voice per template and reset / reconcile the
  Phase 8h value cache
  ([ManifestLiveSession.hs L1437–L1502](../app/MetaSonic/App/ManifestLiveSession.hs#L1437-L1502)).
  The smoke's hook is a stub that just appends the served plan to a
  list ref and emits a `(post-open hook called with plan: …)` line
  into the transcript, which is enough to pin the dispatch
  contract: the hook fires after a successful open, the hook does
  NOT fire after a failed open, and the hook receives the
  currently-serving plan.

Background watchdogs, cooldowns, auto-retry, and any cross-run
persistent diverged-state telemetry are explicitly deferred per the
2026-05-25-f design note and are not exercised here.

## Reproduction recipe

The smoke is implemented as a tasty test case so it runs under
`stack test` and pins the operator-facing strings against renderer
drift. The captured transcript is echoed to stderr between
`<<<SUPERVISION-SLICE-2-TRANSCRIPT-BEGIN>>>` and
`<<<SUPERVISION-SLICE-2-TRANSCRIPT-END>>>` markers (tasty does not
suppress stderr).

```sh
stack test --test-arguments '-p "supervision slice 2 operator transcript"' 2>&1 \
  | sed -n '/<<<SUPERVISION-SLICE-2-TRANSCRIPT-BEGIN>>>/,/<<<SUPERVISION-SLICE-2-TRANSCRIPT-END>>>/p'
```

Test location:
[`test/MetaSonic/Spec/AppManifestLiveSession.hs`](../test/MetaSonic/Spec/AppManifestLiveSession.hs)
— search for `"supervision slice 2 operator transcript"`. The test
asserts the captured transcript contains the load-bearing
operator-facing strings; any renderer drift fails the test and
forces a paired update of this note.

## Transcript

Captured `2026-05-25` against `511eabd` + `dad620f` on
GHC 9.12.4 (nightly resolver per
[GHC 9.12.4 Stack Nightly Upgrade](2026-05-25-e-ghc-9124-stack-nightly-upgrade.md)).
The block below is the test's IORef-sink capture, with the
`<<<...BEGIN>>>` / `<<<...END>>>` framing stripped. As in slice 1,
the `(stderr) live session escalated: no live stack remains.` row
is a hand-written annotation the test emits into the sink to mark
where `runReloadWithSink` writes that text directly to stderr
([ManifestLiveSession.hs L1727–L1728](../app/MetaSonic/App/ManifestLiveSession.hs#L1727-L1728)).
The actual stderr write happens before the `<<<...BEGIN>>>` marker
in the raw test output and is not threaded through the sink.

```text

== operator types: demo:preserve-cutoff-bright ==

  preflight events:
    - preflight started: "preserve-cutoff-bright"
    - preflight succeeded: "preserve-cutoff-bright"

  supervised outcome: escalated (no live stack)
  reload events:
    (none)
  supervisor events:
    - in-window: started
    - in-window: terminal
    - close previous stack: started
    - close previous stack: succeeded
    - fallback open: started
    - fallback open: failed
  in-window cause: in-window-cause
  rebuild cause:   rebuild-cause
  resource timeline:
    - terminal in-window failure; recovering from fallback
    - closed previous stack
    - fallback rebuild failed
    - serving plan: (no live stack)

(stderr) live session escalated: no live stack remains.

== operator types: status ==


  status:
    current plan demo: preserve-cutoff-dark
    audio running:     (no live stack)
    no live stack:     repair required
      in-window cause: in-window-cause
      rebuild cause:   rebuild-cause
    last outcome:      escalated (no live stack)

== operator types: repair ==

  repair: opening a fresh stack on the current plan...
  repair failed: open-refused-retry
  session remains diverged; type 'status' for context, 'repair' to retry, or 'quit' to exit.

== operator types: status ==


  status:
    current plan demo: preserve-cutoff-dark
    audio running:     (no live stack)
    no live stack:     repair required
      in-window cause: in-window-cause
      rebuild cause:   rebuild-cause
      last repair attempt failed: open-refused-retry
    last outcome:      escalated (no live stack)

== operator types: repair ==

  repair: opening a fresh stack on the current plan...
  repair: succeeded; serving preserve-cutoff-dark.
  (post-open hook called with plan: preserve-cutoff-dark)

== operator types: status ==


  status:
    current plan demo: preserve-cutoff-dark
    audio running:     (no live stack)
    last outcome:      escalated (no live stack)
```

The `(post-open hook called with plan: preserve-cutoff-dark)` line
is the smoke's own marker for "`dispatchLiveSessionRepair` invoked
the supplied `onPlanChange` against the currently-serving plan
after the open succeeded"; the production session passes the
auto-start + value-cache-reconcile closure in that slot.

## What the transcript demonstrates against the slice 2 contract

* The first block re-establishes the diverged starting state.
  Escalation comes out of the real `reloadSupervisedWithEvents`
  path (script entry 1: `Left "rebuild-cause"`); the supervisor
  event sequence and the resource timeline are identical to slice
  1's transcript, confirming the same deliberate
  close-then-rebuild decision branch and that
  `divergedStateRef` is populated with both causes and
  `ldsLastRepairFailure = Nothing`.

* The status read after escalation shows the slice 1 block — three
  rows: `no live stack: repair required` plus the two causes — and
  no `last repair attempt failed:` row yet. This pins
  `ldsLastRepairFailure = Nothing` at the point of escalation, the
  field's documented initial value at
  [ManifestLiveSession.hs L1738–L1740](../app/MetaSonic/App/ManifestLiveSession.hs#L1738-L1740).

* The first `repair` attempt prints the three documented lines:
  the attempt line, the failure line carrying the rendered cause
  (`open-refused-retry`, from script entry 2), and the one-line
  hint that names `status` / `repair` / `quit` as the surviving
  options. `dispatchLiveSessionRepair` returned `SsContinue`, so
  the loop stays alive — the test asserts `step1 @?= SsContinue`.

* The status read after the failed `repair` now shows the new
  fourth row `last repair attempt failed: open-refused-retry`
  beneath the in-window / rebuild rows. The original
  in-window-cause and rebuild-cause rows are unchanged: a failed
  repair updates `ldsLastRepairFailure` but never overwrites the
  two original escalation causes.

* The second `repair` attempt (script entry 3: `Right ()`) prints
  the attempt line, the success line naming the served plan
  (`preserve-cutoff-dark`, the plan that was already current — the
  operator never asked for a new key), and the
  `(post-open hook called with plan: preserve-cutoff-dark)` marker
  the test emits to confirm the hook fired against the current
  plan. The test asserts the hook history list contains exactly
  one entry, which proves the hook did NOT fire after the failed
  attempt above.

* The status read after the successful `repair` no longer renders
  the diverged block: `divergedStateRef` was cleared. The test
  asserts `readIORef divergedStateRef >>= (@?= Nothing)` and
  `readIORef currentPlanRef` still resolves to
  `preserve-cutoff-dark`, pinning that a successful repair does
  not silently change the served plan.

* The test also asserts `readIORef openScriptRef >>= (@?= [])`
  after the run — exactly three `sopsOpenStack` calls happened
  (one rebuild + two repairs), no more, no fewer. This pins the
  full lifecycle against a quiet over-call or under-call regression
  in either `runReloadWithSink` or `dispatchLiveSessionRepair`.

## What stays open after this slice

The supervision v1 bullet in `ROADMAP.md` stays unchecked
deliberately: slice 1 + slice 2 cover the in-shell operator gesture
(observe divergence, manually retry), but the larger
"long-running owner supervision" lane the 2026-05-25-f note scoped
also names items that are still out of scope here — notably any
background watchdog above the session, auto-retry with cooldown,
cross-run persistent diverged-state telemetry, and the
`ManifestReloadGraphEvent` / `SessionVoiceAllocationEvent`
consumer-gated event families. A later pass can decide whether
slices 1 + 2 are enough to close the lane (with the remaining items
spun out as their own bullets) or whether the lane should stay open
with a sharper remaining item list.
