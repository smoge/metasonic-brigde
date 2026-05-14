# Phase 4 Reasoning and Work Summary

Date: 2026-05-10
Status: Phase 4 closed; Phase 4.E frozen as test/bench-gated.

This note records why Phase 4 took the shape it did and what work was
completed before opening Phase 5. It is intentionally higher level than the
per-slice notes: the goal is to preserve the engineering argument, not to
repeat every test case or commit.

## 1. The Phase 4 Thesis

Phase 4 moved MetaSonic from "execute dense nodes in order" toward "compile
and execute meaningful regions." The point was not just speed. The point was
to make graph structure explicit enough that later runtime work can be safe:
fused kernels, rate-aware scheduling, deterministic bus writes, and eventually
hot graph replacement all need a stable description of the work being done.

The core rule was conservative: every optimization had to preserve the dense
runtime contract. `NodeIndex` stayed addressable, controls stayed live, bus
ordering stayed deterministic, and every new execution path needed either
byte-equivalence evidence or a counter proving that the new path actually ran.

## 2. Region Formation and Kernel Fusion

Phase 4.A made regions real. The compiler now partitions each template into
contiguous runtime regions with dependency metadata, and the C++ runtime
receives that overlay through the FFI. This created the substrate for both
kernel selection and later schedule analysis.

Phase 4.B used that substrate narrowly. Instead of pivoting to region codegen,
the runtime added hand-written Q-backed kernels for short high-value shapes:
sink-terminal oscillator/noise/bus-reader chains and one buffer-terminal
Saw-LPF-Gain chain. Longest-match selection kept overlapping shapes stable.

The important reasoning from 4.B was the kernel-add gate:

1. The missed shape must recur in the survey across multiple sources.
2. The benchmark must show a real fused-vs-node-loop win.
3. Tests must compare the fused kernel against a stripped node-loop baseline.
4. Stateful and invalid-input paths must match the per-node baseline.

That gate let `RNoiseLpfGainOut` land only after the corpus signal grew, and
kept Tri/Pulse/Add filtered tails parked as singleton-source rows. It also
kept whole-region codegen deferred: the helper layer is still sufficient, and
codegen would add complexity before the maintenance cost demands it.

## 3. Single-Input Rewrite Fusion

Phase 4.C handled a different optimization class: producers whose work can be
absorbed into a single consumer input read. Scalar `Gain` and scalar `Add`
became the shared `FAffineFrom` chain model. The producer node is elided from
execution but remains present in the runtime graph, so existing control paths
and `NodeIndex` identity continue to work.

This distinction matters. Region kernels claim a contiguous region body.
`RFused` rewrites an edge while preserving the node surface. Keeping those two
mechanisms separate avoided a fragile "everything is a kernel" abstraction and
kept the correctness tests easy to reason about.

## 4. Rate Metadata Before Rate Execution

Phase 4.D started with a negative result. Propagated node output rate reached
the runtime and the survey showed the corpus was effectively all
`SampleRate`. That did not mean the rate system was broken; it meant node
output rate was too coarse for block-latch optimization.

The follow-up added per-kind/per-port consumption policy. The decisive
question became: how does the destination port read this input? Filter
frequency and Q are block-latched, oscillator phase inputs are ignored today,
and most signal ports remain sample-accurate. The survey then grouped
opportunities by producer, because one producer feeding both block-latched and
sample-accurate consumers cannot be demoted.

The result was small but useful signal, not enough to justify a runtime
block-rate path. Phase 4.D therefore closed as descriptive infrastructure:
the metadata is preserved and measured, while execution stays conservative.

## 5. Region-Level Parallelism

Phase 4.E asked whether the region model could safely drive worker execution.
The answer was "yes as substrate, no as default policy."

The completed work includes:

- region bus footprints and layered schedules;
- deterministic linear fallback;
- survey columns for runnable width, reduction width, and hazards;
- writer-slot reservation and contribution storage;
- deterministic bus reduction in test mode;
- a global schedule ABI and serial schedule executor;
- a lock-free audio-thread worker dispatch primitive;
- C1c Free-band worker dispatch behind test/bench switches;
- C1d-a region work-item metadata;
- C1d-b serial region-item execution through those work items;
- C1d-c sink-free region-item worker dispatch;
- C1d-d bench columns that separate C1c, C1d-c, and serial noise.

Two lessons from 4.E are load-bearing:

First, byte-equivalence is not enough. Tests also need counters proving which
executor path ran. Without that, an implementation can pass by silently falling
back to the legacy path.

Second, synthetic speedup is not a turn-on policy. The C++ synthetic
`RegionItems` shape shows that C1d-c scales when there is enough independent
work, reaching the documented 2.20x envelope. The Haskell-loaded corpus does
not yet carry that weight: C1d-c barely clears 1.0x on the summary and has a
best targeted row around 1.14x, with another targeted row losing. C1c has
stronger targeted rows but still not enough representative evidence for a
public switch.

The decision is therefore explicit: Phase 4.E is frozen as test/bench-gated.
No default-on worker dispatch, no public switch, no new synthetic workload
chasing, and no C1d-e until a real workload produces counter-confirmed shape
and enough block cost to matter.

## 6. What Phase 4 Leaves Behind

Phase 4 is valuable even if runtime parallelism never becomes default-on. It
leaves behind:

- a region overlay shared by compiler, runtime, inspector, and survey tools;
- a disciplined kernel-add process grounded in corpus recurrence and benches;
- an edge-fusion model that preserves node identity and live controls;
- per-port consumption metadata for future block-rate decisions;
- global schedule and band introspection, later carried as swappable
  `RTGraphState` scratch in
  [Phase 5.1.B](2026-05-10-a-phase-5-rcu-hot-swap-design.md);
- deterministic writer-slot reservation and reduction infrastructure;
- worker dispatch counters that separate "ran in parallel" from "looked
  faster in a benchmark row."

Those pieces are the reason Phase 5 can start without redesigning Phase 4.
Hot swap needs a well-defined runtime world, clear ownership boundaries, and a
way to rebuild schedule-derived scratch from the active graph. Phase 4 created
that shape. Phase 5 should build on it, but it should not reopen Phase 4.E
parallelism unless a successor decision record replaces the default-off
decision with representative evidence.
