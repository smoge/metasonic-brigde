# Session Prep F - Single-Threaded Runtime Owner

Date: 2026-05-12

Status: draft decision artifact for review. This is the first slice that
may own an `RTGraph` lifetime, but it is still not the full runtime
session layer. It wraps the Prep E caller-owned adapter in a
single-threaded Haskell owner, keeps producer fan-in and realtime
queueing gated, and records what happens when runtime state may have
diverged from pure `SessionState`.

## Decision

Add a small Haskell-only session owner around the existing Prep E
adapter:

1. The owner allocates and releases the `RTGraph` using the existing
   `withRTGraph` bracket discipline.
2. The owner constructs the Prep E `SessionRuntimeAdapter IO` with
   `newRTGraphAdapter`.
3. The owner stores the current pure `SessionState` in a private
   `IORef`.
4. The owner stores a private status:

       ready | diverged(reason)

5. `stepSessionOwner` is single-threaded and caller-driven. It does
   not add a realtime queue, worker thread, lock, STM channel, or C++
   session object.
6. `stepSessionOwner` delegates the actual command flow to the already
   landed Prep D/E path:

       SessionCommand
         -> stepSessionCommand realAdapter command currentState
         -> SessionStepResult

7. The owner writes a new `SessionState` only when the step returns
   `StepCommitted`.
8. `StepControlAccepted`, admission rejection, normal runtime failure,
   and preserving-hot-swap rejection do not mutate owner state.
9. The owner becomes diverged when the step result proves the runtime
   and pure state may no longer agree:

   - `StepRuntimeFailed (SriHotSwapInstallFailed issue)`;
   - `StepCommitMismatch issue`;
   - `StepAdapterProtocolBug message`.

10. Once diverged, the owner refuses later commands without calling the
    adapter. V1 recovery is teardown and recreate, not in-place repair.
11. The owner does not claim uninterrupted hot-swap, preserving
    hot-swap, MIDI/OSC arbitration, manifest reload, backend audio
    stream ownership, or recoverable failed-install semantics.

The goal is to move from "callers manually keep `RTGraph`, adapter, and
`SessionState` together" to one explicit runtime-state owner while
keeping concurrency and producer fan-in out of scope.

## Why This Comes After Prep E

Session Prep E proved the existing runtime ABI can satisfy the Prep D
adapter contract:

- session-mode graph install removes loader auto-spawned voices and
  prewarms reservable slots;
- `PlanVoiceStart` reserves, writes initial controls, and activates;
- `PlanVoiceStop` queues release;
- `PlanControlWrite` resolves symbolic controls and queues writes;
- constrained `PlanHotSwap` installs only empty/drop-all swaps and
  rejects preserving swaps;
- setup/install failures are structured as `SessionAdapterSetupIssue`
  and propagate through `SriHotSwapInstallFailed`.

What Prep E deliberately did not answer is ownership. A caller still
has to keep these pieces synchronized:

- the `Ptr RTGraph`;
- the `SessionRuntimeAdapter IO`;
- the current `SessionState`;
- whether a failed graph install made the runtime unsafe to reuse.

Prep F should answer exactly that ownership question without widening
the runtime model. Queueing before ownership would only move commands
around; it would not define who owns state or what happens after a
divergent runtime failure. Preserving hot-swap before ownership would
need a place to coordinate old state, new graph, live bindings, resolve
rebuild, and recovery. Prep F creates that place without attempting
migration yet.

## Recap: What Prep A-E Already Landed

Prep A added:

- `MetaSonic.Session.Command`: producer-agnostic `SessionCommand`,
  `SessionEvent`, `SessionIssue`, and `fromPatternEvent`;
- `MetaSonic.Session.Resolve`: pure `ResolveState` rebuild across
  graph replacement;
- `MetaSonic.Session.Report`: read-only lifecycle report shapes and
  readers.

