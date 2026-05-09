# C1d-a Region Work Item Metadata Review

Date: 2026-05-09
Commit: 410e862 Add C1d region work item metadata
Status: Accepted. No blocking findings.

## Verdict

The C1d-a slice is sound and correctly scoped. It adds descriptive
metadata only: the executor still consumes global schedule bands as
before, while the runtime now also builds a per-region work-item view
that future C1d-b dispatch can consume.

The important boundary properties hold:

- The change is observational in this slice.
- The per-block builder is allocation-free on the audio path.
- Writer-slot subranges are derived from the same region walk as the
  enclosing global-schedule entry totals.
- Capacity follows the same `max(polyphony, occupied)` safety pattern
  as the global schedule and contribution storage.
- Reset clears the new snapshot and counters with the rest of the
  schedule state.

## Checked Invariants

### Writer-Slot Subranges

Each `RegionLayerWorkItem` carries a
`[first_writer_slot, first_writer_slot + writer_slot_count)` subrange.
Those subranges must fit inside the owning `GlobalScheduleEntry`'s
preassigned writer-slot range, stay contiguous in scheduled-region
item order, and sum to the entry total.

This holds because `schedule_step_sink_writer_count` and
`build_region_layer_work_items` iterate the same schedule-step region
items in the same order and apply the same defensive ordinal checks.
The C++ test `region-layer work items: writer slot subranges follow
region order` pins the two-sink-region case.

### Capacity

`required_region_layer_work_items` uses:

```text
sum_t max(def[t].polyphony, occupied_t) * items_per_instance[t]
```

That matches the global-schedule reserve pattern and handles lowering
polyphony below the live instance count. The occupied-count regression
test drives five live instances, lowers polyphony to two, and checks
the reserve still covers all live slots.

### Audio Path

`build_region_layer_work_items` does only `clear()` plus `push_back()`
into pre-reserved storage. Capacity is grown from construction-time
mutation sites that can affect the bound:

- `rt_graph_template_add`
- `rt_graph_template_set_polyphony`
- `rt_graph_template_add_schedule_step`

### Reset

`reset_to_default_state` clears `region_layer_work_items` and resets
the C1d-a counters beside the existing C0/C1 schedule state. The
`clear resets snapshot and counters` test pins this.

### Build Order

The process prelude now runs:

```text
build_global_schedule
build_region_layer_work_items
build_global_schedule_bands
```

That is the right order: C1d-a consumes `entry.first_writer_slot`
from the global schedule, while bands remain independent of the new
region-item view.

### Candidate Counters

The candidate counters are correctly limited to
`FreeLayer && emitted_items > 1`:

- multi-region, sink-free FreeLayer: candidate entry/items
- multi-region FreeLayer with any sink writer: serialized sink entry
- barrier or single-item steps: ignored

This keeps the counters aligned with future C1d-b dispatch decisions.

## Non-Blocking Follow-Up

Add one mixed-shape C++ regression before or during C1d-b:

```text
FreeLayer(region_without_sink, region_with_sink)
```

Expected result:

```text
candidate_entry_count = 0
candidate_item_count = 0
serialized_sink_entry_count = 1
```

The current all-sink-free and all-sink-bearing tests cover the main
branches. The mixed case would specifically pin the `has_sink_writer`
OR logic and prevent a future accidental AND-style regression.

## Net

410e862 is a careful descriptive slice. It pins the canonical
global-entry-to-region-item mapping and writer-slot subranges before
any C1d-b code starts dispatching individual regions.
