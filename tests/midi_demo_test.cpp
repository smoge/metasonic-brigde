// ================================================================
// midi_demo_test.cpp
// Description : Tests for the Phase 3 closing piece (live-MIDI runner)
// ================================================================
//
// These tests cover the C ABI of midi_demo.h: argument validation,
// open/close lifecycle, null-handle safety on every accessor, and
// the no-MIDI-device path. They do NOT require an actual MIDI
// controller — Q's midi_input_stream returns is_valid() == false
// when PortMIDI cannot open a device, and the worker thread observes
// that and stays idle. We verify counters stay at zero in that case.

#include <doctest/doctest.h>

#include "midi_demo.h"
#include "rt_graph.h"

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <thread>
#include <vector>

namespace {

constexpr int kFrames = 1024;

// Two-node template: an Add (kind = 8) feeding an Out (kind = 2).
// Add has two control inputs (used by the demo's freq + gate
// writes); Out has one (channel). This is the same shape used by
// the MidiVoiceProcessor tests — the graph is pure plumbing here,
// since no actual MIDI traffic flows in CI.
RTGraph *make_demo_graph(int polyphony) {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_template_add_node(g, 0, 0, 8);
    rt_graph_template_set_default(g, 0, 0, 0, 0.0);
    rt_graph_template_set_default(g, 0, 0, 1, 0.0);
    rt_graph_template_add_node(g, 0, 1, 2);
    rt_graph_template_set_default(g, 0, 1, 0, 0.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);

    rt_graph_template_set_polyphony(g, 0, polyphony);

    // Pre-warm the per-template pool so VoiceAllocator finds
    // Available slots on its first reserve. Mirrors the
    // make_graph_with_polyphony helper in midi_voice_processor_test.
    rt_graph_instance_remove(g, 0);
    std::vector<int> ids(static_cast<std::size_t>(polyphony));
    for (int i = 0; i < polyphony; ++i) {
        ids[static_cast<std::size_t>(i)] = rt_graph_template_instance_add(g, 0);
        REQUIRE(ids[static_cast<std::size_t>(i)] >= 0);
    }
    for (int id : ids) rt_graph_instance_remove(g, id);

    return g;
}

rt_midi_voice_mapping default_voice_mapping() {
    rt_midi_voice_mapping m{};
    m.freq_node_index    = 0;
    m.freq_control_index = 0;
    m.gate_node_index    = 0;
    m.gate_control_index = 1;
    m.vel_node_index     = -1;  // skip
    m.vel_control_index  = -1;
    return m;
}

} // namespace

TEST_CASE("rt_midi_demo: open/close lifecycle joins the worker cleanly") {
    auto *g = make_demo_graph(2);
    auto  m = default_voice_mapping();

    auto *h = rt_midi_demo_open(g, /*template_id=*/0, /*polyphony=*/2,
                                /*device_index=*/-1, &m,
                                /*cc=*/nullptr, /*cc_count=*/0,
                                /*pitch_bend=*/nullptr,
                                /*channel_mask=*/0xFFFFu);
    REQUIRE(h != nullptr);

    // Give the worker thread a chance to enter run() and snapshot
    // has_device. 50 ms is generous; the worker stores it on the
    // first line of run(), so a few ticks of the OS scheduler suffice.
    std::this_thread::sleep_for(std::chrono::milliseconds(50));

    // has_device is 0 (no MIDI device, typical in CI) or 1 (a
    // controller is plugged in on a developer machine). Anything
    // else means the worker never ran or the C ABI got corrupted.
    const int dev = rt_midi_demo_has_device(h);
    CHECK((dev == 0 || dev == 1));

    // No events have been dispatched yet; counters must be zero.
    CHECK(rt_midi_demo_note_on_count(h)     == 0);
    CHECK(rt_midi_demo_note_off_count(h)    == 0);
    CHECK(rt_midi_demo_cc_count(h)          == 0);
    CHECK(rt_midi_demo_pitch_bend_count(h)  == 0);

    rt_midi_demo_close(h);

    rt_graph_destroy(g);
}

