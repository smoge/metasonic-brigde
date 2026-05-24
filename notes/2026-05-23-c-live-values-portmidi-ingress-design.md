# Phase 8h step 3c — Live `values` PortMIDI ingress design

Status: closed.

Closed 2026-05-24 after the live-shell PortMIDI pass recorded at
`/tmp/metasonic-live-session-8h-3c-sclang.log`. The manual pass used
`sclang` as the CC generator into the host's ALSA / PortMIDI route
rather than VMPK's controller UI, but it exercised the same live
session `--midi-device` path: startup opened with `midi=on`, CC
74 / 71 / 7 produced `midi accept` lines, `values` changed to
`source=accepted`, preserving reloads retained the MIDI-written
values, a later CC 74 update landed after reload, final `status`
stayed healthy, and the session exited with command code 0.

Landed implementation commits:

- `4923307` pre-fix live MIDI default voice to `v0`.
- `53f4677` add combined live ingress ops combinator.
- `c72a11b` add MIDI listener-event renderers and observed-hook
  builder.
- `93fda77` thread `--midi-device` into `runManifestLiveSession`.
- `92f3c73` add live ingress production aliases and operator
  renderers.
- `62286d2` wire the live session to combined ingress ops.
- `670dad5` add the manual test documentation.

Remaining follow-up: physical-controller or VMPK-GUI-specific
confirmation. That follow-up is hardware/operator coverage, not part
of the software PortMIDI ingress contract closed here.

This is the operator-visible follow-on to step 3b
(`a29e5f0 Land Phase 8h step 3b MIDI observed-hook seam`). The
MIDI extractor seam plus the `liveMIDIListenerHooksForObserved`
hook are in place but unwired in the live shell. Step 3c opens
that wiring by giving the manifest live session an actual
PortMIDI-backed MIDI ingress path, manually driven by VMPK / an
ALSA virtual MIDI port. After 3c, sending CC 74/71/7 from VMPK
should update the `values` table the same way OSC writes do
today.

The scope deliberately excludes physical hardware verification
(follow-on once a controller is plugged in) and any in-process
"send CC" operator command (only revisit if PortMIDI integration
proves too heavy on the Haskell side).

## Why a design note first

3b was a single producer-neutral helper plus four hook-to-cache
tests. 3c is wider: a new external resource (PortMIDI source), a
combined ingress-ops bundle, new live-session CLI consumption of
an existing flag, an operator-visible accept / issue line
taxonomy, and a manual operator pass. Each of those is cheap to
write on paper and expensive to discover half-coded.

## Decisions to make in this note

The five questions the user enumerated, with a recommendation
for each.

### 1. Combined OSC + MIDI ingress ops

`RealReloadHostStackInputs` is polymorphic in `(ingressIssue,
handle)`, but each instance is single-typed. To open both
listeners under the existing supervisor lifecycle, the combined
ingress ops must present one bundled `handle` and one bundled
`issue`.

Both halves already exist as `ManifestReloadIngressOps` values:

- `manifestOSCIngressOpsWithTargetHooks` builds the OSC half
  with `ManifestOSCIngressOpsIssue` / `ManifestOSCIngressHandle`.
- `manifestMIDIIngressOps` builds the MIDI half with
  `ManifestMIDIIngressOpsIssue ManifestMIDIPortMIDIError` /
  `ManifestMIDIIngressHandle PortMIDISource`. The MIDI half is
  factory-shaped (`ManifestMIDISourceFactory`) so it opens a
  fresh source per generation; the PortMIDI factory is
  `manifestPortMIDISourceFactory`. Close policy: listener first,
  source second; source-close failures route through
  `mmioohOnSourceCloseFailed` and the manager observes
  `Right ()`. Re-stating this contract in the combined ops would
  duplicate landed code — defer to it.

Recommended shape — a thin combinator over the two existing
`ManifestReloadIngressOps`, parameterized so pure tests can
substitute trivial handle / issue types (the production
`PortMIDISource` is an opaque newtype around a foreign pointer
and cannot be constructed in-language):

```haskell
data LiveIngressHandle oscHandle midiHandle = LiveIngressHandle
  { lihOSC  :: !oscHandle
  , lihMIDI :: !(Maybe midiHandle)
  }

data LiveIngressIssue oscIssue midiIssue
  = LiiOSC  !oscIssue
  | LiiMIDI !midiIssue
```

