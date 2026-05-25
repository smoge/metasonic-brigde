## Long-Running Owner Supervision and Terminal-Divergence Recovery

Date: 2026-05-25

Status: design note. No constructors, no API changes. Scopes the
remaining open lane on the project ROADMAP — long-running owner
supervision and repair/recovery after terminal divergence —
deliberately as a policy decision frame, *before* any
implementation slice. The
[Stale Producer Command Semantics](2026-05-24-b-stale-producer-command-semantics.md),
[Manifest Reload Preflight Event Semantics](2026-05-25-a-manifest-reload-preflight-event-semantics.md),
and
[Allocation and Resource Recovery Event Semantics](2026-05-25-b-allocation-resource-recovery-event-semantics.md)
notes set the pattern: pin terminology, draw the state space, name a
concrete operator consumer, and frame the smallest first slice
before adding constructors. This note does the same for the
supervision lane, with one important twist — its valid conclusions
include "no new event families needed."

## Thesis

The landed v1 reload/event surface answers one question:

> *"What happened during the reload window?"*

For a bounded reload attempt that started against a live stack, the
operator now sees preflight events, reload events, audio events,
retired bindings, supervisor events, resource timeline, and a
status snapshot. That story is complete enough for v1.

This lane asks a structurally different question:

> *"What policy governs the system after a bounded reload leaves no
> usable live stack?"*

The two questions are not the same lane in disguise. The first is
visibility *during* a known operation; the second is *policy* once
the operation has ended in a state the existing reload contract
cannot describe.

## What the current code does today

Before listing decisions, pin the present-day behavior so the
design note has a concrete starting point.

