# Preserving Reload Ingress Binding Policy

Date: 2026-05-15

Status: design pin. Captures what `mrlpControlSurface` and
`mrlpArbitrationPolicy` are supposed to translate into when the
preserving-reload host opens "fresh ingress" against the same live owner,
and which sub-questions remain open before real OSC/MIDI/UI listeners can
be wired against the landed strategy substrate.

Implementation update: the combined ingress target has landed as
`MetaSonic.App.ManifestReloadIngressTarget.ManifestReloadIngressTarget`,
projected by `manifestReloadIngressTargetFromPlan` from a
`ManifestReloadIngressTargetPolicy` plus the validated reload plan; the
strategy CLI smoke (`--manifest-host-reload-smoke`) now opens fresh
ingress against this combined target instead of a UI-only one. The
projection composes the three per-producer projections below; duplicate
CC numbers in the manifest surface as a construction failure so the
orchestrator cannot open a partial surface.

Step 1 of device-backed OSC has also landed as
`MetaSonic.App.ManifestOSCListener`. It composes the existing UDP
listener substrate (`MetaSonic.OSC.Listen.withListenerLoop`) with the
manifest-target validator (`submitManifestOSCMessage`) and exposes both
a bracketed `withManifestOSCListener` and a handle-style
`openManifestOSCListener` / `closeManifestOSCListener` API. Each
received datagram is parsed, projection-validated against the supplied
`ManifestOSCIngressTarget`, and either accepted into the OSC producer
or dropped at the manifest layer — packets aimed at controls absent
from the current manifest never reach `MetaSonic.Session.OSCProducer`.

Step 2 has also landed as
`MetaSonic.App.ManifestOSCIngressOps.manifestOSCIngressOps`. It is an
adapter from `ManifestReloadIngressTarget` to
`ManifestReloadIngressOps`: `mrioOpenIngress` calls
`openManifestOSCListener` against `mitOSC target`, packaging the
listener handle plus its `ListenerInfo` into
`ManifestOSCIngressHandle`; `mrioCloseIngress` calls
`closeManifestOSCListener`; open failures surface as
`MoioiOpenFailed`. The combined target's UI and MIDI projections ride
through unchanged for future steps. Host-level tests prove that
`openFreshManifestReloadIngress` against a different target really
swaps device-backed OSC ingress (old paths reject, new paths accept),
and that an open failure on a fresh reopen leaves the manager closed
without dirtying the fan-in queue.

The UI ingress projection has landed as
`MetaSonic.App.ManifestReloadBinding.ManifestUIIngressTarget` plus a
concrete consumer `MetaSonic.App.ManifestReloadUIIngress`. Last-written
UI values are stored producer-local in a caller-owned
`Map ControlTag Value` that is updated only on accepted fan-in enqueue
and threaded back into `manifestUIIngressTargetFromPlan` at the next
reload. The OSC pair has also landed as
`MetaSonic.App.ManifestReloadOSCBinding.ManifestOSCIngressTarget` plus a
no-socket consumer `MetaSonic.App.ManifestReloadOSCIngress` that
decodes a received `OscMessage` through the existing symbolic parser,
validates the tag against the projection, and forwards through
`MetaSonic.Session.OSCProducer`. The MIDI pair has also landed as
`MetaSonic.App.ManifestReloadMIDIBinding.ManifestMIDIIngressTarget`
plus a no-device consumer `MetaSonic.App.ManifestReloadMIDIIngress`
that projects only controls with `mcsCC = Just`, rejects duplicate CC
numbers at projection time, scales 7-bit CC values through the
binding range, and enqueues `CmdControlWrite` against a
producer-configured default voice under `midiProducerId`. The strategy
CLI smoke (`--manifest-host-reload-smoke`) now drives the device-backed
OSC ingress path: `runManifestHostStrategyReloadSmokeWithCatalog`
builds real `manifestOSCIngressOps`, performs a real initial open
against the OSC projection (surfacing bind failure as a CLI-level
`MrciOSCIngressOpenFailed`), and the rendered snapshot reports the
bound UDP port via `oscPort=`. The first end-to-end packet-traffic
test has also landed
(`MetaSonic.Spec.AppManifestOSCReloadE2E`): it builds a two-entry
custom catalog with disjoint control surfaces, sends a real UDP
packet to the initial listener and observes acceptance, runs
`reloadManifestHostWithStrategy TryPreservingThenStoppedAudio`
(falls back to stopped-audio in the current empty-owner setup),
then sends old-path and new-path packets to the post-reload listener
and observes manifest rejection / acceptance respectively. A
true-preserving variant with live-voice scaffolding and a
PortMIDI-backed MIDI lifecycle remain ahead.

