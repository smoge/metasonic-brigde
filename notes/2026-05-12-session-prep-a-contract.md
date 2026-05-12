# Session Prep A - Command, Resolve, And Lifecycle Contracts

Date: 2026-05-12

Status: decision artifact for the first session-prep slice. This is
not the session runtime. It defines the small library contracts that
the eventual session layer can build on without taking ownership of
`RTGraph`, audio callbacks, runtime install, graph reload, or producer
threads.

The note is written as a standalone handoff. It repeats the relevant
facts from the older pattern, OSC, buffer, plugin, planner, and
authoring notes so the implementation series does not require a reader
to reconstruct the argument from phase history.

## Decision

Start session work with a narrow "Session Prep A" slice:

1. a shared command/event vocabulary for producer fan-in;
2. a pure OSC resolve-state rebuild contract for graph hot-swap;
3. read-only buffer/plugin lifecycle report shapes;
4. tests that pin those contracts without adding a live session owner.

This slice should be a library contract layer. It should not execute
commands, own the runtime handle, import manifests, install graphs, or
change C++ audio-thread behavior.

## Why This Is The Next Step

The project now has enough ingredients to define the session boundary,
but not enough reason to implement the session runtime yet.

Phase 7 answered the planner side of the earlier session gate. Fusion
capability metadata, survey-only planner verdicts, cost-lab joins, and
read-only profitability gates now exist. The generated executors were
also measured and closed out as a read-only performance path: useful
diagnostics, not something a session must depend on. That means session
work no longer needs to wait for a planner/cost-model v1, and it also
does not need to wait for generated execution to ship.

Phase 8 answered the authoring side. Authoring now has deterministic
routing helpers, ensemble builders, named controls, metadata reports,
and an export-only manifest. The manifest is not a graph save file and
does not reload the runtime, but it gives external tools and the future
session layer a stable description of templates, buses, controls,
ranges, CC bindings, and migration keys.

The remaining gap is product/workflow coherence: several producer
surfaces exist, but they do not yet meet at one explicit command
contract. Patterns, OSC, MIDI, future UI actions, hot-swap requests,
and resource diagnostics can all affect a running graph. Letting each
producer grow its own runtime mutation path would duplicate address
resolution, failure reporting, and lifecycle policy. The session layer
should eventually be that arbiter, but the first safe step is to define
the vocabulary and pure rebuild/report helpers before adding runtime
ownership.

This is why Session Prep A makes sense now:

- it turns the older session-scoping questions into testable library
  contracts;
- it reuses the producer/event vocabulary already in the repo;
- it makes hot-swap resolve-state policy explicit before any live
  hot-swap session code exists;
- it exposes buffer/plugin diagnostics in a session-shaped record
  without changing allocation or audio-thread behavior;
- it keeps Phase 8's "elaboration-only" discipline intact by avoiding
  a second compiler or runtime semantic layer.

## Older Notes Folded Into This Contract

### Pattern Layer

The Phase 6.A pattern note defines patterns as Haskell-side producers.
They produce compiled `SynthGraph` / `TemplateGraph` payloads and timed
control / hot-swap events that flow through existing compile, queue,
and swap mechanisms. They are explicitly not an audio-thread scheduler,
not a new DSL layer, and not a new runtime substrate.

The concrete vocabulary from that work is already in
`MetaSonic.Pattern`:

- `TemplateName`
- `VoiceKey`
- `ControlTag`
- `SwapLabel`
- `Value`
- `PatternEvent`

`PatternEvent` already covers voice on, voice off, control write, and
hot-swap. Session Prep A should adapt that event type into the session
command type instead of inventing a parallel symbolic vocabulary.

### OSC Control

The Phase 6.B OSC note makes OSC a Haskell-owned control-plane
producer. OSC parsing and dispatch resolution live in Haskell because
OSC is command traffic, not audio data. The audio thread remains
decoupled through the existing realtime control queue.

The OSC address model also established the important resolve-state
shape:

- a current `TemplateGraph`;
- a `VoiceKey -> (slot_id, TemplateName)` table;
- validation of OSC-safe identifiers at registration time;
- drop-and-diagnose behavior for missing voices, unknown tags, and
  invalid slots.

The existing `ResolveState` implements that idea for the currently
loaded graph. The missing session-level contract is what happens after
a hot-swap replaces the graph shape. Session Prep A defines a pure
rebuild helper so that policy is explicit before live session
hot-swap code exists.

### MIDI And External Control

The MIDI/OSC external-control note keeps live/manual smoke checks
separate from deterministic CI. MIDI currently owns note allocation and
control translation in its own live path, while OSC owns symbolic
control writes. Both are real producers, but neither should become the
general-purpose session owner.

The safe direction from the session scoping note is one high-level
event vocabulary feeding existing MIDI/voice/template mechanisms,
rather than multiple realtime owners. Session Prep A establishes that
vocabulary without rewriting MIDI or OSC.

### Buffer I/O

