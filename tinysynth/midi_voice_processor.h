// ================================================================
// midi_voice_processor.h
// Description : MIDI 1.0 → VoiceAllocator translator (Phase 3.2)
// ================================================================
//
// Phase 3.2: a typed MIDI processor that translates Q's
// q::midi_1_0::note_on / note_off messages into VoiceAllocator
// note_on / note_off calls. Designed to satisfy the
// q::concepts::midi_1_0::Processor concept so it can be passed
// directly to q::midi_input_stream::process().
//
// Wiring against a live MIDI input stream looks like:
//
//   metasonic::VoiceAllocator alloc(graph, tid, polyphony, map, ud);
//   metasonic::MidiVoiceProcessor proc(alloc);
//   q::midi_input_stream stream;
//   while (running) {
//     stream.process(proc);   // consumes 0 or 1 event (non-blocking)
//     alloc.tick();           // retry pending steals, reap auto-frees
//     // sleep / yield to avoid busy-spinning
//   }
//
// Threading: same single-producer contract as VoiceAllocator. The
// thread driving stream.process() and alloc.tick() must be the
// only producer.
//
// MIDI conventions handled:
//   * Note-on with velocity == 0 is treated as note_off (the MIDI
//     1.0 running-status convention used by many controllers).
//   * Channel filtering via a 16-bit mask. Bit i = listen on
//     channel i; default 0xFFFF is omni mode.
//   * Velocity is normalised to a float in [0, 1] (= MIDI value /
//     127). The user's voice-allocator map callback is responsible
//     for any further re-scaling (e.g. perceptual curves).
//   * Control change (CC) is dispatched through a small mapping
//     table (see add_cc_mapping). Each entry binds a CC number to
//     a per-voice (node_index, control_index) with a linear scale
//     [min, max]. When a matching CC arrives, every Active /
//     Releasing voice in the allocator gets the scaled value
//     written via rt_graph_realtime_set_control. Multiple entries
//     can target the same CC.
//   * Pitch-bend is dispatched through a single binding (see
//     set_pitch_bend). Each Active / Releasing voice's frequency
//     control is updated to as_frequency(pitch{voice_note}) *
//     2^(bend * semitone_range / 12). bend is the 14-bit value
//     mapped to [-1, 1].
//   * Aftertouch / program-change are silently ignored — they
//     don't have an obvious universal mapping. Wire them via a
//     custom processor subclass if needed.
//
// Known limitation (Phase 3.3a): CC and pitch-bend updates land at
// the next process_graph block boundary, not per-sample. Rapid
// sweeps (e.g. mod-wheel ramps, pitch-bend trills) may produce
// audible zippering. Phase 3.3b adds q::dynamic_smoother to the
// runtime to fix this without changing the API surface.

#pragma once

#include "voice_allocator.h"

#include <q/support/midi_messages.hpp>
#include <q/support/midi_processor.hpp>

#include <cstddef>
#include <cstdint>

namespace metasonic {

class MidiVoiceProcessor : public cycfi::q::midi_1_0::processor {
public:
  using cycfi::q::midi_1_0::processor::operator();

  // channel_mask: bit i (0-15) set means "listen on MIDI channel i".
  // Default 0xFFFF listens to all 16 channels.
  explicit MidiVoiceProcessor(VoiceAllocator &alloc,
                              std::uint16_t channel_mask = 0xFFFFu) noexcept;

  // q::midi_1_0::Processor overloads. Time is unused for now (the
  // allocator has no notion of sub-block scheduling).
  void operator()(cycfi::q::midi_1_0::note_on        msg, std::size_t time);
  void operator()(cycfi::q::midi_1_0::note_off       msg, std::size_t time);
  void operator()(cycfi::q::midi_1_0::control_change msg, std::size_t time);
  void operator()(cycfi::q::midi_1_0::pitch_bend     msg, std::size_t time);

  // Bind a CC number to a per-voice control with linear scaling.
  // When a control_change with this number arrives on a channel
  // matching channel_mask_, every Active / Releasing voice in the
  // allocator gets node_index/control_index updated to
  //   min + (cc_value / 127) * (max - min).
  // Multiple mappings can target the same CC; they all fire in
  // registration order. Returns true on success, false if the
  // mapping table is full (cap = kMaxCCMappings).
  bool add_cc_mapping(std::uint8_t cc_number, int node_index,
                      int control_index, float min = 0.0f, float max = 1.0f);

  // Drop every CC mapping. Useful for tests and for runtime
  // re-binding when a UI swaps presets.
  void clear_cc_mappings() noexcept;

  // Bind pitch-bend to a per-voice frequency control. Each
  // Active / Releasing voice's (node_index, control_index) is
  // updated to as_frequency(pitch{voice_note}) * 2^(bend *
  // semitone_range / 12) where bend is in [-1, 1] from the 14-bit
  // MIDI value. Default range of 2 semitones matches the most
  // common controller default. clear_pitch_bend disables.
  void set_pitch_bend(int node_index, int control_index,
                      float semitone_range = 2.0f) noexcept;
  void clear_pitch_bend() noexcept;

  // Channel mask. Setter is provided so a runtime UI can switch
  // omni / single-channel mode without rebuilding the processor.
  void          set_channel_mask(std::uint16_t mask) noexcept { channel_mask_ = mask; }
  std::uint16_t channel_mask() const noexcept                  { return channel_mask_; }

  // Observability. Counts are useful both for tests and for
  // monitoring stuck-key / pattern-mismatch issues at runtime.
  // note_on_events counts only velocity > 0 dispatches; running-
  // status note-offs (note_on with vel == 0) increment
  // note_off_events and running_status_offs but NOT note_on_events.
  // filtered_events counts events dropped by the channel mask
  // across all message kinds.
  // control_change_events / pitch_bend_events count accepted
  // dispatches; events that match channel but have no binding still
  // increment.
  int note_on_events()         const noexcept { return note_on_events_; }
  int note_off_events()        const noexcept { return note_off_events_; }
  int running_status_offs()    const noexcept { return running_status_offs_; }
  int filtered_events()        const noexcept { return filtered_events_; }
  int control_change_events()  const noexcept { return cc_events_; }
  int pitch_bend_events()      const noexcept { return pb_events_; }

private:
  bool channel_matches(std::uint8_t channel) const noexcept {
    return ((channel_mask_ >> channel) & 1u) != 0u;
  }

  struct CCMapping {
    std::uint8_t cc_number     = 0;
    int          node_index    = 0;
    int          control_index = 0;
    float        min_value     = 0.0f;
    float        max_value     = 1.0f;
  };

  struct PitchBendBinding {
    int   node_index     = 0;
    int   control_index  = 0;
    float semitone_range = 2.0f;
  };

  static constexpr std::size_t kMaxCCMappings = 32;

  VoiceAllocator &alloc_;
  std::uint16_t   channel_mask_;
  int             note_on_events_      = 0;
  int             note_off_events_     = 0;
  int             running_status_offs_ = 0;
  int             filtered_events_     = 0;
  int             cc_events_           = 0;
  int             pb_events_           = 0;

  std::size_t      cc_mapping_count_ = 0;
  CCMapping        cc_mappings_[kMaxCCMappings];
  bool             pitch_bend_bound_ = false;
  PitchBendBinding pitch_bend_;
};

} // namespace metasonic
