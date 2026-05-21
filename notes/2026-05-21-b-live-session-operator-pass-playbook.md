# Live-session operator pass playbook (2026-05-21)

Status: playbook. Not a design decision; not gated on landing
anything. The point is to take the supervised live session as it
exists today, drive it from the operator side, and let real friction
pick the next code lane instead of speculation.

## Why this pass

The supervisor arc has had four consecutive non-speculative closeouts
in the last week: compact-cause renderer (`13f3a8e`), reject-path
tier-2 wrapper (`9b39fd2`), supervisor lifecycle events
(`d86a2df` + `ffaca33` + `6b8c08c`), and the
`RejectedRecovered` / `Escalated` pressure lane closed by spike
([2026-05-21-a-reject-path-operator-pressure-pass.md](2026-05-21-a-reject-path-operator-pressure-pass.md)).
Pushing more infrastructure now risks becoming circular evidence: we
build a thing because we built the last thing. The way out is to use
the live session as if it were an instrument, then design from what
hurts.

The four lanes any finding could redirect into are listed in the
"Consolidating findings" section. None of them is pre-committed; the
notepad output of this pass is the data.

## Prep

1. **Confirm build is current.** `just stack-build`. A no-op after
   `just check-offline` passed.

2. **Optionally run the marker wrappers first.** These are live /
   device smokes, not offline CI, but they quickly separate "my
   audio / port setup is broken" from "the manual transcript is
   teaching us something":

   ```sh
   just manifest-live-session-require-preserving-smoke
   just manifest-live-session-require-preserving-reject-smoke
   ```

   If a port is already busy, pass `port=N`.

3. **Use the repo-local OSC sender** for ad-hoc control writes from
   the second terminal:

   ```sh
   python3 tools/send_osc.py --host 127.0.0.1 \
     --port 17004 --address /v0/lpf/0 --value 0.75
   ```

   The `just osc-send` recipe is the same helper wrapped in a
   recipe. `oscsend` from `liblo-tools` is also fine if it is
   already installed, but the playbook should not require it.

4. **Pick an audio output you can actually hear.** The fixtures play
   a held drone; a silent default device makes the audible part of
   the pass useless. The session uses whatever PortAudio's default
   device is.

5. **Capture a transcript.** The commands below use `script(1)` so
   stdout and stderr are preserved while the session stays
   interactive. If `script` is unavailable, run the inner
   `stack exec -- ...` command directly and take notes manually.

6. **Open a scratch notepad** (`/tmp/session-notes.md` is fine).
   The point of the pass is to capture friction; unrecorded friction
   does not exist.

7. **Two terminals side by side.** One drives the session stdin and
   reads its output; the other sends OSC writes.

## Session 1 — happy require-preserving path

The wrappers already verify this path's markers. The point here is
not verification; it is feeling what the operator surface is like
with audio actually playing.

1. **Start the session.**

   ```sh
   script -q -f -c 'stack exec -- metasonic-bridge \
     --session-osc-port 17004 \
     --manifest-live-session examples/manifests/preserve-cutoff.json \
     preserve-cutoff-dark \
     --strategy require-preserving' \
     /tmp/metasonic-live-session-happy.log
   ```

   A dark drone should start playing. The terminal prints an
   `initial fan-in:` block, then `ingress: open ... oscPort=17004`,
   then the stdin prompt:

   ```
   Type a command, or <Enter> for status, or <Ctrl-D> to exit:
   ```

2. **Press `<Enter>` once.** Read the status snapshot. Note whether
   the layout reads well at a glance or has to be studied.

3. **Pre-reload OSC write from the second terminal.**

   ```sh
   python3 tools/send_osc.py --host 127.0.0.1 \
     --port 17004 --address /v0/lpf/0 --value 0.75
   ```

   The session terminal should print an `osc accept:` line. Listen
   — the cutoff should have moved. Try `0.15` and `0.95` if you want
   to sweep it.

4. **Trigger the reload.** In the session terminal, type:

   ```
   demo:preserve-cutoff-bright
   ```

   followed by `<Enter>`. You should hear the timbre change with no
   audible glitch. Watch the printed block:

   - `supervised outcome: committed`
   - `reload events: ...`
   - `supervisor events: ...`
   - `resource timeline: ...`

   What to record:

   - Did `reload events:` explain the preserving-domain story while
     `supervisor events:` explained the supervisor stack story, or
     did they feel like duplicate noise?
   - Did the block read in 2–3 seconds, or did it require study?
   - Was the audible transition aligned with the printed events, or
     did they feel out of sync?

5. **Press `<Enter>` for a status snapshot.** Confirm
   `current plan demo:` flipped to `preserve-cutoff-bright`.

6. **OSC write on the new plan.**

   ```sh
   python3 tools/send_osc.py --host 127.0.0.1 \
     --port 17004 --address /v0/lpf/0 --value 0.25
   ```

   Should accept and you should hear the cutoff close. This is the
   "OSC survives the reload" invariant — interesting only if it does
   not work.

