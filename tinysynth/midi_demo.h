// ================================================================
// midi_demo.h
// Description : Live-MIDI demo runner (Phase 3 closing piece)
// ================================================================
//
// Slice 2 of the end-to-end MIDI demo: a small C ABI that opens a
// MIDI input stream, attaches a VoiceAllocator + MidiVoiceProcessor
// to a loaded RTGraph, and dispatches incoming events on a producer
// worker thread until the caller closes the session.
//
// Design intent: keep the live-MIDI plumbing entirely on the C++
// side. Haskell compiles the synth structure and (slice 3) drives
// open/close lifecycle plus binding manifest. Note events themselves
// never cross the FFI boundary — they go straight from PortMIDI →
// q::midi_input_stream → MidiVoiceProcessor → realtime ABI.
//
// Threading model:
//
//   audio thread  ── consumes ── realtime queue
//                                       ▲
//   worker thread ── produces ──┐       │
//                               │       │
//   q::midi_input_stream → MidiVoiceProcessor → VoiceAllocator
//
// The audio thread is started by the caller via rt_graph_start_audio
// before opening the demo (or after — order doesn't matter, the demo
// only writes the producer side of the realtime queue).
//
// Single-session contract: run at most one live-MIDI demo session in a
// process, and serialize open/close calls. This is enough for the demo
// runner's intended use: one producer worker feeding one RTGraph.
//
// Why: Q's midi_device objects borrow process-global listing storage
// (see tinysynth/q_midi_device.cpp). Supporting concurrent opens safely
// would need a process-wide guard around list() -> probe ->
// q::midi_input_stream construction, or the cleaner upstream fix where
// midi_device owns its impl by value.
//
// Graceful no-device behavior: the worker walks
// q::midi_device::list() and only constructs a q::midi_input_stream
// when a device matches the requested id AND has num_inputs() > 0.
// On a host with no MIDI devices, an out-of-range id, or only
// output-only devices at the requested id, no stream is constructed
// at all; the worker stays idle, has_device reports 0, counters stay
// at zero. The handle remains valid; rt_midi_demo_close still joins
// cleanly. CI boxes without a controller (and headless / sandboxed
// hosts without /dev/snd/seq) can construct and destroy demos
// uneventfully.

#pragma once

#include "rt_graph.h"

#include <cstdint>

#define RT_MIDI_DEVICE_NAME_MAX 256