## The question

After a preserving reload succeeds, the orchestrator calls
`openFreshManifestReloadIngress` with `mrhcNewIngressTarget`. The same
session owner is still live, but the graph it runs has changed. The host
needs a concrete rule for what gets reopened.

The plan field that carries the answer-space is split:

- `mrlpControlSurface :: [ManifestControlSurface]` — display name,
  `ControlTag`, default, range, smoothing, optional `mcsCC`.
- `mrlpArbitrationPolicy :: ArbitrationPolicy` — currently always
  `FifoOnly` from the planner.

The ingress manager itself is generic over `target`. It does not know
about OSC, MIDI, or UI. Today `mrhcOldIngressTarget` and
`mrhcNewIngressTarget` are supplied by the caller, and tests use opaque
sentinel values. The "fresh open" is opaque from the manager's
perspective.

The unresolved part is who derives the new target from
`mrlpControlSurface` plus `mrlpArbitrationPolicy`, and what the resulting
listener/producer surface concretely looks like per producer kind.

## What is decided today

- Preserving reload keeps the live owner. Voices in `ssVoices` survive
  the swap. Audio does not stop.
- The ingress manager is closed during quiesce and reopened after the
  preserving command commits. It is opened against a fresh `target`,
  not resumed on the old one.
- `mrlpControlSurface` is captured in the plan, rendered by the CLI
  smoke, and consumed by the landed UI projection plus producer binding
  (`ManifestUIIngressTarget` / `submitManifestUIIngress`), the landed
  OSC projection plus no-socket consumer (`ManifestOSCIngressTarget` /
  `submitManifestOSCMessage`), and the landed MIDI projection plus
  no-device consumer (`ManifestMIDIIngressTarget` /
  `submitManifestMIDICCEvent`).
- `mrlpArbitrationPolicy` defaults to `FifoOnly`. The planner does not
  emit any other policy.
- UI retain-across-reload is producer-local: the caller threads a
  `Map ControlTag Value` through `submitManifestUIIngress`, and that
  same map feeds `manifestUIIngressTargetFromPlan` on the next reload.

## v1 binding rule per producer kind

Before real listeners are wired, the binding rule should be:

Session writes target `(VoiceKey, ControlTag)`, not `ControlTag` alone.
`ManifestControlSurface` only supplies the tag, so each producer binding
must say where its `VoiceKey` comes from. That mapping is producer
policy, not manifest data, and v1 should encode it explicitly per
producer kind below rather than leave it implicit.

**UI ingress.** *Landed.* The fresh target is the set of
`ManifestControlSurface` entries, projected to a UI control list
(display name, range, default, smoothing, current value) by
`manifestUIIngressTargetFromPlan`. Each control becomes a UI binding
keyed by its `ControlTag`. Surviving tags retain their last-written
value (tagged `MuicRetainedValue`); new tags initialize to `mcsDefault`
(tagged `MuicManifestDefault`); removed tags are dropped. The retained
store is producer-local: a caller-owned `Map ControlTag Value` threaded
through `submitManifestUIIngress`, updated only on accepted fan-in
enqueue, and passed back into the projection on the next reload (see
sub-question 2 for the decision rationale). `VoiceKey` is the host-
selected target — focused voice or producer-supplied default — encoded
as `ManifestUIVoiceSelection { focusedVoice, defaultVoice }` on the
target. The manifest does not currently distinguish global from per-
voice controls, so v1 routes UI writes to whichever voice the host UI
has focused, falling back to the default for unfocused writes.

