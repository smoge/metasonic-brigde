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
//   * CC / pitch-bend / aftertouch / program-change are silently
//     ignored. They will land in Phase 3.3 once per-voice control
//     mapping exists.

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
  void operator()(cycfi::q::midi_1_0::note_on  msg, std::size_t time);
  void operator()(cycfi::q::midi_1_0::note_off msg, std::size_t time);

  // Channel mask. Setter is provided so a runtime UI can switch
  // omni / single-channel mode without rebuilding the processor.
  void          set_channel_mask(std::uint16_t mask) noexcept { channel_mask_ = mask; }
  std::uint16_t channel_mask() const noexcept                  { return channel_mask_; }

  // Observability. Counts are useful both for tests and for
  // monitoring stuck-key / pattern-mismatch issues at runtime.
  // note_on_events counts only velocity > 0 dispatches; running-
  // status note-offs (note_on with vel == 0) increment
  // note_off_events and running_status_offs but NOT note_on_events.
  // filtered_events counts events dropped by the channel mask.
  int note_on_events()      const noexcept { return note_on_events_; }
  int note_off_events()     const noexcept { return note_off_events_; }
  int running_status_offs() const noexcept { return running_status_offs_; }
  int filtered_events()     const noexcept { return filtered_events_; }

private:
  bool channel_matches(std::uint8_t channel) const noexcept {
    return ((channel_mask_ >> channel) & 1u) != 0u;
  }

  VoiceAllocator &alloc_;
  std::uint16_t   channel_mask_;
  int             note_on_events_      = 0;
  int             note_off_events_     = 0;
  int             running_status_offs_ = 0;
  int             filtered_events_     = 0;
};

} // namespace metasonic
