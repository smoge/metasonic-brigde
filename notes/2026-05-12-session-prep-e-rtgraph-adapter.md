# Session Prep E - RTGraph Runtime Adapter

Date: 2026-05-12

Status: draft decision artifact for review. This is the first session
prep slice that may call the existing Haskell/C++ runtime boundary, but
it is still not a runtime session owner. It defines a real
`SessionRuntimeAdapter IO` backed by a caller-owned `RTGraph` handle and
keeps the realtime queue, producer arbitration, manifest reload, and
uninterrupted hot-swap semantics gated.

## Decision

Add a Haskell-only `RTGraph` adapter for the Prep D shell:

1. The adapter is injected into `stepSessionCommand` as a normal
   `SessionRuntimeAdapter IO`.
2. The adapter does not allocate or own the `RTGraph`; callers supply a
   `Ptr RTGraph` whose lifetime is managed by `withRTGraph` or an
   equivalent bracket.
3. Graph installation uses the existing `loadTemplateGraph` path and
   its current stop/clear/rebuild semantics. Prep E does not claim
   seamless or uninterrupted hot-swap.
4. Session-mode graph install reconciles the loader's auto-spawn
   behavior with `SessionState`: logical sessions start with no active
   voices, so loader-created instances are removed and pools are
   prewarmed before realtime reserve is used.
5. Template ids are derived from `tgTemplates` execution order, matching
   `loadTemplateGraph`, not from `tplID`.
6. Voice start uses the existing realtime producer ABI:
   reserve, write initial controls to the Reserved slot, then activate.
7. Control writes reuse the same symbolic-control resolution semantics
   as OSC dispatch: `VoiceBinding` gives the runtime slot and template
   name; `ControlTag` resolves to a runtime node index and control slot
   inside that template.
8. Voice off enqueues release. Success means the command was accepted by
   the runtime queue, not that the audio thread has already processed
   the release.
9. Hot-swap is deliberately narrow in v1. A graph install may succeed
   only when the resulting pure rebuild would leave no surviving active
   voices, or when the session has no active voices. Preserving or
   respawning live voices across a clear/reload install is a later
   runtime-owner slice.
10. The adapter follows the existing realtime ABI's single-producer
    contract. Prep E does not add locks, a command queue, or multiple
    producer arbitration.
11. Auto-spawn removal uses an instrumented loader path in Haskell. The
    session helper records the exact slot ids returned by the
    loader-created `rt_graph_template_instance_add` calls and removes
    those slots; it must not assume a slot-id formula.

The goal is to exercise the Prep D shell against real `RTGraph` calls
without widening into a session runtime.

## Why This Comes After Prep D

Session Prep D fixed the orchestration contract:

    SessionCommand
      -> admitSessionCommand
      -> SessionRuntimeAdapter
      -> applyPlannedCommit

The mock adapter tests now pin admission rejection, runtime failure,
commit mismatch, adapter protocol bugs, `StepCommitted`, and
`StepControlAccepted`. The next risk is no longer the shell shape. The
next risk is whether the existing runtime ABI can satisfy that shell
without adding a new owner object or changing the audio thread.

Prep E should therefore be the smallest real adapter:

- no new C ABI;
- no C++ session object;
- no realtime queue worker;
- no MIDI/OSC producer fan-in;
- no manifest reload;
- no seamless hot-swap claim.

It proves that the pure session contracts can drive the existing
runtime through a narrow adapter.

## Existing Runtime Facts

`loadTemplateGraph` is the only graph-install path Prep E should use.
Its important contracts are:

- it clears the graph before loading;
- it registers templates in `tgTemplates` execution order;
- the C-side template id is the execution-order index;
- it auto-spawns one instance per template for legacy/simple ensemble
  use;
- malformed schedule or identity metadata fails before clear, preserving
  the previously loaded graph.

The realtime producer ABI already provides:

    rt_graph_realtime_reserve
    rt_graph_realtime_cancel
    rt_graph_realtime_activate
    rt_graph_realtime_release
    rt_graph_realtime_remove
    rt_graph_realtime_set_control

That group is single-producer. It is safe while audio runs only when a
single Haskell producer owns the calls. Prep E's adapter is that single
producer for tests and for the future owner that injects it.

The reserve path does not grow the instance pool. The caller must
prewarm available slots during construction or graph install. The
existing MIDI demo already follows that shape: load a template graph,
set polyphony, remove the loader-created instance, spawn instances, and
remove them so reserve has `Available` slots to claim later.

Initial voice controls should not use `rt_graph_realtime_set_control`
while the slot is still `Reserved`. The C ABI explicitly allows direct
`rt_graph_instance_set_control` writes on a Reserved slot owned by the
producer before `rt_graph_realtime_activate`.

