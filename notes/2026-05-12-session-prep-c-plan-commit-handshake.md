# Session Prep C - Plan/Commit Handshake

Date: 2026-05-12

Status: decision artifact for Session Prep C implementation.
This is still not the session runtime. It defines a pure checked
boundary between an admitted `SessionPlan` and the later
`SessionCommit` that reports successful runtime work.

## Decision

Add a Haskell-only plan/commit handshake on top of Session Prep B:

1. `admitSessionCommand` remains the only command admission entry
   point. It returns either a rejected command or an admitted
   `SessionPlan`.
2. Runtime work remains outside this layer. A future session owner may
   allocate voices, stop voices, install graphs, or write controls
   after reading the plan.
3. Successful runtime work must come back as a `SessionCommit`.
4. Prep C adds a checked helper that verifies the supplied
   `SessionCommit` matches the original `SessionPlan` before mutating
   pure `SessionState`.
5. Graph-install commits must still expose the authoritative
   commit-time `ResolveRebuildResult`.
6. The slice remains deterministic and library-only: no FFI calls, no
   C++ session object, no realtime queue, no manifest reload, no MIDI
   or OSC producer arbitration, and no runtime allocation.

The goal is to prevent a future runtime shell from accidentally
feeding a successful runtime fact into the wrong admitted plan. Prep B
made admission and commit separate. Prep C makes their relationship
explicit and testable.

## Recap: What Prep A And B Already Landed

Session Prep A established the nouns consumed by any future session
owner:

- `MetaSonic.Session.Command` defines producer intent:
  `CmdVoiceOn`, `CmdVoiceOff`, `CmdControlWrite`, and `CmdHotSwap`.
- `fromPatternEvent` lifts pattern output into the shared command
  vocabulary, so Pattern, OSC, MIDI, and future producers do not each
  invent their own mutation path.
- `SessionEvent` and `SessionIssue` provide a small diagnostic surface
  for command acceptance/rejection.
- `MetaSonic.Session.Resolve` can rebuild OSC `ResolveState` after a
  `TemplateGraph` replacement, preserving surviving `VoiceBinding`s
  and reporting dropped bindings.
- `MetaSonic.Session.Report` exposes read-only lifecycle report
  shapes and readers for buffers/plugins without owning runtime
  resources.

Session Prep B added pure admission and commit state:

- `SessionState` mirrors session-visible facts:

      data SessionState = SessionState
        { ssGraph   :: TemplateGraph
        , ssVoices  :: Map VoiceKey VoiceBinding
        , ssResolve :: ResolveState
        }

- `admitSessionCommand` validates a `SessionCommand` against
  `SessionState` and returns a `SessionPlan` without mutating state.
- `SessionPlan` describes runtime work that may be attempted:

      data SessionPlan
        = PlanVoiceStart TemplateName VoiceKey [(ControlTag, Value)]
        | PlanVoiceStop VoiceBinding
        | PlanControlWrite VoiceBinding ControlTag Value
        | PlanHotSwap SwapLabel TemplateGraph ResolveRebuildResult

- `SessionCommit` describes runtime facts that have already succeeded:

      data SessionCommit
        = CommitVoiceStarted VoiceBinding
        | CommitVoiceStopped VoiceKey
        | CommitGraphInstalled SwapLabel TemplateGraph

- `applySessionCommit` mutates pure state from a commit.
- `commitGraphInstalled` returns both the new state and the
  authoritative commit-time `ResolveRebuildResult`.

Prep B deliberately leaves one gap open: `applySessionCommit` can apply
any `SessionCommit` to any `SessionState`. That is useful as a small
primitive, but it is too permissive for the future runtime shell. Prep C
fills that gap without creating the shell.

## Why This Comes Next

The future session owner will likely follow this shape:

1. receive a `SessionCommand` from Pattern, OSC, MIDI, or a UI;
2. call `admitSessionCommand`;
3. execute the returned plan against the runtime;
4. apply a commit only if the runtime action succeeds;
5. report acceptance, rejection, drops, or runtime failure to
   producers.

Without a checked plan/commit handshake, step 4 can drift from step 2.
Examples:

- a `PlanVoiceStart` for `VoiceKey "lead"` receives a commit for
  `VoiceKey "bass"`;
- a plan for template `"drone"` receives a binding for template
  `"stab"`;
- a `PlanVoiceStop` is followed by a graph-install commit;
- a `PlanHotSwap` preview for one graph is followed by installation of
  a different graph;
- a `PlanControlWrite` receives a state commit even though control
  writes have no session-state mutation in Prep B.

