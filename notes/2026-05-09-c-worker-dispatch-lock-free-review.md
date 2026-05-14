# Worker Dispatch Lock-Free Review

Date: 2026-05-09
Commit: e77868f (`Make worker dispatch lock-free on audio thread`)
Status: Review note. No blocking findings.

## Summary

Commit e77868f converts the Phase 4.E worker dispatch primitive from
the earlier mutex / condition-variable scaffold to an atomic
generation-and-completion protocol. The change is careful and correct
for the current test-gated worker path: ABI shape is unchanged, the
prior C1c tests remain applicable, and the runtime behavior change is
limited to the dispatch mechanism itself.

The important policy point is unchanged: this makes the dispatch
substrate lock/allocation-free on the audio thread, but it does not
make worker scheduling public or default-on. That still waits for the
post-atomic benchmark refresh and a successor turn-on decision.

## Concurrency Correctness

### Publication ordering

The audio thread publishes work in this sequence:

```cpp
current_work_user.store(..., release);
current_work.store(..., release);
completed_workers.store(0, release);
work_generation.fetch_add(1, release);
```

The first three stores are sequenced before the `fetch_add(release)`.
Workers synchronize by observing `work_generation` with an acquire
load, so the published function pointer, user pointer, and reset
completion counter are visible before any worker executes the band.
The later acquire loads of `current_work` and `current_work_user` are
stronger than strictly necessary once the generation acquire has
established the happens-before edge, but they are harmless.

Resetting `completed_workers` before the generation bump is essential.
If the reset happened after the bump, a worker could observe the new
generation and increment a stale completion count. The current order
prevents that.

### Cross-band accounting

The audio thread does not proceed to the next band until:

```cpp
completed_workers >= active_background_workers
```

That means every background worker's band-N completion increment has
landed before band N+1 can reset the counter and bump the generation.
There is no path for a leftover band-N increment to satisfy band N+1's
join early.

### Worker generation initialization

Workers initialize `seen_generation` to zero. This is the correct
choice. Initializing from `work_generation.load()` would let a worker
that starts late observe an already in-flight generation and treat it
as old work, causing the audio thread to wait for a completion that
will never arrive.

Because `stop_workers` resets `work_generation` to zero before a new
pool is spawned, the first nonzero generation seen by each worker is
always a real dispatch.

### Shutdown handshake

`stop_workers` stores `stopping = true` and bumps the generation. The
worker loop checks `stopping` both at the top of the loop and again
after noticing a new generation, so idle and in-flight races both exit
cleanly.

Workers do not increment `completed_workers` on the shutdown path. That
is correct under the call-site invariant: pool shutdown happens outside
`run_parallel`, while audio is stopped or through test/construction
control, so no audio-thread join is waiting for those increments.

### Background worker publication

`set_size` starts the background threads before publishing
`background_workers`. Therefore `run_parallel` cannot observe a
positive worker count before the corresponding threads have been
created. A thread may still not have been scheduled yet, but that only
delays the first dispatch's join; it does not break correctness.

## Spin Window Calibration

`audio_join_pause` spins for up to 4096 pause/yield instructions before
falling back to `std::this_thread::yield()`.

On x86, a pause instruction is roughly in the 100 to 140 cycle range,
so 4096 pauses is around 100 microseconds on a 4 GHz CPU. For a
64-frame block at 48 kHz, whose budget is about 1.33 ms, that is a
reasonable worst-case spin window before yielding. This threshold
should be revisited during the post-atomic benchmark refresh if real
Haskell-loaded workloads show different behavior.

The fallback `std::this_thread::yield()` is not a hard realtime
primitive on POSIX hosts. The code comments are honest about this: a
deployed realtime configuration should run worker lanes with an
audio-compatible scheduling policy so joins complete during the spin
window.

## Documentation Consistency

The documentation updates line up with the implementation:

- `notes/2026-05-09-a-phase-4e-worker-bench-interpretation.md` preserves
  the prior bench note as workload-shape evidence while marking its
  timing numbers as measured against the old mutex/cv dispatch path.
- `notes/2026-05-09-b-phase-4e-worker-turn-on-decision.md` removes the
  old "needs realtime-safe primitive" prerequisite and keeps the
  remaining gates: representative speedup and a successor decision
  record.
- `ROADMAP.md` now records the dispatch primitive as atomic and
  lock/allocation-free on the audio thread, and shifts the next slice
  from building the primitive to rerunning benchmarks against it.
- `notes/2026-05-08-b-deterministic-bus-reduction-design.md` keeps the
  default-off policy tied to post-atomic-dispatch evidence, not to the
  old mutex/cv limitation.

## Non-Blocking Observations

The previous roadmap caveat about "bench pessimism" is mostly
addressed by the atomic primitive: future sub-1.0x rows are stronger
evidence than the old mutex/cv results. Still, if the refreshed bench
lands in a borderline range such as 0.7x to 0.95x, the interpretation
should explicitly decide whether remaining overhead, workload shape, or
parallelism itself is the limiting factor.

The `run_parallel` control flow has separate guards around lane-0
execution and background-worker join. It could be flattened, but the
current shape makes the intended semantics clear: publish work, run the
audio thread's lane 0, then join background lanes if any exist.

## Outcome

The commit is sound. It removes the known audio-thread mutex/cv problem
from the test-gated worker dispatcher without changing the public ABI or
turn-on policy. The next engineering step is a benchmark refresh against
the atomic dispatch primitive, followed by a decision record update if
the data changes the worker-scheduling policy.
