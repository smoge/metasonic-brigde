# Session Prep M - Preserving Hot-Swap Strategy Evidence

Date: 2026-05-13

Status: evidence note. This slice does not implement preserving
session hot-swap, add OSC/MIDI/UI producers, add a background drain
loop, or change the C ABI. It records what the current runtime already
supports so the implementation slice does not re-derive the strategy.

Prep K fixed the session semantics. Prep L pins the queue/state edge
cases in tests. Prep M answers the next strategy question: whether the
first implementation should use runtime migration or session-level
respawn.

## Recommendation

Start with a narrow runtime-migration-backed session hot-swap, not
session respawn.

The earlier conservative bias toward respawn was based on the Prep E
adapter path, which still uses stop/clear/rebuild through
`installSessionGraph`. The C++ runtime and Haskell FFI already have a
separate live-swap substrate:

- `rt_graph_prepare_swap_from_graph` builds a prepared next world from
  an offline `RTGraph`;
- `rt_graph_publish_swap` publishes it to the audio thread;
- `process_graph` installs it at a block boundary;
- `rt_graph_collect_retired_swap` reaps the old world and exposes
  migration counters;
- `hotSwapTemplateGraph*` and `hotSwap*AndWait` wrap that protocol on
  the Haskell side.

That means the first preserving implementation should reuse the
existing prepare/publish/migrate path for the subset it can prove safe.
Session respawn remains the fallback strategy for unsupported graphs or
for a later audible-reset policy.

## Runtime Evidence

### Prepare / Publish Boundary Exists

`RTGraphSwap` owns a prepared `RTGraphState`. The producer builds that
state off-audio, publishes it into a one-deep pending slot, and the
audio thread installs it at the top of `process_graph`.

The install path is intentionally block-boundary and allocation-free:

1. acquire pending swap;
2. drain the realtime control queue against the old world;
3. apply migration from old world to prepared world;
4. move old active world into the swap's retired payload;
5. make the prepared world active;
6. increment the swap generation.

This ordering is important for session semantics. Commands published
before the swap land on the old world; commands after the producer
observes the generation advance target the new world.

### Migration Already Copies Slots And State

The migration path is slot-index and template-id matched. For every
old/new slot pair where both slots are `Active` or `Releasing` and
their template ids match, the runtime copies lifecycle metadata from
the old instance into the new instance.

For node data, the prepared swap carries a migration plan built from
template-local migration keys. A node participates only when:

- the new node has a migration key;
- the old template at the same template id has a node with that key;
- old and new node kinds match;
- control arity matches;
- the node kind participates in the current migration slice.

The audio-thread install then copies matching control vectors and
supported DSP state. The collected swap reports committed, skipped,
instance-copy, state-copy, and lifecycle-copy counters.

### Template Identity Guards Slot Meaning

The runtime has a template identity precondition. If any live old slot
belongs to a template id whose old and new template identities are both
set and differ, `rt_graph_prepare_swap_from_graph` rejects before
publish.

This protects the slot-index migration rule from a silent template
renumbering bug. A later session implementation should keep relying on
template identity instead of treating template names as only diagnostic
strings.

## State Coverage

The current migration-support set is strong enough for common
oscillator/filter voices:

- oscillator phase: `SinOsc`, `SawOsc`, `TriOsc`, `PulseOsc`;
- random generator state: `NoiseGen`;
- filter memory and cached coefficients: `LPF`, `HPF`, `BPF`,
  `Notch`;
- stateless/control-only nodes: `Out`, `Gain`, `Add`, `BusOut`,
  `BusIn`, `BusInDelayed`.

These nodes can preserve controls, and where they have runtime state,
copy that state allocation-free during install.

The current unsupported set is the hard boundary for v1:

- `Env`;
- `Delay`;
- `Smooth`;
- `PlayBufMono`;
- `RecordBufMono`;
- `SpectralFreeze`;
- `StaticPlugin`.

For these, a preserving session swap should not claim seamless state
survival. The first implementation should either reject preservation
when a surviving live voice depends on unsupported stateful nodes, or
require an explicit later reset/respawn policy. Silent reset would be a
semantic bug.

## Session Adapter Gap

Before Prep N, the `MetaSonic.Session.RTGraphAdapter` hot-swap path did
not use the live-swap substrate. `runHotSwap` called
`installSessionGraph`, and `installSessionGraph` used the loader's
clear/rebuild path, removed loader-created auto-spawned instances, then
prewarmed future realtime reservation slots.

That is why Prep E correctly rejected preserving swaps before Prep N:
the session adapter had no path that prepared a next world with active
slots matching the preserved `VoiceBinding` values.

The implementation gap is therefore not "invent hot-swap." It is:

1. build the next session world off-audio with the same template ids
   and enough matching live slots for preserved voices;
2. publish that world through the existing prepared-swap API;
3. wait for or observe install completion;
4. collect migration stats;
5. commit the graph install only after the runtime proves the
   migration happened.

## Commit Vocabulary Consequence

For the runtime-migration path, keep `CommitGraphInstalled label graph`
unchanged at first. The preserved `VoiceBinding` values remain valid
only because the runtime preserves the same slot ids. The commit-time
resolve rebuild can therefore keep the existing binding table.

A new commit shape is mandatory only if the implementation chooses
session respawn. Respawn allocates replacement slots, so the runtime
must return replacement `VoiceBinding` values and the commit path must
install those replacements into `SessionState`.

## Implementation Gate

The next code slice should be narrow:

- add a session-adapter hot-swap path that uses the existing
  prepare/publish/collect protocol;
- initially support only graph swaps where every surviving live voice
  has a matching template id and compatible runtime-migratable node
  set;
- reject, non-terminally, swaps whose surviving voices require
  unsupported state migration;
- preserve the existing terminal divergence policy for publish/install
  failures that leave runtime/session agreement uncertain;
- keep stale queued command behavior exactly as pinned by Prep L.

Tests should prove:

- a supported preserving swap keeps the same `VoiceKey` to slot binding;
- post-swap control writes resolve against the new graph;
- unsupported stateful voices are rejected rather than silently reset;
- reordered template identities reject before publish;
- migration counters are inspected before claiming success.

## Out Of Scope

- Session respawn implementation.
- Replacement-binding commit vocabulary.
- OSC/MIDI/UI producers.
- Background drain loops.
- Multi-producer hot-swap arbitration.
- Automatic rollback after a failed publish/install.
