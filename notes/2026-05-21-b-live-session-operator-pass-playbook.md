# Live-session operator pass playbook (2026-05-21)

Status: playbook. Not a design decision; not gated on landing
anything. The point is to take the supervised live session as it
exists today, drive it from the operator side, and let real friction
pick the next code lane instead of speculation.

Updated 2026-05-22 after the stdin ergonomics arc: `help`,
`status`, `quit` / `exit`, `demo KEY`, `demos`, and `controls` are
now part of the session shell. The next pass should test whether the
remaining friction is deeper than basic command / control-surface
discoverability.

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

## Evidence To Code

This playbook produces evidence, not implementation candidates. The
rubric for promoting evidence into a code lane:

1. **Smoke proves wiring; musical use produces pressure.** The
   `just manifest-live-session-*-smoke` wrappers confirm reload and
   reject paths fire end-to-end. They do not surface the operator
   friction that names the next slice. Musical use — sweeping
   controls, reloading between variants, hitting reject paths,
   exiting cleanly — is what the Findings sections record.

2. **One friction instance is a watch item, not pressure.** A single
   transcript surfacing something operator-hostile gets recorded as a
   watch item in the Findings entry. It does not open a code lane on
   its own.

3. **A code lane opens only after one of:**
   - *Repeated friction* — the same observation surfaces across two
     or more independent passes.
   - *Blocking friction* — a single observation that makes ordinary
     use impossible (audio drop, lost stack, unrecoverable shell).
   - *Calibrated exception* — a single observation, with no competing
     candidate lane, may justify opening one slice. The 2026-05-22 OSC
     accept-line rendering polish (`131e487`) is the working example.
     Exceptions must be named as such in the opening design note so
     future-you doesn't read them as the general rule.

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
     --port 17004 --address /v0/lpf/0 --value 1200
   ```

   OSC values are raw control values in the target parameter's
   units, not normalized 0..1 values. For the preserve-cutoff
   fixtures, `/v0/lpf/0` is an LPF cutoff in Hz with the manifest
   range `[200, 6000]`; useful values are anywhere in that range
   (`1200` and `2400` work well as mnemonics — `1200` sits between
   the dark default `600` and the bright default `2400`).

   You no longer have to memorize that range: the session prints it
   on the addressable-OSC-surface line at startup, e.g.

   ```
   /v0/lpf/0  (name="cutoff", default=600.0, range=[200.0, 6000.0], cc=74)
   ```

   Sending an out-of-range value (e.g. `0.75`) rejects at ingress
   with a single diagnostic and does not reach the runtime:

   ```
   osc reject (out-of-range): tag=lpf/0 value=0.75 range=[200.0, 6000.0]
   ```

   That is intentional — if you want to confirm the rejection is
   wired, send `0.75` deliberately.

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
   the addressable OSC surface (with `range=...` / `default=...` /
   optional `cc=...` per binding), the command
   vocabulary under `commands:`, and then the per-line prompt:

   ```
   Type a command, or <Enter> for status, 'help' for the command list, or <Ctrl-D> to exit:
   ```

   The recognized commands at this prompt are `demo:KEY` /
   `demo KEY` (supervised reload), `demos` (list manifest demo keys),
   `controls` (reprint the current OSC surface), `status` (same as
   `<Enter>`), `help` (or `?`, prints the vocabulary), and `quit`
   (or `exit`, same as `<Ctrl-D>`). Anything else echoes the typed
   line and reprints the same vocabulary.

2. **Exercise the command vocabulary.** In the session terminal, type:

   ```
   help
   demos
   controls
   status
   ```

   Confirm `help` prints the same command vocabulary shown at
   startup, `demos` marks the current demo, `controls` reprints the
   addressable OSC surface, and `status` prints the same kind of
   snapshot as `<Enter>`.

3. **Press `<Enter>` once.** Read the status snapshot. Note whether
   the layout reads well at a glance or has to be studied.

4. **Pre-reload OSC write from the second terminal.**

   ```sh
   python3 tools/send_osc.py --host 127.0.0.1 \
     --port 17004 --address /v0/lpf/0 --value 1200
   ```

   The session terminal should print an `osc accept:` line. Listen
   — the cutoff should have moved. Try `600`, `2400`, and `5000`
   if you want to sweep it without leaving the manifest's Hz range
   (the addressable-surface line from the startup print tells you
   that range). If you want to confirm the rejection path, send
   `0.75` once and look for an `osc reject (out-of-range)` line.

5. **Trigger the reload with the space alias.** In the session terminal,
   type:

   ```
   demo preserve-cutoff-bright
   ```

   The space form is intentionally single-token; `demo foo bar`
   should be rejected rather than silently using only `foo`.

6. **Reload back with the colon form.** In the session terminal, type:

   ```
   demo:preserve-cutoff-dark
   ```

   Both reloads should commit without stopping the drone, but neither
   may create an audible timbre jump by itself. That is expected for
   the preserving route: the active voice is preserved, and the
   runtime migrates the old voice's per-instance control values onto
   the new graph. In this fixture, the target demo's LPF default is
   therefore not forced onto the already-running `v0`; the reload
   proves lifecycle / ingress continuity, not "apply every new default
   to existing voices."

   Watch each printed block:

   - `supervised outcome: committed`
   - `reload events: ...`
   - `supervisor events: ...`
   - `resource timeline: ...`

   What to record:

   - Did `reload events:` explain the preserving-domain story while
     `supervisor events:` explained the supervisor stack story, or
     did they feel like duplicate noise?
   - Did the block read in 2–3 seconds, or did it require study?
   - Did the lack of an audible default jump make the wording or
     operator narrative confusing?
   - Did the commit still read as meaningful once you understood it
     as "audio kept, voice/control state preserved, ingress moved"?

7. **Press `<Enter>` for a status snapshot.**

   Confirm `current plan demo:` reads `preserve-cutoff-dark`. This
   keeps the happy-path pass to two reloads: one space-form reload,
   one colon-form reload.

8. **OSC write on the new plan.** This is the audible confirmation
   for the preserving path.

   ```sh
   python3 tools/send_osc.py --host 127.0.0.1 \
     --port 17004 --address /v0/lpf/0 --value 600
   ```

   Should accept and you should hear the cutoff move on the dark plan.
   `600` matches the dark demo's own default, which is a useful
   mnemonic after reloading back from bright. This is the "OSC survives
   the reload" invariant — interesting only if it does not work.

9. **Exit with `quit`.** Should be clean — no hang, no zombie
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
     --port 17005 --address /v0/lpf/0 --value 1200
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
     --port 17005 --address /v0/lpf/0 --value 2400
   ```

   Should accept; you should hear the cutoff move on the *old*
   drone. Confirms the live stack survived the reject.