## Adapter Module

Add a module:

    MetaSonic.Session.RTGraphAdapter

The module should expose only the session-facing API:

    data RTGraphAdapterOptions
    data RTGraphAdapterState

    defaultRTGraphAdapterOptions :: RTGraphAdapterOptions

    newRTGraphAdapter
      :: Ptr RTGraph
      -> TemplateGraph
      -> RTGraphAdapterOptions
      -> IO (Either SessionAdapterSetupIssue (SessionRuntimeAdapter IO))

    installSessionGraph
      :: Ptr RTGraph
      -> TemplateGraph
      -> RTGraphAdapterOptions
      -> IO (Either SessionAdapterSetupIssue RTGraphAdapterState)

Names can move during implementation, but the shape should stay:

- construction loads the graph in session mode;
- construction returns an adapter that can be injected into
  `stepSessionCommand`;
- adapter metadata is private and mutable only inside the adapter;
- `SessionState` remains owned by `MetaSonic.Session.State`, not by the
  runtime adapter.

`installSessionGraph` is exported for tests and for callers that need to
load/prewarm a graph before constructing a full adapter. Normal session
callers should use `newRTGraphAdapter`.

The v1 options shape should be explicit:

    data RTGraphAdapterOptions = RTGraphAdapterOptions
      { raoPerTemplatePolyphony :: Map TemplateName Int
      , raoDefaultPolyphony     :: Int
      }

`defaultRTGraphAdapterOptions` should use a conservative
`raoDefaultPolyphony = 1`. Per-template entries override the default.

`RTGraphAdapterState` is runtime metadata, not session state. It should
include at least:

- installed `TemplateGraph`;
- `TemplateName -> template_id` map;
- per-template prewarm count actually installed;
- the caller-owned `Ptr RTGraph`.

If the implementation needs mutation after hot-swap, store that metadata
in an `IORef` owned by the adapter value. That `IORef` is not a session
owner; it only tracks runtime lookup data needed to execute admitted
plans.

## Session-Mode Graph Install

Prep E needs a session-specific graph install helper layered over
`loadTemplateGraph`.

The helper should:

1. build the `TemplateName -> template_id` map from `tgTemplates` in
   execution order;
2. reject duplicate template names before touching the runtime;
3. call `loadTemplateGraph`;
4. remove loader-created auto-spawned instances so the runtime has no
   live logical voices after install;
5. set any configured polyphony/prewarm counts;
6. spawn and remove additional instances so
   `rt_graph_realtime_reserve` can later claim `Available` slots;
7. return private runtime metadata for the adapter.

Implementation must factor a small instrumented loader helper that
records the `rt_graph_template_instance_add` return value for each
loader-created auto-spawned instance. The session install helper removes
exactly those returned slot ids before prewarming. It must not assume
that slot id equals template id, and it must not guess silently if the
instrumented loader cannot report a slot id.

Default prewarm policy should be conservative:

- one available voice slot per non-writer template;
- respect writer-template polyphony clamping already performed by the
  loader;
- no dynamic allocation during `PlanVoiceStart`.

Later slices can add authoring/manifest-driven polyphony counts.

## Template Lookup

Template ids for runtime calls must be derived from `tgTemplates`
execution order:

    template_id = position in tgTemplates

Do not use `tplID` for runtime lookup. `tplID` is the input-position id
kept for diagnostics and may differ from execution order.

Duplicate template names should be rejected during adapter construction
or graph install. `SessionCommand` names templates by `TemplateName`, so
a duplicate-name runtime map would make voice admission ambiguous even if
the lower-level template graph could technically load.

## Control Target Resolution

Add a pure helper, likely in `MetaSonic.Session.RTGraphAdapter` or a
small sibling module:

    resolveControlTarget
      :: TemplateGraph
      -> VoiceBinding
      -> ControlTag
      -> Either SessionRuntimeIssue (NodeIndex, Int)

Before adding this helper, factor the shared symbolic-control lookup out
of `MetaSonic.OSC.Dispatch.Internal` so OSC dispatch and the session
adapter call the same implementation. The helper should mirror OSC
dispatch semantics without constructing an OSC address:

1. use `vbTemplateName` to find the voice's template in the installed
   graph;
2. use `ControlTag`'s `MigrationKey` to find a runtime node whose
   `rnMigrationKey` matches;
3. verify the requested control slot is in range for `rnControls`;
4. return the node index and control slot.

This helper is intentionally pure. The adapter turns the result into
`rt_graph_instance_set_control` or `rt_graph_realtime_set_control`.

The current admission layer does not validate symbolic control targets.
Therefore an invalid initial control or control write is a runtime
adapter failure in Prep E, not an admission rejection. A later prep slice
can move this validation earlier if that becomes valuable.

