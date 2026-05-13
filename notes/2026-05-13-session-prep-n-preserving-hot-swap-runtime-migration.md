# Session Prep N - Preserving Hot-Swap Runtime Migration

Date: 2026-05-13

Status: implemented narrow runtime-migration path. This slice does
not add OSC/MIDI/UI producers, a background drain loop, multi-producer
arbitration, session respawn, or replacement-binding commit
vocabulary.

Prep K fixed the preserving hot-swap policy. Prep L pinned stale
queued-command semantics. Prep M chose runtime migration over session
respawn for the first supported implementation. Prep N wires that path
into `MetaSonic.Session.RTGraphAdapter`.

## Decision

Supported preserving swaps now use the existing C++ RCU swap protocol:

1. drain already-queued realtime voice/control commands with a zero-
   frame scripted process step;
2. build an offline next `RTGraph` with the same capacity and
   `max_frames` as the target handle;
3. install the new `TemplateGraph` into that builder;
4. seed active builder slots matching the preserved `VoiceBinding`
   slot ids and template ids;
5. publish the builder world through
   `rt_graph_prepare_swap_from_graph` / `rt_graph_publish_swap`;
6. drive a zero-frame scripted process step so the swap installs;
7. collect the retired swap and inspect migration counters;
8. commit `CommitGraphInstalled` only after lifecycle and state-copy
   counts prove the preserved voices migrated.

The commit vocabulary stays unchanged. Runtime migration keeps the
same slot ids, so the existing resolve-state rebuild can preserve the
same `VoiceBinding` values.

## Supported Subset

The adapter accepts a preserving swap only when every surviving voice
keeps the same template id and the new template's stateful nodes are
runtime-migratable with matching migration keys, node kinds, and
control arities in the old template.

The first supported set is the runtime's existing migration-support
set for oscillator/filter voices:

- `KSinOsc`, `KSawOsc`, `KTriOsc`, `KPulseOsc`;
- `KNoiseGen`;
- `KLPF`, `KHPF`, `KBPF`, `KNotch`;
- stateless/control-only nodes (`KOut`, `KGain`, `KAdd`, `KBusOut`,
  `KBusIn`, `KBusInDelayed`) can appear without forcing a state-copy
  proof.

Validation is destination-driven: every stateful node that survives in
the new template needs a matching old migration key, node kind, and
control arity. Old stateful nodes with no destination in the new graph
are intentionally dropped; smaller preserving swaps are valid as long
as the new graph does not claim state it cannot migrate.

Unsupported stateful nodes still reject non-terminally with
`SriHotSwapWouldPreserveVoices`. That keeps silent reset out of the
contract for:

- `KEnv`;
- `KDelay`;
- `KSmooth`;
- `KPlayBufMono`;
- `KRecordBufMono`;
- `KSpectralFreeze`;
- `KStaticPlugin`.

## Runtime Surface

The C ABI gained three read-only helpers:

- `rt_graph_capacity`;
- `rt_graph_max_frames`.
- `rt_graph_audio_running`.

The session adapter uses the sizing helpers so an offline builder
matches the target handle instead of guessing from Haskell defaults.
The prepared-swap ABI already required matching `max_frames`; using
the target's actual values also avoids moving a next-world state with a
different instance pool size.

`rt_graph_audio_running` gates the scripted path: if realtime audio is
active, the adapter rejects with `SriHotSwapRequiresStoppedAudio`
instead of calling the offline process entry point concurrently with
the callback.

## Caveat

Prep N is the synchronous scripted-owner implementation. It calls
`rt_graph_process rt 0` to drain pending realtime operations before
building the migration source and again to force the published swap to
install before commit. Zero frames still drives the runtime control
queue / RCU swap state machine without rendering audio.

That is correct for the current caller-driven session owner/host path.
The adapter now rejects this scripted path while `rt_graph_audio_running`
is true. A future live-audio/background producer service should not
call the offline process entry concurrently with the audio callback.
It should publish, wait for the audio thread to advance the swap
generation, collect the retired swap, then commit.

## Tests

The real adapter now covers both sides of the boundary:

- `droneVibrato` still rejects as an unsupported preserving swap
  because its live voice has untagged stateful oscillator nodes;
- `hotSwapEdit` preserves a live voice across a supported swap, keeps
  the same `VoiceKey` to slot binding, advances the swap generation,
  leaves the runtime slot live, and resolves a post-swap control write
  against the new graph.

The existing Prep L stale-command tests remain the queue/session
semantic guardrail around this implementation.

## Still Out Of Scope

- OSC/MIDI/UI producer bridges.
- Background drain loops and live-audio generation waits.
- Multi-producer hot-swap arbitration.
- Session respawn for unsupported preserving swaps.
- Replacement `VoiceBinding` commit vocabulary.
- Automatic rollback or repair after terminal divergence.