* The terminal-divergence outcome is
  [`SupervisedReloadEscalated !e !e`](../app/MetaSonic/App/ManifestReloadSupervisor.hs#L126),
  carrying *two* payloads: the original in-window error and the
  rebuild error from `sopsOpenStack` against the captured fallback
  plan. Both fired in sequence inside one supervised attempt.
* The live session renders that as:

  ```text
    in-window cause: <renderedCause>
    rebuild cause:   <renderedCause>
  live session escalated: no live stack remains.
  ```

  The last line goes to **stderr**; the others are operator-facing
  through the configured output sink.
  ([`runReloadWithSink`](../app/MetaSonic/App/ManifestLiveSession.hs#L1479-L1483))
* [`stepFromOutcome SupervisedReloadEscalated`](../app/MetaSonic/App/ManifestLiveSession.hs#L516-L517)
  returns `(LsoEscalated, SsTerminate (ExitFailure 1))`. The
  session loop terminates with exit code 1; the operator is back
  at the shell.
* The `resource timeline:` projection for an escalated outcome is
  `[LsreTerminalRecoveringFromFallback, LsreClosedPreviousStack,
  LsreFallbackRebuildFailed, LsreNoLiveStack]`. That timeline
  prints, then the session exits.

The crucial fact: **today there is no live-session state called
"escalated, awaiting repair."** The session does not retain the
divergence; it exits. Any decision to keep the session alive after
escalation is a behavior change from the current contract.

## Up-front decisions

Three decisions need to be settled before any constructor or
runtime work. The recommended v1 answers below are the smallest
that close the lane without inviting policy bugs.

### 1. Supervision unit

**Recommended v1 answer: one-shot terminal-state reporting, not
long-running autonomous supervision.**

That means v1 should *model* — but not act on — the following
divergence categories:

* reload ended with no live stack (`SupervisedReloadEscalated`);
* old owner could not be restored (in-window failure already
  carried by the existing `Hpari* ResumeFailed` / `Hsari*` issues);
* fallback open failed (the rebuild half of
  `SupervisedReloadEscalated`);
* audio cannot be made live again after graph replacement
  (`SfaiStartFailed` / `SfaiReadyTimeout` inside the rebuild issue);
* ingress cannot reopen after the owner changed
  (`MrhiIngress`-carried failures inside the rebuild issue).

What v1 should *defer*:

* bounded retry loops (auto-retry with a maximum count);
* retry cooldowns (back-off, jitter, time-since-last-failure);
* automatic repair attempts (reopen audio, reopen ingress,
  re-acquire a fresh owner without operator action);
* persistent supervisor state across reload attempts (cross-run
  counters, escalation thresholds, "give up after N tries").

Rationale: each of those deferrals is a policy choice with real
blast radius. An auto-retry that races a half-open audio device
can leave PortAudio in an indeterminate state; a cooldown timer
that fires while the operator is mid-debug can swallow diagnostic
output; a persistent counter can mask a hardware fault that should
have been escalated. v1 should be exhaustively conservative: model
the terminal state, name it, render it, and *stop*. Autonomy is a
separate lane that needs its own design note when a real consumer
asks for it.

### 2. Authority boundary

**Recommended v1 answer: authority stays in
[`runManifestLiveSession`](../app/MetaSonic/App/ManifestLiveSession.hs).**

The live session can retain and display the terminal state and,
later, offer *explicit operator actions* (e.g. a `repair` command
that re-runs `realOpen` against a fresh plan, or a `quit` that
exits cleanly). It should not silently retry, take ownership of
production-style recovery policy, or run background repair work.

A watchdog *above* the session is a later design, because it
shifts ownership:

* it would decide when to retry,
* it would decide when to replace owners,
* it would decide when to reopen ingress,
* it would decide when to give up,
* it would need to interact with whatever surface (CLI, GUI,
  daemon) launches the session.

That is a much bigger commitment — different lifecycle, different
testability story, different blast radius on a bug. Not v1.

The current contract is "session exits on escalation." The
smallest v1 change that addresses the lane *without* taking on
watchdog responsibilities is: **keep the session loop alive after
`SupervisedReloadEscalated`, hold the terminal state alongside the
existing `lastOutcomeRef` / `trackedStackRef` refs — with
`trackedStackRef = Nothing` continuing to represent "no live
stack" (the supervisor already left it that way via
`hsfCloseStack`'s `finally`, and `printStatusWith` already renders
`(no live stack)` for that case) and a new explicit diverged-state
holder carrying the two escalation causes — and let `status` and a
future `repair` command read it.** No background tasks, no
automatic actions. The diverged-state holder is the only new
runtime state v1 adds; everything else reuses what is already
there.

### 3. Event-family discipline

**The note must explicitly say: graph allocation events and voice
allocation events are not assumed to be needed.**

This is the discipline that closed the preflight and audio-event
lanes cleanly: a new event family is only justified when a real
consumer asks for it. Apply that here:

* The existing `SupervisedReloadEscalated !e !e` payload carries
  the structured in-window and rebuild errors. The renderer in the
  live session can already pull `MrhiAudio (SfaiStartFailed n)` /
  `MrhiIngress ingressIssue` / `MrhiPlanning planningIssue` out of
  those payloads to say *which* sub-step failed.
* The existing `reload events:` block names the strategy
  transition that escalated.
* The existing `audio events:` block names the audio start/stop
  bracket that failed (when the rebuild reached audio at all).
* The existing `resource timeline:` already emits
  `LsreFallbackRebuildFailed` + `LsreNoLiveStack`.

A *valid* conclusion of this lane is: **existing surfaces are
enough; v1 needs no new event families.** The implementation slice
becomes a renderer + state-retention change, not a new event ADT.

`ManifestReloadGraphEvent` (graph allocation outcomes) and
`SessionVoiceAllocationEvent` (Haskell-side voice allocation)
remain real ideas, but adding them now would create a noisy event
surface without a clear user. If the implementation slice
identified by this note ends up wanting graph-level breakdown
("which allocation step of the fallback open failed?") that the
existing payloads cannot answer cleanly, *then* a graph-event
family is justified. Until then it stays deferred behind the same
consumer-gate the 2026-05-25-b note set.

## What v1 explicitly is *not*

* Not a bounded-retry policy. Auto-retry is its own lane.
* Not a watchdog above the session. Operator-driven repair only.
* Not new event ADTs unless the renderer slice proves a gap.
* Not a graph allocation event family. Consumer-gated.
* Not a voice allocation event family. Consumer-gated.
* Not a cross-run persistent supervisor. Per-run only.
* Not a GUI surface. The first consumer is the live-session
  stdin/stdout shell, same as the preflight and audio-event lanes.

## Likely v1 implementation slice (post-note)

This note is design-only. If it lands and the policy direction is
agreed, the smallest follow-up implementation slice would be:

**Keep the live-session loop alive after
`SupervisedReloadEscalated`, expose the terminal state through
`status`, and gate every subsequent operator command on the
divergence having been acknowledged or repaired.**

Concretely (sketch, not commitment):

1. Replace `stepFromOutcome SupervisedReloadEscalated → SsTerminate
   (ExitFailure 1)` with `SsContinue`. The stderr "no live stack
   remains" line stays as the immediate operator signal.
2. Add a new diverged-state IORef alongside the existing
   `trackedStackRef :: IORef (Maybe LiveStack)` (which the
   supervisor already left at `Nothing` after escalation via
   `hsfCloseStack`'s `finally`) holding the two escalation causes
   when present. Status reads both refs: a present diverged-state
   triggers a `no live stack: repair required` block carrying the
   in-window and rebuild causes, and the existing `(no live
   stack)` rendering for `trackedStackRef = Nothing` continues to
   work unchanged on the never-opened path.
3. Wire the existing reload command (`demo:KEY`) to refuse while
   in the diverged state (or, more usefully, to interpret a reload
   as a *repair attempt* that calls into the substrate's
   `realOpen` rather than the supervised reload path — but that
   bigger choice belongs in the slice's own scoping turn).
4. Manual smoke: force an escalation by reloading to a plan whose
   `realOpen` fails (e.g. an unavailable PortAudio device), record
   the resulting transcript showing the session staying alive with
   the terminal state visible in `status`.
5. Decide *then* whether anything in the slice surfaced a real
   need for `ManifestReloadGraphEvent`. If yes, promote that to a
   follow-up slice with concrete operator output. If no, the lane
   closes without new event families.

## How this leaves the ROADMAP

The remaining open ROADMAP bullet —

> Long-running owner supervision, teardown beyond the scoped
> bracket, and repair/recovery after terminal divergence.

— would, after this note, read as: *v1 is one-shot terminal-state
reporting inside the live session, with no autonomous supervision,
no watchdog, and no new event families unless a renderer slice
proves a real gap. Implementation deferred to a follow-up slice
that keeps the live-session loop alive past
`SupervisedReloadEscalated`.* The bullet stays unchecked until
that slice lands.
