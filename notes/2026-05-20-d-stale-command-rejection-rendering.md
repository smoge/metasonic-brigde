# Stale-Command Rejection Rendering: Reload-Window OSC Visibility

Date: 2026-05-20 (design); 2026-05-21 (landed)

Status: **landed at the deterministic level**. Implementation split into
two commits per the design plan:

* `144901f` adds the pure renderer helpers
  (`renderOSCAcceptLine :: OSCProducerEnqueueResult -> Maybe String`,
  `renderOSCIssueLine :: ManifestOSCListenerIssue -> String`) plus
  the focused test module
  `MetaSonic.Spec.AppManifestLiveCommonOSCRender` (13 cases: 6 issue-
  line rows, 4 accept-line rows, 3 synthetic listener fan-out
  composition tests). At this point the helpers exist as a parallel
  testable surface; the legacy `renderOSCAccept` /
  `renderOSCIssue` pair is still wired into `liveOSCListenerHooks`
  and still double-prints rejected packets.
* `737b124` wires `liveOSCListenerHooks` to the new helpers
  (`molhOnAccepted` becomes
  `mapM_ (putStrLn . ("  " <>)) . renderOSCAcceptLine` so a
  `Nothing` return on a `SessionEnqueueRejected` inner result is a
  natural no-op; `molhOnIssue` routes through `renderOSCIssueLine`)
  and deletes the legacy private pair. Net diff: -37 / +22.

The 13 deterministic cases now exercise the actually-wired hooks
rather than a parallel surface. Full suite 1306/1306;
`git diff --check` clean. The reload-window rejection line is
`osc reject (reload-window): <cmd>`; the previous double-print is
structurally impossible because the `Maybe` return on
`renderOSCAcceptLine` encodes the dedup at the type level.

