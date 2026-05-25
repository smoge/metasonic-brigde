## Stale Producer Command Semantics During Live Reload

Date: 2026-05-24

Status: design note + implementation log. Scopes one of the open
lanes from the
[ManifestReloadEvent Partial Coverage](2026-05-19-a-manifest-reload-event-partial-coverage.md)
closeout: "stale producer commands". Pins terminology, draws the
state space, and names what each implementation slice needs to
render and to test.

**Slice 1 landed in `8a4a1d7`** — retired voice bindings flow
through both `MrePreservingReloadCommitted` and
`MreStoppedAudioReloadCommitted` event payloads. The "Plumbing the
projection out" section below now describes the as-built shape; the
"Carry the retired set" section names the `RetiredVoiceBinding` /
`RetiredVoiceReason` types that landed in
[`MetaSonic.Session.Resolve`](../src/MetaSonic/Session/Resolve.hs).

Slice 2 keeps the pure renderer/extractor contract separate from the
caller that prints it. The current slice adds
`retiredBindingsFromEvents`, `renderRetiredBindings`, and
`renderRetiredVoiceReason` in
[`MetaSonic.App.ManifestLiveCommon`](../app/MetaSonic/App/ManifestLiveCommon.hs),
with deterministic tests in
[`AppManifestLiveCommonRetiredBindings`](../test/MetaSonic/Spec/AppManifestLiveCommonRetiredBindings.hs).
`runReloadWithSink` in
[`MetaSonic.App.ManifestLiveSession`](../app/MetaSonic/App/ManifestLiveSession.hs)
then prints the `retired bindings:` block next to `reload events:`
whenever a commit payload exists. Slice 3 (stale-by-reload
attribution) remains open.

The driving consumer is
[`runManifestLiveSession`](../app/MetaSonic/App/ManifestLiveSession.hs).
Its module header explicitly defers stale-command semantics: "No new
event streams (allocation, stale-command)" and "every \"consumer-gated\"
decision downstream (resource/allocation event streaming, stale-command
semantics, GUI bindings) is being made in the abstract. This entrypoint
is what those decisions get tested against next."

## What "stale" means here

A producer command (`SessionCommand` from
[Session.Command](../src/MetaSonic/Session/Command.hs)) is *stale by
reload* when its admission outcome differs *because of a reload that
happened between when the producer formed the command and when fan-in
admitted it*. The reload is the proximate cause; absent the reload the
command would have been admitted, or vice versa.

This is narrower than the existing `SiStaleVoice` issue. `SiStaleVoice`
fires from [`admitSessionCommand`](../src/MetaSonic/Session/State.hs)
whenever a `CmdVoiceOff` / `CmdControlWrite` names a voice that is not
in `ssVoices`. That can happen for reasons that have nothing to do
with a reload (the producer never started the voice, the voice was
already stopped, etc.). Today there is no way for an operator to tell
"the voice key was never live" apart from "the binding was retired by
the reload that just committed."

## The reload windows that exist today

There are three distinct admission gates a command can hit, and they
already differ in which reload phase activates them.

### 1. Fan-in host gate (stopped-audio reload only)

[`enqueueSessionFanInCommand`](../src/MetaSonic/Session/FanIn.hs)
inspects `sfihsReloadStatus`. During `SessionFanInReloadInProgress` /
`SessionFanInReloadFailed` every enqueue is rejected with
`SeiReloadInProgress` / `SeiSessionUnavailable`. The host enters
`SessionFanInReloadInProgress` *only* via
`reloadSessionFanInHostOwnerStoppedAudio`, which itself requires
`queueDepth == 0`. So:

* In a stopped-audio reload, the queue is forced empty before the
  window opens, and every new enqueue is reload-window-rejected.
* In a preserving reload, this gate is **not** taken — the fan-in host
  stays in `SessionFanInNormalOperation` throughout the swap.

### 2. Fan-in service ingress gate (both reload types)

[`withServiceIngress`](../src/MetaSonic/Session/FanInService.hs) wraps
service-level enqueues. `quiesceAndDrainSessionFanInService` flips the
ingress to `Quiesced`, drains pending work, and then the orchestrator
runs the swap. While quiesced, service-level enqueues return a
synthetic `SessionEnqueueRejected … SeiReloadInProgress`. Raw host
enqueues via `sessionFanInServiceHost` bypass this gate; concrete
producers are expected to be quiesced upstream.

