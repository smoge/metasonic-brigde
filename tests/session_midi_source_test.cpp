// ================================================================
// session_midi_source_test.cpp
// Description : Tests for the session MIDI decoded source C ABI
// ================================================================
//
// These tests stay hardware-free. Live PortMIDI/Q device behavior is
// covered by higher-level manual smoke tests; this file pins the small
// ABI surface that can regress without an attached controller.

#include <doctest/doctest.h>

#include "session_midi_source.h"

TEST_CASE("rt_session_midi_source: event tags stay stable") {
    CHECK(RT_SESSION_MIDI_EVENT_NONE == 0);
    CHECK(RT_SESSION_MIDI_EVENT_NOTE_ON == 1);
    CHECK(RT_SESSION_MIDI_EVENT_NOTE_OFF == 2);
    CHECK(RT_SESSION_MIDI_EVENT_CONTROL_CHANGE == 3);
}

TEST_CASE("rt_session_midi_source: null handles and null outputs reject safely") {
    int channel = 99;
    int data1 = 99;
    int data2 = 99;

    CHECK(rt_session_midi_source_has_device(nullptr) == -1);
    CHECK(rt_session_midi_source_poll(nullptr, &channel, &data1, &data2) == -1);

    rt_session_midi_source *h =
        rt_session_midi_source_open(/*midi_device_index=*/2147483647);
    REQUIRE(h != nullptr);

    CHECK(rt_session_midi_source_poll(h, nullptr, &data1, &data2) == -1);
    CHECK(rt_session_midi_source_poll(h, &channel, nullptr, &data2) == -1);
    CHECK(rt_session_midi_source_poll(h, &channel, &data1, nullptr) == -1);

    rt_session_midi_source_close(h);
    rt_session_midi_source_close(nullptr);
}
