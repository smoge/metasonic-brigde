#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RTGraph RTGraph;

// ----------------------------------------------------------------
// Thread safety: every entry below carries a "[T:CATEGORY]" tag in
// its comment. Categories and the contract they participate in are
// enumerated in Note [Thread safety contract] in rt_graph.cpp:
//
// Rule of thumb:
//   * Build and reconfigure graphs before audio starts.
//   * While audio is running, use rt_graph_realtime_* from one
//     producer thread for note/control changes.
//   * Read-only helpers are diagnostic; they may be stale during
//     concurrent mutation.
//
//   construction       — mutates shared structure; safe only when
//                        the audio callback is not running
//   control            — mutates per-instance state; safe only when
//                        audio is stopped (one narrow exception:
//                        rt_graph_instance_set_control may write to
//                        a Reserved slot owned by the producer
//                        between _realtime_reserve and _realtime_-
//                        activate)
//   realtime-producer  — A.2 additions; safe to call from a SINGLE
//                        producer thread while audio is running.
//                        Mutation is mediated by the SPSC command
//                        queue drained at the top of process_graph
//   read-only          — reads scalar / atomic fields; may return
//                        stale values during concurrent mutation
//                        but cannot crash
//   bus-read           — copies bus samples; tearable but not racy
//                        on container shape
//   audio-life         — open/close/poll the realtime stream
//   render             — runs process_graph; offline-only when the
//                        audio callback is also running
//   alloc-reset        — cooperate with the audio lifecycle (stop
//                        the stream before mutating state)
// ----------------------------------------------------------------

// ----------------------------------------------------------------
// Lifecycle
// ----------------------------------------------------------------

// [T:alloc-reset] Allocate a fresh runtime graph handle. Initialises
// template 0 (an empty MetaDef) and instance 0 (an empty GraphInstance
// belonging to template 0) so legacy single-template callers can issue
// add_node / set_control / connect without an explicit rt_graph_template_add
// call. New multi-template callers can either keep the auto-created
// template 0 and add more via rt_graph_template_add, or remove
// instance 0 and start fresh. The caller does not yet hold the handle,
// so concurrency does not arise.
RTGraph *rt_graph_create(int capacity, int max_frames);

// [T:alloc-reset] Stop audio (joining the audio thread) and free the
// graph. Caller must ensure no other thread holds g.
void rt_graph_destroy(RTGraph *g);

// [T:alloc-reset] Reset the graph to the initial state: stops audio
// (joining the callback), clears all templates and instances, and
// reinstates template 0 + instance 0. The handle is preserved.
void rt_graph_clear(RTGraph *g);

// ----------------------------------------------------------------
// Multi-template construction (§2.D.3)
// ----------------------------------------------------------------
//
// An RTGraph holds a vector of MetaDefs (templates), one per registered
// template, plus a flat vector of GraphInstances each carrying its
// template_id. The execution order at process time is the registration
// order of templates: process_graph iterates g.defs from 0 to N-1 and
// for each template_id processes every live instance with that
// template_id.
//
// The Haskell side (compileTemplateGraph) chooses registration order
// to match a topological sort over the inter-template precedence DAG
// (T_a precedes T_b iff bfWrites(T_a) ∩ bfReads(T_b) ≠ ∅; BusInDelayed
// reads do not contribute, exactly as within a single graph). Cycles
// in that DAG are rejected at compile time. The runtime is a dumb
// executor — it never inspects the precedence relation or reorders.
//
// Cross-template signal flow goes through the shared Server bus pool
// (BusOut/Out -> BusIn/BusInDelayed). The bus pool is single-buffered
// for live reads and double-buffered for delayed reads, with a swap +
// clear at the Server level once per block (see Note [Bus pool
// double-buffering] in rt_graph.cpp). There is no cross-template
// direct port wiring; rt_graph_template_connect's src and dst nodes
// must both belong to the named template.

// [T:construction] Add a fresh, empty MetaDef and return its dense
// template_id. New templates execute strictly *after* every previously
// registered template within each block. Returns -1 on failure (g is
// null).
int rt_graph_template_add(RTGraph *g);

// [T:read-only] Number of templates currently registered. Iterate
// 0..count-1 to enumerate template_ids.
int rt_graph_template_count(RTGraph *g);

