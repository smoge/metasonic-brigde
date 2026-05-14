# Phase 4.E C1d Region-Layer Dispatch Design

Date: 2026-05-09
Status: Design contract. No runtime C1d code should land before this
contract is implemented in small, test-gated slices.
Scope: Future C1d region-layer worker dispatch inside one
`ScheduleFreeLayer` / `GlobalScheduleEntry`. This follows C1c, which
dispatches whole global schedule entries.

## 1. Problem Statement

C1c dispatches at the `GlobalScheduleEntry` level:

```text
(template_id, instance_slot, schedule_step)
```

That works when useful parallelism comes from several instances or
templates in the same global Free band. The current corpus now exposes a
different shape: a single global entry whose `ScheduleFreeLayer` contains
multiple independent regions. The survey labels this as C1d candidate
surface (`dirC1d` / `redC1d`) so it is not confused with actual C1c
worker-dispatch counters.

Today C1c processes that entry as one unit, so a row such as:

```text
one instance
  one FreeLayer step
    region 0, region 2, region 4
  later barrier sink
```

does not enter worker dispatch even though the regions in the layer are
independent by the Haskell planner's `regionDependencies` result.

C1d asks whether the runtime can split that one entry into region work
items safely:

```text
(template_id, instance_slot, schedule_step, item_index, region_ordinal)
```

The answer is "yes, for a narrow v1 shape, after more metadata and
tests." The first C1d implementation should be sink-free only. Sink
writers inside a same-instance FreeLayer raise additional peak and
writer-slot reduction concerns; those stay gated until explicit tests
exist.

## 2. Non-Goals

C1d must not change these policies:

- No public worker-scheduling switch.
- No default-on worker dispatch.
- No live-bus barrier relaxation.
- No runtime block-rate execution.
- No parallel execution of sink-bearing direct-mode work.
- No policy claim based on timing without worker-dispatch counters.

C1d is a finer dispatch granularity for already-free `FreeLayer` regions.
It is not a new scheduler and it does not rerun dependency analysis on
the audio thread.

## 3. Equivalence Target

C1d output must be bit-identical to the existing global-schedule serial
executor.

The serial reference order is:

```text
template_id ascending
instance_slot ascending
schedule_step ascending
region item order inside schedule_step_regions
node order inside each region
```

For sink-free C1d v1, bit-equivalence mostly means:

- each region writes the same per-node buffers it wrote serially;
- every later consumer runs only after the full FreeLayer join;
- instance lifecycle starts once before the block and finishes once after
  all bands, exactly as in C1c;
- no worker mutates shared per-instance lifecycle fields.

For any later sink-bearing C1d variant, equivalence also includes
canonical writer-slot order and `block_sink_peak` reduction. That is out
of v1 scope.

## 4. Current Substrate

Already available:

- Haskell loaders ship per-template `ScheduleStep` metadata through
  `rt_graph_template_add_schedule_step`.
- A step stores an indirect list of scheduled-region ordinals in
  `MetaDef::schedule_step_regions`, so non-contiguous layers such as
  `{0, 2}` survive the FFI.
- `build_global_schedule` builds canonical per-block entries and assigns
  each entry a writer-slot range:

```text
GlobalScheduleEntry {
  template_id,
  instance_slot,
  step_index,
  first_writer_slot,
  writer_slot_count
}
```

- `build_global_schedule_bands` groups entries into barrier and Free
  bands while preserving canonical entry order.
- C1c hoists instance lifecycle to the audio thread:
  `begin_global_schedule_instance_blocks` before the band loop and
  `finish_global_schedule_instance_blocks` after it.
- The worker pool dispatch primitive is atomic and allocation-free on
  the audio thread.

C1d should reuse all of that. It should not add graph allocation or
thread creation to `process_graph`.

## 5. New Work Unit

C1d introduces a runtime work item:

```cpp
struct RegionLayerWorkItem {
  int global_entry_index;
  int template_id;
  int instance_slot;
  int step_index;
  int item_index;       // index inside this ScheduleStepSpec item slice
  int region_ordinal;   // ordinal into MetaDef::regions
  int first_writer_slot;
  int writer_slot_count;
};
```

For v1 sink-free dispatch, `first_writer_slot` and `writer_slot_count`
will normally be zero-width. They still belong in the structure from the
start because the range is part of the canonical identity for any future
sink-bearing reduction path.

Capacity must be reserved outside the audio callback, following the same
pattern as `ensure_global_schedule_capacity`:

```text
required_region_work_items =
  sum over templates t of
    max(def[t].polyphony, occupied_t)
      * sum(step.item_count for step in def[t].schedule_steps)
```

The per-block builder may then `clear()` and `push_back()` into already
reserved storage.

## 6. Writer-Slot Assignment

C1c assigns one writer-slot range per `GlobalScheduleEntry`. C1d needs
subranges for the regions inside that entry.

For each entry:

```text
slot = entry.first_writer_slot
for item in step.items:
  region = def.regions[item.region_ordinal]
  item.first_writer_slot = slot
  item.writer_slot_count = region_sink_writer_count(def, region)
  slot += item.writer_slot_count
```

This preserves the existing canonical order:

```text
entry order, then step item order, then sink order inside the region
```

The audio thread must not use an atomic shared writer-slot counter. The
range is deterministic metadata, not a runtime allocation.

