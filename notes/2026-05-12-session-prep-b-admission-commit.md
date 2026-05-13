# Session Prep B - Admission And Commit Contract

Date: 2026-05-12

Status: decision artifact for the next non-runtime session-prep slice.
This is still not the session runtime. It defines the pure boundary
between producer commands, planned runtime work, and state commits
after runtime work succeeds.

## Decision

Add a Haskell-only admission/commit layer on top of Session Prep A:

1. `admitSessionCommand` validates a `SessionCommand` against a pure
   `SessionState` and returns either a rejection or a planned action.
2. Admission is read-only. It must not mutate active voices, replace
   graphs, rebuild the authoritative `ResolveState`, write queues, or
   touch `RTGraph`.
3. `applySessionCommit` is the only pure state mutation path. It
   applies facts that are already known to have succeeded outside this
   layer: voice started, voice stopped, control write accepted by the
   runtime shell, or graph install completed.
4. Hot-swap resolve-state rebuild happens at graph-install commit
   time, not at admission time.
5. The slice remains deterministic and library-only: no FFI, no C++
   session object, no realtime command queue, no manifest reload, and
   no producer arbitration.

This gives the eventual runtime session owner a narrow waist:
producers ask for intent, admission returns a plan, the IO/runtime shell
executes that plan, and only successful execution feeds a commit back
into pure session state.

## Why This Comes After Session Prep A

Session Prep A established the nouns:

- `MetaSonic.Session.Command` names producer intent and diagnostic
  rejection events.
- `MetaSonic.Session.Resolve` can rebuild OSC resolve state after a
  new `TemplateGraph` is installed.
- `MetaSonic.Session.Report` exposes read-only lifecycle counters and
  static plugin metadata.

The next risk is ordering. If a future session layer mutates its
authoritative state during admission, a failed runtime action can leave
the Haskell model ahead of the actual installed graph or voice table.
That would be worse than having no session layer: later OSC, MIDI, or
pattern commands would resolve against state the audio side never
accepted.

The fix is an explicit two-step model:

- **admission** answers "is this request coherent enough to attempt?"
- **commit** answers "what state changes after the attempt succeeds?"

This mirrors the existing architecture: Haskell owns structure and
intent; the runtime host owns installed state and returns facts only
after work is actually accepted.

## Core Invariant

Admission must be side-effect free.

For every `SessionCommand`, admission may inspect:

- the current `TemplateGraph`;
- the active voice table;
- the current `ResolveState`;
- OSC-safe identifier rules from `MetaSonic.OSC.Dispatch`;
- static command metadata.

Admission must not:

- allocate a runtime voice slot;
- register a new voice in the authoritative `ResolveState`;
- remove a voice from the authoritative `ResolveState`;
- install or replace a `TemplateGraph`;
- rebuild the authoritative `ResolveState`;
- enqueue realtime control writes;
- call any FFI function;
- read or write buffer/plugin lifecycle counters.

The only functions allowed to produce mutated pure session state are
the commit helpers in `MetaSonic.Session.State`.

## Proposed State Shape

The implementation should add a small pure module, tentatively:

    MetaSonic.Session.State

The v1 state should be just enough to admit commands and rebuild OSC
resolution after graph install:

    data SessionState = SessionState
      { ssGraph   :: TemplateGraph
      , ssVoices  :: Map VoiceKey VoiceBinding
      , ssResolve :: ResolveState
      }

`SessionState` is a mirror of session-visible facts, not runtime
ownership. It does not contain `RTGraph`, queue handles, buffer storage,
plugin instances, PortAudio state, MIDI devices, or manifest source
documents.

The initial state should be constructed from one installed
`TemplateGraph`:

    initialSessionState :: TemplateGraph -> SessionState

It starts with no active voices and `emptyResolveState` for that graph.
An empty graph (`TemplateGraph [] mempty`) is a legal starting point: no
template-name lookup will succeed until the first `CommitGraphInstalled`
replaces it, which matches how a session would boot before the first
authoritative install.

## Admission Result

Admission should return a structural result:

    data SessionAdmissionResult
      = SessionAdmitted SessionCommand SessionPlan
      | SessionRejected SessionCommand SessionIssue

Audit logging requires more than the command alone: a reader of an
`accepted` event needs to know which plan was produced (which
`VoiceBinding` will be stopped, which `ResolveRebuildResult` previewed,
etc.). Prep B therefore keeps the plan-aware admission result in
`MetaSonic.Session.State`, where `SessionPlan` is defined.

