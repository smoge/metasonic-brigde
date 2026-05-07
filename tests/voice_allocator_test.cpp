// ================================================================
// voice_allocator_test.cpp
// Description : Offline event-sequence tests for VoiceAllocator (Phase 3.1)
// ================================================================
//
// These tests drive metasonic::VoiceAllocator with deterministic
// note_on / note_off / tick sequences and assert voice lifecycle and
// runtime side-effects (bus contents, slot states). No MIDI here —
// 3.2 will plug Q's MIDI stack onto this allocator once the offline
// behavior is locked down.
//
// Template under test: Add(node 0) → Out(node 1, bus 0). The map
// callback writes per-note velocity into Add's control[0] so each
// voice's signature on bus 0 is its velocity value (multiple active
// voices sum). This keeps assertions arithmetic rather than DSP-
// shaped.

#include <doctest/doctest.h>

#include "rt_graph.h"
#include "voice_allocator.h"

#include <algorithm>
#include <cmath>
#include <vector>

using metasonic::VoiceAllocator;
using metasonic::VoiceHandle;
using metasonic::VoiceResult;
using metasonic::VoiceResultStatus;
using metasonic::VoiceState;

namespace {

constexpr int kFrames = 1024;

// Map callback: writes velocity into Add's control[0]. (Both Add
// inputs are unwired, so control[0]+control[1] = velocity+0 = velocity
// is what each block of the kernel emits, which Out then accumulates
// onto bus 0.)
bool write_velocity_as_constant(RTGraph *g, int slot_id, int /*note*/,
                                float velocity, void * /*user_data*/) {
    rt_graph_instance_set_control(g, slot_id, 0, 0, static_cast<double>(velocity));
    return true;
}

// Map callback that always fails — used to exercise the MapFailed path.
bool reject_all(RTGraph * /*g*/, int /*slot*/, int /*note*/,
                float /*vel*/, void * /*ud*/) {
    return false;
}

// Build the standard voice template into template 0 and pre-warm
// `polyphony` Available slots in the runtime pool. Returns the
// running RTGraph; caller destroys.
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

    // Pre-warm: spawn `polyphony` instances first (the first reuses
    // the auto-spawned slot 0; subsequent spawns grow the pool),
    // then remove all of them. That leaves `polyphony` Available
    // slots of the right shape — exactly what realtime_reserve needs
    // since it never grows the pool itself.
    rt_graph_instance_remove(g, 0);
    std::vector<int> ids(static_cast<std::size_t>(polyphony));
    for (int i = 0; i < polyphony; ++i) {
        ids[static_cast<std::size_t>(i)] = rt_graph_template_instance_add(g, 0);
        REQUIRE(ids[static_cast<std::size_t>(i)] >= 0);
    }
    for (int id : ids) rt_graph_instance_remove(g, id);

    return g;
}

float read_bus0_constant(RTGraph *g) {
    rt_graph_process(g, kFrames);
    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    // The template emits a per-block constant, so the first sample
    // is representative.
    return bus0[0];
}

} // namespace

// ----------------------------------------------------------------
// Construction + basic state
// ----------------------------------------------------------------

TEST_CASE("VoiceAllocator: polyphony clamps to >= 1 and reports voice_count") {
    auto *g = make_graph_with_polyphony(4);
    {
        VoiceAllocator alloc(g, 0, 0, write_velocity_as_constant, nullptr);
        CHECK(alloc.voice_count() == 1);    // clamped from 0
    }
    {
        VoiceAllocator alloc(g, 0, -5, write_velocity_as_constant, nullptr);
        CHECK(alloc.voice_count() == 1);    // clamped from negative
    }
    rt_graph_destroy(g);
}

