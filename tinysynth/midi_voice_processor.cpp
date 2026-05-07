// ================================================================
// midi_voice_processor.cpp
// Description : Implementation of MIDI 1.0 → VoiceAllocator translator
// ================================================================

#include "midi_voice_processor.h"
#include "rt_graph.h"

#include <q/support/frequency.hpp>
#include <q/support/pitch.hpp>

#include <cmath>

namespace metasonic {

namespace midi = cycfi::q::midi_1_0;

MidiVoiceProcessor::MidiVoiceProcessor(VoiceAllocator &alloc,
                                       std::uint16_t channel_mask) noexcept
    : alloc_(alloc), channel_mask_(channel_mask) {}

void MidiVoiceProcessor::operator()(midi::note_on msg, std::size_t /*time*/) {
  if (!channel_matches(msg.channel())) {
    ++filtered_events_;
    return;
  }

  if (msg.velocity() == 0) {
    // Running-status convention: note_on(vel=0) == note_off.
    ++running_status_offs_;
    ++note_off_events_;
    alloc_.note_off(static_cast<int>(msg.key()));
    return;
  }

  ++note_on_events_;
  const float velocity = static_cast<float>(msg.velocity()) / 127.0f;
  alloc_.note_on(static_cast<int>(msg.key()), velocity);
}

void MidiVoiceProcessor::operator()(midi::note_off msg, std::size_t /*time*/) {
  if (!channel_matches(msg.channel())) {
    ++filtered_events_;
    return;
  }
  ++note_off_events_;
  alloc_.note_off(static_cast<int>(msg.key()));
}

void MidiVoiceProcessor::operator()(midi::control_change msg, std::size_t /*time*/) {
  if (!channel_matches(msg.channel())) {
    ++filtered_events_;
    return;
  }
  ++cc_events_;

  // Walk the table once. Multiple mappings may target the same CC
  // number — they all fire in registration order.
  const std::uint8_t cc_value = static_cast<std::uint8_t>(msg.value()) & 0x7Fu;
  const float        unit     = static_cast<float>(cc_value) / 127.0f;

  RTGraph *g = alloc_.graph();
  if (!g) return;

  for (std::size_t i = 0; i < cc_mapping_count_; ++i) {
    const CCMapping &m = cc_mappings_[i];
    if (m.cc_number != static_cast<std::uint8_t>(msg.controller())) continue;
    const float value = m.min_value + unit * (m.max_value - m.min_value);

    // Push a SetControl onto the realtime queue for every voice
    // currently in the audio schedule. PendingSteal voices are
    // skipped — they have no slot_id yet, and the next pitch-bend /
    // CC after they activate will pick them up.
    for (int vi = 0; vi < alloc_.voice_count(); ++vi) {
      const VoiceState st = alloc_.voice_state(vi);
      if (st != VoiceState::Active && st != VoiceState::Releasing) continue;
      const int slot_id = alloc_.voice_handle(vi).slot_id;
      if (slot_id < 0) continue;
      // Queue-full failures here are silently dropped — caller can
      // retry on the next CC tick. Same contract as the realtime
      // ABI's other entries.
      (void) rt_graph_realtime_set_control(
          g, slot_id, m.node_index, m.control_index,
          static_cast<double>(value));
    }
  }
}

void MidiVoiceProcessor::operator()(midi::pitch_bend msg, std::size_t /*time*/) {
  if (!channel_matches(msg.channel())) {
    ++filtered_events_;
    return;
  }
  ++pb_events_;
  if (!pitch_bend_bound_) return;

  // 14-bit value: 0..16383, centre = 8192.
  const int   raw  = static_cast<int>(msg.value()) - 8192;
  const float bend = static_cast<float>(raw) / 8192.0f;  // [-1, 1)
  const float bend_semitones = bend * pitch_bend_.semitone_range;
  const float bend_factor    = std::pow(2.0f, bend_semitones / 12.0f);

  RTGraph *g = alloc_.graph();
  if (!g) return;

  for (int vi = 0; vi < alloc_.voice_count(); ++vi) {
    const VoiceState st = alloc_.voice_state(vi);
    if (st != VoiceState::Active && st != VoiceState::Releasing) continue;
    const int slot_id = alloc_.voice_handle(vi).slot_id;
    if (slot_id < 0) continue;
    const int note = alloc_.voice_note(vi);
    if (note < 0) continue;

    // 12-TET pitch → frequency via Q's pitch utilities (fast log2 /
    // pow2 approximations; precision is fine for audible pitch).
    const cycfi::q::frequency base = cycfi::q::as_frequency(
        cycfi::q::pitch{static_cast<float>(note)});
    const double bent_hz = cycfi::q::as_double(base) * bend_factor;
    (void) rt_graph_realtime_set_control(
        g, slot_id, pitch_bend_.node_index, pitch_bend_.control_index,
        bent_hz);
  }
}

bool MidiVoiceProcessor::add_cc_mapping(std::uint8_t cc_number, int node_index,
                                       int control_index, float min, float max) {
  if (cc_mapping_count_ >= kMaxCCMappings) return false;
  cc_mappings_[cc_mapping_count_++] =
      CCMapping{cc_number, node_index, control_index, min, max};
  return true;
}

void MidiVoiceProcessor::clear_cc_mappings() noexcept {
  cc_mapping_count_ = 0;
}

void MidiVoiceProcessor::set_pitch_bend(int node_index, int control_index,
                                        float semitone_range) noexcept {
  pitch_bend_       = PitchBendBinding{node_index, control_index, semitone_range};
  pitch_bend_bound_ = true;
}

void MidiVoiceProcessor::clear_pitch_bend() noexcept {
  pitch_bend_bound_ = false;
}

} // namespace metasonic