// [T:construction] Set the polyphony cap for a template — the maximum
// number of simultaneously-live (Active or Releasing) instances of
// that template. rt_graph_template_instance_add returns -1 once the
// cap is reached; the runtime does not steal voices automatically
// (the future Phase-3 voice allocator owns that policy).
//
// Default: 8 per template (covers existing tests). Callers that need
// more declare it explicitly during construction. Values <= 0 are
// clamped to 1. Silent no-op on invalid template_id.
//
// See Note [Pool model] in rt_graph.cpp for how the cap interacts
// with the pre-allocated GraphInstance pool, and Note [Thread safety
// contract] for why this is construction-only.
void rt_graph_template_set_polyphony(RTGraph *g, int template_id, int polyphony);

// [T:construction] Add or reconfigure one node at its dense runtime
// index in the named template. Walks every live instance of that
// template and installs freshly-initialised state at the same index,
// so adding a node early or late produces the same final layout
// per-template. Instances of other templates are not touched (each
// template has its own dense node space). Silent no-op if template_id
// is invalid.
void rt_graph_template_add_node(RTGraph *g, int template_id,
                                int node_index, int node_kind);

// [T:construction] Set one entry of a template's spec.default_controls.
// New instances created later via rt_graph_template_instance_add inherit
// the value; existing instances are *not* mutated. Use
// rt_graph_instance_set_control to update a specific live instance.
void rt_graph_template_set_default(RTGraph *g, int template_id,
                                   int node_index, int control_index,
                                   double value);

// [T:construction] Connect one source output port to one destination
// input port within the named template. Wiring lives on the spec side
// and is shared by every instance of the template. Both src and dst
// must belong to the same template — cross-template signal flow goes
// through the bus pool, not direct wiring.
void rt_graph_template_connect(RTGraph *g, int template_id,
                               int src_index, int src_port,
                               int dst_index, int dst_port);

// [T:construction] Mark a node in the named template as elided. An
// elided node remains in the spec — its NodeIndex is preserved,
// its controls remain addressable via rt_graph_template_set_default,
// rt_graph_instance_set_control, and the realtime control queue —
// but process_instance skips its kernel. The Step C single-edge
// fusion pass uses this to keep a Gain node addressable while
// absorbing its per-block work into the consumer's input read.
//
// Silent no-op on invalid template_id or node_index. Idempotent:
// marking the same node elided twice is harmless.
void rt_graph_template_set_node_elided(RTGraph *g, int template_id,
                                       int node_index);

// [T:construction] Wire one input port of a destination node so it
// reads through a fused scaled-source form rather than from a
// producer's output buffer. At runtime the input resolver
// materialises the value as
//
//   scratch[i] = src[i] * static_cast<float>(scale_node.controls[scale_control])
//
// into a per-instance scratch buffer (allocated here, never grown
// in the audio callback) and returns a span over it. Mirrors the
// scalar branch of process_gain so fused vs. unfused outputs are
// bit-identical.
//
// The scale control is read live: rt_graph_instance_set_control
// (or the realtime queue) targeting (scale_node, scale_control)
// continues to drive the fused output, exactly as it did the
// dispatched Gain.
//
// Allocates one fresh scratch slot per call. Walks every live
// instance of the named template to grow its scratch storage
// in lockstep, mirroring rt_graph_template_add_node's parallel-
// growth contract. Construction-only: must run before audio
// starts.
//
// Silent no-op on any invalid index (template_id, dst_node /
// dst_port out of range, src_node / src_port likewise, or
// scale_node / scale_control likewise). Multiple fused-scale
// wires to the same (dst_node, dst_port) overwrite the previous;
// the older scratch slot becomes unused but is not reclaimed.
void rt_graph_template_connect_fused_scale_input(
    RTGraph *g, int template_id,
    int dst_node, int dst_port,
    int src_node, int src_port,
    int scale_node, int scale_control_index);

