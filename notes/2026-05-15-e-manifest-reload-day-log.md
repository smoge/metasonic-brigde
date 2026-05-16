# Manifest Reload Arc — 2026-05-15 Day Log

Date: 2026-05-15

Status: retrospective log. Captures the chronological trajectory of the
manifest reload ingress arc landed on 2026-05-15, from the fan-in
service substrate that made live reload possible at all to the
audible operator-facing demo at the end of the day. Not a design pin —
design pins for individual decisions are linked inline.

## The arc

At the start of the day the manifest reload story was: a pure planner
plus a non-audio stopped-audio reload helper plus an
operator-invisible host orchestration sketch. The fan-in host's audio
lifecycle and the ingress manager were both stubs.

By the end of the day:

- The fan-in service has an audio-lifecycle seam and a quiesce drain
  handoff that the reload orchestrator can drive.
- A manifest reload ingress manager handles `closeOld + openFresh`
  cycles cleanly, including failure-mode old-owner resume.
- The preserving hot-swap path exists as a distinct command shape
  with its own command, helper, orchestration, and host wiring; it
  is reachable behind an explicit strategy selector.
- UI, OSC, and MIDI ingress projections are derived purely from the
  validated plan and composed into a single combined ingress target.
- Device-backed OSC and source-factory-backed MIDI listeners are wired
  against those projections through `ManifestReloadIngressOps`, with
  both end-to-end packet-traffic test pairs covering the fallback and
  true-preserving paths under real UDP / injected-CC traffic.
- A PortMIDI source factory plus a manual device-backed MIDI smoke
  CLI provide the operator path for exercising the
  `hasDevice == True` boundary that CI cannot reach.
- A v1 closeout note pins the boundary explicitly: what is in scope,
  what is a deliberate non-goal, what remains.
- The first audible consumer of the full pipeline ships as
  `--manifest-live-reload-demo`, an opt-in experimental CLI mode
  that starts audio, drives a real reload across two authored demos,
  and shows the operator the concrete OSC addresses they can send
  packets to.

The day moved through five thematic waves.

## Wave 1 — fan-in substrate and ingress manager (00:29 — 03:07)

What had to land before live reload could even be attempted: the
service needed to expose its audio lifecycle and drain semantics to
the reload orchestrator, and a generic ingress manager had to exist
for the orchestrator to drive.

- `b2d9729` adds the fan-in current-owner audio lifecycle seam:
  `startSessionFanInHostAudioWith` / `stopSessionFanInHostAudioWith`
  operate against the currently-installed owner with explicit failure
  modes for "reload in progress," "no owner," "already stopped,"
  preserving the host's serialized state semantics.
- `f3371a3` adds the fan-in service quiesce drain handoff:
  `stopSessionFanInServiceWorker` lets the orchestrator pause the
  drain worker, drain the queue under host control, and resume —
  the substrate the preserving path needs to quiesce without losing
  buffered work.
- `f34522e` adds the manifest reload supervisor and orchestration
  harnesses: the supervisor's recovery contract (bounded retries,
  single active stack, plan captured per-reload-local) and the
  orchestration scaffolding for stopped-audio / preserving paths.
- `1995fbb` fixes manifest reload old-owner resume paths so a
  retryable failure leaves the old owner installed and the old
  ingress resumed, rather than collapsing into a degenerate state.
- `38f35bb` adds `ManifestReloadIngressManager`: a generic state
  machine over `(target, issue, handle)` parameterized on a
  `ManifestReloadIngressOps`. The manager is binary (`MrisClosed` /
  `MrisOpen target handle`) and doesn't know about OSC, MIDI, or UI;
  it just sequences `closeOld + openFresh` against caller-supplied
  factories.
- `3160269` wires the ingress manager into the orchestration so
  `closeOld + openFresh` runs at the right point in the
  preserving / stopped-audio sequences.
- `9c85d5e` adds the host stopped-audio manifest reload command:
  `reloadManifestSessionStoppedAudio` plus its caller-facing CLI
  smoke. This is the first end-to-end stopped-audio path that
  actually runs against a fan-in host rather than a planner output.
- `784b9ef` adds `tools/render_notes_html.sh` (top-level `notes/*.md`
  to HTML) plus an early hot-swap path note. Design pin:
  [Path To Hot-Swap Reloading Running Graphs](2026-05-15-a-path-to-hot-swap-reloading-running-graphs.md).

By the end of this wave the substrate could in principle support live
reload; nothing was wired through it yet.

## Wave 2 — preserving hot-swap track (12:54 — 15:46)

