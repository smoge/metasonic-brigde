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
                          float value);
void rt_graph_connect(RTGraph *g, int src_index, int src_port, int dst_index,
                      int dst_port);

// Offline block rendering into internal output buses.
// nframes must be between 0 and max_frames inclusive.
void rt_graph_process(RTGraph *g, int nframes);

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

#ifdef __cplusplus
}
#endif