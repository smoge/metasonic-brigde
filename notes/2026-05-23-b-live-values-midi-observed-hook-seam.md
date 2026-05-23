# Phase 8h step 3b — Live `values` MIDI observed-hook seam

Status: draft.

This is the follow-on to step 3a
(`eed8f47 Land producer-neutral accepted-write extractor seam`).
Step 3a structurally closed the producer-neutral accepted-write
projection: `acceptedFanInControlWrite` over
`SessionFanInEnqueueResult`, with `acceptedOSCControlWrite` /
`acceptedUIControlWrite` / `acceptedMIDIProducerControlWrites`
peels. Step 3b is the natural continuation but **stops being pure
extraction** — it touches app-level ingress ownership, which is
why this note exists before any implementation.

The slice is intentionally MIDI-only. UI accepted-write wiring is
deferred until the live shell has any UI ingress at all (no GUI
toolkit binding is in scope). ALSA stderr and persistent
command-history are separate watch items and not the natural next
step after 3a.

## Why a design note first

3a was pure refactor + tests. The implementation choice was
forced: extract once, peel three times, no orchestration
implications. 3b is different: the live shell today opens OSC
ingress only, and making MIDI accepted-writes update `values`
forces a decision about how MIDI ingress is opened and owned in
the live shell. That decision is cheaper to make on paper than to
discover half-coded.

## The structural question

Two candidate scopes for the first 3b implementation slice:

- **A. Observed MIDI listener hook + tests, no live-shell
  wiring.** Add a `liveMIDIListenerHooksForObserved` helper that
  peels accepted enqueue results through
  `acceptedFanInControlWrite` and feeds the same
  `recordAcceptedWrite` updater the OSC hook uses. Pin the
  wiring with pure tests that drive the hook directly. The live
  shell does **not** open `ManifestMIDIListener`.

- **B. Combined OSC + MIDI ingress ops for the live shell.**
  Promote `RealReloadHostStackInputs.rrhsiBuildIngressOps` from
  OSC-only to combined OSC + MIDI ops. The live shell opens both
  listeners, and MIDI accepted-writes flow into `values`
  end-to-end for the operator.

The deciding factor is whether the live shell can plausibly own
a MIDI listener today **without** PortMIDI device work.

### Why A is the right call for 3b

The OSC analogy that made 3a easy does not carry over:

- OSC has a single transport (UDP). The live shell binds a real
  UDP socket; tests bind a real UDP port on a free local port.
  One transport for both, no source-pluggability question.
- MIDI has no equivalent device-independent wire transport.
  `ManifestMIDIListener` is parameterized over a
  `MIDIListenerSource`. The two implementations available today
  are `portMIDIListenerSource` (device) and test-time mocks. A
  live shell that opens a `MIDIListenerSource` is either
  PortMIDI-backed (out of scope) or operator-meaningless.

So B is blocked on either landing PortMIDI for the live shell or
introducing a third MIDI source shape (scripted / file-driven /
some explicit operator-driving CLI) that is operator-meaningful
but device-independent. Either is its own design and its own
slice — not 3b's job.

That leaves A: land the observed-hook seam, pin it with tests
that exercise the existing in-language listener, and stop. The
live shell does not gain a `values`-feeding MIDI path in 3b; it
gains the structural piece that would feed it the moment a MIDI
ingress path is opened.

This matches the 3a stance: the extractors landed even though
only OSC consumes them in the live shell today.

## Implementation shape (A)

### New helper in `ManifestLiveCommon`

Add a single observer-only hook builder:

```haskell
liveMIDIListenerHooksForObserved
  :: (VoiceKey -> ControlTag -> Value -> IO ())
  -> ManifestMIDIListenerHooks
```

Internally it constructs a `ManifestMIDIListenerHooks` value where:

- `mmlhOnAccepted` invokes the observer via
  `acceptedFanInControlWrite` — the same shape the OSC core hook
  uses post-3a. Nothing else.
- `mmlhOnIssue` is the default no-op
  (`defaultManifestMIDIListenerHooks` already provides this).

No `ManifestReloadIngressTarget` parameter, no output sink, no
accept-line printer. Three reasons to keep this minimal in 3b:

1. The live shell does not open a manifest MIDI listener in 3b,
   so an accept-line printer would have no consumer.
2. Issue rendering (the `mmlhOnIssue` taxonomy:
   `MmliIngressIssue` / `MmliEnqueueRejected` / `MmliIgnoredEvent`)
   has no operator surface yet either, and pinning a renderer here
   would freeze wording before any operator transcript has
   exercised it.
3. The smaller shape avoids a "with-sink" / "without-sink" /
   "with-target" / "without-target" combinatorial creep before a
   real caller forces the decision.

When 3c opens a MIDI listener in the live shell, a
`liveMIDIListenerHooksForObservedWith` variant — taking an output
sink and likely the ingress target for accept-line rendering —
can be added next to this one without touching 3b's signature.

### What does **not** change