The Phase 6.C buffer notes define buffers as explicit resources:
producer-allocated, integer-keyed, one channel per ID in v1, and
separate from buses. Buffers are shared memory; delay lines remain
per-node state. Buffer storage can outlive template hot-swap, and live
freeing follows the retire/collect pattern rather than immediate
audio-thread deletion.

The buffer contract also deliberately kept buffer load/free out of
pattern and OSC v1. Buffers are set up out-of-band through
`MetaSonic.Bridge.Buffer`, and invalid or unloaded reads emit zeros
while incrementing diagnostics counters.

Session Prep A does not change any of that. It only gives the future
session layer a read-only report shape for facts that are already
visible: read count, invalid-read count, write count, and invalid-write
count.

### Static Plugins

The Phase 6.E plugin notes keep the plugin ABI narrow. Static plugins
are selected by integer plugin ID and fixed arity. Haskell owns the
per-plugin metadata table; the C ABI remains a dense-input/output
runtime call. Invalid plugin IDs or invalid plugin returns produce
silence and tick diagnostic counters.

Session Prep A should not add external plugin APIs, dynamic loading, or
new plugin lifecycle semantics. It should report the static plugin
registry and existing call/invalid-call counters in a shape a session
can display or log.

### Planner And Generated Fusion

Phase 7 moved through legality metadata, planner verdicts, selected
candidate diagnostics, runtime-program ABI experiments, block-major and
superinstruction probes, and a gate closeout. The closeout matters for
session planning: generated fusion is parked as a read-only performance
path unless the gate later produces actionable evidence.

Therefore the session layer should not be blocked on generated
executor work. It should also not turn generated execution on. The only
Phase 7 dependency this note relies on is that planner/cost/profit
diagnostics are now stable enough that session work is not racing a
moving compiler story.

### Authoring And Manifest Export

Phase 8 stayed elaboration-only over `SynthGraph` and `TemplateGraph`.
It added multichannel helpers, routing, deterministic ensemble bus
allocation, named controls, authoring reports, and the Phase 8.H JSON
manifest. None of those changes added IR fields, runtime ABI surface,
OSC grammar, or graph serialization.

The manifest is a stable description of authoring metadata, not a
reloadable patch. Session Prep A should respect that line: it can name
manifest import/reload as future work, but it should not smuggle import
semantics into the first command ADT.

## Boundary

Session Prep A is allowed to add:

- Haskell data types for session commands, events, and issues;
- pure adapters from existing producer events;
- a pure resolve-state rebuild helper;
- read-only report records and report readers;
- focused library tests;
- roadmap wording that marks these contracts as prep work.

Session Prep A is not allowed to add:

- a command queue worker;
- a session runtime owner;
- a C++ session object;
- audio-thread symbolic lookup;
- manifest import/reload;
- automatic graph install or hot-swap execution;
- MIDI or OSC behavior rewrites;
- generated executor turn-on;
- external plugin APIs;
- buffer allocation policy changes.

## Contract 1: Session Commands

Add a small library module, tentatively
`MetaSonic.Session.Command`, that defines the high-level command
vocabulary consumed by a future session owner.

The v1 command surface should be producer-neutral:

    data SessionCommand
      = CmdVoiceOn TemplateName VoiceKey [(ControlTag, Value)]
      | CmdVoiceOff VoiceKey
      | CmdControlWrite VoiceKey ControlTag Value
      | CmdHotSwap SwapLabel TemplateGraph

The type names can change during implementation if the local code makes
a better name obvious, but the semantic contract should not: the
commands cover voice creation, voice release, control writes, and graph
hot-swap requests.

`PatternEvent` should adapt into this command surface rather than
competing with it:

    fromPatternEvent :: PatternEvent -> SessionCommand

The adapter is deliberately one-way. The session command vocabulary is
allowed to be broader than pattern playback, but pattern playback should
not own a second direct runtime mutation path.

A companion issue/event vocabulary may be added if the implementation
needs to report rejected commands without execution:

    data SessionIssue
      = SiUnknownTemplate TemplateName
      | SiInvalidVoiceKey VoiceKey
      | SiStaleVoice VoiceKey

Keep that issue type small. Detailed runtime rejection causes belong to
the later execution slice.

Out of scope for this contract:

- command execution;
- queue ordering implementation;
- realtime queue writes;
- manifest import as an executable command;
- policy for multiple simultaneous producers.

## Contract 2: Resolve-State Rebuild

Add a pure helper module, tentatively `MetaSonic.Session.Resolve`, that
defines how OSC resolve state is rebuilt after a successful graph
install.

The v1 policy is conservative:

- start from the new `TemplateGraph`;
- reinstall only voice bindings that still name an existing template;
- reject malformed voice keys using the existing OSC dispatch profile;
- drop stale bindings with explicit diagnostics;
- never retry unknown or stale symbolic addresses on the audio thread.

