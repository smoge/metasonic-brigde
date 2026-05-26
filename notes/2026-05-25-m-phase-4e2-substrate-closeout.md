# §4.E.2 Deterministic Bus Reduction — Substrate Close-Out

Date: 2026-05-25
Status: Substrate complete. No further §4.E.2 implementation work
without a real workload, mirroring the §4.E parallel-dispatch freeze.

This note stamps the §4.E.2 substrate landed and pins the design-note
test gates (T-1 … T-11) to their file:line homes so a future re-entry
does not redo this scoping pass. The contract is
[notes/2026-05-08-b-deterministic-bus-reduction-design.md](2026-05-08-b-deterministic-bus-reduction-design.md);
this note refers to its §-numbers.

## 1. Substrate state — what is landed

Phase A (BusWriteTarget abstraction):

  - `BusWriteTarget`, `open_direct_bus_write_target`,
    `open_reduction_bus_write_target`, `open_bus_write_target`
    at [tinysynth/rt_graph.cpp:4480-4580](../tinysynth/rt_graph.cpp#L4480-L4580).
  - `BusWriteMode` enum (`Direct` / `Reduction` / `ReductionDeferred`)
    at [tinysynth/rt_graph.cpp:4414-4426](../tinysynth/rt_graph.cpp#L4414-L4426).

Phase B0 (writer-slot identity):

  - `BusWriteContext::reserve_writer_slot` at
    [tinysynth/rt_graph.cpp:4436](../tinysynth/rt_graph.cpp#L4436).
  - Test surface `rt_graph_test_last_writer_slot_count` at
    [tinysynth/rt_graph.h:1051](../tinysynth/rt_graph.h#L1051).
  - Reservation contract — unconditional even on degraded sinks — is
    pinned in Note [Writer-slot plumbing — Phase §4.E.2.B0 / B2] at
    [tinysynth/rt_graph.cpp:4393](../tinysynth/rt_graph.cpp#L4393).

Phase B1 (contribution storage):

  - `ContributionStorage` at
    [tinysynth/rt_graph.cpp:2403-2429](../tinysynth/rt_graph.cpp#L2403-L2429).
  - `required_contribution_slots` + `ensure_contribution_capacity`
    at [tinysynth/rt_graph.cpp:3633-3661](../tinysynth/rt_graph.cpp#L3633-L3661).
  - Sized per design §5 from `Σ_t (def[t].polyphony × sink_writer_count[t])`.

Phase B2 (route under capture):

  - `open_reduction_bus_write_target` at
    [tinysynth/rt_graph.cpp:4532](../tinysynth/rt_graph.cpp#L4532).
  - Gate: `RTGraph::capture_reduction_mode`, toggled by
    `rt_graph_test_set_reduction_capture` ([rt_graph.h:1096](../tinysynth/rt_graph.h#L1096)).
    Default is `Direct`; reduction-mode is opt-in for offline tests
    and the `--worker-bench` capture path.

Phase B3 (canonical fold):

  - `fold_contribution_slots` at
    [tinysynth/rt_graph.cpp:4605](../tinysynth/rt_graph.cpp#L4605).
  - Per-sink immediate-fold `fold_recent_writer_slot_if_needed` at
    [tinysynth/rt_graph.cpp:4633](../tinysynth/rt_graph.cpp#L4633).
  - Deferred-fold range path used by C1c worker dispatch at
    [tinysynth/rt_graph.cpp:8410-8413](../tinysynth/rt_graph.cpp#L8410-L8413).

Phase C0 (global block schedule):

  - `GlobalScheduleEntry` shape at
    [tinysynth/rt_graph.cpp:1343](../tinysynth/rt_graph.cpp#L1343).
  - `build_global_schedule` / `build_global_schedule_bands` build the
    canonical entry list and band partition once per block on the audio
    thread.
  - FFI shipping the per-template schedule:
    `rt_graph_template_add_schedule_step` plus the schedule-step
    introspection family starting at
    [rt_graph.h:1167](../tinysynth/rt_graph.h#L1167) and the
    global-schedule / band introspection at
    [rt_graph.h:1215](../tinysynth/rt_graph.h#L1215) /
    [rt_graph.h:1234](../tinysynth/rt_graph.h#L1234).

Phase C1a / C1b / C1c (worker pool, sink-free Free-band dispatch):

  - `ScheduleWorkerPool` at
    [tinysynth/rt_graph.cpp:2471](../tinysynth/rt_graph.cpp#L2471).
  - Atomic generation + completion counters (post-mutex review
    landed; see [notes/2026-05-09-c-worker-dispatch-lock-free-review.md](2026-05-09-c-worker-dispatch-lock-free-review.md)).
  - Test gate: `rt_graph_test_set_worker_pool_size` /
    `rt_graph_test_worker_pool_size` at
    [rt_graph.h:1114](../tinysynth/rt_graph.h#L1114) /
    [rt_graph.h:1118](../tinysynth/rt_graph.h#L1118).

Phase C1d-a / C1d-b / C1d-c / C1d-d (region-layer dispatch substrate
and bench):

  - C1d-a region work-item metadata table.
    `rt_graph_test_region_layer_work_item_count` at
    [rt_graph.h:1246](../tinysynth/rt_graph.h#L1246) and the wider
    region-layer test surface; design contract in
    [notes/2026-05-09-d-phase-4e-c1d-region-layer-dispatch-design.md](2026-05-09-d-phase-4e-c1d-region-layer-dispatch-design.md);
    review note in
    [notes/2026-05-09-e-c1d-a-region-work-item-metadata-review.md](2026-05-09-e-c1d-a-region-work-item-metadata-review.md).
  - C1d-b serial region-item executor (test-gated; preserved
    byte-equivalence on T-9). C1d-c sink-free parallel region-item
    dispatch through the worker pool (test-gated). C1d-d bench
    instrumentation feeding `--worker-bench` /
    `tools/rt_graph_bench.cpp` C1c-vs-C1d-c partitioning.
  - All four sit under ROADMAP.md items
    [ROADMAP.md:679](../ROADMAP.md#L679),
    [ROADMAP.md:691](../ROADMAP.md#L691),
    [ROADMAP.md:700](../ROADMAP.md#L700),
    [ROADMAP.md:711](../ROADMAP.md#L711) — all `[x]`. Frozen scope
    starts after C1d-d, not before — see §3 below.

## 2. T-1 … T-11 coverage matrix

Design note §10 names eleven gates. Mapping to current fixtures:

  - **T-1 same-bus multi-writer reduction.** Standalone reduction
    fixtures at
    [tests/rt_graph_test.cpp:6854](../tests/rt_graph_test.cpp#L6854)
    ("reduction capture: same-bus writers stay in separate slots (no
    pre-sum)") and
    [tests/rt_graph_test.cpp:6891](../tests/rt_graph_test.cpp#L6891)
    ("reduction fold: same-bus writers match direct output exactly").
    The first pins canonical slot separation (no kernel pre-sum); the
    second pins direct-vs-reduction bit-equivalence on the folded
    bus. Direct-mode anchors at
    [tests/rt_graph_test.cpp:488](../tests/rt_graph_test.cpp#L488)
    ("Multiple Out nodes accumulate onto the same bus") and
    [tests/rt_graph_test.cpp:1133](../tests/rt_graph_test.cpp#L1133)
    ("BusOut: multiple writers to the same bus sum") cover the
    pre-§4.E direct path.

  - **T-2 cross-instance reduction.** Slot-count gate at
    [tests/rt_graph_test.cpp:6275](../tests/rt_graph_test.cpp#L6275)
    ("writer-slot count: cross-instance same template") and slot-order
    gate at
    [tests/rt_graph_test.cpp:7139](../tests/rt_graph_test.cpp#L7139)
    ("reduction capture: cross-instance slot order matches instance
    slot order"). Bit-equivalence comes through T-10's hand-constructed
    case (writer + reader instances of the same template) plus T-9.

  - **T-3 cross-template read-after-write.** Standalone at
    [tests/rt_graph_test.cpp:7095](../tests/rt_graph_test.cpp#L7095)
    ("reduction fold: cross-template live BusIn sees earlier template
    BusOut").

  - **T-4 BusInDelayed correctness under reduction.** Standalone at
    [tests/rt_graph_test.cpp:6959](../tests/rt_graph_test.cpp#L6959)
    ("reduction fold: BusInDelayed reads previous block's folded
    output_buses"). The pre-reduction direct-mode invariants are
    exercised at
    [tests/rt_graph_test.cpp:1189](../tests/rt_graph_test.cpp#L1189) /
    [tests/rt_graph_test.cpp:1252](../tests/rt_graph_test.cpp#L1252).

  - **T-5 dynamic bus redirect.** Standalone at
    [tests/rt_graph_test.cpp:7274](../tests/rt_graph_test.cpp#L7274)
    ("reduction capture: dynamic bus redirect updates target without
    stale metadata").

  - **T-6 invalid bus paths.** Slot-count side at
    [tests/rt_graph_test.cpp:6380](../tests/rt_graph_test.cpp#L6380)
    ("writer-slot count: invalid bus still consumes its slot"); fold
    side at
    [tests/rt_graph_test.cpp:7231](../tests/rt_graph_test.cpp#L7231)
    ("reduction capture: invalid bus reserves slot but leaves target
    = -1, used = 0").

  - **T-7 sink peak correctness under reduction.** Standalone at
    [tests/rt_graph_test.cpp:7364](../tests/rt_graph_test.cpp#L7364)
    ("§4.E.2 T-7: multi-sink per-instance peak invariant under
    reduction"). Two parallel Env→Out chains in one instance, with
    differently-paced release tails so the slower sink's peak
    determines the auto-free window. Asserts equal blocks-to-free
    between direct and reduction-capture modes — the only externally
    observable signal of `inst.block_sink_peak` is the release-
    silencing path, since the peak read-modify-write at
    [tinysynth/rt_graph.cpp:4696-4711](../tinysynth/rt_graph.cpp#L4696-L4711)
    runs beside `target.add()` but does not flow through it, so a
    regression that bypassed per-sink peak updates would leave bus
    output bit-identical and surface only in this timing check. The
    multi-sink shape distinguishes T-7 from T-8 by forcing the peak
    aggregation across sinks rather than a single-sink decay.

  - **T-8 release-then-free unchanged.** Standalone at
    [tests/rt_graph_test.cpp:7436](../tests/rt_graph_test.cpp#L7436)
    ("§4.E.2 T-8: release-then-free auto-frees under reduction
    capture"). Single Env-bearing sink, mirroring the §2.E direct-mode
    test at
    [tests/rt_graph_test.cpp:4847](../tests/rt_graph_test.cpp#L4847)
    with `rt_graph_test_set_reduction_capture` enabled. Release-to-
    free block counts must match between modes.

  - **T-9 direct ≡ reduction on the full demo corpus.** The full T-9
    surface lives at
    [test/MetaSonic/Spec/FFI/T9.hs](../test/MetaSonic/Spec/FFI/T9.hs)
    (single/multi-template × fused/unfused × 4 blocks). T-9 under
    global-schedule execution at
    [test/MetaSonic/Spec/FFI/C0c.hs](../test/MetaSonic/Spec/FFI/C0c.hs).
    T-9 under global schedule + worker pool size 3 at
    [test/MetaSonic/Spec/FFI/C1c.hs](../test/MetaSonic/Spec/FFI/C1c.hs).
    These three are the load-bearing equivalence gates for B3, C0, and
    C1c.

  - **T-10 same-template cross-instance live BusIn.** Standalone at
    [tests/rt_graph_test.cpp:7028](../tests/rt_graph_test.cpp#L7028)
    ("reduction fold: same-template cross-instance live BusIn").

  - **T-11 cross-template same-bus write/write.** Slot-count side at
    [tests/rt_graph_test.cpp:6300](../tests/rt_graph_test.cpp#L6300)
    ("writer-slot count: cross-template, one instance each"); slot-
    order side at
    [tests/rt_graph_test.cpp:7184](../tests/rt_graph_test.cpp#L7184)
    ("reduction capture: cross-template slot order matches
    registration order"). The bit-equivalence corollary is part of
    the T-9 corpus where applicable.

## 3. What stays explicitly out

  - **Phase D** (lift I-4 for writer-only live-bus steps, parallelize
    reduction, skip cold slots, defer past layer boundary): all four
    candidates are frozen by
    [ROADMAP.md:726](../ROADMAP.md#L726) until a real workload
    appears whose region-layer shape and DSP weight justify worker
    dispatch.

  - **C1d-e sink-bearing region-layer dispatch.** Designed in
    [notes/2026-05-09-d-phase-4e-c1d-region-layer-dispatch-design.md](2026-05-09-d-phase-4e-c1d-region-layer-dispatch-design.md)
    (§10 C1d-e). C1d-a through C1d-d are landed test-gated (see §1
    above); only C1d-e is frozen pending workload, per
    [ROADMAP.md:726](../ROADMAP.md#L726) ("no C1d-e, no public
    switch, no additional synthetic workloads, no policy prototype").
    C1d-e is the slice that would put real load on the
    `block_sink_peak` worker-private path the design note's §7
    anticipates.

  - **Public worker-pool switch / default-on dispatch.** The
    `rt_graph_test_set_worker_pool_size` switch stays test-only;
    there is no public ABI to opt into worker dispatch in production.
    The standing decision is locked at
    [notes/2026-05-09-b-phase-4e-worker-turn-on-decision.md](2026-05-09-b-phase-4e-worker-turn-on-decision.md).

  - **Standalone parallel-dispatch variants of T-2, T-3, T-10, T-11.**
    The design note's parenthetical "parallel-dispatch variant ships
    with the Phase D I-4 relaxation" applies — those variants ship
    when Phase D ships, not before.

  - **The §7 work-unit-private peak path.** C1c does parallelize
    sink-bearing Free bands under reduction mode, but
    `should_parallelize_schedule_band` rejects any band whose entries
    share an instance
    ([tinysynth/rt_graph.cpp:8362](../tinysynth/rt_graph.cpp#L8362))
    and admits sink-bearing bands only when reduction mode is active
    ([tinysynth/rt_graph.cpp:8365](../tinysynth/rt_graph.cpp#L8365));
    the per-band fold runs once on the audio thread after worker join
    ([tinysynth/rt_graph.cpp:8409](../tinysynth/rt_graph.cpp#L8409)).
    Each parallel-dispatched sink entry therefore writes a different
    instance's `inst.block_sink_peak`, so the kernel's read-modify-
    write
    ([tinysynth/rt_graph.cpp:4696-4711](../tinysynth/rt_graph.cpp#L4696-L4711),
    [tinysynth/rt_graph.cpp:5868](../tinysynth/rt_graph.cpp#L5868))
    races no other worker. The §7 work-unit-private peak design
    becomes load-bearing only when same-instance multi-sink region
    items dispatch in parallel — C1d-e territory, frozen.

## 4. Re-entry protocol

When a workload candidate appears that justifies reopening §4.E /
§4.E.2 work:

  1. Read the candidate slice's design note (Phase D notes / C1d
     design note above).
  2. Identify whether the C0–C1 substrate and contribution-table
     shape suffices, or whether the workload exposes a hole the
     substrate close-out missed. The §3 list above is the audit
     start.
  3. Open a successor decision record to
     [notes/2026-05-09-b-phase-4e-worker-turn-on-decision.md](2026-05-09-b-phase-4e-worker-turn-on-decision.md).
     Do not extend that note in place — the freeze is recorded
     against its current text.

## 5. Cross-refs

  - [notes/2026-05-08-b-deterministic-bus-reduction-design.md](2026-05-08-b-deterministic-bus-reduction-design.md)
    — the design contract this note closes out.
  - [notes/2026-05-09-a-phase-4e-worker-bench-interpretation.md](2026-05-09-a-phase-4e-worker-bench-interpretation.md)
    — bench interpretation that gates default-on.
  - [notes/2026-05-09-b-phase-4e-worker-turn-on-decision.md](2026-05-09-b-phase-4e-worker-turn-on-decision.md)
    — decision record locked by the freeze.
  - [notes/2026-05-09-d-phase-4e-c1d-region-layer-dispatch-design.md](2026-05-09-d-phase-4e-c1d-region-layer-dispatch-design.md)
    — frozen successor design.
  - [notes/2026-05-25-l-phase-8-checkpoint.md](2026-05-25-l-phase-8-checkpoint.md)
    — checkpoint whose "next lane" recommendation pointed here.