### 3. Admission against `SessionState` (always)

[`admitSessionCommand`](../src/MetaSonic/Session/State.hs) is the only
gate that ever fires `SiStaleVoice` or `SiUnknownTemplate`. It runs
inside the fan-in drain after the command leaves the queue and the
owner is asked to commit it. Its view is whatever `SessionState` the
current owner holds — i.e. it changes the instant
`CommitGraphInstalled` is applied.

The fact that admission runs *after* enqueue is load-bearing here:
commands that survived the pre-swap drain hit admission against the
old state; commands that arrived after the swap commit hit admission
against the new state.

## Outcome categories for one command crossing a reload

For one command formed by an OSC/MIDI/UI/Pattern producer relative to
a single reload event, the possible outcomes are:

1. **Pre-swap drain-success.** Enqueued before quiesce. Drains and
   commits against the *old* `SessionState`. The reload had no causal
   effect on this command. No "stale" event needed.
2. **Reload-window service-reject.** Arrived after
   `closeSessionFanInServiceIngress` but before
   `resumeSessionFanInService`. Service-level enqueue returns
   `SeiReloadInProgress`. Never reaches the queue.
3. **Reload-window host-reject (stopped-audio only).** Same window as
   (2) but the producer used the raw host path. Host enqueue returns
   `SeiReloadInProgress` / `SeiSessionUnavailable`. Never reaches the
   queue.
4. **Post-swap admission-success.** Arrived after the service ingress
   reopened. Enqueued, drained, admitted against the *new* state, and
   commits. Not stale.
