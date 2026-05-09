# Deterministic Bus Reduction — Design Note

Date: 2026-05-08
Status: Draft. Precedes any C++ runtime change.
Scope: §4.E.2 next slice. Defines the model independent regions /
templates use to accumulate into shared output buses safely and
deterministically once a worker pool exists.

This note is the contract. Implementation should not begin until the
invariants and the canonical writer order in §3 and §4 are precise
enough that the C++ changes are mechanical rather than exploratory.


## 1. Problem statement

Today, every sink-terminal kernel writes directly into the shared
`g.server.output_buses[bus]`:

  - `process_out` accumulates `dst[i] += s` and tracks
    `inst.block_sink_peak` ([rt_graph.cpp:2607](../tinysynth/rt_graph.cpp#L2607)).
  - `SinkAccumulator` does the same from inside fused sink-terminal
    region kernels (`SinGainOut`, `SawLpfGainOut`,
    `BusInLpfGainOut`, etc.) ([rt_graph.cpp:3014](../tinysynth/rt_graph.cpp#L3014)).
  - `process_graph` runs the whole loop serially: per-block
    `swap(output_buses, output_buses_prev)` + zero, then templates
    in registration order, then instances in slot order, then
    regions/nodes in scheduled order ([rt_graph.cpp:4248](../tinysynth/rt_graph.cpp#L4248)).

The compile-time substrate already classifies which work is free to
move: `BusFootprint`, `regionDependencies`, the live-bus barrier
predicate, `regionSchedule`, `layeredRegionSchedule`, and
`SharedWriteHazard` ([Dependencies.hs:106](../src/MetaSonic/Bridge/Compile/Dependencies.hs#L106), [Schedule.hs:99](../src/MetaSonic/Bridge/Compile/Schedule.hs#L99)).
The descriptive plan exposes free layers and flags layers where two
or more regions would write the same bus
([Schedule.hs:546](../src/MetaSonic/Bridge/Compile/Schedule.hs#L546)).

What is missing is the runtime-side answer to: when two writers
that both target bus `b` are scheduled to run in parallel — across
parallel template layers, across parallel instances of the same
template, or eventually within an instance once the live-bus
barrier policy relaxes — how do their contributions reach
`output_buses[b]` without a race and without changing the
floating-point result the current serial executor produces? That
is the question this note pins down. The first real contention
shows up cross-template and cross-instance; intra-template
contention is currently prevented by the §4.E.1c barrier policy
(every `KOut` / `KBusOut` region is a barrier), and lifting that
is a later relaxation — see §8.

The answer is *not* "atomic float adds" or "mutex-protected shared
bus writes". Both either lose deterministic order (atomics) or
serialize the contended path enough to erase the parallelism gain
(mutex). The chosen model is **private per-writer-slot
contribution buffers + a serial reduction pass at well-defined
join points**.

**v1 scope.** v1 builds the deterministic reduction substrate
and may parallelize only bus-independent compute bands;
parallel bus writers wait for the Phase D / I-4 relaxation. The
contention surface described in this section is the *eventual*
target — v1 serializes all of it and exercises the reduction
infrastructure as a serial-equivalent abstraction. See §8 for
why, and Phase D in §9 for what eventually puts parallel load
on the substrate.


## 2. Equivalence target

**Bit-identical** to the current serial executor, where practical.

Bit-equivalence is already the kernel correctness standard in this
project (the fused-region kernels are tested against their unfused
equivalents at the float level). The reduction model must extend
that discipline; floating-point summation order matters.

"Where practical" qualifier: a future relaxation may admit a
deterministic-but-different summation order if measured numerical
divergence is bounded and the project explicitly opts in. That is
out of scope for this note. Until that opt-in exists, treat
bit-identical as a hard requirement and design the reduction so
violating it surfaces as a test failure.

The corollary is the verification gate (§10): a serial-vs-reduction
equivalence test with hand-constructed graphs that have multiple
writers on the same bus, exercising all four sink kernels (`Out`,
`BusOut`, `SinkAccumulator`-using fused kernels) and at least one
cross-template scenario.


## 3. Canonical writer order and writer slots

The reduction must produce the same `output_buses[b][i]` value the
current serial executor produces, sample by sample, bit by bit. The
serial executor visits writers in a fixed nested order; the
reduction restates that order as the addition order on every bus.

**Canonical order (innermost varies fastest):**

  1. Template registration order. `g.defs[0]` first, then
     `g.defs[1]`, … Set by `compileTemplateGraph`'s topo-sort over
     template precedence on the Haskell side.
  2. Instance slot order within a template. `g.instances[0..N)` in
     index order, filtered to `template_id == tid` and
     `state ∈ {Active, Releasing}`. Slot order is implicit in
     `rt_graph_template_instance_add` calls; the runtime never
     reorders.
  3. Scheduled region ordinal within an instance — the position in
     the order the runtime actually executes regions in. Today
     this equals `rrIndex` order because `regionSchedule` is the
     identity over `rrIndex`, but the canonical identity is
     defined in terms of *executed-position ordinal*, not
     `rrIndex`. If `regionSchedule` ever becomes non-identity, the
     ordinal moves with it; canonical order tracks execution, not
     source numbering.
  4. Per-region sink-writer ordinal:
     - Unfused region: position in the per-region node list,
       filtered to sink-terminal nodes (`Out`, `BusOut`).
     - Fused sink-terminal kernel: a single writer at the kernel's
       position in the region's executed order.

A *writer slot* is identified by the tuple
`(template_id, instance_slot, scheduled_region_ordinal, sink_ordinal_within_region)`.
The lexicographic ordering of those tuples is the canonical writer
order.

**The writer slot is the keyed reduction unit, not the work unit.**
A work unit (one region, §6) can hold zero, one, or more writer
slots — an unfused region with two `Out` nodes targeting the same
bus produces two writer slots, and bit-equivalence requires that
each slot's contribution be folded separately. The serial executor
performs `dst[i] += a; dst[i] += b`; pre-summing inside the work
unit to `dst[i] += (a + b)` is mathematically equivalent but not
IEEE-754 equivalent. The contribution table (§5) is therefore
keyed by writer slot, not by work unit.

The reduction phase walks writer slots in canonical order and adds
each slot's frame buffer into the shared bus. This produces the
same sequence of `+=` operations the serial executor performs
today.

Two correctness preconditions for that match, both required:

  1. **Write/write order.** Writer-slot keying + canonical-order
     reduction (this section) — fixes the case where two writers
     target the same bus and would race on `+=`.
  2. **Read-after-write order.** The global block schedule
     (§9 Phase C0) ensures that any live `BusIn` reads
     `output_buses[b]` only after every canonically-earlier
     writer slot has been reduced into it (I-10).

Writer-slot keying alone is not sufficient: parallelizing two
steps where one reads a bus the other writes would still race,
even though no two writers race. The two mechanisms are
orthogonal and both ship in v1.

Notes:

  - `block_sink_peak` (§7) is per-instance, not per-bus. It is
    reduced per-instance (max over that instance's writer slots),
    not as part of the shared-bus pass.
  - `BusInDelayed` reads from `output_buses_prev` and is never a
    writer. It does not participate in the reduction. Its read
    sees the previous block's reduced result, which is the same
    snapshot the serial executor saw.


## 4. Invariants

Implementation must preserve every invariant below. These are the
contract any reduction or scheduler change is checked against.

**I-1.** No allocation on the audio thread. The contribution
table is pre-sized at graph load time as
`max_writer_slots × max_frames` floats plus `O(max_writer_slots)`
metadata (§5). Resizing follows the same path as
`ensure_output_bus_count` ([rt_graph.cpp:1916](../tinysynth/rt_graph.cpp#L1916)) — outside the
audio callback, under the existing quiescent-graph protocol.

**I-2.** No locks on the bus accumulation path. The reduction
model uses private per-writer-slot buffers; the `+=` into
`output_buses[b]` is single-writer (the reduction phase) and
takes no lock. Worker-pool coordination — layer dispatch and
completion signaling — may use realtime-safe primitives
(preallocated, lock-free or wait-free, no per-block allocation),
but those primitives must not block the audio thread on contended
state. Readers of `output_buses[b]` (next-layer `BusIn`
consumers, the hardware copy at block end) only run after the
relevant reduction join completes.

**I-3.** Bit-identical to the serial executor under any schedule
the §4.E.1c policy permits. See §2.

**I-4.** Live-bus barrier regions are immovable
(`regionHasLiveBus`). They retain their canonical scheduled
position in the global block schedule — today this equals
`rrIndex` order because `regionSchedule` is the identity, but
the invariant is stated in terms of the scheduled / global-step
ordinal so a future non-identity `regionSchedule` doesn't
silently break it. They are never parallelized across thread
boundaries, and the reduction pass at any prior join must
complete before they execute. This is required because their
bus controls can be redirected at runtime via
`rt_graph_instance_set_control`, and the static footprint is no
longer authoritative.

**I-5.** Static `BusFootprint` is a *plan* artifact, not the
runtime authority. The reduction's actual target bus index for any
contribution is the runtime-resolved value of `node.controls[0]`
(or the equivalent fused-kernel control), validated under the same
finite/range rules `process_out` uses today
([rt_graph.cpp:2620](../tinysynth/rt_graph.cpp#L2620)). Mismatches between footprint and resolved index do
not cause incorrect reduction; they only cause that contribution to
land on a different bus than the planner predicted, the same way it
does in the serial executor.

**I-6.** Contributions with an invalid resolved bus index
(non-finite, negative, out-of-range) are dropped, matching
`process_out`'s silent-degradation discipline. They contribute
nothing to any bus, do not advance any peak counter, and do not
appear in the reduction.

**I-7.** Determinism across runs. The same graph and the same
input controls produce the same `output_buses` bytes after
reduction. This forbids any reduction step that depends on thread
arrival order, work-stealing order, or atomic-FP commutativity.

**I-8.** `BusInDelayed` semantics unchanged. It reads
`output_buses_prev[b]`. The previous block's reduction must have
finalized into `output_buses` before the per-block swap, after which
the swapped vector becomes the next block's `output_buses_prev`.

**I-9.** `block_sink_peak` is per-instance and monotonic-max within
a block. Parallel sink execution in the same instance must use a
work-private peak accumulator and reduce with `max`. The
release/free path ([rt_graph.cpp:4297](../tinysynth/rt_graph.cpp#L4297)) reads `inst.block_sink_peak`
*after* the instance's contributions have all been folded.

**I-10.** Read-after-write order across instances and templates.
A live `BusIn` (`KBusIn`) in schedule step S must observe
contributions from every writer slot whose canonical position
precedes S, where canonical position follows §3's ordering across
templates, instances, and per-template scheduled regions.
Equivalently: the reduction folding all earlier-canonical writer
slots into `output_buses[b]` must complete before any step
containing a live `BusIn` of bus `b` runs. The global block
schedule (§9 Phase C0) enforces this by serializing any pair of
steps where one reads a bus the other writes in canonical-earlier
position; writer-slot keying alone fixes write/write races but
not read-after-write ordering, so this invariant is not
subsumed by I-3.


## 5. Contribution storage

A *contribution* is a per-block, per-writer-slot, per-frame
buffer. The bus index is per slot, resolved once per block from
the slot's sink node's `node.controls[0]` — a sink writes one bus,
not many.

**Decision: identity is implicit, slot-keyed.** Each writer slot
owns a contiguous slot in a pre-sized contribution table. The
slot index *is* the canonical-order position. There is no
per-block allocation, no metadata struct stored alongside the
floats, and no sort during reduction.

Storage layout (one block):

```
contributions:        float[max_writer_slots][max_frames]
contribution_target:  int  [max_writer_slots]   // resolved bus per slot
                                                // (-1 = invalid / no contribution)
contribution_used:    bit_set indexed by writer slot
```

`contributions[ws]` is the contribution buffer for writer slot
`ws`. The owning work unit zeroes it on entry. A slot whose work
unit didn't run this block keeps its old contents, but the
`contribution_used` bit will not be set, so the reduction ignores
it. `contribution_target[ws]` records the resolved bus index for
slot `ws`, set when the work unit resolves `node.controls[0]` for
that sink. The reduction phase walks `ws = 0 .. total_writer_slots`
in order; for each used slot it adds `contributions[ws][..]` into
`output_buses[contribution_target[ws]][..]`.

The layout is dense in slots, not in (slot × bus) — a 2-D bus
dimension would only matter if a single sink could write multiple
buses, which no kind does.

**Capacity sizing.** `max_writer_slots` is the maximum the current
ensemble can produce, summed across templates and their instance
pools:

```
max_writer_slots = sum over templates t of
                     (def[t].polyphony × sink_writer_count[t])
```

`def[t].polyphony` is the per-template polyphony cap already
carried by `MetaDef` ([rt_graph.cpp:883](../tinysynth/rt_graph.cpp#L883))
and set via `rt_graph_template_set_polyphony`
([rt_graph.h:117](../tinysynth/rt_graph.h#L117));
`sink_writer_count[t]` is the count of sink-terminal `NodeSpec`s
in template `t`'s nodes — those with
`kind ∈ {Out, BusOut}` — independent of how regions are formed.
This is the canonical definition because the runtime supports
both region-driven dispatch and a regionless flat fallback (when
`def->regions.empty()`, see [process_instance](../tinysynth/rt_graph.cpp#L4179));
the latter reserves one writer slot per `Out` / `BusOut`
`NodeSpec` directly through `dispatch_node`. Sizing from the
scheduled region sequence alone would under-size for graphs
built directly via `rt_graph_add_node` without going through the
loaders. Region / kernel metadata still maps slot ranges
(buffer-terminal regions reserve zero, sink-terminal fused
regions reserve one, NodeLoop regions reserve one per
sink-terminal member), but the *total* count is per-`NodeSpec`.
`sink_writer_count[t]` is constant per template once compiled.
Allocation happens at template registration / polyphony change
time, not on the audio thread. Resizing follows the same
quiescent-graph protocol as `ensure_output_bus_count`
([rt_graph.cpp:1916](../tinysynth/rt_graph.cpp#L1916)).

**Memory cost.** With `max_writer_slots = S` and `max_frames = F`,
storage is `S × F × 4` bytes plus `O(S)` metadata. For ensembles
with `S ≤ 256` and `F = 1024` that is 1 MB. The bound that matters
is `S`, not `W × B`: under the current barrier policy, every
sink-terminal region is a barrier, so the polyphony driver is the
only multiplier — sink writers from independent voices, not
within-voice fan-out. If the live-bus barrier is later lifted,
intra-instance multiple sinks add a small linear factor.

**Why writer-slot keyed beats work-unit keyed:**

  - A work unit with two sinks to the same bus would, under
    work-unit-keyed storage, accumulate `a + b` into one buffer
    and then reduce `dst[i] += (a + b)`. That changes rounding
    versus the serial executor's
    `dst[i] += a; dst[i] += b`, violating I-3.
  - Slot-keyed storage preserves each `+=` as a separate reduction
    step in canonical order.

**Why implicit identity beats stored identity:**

  - Stored identity (e.g., `struct Contribution { tuple id; float
    buf[]; }`) still needs a pre-sized array; it adds a sort
    during reduction and metadata bookkeeping for no benefit over
    implicit identity.
  - The implicit form maps directly to canonical order — walk the
    table in linear slot index order and that *is* canonical-tuple
    order, by construction of the slot assignment (§6).

**Why not write directly to `output_buses` from each work unit:**

  - Two work units in the same free layer that target the same bus
    race on `+=`. Even if the race is benign-ish (atomic FP add),
    summation order is non-deterministic, which violates I-3 and
    I-7.
  - Mutex-per-bus serializes the contended path and is worse than
    not parallelizing.


## 6. Work units, writer slots, and index assignment

Two related but distinct indexings:

  - **Work unit index.** A *work unit* is the smallest item the
    scheduler hands to a worker. For this slice it is **one
    scheduled region per work unit**. Smaller (per node) is too
    fine for the work-stealing overhead; larger (per instance,
    per template) loses parallelism. The scheduler dispatches by
    work unit; its index follows canonical work-unit order
    (§3 items 1-3).
  - **Writer slot index.** A *writer slot* is one sink-terminal
    writer (an `Out` / `BusOut` node, or the sink-terminal write
    inside a fused kernel). The contribution table (§5) is keyed
    by writer slot. A work unit owns a contiguous slot range
    `[wu.first_slot, wu.first_slot + wu.slot_count)`.

Both indices are assigned once per block, in canonical order.
Assignment runs on the audio thread after the slot-state snapshot
in `process_graph`:

```
wu_index   = 0
slot_index = 0
for tid in 0 .. template_count:
    for inst_slot in active_instances_of(tid):   // slot order
        for region in scheduledRegions(inst):    // executed order
            work_units[wu_index] = WorkUnit{
              tid, inst_slot, region,
              first_slot = slot_index,
              slot_count = sink_writers_in(region)
            }
            slot_index += sink_writers_in(region)
            wu_index   += 1
total_writer_slots = slot_index
```

The reduction walks `slot_index = 0 .. total_writer_slots`, which
by construction is canonical writer order. The scheduler walks
`wu_index = 0 .. wu_count`; multiple workers may run work units in
parallel within a free layer, but each writes into its own
contiguous slot range, and the reduction folds in slot order
regardless of completion order.

Cost: O(active_slots × regions_per_instance), once per block.

**Slot count per region** maps the per-`NodeSpec` total
(§5 `sink_writer_count[t]`) onto the dispatch shape. It is a
property of the region's kernel choice, not of runtime state, so
it is a constant computed at graph load:

  - NodeLoop region (unfused): count of `Out` / `BusOut`
    `NodeSpec`s in `rrNodes`.
  - Fused sink-terminal kernel: 1.
  - Buffer-terminal kernel (no sink): 0.

For the regionless flat-fallback path (templates built via
`rt_graph_add_node` without registered regions), each `Out` /
`BusOut` `NodeSpec` reserves one slot directly through
`dispatch_node`; there is no enclosing region. The §5 capacity
formula already covers this case because it counts `NodeSpec`s,
not regions. Recording per-region slot counts on each
`RuntimeRegion` (or its C++ counterpart) is a small
Phase-A-companion change for the region-driven path.

**Instance lifetime.** The instance vector is sparse (slots go
`Active → Releasing → Available`). Re-deriving the work-unit and
slot tables every block from the snapshot avoids any cross-block
compaction problem; for the schedule sizes the project targets,
this is negligible. The audio-thread state required is just
"which slots are Active/Releasing right now", which is already
snapshotted at the top of `process_graph` ([rt_graph.cpp:4283](../tinysynth/rt_graph.cpp#L4283)).


## 7. `block_sink_peak` reduction

`block_sink_peak` cannot be written from multiple threads without a
race. The serial executor relies on the fact that every node in an
instance runs on the audio thread in topological order, so every
peak update sees the previous one. Parallelizing within an instance
breaks that.

**Decision: per-work-unit private peak, reduced per-instance with
`max`.**

Each work unit maintains a private `float local_peak` while it
runs. When the work unit completes, it stores `local_peak` into a
per-instance peak slot:

```
work_unit_local_peak: float[work_unit_count]
```

After all work units belonging to instance `i` have completed (this
is a join point — instance-end synchronization), the reduction
phase computes:

```
inst.block_sink_peak = max(work_unit_local_peak[wu]
                           for wu in work_units_of(i))
```

`max` is associative and commutative; reduction order does not
affect the result. This is one of the few places where reduction
order does *not* need to follow canonical order, by virtue of the
operation being associative-commutative on the float domain. (Sum
is associative-commutative algebraically but not at IEEE-754
precision; max is.)

The release/free path at [rt_graph.cpp:4297](../tinysynth/rt_graph.cpp#L4297) reads
`inst.block_sink_peak` after the instance is fully complete; this
remains correct.


## 8. Reduction barriers (join points)

The reduction phase that folds `contributions[*][b][..]` into
`output_buses[b][..]` must run *before* any of:

  **B-1.** Any subsequent `BusIn` (live-bus read, not delayed) of
  bus `b` whose canonical position is after the parallelized
  layer's. This includes:
    - Later regions in the same instance reading bus `b`.
    - Later instances (same or different template) reading bus `b`.
  In practice the §4.E.1c barrier policy already pins live-bus
  regions at their compile positions, so the join point sits between
  the free layer ending and the next barrier (or the next free
  layer that depends on bus `b`, identified via `regionDependencies`).

  **B-2.** Any later free layer that has a `regionDependencies`
  edge into a region in the just-completed layer. The reduction is
  serial; the next free layer waits.

  **B-3.** The end-of-block hardware copy in
  `GraphAudioStream::process` ([rt_graph.cpp:4336](../tinysynth/rt_graph.cpp#L4336)). All reductions
  must be finalized before that copy reads `output_buses`.

  **B-4.** The next block's `swap(output_buses, output_buses_prev)`
  at the top of `process_graph` ([rt_graph.cpp:4264](../tinysynth/rt_graph.cpp#L4264)). The swap is the
  publication point that turns this block's `output_buses` into
  the next block's `output_buses_prev`, which `BusInDelayed` will
  read. By construction this is after B-3.

**Where reduction actually contends — and what v1 chooses to do
about it.** Under the §4.E.1c barrier policy plus I-4, every
`KOut` and `KBusOut` region is a live-bus barrier and v1 never
dispatches them in parallel. The genuine contention sources for
the reduction model are:

  - **Cross-instance, same-bus.** Two `Active` instances of the
    same template (or of writer-disjoint templates that happen
    to write the same bus). The serial executor walks instance
    slots in order; a future worker pool that runs them in
    parallel needs slot-ordered reduction.
  - **Cross-template, same-bus.** The serial executor walks
    templates in registration order; parallelizing at template-
    layer granularity needs template-registration-ordered
    reduction across the writers.
  - **Intra-instance multiple sinks** (only after lifting `KOut`
    / `KBusOut` off the barrier path — the static-bus
    annotation relaxation noted in `Note [Region barrier
    policy]`).

**v1 chooses to serialize all three.** The global schedule
(Phase C0) places every live-bus step in canonical order on the
audio thread. The reduction infrastructure folds each step's
writer slots into `output_buses` immediately after the step
runs, on the same thread. No race exists because there is no
parallel writer; the infrastructure is in place purely as a
serial-equivalent abstraction whose bit-equivalence on every
sink write is what Phase B verifies.

The Phase D candidate "lift I-4 for writer-only live-bus steps"
is what eventually exploits the reduction infrastructure for
real parallelism. v1 builds the substrate; v2 (Phase D) puts
load on it.

The conservative join policy: reduce **after every schedule step
that produced writer slots**. That includes free-layer steps
(parallel work units in the layer) *and* barrier steps that
contain a sink-terminal region (`KOut` / `KBusOut`). Reducing
after barriers is not optional: a subsequent step — barrier or
free layer — may contain a live `BusIn` that reads a bus the
barrier just wrote, and skipping the post-barrier reduction would
make that live read see `output_buses` contents from before this
block's writes were applied.

A more aggressive variant — defer reduction past a step boundary
until a downstream reader actually demands the bus — is a Phase
D candidate; do not do it in v1. The contribution table is sized
for the whole block (§5), so deferral does not help capacity, only
work.


## 9. Phased implementation plan

Each phase ships independently and is verifiable in isolation.

### Phase A — Bus-write abstraction (no behavior change)

Refactor the four kernel sites that touch `output_buses[b]`:

  - `process_out` ([rt_graph.cpp:2607](../tinysynth/rt_graph.cpp#L2607)).
  - `SinkAccumulator::push` ([rt_graph.cpp:3038](../tinysynth/rt_graph.cpp#L3038)) and the
    sink-terminal fused region kernels that use it.
  - The non-fused dispatch site ([rt_graph.cpp:4204](../tinysynth/rt_graph.cpp#L4204)) inherits the
    `process_out` change automatically.

Introduce a small abstraction `BusWriteTarget` that resolves to:

  - `&g.server.output_buses[b]` in serial mode (current behavior),
    or
  - `&contributions[writer_slot]` in reduction mode, where
    `writer_slot` is the canonical-order index assigned to this
    sink for this block (§6) and the resolved bus index `b` is
    written into `contribution_target[writer_slot]` so the
    reduction phase knows where to fold.

In this phase the reduction-mode path is gated off (a compile-time
flag or always-false runtime branch). All existing tests must pass
with byte-identical output. This phase is purely a refactor.

### Phase B — Contribution storage + serial reduction

Add the `contributions` table and the work-unit / writer-slot
canonical-index assignment (§6). Run the audio loop entirely
single-threaded but route all sink writes through the
reduction-mode path: per work unit, write to private contribution
buffers; after every schedule step that produced writer slots
(§8 — including barrier steps with sinks), fold contributions
into `output_buses` in canonical order.

This phase has no threading. Its correctness gate is: serial-mode
output and reduction-mode output are bit-identical. Any divergence
is a reduction-order bug, not a threading bug, which makes it
debuggable.

Phase B also exercises §7 (`block_sink_peak` reduction) — even
single-threaded, the work-unit-local peak path replaces the
read-modify-write into `inst.block_sink_peak`.

### Phase C0 — Global block schedule and layer-aware loader

Today the loader hands the runtime a flat list of regions in
scheduled order via `scheduledRuntimeRegions`. The descriptive
layer / barrier metadata (`ScheduleStep`, `FreeLayer`,
`SharedWriteHazard`) lives only on the Haskell side and is not
shipped across the FFI. More importantly, that metadata is
*per-template*, not per-block: it does not say which schedule
steps across different instances or different templates are
allowed to run concurrently. Phase C without that information
cannot honor I-10.

Phase C0 builds and ships a **global block schedule**: an
ordered sequence of schedule steps over the cross product of
(template, active instance, per-template schedule step). It
answers three questions Phase C cannot answer from per-template
metadata alone:

  1. Where the layer boundaries are.
  2. Where to insert reduction joins (per §8: after every step
     that produced writer slots).
  3. Which units may run concurrently without violating I-10
     (read-after-write ordering across instances and templates).

The global schedule is constructed on the audio thread once per
block, after the slot-state snapshot, in canonical order:

```
global_schedule = []
for tid in 0 .. template_count:                  // canonical (§3.1)
    for inst_slot in active_instances_of(tid):   // canonical (§3.2)
        for step in template_schedule(tid):      // canonical (§3.3)
            global_schedule.append(GlobalStep{tid, inst_slot, step})
```

A `GlobalStep` is "barrier" iff the underlying template step
contains any live-bus node (`KBusIn`, `KOut`, `KBusOut`).
Otherwise it is "free" — a buffer-terminal compute step, a
candidate for parallel dispatch. (The "sink-terminal write" case
is not a separate condition: `KOut` and `KBusOut` are live-bus
kinds and already barrier under I-4.)

**v1 parallelism rule (conservative).** Two `GlobalStep`s may
run concurrently only if *all* of the following hold:

  - Both are typed "free" — i.e. buffer-terminal compute, no
    live-bus node anywhere in either step.
  - Neither has a `regionDependencies` edge into the other.
  - They sit within the same global free band — a maximal run
    of free `GlobalStep`s with no barrier between them.

**v1 explicitly does not parallelize any step containing a
live-bus node.** Cross-instance and cross-template same-bus
writers are serialized in canonical order; the reduction
infrastructure (§5) still folds their contributions, but it
does so on a single thread. That relaxation is the work of
Phase D — see the new candidate added there. This keeps v1's
correctness story narrow: parallelism comes from compute
regions only, and the reduction infrastructure is exercised
purely as a serial-equivalent abstraction whose bit-equivalence
gate (Phase B) does not depend on any threading.

The FFI extension required:

  - An ordered list of schedule steps per template, with each
    step typed as barrier or free layer (regions list).
  - The per-region sink writer count (§6), so writer-slot
    capacity can be computed without the runtime re-deriving it.
  - A predicate per step indicating whether it contains a live
    `BusIn` read, plus the bus indices it writes — so the
    global-schedule builder can mark `GlobalStep`s and apply the
    parallelism rule without re-running dependency analysis on
    the audio thread.

**Static bus metadata is survey/diagnostic in v1, not scheduler
authority.** The bus indices shipped with each step are
compiled from `BusFootprint`, which is built from compile-time
`rnControls[0]` values. `rt_graph_instance_set_control` can
redirect a `KBusOut` / `KBusIn` / `KOut` bus index at runtime,
so the static metadata stops being authoritative the moment any
live-bus control is changed. v1 sidesteps the problem by never
parallelizing live-bus steps (I-4); the static metadata is used
only to *classify* steps as barrier vs free, not to decide
which buses two parallel free steps interact on. A free step
under v1 contains no live-bus node by construction (§9 Phase
C0's barrier rule), so the static metadata's accuracy on bus
indices does not affect the parallelism decision.

The Phase D relaxation that parallelizes writer-only live-bus
steps cannot rely on the static metadata. It must resolve bus
controls per block from the runtime `node.controls[0]` (the
same source `process_out` reads) before applying the
parallelism predicate, matching I-5. This is why the
relaxation is gated to Phase D and not folded into v1's rule.

This phase has no behavior change: the new metadata is loaded
and the global schedule is built each block, but the executor
still walks `GlobalStep`s in flat canonical order. The gate is
that the Phase B serial-vs-reduction equivalence test still
passes with the new loader and global-schedule path active.

### Phase C — Layer-parallel worker execution

Depends on Phase C0. With the global schedule in place, the
executor consumes `GlobalStep`s in canonical order. For each
maximal run of "free" steps eligible under the v1 parallelism
rule (Phase C0):

  1. Hands eligible work units to workers.
  2. Joins on layer completion (every work unit in the run has
     finished; for free steps under v1 this means buffer-terminal
     compute output is settled — there are no contribution
     buffers to reduce, since live-bus steps run serially).
  3. Proceeds to the next eligible run, or to a serial step.

Live-bus steps (any step containing `KBusIn` / `KOut` /
`KBusOut`) execute serially on the audio thread in canonical
`GlobalStep` order. Their writes go through the reduction
infrastructure built in Phase B for correctness uniformity, but
the contribution table is folded immediately after each such
step (§8 join policy) on the same thread. Single-work-unit
"free" steps also run on the audio thread directly, bypassing
the worker hand-off. The worker pool is sized once at audio
start (Q-2); no thread creation on the audio path.

The bit-identity gate from Phase B carries forward: with the
worker pool active, output must still match the serial executor.

### Phase D — Reduction policy refinements (optional)

Only after C is correct and benchmarked. Candidates:

  - **Lift I-4 for writer-only live-bus steps.** Allow `KOut` /
    `KBusOut` steps that contain no `KBusIn` (i.e. write-only,
    no in-step live read) to be dispatched in parallel under
    the global schedule. Requires per-block runtime resolution
    of bus controls inside the Phase C0 parallelism predicate
    so the predicate uses the same authoritative bus indices
    the contribution table uses (I-5). Enables the parallel-
    dispatch variants of T-2 / T-3 / T-10 / T-11; ships only
    when those tests pass under parallel execution. This is
    the relaxation that puts real load on the reduction
    infrastructure; everything else in this list is
    incremental.
  - Skip reduction for cold contribution slots
    (`contribution_used` bit set is empty for that bus).
  - Defer reduction past a layer boundary if no downstream
    reader in the next layer demands the bus.
  - Parallelize the reduction itself (per-bus partition; each
    bus's canonical-order fold is independent of other buses').

None of these are required for correctness; all of them require
fresh equivalence tests.


## 10. Verification gates

Required before any phase ships:

  - `just stack-test` passes.
  - `just cpp-build` passes.
  - The deterministic C++ CTest subset passes:
    `ctest --test-dir build-cpp --output-on-failure -E
    "start_audio|audio start|clear during a running audio stream|rebuild after clear with active stream|destroy after start_audio"`.
    `just cpp-test` runs the full CTest suite and may reach
    host-audio lifecycle tests, so it is useful as an end-to-end
    probe but not the required per-phase gate on no-audio hosts.
  - The kindTag-agreement and `ugenView` arity properties in
    `test/Spec.hs` pass (already required, listed for
    completeness).

New tests added by this slice (offline — *not* live audio; T-1
through T-8 and T-10 are C++ fixtures with hand-constructed
graphs, T-9 is a Haskell/CLI integration test):

  - **T-1.** Same-bus multi-writer reduction. Two regions in the
    same instance both write bus 0. Compare reduction-mode output
    to serial-mode output sample-by-sample at the float-bit level
    over a 64-block run.
  - **T-2.** Cross-instance reduction. Two instances of the same
    template both write bus 0; instance slots 0 and 1 are both
    Active. Same bit-equivalence assertion. v1 runs both
    instances serially under the global schedule (I-4); the
    test verifies the serial-mode-with-reduction-infrastructure
    output equals the serial-direct-write output. The parallel-
    dispatch variant ships with the Phase D I-4 relaxation.
  - **T-3.** Cross-template read-after-write. Template A writes
    bus 0 via `BusOut`; template B reads bus 0 live (not delayed)
    via `BusIn` in a later registration position. The reduction
    must complete A's writer slots and fold them into
    `output_buses[0]` before B's `BusIn` runs. Same
    bit-equivalence assertion. (Exercises I-10 reduction-before-
    read ordering; T-11 exercises the disjoint write/write case.)
  - **T-4.** `BusInDelayed` correctness. A producer instance writes
    bus 5; a consumer instance reads bus 5 delayed. Verify the
    consumer reads the previous block's reduced value, not the
    current block's.
  - **T-5.** Dynamic bus redirect. A `BusOut` whose
    `node.controls[0]` is changed via
    `rt_graph_instance_set_control` between blocks. Verify
    contributions land on the new bus the block after the
    redirect, and that the barrier policy keeps the redirected
    region in its compile position.
  - **T-6.** Invalid bus paths. A sink whose
    `node.controls[0]` is NaN, negative, or out-of-range
    contributes nothing and does not perturb any other bus or
    peak. Same as `process_out`'s current behavior.
  - **T-7.** Sink peak correctness. An instance with multiple sinks
    in the same and across regions has `inst.block_sink_peak` equal
    to the max over all sinks, regardless of work-unit completion
    order. Drive completion order randomly under a deterministic
    seed; assert peak is invariant.
  - **T-8.** Release-then-free behavior unchanged. A Releasing
    instance whose post-reduction peak crosses
    `kReleaseSilenceThreshold` for `kReleaseSilenceBlocks`
    transitions to Available, exactly as it does today.
  - **T-9.** Serial-vs-reduction-mode bit equivalence on the full
    demo SynthGraph corpus (the same corpus `--fusion-survey`
    walks). Implemented as a Haskell-level integration test: the
    test driver compiles each demo SynthGraph, loads it through
    the FFI in both serial and reduction modes, drives N audio
    blocks of identical input, and asserts byte-identical
    `output_buses` after every block. T-9 lives at the
    Haskell/CLI layer because the demo corpus does — the C++
    fixtures cover T-1 through T-8 and T-10 with hand-constructed
    graphs that don't depend on the demo loader.
  - **T-10.** Same-template, cross-instance live `BusIn`. Two
    `Active` instances of the same template; instance 0 writes
    bus 0 via `BusOut`, instance 1 reads bus 0 live (not delayed)
    via `BusIn`. The serial executor's behavior depends on slot
    order: instance 1's `BusIn` sees instance 0's already-reduced
    contribution. Reduction-mode output must match. v1 serializes
    the two instances under the global schedule (I-4) and the
    test verifies bit-equivalence; the parallel-dispatch variant
    that exercises I-10 under contention ships with the Phase D
    I-4 relaxation.
  - **T-11.** Cross-template same-bus write/write reduction. Two
    independent templates A and B both write bus 0 with `BusOut`,
    no live `BusIn` of bus 0 anywhere in either template. v1
    serializes both `BusOut` steps under I-4 (live-bus barrier);
    the reduction must fold A's contributions before B's in
    template-registration order, bit-equivalent to the serial-
    direct-write executor. The parallel-dispatch variant — A's
    and B's writer steps running concurrently — ships with the
    Phase D I-4 relaxation; until then T-11 is a serial
    bit-equivalence test that exercises canonical writer-slot
    ordering at cross-template granularity, separate from T-3's
    read-after-write case.

Live-audio tests are not the first correctness signal. They are
useful as an end-to-end sanity check after T-1 through T-9 pass,
but a regression that shows up only in live audio is harder to
diagnose than the same regression caught by T-9.


## 11. Rejected approaches

  - **Atomic float adds into the shared bus.** Loses determinism
    of summation order (I-3, I-7). Rejected.
  - **Mutex per bus.** Serializes the contended path and erases
    the parallelism gain. Rejected.
  - **Per-thread shared bus pool, mixed at block end.** Works for
    independent writers but violates canonical order across
    instances of the same template (slot order would depend on
    which thread picked which slot). Rejected.
  - **Stored identity per contribution + sort at reduction.** Works
    but pays a sort and metadata-bookkeeping cost on the audio
    thread for no benefit over implicit identity (§5). Rejected.
  - **Work-unit-keyed buffers (one buffer per work unit, not per
    writer slot).** Bit-equivalence breaks when a work unit
    contains multiple sinks targeting the same bus: the work unit
    pre-sums to `a + b` and the reduction folds that as one
    addition, where the serial executor performs two separate
    `+=` steps. Rejected. (Earlier draft of this note made this
    mistake; preserved here so the reasoning is on record.)
  - **Keying canonical identity by `rrIndex` instead of executed
    region ordinal.** Today the planner is the identity over
    `rrIndex`, so the two coincide; relying on `rrIndex` as the
    canonical key bakes that coincidence into the runtime, which
    breaks bit-equivalence the moment `regionSchedule` produces a
    non-identity order. Rejected; canonical key uses
    `scheduled_region_ordinal` (§3).
  - **Dropping bit-equivalence in favor of "stable but different"
    summation order.** Possibly viable later; explicitly out of
    scope for this slice (§2).
  - **Static-bus annotations to lift barriers.** Mentioned in the
    `Note [Region barrier policy]` haddock as a later relaxation;
    out of scope for this slice. The barrier policy stays as-is.


## 12. Open questions

These do not block starting Phase A but should be answered before
Phase B lands:

  - **Q-1.** ~~Polyphony cap surface.~~ **Resolved.** The
    runtime already exposes `rt_graph_template_set_polyphony`
    ([rt_graph.h:117](../tinysynth/rt_graph.h#L117)) and
    `MetaDef::polyphony`
    ([rt_graph.cpp:883](../tinysynth/rt_graph.cpp#L883));
    Phase B sizes the contribution table from
    `Σ_t (def[t].polyphony × sink_writer_count[t])` directly.
    The default polyphony of `kDefaultPolyphony = 8` applies to
    templates that don't call the setter, matching how the
    voice allocator already enforces the cap. No new ABI knob
    is needed.
  - **Q-2.** Should the worker pool size be a property of the
    graph (compile-time) or of the runtime (env var, set at audio
    start)? Audio-start is more flexible; compile-time is more
    deterministic. Default to runtime, with the size pinned for the
    lifetime of one audio start.
  - **Q-3.** Reduction-order test surface for fused sink kernels:
    do we test each fused kernel's per-sample contribution order
    independently, or only the post-reduction output? The latter is
    sufficient for I-3; the former would catch fused-kernel
    accumulation bugs faster. Recommend post-reduction only in v1
    (T-1 through T-9 cover it), revisit if equivalence flakes.


## 13. Ordering against the roadmap

This note is the prerequisite for [ROADMAP.md §4.E next slice
item 1](../draft/ROADMAP.md#L646) ("Deterministic bus reduction
design"). Item 2 ("Runtime scheduler implementation") is Phase C
above and waits for Phase B. Item 3 ("Bench-driven turn-on") is
the bench work that gates whether Phase C ships defaulted-on or
defaulted-off, and it consumes Phase D's measurements.

No code change in this slice depends on §4.D's rate-region work
landing first. The reduction model does not assume rate
distinction; it operates on `RuntimeRegion`s as the §4.E substrate
already produces them.


## 14. Post-C1c bench decision (2026-05-09)

Phase C has now landed as a test-gated substrate:

  - C0 ships schedule metadata and builds the global schedule.
  - C0c / C1a consume global-schedule bands serially.
  - C1b adds the RTGraph-owned worker-pool scaffold.
  - C1c dispatches eligible Free bands through pre-created workers
    under the test ABI and preserves direct-vs-reduction equivalence
    on the Haskell T-9 corpus.

The bench slice (`2c737ce`) added a schedule-worker section to
`tools/rt_graph_bench.cpp`. The interpretation is recorded in
`notes/2026-05-09-phase-4e-worker-bench-interpretation.md`; the
turn-on decision is recorded in
`notes/2026-05-09-phase-4e-worker-turn-on-decision.md`.

Decision summary: do not turn worker dispatch on by default, do not
expose a public runtime switch yet, and do not start Phase-D
live-bus writer relaxation yet. The only positive bench signal is
sink-free Free-band compute at enough width and block work. Reduction-
backed sink dispatch and send/return dispatch both lose on the
current bench grid, and the worker wake/join primitive still uses a
mutex / condition-variable wait on the audio thread.

This updates §13's "bench work gates whether Phase C ships
defaulted-on or defaulted-off" question: for now, Phase C remains
test/bench gated.

The representative-data refresh added two Haskell-facing checks:

  - `--fusion-survey` now reports corpus worker-band shape. After the
    first corpus-evolution probes, the fixed corpus has `dirC1c=2`,
    `redC1c=0`, `maxSfW=2`, and `maxWork=6`.
  - `--worker-bench` loads demos plus corpus through the Haskell FFI path.
    On the measured run it reported `worker_rows_with_parallel=2`,
    `parallel_bands=2`, and `parallel_entries=6`; the only dispatched
    row was the intentionally multi-instance
    `sched/free-only-parallel-compute` probe, and it lost
    (`best_parallel_worker_speedup=0.68x`).

This strengthens the default-off decision: the synthetic C++ bench has a
positive sink-free signal only at enough width/work, while the first
Haskell-loaded worker-shape probes are still narrow and do not yet show
a win. The `sched/parallel-compute-before-master` probe also exposes a
future C1d question: region-layer FreeLayer width exists before a later
sink barrier, but C1c dispatches whole global schedule entries rather
than individual regions inside one FreeLayer step.
