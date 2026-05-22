# Phase 8e — Scripted Operator Evidence Harness

Date: 2026-05-22

Status: design note. Implementation slice opens against this note.
No code lands on the strength of this note alone.

Companion to
[2026-05-21-b-live-session-operator-pass-playbook.md](2026-05-21-b-live-session-operator-pass-playbook.md)
(`## Evidence To Code` rubric at `0a0c98d`).


## Why This Slice — Honest Framing

This is **thin** Evidence To Code, not the strong shape. The rubric
specifies "the same observation surfaces across two or more
*independent* passes." That isn't quite what surfaced here.

What actually surfaced: two-terminal choreography has been a
recurring hidden cost across the operator-pass series on this branch
— saw, noise, OSC-renderer-validation, smooth-cutoff. Every pass
required sequencing session-stdin commands against OSC-sender
invocations against transcript capture against audio monitoring, all
under the operator's manual coordination. The cost was implicit
until session 1 of the smooth-cutoff pass missed the reload between
its two OSC sweeps; that miss made the choreography overhead
concrete enough to name.

The slice is justified on:

- Real friction did surface, even if the rubric's exact "two
  independent passes" shape isn't met.
- The friction is reproducible across passes (manifest in *every*
  prior operator session, just below the threshold of getting
  recorded as friction).
- The scope is small and reversible.

It is **not** justified on the same grounds as 8d-a (roadmap-completeness
exception with no competing lane). Treating this as a calibrated
exception of the same shape would inflate the evidence and erode the
rubric. Naming the framing as thin here keeps the discipline honest
for future-you.


## What This Slice Is, And Is Not

The runner is **transcript scaffolding**, not pass validation.

| Is | Is not |
|----|--------|
| Removes hand choreography (stdin sequencing, OSC sends at marker-synchronized points, transcript capture) | A proof the musical pass succeeded |
| Produces a complete `/tmp/...log` transcript without operator timing errors | A replacement for the audio-paired operator |
| Reports which expected markers were seen and which were missing | A brittle hard-gate that fails CI when a renderer evolves |
| Single fixture (smooth-cutoff complete pass) baked in | A generalized scenario framework |

The operator still listens to the audio and judges:

- Does the cutoff actually glissando through the reload boundary, or
  snap?
- Does anything stutter, click, or drop out?
- Does the post-reload OSC sweep sound continuous with the
  pre-reload sweep?

The runner cannot answer any of those questions. It can only ensure
the *text* events happened in the right order so the operator's
ears can concentrate on the audio rather than on getting the
sequencing right.


## Scope

### Implementation

One script: `tools/run_live_session_pass.py`.

- Launches `stack exec -- metasonic-bridge --session-osc-port 17004
  --manifest-live-session examples/manifests/preserve-smooth-cutoff.json
  preserve-smooth-cutoff-dark --strategy require-preserving` under
  PTY/subprocess control so stdin sequencing is reliable and the
  full output stream is captured.
- Drives the session stdin in the smooth-cutoff complete-pass order:
  1. `demos`
  2. `controls` (pre-reload)
  3. pre-reload OSC sweep
  4. `demo preserve-smooth-cutoff-bright`
  5. `controls` (post-reload)
  6. post-reload OSC sweep
  7. out-of-range probe
  8. `status`
  9. `quit`
- Sends OSC writes by invoking the existing `tools/send_osc.py`
  behavior (or its underlying helper if cleaner). No new OSC plumbing.
- Writes one transcript under `/tmp/metasonic-live-session-scripted-smooth-cutoff.log`.
- Prints a soft marker summary at the end: which expected markers
  were seen, which were missing.

### Markers to look for (soft check, not hard gate)

- Initial OSC surface line: `/v0/cutoff/1  (name="cutoff", ...)`.
- Reload committed event chain: `supervised outcome: committed`
  with the `preserving phase committed` and `in-window: committed`
  sub-events.
- Post-reload `controls` shows the new fixture's defaults.
- Post-reload OSC accepts render with `name="cutoff"`.
- Out-of-range reject: `osc reject (out-of-range): tag=cutoff/1 ...`.
- Clean session shutdown: `Terminating session.` line followed by
  child-process exit code 0. The `Script done` footer applies only
  if the runner uses `script(1)` to wrap the session; under direct
  PTY/subprocess control the equivalent marker is the child's exit
  status plus a runner-emitted transcript footer.

