# Phase 8j - Live Session TTY Line Discipline

Date: 2026-05-22

Status: closed. Implementation landed as `7df0586` using the
line-editor boundary: the live-session command loop now runs under
`haskeline`, operator-facing output routes through an injectable sink
backed by `getExternalPrint`, and the OSC listener accept-line path
uses that sink while the editor session is active. Verification
transcript: `/tmp/metasonic-live-session-8j-tty-after-fix.log`
(2026-05-23). The post-fix replay kept OSC accept lines visible and
eliminated the merged-command failures (`statuvalues`, `statstatus`);
final `status` was healthy and `quit` exited with code 0.

Companion to:

- [2026-05-21-b-live-session-operator-pass-playbook.md](2026-05-21-b-live-session-operator-pass-playbook.md)
  (`## Evidence To Code` rubric and the 8i/8j Findings entries).
- [2026-05-22-g-live-control-value-introspection-design.md](2026-05-22-g-live-control-value-introspection-design.md)
  (8h `values`; the 8i pass confirmed it and surfaced the TTY issue).

## Why This Lane Opens

The live-session shell now has a pinned command-line corruption mode.

Evidence:

| Pass | Transcript | Shape | Result |
|------|------------|-------|--------|
| 8i noise-values pass | `/tmp/metasonic-live-session-8i-noise-values-pass.log` | Normal operator use; OSC accept output landed while a command line was being edited | `unknown command: "svalues"` after a stray prefix survived line editing |
| 8j TTY reproduction pass | `/tmp/metasonic-live-session-8j-tty-reproduction.log` | Deliberately timed OSC accept output during partial command input | `unknown command: "statuvalues"` and `unknown command: "statstatus"` |

This is a calibrated exception, not a claim of repeated independent
organic friction. The 8j pass deliberately provoked the timing window;
that is different from a second organic pass failing by chance. The
lane still opens because the phenomenon is now concrete, narrow, and
mechanically pinned: async operator output can interleave with a
partially typed line, and the stale prefix remains in `getLine`'s
input buffer.

Probe A in 8j is not load-bearing: `val` and `ues` were submitted as
separate commands. That makes it a setup error, not a
non-reproduction of the TTY mechanism. Probes B and C are
load-bearing because the transcript shows partial command prefixes
combining with later submitted commands after OSC accept lines were
printed.

## Problem Statement

The live-session shell has two concurrent operator-facing streams:

- synchronous stdin command input handled by the session loop
- asynchronous event output from ingress hooks, especially OSC accept
  lines

Today those streams share the terminal without a line-discipline
boundary. While an operator is editing a command, an async accept line
can print in the middle of that edit. The visual output is confusing,
but the worse failure is semantic: a partially typed prefix can remain
in the line buffer and combine with the next submitted command.

Observed failures:

```text
unknown command: "svalues"
unknown command: "statuvalues"
unknown command: "statstatus"
```

The session recovers after the bad line, so this is not a runtime
stability issue. It is an operator-shell correctness issue.

## Goal

Make live-session interactive input and asynchronous operator output
coexist without corrupting submitted commands.

The first implementation should protect the text shell contract:

- async OSC/event output must not merge with an in-progress command
  line
- submitted command text must be exactly what the operator intended
  to submit
- prompts should remain understandable after async output
- the shell must still recover cleanly from unknown commands

## Non-Goals

- No DSP, reload, preserving-state, or runtime FFI changes.
- No changes to OSC accept/reject semantics.
- No `values` behavior change.
- No ALSA / PortAudio stderr suppression.
- No same-demo reload wording change.
- No GUI shell.
- No MIDI/UI value-cache wiring.

## Input Model Constraint

Before naming candidates, the structural property of the current input
path needs pinning: `sessionLoop` reads stdin with plain `getLine` on
a default (canonical-mode) TTY. In canonical mode the *kernel's* line
discipline owns the edit buffer — echo, backspace, kill-line, line
delivery on Enter — and userspace only receives the line when the
operator presses Enter.

Two consequences load-bear on the candidate set below:

1. **Userspace cannot read the typed-but-not-submitted text.** It
   lives in the kernel buffer, invisible to `getLine` until newline.
2. **Userspace cannot redraw it.** Redraw means rewriting the edit
   text after async output overwrites it visually; we do not have
   the text to rewrite.