`lihMIDI` is `Maybe` so that when the operator does not pass
`--midi-device`, the MIDI half is simply absent from the
combined open — not "opened and then degraded." See the
open-failure policy below for the case when the device flag
*is* passed but the open fails.

For production wiring, a pair of type aliases keeps the call
sites readable:

```haskell
type LiveProdIngressHandle =
  LiveIngressHandle
    ManifestOSCIngressHandle
    (ManifestMIDIIngressHandle PortMIDISource)

type LiveProdIngressIssue =
  LiveIngressIssue
    ManifestOSCIngressOpsIssue
    (ManifestMIDIIngressOpsIssue ManifestMIDIPortMIDIError)
```

The combinator's signature stays polymorphic; the live session
specializes to the production aliases when it hands the bundle
to `RealReloadHostStackInputs`. Pure tests instantiate the
polymorphic shape with cheap types (e.g. `()` for either handle,
a tiny sum for either issue) so the open / close order and
absent / present `Maybe` branches are exercised without any
PortMIDI or UDP dependency.

Open / close order in the combinator:

- Open: OSC's `mrioOpenIngress` first. On `Left`, surface
  `LiiOSC` and stop. On `Right`, if `--midi-device` is set, call
  MIDI's `mrioOpenIngress`; on `Left`, close the OSC handle
  (best-effort) and surface `LiiMIDI`. If `--midi-device` is
  unset, return `lihMIDI = Nothing`.
- Close: when `lihMIDI` is `Nothing`, just call OSC's
  `mrioCloseIngress` and return its result. When `lihMIDI` is
  `Just`, always attempt both closes (MIDI first, then OSC) so
  the OSC socket is released even if MIDI close fails. OSC
  failure dominates: return `Left (LiiOSC ...)` if OSC's close
  fails; otherwise return `Left (LiiMIDI ...)` if MIDI's close
  failed; otherwise `Right ()`.

The OSC-dominates rule means the combinator cannot rely on the
landed production MIDI close contract (always-`Right ()`) for
correctness — that contract is one of many valid behaviors at
the type level. Production MIDI degenerates to the OSC-only
case (because MIDI close returns `Right ()`); the policy stays
honest for stub MIDI ops that do report close failures.

The combinator lives in a small new module
(`MetaSonic.App.ManifestLiveIngressOps` is a fine name) so
`ManifestLiveCommon` does not grow ingress-orchestration code.

### 2. MIDI device selection for `--manifest-live-session`

The CLI already has `--midi-device N` (parsed to
`optMidiDevice :: Maybe Int` at `app/Main.hs:511`) and
`--midi-list` (documented at `app/Main.hs:863`). The help row at
`app/Main.hs:865-868` currently says `--midi-device` is "Ignored
by non-MIDI modes." 3c's job is to make
`--manifest-live-session` consume `optMidiDevice` and to update
that help row to name `--manifest-live-session` as a consumer.

- `optMidiDevice == Nothing` → no MIDI half in the combined
  ingress ops; behavior identical to today. This stays the
  default so `--manifest-live-session` invocations without
  `--midi-device` keep working unchanged (and CI stays headless).
- `optMidiDevice == Just n` → pass
  `defaultPortMIDISourceOptions { pmsoDeviceId = Just n }` into
  `manifestPortMIDISourceFactory`, plug the resulting factory
  into `manifestMIDIIngressOpsWithTargetHooks` (the per-target
  hooks variant added in decision 3; the constant-hooks
  `manifestMIDIIngressOps` is the wrong choice here because the
  hook renderer needs the per-generation `mmitControls`), and
  combine with the OSC ops per decision 1.

No new CLI flag, no new enumeration subcommand. `--midi-list`
already exists for device-id discovery.

### 3. Haskeline-aware accept / issue rendering

Add a `*With`-variant of the 3b hook builder:

```haskell
liveMIDIListenerHooksForObservedWith
  :: ManifestMIDIIngressTarget
  -> (VoiceKey -> ControlTag -> Value -> IO ())
  -> (String -> IO ())
  -> ManifestMIDIListenerHooks
```

The signature mirrors `liveOSCListenerHooksForObservedWith`. The
target carries `mmitControls`, which the renderer needs to look
up `ControlTag` metadata (display name) for accept lines.

