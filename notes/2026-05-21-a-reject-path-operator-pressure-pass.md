# Reject-path operator-pressure pass (2026-05-21)

Manual pass against the new `reject-preserving-smooth` fixture
([c19e0cc](#)). The point was to see the operator view under a real
`SupervisedReloadRequestRejected` — the only branch of the live
session shell that the deterministic suite could not cover, and the
one the resource-timeline observability slice
([5cc1eda](#)) was built for.

## Setup

```sh
stack exec -- metasonic-bridge \
  --session-osc-port 17005 \
  --manifest-live-session examples/manifests/reject-preserving-smooth.json \
  reject-preserving-smooth-dark \
  --strategy require-preserving
```

Driver (`/tmp/drive_reject_session.sh`, not committed) mirrors the
require-preserving wrapper's FIFO+exec stdin pattern. Sequence:

1. Wait for first prompt.
2. Send pre-reload OSC write (`/v0/lpf/0 = 0.75`).
3. Send `demo:reject-preserving-smooth-bright` on stdin.
4. Wait for `supervised outcome:` line, then `resource timeline:`.
5. Send `<Enter>` for status snapshot.
6. Send post-reject OSC write (`/v0/lpf/0 = 0.25`).
7. Close stdin (EOF), wait for clean exit.

## Result (transcript excerpt)

Pre-reload (auto-started voice, OSC accept):

```text
  initial: auto-starting one instance per template...
    drone -> enqueued CmdVoiceOn ... (VoiceKey "v0") []
  initial fan-in:
    audio running: yes
    active voices: 1
  ingress: open demo=reject-preserving-smooth-dark ... oscPort=17005

Type a command, or <Enter> for status, or <Ctrl-D> to exit:
  osc accept: CmdControlWrite voice=v0 tag=...lpf...slot=0 value=0.75
```

After `demo:reject-preserving-smooth-bright`:

```text
  supervised outcome: request-rejected (stack still on previous plan)
  reload events:
    - preserving phase started
    - resume old ingress: started
    - resume old ingress: succeeded
    - preserving phase rejected: reload-rejected (old owner still installed)
  cause: <13 KB single-line Show dump>
  resource timeline:
    - request rejected; stack stayed live
    - no supervisor rebuild
    - serving plan: reject-preserving-smooth-dark
```

Status snapshot after the reject:

```text
  status:
    current plan demo: reject-preserving-smooth-dark
    fan-in:
      audio running: yes
      owner status: SessionOwnerReady
      active voices: 1
    ingress: open demo=reject-preserving-smooth-dark ... oscPort=17005
    last outcome: request-rejected (stack still on previous plan)
```

Post-reject OSC accept (ingress survives the reject):

```text
  osc accept: CmdControlWrite voice=v0 tag=...lpf...slot=0 value=0.25
```

Clean exit on EOF; port released. Inner-cause evidence inside the
`Show` blob (relevant span only): `StepRuntimeFailed
SriHotSwapWouldPreserveVoices` — confirming the fixture mechanism
(KSmooth on the gain path makes the active voice
preserve-unsupported).

## What this proved

The supervised request-rejected contract holds end-to-end on the
real audio path:

- Initial open auto-starts a voice on a `PreserveUnsupported`
  template (KSmooth) and binds OSC ingress.
- `demo:<key>` enqueues a preserving hot-swap that the runtime
  rejects with `SriHotSwapWouldPreserveVoices`.
- Orchestration runs `resumeAfterFailure`, old ingress reopens, and
  the phase fails with `HpariReloadRejected`.
- `classifyPreservingOutcome` recognizes this as
  `InWindowReloadRejectedLiveFallback`; supervisor surfaces
  `SupervisedReloadRequestRejected`.
- Tracked-stack `IORef` is untouched; `currentPlanRef` stays on the
  old demo; status snapshot reports the original plan and voice
  count.
- OSC ingress accepts writes both before and after the reject.
- Resource timeline reads correctly: `request rejected; stack stayed
  live` / `no supervisor rebuild` / `serving plan: <old>`.

These are the same invariants the supervisor unit tests pin
deterministically (`AppManifestLiveSession.hs`), now observed in a
real session against real PortAudio + real OSC.

## What this surfaced — the headline finding

The `cause:` line printed by `runReloadWith` is **a single
13,112-character `Show`-derived dump** of the entire
`ManifestPreservingHotSwapReport`, including two complete
`TemplateGraph` records (one inside `mphsrCommand
CmdHotSwapPreservingOnly`, one inside `mphsrOwnerState`). Every
`RuntimeNode`, `RuntimeRegion`, `ResourceFootprint`, `BusFootprint`,
`BufferFootprint`, and `ResolveState` appears in full. The
operationally-useful needle in that haystack is
`SriHotSwapWouldPreserveVoices`, ~8 KB into the line.

Consequence in the transcript layout:

```text
  supervised outcome: ...    <- 1 line, useful
  reload events: ...         <- 4 short lines, useful
  cause: <13 KB blob>        <- 1 wrapped pseudo-line, dominant
  resource timeline: ...     <- 3 short lines, useful but BELOW the fold
```

The resource timeline is buried below the cause dump, which inverts
the readability the slice was supposed to deliver. This is the F-1
shape that the strategy-outcome renderer guards against
([AppManifestLiveReloadDemoRender.hs](../test/MetaSonic/Spec/AppManifestLiveReloadDemoRender.hs)
`renderHostPreservingIssueTag never leaks the carried issue
payload`), but the supervised cause-line path
([ManifestLiveSession.hs:runReloadWith](../app/MetaSonic/App/ManifestLiveSession.hs))
is a different site and is unguarded today: it calls `show cause`
directly on the `PreservingAdapterHostStackInWindowIssue` /
`HostPreservingReloadIssue` shape, whose `Show` instance recursively
unrolls the carried report.

## Next lane (closed by `13f3a8e` — see Follow-up below)

*Historical record of what this pass recommended at the time. The
compact-cause slice landed; see the Follow-up section for the
post-fix transcript and the current set of deferred lanes.*

Per the post-pass decision rubric, the lines being too noisy points
at **compact `renderCommand` / compact cause renderer for supervised
outcomes** as the next slice. Concrete shape sketch:

- Add a compact `renderSupervisedCause` (or
  `renderPreservingAdapterHostStackInWindowIssue`) helper to
  `ManifestReloadCli.hs`, parallel to
  `renderHostPreservingIssueTag`, that emits a one-line kebab path
  like `in-window: reload-rejected (StepRuntimeFailed
  SriHotSwapWouldPreserveVoices)` without leaking the report's
  `TemplateGraph`.
- Replace `putStrLn ("  cause: " <> show cause)` and `putStrLn ("  in-window
  cause: " <> show cause)` / `putStrLn ("  rebuild cause: " <> show
  rebuild)` in `runReloadWith` with the new helper.
- Extend the F-1 leak test to cover the new render path against the
  same probe / banned-substring pattern.

Other lanes deliberately deferred until that lands:

- Tier-2 reject wrapper. Premature test surface before the cause
  renderer is operator-friendly; the wrapper would have to assert on
  the noisy line. Reconsider after compact rendering lands.
- Richer recovery timeline for the `RejectedRecovered` /
  `Escalated` branches. Those branches did not fire in this pass;
  reach for them only if a future pass produces a transcript that
  shows the timeline is unclear in those shapes.
- GUI / control binding lane. Stdin felt fine in this pass;
  not the bottleneck today.

## Follow-up (2026-05-21, post-fix)

`13f3a8e` landed the compact supervised-cause renderer along the
lines sketched above. Five new route-specific renderers in
[`ManifestReloadCli.hs`](../app/MetaSonic/App/ManifestReloadCli.hs)
(`renderReloadHostStackOpenIssueTag`,
`renderPreservingHostStackIssueTag`,
`renderStoppedAudioHostStackIssueTag`,
`renderTryPreservingInWindowIssueTag`,
`renderTryPreservingHostStackIssueTag`); a `(e -> String)`
`causeLabel` threaded through `runReloadWith` / `sessionLoop` /
`runSupervised` / `runManifestLiveSession`, replacing the
`Show e =>` constraint; eleven F-1 leak tests in
[`AppManifestLiveReloadDemoRender`](../test/MetaSonic/Spec/AppManifestLiveReloadDemoRender.hs)
covering each constructor of each in-window arm plus the open arm,
all capped at 300 characters and banning `TemplateGraph` /
`RuntimeNode` substrings.

Re-running the same driver (`/tmp/drive_reject_session.sh`) against
the same fixture now produces:

```text
  supervised outcome: request-rejected (stack still on previous plan)
  reload events:
    - preserving phase started
    - resume old ingress: started
    - resume old ingress: succeeded
    - preserving phase rejected: reload-rejected (old owner still installed)
  cause: in-window: reload-rejected (old owner still installed)
  resource timeline:
    - request rejected; stack stayed live
    - no supervisor rebuild
    - serving plan: reject-preserving-smooth-dark
```

The `cause:` line dropped from **13,112 characters to 63** — a 99.5%
reduction. The outcome / events / cause / resource timeline block
now reads as a single contiguous operator narrative; the resource
timeline is no longer below the fold. The F-1 leak shape that this
pass surfaced is closed at the runReloadWith call site, and the
supervised-cause path now has the same kind of leak guard that
`renderHostPreservingIssueTag` has had since the strategy-outcome
F-1 slice.

The inner `SriHotSwapWouldPreserveVoices` reason is intentionally
*not* extracted into the cause line yet — the structural form
("in-window: reload-rejected (old owner still installed)") was the
v1 target. Drilling into `mphsrDrainResult →
SessionDrainItem → StepRuntimeFailed` to surface the runtime reason
is a future slice if a real pass shows the structural line is
insufficient.

### Lanes closed in this arc

- **Tier-2 reject wrapper** landed in `9b39fd2`:
  `tools/manifest_live_session_require_preserving_reject_smoke.sh`
  + `just manifest-live-session-require-preserving-reject-smoke`,
  default port 17005. Pins 23 markers covering the request-rejected
  operator narrative end-to-end — outcome name, reload events,
  compact `cause:` line, resource timeline (stack stayed live / no
  rebuild / serving old plan), post-reject status snapshot, and
  pre/post OSC survival — plus negative markers gating the
  classification (no supervised committed outcome / no preserving
  phase committed / no stopped-audio phase) and the F-1 leak guard
  at runtime (no `TemplateGraph` / `RuntimeNode` substring).

### Lanes still open

- **Richer recovery timeline** for the `RejectedRecovered` /
  `Escalated` branches. Still deferred — those branches did not
  fire in this pass, and recurring evidence of confusion is the
  trigger.
- **GUI / control binding lane** — still not the bottleneck;
  reach for it only after the CLI operator surface is exercised more
  broadly.

## Artifacts

- Driver: `/tmp/drive_reject_session.sh` (one-off, not committed)
- Full transcript: `/tmp/live-session-reject-transcript.txt`
- Fixture commit: `c19e0cc`
- Fixture drift guard: `b01cda6`
- Resource timeline observability slice: `5cc1eda`
- Preserving enqueue-rejected event slice: `5849efc`
- Compact supervised-cause renderer: `13f3a8e`
- Tier-2 reject wrapper: `9b39fd2`
  (`tools/manifest_live_session_require_preserving_reject_smoke.sh`;
  `just manifest-live-session-require-preserving-reject-smoke`)