Prep B added pure session state and admission:

    initialSessionState  :: TemplateGraph -> SessionState
    admitSessionCommand  :: SessionCommand -> SessionState -> SessionAdmissionResult
    applySessionCommit   :: SessionCommit -> SessionState -> SessionState
    commitGraphInstalled :: SwapLabel -> TemplateGraph -> SessionState
                         -> (SessionState, ResolveRebuildResult)

Prep C added checked plan/commit pairing:

    applyPlannedCommit
      :: SessionPlan
      -> SessionCommit
      -> SessionState
      -> Either SessionCommitIssue (SessionState, Maybe ResolveRebuildResult)

Prep D added the injected adapter and single-step orchestrator:

    newtype SessionRuntimeAdapter m = SessionRuntimeAdapter
      { sraRun
          :: SessionPlan
          -> m (Either SessionRuntimeIssue SessionRuntimeSuccess)
      }

    stepSessionCommand
      :: Monad m
      => SessionRuntimeAdapter m
      -> SessionCommand
      -> SessionState
      -> m SessionStepResult

Prep E added the first real adapter:

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

Prep F should not replace any of those contracts. It should compose
them and own their mutable runtime-facing state.

## Proposed Module

Add:

    MetaSonic.Session.Owner

The constructor for `SessionOwner` should remain hidden.

Suggested public surface:

    data SessionOwner

    data SessionOwnerOptions = SessionOwnerOptions
      { sooBuilderCapacity :: !Int
      , sooMaxFrames       :: !Int
      , sooAdapterOptions  :: !RTGraphAdapterOptions
      }

    defaultSessionOwnerOptions :: SessionOwnerOptions

    data SessionOwnerStatus
      = SessionOwnerReady
      | SessionOwnerDiverged !SessionOwnerDivergence

    data SessionOwnerDivergence
      = SodHotSwapInstallFailed !SessionAdapterSetupIssue
      | SodBackendStopped
      | SodCommitMismatch !SessionCommitIssue
      | SodAdapterProtocolBug !String

    data SessionOwnerStepResult
      = SessionOwnerStep !SessionStepResult
      | SessionOwnerDivergedNow !SessionStepResult !SessionOwnerDivergence
      | SessionOwnerBlocked !SessionOwnerDivergence

    withSessionOwner
      :: TemplateGraph
      -> SessionOwnerOptions
      -> (SessionOwner -> IO a)
      -> IO (Either SessionAdapterSetupIssue a)

    stepSessionOwner
      :: SessionOwner
      -> SessionCommand
      -> IO SessionOwnerStepResult

    sessionOwnerState
      :: SessionOwner
      -> IO SessionState

    sessionOwnerStatus
      :: SessionOwner
      -> IO SessionOwnerStatus

`withSessionOwner` is a scoped bracket like `withRTGraph`: callers must
not retain the owner outside the callback. The owner contains a foreign
runtime handle by construction, so returning it from the callback would
be the same class of misuse as returning a raw `Ptr RTGraph` from
`withRTGraph`.

`defaultSessionOwnerOptions` may be test/demo oriented. Callers with
known graph-size or block-size requirements should override
`sooBuilderCapacity` and `sooMaxFrames`; Prep F should not invent a
hidden capacity formula.

## Internal Shape

The hidden owner can be implemented as:

    data SessionOwner = SessionOwner
      { soState   :: IORef SessionState
      , soStatus  :: IORef SessionOwnerStatus
      , soAdapter :: SessionRuntimeAdapter IO
      }

The `RTGraph` pointer itself does not need to be stored if the bracket
owns it and the adapter closure already captures it. If tests need
direct runtime inspection, keep those tests at the `RTGraphAdapter`
level; Prep F tests should inspect owner behavior through the owner API
unless a specific bug requires a lower-level probe.

The owner does not enforce single-threading at runtime. Concurrent
`stepSessionOwner` calls race on the internal `IORef`s and produce
undefined behavior; serialization is the caller's responsibility.