**Per-target hooks at open time.** Because `mmitControls` shifts
across preserving reloads, the renderer must be rebuilt for
each new target — using one fixed hook set at construction time
would render against stale bindings after the first swap. The
landed OSC path solves this with
`manifestOSCIngressOpsWithTargetHooks`, which takes a
`ManifestReloadIngressTarget -> ManifestOSCListenerHooks`
builder and calls it inside `mrioOpenIngress` against the
just-projected target. The MIDI side has no equivalent today —
`manifestMIDIIngressOps` only accepts fixed
`ManifestMIDIListenerHooks`.

3c adds a MIDI analogue:

```haskell
manifestMIDIIngressOpsWithTargetHooks
  :: (ManifestReloadIngressTarget -> ManifestMIDIListenerHooks)
  -> ManifestMIDIIngressOpsHooks issue
  -> MIDIProducerOptions
  -> SessionFanInHost
  -> ManifestMIDISourceFactory issue source
  -> ManifestReloadIngressOps
       ManifestReloadIngressTarget
       (ManifestMIDIIngressOpsIssue issue)
       (ManifestMIDIIngressHandle source)
```

It builds the listener hooks from the per-generation target
just before `openManifestMIDIListener`, the same way the OSC
helper does. The existing `manifestMIDIIngressOps` stays as the
constant-hooks wrapper (`manifestMIDIIngressOps hooks = manifestMIDIIngressOpsWithTargetHooks (const hooks)`)
so existing call sites do not move.

This helper is a prerequisite for the live-session wiring step
in the implementation order — it lands before the combinator
specializes against the production target. The
sink is the live-shell's `extPrintDyn` (the same `extPrintRef`
the OSC observed-hook reads), so async MIDI output redraws under
Haskeline rather than corrupting the operator's edit buffer.

**Hook payload constraint.** `mmlhOnAccepted` takes
`SessionFanInEnqueueResult -> IO ()`
(`app/MetaSonic/App/ManifestMIDIListener.hs:93`). The raw CC
number and channel byte exist inside `processManifestMIDIEvent`
at line 113 but are **not** threaded through to the hook. So the
accept line can only render what is recoverable from the queued
`CmdControlWrite` plus the target's binding table — there is no
`cc=N ch=M` to display at this layer without an API change. 3c
accepts this limit; extending the hook payload is a separate
slice and not on the 3c critical path.

Per-event surface (exact wording to be exercised in the manual
pass and iterated; the design fixes the **information**, not the
literal string):

- `mmlhOnAccepted`: one line per accepted CC, naming the
  resolved concrete address (`/<voice>/<node>/<slot>`), the
  binding's display name when available, and the scaled value.
  Then invoke the observer through `acceptedFanInControlWrite`.
  Reject side (`SessionEnqueueRejected`) returns silently —
  `mmlhOnIssue` owns the rejection line via the
  `MmliEnqueueRejected` arm of `processManifestMIDIEvent`.
- `mmlhOnIssue`:
  - `MmliIngressIssue (MmiiChannelFiltered ch)` →
    `midi reject (channel-filtered): ch=<n>`
  - `MmliIngressIssue (MmiiAddressIssue _)` →
    `midi reject (cc-unbound): cc=<n>` plus the bound-CC list
    for context
  - `MmliIngressIssue (MmiiInvalidChannel _ /
    MmiiInvalidDataByte _)` →
    `midi reject (bad-data): ...`
  - `MmliEnqueueRejected cmd SeiReloadInProgress` →
    `midi reject (reload-window): <cmd>` (matching the OSC
    reload-window taxonomy from
    `notes/2026-05-20-d-stale-command-rejection-rendering.md`)
  - `MmliEnqueueRejected cmd <other>` →
    `midi enqueue-reject: <cmd> issue=<...>`
  - `MmliIgnoredEvent <non-CC>` → either silent (preferred to
    avoid VMPK note-trigger noise) or rate-limited diagnostic.
    Default position: silent.

Keep 3b's `liveMIDIListenerHooksForObserved` exported for the
hook-to-cache tests; the `*With` variant is the production
wiring.

### 4. Preserving reload: close / open across both handles

`ManifestReloadIngressOps` runs `mrioOpenIngress` and
`mrioCloseIngress` on every ingress generation, including
preserving reloads. The combined ops from decision 1 just
forwards that lifecycle uniformly over both halves. There is no
MIDI-specific reload semantics to design here.

