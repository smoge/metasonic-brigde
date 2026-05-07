cmake_minimum_required(VERSION 3.20)
project(tinysynth_tooling LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_library(tinysynth_rt STATIC
    tinysynth/rt_graph.cpp
    tinysynth/voice_allocator.cpp
    tinysynth/midi_voice_processor.cpp
    tinysynth/midi_demo.cpp
    # Local replacements for vendor/q/q_io/src/{midi_device,midi_stream}.cpp
    # — see file headers for the patch rationale. Vendor copies are
    # NOT linked in to avoid an ODR collision on midi_device::list /
    # midi_input_stream::~midi_input_stream / detail internals.
    tinysynth/q_midi_device.cpp
    tinysynth/q_midi_stream.cpp
    vendor/q/q_io/src/audio_device.cpp
    vendor/q/q_io/src/audio_stream.cpp
)

target_include_directories(tinysynth_rt
    PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/tinysynth
    # q_lib/include + infra/include are PUBLIC because
    # midi_voice_processor.h exposes q::midi_1_0::note_on /
    # note_off types in its function signatures, and q_lib's
    # headers transitively include infra/.
    # q_io/include is PUBLIC because the documented integration
    # path (in midi_voice_processor.h) wires our processor to
    # q::midi_input_stream, which lives in q_io. Dependents
    # (tinysynth_tests, the Haskell side via cxx-sources) need
    # all three include paths.
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/q/q_lib/include
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/q/q_io/include
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/infra/include
    PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/q
)

target_link_libraries(tinysynth_rt PUBLIC
    portaudio
    portmidi
    # PortMIDI's static lib (libportmidi.a) uses ALSA on Linux but
    # does not propagate the dependency, so dependents must link
    # libasound directly. PUBLIC so tinysynth_tests / rt_graph_smoke
    # / hpack-driven cxx-sources all pick it up.
    asound
)

add_executable(rt_graph_smoke
    tools/rt_graph_smoke.cpp
)

target_link_libraries(rt_graph_smoke PRIVATE tinysynth_rt)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
# C++-native unit tests for rt_graph.cpp internals and DSP correctness.
# The Haskell test suite covers structural / FFI invariants; these tests
# cover what only C++ can: actual sample values from process_*, the
# kind_from_tag dispatch, and edge cases in resolve_input.
#
# Disable with -DMETASONIC_BUILD_TESTS=OFF if no network on first configure.
option(METASONIC_BUILD_TESTS "Build C++ tests for tinysynth_rt" ON)

if(METASONIC_BUILD_TESTS)
    enable_testing()

    include(FetchContent)
    fetchcontent_declare(
        doctest
        GIT_REPOSITORY https://github.com/doctest/doctest.git
        GIT_TAG        v2.4.11
        GIT_SHALLOW    TRUE
    )
    fetchcontent_makeavailable(doctest)

    add_executable(tinysynth_tests
        tests/rt_graph_test.cpp
        tests/voice_allocator_test.cpp
        tests/midi_voice_processor_test.cpp
        tests/midi_demo_test.cpp
    )

    target_link_libraries(tinysynth_tests PRIVATE
        tinysynth_rt
        doctest::doctest
    )

    include(${doctest_SOURCE_DIR}/scripts/cmake/doctest.cmake)
    doctest_discover_tests(tinysynth_tests)
endif()