## Plan Execution Policy

### PlanVoiceStart

For `PlanVoiceStart templateName voiceKey initialControls`:

1. look up `templateName` in the adapter's template-id map;
2. call `rt_graph_realtime_reserve`;
3. if reserve returns `-1`, return `Left SriVoiceAllocationFailed`;
4. resolve and write every initial control to the Reserved slot using
   `rt_graph_instance_set_control`;
5. if any initial control cannot resolve, cancel the reservation and
   return a runtime failure;
6. call `rt_graph_realtime_activate`;
7. if activation fails, cancel the reservation and return a runtime
   failure;
8. return `Right (RuntimeCommitted (CommitVoiceStarted binding))`.

The resulting `VoiceBinding` uses the reserved slot id, the admitted
`VoiceKey`, and the admitted `TemplateName`.

Initial-control writes happen in the order they appear in the plan's
`[(ControlTag, Value)]` list. The adapter does no coalescing in v1.

### PlanVoiceStop

For `PlanVoiceStop binding`:

1. call `rt_graph_realtime_release` on `vbSlotId`;
2. if the queue accepts the release, return
   `Right (RuntimeCommitted (CommitVoiceStopped (vbVoiceKey binding)))`;
3. if the queue is full or the release is refused, return a runtime
   failure.

Prep E should use release, not remove, as the v1 voice-off behavior.
The runtime already treats release as immediate removal for graphs that
do not have envelope release behavior.

For envelope-bearing graphs, "voice stopped" in the session-state sense
means "release was queued". Audio may continue rendering until the
envelope completes. Prep E does not track post-release audio activity.

### PlanControlWrite

For `PlanControlWrite binding controlTag value`:

1. resolve `controlTag` against the installed graph and `binding`;
2. call `rt_graph_realtime_set_control` with the binding's slot id,
   resolved node index, control slot, and value;
3. on queue acceptance, return
   `Right RuntimeControlWriteAccepted`;
4. on queue refusal or target-resolution failure, return a runtime
   failure.

Success means the realtime queue accepted the write. It does not mean
the audio thread has already drained it.

### PlanHotSwap

Prep E's hot-swap support is intentionally constrained.

The existing loader clears and rebuilds the runtime graph. It does not
preserve live slots, migrate DSP state, or provide new slot ids for
surviving logical voices. Meanwhile Prep B/C's pure
`commitGraphInstalled` preserves bindings whose template still exists in
the new graph. Combining those two behaviors naively would make
`SessionState` claim voices are alive after the runtime has cleared
them.

Therefore Prep E should only accept `PlanHotSwap` when the plan's
preview rebuild leaves no surviving voice bindings. In practice this
means:

- empty-session graph install is supported;
- swaps that drop all currently active voices are supported;
- swaps that would preserve any active voice are rejected with a runtime
  failure until a later slice defines migration or respawn semantics.

On accepted install:

1. run session-mode graph install for the new `TemplateGraph`;
2. update the adapter's private metadata;
3. return `Right (RuntimeCommitted (CommitGraphInstalled label graph))`.

This still does not claim uninterrupted hot-swap. The current loader may
stop active audio, clear, and rebuild.

A later preserving-hot-swap slice has two plausible paths:

- add runtime migration support that preserves slots and DSP state;
- extend the session commit vocabulary to carry replacement
  `VoiceBinding`s after respawning surviving voices.

Both are outside Prep E.

The adapter relies on the plan's preview because Prep D's
`stepSessionCommand` runs admission and adapter execution against the
same `SessionState`. A future queued or multi-step orchestrator would
need the adapter or owner to recompute this policy against the current
state at execution time.

## Runtime Issue Surface

The current `SessionRuntimeIssue` constructors are not quite enough for
the real adapter. Extend the runtime issue surface with structured
runtime-operation payloads rather than stringly-typed queue labels:

    data RealtimeOp
      = RtOpReserve
      | RtOpActivate
      | RtOpCancel
      | RtOpRelease
      | RtOpSetControl

    data SessionRuntimeIssue
      = ...
      | SriUnknownRuntimeTemplate TemplateName
      | SriControlTargetRejected TemplateName ControlTag
      | SriRealtimeQueueFull RealtimeOp

`SriUnknownRuntimeTemplate` should be unreachable from
`stepSessionCommand` after admission succeeds against the same graph. It
is kept as defense-in-depth so adapter/state divergence is surfaced as a
runtime failure rather than a crash.

Do not encode queue-full or target-resolution failures as
`SriAdapterReason`. `SriAdapterReason` remains the escape hatch for
unexpected adapter-specific diagnostics only.

## Setup Issue Surface