**Source lifetime: per-generation, not session-wide.** The
landed `manifestMIDIIngressOps` contract is factory-per-open
(`app/MetaSonic/App/ManifestMIDIIngressOps.hs:134`), and
`manifestPortMIDISourceFactory` opens a fresh `PortMIDISource`
on every `mmsfOpenSource` call
(`app/MetaSonic/App/ManifestMIDIPortMIDI.hs:62`). So the PortMIDI
device handle is re-acquired and re-released on every preserving
reload alongside the listener and the OSC socket. 3c composes
this contract; it does not override it.

This deviates from the earlier draft (which proposed a
session-long source captured by closure). The cost of
re-opening PortMIDI on each preserving reload is a brief
device-handle reacquisition; the benefit is matching the
landed adapter contract and not introducing a source-lifetime
seam that the rest of the system does not have. If a future
operator pass shows the reacquisition window is operator-visible
or device-fragile, hoisting the source to session scope becomes
its own design item, not a 3c sub-decision.

Implementation order for the factory closure:

1. Capture `optMidiDevice :: Maybe Int` at the
   `rrhsiBuildIngressOps` factory site.
2. When `Just n`, construct
   `manifestPortMIDISourceFactory defaultPortMIDISourceOptions
   { pmsoDeviceId = Just n }` and pass it into
   `manifestMIDIIngressOpsWithTargetHooks` along with the
   per-target hooks builder from decision 3.
   `manifestMIDIIngressOps` remains the constant-hooks wrapper
   for callers that do not need per-generation hooks; the live
   session is not one of them.
3. Compose the resulting MIDI `ManifestReloadIngressOps` with
   the existing OSC ops via the decision-1 combinator.

### 5. Manual VMPK test path

Concrete reproduction recipe (Linux / ALSA). VMPK is the
in-scope virtual controller because it is purely software and
ships in Fedora's repos.

**Pre-fix: default-voice mismatch.** Today
`mritpMIDIDefaultVoice = VoiceKey "fx"`
(`app/MetaSonic/App/ManifestLiveCommon.hs:960`), but
`autoStartTemplates` only keeps the literal voice `fx` for a
template literally named `fx`; otherwise non-`fx` templates get
`v<index>`. The saw/noise demo declares a `drone` template, so
it auto-spawns under `v0`, and `values` renders rows only for
voices in the live `ssVoices` set
(`app/MetaSonic/App/ManifestLiveSession.hs:1266`). Without a
fix, MIDI ingress writes against the policy's `fx` voice will
not surface in the `values` table because `fx` is not live.

For the saw/noise pass, change the live policy to
`mritpMIDIDefaultVoice = VoiceKey "v0"`. This matches the
first-non-`fx`-template slot the auto-start policy emits and
makes 3c verifiable without per-demo configuration. Caveat: a
demo whose only template is literally named `fx` would still
need `fx` as the MIDI default — handle that case in a later
slice if a demo of that shape arrives. Document the caveat in
the ROADMAP closeout.

**Setup (one-time):**

```sh
sudo dnf install vmpk
# If ALSA virtual MIDI is needed (VMPK can also expose its own
# ALSA output port directly, in which case this is skipped):
sudo modprobe snd-virmidi
```

**Per-session:**

```sh
# 1. Start VMPK with an ALSA MIDI Output. Note its client:port.
#    A scriptable sclang MIDIOut source is also acceptable if it
#    sends the same CCs through an ALSA / PortMIDI-visible route.
vmpk &

# 2. Discover the PortMIDI device id corresponding to that port.
#    Either via metasonic-bridge --midi-list, or via VMPK's
#    "MIDI Output" dropdown matched against `aconnect -o`.
stack exec -- metasonic-bridge --midi-list
aconnect -o

# 3. Run the live session with the chosen device id.
script -q /tmp/metasonic-live-session-8h-3c-sclang.log -c \
  'stack exec -- metasonic-bridge \
     --session-osc-port 17005 \
     --midi-device <N> \
     --manifest-live-session examples/manifests/saw-noise-filter.json saw-filter-dark \
     --strategy require-preserving'
```

**Manifest expectation:**