The substrate was ready, but the preserving path itself needed to
exist as a distinct shape with its own command, helper,
orchestration, and host wiring. Before this wave there was only
stopped-audio reload.

- `c714b94` adds `CmdHotSwapPreservingOnly` and the matching
  `HotSwapPreservingOnly` runtime case: a hot-swap that refuses
  runtime clear/rebuild fallback, surfacing a retryable rejection
  when the graphs are not preserving-compatible. This is the
  command shape the preserving path commits.
- `e0ec54c` adds preserving-only hot-swap coverage: tests pin the
  retryable-rejection contract on incompatible graph pairs and
  voice survival on compatible pairs.
- `af33602` adds the preserving manifest hot-swap helper:
  `reloadManifestSessionPreservingHotSwap` projects a prevalidated
  plan through the live fan-in path without stopping audio or
  replacing the owner.
- `6464b4a` adds the preserving manifest reload orchestration:
  `HostPreservingReloadOps` (quiesce ingress, drain accepted work,
  run preserving command, open fresh ingress) wires the helper to
  the host's audio-running state machine.
- `4a9fa6f` wires `reloadManifestPreservingHost` to the real app
  host pieces (service + ingress manager + audio FFI), so callers
  can drive preserving reload against a running fan-in host without
  hand-assembling the dependencies.
- `c44baaf` adds the strategy selector
  `reloadManifestHostWithStrategy` with three explicit modes:
  `RequirePreserving`, `TryPreservingThenStoppedAudio`,
  `StoppedAudioOnly`. The fallback mode records *which* strategy
  actually ran and only falls back from the retryable
  preserving-rejection shape where the old owner is still installed.
  Design pins:
  [Manifest Reload Install Strategy](2026-05-14-g-manifest-reload-install-strategy.md),
  [Manifest Reload Runtime Strategy](2026-05-14-i-manifest-reload-runtime-strategy.md),
  [Host Stopped-Audio Manifest Reload Orchestration](2026-05-14-j-host-stopped-audio-manifest-reload-orchestration.md),
  [Manifest Reload Host Supervisor And Recovery Policy](2026-05-14-k-host-reload-supervisor.md).
- `879c698` syncs docs with the preserving reload strategy.
- `5d1a3de` adds the manifest host reload strategy CLI smoke
  (`--manifest-host-reload-smoke STRATEGY MANIFEST.json DEMO`), the
  first operator-visible diagnostic that actually runs the strategy
  selector with fake audio lifecycle hooks against a non-device
  fan-in host.
- `dc65732` updates the roadmap for the manifest strategy smoke.

By the end of this wave the strategy selector existed and was
operator-visible, but ingress was a sentinel target — no real OSC or
MIDI was wired.

## Wave 3 — ingress binding projections (15:55 — 17:38)

The strategy selector needed concrete targets to open. This wave
projects the validated plan into pure per-producer ingress targets
(UI, OSC, MIDI), each with its own consumer that forwards through the
session producer without touching real sockets / devices.

- `2905041` writes the binding-policy design note up-front so the
  projection shapes that follow have a documented contract. Design
  pin:
  [Preserving Reload Ingress Binding Policy](2026-05-15-c-preserving-reload-ingress-binding-policy.md).
- `0aea45d` adds `ManifestUIIngressTarget` plus
  `manifestUIIngressTargetFromPlan`: projects controls into a UI
  control list with retain-across-reload as producer-local policy.
- `f2e4584` adds `submitManifestUIIngress`: the no-socket consumer
  that threads a caller-owned `Map ControlTag Value` retain map
  through the projection, updating it only on accepted fan-in
  enqueue, and forwards through `MetaSonic.Session.UIProducer`.
- `500aa79` adds `ManifestOSCIngressTarget` plus the OSC consumer
  `submitManifestOSCMessage`: decodes a received `OscMessage`
  through the symbolic OSC parser, validates the tag against the
  projection, and forwards accepted writes through
  `MetaSonic.Session.OSCProducer`.
- `ec0353b` adds `ManifestMIDIIngressTarget` plus the MIDI consumer
  `submitManifestMIDICCEvent`: CC-only projection with duplicate-CC
  rejection at build time, 7-bit value scaling, and enqueue against
  a producer-configured default voice under `midiProducerId`.
- `f2d097c` composes the three projections into a single
  `ManifestReloadIngressTarget` record and wires it into the
  strategy CLI smoke so the smoke opens fresh ingress against the
  combined target instead of the prior UI-only sentinel.

By the end of this wave the binding shape was settled and pure; no
real device traffic was wired yet.

## Wave 4 — device-backed OSC then device-backed MIDI (19:03 — 21:20)

