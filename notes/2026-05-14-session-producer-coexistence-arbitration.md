# Session Producer Coexistence And Arbitration

Status: pure policy, optional gateway, service-owned opt-in gateway,
service-level rejection observability, the explicit OSC producer service
path, the opt-in OSC listener service path, and the non-audio OSC
arbitration smoke diagnostics landed. The explicit UI producer service
path has also landed. This note records the arbitration boundary after
MIDI listener-local coalescing. It does not change
`MetaSonic.Session.Queue` or `MetaSonic.Session.FanIn`; concrete
producer/listener paths keep FIFO behavior unless a caller explicitly
routes them through `MetaSonic.Session.ArbitrationGateway` or the
arbitrated `MetaSonic.Session.FanInService` enqueue path with a
non-`FifoOnly` policy.

The session layer now has multiple producers that can address the same
symbolic control target:

- Pattern events through `ProducerPattern`;
- OSC symbolic control writes through `ProducerOSC`;
- MIDI note, CC, sustain, pitch-bend, and all-notes-off events through
  `ProducerMIDI`;
- UI intents through `ProducerUI`.

By default, coexistence is strict FIFO at fan-in. If two producers write
the same `(VoiceKey, ControlTag)`, the owner receives both commands in
the observed enqueue order. That is deterministic and testable, but it
is not a musical ownership policy. A remote OSC slider, a MIDI
controller, an automation pattern, and a UI widget may represent
different user intents even when they write the same logical target.

## Current Contract

- `SessionCommand` is the shared producer vocabulary. It deliberately
  does not encode source-specific ownership or priority.
- `ProducerId` is diagnostic identity attached to accepted queued
  commands. It is not authorization.
- `Session.Queue` assigns sequence numbers and preserves strict FIFO
  for commands that producers actually submit.
- `Session.FanIn` serializes enqueue, drain, and snapshot access. It
  does not inspect command targets for ownership.
- `Session.Arbitration` is pure policy state. `FifoOnly` preserves the
  baseline, `ProducerPriority` updates owner state only after accepted
  enqueues, and `TargetClaim` blocks claimed control targets.
- `Session.ArbitrationGateway` is an optional wrapper above fan-in. Its
  default policy is `FifoOnly`; policy rejections happen before enqueue
  and do not consume queue capacity or command sequence numbers.
- `Session.FanInService` can optionally own one arbitration gateway. Its
  raw enqueue path remains FIFO; the arbitrated service enqueue path uses
  the service-owned gateway when configured and otherwise falls back to
  FIFO. Policy rejections from that service-owned path are reported as
  `SfsiiArbitrationRejected`, separate from drain-stop and fan-in
  backpressure issues.
- `Session.OSCProducer` has an explicit arbitrated service enqueue
  helper for symbolic control writes. The existing host-based OSC
  enqueue path remains the default FIFO behavior.
- `Session.OSCListener` has an opt-in service-backed listener wrapper
  that routes decoded packets through the explicit OSC producer
  service path. Its existing host-based listener remains the default
  FIFO behavior.
- `Session.UIProducer` has an explicit arbitrated service enqueue
  helper for already-decoded UI intents. Its existing host-based enqueue
  path remains the default FIFO behavior.
- `--session-osc-arbitration-smoke` exercises the opt-in OSC listener
  service path with a configured `TargetClaim` policy and reports both
  listener-level and service-level arbitration rejection counters. It is
  a non-audio diagnostic probe, not a default live-policy route.
- The landed MIDI coalescer is listener-local. It can merge repeated
  MIDI-origin `CmdControlWrite`s before enqueue, but it cannot merge,
  reorder, or drop another producer's commands.

Those constraints stay load-bearing: a command accepted by fan-in must
remain visible in the drained FIFO stream as itself.

## Problem Shape

The first arbitration target is control writes:

```text
Control target = (VoiceKey, ControlTag)
```

Two producers can currently write the same control target without any
policy beyond enqueue order. That is acceptable as a baseline, but it
does not answer questions such as:

- Should a UI touch override Pattern automation until release?
- Should a MIDI wheel override OSC remote control for a specific voice?
- Should OSC be allowed to write a control that a manifest declares UI
  owned?
- Should Pattern automation keep emitting after a live performance
  gesture takes temporary control?

