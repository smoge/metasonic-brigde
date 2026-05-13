# Session Prep D - Runtime Adapter Shell

Date: 2026-05-12

Status: decision artifact for the next non-runtime session-prep slice.
This still does not introduce a runtime session owner. It defines the
narrow adapter vocabulary a later owner will inject, and a pure
single-step orchestrator that pins how admission, runtime work, and the
plan/commit handshake compose.

## Decision

Add a Haskell-only runtime adapter shell on top of Session Prep C:

1. The session orchestrator is **single-threaded**. No realtime queue,
   no concurrency primitive, no audio-thread cooperation lands in this
   slice.
2. The adapter is an **injected, mockable** record of functions, not a
   typeclass and not a C++ object.
3. The flow is fixed:

       SessionCommand
         -> admitSessionCommand
         -> SessionRuntimeAdapter
         -> applyPlannedCommit

   No other path mutates `SessionState`.
4. **Control-write success has no `SessionState` mutation.** The
   adapter reports a control-write acknowledgement; the orchestrator
   surfaces it without calling `applyPlannedCommit` for that plan.
5. Failure classes are kept structurally distinct:

   - admission rejection (`SessionIssue`);
   - runtime failure (`SessionRuntimeIssue`);
   - commit handshake mismatch (`SessionCommitIssue`);
   - adapter protocol bug (string-tagged for now).

6. No claim of uninterrupted hot-swap. The adapter may report a
   successful `CommitGraphInstalled`, but Prep D does not guarantee
   gap-free audio. That belongs to the runtime-owner slice that
   actually drives a backend.
7. The slice remains deterministic and library-only: no FFI, no C++
   session object, no realtime queue, no manifest reload, no MIDI/OSC
   producer arbitration, no buffer/plugin lifecycle policy beyond what
   Session Prep A already exposes.

The goal is to land a single-step shell whose behavior can be pinned
with a mock adapter, so the first real runtime adapter has a fixed
contract to satisfy.

## Recap: What Prep A, B, And C Already Landed

Session Prep A established the producer-facing vocabulary
(`MetaSonic.Session.Command`), pure OSC resolve-state rebuild
(`MetaSonic.Session.Resolve`), and read-only buffer/plugin lifecycle
report shapes (`MetaSonic.Session.Report`).

Session Prep B added pure admission and commit state in
`MetaSonic.Session.State`:

    initialSessionState  :: TemplateGraph -> SessionState
    admitSessionCommand  :: SessionCommand -> SessionState -> SessionAdmissionResult
    applySessionCommit   :: SessionCommit -> SessionState -> SessionState
    commitGraphInstalled :: SwapLabel -> TemplateGraph -> SessionState
                         -> (SessionState, ResolveRebuildResult)

Session Prep C added the plan/commit handshake:

    applyPlannedCommit
      :: SessionPlan
      -> SessionCommit
      -> SessionState
      -> Either SessionCommitIssue (SessionState, Maybe ResolveRebuildResult)

Prep C deliberately stopped at the handshake. It does not say *who*
calls the runtime between admission and commit, or how runtime failure
is reported. Prep D fills that gap with a mockable adapter and a
single-step orchestrator.

## Why This Comes Next

The future runtime session owner will need to:

1. accept a `SessionCommand` from Pattern, OSC, MIDI, or a UI;
2. call `admitSessionCommand`;
3. attempt the admitted plan against some runtime;
4. feed the resulting commit (if any) through `applyPlannedCommit`;
5. report acceptance, rejection, drops, or runtime failure.

Steps 3 and 4 are where the previous slices stopped. Without a small
abstraction for step 3, the eventual runtime owner risks either
inlining the runtime call into the orchestrator (which makes mocking
impossible) or skipping the handshake (which reintroduces the
plan/commit drift Prep C closed).

The fix is to inject step 3 as a record-of-functions adapter and pin
the orchestrator behavior with a mock implementation before any real
adapter exists. Once the shell is pinned, the first real adapter (for
the existing Haskell-driven load path) only has to satisfy a contract
that already has tests.

