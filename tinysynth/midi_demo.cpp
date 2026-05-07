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
#include <q_io/midi_device.hpp>
#include <q_io/midi_stream.hpp>

#include <atomic>
#include <chrono>
#include <new>
#include <optional>
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
  // Held in std::optional so we can skip emplace entirely when the
  // device list doesn't include a valid input device at the requested
  // id. Q's q::midi_input_stream dtor calls Pm_Close(_impl)
  // unconditionally; on some PortMIDI builds Pm_Close(nullptr) crashes,
  // so any code path that constructs the stream with _impl == nullptr
  // (output-only device, missing /dev/snd/seq, busy device, ...)
  // becomes a latent crash. The worker's probe below narrows
  // construction to "id matches a device with num_inputs() > 0";
  // the residual rare path (probe says OK, Pm_OpenInput races with a
  // hot-unplug) still hits the same dtor and needs a vendor patch.
  std::optional<cycfi::q::midi_input_stream> stream;
  std::atomic<bool>                 stop;
  std::atomic<int>                  has_device;  // 0 / 1, set by worker
  // Caller-supplied device index. -1 means "Q's canonical default
  // (device 0)" — resolved by the worker so we don't have to touch
  // Q's process-global default_device_id at all.
  int                               midi_device_index;
  std::thread                       worker;

  rt_midi_demo(RTGraph *g, int tid, int polyphony,
               const rt_midi_voice_mapping &mapping,
               int dev_idx,
               std::uint16_t channel_mask)
    : graph(g),
      voice_mapping(mapping),
      alloc(g, tid, polyphony, &default_voice_map, &voice_mapping),
      proc(alloc, channel_mask),
      stream(std::nullopt),
      stop(false),
      has_device(0),
      midi_device_index(dev_idx) {}

  void run() noexcept {
    // Walk q::midi_device::list() and only construct the stream
    // when we find a device whose id matches our target AND that
    // reports num_inputs() > 0. This rules out three crash classes
    // up front:
    //   * No-device host (list is empty -> no emplace).
    //   * Output-only device at the target id (num_inputs == 0 ->
    //     no emplace; Pm_OpenInput would have set _impl to null).
    //   * Out-of-range id (no match -> no emplace).
    // q::midi_device::list() calls Pm_Initialize + Pm_CountDevices,
    // both of which return error codes on no-/dev/snd/seq hosts
    // rather than crashing.
    bool ok = false;
    try {
      const auto devices = cycfi::q::midi_device::list();
      const int target =
          midi_device_index < 0 ? 0 : midi_device_index;
      for (const auto &d : devices) {
        if (static_cast<int>(d.id()) == target && d.num_inputs() > 0) {
          stream.emplace(d);
          ok = stream->is_valid();
          // If is_valid() is false here, Pm_OpenInput failed
          // despite the probe — typically a hot-unplug racing with
          // open. We deliberately do NOT call stream.reset(): that
          // would invoke ~midi_input_stream() right now, and on some
          // PortMIDI builds Pm_Close(nullptr) crashes. Leaving the
          // optional engaged means the same dtor still runs at
          // ~rt_midi_demo, but at least we don't double-trigger it
          // and the worker's `if (ok)` below skips processing.
          break;
        }
      }
    } catch (...) {
      // PortMIDI / ALSA enumeration crashed; stay idle.
      ok = false;
    }
    has_device.store(ok ? 1 : 0, std::memory_order_release);

    while (!stop.load(std::memory_order_acquire)) {
      if (stream && ok) {
        for (int i = 0; i < kEventsPerPass; ++i) {
          stream->process(proc);
        }
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

  // Note: we deliberately do NOT call
  // cycfi::q::midi_input_stream::set_default_device here. The worker
  // resolves midi_device_index itself (via q::midi_device::list() and
  // the device-aware ctor), so Q's process-global default never
  // matters. This makes -1 stable across calls regardless of earlier
  // explicit-device opens elsewhere in the process.

  rt_midi_demo *h = nullptr;
  try {
    h = new rt_midi_demo(graph, template_id, polyphony, *voice_mapping,
                          midi_device_index, channel_mask);
  } catch (...) {
    // Any standard exception (bad_alloc, length_error from
    // VoiceAllocator's vector resize on pathological polyphony,
    // bad_array_new_length, ...) must not cross extern "C". Anything
    // non-standard would also UB on Haskell side, so swallow all.
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
  } catch (...) {
    // Same blanket catch as construction: thread spawn can throw
    // std::system_error (resource exhaustion) or std::bad_alloc.
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
