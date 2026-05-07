#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RTGraph RTGraph;

// ----------------------------------------------------------------
// Lifecycle
// ----------------------------------------------------------------

// Allocate a fresh runtime graph handle. Initialises template 0 (an
// empty MetaDef) and instance 0 (an empty GraphInstance belonging to
// template 0) so legacy single-template callers can issue add_node /
// set_control / connect without an explicit rt_graph_template_add
// call. New multi-template callers can either keep the auto-created
// template 0 and add more via rt_graph_template_add, or remove
// instance 0 and start fresh.
RTGraph *rt_graph_create(int capacity, int max_frames);
void rt_graph_destroy(RTGraph *g);

// Reset the graph to the initial state: stops audio, clears all
// templates and instances, and reinstates template 0 + instance 0.
// The handle is preserved.
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

// Add a fresh, empty MetaDef and return its dense template_id. New
// templates execute strictly *after* every previously registered
// template within each block. Returns -1 on failure (g is null).
int rt_graph_template_add(RTGraph *g);

// Number of templates currently registered. Iterate 0..count-1 to
// enumerate template_ids.
int rt_graph_template_count(RTGraph *g);

// Add or reconfigure one node at its dense runtime index in the named
// template. Walks every live instance of that template and installs
// freshly-initialised state at the same index, so adding a node early
// or late produces the same final layout per-template. Instances of
// other templates are not touched (each template has its own dense
// node space). Silent no-op if template_id is invalid.
void rt_graph_template_add_node(RTGraph *g, int template_id,
                                int node_index, int node_kind);

// Set one entry of a template's spec.default_controls. New instances
// created later via rt_graph_template_instance_add inherit the value;
// existing instances are *not* mutated. Use rt_graph_instance_set_control
// to update a specific live instance.
void rt_graph_template_set_default(RTGraph *g, int template_id,
                                   int node_index, int control_index,
                                   double value);

// Connect one source output port to one destination input port within
// the named template. Wiring lives on the spec side and is shared by
// every instance of the template. Both src and dst must belong to the
// same template — cross-template signal flow goes through the bus
// pool, not direct wiring.
void rt_graph_template_connect(RTGraph *g, int template_id,
                               int src_index, int src_port,
                               int dst_index, int dst_port);

// Spawn an instance of the named template. Returns globally-unique
// instance_id (>= 0) or -1 on failure. Slot reuse: a dead slot is
// reused before appending. The instance carries its template_id and
// is processed by every subsequent rt_graph_process call until
// removed.
int rt_graph_template_instance_add(RTGraph *g, int template_id);

// ----------------------------------------------------------------
// Legacy single-template construction (template 0 shim)
// ----------------------------------------------------------------
//
// These entries operate on template 0 (auto-created by
// rt_graph_create / rt_graph_clear). They are kept unchanged for
// callers that don't need multi-template support; new callers should
// prefer the explicit rt_graph_template_* variants above.

void rt_graph_add_node(RTGraph *g, int node_index, int node_kind);
void rt_graph_set_control(RTGraph *g, int node_index, int control_index,
                          double value);
void rt_graph_connect(RTGraph *g, int src_index, int src_port, int dst_index,
                      int dst_port);

// Offline block rendering. Processes every live instance of every
// template, in template registration (= execution) order.
// nframes must be between 0 and max_frames inclusive.
void rt_graph_process(RTGraph *g, int nframes);

// Copy nframes samples from one server bus into out. Returns the
// number of samples written, or 0 on bad arguments. Reads directly
// from the shared Server bus pool — under §2.C+§2.D.3 the pool is
// shared across all instances of all templates, so there is no
// per-instance / per-template scope for bus reads. Intended for
// offline rendering and tests.
int rt_graph_read_bus(RTGraph *g, int bus_index, int nframes, float *out);