All of those are session-owner bugs, not producer mistakes. They should
be caught by a pure helper before the state mirror is mutated.

## Core Invariant

A `SessionCommit` may mutate `SessionState` only when it matches the
`SessionPlan` that authorized the runtime attempt.

Any `Left SessionCommitIssue` outcome leaves `SessionState`
unmodified. Mutation happens only on `Right`.

Prep C does not re-admit the original command. It validates the
commit against the plan snapshot. This is important because the state
may have legitimately changed between admission and commit, especially
around graph install:

- `PlanHotSwap` carries an admission-time `ResolveRebuildResult`
  preview.
- `commitGraphInstalled` recomputes the authoritative rebuild against
  the current `ssVoices`.
- Prep C must preserve that distinction: matching the plan proves the
  commit is for the same swap request, not that the preview is still
  authoritative.

## Proposed API

Add a small checked helper to `MetaSonic.Session.State`:

    data SessionCommitIssue
      = SciUnexpectedCommit SessionPlan SessionCommit
      | SciVoiceKeyMismatch VoiceKey VoiceKey
      | SciTemplateMismatch TemplateName TemplateName
      | SciSwapLabelMismatch SwapLabel SwapLabel
      | SciGraphMismatch
      | SciControlPlanHasNoStateCommit

    applyPlannedCommit
      :: SessionPlan
      -> SessionCommit
      -> SessionState
      -> Either SessionCommitIssue (SessionState, Maybe ResolveRebuildResult)

The `Maybe ResolveRebuildResult` is `Just` only for graph-install
commits. Voice-start and voice-stop commits return `Nothing`. Control
writes do not have a state commit in the Prep B model.

`applyPlannedCommit` deliberately takes the bare `SessionPlan`, not a
full `SessionAdmissionResult`. The originating `SessionCommand` is
producer-audit metadata; the handshake itself does not need it.

Constructor names may be adjusted during implementation, but these
issue distinctions are normative:

- wrong commit constructor for the plan;
- wrong voice key;
- wrong template name;
- wrong swap label;
- wrong graph;
- state commit supplied for a control-write plan.

Keep `SessionCommitIssue` separate from `SessionIssue`.
`SessionIssue` is command-admission vocabulary. `SessionCommitIssue`
is session-owner/internal handshake vocabulary.

`SciGraphMismatch` intentionally carries no graph payload. Both graphs
are recoverable from the plan and commit if a caller needs detailed
diagnostics, and embedding whole `TemplateGraph` values in routine
error logs would be noisy.

## Matching Rules

### `PlanVoiceStart`

Expected commit:

    CommitVoiceStarted binding

The commit matches when:

- `vbVoiceKey binding == planned VoiceKey`;
- `vbTemplateName binding == planned TemplateName`.

The runtime slot in `VoiceBinding` is intentionally not predicted by
the plan. Prep B leaves slot allocation to the future runtime owner.
Therefore any `vbSlotId` is accepted as long as the voice key and
template match.

On match, call `applySessionCommit` and return `(state', Nothing)`.

On mismatch:

- wrong constructor -> `SciUnexpectedCommit`;
- wrong key -> `SciVoiceKeyMismatch expected actual`;
- wrong template -> `SciTemplateMismatch expected actual`.

### `PlanVoiceStop`

Expected commit:

    CommitVoiceStopped voiceKey

The commit matches when:

- `voiceKey == vbVoiceKey plannedBinding`.

The planned `VoiceBinding` is a snapshot from admission. Prep C should
not require the runtime shell to echo the whole binding back for stop;
the key is enough to remove the voice from `SessionState`.

On match, call `applySessionCommit` and return `(state', Nothing)`.

On mismatch:

- wrong constructor -> `SciUnexpectedCommit`;
- wrong key -> `SciVoiceKeyMismatch expected actual`.

### `PlanControlWrite`

Expected commit:

    none

Prep B intentionally has no `CommitControlWritten`: symbolic control
writes have no state to mutate at this layer. A future runtime shell
can report acknowledgements directly from the plan or a later execution
result vocabulary.

Well-behaved runtime shells should not call `applyPlannedCommit` for
`PlanControlWrite` at all. `SciControlPlanHasNoStateCommit` exists to
catch buggy shells, not to model a normal path.

If `applyPlannedCommit` receives any `SessionCommit` for
`PlanControlWrite`, return `SciControlPlanHasNoStateCommit` (or the
final equivalent name) and leave state unchanged.

### `PlanHotSwap`

Expected commit:

    CommitGraphInstalled label graph

The commit matches when:

