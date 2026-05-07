// ================================================================
// midi_voice_processor_test.cpp
// Description : Tests for the Phase 3.2 MIDI → VoiceAllocator translator
// ================================================================
//
// These tests inject synthetic q::midi_1_0 messages directly at the
// MidiVoiceProcessor — no live MIDI hardware required. The processor
// is intentionally pure dispatch: it forwards to a VoiceAllocator,
// so we can verify allocator state after each event sequence.

#include <doctest/doctest.h>

#include "midi_voice_processor.h"
#include "rt_graph.h"
#include "voice_allocator.h"

#include <q/support/midi_messages.hpp>
#include <q_io/midi_device.hpp>
#include <q_io/midi_stream.hpp>

#include <cstdint>
#include <vector>

using metasonic::MidiVoiceProcessor;
using metasonic::VoiceAllocator;
using metasonic::VoiceResultStatus;
using metasonic::VoiceState;

namespace midi = cycfi::q::midi_1_0;

namespace {

constexpr int kFrames = 1024;

// Captures velocity from the allocator's map callback so the test
// can verify the float conversion.
struct MapCapture {
    int   slot   = -1;
    int   note   = -1;
    float velocity = 0.0f;
    int   call_count = 0;
};

bool capture_map(RTGraph *g, int slot_id, int note, float velocity, void *user_data) {
    auto *c = static_cast<MapCapture *>(user_data);
    c->slot     = slot_id;
    c->note     = note;
    c->velocity = velocity;
    c->call_count++;
    rt_graph_instance_set_control(g, slot_id, 0, 0, static_cast<double>(velocity));
    return true;
}

bool simple_map(RTGraph *g, int slot_id, int /*note*/, float velocity, void * /*ud*/) {
    rt_graph_instance_set_control(g, slot_id, 0, 0, static_cast<double>(velocity));
    return true;
}

RTGraph *make_graph_with_polyphony(int polyphony) {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_template_add_node(g, 0, 0, 8);                // Add (constant)
    rt_graph_template_set_default(g, 0, 0, 0, 0.0);
    rt_graph_template_set_default(g, 0, 0, 1, 0.0);
    rt_graph_template_add_node(g, 0, 1, 2);                // Out
    rt_graph_template_set_default(g, 0, 1, 0, 0.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);

    rt_graph_template_set_polyphony(g, 0, polyphony);

    rt_graph_instance_remove(g, 0);
    std::vector<int> ids(static_cast<std::size_t>(polyphony));
    for (int i = 0; i < polyphony; ++i) {
        ids[static_cast<std::size_t>(i)] = rt_graph_template_instance_add(g, 0);
        REQUIRE(ids[static_cast<std::size_t>(i)] >= 0);
    }
    for (int id : ids) rt_graph_instance_remove(g, id);

    return g;
}

} // namespace

// ----------------------------------------------------------------
// Basic dispatch
// ----------------------------------------------------------------

TEST_CASE("MidiVoiceProcessor: note_on dispatches to VoiceAllocator::note_on") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    proc(midi::note_on{0, 60, 100}, 0);
    CHECK(proc.note_on_events() == 1);
    CHECK(proc.note_off_events() == 0);

    // Voice 0 is now Active on note 60.
    CHECK(alloc.voice_state(0) == VoiceState::Active);
    CHECK(alloc.voice_note(0) == 60);

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor: note_off dispatches to VoiceAllocator::note_off") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    proc(midi::note_on{0, 60, 100}, 0);
    proc(midi::note_off{0, 60, 64}, 0);

    CHECK(proc.note_on_events() == 1);
    CHECK(proc.note_off_events() == 1);
    // Without an Env on the template, the runtime release falls
    // through to a hard free — but the allocator still surfaces
    // Releasing until tick reaps it.
    CHECK(alloc.voice_state(0) == VoiceState::Releasing);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// MIDI conventions
// ----------------------------------------------------------------