Voice lifecycle and hot-swap commands are different classes:

```text
Voice target = VoiceKey
Global target = CmdHotSwap
```

They are non-coalescible fences. Any future arbitration around them
must be explicit and conservative because dropping or reordering them
changes session structure, not just a continuous control value.

## Non-Goals

- Do not add cross-producer coalescing to the shared queue.
- Do not make `Session.Queue` or `Session.FanIn` silently drop commands
  that were accepted.
- Do not invent a global priority order without a session or manifest
  policy source.
- Do not turn `ProducerId` into authentication or authorization.
- Do not arbitrate `CmdVoiceOn`, `CmdVoiceOff`, or `CmdHotSwap` in v1.
- Do not require Pattern automation to be continuous-control aware
  before an authoring marker exists.

## Design Principles

- Keep FIFO as the last shared contract. Arbitration must happen before
  enqueue; the v1 surface may be a per-producer gateway, a session policy
  wrapper, or a future orchestration layer.
- Make blocking observable. A producer denied by policy should get a
  typed issue/report that includes producer identity, target, and
  policy reason.
- Scope authority by target. Control ownership should be keyed by
  `(VoiceKey, ControlTag)`, not by a broad producer kind alone.
- Keep Pattern conservative. Authored event timing is data; do not
  collapse or suppress it unless the pattern lane opted into a
  continuous-control policy.
- Prefer opt-in policy. The current FIFO behavior should remain the
  default until a session manifest or caller explicitly requests a
  different arbitration mode.

## Candidate Policy Surface

A later implementation can start as a pure policy layer above fan-in:

```text
producer decode -> optional producer-local coalescer
                -> arbitration policy
                -> fan-in FIFO
```

Possible policy modes:

- `FifoOnly`: current behavior. No producer is blocked by target
  ownership; all accepted fan-in commands drain in enqueue order.
- `ProducerPriority`: for the same control target, allow higher-priority
  producer kinds to override lower-priority producers. The priority
  table must be explicit session configuration, not hard-coded globally.
- `TargetClaim`: one producer claims `(VoiceKey, ControlTag)` until a
  release, timeout, or session reset. Other producers receive an
  observable arbitration rejection for that target.
- `TouchOverride`: a UI or MIDI gesture temporarily claims a Pattern
  automation target until release, then automation resumes.
- `ManifestOwnership`: a future authoring manifest marks which producer
  class owns a control target, and policy rejects writes outside that
  declaration.

The first implementation is pure and testable before it is wired to any
live producer. The landed data model is:

```text
data ArbitrationPolicy =
    FifoOnly
  | ProducerPriority [ProducerKind] ControlOwnerTable
  | TargetClaim TargetClaimTable
```

The gateway decides before enqueue, and accepted fan-in commands remain
strict FIFO. `TouchOverride` and manifest-owned policies are still future
extensions rather than constructors in the landed module.

## Observability

Arbitration diagnostics should be separate from queue pressure and
coalescing diagnostics:

- `arbitration_rejected_count`;
- producer identity;
- target `(VoiceKey, ControlTag)` for control writes;
- losing producer and current owner, when an owner exists;
- policy mode and reason;
- whether the rejected event is retryable.

Retry behavior is producer-specific. The retryable flag only indicates
whether the current policy state would admit a re-submission.

These counters should not be mixed with `SeiQueueFull`,
`sfisQueueDepth`, or producer-local coalescing counters. Queue-full
means fan-in backpressure. Coalescing means a producer emitted more
intermediate values than fan-in needed. Arbitration rejection means a
policy chose another producer's intent for the same target.
The service-owned gateway surfaces that case as
`SfsiiArbitrationRejected` on `sfshOnIssue`.
The manual `--session-osc-arbitration-smoke` command exposes that
service issue alongside the OSC listener's `SoliArbitrationRejected`
counter so operators can see both the cross-producer service signal and
the producer-specific packet signal without treating either as queue
pressure.

## Test Plan

Keep existing queue and fan-in tests unchanged. Policy tests should live
above fan-in, using a small pure policy function or wrapper:

- `FifoOnly` preserves current behavior for same-target writes from two
  producers.
- A priority policy accepts the winning producer and rejects the losing
  producer before enqueue.