Therefore any candidate that requires keeping `getLine` *and*
redrawing on top of async output is structurally not implementable
without leaving canonical mode and owning echo in userspace.

## Candidate Shapes To Decide

The constraint above narrows the choice to two real options. A naïve
"redraw the prompt after async output" is not an independent third
option on the current input model — see the Line-Editor section.

The implementation picked the line-editor boundary. The deferred-output
serialization option below remains as historical context for the
decision that was available before code landed.

### Small Safety Fix: Output Serialization With Deferred Async

Smallest change that fixes command corruption. Take a stdout lock so
every operator-facing write is atomic, and **defer** async output
(OSC accept lines, anything from ingress hooks) until the operator
submits a line. The kernel edit buffer is never disturbed mid-edit
because nothing prints while typing; on Enter, the submitted command
and any queued async lines flush together.

Cost: OSC accept lines become invisible during typing. The operator
loses the real-time "I see the sweep landing as I type" feedback that
the 8h pass made enjoyable. Worth it iff command correctness matters
more than live OSC visibility for this surface.

Closes the command-corruption failure modes:

- `unknown command: "statuvalues"` (Probe B): writes deferred during
  typing, so kernel buffer is not disturbed.
- `unknown command: "statstatus"` (Probe C): same.

Does not close the existing command-history watch item.

Questions:

- Can deferral be done without blocking ingress threads on the
  command-loop's read? (A bounded queue with a non-blocking writer
  is the obvious shape.)
- How visible is the lag between an accepted OSC packet and its
  printed accept line during a slow operator edit?

### Proper Operator Shell: Line-Editor Boundary

Replace canonical-mode `getLine` with a userspace line editor that
owns prompt, current buffer, history, redraw, and the input read.
Async output prints, then the prompt + current edit buffer is
redrawn beneath it; the operator never sees their typed text get
visually clobbered, and the kernel never delivers a corrupted
submitted line because the kernel is no longer driving echo.

The classic readline-style redraw behavior that an earlier draft of
this note framed as a third candidate belongs *inside* this option,
not as a standalone candidate — the canonical-mode constraint above
makes "prompt redraw without leaving canonical mode" structurally
unimplementable.

Dependency cost (inspected 2026-05-22): `haskeline-0.8.2.1` is
bundled with GHC as a boot library
(`ghc-9.10.3/lib/package.conf.d`), and its transitive `terminfo`
dependency is already present in the project's dependency tree.
Adopting `haskeline` adds zero external dependencies to the snapshot
— declaring it in `package.yaml` resolves to the GHC-bundled
version.

Closes the command-corruption failure modes and also closes the
existing command-history watch item as a side effect.

Questions:

- Does `haskeline`'s `MonadException` / `InputT IO` API integrate
  cleanly with the existing `sessionLoop` shape (IORef-threaded,
  `mask` / `finally` around the supervisor bracket), or does it
  force restructuring beyond this slice?
- Can tests cover prompt + buffer state without requiring a real
  terminal? `haskeline`'s `runInputTBehavior useFile` /
  `useFileHandle` mode provides an in-process, no-TTY input path
  that is the standard test seam.
- Should command history land in the same slice, or be split out
  to keep the first slice focused on corruption? (Line editing is
  cheap once `haskeline` is wired; persistent history-file behavior is
  a separate operator-contract choice.)

### Lean

The user-facing live session is becoming a real operator surface, not
just an internal smoke. Dependency / risk inspection found the
`haskeline` cost is essentially nil (GHC boot library, transitive dep
already present). The leaning recommendation, pending the
implementation note's confirmation, is the **line-editor boundary**:
it solves command corruption without the deferred-output operator
regression and gives the shell real line-editor behavior. Persistent
cross-session command history remains outside the closed slice unless a
later operator pass makes it worth opening separately.

Implementation `7df0586` made this recommendation binding for the
closed slice. It deliberately used an in-memory `haskeline` session
(`historyFile = Nothing`); persistent cross-session history is not
claimed by this closeout and can be treated as a separate polish
follow-up if it becomes useful.

## Source Seams To Inspect

