## Supervision v1 Slice 1 — Operator Transcript Smoke

Date: 2026-05-25

Status: evidence note. Records the operator-facing transcript that
slice 1 of the supervision lane produces when the supervisor
deliberately classifies an in-window reload as terminal and the
fallback open also fails. Companion to the design note
[Long-Running Owner Supervision and Terminal-Divergence Recovery](2026-05-25-f-long-running-owner-supervision-recovery.md),
which scoped the slice; the slice itself landed as `f6c0ec0` with
the doc-tense cleanup `f0de6ba`.

## What this smoke proves

The slice 1 sketch in §"Likely v1 implementation slice (post-note)"
of the 2026-05-25-f design note called for:

1. `stepFromOutcome SupervisedReloadEscalated → SsContinue` (loop
   stays alive past escalation);
2. a diverged-state IORef holding the two escalation causes;
3. `printStatusWith` rendering a `no live stack: repair required`
   block when the ref is populated;
4. the dispatch gate refusing `demo:KEY` / `set` / `controls` /
   `values` while diverged, keeping `status` / `demos` / `help` /
   `quit` open;
5. a transcript demonstrating the loop staying alive with the
   terminal state visible in `status`.

(1)–(4) are pinned across three test groups:
[`stepFromOutcomeTests`](../test/MetaSonic/Spec/AppManifestLiveSession.hs#L287)
pins (1) (the `LsoEscalated → SsContinue` mapping at
[L301](../test/MetaSonic/Spec/AppManifestLiveSession.hs#L301));
[`runReloadWithTests`](../test/MetaSonic/Spec/AppManifestLiveSession.hs#L735)
pins (2) (the `divergedStateRef` populated with both causes at
[L950](../test/MetaSonic/Spec/AppManifestLiveSession.hs#L950));
and
[`supervisionDivergedTests`](../test/MetaSonic/Spec/AppManifestLiveSession.hs#L1687)
pins (3) (status-block rendering, with and without the ref
populated) and (4) (gate policy per command + refusal wording).
This note adds (5): a contiguous operator-facing transcript
covering one escalation event plus the gate policy and refusal
text for each command, captured from the real
`reloadSupervisedWithEvents` + `runReloadWithSink` +
`printStatusWith` + `liveSessionCommandIsGatedWhileDiverged`
surfaces. The dispatcher local to `sessionLoop` is *not* exercised
end-to-end — the smoke calls the gate predicate directly and
emits the refusal text manually, so it pins the policy and the
wording but not the dispatch site itself.

## What this smoke does *not* prove

The smoke does not run real PortAudio or real OSC ingress.
Reproducing the supervisor's deliberate
in-window-terminal-plus-failed-fallback-open path against real
hardware is racy: it requires the fallback open of an already-opened
plan to fail, which would need external state to change in a narrow
window between `sopsCloseStack` and `sopsOpenStack`. The supervisor
and renderers under test are unchanged production code; only the
substrate is stubbed, deterministically presenting
`InWindowReloadTerminal` from `sopsInWindowReload` and `Left` from
`sopsOpenStack`. This is the deliberate decision branch
([ManifestReloadSupervisor.hs L293–L319](../app/MetaSonic/App/ManifestReloadSupervisor.hs#L293-L319))
— *not* the `onException` cleanup path that fires when
`sopsInWindowReload` throws.

The follow-up "repair" command (an explicit `repair` that re-runs
the substrate's `realOpen` against a fresh plan) is deliberately
out of scope here; the slice closes when the operator can observe
the divergence and exit cleanly, not when they can recover from it.

## Reproduction recipe

The smoke is implemented as a tasty test case so it runs under
`stack test` and pins the operator-facing strings against renderer
drift. The captured transcript is echoed to stderr between
`<<<SUPERVISION-SLICE-1-TRANSCRIPT-BEGIN>>>` and
`<<<SUPERVISION-SLICE-1-TRANSCRIPT-END>>>` markers (tasty does not
suppress stderr).

```sh
stack test --test-arguments '-p "supervision slice 1 operator transcript"' 2>&1 \
  | sed -n '/<<<SUPERVISION-SLICE-1-TRANSCRIPT-BEGIN>>>/,/<<<SUPERVISION-SLICE-1-TRANSCRIPT-END>>>/p'
```

Test location:
[`test/MetaSonic/Spec/AppManifestLiveSession.hs`](../test/MetaSonic/Spec/AppManifestLiveSession.hs)
— search for `"supervision slice 1 operator transcript"`. The test
asserts the captured transcript contains the load-bearing
operator-facing strings; any renderer drift fails the test and
forces a paired update of this note.

## Transcript

Captured `2026-05-25` against `f6c0ec0` + `f0de6ba` on
GHC 9.12.4 (nightly resolver per
[GHC 9.12.4 Stack Nightly Upgrade](2026-05-25-e-ghc-9124-stack-nightly-upgrade.md)).
The block below is the test's IORef-sink capture, with the
`<<<...BEGIN>>>` / `<<<...END>>>` framing stripped. One line is
*not* a sink capture: the `(stderr) live session escalated: no
live stack remains.` row is a hand-written annotation the test
emits into the sink to mark where `runReloadWithSink` writes that
text to stderr
([ManifestLiveSession.hs L1615–L1616](../app/MetaSonic/App/ManifestLiveSession.hs#L1615-L1616)).
The real stderr write happens before the `<<<...BEGIN>>>` marker
in the raw test output (visible at the top of `stack test`
output) and is not threaded through the sink.

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

== operator types: demo:preserve-cutoff-bright ==

  no live stack: repair required.
  this command is unavailable while the session is diverged.
  available commands: status, demos, help, quit.

== operator types: set lpf 1500 ==

  no live stack: repair required.
  this command is unavailable while the session is diverged.
  available commands: status, demos, help, quit.

== operator types: controls ==

  no live stack: repair required.
  this command is unavailable while the session is diverged.
  available commands: status, demos, help, quit.

== operator types: values ==

  no live stack: repair required.
  this command is unavailable while the session is diverged.
  available commands: status, demos, help, quit.

== operator types: status ==

(passes the diverged gate; would be dispatched)

== operator types: demos ==

(passes the diverged gate; would be dispatched)

== operator types: help ==

(passes the diverged gate; would be dispatched)

== operator types: quit ==

(passes the diverged gate; would be dispatched)
```

`(passes the diverged gate; would be dispatched)` is the smoke's
own marker for "the dispatcher would call into the per-command
handler here"; the production session loop renders the actual
output of `status` / `demos` / `help` / a clean shutdown for
`quit` at that point.

## What the transcript demonstrates against the slice contract

* The `supervised outcome: escalated (no live stack)` line and the
  two cause lines come from
  [`runReloadWithSink`](../app/MetaSonic/App/ManifestLiveSession.hs#L1473)
  after `reloadSupervisedWithEvents` returns
  `SupervisedReloadEscalated`. The six-step supervisor event
  sequence (in-window started/terminal → close started/succeeded →
  fallback open started/failed) confirms the deliberate
  close-then-rebuild decision branch — the cleanup-on-exception
  path would have emitted only `in-window: started` before
  unwinding.

* The real `live session escalated: no live stack remains.`
  stderr line is the operator's immediate "something terminal
  happened" signal, kept on stderr per the design note's
  stipulation that it is a non-operator surface and is exempt
  from the Haskeline edit-buffer corruption mechanism the
  §"Phase 8j" sink work addresses. The transcript block mirrors
  that line as `(stderr) ...` because the actual stderr write is
  outside the sink capture and appears before the raw BEGIN marker.

* The next prompt does **not** terminate the process. The slice's
  load-bearing change — `stepFromOutcome` returning `SsContinue`
  for `LsoEscalated` — keeps the loop alive so the operator can
  read the state.

* `status` renders the new diverged block between the existing
  `audio running:     (no live stack)` and `last outcome:` lines.
  The block ordering is pinned by the existing
  `printStatusWith renders 'no live stack: repair required' block`
  test ([AppManifestLiveSession.hs:1716](../test/MetaSonic/Spec/AppManifestLiveSession.hs#L1716)).

* Four commands (`demo:KEY`, `set`, `controls`, `values`) hit the
  diverged refusal — the three-line operator-facing text
  `liveSessionDivergedRefusal` defines and the
  `supervisionDivergedTests` "refusal text" case pins.

* Four commands (`status`, `demos`, `help`, `quit`) pass through
  the gate. The gate-table test pins which commands gate vs pass.

## Next slice (out of scope here)

The diverged state is currently terminal-by-design: there is no
operator gesture that re-opens the substrate. The agreed shape for
the follow-up is a new explicit `repair` command (not an overload
of `demo:KEY`); see the conversation thread on this note for the
rationale. That slice is not started yet.