TEST_CASE("VoiceAllocator: every voice starts Free with note=-1") {
    auto *g = make_graph_with_polyphony(4);
    VoiceAllocator alloc(g, 0, 4, write_velocity_as_constant, nullptr);

    CHECK(alloc.voice_count() == 4);
    for (int i = 0; i < 4; ++i) {
        CHECK(alloc.voice_state(i) == VoiceState::Free);
        CHECK(alloc.voice_note(i) == -1);
        CHECK(alloc.voice_handle(i).slot_id == -1);
    }
    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Free-voice path: note_on returns Started, audio routes
// ----------------------------------------------------------------

TEST_CASE("VoiceAllocator: note_on with a Free voice returns Started and routes audio") {
    auto *g = make_graph_with_polyphony(4);
    VoiceAllocator alloc(g, 0, 4, write_velocity_as_constant, nullptr);

    VoiceResult r = alloc.note_on(60, 0.5f);
    CHECK(r.status == VoiceResultStatus::Started);
    REQUIRE(r.voice.voice_index >= 0);
    REQUIRE(r.voice.slot_id >= 0);
    CHECK(r.stolen_slot_id == -1);

    CHECK(alloc.voice_state(r.voice.voice_index) == VoiceState::Active);
    CHECK(alloc.voice_note(r.voice.voice_index) == 60);

    // Bus 0 carries the velocity (per the test's map callback).
    CHECK(read_bus0_constant(g) == doctest::Approx(0.5f));

    rt_graph_destroy(g);
}

TEST_CASE("VoiceAllocator: note_off on Active voice transitions to Releasing") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, write_velocity_as_constant, nullptr);

    auto r = alloc.note_on(60, 0.5f);
    REQUIRE(r.status == VoiceResultStatus::Started);
    const int vi = r.voice.voice_index;

    alloc.note_off(60);
    // Without an Env on the template, runtime release falls through
    // to a hard-free at the next process call. Allocator's record
    // still surfaces Releasing until tick reaps it.
    CHECK(alloc.voice_state(vi) == VoiceState::Releasing);

    rt_graph_process(g, kFrames);
    alloc.tick();

    CHECK(alloc.voice_state(vi) == VoiceState::Free);
    CHECK(alloc.voice_note(vi) == -1);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Stealing
// ----------------------------------------------------------------

TEST_CASE("VoiceAllocator: stealing prefers oldest Releasing over oldest Active") {
    // Sequence: fill polyphony=3 with notes A, B, C; release A; spawn
    // new note D. D should steal A's voice (oldest Releasing) instead
    // of any Active voice.
    auto *g = make_graph_with_polyphony(3);
    VoiceAllocator alloc(g, 0, 3, write_velocity_as_constant, nullptr);

    auto a = alloc.note_on(60, 0.1f);    // age 1
    auto b = alloc.note_on(62, 0.2f);    // age 2
    auto c = alloc.note_on(64, 0.3f);    // age 3
    REQUIRE(a.status == VoiceResultStatus::Started);
    REQUIRE(b.status == VoiceResultStatus::Started);
    REQUIRE(c.status == VoiceResultStatus::Started);

    alloc.note_off(60);                                 // A → Releasing
    REQUIRE(alloc.voice_state(a.voice.voice_index) == VoiceState::Releasing);

    auto d = alloc.note_on(67, 0.4f);                   // should steal A
    CHECK(d.status == VoiceResultStatus::PendingSteal);
    CHECK(d.voice.voice_index == a.voice.voice_index);
    CHECK(d.stolen_slot_id == a.voice.slot_id);
    // Generation bumped on steal → no longer matches A's handle.
    CHECK(d.voice.generation != a.voice.generation);

    // B and C unchanged.
    CHECK(alloc.voice_state(b.voice.voice_index) == VoiceState::Active);
    CHECK(alloc.voice_state(c.voice.voice_index) == VoiceState::Active);

    rt_graph_destroy(g);
}