#ifdef __cplusplus
extern "C" {
#endif

// Forward-declared opaque handle; the implementation is hidden in
// midi_demo.cpp behind a struct that owns the worker thread, the
// MIDI stream, the voice allocator, and the processor.
typedef struct rt_midi_demo rt_midi_demo;

// Per-note control routing. The demo's built-in VoiceMapFn writes:
//   * freq_node_index/freq_control_index ←
//       cycfi::q::as_double(as_frequency(pitch{note}))
//   * gate_node_index/gate_control_index ← 1.0 (note-on)
//   * vel_node_index/vel_control_index   ← velocity in [0, 1]
//       (skipped when vel_node_index < 0)
// Note-off gates are issued by VoiceAllocator's own release path
// (rt_graph_instance_release), not by this struct.
struct rt_midi_voice_mapping {
  int freq_node_index;
  int freq_control_index;
  int gate_node_index;
  int gate_control_index;
  int vel_node_index;     // negative to skip
  int vel_control_index;  // negative to skip
};

// CC mapping entry; one row per (cc_number → control) binding.
// Multiple rows may target the same CC. See
// MidiVoiceProcessor::add_cc_mapping for the per-voice broadcast
// semantics.
struct rt_midi_cc_mapping {
  std::uint8_t cc_number;
  int          node_index;
  int          control_index;
  float        min_value;
  float        max_value;
};

// Optional pitch-bend binding. Pass nullptr to leave pitch bend
// unbound. When set, every Active / Releasing voice's freq control
// is updated to as_frequency(pitch{voice_note}) * 2^(bend *
// semitone_range / 12), where bend is the 14-bit value mapped to
// [-1, 1].
struct rt_midi_pitch_bend_binding {
  int   node_index;
  int   control_index;
  float semitone_range;  // 2.0f matches typical controller default
};

// Snapshot row for q::midi_device::list(). `name` is always
// NUL-terminated, truncated if the backend reports a longer string.
// Use rt_midi_device_list(nullptr, 0) to get the current device
// count, then call again with an array of that many rows.
struct rt_midi_device_info {
  int  id;
  int  num_inputs;
  int  num_outputs;
  char name[RT_MIDI_DEVICE_NAME_MAX];
};

// Enumerate current MIDI devices through Q / PortMIDI.
//
// Returns the total number of devices on success, whether or not
// `out` has enough capacity to receive all rows. Copies at most
// `max_devices` rows when `out` is non-null. Returns -1 if
// enumeration throws or if `max_devices` is negative.
int rt_midi_device_list(rt_midi_device_info *out, int max_devices);

// Open a live MIDI session over `graph`. Spawns a worker thread that
// runs `stream.process(proc); proc.tick();` in a loop with a small
// sleep between iterations.
//
// graph              : compiled rt_graph; caller retains ownership
//                      and must outlive the demo handle.
// template_id        : id from rt_graph_template_create.
// polyphony          : number of voices (clamped to >= 1). The
//                      caller must have called
//                      rt_graph_template_set_polyphony with a value
//                      >= polyphony AND pre-warmed the per-template
//                      pool with that many spawn-then-remove cycles
//                      so that VoiceAllocator can find Available
//                      slots on its first reserve.
// midi_device_index  : -1 selects device 0 (Q's canonical default).
//                      The worker resolves this by walking
//                      q::midi_device::list() and matching by id; we
//                      never touch Q's process-global default_device_id,
//                      so -1 is stable across calls regardless of
//                      earlier explicit-device opens elsewhere in the
//                      process. Out-of-range or no-input-device cases
//                      yield a handle whose worker observes no usable
//                      device and stays idle (has_device == 0).
// voice_mapping      : required.
// cc_mappings        : may be null when count == 0.
// cc_mapping_count   : 0..32 (capped at MidiVoiceProcessor's
//                      kMaxCCMappings; entries past the cap are
//                      silently ignored).
// pitch_bend         : may be null.
// channel_mask       : 0xFFFF = listen on all channels (omni).
//
// Returns nullptr on hard allocation failure or invalid arguments
// (null graph, null voice_mapping). Returns a valid handle even if
// no MIDI device is present — see "Graceful no-device behavior"
// at the top of this header.
rt_midi_demo *
rt_midi_demo_open(RTGraph                            *graph,
                  int                                 template_id,
                  int                                 polyphony,
                  int                                 midi_device_index,
                  const rt_midi_voice_mapping        *voice_mapping,
                  const rt_midi_cc_mapping           *cc_mappings,
                  int                                 cc_mapping_count,
                  const rt_midi_pitch_bend_binding   *pitch_bend,
                  std::uint16_t                       channel_mask);

// Stop the worker thread, join it, and tear down the MIDI stream.
// After return the handle is invalid. Safe to call with a null
// handle (no-op).
void rt_midi_demo_close(rt_midi_demo *h);

// Diagnostic counters, cumulative since open. -1 if h is null.
int rt_midi_demo_note_on_count(const rt_midi_demo *h);
int rt_midi_demo_note_off_count(const rt_midi_demo *h);
int rt_midi_demo_cc_count(const rt_midi_demo *h);
int rt_midi_demo_pitch_bend_count(const rt_midi_demo *h);

// True when the underlying q::midi_input_stream connected to a
// device. False on no-device boxes, or before the worker has
// initialized. -1 if h is null. Useful for CI / smoke tests that
// want to assert "this binary handles a no-MIDI environment."
int rt_midi_demo_has_device(const rt_midi_demo *h);

#ifdef __cplusplus
} // extern "C"
#endif