Adapter construction and session-mode graph install happen before a plan
is being executed, so construction failures should not be silently mixed
into the plan-execution issue vocabulary.

Add a small setup issue type:

    data SessionAdapterSetupIssue
      = SasiDuplicateTemplateName TemplateName
      | SasiLoaderException String
      | SasiAutoSpawnTemplateIdMismatch Int Int
      | SasiAutoSpawnRowCountMismatch Int Int
      | SasiAutoSpawnMissing TemplateName
      | SasiPrewarmFailed TemplateName SessionPrewarmIssue

Keep the distinction from `SessionIssue` and `SessionCommitIssue`:

- admission problems are producer-facing `SessionIssue`;
- runtime call failures are `SessionRuntimeIssue`;
- setup/install failures before an adapter exists are
  `SessionAdapterSetupIssue`;
- setup/install failures during a constrained hot-swap are wrapped as
  `SriHotSwapInstallFailed SessionAdapterSetupIssue` so the runtime
  failure still carries the structured install detail;
- adapter returns that do not match the admitted plan are
  `SessionCommitIssue` through `StepCommitMismatch`;
- wrong success-shape bugs remain `StepAdapterProtocolBug`.

## Non-Goals

Session Prep E must not add:

- a C++ session object;
- a new C ABI;
- a realtime command worker;
- multiple producer arbitration;
- MIDI or OSC ownership;
- manifest reload;
- persistent session files;
- seamless hot-swap;
- live voice migration across graph reload;
- buffer/plugin lifecycle policy beyond the existing report surface;
- automatic generated-fusion turn-on.

## Implementation Series

Recommended commit shape:

1. **Decision note.** Land this note after review.
2. **Control target resolver.** Add the pure symbolic-control resolver
   by factoring the existing OSC dispatch lookup before duplicating it.
   Add tests for known target, missing template, missing node tag, and
   invalid control slot.
3. **Session-mode graph install helper.** Add the loader/prewarm helper
   using the instrumented loader strategy: record the exact auto-spawned
   slot ids, remove those ids, prewarm configured slots, and IO-test
   that no logical voices are live after install and reserve can claim a
   prewarmed slot.
4. **Adapter scaffold.** Add `MetaSonic.Session.RTGraphAdapter`,
   private adapter metadata, options, and constructor returning
   `SessionRuntimeAdapter IO`.
5. **Voice/control execution.** Implement `PlanVoiceStart`,
   `PlanVoiceStop`, and `PlanControlWrite` against the existing realtime
   ABI, including rollback on failed activation.
6. **Constrained graph install.** Implement `PlanHotSwap` only for
   empty/all-dropped voice cases; reject preserving swaps for now.
7. **IO-side step tests.** Drive the adapter through
   `stepSessionCommand` with `withRTGraph`. Pin at least:
   - voice-start success returns `StepCommitted` with the reserved slot
     in the `VoiceBinding`;
   - voice-start with an empty pool returns
     `StepRuntimeFailed SriVoiceAllocationFailed`;
   - voice-start with an unresolvable initial control returns
     `StepRuntimeFailed (SriControlTargetRejected ...)` and cancels the
     reservation;
   - voice-stop on an active slot returns `StepCommitted` with no
     rebuild result;
   - control-write to a known target returns `StepControlAccepted`;
   - control-write to an unknown `MigrationKey` returns
     `StepRuntimeFailed (SriControlTargetRejected ...)`;
   - hot-swap of an empty session returns `StepCommitted` with empty
     `rrrDropped`;
   - hot-swap that drops all active voices returns `StepCommitted` with
     non-empty `rrrDropped`;
   - hot-swap that would preserve any active voice returns
     `StepRuntimeFailed`;
   - `fromPatternEvent -> stepSessionCommand -> RTGraph` round-trips on
     at least one demo graph.
8. **Roadmap sync.** Mark only the first real adapter and constrained
   install behavior as landed. Keep full runtime session ownership
   gated.

## Verification

Minimum verification after implementation:

    just stack-test
    stack exec -- metasonic-bridge --snapshot-check
    stack exec -- metasonic-bridge --authoring-manifest named-control

No C++ verification is required unless the implementation changes C++
sources, headers, package C++ source lists, or the C ABI. The IO tests
for Prep E still exercise the existing C++ runtime through the Haskell
FFI.

## Next Slice After Prep E

After Prep E, the next useful decision is whether to build:

- a tiny single-threaded session owner around the real adapter; or
- a graph-reload/migration slice that can preserve active voices across
  hot-swap.

Do not start the realtime command queue until one of those paths has a
clear owner contract. The queue solves producer fan-in and audio-thread
handoff; it does not by itself solve graph reload ownership or voice
migration.