Missing markers are reported to stderr but do **not** fail the
runner — exit 0 in this slice for soft-marker gaps. Hard-gate exit
codes on missing markers are a follow-up only if the soft summary
repeatedly catches the same gap and warrants codification.

**Infrastructure failures are always exit nonzero**, regardless of
the soft-marker policy. The runner exits nonzero if `stack exec`
fails to launch, the OSC sender fails, prompt detection times out
on a marker the implementation considers load-bearing for
sequencing, the child exits nonzero on its own, or any other
harness-level failure prevents the pass from running at all. The
soft-marker discipline applies only to *content* assertions on a
session that otherwise completed cleanly; it must not mask real
harness failures.

### Discipline

- **Synchronous prompt detection is the default.** Every OSC write
  or session command waits on a known marker (prompt line, accept
  line, supervisor outcome line) before proceeding. Sleeps require
  a *local justification comment* naming the specific external
  event being waited for and why no marker is available.
- **Single fixture first.** smooth-cutoff is the only baked target.
  Do not parameterize for other fixtures until a second fixture
  asks for the same scaffolding. The cost of generalization later
  is small; the cost of premature abstraction is silent drift.


## Out Of Scope

- **No KDelay / KEnv runtime work.** Substrate phases stay
  independent. The deferral named in the 8d-b closeout discussion
  holds.
- **No live audio capture.** The runner does not record or analyze
  audio. The operator's ears remain the perceptual authority.
- **No CI integration.** This is a development-time operator tool,
  not a test framework. Adding it to CI would conflict with the
  audio-paired-by-a-human contract above.
- **No broad pass framework.** No YAML scenarios, no scripted
  test-case DSL, no shared base class for multiple fixtures.
- **No current-value introspection.** Still a candidate lane on the
  watch list, still not opened.
- **No hard marker assertions in 8e.** Marker summary is soft;
  promote to hard gates only after manual+scripted runs show the
  soft summary catches real drift and not just noise.


## Open Questions To Resolve Before Code

- **PTY library choice.** Standard options: `pexpect` (most
  ergonomic for prompt-driven flows but adds a Python dependency),
  raw `pty` + `os` (no dependency but more code), `subprocess.Popen`
  with manual select-based reading (no dependency, robust for
  line-buffered flows). The slice should pick one and justify it in
  the script's header; my preference is whichever avoids new
  dependencies if the prompt-detection complexity stays small.
- **OSC helper reuse.** `tools/send_osc.py` is a CLI; calling it as
  a subprocess is wasteful but cheap, calling its underlying helper
  function requires importing or refactoring. Both are fine; the
  slice should pick whichever is less invasive.
- **Marker matching precision.** Should the runner match the exact
  format string of each accept/reject line, or a substring/regex?
  Exact match is brittle (the 8b OSC-renderer slice rewrote accept
  lines); substring/regex on the salient tokens (e.g. `osc accept:`
  + `name="cutoff"` + the value) is more resilient. Pick
  substring/regex by default.
- **Transcript naming.** Single hardcoded path under `/tmp` is
  fine; adding a timestamp suffix is cheap if multiple runs in one
  shell would otherwise overwrite the last transcript. Worth one
  line of decision in the script.


## Verification

1. Run the script manually with audio paired.
2. Confirm the produced transcript is comparable to a manually-driven
   smooth-cutoff pass: same markers, same order, audio sounds the
   same.
3. The soft marker summary at the end matches the operator's eyeball
   reading of the transcript.

If those three hold on the first run, the slice has done what 8e is
meant to do: removed the choreography overhead without claiming to
have replaced operator judgment.


## Sequencing After 8e

| Slice | Status | Notes |
|-------|--------|-------|
| **8e** (this note) | Open | Scripted scaffolding for smooth-cutoff pass |
| Later: marker hard-gate | Not open | Only if soft summary repeatedly catches real drift |
| Later: second fixture | Not open | Only if a second pass wants the same scaffolding |
| Later: pass framework | Not open | Strong YAGNI; do not pre-generalize |

No KDelay or KEnv arc opens from 8e. The substrate gap remains
deferred; this slice is about tooling, not runtime.