This wave is the longest single thread of the day: turning the pure
projections into real device-backed listeners that survive a reload
under live UDP/CC traffic, with end-to-end test pairs.

OSC:

- `f941ecb` adds `MetaSonic.App.ManifestOSCListener`: a
  target-aware UDP listener that composes the existing
  `MetaSonic.OSC.Listen.withListenerLoop` substrate with the
  manifest validator `submitManifestOSCMessage`, with both
  bracketed and handle-style entry points. Packets aimed at
  controls absent from the current manifest reject at the
  projection layer.
- `21e38cc` adds the `ManifestReloadIngressOps` adapter
  `manifestOSCIngressOps` so the existing ingress manager drives a
  real UDP listener through `mitOSC target`.
- `95a0588` wires the OSC adapter into the strategy CLI smoke
  end-to-end: real initial open against the OSC projection, real
  `closeOld + openFresh`, bound `oscPort=` rendered in the
  diagnostic output, and `MrciOSCIngressOpenFailed` surfaces real
  bind failure as a CLI issue.
- `3d95b86` adds the end-to-end OSC packet-traffic test
  (`MetaSonic.Spec.AppManifestOSCReloadE2E`, fallback variant):
  two-entry custom catalog with disjoint control surfaces, sends a
  real UDP packet to the initial listener and observes acceptance,
  runs `reloadManifestHostWithStrategy TryPreservingThenStoppedAudio`
  (falls back to stopped-audio in the empty-owner setup), then
  sends old-path and new-path packets to the post-reload listener
  and observes manifest rejection / acceptance respectively.
- `ee3c70a` adds the preserving-path OSC packet-traffic test:
  reuses the existing `hotSwapEdit` / `hotSwapEditAfterTemplates`
  preserving-compatible graph pair, installs a live voice via
  `CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") [...]` before
  the reload, runs the same strategy, and asserts `Right
  MrhsrPreserving`, no `AudioStop` events, audio still running,
  voice survival in `ssVoices`, and old/new OSC paths swap.

MIDI (mirrors the OSC sequence with one important shape difference):

- `72246b0` adds `MetaSonic.App.ManifestMIDIListener`: a worker
  over an injected `MIDIListenerSource` that routes
  `MIDIProducerControlChange` through `submitManifestMIDICCEvent`
  and surfaces non-CC events via the `MmliIgnoredEvent`
  diagnostic. Deliberately does *not* wrap
  `MetaSonic.Session.MIDIListener` because the latter's
  note/sustain/coalescing semantics belong to the rich session
  path, not the v1 manifest path. The non-goal is recorded in the
  closeout note.
- `a6700a2` adds the MIDI `ManifestReloadIngressOps` adapter with
  a **bracket-shaped** `ManifestMIDISourceFactory issue source`.
  The shape matters: a real PortMIDI source owns a device handle
  whose lifetime must be paired with a close action, while a test
  source can supply a trivial handle and a no-op close. Source-close
  failures fire an adapter hook (`mmioohOnSourceCloseFailed`) but
  still report a clean close to the ingress manager so its
  `MrisClosed` state stays honest after the listener is already
  stopped — a manager-level regression test pins this behavior.
- `dcb142a` adds both MIDI end-to-end packet-traffic tests in one
  commit (fallback + preserving) using a `Chan`-backed source
  factory so CI is device-free. The preserving variant reuses the
  same preserving-compatible graph pair as the OSC preserving test
  and asserts the same invariants under CC swap.
- `f45aadc` adds the PortMIDI-backed source factory
  `manifestPortMIDISourceFactory`: opens via `openPortMIDISource`,
  distinguishes the `Nothing`-open case (`MmppOpenFailed`) from
  the idle-handle case (`portMIDISourceHasDevice == False`) by
  closing the idle handle and reporting `MmppNoInputDevice`, and
  yields `portMIDIListenerSource opts source` on the device-active
  success path. The `MmppNoInputDevice` branch is CI-safe via the
  invalid-device-id idiom; the device-active branch is intentionally
  not in CI because PortMIDI is not deterministic.

By the end of this wave the only remaining slice for the v1 arc was
a manual device-backed smoke that actually exercised the
`hasDevice == True` branch.

## Wave 5 — manual MIDI device smoke, closeout, audible demo (21:47 — 23:08)

The final wave of the day landed in this session.