6. **Exit with `<Ctrl-D>`.**

## Session 3 — bad-key / rejected command probes

These are stdin-protocol probes, not a third audio scenario. If one
of the earlier sessions is still open, fold in the first few checks
that match your immediate question. If you want a complete parser pass,
run all seven in a short follow-up session; only `exit` needs to come
last because it closes the shell.

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

3. **Malformed space-form reload.**

   ```
   demo foo bar
   ```

   Expected: non-fatal, hits `LscUnknown`. The space form is
   intentionally single-token; it must not silently use `foo` and
   ignore `bar`.

4. **Bare reload word.**

   ```
   demo
   ```

   Expected: non-fatal, hits `LscUnknown`; a reload key is required.

5. **Help alias.**

   ```
   ?
   ```

   Expected: prints the same vocabulary as `help`.

6. **Empty whitespace.** A few spaces and `<Enter>` should fall
   through to the status snapshot path.

7. **Exit alias.** `exit` should close the session cleanly. Run this
   last if you are folding these probes into an active session.

What to record:

- Is the distinction between "unknown command" and "unknown demo
  key" clear?
- For `hello world`, `demo foo bar`, and `demo`, is the full command
  vocabulary helpful, or would a one-line hint be better?
- Does the session make it obvious that a command-level reject did
  not invoke the supervisor at all?
- Do the `?` and `exit` aliases feel discoverable, or are they just
  extra vocabulary to remember?

## Consolidating findings

In the scratch notepad, sort each finding into one of four buckets:

- **Interaction friction.** Basic stdin vocabulary and current
  demo/control-surface discovery are now available through `help`,
  `demos`, and `controls`; remaining friction is more specific:
  status snapshot hard to read, no command history, can't introspect
  current control values live, or can't make repeated changes quickly.
  → points at command-history/readline, current-value reporting, or
  GUI / control binding if the text shell itself becomes the
  bottleneck.
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

### 2026-05-22 — happy require-preserving session

Transcript: `/tmp/metasonic-live-session-happy.log`, captured from:

