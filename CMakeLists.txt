cmake_minimum_required(VERSION 3.20)
project(tinysynth_tooling LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_library(tinysynth_rt STATIC
    tinysynth/rt_graph.cpp
    vendor/q/q_io/src/audio_device.cpp
    vendor/q/q_io/src/audio_stream.cpp
)

target_include_directories(tinysynth_rt
    PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/tinysynth
    PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/q
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/q/q_lib/include
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/q/q_io/include
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/infra/include
)

target_link_libraries(tinysynth_rt PRIVATE
    portaudio
    portmidi
)

add_executable(rt_graph_smoke
    tools/rt_graph_smoke.cpp
)

target_link_libraries(rt_graph_smoke PRIVATE tinysynth_rt)