Do not widen `SessionEvent` in `MetaSonic.Session.Command` to mention
`SessionPlan`. `Command` defines the producer vocabulary that `State`
will consume; importing `SessionPlan` back into `Command` would create
the wrong dependency direction and likely a module cycle.

Callers that only need the coarse Prep A event vocabulary can still
derive `SessionCommandAccepted` / `SessionCommandRejected` from
`SessionAdmissionResult` and ignore the plan. Callers that need audit
detail should log the full admission result.

## Planned Actions

Plans describe work a runtime shell may attempt:

    data SessionPlan
      = PlanVoiceStart TemplateName VoiceKey [(ControlTag, Value)]
      | PlanVoiceStop VoiceBinding
      | PlanControlWrite VoiceBinding ControlTag Value
      | PlanHotSwap SwapLabel TemplateGraph ResolveRebuildResult

`VoiceBinding` fields inside a plan are snapshots taken at admission
time. Embedding the binding rather than re-keying by `VoiceKey` saves
the runtime shell a second lookup and keeps the plan self-describing
once it leaves the session module.

Important details:

- `PlanVoiceStart` does not contain a runtime slot. Slot assignment is
  runtime/session-owner work. State changes only after a later
  `CommitVoiceStarted` supplies a concrete `VoiceBinding`.
- `PlanVoiceStop` carries the existing `VoiceBinding` so the runtime
  shell has the slot and template identity it needs.
- `PlanControlWrite` carries the existing `VoiceBinding` plus the
  symbolic target. Prep B does not lower this into an FFI call.
- `PlanHotSwap` may carry a preview `ResolveRebuildResult` computed
  from the state at admission time. That preview is diagnostic only.
  The authoritative rebuild happens again at commit time, against the
  state that is current when the graph install succeeds.

The diagnostic preview is useful for UI/logging because it can tell a
producer which active voices would be dropped if the graph install
succeeds. It must not be used as proof that the graph has been
installed.

## Commits

Commits describe runtime facts that have already happened:

    data SessionCommit
      = CommitVoiceStarted VoiceBinding
      | CommitVoiceStopped VoiceKey
      | CommitGraphInstalled SwapLabel TemplateGraph

`applySessionCommit` should be pure:

    applySessionCommit :: SessionCommit -> SessionState -> SessionState

Graph install also needs a result-bearing helper:

    commitGraphInstalled
      :: SwapLabel
      -> TemplateGraph
      -> SessionState
      -> (SessionState, ResolveRebuildResult)

Commit policy:

- `CommitVoiceStarted` inserts the `VoiceBinding` into `ssVoices` and
  registers it in `ssResolve` with `registerVoice`.
- `CommitVoiceStopped` removes the voice from `ssVoices` and
  `ssResolve`.
- `CommitGraphInstalled` replaces `ssGraph` and rebuilds `ssResolve`
  from the current `ssVoices` using `rebuildResolveState`. Voices
  reported as dropped by the rebuild are removed from `ssVoices`.
  The admission-time `ResolveRebuildResult` preview is advisory and
  may become stale. The authoritative rebuild happens at commit time
  against the current `ssVoices`. The eventual runtime owner must
  serialize commits before applying them, but it does not need to
  block every producer between hot-swap admission and install
  completion. Callers that need to log or route the actual
  commit-time drop list must use `commitGraphInstalled`; the
  `applySessionCommit` wrapper returns only the new state. Prep B does
  not retain the drop list inside `SessionState`.

`SessionState` stores active voices in `Map VoiceKey VoiceBinding`.
Therefore rebuild diagnostics emitted by `commitGraphInstalled` are
deterministic in `VoiceKey` order, not runtime/start order. Prep B does
not track start order.

There is deliberately no `CommitControlWritten` constructor. Symbolic
control writes have no state to mutate at this layer, and an empty
constructor would invite future drift toward local control-value
storage that contradicts the Non-Goals list. The runtime shell can log
control-write acknowledgements directly from the plan without going
through `applySessionCommit`.

There are also no `Commit*Failed` constructors. Runtime failure is
signaled by the absence of a commit; pure session state stays
consistent because admission never mutated it.

The commit path is the only place where active voices may be added,
removed, or re-associated with an installed graph.

## Command Admission Policy

### `CmdVoiceOn`

Admission accepts only when:

- the requested `TemplateName` exists in `ssGraph`;
- the `VoiceKey` is not already active;
- the `VoiceKey` satisfies the same OSC-safe identifier profile used by
  `MetaSonic.OSC.Dispatch.registerVoice`;
- the `VoiceKey` is not one of `reservedOscPathSegments`.

Pure admission must not call `registerVoice` because that helper
mutates `ResolveState`. The implementation should export a non-mutating
validator from `MetaSonic.OSC.Dispatch`:

    validateVoiceKey :: ByteString -> Either DispatchIssue ()