- the commit label matches the planned `SwapLabel`;
- the commit graph equals the planned `TemplateGraph`.

The graph-equality check is structural. The runtime shell is expected
to install the exact `TemplateGraph` value it received in the plan;
reconstructed-equivalent graphs, such as graphs decoded again from a
manifest, will fail this check by design.

On match, call `commitGraphInstalled` and return
`(state', Just rebuildResult)`. The returned `ResolveRebuildResult` is
the authoritative commit-time result. It may differ from the preview
stored in `PlanHotSwap` if voices changed between admission and commit.

The preview `ResolveRebuildResult` embedded in `PlanHotSwap` is not
consulted for mutation. The returned `Just ResolveRebuildResult` is
the freshly recomputed authoritative result from
`commitGraphInstalled`.

On mismatch:

- wrong constructor -> `SciUnexpectedCommit`;
- wrong label -> `SciSwapLabelMismatch expected actual`;
- wrong graph -> `SciGraphMismatch`.

## State And Ordering Model

Prep C keeps the same ordering model as Prep B:

- commands are admitted against one `SessionState`;
- runtime work is attempted outside this module;
- successful runtime facts are committed back into the state;
- no concurrency primitive lands in this slice.

If two producers race, the eventual session owner must serialize them
before admission and commit. Prep C does not solve concurrency. It
only makes one admitted plan and one returned commit agree before state
mutation.

Prep C does not re-admit. If `SessionState` changed between admission
and commit, such as another voice with the same key starting or the
graph being replaced, the handshake will still accept a matching
commit and delegate to the Prep B commit primitive. Per-commit
re-admission is a later slice if real call patterns need it; for v1,
serialization upstream is the assumed remedy.

Because `SessionState` stores voices in `Map VoiceKey VoiceBinding`,
graph-install rebuild diagnostics remain deterministic in `VoiceKey`
order, not start order.

## Non-Goals

Session Prep C must not add:

- `RTGraph` ownership;
- runtime voice allocation;
- FFI calls;
- a C++ session object;
- a realtime queue;
- graph installation;
- live OSC/MIDI/pattern producer arbitration;
- manifest import/reload;
- control-value persistence;
- a `CommitControlWritten` constructor;
- runtime failure events.

Runtime failure continues to be modeled by absence of a matching commit.
A later runtime-owner slice can add a separate execution-result
vocabulary if the caller needs structured failure reporting.

## Implementation Series

Recommended commit shape:

1. **Decision note.** Land this note.
2. **Commit issue vocabulary.** Add `SessionCommitIssue` to
   `MetaSonic.Session.State`. Keep it distinct from `SessionIssue`.
3. **Checked helper.** Add `applyPlannedCommit` with the shape:

       applyPlannedCommit
         :: SessionPlan
         -> SessionCommit
         -> SessionState
         -> Either SessionCommitIssue (SessionState, Maybe ResolveRebuildResult)

   Delegate to `applySessionCommit` and `commitGraphInstalled` only
   after matching succeeds.
4. **Handshake tests.** Pin:
   - voice-start plan accepts matching `CommitVoiceStarted`;
   - voice-start rejects wrong key and wrong template without mutation;
   - voice-stop plan accepts matching `CommitVoiceStopped`;
   - voice-stop rejects wrong key without mutation;
   - control-write plan rejects all state commits;
   - hot-swap plan accepts matching graph install and returns the
     authoritative commit-time `ResolveRebuildResult`;
   - hot-swap rejects wrong label and wrong graph without mutation;
   - stale `PlanHotSwap` preview is not reused;
   - at least one wrong-constructor case per plan type so
     `SciUnexpectedCommit` is structurally exercised.
5. **Roadmap sync.** Add Session Prep C under the
   Session-Layer Scoping Gate while keeping runtime session
   implementation explicitly gated.

## Verification

Minimum verification after implementation:

    just stack-test
    stack exec -- metasonic-bridge --snapshot-check
    stack exec -- metasonic-bridge --authoring-manifest named-control

No C++ verification is required unless the implementation touches C++
sources, headers, package C++ source lists, or the FFI surface.

## Next Slice After Prep C

After Prep C, the next useful design step is a runtime-owner scoping
note, not immediate queue or audio-thread work. That note should define
the shape of a single-threaded session shell that:

- receives `SessionCommand`;
- calls `admitSessionCommand`;
- executes the admitted plan through a narrow runtime adapter;
- feeds successful facts through `applyPlannedCommit`;
- emits producer-facing diagnostics without claiming uninterrupted
  hot-swap behavior.

Only after that scoping pass should the project start implementing a
real session owner.