Suggested shape:

    data VoiceBinding = VoiceBinding
      { vbVoiceKey     :: VoiceKey
      , vbSlotId       :: Int
      , vbTemplateName :: TemplateName
      }

    data ResolveRebuildIssue
      = RriInvalidVoiceKey VoiceKey DispatchIssue
      | RriMissingTemplate VoiceKey TemplateName

    data ResolveRebuildResult = ResolveRebuildResult
      { rrrState   :: ResolveState
      , rrrDropped :: [ResolveRebuildIssue]
      }

    rebuildResolveState
      :: TemplateGraph
      -> [VoiceBinding]
      -> ResolveRebuildResult

Implementation should prefer the existing dispatch helpers rather than
duplicating validation. A likely shape is:

1. construct an empty `ResolveState` for the new `TemplateGraph`;
2. for each old `VoiceBinding`, check that `vbTemplateName` is still
   present in the new graph;
3. call `registerVoice` so the existing OSC-safe key validation stays
   authoritative;
4. accumulate dropped bindings in declaration order.

The helper does not install graphs. It only computes the resolve state
a future session owner should swap in after install succeeds.

## Contract 3: Lifecycle Reports

Add a read-only reporting module, tentatively
`MetaSonic.Session.Report`, that exposes session-facing snapshots for
resource diagnostics.

The v1 report should describe facts already visible today:

    data BufferLifecycleReport = BufferLifecycleReport
      { blrReadCount         :: Word64
      , blrInvalidReadCount  :: Word64
      , blrWriteCount        :: Word64
      , blrInvalidWriteCount :: Word64
      }

    data PluginLifecycleReport = PluginLifecycleReport
      { plrRegistered       :: [PluginRegistryEntry]
      , plrCallCount        :: Word64
      , plrInvalidCallCount :: Word64
      }

    data SessionLifecycleReport = SessionLifecycleReport
      { slrBuffers :: BufferLifecycleReport
      , slrPlugins :: PluginLifecycleReport
      }

Readers may use existing FFI diagnostics:

    readBufferLifecycleReport :: Ptr RTGraph -> IO BufferLifecycleReport
    readPluginLifecycleReport :: Ptr RTGraph -> IO PluginLifecycleReport

This is not a resource allocator, not a buffer slot inventory, and not a
plugin loading API. It is only the producer-facing state snapshot that a
future session can render or log outside the audio thread.

If the current FFI surface cannot expose one field without a new ABI
entry, prefer narrowing the v1 report over adding C++ API in this prep
slice. New C ABI belongs only where an existing counter or registry
fact is genuinely unavailable.

## Implementation Series

Recommended commit shape:

1. **Decision note.** Land this note and sync the stale planning-gate
   wording in the older session scoping note if needed.
2. **Command module.** Add `MetaSonic.Session.Command`, export it from
   `package.yaml`, and add adapter tests for `PatternEvent`.
3. **Resolve module.** Add `MetaSonic.Session.Resolve` and tests for
   retained bindings, missing templates, malformed keys, and dispatch
   through a rebuilt state.
4. **Report module.** Add `MetaSonic.Session.Report`, report readers,
   and minimal tests for fresh counters and static plugin registry
   visibility.
5. **Roadmap sync.** Add Session Prep A under the Session-Layer
   Scoping Gate, explicitly keeping the runtime session gated.
6. **Focused tests and verification.** Pin the command adapter,
   resolve rebuild policy, and lifecycle report counters before
   committing the slice.

The report module can be split into its own follow-up if the command
and resolve contracts expose enough review surface on their own.

## Tests

The first implementation series should add focused library tests:

- `PatternEvent` adapts to the expected `SessionCommand`.
- valid voice bindings survive a resolve rebuild.
- bindings for removed templates are dropped with
  `RriMissingTemplate`.
- malformed voice keys are dropped with `RriInvalidVoiceKey`.
- dropped bindings preserve diagnostic order.
- a retained binding resolves through the rebuilt `ResolveState`.
- fresh lifecycle reports start at zero counters.
- plugin reports include the static plugin registry.
- buffer/plugin counters reflect one existing deterministic test path if
  that can be exercised without adding runtime behavior.

No corpus snapshot pin is required for this prep slice unless a later
implementation moves session metadata into the app-side demo table.

## Roadmap Placement

`ROADMAP.md` should gain this as a session-prep entry under the
Session-Layer Scoping Gate, not as a numbered runtime phase.

Mark only these artifacts as landed when they exist:

- command/event vocabulary;
- OSC resolve-state rebuild helper;
- lifecycle report shapes/readers.

Keep the full session runtime gated until the ownership, command queue,
install/hot-swap execution, MIDI/OSC arbitration, and manifest reload
policies are specified and tested separately.

The older session scoping note's gate can also be updated after this
series:

1. Phase 7 planner/cost/profitability gates are now done.
2. Session Prep A supplies the command/event sketch.
3. Session Prep A supplies the hot-swap resolve-state contract.
4. Session Prep A supplies the lifecycle reporting contract.
5. Runtime session implementation remains a later phase.

## Verification

Minimum verification after implementation:

    just stack-test
    stack exec -- metasonic-bridge --snapshot-check
    stack exec -- metasonic-bridge --authoring-manifest named-control

If a later implementation touches C++ headers, runtime sources, or FFI
surface area, also run:

    just cpp-build
    just cpp-test
