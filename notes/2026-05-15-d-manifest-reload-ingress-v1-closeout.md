# Manifest Reload Ingress v1 Closeout

Date: 2026-05-15

Status: checkpoint. Captures the durable "what landed / what remains"
boundary for v1 of the manifest reload ingress arc. Use this when
deciding whether a follow-up belongs in v1 polish, in a deliberate v2
slice, or in a separate concern (live demo path, hardware-CI). Not a
design pin; design pins are
[Manifest Reload Install Strategy](2026-05-14-g-manifest-reload-install-strategy.md),
[Manifest Reload Runtime Strategy](2026-05-14-i-manifest-reload-runtime-strategy.md),
[Host Stopped-Audio Manifest Reload Orchestration](2026-05-14-j-host-stopped-audio-manifest-reload-orchestration.md),
[Manifest Reload Host Supervisor And Recovery Policy](2026-05-14-k-host-reload-supervisor.md),
and
[Preserving Reload Ingress Binding Policy](2026-05-15-c-preserving-reload-ingress-binding-policy.md).

## v1 scope

What is in tree and tested at this checkpoint:

- **Planner.** Pure `MR.planManifestReload` validates the catalog
  against an external manifest doc, projects the per-template graphs,
  the static resource policy (`RTGraphAdapterOptions`), the control
  surface, the arbitration policy (always `FifoOnly` from v1), and
  the `CmdHotSwap` / `CmdHotSwapPreservingOnly` command. Construction
  and stopped-audio reload helpers ride on this plan; CLI diagnostics
  (`--manifest-reload-plan`, `--manifest-reload-plan-file`,
  `--manifest-session-smoke`,
  `--manifest-stopped-audio-reload-smoke`) cover the no-audio surface.

- **Strategy selector.** `reloadManifestHostWithStrategy` exposes
  `RequirePreserving`, `TryPreservingThenStoppedAudio`, and
  `StoppedAudioOnly`. The fallback mode records which strategy ran and
  falls back only from the retryable preserving-rejection shape where
  the old owner is still installed and old ingress has resumed; it
  never silently falls back after the preserving path mutated the
  live owner. `--manifest-host-reload-smoke STRATEGY MANIFEST.json
  DEMO` exposes the selector with fake audio lifecycle hooks.

- **UI / OSC / MIDI ingress projections.** Pure per-producer
  projections from the validated plan: `manifestUIIngressTargetFromPlan`
  (UI), `manifestOSCIngressTargetFromPlan` (OSC),
  `manifestMIDIIngressTargetFromPlan` (MIDI, CC-only with duplicate-CC
  rejection at build time). Composed by
  `manifestReloadIngressTargetFromPlan` into a single combined
  `ManifestReloadIngressTarget` record that the ingress manager opens
  fresh on each reload. Per-producer consumers
  (`submitManifestUIIngress`, `submitManifestOSCMessage`,
  `submitManifestMIDICCEvent`) validate the projection against an
  already-decoded write and forward through the corresponding
  session producer.

- **OSC ingress ops.** `manifestOSCIngressOps` is the
  `ManifestReloadIngressOps` adapter for OSC: `mrioOpenIngress`
  drives `openManifestOSCListener` against `mitOSC target` and
  returns a handle carrying the listener plus its bound
  `ListenerInfo`; `mrioCloseIngress` releases the listener and the
  UDP socket. The strategy CLI smoke opens this adapter end-to-end
  (real initial bind, real `closeOld + openFresh`, bound
  `oscPort=` rendered in the output, `MrciOSCIngressOpenFailed`
  surfaces real bind failure as a CLI issue).