- A target-claim policy blocks only the claimed `(VoiceKey, ControlTag)`
  and allows unrelated targets through.
- Pattern events remain non-coalesced and FIFO when no continuous lane
  policy is configured.
- v1 bypasses control arbitration for lifecycle and hot-swap commands. A
  later policy that adds lifecycle arbitration must surface explicit
  unsupported-policy issues rather than silently dropping or collapsing
  commands.
- Rejected commands do not consume queue capacity or sequence numbers.
- A fan-in rejection after policy acceptance does not update priority
  owner state.
- A service-owned gateway rejection reports `SfsiiArbitrationRejected`
  without waking the drain worker.
- The explicit OSC producer/listener and UI producer service paths
  default to FIFO behavior and report service-owned policy rejection
  when a non-`FifoOnly` gateway is configured.

## Implementation Sequence

1. Keep this note as the contract for the design boundary.
2. Add a pure arbitration-policy module with no fan-in changes. Done:
   `MetaSonic.Session.Arbitration`.
3. Add tests for same-target cross-producer writes, rejected writes,
   unclaimed targets, and unchanged FIFO behavior. Done in `test/Spec.hs`.
4. Add an optional wrapper around producer enqueue paths while defaulting
   to `FifoOnly`. Done: `MetaSonic.Session.ArbitrationGateway`.
5. Let the scoped fan-in service own an optional gateway for callers that
   explicitly choose the arbitrated enqueue path. Done:
   `MetaSonic.Session.FanInService`.
6. Report service-owned gateway policy rejections as service issues
   separate from queue-full and drain-stop issues. Done:
   `SfsiiArbitrationRejected`.
7. Wire one concrete producer path through the service-owned gateway
   while keeping default behavior FIFO. Done:
   `enqueueArbitratedOSCControlWrite`.
8. Wire one concrete listener path through the service-owned gateway
   while keeping default behavior FIFO. Done:
   `withArbitratedSessionOSCListener`.
9. Wire additional MIDI, UI, or Pattern producer/listener paths only
   when configuration can explicitly enable a non-FIFO policy. Done for
   UI producer: `enqueueArbitratedUIProducerIntent`. MIDI and Pattern
   remain gated.
10. Add smoke diagnostics if a live policy is enabled by configuration.
    Done: `--session-osc-arbitration-smoke` binds the opt-in
    arbitrated OSC listener path with a `TargetClaim` policy and reports
    listener/service arbitration counters.

## Deferred Work

The following items are recorded as use-case-gated questions, not the
next implementation step:

- Gateway policy mutation API. Claim release, claim replacement, and
  owner clearing should wait for a concrete live policy owner that needs
  mutation after gateway construction.
- Gateway lock-span two-phase split. `SessionArbitrationGateway`
  currently holds its policy `MVar` across policy decision, fan-in
  enqueue, and policy update so accepted ownership updates follow the
  same order as admitted fan-in commands. Splitting into
  snapshot/enqueue/update phases stays deferred until smoke output or a
  dedicated contention benchmark shows caller-visible lock wait.
- Voice-lifecycle ownership clearing. `CmdVoiceOff` does not clear
  `ProducerPriority` owner entries today; changing that should wait for
  a concrete policy decision about deterministic `VoiceKey` reuse,
  release semantics, and hot-swap behavior.

## Open Questions

- Which component owns policy configuration: session options, authoring
  manifest, or a higher UI/runtime supervisor?
- Which additional MIDI or Pattern producer/listener path should next
  route through the service-owned gateway when a live non-FIFO policy is
  enabled?
- Should a default non-FIFO policy ever exist, or should all arbitration
  be opt-in?
- Should multi-policy composition, such as target-claim precedence with
  priority fallback, be modeled as a new constructor or a policy
  combinator?
- Should the gateway expose explicit policy mutation for claim release,
  claim replacement, or owner clearing, or should those wait for a
  configured live policy owner?
- What release signal ends a MIDI or UI `TouchOverride` claim?
- Should voice lifecycle commands clear ownership entries keyed on the
  released voice, or should ownership survive deterministic voice-key
  reuse?
- Does hot-swap clear claims, preserve claims by symbolic target, or
  require an explicit migration policy?
- How should Pattern automation mark continuous-control lanes that are
  safe to suppress or resume after live takeover?
