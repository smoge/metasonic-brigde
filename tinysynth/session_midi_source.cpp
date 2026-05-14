// ================================================================
// session_midi_source.cpp
// Description : Small PortMIDI/Q decoded-event source for session MIDI
// ================================================================

#include "session_midi_source.h"

#include <q/support/midi_messages.hpp>
#include <q_io/midi_device.hpp>
#include <q_io/midi_stream.hpp>

#include <cstdint>
#include <cstddef>
#include <new>
#include <optional>

namespace {

constexpr int kRawEventsPerPoll = 16;

struct DecodedEvent {
  int kind = RT_SESSION_MIDI_EVENT_NONE;
  int channel = 0;
  int data1 = 0;
  int data2 = 0;
};

bool decode_raw(cycfi::q::midi_1_0::raw_message msg,
                DecodedEvent &out) noexcept {
  const auto status = static_cast<std::uint8_t>(msg.data & 0xFFu);
  const auto tag = static_cast<std::uint8_t>(status & 0xF0u);
  const auto channel = static_cast<int>(status & 0x0Fu);
  const auto data1 = static_cast<int>((msg.data >> 8) & 0x7Fu);
  const auto data2 = static_cast<int>((msg.data >> 16) & 0x7Fu);

  switch (tag) {
    case cycfi::q::midi_1_0::status::note_on:
      out = DecodedEvent{RT_SESSION_MIDI_EVENT_NOTE_ON,
                         channel, data1, data2};
      return true;
    case cycfi::q::midi_1_0::status::note_off:
      out = DecodedEvent{RT_SESSION_MIDI_EVENT_NOTE_OFF,
                         channel, data1, data2};
      return true;
    case cycfi::q::midi_1_0::status::control_change:
      out = DecodedEvent{RT_SESSION_MIDI_EVENT_CONTROL_CHANGE,
                         channel, data1, data2};
      return true;
    case cycfi::q::midi_1_0::status::pitch_bend:
      out = DecodedEvent{RT_SESSION_MIDI_EVENT_PITCH_BEND,
                         channel, data1 | (data2 << 7), 0};
      return true;
    default:
      return false;
  }
}

struct RawCapture {
  bool saw_raw = false;
  bool saw_supported = false;
  DecodedEvent event {};

  void process_midi(cycfi::q::midi_1_0::raw_message msg,
                    std::size_t /*time*/) noexcept {
    saw_raw = true;
    saw_supported = decode_raw(msg, event);
  }
};

} // namespace

struct rt_session_midi_source {
  std::optional<cycfi::q::midi_input_stream> stream;
  int midi_device_index;
  int has_device;

  explicit rt_session_midi_source(int dev_idx)
    : stream(std::nullopt),
      midi_device_index(dev_idx),
      has_device(0) {
    open_device();
  }

  void open_device() noexcept {
    try {
      const auto devices = cycfi::q::midi_device::list();
      const int target =
          midi_device_index < 0 ? 0 : midi_device_index;
      for (const auto &d : devices) {
        if (static_cast<int>(d.id()) == target && d.num_inputs() > 0) {
          stream.emplace(d);
          has_device = stream->is_valid() ? 1 : 0;
          return;
        }
      }
    } catch (...) {
      // Keep no-device / backend-error hosts idle and closeable.
    }
    stream.reset();
    has_device = 0;
  }

  int poll(int *channel, int *data1, int *data2) noexcept {
    if (!channel || !data1 || !data2) return -1;

    *channel = 0;
    *data1 = 0;
    *data2 = 0;

    if (!stream || !has_device) {
      return RT_SESSION_MIDI_EVENT_NONE;
    }

    for (int i = 0; i < kRawEventsPerPoll; ++i) {
      RawCapture capture;
      stream->process_raw(capture);
      if (!capture.saw_raw) {
        return RT_SESSION_MIDI_EVENT_NONE;
      }
      if (capture.saw_supported) {
        *channel = capture.event.channel;
        *data1 = capture.event.data1;
        *data2 = capture.event.data2;
        return capture.event.kind;
      }
    }

    return RT_SESSION_MIDI_EVENT_NONE;
  }
};

extern "C" {

rt_session_midi_source *
rt_session_midi_source_open(int midi_device_index) {
  try {
    return new rt_session_midi_source(midi_device_index);
  } catch (...) {
    return nullptr;
  }
}

void rt_session_midi_source_close(rt_session_midi_source *h) {
  delete h;
}

int rt_session_midi_source_has_device(const rt_session_midi_source *h) {
  return h ? h->has_device : -1;
}

int rt_session_midi_source_poll(rt_session_midi_source *h,
                                int *channel,
                                int *data1,
                                int *data2) {
  if (!h) return -1;
  return h->poll(channel, data1, data2);
}

} // extern "C"