- **MIDI ingress ops.** `manifestMIDIIngressOps` is the
  `ManifestReloadIngressOps` adapter for MIDI: it accepts a
  bracket-shaped `ManifestMIDISourceFactory issue source` so the
  same shape carries both PortMIDI-backed and test-only sources,
  owns the caller-typed source handle plus the listener handle, and
  closes them listener-first to satisfy the PortMIDI
  single-consumer contract. Source-close failure after the
  listener has stopped fires an adapter hook
  (`mmioohOnSourceCloseFailed`) but still reports a clean close to
  the ingress manager, so the manager's `MrisClosed` state stays
  honest. The listener itself
  (`MetaSonic.App.ManifestMIDIListener`) routes
  `MIDIProducerControlChange` through `submitManifestMIDICCEvent`
  and surfaces non-CC events via the `MmliIgnoredEvent` diagnostic;
  it deliberately does not wrap `MetaSonic.Session.MIDIListener`,
  whose note/sustain/coalescing semantics belong to the rich
  session path, not the v1 manifest path.

- **OSC end-to-end coverage.**
  `MetaSonic.Spec.AppManifestOSCReloadE2E` runs both
  `reloadManifestHostWithStrategy TryPreservingThenStoppedAudio`
  variants under real UDP traffic before and after the swap. The
  fallback variant uses a two-entry catalog with disjoint control
  surfaces against an empty-owner setup. The preserving variant
  installs a live voice via `CmdVoiceOn` on the
  `hotSwapEdit` / `hotSwapEditAfterTemplates` graph pair and
  asserts `Right MrhsrPreserving`, no captured `AudioStop` events,
  `sfisAudioRunning == True`, voice survival in `ssVoices`, the
  new graph installed, and old/new OSC paths swapping correctly.

- **MIDI end-to-end coverage.**
  `MetaSonic.Spec.AppManifestMIDIReloadE2E` mirrors the OSC pair
  under real CC traffic via a `Chan`-backed source factory. The
  fallback variant uses two-entry catalogs with disjoint CC
  bindings (CC 7 old, CC 11 new); the preserving variant reuses the
  same preserving-compatible graph pair and asserts the same set of
  preserving invariants under MIDI CC swap. CI is `Chan`-backed and
  device-free.

- **PortMIDI source factory.**
  `manifestPortMIDISourceFactory` is the production-side
  counterpart to the `Chan` test factory. It opens via
  `openPortMIDISource`, distinguishes the `Nothing`-open case
  (`MmppOpenFailed`) from the idle-handle case
  (`portMIDISourceHasDevice == False`) by closing the idle handle
  and reporting `MmppNoInputDevice`, and yields
  `portMIDIListenerSource opts source` on the device-active
  success path. CI-safe tests cover the `NoInputDevice` branch via
  the invalid-device-id idiom and confirm it composes with
  `manifestMIDIIngressOps` surfacing as
  `MmioiSourceOpenFailed MmppNoInputDevice`.

- **Manual MIDI device smoke.**
  `MetaSonic.App.ManifestMIDIReloadSmoke` plus
  `--manifest-midi-reload-smoke MANIFEST.json DEMO` is the
  operational counterpart to the CI-safe MIDI tests. It opens a
  real PortMIDI input through the factory, runs
  `manifestMIDIIngressOps` against the plan's MIDI ingress
  projection, prints accepted `CmdControlWrite` lines plus
  manifest-layer rejects (unbound CC, invalid byte, channel
  filtered, enqueue rejected) and ignored non-CC events, then
  closes cleanly. It is the only path that exercises the
  `hasDevice == True` branch of `manifestPortMIDISourceFactory`,
  because CI cannot make a real PortMIDI input deterministic.
  Exits non-zero only when the factory cannot produce an
  input-capable source; empty event counters are summary-only.
  Does not start audio, run a hot-swap, or claim reload semantics.

## Explicit non-goals

These were considered and explicitly left for later:

- **No default live demo path.** None of the manifest reload modes is
  the default for any built-in demo, none is reachable from the
  normal `metasonic-bridge` entry, and none of the built-in audible
  demos has been ported to flow through the manifest reload
  pipeline. The reload modes are operator-visible diagnostics and
  manual smokes; a "live demo that uses manifest reload" is a
  separate concern.

