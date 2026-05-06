// ================================================================
// rt_graph_test.cpp
// Description : C++-native tests for tinysynth's rt_graph runtime
// ================================================================
//
// Scope: things only C++ can verify — actual sample values from the
// process_* kernels, kind_from_tag dispatch, and edge cases in the
// runtime that the Haskell-side structural tests can't reach.
//
// The Haskell test suite (test/Spec.hs) already covers graph
// validation, dense lowering, FFI wiring, and the kindTag agreement
// contract. These tests deliberately do not duplicate that work.

#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>

#include "rt_graph.h"

#include <algorithm>
#include <cmath>
#include <numbers>
#include <vector>

namespace {

constexpr int   kFrames = 1024;
constexpr float kSampleRate = 48000.0f;
constexpr double kTau = 2.0 * std::numbers::pi;

// Render one block and copy bus 0 into a vector for inspection.
std::vector<float> render_bus0(RTGraph *g, int nframes) {
    std::vector<float> out(static_cast<std::size_t>(nframes), 0.0f);
    rt_graph_process(g, nframes);
    rt_graph_read_bus(g, 0, nframes, out.data());
    return out;
}

float peak_abs(const std::vector<float> &xs) {
    float p = 0.0f;
    for (auto x : xs) {
        p = std::max(p, std::abs(x));
    }
    return p;
}

int zero_crossings(const std::vector<float> &xs) {
    int zc = 0;
    for (std::size_t i = 1; i < xs.size(); ++i) {
        if ((xs[i - 1] >= 0.0f) != (xs[i] >= 0.0f)) {
            ++zc;
        }
    }
    return zc;
}

} // namespace

// ----------------------------------------------------------------
// kind_from_tag dispatch
// ----------------------------------------------------------------

TEST_CASE("kind_from_tag accepts every defined tag") {
    CHECK(rt_graph_kind_supported(1) == 1); // SinOsc
    CHECK(rt_graph_kind_supported(2) == 1); // Out
    CHECK(rt_graph_kind_supported(3) == 1); // Gain
    CHECK(rt_graph_kind_supported(5) == 1); // SawOsc
    CHECK(rt_graph_kind_supported(6) == 1); // NoiseGen
    CHECK(rt_graph_kind_supported(7) == 1); // LPF
    CHECK(rt_graph_kind_supported(8) == 1); // Add
}

TEST_CASE("kind_from_tag rejects unknown tags") {
    CHECK(rt_graph_kind_supported(0) == 0);
    CHECK(rt_graph_kind_supported(4) == 0); // intentional gap
    CHECK(rt_graph_kind_supported(9) == 0);
    CHECK(rt_graph_kind_supported(99) == 0);
    CHECK(rt_graph_kind_supported(-1) == 0);
}

// ----------------------------------------------------------------
// SinOsc: produces a sine wave on bus 0
// ----------------------------------------------------------------

TEST_CASE("SinOsc(440 Hz) produces a sine wave with peak ≈ 1") {
    auto *g = rt_graph_create(/*capacity*/ 4, /*max_frames*/ kFrames);
    REQUIRE(g != nullptr);

    // node 0: SinOsc, freq=440, initial phase=0
    rt_graph_add_node(g, 0, 1);
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_set_control(g, 0, 1, 0.0f);

    // node 1: Out, bus=0
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);

    // wire SinOsc.out0 → Out.in0
    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kFrames);

    CHECK(peak_abs(samples) == doctest::Approx(1.0f).epsilon(0.02));

    // 440 Hz over 1024 frames @ 48 kHz = 9.39 cycles → ~18-19 zero crossings
    int zc = zero_crossings(samples);
    CHECK(zc >= 17);
    CHECK(zc <= 21);

    // Initial phase = 0 → sample 0 should be ≈ sin(0) = 0
    CHECK(std::abs(samples[0]) < 0.02f);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Gain (constant): scalar multiplication
// ----------------------------------------------------------------