## Core Invariant

`SessionState` mutates if and only if the orchestrator returns
`StepCommitted`. Every other result — admission rejection, runtime
failure, commit mismatch, adapter protocol bug, control-write
acknowledgement — leaves state unchanged.

Equivalently:

- **admission** is pure (Prep B);
- the **adapter** runs in `m` but does not see `SessionState`;
- **commit** is gated by `applyPlannedCommit` (Prep C);
- `StepControlAccepted` is success without mutation, by design.

## Adapter Shape

Add a small library module, `MetaSonic.Session.Runtime`:

    newtype SessionRuntimeAdapter m = SessionRuntimeAdapter
      { sraRun
          :: SessionPlan
          -> m (Either SessionRuntimeIssue SessionRuntimeSuccess)
      }

    data SessionRuntimeSuccess
      = RuntimeCommitted SessionCommit
      | RuntimeControlWriteAccepted

    data SessionRuntimeIssue
      = SriVoiceAllocationFailed
      | SriHotSwapInstallFailed SessionAdapterSetupIssue
      | SriControlWriteRejected
      | SriBackendStopped
      | SriAdapterReason String

`SessionRuntimeAdapter m` is a record of one function so it composes
with any `Monad m`: `Identity` and `IO` for tests, `IO` for the
eventual real adapter, more elaborate stacks if a future caller wants
logging/instrumentation around the adapter.

`SessionRuntimeIssue` is intentionally narrow. The free-form
`SriAdapterReason` is a documented escape hatch for adapter-specific
diagnostics; an adapter that wants richer structured failures can wrap
its own ADT into a `Show` text or define a richer outer type in a
later slice.

`SessionRuntimeSuccess` separates the two success shapes the
orchestrator needs to distinguish:

- `RuntimeCommitted` carries a `SessionCommit` that should flow through
  `applyPlannedCommit`;
- `RuntimeControlWriteAccepted` says "the runtime accepted the symbolic
  control write; nothing to commit at the session-state layer."

## Orchestrator Shape

Add a second library module, `MetaSonic.Session.Step`:

    data SessionStepResult
      = StepRejected SessionIssue
      | StepRuntimeFailed SessionRuntimeIssue
      | StepCommitMismatch SessionCommitIssue
      | StepAdapterProtocolBug String
      | StepCommitted SessionState (Maybe ResolveRebuildResult)
      | StepControlAccepted

    stepSessionCommand
      :: Monad m
      => SessionRuntimeAdapter m
      -> SessionCommand
      -> SessionState
      -> m SessionStepResult

The orchestrator must:

1. call `admitSessionCommand`; on rejection, return `StepRejected`
   without invoking the adapter;
2. call `sraRun adapter plan`; on `Left`, return `StepRuntimeFailed`;
3. on `Right (RuntimeCommitted commit)`, call `applyPlannedCommit`;
   on `Left`, return `StepCommitMismatch`; on `Right (st', rebuild)`,
   return `StepCommitted st' rebuild`;
4. on `Right RuntimeControlWriteAccepted`:
   - if the plan was `PlanControlWrite`, return `StepControlAccepted`;
   - otherwise return `StepAdapterProtocolBug` describing the mismatch.

The orchestrator does not retry, does not split the plan, does not
return partial state, and does not log. Logging belongs to the eventual
runtime owner.

## Failure Class Discipline

Prep D distinguishes four failure classes because they imply different
caller actions:

- **`StepRejected SessionIssue`** — producer error. Surface to the
  producer (Pattern, OSC, MIDI, UI). The producer can correct and
  resubmit.
- **`StepRuntimeFailed SessionRuntimeIssue`** — runtime/backend
  problem. The session owner may retry, backoff, or escalate to an
  operator. The producer often does not need to know the runtime
  detail.
- **`StepCommitMismatch SessionCommitIssue`** — the runtime adapter
  returned a commit that did not match the plan. This is a bug in the
  adapter or the runtime, not in the producer. The session owner
  should log loudly.