7. **Exit with `<Ctrl-D>`.** Should be clean — no hang, no zombie
   audio device.

## Session 2 — reject-preserving-smooth path

Same shape, but the reload is supposed to be rejected by design
(`KSmooth` on the gain path makes the active voice preserve-
unsupported). The interesting part is the operator narrative around
the rejection.

1. **Start.**

   ```sh
   script -q -f -c 'stack exec -- metasonic-bridge \
     --session-osc-port 17005 \
     --manifest-live-session examples/manifests/reject-preserving-smooth.json \
     reject-preserving-smooth-dark \
     --strategy require-preserving' \
     /tmp/metasonic-live-session-reject.log
   ```

2. **Pre-reload OSC, to confirm it's bound.**

   ```sh
   python3 tools/send_osc.py --host 127.0.0.1 \
     --port 17005 --address /v0/lpf/0 --value 0.75
   ```

3. **Attempt the reload that gets rejected.**

   ```
   demo:reject-preserving-smooth-bright
   ```

   Audio should *not* change. The terminal should print:

   - `supervised outcome: request-rejected (stack still on previous plan)`
   - `supervisor events:` ending in
     `in-window: rejected-live-fallback`
   - a compact `cause: in-window: reload-rejected (old owner still installed)`
   - a resource timeline ending in
     `serving plan: reject-preserving-smooth-dark`

   What to record:

   - Does the cause line actually tell you *what to do*? If you
     didn't already know what "preserve-unsupported" meant, would
     you know this is a KSmooth-on-gain-path problem?
   - Is the distinction between `request-rejected` and a future
     `rejected-recovered` clear from the outcome line alone, or only
     from the resource timeline?

4. **Press `<Enter>` for status.** Confirm the plan is still `-dark`
   and OSC is still bound.

5. **OSC after the reject.**

   ```sh
   python3 tools/send_osc.py --host 127.0.0.1 \
     --port 17005 --address /v0/lpf/0 --value 0.25
   ```

   Should accept; you should hear the cutoff move on the *old*
   drone. Confirms the live stack survived the reject.

6. **Exit with `<Ctrl-D>`.**

## Session 3 — bad-key / rejected command probes

Do not start a third session; fold these into one of the two above.

1. **Typo'd demo key.**

   ```
   demo:nonexistent
   ```

   Expected: session prints something about an unresolved key, audio
   keeps playing, session does *not* exit. This is the
   `LscReloadTo "nonexistent"` → `LsoPlanRejected` path.

2. **Malformed line.**

   ```
   hello world
   ```

   Expected: also non-fatal, hits `LscUnknown`.

3. **Empty whitespace.** A few spaces and `<Enter>` should fall
   through to the status snapshot path.

What to record:

- Does the typo response tell you what *would* have been valid?
- Is the distinction between "unknown command" and "unknown demo
  key" clear?
- Does the session make it obvious that a command-level reject did
  not invoke the supervisor at all?

## Consolidating findings

In the scratch notepad, sort each finding into one of four buckets:

- **Interaction friction.** Stdin awkward; status snapshot hard to
  read; no command history; can't see what demos exist; can't
  introspect controls live. → points at GUI / control binding.
- **Strategy gaps.** "I wanted to try try-preserving and there's no
  wrapper"; "the strategy flag default isn't obvious"; "I want to
  switch strategy without restarting the session." → points at
  try-preserving / stopped-audio live-session wrappers, or at a
  mid-session `strategy:NAME` stdin command.
- **Diagnosis thinness.** `supervisor events:` too coarse; the
  compact cause line is not actionable; can't tell which stage
  failed; the resource timeline does not name the right resource.
  → points at finer allocation / resource event rendering, or at
  enriching the cause line with the inner runtime reason.
- **Nothing hurt.** Operator surface was fine; the friction was
  wanting to make music rather than diagnose plumbing. → points at
  musical patch / authoring lanes (Phase 8 authoring DSL beyond
  v0), not runtime plumbing.

The honest output of the pass may be more than one bucket with
weak signal each, or none of them with strength. Don't pre-commit
to a lane.

## Next-step rubric

If a finding is sharp enough to act on, the next move is a *design
note*, not a code slice — same shape as
[2026-05-20-d-stale-command-rejection-rendering.md](2026-05-20-d-stale-command-rejection-rendering.md):
name the friction, name the proposed fix, name what is deliberately
out of scope. Code follows once the design note exists.

If no finding is sharp enough, the right output is a one-paragraph
update to this note's "Findings" section (added below when the pass
runs) recording what the session felt like, and a continued pause
until a real operator-side signal materializes. "Nothing hurt" is a
valid result and is the discipline working.

Before appending findings, skim the saved transcripts:

```sh
less /tmp/metasonic-live-session-happy.log
less /tmp/metasonic-live-session-reject.log
```

Copy only the lines that matter. The note should preserve the
operator evidence, not the whole terminal dump.

## Findings

(Empty until the pass runs. Append a dated subsection per pass,
ordered chronologically. Keep the playbook part of the note stable
so future passes can re-use it.)
