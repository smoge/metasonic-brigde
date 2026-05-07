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
                                       std::uint16_t channel_mask)
    : alloc_(alloc), channel_mask_(channel_mask) {
  // voice_tracks_.resize can throw bad_alloc; not noexcept.
  voice_tracks_.resize(static_cast<std::size_t>(alloc.voice_count()));
}

void MidiVoiceProcessor::operator()(midi::note_on msg, std::size_t /*time*/) {
  if (!channel_matches(msg.channel())) {
    filtered_events_.fetch_add(1, std::memory_order_relaxed);
    return;
  }

  if (msg.velocity() == 0) {
    // Running-status convention: note_on(vel=0) == note_off.
    running_status_offs_.fetch_add(1, std::memory_order_relaxed);
    note_off_events_.fetch_add(1, std::memory_order_relaxed);
    alloc_.note_off(static_cast<int>(msg.key()));
    return;
  }

  note_on_events_.fetch_add(1, std::memory_order_relaxed);
  const float velocity = static_cast<float>(msg.velocity()) / 127.0f;
  alloc_.note_on(static_cast<int>(msg.key()), velocity);
}

void MidiVoiceProcessor::operator()(midi::note_off msg, std::size_t /*time*/) {
  if (!channel_matches(msg.channel())) {
    filtered_events_.fetch_add(1, std::memory_order_relaxed);
    return;
  }
  note_off_events_.fetch_add(1, std::memory_order_relaxed);
  alloc_.note_off(static_cast<int>(msg.key()));
}

void MidiVoiceProcessor::operator()(midi::control_change msg, std::size_t /*time*/) {
  if (!channel_matches(msg.channel())) {
    filtered_events_.fetch_add(1, std::memory_order_relaxed);
    return;
  }
  cc_events_.fetch_add(1, std::memory_order_relaxed);

  // Walk the table once. Multiple mappings may target the same CC
  // number — they all fire in registration order.
  const std::uint8_t cc_value = static_cast<std::uint8_t>(msg.value()) & 0x7Fu;
  const float        unit     = static_cast<float>(cc_value) / 127.0f;

  RTGraph *g = alloc_.graph();
  if (!g) return;

  for (std::size_t i = 0; i < cc_mapping_count_; ++i) {
    CCMapping &m = cc_mappings_[i];
    if (m.cc_number != static_cast<std::uint8_t>(msg.controller())) continue;
    const float value = m.min_value + unit * (m.max_value - m.min_value);

    // Cache the scaled value for state inheritance (3.3b). Replay
    // on activation will use last_value directly, so the cache is
    // independent of any later remapping on the same CC number.
    m.has_last_value = true;
    m.last_value     = value;

    // Push a SetControl onto the realtime queue for every voice
    // currently in the audio schedule. PendingSteal voices are
    // skipped — they have no slot_id yet, and tick()'s state
    // inheritance will catch them up when they become Active.
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
    filtered_events_.fetch_add(1, std::memory_order_relaxed);
    return;
  }
  pb_events_.fetch_add(1, std::memory_order_relaxed);
  if (!pitch_bend_bound_) return;

  // Cache the raw 14-bit value so a stolen / pending-steal voice
  // inherits the current bend on activation.
  pitch_bend_.last_raw = static_cast<std::uint16_t>(msg.value());

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

// Phase 3.3b: producer-thread tick. Drives the allocator forward
// (retry pending steals, reap auto-frees) and then walks the voice
// table, replaying cached CC + pitch-bend values onto any voice
// that just became Active. The replay is gated on (voice_index,
// generation): once applied for a given activation, it does not
// re-fire on subsequent ticks until the voice is reused.
void MidiVoiceProcessor::tick() {
  alloc_.tick();

  // The allocator's voice_count is constant for its lifetime, but
  // we resize defensively in case the caller built the processor
  // before adjusting polyphony or mutated the allocator externally.
  const auto vc = static_cast<std::size_t>(alloc_.voice_count());
  if (voice_tracks_.size() < vc) voice_tracks_.resize(vc);

  for (std::size_t i = 0; i < vc; ++i) {
    const int          vi = static_cast<int>(i);
    const VoiceState   st = alloc_.voice_state(vi);
    const VoiceHandle  h  = alloc_.voice_handle(vi);
    VoiceTrack        &t  = voice_tracks_[i];

    if (st != VoiceState::Active) {
      // Voice not in the audio schedule. Reset was_active so the
      // next time it goes Active we recognize the transition.
      t.was_active = false;
      continue;
    }

    // Voice is Active. Replay if this is a fresh activation (not
    // already Active in the previous tick) or if the generation
    // has advanced (same index, new owner).
    const bool newly_active =
        !t.was_active || t.last_generation != h.generation;
    if (!newly_active) continue;

    apply_inherited_state_to_voice(vi, h);
    t.last_generation = h.generation;
    t.was_active      = true;
  }
}

// Replay every cached CC value (only mappings that have observed
// at least one CC event fire) plus the pitch-bend default if a
// binding exists. Both writes go through rt_graph_realtime_set_-
// control, so they land at the next process_graph drain — i.e. one
// block after activation, same latency as a regular CC dispatch.
void MidiVoiceProcessor::apply_inherited_state_to_voice(
    int voice_index, VoiceHandle handle) {
  RTGraph *g = alloc_.graph();
  if (!g || handle.slot_id < 0) return;

  // CC: replay only mappings whose has_last_value is set. We
  // never fabricate a default — the user did not necessarily mean
  // 0.0 (or min_value) when they registered the mapping.
  for (std::size_t i = 0; i < cc_mapping_count_; ++i) {
    const CCMapping &m = cc_mappings_[i];
    if (!m.has_last_value) continue;
    (void) rt_graph_realtime_set_control(
        g, handle.slot_id, m.node_index, m.control_index,
        static_cast<double>(m.last_value));
  }

  // Pitch-bend: always replay if bound. The centred default
  // (last_raw = 8192, factor 1.0) is the right inherited value
  // pre-event because binding pitch-bend to a control declares
  // pitch-bend ownership of it — silence-by-omission would be
  // wrong (the freq control would otherwise carry whatever the
  // map callback wrote, e.g. velocity).
  if (pitch_bend_bound_) {
    const int note = alloc_.voice_note(voice_index);
    if (note >= 0) {
      const int   raw            = static_cast<int>(pitch_bend_.last_raw) - 8192;
      const float bend           = static_cast<float>(raw) / 8192.0f;
      const float bend_semitones = bend * pitch_bend_.semitone_range;
      const float bend_factor    = std::pow(2.0f, bend_semitones / 12.0f);
      const cycfi::q::frequency base = cycfi::q::as_frequency(
          cycfi::q::pitch{static_cast<float>(note)});
      const double bent_hz = cycfi::q::as_double(base) * bend_factor;
      (void) rt_graph_realtime_set_control(
          g, handle.slot_id, pitch_bend_.node_index,
          pitch_bend_.control_index, bent_hz);
    }
  }
}

} // namespace metasonic
