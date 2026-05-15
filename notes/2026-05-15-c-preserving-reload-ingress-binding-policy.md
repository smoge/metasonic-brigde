# Preserving Reload Ingress Binding Policy

Date: 2026-05-15

Status: design pin. Captures what `mrlpControlSurface` and
`mrlpArbitrationPolicy` are supposed to translate into when the
preserving-reload host opens "fresh ingress" against the same live owner,
and which sub-questions remain open before real OSC/MIDI/UI listeners can
be wired against the landed strategy substrate.

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
  smoke, and otherwise pure data with no producer bound to it.
- `mrlpArbitrationPolicy` defaults to `FifoOnly`. The planner does not
  emit any other policy.

## v1 binding rule per producer kind

Before real listeners are wired, the binding rule should be:

Session writes target `(VoiceKey, ControlTag)`, not `ControlTag` alone.
`ManifestControlSurface` only supplies the tag, so each producer binding
must say where its `VoiceKey` comes from. That mapping is producer
policy, not manifest data, and v1 should encode it explicitly per
producer kind below rather than leave it implicit.

**UI ingress.** The fresh target is the set of `ManifestControlSurface`
entries, projected to a UI control list (display name, range, default,
smoothing, current value). Each control becomes a UI binding keyed by
its `ControlTag`. Surviving tags retain their last-written value as
v1 policy; new tags initialize to `mcsDefault`; removed tags are
dropped. The implementation shape that holds last-written values
across a reload is left open (see sub-question 2). `VoiceKey` is the
host-selected target — typically the singleton fx voice for global
controls, or the operator-selected voice for per-voice controls. The
manifest does not currently distinguish global from per-voice
controls, so v1 routes UI writes to whichever voice the host UI has
focused, and a producer-supplied default voice key for unfocused
writes. That means the UI ingress target is not just a projected
control list: it must also carry a host-supplied voice-selection policy
for resolving "focused voice" plus the default fallback voice.

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

**MIDI ingress.** The fresh target is a CC routing table built from
entries where `mcsCC` is `Just cc`. If the new manifest changes a tag's
CC number, the old CC mapping is dropped and the new CC mapping is
installed. If a tag drops its `mcsCC`, no MIDI binding exists for it
after reload. The session's symbolic control write is what producers
emit; the listener-local CC→tag table is what changes. `VoiceKey` for
a MIDI CC has no caller-supplied source — v1 routes MIDI CCs to a
producer-configured default voice key (typically the singleton fx
voice), the same convention the current MIDI listener already uses.
Per-channel-to-voice mapping is a producer-local concern, not a
manifest concern.

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

## Open sub-questions blocking real listener wiring

These should be resolved before the first non-smoke listener lands:

1. **Who derives `mrhcNewIngressTarget`?** A pure function over
   `ManifestReloadPlan`? Built host-side per app? Both — pure projection
   plus a host-supplied factory? For UI, the derived target must also
   include the host's voice-selection policy, because `ManifestControlSurface`
   alone cannot choose the `VoiceKey` for a control write. The strategy
   CLI smoke ducks this by using opaque sentinel targets.
2. **Last-written value store for retain-across-reload.** v1 retains
   surviving tags' last-written values (decision above). The
   implementation shape is still open: is the cache producer-local
   (each UI/OSC/MIDI binding remembers its own last write), session-
   level (read back from the live owner's control state), or
   manifest-time (a sidecar map keyed by `ControlTag`)? Different
   choices have different consistency guarantees when several
   producers wrote to the same tag before reload.
3. **MIDI mapping migration.** If a CC# moves from one tag to another
   across reload, is the old CC silenced first, or does the new mapping
   replace it atomically? Matters for hardware that holds CC values
   between reloads.
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