5. **Post-swap admission-reject by retired voice key.** Arrived
   after reopen. Enqueued, drained, but the `VoiceKey` it names
   was *retired by this reload*. Admission rejects with
   `SiStaleVoice`, indistinguishable today from a producer error.
   The retired-set source depends on the reload path:

   * **Preserving:** the key appears in one of the
     `ResolveRebuildIssue` entries in `rrrDropped` on the
     `ResolveRebuildResult` produced at commit by
     [`commitGraphInstalled`](../src/MetaSonic/Session/State.hs#L225).
     Surviving bindings stay live in the new `ssVoices`.
   * **Stopped-audio:** every key in the pre-reload `ssVoices` is
     retired.
     [`reloadSessionFanInHostOwnerStoppedAudio`](../src/MetaSonic/Session/FanIn.hs#L656)
     releases the old owner and acquires a fresh one with
     `initialSessionState`; there is no `commitGraphInstalled` call
     and no `ResolveRebuildResult`. The retired set is whatever was
     in the old owner's `ssVoices` immediately before release.

(1)–(4) are already named in the existing vocabulary. (5) is the
single gap this note exists to scope.

There is a structurally adjacent case that is *not* covered here:
`CmdVoiceOn tname …` admitted against a `TemplateGraph` that no longer
carries `tname` produces `SiUnknownTemplate`. The retired set for
template-name attribution is a different projection — the set
difference between the old and new graph's templates — and a
`CmdVoiceOn` never has a pre-existing `VoiceKey` to look up in
`rrrDropped`. Template-name attribution is therefore a separate v2
lane, named in [Out of scope](#out-of-scope-for-this-note) below.

A sixth case — *pre-swap admitted command that names a voice the swap
will retire* — collapses into (1): the command runs against the old
state and commits before the swap. The reload retires the binding
afterwards. The reload's `rrrDropped` already documents that the
binding existed and was dropped; the producer command itself is not
stale.

## The gap, concretely

Slice 1 (`8a4a1d7`) landed the structured retired-binding payload on
the reload commit events. The operator-visible breadcrumb is now:

* The fan-in drain emits a `SessionRejected cmd SiStaleVoice` record
  into producer-local rejection paths (e.g. `submitManifest*`
  consumer issue types).
* The reload emits
  `MrePreservingReloadCommitted ![RetiredVoiceBinding]` /
  `MreStoppedAudioReloadCommitted ![RetiredVoiceBinding]` carrying
  the bindings the reload dropped.
* The pure render surface now exists in `ManifestLiveCommon`:
  `retiredBindingsFromEvents` extracts the most recent commit
  payload, `renderRetiredVoiceReason` pins stable reason labels, and
  `renderRetiredBindings` renders the `(none)`, per-binding, and
  stopped-audio summary rows.
* `runReloadWithSink` prints those rows under a `retired bindings:`
  header after the existing `reload events:` block when the timeline
  contains a commit event.

The remaining gap for stale-command attribution (slice 3): an
operator still cannot answer "was this `SiStaleVoice` caused by the
reload I just ran?" without manually correlating the rejection
against the recent retired-binding payload. Slice 3 wires that
attribution end-to-end.

Each reload path knows its retired set at a different point. Slice
1 wired both into the structured `rrrRetired` /
`SessionFanInReloadReport.sfirrRetired` projections; the timeline of
how those values are built remains useful for slice 2 / slice 3
context:

* **Preserving:** the hot-swap commit produces `rrrDropped ::
  [ResolveRebuildIssue]` plus `rrrRetired :: [RetiredVoiceBinding]`
  ([Resolve.hs:77](../src/MetaSonic/Session/Resolve.hs#L77)) in
  input order — `RriMissingTemplate vkey tname` for bindings whose
  template vanished, `RriInvalidVoiceKey vkey dispatchIssue` for
  keys the new graph's dispatcher refused. `applyPlannedCommit`
  returns the `ResolveRebuildResult` alongside the new state; slice
  1 threads `rrrRetired` up through the drain, the preserving
  host op, and `MrePreservingReloadCommitted`.
* **Stopped-audio:** the retired set is the *entire* old
  `ssVoices`.
  [`reloadSessionFanInHostOwnerStoppedAudio`](../src/MetaSonic/Session/FanIn.hs#L656)
  snapshots the old owner's voice map *before* `releaseSessionOwner`
  and forwards it as `sfirrRetired`, threaded up through
  `msarrRetired` and `MreStoppedAudioReloadCommitted`. Each entry
  carries `RvrOwnerReplaced`.

## Implemented shape (slice 1, `8a4a1d7`)

The actual type contract that landed:

### Carry the retired set onto the reload event

`MrePreservingReloadCommitted` and `MreStoppedAudioReloadCommitted`
should both carry a `[RetiredVoiceBinding]` projection — a shared
shape with three reasons spanning the two paths:

```haskell
data RetiredVoiceBinding = RetiredVoiceBinding
  { rvbBinding :: !VoiceBinding
  , rvbReason  :: !RetiredVoiceReason
  } deriving stock (Eq, Show)

data RetiredVoiceReason
  = RvrTemplateGone               -- preserving: RriMissingTemplate
  | RvrInvalidVoiceKey !DispatchIssue
                                  -- preserving: RriInvalidVoiceKey
  | RvrOwnerReplaced              -- stopped-audio: old owner released
  deriving stock (Eq, Show)
```

`rrrDropped` alone is *not* that projection on the preserving path.
It is `[ResolveRebuildIssue]`, and the `RriInvalidVoiceKey`
constructor carries only the `VoiceKey` and a `DispatchIssue` — no
template name. The operator render below assumes a "template"
column for every retired row, which means the implementation must
thread the originating `VoiceBinding` through. `commitGraphInstalled`
has it: `previewResolveRebuild` is called with
`M.elems (ssVoices st)`, so the binding and the dropping issue are
paired on the same iteration inside
[`rebuildResolveState`](../src/MetaSonic/Session/Resolve.hs#L97).

On the stopped-audio path the projection is even simpler: every
old binding becomes a `RetiredVoiceBinding _ RvrOwnerReplaced`. No
issue join is needed; the snapshot is the input.

### Plumbing the projection out (slice 1 as-built)

Slice 1 widened the op-success types and event constructors so a
single `[RetiredVoiceBinding]` flows from the reload commit out to
the event emitter. Each path is wired below; both converge at the
commit event regardless of which reload path ran.

**Preserving.** The drain plumbs the rebuild result all the way
down to the host op's drain report.
`applyPlannedCommit` returns `Maybe ResolveRebuildResult` alongside
the new state ([State.hs:179](../src/MetaSonic/Session/State.hs#L179)),
`stepSessionCommand` packages that into
`StepCommitted !SessionState !(Maybe ResolveRebuildResult)`
([Step.hs:60](../src/MetaSonic/Session/Step.hs#L60)), the drain
carries it as `SessionDrainItem` ([Queue.hs:155](../src/MetaSonic/Session/Queue.hs#L155)),
and `ManifestPreservingHotSwapReport` retains the whole drain
result as `mphsrDrainResult`
([ManifestReload/Runtime.hs:68](../src/MetaSonic/Session/ManifestReload/Runtime.hs#L68)).

Slice 1 then wires three sites:

1. `mapPreservingReloadReport`'s `classifySessionStep` returns
   `Right (rrrRetired rebuild)` for `StepCommitted _ (Just rebuild)`
   ([ManifestReloadHost.hs:673-689](../app/MetaSonic/App/ManifestReloadHost.hs#L673-L689)).
2. `hproReloadPreserving` success type is
   `plan -> IO (Either (HostPreservingReloadFailure issue) [RetiredVoiceBinding])`
   ([Types.hs:135](../app/MetaSonic/App/ManifestReloadOrchestration/Types.hs#L135)).
3. `MrePreservingReloadCommitted ![RetiredVoiceBinding]` is emitted
   by the orchestrator's `finishOk` from the threaded value
   ([ManifestReloadOrchestration.hs:276-278](../app/MetaSonic/App/ManifestReloadOrchestration.hs#L276-L278)).

**Stopped-audio.** The retired set never enters the drain — the old
owner is released wholesale — so slice 1 adds plumbing at every
layer:

1. `reloadSessionFanInHostOwnerStoppedAudio` snapshots the old
   owner's `ssVoices` *before* `releaseSessionOwner`, maps it to
   `[RetiredVoiceBinding _ RvrOwnerReplaced]`, and returns it via
   the new `sfirrRetired` field on `SessionFanInReloadReport`
   ([FanIn.hs:261-269](../src/MetaSonic/Session/FanIn.hs#L261-L269),
   snapshot at [FanIn.hs:691-703](../src/MetaSonic/Session/FanIn.hs#L691-L703)).
2. `ManifestStoppedAudioReloadReport`
   ([ManifestReload/Runtime.hs:53-69](../src/MetaSonic/Session/ManifestReload/Runtime.hs#L53-L69))
   has `msarrRetired :: [RetiredVoiceBinding]` and
   `reloadManifestSessionStoppedAudio` forwards from `sfirrRetired`.
3. `hsaroReloadStopped` success type is
   `plan -> IO (Either (HostStoppedAudioReloadFailure issue) [RetiredVoiceBinding])`
   ([Types.hs:47](../app/MetaSonic/App/ManifestReloadOrchestration/Types.hs#L47)).
   The concrete `reloadStopped` in
   [ManifestReloadHost.hs:219-229](../app/MetaSonic/App/ManifestReloadHost.hs#L219-L229)
   returns `Right (msarrRetired report)`.
4. `MreStoppedAudioReloadCommitted ![RetiredVoiceBinding]` is
   emitted by the orchestrator's `finishOk` from the threaded
   value, mirroring the preserving change.

The two paths converge at the event: a single `[RetiredVoiceBinding]`
flows to any future attribution layer regardless of which reload
happened. Slice 2 renders this list in the live-shell reload output.
Slice 3 attributes `SiStaleVoice` rejects against it.

### Attribute admission rejections to the reload window

A producer command whose admission rejects with `SiStaleVoice` *and*
whose `VoiceKey` appears in the most recent reload's retired set
should be attributed to the reload. v1 scopes this to voice-key
attribution only:

```haskell
data SessionFanInServiceIssue
  = …
  | SfsiiCommandStaleByReload
      !ProducerId
      !SessionCommand
      !VoiceKey            -- the retired key the command named
      !RetiredVoiceReason  -- why it was retired
      !SwapLabel           -- which reload retired it
```

`SiUnknownTemplate` is deliberately not in this constructor — see
[Out of scope](#out-of-scope-for-this-note).

The attribution window is bounded — once another reload runs, the
previous retired set no longer applies. A small per-host "last
retired set" snapshot is enough; nothing needs to be persistent.

### Distinguish reload-window rejects from producer errors

Outcomes (2) and (3) are already encoded as `SeiReloadInProgress` /
`SeiSessionUnavailable`. The current producer-facing render just
echoes the issue tag. A reload-window-aware render should label them
explicitly so the operator does not see "queue rejected" for a
command that was structurally fine and merely arrived during a swap.

### Out of scope for this note

* No `SiUnknownTemplate` attribution. `CmdVoiceOn`-against-a-removed
  template needs a different retired set (the diff of old vs new
  `tgTemplates`, keyed by `TemplateName`) and a different rendered
  row shape ("template X was removed by this reload"). The mechanism
  is a clean analog of voice-key attribution but builds on a
  template-name retirement record that `commitGraphInstalled` does
  not compute today. v2 lane.
* No new realtime queue, no new FFI surface, no audio-thread work.
  Attribution is entirely a Haskell-side correlation between admission
  and the most recent reload's retired set.
* No producer replay / retry. Stale-by-reload is a terminal outcome
  for that command; the producer chooses whether to re-form it.
* No cross-run stale tracking. Attribution is per-reload; once the
  next reload runs, the previous retired set is forgotten.
* No GUI surface. The first consumer is the
  [`runManifestLiveSession`](../app/MetaSonic/App/ManifestLiveSession.hs)
  stdin sink and `--manifest-host-reload-smoke` CLI render in
  [`ManifestReloadCli`](../app/MetaSonic/App/ManifestReloadCli.hs).
* No allocation / resource-recovery event family. That is the other
  open lane from the 2026-05-19 closeout and remains separately
  consumer-gated.

## Operator rendering

The existing reload-events render in `runReloadWithSink` already
prints `reload events:` and `resource timeline:` blocks. The stale
surface should compose with that, not replace it:

```text
reload events:
  - MrePreservingReloadStarted
  - MrePreservingReloadCommitted   (2 bindings retired)
retired bindings:
  - voice "lead/1"        template "saw_lead"   reason: template-gone
  - voice "pad/A"         template "sustain"    reason: invalid-key
stale-by-reload commands:
  - osc "/voice/lead/1/cutoff"  -> reload retired voice "lead/1"
  - midi note-off ch1 v62      -> reload retired voice "pad/A"
```

One bullet per retired binding (each row needs the `VoiceKey`,
`TemplateName`, and `RetiredVoiceReason`, which is why the commit
event must carry the richer `RetiredVoiceBinding` projection rather
than raw `rrrDropped`); one bullet per attributed command. Both
blocks suppress to a single `(none)` line when empty.

Stopped-audio reloads usually retire dozens of voices and every
reason is `RvrOwnerReplaced`. The render should collapse that case
to a single summary row (`- all NN voices retired by owner
replacement`) instead of one-bullet-per-voice; the stale-by-reload
block below it stays per-command and still names individual
`VoiceKey`s.

Commands rejected at the service ingress gate (outcomes 2/3)
render under a separate block (`reload-window rejects:`) so they
don't get conflated with stale-by-retirement. `SiUnknownTemplate`
rejections still render as ordinary admission errors in v1 — see
[Out of scope](#out-of-scope-for-this-note).

Current slice 2 status: the pure renderer contract and live-shell
caller are split but wired together. `retiredBindingsFromEvents`
scans a reload-event timeline and returns the last commit event's
retired-binding payload. `renderRetiredBindings` owns the rows under
a caller-provided `retired bindings:` header:

* `[]` renders as one `(none)` row.
* A non-empty all-`RvrOwnerReplaced` list renders as
  `- all N voices retired by owner replacement`.
* Preserving-style and mixed lists render one row per binding,
  preserving input order and using stable reason labels
  `template-gone`, `invalid-key`, and `owner-replaced`.

`runReloadWithSink` prints the header and rows immediately after
`reload events:` when a commit payload is present. Rejection-only
timelines suppress the block because there is no retired set to
render.

## What tests would pin

The boundary is small enough to cover with three test classes:

1. **State.hs unit tests.** `commitGraphInstalled` already returns
   `rrrDropped`; tests should pin that a `CmdVoiceOff` / `CmdControlWrite`
   naming a key in that set rejects with `SiStaleVoice` against the
   new state *exactly when* that key appears in `rrrDropped`. Add a
   property: for any commit `c` and command `cmd` of those two
   shapes, the new admission outcome can be predicted from the old
   state, the new state, and the `VoiceKey` projection of `rrrDropped`.
   `CmdVoiceOn` is excluded from the property — its rejection
   depends on template existence, not the dropped set.

2. **FanIn drain tests, both reload paths.** Two fixtures. Both
   must enqueue the stale command *after* the swap commits and
   ingress reopens — anything enqueued before the orchestrator
   starts gets drained against the *old* state by `hproDrainLive`
   ([ManifestReloadOrchestration.hs:291](../app/MetaSonic/App/ManifestReloadOrchestration.hs#L291))
   and is not stale (outcome (1), not outcome (5)).

   * *Preserving.* Start an owner with one voice, drive a
     preserving swap whose new graph retires the template, wait
     for `MrePreservingReloadCommitted` and ingress to reopen,
     *then* enqueue a control-write naming the retired voice.
     Assert the drain reports `SiStaleVoice` *and* that the
     rejection is attributable to the swap's
     `rrrDropped`-derived retired-voice-key set carried on the
     commit event.
   * *Stopped-audio.* Start an owner with one voice, drive
     `reloadSessionFanInHostOwnerStoppedAudio`, wait for
     `MreStoppedAudioReloadCommitted` to surface the
     pre-release `ssVoices` snapshot, *then* enqueue a
     control-write naming a retired voice against the new owner.
     Assert the rejection is attributable to that snapshot with
     reason `RvrOwnerReplaced`.

   The existing fan-in tests in
   [`Spec/Session/FanInService.hs`](../test/MetaSonic/Spec/Session/FanInService.hs)
   and the preserving-hot-swap suite under
   [`Spec/Session/PreservingHotSwap.hs`](../test/MetaSonic/Spec/Session/PreservingHotSwap.hs)
   are the right neighbors for the preserving fixture; the
   stopped-audio fixture sits next to the existing
   `reloadSessionFanInHostOwnerStoppedAudio` coverage in the same
   suite.

3. **App-layer render tests.** The slice 2 pure-renderer coverage
   lives in
   [`AppManifestLiveCommonRetiredBindings`](../test/MetaSonic/Spec/AppManifestLiveCommonRetiredBindings.hs):
   reason labels, empty rows, stopped-audio summary rows,
   per-binding preserving rows, mixed fallback rows, and
   `retiredBindingsFromEvents` extraction from preserving /
   stopped-audio timelines. The caller-wiring assertion should mirror
   [`AppManifestReloadCli`](../test/MetaSonic/Spec/AppManifestReloadCli.hs)'s
   `assertContainsInOrder` pattern and assert that the operator
   output places `retired bindings:` after `reload events:`. Slice 3
   then extends that into a commit-with-retired-bindings +
   arriving-stale-command sequence with the right attribution.

A small property worth adding: outcomes (2)/(3)/(5) are mutually
exclusive for one command relative to one reload. The implementation
should not double-attribute.

## How this leaves the ROADMAP

The "Failure/event semantics across compile, allocation, install,
and stale producer commands" lane reads, after the 2026-05-19 note,
as: install/reload-strategy timeline landed; compile, allocation,
and stale-command semantics still open and consumer-gated.

This note pins the stale-command sub-lane to a concrete shape:
carry a `[RetiredVoiceBinding]` projection on both
`MrePreservingReloadCommitted` and `MreStoppedAudioReloadCommitted`,
sourced from `rrrDropped` on the preserving path and from a
pre-release `ssVoices` snapshot on the stopped-audio path; widen
the preserving op success type and the stopped-audio reload report
so the projection can reach the event emitter; render the retired
list through pure, tested row helpers before caller wiring; then
attribute post-swap `SiStaleVoice` rejections against the retired
`VoiceKey` set. `SiUnknownTemplate` attribution is a separate v2
lane on the same machinery.
