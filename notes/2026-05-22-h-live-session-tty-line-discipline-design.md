# Phase 8j - Live Session TTY Line Discipline

Date: 2026-05-22

Status: open. This note opens the lane from the 8i/8j live-session
operator evidence. No implementation choice is selected yet.

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

## Candidate Shapes To Decide

This note deliberately does not pick the implementation in advance.
The implementation design should choose one of these shapes, or explain
why another shape is smaller and safer.

### Output Serialization

Serialize all operator-facing writes from the live-session shell
through one output path. Async hooks would enqueue or call through an
output abstraction instead of printing directly.

Questions:

- Does serialization alone solve command corruption, or only make
  output ordering deterministic?
- Can it be done without blocking ingress threads on slow terminal I/O?
- Does it need a prompt redraw after async output?

### Prompt Redraw Boundary

Keep the current input model but redraw the prompt/current buffer
after async output. This is the classic terminal behavior needed when
background output appears during line editing.

Questions:

- Is there enough state today to know the current edit buffer?
- If the input path is still `getLine`, can this be made correct, or
  does it require a real line editor?

### Line-Editor Boundary

Replace raw `getLine` behavior for the live-session shell with a small
line editor / readline-style boundary that owns prompt, current buffer,
history, and redraw.

Questions:

- Is adding a dependency justified for this operator shell?
- Can tests cover the behavior without requiring a real terminal?
- Does this also close the existing command-history watch item, or
  should history remain a separate follow-up?

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

## Open Questions Before Code

- Which boundary should own operator output: a global shell output
  lock, a queue drained by the command loop, or a terminal/line-editor
  abstraction?
- Is it acceptable for ingress hooks to block briefly while writing
  operator output, or must all async output become fire-and-forget?
- Can prompt redraw be correct with `getLine`, or is that a false
  economy?
- Should command history land in the same slice if a line editor is
  chosen, or stay as a follow-up to keep the first fix focused on
  corruption?
- What is the smallest deterministic test harness that proves command
  payloads are not corrupted by async output?
