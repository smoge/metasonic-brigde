// ================================================================
// q_midi_device_test.cpp
// Description : Pins the by-value contract for cycfi::q::midi_device
// ================================================================
//
// AddressSanitizer caught a heap-buffer-overflow in
// cycfi::q::midi_device::list() when parallel Tasty workers held
// midi_device results across a subsequent list() call. The root
// cause was Q's header declaring midi_device with
//     impl const& _impl;
// referencing a static accumulator that the next list() call
// clear()ed and repopulated. The fix is the local shadow header
// tinysynth/q_io/midi_device.hpp which stores _impl by value, making
// returned midi_device objects independent of any shared backing
// storage. These tests pin that contract so a future revert (or a
// vendor submodule update that silently restores the borrowed-ref
// layout) fails here instead of at runtime under ASan.

#include <doctest/doctest.h>

#include <q_io/midi_device.hpp>

#include <cstddef>
#include <string>

// Compile-time guard. If midi_device reverts to storing impl const&,
// sizeof drops to a single pointer. The by-value layout contains at
// least a std::string plus a uint32_t plus two size_t, well over a
// pointer's width. Catch the revert at build time.
static_assert(
    sizeof(cycfi::q::midi_device)
        >= sizeof(std::string) + sizeof(std::size_t),
    "midi_device must own its impl by value; reverting to impl const& "
    "would reintroduce the dangling-reference bug captured by ASan."
);

TEST_CASE("midi_device::list: results survive a subsequent list() call (lifetime)") {
    // Exact lifetime pattern ASan flagged: hold one list result,
    // call list() again, then read from the first result. Pre-fix
    // the second list() invalidated the first's backing storage and
    // the .id() / .name() reads were heap-use-after-free.
    //
    // Skipped automatically on hosts with no MIDI device visible —
    // the static_assert above still enforces the by-value layout,
    // and the parallel Tasty suite under ASan exercises the path
    // end-to-end when enumeration is reachable.
    auto first = cycfi::q::midi_device::list();
    if (first.empty()) {
        MESSAGE("skipping lifetime check: no MIDI devices visible");
        return;
    }

    const auto saved_id = first[0].id();
    const auto saved_name = first[0].name();
    const auto saved_in = first[0].num_inputs();
    const auto saved_out = first[0].num_outputs();

    // Force a second enumeration. Pre-fix this would have
    // invalidated first[0]'s backing storage.
    auto second [[maybe_unused]] = cycfi::q::midi_device::list();

    CHECK(first[0].id() == saved_id);
    CHECK(first[0].name() == saved_name);
    CHECK(first[0].num_inputs() == saved_in);
    CHECK(first[0].num_outputs() == saved_out);
}