```sh
script -q -f -c 'stack exec -- metasonic-bridge \
  --session-osc-port 17004 \
  --manifest-live-session examples/manifests/preserve-cutoff.json \
  preserve-cutoff-dark \
  --strategy require-preserving' \
  /tmp/metasonic-live-session-happy.log
```

Objective result:

- Session opened on `preserve-cutoff-dark` with `audio running: yes`,
  `active voices: 1`, OSC port `17004`, and addressable control
  `/v0/lpf/0  (name="cutoff", default=600.0, range=[200.0, 6000.0], cc=74)`.
- `status` and `help` rendered the expected operator surfaces.
- `demo preserve-cutoff-bright` committed and reported
  `serving plan: preserve-cutoff-bright`.
- `demo:preserve-cutoff-dark` committed and reported
  `serving plan: preserve-cutoff-dark`.
- Post-reload OSC writes to `/v0/lpf/0` with values `600.0`,
  `1600.0`, and `300.0` were accepted, and the audible cutoff changed
  without a glitch.
- Final status reported `current plan demo: preserve-cutoff-dark`,
  `last outcome: committed (new plan installed)`, and one active
  voice.
- `quit` terminated cleanly with command exit code `0`.

Observed friction:

- ALSA / PortAudio device-enumeration stderr is noisy enough to bury
  the useful startup lines in transcripts, even though the run itself
  succeeds. This is an operator-readability issue, not a correctness
  failure in this pass.
- Arrow-up history is not available in the raw stdin shell; escape
  bytes are treated as an unknown command. This confirms "no command
  history" as real shell friction, but it is not yet stronger than the
  demo / control discoverability gap this pass produced.
- The sharpest self-discovery gap was that the operator could read
  the startup vocabulary but could not ask the shell which demos are
  reload targets or reprint the current control surface after
  scrollback had moved.

Immediate follow-up chosen from this pass and landed into the shell:
add App-level `demos` and `controls` commands. Keep later slices
narrow: do not mix current-value introspection, GUI bindings,
readline-style history, or ALSA stderr suppression into the same
change without a fresh operator pass.

### 2026-05-22 — `demos` / `controls` validation pass

Transcript: `/tmp/metasonic-live-session-discovery.log`, captured
against `bdad6e6` on the same require-preserving route as above. The
operator exercised `status`, `demos`, `controls`, `demo preserve-cutoff-bright`
(space form), `controls`, `demo:preserve-cutoff-dark` (colon form),
`controls`, `help`, `quit`.

Against the questions raised when the slice was chosen:

- `demos` made the reload targets obvious enough. Two-line output with
  `*` on the current key, no typo round-trip needed.
- `controls` was useful after scrollback moved. Reprinting both the
  pattern and addressable surface — and showing the new
  `default=2400.0` after committing `preserve-cutoff-bright` — was the
  clearest confirmation that the live plan, not the manifest's first
  entry, drives the display.
- Output volume felt about right. Two-line `demos`, three-line
  `controls`, no need to trim further on this pass.
- ALSA stderr noise is still present at startup but did not interfere
  with the operator commands once the prompt appeared. Arrow-key
  history was not exercised in this pass; the discoverability gap it
  was deferred against has now been closed by `demos` / `controls`, so
  the next lane on it should be a fresh operator pass, not this one.
- Wanting current control values (live `cutoff` reading, not just the
  declared surface) did not come up in this pass. It remains a real
  candidate for the next slice, but only if it surfaces again under
  operator pressure.

No new friction surfaced. Per the playbook rubric, no follow-up work
is opened on the strength of this pass alone.

### 2026-05-22 — Phase 8b saw/noise repertoire pass

Transcripts:

- `/tmp/metasonic-live-session-repertoire-saw.log`
- `/tmp/metasonic-live-session-repertoire-noise.log`

Both were captured against
`examples/manifests/saw-noise-filter.json` with
`--strategy require-preserving`.

Objective result:

- `saw-filter-dark` opened with four controls: pitch, cutoff, q, and
  level. `demos` listed all four repertoire entries and marked
  `saw-filter-dark` as current.
- `controls` printed both the pattern surface and the addressable
  `/v0/...` surface for the saw graph. After
  `demo saw-filter-bright`, the committed plan showed the expected
  bright cutoff default (`2400.0`) while the other controls stayed
  stable.
