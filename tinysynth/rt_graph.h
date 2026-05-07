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
//   construction  — mutates shared structure; safe only when the
//                   audio callback is not running
//   control       — mutates per-instance state; today safe only when
//                   audio is stopped, will become safe via deferred
//                   command queue in Phase 3
//   read-only     — reads scalar / optional fields; may return stale
//                   or torn values during concurrent mutation but
//                   cannot crash
//   bus-read      — copies bus samples; tearable but not racy on
//                   container shape
//   audio-life    — open/close/poll the realtime stream
//   render        — runs process_graph; offline-only when the audio
//                   callback is also running
//   alloc-reset   — cooperate with the audio lifecycle (stop the
//                   stream before mutating state)
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
// instance_id must reference a live instance; otherwise the call is
// a silent no-op. Mutates the *instance's* controls — to set a
// template's spec defaults, use rt_graph_template_set_default.
void rt_graph_instance_set_control(RTGraph *g, int instance_id,
                                   int node_index, int control_index,
                                   double value);

// (rt_graph_instance_read_bus was removed in the post-§2.E ABI
// cleanup. Under §2.C the bus pool is server-global, so an
// instance-keyed bus read added nothing beyond rt_graph_read_bus
// except a liveness gate the caller can do explicitly via
// rt_graph_instance_alive / _status. Use rt_graph_read_bus.)

#ifdef __cplusplus
}
#endif