// Realtime audio via q_io/PortAudio.
// output_channels <= 0 means: infer from configured Out buses, minimum 1.
// device_id < 0 means: use the PortAudio default output device if possible,
// otherwise the first device with enough output channels.
// Returns 0 on success, negative values on failure.
int rt_graph_start_audio(RTGraph *g, int output_channels, int device_id);

// Wait until the realtime callback has executed at least once.
// timeout_ms < 0 waits indefinitely.
// Returns 0 when started, negative values on error/timeout.
int rt_graph_wait_started(RTGraph *g, int timeout_ms);

// Stop realtime audio if it is running.
void rt_graph_stop_audio(RTGraph *g);

// Introspection: returns 1 if node_kind names a kind this runtime knows
// how to construct (i.e. it has a case in rt_graph_add_node), 0 otherwise.
// Intended for contract tests that verify Haskell's NodeKind tags agree
// with this file's enum.
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

// Spawn an instance of template 0. Returns the new instance_id (>= 0)
// or -1 on failure (e.g. g is null). Equivalent to
// rt_graph_template_instance_add(g, 0).
int rt_graph_instance_add(RTGraph *g);

// Remove the instance; subsequent operations on instance_id are
// silent no-ops. Slots are reused by future rt_graph_instance_add /
// rt_graph_template_instance_add calls. Removing instance 0 is
// allowed and disables the back-compatibility single-instance
// functions until a new instance is added at slot 0.
//
// This is the *hard-free* path: the slot is cleared at the next
// block boundary regardless of whether the instance still has audio
// in flight, so it clicks if applied to a sustaining voice. Use
// rt_graph_instance_release for graceful tear-down (envelope tail
// completes, then slot is reclaimed automatically).
void rt_graph_instance_remove(RTGraph *g, int instance_id);

// Request graceful tear-down of an instance. Sets the gate control
// of every Env node in the instance to 0 so envelopes start their
// release ramp, marks the instance as "Releasing", and lets it keep
// processing every block. Once the instance contributes silence
// (per-block peak below an internal threshold) for a small number of
// consecutive blocks, the slot is reclaimed and the instance_id may
// be reused by future rt_graph_instance_add / _template_instance_add
// calls. If the instance has no Env node (no envelope to release),
// the call is equivalent to rt_graph_instance_remove. Silent no-op
// on dead/invalid instance_id.
//
// Pair this with rt_graph_instance_status to observe the lifecycle
// transition (Live -> Releasing -> dead). Hard-free remains
// available via rt_graph_instance_remove for panic stops and voice
// stealing under pressure.
void rt_graph_instance_release(RTGraph *g, int instance_id);

// Returns the lifecycle status of an instance:
//   0  = Live (default after add; the steady-state of a sounding voice)
//   1  = Releasing (release requested, awaiting silence)
//  -1  = no such instance (dead slot, out of range, or null graph)
//
// "Dead" is reported as -1 (same as out-of-range), not as a separate
// positive value, because a freed slot is observationally identical to
// a slot that never existed. Use rt_graph_instance_alive when the
// distinction the caller cares about is liveness rather than status.
int rt_graph_instance_status(RTGraph *g, int instance_id);

// Number of instance slots (live + dead). Iterate 0..count-1 to
// enumerate; check liveness with rt_graph_instance_alive.
int rt_graph_instance_count(RTGraph *g);

// 1 if the slot holds a live instance, 0 otherwise (dead slot, out
// of range, or null graph).
int rt_graph_instance_alive(RTGraph *g, int instance_id);

// Per-instance variants of rt_graph_set_control / rt_graph_read_bus.
// instance_id must reference a live instance; otherwise the call is
// a silent no-op (and read_bus returns 0). Mutates the *instance's*
// controls — to set a template's spec defaults, use
// rt_graph_template_set_default.
void rt_graph_instance_set_control(RTGraph *g, int instance_id,
                                   int node_index, int control_index,
                                   double value);
int rt_graph_instance_read_bus(RTGraph *g, int instance_id,
                               int bus_index, int nframes, float *out);

#ifdef __cplusplus
}
#endif