- `demo:saw-filter-dark` committed back to the dark saw plan.
- Attempting `demo noise-filter-soft` from the active saw plan was
  rejected as expected for the cross-family preserving boundary. The
  session reported `request-rejected (stack still on previous plan)`,
  resumed the old ingress, skipped supervisor rebuild, and continued
  serving `saw-filter-dark`.
- `noise-filter-soft` opened with three controls: cutoff, q, and
  level. The absence of pitch in the noise family was reflected in
  both startup output and `controls`.
- `demo noise-filter-sharp` committed and showed the expected sharp
  defaults (`cutoff=3200.0`, `q=3.0`). `demo:noise-filter-soft`
  committed back and restored the soft defaults (`cutoff=900.0`,
  `q=1.0`).
- A typo at the prompt (`quis`) stayed non-fatal and reprinted the
  complete command vocabulary. `quit` then terminated cleanly with
  command exit code `0`.

Observed friction:

- The richer manifest did what it was meant to do: it generated a
  broader operator pass without exposing new supervisor plumbing
  friction. Same-family preserving reloads committed cleanly in both
  source families, and cross-family reload rejected without taking
  down the old plan.
- `controls` is now tall enough to notice, especially with a
  10-line terminal, but still readable for a three- or four-control
  voice. This is a watch item, not yet a control-grouping slice.
- The typo recovery path was useful in the moment. Reprinting the
  full vocabulary after `quis` was not too heavy for this pass.
- ALSA stderr noise remains present at startup. It still reads as
  transcript noise rather than operator-session failure.
- Current-value introspection was not exercised here. The pass
  validated declared control surfaces and preserving/reject behavior,
  not live readback of mutated values.

Follow-up chosen from this pass: no immediate implementation. The
Phase 8b Tier 1 repertoire is a better friction generator than the
single-cutoff fixture, and the first operator pass over it validated
that premise. The next useful pass should use this manifest musically
with OSC writes; only open a new code slice if that pass makes a
specific pain point sharp.

### 2026-05-22 — Phase 8b saw/noise OSC pass

Transcript: `/tmp/metasonic-live-session-repertoire-osc.log`,
captured against `examples/manifests/saw-noise-filter.json` starting
from `saw-filter-dark` with `--strategy require-preserving`.

Objective result:

- `saw-filter-dark` opened with four addressable OSC controls:
  pitch (`/v0/carrier/0`), cutoff (`/v0/lpf/0`), q (`/v0/lpf/1`),
  and level (`/v0/gain/0`).
- Pre-reload OSC writes were accepted for all four controls:
  level `0.18`, cutoff `700.0`, cutoff `2400.0`, q `2.5`, and
  pitch `110.0`, `330.0`, `220.0`.
- `demo saw-filter-bright` committed with the preserving route and
  reported `serving plan: saw-filter-bright`.
- A repeated `demo saw-filter-bright` while already on the bright
  plan also committed. This is behaviorally harmless in the pass, but
  it confirms the shell does not currently special-case same-demo
  reloads.
- Post-reload OSC writes still reached the preserved voice: cutoff
  `600.0`, q `0.7`, and level `0.12` were accepted on the bright
  plan.
- The deliberate out-of-range write to cutoff with value `10000.0`
  was rejected at ingress with the declared `[200.0, 6000.0]` range.
- `exit` terminated cleanly with command exit code `0`.

Observed friction:

- The richer saw surface is playable through `tools/send_osc.py`: the
  operator could move level, cutoff, q, and pitch before reload, then
  keep controlling cutoff/q/level after a preserving reload.
- The OSC accept diagnostics are now visibly internal: they expose
  `CmdControlWrite`, `ControlTag`, `MigrationKey`, and floating-point
  representation noise such as `0.18000000715255737`. That did not
  block this pass, but repeated OSC work makes the renderer polish
  more noticeable than the earlier one-control fixtures did.
- Current-value introspection still did not become a hard blocker.
  The transcript proves accepted writes and rejects, but not a live
  "what value is the voice currently using?" query.
- Same-demo reloads are allowed and produce a full committed reload
  block. The transcript does not show this causing confusion, so it
  stays below implementation threshold.

Follow-up chosen from this pass: no new code slice yet. The next
sharpest candidate is cosmetic/operator rendering for OSC accept
lines, but only if another pass confirms those internal constructors
make live use harder. Current-value introspection remains
design-note-first if it becomes the actual pain point.

### 2026-05-22 — OSC accept-line rendering validation