**OSC ingress.** The fresh target is an OSC address namespace derived
deterministically from `ControlTag` — concretely, a stable address
function over the tag's migration key plus slot index. Re-handshake of
external OSC clients is not required as long as the address function
remains pure of plan state. New tags appear, removed tags stop
matching. `VoiceKey` already rides in the OSC address: today's listener
decodes `/<voice>/<tag>/<slot>` into a `CmdControlWrite` whose key is
the path-supplied `VoiceKey`. Reload does not change this contract; the
new address namespace is the union of surviving and new tags, and the
voice component is always client-supplied.

**MIDI ingress.** *Landed.* The fresh target is a CC routing table
built from entries where `mcsCC` is `Just cc`, projected by
`manifestMIDIIngressTargetFromPlan`. The projection rejects duplicate
CC numbers at build time (`MmpiDuplicateCC` carries the colliding tags
in manifest order). If the new manifest changes a tag's CC number, the
old CC mapping is dropped and the new CC mapping is installed; if a
tag drops its `mcsCC`, no MIDI binding exists for it after reload. The
session's symbolic control write is what producers emit; the
listener-local CC→tag table is what changes. `VoiceKey` for a MIDI CC
has no caller-supplied source — v1 routes MIDI CCs to a
producer-configured default voice carried on the target as
`mmitDefaultVoice` (typically the singleton fx voice). The consumer
`submitManifestMIDICCEvent` validates channel and data bytes, scales
the 7-bit value through the binding's `[mmcbRangeMin, mmcbRangeMax]`
range, and enqueues a single `CmdControlWrite` against the default
voice under `midiProducerId` — bypassing the active-notes routing in
`MIDIProducer.controlChange` because the v1 binding policy targets a
fixed voice, not the currently-held notes. Per-channel-to-voice
mapping remains a producer-local concern, not a manifest concern.

**Arbitration.** The fresh target reads `mrlpArbitrationPolicy` and
re-applies it to the session's arbitration layer. With `FifoOnly` the
re-apply is a no-op. The policy is not preserved across the reload as
"the policy that was in effect"; the manifest is authoritative because
the producers are about to be rebound.

Across all three producer kinds, the binding rebuild happens **before
those producers can enqueue again**. The orchestrator's
`hproResumeService` runs before `hproReopenIngress`, so the
SessionFanInService is back online ahead of concrete listeners — direct
service enqueueing is a separate host discipline that must not race the
binding rebuild. The contract that this note pins is narrower: a
concrete UI/OSC/MIDI listener cannot enqueue against the new graph
until its binding has been rebuilt against the new control surface.

## Remaining ingress policy questions

These should be resolved before wiring more device-backed listener
behavior:

1. **Who derives `mrhcNewIngressTarget`?** *Decided.* Pure per-producer
   projections are landed for all three kinds
   (`manifestUIIngressTargetFromPlan`,
   `manifestOSCIngressTargetFromPlan`,
   `manifestMIDIIngressTargetFromPlan`), each taking the producer
   policy that the manifest does not own (UI voice selection plus
   retain map; MIDI default voice). They are composed by
   `manifestReloadIngressTargetFromPlan` into a single
   `ManifestReloadIngressTarget` record carried as
   `mrhcNewIngressTarget`. Construction is a pure function from
   `ManifestReloadIngressTargetPolicy` plus the validated plan; it
   can fail with `ManifestMIDIProjectionIssue` if MIDI CC numbers
   duplicate. The strategy CLI smoke now opens fresh ingress against
   this combined target instead of the UI-only sentinel it used
   before. The OSC listener has also landed plus its
   `ManifestReloadIngressOps` adapter
   (`MetaSonic.App.ManifestOSCIngressOps`), so the only remaining
   factory question is whether a host-supplied wrapper around this
   projection plus a PortMIDI device lifecycle is needed once MIDI
   gets its own device-backed listener — likely yes, but that wrapping
   is host policy, not manifest policy.