// [T:construction] Wire one input port of a destination node so it
// reads through a chained fused scaled-source form: a single source
// buffer multiplied by a sequence of scalar gains, applied in
// source-to-sink order.
//
// Operationally equivalent to making N consecutive single-edge fused
// inputs, except (a) it claims one scratch slot regardless of chain
// length, and (b) the resolver applies all scales in a single
// per-block pass, preserving float multiplication order so the fused
// output is bit-identical to the unfused chain of process_gain
// kernels:
//
//   scratch[i] = src[i]
//   for k in 0 .. scale_count-1:
//     k_f = sanitize_finite(static_cast<float>(scale_nodes[k]
//                            .controls[scale_controls[k]]), 1.0f)
//     for i in 0 .. nframes-1: scratch[i] *= k_f
//
// scale_count must be ≥ 1. Each (scale_nodes[k], scale_controls[k])
// pair is a live read on every block — the elided Gain nodes remain
// addressable and rt_graph_instance_set_control on any of them
// continues to drive the consumer's input.
//
// Validation: every scale_node / scale_control pair is checked
// before the scratch slot is claimed. On any invalid index (or null
// arrays / zero count), this is a silent no-op and no slot is
// allocated. Multiple fused-scale wires (chain or single) to the
// same (dst_node, dst_port) overwrite the previous; the older
// scratch slot becomes unused but is not reclaimed.
//
// Construction-only: must run before audio starts. Walks every live
// instance of the named template to grow its scratch storage in
// lockstep with the new slot, mirroring the parallel-growth contract
// of rt_graph_template_add_node.
void rt_graph_template_connect_fused_scale_chain_input(
    RTGraph *g, int template_id,
    int dst_node, int dst_port,
    int src_node, int src_port,
    int scale_count,
    const int *scale_nodes,
    const int *scale_controls);

// [T:construction] Phase 4.C.2: wire one input port through an
// affine chain — a run of scalar Gain (multiply) and scalar Add
// (bias) operations applied in source-to-sink order. Generalises
// rt_graph_template_connect_fused_scale_input and the chain entry:
// every fused input that contains at least one bias step takes
// this entry; pure-scale chains stay on the older entries to keep
// existing callers and tests bit-identical.
//
//   step_kinds[k]:    0 = Scale (multiply), 1 = Bias (add)
//   step_nodes[k]:    NodeIndex of the elided producer (kept
//                     addressable for set_control / realtime
//                     control writes)
//   step_controls[k]: control slot on that node — 0 for Gain;
//                     0 or 1 for Add, depending on which port
//                     held the bias literal.
//
// Per-block resolver materialises:
//
//   scratch[i] = src[i]
//   for k in 0 .. step_count-1:
//     v = sanitize_finite(static_cast<float>(step_nodes[k]
//                          .controls[step_controls[k]]),
//                         step_kinds[k] == 0 ? 1.0f : 0.0f)
//     if step_kinds[k] == 0: for i in 0..nframes-1: scratch[i] *= v
//     if step_kinds[k] == 1: for i in 0..nframes-1: scratch[i] += v
//
// Float arithmetic is non-associative so step order is preserved;
// scales are *not* pre-multiplied and biases are *not* pre-summed.
// Each control is read live every block, so set_control on any
// elided Gain or Add still drives the consumer's input.
//
// Validation: every step (kind ∈ {0,1}, node + control range) is
// checked before the scratch slot is claimed. Any failure or null
// arrays / zero count is a silent no-op. step_count must be ≥ 1.
// One scratch slot per fused input regardless of chain length.
// Construction-only; walks every live instance to grow scratch in
// lockstep, mirroring the parallel-growth contract.
void rt_graph_template_connect_fused_affine_input(
    RTGraph *g, int template_id,
    int dst_node, int dst_port,
    int src_node, int src_port,
    int step_count,
    const int *step_kinds,
    const int *step_nodes,
    const int *step_controls);

// [T:construction] Add one region to the named template's MetaDef.
// Regions are an execution-order overlay on the template's node array;
// process_instance iterates them as the unit of dispatch when the
// template has at least one region registered, and falls back to a
// flat per-node loop when the regions vector is empty.
//
//   rate         : raw int matching the Haskell 'Rate' lattice ordering
//                  (0=CompileRate, 1=InitRate, 2=BlockRate, 3=SampleRate).
//                  Stored verbatim; future Step-B / Step-C work consumes
//                  it. The runtime does not currently make decisions
//                  based on rate.
//   first_node   : dense index of the region's first node within the
//                  template's node array.
//   node_count   : number of contiguous nodes in this region.
//
// Regions are expected to cover every node in the template exactly
// once with no overlap (the Haskell greedy region pass guarantees
// this). The C ABI does not currently validate that contract — it is
// a precondition. Silent no-op if template_id is invalid or if
// first_node/node_count would step outside the template's node array.
//
// NodeIndex remains the addressable identity for every control-write
// ABI ('rt_graph_template_set_default', 'rt_graph_realtime_set_control',
// etc.). Future fusion passes that elide nodes must preserve or
// redirect their control-slot identities.
void rt_graph_template_add_region(RTGraph *g, int template_id,
                                  int rate, int first_node, int node_count);