Transcript: `/tmp/metasonic-live-session-osc-render.log`, captured
after `131e487` against `examples/manifests/saw-noise-filter.json`
starting from `saw-filter-dark` with `--strategy require-preserving`.

Objective result:

- `saw-filter-dark` opened with the expected four-control addressable
  OSC surface.
- Pre-reload accepted OSC writes rendered without internal
  constructors and with manifest display names:
  `/v0/gain/0 name="level" value=0.18`,
  `/v0/lpf/0 name="cutoff" value=700`,
  `/v0/lpf/1 name="q" value=0.7`, and
  `/v0/carrier/0 name="pitch" value=330`.
- `demo saw-filter-bright` committed through the preserving route and
  reported `serving plan: saw-filter-bright`.
- A post-reload OSC write to `/v0/lpf/0` still rendered with the
  friendly binding metadata: `name="cutoff" value=600`.
- The out-of-range rejection path stayed on the existing rejection
  shape: `osc reject (out-of-range): tag=lpf/0 value=10000.0
  range=[200.0, 6000.0]`.

Observed friction:

- The accept-line polish achieved the intended operator effect. The
  transcript no longer leaks `CmdControlWrite`, `ControlTag`,
  `MigrationKey`, or float tails like `0.18000000715255737`.
- Binding lookup after preserving reload worked: the accepted
  post-reload write still used the current target metadata.
- Rejection rendering stayed stable. This pass did not ask for or
  need a wider rejection-rendering redesign.
- The pasted transcript stops after the out-of-range rejection and
  does not include `quit` / `Script done`, so this entry does not
  claim clean termination for this specific run.

Follow-up chosen from this pass: none. The OSC accept-line rendering
polish is closed; current-value introspection, ALSA stderr noise,
command history, and same-demo reload special-casing remain separate
lanes that need fresh operator pressure before implementation.

### 2026-05-22 — short musical OSC check

Transcript: `/tmp/metasonic-live-session-musical-pass.log`, captured
against `examples/manifests/saw-noise-filter.json` starting from
`saw-filter-dark` with `--strategy require-preserving`.

Objective result:

- Session opened on `saw-filter-dark` with `audio running: yes`, one
  active voice, OSC port `17004`, and the expected four-control
  addressable surface.
- Four ordinary OSC writes were accepted with the polished operator
  rendering: cutoff `700`, q `2.5`, level `0.15`, and pitch `330`.
- `exit` terminated cleanly with command exit code `0`.

Observed friction:

- No new interaction or diagnosis friction surfaced in this short
  check.
- The polished accept lines remained readable in ordinary use.
- ALSA stderr noise is still present at startup, but it did not
  affect the post-start OSC interaction in this run.
- This was a short straight-through OSC check, not an extended musical
  pass: it did not exercise reloads, cross-family rejection, command
  repetition, or a longer performance flow.

Follow-up chosen from this pass: none. Treat this as another
no-new-lane observation, not as evidence for a new implementation
slice. A future pass would need longer use or repeated friction to
promote any of the standing candidates.

### 2026-05-22 — reproducible saw-family OSC pass

Transcript: `/tmp/metasonic-live-session-musical-long-saw.log`,
captured against `examples/manifests/saw-noise-filter.json` starting
from `saw-filter-dark` with `--strategy require-preserving`.

Objective result:

- Session opened on `saw-filter-dark` with one active voice, OSC port
  `17004`, and the expected four-control addressable surface.
- `demos` listed all four Phase 8b Tier 1 demos and marked
  `saw-filter-dark` as current.
- `controls` printed the saw-family pattern and addressable surfaces
  for pitch (`/v0/carrier/0`), cutoff (`/v0/lpf/0`), q
  (`/v0/lpf/1`), and level (`/v0/gain/0`).
- Pre-reload OSC writes were accepted with the polished operator
  rendering: level `0.18`, cutoff `700`, cutoff `2400`, q `2.5`,
  and pitch `110`, `330`, `220`.
- The timed multi-write sweeps sent through `tools/send_osc.py` with
  `--interval 0.2` landed cleanly: cutoff `700` to `2400`, and pitch
  `110` to `330` to `220`.
- `demo saw-filter-bright` committed through the preserving route and
  reported `serving plan: saw-filter-bright`.
- Post-reload `controls` showed the bright cutoff default `2400.0`
  while preserving the same addressable surface shape.
- Post-reload OSC writes were accepted for cutoff `600`, q `0.7`,
  and level `0.12`.
