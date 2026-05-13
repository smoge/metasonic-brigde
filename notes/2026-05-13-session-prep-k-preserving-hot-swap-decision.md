# Session Prep K - Preserving Hot-Swap Decision

Date: 2026-05-13

Status: decision artifact. This slice does not implement preserving
hot-swap, add a background drain loop, add concrete OSC/MIDI/UI
producer bridges, or change the realtime C ABI.

## Decision

Keep the current runtime adapter behavior for now:

- empty-session graph installs may proceed;
- swaps that drop all active voices may proceed;
- swaps that would preserve live voices remain rejected by the real
  `RTGraph` adapter until a later implementation slice chooses a
  concrete preservation strategy.

The next implementation work must not treat queued `PEHotSwap` as just
another already-settled runtime command. Prep G/H/I/J made hot-swap
observable through the producer queue, Pattern producer, scripted
runner, and serialized host. That makes the open semantics explicit:
preserving hot-swap needs a policy for stale queued commands, resolve
state, live voice bindings, DSP state, and failed installs before more
producer fan-in or background draining is added.

## Current Ground Truth

The pure session layer can preview and commit a hot-swap against
`SessionState`. Its resolve rebuild keeps symbolic voice bindings whose
templates still exist in the new graph.

The real `RTGraph` adapter cannot yet preserve runtime voice slots or
stateful DSP state across a graph reinstall. The existing loader clears
and rebuilds runtime graph state. If pure session state claimed a voice
survived while the runtime had actually cleared that slot, callers would
observe a false live binding.

For that reason, the real adapter rejects preserving swaps today. This
is a deliberate correctness boundary, not a missing queue feature.

## Execution-Time Semantics

Admission-time hot-swap previews are advisory. Any preserving
implementation must recompute the hot-swap policy against the current
owner state at execution time, because queued commands before the swap
may have started, stopped, or changed voices after the command was
admitted.

The execution-time rule should be:

1. Drain earlier queued commands in FIFO order against the old graph.
2. At the hot-swap command, rebuild the preview from the current
   `SessionState`.
3. Install or reject based on that current state, not only on stale
   admission-time facts.
4. After a successful install, make the resulting `SessionState`
   authoritative for later queued commands.

`PEHotSwap` should not bypass the queue, receive priority ordering, or
silently drop commands around it.

## Stale Queued Commands

Commands after a successful preserving hot-swap should be interpreted
against the post-swap `SessionState`.

That implies:

- commands targeting voices or templates dropped by the swap should
  fail as normal session admission/runtime rejections, not as owner
  divergence;
- commands targeting preserved logical voices must resolve through the
  post-swap binding table;
- queued commands must not retain old runtime slot assumptions across
  the swap.

This is one reason the public command layer uses symbolic `VoiceKey`
and template labels rather than exposing runtime slot ids to producers.

## Preservation Strategies

There are two plausible implementation paths.

### Runtime Migration

Teach the C++ runtime to migrate compatible live voice slots and
stateful DSP state through a graph install. This is the most seamless
path, but it requires explicit runtime support for compatibility,
state transfer, and audio-thread cooperation.

Under this path, preserved logical voices can keep their runtime slot
identity only if the runtime proves the slot still refers to a valid
voice in the new graph.

### Session Respawn

Install the new graph, respawn each preserved logical voice into the new
runtime graph, and return replacement `VoiceBinding` values from the
adapter/commit path. This is less seamless, but it avoids pretending the
old runtime slot survived a clear/rebuild install.

Under this path, preserving hot-swap is really a controlled stop,
install, and respawn operation. It may be audible. The commit vocabulary
would need to carry the replacement bindings returned by runtime
execution.

## Failure And Recovery

Do not claim automatic rollback until the runtime has a protocol that
can prove the old graph remains active after a failed install.

If a preserving install mutates the runtime and then fails, the owner
should continue to treat that as terminal divergence, matching the
current Prep F/E failure model. A later recovery slice can add a
prepare/publish protocol or another explicit recovery mechanism, but
Prep K does not assume one exists.

The Prep J host lock serializes hosted steps; it does not make hot-swap
installation transactional.

## Consequences

- Concrete OSC/MIDI/UI producer bridges can be designed against the
  existing queue shape, but should not force preserving hot-swap policy.
- Background drain loops and thread-safe fan-in beyond the Pattern host
  remain deferred until preserving swap execution semantics are tested.
- The current rejection of preserving hot-swap by the real adapter
  remains correct for v1.
- The next preserving-hot-swap implementation slice should start with
  tests for execution-time preview rebuild, stale queued commands, and
  failed-install divergence before adding runtime migration or respawn
  behavior.
