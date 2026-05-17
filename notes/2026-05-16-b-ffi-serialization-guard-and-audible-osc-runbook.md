# FFI Process-Global Serialization Guard And Audible OSC Reload Runbook

Date: 2026-05-16

Status: stabilization decision plus the operator-runbook half. The
process-global FFI lock is a conservative bandage to stop intermittent
SIGABRT in `stack test` poisoning the validation loop; the audible OSC
reload runbook is the next product-facing validation pass that sits on
top of the now-trustworthy test runner. Not a design pin; the design
pin for the underlying race is in the inline `Note [Process-global FFI
serialization guard]` at the top of
[src/MetaSonic/Bridge/FFI.hs](../src/MetaSonic/Bridge/FFI.hs).

## Why this came up

`stack test` aborted intermittently with glibc heap-corruption signals:

```text
free(): double free detected in tcache 2
double free or corruption (out)
malloc(): unsorted double linked list corrupted
```

All with SIGABRT (-6). Different symptoms across runs but same general
shape (glibc heap consistency check killing the process). Two failures
of different shapes within one session ruled out "one-off flake".

The failures interleaved with test output around the §4.B fusion
kernel group:

```text
ring mod (audio-mod gain stays dispatched, output gain fuses): free(): double free detected in tcache 2
fm carrier with scalar output gain:                            OK
scalar Gain chain x2:                                          OK
scalar Gain chain x3:                                          ...
```

## Investigation