// [T:control] Spawn an instance of the named template. Returns
// globally-unique instance_id (>= 0) or -1 on failure. Slot reuse: a
// dead slot is reused before appending. The instance carries its
// template_id and is processed by every subsequent rt_graph_process
// call until removed.
int rt_graph_template_instance_add(RTGraph *g, int template_id);

// ----------------------------------------------------------------
// Legacy single-template construction (template 0 shim)
// ----------------------------------------------------------------
//
// These entries operate on template 0 (auto-created by
// rt_graph_create / rt_graph_clear). They are kept unchanged for
// callers that don't need multi-template support; new callers should
// prefer the explicit rt_graph_template_* variants above.

// [T:construction] Template-0 shim for rt_graph_template_add_node.
void rt_graph_add_node(RTGraph *g, int node_index, int node_kind);

// [T:control] Template-0 shim for rt_graph_instance_set_control on
// instance 0. Note: this entry can also grow the bus pool as a side
// effect (when control 0 of an Out / BusOut / BusIn / BusInDelayed
// node is set), which makes it a [T:construction] step in practice
// during graph build. Existing callers always use it during graph
// build, before audio starts; do not call after rt_graph_start_audio.
void rt_graph_set_control(RTGraph *g, int node_index, int control_index,
                          double value);

// [T:construction] Template-0 shim for rt_graph_template_connect.
void rt_graph_connect(RTGraph *g, int src_index, int src_port, int dst_index,
                      int dst_port);

// [T:construction] Template-0 shim for rt_graph_template_add_region.
void rt_graph_add_region(RTGraph *g, int rate, int first_node, int node_count);

// [T:construction] Template-0 shim for rt_graph_template_set_node_elided.
void rt_graph_set_node_elided(RTGraph *g, int node_index);

// [T:construction] Template-0 shim for
// rt_graph_template_connect_fused_scale_input.
void rt_graph_connect_fused_scale_input(
    RTGraph *g,
    int dst_node, int dst_port,
    int src_node, int src_port,
    int scale_node, int scale_control_index);

// [T:render] Offline block rendering. Processes every live instance of
// every template, in template registration (= execution) order.
// nframes must be between 0 and max_frames inclusive. While realtime
// audio is running the audio callback also calls process_graph from
// its own thread; concurrent calls from any other thread are UB.
void rt_graph_process(RTGraph *g, int nframes);

// [T:construction] Grow the shared Server bus pool to cover bus_index.
// No-op if the pool already covers that bus. This is the only
// caller-facing way to size the pool — rt_graph_template_set_default
// and rt_graph_instance_set_control never resize as a side effect of
// writing a control. Construction-only: must run before
// rt_graph_start_audio.
//
// See Note [Explicit bus-pool sizing] in rt_graph.cpp for why the
// implicit-growth path was removed and how the audio thread depends
// on this contract.
void rt_graph_ensure_bus(RTGraph *g, int bus_index);

// [T:bus-read] Copy nframes samples from one server bus into out.
// Returns the number of samples written, or 0 on bad arguments. Reads
// directly from the shared Server bus pool — under §2.C+§2.D.3 the
// pool is shared across all instances of all templates, so there is
// no per-instance / per-template scope for bus reads. Intended for
// offline rendering and tests; calling while audio is running may
// return torn samples (no resize race; the pool is not grown after
// construction).
int rt_graph_read_bus(RTGraph *g, int bus_index, int nframes, float *out);

// [T:audio-life] Realtime audio via q_io/PortAudio.
// output_channels <= 0 means: infer from configured Out buses, minimum 1.
// device_id < 0 means: use the PortAudio default output device if possible,
// otherwise the first device with enough output channels.
// Returns 0 on success, negative values on failure.
int rt_graph_start_audio(RTGraph *g, int output_channels, int device_id);

// [T:audio-life] Wait until the realtime callback has executed at
// least once. Polls an std::atomic<bool>; safe to call concurrently
// with the callback. timeout_ms < 0 waits indefinitely.
// Returns 0 when started, negative values on error/timeout.
int rt_graph_wait_started(RTGraph *g, int timeout_ms);

// [T:audio-life] Stop realtime audio if it is running. Joins the
// audio thread before returning.
void rt_graph_stop_audio(RTGraph *g);

// [T:read-only] Pure introspection: returns 1 if node_kind names a kind
// this runtime knows how to construct (i.e. it has a case in
// rt_graph_add_node), 0 otherwise. Intended for contract tests that
// verify Haskell's NodeKind tags agree with this file's enum.
int rt_graph_kind_supported(int node_kind);