`registerVoice` then becomes `validateVoiceKey` plus the existing
state insert, so the two paths share one rule set without duplication.

On success, admission returns `PlanVoiceStart`.

On failure:

- missing template -> `SiUnknownTemplate`;
- duplicate voice -> `SiVoiceAlreadyActive` (new issue constructor);
- bad or reserved voice key -> `SiInvalidVoiceKey`.

### `CmdVoiceOff`

Admission accepts only when the voice is active.

On success, admission returns `PlanVoiceStop` with the current
`VoiceBinding`.

On failure, admission returns `SiStaleVoice`.

### `CmdControlWrite`

Admission accepts only when the voice is active.

On success, admission returns `PlanControlWrite` with the current
`VoiceBinding`.

On failure, admission returns `SiStaleVoice`.

Prep B deliberately does not introduce full symbolic-control
validation. That can land with the runtime action lowering slice, where
`ControlTag` is translated to a concrete node/control target. This
keeps Prep B focused on session ownership state, not FFI action
construction.

### `CmdHotSwap`

Admission accepts a precompiled `TemplateGraph` and returns
`PlanHotSwap`.

Admission may compute a diagnostic `ResolveRebuildResult` using the
current voice table, but it must not install the graph or mutate
`ssResolve`.

The graph becomes authoritative only after
`CommitGraphInstalled label graph`.

## Issue Vocabulary

Session Prep B should add only the issue constructor needed by pure
admission:

    SiVoiceAlreadyActive VoiceKey

Keep runtime and install failures out of `SessionIssue` for now.
Examples that remain out of scope:

- voice allocation failed;
- realtime queue full;
- runtime graph install failed;
- buffer allocation failed;
- plugin unavailable at runtime;
- audio backend stopped.

Those belong to a later execution-result vocabulary once a runtime
session shell exists.

## Ordering Model

Prep B assumes one serialized command stream, but does not implement
that stream.

The pure tests can model ordering by applying:

1. `admitSessionCommand cmd state`
2. a synthetic successful `SessionCommit`
3. `applySessionCommit commit state`

No concurrency policy lands in this slice. If two producers race to
start the same `VoiceKey`, the eventual session owner must serialize
them before admission. The pure model then rejects the second command
against the state produced by the first successful commit.

## Non-Goals

Session Prep B must not add:

- `RTGraph` ownership;
- FFI calls;
- a C++ session object;
- a realtime queue worker;
- graph installation;
- voice allocation;
- MIDI / OSC / pattern arbitration;
- manifest import/reload;
- buffer allocation policy;
- plugin loading or dynamic plugin APIs;
- audio-thread symbolic lookup;
- control-value persistence.

It is acceptable for tests to build `TemplateGraph` values and
synthetic `VoiceBinding`s. It is not acceptable for Prep B tests to
require live audio or runtime graph installation.

## Implementation Series

Recommended commit shape:

1. **Decision note.** Land this note.
2. **Vocabulary and validation helpers.** In `MetaSonic.Session.Command`,
   add `SiVoiceAlreadyActive` but keep `SessionEvent` unchanged. In
   `MetaSonic.OSC.Dispatch`, export
   `validateVoiceKey :: ByteString -> Either DispatchIssue ()` and
   refactor `registerVoice` to call it.
3. **State module scaffold.** Add `MetaSonic.Session.State` with
   `SessionState`, `SessionPlan`, `SessionCommit`,
   `SessionAdmissionResult`, `initialSessionState`,
   `admitSessionCommand`, `applySessionCommit`, and
   `commitGraphInstalled`.
4. **Admission tests.** Pin known-template voice start, unknown
   template rejection, invalid/reserved voice key rejection, duplicate
   voice rejection after commit, stale voice-off/control-write
   rejection, and valid control-write planning.
5. **Commit tests.** Pin voice-start insertion, voice-stop removal,
   graph-install rebuild, hot-swap dropping missing-template voices,
   authoritative commit-time rebuild reporting, invariant failure on
   invalid committed bindings, and the absence-of-commit behavior on
   simulated runtime failure.
6. **Roadmap sync.** Add Session Prep B under the same
   Session-Layer Scoping Gate while keeping runtime session
   implementation explicitly gated.

## Verification

Minimum verification after implementation:

    just stack-test
    stack exec -- metasonic-bridge --snapshot-check
    stack exec -- metasonic-bridge --authoring-manifest named-control

No C++ verification is required unless the implementation touches C++
sources, headers, package C++ source lists, or the FFI surface.
