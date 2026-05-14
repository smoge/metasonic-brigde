# Session Producer Coexistence And Arbitration

Status: pure policy and optional gateway landed. This note records the
arbitration boundary after MIDI listener-local coalescing. It does not
change `MetaSonic.Session.Queue` or `MetaSonic.Session.FanIn`; concrete
producer/listener paths keep FIFO behavior unless a caller explicitly
routes them through `MetaSonic.Session.ArbitrationGateway` with a
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

## Implementation Sequence

1. Keep this note as the contract for the design boundary.
2. Add a pure arbitration-policy module with no fan-in changes. Done:
   `MetaSonic.Session.Arbitration`.
3. Add tests for same-target cross-producer writes, rejected writes,
   unclaimed targets, and unchanged FIFO behavior. Done in `test/Spec.hs`.
4. Add an optional wrapper around producer enqueue paths while defaulting
   to `FifoOnly`. Done: `MetaSonic.Session.ArbitrationGateway`.
5. Wire concrete MIDI, OSC, UI, or Pattern producer/listener paths only
   when configuration can explicitly enable a non-FIFO policy.
6. Add smoke diagnostics if a live policy is enabled by configuration.

## Open Questions

- Which component owns policy configuration: session options, authoring
  manifest, or a higher UI/runtime supervisor?
- Which configured producer/listener entrypoint should own the optional
  gateway when a live non-FIFO policy is enabled?
- Should a default non-FIFO policy ever exist, or should all arbitration
  be opt-in?
- Should multi-policy composition, such as target-claim precedence with
  priority fallback, be modeled as a new constructor or a policy
  combinator?
- What release signal ends a MIDI or UI `TouchOverride` claim?
- Does hot-swap clear claims, preserve claims by symbolic target, or
  require an explicit migration policy?
- How should Pattern automation mark continuous-control lanes that are
  safe to suppress or resume after live takeover?
