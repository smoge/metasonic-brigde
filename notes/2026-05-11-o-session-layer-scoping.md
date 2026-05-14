# Session Layer Scoping Gate

Date: 2026-05-11
Updated: 2026-05-12

Status: direction note, not an implementation phase. Session Prep A
now supplies the first library-side command, resolve, and lifecycle
contracts; runtime session ownership remains out of scope.

## Decision

Treat session/authoring as a next product direction, not a small
continuation of the authoring DSL. The original planner precondition is
now satisfied: Phase 7 has capability metadata, survey-only planning,
and cost/profitability tables derived from `--fusion-cost-lab` /
`--snapshot-check`, and Session Prep A supplies the first command,
resolve, and lifecycle contracts.

That means session scoping can move beyond the planner gate, but
runtime implementation still needs a dedicated ownership and execution
policy pass. It does not need to wait for a generated fusion executor
to ship; generated execution remains a diagnostic/performance track
unless later measurements justify automatic turn-on.

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

The original prep gate is now satisfied:

1. [x] Phase 7.B capability metadata for fusion legality.
2. [x] Phase 7.C survey-only planner output.
3. [x] A v1 profitability/cost table from the cost lab.
4. [x] A command/event ADT sketch for session producer fan-in.
5. [x] A hot-swap/OSC resolve-state update contract.
6. [x] A buffer/plugin lifecycle reporting contract.

That does not make the runtime session layer a small follow-up. The
next session slice still needs its own scoping pass for runtime
ownership, command queue semantics, graph install / hot-swap execution,
MIDI/OSC/pattern arbitration, manifest reload, and failure/event
policy. Session runtime code should start only after those policies are
specified and tested separately.