- `6d2d26f` adds the manual MIDI device smoke CLI runner
  `MetaSonic.App.ManifestMIDIReloadSmoke` and the matching
  `--manifest-midi-reload-smoke MANIFEST.json DEMO` mode. It opens
  a real PortMIDI input through `manifestPortMIDISourceFactory`,
  runs `manifestMIDIIngressOps` against the plan's MIDI ingress
  projection, prints accepted `CmdControlWrite` lines plus
  manifest-layer rejects keyed by reason and ignored non-CC events,
  and exits non-zero only when the factory cannot produce an
  input-capable source. It is the only path that exercises the
  `hasDevice == True` branch of `manifestPortMIDISourceFactory` and
  intentionally does not start audio, run a hot-swap, or claim
  reload semantics — it is an operational probe, not a CI test.
- `02fbe25` adds the closeout note and ROADMAP sync. The note pins
  the v1 boundary (planner, strategy selector, UI/OSC/MIDI
  projections, OSC and MIDI ingress ops, both E2E reload-traffic
  test pairs, PortMIDI factory, manual MIDI smoke), the four
  explicit non-goals (no default live demo path, no hidden caller
  fallback, no MIDI note ownership in the manifest path, no
  recovery event stream yet), and what would constitute v2 rather
  than v1 polish. Design pin:
  [Manifest Reload Ingress v1 Closeout](2026-05-15-d-manifest-reload-ingress-v1-closeout.md).
- `09284e9` adds the first **audible** consumer:
  `MetaSonic.App.ManifestLiveReloadDemo` and the matching
  `--manifest-live-reload-demo STRATEGY MANIFEST.json OLD NEW`
  CLI. The demo starts audio from one authored demo, opens
  manifest-aware OSC ingress, auto-starts one voice per template
  so the surface is audible, then on operator Enter runs
  `reloadManifestHostWithStrategy` to swap to a second demo and
  prints what changed. Two operator-visible refinements landed in
  this slice:
  - Listener-hook output is structured: `renderOSCAccept` and
    `renderOSCIssue` render one short line per event rather than
    dumping a full `Show` of the enqueue record.
  - The "addressable OSC surface" block crosses live `ssVoices`
    against the bound controls so the operator sees concrete
    `/<voice>/<tag>/<slot>` addresses to copy into a test sender,
    rather than the literal `<voice>` placeholder
    `renderManifestOSCAddressPattern` emits.
  - The post-reload follow-up prompt branches on the **ingress
    snapshot** rather than the strategy outcome, because the
    strategy's failure paths can leave ingress closed, resumed on
    the old target, or open on the new target — only the snapshot
    reflects reality.

  Explicitly experimental and opt-in: the normal demo path is
  unchanged, no built-in demo defaults to this entry, and the
  helper does not claim that manifest reload is now the default
  live path.

## Tooling and scratch

`tools/render_notes_html.sh` walks top-level `notes/*.md` only.
Scratch material under `notes/lembretes/` (operator-test reminders,
session memos) is intentionally outside the rendered set.

## What this day did not do

By design (closeout note has the long form):

- No default live demo path: no built-in demo runs through the
  manifest reload pipeline by default.
- No automatic fallback hidden from the caller: the strategy
  selector records *which* strategy ran.
- No full MIDI note ownership in the manifest path: only CC is
  routed; note on/off, pitch-bend, all-notes-off remain on the
  rich session MIDI path.
- No resource/allocation recovery event stream: gated on a
  concrete consumer, not designed speculatively.
- No device-backed CI: PortMIDI hardware state is not deterministic
  in CI; the manual MIDI smoke covers the boundary.

## Cross-references

- v1 boundary and remaining work:
  [Manifest Reload Ingress v1 Closeout](2026-05-15-d-manifest-reload-ingress-v1-closeout.md).
- Binding policy decisions per producer kind:
  [Preserving Reload Ingress Binding Policy](2026-05-15-c-preserving-reload-ingress-binding-policy.md).
- Current architectural surface:
  [Hot-Swap Reload Current Interaction Graph](2026-05-15-b-hot-swap-reload-current-interaction-graph.md).
- Strategy boundary:
  [Path To Hot-Swap Reloading Running Graphs](2026-05-15-a-path-to-hot-swap-reloading-running-graphs.md).
- Supervisor recovery contract:
  [Manifest Reload Host Supervisor And Recovery Policy](2026-05-14-k-host-reload-supervisor.md).
- Strategy and orchestration pins:
  [Manifest Reload Install Strategy](2026-05-14-g-manifest-reload-install-strategy.md),
  [Manifest Reload Runtime Strategy](2026-05-14-i-manifest-reload-runtime-strategy.md),
  [Host Stopped-Audio Manifest Reload Orchestration](2026-05-14-j-host-stopped-audio-manifest-reload-orchestration.md).