`examples/manifests/saw-noise-filter.json` should bind CC 74 →
`lpf/0` (cutoff), CC 71 → `lpf/1` (q), CC 7 → `gain/0` (level).
With the default-voice fix above, accepted MIDI writes appear
against `/v0/lpf/0`, `/v0/lpf/1`, `/v0/gain/0`. Confirm the
manifest's CC bindings before the pass; if a binding is missing,
that is its own fixup slice, not a 3c blocker.

**Operator sweep:**

1. In the session, run `values`. Expect rows for `/v0/...` with
   `source=default`.
2. From VMPK, send CC 74 = 90. Confirm a `midi accept` line in
   the transcript; run `values`; confirm `/v0/lpf/0` shows
   `source=accepted` with the scaled value.
3. Repeat with CC 71 = 40 and CC 7 = 30.
4. Switch demo: `demo saw-filter-bright`. Run `values`; confirm
   cached values retain for surviving `ControlTag`s and the
   others default.
5. From VMPK again, send CC 74 = 64; confirm `values` updates
   on the new plan.
6. `quit`.

**Pass criteria:**

- Every VMPK CC produced exactly one `midi accept` line.
- `values` table reflected every accepted MIDI write the same
  way it reflects accepted OSC writes today.
- Preserving reload retained MIDI-written values across the
  swap.
- Reload events and OSC writes (if any) continued to work
  unchanged.
- No ALSA / PortMIDI stderr spam beyond what is already a
  standing watch item.

A failure on any of those is a 3c slice bug, not a 3d issue.

### Open-failure policy: split by lifecycle phase

`manifestPortMIDISourceFactory` already returns two failure
shapes: `MmppOpenFailed` (allocation failed before any device
probe) and `MmppNoInputDevice` (handle valid but no input
device). These project to
`MmioiSourceOpenFailed ManifestMIDIPortMIDIError` in the
ingress-ops adapter.

The combined ops needs distinct policies for the two lifecycle
phases — the earlier draft conflated them:

- **Initial open (live-session startup).** If `--midi-device` is
  set and the first MIDI open fails, abort startup with a clear
  message naming the failure shape (`no input device for
  --midi-device N` vs `PortMIDI open failed`). Same posture as
  an OSC port-bind failure: operators pass `--midi-device`
  expecting MIDI to work, and silently degrading would mask the
  device-id mistake. (This is a change from the earlier draft's
  "warn and continue OSC-only" framing.)
- **Reload-time open (preserving / fallback rebuild).** The
  combined `mrioOpenIngress` returns `Left LiiMIDI` and the
  supervisor's existing escalation handles it the same way it
  handles an OSC reopen failure. No special MIDI policy.

This is the simpler shape. A future "warn and continue OSC-only"
mode would belong in a separate slice that adds an explicit
`--midi-device-optional` opt-in or detects "device removed
mid-session" as a distinct event.

**Renderer seam for startup-time abort.** Startup currently goes
through `hsfOpenStack factory initialPlan` inside `runSupervised`
(`ManifestLiveSession.hs:791`). The factory is route-specific:
each `hsfOpenStack` impl wraps `ReloadHostStackOpenIssue`
through `first <Route>Open` before returning, so failures arrive
as `Left (SahsiOpen (RhsoiIngressOpenFailed e))` for
StoppedAudioOnly (`ManifestReloadHostStack.hs:305, 425`),
`Left (PahsiOpen (RhsoiIngressOpenFailed e))` for
RequirePreserving (`ManifestReloadPreservingHostStack.hs:171,
362`), and
`Left (TpahsiOpen (RhsoiIngressOpenFailed e))` for
TryPreserving (`ManifestReloadTryPreservingHostStack.hs:175,
376`). The shared
`renderReloadHostStackOpenIssueTag` (`ManifestReloadCli.hs:1381,
1387`) collapses every inner variant to a short tag like
`"ingress-open-failed"`. That collapse is fine for the
supervisor's reload-time path but swallows the operator message
the initial-open policy promises
(`no input device for --midi-device N` /
`PortMIDI open failed`).

3c adds a small live-session-specific renderer. The signature
threads the device id explicitly because
`LiveProdIngressIssue` does not carry it:

```haskell
renderLiveProdIngressIssue
  :: Maybe Int                 -- optMidiDevice
  -> LiveProdIngressIssue
  -> String
renderLiveProdIngressIssue mDevice = \case
  LiiOSC oscIssue ->
    "OSC ingress open failed: " <> show oscIssue
  LiiMIDI (MmioiSourceOpenFailed MmppNoInputDevice) ->
    "no input device for --midi-device "
      <> maybe "(unset)" show mDevice
  LiiMIDI (MmioiSourceOpenFailed MmppOpenFailed) ->
    "PortMIDI open failed for --midi-device "
      <> maybe "(unset)" show mDevice
```

`Maybe Int` (rather than `Int`) keeps the renderer total
without forcing the caller to assert "we only render this when
`optMidiDevice = Just _`" — useful for tests, and harmless in
practice because the unset case is unreachable for the
`LiiMIDI` arms.

**Where the renderer is wired.** Because the outer wrapper
varies by route, `runSupervised` gains a small route-specific
projector argument alongside the existing `causeLabel` renderer
argument (today one of
`renderStoppedAudioHostStackIssueTag`,
`renderPreservingHostStackIssueTag`, or
`renderTryPreservingHostStackIssueTag`, each of which delegates
to the shared `renderReloadHostStackOpenIssueTag` for open-issue
tags):

```haskell
projectInitialIngressFailure
  :: routeOpenIssue -> Maybe LiveProdIngressIssue
```

The three `case strategy of` arms in
`ManifestLiveSession.hs` pass route-specific projectors:

- StoppedAudioOnly →
  `\case SahsiOpen  (RhsoiIngressOpenFailed e) -> Just e; _ -> Nothing`
- RequirePreserving →
  `\case PahsiOpen  (RhsoiIngressOpenFailed e) -> Just e; _ -> Nothing`
- TryPreserving →
  `\case TpahsiOpen (RhsoiIngressOpenFailed e) -> Just e; _ -> Nothing`

Inside `runSupervised`, when the initial `hsfOpenStack` returns
`Left issue`, the projector runs first. `Just e` →
`die (renderLiveProdIngressIssue optMidiDevice e)`. `Nothing`
→ fall through to the existing `causeLabel`-driven path so
unrelated startup failures (audio start, service open,
fallback) retain their current operator strings. Reload-time
ingress failures continue to flow through the same shared
collapse — those are reload-window operator events during a
live session, not startup contracts.

Tests pin the exact strings for each `LiveProdIngressIssue`
variant so the operator-facing surface does not drift on a
later refactor.

## Implementation order

1. Pre-fix `mritpMIDIDefaultVoice = VoiceKey "v0"` in
   `ManifestLiveCommon.liveIngressTargetPolicy`. Verify the
   existing ingress-target projection tests still pass; add one
   if the constant is not currently pinned.
2. Add `manifestMIDIIngressOpsWithTargetHooks` in
   `ManifestMIDIIngressOps`, the MIDI analogue of
   `manifestOSCIngressOpsWithTargetHooks` (see decision 3).
   Re-express the existing `manifestMIDIIngressOps` as
   `manifestMIDIIngressOpsWithTargetHooks (const hooks)` so
   current call sites do not move. Pure tests confirm the
   per-target hooks builder fires inside `mrioOpenIngress`
   against the just-projected target.
3. Add the combined-ops module
   (`MetaSonic.App.ManifestLiveIngressOps` or equivalent) with
   the polymorphic `LiveIngressHandle` / `LiveIngressIssue`
   types and a constructor that composes an OSC
   `ManifestReloadIngressOps` and an optional MIDI
   `ManifestReloadIngressOps`. Pure tests cover the open /
   close order, the `Maybe` MIDI absent / present branches,
   and the generic close policy (OSC failure dominates,
   otherwise MIDI failure is reported, both closes always
   attempted) using stub `ManifestReloadIngressOps` values on
   both sides — `()` handles, tiny-sum issues, no PortMIDI, no
   UDP.
4. Add `liveMIDIListenerHooksForObservedWith` plus accept /
   issue line renderers. Pure tests pin the line shapes the
   same way `renderOSCAcceptLine` / `renderOSCIssueLine` are
   pinned.
5. Update `app/Main.hs`: thread `optMidiDevice` into
   `runManifestLiveSession` (already parsed; just unblocked from
   "ignored by non-MIDI modes"). Update the `--midi-device`
   help row to name `--manifest-live-session` alongside the
   existing consumers.
