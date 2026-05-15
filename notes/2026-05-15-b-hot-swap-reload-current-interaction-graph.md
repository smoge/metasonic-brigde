# Hot-Swap Reload Current Interaction Graph

Date: 2026-05-15

Status: architecture diagram. This note records how the current manifest
reload, session owner, fan-in, and hot-swap pieces interact as of this
checkout. It does not propose new semantics beyond the gaps explicitly marked
as still open.

![MetaSonic manifest reload and hot-swap interaction graph](./2026-05-15-b-hot-swap-reload-current-interaction-graph.svg)

Graph source:
[`2026-05-15-b-hot-swap-reload-current-interaction-graph.dot`](./2026-05-15-b-hot-swap-reload-current-interaction-graph.dot)

## Reading The Graph

The solid paths are implemented today:

- `MetaSonic.Session.ManifestReload` validates an `AuthoringManifestDoc`
  against the app catalog and builds a `ManifestReloadPlan`.
- `manifestReloadCommand` projects that plan into
  `CmdHotSwapPreservingOnly`, so runtime clear/rebuild fallback is rejected
  rather than silently used.
- `constructManifestSessionFromPlan` constructs a fresh owner from a plan. It
  is construction-time only and does not reload an existing owner.
- `reloadManifestSessionStoppedAudio` is the landed session-layer stopped-audio
  helper. It replaces the fan-in host owner only after the caller has stopped
  audio, quiesced producers/listeners, and drained accepted queue work.
- `reloadManifestStoppedAudioHost` wires the app-level stopped-audio sequence:
  plan, quiesce ingress, drain, stop old audio, replace owner, start new audio,
  and reopen ingress.
- `reloadManifestSessionPreservingHotSwap` submits a prevalidated plan through
  the live fan-in path and records enqueue/drain/snapshot state.
- `HostPreservingReloadOps` and `reloadManifestPreservingHost` wire the
  app-level preserving sequence: plan, quiesce ingress, drain accepted work,
  submit preserving hot-swap, resume service, and open fresh ingress for the
  same owner.
- `reloadManifestHostWithStrategy` chooses explicitly among
  `RequirePreserving`, `TryPreservingThenStoppedAudio`, and
  `StoppedAudioOnly`. Fallback is visible in the result type and is allowed
  only from the retryable preserving rejection shape.
- `CmdHotSwap` and `CmdHotSwapPreservingOnly` both reach the real
  `RTGraphAdapter.runHotSwap` path through `SessionState`,
  `stepSessionCommand`, and `stepSessionOwner`.
- When the resolve preview has preserved bindings, `runHotSwap` uses
  `preservingHotSwapPlan` and then the preserving runtime path. If audio is
  running, `runLiveHotSwapProtocol` pins the order: read generation, acquire,
  publish, wait, collect retired stats, and verify migration.

The only dashed node in this note is still open:

- concrete producer/listener binding policy for real app ingress after a
  successful preserving manifest swap. The abstract host path already opens a
  fresh ingress generation for the same live owner, but concrete OSC/MIDI/UI
  binding rebuild has not been exposed as a product path.

## Current Boundary To Keep Clear

The stopped-audio path is an implemented sibling strategy. It is not the live
preserving path. The preserving manifest path consumes the same
`ManifestReloadPlan`, but uses its own named helper and orchestration shape so
it cannot quietly call the stopped-audio owner replacement path.

The most important remaining gap is no longer the preserving-only manifest
path itself. It is exposing the landed strategies through concrete app ingress
and operator-facing commands without making silent fallback or default live
reload claims.
