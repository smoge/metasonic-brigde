# Session Layer Scoping Gate

Date: 2026-05-11

Status: direction note, not an implementation phase.

## Decision

Treat session/authoring as a next product direction, not the next
implementation phase. The scoping pass can happen now, but session
runtime implementation should wait until Phase 7 has a real planner
story: capability metadata, survey-only planning, and a first cost
model table derived from `--fusion-cost-lab` / `--snapshot-check`.

This puts session implementation after a cost-model v1, but before any
requirement to ship a generated fusion executor. That order gives the
session layer a stable enough compiler/planner contract while still
letting later real musical workloads exercise generated-fusion
decisions before generated execution becomes default.

## Why This Is Not A Small Slice

A real session layer is larger than a convenience authoring helper. It
crosses ownership boundaries that are currently deliberately separate:

- `RTGraph` ownership and lifetime;
- graph producer fan-in;
- OSC address resolution across hot-swap;
- MIDI voice control coexisting with pattern events;
- buffer and plugin lifecycle visibility;
- graph identity and state migration;
- failure policy when a compile, allocation, or install step rejects a
  candidate graph.

Landing only half of that surface would create a second, ambiguous
runtime owner on top of the existing compiler/runtime boundary. That is
the failure mode to avoid.

## Ownership Questions To Resolve

### Runtime Graph Ownership

Current demos load one graph or template graph directly into an
`RTGraph` handle. A session layer needs to decide whether it owns:

- the source `SynthGraph` / `TemplateGraph` values;
- the compiled `RuntimeGraph` / `TemplateGraph` values;
- the installed runtime handle;
- or only a command stream that asks the existing host to install
  graphs.

The conservative direction is: Haskell session owns source/compiled
graph identity and migration metadata; the realtime host owns the
installed handle and exposes state through existing non-audio-thread
queries.

### Producer Fan-In

The likely producers are pattern events, OSC, MIDI, authoring/UI
commands, buffer/plugin lifecycle actions, and hot-swap requests. They
should not each mutate runtime state directly. The session needs one
ordered command stream with explicit command types and explicit
rejection reporting.

### OSC Resolve State On Hot-Swap

`ResolveState` currently resolves against one compiled graph shape.
A session must define when that state is rebuilt, how it is swapped, and
what happens to messages that target names removed by the new graph.

Default policy for v0 should be simple: rebuild resolve state only
after a graph install succeeds; unknown or stale addresses are dropped
with producer-side diagnostics, not retried on the audio thread.

### MIDI And Pattern Coexistence

The live MIDI path owns voice allocation and direct note/control
translation. Pattern playback will also want to emit note-like and
control-like events. The scoping pass must decide whether patterns use
the same voice allocator contract, a separate template-instance path, or
an adapter above both.

The safe default is one shared high-level event vocabulary feeding
existing MIDI/voice and template-instance mechanisms, rather than two
independent realtime owners.

### Buffer And Plugin Lifecycle Reporting

Buffers and static plugins now have enough metadata/counters for tests
and diagnostics, but not a session-visible lifecycle report. A session
needs a producer-facing view of:

- buffer allocation/load/clear/retire state;
- plugin availability and invalid-call counters;
- graph install rejection causes tied to missing resources;
- retired resource collection after hot-swap.

This reporting belongs outside the audio thread. The session should
surface it as state snapshots or event log entries.

## Scope For A Future Session v0

A useful v0 should be intentionally narrow:

- one active template graph at a time;
- one command queue for producer actions;
- graph install/hot-swap as an explicit command;
- atomic rebuild of OSC resolve state after successful install;
- a shared event vocabulary for MIDI-like and pattern-like note/control
  events;
- read-only reporting for buffer/plugin lifecycle and counters;
- no generated executor dependency.

Out of v0:

- external plugin APIs;
- session file format;
- multi-project timelines;
- unrestricted producer scripting;
- audio-thread symbolic lookup;
- new runtime graph ownership in C++.

## Planning Gate

Do not promote this to a numbered phase until these artifacts exist:

1. Phase 7.B capability metadata for fusion legality.
2. Phase 7.C survey-only planner output.
3. A v1 profitability/cost table from the cost lab.
4. A command/event ADT sketch for session producer fan-in.
5. A hot-swap/OSC resolve-state update contract.
6. A buffer/plugin lifecycle reporting contract.

The next implementation work should therefore stay on the planner
story first. Session scoping can continue in notes, but session runtime
code should not compete with the Phase 7 planner gate.