## 7. Eligibility Rules

V1 C1d can dispatch a region-layer work item group only when all of the
following are true:

- the parent band is `Free`;
- the parent `ScheduleStepSpec` is `FreeLayer`;
- at least one parent entry contains two or more region items;
- worker pool logical size is greater than one;
- every dispatched region item is sink-free;
- the step has no shared-write hazards (automatically true for sink-free
  v1);
- no metadata-free template fallback is active.

If a FreeLayer contains sink writers:

- direct mode serializes the whole entry;
- reduction mode also serializes in v1 unless a later slice adds
  per-region peak reduction and explicit sink equivalence tests.

This conservative rule is intentional. The current fixed corpus has
`redC1d=0`, so there is no representative evidence requiring
sink-bearing C1d yet.

## 8. Same-Instance Safety

C1d deliberately allows multiple regions from the same instance to run
at the same time, but only when they are members of the same
`FreeLayer`.

Safe in v1:

- distinct regions own distinct node output buffers;
- distinct regions own distinct node DSP state;
- reads of controls and constants are immutable for the block;
- later consumers wait for the FreeLayer join.

Unsafe unless separately handled:

- multiple sink regions in one instance updating `inst.block_sink_peak`;
- multiple sink regions mutating shared bus storage in direct mode;
- any future region kind that mutates shared instance-level state outside
  its own node states.

Therefore v1 C1d stays sink-free. A sink-bearing C1d variant needs
per-work-item peak accumulation and post-join max reduction before it can
be correct.

## 9. Join Points

The join-before-next-band invariant is unconditional.

For C1d, the audio thread must wait for all region work items in the
current dispatched layer before any of these run:

- a later region item in a later `ScheduleStep`;
- a barrier step;
- another Free band;
- end-of-block hardware copy;
- `finish_global_schedule_instance_blocks`.

This is stricter than only joining before barriers. A later FreeLayer can
read buffers written by an earlier FreeLayer in the same instance, so
Free band -> Free band also requires a full join.

## 10. Implementation Slices

### C1d-a — Metadata and Introspection

Add allocation-free per-block region-work-item storage and test
introspection:

- required capacity helper;
- grow-only reserve at graph/template/schedule-step mutation points;
- per-block builder that maps global entries to region items;
- counters for built item count and candidate/serialized groups.

No executor change.

### C1d-b — Serial Region-Item Executor

Consume the region-item table serially for eligible FreeLayer entries,
but in the same order as `process_schedule_step` uses today.

Gate: global-schedule serial executor and C1d serial item executor are
byte-identical on the full T-9 corpus.

### C1d-c — Sink-Free Parallel Region Items

Dispatch sink-free region items through the existing worker pool.

Gate:

- counter proves region-item worker dispatch actually happened;
- legacy-vs-schedule equivalence still passes;
- direct-vs-reduction equivalence still passes;
- release/free lifecycle remains unchanged.

### C1d-d — Bench and Decision Refresh

Only after C1d-c correctness passes:

- rerun the synthetic C++ schedule bench;
- rerun `--worker-bench`;
- update the worker turn-on decision.

No default-on or public switch without a new decision record.

### C1d-e — Optional Sink-Bearing C1d

Only if the corpus grows `redC1d` signal. Requires:

- per-region writer-slot ranges;
- reduction-deferred slot writes;
- post-layer canonical fold;
- per-work-item `block_sink_peak` accumulation and per-instance max
  reduction;
- explicit same-instance multi-sink tests.

## 11. Required Tests

Minimum tests before any C1d parallel code ships:

- **T-C1d-1.** Metadata table for a non-contiguous FreeLayer such as
  `{0, 2}` builds two region work items in item order.
- **T-C1d-2.** One instance, one sink-free FreeLayer with width 3:
  C1d serial item executor equals global-schedule serial.
- **T-C1d-3.** Same graph with worker pool size 3 enters region-item
  worker dispatch and remains byte-identical.
- **T-C1d-4.** Later barrier reads buffers produced by the parallel
  FreeLayer; join-before-barrier is required and tested.
- **T-C1d-5.** Two consecutive FreeLayers in one instance: join before
  the second FreeLayer is required and tested.
- **T-C1d-6.** Direct-mode sink-bearing FreeLayer serializes and records
  a fallback counter.
- **T-C1d-7.** Release-then-free lifecycle is unchanged when a releasing
  instance has a split FreeLayer.
- **T-C1d-8.** Full Haskell T-9 corpus under schedule execution,
  reduction mode, and worker pool size 3 remains byte-identical.
- **T-C1d-9.** `--worker-bench` reports separate C1c entry counters and
  C1d region-item counters so timing cannot be misread.

## 12. Benchmark Interpretation Rule

C1d should be judged only on rows where counters show that region-item
parallelism actually happened:

```text
c1d_parallel_items > 0
```

Rows where the schedule executor is enabled but no region items dispatch
are useful for overhead observation, not for a positive worker-policy
decision.

## 13. Recommendation

Implement C1d only as the narrow sink-free path described above. The
current data justifies a design and an experimental substrate, not a
public feature. If post-C1d benchmarks still show sub-1.0x speedup on
counter-confirmed rows, keep Phase 4.E worker dispatch test/bench gated
and move attention back to corpus evolution or other roadmap areas.