2. **Last-written value store for retain-across-reload.** *Decided for
   UI and no-device MIDI; open for OSC and device-backed MIDI policy.*
   v1 retains surviving tags' last-written values for UI: the
   implementation is producer-local (`submitManifestUIIngress` threads
   a `Map ControlTag Value` in and out, updating it only on accepted
   fan-in enqueue). The no-device MIDI consumer carries no retain map
   because CC values flow continuously from a device — the next CC
   event replaces whatever the producer last wrote without needing a
   producer-local cache. What remains open is whether OSC uses the
   same per-producer cache shape as UI, shares one, or reads back from
   the live owner's control state, and whether a device-backed MIDI
   path will eventually want a snapshot (e.g. to seed a UI mirror at
   reload time) — different choices have different consistency
   guarantees when several producers wrote to the same tag before
   reload.
3. **MIDI mapping migration.** *Decided for the no-device slice.* The
   reopen path closes the old ingress target before opening the new
   one (the ingress manager is binary, not partial), so the old CC
   table is structurally gone by the time the new table accepts
   events. There is no "silence the old CC first" step inside the
   projection itself. What is still open is operator UX: hardware that
   holds a CC value between reloads will start emitting against the
   new mapping on the operator's next nudge, with no replay of the
   last value through the new tag — equivalent to UI's "new control
   starts at manifest default" rule.
4. **OSC subscription state.** Do bundle-listener subscriptions
   survive? If the address function is deterministic over `ControlTag`,
   subscriptions to surviving tags continue to work. Subscriptions to
   removed tags become silent. Worth documenting as part of the address
   function contract, not the reload contract.
5. **Arbitration policy in non-FifoOnly modes.** The planner currently
   only emits `FifoOnly`. If a future manifest field selects
   `ProducerPriority` or `TargetClaim`, does the policy mutation happen
   at reopen time, or is it a separate session-level command after the
   reopen completes? Until the planner emits anything but `FifoOnly`,
   this is theoretical.
6. **Failure of the binding rebuild.** If UI/OSC/MIDI binding
   construction fails, that is reported as `HpariIngressRestartFailed`
   via the ingress factory's `issue` type. The orchestrator already
   leaves the new graph live and ingress closed in that case. The host
   must decide whether to retry the binding rebuild, escalate to
   stopped-audio, or surface to the operator. The strategy selector
   currently does the third by default (no fallback after install).

## What v1 explicitly does not decide

- Whether `mrhcNewIngressTarget` is a record, a function, or a sum
  type. Pick at the wiring slice, not here.
- Whether UI binding diffing emits user-visible events ("control X
  added", "control Y removed"). Operator UX choice, not a reload
  invariant.
- Whether the binding rebuild is the moment to flush coalesced control
  writes from the old surface. Coalescing policy is owned by
  [Session Control Coalescing And Arbitration](2026-05-13-o-session-control-coalescing-arbitration.md);
  reload should not invent flush semantics.
- Whether the fresh target can be opened with partial success (UI yes,
  MIDI no). The ingress manager is binary: open or closed. Partial
  surfaces are a host-level concern, not a manager-level concern.

## Cross-references

- Producer/listener coexistence and arbitration rules:
  [Session Producer Coexistence And Arbitration](2026-05-14-a-session-producer-coexistence-arbitration.md).
- Manifest reload runtime strategy (where the plan came from):
  [Manifest Reload Runtime Strategy](2026-05-14-i-manifest-reload-runtime-strategy.md).
- Strategy boundary between stopped-audio and preserving paths:
  [Path To Hot-Swap Reloading Running Graphs](2026-05-15-a-path-to-hot-swap-reloading-running-graphs.md).
- Current architectural surface diagram with the remaining dashed node:
  [Hot-Swap Reload Current Interaction Graph](2026-05-15-b-hot-swap-reload-current-interaction-graph.md).