6. Wire the live session: build the optional MIDI ingress ops
   from `manifestMIDIIngressOpsWithTargetHooks` plus
   `manifestPortMIDISourceFactory` when `optMidiDevice` is
   `Just _`, plug into the combined ops, hand the bundled ops
   to `rrhsiBuildIngressOps`. Apply the startup-time open-
   failure policy from above (die with a clear message on
   `MmppOpenFailed` / `MmppNoInputDevice`).
   Add a new live-session-only ingress-snapshot renderer rather
   than modifying the shared one. Today
   `renderIngressSnapshot` / `printIngressSnapshotWith` are
   specialized to `ManifestOSCIngressHandle`
   (`ManifestLiveCommon.hs:461`) and are shared with the
   live-reload demo and host-reload smoke, both of which stay
   OSC-only. Introduce `renderLiveIngressSnapshot` /
   `printLiveIngressSnapshotWith` against `LiveProdIngressHandle`,
   extracting `lihOSC` for the bound-port field and adding a
   one-token MIDI marker (`midi=on` / `midi=off`) from
   `lihMIDI`'s `Maybe`. The OSC-only `renderIngressSnapshot`
   stays for the demos / smoke; only the live-session
   entrypoint switches to the new renderer.
   Also wire `renderLiveProdIngressIssue` through a route-specific
   `projectInitialIngressFailure` (see the open-failure policy
   above) — three projectors peeling `SahsiOpen` / `PahsiOpen` /
   `TpahsiOpen` plus the inner `RhsoiIngressOpenFailed`, each
   passed into `runSupervised` next to its existing `causeLabel`
   argument (`renderStoppedAudioHostStackIssueTag` /
   `renderPreservingHostStackIssueTag` /
   `renderTryPreservingHostStackIssueTag`). On `Just e`,
   the supervisor `die`s through the renderer; on `Nothing`,
   the existing `causeLabel` path renders the failure as before.
7. Manual ALSA / PortMIDI pass; accepted closeout transcript:
   `/tmp/metasonic-live-session-8h-3c-sclang.log`. VMPK's GUI
   controller path remains an optional follow-up, not the software
   PortMIDI contract gate.
8. ROADMAP / note-status update after the manual pass passes.

Each in-language step (1–6) is independently testable; step 7 is
the only step requiring a Linux host with ALSA plus either VMPK or a
scriptable MIDI generator such as `sclang`.

## Tests

In-language tests cover every step except 7:

- Combined ingress ops: OSC open ok + MIDI absent (Nothing) ⇒
  combined Right with `lihMIDI = Nothing`; OSC open ok + MIDI
  open ok ⇒ combined Right with both halves; OSC open ok + MIDI
  open fails ⇒ OSC closed, combined Left LiiMIDI; OSC open
  fails ⇒ combined Left LiiOSC, MIDI never attempted; close
  order is MIDI then OSC.
- Hook renderers: every `ManifestMIDIListenerIssue` variant maps
  to a deterministic line shape; the accept-line shape resolves
  the queued `CmdControlWrite`'s `ControlTag` against the
  target's `mmitControls`.
- CLI plumbing: `optMidiDevice == Just N` is threaded into the
  live-session entrypoint (test by inspecting the bundled
  options record produced by argument parsing); the help-row
  text mentions `--manifest-live-session`.
- Live-session wiring: a synthetic `MIDIListenerSource` (the
  `Chan` shape `AppManifestMIDIListener` already uses) drives
  the listener through the combined ops and confirms the
  observer-to-cache loop fires end-to-end. This is the smoke 3b
  deferred.
- Ingress-snapshot renderer: `renderLiveIngressSnapshot`
  against a `LiveProdIngressHandle` reports `oscPort=N` from
  `lihOSC` and `midi=on` / `midi=off` from `lihMIDI`'s `Maybe`.
  Closed snapshot still renders as `closed`. The shared
  `renderIngressSnapshot` is untouched and the demo / smoke
  tests that exercise it stay green.
- Startup-error renderer: `renderLiveProdIngressIssue`'s output
  is pinned for each `LiveProdIngressIssue` variant —
  `LiiOSC oscIssue`, `LiiMIDI (MmioiSourceOpenFailed
  MmppNoInputDevice)`, `LiiMIDI (MmioiSourceOpenFailed
  MmppOpenFailed)` — so the operator-facing initial-open strings
  do not drift on later refactors. At least one MIDI case is
  exercised with `mDevice = Just N` so the rendered string pins
  the device-id substitution (e.g.
  `"no input device for --midi-device 3"`); one case with
  `mDevice = Nothing` exercises the totality fallback
  (`"(unset)"`) so the renderer cannot regress to a
  `fromJust`-style partial pattern.
