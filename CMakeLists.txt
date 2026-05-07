cmake_minimum_required(VERSION 3.20)
project(tinysynth_tooling LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_library(tinysynth_rt STATIC
    tinysynth/rt_graph.cpp
    tinysynth/voice_allocator.cpp
    tinysynth/midi_voice_processor.cpp
    vendor/q/q_io/src/audio_device.cpp
    vendor/q/q_io/src/audio_stream.cpp
)

target_include_directories(tinysynth_rt
    PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/tinysynth
    # q_lib/include + infra/include are PUBLIC because
    # midi_voice_processor.h exposes q::midi_1_0::note_on /
    # note_off types in its function signatures, and q_lib's
    # headers transitively include infra/. Dependents
    # (tinysynth_tests, the Haskell side via cxx-sources) need
    # the same paths.
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/q/q_lib/include
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/infra/include
    PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/q
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/q/q_io/include
)

target_link_libraries(tinysynth_rt PRIVATE
    portaudio
    portmidi
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
    )

    target_link_libraries(tinysynth_tests PRIVATE
        tinysynth_rt
        doctest::doctest
    )

    include(${doctest_SOURCE_DIR}/scripts/cmake/doctest.cmake)
    doctest_discover_tests(tinysynth_tests)
endif()