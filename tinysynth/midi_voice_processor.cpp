// ================================================================
// midi_voice_processor.cpp
// Description : Implementation of MIDI 1.0 → VoiceAllocator translator
// ================================================================

#include "midi_voice_processor.h"

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

} // namespace metasonic