- `RealReloadHostStackInputs.rrhsiBuildIngressOps` stays OSC-only.
- `ManifestOSCIngressOps` keeps its existing comment ("UI and MIDI
  projections still ride inside the same target for future
  steps"). 3b does not introduce a combined ingress-ops bundle.
- The live shell still opens OSC ingress only. No PortMIDI, no
  scripted MIDI source.
- `submitManifestMIDICCEvent` is unchanged. The listener already
  routes through it.

## Tests

All in-language, no device work, no real PortMIDI. Each test
closes the projection-to-cache loop by binding the observer to a
`LiveValueCache` updater (`recordAcceptedWrite` on an `IORef
LiveValueCache`) and asserting through `lookupLiveValue`. This
matches how the live shell wires the OSC observer today
(`recordAccepted` in `ManifestLiveSession.hs`) and avoids the
weaker shape of dumping triples into an `IORef [(...)]`.

1. **MIDI accepted control write updates the cache.** Construct
   `liveMIDIListenerHooksForObserved` bound to an `IORef
   LiveValueCache`, drive `mmlhOnAccepted` directly with a
   synthetic accepted `SessionFanInEnqueueResult` wrapping a
   `CmdControlWrite voice tag value`, assert
   `lookupLiveValue voice tag` returns
   `Just (LiveControlValue value LcvsAccepted)`.
2. **Non-control accepted commands leave the cache untouched.**
   Same setup, feed an accepted `CmdVoiceOff` (or any non-control
   queued command), assert `lookupLiveValue` returns `Nothing`.
3. **Rejected enqueues leave the cache untouched.** Same setup,
   feed a `SessionEnqueueRejected` result wrapping a
   `CmdControlWrite`, assert `lookupLiveValue` returns `Nothing`.
4. **Issue path does not touch the cache.** Drive `mmlhOnIssue`
   with each of `MmliIngressIssue`, `MmliEnqueueRejected`,
   `MmliIgnoredEvent`; assert `lookupLiveValue` returns `Nothing`
   in all three cases.

These tests live next to the existing
`AppManifestLiveValueCache` group; they exercise the same
`recordAcceptedWrite` updater the OSC tests already exercise. No
new test file is required.

### Optional smoke

A device-independent `MIDIListenerSource` is already in routine
test use: `test/MetaSonic/Spec/AppManifestMIDIListener.hs` drives
`withManifestMIDIListener` over a `Chan (Maybe MIDIProducerEvent)`
to emit synthetic CC events. An end-to-end smoke could do the
same — open the listener with that `Chan`, feed one CC event,
and confirm the observer fires through the real listener
machinery into a `LiveValueCache`.

Optional but redundant for 3b: the four direct hook tests above
already pin the projection-to-cache contract, and the existing
`AppManifestMIDIListener` tests already pin the
`Chan`-source-to-`mmlhOnAccepted` path. The end-to-end smoke
only re-exercises that join. Land it if the redundancy reads as
operator evidence rather than test bloat; otherwise skip.

## What gates 3b → 3c

3c (operator-visible MIDI path landing in `values`) requires one
of:

- **PortMIDI live-shell integration.** Not strictly hardware:
  PortMIDI sits on top of ALSA on Linux, so a virtual MIDI
  controller such as VMPK can drive the live shell without
  physical devices. That makes 3c reachable on a laptop without
  hardware, while still going through the real PortMIDI source.
  Hardware verification is a follow-on, not the gate.
- **An in-process operator-driving MIDI source.** Plausible
  shapes: a stdin-driven "send CC" verb in the live shell, a
  scripted file source, or a localhost OSC-to-MIDI bridge.
  Useful if PortMIDI integration is deferred for other reasons,
  but otherwise duplicates the VMPK path.

Either path is its own design note. 3b should not pre-commit.

## Non-Goals

- No PortMIDI device opening in the live shell.
- No combined OSC + MIDI ingress-ops bundle.
- No UI ingress wiring.
- No new C ABI or runtime surface.
- No change to `acceptedFanInControlWrite` or any 3a-landed
  extractor; 3b consumes the seam, does not modify it.
- No ALSA stderr suppression, no persistent command-history
  changes.

## Open questions to resolve before code

1. **Where do the tests live?** Default position: extend
   `AppManifestLiveValueCache.hs` with a new `testGroup` named
   `liveMIDIListenerHooksForObserved`, mirroring the existing
   accepted-write group structure. Splitting into a new file
   should wait for a second consumer.
2. **Land the optional `Chan`-source smoke or skip?** Decided at
   implementation time once the four direct hook tests are
   written: keep if the end-to-end joins read as evidence the
   direct tests do not (e.g., real listener thread teardown,
   `Maybe` end-of-stream handling); otherwise skip as redundant
   with the existing `AppManifestMIDIListener` coverage.

## Validation plan

1. `just stack-test` (specifically the
   `App manifest live value cache (Phase 8h)` group).
2. `git diff --check`.
3. No live transcript. Operator-visible MIDI behavior is 3c.

A short ROADMAP entry should follow the same pattern as the 3a
land: name the new symbol(s), note the residual ("MIDI accepted-
write hook landed, live shell still opens OSC only — operator-
visible MIDI path is 3c, blocked on a non-device source or
PortMIDI").