| Topic | File | Symbol |
|-------|------|--------|
| Live session loop and command dispatch | [ManifestLiveSession.hs](../app/MetaSonic/App/ManifestLiveSession.hs) | `sessionLoop` |
| Prompt/help rendering | [ManifestLiveSession.hs](../app/MetaSonic/App/ManifestLiveSession.hs) | `renderLiveSessionCommandHelp` / prompt text |
| OSC accept-line hooks | [ManifestLiveCommon.hs](../app/MetaSonic/App/ManifestLiveCommon.hs) | `liveOSCListenerHooksForObserved` |
| OSC listener hook contract | [ManifestOSCListener.hs](../app/MetaSonic/App/ManifestOSCListener.hs) | `ManifestOSCListenerHooks` |
| Scripted session runner | [run_live_session_pass.py](../tools/run_live_session_pass.py) | prompt detection discipline |

## Acceptance Criteria

Deterministic tests should cover the chosen abstraction before the
next live pass. The exact test shape depends on the chosen design, but
the assertions should pin:

- async output cannot change the submitted command payload
- async output remains visible to the operator
- prompt/help text remains coherent after async output
- unknown-command behavior still works for genuinely unknown commands

Live validation should replay the 8j shape:

```sh
script -q /tmp/metasonic-live-session-8j-tty-after-fix.log -c 'stack exec -- metasonic-bridge --session-osc-port 17004 --manifest-live-session examples/manifests/saw-noise-filter.json noise-filter-soft --strategy require-preserving'
```

Run partial `statu` + OSC burst + intended `values`, and partial
`stat` + OSC burst + intended `status`. Passing live behavior means no
`statuvalues`, `statstatus`, or equivalent merged-command submission,
while OSC accept lines remain visible and final `status` is healthy.

Closed verification (2026-05-23):

- Transcript: `/tmp/metasonic-live-session-8j-tty-after-fix.log`.
- Implementation: `7df0586`.
- Deterministic focused test before live replay:
  `stack test --fast --test-arguments "-p output --hide-successes"`
  passed (`22/22`).
- Probe B replay: async OSC accept lines landed while `statu` was in
  the edit buffer; the operator then submitted `values`. The transcript
  contains no `statuvalues`, and `values` executed normally with
  accepted values `cutoff=2200`, `q=0.8`, `level=5e-2`.
- Probe C replay: async OSC accept lines landed while `stat` was in
  the edit buffer; the operator then submitted `status`. The transcript
  contains no `statstatus`, and `status` reported audio running,
  queue depth 0, owner ready, reload normal, and one active voice.
- `quit` exited cleanly with `COMMAND_EXIT_CODE="0"`.
- One non-load-bearing setup artifact remained:
  `unknown command: "statu"` appeared before the timed Probe B replay,
  because `statu` was submitted on its own once. This mirrors the
  earlier Probe A setup-error framing and does not affect the
  load-bearing OSC-interleaved probes.

## Open Questions Before Code

Closeout answer: the slice chose the line-editor option. `haskeline`
integrated cleanly with the existing IORef-threaded loop by placing
one `runInputT` bracket around the whole `sessionLoop`, using an
IORef-backed dynamic sink for listener hooks created before the
`InputT` scope, and restoring the sink with `finally` before host-stack
teardown. Async operator output is not deferred; it remains visible via
`getExternalPrint`. Persistent history was intentionally not enabled in
this slice.

The questions below are scoped to whichever candidate the
implementation note picks; "Can prompt redraw be correct with
`getLine`?" is no longer one of them — see the Input Model Constraint
above.

- For the line-editor option: how cleanly does `haskeline`'s
  `InputT IO` integrate with `sessionLoop`'s existing IORef +
  `mask` / `finally` shape, and is the right wiring point a
  `runInputT` wrapper around the whole loop or per-iteration?
- For the deferred-output option: bounded queue size, and behavior
  on overflow during a long edit (drop, drop+counter, block
  briefly)?
- Is it acceptable for ingress hooks to block briefly while writing
  operator output, or must all async output become fire-and-forget?
- Should command history land in the same slice if a line editor is
  chosen, or stay as a follow-up to keep the first fix focused on
  corruption?
- What is the smallest deterministic test harness that proves command
  payloads are not corrupted by async output? `haskeline`'s file-
  backed input behavior is the obvious seam for the line-editor
  option; the deferred-output option can be tested with the existing
  in-language fake-hook patterns.