// ----------------------------------------------------------------
// Multi-instance support
// ----------------------------------------------------------------
//
// Instances are independent running copies of a template's MetaDef:
// each has its own control values, kernel state (oscillator phase,
// filter memory, delay buffers, envelope position) but shares the
// Server bus pool with every other instance of every template. The
// instance_id returned here is globally unique and stable for the
// life of the instance; it does not encode the template_id.
//
// rt_graph_instance_add (legacy, no template argument) spawns an
// instance of template 0. For instances of other templates use
// rt_graph_template_instance_add above.
//
// rt_graph_process processes every live instance; the realtime audio
// callback sums their bus contributions onto hardware channels via
// the shared Server pool.

// [T:control] Spawn an instance of template 0. Returns the new
// instance_id (>= 0) or -1 on failure (e.g. g is null). Equivalent
// to rt_graph_template_instance_add(g, 0).
int rt_graph_instance_add(RTGraph *g);

// [T:control] Remove the instance; subsequent operations on
// instance_id are silent no-ops. Slots are reused by future
// rt_graph_instance_add / rt_graph_template_instance_add calls.
// Removing instance 0 is allowed and disables the back-compatibility
// single-instance functions until a new instance is added at slot 0.
//
// This is the *hard-free* path: the slot is cleared at the next
// block boundary regardless of whether the instance still has audio
// in flight, so it clicks if applied to a sustaining voice. Use
// rt_graph_instance_release for graceful tear-down (envelope tail
// completes, then slot is reclaimed automatically).
void rt_graph_instance_remove(RTGraph *g, int instance_id);

// [T:control] Request graceful tear-down of an instance. Sets the
// gate control of every Env node in the instance to 0 so envelopes
// start their release ramp, marks the instance as "Releasing", and
// lets it keep processing every block. Once the instance contributes
// silence (per-block peak below an internal threshold) for a small
// number of consecutive blocks, the slot is reclaimed and the
// instance_id may be reused by future rt_graph_instance_add /
// _template_instance_add calls. If the instance has no Env node (no
// envelope to release), the call is equivalent to
// rt_graph_instance_remove. Silent no-op on dead/invalid instance_id.
//
// Pair this with rt_graph_instance_status to observe the lifecycle
// transition (Live -> Releasing -> dead). Hard-free remains
// available via rt_graph_instance_remove for panic stops and voice
// stealing under pressure.
void rt_graph_instance_release(RTGraph *g, int instance_id);

// [T:read-only] Returns the lifecycle status of an instance:
//   0  = Live (Active; the steady-state of a sounding voice)
//   1  = Releasing (release requested, awaiting silence)
//  -1  = no such instance (free slot, slot reserved by a producer
//        but not yet activated, out of range, or null graph)
//
// Both freed and Reserved slots return -1: a freed slot is
// observationally identical to a slot that never existed, and a
// Reserved slot is the producer's private claim (under the Phase-3
// realtime queue) that has not yet been published to the audio
// schedule via Activate. Use rt_graph_instance_alive when the
// distinction the caller cares about is liveness rather than status.
int rt_graph_instance_status(RTGraph *g, int instance_id);

// [T:read-only] Number of instance slots (live + dead). Iterate
// 0..count-1 to enumerate; check liveness with rt_graph_instance_alive.
int rt_graph_instance_count(RTGraph *g);

// [T:read-only] 1 if the slot is part of the audio schedule (Active
// or Releasing), 0 otherwise (free, reserved-but-not-activated, out
// of range, or null graph). May race with the §2.E auto-free path
// and the Phase-3 realtime queue; treat the result as a hint, not a
// synchronization barrier.
int rt_graph_instance_alive(RTGraph *g, int instance_id);

// [T:control] Per-instance variant of rt_graph_set_control.
// instance_id must reference a live or Reserved instance; an
// Available slot is a silent no-op. Mutates the *instance's*
// controls — to set a template's spec defaults, use
// rt_graph_template_set_default.
//
// Direct write on a Reserved slot is permitted as an explicit
// exception to "[T:control] is audio-stopped only" — the slot is
// the producer's private claim before Activate, and the audio
// thread skips Reserved slots in process_graph. The exception
// applies *only* to the producer that owns the reservation; no
// other thread should write to a Reserved slot. Once the producer
// has enqueued Activate, all subsequent control changes must go
// through rt_graph_realtime_set_control (queued).
void rt_graph_instance_set_control(RTGraph *g, int instance_id,
                                   int node_index, int control_index,
                                   double value);

