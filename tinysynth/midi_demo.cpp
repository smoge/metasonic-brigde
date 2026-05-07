// ================================================================
// midi_demo.cpp
// Description : Live-MIDI demo runner (Phase 3 closing piece)
// ================================================================

#include "midi_demo.h"

#include "midi_voice_processor.h"
#include "rt_graph.h"
#include "voice_allocator.h"

#include <q/support/midi_processor.hpp>
#include <q/support/pitch.hpp>
#include <q_io/midi_stream.hpp>

#include <atomic>
#include <chrono>
#include <new>
#include <thread>

namespace {

// VoiceAllocator's per-note map callback. Reads the routing struct
// out of user_data and writes freq + gate (+ optional velocity) to
// the freshly Reserved slot. Direct rt_graph_instance_set_control
// is allowed on Reserved slots (see [T:control] in rt_graph.h).
//
// Returning false makes the allocator surface MapFailed and cancel
// the reservation — we use that for the null-routing case (which
// shouldn't happen in practice since open() validates voice_mapping).
bool default_voice_map(RTGraph *graph, int slot_id, int note,
                       float velocity, void *user_data) noexcept {
  const auto *m = static_cast<const rt_midi_voice_mapping *>(user_data);
  if (!m || !graph) return false;

  const auto base = cycfi::q::as_frequency(
      cycfi::q::pitch{static_cast<float>(note)});
  rt_graph_instance_set_control(graph, slot_id, m->freq_node_index,
                                m->freq_control_index,
                                cycfi::q::as_double(base));
  rt_graph_instance_set_control(graph, slot_id, m->gate_node_index,
                                m->gate_control_index, 1.0);
  if (m->vel_node_index >= 0) {
    rt_graph_instance_set_control(graph, slot_id, m->vel_node_index,
                                  m->vel_control_index,
                                  static_cast<double>(velocity));
  }
  return true;
}

// How long the worker sleeps between dispatch passes. PortMIDI is
// poll-based; ~1 ms keeps latency tight without burning a core.
constexpr auto kWorkerSleep = std::chrono::milliseconds(1);
// How many events to drain per pass before sleeping. Q's
// process() consumes at most one per call; bursting up to 16 keeps
// us from falling behind on rapid pitch-bend / CC streams.
constexpr int kEventsPerPass = 16;

} // namespace

struct rt_midi_demo {
  RTGraph                          *graph;
  // Stored *before* alloc so the &voice_mapping pointer handed to
  // the allocator's user_data stays valid for the allocator's life.
  rt_midi_voice_mapping             voice_mapping;
  metasonic::VoiceAllocator         alloc;
  metasonic::MidiVoiceProcessor     proc;
  cycfi::q::midi_input_stream       stream;
  std::atomic<bool>                 stop;
  std::atomic<int>                  has_device;  // 0 / 1, set by worker
  std::thread                       worker;

  rt_midi_demo(RTGraph *g, int tid, int polyphony,
               const rt_midi_voice_mapping &mapping,
               std::uint16_t channel_mask)
    : graph(g),
      voice_mapping(mapping),
      alloc(g, tid, polyphony, &default_voice_map, &voice_mapping),
      proc(alloc, channel_mask),
      stream(),
      stop(false),
      has_device(0) {}

  void run() noexcept {
    // Snapshot the device state once. is_valid() reflects whether
    // PortMIDI opened a stream successfully; on no-device boxes
    // process()/next() are no-ops, so the loop is harmless either
    // way, but recording it lets callers diagnose "did MIDI come
    // up?" without their own probe.
    has_device.store(stream.is_valid() ? 1 : 0, std::memory_order_release);

    while (!stop.load(std::memory_order_acquire)) {
      for (int i = 0; i < kEventsPerPass; ++i) {
        stream.process(proc);
      }
      proc.tick();
      std::this_thread::sleep_for(kWorkerSleep);
    }
  }
};

extern "C" {

rt_midi_demo *
rt_midi_demo_open(RTGraph                            *graph,
                  int                                 template_id,
                  int                                 polyphony,
                  int                                 midi_device_index,
                  const rt_midi_voice_mapping        *voice_mapping,
                  const rt_midi_cc_mapping           *cc_mappings,
                  int                                 cc_mapping_count,
                  const rt_midi_pitch_bend_binding   *pitch_bend,
                  std::uint16_t                       channel_mask) {
  if (!graph || !voice_mapping) return nullptr;

  // Q's set_default_device is a static module-level setting consulted
  // by the next midi_input_stream() default-ctor invocation. We honour
  // -1 by leaving it at whatever the previous setting was (initial
  // value is 0 = first device).
  if (midi_device_index >= 0) {
    cycfi::q::midi_input_stream::set_default_device(midi_device_index);
  }

  rt_midi_demo *h = nullptr;
  try {
    h = new rt_midi_demo(graph, template_id, polyphony, *voice_mapping,
                          channel_mask);
  } catch (const std::bad_alloc &) {
    return nullptr;
  }

  // Register CC mappings (silently dropped past MidiVoiceProcessor's
  // kMaxCCMappings cap; surfaced via the bool return that we ignore
  // here for ABI simplicity — the demo is a best-effort runner).
  if (cc_mappings) {
    for (int i = 0; i < cc_mapping_count; ++i) {
      const auto &m = cc_mappings[i];
      h->proc.add_cc_mapping(m.cc_number, m.node_index, m.control_index,
                              m.min_value, m.max_value);
    }
  }
  if (pitch_bend) {
    h->proc.set_pitch_bend(pitch_bend->node_index,
                           pitch_bend->control_index,
                           pitch_bend->semitone_range);
  }

  try {
    h->worker = std::thread([h]() { h->run(); });
  } catch (const std::system_error &) {
    delete h;
    return nullptr;
  }

  return h;
}

void rt_midi_demo_close(rt_midi_demo *h) {
  if (!h) return;
  h->stop.store(true, std::memory_order_release);
  if (h->worker.joinable()) h->worker.join();
  delete h;
}

int rt_midi_demo_note_on_count(const rt_midi_demo *h) {
  return h ? h->proc.note_on_events() : -1;
}

int rt_midi_demo_note_off_count(const rt_midi_demo *h) {
  return h ? h->proc.note_off_events() : -1;
}

int rt_midi_demo_cc_count(const rt_midi_demo *h) {
  return h ? h->proc.control_change_events() : -1;
}

int rt_midi_demo_pitch_bend_count(const rt_midi_demo *h) {
  return h ? h->proc.pitch_bend_events() : -1;
}

int rt_midi_demo_has_device(const rt_midi_demo *h) {
  return h ? h->has_device.load(std::memory_order_acquire) : -1;
}

} // extern "C"