## Step Semantics

`stepSessionOwner owner cmd`:

1. Read `soStatus`.
2. If status is `SessionOwnerDiverged reason`, return
   `SessionOwnerBlocked reason` without invoking the adapter.
3. Read current `SessionState`.
4. Call `stepSessionCommand soAdapter cmd currentState`.
5. If the result is `StepCommitted newState _`, write `newState` to
   `soState`.
6. If the result is `StepRuntimeFailed (SriHotSwapInstallFailed issue)`,
   write `SessionOwnerDiverged (SodHotSwapInstallFailed issue)` to
   `soStatus`.
7. If the result is `StepRuntimeFailed SriBackendStopped`, write
   `SessionOwnerDiverged SodBackendStopped` to `soStatus`.
8. If the result is `StepCommitMismatch issue`, write
   `SessionOwnerDiverged (SodCommitMismatch issue)` to `soStatus`.
9. If the result is `StepAdapterProtocolBug message`, write
   `SessionOwnerDiverged (SodAdapterProtocolBug message)` to `soStatus`.
10. If the step produced a divergence reason, return
    `SessionOwnerDivergedNow result reason`.
11. Otherwise, return `SessionOwnerStep result`.

All other outcomes leave status and state unchanged.

This means the call that causes divergence makes the transition visible
without forcing callers to re-run the classifier or reread
`sessionOwnerStatus`. It carries both the underlying `SessionStepResult`
for audit and the structured `SessionOwnerDivergence` reason. The
*next* command is blocked with `SessionOwnerBlocked reason`.

After divergence, `sessionOwnerState` returns the last `SessionState`
for which the runtime was known to agree. The runtime may have advanced
past that point; callers should treat the returned state as stale
relative to actual audio behavior.

## Divergence Policy

V1 treats divergence as terminal for the owner.

The important case is failed constrained hot-swap install. Prep E
documents that `installSessionGraph` may clear or partially rebuild the
runtime before returning `Left`. In that case, pure `SessionState` still
claims the old graph while the runtime may no longer contain it. Prep F
must not pretend the owner can keep running safely.

`StepCommitMismatch` and `StepAdapterProtocolBug` are also terminal for
the owner. They indicate the runtime adapter returned a result that does
not match the admitted plan. Even if current tests can only produce
those paths with mocks, the real owner should treat them as state-sync
failures rather than continuing.

`SriBackendStopped` is terminal for the owner in v1. A stopped backend
means runtime work may no longer be accepted or drained in the way the
session state expects. If a later backend owner can restart audio
out-of-band while preserving the same `RTGraph` and queue semantics, it
can introduce a narrower non-terminal policy then.

Non-terminal failures:

- `StepRejected issue`: admission rejected the command before runtime
  work;
- `StepRuntimeFailed SriVoiceAllocationFailed`: no slot was allocated;
- `StepRuntimeFailed (SriControlTargetRejected issue)`: the adapter
  cancels any voice-start reservation before returning;
- `StepRuntimeFailed SriHotSwapWouldPreserveVoices`: the adapter
  rejected before installing a graph;
- `StepRuntimeFailed (SriRealtimeQueueFull op)`: queue acceptance
  failed for the reported operation;
- `StepControlAccepted`: control write succeeded without state
  mutation.

If later runtime issues prove non-recoverable, add them to the owner
divergence classifier explicitly. Do not make every
`SessionRuntimeIssue` terminal by default.

## Construction Failure

`withSessionOwner` should construct in this order:

1. Allocate the `RTGraph` with `withRTGraph`.
2. Call `newRTGraphAdapter`.
3. On `Left issue`, return `Left issue` from `withSessionOwner`.
4. On success, create `IORef`s for:
   - `initialSessionState graph`;
   - `SessionOwnerReady`.
5. Run the callback with the hidden owner.
6. Let the `withRTGraph` bracket destroy the runtime after the callback
   returns or throws.