- Route-specific initial-open projectors: each of the three
  projectors maps `<Route>Open (RhsoiIngressOpenFailed e)` to
  `Just e` and every other issue variant of its route to
  `Nothing`, so the supervisor's fallthrough path stays correct
  for unrelated route issues.

Step 7 is the operator transcript, not an automated test.

## Failure modes / what could go wrong

- **PortMIDI open returns Nothing (`MmppOpenFailed`).** Startup
  aborts with a clear message naming the failure shape per the
  open-failure policy above. The operator either drops
  `--midi-device` or fixes the system PortMIDI install.
- **Device id mismatch (`MmppNoInputDevice`).** Same startup
  abort path; message names "no input device for --midi-device
  N" so the operator knows to re-run `--midi-list`.
- **VMPK note-on noise.** The MIDI keyboard area of VMPK emits
  note-on / note-off, not CC. Those route to `MmliIgnoredEvent`.
  Default to silent (see decision 3); a noisy default would
  drown the operator transcript.
- **Reload during a CC stream.** The reload-window taxonomy in
  decision 3 covers this; VMPK does not buffer, so the typical
  outcome is one or two `midi reject (reload-window):` lines
  during the swap.
- **Reload-time MIDI re-open fails.** Supervisor escalation
  handles it the same way it handles an OSC reopen failure; no
  3c-specific path.
- **Source-close failure on a generation.** Surfaces via
  `mmioohOnSourceCloseFailed`, not via the manager's `Either`,
  per the landed adapter contract. The combined ops just
  inherits this behavior.
- **ALSA / PortMIDI stderr noise on startup.** Pre-existing
  watch item; 3c does not regress it but does not solve it
  either. Mention in the manual pass writeup if it's worse than
  baseline.

## Non-Goals

- No physical MIDI hardware verification (follow-on slice).
- No in-process "send CC" operator command.
- No UI ingress (deferred to its own design pass).
- No channel-routing / per-channel voice selection beyond what
  `mmciChannel` already carries.
- No MIDI-CC → manifest-rebinding live editing.
- No PortMIDI source hot-swap (device id is fixed at startup).
- No extension of `mmlhOnAccepted`'s payload to carry raw
  CC / channel; the accept line renders only what survives the
  hook boundary in 3c (see decision 3).
- No "warn and continue OSC-only" degrade path on
  `--midi-device` failure; that is a separate slice.
- No per-demo `mritpMIDIDefaultVoice` machinery; the policy is
  pinned to `v0` for now.

## Open questions to resolve before code

1. **Ignored-event policy.** Silent by default is the proposal.
   If the manual pass reveals operator confusion ("is MIDI
   working at all?"), revisit with a rate-limited diagnostic.
2. **Default-voice policy corner cases.** Pinning
   `mritpMIDIDefaultVoice = VoiceKey "v0"` works for the
   saw/noise demo. The corner case is a demo whose only template
   is literally named `fx` (the auto-start policy keeps `fx` as
   the voice, and `v0` would not be live). No such demo exists
   today; resolve the corner case only when one arrives.
3. **Combined-ops module placement.** Default position is a new
   `MetaSonic.App.ManifestLiveIngressOps` module beside the OSC
   and MIDI ingress-ops modules. Appending into
   `ManifestLiveCommon` would couple orchestration to the
   live-config bag and make 3c's footprint harder to read.
   Confirm at the start of step 3.

## Validation plan

1. `just stack-test` (combined ingress ops tests, hook renderer
   tests, CLI plumbing tests, live-session wiring smoke).
2. `git diff --check`.
3. Manual ALSA / PortMIDI transcript at
   `/tmp/metasonic-live-session-8h-3c-sclang.log`, recorded with
   `script -q`.
4. Findings entry in
   `notes/2026-05-21-b-live-session-operator-pass-playbook.md`
   on close-out.
5. ROADMAP update: name the combined ingress ops module and the
   threaded `--midi-device` consumer; flip the residual
   "operator-visible MIDI `values`" item to closed; carry the
   physical-hardware verification as a new follow-on watch item
   if still open.