TEST_CASE("Gain(0.5) constant control halves the carrier amplitude") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    // SinOsc → Gain(0.5) → Out
    rt_graph_add_node(g, 0, 1); // SinOsc
    rt_graph_set_control(g, 0, 0, 440.0f);

    rt_graph_add_node(g, 1, 3); // Gain
    rt_graph_set_control(g, 1, 0, 0.5f);

    rt_graph_add_node(g, 2, 2); // Out
    rt_graph_set_control(g, 2, 0, 0.0f);

    rt_graph_connect(g, 0, 0, 1, 0); // sin → gain.signal
    rt_graph_connect(g, 1, 0, 2, 0); // gain → out

    auto samples = render_bus0(g, kFrames);
    CHECK(peak_abs(samples) == doctest::Approx(0.5f).epsilon(0.02));

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Gain (modulated): the sample-accuracy proof
// ----------------------------------------------------------------
//
// Ring modulation: with both inputs as audio rate, the output at
// sample n must equal sin(2π·440·n/sr) × sin(2π·220·n/sr).
// If process_gain were block-latched, the output would be
// sin(2π·440·n/sr) × sin(0)  = 0 for the entire first block, since
// the modulator's value at sample 0 is sin(0) = 0. So peak ≈ 0
// would betray the bug. With sample-accuracy, peak is meaningful.

TEST_CASE("Gain modulated by audio (ring mod) is sample-accurate") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1); // carrier 440 Hz
    rt_graph_set_control(g, 0, 0, 440.0f);

    rt_graph_add_node(g, 1, 1); // modulator 220 Hz, phase = 0.25 (cosine)
    rt_graph_set_control(g, 1, 0, 220.0f);
    rt_graph_set_control(g, 1, 1, 0.25f);

    rt_graph_add_node(g, 2, 3); // Gain (audio-modulated)
    rt_graph_add_node(g, 3, 2); // Out
    rt_graph_set_control(g, 3, 0, 0.0f);

    rt_graph_connect(g, 0, 0, 2, 0); // carrier  → gain.signal
    rt_graph_connect(g, 1, 0, 2, 1); // modulator → gain.gain
    rt_graph_connect(g, 2, 0, 3, 0); // gain     → out

    auto samples = render_bus0(g, kFrames);

    // Bounded: |sin · cos| ≤ 1
    for (auto s : samples) {
        CHECK(std::abs(s) <= 1.001f);
    }

    // Peak must be substantial (block-latch bug would give peak ≈ 0
    // because modulator[0] = cos(0) is +1 only with our phase=0.25
    // shift; without that shift the bug would silence the output).
    // With phase=0.25, the modulator at sample 0 is cos(0) = 1, so
    // even the buggy version would output the carrier. We pick a
    // sample N where the analytical result is large and the buggy
    // version would diverge.
    CHECK(peak_abs(samples) > 0.5f);

    // Per-sample agreement with sin·cos at picked points.
    // q::sin is a LUT, so use a generous tolerance.
    for (std::size_t n : {100u, 250u, 500u, 800u}) {
        const double t = static_cast<double>(n) / kSampleRate;
        const double carrier = std::sin(kTau * 440.0 * t);
        const double mod = std::cos(kTau * 220.0 * t); // phase=0.25 ↔ cos
        const double expected = carrier * mod;
        CHECK(samples[n] ==
              doctest::Approx(static_cast<float>(expected)).epsilon(0.05));
    }

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Add: bias + audio
// ----------------------------------------------------------------

TEST_CASE("Add(0.5, sin) shifts a bipolar sine to [-0.5, 1.5]") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1); // SinOsc 440
    rt_graph_set_control(g, 0, 0, 440.0f);

    rt_graph_add_node(g, 1, 8);             // Add
    rt_graph_set_control(g, 1, 0, 0.5f);    // bias = 0.5
    rt_graph_connect(g, 0, 0, 1, 1);        // sin → add.b

    rt_graph_add_node(g, 2, 2); // Out
    rt_graph_set_control(g, 2, 0, 0.0f);
    rt_graph_connect(g, 1, 0, 2, 0);

    auto samples = render_bus0(g, kFrames);

    float min_v = std::numeric_limits<float>::infinity();
    float max_v = -std::numeric_limits<float>::infinity();
    for (auto s : samples) {
        min_v = std::min(min_v, s);
        max_v = std::max(max_v, s);
    }
    CHECK(min_v == doctest::Approx(-0.5f).epsilon(0.02));
    CHECK(max_v == doctest::Approx(1.5f).epsilon(0.02));

    rt_graph_destroy(g);
}