TEST_CASE("VoiceAllocator: stealing falls back to oldest Active when no Releasing voice exists") {
    auto *g = make_graph_with_polyphony(3);
    VoiceAllocator alloc(g, 0, 3, write_velocity_as_constant, nullptr);

    auto a = alloc.note_on(60, 0.1f);    // oldest
    auto b = alloc.note_on(62, 0.2f);
    auto c = alloc.note_on(64, 0.3f);
    REQUIRE(a.status == VoiceResultStatus::Started);
    REQUIRE(b.status == VoiceResultStatus::Started);
    REQUIRE(c.status == VoiceResultStatus::Started);

    auto d = alloc.note_on(67, 0.4f);    // all Active → steal oldest (A)
    CHECK(d.status == VoiceResultStatus::PendingSteal);
    CHECK(d.voice.voice_index == a.voice.voice_index);
    CHECK(d.stolen_slot_id == a.voice.slot_id);

    rt_graph_destroy(g);
}

TEST_CASE("VoiceAllocator: PendingSteal becomes Active after tick + drain") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, write_velocity_as_constant, nullptr);

    auto a = alloc.note_on(60, 0.5f);
    auto b = alloc.note_on(62, 0.5f);
    REQUIRE(a.status == VoiceResultStatus::Started);
    REQUIRE(b.status == VoiceResultStatus::Started);

    auto c = alloc.note_on(64, 0.5f);    // steals oldest Active (a)
    REQUIRE(c.status == VoiceResultStatus::PendingSteal);
    CHECK(alloc.voice_state(c.voice.voice_index) == VoiceState::PendingSteal);

    // Drain the queue (Remove on victim's slot fires) and tick to
    // retry the pending reserve.
    rt_graph_process(g, kFrames);
    alloc.tick();

    CHECK(alloc.voice_state(c.voice.voice_index) == VoiceState::Active);
    CHECK(alloc.voice_note(c.voice.voice_index) == 64);
    // The newly-active voice has a slot_id now.
    CHECK(alloc.voice_handle(c.voice.voice_index).slot_id >= 0);

    rt_graph_destroy(g);
}

TEST_CASE("VoiceAllocator: note_off on PendingSteal drops the pending allocation") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, write_velocity_as_constant, nullptr);

    auto a = alloc.note_on(60, 0.5f);
    auto b = alloc.note_on(62, 0.5f);
    REQUIRE(a.status == VoiceResultStatus::Started);
    REQUIRE(b.status == VoiceResultStatus::Started);

    auto c = alloc.note_on(64, 0.5f);
    REQUIRE(c.status == VoiceResultStatus::PendingSteal);

    // Caller changes their mind before tick activates the steal.
    alloc.note_off(64);
    CHECK(alloc.voice_state(c.voice.voice_index) == VoiceState::Free);
    CHECK(alloc.voice_note(c.voice.voice_index) == -1);

    // Drain the victim's queued Remove. tick must NOT resurrect the
    // cancelled note — the voice stays Free.
    rt_graph_process(g, kFrames);
    alloc.tick();
    CHECK(alloc.voice_state(c.voice.voice_index) == VoiceState::Free);

    // The freed slot is now usable again. A subsequent note_on
    // succeeds synchronously (Started, not PendingSteal).
    auto e = alloc.note_on(67, 0.5f);
    CHECK(e.status == VoiceResultStatus::Started);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Generation
// ----------------------------------------------------------------

TEST_CASE("VoiceAllocator: generation bumps on note_on, not on Active->Releasing") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, write_velocity_as_constant, nullptr);

    auto a = alloc.note_on(60, 0.5f);
    REQUIRE(a.status == VoiceResultStatus::Started);
    const auto gen_after_on = a.voice.generation;

    alloc.note_off(60);
    // Same logical owner — no bump.
    CHECK(alloc.voice_handle(a.voice.voice_index).generation == gen_after_on);

    // Reap.
    rt_graph_process(g, kFrames);
    alloc.tick();
    CHECK(alloc.voice_state(a.voice.voice_index) == VoiceState::Free);
    // Auto-free does NOT bump (generation only changes on the next
    // assignment).
    CHECK(alloc.voice_handle(a.voice.voice_index).generation == gen_after_on);

    auto b = alloc.note_on(72, 0.5f);
    REQUIRE(b.status == VoiceResultStatus::Started);
    if (b.voice.voice_index == a.voice.voice_index) {
        // Reused this voice — generation must have advanced.
        CHECK(b.voice.generation > gen_after_on);
    }

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Map callback failure
// ----------------------------------------------------------------