TEST_CASE("rt_midi_demo: null inputs reject open and surface -1 on accessors") {
    auto m = default_voice_mapping();

    // Null graph rejected.
    CHECK(rt_midi_demo_open(nullptr, 0, 2, -1, &m,
                             nullptr, 0, nullptr, 0xFFFFu) == nullptr);

    // Null voice_mapping rejected.
    auto *g = make_demo_graph(2);
    CHECK(rt_midi_demo_open(g, 0, 2, -1, nullptr,
                             nullptr, 0, nullptr, 0xFFFFu) == nullptr);
    rt_graph_destroy(g);

    // Null handle is safe on every accessor and on close.
    CHECK(rt_midi_demo_note_on_count(nullptr)     == -1);
    CHECK(rt_midi_demo_note_off_count(nullptr)    == -1);
    CHECK(rt_midi_demo_cc_count(nullptr)          == -1);
    CHECK(rt_midi_demo_pitch_bend_count(nullptr)  == -1);
    CHECK(rt_midi_demo_has_device(nullptr)        == -1);
    rt_midi_demo_close(nullptr);  // must not crash
}

TEST_CASE("rt_midi_device_info: C ABI layout matches Haskell Storable mirror") {
    rt_midi_device_info row{};

    CHECK(sizeof(rt_midi_device_info) == 268);
    CHECK(alignof(rt_midi_device_info) == alignof(int));
    CHECK(offsetof(rt_midi_device_info, id) == 0);
    CHECK(offsetof(rt_midi_device_info, num_inputs) == 4);
    CHECK(offsetof(rt_midi_device_info, num_outputs) == 8);
    CHECK(offsetof(rt_midi_device_info, name) == 12);
    CHECK(sizeof(row.name) == RT_MIDI_DEVICE_NAME_MAX);
    CHECK(RT_MIDI_DEVICE_NAME_MAX == 256);
}

TEST_CASE("rt_midi_device_list: enumeration ABI is safe without MIDI hardware") {
    CHECK(rt_midi_device_list(nullptr, -1) == -1);

    const int count = rt_midi_device_list(nullptr, 0);
    REQUIRE(count >= 0);

    rt_midi_device_info first{};
    const int one_count = rt_midi_device_list(&first, 1);
    CHECK(one_count >= 0);
    if (one_count > 0) {
        CHECK(first.id >= 0);
        CHECK(first.num_inputs >= 0);
        CHECK(first.num_outputs >= 0);
        CHECK(first.name[RT_MIDI_DEVICE_NAME_MAX - 1] == '\0');
    }

    if (count > 0) {
        std::vector<rt_midi_device_info> rows(static_cast<std::size_t>(count));
        const int count2 = rt_midi_device_list(rows.data(), count);
        REQUIRE(count2 >= 0);

        const int copied = std::min(count, count2);
        for (int i = 0; i < copied; ++i) {
            CHECK(rows[static_cast<std::size_t>(i)].id >= 0);
            CHECK(rows[static_cast<std::size_t>(i)].num_inputs >= 0);
            CHECK(rows[static_cast<std::size_t>(i)].num_outputs >= 0);
            CHECK(rows[static_cast<std::size_t>(i)].name[RT_MIDI_DEVICE_NAME_MAX - 1]
                  == '\0');
        }
    }
}

TEST_CASE("rt_midi_demo: CC mappings + pitch-bend binding are accepted at open") {
    auto *g = make_demo_graph(2);
    auto  m = default_voice_mapping();

    rt_midi_cc_mapping cc[2] = {
        { /*cc=*/7,  /*node=*/0, /*ctl=*/0, /*min=*/0.0f, /*max=*/1.0f },
        { /*cc=*/74, /*node=*/0, /*ctl=*/1, /*min=*/0.0f, /*max=*/1.0f },
    };
    rt_midi_pitch_bend_binding pb{ /*node=*/0, /*ctl=*/0,
                                    /*semitone_range=*/2.0f };

    auto *h = rt_midi_demo_open(g, 0, 2, -1, &m, cc, 2, &pb, 0xFFFFu);
    REQUIRE(h != nullptr);

    // Counters are still 0 — the demo accepted the bindings, but no
    // events have been dispatched. We're proving registration didn't
    // throw or corrupt the handle, not that mappings fire.
    CHECK(rt_midi_demo_cc_count(h)         == 0);
    CHECK(rt_midi_demo_pitch_bend_count(h) == 0);

    rt_midi_demo_close(h);
    rt_graph_destroy(g);
}