What the failing tests actually do:
- Each test in `Step C (f): fused render equals unfused render`
  (driver: [test/MetaSonic/Spec/FFI.hs:677](../test/MetaSonic/Spec/FFI.hs#L677),
  predicate: [assertFusedEquivalent](../test/MetaSonic/Spec/FFI.hs#L2448))
  runs in isolation: own `withRTGraph`, own `loadRuntimeGraph`,
  own `c_rt_graph_process`, own `c_rt_graph_read_bus`, then bracket
  cleanup runs `destroyRTGraph`.
- No `start_audio`, so PortAudio is not in play for these tests.
- Tasty's default parallelism (`N = numCapabilities`) runs many of
  these on different OS threads. Each test gets its own
  `Ptr RTGraph` and never shares it.
- The crash is therefore **cross-handle**, not intra-handle.

What state is actually shared across handles:
- **q_lib / Cycfi Q lazy/static process-global state** (oscillator
  lookup tables, BLEP, biquad coefficients, anything statically owned
  inside the q headers). Unverified — true C++11 Meyers singletons are
  thread-safe at first-touch, but we have not audited which q surfaces
  are initialized that way versus by other lazy patterns. Remains a
  suspect.
- **PortAudio `Pa_Initialize` / `Pa_Terminate` refcount** — process-global.
  Not in play for the §4.B Step C tests; they never call `start_audio`.
- **`ScheduleWorkerPool` teardown** — per-handle in principle, but if any
  test sets `set_worker_pool_size > 1`, that handle spawns OS threads.
  The destroy path
  (`g->worker_pool.stop_workers()` at
  [tinysynth/rt_graph.cpp:8740](../tinysynth/rt_graph.cpp#L8740))
  is the most exposure-prone teardown path; bad join interleavings
  across handles are plausible.
- **glibc malloc** is thread-safe under default config, so not a direct
  culprit.

What is NOT shared: every C ABI entry takes `Ptr RTGraph` first, and
the major data structures (`Server`, `worker_pool`, audio stream,
contribution slots, schedule capacity) live as members of the `RTGraph`
struct. `rt_graph.cpp` has no file-scope mutable data beyond
`static constexpr` constants.

## Decision: option C, process-global lock as stabilization

Considered three wrapper shapes:

**(A)** Per-handle MVar packaged with the handle. Invasive type change
(`Ptr RTGraph` → `data RTGraphHandle = RTGraphHandle (Ptr RTGraph)
(MVar ())`). Touches every consumer signature. Cleanest contract but
high cost — and it only protects "same Ptr RTGraph used concurrently",
which the failure path says is not the situation.

**(B)** Per-handle MVar in a side-map keyed by pointer
(`MVar (Map (Ptr RTGraph) (MVar ()))`). Preserves signatures. Still
preserves cross-handle parallelism — which is exactly where the abort
appears.

**(C)** Single process-global MVar. Wraps lifecycle-sensitive
entrypoints. Trades cross-handle serialization for deterministic
test runs. Documents the boundary where shared C++/q_lib state is
suspected.

Picked **(C)**. The race is cross-handle, so cross-handle
serialization is what we need to suppress it. (A) and (B) optimize for
intra-handle correctness that we have no evidence of needing.

`just stack-test-serial` (a `-j 1` recipe) was considered as an
alternative escape hatch and rejected: it hides the bug at the test
runner level and slows unrelated Haskell tests. A narrow FFI lock is
better because it documents the suspected boundary inline in the code.

## What landed in [src/MetaSonic/Bridge/FFI.hs](../src/MetaSonic/Bridge/FFI.hs)

Lock infrastructure (`{-# NOINLINE #-}` `ffiLock :: MVar ()` plus a
`withFfiLock :: IO a -> IO a` helper) at the top of the module, with an
inline `Note [Process-global FFI serialization guard]` framing this as
conservative Haskell-side serialization for process-global state in the
C++/q_io runtime — not a claim that individual `Ptr RTGraph` handles
are shared across Haskell threads.

Pattern for each wrapped call: rename the foreign import to add
`_raw`, then define a Haskell function with the original exported name
that wraps the body in `withFfiLock`. Consumer signatures and the
export list are unchanged.

**Wrapped (14 entries):**

| Group     | Wrapped                                                                                            |
|-----------|----------------------------------------------------------------------------------------------------|
| Lifecycle | `c_rt_graph_destroy`, `c_rt_graph_clear`                                                           |
| Render    | `c_rt_graph_process`, `c_rt_graph_read_bus`                                                        |
| Audio     | `c_rt_graph_start_audio`, `c_rt_graph_stop_audio`                                                  |
| Swap      | `c_rt_graph_prepare_swap`, `c_rt_graph_prepare_swap_from_graph`, `c_rt_graph_cancel_swap`, `c_rt_graph_publish_swap`, `c_rt_graph_collect_retired_swap` |
| Test knobs| `c_rt_graph_test_set_worker_pool_size`, `c_rt_graph_test_set_global_schedule_execution`, `c_rt_graph_test_set_reduction_capture` |

**`c_rt_graph_wait_started` deliberately unwrapped**, with an inline
comment at the import site explaining why: it is a blocking poll on
the audio-thread readiness flag; holding `ffiLock` during the wait
would block every other FFI call across all handles for the duration
of the wait. The C side already polls a per-handle atomic without
touching shared mutable state. This is a maintenance trap and the
comment makes it visible.

**Haskell helpers inherit the lock through their underlying calls:**
- `destroyRTGraph = c_rt_graph_destroy` — wrapped via the
  `c_rt_graph_destroy` name now resolving to the locked Haskell
  wrapper, not the foreign import.
- `startAudio g chans dev = fromIntegral <$> c_rt_graph_start_audio g chans dev`.
- `stopAudio = c_rt_graph_stop_audio`.

No separate wrapping was needed at the helper layer; the export-name
shadow does the work.

**Not wrapped** (per the "do not bother with pure metadata reads"
guidance):

- `c_rt_graph_capacity`, `c_rt_graph_max_frames`, `c_rt_graph_audio_running`
- swap generation / migration counters
  (`c_rt_graph_swap_generation`,
  `c_rt_graph_test_swap_*`,
  `c_rt_graph_swap_migration_*_count`)
- registry probes (`c_rt_graph_kind_supported`, `c_rt_graph_plugin_*`)
- all `c_rt_graph_test_*` introspection getters
- the loader-phase mutators (`c_rt_graph_add_node`,
  `c_rt_graph_set_control`, `c_rt_graph_connect`,
  `c_rt_graph_ensure_bus`, and the multi-template equivalents) —
  called many times per graph load from one thread per test;
  intra-load serialization adds no value and would inflate lock
  acquisitions per test by orders of magnitude

## Validation

Five consecutive full `stack test` runs passed, each in ~0.3s wall
time. No SIGABRTs, no heap-corruption messages, no `free():`
interleaving. The earlier intermittent `double free in tcache 2` /
`unsorted double linked list corrupted` failures do not reproduce.

Build is clean. Two `--help` / `--authoring-manifest` smoke checks
confirm the FFI lock didn't disturb the operator-facing CLI paths.

## What this does NOT prove

The underlying C++ race is not fixed. The serialization guard is a
Haskell-side bandage. The inline note explicitly frames it that way
and points at the suspects: unverified lazy/static process-global
state in q_lib, `ScheduleWorkerPool` teardown, PortAudio refcount.

If the C++ side is hardened later (per-handle isolation in the worker
pool, explicit q_lib init at startup, scrutiny of any static state
between handles), this guard can be narrowed to a per-handle lock or
removed entirely.

## Residual risk and next expansion points

- The guard does not serialize C++ audio callback execution once
  `startAudio` returns. The callback runs unlocked, which is correct
  (Haskell must not hold a lock the realtime thread might wait on)
  but means a runtime race in the audio callback would not be caught
  by this guard.
- The guard does not wrap loader-phase mutators
  (`add_node`, `set_control`, `connect`, `ensure_bus`,
  multi-template equivalents). Loader-time corruption is unlikely
  given the single-thread-per-load discipline, but if the abort
  returns and points there, the next expansion would be to wrap
  full loader phases (whole `loadRuntimeGraph` / `loadTemplateGraph`
  calls) rather than individual mutators — a single `withFfiLock`
  around the whole loader body keeps the lock-acquisition count low.
- If neither expansion stops new aborts, the real fix is in C++:
  audit `ScheduleWorkerPool` teardown ordering and pin down q_lib
  static initialization (Meyers singletons, lookup tables) so they
  cannot race across handles.

## Audible OSC reload validation — operator runbook

This is the next product-facing validation pass. The FFI guard
stabilizes the deterministic test loop; the OSC tool split
([2026-05-16-a recap](2026-05-16-a-manifest-midi-smoke-operator-recap.md)
sibling work) gives a clean operator sender. The remaining open
question is integration: does the experimental live reload path
behave audibly with real audio running and manifest-aware OSC ingress?

Treat this as a manual validation pass. Don't add more MIDI plumbing
until this OSC path is heard and understood.

### Step 1 — capture the manifest

```sh
stack exec -- metasonic-bridge --authoring-manifest named-control send-return \
  > /tmp/metasonic-live-manifest.json
```

### Step 2 — start the experimental audible reload demo

```sh
stack exec -- metasonic-bridge \
  --session-osc-port 7001 \
  --manifest-live-reload-demo try-preserving \
  /tmp/metasonic-live-manifest.json \
  named-control \
  send-return
```

This:

1. Validates the manifest against the compiled catalog.
2. Starts audio.
3. Opens manifest-aware OSC ingress on port 7001.
4. Auto-spawns one voice per template so the surface is audible.
5. Prints the addressable OSC surface — concrete
   `/<voice>/<tag>/<slot>` addresses with `<voice>` filled in from
   `ssVoices` (per the day-log refinement).
6. Waits for Enter, then runs `reloadManifestHostWithStrategy
   try-preserving` to swap to `send-return`.
7. Prints the strategy outcome — `MrhsrPreserving` /
   `MrhsrStoppedAudio` fallback / failure shape — then the
   post-reload addressable surface.

### Step 3 — exercise OSC before the reload (different terminal)

```sh
# Replace v0/cutoff/0 with whatever the demo printed
just osc-send 1500 7001 127.0.0.1 /v0/cutoff/0
just osc-send 0.5  7001 127.0.0.1 /v0/vol/0

# Or with the script directly, including an int test:
python3 tools/send_osc.py --port 7001 --address /v0/cutoff/0 --value 1500
python3 tools/send_osc.py --port 7001 --address /v0/cutoff/0 --type int --value 800
```

### Step 4 — press Enter in the demo terminal to trigger the reload

### Step 5 — exercise OSC after the reload

Against whatever the demo prints as the *new* addressable surface
(different controls, possibly different voice keys).

### What to capture / watch for

- **Strategy outcome and audio continuity.** The demo prints which
  strategy ran (`MrhsrPreserving` / `MrhsrStoppedAudio` fallback /
  failure shape) and the post-reload addressable surface. For
  `MrhsrPreserving`, expect audio to keep running and the new surface
  to appear without an intervening audio restart. For
  `MrhsrStoppedAudio`, expect a clean audio restart between the old
  and new surface. Either is a successful path; what matters is that
  it matches what the underlying graph pair supports. The
  `named-control` → `send-return` pair will probably fall back to
  stopped-audio because their template shapes differ; that is still
  a success. The demo does not currently surface `AudioStop` as an
  operator-facing event — if it becomes useful, the demo's
  listener-hook output would need to print it explicitly.
- **Old OSC addresses reject after reload** — `osc reject (manifest):
  ...` lines (the listener was reopened against the new target).
- **New OSC addresses accept and produce audible change** — the
  audible part only a human can verify.
- **`osc accept: ...` lines** for each accepted CC write: one short
  line per event, not full `Show` dumps.
- **No `SeiQueueFull` spam** during a moderate operator sweep — the
  fan-in service should drain.

### What this validation does not cover

- The audible quality of the reload (click, glitch, silence on
  fallback, timbral correctness on the new demo).
- MIDI ingress in the live reload path — explicitly deferred per the
  reload arc closeout note.
- Hot-swap preservation across actually-preserving-compatible graph
  pairs (`named-control` → `send-return` is not such a pair). Pinning
  preserving behavior under real audio against a compatible pair is
  a follow-up validation, not part of this first audible smoke.

### After

Capture friction the same way as the MIDI smoke recap. Worth writing
a sibling note (`notes/2026-05-16-c-manifest-osc-live-reload-operator-recap.md`)
if anything interesting surfaces — keeps the letter-suffix
convention going.

## Related files

- [src/MetaSonic/Bridge/FFI.hs](../src/MetaSonic/Bridge/FFI.hs) —
  `ffiLock`, `withFfiLock`, the 14 wrapped foreign imports, the
  deliberate `c_rt_graph_wait_started` exception, the inline
  `Note [Process-global FFI serialization guard]`.
- [test/MetaSonic/Spec/FFI.hs](../test/MetaSonic/Spec/FFI.hs) —
  `Step C (f): fused render equals unfused render` is where the
  crash surfaced; the tests themselves are unchanged.
- [tinysynth/rt_graph.cpp](../tinysynth/rt_graph.cpp) —
  `ScheduleWorkerPool` (line ~2354), the destroy/teardown path
  (line ~8740), and PortAudio integration are the suspect surfaces
  for a future C++-side fix.
- [app/MetaSonic/App/ManifestLiveReloadDemo.hs](../app/MetaSonic/App/ManifestLiveReloadDemo.hs) —
  the audible reload demo entry behind `--manifest-live-reload-demo`.
- [notes/2026-05-15-d-manifest-reload-ingress-v1-closeout.md](2026-05-15-d-manifest-reload-ingress-v1-closeout.md) —
  v1 boundary for the manifest reload arc; this audible demo is the
  first product-facing consumer that sits above that boundary.
- [notes/2026-05-15-e-manifest-reload-day-log.md](2026-05-15-e-manifest-reload-day-log.md) —
  arc retrospective; Wave 5 introduces `--manifest-live-reload-demo`.
- [notes/2026-05-16-a-manifest-midi-smoke-operator-recap.md](2026-05-16-a-manifest-midi-smoke-operator-recap.md) —
  sibling operator pass on the MIDI side.

## ASan Validation Against e5ed3d9

Date: 2026-05-17

Status: first sanitizer-evidence pass after `e5ed3d9`
(`Make midi_device own impl by value; add ASan diagnostic lane`).
Five consecutive runs of `just stack-test-parallel-asan` against the
fixed C++ side. Five clean runs is enough to say the MIDI lifetime
fix did not immediately regress under the known sanitizer lane; it
is **not** enough to claim the process-global FFI guard from
`5629532` is obsolete. Lock narrowing would need 10+ clean runs
under varied load and is a separate, later commit with its own
failure-mode argument.

### Environment

- Host kernel: `Linux 6.17.10-100.fc41.x86_64 #1 SMP PREEMPT_DYNAMIC Mon Dec  1 16:10:21 UTC 2025 x86_64 GNU/Linux`
- Stack flag: `metasonic-bridge:asan` (`-fsanitize=address,undefined`)
- Sanitizer options:
  `ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:fast_unwind_on_malloc=0:print_stacktrace=1`
  / `UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1`
- Work-dir: `.stack-work-asan` (isolated from default `.stack-work`)
- Tasty parallelism: defaults to `numCapabilities`

### Runs

| # | Started (local)        | Result | Tasty (count / time)    | Wall  |
|---|------------------------|--------|-------------------------|-------|
| 1 | 2026-05-17T18:40:09-03:00 | PASS   | 1141 tests in 0.85s     | 2s    |
| 2 | 2026-05-17T18:40:11-03:00 | PASS   | 1141 tests in 0.82s     | 2s    |
| 3 | 2026-05-17T18:40:13-03:00 | PASS   | 1141 tests in 0.71s     | 1s    |
| 4 | 2026-05-17T18:40:14-03:00 | PASS   | 1141 tests in 0.83s     | 2s    |
| 5 | 2026-05-17T18:40:15-03:00 | PASS   | 1141 tests in 0.71s     | 2s    |

No AddressSanitizer aborts. No UndefinedBehaviorSanitizer reports.
Test count constant across runs.

### Verdict

The MIDI-lifetime fix in `e5ed3d9` survives parallel Tasty execution
under ASan + UBSan over five consecutive runs on this host. That
result is consistent with the documented mechanism: `midi_device`
now owns its `impl` by value (via the local shadow header
[tinysynth/q_io/midi_device.hpp](../tinysynth/q_io/midi_device.hpp)),
so the old "later `list()` call dangles every prior `midi_device`"
pattern can no longer arise from the type contract.

What this evidence does **not** establish:

- That the other two suspects originally named in `5629532`
  (`ScheduleWorkerPool` teardown, PortAudio refcount semantics)
  are race-free under parallel test load.
- That the process-global FFI lock from `5629532` is removable.
- That the serial-default gate from `a6cba56` can be relaxed.

Next evidence pass before any lock or default change: 10+ clean
runs of `just stack-test-parallel-asan` under varied machine load
(idle vs. concurrent CPU-bound work vs. `nice` deprioritized),
documented in this same note as a separate section.

### Extended pass: varied load

Date: 2026-05-17

Status: ten additional runs of `just stack-test-parallel-asan`
against `e5ed3d9`, spread across three load conditions. This
addresses the load-dependence of the original race: five idle
passes is not statistically different from one idle pass, and the
crash captured in `5629532` only fired when test threads were
competing for cores. Ten clean runs across three regimes is the
first evidence that speaks to that failure mode.

Host kernel, sanitizer environment, and work-dir isolation are
unchanged from the previous section. The only variation is the
load profile per run.

| #  | Started (local)        | Load condition                                | Tasty time | Wall | Result |
|----|------------------------|-----------------------------------------------|-----------:|-----:|--------|
| 1  | 2026-05-17T18:51:11-03:00 | idle                                          | 0.62s      | 2s   | PASS   |
| 2  | 2026-05-17T18:51:13-03:00 | idle                                          | 0.63s      | 1s   | PASS   |
| 3  | 2026-05-17T18:51:14-03:00 | idle                                          | 0.66s      | 1s   | PASS   |
| 4  | 2026-05-17T18:51:15-03:00 | idle                                          | 0.61s      | 1s   | PASS   |
| 5  | 2026-05-17T18:51:17-03:00 | concurrent `stress-ng --cpu 14 --timeout 30s` | 4.86s      | 7s   | PASS   |
| 6  | 2026-05-17T18:51:47-03:00 | concurrent `stress-ng --cpu 14 --timeout 30s` | 3.43s      | 5s   | PASS   |
| 7  | 2026-05-17T18:52:17-03:00 | concurrent `stress-ng --cpu 14 --timeout 30s` | 3.31s      | 5s   | PASS   |
| 8  | 2026-05-17T18:52:47-03:00 | `nice -n 19 just stack-test-parallel-asan`    | 0.74s      | 1s   | PASS   |
| 9  | 2026-05-17T18:52:48-03:00 | `nice -n 19 just stack-test-parallel-asan`    | 0.74s      | 2s   | PASS   |
| 10 | 2026-05-17T18:52:50-03:00 | `nice -n 19 just stack-test-parallel-asan`    | 0.92s      | 1s   | PASS   |

All 10 runs: 1141 Tasty tests, no AddressSanitizer aborts, no
UndefinedBehaviorSanitizer reports.

The CPU-stress runs' Tasty time (3.3–4.9s) is ~5–8× the idle
baseline (~0.6s), confirming the stressor actually competed with
Tasty workers for the 14 cores (`nproc` on this host) rather than
running on idle headroom. That is the scheduling pressure
condition the original `5629532` race depended on; the lifetime
fix in `e5ed3d9` did not regress under it.

### Verdict (after 5 idle + 10 varied-load runs)

Fifteen total clean ASan+UBSan runs against `e5ed3d9` across idle,
contended, and deprioritized conditions. This is the first evidence
pass that meaningfully addresses the load-dependent failure mode
the `5629532` lock was patching.

What this now establishes:

- The MIDI-lifetime fix in `e5ed3d9` is stable under sustained
  parallel sanitizer load on this host kernel.
- The C++ runtime, exercised through the entire Haskell test
  corpus, does not surface any other ASan-detectable corruption
  under the same scheduling pressure that previously fired the
  `5629532` SIGABRT.

What this still does **not** establish:

- That `ScheduleWorkerPool` teardown and PortAudio refcount
  semantics (the other two suspects named in `5629532`) are
  race-free. The current test corpus may not stress those code
  paths under enough scheduling pressure to fire any latent race.
- That the same result holds on a different host kernel, glibc
  version, or CPU count.

### Next slice (separate commit)

With this evidence in place, the next slice is the lock-narrowing
or removal decision. That belongs in its own commit, with its own
failure-mode argument referencing this section and the inline
`Note [Process-global FFI serialization guard]` in
[src/MetaSonic/Bridge/FFI.hs](../src/MetaSonic/Bridge/FFI.hs).
Relaxing the `just stack-test` serial default to parallel is a
further separate commit after that, contingent on the lock change
holding green.
