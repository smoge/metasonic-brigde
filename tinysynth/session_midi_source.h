// ================================================================
// session_midi_source.h
// Description : Small PortMIDI/Q decoded-event source for session MIDI
// ================================================================
//
// This C ABI exposes a polling source of already-decoded MIDI note
// and CC events. It is intentionally smaller than midi_demo.h: no
// RTGraph, VoiceAllocator, realtime queue, worker thread, pitch-bend
// policy, or control mapping lives here. Haskell owns the worker via
// MetaSonic.Session.MIDIListener and polls this handle from that
// worker.
//
// Threading: a source handle is single-consumer. Poll it from one
// owner thread and do not close it while another thread is polling.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rt_session_midi_source rt_session_midi_source;

enum {
  RT_SESSION_MIDI_EVENT_NONE = 0,
  RT_SESSION_MIDI_EVENT_NOTE_ON = 1,
  RT_SESSION_MIDI_EVENT_NOTE_OFF = 2,
  RT_SESSION_MIDI_EVENT_CONTROL_CHANGE = 3
};

// Open a polling source over a Q / PortMIDI input device.
//
// midi_device_index : -1 selects Q's canonical default device id 0.
//                     Other values match ids returned by
//                     rt_midi_device_list. Missing, output-only, or
//                     failed-open devices produce a valid idle handle
//                     whose has_device accessor returns 0.
//
// Returns nullptr only for hard allocation failure.
rt_session_midi_source *
rt_session_midi_source_open(int midi_device_index);

// Close a source handle. Safe with nullptr.
void rt_session_midi_source_close(rt_session_midi_source *h);

// True when the source opened a real MIDI input device. Returns -1
// for nullptr.
int rt_session_midi_source_has_device(const rt_session_midi_source *h);

// Poll for one supported MIDI event.
//
// Returns one of RT_SESSION_MIDI_EVENT_* or -1 for invalid arguments.
// On a positive event return, channel/data1/data2 are filled with:
//   note-on:        channel, note, velocity
//   note-off:       channel, note, velocity
//   control-change: channel, controller, value
//
// Unsupported MIDI 1.0 messages are consumed and ignored. No-event and
// no-device both return RT_SESSION_MIDI_EVENT_NONE.
int rt_session_midi_source_poll(rt_session_midi_source *h,
                                int *channel,
                                int *data1,
                                int *data2);

#ifdef __cplusplus
} // extern "C"
#endif