Construction failure is not a `SessionOwnerStatus`, because no owner
exists yet.

Like `withRTGraph`, `withSessionOwner` propagates exceptions thrown by
the callback after running the runtime-cleanup bracket. Construction
failures are returned as `Left`; runtime exceptions during the callback
are thrown.

## Event Semantics

Prep F should not introduce a broad producer event stream. Returning
`SessionOwnerStepResult` plus readable owner state/status is enough for
library tests and direct callers.

Future producer-facing event work can translate owner results into a
larger event vocabulary after the system decides how Pattern, OSC, MIDI,
and UI producers share one owner. That belongs with producer
arbitration, not this slice.

## Non-Goals

Session Prep F must not add:

- a realtime command queue;
- a worker thread;
- STM/channel producer fan-in;
- MIDI, OSC, Pattern, or UI arbitration;
- a C++ session object;
- new C ABI;
- audio backend ownership;
- uninterrupted hot-swap;
- preserving active voices across graph install;
- recoverable failed-install repair;
- manifest reload;
- resource allocation policy beyond the graph/options already passed to
  the owner.

## Implementation Series

Recommended commit shape:

1. **Decision note.** Land this note after review.
2. **Owner types and module export.** Add
   `MetaSonic.Session.Owner`, hidden `SessionOwner`, options, status,
   divergence, and step-result types. Add the module to `package.yaml`.
3. **Owner construction.** Implement `withSessionOwner`,
   `defaultSessionOwnerOptions`, `sessionOwnerState`, and
   `sessionOwnerStatus`. Construction wraps `withRTGraph` and
   `newRTGraphAdapter`.
4. **Owner step.** Implement `stepSessionOwner` and the divergence
   classifier. State writes happen only for `StepCommitted`; status
   writes happen only for the explicit terminal cases. A
   divergence-causing command returns `SessionOwnerDivergedNow`, while
   later commands return `SessionOwnerBlocked`.
5. **Owner tests.** Pin:
   - construction initializes `initialSessionState`;
   - setup failure returns `Left SessionAdapterSetupIssue`;
   - `CmdVoiceOn` mutates owner state internally;
   - `CmdControlWrite` returns accepted and does not mutate owner
     state;
   - `CmdVoiceOff` removes the binding from owner state;
   - empty-session hot-swap updates owner graph and allows starting a
     voice from the new graph;
   - duplicate-template hot-swap returns the underlying runtime failure,
     marks owner status diverged, and blocks a later command without
     invoking the adapter;
   - after divergence, a follow-up command returns
     `SessionOwnerBlocked` and a mock adapter call counter proves zero
     new adapter invocations across that follow-up command;
   - preserving-hot-swap rejection does not mark the owner diverged;
   - `SriBackendStopped` marks the owner diverged;
   - admission rejection does not mark the owner diverged.
6. **Roadmap sync.** Mark only the single-threaded owner and divergence
   policy landed. Keep queueing, producer arbitration,
   preserving-hot-swap, audio-thread coordinated reload, and repair
   semantics gated.

## Verification

Minimum verification after implementation:

    just stack-test

No C++ verification is required unless the implementation changes C++
sources, headers, package C++ source lists, or the C ABI. Prep F should
be Haskell-only and should reuse the Prep E adapter and existing FFI
surface.

## Next Slice After Prep F

After Prep F, there are two defensible next directions:

1. **Producer arbitration / queue decision.** Once one owner exists, a
   queue can target it. That slice should decide command ordering,
   backpressure, dropped-command events, and how OSC/MIDI/Pattern share
   the single producer contract.
2. **Preserving hot-swap decision.** With ownership and divergence
   policy in place, the system can scope active-voice migration,
   resolve-state rebuild, slot preservation, and failed-install
   recovery.

Do not do both in one slice. Queueing and preserving hot-swap have
different failure modes and different tests.