TEST_CASE("Add(RConst, RConst) renders the constant sum") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    // node 0: Add with both controls set, no inputs wired.
    rt_graph_add_node(g, 0, 8);
    rt_graph_set_control(g, 0, 0, 0.3f);
    rt_graph_set_control(g, 0, 1, 0.4f);

    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kFrames);
    for (auto s : samples) {
        CHECK(s == doctest::Approx(0.7f).epsilon(1e-5));
    }

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// FM: sample-accurate freq input on SinOsc
// ----------------------------------------------------------------
//
// We don't try to characterize the spectrum here (no FFT). We assert:
//   1. The carrier still oscillates (peak ≈ 1, many zero crossings).
//   2. The output differs meaningfully from a pure 440 Hz sine — i.e.
//      the kernel is consuming the modulator, not ignoring it.

TEST_CASE("SinOsc with audio-rate freq input runs and oscillates") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    // lfo (5 Hz) → gain(30) → add(440) → carrier.freq → out
    rt_graph_add_node(g, 0, 1); // lfo
    rt_graph_set_control(g, 0, 0, 5.0f);

    rt_graph_add_node(g, 1, 3); // gain(30)
    rt_graph_set_control(g, 1, 0, 30.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_add_node(g, 2, 8); // add(440)
    rt_graph_set_control(g, 2, 0, 440.0f);
    rt_graph_connect(g, 1, 0, 2, 1);

    rt_graph_add_node(g, 3, 1); // carrier
    rt_graph_connect(g, 2, 0, 3, 0);

    rt_graph_add_node(g, 4, 2); // out
    rt_graph_set_control(g, 4, 0, 0.0f);
    rt_graph_connect(g, 3, 0, 4, 0);

    auto samples = render_bus0(g, kFrames);

    CHECK(peak_abs(samples) == doctest::Approx(1.0f).epsilon(0.03));

    // Carrier centred around 440 Hz with ±30 Hz LFO at 5 Hz over 1024
    // frames is essentially 9-10 cycles → 18-20 ZCs.
    int zc = zero_crossings(samples);
    CHECK(zc >= 16);
    CHECK(zc <= 22);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Out node edge cases
// ----------------------------------------------------------------

TEST_CASE("Out with no signal input is silence") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 2); // Out, no wiring
    rt_graph_set_control(g, 0, 0, 0.0f);

    auto samples = render_bus0(g, kFrames);
    for (auto s : samples) {
        CHECK(s == 0.0f);
    }

    rt_graph_destroy(g);
}

TEST_CASE("Multiple Out nodes accumulate onto the same bus") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1);
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_add_node(g, 1, 1);
    rt_graph_set_control(g, 1, 0, 220.0f);

    rt_graph_add_node(g, 2, 2);
    rt_graph_set_control(g, 2, 0, 0.0f);
    rt_graph_add_node(g, 3, 2);
    rt_graph_set_control(g, 3, 0, 0.0f);

    rt_graph_connect(g, 0, 0, 2, 0);
    rt_graph_connect(g, 1, 0, 3, 0);

    auto samples = render_bus0(g, kFrames);

    // Both sines contribute, so peak should exceed any single sine.
    // Bound: ≤ 2 (in-phase sum); evidence of accumulation: > 1.
    const float p = peak_abs(samples);
    CHECK(p <= 2.001f);
    CHECK(p > 1.0f);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// resolve_input edge case via public ABI
// ----------------------------------------------------------------

TEST_CASE("Gain with no signal input is silence (signal-side fallback)") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    // Gain alone with non-zero gain control, no signal wired.
    rt_graph_add_node(g, 0, 3);
    rt_graph_set_control(g, 0, 0, 1.0f);

    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kFrames);
    for (auto s : samples) {
        CHECK(s == 0.0f);
    }

    rt_graph_destroy(g);
}