TEST_CASE("MidiVoiceProcessor: note_on with velocity 0 is treated as note_off") {
    // Many controllers emit `note_on(key, 0)` instead of explicit
    // `note_off(key, ...)` to save bandwidth (running status). The
    // processor must honor this convention.
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    proc(midi::note_on{0, 60, 100}, 0);
    REQUIRE(alloc.voice_state(0) == VoiceState::Active);

    // velocity == 0 → running-status note_off.
    proc(midi::note_on{0, 60, 0}, 0);

    CHECK(proc.note_on_events() == 1);            // only the first
    CHECK(proc.note_off_events() == 1);           // including the vel-0
    CHECK(proc.running_status_offs() == 1);
    CHECK(alloc.voice_state(0) == VoiceState::Releasing);

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor: velocity is normalised to [0, 1]") {
    auto *g = make_graph_with_polyphony(2);
    MapCapture cap{};
    VoiceAllocator alloc(g, 0, 2, capture_map, &cap);
    MidiVoiceProcessor proc(alloc);

    proc(midi::note_on{0, 60, 127}, 0);
    CHECK(cap.note == 60);
    CHECK(cap.velocity == doctest::Approx(1.0f));

    proc(midi::note_off{0, 60, 0}, 0);
    rt_graph_process(g, kFrames);
    alloc.tick();

    proc(midi::note_on{0, 64, 64}, 0);
    CHECK(cap.note == 64);
    // 64 / 127 ≈ 0.5039
    CHECK(cap.velocity == doctest::Approx(64.0f / 127.0f));

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Channel filtering
// ----------------------------------------------------------------

TEST_CASE("MidiVoiceProcessor: channel mask filters events on non-listening channels") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    // Listen on channel 0 only.
    MidiVoiceProcessor proc(alloc, /*channel_mask*/ 0x0001);

    proc(midi::note_on{0, 60, 100}, 0);   // ch 0 — accepted
    proc(midi::note_on{1, 62, 100}, 0);   // ch 1 — filtered
    proc(midi::note_off{1, 62, 0}, 0);    // ch 1 — filtered

    CHECK(proc.note_on_events() == 1);
    CHECK(proc.note_off_events() == 0);
    CHECK(proc.filtered_events() == 2);

    // Only the first event was forwarded.
    CHECK(alloc.voice_state(0) == VoiceState::Active);
    CHECK(alloc.voice_note(0) == 60);
    // Voice 1 is still Free (the ch1 note was filtered).
    CHECK(alloc.voice_state(1) == VoiceState::Free);

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor: omni mask (default) accepts all 16 channels") {
    auto *g = make_graph_with_polyphony(4);
    VoiceAllocator alloc(g, 0, 4, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);  // default 0xFFFF

    for (std::uint8_t ch = 0; ch < 16; ++ch) {
        proc(midi::note_on{ch, static_cast<std::uint8_t>(60 + ch), 100}, 0);
    }
    // First 4 succeed (polyphony cap = 4), rest go PendingSteal.
    // What matters: zero filtered events.
    CHECK(proc.filtered_events() == 0);
    CHECK(proc.note_on_events() == 16);

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor: set_channel_mask updates the filter at runtime") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc, /*ch 0 only*/ 0x0001);

    proc(midi::note_on{1, 60, 100}, 0);   // filtered
    CHECK(proc.filtered_events() == 1);
    CHECK(proc.note_on_events() == 0);

    proc.set_channel_mask(0x0002);        // listen on ch 1 instead
    proc(midi::note_on{1, 62, 100}, 0);   // accepted
    CHECK(proc.note_on_events() == 1);
    CHECK(alloc.voice_note(0) == 62);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Lifecycle through the processor
// ----------------------------------------------------------------

TEST_CASE("MidiVoiceProcessor: full note lifecycle through the processor") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    // Three notes in, three out.
    proc(midi::note_on{0, 60, 100}, 0);
    proc(midi::note_on{0, 64, 100}, 0);
    REQUIRE(proc.note_on_events() == 2);
    CHECK(alloc.voice_state(0) == VoiceState::Active);
    CHECK(alloc.voice_state(1) == VoiceState::Active);

    proc(midi::note_off{0, 60, 0}, 0);
    proc(midi::note_off{0, 64, 0}, 0);
    REQUIRE(proc.note_off_events() == 2);
    CHECK(alloc.voice_state(0) == VoiceState::Releasing);
    CHECK(alloc.voice_state(1) == VoiceState::Releasing);

    rt_graph_process(g, kFrames);
    alloc.tick();

    // Both voices reaped.
    CHECK(alloc.voice_state(0) == VoiceState::Free);
    CHECK(alloc.voice_state(1) == VoiceState::Free);

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor: ignored MIDI categories do not disturb allocator state") {
    // CC, pitch_bend, aftertouch, etc. are silently dropped in 3.2.
    // The base midi_1_0::processor's empty operator() handles the
    // catch-all. Verify nothing leaks into the allocator.
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    proc(midi::note_on{0, 60, 100}, 0);
    REQUIRE(alloc.voice_state(0) == VoiceState::Active);

    // Send a smattering of categories the processor doesn't (yet) wire.
    proc(midi::control_change{0, midi::cc::channel_volume, 100}, 0);
    proc(midi::pitch_bend{0, 0x40, 0x40}, 0);     // centered pitch bend
    proc(midi::channel_aftertouch{0, 64}, 0);
    proc(midi::poly_aftertouch{0, 60, 64}, 0);
    proc(midi::program_change{0, 1}, 0);

    // Allocator state untouched.
    CHECK(alloc.voice_state(0) == VoiceState::Active);
    CHECK(alloc.voice_note(0) == 60);
    CHECK(proc.note_on_events() == 1);
    CHECK(proc.note_off_events() == 0);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Out-of-spec inputs
// ----------------------------------------------------------------

// ----------------------------------------------------------------
// Q MIDI-source linkage
// ----------------------------------------------------------------

TEST_CASE("Linkage: Q MIDI sources are compiled into tinysynth_rt") {
    // The header advertises wiring against q::midi_input_stream and
    // q::midi_device. Both live in q_io/src/midi_*.cpp and must be
    // compiled into the static lib (alongside the audio_*.cpp files).
    // Reference one symbol from each translation unit so the linker
    // is forced to pull them in — a missing source surfaces as a
    // link error before the tests even start. We do NOT actually
    // construct a midi_input_stream (its destructor calls Pm_Close
    // unconditionally on _impl, and on systems without a MIDI device
    // _impl can be nullptr).
    auto stream_set_default = &cycfi::q::midi_input_stream::set_default_device;
    auto device_list        = &cycfi::q::midi_device::list;
    CHECK(reinterpret_cast<void*>(stream_set_default) != nullptr);
    CHECK(reinterpret_cast<void*>(device_list)        != nullptr);
}

TEST_CASE("MidiVoiceProcessor: note_off on never-played note is a safe no-op") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    proc(midi::note_off{0, 60, 0}, 0);
    proc(midi::note_off{0, 99, 0}, 0);

    CHECK(proc.note_off_events() == 2);
    for (int i = 0; i < alloc.voice_count(); ++i) {
        CHECK(alloc.voice_state(i) == VoiceState::Free);
    }

    rt_graph_destroy(g);
}