TEST_CASE("VoiceAllocator: map callback returning false yields MapFailed and cancels reservation") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, reject_all, nullptr);

    auto r = alloc.note_on(60, 0.5f);
    CHECK(r.status == VoiceResultStatus::MapFailed);
    CHECK(r.voice.slot_id == -1);

    // Voice did not transition out of Free; another note_on with a
    // working callback (we can't swap, so instead verify the slot
    // pool is still pristine: a fresh allocator gets a Started).
    VoiceAllocator alloc2(g, 0, 2, write_velocity_as_constant, nullptr);
    auto r2 = alloc2.note_on(60, 0.5f);
    CHECK(r2.status == VoiceResultStatus::Started);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// all_notes_off
// ----------------------------------------------------------------

TEST_CASE("VoiceAllocator: all_notes_off clears every voice and resets the runtime") {
    auto *g = make_graph_with_polyphony(3);
    VoiceAllocator alloc(g, 0, 3, write_velocity_as_constant, nullptr);

    REQUIRE(alloc.note_on(60, 0.1f).status == VoiceResultStatus::Started);
    REQUIRE(alloc.note_on(62, 0.2f).status == VoiceResultStatus::Started);
    REQUIRE(alloc.note_on(64, 0.3f).status == VoiceResultStatus::Started);

    alloc.all_notes_off();
    for (int i = 0; i < alloc.voice_count(); ++i) {
        CHECK(alloc.voice_state(i) == VoiceState::Free);
        CHECK(alloc.voice_note(i) == -1);
    }

    rt_graph_process(g, kFrames);
    // Bus 0 is silent: every Active runtime slot was Removed.
    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    for (auto x : bus0) CHECK(x == doctest::Approx(0.0f));

    // Pool fully reusable: a new round of note_ons succeeds.
    REQUIRE(alloc.note_on(72, 0.4f).status == VoiceResultStatus::Started);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Bus accounting: multiple voices sum on bus 0
// ----------------------------------------------------------------

TEST_CASE("VoiceAllocator: bus 0 sums per-voice constants from all Active voices") {
    auto *g = make_graph_with_polyphony(3);
    VoiceAllocator alloc(g, 0, 3, write_velocity_as_constant, nullptr);

    REQUIRE(alloc.note_on(60, 0.1f).status == VoiceResultStatus::Started);
    REQUIRE(alloc.note_on(62, 0.2f).status == VoiceResultStatus::Started);
    REQUIRE(alloc.note_on(64, 0.3f).status == VoiceResultStatus::Started);

    // Three voices, velocities 0.1 + 0.2 + 0.3 = 0.6.
    CHECK(read_bus0_constant(g) == doctest::Approx(0.6f).epsilon(1e-6));

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// note_off on unknown / Free / out-of-range
// ----------------------------------------------------------------

TEST_CASE("VoiceAllocator: note_off on never-played note is a no-op") {
    auto *g = make_graph_with_polyphony(2);
    VoiceAllocator alloc(g, 0, 2, write_velocity_as_constant, nullptr);

    alloc.note_off(60);            // never played
    alloc.note_off(-1);            // out of range
    alloc.note_off(200);           // out of range

    for (int i = 0; i < alloc.voice_count(); ++i) {
        CHECK(alloc.voice_state(i) == VoiceState::Free);
    }
    rt_graph_destroy(g);
}