What this slice still does **not** address: the
`MrePreservingReloadEnqueueRejected` consumer surface (the second
half of the v0 note's "Stale-command semantics" bullet), tier-2
runbook capture (deferred until an operator actually catches the
line during a real session — the wrapper grep contract for the four
existing wrappers is unchanged), and the verbose `renderCommand`
payload follow-up. See the Out-of-scope section below.

This note scopes the first Phase 8 / live-session productization slice
flagged by the recent narrative checkpoint at
[2026-05-20-c-compiler-runtime-to-live-system.md](2026-05-20-c-compiler-runtime-to-live-system.md)
and the "What this slice does NOT do" list in the live-session v0 note at
[2026-05-20-b-manifest-live-session-v0.md (line 179)](2026-05-20-b-manifest-live-session-v0.md).

## Problem

The `--manifest-live-session` operator surface accepts OSC writes
continuously, including during a supervised reload. When a packet
arrives during the reload window, after the supervisor has flipped
`sfihsReloadStatus` to `SessionFanInReloadInProgress` but before the
new owner has been installed, the host-level enqueue gate rejects it
with `SessionEnqueueRejected _ cmd SeiReloadInProgress`.

Today the live session renders that rejection identically to any other
queue-side enqueue failure:
`osc enqueue-reject: CmdControlWrite ... issue=...`. Manifest-side
rejections already have their own `osc reject (manifest): ...` line,
but the queue-side line does not distinguish a normal enqueue failure
(`SeiQueueFull`, `SeiSessionUnavailable`) from the expected transient
reload-window rejection (`SeiReloadInProgress`). Worse, see the
investigation finding below, the same rejected packet currently prints
**twice**.

## Current Surfaces

Three files cooperate to produce the rendered line:

- [src/MetaSonic/Session/FanIn.hs:354-380](../src/MetaSonic/Session/FanIn.hs#L354-L380):
  `enqueueSessionFanInCommand` checks `sfihsReloadStatus` and produces
  `SessionEnqueueRejected _ _ SeiReloadInProgress` when reload is in
  progress.
- [app/MetaSonic/App/ManifestOSCListener.hs:136-162](../app/MetaSonic/App/ManifestOSCListener.hs#L136-L162):
  `processManifestOSCPacket` parses, projects, submits, and dispatches
  to hooks. The double-fire issue lives here.
- [app/MetaSonic/App/ManifestLiveCommon.hs:445-475](../app/MetaSonic/App/ManifestLiveCommon.hs#L445-L475):
  `liveOSCListenerHooks`, `renderOSCAccept`, and `renderOSCIssue`
  collapse the listener events into the operator-facing text.

## Investigation findings

Both load-bearing questions were code-readable before any edit. The
answers materially reshape the implementation plan, so they are part
of this note rather than left to discover during the slice.

**1. Is `SeiReloadInProgress` actually reachable from the live OSC
path during reload?** Yes. The chain is `processManifestOSCPacket` ->
`submitManifestOSCMessage` -> `enqueueOSCControlWrite` ->
`enqueueSessionFanInCommand producer cmd host`, which inspects
`sfihsReloadStatus` directly and produces
`SessionEnqueueRejected producer cmd SeiReloadInProgress` when the
host is in `SessionFanInReloadInProgress`. The host-level gate is
reachable without routing through the `SessionFanInService` wrapper.
No ingress wiring change is needed; the slice is rendering-only.

**2. Do `molhOnAccepted` and `molhOnIssue` both fire for the same
packet on enqueue rejection?** Yes.
[processManifestOSCPacket](../app/MetaSonic/App/ManifestOSCListener.hs#L136-L147)
calls both unconditionally for any manifest-accepted packet:

```haskell
Right producerResult -> do
  molhOnAccepted hooks producerResult
  reportProducerEnqueue (molhOnIssue hooks) producerResult
```

And `reportProducerEnqueue` calls `molhOnIssue (MoliEnqueueRejected
cmd issue)` whenever the inner `SessionEnqueueRejected` shows up.
Looking at the two renderers in `ManifestLiveCommon.hs`:

- `renderOSCAccept`'s `SessionEnqueueRejected` arm renders `"osc
  enqueue-reject: <cmd> issue=<issue>"`.
- `renderOSCIssue`'s `MoliEnqueueRejected cmd queueIssue` arm renders
  the same `"osc enqueue-reject: <cmd> issue=<queueIssue>"`.

Both fire for the same packet, both print, with identical content.
**The live session prints two identical `osc enqueue-reject` lines
per rejected packet today.** Pre-existing bug, independent of the
reload-window classification work, but the slice has to fix it.

## Contract

After the slice, each rejected packet produces **exactly one**
operator-facing line, classified by the underlying cause:

```text
osc accept:                 CmdControlWrite voice=v0 ...           (SessionEnqueued)
osc reject (parse):         <decoder error>
osc reject (manifest):      <tag absent from current manifest>
osc reject (reload-window): CmdControlWrite voice=v0 ...           (SeiReloadInProgress)
osc enqueue-reject:         CmdControlWrite voice=v0 ... issue=... (other SessionEnqueueIssue)
```

The `(reload-window)` label fits the existing `(parse) / (manifest)`
taxonomy. `osc enqueue-reject` stays as the catch-all for non-reload
enqueue rejections (`SeiSessionUnavailable`, future variants); the
`issue=` suffix stays on it because it covers multiple causes. The
`(reload-window)` line drops `issue=` because the label already names
the cause.

**`SeiSessionUnavailable` mid-rebuild stays generic.** During a
Terminal in-window outcome the host briefly sits in
`SessionFanInReloadFailed` between `sopsCloseStack` and
`sopsOpenStack`, and any OSC arrival in that window surfaces as
`SessionEnqueueRejected _ _ SeiSessionUnavailable`. Those packets are
**not** the "expected transient" case the new label is for: the
session genuinely had no live owner at that instant. They keep the
generic `osc enqueue-reject: ... issue=SeiSessionUnavailable`
rendering. Same applies to the `SessionFanInNormalOperation, Nothing`
arm of `enqueueSessionFanInCommand` (rare; means no owner installed).
Distinguishing those cases is a future slice if operator demand
surfaces.

This remains an operator-rendering contract, not a reload-orchestrator
event contract. Do **not** add a `ManifestReloadEvent` constructor for
this slice: the packet event is concurrent ingress activity, while
`ManifestReloadEvent` is the reload transition timeline emitted by the
strategy/orchestrator path. A future UI event stream can unify those
views if a real consumer needs it.

## Implementation plan

Single render-layer commit. No listener-API change, no ingress
rewiring, no `ManifestReloadEvent` change.

In `ManifestLiveCommon.hs`:

1. Introduce exported, pure line renderers for the OSC listener surface,
   for example:
   - `renderOSCAcceptLine :: OSCProducerEnqueueResult -> Maybe String`
   - `renderOSCIssueLine :: ManifestOSCListenerIssue -> String`

   The `Maybe` on the accepted side is the dedup policy: parser +
   manifest acceptance is still observable through the hook contract,
   but it does not necessarily imply an operator-facing `osc accept:`
   line.
2. `liveOSCListenerHooks.molhOnAccepted` only `putStrLn`s a line when
   `renderOSCAcceptLine` returns `Just`. For
   `OSCProducerEnqueueAttempted _ enqueue` whose inner result is
   `SessionEnqueueRejected`, it returns `Nothing` because `molhOnIssue`
   owns rejection rendering.
3. `renderOSCAcceptLine` returns:
   - `Just "osc accept: <cmd>"` for `SessionEnqueued`;
   - `Nothing` for `SessionEnqueueRejected`;
   - a defensive `Just "osc reject (decode): ..."` for
     `OSCProducerDecodeRejected`, even though the manifest listener's
     normal path pre-decodes before the producer call.
4. `renderOSCIssueLine`'s `MoliEnqueueRejected cmd queueIssue` arm
   splits:
   - `queueIssue == SeiReloadInProgress` produces
     `"osc reject (reload-window): <cmd>"`;
   - any other `queueIssue` keeps the current generic shape:
     `"osc enqueue-reject: <cmd> issue=<queueIssue>"`.

`processManifestOSCPacket` in `ManifestOSCListener.hs` stays unchanged.
The double-fire is resolved at the renderer site, not at the listener
hook contract. This preserves any other downstream consumer of
`molhOnAccepted` that might want its existing "I saw it, here is what
happened" semantics. A future consumer that wants to surface accept +
enqueue-rejected on separate channels still has that option through
the unchanged listener API.

Exporting these helpers is intentional. They are not a new public
runtime API; they are a testable operator-string contract shared by
`--manifest-live-session` and `--manifest-live-reload-demo`.

## Tests / exit criteria

Deterministic tests, no live IO:

1. **Issue renderer table.** `renderOSCIssueLine` rows covering
   `MoliParseFailure`, `MoliManifestIssue`, `MoliEnqueueRejected _
   SeiReloadInProgress`, and `MoliEnqueueRejected _ <non-reload
   variant>`. Pin each rendered string exactly so the wrapper grep
   contract is explicit.
2. **Accepted renderer table.** `renderOSCAcceptLine` rows covering
   `SessionEnqueued` (`Just "osc accept: ..."`),
   `SessionEnqueueRejected _ _ SeiReloadInProgress` (`Nothing`), and
   one non-reload `SessionEnqueueRejected` (`Nothing`). This pins the
   dedup behavior without stdout capture.
3. **Synthetic one-packet composition.** A tiny pure helper in the
   test can model the current listener fan-out:

   ```haskell
   maybeToList (renderOSCAcceptLine producerResult)
     ++ [ renderOSCIssueLine issue
        | Just issue <- [enqueueIssueFromProducerResult producerResult]
        ]
   ```

   For a synthesized reload-window rejection, the composed output must
   contain exactly one line:
   `osc reject (reload-window): <cmd>`.

If a future implementation does change `processManifestOSCPacket`
instead of the render site, add a listener-level regression test then.
For this slice, the pure renderer/composition checks are the sharper
contract and avoid brittle stdout capture.

No tier-2 wrapper assertion this slice. Triggering a reload-window OSC
arrival deterministically from a wrapper is a real-time race: the
operator wrapper sends OSC at known points in the script, and there is
no clean way to guarantee the packet lands inside the reload window.
Once an operator catches the line during a real session, transcript +
runbook update lands in
[notes/2026-05-19-b-manifest-host-reload-smoke-runbook.md](2026-05-19-b-manifest-host-reload-smoke-runbook.md)
under whichever supervised section the operator was running. Until
then, deterministic tests are sufficient evidence.

**Tier-2 wrapper compatibility.** Verified before drafting this note:
none of the four existing tier-2 wrappers
(`manifest_supervised_live_smoke.sh`,
`manifest_supervised_try_preserving_live_smoke.sh`,
`manifest_supervised_require_preserving_live_smoke.sh`,
`manifest_live_session_require_preserving_smoke.sh`) grep on the
`osc enqueue-reject` shape. The OSC-related markers grep on
`value=0.75` / `value=0.25` against the `osc accept: ...` line, which
still fires unchanged for the committed-enqueue path. The slice
changes only the rejection-rendering surface, so no wrapper update is
needed in the same commit.

## Out of scope

Hard non-goals for this slice; named here so review residue stays
small.

- **Allocation/recovery event timeline rendering.** Separate slice,
  next in the Phase 8 / live-session lane after this one lands.
- **`MrePreservingReloadEnqueueRejected` consumer surface.** The v0
  note's "Stale-command semantics" bullet at
  [2026-05-20-b-manifest-live-session-v0.md (line 179)](2026-05-20-b-manifest-live-session-v0.md)
  names *two* deferred items: producer-aware OSC enqueue rejection
  rendering (this slice resolves it) AND a richer
  `MrePreservingReloadEnqueueRejected` consumer surface beyond the
  existing `renderLiveReloadEvents` timeline (this slice does NOT
  resolve it). Those two timelines are separate concerns: the OSC
  packet event is concurrent ingress activity; the preserving event
  is internal to the hot-swap's queueing. Closing the second half is
  its own future slice.
- **Producer-aware coalescing/throttling.** Listed in the ROADMAP's
  session policy lane around line 3778, gated on session pressure that
  has not surfaced yet.
- **Listener hook API change.** `molhOnAccepted` keeps its current
  semantics; the dedup is at the renderer site only.
- **Stdout-capture test helpers.** The contract should be pinned at the
  pure renderer layer. Capturing stdout from `liveOSCListenerHooks`
  would test buffering mechanics more than policy.
- **Compact `renderCommand` payload.** The current
  `CmdControlWrite voice=v0 tag=ControlTag {ctNodeTag = MigrationKey
  {unMigrationKey = "lpf"}, ctSlot = 0} value=0.75` shape is verbose,
  and a burst of reload-window rejections will render as a wall of
  long lines. A compact form (e.g.
  `/v0/lpf/0=0.75 (reload-window)`) would help, but `renderCommand` is
  shared by every line and changing it touches the broader operator
  surface. Out of scope here; promote to its own slice if an operator
  asks for it after a real session.
- **`--manifest-live-reload-demo` rendering changes.** The two-shot
  demo shares the same `ManifestLiveCommon` renderer surface, so the
  fix and the `(reload-window)` classification automatically improve
  its timeline too. No additional work; the commit message should
  mention the spillover.

## Commit shape

One commit: `Render reload-window OSC rejection distinctly; fix
listener double-print`.

Touches:

- `app/MetaSonic/App/ManifestLiveCommon.hs` (renderer + hook
  adjustment + test-facing renderer exports);
- `test/MetaSonic/Spec/AppManifestLiveCommonOSCRender.hs` (new focused
  test module);
- `test/Spec.hs` (register the new test group);
- `package.yaml` (add the new test module; let hpack regenerate the
  `.cabal` file).

If the implementation instead extends the existing
`AppManifestLiveSession` tests, the test-module wiring disappears, but
the focused module is the cleaner shape because `ManifestLiveCommon`
is shared by both live entrypoints. Suite grows by roughly 5-6
deterministic cases.