- The deliberate out-of-range cutoff write `10000.0` was rejected at
  ingress with the declared `[200.0, 6000.0]` range.
- The cross-family `demo noise-filter-soft` request was rejected under
  `require-preserving`; the status check confirmed the stack stayed
  live on `saw-filter-bright` with `audio running: yes`, one active
  voice, open ingress, and `last outcome: request-rejected`.
- `quit` terminated cleanly with command exit code `0`.

Observed friction:

- Unlike the short musical OSC check above, this pass exercised the
  full operator vocabulary for the current shell: `demos`, `controls`,
  multi-write OSC control, preserving reload, post-reload `controls`,
  post-reload OSC writes, range rejection, cross-family rejection,
  `status`, and `quit`.
- The OSC accept-line polish held up across a longer, reproducible
  saw-family pass. Accepted writes stayed readable before and after a
  preserving reload, including repeated writes to the same address and
  binding metadata lookup after `saw-filter-bright` became current.
- The same-family reload and cross-family reject behaviors matched the
  Phase 8b repertoire contract.
- The cross-family reject diagnostic is now well rehearsed in saw/noise
  operator passes; this run did not add any operator-side complaint
  about that output.
- ALSA stderr noise remained present at startup, but it did not
  obscure the post-start commands or OSC accept/reject evidence in
  this run.
- The run covered the short-pass gaps: reload, cross-family rejection,
  command repetition, and clean termination after the reject path.
- No repeated or blocking interaction friction surfaced.

Follow-up chosen from this pass: none. This is durable validation of
the Phase 8b saw-family operator path, not evidence for a new code
slice. The standing candidates remain watch items until a future
operator pass repeats or sharpens one of them.

### 2026-05-22 — reproducible noise-family OSC pass

Transcript: `/tmp/metasonic-live-session-musical-long-noise.log`,
captured against `examples/manifests/saw-noise-filter.json` starting
from `noise-filter-soft` with `--strategy require-preserving`.

Objective result:

- Session opened on `noise-filter-soft` with one active voice, OSC
  port `17004`, and the expected three-control addressable surface.
- `demos` listed all four Phase 8b Tier 1 demos and marked
  `noise-filter-soft` as current.
- `controls` printed the noise-family pattern and addressable surfaces
  for cutoff (`/v0/lpf/0`), q (`/v0/lpf/1`), and level
  (`/v0/gain/0`).
- Pre-reload OSC writes were accepted with the polished operator
  rendering: level `0.15`, cutoff `900`, cutoff `3200`, q `1`, and
  q `3`.
- The timed multi-write sweeps sent through `tools/send_osc.py` with
  `--interval 0.2` landed cleanly: cutoff `900` to `3200`, and q `1`
  to `3`.
- `demo noise-filter-sharp` committed through the preserving route and
  reported `serving plan: noise-filter-sharp`.
- Post-reload `controls` showed the sharp defaults, cutoff `3200.0`
  and q `3.0`, while preserving the same addressable surface shape.
- Post-reload OSC writes were accepted for cutoff `900`, q `1`, and
  level `0.1`.
- The deliberate out-of-range cutoff write `10000.0` was rejected at
  ingress with the declared `[200.0, 6000.0]` range.
- The cross-family `demo saw-filter-dark` request was rejected under
  `require-preserving`; the status check confirmed the stack stayed
  live on `noise-filter-sharp` with `audio running: yes`, one active
  voice, open ingress, and `last outcome: request-rejected`.
- `quit` terminated cleanly with command exit code `0`.

Observed friction:

- This pass completed the saw/noise symmetry check: both source
  families now have an extended pass covering `demos`, `controls`,
  multi-write OSC control, preserving reload, post-reload `controls`,
  post-reload OSC writes, range rejection, cross-family rejection,
  `status`, and `quit`.
- The OSC accept-line polish held up across the noise-family reload,
  including binding metadata lookup after `noise-filter-sharp` became
  current.
- The same-family reload and cross-family reject behaviors matched the
  Phase 8b repertoire contract from the noise side as well.
- ALSA stderr noise remained present at startup, but it did not
  obscure the post-start commands or OSC accept/reject evidence in
  this run.
- No repeated or blocking interaction friction surfaced.

Follow-up chosen from this pass: none. Under the Evidence To Code
rubric above, this is a third no-new-lane pass after the Phase 8b
closure tag and completes the mirrored saw/noise validation. The
standing candidates remain watch items, not implementation pressure.