- **No automatic fallback hidden from the caller.**
  `TryPreservingThenStoppedAudio` records which strategy actually
  ran and only falls back from the retryable preserving-rejection
  shape; once the preserving path has changed the live owner,
  fallback is not attempted. Callers that need a different recovery
  shape compose strategies explicitly rather than relying on a
  hidden retry policy.

- **No full MIDI note ownership / active-note routing in the
  manifest path.** The v1 manifest MIDI listener routes only
  `MIDIProducerControlChange` through `submitManifestMIDICCEvent`,
  against a producer-configured default voice. Note on/off,
  pitch-bend, all-notes-off, and the active-notes routing in
  `MIDIProducer.controlChange` remain on the rich session MIDI
  path, not the manifest path; non-CC events are surfaced via the
  `MmliIgnoredEvent` diagnostic. The decision is in
  [Preserving Reload Ingress Binding Policy](2026-05-15-c-preserving-reload-ingress-binding-policy.md).

- **No resource/allocation recovery event stream yet.** The
  ingress manager surfaces open and close failures through the
  factory's `issue` type, and the strategy selector surfaces
  preserving / stopped-audio outcomes. A broader observability
  stream for graph allocation, polyphony pool exhaustion, audio
  ready / not-ready transitions across reload, or operator-visible
  recovery progress is not designed yet — there is no concrete
  consumer asking for the shape, and the supervisor recovery
  contract in
  [Manifest Reload Host Supervisor And Recovery Policy](2026-05-14-k-host-reload-supervisor.md)
  encodes recovery as bounded retries plus escalation rather than
  an event stream.

- **No device-backed end-to-end test in CI.** PortMIDI hardware
  state is not deterministic in CI, and the running MIDI through
  port on a developer host is not enough to gate merges on. The
  manual MIDI smoke covers the device boundary; promoting that to
  CI requires a stable hardware fixture.

## Remaining work

What is *not* done and would be a future v2 slice, *not* v1 polish:

- **Resource/allocation recovery events.** Once a real consumer
  exists — a UI surface that wants to render install progress, a
  supervisor that wants per-stage telemetry, or a CI gate that
  wants to count audio restarts during a reload — design the event
  stream to fit that consumer. Designing it speculatively now would
  land in a shape nobody uses.

- **Operator UX polish based on manual smoke use.** The manual
  MIDI smoke and the `--manifest-host-reload-smoke` strategy smoke
  are deliberately minimal: header, per-event log lines, summary
  counters, exit code on hard open failure. Real operator use will
  surface friction (e.g. printing the bound CC table once but not
  hot-reloading when the manifest changes mid-window; nudging the
  operator to send a specific CC; rendering raw byte values
  alongside scaled values) that should be addressed when a real
  use case asks. This is polish on a manual surface, not a
  contract change.

- **Broader device-backed CI.** If a stable hardware environment
  exists, both `manifestPortMIDISourceFactory`'s `hasDevice ==
  True` branch and the `--manifest-host-reload-smoke`'s real OSC
  bind path could move from manual smoke into hardware-gated CI.
  The shape is ready; the fixture is the gate.

## Cross-references

- Strategy boundary and preserving vs stopped-audio decision:
  [Path To Hot-Swap Reloading Running Graphs](2026-05-15-a-path-to-hot-swap-reloading-running-graphs.md).
- Current architectural surface diagram:
  [Hot-Swap Reload Current Interaction Graph](2026-05-15-b-hot-swap-reload-current-interaction-graph.md).
- Binding policy decisions per producer kind:
  [Preserving Reload Ingress Binding Policy](2026-05-15-c-preserving-reload-ingress-binding-policy.md).
- Supervisor recovery contract:
  [Manifest Reload Host Supervisor And Recovery Policy](2026-05-14-k-host-reload-supervisor.md).
- Producer coexistence and arbitration:
  [Session Producer Coexistence And Arbitration](2026-05-14-a-session-producer-coexistence-arbitration.md).
