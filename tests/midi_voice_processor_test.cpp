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

TEST_CASE("MidiVoiceProcessor: unbound CC / pitch-bend and aftertouch do not disturb voices") {
    // After Phase 3.3a, CC and pitch-bend have explicit overloads —
    // but with no mappings registered (and no pitch-bend bound),
    // they're no-ops on the allocator/runtime side. Aftertouch and
    // program-change are still routed to the base processor's empty
    // catch-all and remain ignored.
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    proc(midi::note_on{0, 60, 100}, 0);
    REQUIRE(alloc.voice_state(0) == VoiceState::Active);

    proc(midi::control_change{0, midi::cc::channel_volume, 100}, 0);
    proc(midi::pitch_bend{0, 0x40, 0x40}, 0);     // centred pitch-bend
    proc(midi::channel_aftertouch{0, 64}, 0);
    proc(midi::poly_aftertouch{0, 60, 64}, 0);
    proc(midi::program_change{0, 1}, 0);

    // Allocator state untouched.
    CHECK(alloc.voice_state(0) == VoiceState::Active);
    CHECK(alloc.voice_note(0) == 60);
    CHECK(proc.note_on_events() == 1);
    CHECK(proc.note_off_events() == 0);
    // CC and pitch-bend events were accepted (just no mappings to fire).
    CHECK(proc.control_change_events() == 1);
    CHECK(proc.pitch_bend_events() == 1);

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

// ----------------------------------------------------------------
// Phase 3.3a: CC dispatch through the mapping table
// ----------------------------------------------------------------

namespace {

// Read bus 0's first sample after one block. The Add(constant) →
// Out(bus 0) template emits a steady value, so this is enough to
// observe what the allocator's voices are writing.
float bus0_first_sample(RTGraph *g) {
    rt_graph_process(g, kFrames);
    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    return bus0[0];
}

} // namespace

TEST_CASE("MidiVoiceProcessor CC: bound CC writes to the mapped control on every Active voice") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    REQUIRE(proc.add_cc_mapping(/*cc*/ 7, /*node*/ 0, /*ctl*/ 0,
                                /*min*/ 0.0f, /*max*/ 1.0f));

    proc(midi::note_on{0, 60, 100}, 0);
    REQUIRE(alloc.voice_state(0) == VoiceState::Active);

    // Send CC 7 with value 64 → 64/127 → 0.5039...
    proc(midi::control_change{0, midi::cc::channel_volume, 64}, 0);
    CHECK(proc.control_change_events() == 1);

    CHECK(bus0_first_sample(g) == doctest::Approx(64.0f / 127.0f).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor CC: linear scaling with custom min/max") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    // Map CC 7 to control[0] scaled to [0.5, 1.5].
    REQUIRE(proc.add_cc_mapping(7, 0, 0, /*min*/ 0.5f, /*max*/ 1.5f));

    proc(midi::note_on{0, 60, 100}, 0);

    proc(midi::control_change{0, midi::cc::channel_volume, 0}, 0);
    CHECK(bus0_first_sample(g) == doctest::Approx(0.5f).epsilon(1e-5));

    proc(midi::control_change{0, midi::cc::channel_volume, 127}, 0);
    CHECK(bus0_first_sample(g) == doctest::Approx(1.5f).epsilon(1e-5));

    proc(midi::control_change{0, midi::cc::channel_volume, 64}, 0);
    const float mid = 0.5f + (64.0f / 127.0f) * 1.0f;
    CHECK(bus0_first_sample(g) == doctest::Approx(mid).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor CC: unmapped CC numbers are no-op for voice state") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    REQUIRE(proc.add_cc_mapping(7, 0, 0, 0.0f, 1.0f));  // bind only CC 7

    proc(midi::note_on{0, 60, 100}, 0);
    const float before = bus0_first_sample(g);

    // CC 1 (mod wheel) is not mapped — bus value should not change.
    proc(midi::control_change{0, midi::cc::modulation, 100}, 0);
    CHECK(bus0_first_sample(g) == doctest::Approx(before).epsilon(1e-6));
    // The event was still counted as a CC dispatch.
    CHECK(proc.control_change_events() == 1);

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor CC: channel mask filters CC events") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    // Listen on channel 0 only.
    MidiVoiceProcessor proc(alloc, /*channel_mask*/ 0x0001);

    REQUIRE(proc.add_cc_mapping(7, 0, 0, 0.0f, 1.0f));

    proc(midi::note_on{0, 60, 100}, 0);
    const float before = bus0_first_sample(g);

    // CC on channel 1 is filtered.
    proc(midi::control_change{1, midi::cc::channel_volume, 0}, 0);
    CHECK(proc.filtered_events() == 1);
    CHECK(proc.control_change_events() == 0);
    CHECK(bus0_first_sample(g) == doctest::Approx(before).epsilon(1e-6));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor CC: multiple mappings on the same CC all fire") {
    // Two mappings both target the same CC number but write different
    // controls. The Add template only has control[0] and control[1]
    // (the two summed constants) so we can verify both writes by
    // reading bus 0, which carries control[0] + control[1].
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    REQUIRE(proc.add_cc_mapping(7, 0, 0, 0.0f, 0.25f));   // → control[0]
    REQUIRE(proc.add_cc_mapping(7, 0, 1, 0.0f, 0.75f));   // → control[1]

    proc(midi::note_on{0, 60, 100}, 0);
    proc(midi::control_change{0, midi::cc::channel_volume, 127}, 0);

    // Both mappings fired: control[0] = 0.25, control[1] = 0.75.
    // Add outputs control[0] + control[1] = 1.0.
    CHECK(bus0_first_sample(g) == doctest::Approx(1.0f).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor CC: PendingSteal voices are skipped, Active voices receive") {
    auto *g = make_graph_with_polyphony(1);
    VoiceAllocator alloc(g, 0, 1, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);
    REQUIRE(proc.add_cc_mapping(7, 0, 0, 0.0f, 1.0f));

    // Voice 0 is Active.
    proc(midi::note_on{0, 60, 100}, 0);
    REQUIRE(alloc.voice_state(0) == VoiceState::Active);

    // Steal: voice 0 is now PendingSteal (its slot is being recycled).
    proc(midi::note_on{0, 62, 100}, 0);
    REQUIRE(alloc.voice_state(0) == VoiceState::PendingSteal);
    REQUIRE(alloc.voice_handle(0).slot_id == -1);

    // CC arrives mid-steal. Should be enqueued for nobody — the
    // PendingSteal voice has no slot_id yet. Process to drain.
    proc(midi::control_change{0, midi::cc::channel_volume, 127}, 0);
    rt_graph_process(g, kFrames);
    alloc.tick();

    // Voice now Active. The CC value was *not* applied retroactively
    // (this is the documented limitation: PendingSteal voices miss
    // CC events that arrive during their pending window). The voice
    // started with the map callback's velocity (100/127 ≈ 0.787).
    REQUIRE(alloc.voice_state(0) == VoiceState::Active);
    CHECK(bus0_first_sample(g) == doctest::Approx(100.0f / 127.0f).epsilon(1e-5));

    // A subsequent CC arrives now that the voice is Active.
    proc(midi::control_change{0, midi::cc::channel_volume, 64}, 0);
    CHECK(bus0_first_sample(g) == doctest::Approx(64.0f / 127.0f).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor CC: clear_cc_mappings empties the table") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    REQUIRE(proc.add_cc_mapping(7, 0, 0, 0.0f, 1.0f));
    proc(midi::note_on{0, 60, 100}, 0);

    proc(midi::control_change{0, midi::cc::channel_volume, 0}, 0);
    REQUIRE(bus0_first_sample(g) == doctest::Approx(0.0f).epsilon(1e-5));

    proc.clear_cc_mappings();

    proc(midi::control_change{0, midi::cc::channel_volume, 127}, 0);
    // After clear, the table is empty; bus 0 stays at the previous
    // value (0).
    CHECK(bus0_first_sample(g) == doctest::Approx(0.0f).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor CC: mapping table caps at kMaxCCMappings (32)") {
    auto *g = make_graph_with_polyphony(1);
    VoiceAllocator alloc(g, 0, 1, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    for (int i = 0; i < 32; ++i) {
        CHECK(proc.add_cc_mapping(static_cast<std::uint8_t>(i), 0, 0));
    }
    // 33rd binding is rejected.
    CHECK_FALSE(proc.add_cc_mapping(99, 0, 0));

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Phase 3.3a: pitch-bend dispatch
// ----------------------------------------------------------------

TEST_CASE("MidiVoiceProcessor PB: bound pitch-bend at centre writes the unbent base frequency") {
    // Bind pitch-bend to Add's control[0]. Note 60 → MIDI middle C
    // → ~261.626 Hz via Q's 12-TET pitch utilities. Centred bend
    // (value 8192) gives a multiplier of 1.0.
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    proc.set_pitch_bend(/*node*/ 0, /*ctl*/ 0, /*range*/ 2.0f);

    proc(midi::note_on{0, 60, 100}, 0);
    REQUIRE(alloc.voice_state(0) == VoiceState::Active);

    proc(midi::pitch_bend{0, 8192}, 0);
    CHECK(proc.pitch_bend_events() == 1);

    // Q's as_frequency uses fast log2/pow2 — float tolerance for
    // the round-trip. ~261.6 Hz for note 60.
    CHECK(bus0_first_sample(g) == doctest::Approx(261.6f).epsilon(0.01));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor PB: positive bend raises frequency by 2^(range/12)") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    proc.set_pitch_bend(0, 0, 2.0f);
    proc(midi::note_on{0, 60, 100}, 0);

    // Maximum positive bend (16383) → bend ≈ +1.0 → multiplier 2^(2/12)
    // ≈ 1.1224.
    proc(midi::pitch_bend{0, 16383}, 0);

    constexpr float base = 261.6256f;          // MIDI 60
    const float expected = base * 1.1224620f;  // ~293.6
    CHECK(bus0_first_sample(g) == doctest::Approx(expected).epsilon(0.01));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor PB: negative bend lowers frequency by 1/2^(range/12)") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    proc.set_pitch_bend(0, 0, 2.0f);
    proc(midi::note_on{0, 60, 100}, 0);

    // Minimum bend (0) → bend = -1.0 → multiplier 2^(-2/12) ≈ 0.8909.
    proc(midi::pitch_bend{0, 0}, 0);

    constexpr float base = 261.6256f;
    const float expected = base * 0.8908987f;  // ~233.1
    CHECK(bus0_first_sample(g) == doctest::Approx(expected).epsilon(0.01));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor PB: unbound pitch-bend is a no-op") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    // No set_pitch_bend call.
    proc(midi::note_on{0, 60, 100}, 0);
    const float before = bus0_first_sample(g);

    proc(midi::pitch_bend{0, 16383}, 0);
    CHECK(proc.pitch_bend_events() == 1);   // event was dispatched
    // But the voice's control did not change.
    CHECK(bus0_first_sample(g) == doctest::Approx(before).epsilon(1e-6));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor PB: clear_pitch_bend disables the binding") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    proc.set_pitch_bend(0, 0, 2.0f);
    proc(midi::note_on{0, 60, 100}, 0);

    proc(midi::pitch_bend{0, 8192}, 0);
    const float bound_value = bus0_first_sample(g);
    REQUIRE(bound_value == doctest::Approx(261.6f).epsilon(0.01));

    proc.clear_pitch_bend();
    proc(midi::pitch_bend{0, 16383}, 0);
    // Bound value unchanged.
    CHECK(bus0_first_sample(g) == doctest::Approx(bound_value).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor PB: applies independently to every voice's own note") {
    // Two voices, two different notes. A single pitch-bend message
    // updates each voice's frequency control to its own base * factor.
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    proc.set_pitch_bend(0, 0, 2.0f);

    proc(midi::note_on{0, 60, 100}, 0);   // voice 0, base ~261.6
    proc(midi::note_on{0, 72, 100}, 0);   // voice 1, base ~523.3

    // Centred bend → each voice's freq is its own base.
    proc(midi::pitch_bend{0, 8192}, 0);

    rt_graph_process(g, kFrames);
    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    // Bus 0 carries the sum of both voices' Add(constant) writes:
    // ~261.6 + ~523.3 = ~784.9 (well within the float bus's range).
    CHECK(bus0[0] == doctest::Approx(261.6256f + 523.2511f).epsilon(0.01));

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Phase 3.3b: state inheritance via proc.tick()
// ----------------------------------------------------------------

TEST_CASE("MidiVoiceProcessor 3.3b: synchronous note_on inherits cached CC value") {
    // Setup: CC binding + a CC observed BEFORE any voice is alive.
    // The next note_on activates a voice synchronously; proc.tick()
    // walks newly-Active voices and replays the cached CC value,
    // overwriting whatever the map callback wrote.
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    REQUIRE(proc.add_cc_mapping(7, 0, 0, 0.0f, 1.0f));

    // CC arrives with no voice active. No per-voice writes happen,
    // but the mapping caches last_value.
    proc(midi::control_change{0, midi::cc::channel_volume, 64}, 0);

    // Note on: map callback writes velocity = 100/127 to control 0.
    proc(midi::note_on{0, 60, 100}, 0);
    REQUIRE(alloc.voice_state(0) == VoiceState::Active);

    // Without proc.tick() the cached value would not have landed yet.
    // tick() inherits — control 0 is overwritten with 64/127.
    proc.tick();

    CHECK(bus0_first_sample(g) == doctest::Approx(64.0f / 127.0f).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor 3.3b: pending-steal voice inherits cached CC at activation") {
    // The headline scenario: a CC arrives, a note steals an active
    // voice, and the new voice activates one block later. tick()
    // replays the cached CC onto the newly-active voice — no need
    // for a fresh CC message after activation.
    auto *g = make_graph_with_polyphony(1);
    VoiceAllocator alloc(g, 0, 1, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    REQUIRE(proc.add_cc_mapping(7, 0, 0, 0.0f, 1.0f));

    proc(midi::note_on{0, 60, 100}, 0);
    REQUIRE(alloc.voice_state(0) == VoiceState::Active);

    // CC dispatched to the live voice. Cached value also stored.
    proc(midi::control_change{0, midi::cc::channel_volume, 64}, 0);

    // Steal: voice 0 transitions to PendingSteal.
    proc(midi::note_on{0, 62, 100}, 0);
    REQUIRE(alloc.voice_state(0) == VoiceState::PendingSteal);

    // Drain so the runtime processes Remove(victim) and frees the
    // slot for the pending reservation. proc.tick() then activates
    // the new voice AND replays the cached CC value.
    rt_graph_process(g, kFrames);
    proc.tick();

    REQUIRE(alloc.voice_state(0) == VoiceState::Active);
    // Bus 0 reflects the inherited CC value, not the velocity that
    // the map callback wrote.
    CHECK(bus0_first_sample(g) == doctest::Approx(64.0f / 127.0f).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor 3.3b: no CC observed -> map callback's value stands") {
    // Inheritance only fires for mappings that have observed at
    // least one CC event. Without a prior CC, the map callback's
    // initial control value (velocity here) is what plays.
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    REQUIRE(proc.add_cc_mapping(7, 0, 0, 0.0f, 1.0f));

    // No CC dispatched.
    proc(midi::note_on{0, 60, 100}, 0);
    proc.tick();

    // Velocity 100/127 from the map callback.
    CHECK(bus0_first_sample(g) == doctest::Approx(100.0f / 127.0f).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor 3.3b: pitch-bend bound -> centred default is the inherited value") {
    // Binding pitch-bend to a control implies pitch-bend ownership.
    // A newly-activated voice gets its base frequency on that
    // control even before the first pitch-bend event — the centred
    // default factor (1.0) IS the inherited value.
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    proc.set_pitch_bend(0, 0, 2.0f);

    proc(midi::note_on{0, 60, 100}, 0);
    proc.tick();

    // No pitch-bend message was sent. The voice's control 0 was
    // first written to velocity by the map callback, then
    // overwritten by inheritance to base freq (~261.6 Hz for C4).
    CHECK(bus0_first_sample(g) == doctest::Approx(261.6f).epsilon(0.01));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor 3.3b: pitch-bend last value is inherited at activation") {
    auto *g = make_graph_with_polyphony(1);
    VoiceAllocator alloc(g, 0, 1, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    proc.set_pitch_bend(0, 0, 2.0f);

    // First voice + a +1 semitone bend (raw 12288 ~ +0.5 of range).
    proc(midi::note_on{0, 60, 100}, 0);
    proc.tick();   // initial inheritance: centred → base freq.
    proc(midi::pitch_bend{0, 12288}, 0);  // ~+1 semitone

    // Steal: voice 0 PendingSteal.
    proc(midi::note_on{0, 72, 100}, 0);
    REQUIRE(alloc.voice_state(0) == VoiceState::PendingSteal);

    rt_graph_process(g, kFrames);
    proc.tick();

    REQUIRE(alloc.voice_state(0) == VoiceState::Active);
    REQUIRE(alloc.voice_note(0) == 72);

    // The new voice's note is 72 (C5, ~523.25 Hz). The held bend
    // factor is 2^((bend * 2) / 12) for bend = (12288 - 8192)/8192 = 0.5,
    // so factor = 2^(1/12) ≈ 1.0595. Expected freq ≈ 554.4 Hz.
    constexpr float base_72 = 523.2511f;
    const float bend = (12288.0f - 8192.0f) / 8192.0f;
    const float factor = std::pow(2.0f, (bend * 2.0f) / 12.0f);
    CHECK(bus0_first_sample(g) == doctest::Approx(base_72 * factor).epsilon(0.02));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor 3.3b: re-trigger on same voice index re-fires inheritance") {
    // After auto-free + a fresh note_on, the same voice index hosts
    // a different generation. Inheritance must fire again — the
    // (voice_index, generation) gate is what makes replay correct.
    auto *g = make_graph_with_polyphony(1);
    VoiceAllocator alloc(g, 0, 1, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    REQUIRE(proc.add_cc_mapping(7, 0, 0, 0.0f, 1.0f));

    // Round 1: dispatch CC, activate, tick.
    proc(midi::control_change{0, midi::cc::channel_volume, 32}, 0);
    proc(midi::note_on{0, 60, 100}, 0);
    proc.tick();
    REQUIRE(bus0_first_sample(g) == doctest::Approx(32.0f / 127.0f).epsilon(1e-5));

    // Round 2: free the voice, re-trigger. (Use realtime_remove via
    // note_off since there's no Env on this template.)
    proc(midi::note_off{0, 60, 0}, 0);
    rt_graph_process(g, kFrames);  // drain release → auto-free
    proc.tick();                   // reaps Releasing → Free

    // Update cached CC, then re-trigger.
    proc(midi::control_change{0, midi::cc::channel_volume, 96}, 0);
    proc(midi::note_on{0, 64, 100}, 0);
    proc.tick();   // newly-activated voice picks up the new cache

    CHECK(bus0_first_sample(g) == doctest::Approx(96.0f / 127.0f).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor 3.3b: tick() is idempotent on a stable Active voice") {
    // The inheritance gate is (voice_index, generation): once
    // applied for a given activation, subsequent ticks must not
    // re-fire. We verify by writing a sentinel value directly to
    // the voice's control between ticks; if tick re-applied
    // inheritance, the sentinel would be overwritten.
    auto *g = make_graph_with_polyphony(1);
    VoiceAllocator alloc(g, 0, 1, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    REQUIRE(proc.add_cc_mapping(7, 0, 0, 0.0f, 1.0f));
    proc(midi::control_change{0, midi::cc::channel_volume, 64}, 0);
    proc(midi::note_on{0, 60, 100}, 0);
    proc.tick();
    REQUIRE(bus0_first_sample(g) == doctest::Approx(64.0f / 127.0f).epsilon(1e-5));

    // Direct sentinel write on the live slot (bypasses the queue).
    // This is a [T:control] entry — safe in offline tests where
    // no audio thread is racing.
    const int slot_id = alloc.voice_handle(0).slot_id;
    REQUIRE(slot_id >= 0);
    rt_graph_instance_set_control(g, slot_id, 0, 0, 0.99);
    REQUIRE(bus0_first_sample(g) == doctest::Approx(0.99f).epsilon(1e-5));

    // Three consecutive ticks. If inheritance re-fired on any of
    // them, the queued SetControl would overwrite 0.99 with the
    // cached 64/127.
    proc.tick();
    proc.tick();
    proc.tick();

    CHECK(bus0_first_sample(g) == doctest::Approx(0.99f).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor 3.3b: clear_cc_mappings drops the inheritance cache") {
    auto *g = make_graph_with_polyphony(1);
    VoiceAllocator alloc(g, 0, 1, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    REQUIRE(proc.add_cc_mapping(7, 0, 0, 0.0f, 1.0f));
    proc(midi::control_change{0, midi::cc::channel_volume, 32}, 0);

    // Clear before the next note_on. The cache is dropped along
    // with the mapping (the new mapping starts with no cache).
    proc.clear_cc_mappings();
    REQUIRE(proc.add_cc_mapping(7, 0, 0, 0.0f, 1.0f));

    proc(midi::note_on{0, 60, 100}, 0);
    proc.tick();

    // No CC observed since rebind → no inheritance → bus reflects
    // velocity (100/127), not the pre-clear cached value.
    CHECK(bus0_first_sample(g) == doctest::Approx(100.0f / 127.0f).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor 3.3b: clear_pitch_bend disables the inheritance default") {
    auto *g = make_graph_with_polyphony(1);
    VoiceAllocator alloc(g, 0, 1, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc);

    proc.set_pitch_bend(0, 0, 2.0f);
    proc.clear_pitch_bend();

    proc(midi::note_on{0, 60, 100}, 0);
    proc.tick();

    // No PB binding → no centred default applied. Velocity from
    // the map callback stands.
    CHECK(bus0_first_sample(g) == doctest::Approx(100.0f / 127.0f).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("MidiVoiceProcessor PB: channel mask filters pitch-bend events") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, simple_map, nullptr);
    MidiVoiceProcessor proc(alloc, /*ch 0 only*/ 0x0001);

    proc.set_pitch_bend(0, 0, 2.0f);
    proc(midi::note_on{0, 60, 100}, 0);
    const float before = bus0_first_sample(g);

    // Bend on channel 1 — filtered out, so the voice (which lives on
    // channel 0's allocator) keeps its previous value.
    proc(midi::pitch_bend{1, 16383}, 0);
    CHECK(proc.filtered_events() == 1);
    CHECK(proc.pitch_bend_events() == 0);
    CHECK(bus0_first_sample(g) == doctest::Approx(before).epsilon(1e-6));

    rt_graph_destroy(g);
}
