#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RTGraph RTGraph;

// Lifecycle
RTGraph *rt_graph_create(int capacity, int max_frames);
void rt_graph_destroy(RTGraph *g);
void rt_graph_clear(RTGraph *g);

// Graph construction
void rt_graph_add_node(RTGraph *g, int node_index, int node_kind);
void rt_graph_set_control(RTGraph *g, int node_index, int control_index,
                          double value);
void rt_graph_connect(RTGraph *g, int src_index, int src_port, int dst_index,
                      int dst_port);

// Offline block rendering into internal output buses.
// nframes must be between 0 and max_frames inclusive.
void rt_graph_process(RTGraph *g, int nframes);

// Copy nframes samples from one output bus into out (which must point to
// at least nframes floats). Returns the number of samples written, or 0
// if bus_index is out of range / nframes is invalid.
// Intended for offline rendering and for inspecting buses from tests
// without going through the realtime audio path.
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
// One RTGraph hosts a single MetaDef (the immutable template, built
// via rt_graph_add_node + rt_graph_connect) plus a vector of
// GraphInstances. Each instance has independent control values,
// kernel state (oscillator phase, filter memory, delay buffers,
// envelope position), and bus pool — multiple voices of the same
// synth template run in parallel.
//
// A default instance is created at index 0 when rt_graph_create runs.
// The single-instance functions above (rt_graph_set_control,
// rt_graph_read_bus) operate on instance 0 for back-compatibility.
// rt_graph_process processes every live instance; the realtime audio
// callback sums their bus contributions onto hardware channels.

// Add a new instance from the current MetaDef. Returns the new
// instance_id (>= 0) or -1 on failure (e.g. g is null). Newly added
// nodes (rt_graph_add_node) and new connections (rt_graph_connect)
// after this point apply to this instance too — adding an instance
// "early" or "late" does not change its layout.
int rt_graph_instance_add(RTGraph *g);

// Remove the instance; subsequent operations on instance_id are
// silent no-ops. Slots are reused by future rt_graph_instance_add
// calls. Removing instance 0 is allowed and disables the
// back-compatibility single-instance functions until a new instance
// is added at slot 0.
void rt_graph_instance_remove(RTGraph *g, int instance_id);

// Number of instance slots (live + dead). Iterate 0..count-1 to
// enumerate; check liveness with rt_graph_instance_alive.
int rt_graph_instance_count(RTGraph *g);

// 1 if the slot holds a live instance, 0 otherwise (dead slot, out
// of range, or null graph).
int rt_graph_instance_alive(RTGraph *g, int instance_id);

// Per-instance variants of rt_graph_set_control / rt_graph_read_bus.
// instance_id must reference a live instance; otherwise the call is
// a silent no-op (and read_bus returns 0).
void rt_graph_instance_set_control(RTGraph *g, int instance_id,
                                   int node_index, int control_index,
                                   double value);
int rt_graph_instance_read_bus(RTGraph *g, int instance_id,
                               int bus_index, int nframes, float *out);

#ifdef __cplusplus
}
#endif