- **`StepAdapterProtocolBug String`** — the adapter returned the wrong
  success *shape* (e.g., a `RuntimeControlWriteAccepted` for a
  `PlanHotSwap`). Distinct from a commit mismatch because there is no
  `SessionCommit` to point at. Log and stop using the adapter.

The first two are recoverable. The last two indicate a defect.

## Non-Goals

Session Prep D must not add:

- a realtime command queue;
- a runtime session owner with `IO` lifecycle;
- a C++ session object;
- actual graph install / hot-swap execution;
- audio-thread cooperation;
- FFI calls;
- manifest reload;
- MIDI/OSC producer arbitration;
- control-value persistence;
- a generated-executor turn-on;
- buffer/plugin allocation policy beyond Session Prep A.

The first real runtime adapter (covering the existing
Haskell-controlled `loadTemplateGraph` / `rt_graph_realtime_*` path)
belongs to a later slice. It should only land *after* Prep D's shell
behavior is pinned with a mock adapter.

## Mock Adapter Pattern

The Prep D tests should use a mock `SessionRuntimeAdapter` to simulate
each branch:

- always-rejects-with-admission-issue (tested by passing a known-bad
  command and verifying the adapter is never called);
- always-fails-with-`SriVoiceAllocationFailed`;
- returns a wrong-key `CommitVoiceStarted`;
- returns `RuntimeControlWriteAccepted`;
- returns a matching `CommitGraphInstalled`.

For the "adapter is never called on rejection" test, the mock should
expose a call counter (e.g., via `IORef`) so the test can assert
`callCount == 0` after a rejected command.

## Implementation Series

Recommended commit shape:

1. **Decision note.** Land this note.
2. **Runtime module.** Add `MetaSonic.Session.Runtime`:
   `SessionRuntimeAdapter`, `SessionRuntimeSuccess`,
   `SessionRuntimeIssue`. No orchestrator logic in this module.
3. **Step module.** Add `MetaSonic.Session.Step`:
   `SessionStepResult` and `stepSessionCommand`. Wire admission,
   adapter call, and `applyPlannedCommit` together; no public helpers
   beyond those two names.
4. **Mock adapter tests.** Pin:
   - admission rejection does not call the runtime adapter
     (counter-confirmed);
   - voice-start success commits a `VoiceBinding`;
   - voice-start runtime failure leaves state unchanged;
   - a wrong-key runtime commit surfaces as `StepCommitMismatch`;
   - control-write success leaves `SessionState` unchanged;
   - hot-swap success returns the commit-time
     `ResolveRebuildResult`;
   - `RuntimeControlWriteAccepted` on a non-control plan surfaces as
     `StepAdapterProtocolBug`;
   - `PEVoiceOn` flows from `fromPatternEvent` through
     `stepSessionCommand` to `StepCommitted`.
5. **Roadmap sync.** Add Session Prep D under the Session-Layer
   Scoping Gate. Mark runtime adapter contract and single-step mock
   shell landed. Keep realtime queue, actual graph installation
   policy, MIDI/OSC arbitration, and manifest reload explicitly
   gated.

## Verification

Minimum verification after implementation:

    just stack-test
    stack exec -- metasonic-bridge --snapshot-check
    stack exec -- metasonic-bridge --authoring-manifest named-control

No C++ verification is required unless the implementation touches C++
sources, headers, package C++ source lists, or the FFI surface.

## Next Slice After Prep D

After Prep D, the next useful step is the first **real** runtime
adapter: one that drives the existing Haskell-controlled load path
(`loadTemplateGraph`, `rt_graph_realtime_*`) for voice start/stop and
hot-swap. That slice must satisfy the Prep D contract — same mock
tests, plus IO-side tests that exercise real `RTGraph` ownership.

Only after the first real adapter ships should the project add a
realtime command queue, MIDI/OSC arbitration, manifest reload, or any
of the still-gated items.