// (rt_graph_instance_read_bus was removed in the post-§2.E ABI
// cleanup. Under §2.C the bus pool is server-global, so an
// instance-keyed bus read added nothing beyond rt_graph_read_bus
// except a liveness gate the caller can do explicitly via
// rt_graph_instance_alive / _status. Use rt_graph_read_bus.)

// ----------------------------------------------------------------
// A.2: realtime ABI — single-producer entries safe to call from a
// non-audio thread while the audio callback is running
// ----------------------------------------------------------------
//
// Mutation that must happen while audio is live (note-on, note-off,
// CC streams, panic stops) goes through these entries, not the
// [T:control] direct entries above. The work is mediated by an
// SPSC lock-free command queue drained at the top of every
// process_graph block. See Note [A.2: realtime control queue] in
// rt_graph.cpp for the design and memory model.
//
// Single-producer contract: only ONE thread may call this group of
// entries. UI / OSC / MIDI ingress should feed a single producer
// thread (typically the voice allocator's input handler), which is
// the only thread that calls these entries. Concurrent calls from
// multiple threads will corrupt the queue. The C ABI cannot enforce
// this — it is the caller's responsibility.
//
// Lifecycle of a realtime spawn:
//
//   1. rt_graph_realtime_reserve(g, template_id) -> slot_id
//      synchronously CAS-claims an Available slot, prepares it
//      (resize nodes, init kernel state, set defaults), and
//      returns it in Reserved state. -1 on failure.
//
//   2. (Optional) rt_graph_instance_set_control on the Reserved
//      slot to override per-note controls. Direct call — see the
//      [T:control] exception above.
//
//   3. rt_graph_realtime_activate(g, slot_id) enqueues Activate.
//      The audio drain CAS-flips Reserved -> Active at the next
//      block boundary, publishing the slot into the schedule.
//      If enqueue fails (queue full), call rt_graph_realtime_cancel
//      to roll back the reservation.

// [T:realtime-producer] Reserve and prepare a slot of the named
// template. Returns slot_id (>= 0) on success, -1 on any failure
// (null graph, invalid template_id, polyphony cap reached, no
// Available slot in the pool to recycle). Realtime reserve never
// grows the slot pool — callers must pre-warm the pool during
// construction (the standard pattern: spawn N instances via
// rt_graph_template_instance_add, then immediately remove them via
// rt_graph_instance_remove; the slots stay Available with their
// vector capacity preserved).
int rt_graph_realtime_reserve(RTGraph *g, int template_id);

// [T:realtime-producer] Cancel a reservation, returning the slot
// to Available without ever publishing it. Used to roll back when
// rt_graph_realtime_activate's enqueue fails. Silent no-op if the
// slot's state is anything other than Reserved (caller bug or
// already activated).
void rt_graph_realtime_cancel(RTGraph *g, int slot_id);

// [T:realtime-producer] Enqueue Activate(slot_id). Returns 1 on
// success, 0 if the queue is full. The audio drain applies it at
// the next block boundary via a CAS Reserved -> Active. On failure
// the producer should rt_graph_realtime_cancel.
int rt_graph_realtime_activate(RTGraph *g, int slot_id);

// [T:realtime-producer] Enqueue Release(slot_id) — graceful tear-
// down via §2.E silence-window. The audio drain gates to Active
// only (Reserved is producer-private; Releasing is already in
// flight). Returns 1 on success, 0 if the queue is full.
int rt_graph_realtime_release(RTGraph *g, int slot_id);

// [T:realtime-producer] Enqueue Remove(slot_id) — hard-free at the
// next block boundary. The audio drain gates to Active or
// Releasing; Reserved slots are producer-private and should be
// cancelled via rt_graph_realtime_cancel instead. Returns 1 on
// success, 0 if the queue is full.
int rt_graph_realtime_remove(RTGraph *g, int slot_id);

// [T:realtime-producer] Enqueue SetControl. The audio drain
// applies it only to Active or Releasing slots — Reserved slots
// receive their initial controls from the producer's pre-enqueue
// path (direct rt_graph_instance_set_control on the Reserved
// slot). Returns 1 on success, 0 if the queue is full.
int rt_graph_realtime_set_control(RTGraph *g, int slot_id,
                                  int node_index, int control_index,
                                  double value);

#ifdef __cplusplus
}
#endif
