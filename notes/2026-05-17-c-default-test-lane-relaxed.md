# Default Test Lane Relaxed Back to Parallel

Date: 2026-05-17

Status: policy change. After the lock narrowing in `5a66054` and the
MIDI lifetime fix in `e5ed3d9`, the serial-default gate on
`just stack-test` is no longer pulling its weight. This note records
the relaxation and the conditions under which it should be re-tightened.

## What changed

[justfile](../justfile):

- `stack-test` is back to `stack test` (Tasty default parallelism,
  `numCapabilities` workers).
- A new `stack-test-serial` recipe carries the `--num-threads=1`
  escape hatch.
- `stack-test-parallel` is gone — `stack-test` is now the parallel
  default, so the explicit-parallel alias would be a duplicate.
- The `stack-test-parallel-asan` recipe comment was edited to drop
  the stale "the serial-default gate currently masks" framing and
  reframe the ASan lane as the diagnostic surface against the two
  still-unproven FFI-lock suspects.

## Why it was safe to flip

The serial default landed during the parallel-test SIGABRT
investigation. Two distinct bugs were responsible:

1. **MIDI lifetime (e5ed3d9).** `cycfi::q::midi_device::list()`
   handed out by-reference references into a static accumulator
   plus a by-reference `_impl` member; concurrent test entry
   destroyed both. Fixed with a shadow-header replacement that
   stores `impl` by value and removes the static accumulator.
2. **Process-global FFI re-entry.** The original mitigation was a
   monolithic `ffiLock`. After the lifetime fix, that lock was
   narrowed in `5a66054` to two specific scopes: PortAudio
   start/stop/clear, and ScheduleWorkerPool destroy/clear/test-set-pool-size.
   The 9 other previously-locked calls were unlocked.

After that pair of changes:

- 15 ASan + UBSan validation runs at varied load passed clean
  (recorded in [notes/2026-05-16-b-ffi-serialization-guard-and-audible-osc-runbook.md](2026-05-16-b-ffi-serialization-guard-and-audible-osc-runbook.md)).
- 10 consecutive parallel `stack test` runs at the current HEAD
  passed without SIGABRT or test failure (verified at the time of
  this commit).

That is enough evidence to flip the default back. The remaining
FFI locks are preserved exactly because the two named suspects are
the only paths the validation runs did not falsify; their drop
conditions are documented inline in
[src/MetaSonic/Bridge/FFI.hs](../src/MetaSonic/Bridge/FFI.hs) (`Note [FFI lock: PortAudio lifecycle]`
and `Note [FFI lock: ScheduleWorkerPool teardown]`).

## When to revisit

Re-tighten the default to serial if:

- A new intermittent SIGABRT appears in CI or local parallel runs
  and the ASan diagnostic lane (`just stack-test-parallel-asan`)
  cannot pin a single shared-state offender. The serial gate buys
  time to isolate the regression without burning developer-cycles
  on flaky reds.
- A new test lands that drives process-global C state outside the
  two locks the FFI helpers currently guard. In that case, prefer
  adding the test under `stack-test-serial` while the lock surface
  catches up, rather than relaxing the lock prematurely.

Drop the remaining FFI locks if either of the inline `Note` drop
conditions in `Bridge/FFI.hs` is met — a focused stress harness
proving the suspect is safe under concurrent calls, not just the
broader-suite evidence the relaxation here rests on.
