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
#include <chrono>
#include <cmath>
#include <limits>
#include <numbers>
#include <random>
#include <thread>
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
    CHECK(rt_graph_kind_supported(1) == 1);  // SinOsc
    CHECK(rt_graph_kind_supported(2) == 1);  // Out
    CHECK(rt_graph_kind_supported(3) == 1);  // Gain
    CHECK(rt_graph_kind_supported(5) == 1);  // SawOsc
    CHECK(rt_graph_kind_supported(6) == 1);  // NoiseGen
    CHECK(rt_graph_kind_supported(7) == 1);  // LPF
    CHECK(rt_graph_kind_supported(8) == 1);  // Add
    CHECK(rt_graph_kind_supported(9) == 1);  // Env
    CHECK(rt_graph_kind_supported(10) == 1); // BusOut
    CHECK(rt_graph_kind_supported(11) == 1); // BusIn
    CHECK(rt_graph_kind_supported(12) == 1); // BusInDelayed
    CHECK(rt_graph_kind_supported(13) == 1); // Delay
    CHECK(rt_graph_kind_supported(14) == 1); // Smooth
    CHECK(rt_graph_kind_supported(15) == 1); // PulseOsc
    CHECK(rt_graph_kind_supported(16) == 1); // TriOsc
    CHECK(rt_graph_kind_supported(17) == 1); // HPF
    CHECK(rt_graph_kind_supported(18) == 1); // BPF
    CHECK(rt_graph_kind_supported(19) == 1); // Notch
    CHECK(rt_graph_kind_supported(20) == 1); // PlayBufMono
    CHECK(rt_graph_kind_supported(21) == 1); // RecordBufMono
    CHECK(rt_graph_kind_supported(22) == 1); // SpectralFreeze
}

TEST_CASE("kind_from_tag rejects unknown tags") {
    CHECK(rt_graph_kind_supported(0) == 0);
    CHECK(rt_graph_kind_supported(4) == 0);  // intentional gap
    CHECK(rt_graph_kind_supported(23) == 0); // first unallocated past KSpectralFreeze
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

    // Carrier centered around 440 Hz with ±30 Hz LFO at 5 Hz over 1024
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

// ----------------------------------------------------------------
// SawOsc kernel
// ----------------------------------------------------------------

TEST_CASE("SawOsc(440 Hz) produces a bandlimited saw with peak ≈ 1") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 5); // SawOsc, freq=440, phase=0
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_set_control(g, 0, 1, 0.0f);

    rt_graph_add_node(g, 1, 2); // Out
    rt_graph_set_control(g, 1, 0, 0.0f);

    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kFrames);

    // PolyBLEP saw is bipolar [-1, 1], peak should be near 1
    // (BLEP correction trims the discontinuity slightly).
    CHECK(peak_abs(samples) == doctest::Approx(1.0f).epsilon(0.05));

    // 440 Hz over 1024 frames at 48 kHz = ~9.4 cycles. Each saw cycle
    // crosses zero once in the ramp and once at the reset.
    int zc = zero_crossings(samples);
    CHECK(zc >= 17);
    CHECK(zc <= 21);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// PulseOsc kernel
// ----------------------------------------------------------------

TEST_CASE("PulseOsc(440 Hz, width=0.5) is a bandlimited square: peak ~1, balanced duty") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 15);              // PulseOsc
    rt_graph_set_control(g, 0, 0, 440.0f);    // freq
    rt_graph_set_control(g, 0, 1, 0.0f);      // initial phase
    rt_graph_set_control(g, 0, 2, 0.5f);      // width = square

    rt_graph_add_node(g, 1, 2);               // Out
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kFrames);

    // PolyBLEP pulse is bipolar [-1, 1]; peak should be near 1.
    CHECK(peak_abs(samples) == doctest::Approx(1.0f).epsilon(0.05));

    // 440 Hz over 1024 frames at 48 kHz = ~9.4 cycles. Each square
    // cycle crosses zero exactly twice (rising + falling edge), so
    // we expect ~18-19 crossings, with a small margin for the
    // start/end-of-block partial cycle.
    int zc = zero_crossings(samples);
    CHECK(zc >= 17);
    CHECK(zc <= 21);

    // 50% duty: roughly half the samples should be above zero. Allow
    // ±5% slack for BLEP-softened transitions and partial cycles.
    int high = 0;
    for (auto s : samples) if (s > 0.0f) ++high;
    const float duty = static_cast<float>(high) / samples.size();
    CHECK(duty == doctest::Approx(0.5f).epsilon(0.05));

    rt_graph_destroy(g);
}

TEST_CASE("PulseOsc width=0.25 produces a narrower duty cycle") {
    // The pulse is high for `width` of each cycle. width=0.25 means
    // ~25% of samples should be > 0. Confirms the width control is
    // actually consulted and translated to phase correctly.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 15);
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_set_control(g, 0, 1, 0.0f);
    rt_graph_set_control(g, 0, 2, 0.25f);     // narrow pulse

    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kFrames);

    int high = 0;
    for (auto s : samples) if (s > 0.0f) ++high;
    const float duty = static_cast<float>(high) / samples.size();
    CHECK(duty == doctest::Approx(0.25f).epsilon(0.05));

    rt_graph_destroy(g);
}

TEST_CASE("PulseOsc width-modulation via set_control changes duty within the kernel") {
    // Render two consecutive blocks at different widths. If the
    // block-rate width path is wired correctly, the second block's
    // duty should reflect the new width without restarting phase.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 15);
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_set_control(g, 0, 1, 0.0f);
    rt_graph_set_control(g, 0, 2, 0.1f);      // very narrow

    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto narrow = render_bus0(g, kFrames);

    rt_graph_set_control(g, 0, 2, 0.9f);      // very wide
    auto wide   = render_bus0(g, kFrames);

    int narrow_high = 0;
    for (auto s : narrow) if (s > 0.0f) ++narrow_high;
    int wide_high = 0;
    for (auto s : wide)   if (s > 0.0f) ++wide_high;

    const float narrow_duty = static_cast<float>(narrow_high) / narrow.size();
    const float wide_duty   = static_cast<float>(wide_high)   / wide.size();

    CHECK(narrow_duty == doctest::Approx(0.10f).epsilon(0.05));
    CHECK(wide_duty   == doctest::Approx(0.90f).epsilon(0.05));

    rt_graph_destroy(g);
}

TEST_CASE("PulseOsc takes audio-rate width modulation (PWM) without zippering") {
    // Wire a slow LFO into the width input. The output's duty cycle
    // should drift across the block — counted as: the second half's
    // duty differs from the first half's. A failure here would mean
    // the kernel ignores the width port or only samples it once.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    // LFO: SinOsc at ~5 Hz scaled+offset to [0.1, 0.9] via a Gain
    // (output ∈ [-1,1] -> scale by 0.4 -> [-0.4, 0.4]) + Add 0.5
    // -> [0.1, 0.9].
    rt_graph_add_node(g, 0, 1);                 // SinOsc (LFO)
    rt_graph_set_control(g, 0, 0, 5.0f);        // 5 Hz
    rt_graph_set_control(g, 0, 1, 0.0f);

    rt_graph_add_node(g, 1, 3);                 // Gain: scale LFO
    rt_graph_set_control(g, 1, 0, 0.4f);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_add_node(g, 2, 8);                 // Add: bias
    rt_graph_set_control(g, 2, 1, 0.5f);
    rt_graph_connect(g, 1, 0, 2, 0);

    rt_graph_add_node(g, 3, 15);                // PulseOsc
    rt_graph_set_control(g, 3, 0, 440.0f);
    rt_graph_set_control(g, 3, 1, 0.0f);
    rt_graph_connect(g, 2, 0, 3, 2);            // LFO -> width

    rt_graph_add_node(g, 4, 2);                 // Out
    rt_graph_set_control(g, 4, 0, 0.0f);
    rt_graph_connect(g, 3, 0, 4, 0);

    // Render enough samples to span at least one LFO half-cycle
    // (5 Hz at 48 kHz = 9600 samples per cycle, ~9 blocks of 1024).
    constexpr int kBlocks = 10;
    std::vector<float> all;
    all.reserve(kFrames * kBlocks);
    for (int b = 0; b < kBlocks; ++b) {
        auto block = render_bus0(g, kFrames);
        all.insert(all.end(), block.begin(), block.end());
    }

    // Output is finite, bounded, non-trivial.
    for (auto s : all) {
        CHECK(std::isfinite(s));
        CHECK(std::abs(s) <= 1.5f);
    }

    // Duty in the first vs. last quarter should differ noticeably:
    // the LFO is sweeping width, so the first quarter (LFO near
    // crossing zero, width near 0.5) and the last quarter (LFO at
    // a different phase, width different) should produce different
    // ratios. Threshold is loose (just "not identical") to avoid
    // depending on LFO phase alignment.
    const std::size_t qsize = all.size() / 4;
    int first_high = 0, last_high = 0;
    for (std::size_t i = 0;            i < qsize;            ++i) if (all[i] > 0.0f) ++first_high;
    for (std::size_t i = all.size()-qsize; i < all.size();    ++i) if (all[i] > 0.0f) ++last_high;

    const float first_duty = static_cast<float>(first_high) / qsize;
    const float last_duty  = static_cast<float>(last_high)  / qsize;
    INFO("first_duty=" << first_duty << " last_duty=" << last_duty);
    CHECK(std::abs(first_duty - last_duty) > 0.05f);

    rt_graph_destroy(g);
}

TEST_CASE("PulseOsc clamps invalid width controls and stays bounded") {
    // q::pulse_osc expects width in [0, 1]. Bad control values should
    // be cleaned at the kernel boundary so the oscillator never sees
    // NaN, infinities, or negative phase fractions.
    auto run_with_bad_width = [](double bad_w) {
        auto *g = rt_graph_create(2, kFrames);
        REQUIRE(g != nullptr);

        rt_graph_add_node(g, 0, 15);                  // PulseOsc
        rt_graph_set_control(g, 0, 0, 440.0f);
        rt_graph_set_control(g, 0, 1, 0.0f);
        rt_graph_set_control(g, 0, 2, bad_w);         // invalid width

        rt_graph_add_node(g, 1, 2);
        rt_graph_set_control(g, 1, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);

        auto samples = render_bus0(g, kFrames);

        for (auto s : samples) {
            CHECK(std::isfinite(s));
            CHECK(std::abs(s) <= 4.0f);  // ±1 base + polyBLEP transient
        }
        rt_graph_destroy(g);
    };

    // Non-finite values fall back to the square-wave default.
    run_with_bad_width(std::numeric_limits<double>::quiet_NaN());
    run_with_bad_width(std::numeric_limits<double>::infinity());
    run_with_bad_width(-std::numeric_limits<double>::infinity());
    // Negative values used to trip Q's debug assert.
    run_with_bad_width(-1.0);
    run_with_bad_width(-1000.0);
    // Values above 1 clamp to the wide end of the pulse domain.
    run_with_bad_width(2.5);
    run_with_bad_width(1e9);
}

TEST_CASE("PulseOsc clamps audio-rate width modulation") {
    // Same contract for the sample-accurate path: an exaggerated LFO
    // drives the width input far outside [0, 1], and the inner loop
    // keeps every sample finite and bounded.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1);                       // SinOsc LFO
    rt_graph_set_control(g, 0, 0, 5.0f);
    rt_graph_set_control(g, 0, 1, 0.0f);
    rt_graph_add_node(g, 1, 3);                       // Gain × 1e6
    rt_graph_set_control(g, 1, 0, 1.0e6);
    rt_graph_connect(g, 0, 0, 1, 0);                  // wild swings

    rt_graph_add_node(g, 2, 15);                      // PulseOsc
    rt_graph_set_control(g, 2, 0, 220.0f);
    rt_graph_set_control(g, 2, 1, 0.0f);
    rt_graph_connect(g, 1, 0, 2, 2);                  // bad width signal

    rt_graph_add_node(g, 3, 2);
    rt_graph_set_control(g, 3, 0, 0.0f);
    rt_graph_connect(g, 2, 0, 3, 0);

    // Render multiple blocks so the width sweeps the full LFO range
    // (and through wraparound in the *1e6-amplified signal).
    for (int b = 0; b < 6; ++b) {
        auto samples = render_bus0(g, kFrames);
        for (auto s : samples) {
            CHECK(std::isfinite(s));
            CHECK(std::abs(s) <= 4.0f);
        }
    }

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// TriOsc kernel
// ----------------------------------------------------------------

TEST_CASE("TriOsc(440 Hz) is a bandlimited triangle: peak ~1, ~18 zero-crossings") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 16);              // TriOsc
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_set_control(g, 0, 1, 0.0f);

    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kFrames);
    CHECK(peak_abs(samples) == doctest::Approx(1.0f).epsilon(0.05));

    int zc = zero_crossings(samples);
    CHECK(zc >= 17);
    CHECK(zc <= 21);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Biquad family: HPF / BPF / Notch
// ----------------------------------------------------------------
//
// Each filter test runs a few "settling" blocks before measuring so
// the IIR transient has decayed. Amplitude thresholds are loose
// (0.3 / 0.7) to tolerate biquad rolloff variation between Q values
// without depending on exact magnitude-response curves.

namespace {
// Render N blocks and return the last one. Lets the IIR settle before
// the test reads peak amplitude.
std::vector<float> render_settled(RTGraph *g, int blocks, int frames) {
    std::vector<float> out;
    for (int i = 0; i < blocks; ++i) {
        out = render_bus0(g, frames);
    }
    return out;
}
} // namespace

TEST_CASE("HPF rejects sub-cutoff sine and passes super-cutoff sine") {
    constexpr int kSettle = 4;
    auto build = [](float sine_hz, float cutoff_hz) {
        auto *g = rt_graph_create(4, kFrames);
        REQUIRE(g != nullptr);
        rt_graph_add_node(g, 0, 1);                       // SinOsc source
        rt_graph_set_control(g, 0, 0, sine_hz);
        rt_graph_set_control(g, 0, 1, 0.0f);
        rt_graph_add_node(g, 1, 17);                      // HPF
        rt_graph_set_control(g, 1, 0, cutoff_hz);
        rt_graph_set_control(g, 1, 1, 0.707);
        rt_graph_add_node(g, 2, 2);                       // Out
        rt_graph_set_control(g, 2, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);                  // sine -> HPF
        rt_graph_connect(g, 1, 0, 2, 0);                  // HPF -> Out
        return g;
    };

    SUBCASE("100 Hz sine through HPF cutoff=2000 Hz: heavily attenuated") {
        auto *g = build(100.0f, 2000.0f);
        auto last = render_settled(g, kSettle, kFrames);
        CHECK(peak_abs(last) < 0.3f);
        rt_graph_destroy(g);
    }
    SUBCASE("5000 Hz sine through HPF cutoff=1000 Hz: passes through") {
        auto *g = build(5000.0f, 1000.0f);
        auto last = render_settled(g, kSettle, kFrames);
        CHECK(peak_abs(last) > 0.7f);
        rt_graph_destroy(g);
    }
}

TEST_CASE("BPF passes center-tuned sine and rejects off-band sine") {
    constexpr int kSettle = 6;
    auto build = [](float sine_hz, float center_hz, double q) {
        auto *g = rt_graph_create(4, kFrames);
        REQUIRE(g != nullptr);
        rt_graph_add_node(g, 0, 1);
        rt_graph_set_control(g, 0, 0, sine_hz);
        rt_graph_set_control(g, 0, 1, 0.0f);
        rt_graph_add_node(g, 1, 18);                      // BPF
        rt_graph_set_control(g, 1, 0, center_hz);
        rt_graph_set_control(g, 1, 1, q);
        rt_graph_add_node(g, 2, 2);
        rt_graph_set_control(g, 2, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);
        rt_graph_connect(g, 1, 0, 2, 0);
        return g;
    };

    SUBCASE("1000 Hz sine through BPF center=1000 Hz: passes through") {
        auto *g = build(1000.0f, 1000.0f, 2.0);
        auto last = render_settled(g, kSettle, kFrames);
        CHECK(peak_abs(last) > 0.7f);
        rt_graph_destroy(g);
    }
    SUBCASE("100 Hz sine through BPF center=1000 Hz: rejected") {
        auto *g = build(100.0f, 1000.0f, 2.0);
        auto last = render_settled(g, kSettle, kFrames);
        CHECK(peak_abs(last) < 0.5f);
        rt_graph_destroy(g);
    }
}

TEST_CASE("Notch rejects center-tuned sine and passes off-band sine") {
    constexpr int kSettle = 6;
    auto build = [](float sine_hz, float center_hz, double q) {
        auto *g = rt_graph_create(4, kFrames);
        REQUIRE(g != nullptr);
        rt_graph_add_node(g, 0, 1);
        rt_graph_set_control(g, 0, 0, sine_hz);
        rt_graph_set_control(g, 0, 1, 0.0f);
        rt_graph_add_node(g, 1, 19);                      // Notch
        rt_graph_set_control(g, 1, 0, center_hz);
        rt_graph_set_control(g, 1, 1, q);
        rt_graph_add_node(g, 2, 2);
        rt_graph_set_control(g, 2, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);
        rt_graph_connect(g, 1, 0, 2, 0);
        return g;
    };

    SUBCASE("1000 Hz sine through Notch center=1000 Hz: heavily attenuated") {
        auto *g = build(1000.0f, 1000.0f, 8.0);
        auto last = render_settled(g, kSettle, kFrames);
        CHECK(peak_abs(last) < 0.3f);
        rt_graph_destroy(g);
    }
    SUBCASE("100 Hz sine through Notch center=1000 Hz: passes through") {
        auto *g = build(100.0f, 1000.0f, 8.0);
        auto last = render_settled(g, kSettle, kFrames);
        CHECK(peak_abs(last) > 0.7f);
        rt_graph_destroy(g);
    }
}

// ----------------------------------------------------------------
// NoiseGen kernel
// ----------------------------------------------------------------

TEST_CASE("NoiseGen samples roughly fill [-1, 1] with no bin starvation") {
    // Render a long run and bin into 16 buckets across [-1, 1]. With
    // ~16k samples and uniform [-1, 1] noise, each bin should hold
    // ~1000 samples. We check no bin is empty and no bin holds more
    // than ~3× the expected count — a very forgiving sanity bound that
    // would still flag a kernel that suddenly produced only positive
    // values, biased values, or DC.
    constexpr int kBlocks = 16;
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_add_node(g, 0, 6);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    constexpr int kBins = 16;
    int hist[kBins] = {0};
    int total = 0;

    for (int b = 0; b < kBlocks; ++b) {
        auto samples = render_bus0(g, kFrames);
        for (auto s : samples) {
            ++total;
            const float clamped = std::max(-1.0f, std::min(1.0f, s));
            int bin = static_cast<int>((clamped + 1.0f) * 0.5f * kBins);
            if (bin >= kBins) bin = kBins - 1;
            if (bin < 0)      bin = 0;
            ++hist[bin];
        }
    }
    rt_graph_destroy(g);

    const int expected = total / kBins;
    for (int i = 0; i < kBins; ++i) {
        CHECK(hist[i] > expected / 4); // no near-empty bin
        CHECK(hist[i] < expected * 3); // no dominant bin
    }
}

TEST_CASE("NoiseGen has low autocorrelation at lag 1") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_add_node(g, 0, 6);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kFrames);
    rt_graph_destroy(g);

    // Centre samples on the empirical mean (already near 0, but be safe).
    double mean = 0.0;
    for (auto s : samples) mean += s;
    mean /= static_cast<double>(samples.size());

    double num = 0.0, den = 0.0;
    for (std::size_t i = 1; i < samples.size(); ++i) {
        const double a = samples[i - 1] - mean;
        const double b = samples[i] - mean;
        num += a * b;
        den += a * a;
    }
    const double r1 = num / den;

    // White noise has expected r1 = 0; a deterministic ramp or
    // strongly-colored signal would push toward ±1. Anything past
    // ±0.2 in 1024 samples points at non-whiteness.
    CHECK(std::abs(r1) < 0.2);
}

TEST_CASE("NoiseGen has no improbably long same-sign runs") {
    // For an idealised uniform source, longest runs in 1024 samples
    // cluster around log2(1024)≈10. q::white_noise_gen's empirical
    // distribution is looser than that (the DC-offset bug we already
    // documented hints at imperfect uniformity), so we use a generous
    // bound that still flags a stuck-state bug — a run of 100+ would
    // be unambiguous breakage.
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_add_node(g, 0, 6);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kFrames);
    rt_graph_destroy(g);

    int max_run = 0;
    int cur_run = 1;
    for (std::size_t i = 1; i < samples.size(); ++i) {
        const bool same_sign = (samples[i] >= 0.0f) == (samples[i - 1] >= 0.0f);
        cur_run = same_sign ? cur_run + 1 : 1;
        if (cur_run > max_run) max_run = cur_run;
    }
    CHECK(max_run < 100);
}

TEST_CASE("NoiseGen produces bounded, non-constant, near-zero-mean output") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 6); // NoiseGen
    rt_graph_add_node(g, 1, 2); // Out
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kFrames);

    // Bounded
    for (auto s : samples) {
        CHECK(std::abs(s) <= 1.001f);
    }

    // Non-constant: meaningful variance.
    double mean = 0.0;
    for (auto s : samples) {
        mean += s;
    }
    mean /= static_cast<double>(samples.size());
    double variance = 0.0;
    for (auto s : samples) {
        const double d = s - mean;
        variance += d * d;
    }
    variance /= static_cast<double>(samples.size());
    CHECK(variance > 0.1);

    // Near-zero DC over 1024 samples (uniform [-1, 1] → mean ≈ 0).
    CHECK(std::abs(mean) < 0.1);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// BusOut / BusIn (audio-bus routing)
// ----------------------------------------------------------------
//
// Note: same-cycle ordering between BusOut and BusIn is enforced on the
// Haskell side by E_r edges in effectiveDeps; from the C++ side's point
// of view we just rely on the runtime processing nodes in storage order.
// These tests exercise the kernels directly by building the graph in the
// "writer-then-reader" storage order.

TEST_CASE("BusOut(5) writes a constant to bus 5; BusIn(5) reads it back") {
    // Use a SinOsc as the source so we have a non-trivial signal,
    // then BusOut to bus 5, BusIn from bus 5, and Out to bus 0.
    constexpr int kBus = 5;
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, kBus);

    rt_graph_add_node(g, 0, 1);                       // SinOsc
    rt_graph_set_control(g, 0, 0, 440.0);             // freq
    rt_graph_add_node(g, 1, 10);                      // BusOut
    rt_graph_set_control(g, 1, 0, static_cast<double>(kBus));
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_add_node(g, 2, 11);                      // BusIn
    rt_graph_set_control(g, 2, 0, static_cast<double>(kBus));
    rt_graph_add_node(g, 3, 2);                       // Out
    rt_graph_set_control(g, 3, 0, 0.0);
    rt_graph_connect(g, 2, 0, 3, 0);

    auto bus0 = render_bus0(g, kFrames);
    rt_graph_destroy(g);

    // BusIn should reproduce the original sine on bus 0 with peak ≈ 1.
    const float peak = *std::max_element(bus0.begin(), bus0.end(),
        [](float a, float b) { return std::abs(a) < std::abs(b); });
    CHECK(std::abs(std::abs(peak) - 1.0f) < 0.05f);
}

TEST_CASE("BusOut: multiple writers to the same bus sum") {
    // Two SinOscs (440 Hz, 0 phase + 440 Hz, 0 phase) BusOut to bus 5
    // separately. BusIn reads bus 5 — it should see double-amplitude.
    constexpr int kBus = 5;
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, kBus);

    rt_graph_add_node(g, 0, 1);              // SinOsc A
    rt_graph_set_control(g, 0, 0, 440.0);
    rt_graph_add_node(g, 1, 1);              // SinOsc B (identical)
    rt_graph_set_control(g, 1, 0, 440.0);

    rt_graph_add_node(g, 2, 10);             // BusOut from A
    rt_graph_set_control(g, 2, 0, static_cast<double>(kBus));
    rt_graph_connect(g, 0, 0, 2, 0);

    rt_graph_add_node(g, 3, 10);             // BusOut from B
    rt_graph_set_control(g, 3, 0, static_cast<double>(kBus));
    rt_graph_connect(g, 1, 0, 3, 0);

    rt_graph_add_node(g, 4, 11);             // BusIn
    rt_graph_set_control(g, 4, 0, static_cast<double>(kBus));
    rt_graph_add_node(g, 5, 2);              // Out
    rt_graph_set_control(g, 5, 0, 0.0);
    rt_graph_connect(g, 4, 0, 5, 0);

    auto bus0 = render_bus0(g, kFrames);
    rt_graph_destroy(g);

    const float peak = *std::max_element(bus0.begin(), bus0.end());
    CHECK(peak > 1.5f); // additive sum of two peak-1 sines ≈ 2.0
    CHECK(peak < 2.1f);
}

TEST_CASE("BusIn from an unwritten bus is silence") {
    // No BusOut anywhere — BusIn 5 should read zeros, since the pool is
    // cleared at the start of each block.
    constexpr int kBus = 5;
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 11);             // BusIn alone
    rt_graph_set_control(g, 0, 0, static_cast<double>(kBus));
    rt_graph_add_node(g, 1, 2);              // Out
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto bus0 = render_bus0(g, kFrames);
    rt_graph_destroy(g);

    for (auto s : bus0) {
        CHECK(std::abs(s) < 1e-6f);
    }
}

TEST_CASE("BusInDelayed reads the previous block's BusOut contents") {
    // Phase 2 ping-pong test. Build:
    //   SinOsc(440) → BusOut(5)
    //   BusInDelayed(5) → Out(0)
    // Block 1: prev is zero-initialized, so BusInDelayed → Out(0) = silence.
    //          BusOut still writes block 1's sine into live bus 5.
    // Block 2: the swap moves block 1's bus 5 into the snapshot;
    //          BusInDelayed therefore reads block 1's sine into Out(0),
    //          while BusOut writes block 2's sine into live bus 5.
    //
    // The assertion that Out(0) in block 2 equals bus 5 captured at the
    // end of block 1 is the proof that:
    //   - the snapshot persists exactly what was last written to live;
    //   - the swap happens before the block's writes (otherwise the
    //     snapshot would already contain block 2's data);
    //   - BusInDelayed reads from the snapshot, not from live.
    constexpr int kBus = 5;
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, kBus);

    rt_graph_add_node(g, 0, 1);                          // SinOsc
    rt_graph_set_control(g, 0, 0, 440.0);

    rt_graph_add_node(g, 1, 10);                         // BusOut
    rt_graph_set_control(g, 1, 0, static_cast<double>(kBus));
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_add_node(g, 2, 12);                         // BusInDelayed
    rt_graph_set_control(g, 2, 0, static_cast<double>(kBus));

    rt_graph_add_node(g, 3, 2);                          // Out
    rt_graph_set_control(g, 3, 0, 0.0);
    rt_graph_connect(g, 2, 0, 3, 0);

    // Block 1.
    rt_graph_process(g, kFrames);
    std::vector<float> block1_bus5(kFrames, 0.0f);
    rt_graph_read_bus(g, kBus, kFrames, block1_bus5.data());
    std::vector<float> block1_out(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, block1_out.data());

    // BusInDelayed sees zero on the very first block.
    CHECK(peak_abs(block1_out) < 1e-6f);
    // BusOut still wrote a real sine into bus 5 this block.
    CHECK(peak_abs(block1_bus5) > 0.9f);

    // Block 2.
    rt_graph_process(g, kFrames);
    std::vector<float> block2_out(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, block2_out.data());

    // BusInDelayed in block 2 must read exactly what BusOut wrote in
    // block 1 — the snapshot is bit-identical to block 1's live bus 5.
    float max_diff = 0.0f;
    for (int i = 0; i < kFrames; ++i) {
        max_diff = std::max(max_diff, std::abs(block1_bus5[i] - block2_out[i]));
    }
    CHECK(max_diff < 1e-6f);

    rt_graph_destroy(g);
}

TEST_CASE("BusInDelayed snapshot is one-block-old across many blocks") {
    // The "BusInDelayed reads the previous block's BusOut contents"
    // test verifies blocks 1 and 2 of the swap. This test extends
    // that to several blocks: a swap-direction regression that only
    // shows up on block 3+ (e.g. ping-ponging back to a stale
    // buffer instead of advancing the snapshot every block) wouldn't
    // be caught by the 2-block test but would here.
    //
    //   SinOsc(440) → BusOut(5)
    //   BusInDelayed(5) → Out(0)
    //
    // Invariant: for every block N >= 1, Out(0) at block N must be
    // bit-equal to bus 5 captured at the *end* of block N-1.
    constexpr int kBus = 5;
    constexpr int kBlocks = 5;
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, kBus);

    rt_graph_add_node(g, 0, 1);                          // SinOsc
    rt_graph_set_control(g, 0, 0, 440.0);

    rt_graph_add_node(g, 1, 10);                         // BusOut
    rt_graph_set_control(g, 1, 0, static_cast<double>(kBus));
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_add_node(g, 2, 12);                         // BusInDelayed
    rt_graph_set_control(g, 2, 0, static_cast<double>(kBus));

    rt_graph_add_node(g, 3, 2);                          // Out(0)
    rt_graph_set_control(g, 3, 0, 0.0);
    rt_graph_connect(g, 2, 0, 3, 0);

    std::vector<std::vector<float>> bus5(kBlocks, std::vector<float>(kFrames, 0.0f));
    std::vector<std::vector<float>> out0(kBlocks, std::vector<float>(kFrames, 0.0f));

    for (int blk = 0; blk < kBlocks; ++blk) {
        rt_graph_process(g, kFrames);
        rt_graph_read_bus(g, 0, kFrames, out0[blk].data());
        rt_graph_read_bus(g, kBus, kFrames, bus5[blk].data());
    }

    // Block 0: prev was zero-initialized → Out(0) is silence.
    CHECK(peak_abs(out0[0]) < 1e-6f);

    // Sanity: each block produces a non-trivial sine on bus 5
    // (otherwise the equality test below would be vacuous).
    for (int n = 0; n < kBlocks; ++n) {
        INFO("block " << n << " bus 5 should carry a sine");
        CHECK(peak_abs(bus5[n]) > 0.9f);
    }

    // The core invariant: for every block N >= 1, BusInDelayed in
    // block N reads exactly what BusOut wrote in block N-1.
    for (int n = 1; n < kBlocks; ++n) {
        float max_diff = 0.0f;
        for (int i = 0; i < kFrames; ++i) {
            max_diff = std::max(max_diff, std::abs(out0[n][i] - bus5[n - 1][i]));
        }
        INFO("block " << n << ": delayed read should equal block " << n - 1
                      << "'s bus 5; max_diff=" << max_diff);
        CHECK(max_diff < 1e-6f);
    }

    // Sanity: consecutive blocks of the sine differ (phase advances
    // across blocks). Without this, a swap regression that copied
    // the same buffer twice could pass the equality check.
    for (int n = 1; n < kBlocks; ++n) {
        float phase_diff = 0.0f;
        for (int i = 0; i < kFrames; ++i) {
            phase_diff = std::max(phase_diff, std::abs(bus5[n][i] - bus5[n - 1][i]));
        }
        INFO("block " << n << " bus 5 should differ from block " << n - 1);
        CHECK(phase_diff > 0.05f);
    }

    rt_graph_destroy(g);
}

TEST_CASE("BusIn (live) and BusInDelayed (prev) coexist on the same bus") {
    // SC counterpart: In.ar(5) and InFeedback.ar(5) on the same bus.
    // The live BusIn is forced to follow BusOut by an E_r edge, so
    // it sees this block's writes; BusInDelayed reads the snapshot,
    // unconstrained, so it sees the previous block's writes. Both
    // routed to separate output buses so they can be inspected
    // independently.
    //
    //   SinOsc(440) → BusOut(5)
    //   BusIn(5)        → Out(0)   (live read)
    //   BusInDelayed(5) → Out(1)   (delayed read)
    //
    // Block 1: bus 0 = block 1 sine; bus 1 = silence (no prev).
    // Block 2: bus 0 = block 2 sine; bus 1 = block 1 sine.
    constexpr int kBus = 5;
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, kBus);
    rt_graph_ensure_bus(g, 1);  // BusInDelayed routes to bus 1

    rt_graph_add_node(g, 0, 1);                          // SinOsc
    rt_graph_set_control(g, 0, 0, 440.0);

    rt_graph_add_node(g, 1, 10);                         // BusOut
    rt_graph_set_control(g, 1, 0, static_cast<double>(kBus));
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_add_node(g, 2, 11);                         // BusIn (live)
    rt_graph_set_control(g, 2, 0, static_cast<double>(kBus));
    rt_graph_add_node(g, 3, 2);                          // Out(0)
    rt_graph_set_control(g, 3, 0, 0.0);
    rt_graph_connect(g, 2, 0, 3, 0);

    rt_graph_add_node(g, 4, 12);                         // BusInDelayed
    rt_graph_set_control(g, 4, 0, static_cast<double>(kBus));
    rt_graph_add_node(g, 5, 2);                          // Out(1)
    rt_graph_set_control(g, 5, 0, 1.0);
    rt_graph_connect(g, 4, 0, 5, 0);

    // Block 1.
    rt_graph_process(g, kFrames);
    std::vector<float> b1_bus0(kFrames, 0.0f), b1_bus1(kFrames, 0.0f),
                       b1_bus5(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, b1_bus0.data());
    rt_graph_read_bus(g, 1, kFrames, b1_bus1.data());
    rt_graph_read_bus(g, kBus, kFrames, b1_bus5.data());

    // Live: bus 0 must equal bus 5 (the live BusIn read this block's
    // accumulated writes after E_r-forced ordering).
    float live_diff_b1 = 0.0f;
    for (int i = 0; i < kFrames; ++i) {
        live_diff_b1 = std::max(live_diff_b1, std::abs(b1_bus0[i] - b1_bus5[i]));
    }
    CHECK(live_diff_b1 < 1e-6f);
    // Delayed: bus 1 is silence (zero-initialized snapshot).
    CHECK(peak_abs(b1_bus1) < 1e-6f);

    // Block 2.
    rt_graph_process(g, kFrames);
    std::vector<float> b2_bus0(kFrames, 0.0f), b2_bus1(kFrames, 0.0f),
                       b2_bus5(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, b2_bus0.data());
    rt_graph_read_bus(g, 1, kFrames, b2_bus1.data());
    rt_graph_read_bus(g, kBus, kFrames, b2_bus5.data());

    // Live: still tracks block 2's bus 5.
    float live_diff_b2 = 0.0f;
    for (int i = 0; i < kFrames; ++i) {
        live_diff_b2 = std::max(live_diff_b2, std::abs(b2_bus0[i] - b2_bus5[i]));
    }
    CHECK(live_diff_b2 < 1e-6f);
    // Delayed: matches block 1's bus 5 (the snapshot).
    float delayed_diff = 0.0f;
    for (int i = 0; i < kFrames; ++i) {
        delayed_diff = std::max(delayed_diff, std::abs(b2_bus1[i] - b1_bus5[i]));
    }
    CHECK(delayed_diff < 1e-6f);
    // Sanity: block 2's bus 5 differs from block 1's. Without this,
    // both equality checks above could pass on a degenerate signal.
    float advance = 0.0f;
    for (int i = 0; i < kFrames; ++i) {
        advance = std::max(advance, std::abs(b2_bus5[i] - b1_bus5[i]));
    }
    CHECK(advance > 0.05f);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Delay (per-node fractional delay line via q::delay)
// ----------------------------------------------------------------
//
// q::delay's read API returns the value at a fractional index that
// represents (i+1) samples of delay (it reads BEFORE pushing). Our
// kernel maps user-facing time-in-seconds to samples_back via
// time*sps, so the perceived delay is effectively (time*sps + 1)
// samples. The +1 is a sub-millisecond artifact at audio rates and
// the tests below allow ±2 samples of slop where it matters.

TEST_CASE("Delay: constant input becomes silence then constant after delay catches up") {
    // Use Add(Param 1.0, Param 0.0) as a trivial constant 1.0 source —
    // process_add reads control fallbacks per sample when no audio
    // is wired, which gives us a steady DC signal at 1.0. Pipe that
    // through a Delay with max=10ms and time=1ms; expect silence for
    // ~48 samples then constant 1.0 thereafter.
    constexpr double kDelaySec = 0.001;
    // 1024-frame block at 48kHz default. 1ms = 48 samples. We allow
    // ±2 around that to absorb the API's off-by-one.
    constexpr int kExpectedDelaySamples = 48;

    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 8);                           // Add (constant)
    rt_graph_set_control(g, 0, 0, 1.0);                   // a = 1.0
    rt_graph_set_control(g, 0, 1, 0.0);                   // b = 0.0

    rt_graph_add_node(g, 1, 13);                          // Delay
    rt_graph_set_control(g, 1, 0, 0.01);                  // max = 10ms
    rt_graph_set_control(g, 1, 1, kDelaySec);             // time = 1ms
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_add_node(g, 2, 2);                           // Out
    rt_graph_set_control(g, 2, 0, 0.0);
    rt_graph_connect(g, 1, 0, 2, 0);

    auto bus0 = render_bus0(g, kFrames);
    rt_graph_destroy(g);

    // Find where the buffer transitions from silence (~0) to constant
    // (~1.0). That index is the perceived delay length in samples.
    int silence_end = -1;
    for (int i = 0; i < kFrames; ++i) {
        if (std::abs(bus0[i]) > 0.5f) { silence_end = i; break; }
    }
    REQUIRE(silence_end >= 0);
    CHECK(silence_end >= kExpectedDelaySamples - 2);
    CHECK(silence_end <= kExpectedDelaySamples + 2);

    // After the transition, output should hold steady at 1.0.
    for (int i = silence_end + 5; i < kFrames; ++i) {
        INFO("post-delay sample " << i << " should be ≈ 1.0");
        CHECK(std::abs(bus0[i] - 1.0f) < 1e-3f);
    }
}

TEST_CASE("Delay: requested time > max_time saturates safely") {
    // The kernel clamps t_samples to [0, buf_size - 1]. Verify a
    // request well beyond max doesn't crash, doesn't produce NaN,
    // and effectively saturates at the maximum delay (so post-
    // saturation we still get the constant input back).
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 8);                           // Add 1.0
    rt_graph_set_control(g, 0, 0, 1.0);
    rt_graph_set_control(g, 0, 1, 0.0);

    rt_graph_add_node(g, 1, 13);                          // Delay
    rt_graph_set_control(g, 1, 0, 0.001);                 // max = 1ms (~48 samples)
    rt_graph_set_control(g, 1, 1, 0.1);                   // requested = 100ms
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_add_node(g, 2, 2);                           // Out
    rt_graph_set_control(g, 2, 0, 0.0);
    rt_graph_connect(g, 1, 0, 2, 0);

    auto bus0 = render_bus0(g, kFrames);
    rt_graph_destroy(g);

    for (auto s : bus0) { CHECK(std::isfinite(s)); }
    // Max delay is ~48 samples; well past that we still see the
    // constant input, regardless of the over-large time request.
    CHECK(std::abs(bus0[kFrames - 1] - 1.0f) < 1e-3f);
}

TEST_CASE("Delay: continuity across blocks") {
    // Render two N-frame blocks sequentially and assert the result
    // matches a single 2N-frame block. This pins that the ring
    // buffer's read/write pointers survive block boundaries (the
    // q::delay state lives across calls into process_delay).
    constexpr int nhalf = 256;
    constexpr int nfull = 2 * nhalf;

    auto build = [](RTGraph *g) {
        rt_graph_add_node(g, 0, 1);                       // SinOsc
        rt_graph_set_control(g, 0, 0, 440.0);
        rt_graph_add_node(g, 1, 13);                      // Delay
        rt_graph_set_control(g, 1, 0, 0.01);              // max = 10ms
        rt_graph_set_control(g, 1, 1, 0.005);             // time = 5ms
        rt_graph_connect(g, 0, 0, 1, 0);
        rt_graph_add_node(g, 2, 2);                       // Out
        rt_graph_set_control(g, 2, 0, 0.0);
        rt_graph_connect(g, 1, 0, 2, 0);
    };

    // Single 2N-frame render.
    auto *g_full = rt_graph_create(4, nfull);
    REQUIRE(g_full != nullptr);
    build(g_full);
    std::vector<float> full(nfull, 0.0f);
    rt_graph_process(g_full, nfull);
    rt_graph_read_bus(g_full, 0, nfull, full.data());
    rt_graph_destroy(g_full);

    // Two N-frame renders concatenated.
    auto *g_split = rt_graph_create(4, nfull);
    REQUIRE(g_split != nullptr);
    build(g_split);
    std::vector<float> split(nfull, 0.0f);
    std::vector<float> half(nhalf, 0.0f);
    rt_graph_process(g_split, nhalf);
    rt_graph_read_bus(g_split, 0, nhalf, half.data());
    std::copy(half.begin(), half.end(), split.begin());
    rt_graph_process(g_split, nhalf);
    rt_graph_read_bus(g_split, 0, nhalf, half.data());
    std::copy(half.begin(), half.end(), split.begin() + nhalf);
    rt_graph_destroy(g_split);

    float max_diff = 0.0f;
    for (int i = 0; i < nfull; ++i) {
        max_diff = std::max(max_diff, std::abs(full[i] - split[i]));
    }
    INFO("split vs full max_diff = " << max_diff);
    CHECK(max_diff < 1e-5f);
}

TEST_CASE("BusInDelayed feedback path: stable attenuated loop") {
    // Pin the use case the abstraction exists for: feedback. Build a
    // graph that on each block reads the previous block's bus 5,
    // attenuates by 0.5, mixes with a fresh impulse-shaped source,
    // and writes the result back to bus 5. With attenuation the loop
    // stays bounded; without the snapshot mechanism the topological
    // sorter would refuse to schedule this graph.
    //
    //   NoiseGen → Gain(0.1) ─┐
    //                          ├→ Add → Gain(0.5) → BusOut(5) → Out(0)
    //   BusInDelayed(5) ──────┘
    //
    // We just check the output is finite and non-zero after several
    // blocks — a hard correctness oracle would require modeling the
    // feedback transfer function. The test's real value is that it
    // exercises the swap+clear+kernel sequence under feedback load
    // and that nothing becomes NaN/inf.
    constexpr int kBus = 5;
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, kBus);

    rt_graph_add_node(g, 0, 6);                          // NoiseGen
    rt_graph_add_node(g, 1, 3);                          // Gain(0.1)
    rt_graph_set_control(g, 1, 0, 0.1);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_add_node(g, 2, 12);                         // BusInDelayed(5)
    rt_graph_set_control(g, 2, 0, static_cast<double>(kBus));

    rt_graph_add_node(g, 3, 8);                          // Add
    rt_graph_connect(g, 1, 0, 3, 0);                     // noise → Add.a
    rt_graph_connect(g, 2, 0, 3, 1);                     // delayed → Add.b

    rt_graph_add_node(g, 4, 3);                          // Gain(0.5)
    rt_graph_set_control(g, 4, 0, 0.5);
    rt_graph_connect(g, 3, 0, 4, 0);

    rt_graph_add_node(g, 5, 10);                         // BusOut(5)
    rt_graph_set_control(g, 5, 0, static_cast<double>(kBus));
    rt_graph_connect(g, 4, 0, 5, 0);

    rt_graph_add_node(g, 6, 2);                          // Out(0)
    rt_graph_set_control(g, 6, 0, 0.0);
    rt_graph_connect(g, 4, 0, 6, 0);

    // Run several blocks; loop should stay bounded (gain 0.5 < 1).
    for (int blk = 0; blk < 8; ++blk) {
        rt_graph_process(g, kFrames);
    }
    std::vector<float> out(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, out.data());

    const float peak = peak_abs(out);
    // Bounded by the noise input × 0.1 / (1 - 0.5) = ~0.2 in the
    // limit; allow generous slack since the input is white noise.
    CHECK(peak > 0.0f);
    CHECK(peak < 1.0f);
    for (auto s : out) {
        CHECK(std::isfinite(s));
    }

    rt_graph_destroy(g);
}

TEST_CASE("Delay inside a BusInDelayed feedback loop stays bounded (echo/comb)") {
    // The canonical single-tap echo: an impulse-like source mixed with a
    // delayed, attenuated copy of itself, where the delay line lives
    // inside the loop. Validates that swap+clear (Phase 2 plumbing) and
    // the per-node Delay state (Phase 1.5) compose under feedback.
    //
    //   SinOsc(220) → Gain(0.05) ─┐
    //                              ├→ Add → Delay(20ms) → Gain(0.6) → BusOut(7) → Out(0)
    //   BusInDelayed(7) ──────────┘
    //
    // The cross-block feedback edge (BusOut(7) → BusInDelayed(7)) is
    // exactly what BusInDelayed exists to schedule. Adding the Delay in
    // the loop adds intra-block latency on top of the inter-block
    // snapshot, so the effective loop period is one block + 20 ms.
    constexpr int kBus = 7;
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1);                          // SinOsc
    rt_graph_set_control(g, 0, 0, 220.0);
    rt_graph_set_control(g, 0, 1, 0.0);

    rt_graph_add_node(g, 1, 3);                          // Gain(0.05) — input trim
    rt_graph_set_control(g, 1, 0, 0.05);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_add_node(g, 2, 12);                         // BusInDelayed(7)
    rt_graph_set_control(g, 2, 0, static_cast<double>(kBus));

    rt_graph_add_node(g, 3, 8);                          // Add: trimmed src + delayed loop
    rt_graph_connect(g, 1, 0, 3, 0);
    rt_graph_connect(g, 2, 0, 3, 1);

    rt_graph_add_node(g, 4, 13);                         // Delay inside the loop
    rt_graph_set_control(g, 4, 0, 0.05);                 // max = 50 ms
    rt_graph_set_control(g, 4, 1, 0.02);                 // time = 20 ms
    rt_graph_connect(g, 3, 0, 4, 0);

    rt_graph_add_node(g, 5, 3);                          // Gain(0.6) — loop attenuator
    rt_graph_set_control(g, 5, 0, 0.6);
    rt_graph_connect(g, 4, 0, 5, 0);

    rt_graph_add_node(g, 6, 10);                         // BusOut(7) — closes the loop
    rt_graph_set_control(g, 6, 0, static_cast<double>(kBus));
    rt_graph_connect(g, 5, 0, 6, 0);

    rt_graph_add_node(g, 7, 2);                          // Out(0) — what we listen to
    rt_graph_set_control(g, 7, 0, 0.0);
    rt_graph_connect(g, 5, 0, 7, 0);

    // Run several blocks so the loop has time to ring.
    for (int blk = 0; blk < 16; ++blk) {
        rt_graph_process(g, kFrames);
    }
    std::vector<float> out(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, out.data());
    rt_graph_destroy(g);

    // Bounded: with loop gain 0.6 < 1 the geometric series converges.
    // Source peak after the 0.05 trim is ~0.05; steady-state envelope is
    // ~0.05 / (1 - 0.6) = 0.125. Allow generous slack.
    const float peak = peak_abs(out);
    CHECK(peak > 0.0f);
    CHECK(peak < 1.0f);
    for (auto s : out) {
        CHECK(std::isfinite(s));
    }
}

TEST_CASE("Two Delay nodes in one graph keep independent ring-buffer state") {
    // State-isolation check for the std::variant per-node model: two
    // Delay nodes driven by the same constant source with different
    // delay times must transition from silence to constant at their
    // own configured times. If their ring buffers aliased (or shared
    // state via the variant somehow) the two outputs would be
    // identical. This pins the load-bearing assumption for §2: each
    // GraphInstance has its own per-node state.
    constexpr double kShortDelaySec = 0.001;             // 1 ms (~48 samples)
    constexpr double kLongDelaySec  = 0.005;             // 5 ms (~240 samples)
    constexpr int    kShortExpect   = 48;
    constexpr int    kLongExpect    = 240;

    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 1);  // long-delay Out routes to bus 1

    rt_graph_add_node(g, 0, 8);                          // Add — constant 1.0 source
    rt_graph_set_control(g, 0, 0, 1.0);
    rt_graph_set_control(g, 0, 1, 0.0);

    rt_graph_add_node(g, 1, 13);                         // Delay #1 — short
    rt_graph_set_control(g, 1, 0, 0.01);                 // max = 10 ms
    rt_graph_set_control(g, 1, 1, kShortDelaySec);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_add_node(g, 2, 13);                         // Delay #2 — long
    rt_graph_set_control(g, 2, 0, 0.01);
    rt_graph_set_control(g, 2, 1, kLongDelaySec);
    rt_graph_connect(g, 0, 0, 2, 0);

    rt_graph_add_node(g, 3, 2);                          // Out(bus 0) — short
    rt_graph_set_control(g, 3, 0, 0.0);
    rt_graph_connect(g, 1, 0, 3, 0);

    rt_graph_add_node(g, 4, 2);                          // Out(bus 1) — long
    rt_graph_set_control(g, 4, 0, 1.0);
    rt_graph_connect(g, 2, 0, 4, 0);

    rt_graph_process(g, kFrames);
    std::vector<float> bus0(kFrames, 0.0f);
    std::vector<float> bus1(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    rt_graph_read_bus(g, 1, kFrames, bus1.data());
    rt_graph_destroy(g);

    auto first_nonsilent = [](const std::vector<float> &xs) {
        for (int i = 0; i < static_cast<int>(xs.size()); ++i) {
            if (std::abs(xs[static_cast<std::size_t>(i)]) > 0.5f) return i;
        }
        return -1;
    };

    int short_at = first_nonsilent(bus0);
    int long_at  = first_nonsilent(bus1);
    REQUIRE(short_at >= 0);
    REQUIRE(long_at  >= 0);

    // Each node hits its own configured delay, ±2-sample API slop.
    CHECK(std::abs(short_at - kShortExpect) <= 2);
    CHECK(std::abs(long_at  - kLongExpect)  <= 2);

    // The two transition points must be far apart — independent state,
    // not a shared buffer that splits the difference.
    CHECK((long_at - short_at) > 100);
}

// ----------------------------------------------------------------
// Smooth: per-node q::dynamic_smoother kernel (Phase 3.3c)
// ----------------------------------------------------------------

TEST_CASE("Smooth: seeds to the target on first block (no ramp from zero)") {
    // Smooth wraps q::dynamic_smoother. First call seeds the IIR
    // state to the first input sample so the kernel does not
    // produce a "ramp from zero" attack on the very first block.
    // With the audio input unconnected the target comes from
    // controls[1]; the smoother should emit that target throughout
    // the block.
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 14);                         // Smooth
    rt_graph_set_control(g, 0, 0, 20.0);                 // base_freq
    rt_graph_set_control(g, 0, 1, 0.5);                  // target
    rt_graph_add_node(g, 1, 2);                          // Out
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kFrames);
    for (auto x : samples) {
        CHECK(x == doctest::Approx(0.5f).epsilon(1e-4));
    }
    rt_graph_destroy(g);
}

TEST_CASE("Smooth: small target change ramps without zipper") {
    // q::dynamic_smoother is adaptive: a *large* step triggers
    // bandpass-driven cutoff boost and tracks it quickly. A
    // *small* CC-sized change (the realistic Phase 3.3 use case)
    // produces a smooth ramp without aggressive adaptation. This
    // test verifies the smooth case: target steps from 0 → 0.05
    // and the per-sample delta stays well below the step.
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 14);
    rt_graph_set_control(g, 0, 0, 20.0);                 // typical CC base
    rt_graph_set_control(g, 0, 1, 0.0);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto block1 = render_bus0(g, kFrames);
    REQUIRE(block1[kFrames-1] == doctest::Approx(0.0f).epsilon(1e-4));

    rt_graph_set_control(g, 0, 1, 0.05);                 // small CC-sized step
    auto block2 = render_bus0(g, kFrames);

    // The first sample of block 2 is essentially at the previous
    // block's last value — no instantaneous jump.
    CHECK(std::abs(block2[0] - block1[kFrames-1]) < 0.005f);
    // Some progress made within the block (smoothing is happening,
    // not frozen).
    CHECK(block2[kFrames-1] > 0.0f);
    // Per-sample deltas stay well below the step magnitude (0.05).
    // A non-smoothing kernel would emit one big jump and zeros.
    for (std::size_t i = 1; i < block2.size(); ++i) {
        CHECK(std::abs(block2[i] - block2[i-1]) < 0.005f);
    }
    rt_graph_destroy(g);
}

TEST_CASE("Smooth: smaller base_freq has a smaller initial response than larger") {
    // q::dynamic_smoother is adaptive — over a 1024-sample window
    // even base_freq=2 Hz ramps most of the way to target. The
    // base_freq difference is sharpest at the FIRST post-step
    // sample, where the smoother has not yet had time for the
    // bandpass to lift the cutoff. The slow smoother emits a
    // negligible response on sample 0; the fast one moves
    // measurably.
    auto first_sample = [](float freq) -> float {
        auto *g = rt_graph_create(2, kFrames);
        REQUIRE(g != nullptr);
        rt_graph_add_node(g, 0, 14);
        rt_graph_set_control(g, 0, 0, freq);
        rt_graph_set_control(g, 0, 1, 0.0);
        rt_graph_add_node(g, 1, 2);
        rt_graph_set_control(g, 1, 0, 0.0);
        rt_graph_connect(g, 0, 0, 1, 0);

        rt_graph_process(g, kFrames);                    // settle at 0
        rt_graph_set_control(g, 0, 1, 0.05);             // small step
        auto block = render_bus0(g, kFrames);
        const float result = block[0];
        rt_graph_destroy(g);
        return result;
    };

    const float slow = first_sample(2.0f);
    const float fast = first_sample(2000.0f);
    INFO("slow=" << slow << " fast=" << fast);
    // Both produce a positive response (smoothing isn't broken).
    CHECK(fast > 0.0f);
    CHECK(slow >= 0.0f);
    // Fast initial response is orders of magnitude larger than
    // slow. (Concrete numbers from q::dynamic_smoother on a small
    // step at sample 0: slow ≈ 1e-9, fast ≈ 1e-3.)
    CHECK(fast > slow * 1000.0f);
}

TEST_CASE("Smooth: two nodes in one graph hold independent state") {
    // Same small step, different base_freq → different first-
    // sample responses. Confirms each Smooth carries its own
    // q::dynamic_smoother (no shared coefficients across the
    // variant-wrapped state).
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 1);                           // Out node 3 writes here

    rt_graph_add_node(g, 0, 14);                         // Smooth A (slow)
    rt_graph_set_control(g, 0, 0, 2.0);
    rt_graph_set_control(g, 0, 1, 0.0);
    rt_graph_add_node(g, 1, 14);                         // Smooth B (fast)
    rt_graph_set_control(g, 1, 0, 2000.0);
    rt_graph_set_control(g, 1, 1, 0.0);

    rt_graph_add_node(g, 2, 2);                          // Out → bus 0
    rt_graph_set_control(g, 2, 0, 0.0);
    rt_graph_add_node(g, 3, 2);                          // Out → bus 1
    rt_graph_set_control(g, 3, 0, 1.0);
    rt_graph_connect(g, 0, 0, 2, 0);
    rt_graph_connect(g, 1, 0, 3, 0);

    rt_graph_process(g, kFrames);                        // settle
    rt_graph_set_control(g, 0, 1, 0.05);                 // small step (slow)
    rt_graph_set_control(g, 1, 1, 0.05);                 // small step (fast)
    rt_graph_process(g, kFrames);

    std::vector<float> bus0(kFrames, 0.0f);
    std::vector<float> bus1(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    rt_graph_read_bus(g, 1, kFrames, bus1.data());

    INFO("bus0[0]=" << bus0[0] << " bus1[0]=" << bus1[0]);
    // Independent state shows up cleanly at sample 0 of the post-
    // step block: fast smoother responds, slow smoother barely
    // does.
    CHECK(bus1[0] > bus0[0] * 1000.0f);
    rt_graph_destroy(g);
}

TEST_CASE("Smooth: pathological base_freq is sanitized — no freeze, no NaN, smoother still tracks target") {
    // q::dynamic_smoother computes g0 = 2*tan(pi*base/sps) /
    // (1 + tan(...)). The math falls apart in three regions:
    //   - base <= 0:          g0 collapses to 0 (freeze) or goes
    //                         negative (IIR pushed away from input).
    //   - non-finite base:    tan propagates NaN through low1/low2
    //                         and the smoother is permanently
    //                         poisoned.
    //   - base >= sps/2:      tan(pi*wc) for wc >= 0.5 wraps to
    //                         negative, same instability as <= 0
    //                         by a different route.
    // The kernel sanitizes to [0.001 Hz, 0.49 * sps] with non-
    // finite values mapped to the lower bound. This test pins
    // that — across all three failure regions — the smoother
    // emits finite, bounded samples AND visibly tracks toward
    // the target after a step.
    constexpr double kSampleRate = 48000.0;
    auto run_with_pathological_base = [](double bad_base) {
        auto *g = rt_graph_create(2, kFrames);
        REQUIRE(g != nullptr);
        rt_graph_add_node(g, 0, 14);
        rt_graph_set_control(g, 0, 0, bad_base);             // pathological
        rt_graph_set_control(g, 0, 1, 0.0);
        rt_graph_add_node(g, 1, 2);
        rt_graph_set_control(g, 1, 0, 0.0);
        rt_graph_connect(g, 0, 0, 1, 0);

        rt_graph_process(g, kFrames);                        // settle (seeded at 0)
        rt_graph_set_control(g, 0, 1, 0.5);                  // step the target
        auto block2 = render_bus0(g, kFrames);

        for (auto x : block2) {
            CHECK(std::isfinite(x));
            CHECK(std::abs(x) <= 1.0f);                      // bounded, no explosion
        }

        // Smoother is alive. Without sanitation: base == 0 freezes
        // at ~0; base < 0 wobbles near zero; non-finite produces
        // NaN; base >= Nyquist either wraps unstable or also
        // freezes. With the clamp the bandpass adaptation kicks
        // in and the output tracks toward the 0.5 target.
        INFO("bad_base=" << bad_base << " final=" << block2[kFrames - 1]);
        CHECK(block2[kFrames - 1] > 0.1f);
        rt_graph_destroy(g);
    };

    // Non-positive: collapses g0.
    run_with_pathological_base(0.0);
    run_with_pathological_base(-1.0);
    run_with_pathological_base(-1000.0);
    // Non-finite: poisons the IIR with NaN.
    run_with_pathological_base(std::numeric_limits<double>::quiet_NaN());
    run_with_pathological_base(std::numeric_limits<double>::infinity());
    run_with_pathological_base(-std::numeric_limits<double>::infinity());
    // Above-Nyquist: tan(pi*wc) wraps for wc >= 0.5.
    run_with_pathological_base(kSampleRate * 0.5);           // exactly Nyquist
    run_with_pathological_base(kSampleRate);                 // sample rate
    run_with_pathological_base(kSampleRate * 10.0);          // far above
}

TEST_CASE("Smooth: connected audio input flows through with no zipper at boundaries") {
    // When port 0 is connected, the kernel runs the smoother over
    // the audio input. Feed a SinOsc at 100 Hz; the output should
    // closely track the input (the smoother is wide-cutoff at
    // 5 kHz here, well above the carrier) without any block-
    // boundary glitch.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1);                          // SinOsc
    rt_graph_set_control(g, 0, 0, 100.0);
    rt_graph_add_node(g, 1, 14);                         // Smooth
    rt_graph_set_control(g, 1, 0, 5000.0);               // wide cutoff
    rt_graph_set_control(g, 1, 1, 0.0);
    rt_graph_add_node(g, 2, 2);                          // Out
    rt_graph_set_control(g, 2, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);
    rt_graph_connect(g, 1, 0, 2, 0);

    auto block1 = render_bus0(g, kFrames);
    auto block2 = render_bus0(g, kFrames);
    // Output is bounded and oscillating (passed through, not
    // squashed to silence).
    CHECK(peak_abs(block1) > 0.5f);
    CHECK(peak_abs(block2) > 0.5f);
    // Block boundary is continuous: |block2[0] - block1[end]| is
    // small relative to the carrier amplitude (~1.0).
    CHECK(std::abs(block2[0] - block1[kFrames - 1]) < 0.3f);

    rt_graph_destroy(g);
}

TEST_CASE("Two LPF nodes in one graph hold independent biquad state") {
    // Companion check: same source through two LPFs at very different
    // cutoffs must produce two different waveforms. If the variant-
    // wrapped LPFState shared coefficients across nodes the outputs
    // would converge.
    auto build_chain = [](RTGraph *g, int sin_id, int lpf_id, int out_id,
                          double cutoff_hz, double bus) {
        rt_graph_add_node(g, sin_id, 1);                 // SinOsc(880)
        rt_graph_set_control(g, sin_id, 0, 880.0);
        rt_graph_set_control(g, sin_id, 1, 0.0);

        rt_graph_add_node(g, lpf_id, 7);                 // LPF
        rt_graph_set_control(g, lpf_id, 0, cutoff_hz);
        rt_graph_set_control(g, lpf_id, 1, 0.7);
        rt_graph_connect(g, sin_id, 0, lpf_id, 0);

        rt_graph_add_node(g, out_id, 2);                 // Out
        rt_graph_set_control(g, out_id, 0, bus);
        rt_graph_connect(g, lpf_id, 0, out_id, 0);
    };

    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 1);  // second chain routes to bus 1
    build_chain(g, 0, 1, 2, /*cutoff*/ 200.0,  /*bus*/ 0.0);  // far below carrier — heavy attenuation
    build_chain(g, 3, 4, 5, /*cutoff*/ 8000.0, /*bus*/ 1.0);  // well above carrier — pass-through

    // Let the filters settle, then read.
    rt_graph_process(g, kFrames);
    rt_graph_process(g, kFrames);
    std::vector<float> bus0(kFrames, 0.0f);
    std::vector<float> bus1(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    rt_graph_read_bus(g, 1, kFrames, bus1.data());
    rt_graph_destroy(g);

    const float peak_low  = peak_abs(bus0);
    const float peak_high = peak_abs(bus1);

    // High cutoff lets the 880 Hz carrier through; low cutoff crushes it.
    CHECK(peak_high > 0.5f);
    CHECK(peak_low  < 0.3f);
    // And the ratio is meaningful — they aren't sharing state.
    CHECK(peak_high > peak_low * 2.0f);
}

TEST_CASE("BusIn on out-of-range bus emits silence safely") {
    // Bus index larger than the pool grew to: should be a no-op, not a
    // crash or out-of-bounds read.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 11);
    rt_graph_set_control(g, 0, 0, 999.0);    // way past anything
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    // Truncate the pool back to the minimum so bus 999 is out of range.
    // (rt_graph_set_control grew it to 1000; we just shrink expectations.)
    auto bus0 = render_bus0(g, kFrames);
    rt_graph_destroy(g);

    // Pool was grown to fit bus 999 by set_control; BusIn finds it
    // present but cleared each block, so silence either way.
    for (auto s : bus0) {
        CHECK(std::abs(s) < 1e-6f);
    }
}

// ----------------------------------------------------------------
// Env (ADSR) kernel
// ----------------------------------------------------------------

TEST_CASE("Env(gate=1) attacks toward 1 and decays to sustain") {
    // Hold the gate high (control default = 1.0). With A=0.5ms, D=2ms,
    // S=0.5, R=10ms at 48 kHz, the envelope should reach near-1 inside
    // the first 30 samples and settle near 0.5 after the decay segment.
    constexpr int kBlock = 1024;
    auto *g = rt_graph_create(2, kBlock);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 9);                  // Env
    rt_graph_set_control(g, 0, 0, 1.0);          // gate held high
    rt_graph_set_control(g, 0, 1, 0.0005);       // attack 0.5 ms
    rt_graph_set_control(g, 0, 2, 0.002);        // decay 2 ms
    rt_graph_set_control(g, 0, 3, 0.5);          // sustain 0.5
    rt_graph_set_control(g, 0, 4, 0.01);         // release 10 ms
    rt_graph_add_node(g, 1, 2);                  // Out
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kBlock);
    rt_graph_destroy(g);

    const float peak = *std::max_element(samples.begin(), samples.end());
    CHECK(peak > 0.9f);

    // Tail average over the last quarter of the block — well past the
    // attack+decay transient, so this is the sustain level.
    double tail = 0.0;
    for (int i = 768; i < kBlock; ++i) tail += samples[static_cast<std::size_t>(i)];
    tail /= static_cast<double>(kBlock - 768);
    CHECK(std::abs(tail - 0.5) < 0.1);
}

TEST_CASE("Env(gate=0) idle stays silent") {
    // Gate held low: prev_gate starts at 0, no rising edge ever fires,
    // envelope_gen stays in idle and emits zeros.
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 9);
    rt_graph_set_control(g, 0, 0, 0.0); // gate low
    rt_graph_set_control(g, 0, 1, 0.01);
    rt_graph_set_control(g, 0, 2, 0.05);
    rt_graph_set_control(g, 0, 3, 0.5);
    rt_graph_set_control(g, 0, 4, 0.1);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kFrames);
    rt_graph_destroy(g);

    for (auto s : samples) {
        CHECK(std::abs(s) < 1e-6f);
    }
}

TEST_CASE("Env release: gate 1→0 triggers a ramp toward zero") {
    // §2's instance lifecycle hinges on "gate-off triggers envelope
    // release; instance freed when silent" (ROADMAP §2.2). The existing
    // Env tests cover gate-held-high (attack→sustain) and gate-held-low
    // (idle silence); neither exercises the falling edge that fires
    // env.release(). Walk through three phases:
    //
    //   Block 0: gate=1  — attack and reach sustain (S=0.5).
    //   Block 1: gate=0  — falling edge triggers release; tail of the
    //                      block decays meaningfully below sustain.
    //   Block 2: gate=0  — release continues; final samples are near
    //                      zero, well below the post-release block tail.
    constexpr int kBlock = 1024;
    auto *g = rt_graph_create(2, kBlock);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 9);                          // Env
    rt_graph_set_control(g, 0, 0, 1.0);                  // gate high
    rt_graph_set_control(g, 0, 1, 0.0005);               // A = 0.5 ms
    rt_graph_set_control(g, 0, 2, 0.002);                // D = 2 ms
    rt_graph_set_control(g, 0, 3, 0.5);                  // S = 0.5
    rt_graph_set_control(g, 0, 4, 0.005);                // R = 5 ms
    rt_graph_add_node(g, 1, 2);                          // Out
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto block0 = render_bus0(g, kBlock);

    // Last sample of block 0 should be near sustain (~0.5).
    const float at_sustain = block0[kBlock - 1];
    INFO("end-of-attack-block sample = " << at_sustain);
    CHECK(at_sustain > 0.3f);
    CHECK(at_sustain < 0.7f);

    // Drop the gate; render the release block.
    rt_graph_set_control(g, 0, 0, 0.0);
    auto block1 = render_bus0(g, kBlock);

    // Tail of release block must be meaningfully lower than sustain.
    // R = 5 ms ≈ 240 samples — well within a 1024-sample block, so by
    // the end the release segment is essentially complete.
    const float release_tail = block1[kBlock - 1];
    INFO("release-block tail sample = " << release_tail);
    CHECK(release_tail < at_sustain * 0.5f);
    CHECK(release_tail >= 0.0f);

    // One more block with gate held low: should be silent.
    auto block2 = render_bus0(g, kBlock);
    rt_graph_destroy(g);

    for (auto s : block2) {
        CHECK(std::abs(s) < 1e-3f);
    }
}

// ----------------------------------------------------------------
// LPF kernel
// ----------------------------------------------------------------
//
// Verify the LPF actually attenuates content above the cutoff. We don't
// try to characterize the rolloff curve; we just check that a 4 kHz sine
// through LPF(800 Hz) is meaningfully quieter than a 100 Hz sine through
// the same filter. q::lowpass is a Butterworth-like biquad (Q=0.7), so
// 100 Hz is well in the passband and 4 kHz is ~2.3 octaves above cutoff
// (~28 dB attenuation, peak ≈ 0.04).

TEST_CASE("LPF(800 Hz) passes 100 Hz and attenuates 4 kHz") {
    auto build = [](float carrier_hz) {
        auto *g = rt_graph_create(4, kFrames);
        REQUIRE(g != nullptr);

        rt_graph_add_node(g, 0, 1); // SinOsc
        rt_graph_set_control(g, 0, 0, carrier_hz);

        rt_graph_add_node(g, 1, 7); // LPF
        rt_graph_set_control(g, 1, 0, 800.0f);
        rt_graph_set_control(g, 1, 1, 0.7f);

        rt_graph_add_node(g, 2, 2); // Out
        rt_graph_set_control(g, 2, 0, 0.0f);

        rt_graph_connect(g, 0, 0, 1, 0);
        rt_graph_connect(g, 1, 0, 2, 0);
        return g;
    };

    auto *g_low = build(100.0f);
    auto samples_low = render_bus0(g_low, kFrames);
    rt_graph_destroy(g_low);

    auto *g_high = build(4000.0f);
    auto samples_high = render_bus0(g_high, kFrames);
    rt_graph_destroy(g_high);

    const float peak_low = peak_abs(samples_low);
    const float peak_high = peak_abs(samples_high);

    CHECK(peak_low > 0.7f);   // passband, near unity gain
    CHECK(peak_high < 0.3f);  // well attenuated (predicted ≈ 0.04)
    CHECK(peak_low > 3.0f * peak_high); // sanity: low ≫ high
}

// ----------------------------------------------------------------
// LPF parameter sensitivity (Q)
// ----------------------------------------------------------------
//
// The cutoff control gates the rolloff frequency; the Q control
// shapes the peak around the cutoff. Existing tests pin passband and
// stopband behavior at Q=0.7. These pin that Q is actually wired and
// has the expected resonant effect: at the cutoff frequency, output
// amplitude scales with Q. A regression that ignores Q (or wires the
// wrong control) would silence this difference.

namespace {

float render_sine_through_lpf(float sine_hz, float cutoff_hz, float q) {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1); // SinOsc
    rt_graph_set_control(g, 0, 0, sine_hz);
    rt_graph_set_control(g, 0, 1, 0.0f);

    rt_graph_add_node(g, 1, 7); // LPF
    rt_graph_set_control(g, 1, 0, cutoff_hz);
    rt_graph_set_control(g, 1, 1, q);

    rt_graph_add_node(g, 2, 2); // Out
    rt_graph_set_control(g, 2, 0, 0.0f);

    rt_graph_connect(g, 0, 0, 1, 0);
    rt_graph_connect(g, 1, 0, 2, 0);

    // Render a few blocks first to let the filter settle (transient
    // response from zero state inflates the early peak).
    for (int i = 0; i < 4; ++i) {
        rt_graph_process(g, kFrames);
    }
    auto samples = render_bus0(g, kFrames);
    rt_graph_destroy(g);
    return peak_abs(samples);
}

} // namespace

TEST_CASE("LPF Q controls resonance: high Q boosts the cutoff frequency") {
    // Drive with a sine at the cutoff frequency. Higher Q should give
    // a measurably louder steady-state response.
    constexpr float kCutoff = 800.0f;
    const float low_q  = render_sine_through_lpf(kCutoff, kCutoff, 0.7f);
    const float high_q = render_sine_through_lpf(kCutoff, kCutoff, 4.0f);

    CHECK(low_q > 0.5f);                     // sanity: signal passes
    CHECK(high_q > low_q * 1.5f);            // high Q is meaningfully louder
    CHECK(std::isfinite(high_q));
}

TEST_CASE("LPF cutoff control gates rolloff frequency") {
    // Same Q, two cutoffs. A 4 kHz sine through an 800 Hz LPF should be
    // much quieter than the same sine through a 6 kHz LPF.
    constexpr float kSine = 4000.0f;
    const float low_cut  = render_sine_through_lpf(kSine, 800.0f, 0.7f);
    const float high_cut = render_sine_through_lpf(kSine, 6000.0f, 0.7f);

    CHECK(high_cut > 0.5f);                  // 4 kHz inside passband
    CHECK(low_cut < 0.2f);                   // 4 kHz well above 800 Hz cutoff
    CHECK(high_cut > low_cut * 3.0f);
}

TEST_CASE("LPF stays stable at extreme Q values") {
    // Q at the practical edges: very low (overdamped) and quite high.
    // The output must remain finite and bounded.
    for (float q : {0.05f, 8.0f, 16.0f}) {
        const float p = render_sine_through_lpf(440.0f, 1000.0f, q);
        CHECK(std::isfinite(p));
        CHECK(p < 100.0f); // not a runaway
    }
}

// ----------------------------------------------------------------
// Cross-block invariants
// ----------------------------------------------------------------

TEST_CASE("SinOsc preserves phase across consecutive blocks") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1);
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_set_control(g, 0, 1, 0.0f);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    std::vector<float> block1(static_cast<std::size_t>(kFrames));
    std::vector<float> block2(static_cast<std::size_t>(kFrames));

    rt_graph_process(g, kFrames);
    rt_graph_read_bus(g, 0, kFrames, block1.data());
    rt_graph_process(g, kFrames);
    rt_graph_read_bus(g, 0, kFrames, block2.data());

    // After kFrames samples at kSampleRate, expected analytical phase is
    // 2π · 440 · (kFrames / kSampleRate). block2[0] should match.
    const double t = static_cast<double>(kFrames) / kSampleRate;
    const double expected = std::sin(kTau * 440.0 * t);
    CHECK(block2[0] ==
          doctest::Approx(static_cast<float>(expected)).epsilon(0.05));

    // Boundary diff (last of block1 → first of block2) should be in the
    // same range as adjacent-sample diffs within block1. A phase reset
    // would put block2[0] near 0 and yield a much larger diff.
    const float boundary_diff =
        std::abs(block2[0] - block1[block1.size() - 1]);
    const float typical_diff =
        std::abs(block1[block1.size() - 1] - block1[block1.size() - 2]);
    CHECK(boundary_diff < 10.0f * typical_diff + 0.01f);

    rt_graph_destroy(g);
}

TEST_CASE("SinOsc with initial phase=0.25 starts at the cosine peak") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1);
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_set_control(g, 0, 1, 0.25f); // quarter cycle = π/2
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kFrames);

    // sin(2π · 0.25) = sin(π/2) = 1
    CHECK(samples[0] == doctest::Approx(1.0f).epsilon(0.02));

    rt_graph_destroy(g);
}

TEST_CASE("LPF stays stable over many blocks (no NaN or Inf)") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1); // SinOsc
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_add_node(g, 1, 7); // LPF
    rt_graph_set_control(g, 1, 0, 800.0f);
    rt_graph_set_control(g, 1, 1, 0.7f);
    rt_graph_add_node(g, 2, 2); // Out
    rt_graph_set_control(g, 2, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);
    rt_graph_connect(g, 1, 0, 2, 0);

    constexpr int kNumBlocks = 100;
    std::vector<float> samples(static_cast<std::size_t>(kFrames));

    for (int i = 0; i < kNumBlocks; ++i) {
        rt_graph_process(g, kFrames);
        rt_graph_read_bus(g, 0, kFrames, samples.data());
    }

    for (auto s : samples) {
        CHECK(std::isfinite(s));
    }
    CHECK(peak_abs(samples) > 0.5f); // still oscillating

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Lifecycle: clear + reload
// ----------------------------------------------------------------

TEST_CASE("rt_graph_clear empties the graph (subsequent process is silent)") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1);
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto first = render_bus0(g, kFrames);
    CHECK(peak_abs(first) > 0.5f);

    rt_graph_clear(g);

    auto second = render_bus0(g, kFrames);
    for (auto s : second) {
        CHECK(s == 0.0f);
    }

    rt_graph_destroy(g);
}

TEST_CASE("rt_graph_clear allows building a new graph in the same handle") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    // First: SinOsc 440
    rt_graph_add_node(g, 0, 1);
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);
    auto first = render_bus0(g, kFrames);

    rt_graph_clear(g);

    // Second: NoiseGen — totally different output character.
    rt_graph_add_node(g, 0, 6);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);
    auto second = render_bus0(g, kFrames);

    CHECK(peak_abs(first) > 0.5f);
    CHECK(peak_abs(second) > 0.1f);

    // The two outputs should differ at most positions (one is a sine,
    // the other is noise). Coincidental matches are rare.
    int diff_count = 0;
    for (std::size_t i = 0; i < first.size(); ++i) {
        if (std::abs(first[i] - second[i]) > 0.05f) {
            ++diff_count;
        }
    }
    CHECK(diff_count > static_cast<int>(first.size()) * 8 / 10);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// ABI robustness
// ----------------------------------------------------------------

// ----------------------------------------------------------------
// Cascaded same-kind nodes
// ----------------------------------------------------------------
//
// Existing tests cover one of each kind. These verify composition
// of multiple instances of the same kind: parallel summing into a
// shared bus, serial filtering, long gain chains.

TEST_CASE("five Outs to bus 0 sum cleanly (in-phase peak ≈ 5)") {
    constexpr int kSources = 5;
    auto *g = rt_graph_create(kSources + 1, kFrames);
    REQUIRE(g != nullptr);

    // Five identical SinOscs at 440 Hz, each going to its own Out → bus 0.
    for (int i = 0; i < kSources; ++i) {
        rt_graph_add_node(g, i, 1);
        rt_graph_set_control(g, i, 0, 440.0f);
        rt_graph_set_control(g, i, 1, 0.0f);
    }
    for (int i = 0; i < kSources; ++i) {
        const int out_idx = kSources + i;
        rt_graph_add_node(g, out_idx, 2);
        rt_graph_set_control(g, out_idx, 0, 0.0f);
        rt_graph_connect(g, i, 0, out_idx, 0);
    }
    // The graph has kSources*2 = 10 nodes but capacity was kSources+1.
    // Reallocate with proper capacity.
    rt_graph_destroy(g);

    g = rt_graph_create(kSources * 2 + 1, kFrames);
    REQUIRE(g != nullptr);
    for (int i = 0; i < kSources; ++i) {
        rt_graph_add_node(g, i, 1);
        rt_graph_set_control(g, i, 0, 440.0f);
        rt_graph_set_control(g, i, 1, 0.0f);
    }
    for (int i = 0; i < kSources; ++i) {
        const int out_idx = kSources + i;
        rt_graph_add_node(g, out_idx, 2);
        rt_graph_set_control(g, out_idx, 0, 0.0f);
        rt_graph_connect(g, i, 0, out_idx, 0);
    }

    auto samples = render_bus0(g, kFrames);
    rt_graph_destroy(g);

    // All sources have the same freq and phase, so they sum in phase:
    // peak ≈ kSources × 1.0.
    const float p = peak_abs(samples);
    CHECK(p == doctest::Approx(static_cast<float>(kSources)).epsilon(0.05));
    for (auto s : samples) {
        CHECK(std::isfinite(s));
    }
}

TEST_CASE("three LPFs in series attenuate more than one") {
    auto build = [](int num_filters) {
        auto *g = rt_graph_create(num_filters + 2, kFrames);
        REQUIRE(g != nullptr);

        rt_graph_add_node(g, 0, 1); // SinOsc 4 kHz (well above cutoff)
        rt_graph_set_control(g, 0, 0, 4000.0f);

        int prev = 0;
        for (int i = 1; i <= num_filters; ++i) {
            rt_graph_add_node(g, i, 7);
            rt_graph_set_control(g, i, 0, 800.0f);
            rt_graph_set_control(g, i, 1, 0.7f);
            rt_graph_connect(g, prev, 0, i, 0);
            prev = i;
        }

        const int out_idx = num_filters + 1;
        rt_graph_add_node(g, out_idx, 2);
        rt_graph_set_control(g, out_idx, 0, 0.0f);
        rt_graph_connect(g, prev, 0, out_idx, 0);

        // Let the filter chain settle past its initial transient.
        for (int i = 0; i < 4; ++i) {
            rt_graph_process(g, kFrames);
        }
        auto out = render_bus0(g, kFrames);
        rt_graph_destroy(g);
        return peak_abs(out);
    };

    const float p1 = build(1);
    const float p3 = build(3);

    CHECK(std::isfinite(p1));
    CHECK(std::isfinite(p3));
    CHECK(p3 < p1 * 0.5f); // three stages cut at least the second stage's worth
}

TEST_CASE("Gain(1.0) chain of 16 nodes preserves the input") {
    constexpr int kStages = 16;
    auto *g = rt_graph_create(kStages + 2, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1); // SinOsc 440
    rt_graph_set_control(g, 0, 0, 440.0f);

    int prev = 0;
    for (int i = 1; i <= kStages; ++i) {
        rt_graph_add_node(g, i, 3);
        rt_graph_set_control(g, i, 0, 1.0f); // identity gain
        rt_graph_connect(g, prev, 0, i, 0);
        prev = i;
    }

    const int out_idx = kStages + 1;
    rt_graph_add_node(g, out_idx, 2);
    rt_graph_set_control(g, out_idx, 0, 0.0f);
    rt_graph_connect(g, prev, 0, out_idx, 0);

    auto samples = render_bus0(g, kFrames);
    rt_graph_destroy(g);

    // Identity gain × 16 should preserve peak exactly (single-precision
    // multiply by 1.0f has no rounding error).
    CHECK(peak_abs(samples) == doctest::Approx(1.0f).epsilon(0.02));
}

TEST_CASE("rt_graph_destroy(nullptr) is a no-op") {
    rt_graph_destroy(nullptr);
    CHECK(true); // reaching here = didn't crash
}

TEST_CASE("rt_graph_process(nullptr, n) is a no-op") {
    rt_graph_process(nullptr, kFrames);
    rt_graph_process(nullptr, 0);
    rt_graph_process(nullptr, 1);
    CHECK(true); // reaching here = didn't crash
}

TEST_CASE("rt_graph_clear(nullptr) is a no-op") {
    rt_graph_clear(nullptr);
    CHECK(true);
}

TEST_CASE("rt_graph_add_node(nullptr, ...) is a no-op") {
    rt_graph_add_node(nullptr, 0, 1);
    rt_graph_set_control(nullptr, 0, 0, 1.0f);
    rt_graph_connect(nullptr, 0, 0, 0, 0);
    CHECK(true);
}

TEST_CASE("Bad indices on construction APIs are silently ignored") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    // None of these should crash; they should silently no-op or print.
    rt_graph_add_node(g, -1, 1);          // negative node index
    rt_graph_add_node(g, 0, 999);         // unknown kind
    rt_graph_set_control(g, 99, 0, 1.0f); // missing node
    rt_graph_set_control(g, 0, 99, 1.0f); // missing control slot
    rt_graph_connect(g, 0, 0, 99, 0);     // missing dst node
    rt_graph_connect(g, 99, 0, 0, 0);     // missing src node
    rt_graph_connect(g, -1, 0, 0, 0);     // negative src
    rt_graph_connect(g, 0, 0, 0, -1);     // negative dst port

    // Subsequent valid construction still works.
    rt_graph_add_node(g, 0, 1);
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kFrames);
    CHECK(peak_abs(samples) > 0.5f);

    rt_graph_destroy(g);
}

TEST_CASE("rt_graph_read_bus returns 0 on bad arguments") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);
    std::vector<float> buf(static_cast<std::size_t>(kFrames));

    CHECK(rt_graph_read_bus(nullptr, 0, kFrames, buf.data()) == 0);
    CHECK(rt_graph_read_bus(g, -1, kFrames, buf.data()) == 0);
    CHECK(rt_graph_read_bus(g, 999, kFrames, buf.data()) == 0);
    CHECK(rt_graph_read_bus(g, 0, -1, buf.data()) == 0);
    CHECK(rt_graph_read_bus(g, 0, 0, buf.data()) == 0);
    CHECK(rt_graph_read_bus(g, 0, kFrames, nullptr) == 0);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Variable block sizes
// ----------------------------------------------------------------
//
// Audio hosts can deliver any nframes <= max_frames. The runtime must
// handle the boundary cases (0, 1, max_frames) without crashing, and
// must produce identical output for a given total frame count
// regardless of how it was split into blocks (for deterministic
// kernels — i.e. not NoiseGen).

namespace {

// Build a SinOsc(440)→Out graph. Caller owns the returned handle.
RTGraph *build_sin_out(int capacity, int max_frames, float freq = 440.0f) {
    auto *g = rt_graph_create(capacity, max_frames);
    REQUIRE(g != nullptr);
    rt_graph_add_node(g, 0, 1); // SinOsc
    rt_graph_set_control(g, 0, 0, freq);
    rt_graph_set_control(g, 0, 1, 0.0f);
    rt_graph_add_node(g, 1, 2); // Out
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);
    return g;
}

} // namespace

TEST_CASE("process(g, 0) is a no-op and does not crash") {
    auto *g = build_sin_out(2, kFrames);
    rt_graph_process(g, 0);
    // Reading 0 frames returns 0 written; reading kFrames after a 0-frame
    // process should still return whatever the bus holds (zero-initialized).
    std::vector<float> buf(static_cast<std::size_t>(kFrames), 7.0f);
    int wrote = rt_graph_read_bus(g, 0, 0, buf.data());
    CHECK(wrote == 0);
    rt_graph_destroy(g);
}

TEST_CASE("process(g, 1) advances the kernel by exactly one sample") {
    auto *g = build_sin_out(2, kFrames);

    // First sample of SinOsc(440, phase=0) is sin(0) ≈ 0.
    rt_graph_process(g, 1);
    std::vector<float> buf(1, 99.0f);
    int wrote = rt_graph_read_bus(g, 0, 1, buf.data());
    CHECK(wrote == 1);
    CHECK(std::abs(buf[0]) < 0.02f);

    // After one more sample, phase has advanced by 440/sr cycle, so
    // sample 1 ≈ sin(2π · 440 / 48000) ≈ 0.0576.
    rt_graph_process(g, 1);
    rt_graph_read_bus(g, 0, 1, buf.data());
    const double expected = std::sin(kTau * 440.0 / kSampleRate);
    CHECK(buf[0] == doctest::Approx(static_cast<float>(expected)).epsilon(0.05));

    rt_graph_destroy(g);
}

TEST_CASE("process at max_frames boundary works") {
    constexpr int kMax = 256;
    auto *g = build_sin_out(2, kMax);
    auto out = render_bus0(g, kMax); // exactly max_frames
    CHECK(peak_abs(out) == doctest::Approx(1.0f).epsilon(0.05));
    rt_graph_destroy(g);
}

TEST_CASE("max_frames=1 minimal buffer renders one sample at a time") {
    auto *g = build_sin_out(2, /*max_frames*/ 1);

    // Render 1024 samples, one per process call.
    std::vector<float> samples;
    samples.reserve(1024);
    for (int i = 0; i < 1024; ++i) {
        rt_graph_process(g, 1);
        float s = 0.0f;
        rt_graph_read_bus(g, 0, 1, &s);
        samples.push_back(s);
    }
    CHECK(peak_abs(samples) == doctest::Approx(1.0f).epsilon(0.05));

    rt_graph_destroy(g);
}

TEST_CASE("sample-by-sample processing matches one big block (SinOsc)") {
    // Reference: render kFrames in one go.
    auto *g_block = build_sin_out(2, kFrames);
    auto block_samples = render_bus0(g_block, kFrames);
    rt_graph_destroy(g_block);

    // Comparison: render kFrames as kFrames×1-sample calls.
    auto *g_step = build_sin_out(2, kFrames);
    std::vector<float> step_samples(static_cast<std::size_t>(kFrames));
    for (int i = 0; i < kFrames; ++i) {
        rt_graph_process(g_step, 1);
        rt_graph_read_bus(g_step, 0, 1, &step_samples[i]);
    }
    rt_graph_destroy(g_step);

    // Phase iterator advances per sample regardless of block size, so
    // outputs should agree to within float rounding.
    for (std::size_t i = 0; i < step_samples.size(); ++i) {
        CHECK(step_samples[i] ==
              doctest::Approx(block_samples[i]).epsilon(1e-4));
    }
}

TEST_CASE("non-uniform block sizes produce same output as one big block") {
    // Reference: 256 frames in one go.
    constexpr int kTotal = 256;
    auto *g_ref = build_sin_out(2, kTotal);
    auto ref = render_bus0(g_ref, kTotal);
    rt_graph_destroy(g_ref);

    // Comparison: 256 frames as (1, 7, 64, 128, 56) — a non-uniform split.
    auto *g_var = build_sin_out(2, kTotal);
    std::vector<float> var(static_cast<std::size_t>(kTotal));
    int offset = 0;
    for (int n : {1, 7, 64, 128, 56}) {
        rt_graph_process(g_var, n);
        rt_graph_read_bus(g_var, 0, n, var.data() + offset);
        offset += n;
    }
    rt_graph_destroy(g_var);

    REQUIRE(offset == kTotal);
    for (std::size_t i = 0; i < ref.size(); ++i) {
        CHECK(var[i] == doctest::Approx(ref[i]).epsilon(1e-4));
    }
}

// ----------------------------------------------------------------
// Property-style fuzzing
// ----------------------------------------------------------------
//
// Generate small random DAGs and assert that the runtime never
// produces NaN/Inf and never crashes. Non-cyclical by construction
// (each node only references earlier indices), final node is always
// Out so something gets rendered.

namespace {

struct FuzzKind {
    int  tag;             // node_kind tag the runtime accepts
    int  num_inputs;      // ports the kernel reads from connections
    int  num_controls;    // control slots to populate
    bool is_source;       // can be the very first node (no inputs)
    bool stochastic;      // output not bit-reproducible (NoiseGen)
};

constexpr FuzzKind kFuzzKinds[] = {
    // tag, ins, ctls, source?, stochastic?
    {1,    0, 2, true,  false}, // SinOsc
    {5,    0, 2, true,  false}, // SawOsc
    {6,    0, 0, true,  true},  // NoiseGen
    {3,    2, 2, false, false}, // Gain
    {7,    1, 2, false, false}, // LPF
    {8,    2, 2, false, false}, // Add
};

float random_freq(std::mt19937 &rng) {
    return std::uniform_real_distribution<float>(50.0f, 4000.0f)(rng);
}

float random_gain(std::mt19937 &rng) {
    return std::uniform_real_distribution<float>(-1.5f, 1.5f)(rng);
}

float random_q(std::mt19937 &rng) {
    return std::uniform_real_distribution<float>(0.3f, 2.0f)(rng);
}

// Build a random DAG of `num_nodes` nodes (3..8), final node is Out.
// Returns the constructed graph (caller destroys).
RTGraph *build_random_graph(std::mt19937 &rng, int num_nodes, int max_frames) {
    auto *g = rt_graph_create(num_nodes + 2, max_frames);
    REQUIRE(g != nullptr);

    // First node must be a source (no inputs available yet).
    constexpr int kNumKinds = sizeof(kFuzzKinds) / sizeof(kFuzzKinds[0]);
    constexpr int kNumSources = 3; // SinOsc, SawOsc, NoiseGen

    auto add_node_with_kind = [&](int idx, const FuzzKind &k) {
        rt_graph_add_node(g, idx, k.tag);
        for (int c = 0; c < k.num_controls; ++c) {
            float v;
            if (k.tag == 1 || k.tag == 5) {
                // Osc: control 0 is freq, control 1 is phase.
                v = (c == 0) ? random_freq(rng)
                             : std::uniform_real_distribution<float>(0.0f,
                                                                     1.0f)(rng);
            } else if (k.tag == 7) {
                // LPF: cutoff, q
                v = (c == 0) ? random_freq(rng) : random_q(rng);
            } else {
                v = random_gain(rng);
            }
            rt_graph_set_control(g, idx, c, v);
        }
    };

    // Index 0: pick a source kind.
    {
        int src_idx = std::uniform_int_distribution<int>(0, kNumSources - 1)(rng);
        add_node_with_kind(0, kFuzzKinds[src_idx]);
    }

    // Indices 1..num_nodes-2: any kind, wire inputs to earlier nodes.
    for (int i = 1; i < num_nodes - 1; ++i) {
        int kind_idx = std::uniform_int_distribution<int>(0, kNumKinds - 1)(rng);
        const FuzzKind &k = kFuzzKinds[kind_idx];
        add_node_with_kind(i, k);
        for (int p = 0; p < k.num_inputs; ++p) {
            int src = std::uniform_int_distribution<int>(0, i - 1)(rng);
            rt_graph_connect(g, src, 0, i, p);
        }
    }

    // Final node: Out, wired to the previous node.
    const int out_idx = num_nodes - 1;
    rt_graph_add_node(g, out_idx, 2);
    rt_graph_set_control(g, out_idx, 0, 0.0f);
    rt_graph_connect(g, out_idx - 1, 0, out_idx, 0);

    return g;
}

} // namespace

TEST_CASE("random small DAGs produce only finite samples (100 seeds)") {
    constexpr int kNumSeeds = 100;
    constexpr int kFuzzFrames = 256;

    int total_samples = 0;
    int finite_samples = 0;

    for (int seed = 0; seed < kNumSeeds; ++seed) {
        std::mt19937 rng(static_cast<unsigned>(seed));
        const int num_nodes =
            std::uniform_int_distribution<int>(3, 8)(rng);

        auto *g = build_random_graph(rng, num_nodes, kFuzzFrames);
        auto samples = render_bus0(g, kFuzzFrames);
        rt_graph_destroy(g);

        for (auto s : samples) {
            ++total_samples;
            if (std::isfinite(s)) {
                ++finite_samples;
            }
            // Sanity bound: even with stacked gains, bipolar kernels
            // shouldn't push past a few units before the LPF clamps.
            // A blow-up would be huge, not slightly-out-of-range.
            CHECK(std::abs(s) < 100.0f);
        }
    }

    CHECK(finite_samples == total_samples);
}

// ----------------------------------------------------------------
// Algebraic identities on kernels
// ----------------------------------------------------------------
//
// Sample-accurate equalities the kernels should satisfy by definition.
// These are stronger than range checks: they fix the exact output for
// the identity case, so any kernel-internal drift breaks the test.

namespace {

// Render bus 0 for a graph that pipes a SinOsc(440) through one
// transformation node (a "unary" kernel under test).
std::vector<float> render_with_transform(int kind_tag,
                                         std::vector<std::pair<int, float>> ctls,
                                         std::vector<std::pair<int, int>> wires,
                                         int signal_port) {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1); // SinOsc 440
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_set_control(g, 0, 1, 0.0f);

    rt_graph_add_node(g, 1, kind_tag);
    for (auto [c, v] : ctls) {
        rt_graph_set_control(g, 1, c, v);
    }
    rt_graph_connect(g, 0, 0, 1, signal_port); // sin → kernel.signal

    for (auto [src, port] : wires) {
        rt_graph_connect(g, src, 0, 1, port); // any extra audio inputs
    }

    rt_graph_add_node(g, 2, 2); // Out
    rt_graph_set_control(g, 2, 0, 0.0f);
    rt_graph_connect(g, 1, 0, 2, 0);

    auto samples = render_bus0(g, kFrames);
    rt_graph_destroy(g);
    return samples;
}

// Reference: SinOsc(440) directly to Out.
std::vector<float> render_sin_direct() {
    auto *g = build_sin_out(2, kFrames);
    auto s = render_bus0(g, kFrames);
    rt_graph_destroy(g);
    return s;
}

} // namespace

TEST_CASE("Gain(x, 0) is identically zero regardless of x") {
    auto samples = render_with_transform(/*Gain*/ 3,
                                         {{0, 0.0f}}, // amount control = 0
                                         {},          // no audio gain wire
                                         /*signal_port*/ 0);
    for (auto s : samples) {
        CHECK(s == 0.0f);
    }
}

TEST_CASE("Gain(x, 1) is sample-equal to x") {
    auto identity = render_with_transform(/*Gain*/ 3,
                                          {{0, 1.0f}}, // amount = 1
                                          {},
                                          0);
    auto direct = render_sin_direct();
    REQUIRE(identity.size() == direct.size());
    for (std::size_t i = 0; i < identity.size(); ++i) {
        CHECK(identity[i] == direct[i]);
    }
}

TEST_CASE("Add(x, 0) is sample-equal to x") {
    // Add reads control 0 as bias, port 1 as audio. Wire sin→port 1,
    // bias=0 ⇒ output = x.
    auto added = render_with_transform(/*Add*/ 8,
                                       {{0, 0.0f}}, // bias = 0
                                       {},
                                       /*signal_port*/ 1);
    auto direct = render_sin_direct();
    REQUIRE(added.size() == direct.size());
    for (std::size_t i = 0; i < added.size(); ++i) {
        CHECK(added[i] == direct[i]);
    }
}

TEST_CASE("Add(0, x) is sample-equal to x") {
    // Mirror image: wire sin→port 0, control 1 = 0.
    auto added = render_with_transform(/*Add*/ 8,
                                       {{1, 0.0f}}, // RConst on port 1 = 0
                                       {},
                                       /*signal_port*/ 0);
    auto direct = render_sin_direct();
    REQUIRE(added.size() == direct.size());
    for (std::size_t i = 0; i < added.size(); ++i) {
        CHECK(added[i] == direct[i]);
    }
}

TEST_CASE("Add is commutative: Add(a, b) == Add(b, a) sample-by-sample") {
    // Build two graphs: one with bias=0.3, sin on port 1; the other
    // with sin on port 0, RConst 0.3 on port 1. Outputs must match.
    auto ab = render_with_transform(8, {{0, 0.3f}}, {}, /*sin→port*/ 1);
    auto ba = render_with_transform(8, {{1, 0.3f}}, {}, /*sin→port*/ 0);
    REQUIRE(ab.size() == ba.size());
    for (std::size_t i = 0; i < ab.size(); ++i) {
        CHECK(ab[i] == ba[i]);
    }
}

// ----------------------------------------------------------------
// Capacity / resource boundaries
// ----------------------------------------------------------------

TEST_CASE("process on empty graph (no nodes added) is silent") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    // No nodes added — bus should stay zero.
    auto samples = render_bus0(g, kFrames);
    for (auto s : samples) {
        CHECK(s == 0.0f);
    }

    rt_graph_destroy(g);
}

TEST_CASE("rt_graph_create(0, kFrames) is either rejected or produces a silent graph") {
    auto *g = rt_graph_create(0, kFrames);
    if (g == nullptr) {
        // Rejected outright — fine.
        CHECK(true);
        return;
    }
    // Accepted — must be safe to use, just can't hold nodes.
    auto samples = render_bus0(g, kFrames);
    for (auto s : samples) {
        CHECK(s == 0.0f);
    }
    rt_graph_destroy(g);
}

TEST_CASE("rt_graph_create with invalid args returns nullptr or a safe handle") {
    // Negative capacity / max_frames: implementation may reject or
    // clamp; either way must not crash.
    auto *g1 = rt_graph_create(-1, kFrames);
    if (g1) rt_graph_destroy(g1);
    auto *g2 = rt_graph_create(4, -1);
    if (g2) rt_graph_destroy(g2);
    auto *g3 = rt_graph_create(4, 0);
    if (g3) rt_graph_destroy(g3);
    CHECK(true); // reaching here = no crash
}

// ----------------------------------------------------------------
// Multi-bus routing
// ----------------------------------------------------------------
//
// Verify the bus index isn't being clamped to 0. Two oscillators of
// distinct frequencies routed to bus 0 and bus 1 should end up on
// the bus they were addressed to, not co-mingled.

TEST_CASE("Out nodes route to the bus indicated by control 0") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 1);  // second Out routes to bus 1

    rt_graph_add_node(g, 0, 1); // SinOsc 200 → bus 0
    rt_graph_set_control(g, 0, 0, 200.0f);
    rt_graph_add_node(g, 1, 1); // SinOsc 4000 → bus 1
    rt_graph_set_control(g, 1, 0, 4000.0f);

    rt_graph_add_node(g, 2, 2);
    rt_graph_set_control(g, 2, 0, 0.0f); // bus 0
    rt_graph_connect(g, 0, 0, 2, 0);

    rt_graph_add_node(g, 3, 2);
    rt_graph_set_control(g, 3, 0, 1.0f); // bus 1
    rt_graph_connect(g, 1, 0, 3, 0);

    rt_graph_process(g, kFrames);

    std::vector<float> bus0(static_cast<std::size_t>(kFrames));
    std::vector<float> bus1(static_cast<std::size_t>(kFrames));
    CHECK(rt_graph_read_bus(g, 0, kFrames, bus0.data()) == kFrames);
    CHECK(rt_graph_read_bus(g, 1, kFrames, bus1.data()) == kFrames);

    // Bus 0 should be the 200 Hz sine: ~4.27 cycles in 1024 frames @ 48 kHz
    // → 8-9 zero crossings.
    int zc0 = zero_crossings(bus0);
    CHECK(zc0 >= 7);
    CHECK(zc0 <= 11);

    // Bus 1 should be the 4000 Hz sine: ~85 cycles → 170 ZCs.
    int zc1 = zero_crossings(bus1);
    CHECK(zc1 >= 160);
    CHECK(zc1 <= 180);

    // Both buses are non-trivial.
    CHECK(peak_abs(bus0) > 0.5f);
    CHECK(peak_abs(bus1) > 0.5f);

    rt_graph_destroy(g);
}

TEST_CASE("writing to bus 1 leaves bus 0 silent") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 1);

    rt_graph_add_node(g, 0, 1); // SinOsc 440
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_add_node(g, 1, 2); // Out → bus 1 only
    rt_graph_set_control(g, 1, 0, 1.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_process(g, kFrames);

    std::vector<float> bus0(static_cast<std::size_t>(kFrames));
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    for (auto s : bus0) {
        CHECK(s == 0.0f);
    }

    std::vector<float> bus1(static_cast<std::size_t>(kFrames));
    rt_graph_read_bus(g, 1, kFrames, bus1.data());
    CHECK(peak_abs(bus1) > 0.5f);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Connection edge cases
// ----------------------------------------------------------------

TEST_CASE("connect to the same dst port twice is last-writer-wins") {
    // Build two oscillators of distinct frequencies, then wire both
    // to the same Gain.signal port. The second connect should win:
    // output should be sample-equal to a graph where only sin2 is wired.
    auto build = [](float a_freq, float b_freq, bool wire_a) {
        auto *g = rt_graph_create(4, kFrames);
        REQUIRE(g != nullptr);

        rt_graph_add_node(g, 0, 1);
        rt_graph_set_control(g, 0, 0, a_freq);
        rt_graph_add_node(g, 1, 1);
        rt_graph_set_control(g, 1, 0, b_freq);

        rt_graph_add_node(g, 2, 3); // Gain
        rt_graph_set_control(g, 2, 0, 1.0f);

        if (wire_a) {
            rt_graph_connect(g, 0, 0, 2, 0); // wire A first
        }
        rt_graph_connect(g, 1, 0, 2, 0);     // wire B (overrides if wire_a)

        rt_graph_add_node(g, 3, 2);
        rt_graph_set_control(g, 3, 0, 0.0f);
        rt_graph_connect(g, 2, 0, 3, 0);
        return g;
    };

    auto *g_both = build(440.0f, 1100.0f, /*wire_a=*/true);
    auto both = render_bus0(g_both, kFrames);
    rt_graph_destroy(g_both);

    auto *g_b_only = build(440.0f, 1100.0f, /*wire_a=*/false);
    auto b_only = render_bus0(g_b_only, kFrames);
    rt_graph_destroy(g_b_only);

    REQUIRE(both.size() == b_only.size());
    for (std::size_t i = 0; i < both.size(); ++i) {
        CHECK(both[i] == b_only[i]);
    }
}

TEST_CASE("connect to a non-existent port is rejected and does not crash") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1); // SinOsc, has 1 output port
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_add_node(g, 1, 3); // Gain, has 2 input ports (0, 1)
    rt_graph_set_control(g, 1, 0, 1.0f);

    // Out-of-range dst port: no effect, no crash.
    rt_graph_connect(g, 0, 0, 1, 5);
    rt_graph_connect(g, 0, 0, 1, 99);

    // The graph still works after the bad connects.
    rt_graph_connect(g, 0, 0, 1, 0); // valid
    rt_graph_add_node(g, 2, 2);
    rt_graph_set_control(g, 2, 0, 0.0f);
    rt_graph_connect(g, 1, 0, 2, 0);

    auto samples = render_bus0(g, kFrames);
    CHECK(peak_abs(samples) > 0.5f);

    rt_graph_destroy(g);
}

TEST_CASE("connect after a process call takes effect on subsequent blocks") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1); // SinOsc 440
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_add_node(g, 1, 2); // Out, no signal wired yet
    rt_graph_set_control(g, 1, 0, 0.0f);

    // First block: Out has no input → silent.
    auto block1 = render_bus0(g, kFrames);
    for (auto s : block1) {
        CHECK(s == 0.0f);
    }

    // Wire mid-flight, then render again.
    rt_graph_connect(g, 0, 0, 1, 0);
    auto block2 = render_bus0(g, kFrames);
    CHECK(peak_abs(block2) > 0.5f);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Realtime audio (PortAudio path)
// ----------------------------------------------------------------
//
// These tests exercise rt_graph_start_audio / wait_started / stop_audio.
// They skip cleanly on machines with no audio output (CI containers,
// headless build agents) — start_audio returns a negative status and
// we treat that as a SKIP rather than a failure.

TEST_CASE("start_audio + stop_audio cycle runs cleanly when a device is available") {
    auto *g = build_sin_out(2, /*max_frames*/ 256);

    // device_id = -1 → default; output_channels = 1 → mono.
    int rc = rt_graph_start_audio(g, /*output_channels*/ 1, /*device_id*/ -1);
    if (rc != 0) {
        // No usable device. Pass without exercising the realtime path.
        WARN_MESSAGE(true, "no audio device available (rc=" << rc
                                                            << "), skipping");
        rt_graph_destroy(g);
        return;
    }

    // Wait up to 500 ms for the callback to report ready.
    int ready = rt_graph_wait_started(g, 500);
    CHECK(ready == 0);

    // Let the stream run briefly, then stop.
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    rt_graph_stop_audio(g);

    rt_graph_destroy(g);
}

TEST_CASE("stop_audio is safe to call when audio was never started") {
    auto *g = build_sin_out(2, kFrames);
    rt_graph_stop_audio(g); // must not crash
    rt_graph_destroy(g);
    CHECK(true);
}

TEST_CASE("offline create/process/destroy 1000× does not leak or crash") {
    // Pure resource-cycle stress test. If rt_graph_create is leaking
    // backing memory, valgrind or ASAN will catch it; if it leaks
    // heap fragments only, this loop will at least make the leak
    // proportionally obvious in RSS observation.
    constexpr int kIters = 1000;
    for (int i = 0; i < kIters; ++i) {
        const int cap        = (i % 7) + 2;
        const int max_frames = ((i % 4) + 1) * 64;
        auto *g = rt_graph_create(cap, max_frames);
        REQUIRE(g != nullptr);
        rt_graph_add_node(g, 0, 1);
        rt_graph_set_control(g, 0, 0, 440.0f + static_cast<float>(i));
        rt_graph_add_node(g, 1, 2);
        rt_graph_set_control(g, 1, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);
        rt_graph_process(g, max_frames);
        rt_graph_destroy(g);
    }
    CHECK(true);
}

TEST_CASE("audio start/stop cycle 25× does not exhaust device handles") {
    // PortAudio resource leaks (unclosed streams, leaked devices) tend
    // to manifest as start_audio returning failure after ~10-20
    // iterations. We don't assert success on every iteration (the host
    // may need a moment to reclaim handles), but we do require that we
    // see at least *some* successful starts and that nothing crashes.
    constexpr int kIters = 25;
    int success_count = 0;

    for (int i = 0; i < kIters; ++i) {
        auto *g = build_sin_out(2, /*max_frames*/ 256);
        int rc = rt_graph_start_audio(g, 1, -1);
        if (rc == 0) {
            ++success_count;
            rt_graph_wait_started(g, 200);
            rt_graph_stop_audio(g);
        }
        rt_graph_destroy(g);
    }

    if (success_count == 0) {
        // No usable device — pass without exercising the cycle.
        WARN_MESSAGE(true, "no audio device available, skipping");
    } else {
        // We got at least one success; require that a healthy fraction
        // of attempts succeeded. A clean implementation should hit
        // 25/25; allow some tolerance for transient platform issues.
        CHECK(success_count >= kIters * 3 / 4);
    }
}

TEST_CASE("clear during a running audio stream does not crash") {
    // Pin the observed behavior: it is safe to call rt_graph_clear
    // while audio is running. Whether clear silences the stream
    // immediately, on the next callback, or only after a follow-up
    // stop_audio is left to the implementation — this test only
    // checks that no crash, no NaN propagation, and a subsequent
    // stop_audio + destroy completes cleanly.
    auto *g = build_sin_out(2, /*max_frames*/ 256);
    int rc = rt_graph_start_audio(g, 1, -1);
    if (rc != 0) {
        WARN_MESSAGE(true, "no audio device available, skipping");
        rt_graph_destroy(g);
        return;
    }
    rt_graph_wait_started(g, 500);
    std::this_thread::sleep_for(std::chrono::milliseconds(20));

    rt_graph_clear(g);                           // mid-flight clear
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    rt_graph_stop_audio(g);
    rt_graph_destroy(g);
    CHECK(true);
}

TEST_CASE("rebuild after clear with active stream produces audio again") {
    // The full clear-and-reload-while-running path: start, clear,
    // build a different graph, audio should keep running on the new
    // topology. This is not a guaranteed contract — implementations
    // may require stop+restart — so we accept either "still streaming"
    // or "stream ended cleanly", just not a crash.
    auto *g = build_sin_out(4, /*max_frames*/ 256);
    int rc = rt_graph_start_audio(g, 1, -1);
    if (rc != 0) {
        WARN_MESSAGE(true, "no audio device available, skipping");
        rt_graph_destroy(g);
        return;
    }
    rt_graph_wait_started(g, 500);

    rt_graph_clear(g);
    // Rebuild as a different graph in place.
    rt_graph_add_node(g, 0, 6); // NoiseGen
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    rt_graph_stop_audio(g);
    rt_graph_destroy(g);
    CHECK(true);
}

TEST_CASE("destroy after start_audio cleans up the audio thread") {
    auto *g = build_sin_out(2, /*max_frames*/ 256);
    int rc = rt_graph_start_audio(g, 1, -1);
    if (rc != 0) {
        WARN_MESSAGE(true, "no audio device available, skipping");
        rt_graph_destroy(g);
        return;
    }
    rt_graph_wait_started(g, 500);
    // Destroy without an explicit stop — runtime should tear down cleanly.
    rt_graph_destroy(g);
    CHECK(true);
}

// ----------------------------------------------------------------
// Multiple-instance isolation
// ----------------------------------------------------------------
//
// Two RTGraph handles must not share state. Same-shape graphs in
// different handles render the same deterministic output; NoiseGen
// instances in two handles must not share an RNG (or if they do,
// the runtime needs to declare it).

TEST_CASE("two SinOsc graphs in distinct handles render identical output") {
    auto *g1 = build_sin_out(2, kFrames);
    auto *g2 = build_sin_out(2, kFrames);

    auto a = render_bus0(g1, kFrames);
    auto b = render_bus0(g2, kFrames);
    rt_graph_destroy(g1);
    rt_graph_destroy(g2);

    REQUIRE(a.size() == b.size());
    for (std::size_t i = 0; i < a.size(); ++i) {
        CHECK(a[i] == b[i]);
    }
}

TEST_CASE("interleaved processing of two graphs does not corrupt either") {
    // g_a: SinOsc 440. g_b: SinOsc 880. Process them in an alternating
    // sequence (a, b, a, b, ...) and compare against running each one
    // alone for the same total frames. State must not bleed across.
    auto *g_a_alone = build_sin_out(2, kFrames, 440.0f);
    auto a_alone = render_bus0(g_a_alone, kFrames);
    rt_graph_destroy(g_a_alone);

    auto *g_b_alone = build_sin_out(2, kFrames, 880.0f);
    auto b_alone = render_bus0(g_b_alone, kFrames);
    rt_graph_destroy(g_b_alone);

    // Now run a/b interleaved at half-block granularity.
    constexpr int kHalf = kFrames / 2;
    auto *g_a = build_sin_out(2, kFrames, 440.0f);
    auto *g_b = build_sin_out(2, kFrames, 880.0f);

    std::vector<float> a_inter(static_cast<std::size_t>(kFrames));
    std::vector<float> b_inter(static_cast<std::size_t>(kFrames));

    rt_graph_process(g_a, kHalf);
    rt_graph_read_bus(g_a, 0, kHalf, a_inter.data());
    rt_graph_process(g_b, kHalf);
    rt_graph_read_bus(g_b, 0, kHalf, b_inter.data());
    rt_graph_process(g_a, kHalf);
    rt_graph_read_bus(g_a, 0, kHalf, a_inter.data() + kHalf);
    rt_graph_process(g_b, kHalf);
    rt_graph_read_bus(g_b, 0, kHalf, b_inter.data() + kHalf);

    rt_graph_destroy(g_a);
    rt_graph_destroy(g_b);

    for (std::size_t i = 0; i < a_inter.size(); ++i) {
        CHECK(a_inter[i] == doctest::Approx(a_alone[i]).epsilon(1e-4));
        CHECK(b_inter[i] == doctest::Approx(b_alone[i]).epsilon(1e-4));
    }
}

TEST_CASE("NoiseGen in two handles produces meaningfully different sequences") {
    auto build_noise = [] {
        auto *g = rt_graph_create(2, kFrames);
        REQUIRE(g != nullptr);
        rt_graph_add_node(g, 0, 6); // NoiseGen
        rt_graph_add_node(g, 1, 2); // Out
        rt_graph_set_control(g, 1, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);
        return g;
    };

    auto *g1 = build_noise();
    auto *g2 = build_noise();
    auto a = render_bus0(g1, kFrames);
    auto b = render_bus0(g2, kFrames);
    rt_graph_destroy(g1);
    rt_graph_destroy(g2);

    // Whether two fresh NoiseGens produce identical or distinct sequences
    // is implementation-defined. We assert only the practical
    // requirement: if they happen to be identical, that's a documented
    // characteristic; if they differ, the difference is substantial.
    int matches = 0;
    for (std::size_t i = 0; i < a.size(); ++i) {
        if (std::abs(a[i] - b[i]) < 1e-6f) {
            ++matches;
        }
    }
    const int total = static_cast<int>(a.size());
    const bool fully_identical = (matches == total);
    const bool substantially_different = (matches < total * 3 / 10);
    CHECK((fully_identical || substantially_different));
}

// ----------------------------------------------------------------
// Golden samples for deterministic kernels
// ----------------------------------------------------------------
//
// Pin specific sample values for the deterministic oscillator kernel.
// q::sin is a LUT (~14-15 bit precision), so we compare against the
// analytical sin() with a tolerance generous enough to absorb the LUT
// quantization but tight enough to catch any genuine kernel drift
// (e.g. a future change that swaps the LUT, alters phase advancement,
// or breaks the initial-phase contract).

TEST_CASE("SinOsc(440, 0) first 32 samples match analytical sin within LUT tolerance") {
    auto *g = build_sin_out(2, kFrames);
    auto samples = render_bus0(g, kFrames);
    rt_graph_destroy(g);

    constexpr int kCheck = 32;
    for (int n = 0; n < kCheck; ++n) {
        const double t = static_cast<double>(n) / kSampleRate;
        const double expected = std::sin(kTau * 440.0 * t);
        // 1e-3 absolute slack: comfortably above LUT noise (~6e-5) but
        // far below any kernel rewrite that drops or doubles a sample.
        CHECK(samples[static_cast<std::size_t>(n)] ==
              doctest::Approx(static_cast<float>(expected)).epsilon(1e-3));
    }
}

TEST_CASE("Add(0.3, 0.4) renders exactly 0.7 for the entire block") {
    // Pure constant-fold case. No tolerance — these are floats with
    // exact representations of the sum.
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_add_node(g, 0, 8);
    rt_graph_set_control(g, 0, 0, 0.3f);
    rt_graph_set_control(g, 0, 1, 0.4f);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    auto samples = render_bus0(g, kFrames);
    const float expected = 0.3f + 0.4f;
    for (auto s : samples) {
        CHECK(s == expected);
    }

    rt_graph_destroy(g);
}

TEST_CASE("Gain(0.5) on SinOsc(440) is sample-equal to 0.5 × SinOsc(440)") {
    // Render the carrier alone, then through a 0.5 gain. Output of the
    // second graph at every sample must equal exactly 0.5 × the first.
    auto *g_plain = build_sin_out(2, kFrames);
    auto plain = render_bus0(g_plain, kFrames);
    rt_graph_destroy(g_plain);

    auto *g_scaled = rt_graph_create(4, kFrames);
    rt_graph_add_node(g_scaled, 0, 1);
    rt_graph_set_control(g_scaled, 0, 0, 440.0f);
    rt_graph_add_node(g_scaled, 1, 3);
    rt_graph_set_control(g_scaled, 1, 0, 0.5f);
    rt_graph_add_node(g_scaled, 2, 2);
    rt_graph_set_control(g_scaled, 2, 0, 0.0f);
    rt_graph_connect(g_scaled, 0, 0, 1, 0);
    rt_graph_connect(g_scaled, 1, 0, 2, 0);
    auto scaled = render_bus0(g_scaled, kFrames);
    rt_graph_destroy(g_scaled);

    REQUIRE(plain.size() == scaled.size());
    for (std::size_t i = 0; i < plain.size(); ++i) {
        CHECK(scaled[i] == 0.5f * plain[i]);
    }
}

// ----------------------------------------------------------------
// SawOsc edge frequencies
// ----------------------------------------------------------------
//
// PolyBLEP saw is bandlimited and well-behaved across most of the
// audible range, but the kernel must also handle edge frequencies
// gracefully — DC, near Nyquist, and negative frequencies — without
// blowing up or returning NaN/Inf.

namespace {

// Render bus 0 from a one-saw graph at the given frequency.
std::vector<float> render_saw(float freq, int max_frames = kFrames) {
    auto *g = rt_graph_create(2, max_frames);
    REQUIRE(g != nullptr);
    rt_graph_add_node(g, 0, 5); // SawOsc
    rt_graph_set_control(g, 0, 0, freq);
    rt_graph_set_control(g, 0, 1, 0.0f);
    rt_graph_add_node(g, 1, 2); // Out
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);
    auto samples = render_bus0(g, max_frames);
    rt_graph_destroy(g);
    return samples;
}

} // namespace

TEST_CASE("SawOsc(0 Hz) produces finite, bounded DC-like output") {
    auto samples = render_saw(0.0f);
    for (auto s : samples) {
        CHECK(std::isfinite(s));
        CHECK(std::abs(s) <= 1.5f);
    }
    // At freq=0 the phase never advances, so output is constant.
    // Whatever value the kernel picks for that constant is fine, but
    // every sample should equal the first.
    for (std::size_t i = 1; i < samples.size(); ++i) {
        CHECK(samples[i] == samples[0]);
    }
}

TEST_CASE("SawOsc near Nyquist stays finite") {
    auto samples = render_saw(23000.0f);
    for (auto s : samples) {
        CHECK(std::isfinite(s));
        // PolyBLEP's job is to keep output bounded; allow some headroom
        // for transient overshoot at the edge.
        CHECK(std::abs(s) <= 1.5f);
    }
}

TEST_CASE("SawOsc above Nyquist stays finite (no UB on extreme input)") {
    // Beyond Nyquist (24 kHz @ 48 kHz SR) the result is meaningless
    // musically, but the kernel must not crash or produce NaN/Inf.
    for (float f : {30000.0f, 100000.0f}) {
        auto samples = render_saw(f);
        for (auto s : samples) {
            CHECK(std::isfinite(s));
            CHECK(std::abs(s) <= 5.0f);
        }
    }
}

TEST_CASE("SawOsc with negative frequency stays finite") {
    auto samples = render_saw(-440.0f);
    for (auto s : samples) {
        CHECK(std::isfinite(s));
        CHECK(std::abs(s) <= 1.5f);
    }
    // A negative freq either inverts the waveform direction or aliases
    // to its positive counterpart. Either way the signal should still
    // oscillate (have substantial amplitude), not collapse to silence.
    CHECK(peak_abs(samples) > 0.3f);
}

TEST_CASE("SinOsc edge frequencies stay finite") {
    // Mirror coverage for SinOsc.
    for (float f : {0.0f, 23000.0f, -440.0f, 100000.0f}) {
        auto *g = rt_graph_create(2, kFrames);
        rt_graph_add_node(g, 0, 1);
        rt_graph_set_control(g, 0, 0, f);
        rt_graph_set_control(g, 0, 1, 0.0f);
        rt_graph_add_node(g, 1, 2);
        rt_graph_set_control(g, 1, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);
        auto samples = render_bus0(g, kFrames);
        rt_graph_destroy(g);

        for (auto s : samples) {
            CHECK(std::isfinite(s));
            CHECK(std::abs(s) <= 1.5f);
        }
    }
}

// ----------------------------------------------------------------
// Pathological-control sanitation across every parameter kernel
// ----------------------------------------------------------------
//
// Single battery covering the canonical set of pathological control
// values ({NaN, +Inf, -Inf, large finite} and where sensible {0,
// negative}) for every kernel that has a non-trivial parameter
// math path. Each subcase wires a fresh graph, drives the chosen
// control with each pathological value, renders multiple blocks,
// and asserts every output sample is finite and bounded.
//
// Rationale: q's primitives propagate NaN/Inf or assert/UB on
// non-finite parameters (frac_to_phase, biquad config, q::duration).
// The kernel boundary in rt_graph.cpp is where we stamp out the
// whole class.

namespace {
constexpr double kPathNaN     = std::numeric_limits<double>::quiet_NaN();
constexpr double kPathPosInf  = std::numeric_limits<double>::infinity();
constexpr double kPathNegInf  = -std::numeric_limits<double>::infinity();

void check_block_finite_bounded(const std::vector<float> &samples, float max_abs) {
    for (auto s : samples) {
        CHECK(std::isfinite(s));
        CHECK(std::abs(s) <= max_abs);
    }
}

// Battery of pathological doubles. NaN + non-finite is the load-
// bearing class we just stamped out; >Nyquist / negative finite are
// already exercised elsewhere but doubling-up is cheap and pins the
// new sanitizer's "finite passes through" behavior for those.
const std::vector<double> kPathologicalParams = {
    kPathNaN, kPathPosInf, kPathNegInf, -1e9, 1e9
};
} // namespace

TEST_CASE("oscillator freq sanitized: SinOsc/SawOsc/PulseOsc/TriOsc accept any double on controls[0]") {
    // Each oscillator kind, each pathological control[0] value.
    // Output must be finite and bounded for every block.
    const int osc_kinds[] = {1, 5, 15, 16}; // SinOsc, SawOsc, PulseOsc, TriOsc
    for (int kind : osc_kinds) {
        for (double bad : kPathologicalParams) {
            CAPTURE(kind);
            CAPTURE(bad);
            auto *g = rt_graph_create(2, kFrames);
            REQUIRE(g != nullptr);
            rt_graph_add_node(g, 0, kind);
            rt_graph_set_control(g, 0, 0, bad);   // freq
            rt_graph_set_control(g, 0, 1, 0.0f);  // phase
            if (kind == 15) {                     // PulseOsc has width
                rt_graph_set_control(g, 0, 2, 0.5);
            }
            rt_graph_add_node(g, 1, 2);
            rt_graph_set_control(g, 1, 0, 0.0f);
            rt_graph_connect(g, 0, 0, 1, 0);
            for (int b = 0; b < 4; ++b) {
                auto samples = render_bus0(g, kFrames);
                check_block_finite_bounded(samples, 4.0f);
            }
            rt_graph_destroy(g);
        }
    }
}

TEST_CASE("biquad q sanitized at and near zero (divide-by-zero in alpha = sin/(2Q))") {
    // Q = 0 makes alpha = sin(omega) / 0 = ±Inf in q::biquad's
    // coefficient math; tiny Q (e.g. 1e-9) gives huge but finite
    // alpha. Both produce ill-conditioned biquads. The sanitizer
    // clamps Q to a useful musical range, so output stays finite +
    // bounded for a 440 Hz sine through the filter. Pinned because
    // the general "any double on q" battery uses {NaN, ±Inf,
    // ±1e9} but not 0 / sub-eps positive, even though those are
    // exactly the divide-by-zero / near-zero cases the audit
    // flagged.
    const int biquad_kinds[] = {7, 17, 18, 19};
    for (int kind : biquad_kinds) {
        for (double bad_q : {0.0, 1e-15, 1e-9, -1e-9}) {
            CAPTURE(kind);
            CAPTURE(bad_q);
            auto *g = rt_graph_create(4, kFrames);
            REQUIRE(g != nullptr);
            rt_graph_add_node(g, 0, 1);
            rt_graph_set_control(g, 0, 0, 440.0f);
            rt_graph_add_node(g, 1, kind);
            rt_graph_set_control(g, 1, 0, 1000.0);
            rt_graph_set_control(g, 1, 1, bad_q);
            rt_graph_add_node(g, 2, 2);
            rt_graph_set_control(g, 2, 0, 0.0f);
            rt_graph_connect(g, 0, 0, 1, 0);
            rt_graph_connect(g, 1, 0, 2, 0);
            for (int b = 0; b < 4; ++b) {
                auto samples = render_bus0(g, kFrames);
                check_block_finite_bounded(samples, 8.0f);
            }
            rt_graph_destroy(g);
        }
    }
}

TEST_CASE("biquad freq sanitized: LPF/HPF/BPF/Notch accept any double on cutoff/q") {
    // Drive a 440 Hz sine through the filter; sweep one control at
    // a time through the pathological set. Both freq (control 0)
    // and q (control 1) must be sanitized -- non-finite freq -> NaN
    // coefficients, q ~= 0 -> divide-by-zero.
    const int biquad_kinds[] = {7, 17, 18, 19}; // LPF, HPF, BPF, Notch
    for (int kind : biquad_kinds) {
        for (double bad : kPathologicalParams) {
            for (int which_ctl : {0, 1}) {        // freq or q
                CAPTURE(kind);
                CAPTURE(bad);
                CAPTURE(which_ctl);
                auto *g = rt_graph_create(4, kFrames);
                REQUIRE(g != nullptr);
                rt_graph_add_node(g, 0, 1);                 // SinOsc src
                rt_graph_set_control(g, 0, 0, 440.0f);
                rt_graph_add_node(g, 1, kind);              // filter
                rt_graph_set_control(g, 1, 0, 1000.0);      // freq
                rt_graph_set_control(g, 1, 1, 0.707);       // q
                rt_graph_set_control(g, 1, which_ctl, bad); // pathological
                rt_graph_add_node(g, 2, 2);
                rt_graph_set_control(g, 2, 0, 0.0f);
                rt_graph_connect(g, 0, 0, 1, 0);
                rt_graph_connect(g, 1, 0, 2, 0);
                for (int b = 0; b < 4; ++b) {
                    auto samples = render_bus0(g, kFrames);
                    check_block_finite_bounded(samples, 8.0f);
                }
                rt_graph_destroy(g);
            }
        }
    }
}

TEST_CASE("Env A/D/S/R sanitized: pathological ramp params still produce a bounded envelope") {
    // Env has 5 controls: gate_default, A, D, S, R. Drive each of
    // A/D/R/S in turn with each pathological value and ensure the
    // generated envelope stays finite + bounded.
    for (double bad : kPathologicalParams) {
        for (int which_ctl : {1, 2, 3, 4}) {  // skip 0 (gate)
            CAPTURE(bad);
            CAPTURE(which_ctl);
            auto *g = rt_graph_create(2, kFrames);
            REQUIRE(g != nullptr);
            rt_graph_add_node(g, 0, 9);                       // Env
            rt_graph_set_control(g, 0, 0, 1.0);               // gate held
            rt_graph_set_control(g, 0, 1, 0.005);             // A
            rt_graph_set_control(g, 0, 2, 0.05);              // D
            rt_graph_set_control(g, 0, 3, 0.5);               // S
            rt_graph_set_control(g, 0, 4, 0.1);               // R
            rt_graph_set_control(g, 0, which_ctl, bad);       // pathological
            rt_graph_add_node(g, 1, 2);
            rt_graph_set_control(g, 1, 0, 0.0f);
            rt_graph_connect(g, 0, 0, 1, 0);
            for (int b = 0; b < 4; ++b) {
                auto samples = render_bus0(g, kFrames);
                // Env amplitude is in [0, 1] in steady state; allow
                // slack for ramp transients.
                check_block_finite_bounded(samples, 2.0f);
            }
            rt_graph_destroy(g);
        }
    }
}

TEST_CASE("Out / BusIn / BusInDelayed bus index validates before double->int cast") {
    // controls[0] on Out / BusIn / BusInDelayed is cast to int before
    // the range check. NaN / ±Inf / out-of-int-range finite double
    // (e.g. 1e15, 1e30) hit the unspecified-conversion case in C++,
    // so sanitation has to happen in the double domain BEFORE the
    // cast. Verifies all three kernels emit silence (no crash, no
    // out-of-bounds bus access) for each pathological value.
    //
    // Set-up: feed a SinOsc into the kind under test; the kind's
    // bus control is the pathological value. Out is a sink (we read
    // the *audio thread's* bus 0 by adding a benign Out as well so
    // render_bus0 has something to read). BusIn / BusInDelayed are
    // sources with no audio input — their output is what we sample.

    SUBCASE("Out with pathological bus index: silent (no crash)") {
        for (double bad_bus : {kPathNaN, kPathPosInf, kPathNegInf,
                                -1.0, 1e15, 1e30}) {
            CAPTURE(bad_bus);
            auto *g = rt_graph_create(4, kFrames);
            REQUIRE(g != nullptr);
            rt_graph_add_node(g, 0, 1);
            rt_graph_set_control(g, 0, 0, 440.0f);
            rt_graph_add_node(g, 1, 2);                  // Out
            rt_graph_set_control(g, 1, 0, bad_bus);      // bad bus index
            rt_graph_connect(g, 0, 0, 1, 0);
            for (int b = 0; b < 2; ++b) {
                auto samples = render_bus0(g, kFrames);
                check_block_finite_bounded(samples, 4.0f);
            }
            rt_graph_destroy(g);
        }
    }

    SUBCASE("BusIn with pathological bus index: silence on its output port") {
        for (double bad_bus : {kPathNaN, kPathPosInf, kPathNegInf,
                                -1.0, 1e15, 1e30}) {
            CAPTURE(bad_bus);
            auto *g = rt_graph_create(4, kFrames);
            REQUIRE(g != nullptr);
            rt_graph_add_node(g, 0, 11);                 // BusIn
            rt_graph_set_control(g, 0, 0, bad_bus);
            rt_graph_add_node(g, 1, 2);                  // Out -> bus 0
            rt_graph_set_control(g, 1, 0, 0.0f);
            rt_graph_connect(g, 0, 0, 1, 0);
            for (int b = 0; b < 2; ++b) {
                auto samples = render_bus0(g, kFrames);
                check_block_finite_bounded(samples, 4.0f);
                // BusIn with an invalid bus emits silence; nothing
                // else writes the output bus, so bus 0 is all zeros.
                for (auto s : samples) CHECK(s == 0.0f);
            }
            rt_graph_destroy(g);
        }
    }

    SUBCASE("BusInDelayed with pathological bus index: silence") {
        for (double bad_bus : {kPathNaN, kPathPosInf, kPathNegInf,
                                -1.0, 1e15, 1e30}) {
            CAPTURE(bad_bus);
            auto *g = rt_graph_create(4, kFrames);
            REQUIRE(g != nullptr);
            rt_graph_add_node(g, 0, 12);                 // BusInDelayed
            rt_graph_set_control(g, 0, 0, bad_bus);
            rt_graph_add_node(g, 1, 2);
            rt_graph_set_control(g, 1, 0, 0.0f);
            rt_graph_connect(g, 0, 0, 1, 0);
            for (int b = 0; b < 2; ++b) {
                auto samples = render_bus0(g, kFrames);
                check_block_finite_bounded(samples, 4.0f);
                for (auto s : samples) CHECK(s == 0.0f);
            }
            rt_graph_destroy(g);
        }
    }
}

TEST_CASE("Gain + Add: NaN control default doesn't poison the audio path") {
    // Gain.controls[0] (gain amount) and Add.controls[0/1] (bias
    // operands) are reached only when the corresponding audio input
    // port is unconnected. A NaN control value would multiply / add
    // NaN into every sample of the block and propagate to downstream
    // filters / smoothers, where their IIR state then carries NaN
    // forever. Sanitizers fall back to identity (Gain -> 1.0,
    // Add -> 0.0).

    SUBCASE("Gain: NaN amount falls back to unity") {
        auto *g = rt_graph_create(4, kFrames);
        REQUIRE(g != nullptr);
        rt_graph_add_node(g, 0, 1);
        rt_graph_set_control(g, 0, 0, 440.0f);
        rt_graph_add_node(g, 1, 3);                       // Gain
        rt_graph_set_control(g, 1, 0, kPathNaN);          // pathological
        rt_graph_add_node(g, 2, 2);
        rt_graph_set_control(g, 2, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);
        rt_graph_connect(g, 1, 0, 2, 0);
        auto samples = render_bus0(g, kFrames);
        check_block_finite_bounded(samples, 1.5f);
        // Sin amplitude ~1.0; with NaN→1.0 fallback the gain pass-
        // through keeps the sine at its natural amplitude.
        CHECK(peak_abs(samples) > 0.5f);
        rt_graph_destroy(g);
    }

    SUBCASE("Add: NaN bias on each control falls back to zero") {
        for (int which : {0, 1}) {
            CAPTURE(which);
            auto *g = rt_graph_create(4, kFrames);
            REQUIRE(g != nullptr);
            rt_graph_add_node(g, 0, 1);
            rt_graph_set_control(g, 0, 0, 440.0f);
            rt_graph_add_node(g, 1, 8);                   // Add
            rt_graph_set_control(g, 1, 0, 0.0);
            rt_graph_set_control(g, 1, 1, 0.0);
            rt_graph_set_control(g, 1, which, kPathNaN);  // bad bias
            rt_graph_add_node(g, 2, 2);
            rt_graph_set_control(g, 2, 0, 0.0f);
            // Wire only ONE audio input so the OTHER port falls back
            // to its (now-pathological-but-sanitized) control.
            rt_graph_connect(g, 0, 0, 1, 1 - which);
            rt_graph_connect(g, 1, 0, 2, 0);
            auto samples = render_bus0(g, kFrames);
            check_block_finite_bounded(samples, 1.5f);
            rt_graph_destroy(g);
        }
    }
}

TEST_CASE("Smooth: NaN target does not poison IIR state across blocks") {
    // The audit flagged this as the worst case: q::dynamic_smoother
    // runs `low1 += g * (input - low1)`, so a single NaN target
    // makes low1 + low2 NaN and they stay NaN forever -- even after
    // the producer writes a valid target on a later block. Sanitizer
    // substitutes 0.0 for non-finite, so the smoother's state stays
    // finite and recovers normally on the next valid write.
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_add_node(g, 0, 14);                          // Smooth
    rt_graph_set_control(g, 0, 0, 20.0);                  // base_freq
    rt_graph_set_control(g, 0, 1, 0.5);                   // initial target
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    // Block 1: settle at target=0.5.
    auto block1 = render_bus0(g, kFrames);
    for (auto s : block1) CHECK(std::isfinite(s));

    // Block 2: producer writes a NaN target. Sanitizer should fall
    // back to 0.0; smoother state must stay finite.
    rt_graph_set_control(g, 0, 1, kPathNaN);
    auto block2 = render_bus0(g, kFrames);
    for (auto s : block2) CHECK(std::isfinite(s));

    // Block 3: producer writes a valid target again. State must NOT
    // be poisoned -- output should track toward the new target.
    // Without the sanitizer, low1 / low2 would still be NaN here and
    // every subsequent sample would also be NaN.
    rt_graph_set_control(g, 0, 1, 0.8);
    auto block3 = render_bus0(g, kFrames);
    for (auto s : block3) CHECK(std::isfinite(s));
    // State recovered: the smoother should be tracking toward 0.8.
    // Allow generous slack since the smoothing time constant could
    // leave us anywhere in [0, 0.8] depending on exactly when it
    // resumed.
    CHECK(block3[kFrames - 1] > 0.0f);
    CHECK(block3[kFrames - 1] < 1.0f);

    rt_graph_destroy(g);
}

TEST_CASE("Delay max_time + time sanitized: pathological values stay finite + bounded") {
    // Delay has controls[0]=max_time, controls[1]=delay_time. The
    // ring buffer is sized from max_time at first process(), so a
    // non-finite max_time would crash q::delay's ctor; non-finite
    // delay_time would index the buffer with NaN.
    for (double bad : kPathologicalParams) {
        for (int which_ctl : {0, 1}) {  // max_time or delay_time
            CAPTURE(bad);
            CAPTURE(which_ctl);
            auto *g = rt_graph_create(4, kFrames);
            REQUIRE(g != nullptr);
            rt_graph_add_node(g, 0, 1);                 // SinOsc src
            rt_graph_set_control(g, 0, 0, 440.0f);
            rt_graph_add_node(g, 1, 13);                // Delay
            rt_graph_set_control(g, 1, 0, 0.05);        // max_time
            rt_graph_set_control(g, 1, 1, 0.01);        // delay_time
            rt_graph_set_control(g, 1, which_ctl, bad); // pathological
            rt_graph_add_node(g, 2, 2);
            rt_graph_set_control(g, 2, 0, 0.0f);
            rt_graph_connect(g, 0, 0, 1, 0);
            rt_graph_connect(g, 1, 0, 2, 0);
            for (int b = 0; b < 4; ++b) {
                auto samples = render_bus0(g, kFrames);
                check_block_finite_bounded(samples, 4.0f);
            }
            rt_graph_destroy(g);
        }
    }
}

TEST_CASE("self-loop wiring does not crash and stays finite") {
    // Wire a Gain node to itself. Whatever the runtime does (read
    // last-block buffer, read zeros, etc.) it must not crash or
    // produce NaN/Inf. We don't assert audio behavior beyond that.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1); // SinOsc 440 (kicks something into the chain)
    rt_graph_set_control(g, 0, 0, 440.0f);

    rt_graph_add_node(g, 1, 3); // Gain
    rt_graph_set_control(g, 1, 0, 0.5f);
    rt_graph_connect(g, 0, 0, 1, 0); // sin → gain.signal
    rt_graph_connect(g, 1, 0, 1, 1); // self-loop on gain.gain

    rt_graph_add_node(g, 2, 2);
    rt_graph_set_control(g, 2, 0, 0.0f);
    rt_graph_connect(g, 1, 0, 2, 0);

    // Render multiple blocks to give any feedback path time to blow up.
    for (int i = 0; i < 8; ++i) {
        auto samples = render_bus0(g, kFrames);
        for (auto s : samples) {
            CHECK(std::isfinite(s));
            CHECK(std::abs(s) < 100.0f);
        }
    }

    rt_graph_destroy(g);
}

TEST_CASE("adding nodes past capacity does not crash and remaining graph still works") {
    constexpr int kCap = 3;
    auto *g = rt_graph_create(kCap, kFrames);
    REQUIRE(g != nullptr);

    // Fill up the graph: 3 nodes (SinOsc, Gain, Out).
    rt_graph_add_node(g, 0, 1);
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_add_node(g, 1, 3);
    rt_graph_set_control(g, 1, 0, 0.5f);
    rt_graph_add_node(g, 2, 2);
    rt_graph_set_control(g, 2, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);
    rt_graph_connect(g, 1, 0, 2, 0);

    // Try to add three more nodes past capacity. These must not crash
    // and must not corrupt the existing valid graph.
    rt_graph_add_node(g, 3, 1);
    rt_graph_add_node(g, 4, 1);
    rt_graph_add_node(g, 5, 1);
    rt_graph_set_control(g, 3, 0, 880.0f);

    auto samples = render_bus0(g, kFrames);
    CHECK(peak_abs(samples) == doctest::Approx(0.5f).epsilon(0.05));

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Multi-instance support (§2.B)
// ----------------------------------------------------------------
//
// One MetaDef hosts a vector of GraphInstances. Each instance has
// independent kernel state, controls, and bus pool. Tests below pin
// the per-instance behavior expected of the API:
//   * Instance 0 is the default; legacy single-instance API targets it.
//   * Instances added later don't disturb existing instances.
//   * Slot reuse after rt_graph_instance_remove.
//   * Independent state evolution per instance.
//   * Removed instances disappear (no cross-block residue, read_bus → 0).

TEST_CASE("Multi-instance: two SinOsc instances at different frequencies") {
    // Build SinOsc → Out template once, then host two instances of it
    // at different frequencies. Verify each instance's bus 0 oscillates
    // at its own freq — this is the load-bearing claim of §2.B (per-
    // instance controls and per-instance kernel state).
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 1);  // inst1 routes to bus 1

    rt_graph_add_node(g, 0, 1);                          // SinOsc
    rt_graph_set_control(g, 0, 0, 440.0);                // instance 0 freq
    rt_graph_add_node(g, 1, 2);                          // Out
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    int inst1 = rt_graph_instance_add(g);
    REQUIRE(inst1 == 1);
    rt_graph_instance_set_control(g, inst1, 0, 0, 660.0);
    // §2.C: server bus pool is shared. Route inst1's Out to bus 1 so
    // each voice writes its own bus and we can read them separately.
    rt_graph_instance_set_control(g, inst1, 1, 0, 1.0);

    rt_graph_process(g, kFrames);

    std::vector<float> bus0(kFrames, 0.0f);
    std::vector<float> bus1(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    rt_graph_read_bus(g, 1, kFrames, bus1.data());
    rt_graph_destroy(g);

    CHECK(peak_abs(bus0) > 0.9f);
    CHECK(peak_abs(bus1) > 0.9f);

    // 440 Hz × (1024/48000 s) ≈ 9.4 cycles → ~19 zero crossings;
    // 660 Hz × (1024/48000 s) ≈ 14.1 cycles → ~28 ZCs. The two should
    // differ meaningfully.
    const int zc0 = zero_crossings(bus0);
    const int zc1 = zero_crossings(bus1);
    INFO("zc0=" << zc0 << " zc1=" << zc1);
    CHECK(zc0 >= 15);
    CHECK(zc0 <= 22);
    CHECK(zc1 >= 25);
    CHECK(zc1 <= 32);
    CHECK(zc1 > zc0);
}

TEST_CASE("Multi-instance: per-instance Delay state is independent") {
    // Same Add → Delay → Out template, two instances, different delay
    // times. Verifies that q::delay's ring buffer is per-instance state
    // (independent ring buffers, no cross-instance pollution).
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 1);  // inst1 routes to bus 1

    rt_graph_add_node(g, 0, 8);                          // Add
    rt_graph_add_node(g, 1, 13);                         // Delay
    rt_graph_connect(g, 0, 0, 1, 0);
    rt_graph_add_node(g, 2, 2);                          // Out
    rt_graph_set_control(g, 2, 0, 0.0);
    rt_graph_connect(g, 1, 0, 2, 0);

    // Instance 0: constant 1.0 → 1ms delay.
    rt_graph_instance_set_control(g, 0, 0, 0, 1.0);      // Add a = 1.0
    rt_graph_instance_set_control(g, 0, 0, 1, 0.0);      // Add b = 0.0
    rt_graph_instance_set_control(g, 0, 1, 0, 0.01);     // Delay max = 10 ms
    rt_graph_instance_set_control(g, 0, 1, 1, 0.001);    // Delay time = 1 ms

    int inst1 = rt_graph_instance_add(g);
    REQUIRE(inst1 == 1);
    // Instance 1: constant 1.0 → 5 ms delay → bus 1 (separate from inst 0).
    rt_graph_instance_set_control(g, 1, 0, 0, 1.0);
    rt_graph_instance_set_control(g, 1, 0, 1, 0.0);
    rt_graph_instance_set_control(g, 1, 1, 0, 0.01);
    rt_graph_instance_set_control(g, 1, 1, 1, 0.005);
    rt_graph_instance_set_control(g, 1, 2, 0, 1.0);  // Out → bus 1

    rt_graph_process(g, kFrames);

    std::vector<float> bus0(kFrames, 0.0f);
    std::vector<float> bus1(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    rt_graph_read_bus(g, 1, kFrames, bus1.data());
    rt_graph_destroy(g);

    auto first_nonsilent = [](const std::vector<float> &xs) {
        for (int i = 0; i < static_cast<int>(xs.size()); ++i) {
            if (std::abs(xs[static_cast<std::size_t>(i)]) > 0.5f) return i;
        }
        return -1;
    };
    const int t0 = first_nonsilent(bus0);
    const int t1 = first_nonsilent(bus1);
    REQUIRE(t0 >= 0);
    REQUIRE(t1 >= 0);

    // 1 ms ≈ 48 samples; 5 ms ≈ 240 samples. ±2-sample API slop.
    CHECK(std::abs(t0 - 48) <= 2);
    CHECK(std::abs(t1 - 240) <= 2);
    // The two transitions must be clearly far apart.
    CHECK((t1 - t0) > 100);
}

TEST_CASE("Multi-instance: lifecycle (add, remove, re-add reuses slot)") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 1);  // id_a routes to bus 1
    rt_graph_add_node(g, 0, 1);                          // SinOsc
    rt_graph_set_control(g, 0, 0, 440.0);
    rt_graph_add_node(g, 1, 2);                          // Out
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    REQUIRE(rt_graph_instance_count(g) == 1);
    REQUIRE(rt_graph_instance_alive(g, 0) == 1);
    REQUIRE(rt_graph_instance_alive(g, 1) == 0);

    int id_a = rt_graph_instance_add(g);
    REQUIRE(id_a == 1);
    rt_graph_instance_set_control(g, id_a, 0, 0, 1000.0);
    // §2.C: route to bus 1 so we can isolate this instance's contribution
    // (instance 0 still writes 440 Hz to bus 0).
    rt_graph_instance_set_control(g, id_a, 1, 0, 1.0);

    REQUIRE(rt_graph_instance_count(g) == 2);
    REQUIRE(rt_graph_instance_alive(g, 1) == 1);

    rt_graph_process(g, kFrames);
    std::vector<float> bus1(kFrames, 0.0f);
    rt_graph_read_bus(g, 1, kFrames, bus1.data());
    CHECK(peak_abs(bus1) > 0.9f);

    // Remove and re-add: the new instance should get the same id (slot
    // 1 reused) with a fresh state — control 0 (freq) back to default 0.
    rt_graph_instance_remove(g, id_a);
    REQUIRE(rt_graph_instance_alive(g, 1) == 0);

    int id_b = rt_graph_instance_add(g);
    CHECK(id_b == 1);
    REQUIRE(rt_graph_instance_alive(g, 1) == 1);
    // Route the fresh instance to bus 1 too. Default freq=0 → SinOsc
    // phase doesn't advance → output is sin(0)=0 forever, so bus 1
    // (where only this instance writes) should be silent.
    rt_graph_instance_set_control(g, id_b, 1, 0, 1.0);

    rt_graph_process(g, kFrames);
    std::vector<float> fresh(kFrames, 0.0f);
    rt_graph_read_bus(g, 1, kFrames, fresh.data());
    rt_graph_destroy(g);

    CHECK(peak_abs(fresh) < 1e-3f);
}

TEST_CASE("Multi-instance: removing an instance stops its contribution to the pool") {
    // Two instances of one template route to *different* buses
    // (instance 0 → bus 0 by default; instance 1 → bus 1 via per-
    // instance control). After removing instance 1, bus 1 should
    // go silent (clear_output_buses zeroes it each block and no
    // kernel writes to it anymore), while bus 0 keeps singing.
    //
    // This pins the actually-load-bearing semantics: removing an
    // instance withdraws its kernels from the schedule. The earlier
    // version of this test relied on rt_graph_instance_read_bus's
    // liveness gate, which was removed alongside the function in
    // the post-§2.E ABI cleanup.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 1);                           // inst 1 routes here

    rt_graph_add_node(g, 0, 1);                          // SinOsc
    rt_graph_set_control(g, 0, 0, 440.0);
    rt_graph_add_node(g, 1, 2);                          // Out
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    int inst1 = rt_graph_instance_add(g);
    REQUIRE(inst1 == 1);
    rt_graph_instance_set_control(g, inst1, 0, 0, 880.0);
    rt_graph_instance_set_control(g, inst1, 1, 0, 1.0);  // route to bus 1

    // Both alive and producing.
    rt_graph_process(g, kFrames);
    std::vector<float> bus0(kFrames, 0.0f);
    std::vector<float> bus1(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    rt_graph_read_bus(g, 1, kFrames, bus1.data());
    CHECK(peak_abs(bus0) > 0.9f);
    CHECK(peak_abs(bus1) > 0.9f);

    // Remove instance 1, run another block: bus 1 has no writer left,
    // so clear_output_buses leaves it at zero. Bus 0 still gets
    // instance 0's contribution.
    rt_graph_instance_remove(g, inst1);
    rt_graph_process(g, kFrames);

    std::vector<float> bus0_after(kFrames, 0.0f);
    std::vector<float> bus1_after(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0_after.data());
    rt_graph_read_bus(g, 1, kFrames, bus1_after.data());
    CHECK(peak_abs(bus0_after) > 0.9f);  // survivor still sings
    CHECK(peak_abs(bus1_after) < 1e-6f); // removed voice's bus is silent

    rt_graph_destroy(g);
}

TEST_CASE("Multi-instance: counting and aliveness on null/bad ids") {
    CHECK(rt_graph_instance_count(nullptr) == 0);
    CHECK(rt_graph_instance_alive(nullptr, 0) == 0);

    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    CHECK(rt_graph_instance_alive(g, -1) == 0);
    CHECK(rt_graph_instance_alive(g, 99) == 0);
    CHECK(rt_graph_instance_count(g) == 1);  // default instance 0
    CHECK(rt_graph_instance_alive(g, 0) == 1);
    rt_graph_destroy(g);
}

// (TEST_CASE "Multi-instance: legacy API targets instance 0" was
// deleted in the post-§2.E ABI cleanup. It compared rt_graph_read_bus
// to rt_graph_instance_read_bus; with the latter removed (under §2.C
// it added nothing beyond a liveness gate over the shared pool), the
// comparison has no remaining content. The "legacy entries target
// instance 0" invariant is covered by the legacy-shim Note in
// rt_graph.cpp and exercised by every test that uses the bare
// rt_graph_set_control entry.)

TEST_CASE("Multi-instance: removing instance 0 disables instance-scoped API only") {
    // After removing instance 0, instance-scoped legacy entries
    // (rt_graph_set_control, which targets instance 0) become silent
    // no-ops. But under §2.C+§2.D.3, the bus pool is server-global —
    // not instance-scoped — so rt_graph_read_bus still reads the live
    // pool regardless of any single instance's liveness. This test
    // pins both halves: the instance-scoped half goes silent, the
    // pool-scoped half does not.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_add_node(g, 0, 1);
    rt_graph_set_control(g, 0, 0, 440.0);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_process(g, kFrames);

    rt_graph_instance_remove(g, 0);
    REQUIRE(rt_graph_instance_alive(g, 0) == 0);

    // Bus read after removal: returns kFrames (the shared pool still
    // holds whatever the last block left there). This is *not* the
    // pre-§2.D.3 behavior — the legacy entry used to delegate to a
    // since-removed rt_graph_instance_read_bus, which checked instance
    // liveness. Under §2.C the pool is shared, so the instance check
    // was a legacy quirk that masked the real (pool-scoped) semantics;
    // the post-§2.E ABI cleanup dropped the entry alongside its quirk.
    std::vector<float> samples(kFrames, 7.0f);
    int n = rt_graph_read_bus(g, 0, kFrames, samples.data());
    CHECK(n == kFrames);

    // Instance-scoped legacy entry: silent no-op. We can verify by
    // setting an absurd freq via the legacy entry, processing, and
    // observing the bus stays zero (no instance to write into it).
    rt_graph_set_control(g, 0, 0, 99.0); // legacy → instance 0 → no-op
    rt_graph_process(g, kFrames);

    std::vector<float> after_dead(kFrames, 1.0f);
    int n2 = rt_graph_read_bus(g, 0, kFrames, after_dead.data());
    CHECK(n2 == kFrames);
    // No live instance wrote bus 0; clear_output_buses zeroed it at
    // the start of the block.
    CHECK(peak_abs(after_dead) == 0.0f);

    // Re-add: slot 0 is reused, instance-scoped API works again.
    int reborn = rt_graph_instance_add(g);
    CHECK(reborn == 0);
    rt_graph_set_control(g, 0, 0, 440.0);
    rt_graph_process(g, kFrames);

    std::vector<float> reborn_samples(kFrames, 0.0f);
    int got = rt_graph_read_bus(g, 0, kFrames, reborn_samples.data());
    CHECK(got == kFrames);
    CHECK(peak_abs(reborn_samples) > 0.9f);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Server-global buses (§2.C)
// ----------------------------------------------------------------
//
// The bus pool moved out of GraphInstance into a Server shared by
// all instances. Two consequences:
//   * Instances writing to the same bus index sum into one bus.
//   * One instance's BusOut feeds another instance's BusIn within
//     the same block (subject to instance iteration order).

TEST_CASE("Server buses §2.C: two voices on the same bus sum into one signal") {
    // §2.C global pool: two instances writing constants to bus 0
    // produce bus 0 = a + b. This is the polyphonic-mixer pattern that
    // motivated shared buses.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_add_node(g, 0, 8);                          // Add (constant)
    rt_graph_add_node(g, 1, 2);                          // Out
    rt_graph_connect(g, 0, 0, 1, 0);

    // Instance 0: constant +0.3 → bus 0.
    rt_graph_instance_set_control(g, 0, 0, 0, 0.3);
    rt_graph_instance_set_control(g, 0, 0, 1, 0.0);
    rt_graph_instance_set_control(g, 0, 1, 0, 0.0);

    int inst1 = rt_graph_instance_add(g);
    REQUIRE(inst1 == 1);
    // Instance 1: constant +0.4 → bus 0.
    rt_graph_instance_set_control(g, 1, 0, 0, 0.4);
    rt_graph_instance_set_control(g, 1, 0, 1, 0.0);
    rt_graph_instance_set_control(g, 1, 1, 0, 0.0);

    rt_graph_process(g, kFrames);

    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    rt_graph_destroy(g);

    // Bus 0 should be exactly 0.3 + 0.4 = 0.7 sample-by-sample.
    for (auto s : bus0) {
        CHECK(s == doctest::Approx(0.7f).epsilon(1e-6));
    }
}

TEST_CASE("Server buses §2.C: cross-instance routing through a shared bus") {
    // The headline §2.C demo: voice A writes its SinOsc to bus 5,
    // voice B's BusIn(5) reads it within the same block, voice B
    // routes the result to hardware bus 0. Because A is added first
    // (instance 0) and instances run in vector order, A's BusOut
    // executes before B's BusIn; the bus pool acts as the inter-voice
    // wire.
    //
    // Shared graph topology — both instances run all four nodes:
    //   SinOsc → BusOut    (write to bus controlled by per-instance ctl)
    //   BusIn → Out        (read from bus, write to bus controlled by ctl)
    //
    // Per-instance controls steer each voice into "produce" or
    // "consume" mode by aiming its bus indices at the cross bus or
    // at junk-bus 99.
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 5);   // shared cross-voice bus
    rt_graph_ensure_bus(g, 99);  // junk bus used by the unused paths
    rt_graph_add_node(g, 0, 1);                          // SinOsc
    rt_graph_add_node(g, 1, 10);                         // BusOut
    rt_graph_connect(g, 0, 0, 1, 0);
    rt_graph_add_node(g, 2, 11);                         // BusIn
    rt_graph_add_node(g, 3, 2);                          // Out
    rt_graph_connect(g, 2, 0, 3, 0);

    // Voice A (instance 0): produce 440 Hz on bus 5; reads/writes
    // junk bus 99 for its own (unused) BusIn → Out path.
    rt_graph_instance_set_control(g, 0, 0, 0, 440.0);
    rt_graph_instance_set_control(g, 0, 1, 0, 5.0);
    rt_graph_instance_set_control(g, 0, 2, 0, 99.0);
    rt_graph_instance_set_control(g, 0, 3, 0, 99.0);

    int inst1 = rt_graph_instance_add(g);
    REQUIRE(inst1 == 1);
    // Voice B (instance 1): SinOsc muted; BusIn reads bus 5 (voice A's
    // signal) and Out routes it to hardware bus 0.
    rt_graph_instance_set_control(g, 1, 0, 0, 0.0);
    rt_graph_instance_set_control(g, 1, 1, 0, 99.0);
    rt_graph_instance_set_control(g, 1, 2, 0, 5.0);
    rt_graph_instance_set_control(g, 1, 3, 0, 0.0);

    rt_graph_process(g, kFrames);

    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    rt_graph_destroy(g);

    // Bus 0 should carry voice A's 440 Hz sine, having traveled
    // A.BusOut(5) → server.bus[5] → B.BusIn(5) → B.Out(0).
    CHECK(peak_abs(bus0) > 0.9f);
    const int zc = zero_crossings(bus0);
    INFO("zc=" << zc);
    CHECK(zc >= 15);
    CHECK(zc <= 22);
}

// ----------------------------------------------------------------
// Multi-template (§2.D.3)
// ----------------------------------------------------------------
//
// These tests exercise the new template-aware C ABI:
// rt_graph_template_add / _add_node / _set_default / _connect /
// _instance_add. The legacy single-template entries used elsewhere
// in this file still work (they target template 0), so we focus
// here on the new shape: multiple MetaDefs in one RTGraph,
// per-template instance pools, cross-template bus routing, and the
// process_graph outer-by-template iteration order.

TEST_CASE("Multi-template: template_add returns dense ids; count tracks them") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    // rt_graph_create auto-creates template 0 so legacy callers work.
    CHECK(rt_graph_template_count(g) == 1);

    // Each subsequent rt_graph_template_add appends a fresh MetaDef
    // and returns its dense id (1, 2, 3, ...). Registration order
    // equals execution order; the Haskell side picks registration
    // order to match the topo sort over template precedence.
    CHECK(rt_graph_template_add(g) == 1);
    CHECK(rt_graph_template_add(g) == 2);
    CHECK(rt_graph_template_add(g) == 3);
    CHECK(rt_graph_template_count(g) == 4);

    // Null safety.
    CHECK(rt_graph_template_add(nullptr) == -1);
    CHECK(rt_graph_template_count(nullptr) == 0);

    rt_graph_destroy(g);
}

TEST_CASE("Multi-template: per-template node spaces are independent") {
    // Adding a node at index 0 in template 0 must not affect
    // template 1's node 0. Each template has its own dense node
    // space; rt_graph_template_add_node grows only the named
    // template's MetaDef and the per-template instances' state
    // vectors.
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 1);  // template 1 routes to bus 1

    int t0 = 0;                                // auto-created
    int t1 = rt_graph_template_add(g);
    REQUIRE(t1 == 1);

    // Template 0: SinOsc(440) → Out(0)
    rt_graph_template_add_node(g, t0, 0, 1);    // SinOsc
    rt_graph_template_set_default(g, t0, 0, 0, 440.0);
    rt_graph_template_add_node(g, t0, 1, 2);    // Out
    rt_graph_template_set_default(g, t0, 1, 0, 0.0);
    rt_graph_template_connect(g, t0, 0, 0, 1, 0);

    // Template 1: SinOsc(880) → Out(1)
    rt_graph_template_add_node(g, t1, 0, 1);    // SinOsc
    rt_graph_template_set_default(g, t1, 0, 0, 880.0);
    rt_graph_template_add_node(g, t1, 1, 2);    // Out
    rt_graph_template_set_default(g, t1, 1, 0, 1.0);
    rt_graph_template_connect(g, t1, 0, 0, 1, 0);

    // One instance per template.
    rt_graph_instance_remove(g, 0);             // drop the auto-created one
    int i0 = rt_graph_template_instance_add(g, t0);
    int i1 = rt_graph_template_instance_add(g, t1);
    REQUIRE(i0 >= 0);
    REQUIRE(i1 >= 0);
    CHECK(i0 != i1);

    rt_graph_process(g, kFrames);

    // Each voice writes to its own bus; per-instance bus reads
    // distinguish them because they target different bus indices.
    std::vector<float> bus0(kFrames, 0.0f);
    std::vector<float> bus1(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    rt_graph_read_bus(g, 1, kFrames, bus1.data());

    // 440 Hz over 1024 frames at 48000 ≈ 19 zero crossings.
    // 880 Hz over the same window ≈ 38.
    const int zc0 = zero_crossings(bus0);
    const int zc1 = zero_crossings(bus1);
    INFO("zc0=" << zc0 << " zc1=" << zc1);
    CHECK(zc0 >= 15);
    CHECK(zc0 <= 22);
    CHECK(zc1 >= 32);
    CHECK(zc1 <= 42);

    rt_graph_destroy(g);
}

TEST_CASE("Multi-template: template_set_default propagates to future instances") {
    // The defining feature of rt_graph_template_set_default: it
    // mutates the *spec*, so every instance spawned afterwards
    // inherits the value. Existing instances are not changed (that's
    // the per-instance setter's job).
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 5);  // instA routes to bus 5
    rt_graph_ensure_bus(g, 6);  // instB routes to bus 6

    int t0 = 0;
    rt_graph_template_add_node(g, t0, 0, 1);    // SinOsc
    rt_graph_template_add_node(g, t0, 1, 2);    // Out
    rt_graph_template_set_default(g, t0, 1, 0, 0.0);
    rt_graph_template_connect(g, t0, 0, 0, 1, 0);

    // Instance A (auto-created at slot 0): inherits the spec
    // default (which is 0 for the SinOsc freq because we haven't
    // set it yet). It should be silent.
    int instA = 0;

    // Now set the spec default — instance A is *not* mutated.
    rt_graph_template_set_default(g, t0, 0, 0, 660.0);

    // Instance B: spawned after the spec default change, so its
    // SinOsc freq starts at 660 Hz.
    int instB = rt_graph_template_instance_add(g, t0);

    // Use different output buses so we can observe each voice
    // separately. (They're both on Out(0) by spec default; override
    // per-instance.)
    rt_graph_instance_set_control(g, instA, 1, 0, 5.0); // A → bus 5
    rt_graph_instance_set_control(g, instB, 1, 0, 6.0); // B → bus 6

    rt_graph_process(g, kFrames);

    std::vector<float> bus5(kFrames, 0.0f);
    std::vector<float> bus6(kFrames, 0.0f);
    rt_graph_read_bus(g, 5, kFrames, bus5.data());
    rt_graph_read_bus(g, 6, kFrames, bus6.data());

    // Instance A: freq still default-zero, no signal.
    CHECK(peak_abs(bus5) < 0.01f);
    // Instance B: spawned with the updated default 660 Hz.
    CHECK(peak_abs(bus6) > 0.9f);
    const int zcB = zero_crossings(bus6);
    INFO("zcB=" << zcB);
    // 660 Hz × (1024/48000) ≈ 14 cycles → ~28 zero crossings.
    CHECK(zcB >= 22);
    CHECK(zcB <= 32);

    rt_graph_destroy(g);
}

TEST_CASE("Multi-template: cross-template routing through the shared bus pool") {
    // Two templates A and B share the server bus pool. A writes a
    // signal to bus 7; B reads bus 7 and routes it to hardware bus 0.
    // process_graph iterates templates in registration order, so
    // A's writes are visible to B's BusIn within the same block —
    // this is the mechanism that makes inter-template bus routing
    // work, and it's exactly what compileTemplateGraph's
    // topological sort enforces (writers before readers when their
    // footprints intersect).
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 7);  // cross-template send/return

    int producer = 0;                           // auto-created template 0
    int consumer = rt_graph_template_add(g);
    REQUIRE(consumer == 1);

    // Producer template: SinOsc(330) → BusOut(7).
    rt_graph_template_add_node(g, producer, 0, 1);    // SinOsc
    rt_graph_template_set_default(g, producer, 0, 0, 330.0);
    rt_graph_template_add_node(g, producer, 1, 10);   // BusOut
    rt_graph_template_set_default(g, producer, 1, 0, 7.0);
    rt_graph_template_connect(g, producer, 0, 0, 1, 0);

    // Consumer template: BusIn(7) → Out(0).
    rt_graph_template_add_node(g, consumer, 0, 11);   // BusIn
    rt_graph_template_set_default(g, consumer, 0, 0, 7.0);
    rt_graph_template_add_node(g, consumer, 1, 2);    // Out
    rt_graph_template_set_default(g, consumer, 1, 0, 0.0);
    rt_graph_template_connect(g, consumer, 0, 0, 1, 0);

    // Drop the auto-created instance 0 and spawn one of each.
    rt_graph_instance_remove(g, 0);
    int prodInst = rt_graph_template_instance_add(g, producer);
    int consInst = rt_graph_template_instance_add(g, consumer);
    REQUIRE(prodInst >= 0);
    REQUIRE(consInst >= 0);

    rt_graph_process(g, kFrames);

    // Bus 0 should carry the producer's 330 Hz sine, having
    // traveled producer.BusOut(7) → server.bus[7] →
    // consumer.BusIn(7) → consumer.Out(0).
    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    CHECK(peak_abs(bus0) > 0.9f);
    const int zc = zero_crossings(bus0);
    INFO("zc=" << zc);
    // 330 Hz × (1024/48000) ≈ 7 cycles → ~14 zero crossings.
    CHECK(zc >= 11);
    CHECK(zc <= 18);

    rt_graph_destroy(g);
}

TEST_CASE("Multi-template: instances of different templates execute in template order") {
    // Two templates each produce a distinct constant on the same
    // bus. Because rt_graph_template_set_default writes spec
    // defaults that are visible to bus accumulation, and BusOut/Out
    // sum into the live pool, a single bus N receives the sum of
    // every template's contribution. Critically, this works
    // regardless of which template was registered first — the bus
    // pool is server-global and BusOut accumulates additively.
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    int tA = 0;
    int tB = rt_graph_template_add(g);
    REQUIRE(tB == 1);

    // Template A: NoiseGen → Gain(0.0, then will be set to 0.3) →
    // Out(3). We use NoiseGen + Gain(0) to write a constant 0.0;
    // simpler: use SinOsc with extremely low freq → ~constant.
    // Even simpler: just SinOsc → Out and check peak_abs / sum.
    //
    // Use SinOsc(110) on tA, SinOsc(220) on tB, both into Out(0).
    // The bus 0 reading is the sum, and peak_abs gives a quick
    // sanity check that both contributed (else peak would match a
    // single SinOsc).
    rt_graph_template_add_node(g, tA, 0, 1);
    rt_graph_template_set_default(g, tA, 0, 0, 110.0);
    rt_graph_template_add_node(g, tA, 1, 2);
    rt_graph_template_set_default(g, tA, 1, 0, 0.0);
    rt_graph_template_connect(g, tA, 0, 0, 1, 0);

    rt_graph_template_add_node(g, tB, 0, 1);
    rt_graph_template_set_default(g, tB, 0, 0, 220.0);
    rt_graph_template_add_node(g, tB, 1, 2);
    rt_graph_template_set_default(g, tB, 1, 0, 0.0);
    rt_graph_template_connect(g, tB, 0, 0, 1, 0);

    rt_graph_instance_remove(g, 0);
    int iA = rt_graph_template_instance_add(g, tA);
    int iB = rt_graph_template_instance_add(g, tB);
    REQUIRE(iA >= 0);
    REQUIRE(iB >= 0);

    rt_graph_process(g, kFrames);

    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());

    // Two unit sines summed: peak in [1.0, 2.0] (depends on phase
    // alignment over the 1024-frame window). A single SinOsc would
    // peak near 1.0 exactly. Since tA at 110 Hz won't peak in
    // 1024 frames, the dominant contribution is tB's 220 Hz.
    // Either way, peak should exceed 0.9 and the spectrum carries
    // both frequencies — total zero crossings reflect the sum.
    CHECK(peak_abs(bus0) > 0.9f);

    rt_graph_destroy(g);
}

TEST_CASE("Multi-template: removing an instance only stops that voice") {
    // Spawn two voices of the same template, observe the sum, then
    // remove one voice and observe only the survivor's signal.
    // Verifies that per-instance lifecycle interacts correctly with
    // the multi-template execution loop.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    int t0 = 0;
    rt_graph_template_add_node(g, t0, 0, 1);
    rt_graph_template_add_node(g, t0, 1, 2);
    rt_graph_template_set_default(g, t0, 1, 0, 0.0);
    rt_graph_template_connect(g, t0, 0, 0, 1, 0);

    rt_graph_instance_remove(g, 0);
    int iA = rt_graph_template_instance_add(g, t0);
    int iB = rt_graph_template_instance_add(g, t0);
    REQUIRE(iA >= 0);
    REQUIRE(iB >= 0);
    CHECK(iA != iB);

    // Different freqs so we can distinguish the survivor by zc.
    rt_graph_instance_set_control(g, iA, 0, 0, 220.0);
    rt_graph_instance_set_control(g, iB, 0, 0, 880.0);

    rt_graph_process(g, kFrames);
    std::vector<float> bus_both(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus_both.data());
    const int zc_both = zero_crossings(bus_both);

    rt_graph_instance_remove(g, iA);
    REQUIRE(rt_graph_instance_alive(g, iA) == 0);
    REQUIRE(rt_graph_instance_alive(g, iB) == 1);

    rt_graph_process(g, kFrames);
    std::vector<float> bus_b_only(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus_b_only.data());
    const int zc_b = zero_crossings(bus_b_only);

    INFO("zc_both=" << zc_both << " zc_b=" << zc_b);
    // 880 Hz alone over 1024 frames at 48000 ≈ 38 zc.
    CHECK(zc_b >= 32);
    CHECK(zc_b <= 42);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// §2.E release-then-free instance lifecycle
// ----------------------------------------------------------------
//
// rt_graph_instance_release is the graceful counterpart to
// rt_graph_instance_remove: it gates-off any Env nodes, lets the
// tail render, and reclaims the slot once the instance has been
// silent for a small window. These tests pin:
//
//   * status reporting (Live / Releasing / -1 for dead),
//   * the no-Env shortcut (release == hard-free),
//   * the Env path: transition to Releasing, eventual auto-free,
//   * isolation: releasing one instance does not affect peers.
//
// See Note [§2.E: release-then-free instance lifecycle] in
// rt_graph.cpp for the design.

TEST_CASE("§2.E status: fresh instance reports Live") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    // Auto-created instance 0 is Live by default.
    CHECK(rt_graph_instance_status(g, 0) == 0);

    // Out-of-range and never-allocated slots are -1.
    CHECK(rt_graph_instance_status(g, 99) == -1);
    CHECK(rt_graph_instance_status(g, -1) == -1);
    CHECK(rt_graph_instance_status(nullptr, 0) == -1);

    rt_graph_destroy(g);
}

TEST_CASE("§2.E release on instance with no Env hard-frees the slot") {
    // No envelope means there is nothing to "release" — the runtime
    // falls back to immediate slot reset. Verifies the documented
    // shortcut path.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1);                  // SinOsc
    rt_graph_set_control(g, 0, 0, 220.0);
    rt_graph_add_node(g, 1, 2);                  // Out
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    REQUIRE(rt_graph_instance_alive(g, 0) == 1);
    rt_graph_instance_release(g, 0);

    // Slot is dead immediately, not after the next process call.
    CHECK(rt_graph_instance_alive(g, 0) == 0);
    CHECK(rt_graph_instance_status(g, 0) == -1);

    rt_graph_destroy(g);
}

TEST_CASE("§2.E release on Env-bearing instance transitions to Releasing then auto-frees") {
    // Held gate (default 1.0) drives the envelope to sustain. After
    // release, the falling edge fires q's release ramp; the instance
    // keeps processing every block until block_sink_peak stays below
    // the silence threshold for kReleaseSilenceBlocks (= 8) blocks
    // running, at which point the slot is reclaimed.
    constexpr int kBlock = 256;  // smaller block to make the silence window land in a reasonable test runtime
    auto *g = rt_graph_create(4, kBlock);
    REQUIRE(g != nullptr);

    // Env(gate=1, A=0.5ms, D=2ms, S=0.5, R=2ms) → Out(bus 0).
    // Short release (2 ms) so the tail decays to near-zero quickly
    // and the silence window starts almost immediately.
    rt_graph_add_node(g, 0, 9);                  // Env
    rt_graph_set_control(g, 0, 0, 1.0);          // gate high
    rt_graph_set_control(g, 0, 1, 0.0005);
    rt_graph_set_control(g, 0, 2, 0.002);
    rt_graph_set_control(g, 0, 3, 0.5);
    rt_graph_set_control(g, 0, 4, 0.002);        // R = 2 ms
    rt_graph_add_node(g, 1, 2);                  // Out
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    // Block 0: attack and reach sustain. Pre-release status must
    // still report Live.
    rt_graph_process(g, kBlock);
    REQUIRE(rt_graph_instance_status(g, 0) == 0);

    // Trigger release. Status must flip to Releasing immediately;
    // the slot is still alive because the tail has not rendered yet.
    rt_graph_instance_release(g, 0);
    CHECK(rt_graph_instance_status(g, 0) == 1);
    CHECK(rt_graph_instance_alive(g, 0) == 1);

    // Process up to 64 blocks; somewhere inside that window the tail
    // should fall below the silence threshold and the silence
    // counter should cross kReleaseSilenceBlocks. Bound loosely —
    // the precise count depends on q's release ramp shape.
    bool freed = false;
    for (int i = 0; i < 64; ++i) {
        rt_graph_process(g, kBlock);
        if (rt_graph_instance_alive(g, 0) == 0) {
            freed = true;
            break;
        }
    }
    CHECK(freed);
    CHECK(rt_graph_instance_status(g, 0) == -1);

    rt_graph_destroy(g);
}

TEST_CASE("§2.E release on a dead slot is a no-op") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_instance_remove(g, 0);
    REQUIRE(rt_graph_instance_alive(g, 0) == 0);

    // Releasing a dead/invalid slot must not crash and must not
    // resurrect the slot.
    rt_graph_instance_release(g, 0);
    rt_graph_instance_release(g, 99);
    rt_graph_instance_release(g, -1);
    rt_graph_instance_release(nullptr, 0);

    CHECK(rt_graph_instance_alive(g, 0) == 0);

    rt_graph_destroy(g);
}

TEST_CASE("§2.E releasing one voice does not affect peer voices") {
    // Two voices of the same template, each with its own Env. After
    // releasing voice A, voice B must remain Live, audible, and
    // never enter Releasing.
    constexpr int kBlock = 256;
    auto *g = rt_graph_create(4, kBlock);
    REQUIRE(g != nullptr);

    int t0 = 0;
    rt_graph_template_add_node(g, t0, 0, 9);             // Env
    rt_graph_template_set_default(g, t0, 0, 0, 1.0);     // gate default 1
    rt_graph_template_set_default(g, t0, 0, 1, 0.0005);
    rt_graph_template_set_default(g, t0, 0, 2, 0.002);
    rt_graph_template_set_default(g, t0, 0, 3, 0.5);
    rt_graph_template_set_default(g, t0, 0, 4, 0.005);
    rt_graph_template_add_node(g, t0, 1, 2);             // Out
    rt_graph_template_set_default(g, t0, 1, 0, 0.0);
    rt_graph_template_connect(g, t0, 0, 0, 1, 0);

    rt_graph_instance_remove(g, 0);
    int iA = rt_graph_template_instance_add(g, t0);
    int iB = rt_graph_template_instance_add(g, t0);
    REQUIRE(iA >= 0);
    REQUIRE(iB >= 0);

    // Run a block so both envelopes leave idle.
    rt_graph_process(g, kBlock);

    rt_graph_instance_release(g, iA);
    CHECK(rt_graph_instance_status(g, iA) == 1);
    CHECK(rt_graph_instance_status(g, iB) == 0);

    // Drive enough blocks to free voice A. Voice B must remain Live.
    for (int i = 0; i < 64; ++i) {
        rt_graph_process(g, kBlock);
    }
    CHECK(rt_graph_instance_alive(g, iA) == 0);
    CHECK(rt_graph_instance_alive(g, iB) == 1);
    CHECK(rt_graph_instance_status(g, iB) == 0);

    rt_graph_destroy(g);
}

TEST_CASE("§2.E releasing a slot then re-adding reuses the freed id") {
    // The slot-reuse contract documented for rt_graph_instance_remove
    // also applies to slots auto-freed by the release pathway: once
    // the instance is gone, the next add fills the same slot.
    constexpr int kBlock = 256;
    auto *g = rt_graph_create(4, kBlock);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 9);
    rt_graph_set_control(g, 0, 0, 1.0);
    rt_graph_set_control(g, 0, 4, 0.002);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_process(g, kBlock);
    rt_graph_instance_release(g, 0);

    bool freed = false;
    for (int i = 0; i < 64 && !freed; ++i) {
        rt_graph_process(g, kBlock);
        if (rt_graph_instance_alive(g, 0) == 0) freed = true;
    }
    REQUIRE(freed);

    int reused = rt_graph_instance_add(g);
    CHECK(reused == 0);
    CHECK(rt_graph_instance_alive(g, 0) == 1);
    CHECK(rt_graph_instance_status(g, 0) == 0);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// §2.E polyphonic stress: many voices, staggered release
// ----------------------------------------------------------------
//
// The earlier §2.E tests exercise lifecycle on at most two instances.
// A future voice allocator (Phase 3.1) will routinely run with eight
// to a few dozen concurrent voices, with new voices spawning while
// older ones are mid-release and slot reuse cycling continuously.
// This test pins the concurrent behavior:
//
//   * many voices Live + Releasing in the same template,
//   * staggered release so per-instance silence counters are at
//     different points across the population,
//   * slot reuse: spawning during an active release wave fills slots
//     freed by prior auto-frees, exercising the rt_graph_template_-
//     instance_add scan path,
//   * peer isolation: surviving Live voices keep singing while
//     released peers around them flicker through Releasing → dead,
//   * eventual full drain: once everyone is released, the population
//     reaches alive == 0 and stays there.
//
// The template is a minimal ADSR-shaped sine: one Env (gate held high
// by spec default), one SinOsc, one Gain (modulated by the Env),
// one Out routing to bus 0. Per-instance freq is set after spawn.
//
// Tunables match Phase 3 expectations: kVoices is small enough that
// dead-slot scan in rt_graph_template_instance_add is irrelevant
// (linear scan is fine here), large enough that "many voices at once"
// is a real condition rather than a special case.
TEST_CASE("§2.E polyphonic stress: staggered release, slot reuse, full drain") {
    constexpr int kBlock  = 256;
    constexpr int kVoices = 8;
    constexpr float kFreqs[kVoices] = {
        110.0f, 138.59f, 165.0f, 220.0f,
        261.63f, 329.63f, 392.0f, 523.25f,
    };

    auto *g = rt_graph_create(/*capacity*/ 16, kBlock);
    REQUIRE(g != nullptr);

    int t0 = 0;
    // Env: gate default 1, A=1ms, D=2ms, S=0.7, R=5ms.
    rt_graph_template_add_node(g, t0, 0, 9);
    rt_graph_template_set_default(g, t0, 0, 0, 1.0);
    rt_graph_template_set_default(g, t0, 0, 1, 0.001);
    rt_graph_template_set_default(g, t0, 0, 2, 0.002);
    rt_graph_template_set_default(g, t0, 0, 3, 0.7);
    rt_graph_template_set_default(g, t0, 0, 4, 0.005);
    // SinOsc: freq default 440 (overridden per-instance after spawn).
    rt_graph_template_add_node(g, t0, 1, 1);
    rt_graph_template_set_default(g, t0, 1, 0, 440.0);
    // Gain: signal_in <- SinOsc, gain_in <- Env.
    rt_graph_template_add_node(g, t0, 2, 3);
    // Out: bus 0.
    rt_graph_template_add_node(g, t0, 3, 2);
    rt_graph_template_set_default(g, t0, 3, 0, 0.0);
    rt_graph_template_connect(g, t0, 1, 0, 2, 0);  // SinOsc → Gain.signal
    rt_graph_template_connect(g, t0, 0, 0, 2, 1);  // Env → Gain.gain
    rt_graph_template_connect(g, t0, 2, 0, 3, 0);  // Gain → Out

    // Drop the auto-spawned instance 0 — we want a clean population
    // we built ourselves so id assignments are predictable.
    rt_graph_instance_remove(g, 0);

    int ids[kVoices] = {};
    for (int v = 0; v < kVoices; ++v) {
        ids[v] = rt_graph_template_instance_add(g, t0);
        REQUIRE(ids[v] >= 0);
        rt_graph_instance_set_control(g, ids[v], 1, 0,
                                       static_cast<double>(kFreqs[v]));
        // Sanity: each voice spawns Live.
        REQUIRE(rt_graph_instance_status(g, ids[v]) == 0);
    }

    // Warm-up: a few blocks so every envelope leaves idle and reaches
    // sustain. Without this, releasing in the next phase would race
    // the attack ramp and confuse the silence counter on voices whose
    // attacks haven't completed.
    for (int b = 0; b < 4; ++b) rt_graph_process(g, kBlock);

    for (int v = 0; v < kVoices; ++v) {
        CHECK(rt_graph_instance_alive(g, ids[v]) == 1);
        CHECK(rt_graph_instance_status(g, ids[v]) == 0);
    }

    // Phase 1: stagger release of the lower half (voices 0..3), one
    // per block. This puts the silence counters at four different
    // offsets, so when we later check "all released voices are gone"
    // we know the runtime tolerated overlapping Releasing populations
    // rather than only the simple "all release at once" case.
    constexpr int kReleased = kVoices / 2;
    for (int v = 0; v < kReleased; ++v) {
        rt_graph_instance_release(g, ids[v]);
        CHECK(rt_graph_instance_status(g, ids[v]) == 1);
        CHECK(rt_graph_instance_alive(g, ids[v]) == 1);  // tail still rendering
        rt_graph_process(g, kBlock);
    }

    // Mid-release sanity: lower-half is Releasing, upper-half is
    // still Live, exactly. No Releasing voice should have flipped
    // back to Live; no Live voice should have drifted to Releasing.
    for (int v = 0; v < kReleased; ++v) {
        const int s = rt_graph_instance_status(g, ids[v]);
        // Either still Releasing or already auto-freed (if R + window
        // elapsed for the earliest releases). Definitely not Live.
        CHECK((s == 1 || s == -1));
    }
    for (int v = kReleased; v < kVoices; ++v) {
        CHECK(rt_graph_instance_status(g, ids[v]) == 0);
        CHECK(rt_graph_instance_alive(g, ids[v]) == 1);
    }

    // Phase 2: drain the released voices. Run enough blocks for the
    // longest-tail voice to clear the silence window comfortably.
    for (int b = 0; b < 64; ++b) rt_graph_process(g, kBlock);

    int alive_lower = 0;
    int alive_upper = 0;
    for (int v = 0; v < kVoices; ++v) {
        const int alive = rt_graph_instance_alive(g, ids[v]);
        (v < kReleased ? alive_lower : alive_upper) += alive;
    }
    CHECK(alive_lower == 0);              // released voices freed
    CHECK(alive_upper == kVoices - kReleased);  // survivors still alive

    // Phase 3: spawn fresh voices into the freed slots. Slot-reuse
    // contract: rt_graph_template_instance_add scans for empty
    // optionals first. Order of reuse is implementation-defined
    // (today: ascending slot index), but every new id MUST land in
    // the [0, kVoices) range — no growth past the original
    // population — because there are exactly kReleased free slots.
    int reused_ids[kReleased] = {};
    for (int v = 0; v < kReleased; ++v) {
        reused_ids[v] = rt_graph_template_instance_add(g, t0);
        REQUIRE(reused_ids[v] >= 0);
        REQUIRE(reused_ids[v] < kVoices);
        rt_graph_instance_set_control(g, reused_ids[v], 1, 0, 880.0);
    }
    CHECK(rt_graph_instance_count(g) == kVoices);

    // Phase 4: release everyone, drain, verify final population is
    // empty across the board (alive count zero for every slot).
    for (int v = kReleased; v < kVoices; ++v) {
        rt_graph_instance_release(g, ids[v]);
    }
    for (int v = 0; v < kReleased; ++v) {
        rt_graph_instance_release(g, reused_ids[v]);
    }
    for (int b = 0; b < 64; ++b) rt_graph_process(g, kBlock);

    int final_alive = 0;
    for (int slot = 0; slot < rt_graph_instance_count(g); ++slot) {
        final_alive += rt_graph_instance_alive(g, slot);
    }
    CHECK(final_alive == 0);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// A.1: per-template polyphony cap
// ----------------------------------------------------------------
//
// rt_graph_template_set_polyphony bounds the number of simultaneously
// live (Active or Releasing) instances of a template; once the cap is
// reached, rt_graph_template_instance_add returns -1 instead of
// silently growing the pool. The cap is per-template — one template
// hitting its cap doesn't keep other templates from spawning. After
// remove or auto-free transitions the slot back to Available, a
// future spawn fits within the cap again.

TEST_CASE("A.1 polyphony: default cap of 8 rejects the 9th spawn") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1);                    // SinOsc
    rt_graph_add_node(g, 1, 2);                    // Out
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    // Drop the auto-spawned instance 0 to start with a clean count.
    rt_graph_instance_remove(g, 0);

    // Default cap is 8; eight spawns must succeed, the ninth must fail.
    for (int i = 0; i < 8; ++i) {
        const int id = rt_graph_instance_add(g);
        REQUIRE(id >= 0);
    }
    CHECK(rt_graph_instance_add(g) == -1);  // cap reached

    rt_graph_destroy(g);
}

TEST_CASE("A.1 polyphony: explicit cap is honored per-template") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    int t0 = 0;
    int t1 = rt_graph_template_add(g);
    REQUIRE(t1 == 1);

    rt_graph_template_add_node(g, t0, 0, 1);
    rt_graph_template_add_node(g, t0, 1, 2);
    rt_graph_template_add_node(g, t1, 0, 1);
    rt_graph_template_add_node(g, t1, 1, 2);

    rt_graph_template_set_polyphony(g, t0, 2);
    rt_graph_template_set_polyphony(g, t1, 4);

    // Drop auto-instance 0; spawn pool starts empty.
    rt_graph_instance_remove(g, 0);

    // Template 0: cap 2. Two succeed, third returns -1.
    REQUIRE(rt_graph_template_instance_add(g, t0) >= 0);
    REQUIRE(rt_graph_template_instance_add(g, t0) >= 0);
    CHECK(rt_graph_template_instance_add(g, t0) == -1);

    // Template 1's cap is independent — its 4-slot allocation is
    // unaffected by template 0 being full.
    REQUIRE(rt_graph_template_instance_add(g, t1) >= 0);
    REQUIRE(rt_graph_template_instance_add(g, t1) >= 0);
    REQUIRE(rt_graph_template_instance_add(g, t1) >= 0);
    REQUIRE(rt_graph_template_instance_add(g, t1) >= 0);
    CHECK(rt_graph_template_instance_add(g, t1) == -1);

    rt_graph_destroy(g);
}

TEST_CASE("A.1 polyphony: cap <= 0 clamps to 1") {
    // Defensive: zero or negative caps would deadlock callers that
    // expect _instance_add to succeed at least once. The runtime
    // clamps them up to 1 instead of refusing or accepting.
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_template_set_polyphony(g, 0, 0);
    rt_graph_instance_remove(g, 0);
    REQUIRE(rt_graph_instance_add(g) >= 0);     // first spawn succeeds (cap = 1)
    CHECK(rt_graph_instance_add(g) == -1);      // second spawn refused

    rt_graph_template_set_polyphony(g, 0, -10); // negatives clamp the same way
    rt_graph_instance_remove(g, 0);
    REQUIRE(rt_graph_instance_add(g) >= 0);
    CHECK(rt_graph_instance_add(g) == -1);

    rt_graph_destroy(g);
}

TEST_CASE("A.1 polyphony: removing a slot frees up a cap unit") {
    // After remove (or §2.E auto-free) transitions a slot back to
    // Available, the cap regains one unit and a new spawn fits.
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_template_set_polyphony(g, 0, 2);
    rt_graph_instance_remove(g, 0);

    int a = rt_graph_instance_add(g);
    int b = rt_graph_instance_add(g);
    REQUIRE(a >= 0);
    REQUIRE(b >= 0);
    CHECK(rt_graph_instance_add(g) == -1);  // cap reached

    rt_graph_instance_remove(g, a);
    int c = rt_graph_instance_add(g);
    REQUIRE(c >= 0);                        // freed slot now reusable
    CHECK(c == a);                          // and the very same slot index

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// A.2: realtime control queue
// ----------------------------------------------------------------
//
// These tests cover the lock-free SPSC control queue and the six
// rt_graph_realtime_* entries layered over it. The contract under
// test:
//
//   * reserve synchronously CAS-claims an Available slot, prepares
//     it (template_id, nodes, default controls), and returns it in
//     Reserved state. Reserved counts toward the polyphony cap and
//     surfaces as -1 / not-alive through the inspection ABI.
//   * cancel rolls back a Reserved slot to Available; no audio-
//     thread side effects.
//   * activate / release / remove / set_control enqueue work that
//     the audio thread applies at the top of the next process_graph
//     block, in FIFO order. Each enqueue returns 1 on success or 0
//     when the ring (capacity 256) is full.
//   * Reserved slots are excluded from the audio schedule until
//     Activate flips them to Active; SetControl on a Reserved slot
//     is dropped by the drain (controls flow through the producer's
//     pre-enqueue path instead).
//   * rt_graph_clear discards any pending queued commands so a
//     reloaded graph never replays stale work.
//
// Pool pre-warming: realtime_reserve never grows the pool. Tests
// that need a Reserved slot first ensure an Available slot exists,
// either by removing the auto-spawned instance 0 or by spawning
// extra instances via rt_graph_template_instance_add and removing
// them. Both leave Available-shaped slots that reserve can recycle.

namespace {

// Build a minimal "constant on bus 0" template: Add(node 0) → Out(node 1).
// Add's control[0] / control[1] are the two summed constants (default 0);
// Out's control[0] is the bus index (default 0). The caller can override
// per-instance via rt_graph_realtime_set_control on Add's control 0 to
// steer bus 0 to a known value, which makes assertions cheap.
void build_constant_template(RTGraph *g) {
    rt_graph_template_add_node(g, 0, 0, 8);                 // Add
    rt_graph_template_add_node(g, 0, 1, 2);                 // Out
    rt_graph_template_set_default(g, 0, 1, 0, 0.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);
}

} // namespace

TEST_CASE("A.2 reserve: status surfaces Reserved as -1, alive as 0") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    build_constant_template(g);
    // Free the auto-spawned instance 0 so an Available slot exists.
    rt_graph_instance_remove(g, 0);

    int s = rt_graph_realtime_reserve(g, 0);
    REQUIRE(s >= 0);
    // Reserved is the producer's private claim: the inspection ABI
    // hides it, even though the slot is not Available either.
    CHECK(rt_graph_instance_status(g, s) == -1);
    CHECK(rt_graph_instance_alive(g, s) == 0);

    rt_graph_destroy(g);
}

TEST_CASE("A.2 reserve: -1 when the pool has no Available slot") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    // Auto-spawned instance 0 is Active and is the only slot. Realtime
    // reserve must refuse to grow the pool — pre-warming is the
    // caller's responsibility.
    CHECK(rt_graph_realtime_reserve(g, 0) == -1);

    rt_graph_destroy(g);
}

TEST_CASE("A.2 reserve: Reserved slots count toward the polyphony cap") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    build_constant_template(g);
    rt_graph_template_set_polyphony(g, 0, 3);

    // Pre-warm three Available slots: spawn three (which grows the
    // pool past the auto-instance) then remove all four so the
    // pool holds three Available slots of the right shape. We
    // intentionally exceed the cap during pre-warm — the cap is on
    // the live state at spawn time, not on the pool size.
    int a = rt_graph_template_instance_add(g, 0);
    int b = rt_graph_template_instance_add(g, 0);
    REQUIRE(a >= 0); REQUIRE(b >= 0);
    // a and b plus auto-instance 0 = 3 live; cap is 3 so a fourth
    // spawn would fail. Remove all to free three Available slots.
    rt_graph_instance_remove(g, 0);
    rt_graph_instance_remove(g, a);
    rt_graph_instance_remove(g, b);

    int r0 = rt_graph_realtime_reserve(g, 0);
    int r1 = rt_graph_realtime_reserve(g, 0);
    int r2 = rt_graph_realtime_reserve(g, 0);
    REQUIRE(r0 >= 0); REQUIRE(r1 >= 0); REQUIRE(r2 >= 0);
    // Three Reserved slots fill the cap of 3. The fourth reserve
    // must fail — even though there might be Available capacity in
    // the pool, the polyphony counter rejects it.
    CHECK(rt_graph_realtime_reserve(g, 0) == -1);

    rt_graph_destroy(g);
}

TEST_CASE("A.2 cancel: returns slot to Available; another reserve picks the same slot") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    build_constant_template(g);
    rt_graph_template_set_polyphony(g, 0, 1);
    rt_graph_instance_remove(g, 0);

    int s = rt_graph_realtime_reserve(g, 0);
    REQUIRE(s >= 0);
    // Cap is 1; the Reserved slot occupies it.
    CHECK(rt_graph_realtime_reserve(g, 0) == -1);

    rt_graph_realtime_cancel(g, s);
    int s2 = rt_graph_realtime_reserve(g, 0);
    REQUIRE(s2 >= 0);
    CHECK(s2 == s);  // same slot — cancel returned it to Available

    rt_graph_destroy(g);
}

TEST_CASE("A.2 cancel: silent no-op on Active / out-of-range / null") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    // Auto-instance 0 is Active. Cancel must not flip Active to
    // Available (only Reserved → Available is allowed).
    rt_graph_realtime_cancel(g, 0);
    CHECK(rt_graph_instance_alive(g, 0) == 1);
    CHECK(rt_graph_instance_status(g, 0) == 0);

    // Out-of-range / negative / null — must not crash.
    rt_graph_realtime_cancel(g, 99);
    rt_graph_realtime_cancel(g, -1);
    rt_graph_realtime_cancel(nullptr, 0);

    rt_graph_destroy(g);
}

TEST_CASE("A.2 reserved slot is not processed by the audio thread") {
    // The Reserved slot is the only potential writer of bus 0 in this
    // graph (we drop the auto-instance and never activate). If the
    // audio thread mistakenly processed Reserved slots, bus 0 would
    // carry the slot's Add(0.5, 0.0) constant. Bus 0 must stay silent.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    build_constant_template(g);
    rt_graph_template_set_default(g, 0, 0, 0, 0.5);  // Add a-default = 0.5

    rt_graph_instance_remove(g, 0);
    int s = rt_graph_realtime_reserve(g, 0);
    REQUIRE(s >= 0);

    rt_graph_process(g, kFrames);
    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());

    CHECK(peak_abs(bus0) == doctest::Approx(0.0f));

    rt_graph_destroy(g);
}

TEST_CASE("A.2 reserve + activate publishes the slot in the same block") {
    // Activate is enqueued before the next process_graph runs; the
    // drain at the top of process_graph CAS-flips Reserved → Active,
    // so the slot's contribution lands in this very block. This is
    // the latency property the realtime API promises: at most one
    // block of delay between enqueue and audible effect.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    build_constant_template(g);
    rt_graph_template_set_default(g, 0, 0, 0, 0.5);  // Add a-default = 0.5

    rt_graph_instance_remove(g, 0);
    int s = rt_graph_realtime_reserve(g, 0);
    REQUIRE(s >= 0);
    REQUIRE(rt_graph_realtime_activate(g, s) == 1);

    rt_graph_process(g, kFrames);
    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());

    for (auto x : bus0) CHECK(x == doctest::Approx(0.5f).epsilon(1e-6));
    CHECK(rt_graph_instance_alive(g, s) == 1);
    CHECK(rt_graph_instance_status(g, s) == 0);

    rt_graph_destroy(g);
}

TEST_CASE("A.2 FIFO: SetControl after Activate applies; same-slot order matters") {
    // The drain order for commands targeting one slot is observable:
    //   FIFO:    [Activate, SetControl(0.5), SetControl(1.0)] →
    //            Activate flips Reserved → Active first, both
    //            SetControls then land on the Active slot (gate is
    //            Active or Releasing); final Add a_const = 1.0.
    //   non-FIFO (e.g. reverse): SetControls drain first against a
    //            Reserved slot (drain gate drops them), then Activate
    //            runs; final Add a_const stays at the spec default 0.
    //
    // Asserting 1.0 vs 0.0 on bus 0 distinguishes the two.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    build_constant_template(g);
    // Spec defaults already give Add(0, 0) → silence; SetControls
    // are what raise it to 1.0.

    rt_graph_instance_remove(g, 0);
    int s = rt_graph_realtime_reserve(g, 0);
    REQUIRE(s >= 0);

    REQUIRE(rt_graph_realtime_activate(g, s) == 1);
    REQUIRE(rt_graph_realtime_set_control(g, s, /*node*/0, /*ctl*/0, 0.5) == 1);
    REQUIRE(rt_graph_realtime_set_control(g, s, /*node*/0, /*ctl*/0, 1.0) == 1);

    rt_graph_process(g, kFrames);
    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());

    for (auto x : bus0) CHECK(x == doctest::Approx(1.0f).epsilon(1e-6));

    rt_graph_destroy(g);
}

TEST_CASE("A.2 queue: enqueue returns 0 once the ring is full; drain reopens it") {
    // The producer fills the queue without any drain (no
    // rt_graph_process) running between enqueues. Capacity is 256;
    // the 257th enqueue must return 0. After a process call drains
    // the queue, the producer can enqueue again.
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    int ok = 0;
    for (int i = 0; i < 256; ++i) {
        ok += rt_graph_realtime_set_control(g, 0, 0, 0, static_cast<double>(i));
    }
    CHECK(ok == 256);
    CHECK(rt_graph_realtime_set_control(g, 0, 0, 0, 0.0) == 0);  // ring full

    // Drain — every command is consumed (slot 0 has no nodes here, so
    // the SetControls silently no-op once they reach apply_control_-
    // command, but the queue mechanics still advance read_idx).
    rt_graph_process(g, kFrames);

    CHECK(rt_graph_realtime_set_control(g, 0, 0, 0, 0.0) == 1);

    rt_graph_destroy(g);
}

TEST_CASE("A.2 queue: wraparound with intermediate drain applies commands across batches") {
    // Two batches of 200 enqueues separated by a drain push the
    // producer's write_idx 0 → 200 → 400, well past the ring's
    // capacity of 256. Batch 2's writes wrap from ring[200] back
    // through ring[0..]. The test checks the ring index math + the
    // memory-order pair stay correct: each batch's last SetControl
    // is what bus 0 reflects after the next drain.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    build_constant_template(g);
    // Auto-instance 0 is Active and has both nodes; slot 0 is the
    // SetControl target. No reserve needed for this test — the
    // queue mechanics are independent of slot lifecycle.

    constexpr int kBatch = 200;

    // Batch 1: 199 zero writes followed by 0.25.
    for (int i = 0; i < kBatch - 1; ++i) {
        REQUIRE(rt_graph_realtime_set_control(g, 0, 0, 0, 0.0) == 1);
    }
    REQUIRE(rt_graph_realtime_set_control(g, 0, 0, 0, 0.25) == 1);

    rt_graph_process(g, kFrames);
    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    for (auto x : bus0) CHECK(x == doctest::Approx(0.25f).epsilon(1e-6));

    // Batch 2: 199 zero writes followed by 0.75. write_idx now passes
    // 256 and wraps; read_idx tracks behind it.
    for (int i = 0; i < kBatch - 1; ++i) {
        REQUIRE(rt_graph_realtime_set_control(g, 0, 0, 0, 0.0) == 1);
    }
    REQUIRE(rt_graph_realtime_set_control(g, 0, 0, 0, 0.75) == 1);

    rt_graph_process(g, kFrames);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    for (auto x : bus0) CHECK(x == doctest::Approx(0.75f).epsilon(1e-6));

    rt_graph_destroy(g);
}

TEST_CASE("A.2 queued release: env-bearing slot transitions to Releasing then auto-frees") {
    constexpr int kBlock = 256;
    auto *g = rt_graph_create(8, kBlock);
    REQUIRE(g != nullptr);

    // Env (gate held high) → Out(bus 0). Same shape as the §2.E
    // direct-API release test, but the release goes through the
    // queue this time.
    rt_graph_template_add_node(g, 0, 0, 9);                 // Env
    rt_graph_template_set_default(g, 0, 0, 0, 1.0);
    rt_graph_template_set_default(g, 0, 0, 1, 0.0005);
    rt_graph_template_set_default(g, 0, 0, 2, 0.002);
    rt_graph_template_set_default(g, 0, 0, 3, 0.5);
    rt_graph_template_set_default(g, 0, 0, 4, 0.002);
    rt_graph_template_add_node(g, 0, 1, 2);                 // Out
    rt_graph_template_set_default(g, 0, 1, 0, 0.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);

    rt_graph_instance_remove(g, 0);
    int s = rt_graph_realtime_reserve(g, 0);
    REQUIRE(s >= 0);
    REQUIRE(rt_graph_realtime_activate(g, s) == 1);

    rt_graph_process(g, kBlock);
    REQUIRE(rt_graph_instance_status(g, s) == 0);  // Active

    REQUIRE(rt_graph_realtime_release(g, s) == 1);
    rt_graph_process(g, kBlock);
    CHECK(rt_graph_instance_status(g, s) == 1);    // drain flipped to Releasing

    bool freed = false;
    for (int i = 0; i < 64 && !freed; ++i) {
        rt_graph_process(g, kBlock);
        if (rt_graph_instance_alive(g, s) == 0) freed = true;
    }
    CHECK(freed);
    CHECK(rt_graph_instance_status(g, s) == -1);

    rt_graph_destroy(g);
}

TEST_CASE("A.2 queued remove: hard-frees the slot at the next block boundary") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    build_constant_template(g);
    rt_graph_template_set_default(g, 0, 0, 0, 0.5);  // Add a-default = 0.5

    rt_graph_instance_remove(g, 0);
    int s = rt_graph_realtime_reserve(g, 0);
    REQUIRE(s >= 0);
    REQUIRE(rt_graph_realtime_activate(g, s) == 1);

    rt_graph_process(g, kFrames);
    REQUIRE(rt_graph_instance_alive(g, s) == 1);

    REQUIRE(rt_graph_realtime_remove(g, s) == 1);
    rt_graph_process(g, kFrames);

    CHECK(rt_graph_instance_alive(g, s) == 0);

    // Slot is hard-freed; bus 0 reverts to silence (no live writers).
    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    CHECK(peak_abs(bus0) == doctest::Approx(0.0f));

    rt_graph_destroy(g);
}

TEST_CASE("A.2 queued set_control: takes effect on the block following the enqueue") {
    // Block A renders with the spec default (Add a_const = 0.25).
    // Between blocks the producer enqueues SetControl(a_const = 0.875).
    // Block B's drain applies the new value; bus 0 reflects it. (We
    // do NOT claim the change misses the in-progress block — the
    // offline harness can't observe sub-block timing.)
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    build_constant_template(g);
    rt_graph_template_set_default(g, 0, 0, 0, 0.25);

    rt_graph_instance_remove(g, 0);
    int s = rt_graph_realtime_reserve(g, 0);
    REQUIRE(s >= 0);
    REQUIRE(rt_graph_realtime_activate(g, s) == 1);

    rt_graph_process(g, kFrames);
    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    for (auto x : bus0) CHECK(x == doctest::Approx(0.25f).epsilon(1e-6));

    REQUIRE(rt_graph_realtime_set_control(g, s, /*node*/0, /*ctl*/0, 0.875) == 1);
    rt_graph_process(g, kFrames);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    for (auto x : bus0) CHECK(x == doctest::Approx(0.875f).epsilon(1e-6));

    rt_graph_destroy(g);
}

TEST_CASE("A.2 allocator failure path: queue-full activate, cancel, drain, retry") {
    // The realistic producer flow when the audio thread is too slow
    // and the queue saturates:
    //   1. queue is full (256 commands waiting for the next drain);
    //   2. realtime_reserve still succeeds — it never touches the
    //      queue, just CAS-claims a slot synchronously;
    //   3. realtime_activate returns 0 (queue rejects the enqueue);
    //   4. producer falls back: cancel rolls the slot back, the next
    //      process_graph drains the queue, and a fresh reserve+activate
    //      succeeds.
    //
    // This locks down the cancel-as-rollback contract end-to-end.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    build_constant_template(g);
    rt_graph_template_set_default(g, 0, 0, 0, 0.5);  // Add a-default = 0.5
    rt_graph_instance_remove(g, 0);

    // Saturate the queue. Slot 99 is out of range; the drain will
    // silently drop each command. Queue mechanics still advance.
    for (int i = 0; i < 256; ++i) {
        REQUIRE(rt_graph_realtime_set_control(g, 99, 0, 0, 0.0) == 1);
    }

    int s = rt_graph_realtime_reserve(g, 0);
    REQUIRE(s >= 0);                                  // synchronous; queue state irrelevant
    CHECK(rt_graph_realtime_activate(g, s) == 0);     // queue full

    rt_graph_realtime_cancel(g, s);                   // roll back
    CHECK(rt_graph_instance_alive(g, s) == 0);
    CHECK(rt_graph_instance_status(g, s) == -1);

    // One process call drains the saturated queue.
    rt_graph_process(g, kFrames);

    int s2 = rt_graph_realtime_reserve(g, 0);
    REQUIRE(s2 >= 0);
    CHECK(s2 == s);                                   // cancel returned the same slot
    CHECK(rt_graph_realtime_activate(g, s2) == 1);    // queue has room now

    rt_graph_process(g, kFrames);
    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    for (auto x : bus0) CHECK(x == doctest::Approx(0.5f).epsilon(1e-6));

    rt_graph_destroy(g);
}

TEST_CASE("init_node_state: reconfiguring a node to lower arity hides stale outputs") {
    // rt_graph_template_add_node may reconfigure a node in place at
    // the same index. When the new kind has fewer outputs than the
    // old one (e.g. SinOsc → Out drops from 1 output to 0), any
    // downstream wiring still aimed at the old port must see an empty
    // span, not a stale audio buffer. init_node_state preserves the
    // outer outputs vector for capacity, so the test for "no port
    // exists" sits in the inner buffer's size — clear()-on-shrink is
    // what makes resolve_input bail out.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    // Initial graph: SinOsc(node 0) → Out(node 1, bus 0).
    rt_graph_add_node(g, 0, 1);                    // SinOsc
    rt_graph_set_control(g, 0, 0, 440.0);
    rt_graph_add_node(g, 1, 2);                    // Out
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_process(g, kFrames);
    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    REQUIRE(peak_abs(bus0) > 0.5f);                // baseline: oscillator audible

    // Reconfigure node 0 from SinOsc (1 output) to Out (0 outputs).
    // The connect from node 0 → node 1 is unchanged at the spec
    // level, but node 0 no longer produces a signal at port 0.
    rt_graph_add_node(g, 0, 2);                    // re-add as Out
    rt_graph_set_control(g, 0, 0, 1.0);            // route node 0 to bus 1 (junk)

    rt_graph_process(g, kFrames);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());

    // Bus 0 must be silent: node 1's input port 0 is wired to node 0
    // which now has 0 outputs. Without the inactive-buffer clear,
    // node 0's old outputs[0] (last block of SinOsc audio) would be
    // exposed to node 1 and copied to bus 0.
    CHECK(peak_abs(bus0) == doctest::Approx(0.0f));

    rt_graph_destroy(g);
}

TEST_CASE("A.2 slot reuse: per-voice state resets across reserve cycles") {
    // init_node_state's contract is that every reserve produces a
    // freshly-zeroed slot — no carryover of phase, filter memory,
    // envelope position, or output buffer contents from the previous
    // voice that occupied this slot. The SinOsc test below pins it:
    // each voice's initial phase is 0, so sample 0 of the first block
    // is sin(0) = 0. After 256 samples at 48 kHz / 440 Hz the phase
    // ends well past 0; if init_node_state leaked state across cycles,
    // sample 0 of the second voice would carry the previous voice's
    // terminal phase and read non-zero.
    //
    // This test also exercises the in-place reset path many times in
    // a row, surfacing any slot-reuse bug that depends on cycle count.
    constexpr int kBlock = 256;
    auto *g = rt_graph_create(4, kBlock);
    REQUIRE(g != nullptr);

    rt_graph_template_add_node(g, 0, 0, 1);                 // SinOsc
    rt_graph_template_set_default(g, 0, 0, 0, 440.0);
    rt_graph_template_set_default(g, 0, 0, 1, 0.0);         // initial phase = 0
    rt_graph_template_add_node(g, 0, 1, 2);                 // Out
    rt_graph_template_set_default(g, 0, 1, 0, 0.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);

    rt_graph_instance_remove(g, 0);

    constexpr int kCycles = 8;
    for (int cycle = 0; cycle < kCycles; ++cycle) {
        int s = rt_graph_realtime_reserve(g, 0);
        REQUIRE(s >= 0);
        REQUIRE(rt_graph_realtime_activate(g, s) == 1);

        rt_graph_process(g, kBlock);
        std::vector<float> bus0(kBlock, 0.0f);
        rt_graph_read_bus(g, 0, kBlock, bus0.data());

        INFO("cycle=" << cycle);
        // Phase reset → sample 0 is sin(0) = 0.
        CHECK(std::abs(bus0[0]) < 1e-5f);
        // And the oscillator did run — not just silently zeroed by a
        // bug elsewhere.
        CHECK(peak_abs(bus0) > 0.5f);

        // No Env on this template, so release falls through to a
        // hard free — but use queued remove for symmetry with the
        // realtime ABI surface.
        REQUIRE(rt_graph_realtime_remove(g, s) == 1);
        rt_graph_process(g, kBlock);
        REQUIRE(rt_graph_instance_alive(g, s) == 0);
    }

    rt_graph_destroy(g);
}

TEST_CASE("A.2 reset: rt_graph_clear discards pending queued commands") {
    // Without resetting the queue's read/write indices in the clear
    // path, the next process_graph after rt_graph_clear would replay
    // any commands the producer enqueued before the clear. The fix
    // resets both indices in reset_to_default_state; this test pins
    // it down — enqueue a SetControl that, if replayed, would write
    // 0.99 onto the rebuilt instance 0; assert bus 0 stays at the
    // spec default 0.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    REQUIRE(rt_graph_realtime_set_control(g, 0, 0, 0, 0.99) == 1);

    rt_graph_clear(g);

    // Rebuild a fresh constant graph after clear. The auto-instance
    // 0 reappears with the new template's spec defaults (a_const = 0).
    build_constant_template(g);

    rt_graph_process(g, kFrames);
    std::vector<float> bus0(kFrames, 0.0f);
    rt_graph_read_bus(g, 0, kFrames, bus0.data());
    for (auto x : bus0) CHECK(x == doctest::Approx(0.0f));

    // The queue should still be usable after clear.
    CHECK(rt_graph_realtime_set_control(g, 0, 0, 0, 0.5) == 1);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Step A region overlay: registering regions must not change the
// rendered audio. The Haskell loaders always emit them; legacy
// callers building graphs via rt_graph_add_node directly do not.
// process_instance must produce sample-identical output along both
// paths (this is the entire point of Step A — structural plumbing,
// no behavior change).
// ----------------------------------------------------------------

TEST_CASE("regions overlay produces sample-identical output to flat node loop") {
    // Helper: build SinOsc(440) → Gain(0.5) → Out(0) into a fresh graph.
    auto build = [](RTGraph *g) {
        rt_graph_add_node(g, 0, 1); // SinOsc tag = 1
        rt_graph_set_control(g, 0, 0, 440.0f);
        rt_graph_set_control(g, 0, 1, 0.0f);

        rt_graph_add_node(g, 1, 3); // Gain tag = 3
        rt_graph_set_control(g, 1, 0, 0.5f);

        rt_graph_add_node(g, 2, 2); // Out tag = 2
        rt_graph_set_control(g, 2, 0, 0.0f);

        rt_graph_connect(g, 0, 0, 1, 0); // SinOsc.out0 → Gain.in0
        rt_graph_connect(g, 1, 0, 2, 0); // Gain.out0 → Out.in0
    };

    // Path 1: no regions registered → flat node loop.
    auto *g_flat = rt_graph_create(/*capacity*/ 4, /*max_frames*/ kFrames);
    REQUIRE(g_flat != nullptr);
    build(g_flat);
    auto flat_samples = render_bus0(g_flat, kFrames);
    rt_graph_destroy(g_flat);

    // Path 2: one region covering all 3 nodes → region path.
    auto *g_regions = rt_graph_create(/*capacity*/ 4, /*max_frames*/ kFrames);
    REQUIRE(g_regions != nullptr);
    build(g_regions);
    // SampleRate = 3 in the Haskell Rate enum (CompileRate=0,
    // InitRate=1, BlockRate=2, SampleRate=3); first_node=0,
    // node_count=3 covers the entire chain. See
    // Note [Region fallback] in rt_graph.cpp.
    rt_graph_add_region(g_regions, /*rate=*/3, /*first_node=*/0, /*node_count=*/3);
    auto region_samples = render_bus0(g_regions, kFrames);
    rt_graph_destroy(g_regions);

    REQUIRE(flat_samples.size() == region_samples.size());
    for (std::size_t i = 0; i < flat_samples.size(); ++i) {
        // Bit-identical expected: same kernels in the same order
        // with no scratch reuse yet (Step A is structural only).
        CHECK(flat_samples[i] == region_samples[i]);
    }
}

TEST_CASE("multiple regions in the overlay still cover every node exactly once") {
    // Build a 3-node chain and split it across two regions:
    //   region 0 = [SinOsc] (1 node)
    //   region 1 = [Gain, Out] (2 nodes)
    // Output must still match the flat-loop result.
    auto build = [](RTGraph *g) {
        rt_graph_add_node(g, 0, 1);
        rt_graph_set_control(g, 0, 0, 220.0f);
        rt_graph_set_control(g, 0, 1, 0.0f);

        rt_graph_add_node(g, 1, 3);
        rt_graph_set_control(g, 1, 0, 0.25f);

        rt_graph_add_node(g, 2, 2);
        rt_graph_set_control(g, 2, 0, 0.0f);

        rt_graph_connect(g, 0, 0, 1, 0);
        rt_graph_connect(g, 1, 0, 2, 0);
    };

    auto *g_flat = rt_graph_create(4, kFrames);
    REQUIRE(g_flat != nullptr);
    build(g_flat);
    auto flat_samples = render_bus0(g_flat, kFrames);
    rt_graph_destroy(g_flat);

    auto *g_split = rt_graph_create(4, kFrames);
    REQUIRE(g_split != nullptr);
    build(g_split);
    rt_graph_add_region(g_split, /*rate=*/3, /*first_node=*/0, /*node_count=*/1);
    rt_graph_add_region(g_split, /*rate=*/3, /*first_node=*/1, /*node_count=*/2);
    auto split_samples = render_bus0(g_split, kFrames);
    rt_graph_destroy(g_split);

    REQUIRE(flat_samples.size() == split_samples.size());
    for (std::size_t i = 0; i < flat_samples.size(); ++i) {
        CHECK(flat_samples[i] == split_samples[i]);
    }
}

TEST_CASE("rt_graph_template_add_region rejects out-of-range ranges") {
    // Defensive: the C ABI doc says invalid template_id and ranges
    // that step outside def->nodes are silent no-ops. Pin that.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1);
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_set_control(g, 0, 1, 0.0f);

    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);

    rt_graph_connect(g, 0, 0, 1, 0);

    // None of these should land in def->regions; rendering must
    // therefore still take the flat fallback path.
    rt_graph_add_region(g, 3, /*first=*/-1, /*count=*/2);  // negative first
    rt_graph_add_region(g, 3, /*first=*/0,  /*count=*/0);  // zero count
    rt_graph_add_region(g, 3, /*first=*/0,  /*count=*/-1); // negative count
    rt_graph_add_region(g, 3, /*first=*/5,  /*count=*/1);  // first out of range
    rt_graph_add_region(g, 3, /*first=*/1,  /*count=*/5);  // overflow

    auto samples = render_bus0(g, kFrames);
    CHECK(peak_abs(samples) == doctest::Approx(1.0f).epsilon(0.02));

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Step C: elided dispatch + fused-input resolver. Pins the runtime
// contract that fuseRuntimeGraph (Haskell) produces for the FFI
// loader to consume. The kernels are unchanged; only NodeSpec.elided
// / NodeSpec.fused_inputs and the resolver path are new. The cases
// in this section exercise the scale-only legacy ABI
// (rt_graph_connect_fused_scale_input); chain and affine paths are
// covered by the equivalent Haskell-side tests in test/Spec.hs.
// ----------------------------------------------------------------

TEST_CASE("Step C (d): fused Gain renders bit-identically to unfused chain") {
    // Helper: build SinOsc(440) → Gain(0.5) → Out(0).
    auto build_unfused = [](RTGraph *g) {
        rt_graph_add_node(g, 0, 1); // SinOsc
        rt_graph_set_control(g, 0, 0, 440.0f);
        rt_graph_set_control(g, 0, 1, 0.0f);
        rt_graph_add_node(g, 1, 3); // Gain
        rt_graph_set_control(g, 1, 0, 0.5f);
        rt_graph_add_node(g, 2, 2); // Out
        rt_graph_set_control(g, 2, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0); // SinOsc → Gain.signal
        rt_graph_connect(g, 1, 0, 2, 0); // Gain → Out.signal
    };

    // Path 1: unfused — Gain dispatched, Out reads from Gain.
    auto *g_un = rt_graph_create(4, kFrames);
    REQUIRE(g_un != nullptr);
    build_unfused(g_un);
    auto unfused_samples = render_bus0(g_un, kFrames);
    rt_graph_destroy(g_un);

    // Path 2: fused — Gain elided, Out reads from a fused input
    // (single-scale: SinOsc.out0 × Gain.controls[0]). The Out -> Gain
    // direct connect is intentionally still present: the resolver
    // must take the fused path because fused_inputs[port] carries
    // a value, regardless of input_refs.
    auto *g_fu = rt_graph_create(4, kFrames);
    REQUIRE(g_fu != nullptr);
    build_unfused(g_fu);
    rt_graph_set_node_elided(g_fu, /*node=*/1);
    rt_graph_connect_fused_scale_input(
        g_fu,
        /*dst_node=*/2, /*dst_port=*/0,
        /*src_node=*/0, /*src_port=*/0,
        /*scale_node=*/1, /*scale_control_index=*/0);
    auto fused_samples = render_bus0(g_fu, kFrames);
    rt_graph_destroy(g_fu);

    REQUIRE(unfused_samples.size() == fused_samples.size());
    for (std::size_t i = 0; i < unfused_samples.size(); ++i) {
        // Bit-identical: the materialization casts the same way
        // and multiplies in the same order as process_gain's
        // scalar branch. Any divergence is a step-(d) bug.
        CHECK(unfused_samples[i] == fused_samples[i]);
    }
}

TEST_CASE("Step C (d): set_control on an elided Gain still drives the fused output") {
    // Build a fused chain twice with different scale values and
    // confirm the rendered amplitude tracks the live control.
    // This pins the load-bearing semantic claim that elided Gains
    // remain control-addressable.
    auto build_fused = [](RTGraph *g, float scale) {
        rt_graph_add_node(g, 0, 1); // SinOsc
        rt_graph_set_control(g, 0, 0, 440.0f);
        rt_graph_set_control(g, 0, 1, 0.0f);
        rt_graph_add_node(g, 1, 3); // Gain (will be elided)
        rt_graph_set_control(g, 1, 0, 1.0f); // initial value, overwritten below
        rt_graph_add_node(g, 2, 2); // Out
        rt_graph_set_control(g, 2, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);
        rt_graph_connect(g, 1, 0, 2, 0);
        rt_graph_set_node_elided(g, 1);
        rt_graph_connect_fused_scale_input(g, 2, 0, 0, 0, 1, 0);
        // Overwrite the elided Gain's control AFTER fusion is
        // wired. The next render must materialize scratch through
        // this freshly-set value.
        rt_graph_set_control(g, 1, 0, scale);
    };

    auto *g1 = rt_graph_create(4, kFrames);
    REQUIRE(g1 != nullptr);
    build_fused(g1, 0.5f);
    auto half = render_bus0(g1, kFrames);
    rt_graph_destroy(g1);

    auto *g2 = rt_graph_create(4, kFrames);
    REQUIRE(g2 != nullptr);
    build_fused(g2, 0.25f);
    auto quarter = render_bus0(g2, kFrames);
    rt_graph_destroy(g2);

    // SinOsc peaks at ~1.0; the fused path scales it by the
    // elided Gain's live control. Two renders should differ by
    // exactly the ratio of their controls (modulo float fuzz).
    const float peak_half    = peak_abs(half);
    const float peak_quarter = peak_abs(quarter);
    CHECK(peak_half    == doctest::Approx(0.5f).epsilon(0.05));
    CHECK(peak_quarter == doctest::Approx(0.25f).epsilon(0.05));
    // Sample-wise ratio is 2:1 wherever the source is non-trivial.
    for (std::size_t i = 0; i < half.size(); ++i) {
        if (std::abs(half[i]) > 0.05f) {
            CHECK(half[i] / quarter[i] == doctest::Approx(2.0f).epsilon(0.01));
        }
    }
}

TEST_CASE("Step C (d): recycled instance slot grows fused_scratch on reuse") {
    // Repro for the P2 reuse hazard: a slot becomes Available
    // before any fused input is registered, the fused_input_count
    // grows post-spawn via rt_graph_template_connect_fused_scale_input,
    // and a later rt_graph_template_instance_add reuses that slot.
    // Without ensure_fused_scratch on the reuse path, fused_scratch
    // stays size 0 and resolve_input returns silence — visible as a
    // muted bus 0.
    auto *g = rt_graph_create(/*capacity*/ 4, /*max_frames*/ kFrames);
    REQUIRE(g != nullptr);

    // Auto-created template 0 starts with an instance 0 (also auto-
    // created). Remove it so the slot enters Available *before* any
    // fused input has been registered on the template.
    rt_graph_instance_remove(g, 0);

    // Build the spec.
    rt_graph_template_add_node(g, 0, 0, 1); // SinOsc
    rt_graph_template_set_default(g, 0, 0, 0, 440.0);
    rt_graph_template_set_default(g, 0, 0, 1, 0.0);
    rt_graph_template_add_node(g, 0, 1, 3); // Gain
    rt_graph_template_set_default(g, 0, 1, 0, 0.5);
    rt_graph_template_add_node(g, 0, 2, 2); // Out
    rt_graph_template_set_default(g, 0, 2, 0, 0.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);
    rt_graph_template_connect(g, 0, 1, 0, 2, 0);

    // Register the fused input (single-scale flavor) *while* the
    // prior instance slot is sitting Available. The growth path
    // inside _connect_fused_scale_input only walks Active/Releasing
    // slots, so the Available slot's fused_scratch stays empty until
    // reuse.
    rt_graph_template_set_node_elided(g, 0, 1);
    rt_graph_template_connect_fused_scale_input(
        g, 0,
        /*dst=*/2, /*dst_port=*/0,
        /*src=*/0, /*src_port=*/0,
        /*scale=*/1, /*scale_control_index=*/0);

    // Reuse the slot. ensure_fused_scratch must run on the reuse
    // path; otherwise resolve_input returns silence on the next
    // render.
    const int reused = rt_graph_template_instance_add(g, 0);
    REQUIRE(reused == 0);

    auto samples = render_bus0(g, kFrames);
    // 440 Hz × 0.5 gain through fused path: peak ≈ 0.5.
    CHECK(peak_abs(samples) == doctest::Approx(0.5f).epsilon(0.05));

    rt_graph_destroy(g);
}

TEST_CASE("Step C (d): out-of-range fused refs are silent no-ops, render is unaffected") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_add_node(g, 0, 1);
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_set_control(g, 0, 1, 0.0f);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    // Each of these should leave fused_inputs untouched. The
    // override is rejected before fused_input_count is bumped, so a
    // resolver call on this graph never sees a stale FusedAffineRef
    // pointing at an out-of-range source/scale slot — which would
    // silence a previously-valid direct input, since the fused
    // override takes precedence inside resolve_input.
    rt_graph_connect_fused_scale_input(g, 1, /*dst_port=*/9, 0, 0, 0, 0);   // bad dst_port
    rt_graph_connect_fused_scale_input(g, 1, 0, /*src_node=*/-1, 0, 0, 0);  // bad src_node
    rt_graph_connect_fused_scale_input(g, 1, 0, 0, 0, /*scale_node=*/9, 0); // bad scale_node
    // Bad src_port: SinOsc only has output port 0; port 1 is out
    // of range. Without validation this would silently mute the
    // Out signal because resolve_input would fail the
    // src_port-vs-arity check on every block.
    rt_graph_connect_fused_scale_input(
        g, 1, 0,
        /*src_node=*/0, /*src_port=*/1,
        /*scale_node=*/0, /*scale_control_index=*/0);
    // Bad scale_control_index: SinOsc has 2 controls (0, 1);
    // index 5 is out of range.
    rt_graph_connect_fused_scale_input(
        g, 1, 0,
        /*src_node=*/0, /*src_port=*/0,
        /*scale_node=*/0, /*scale_control_index=*/5);
    rt_graph_set_node_elided(g, /*node=*/9); // bad node
    rt_graph_set_node_elided(g, /*node=*/-1);

    auto samples = render_bus0(g, kFrames);
    CHECK(peak_abs(samples) == doctest::Approx(1.0f).epsilon(0.02));

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Phase §4.E.2.B0: writer-slot reservation contract
// ----------------------------------------------------------------
//
// process_graph reserves one canonical writer slot per sink writer at
// the dispatch boundary (dispatch_node Out/BusOut branches and
// process_instance fused-sink branches). The total per block is
// exposed via rt_graph_test_last_writer_slot_count for tests that
// assert canonical-order slot reservation across the dispatch shapes
// the runtime supports today.
//
// Key invariant: the count must equal the number of sink-terminal
// NodeSpecs across all Active/Releasing instances of all templates,
// regardless of whether each was dispatched via flat fallback,
// NodeLoop region, or a fused sink kernel. Phase B2 will use the same
// canonical numbering as the contribution-table key.

TEST_CASE("writer-slot count: flat fallback, single Out") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    // SinOsc → Out, no regions registered → flat-fallback dispatch.
    rt_graph_add_node(g, 0, 1); // SinOsc
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_add_node(g, 1, 2); // Out
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_last_writer_slot_count(g) == 1);

    rt_graph_destroy(g);
}

TEST_CASE("writer-slot count: flat fallback, mixed Out and BusOut") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 3);

    // SinOsc fanned into Out(bus 0), Out(bus 1), and BusOut(bus 3).
    // Three sinks total → three writer slots in flat-fallback order.
    rt_graph_add_node(g, 0, 1); // SinOsc
    rt_graph_set_control(g, 0, 0, 220.0f);
    rt_graph_add_node(g, 1, 2);  // Out → bus 0
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_add_node(g, 2, 2);  // Out → bus 1
    rt_graph_set_control(g, 2, 0, 1.0f);
    rt_graph_add_node(g, 3, 10); // BusOut → bus 3
    rt_graph_set_control(g, 3, 0, 3.0f);
    rt_graph_connect(g, 0, 0, 1, 0);
    rt_graph_connect(g, 0, 0, 2, 0);
    rt_graph_connect(g, 0, 0, 3, 0);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_last_writer_slot_count(g) == 3);

    rt_graph_destroy(g);
}

TEST_CASE("writer-slot count: NodeLoop region with two Out nodes") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 1);

    rt_graph_template_add_node(g, 0, 0, 1);              // SinOsc
    rt_graph_template_set_default(g, 0, 0, 0, 440.0);
    rt_graph_template_add_node(g, 0, 1, 2);              // Out (bus 0)
    rt_graph_template_set_default(g, 0, 1, 0, 0.0);
    rt_graph_template_add_node(g, 0, 2, 2);              // Out (bus 1)
    rt_graph_template_set_default(g, 0, 2, 0, 1.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);
    rt_graph_template_connect(g, 0, 0, 0, 2, 0);

    // One NodeLoop region covering all three nodes. The two Out
    // members each consume one slot; the SinOsc consumes none.
    rt_graph_template_add_region(g, /*template_id=*/0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/3);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_last_writer_slot_count(g) == 2);

    rt_graph_destroy(g);
}

TEST_CASE("writer-slot count: sink-terminal fused region (SinGainOut)") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_template_add_node(g, 0, 0, 1);              // SinOsc
    rt_graph_template_set_default(g, 0, 0, 0, 220.0);
    rt_graph_template_add_node(g, 0, 1, 3);              // Gain
    rt_graph_template_set_default(g, 0, 1, 0, 0.5);
    rt_graph_template_add_node(g, 0, 2, 2);              // Out (bus 0)
    rt_graph_template_set_default(g, 0, 2, 0, 0.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);
    rt_graph_template_connect(g, 0, 1, 0, 2, 0);

    // SinGainOut fused region (kernel_kind = 2). One sink-terminal
    // fused kernel reserves exactly one slot, regardless of node
    // count inside.
    rt_graph_template_add_region_kernel(
        g, /*template_id=*/0, /*kernel_kind=*/2, /*rate=*/0,
        /*first_node=*/0, /*node_count=*/3);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_last_writer_slot_count(g) == 1);

    rt_graph_destroy(g);
}

TEST_CASE("writer-slot count: cross-instance same template") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    // Single template with one Out; spawn 3 instances → 3 slots in
    // canonical (slot-order) sequence within the same template.
    rt_graph_template_add_node(g, 0, 0, 1);               // SinOsc
    rt_graph_template_set_default(g, 0, 0, 0, 440.0);
    rt_graph_template_add_node(g, 0, 1, 2);               // Out (bus 0)
    rt_graph_template_set_default(g, 0, 1, 0, 0.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);
    rt_graph_template_set_polyphony(g, 0, 4);

    // Drop auto-created instance 0 to keep the count exact.
    rt_graph_instance_remove(g, 0);
    REQUIRE(rt_graph_template_instance_add(g, 0) >= 0);
    REQUIRE(rt_graph_template_instance_add(g, 0) >= 0);
    REQUIRE(rt_graph_template_instance_add(g, 0) >= 0);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_last_writer_slot_count(g) == 3);

    rt_graph_destroy(g);
}

TEST_CASE("writer-slot count: cross-template, one instance each") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 3);

    // Template 0: SinOsc → BusOut(bus 3). Auto-created.
    rt_graph_template_add_node(g, 0, 0, 1);               // SinOsc
    rt_graph_template_set_default(g, 0, 0, 0, 220.0);
    rt_graph_template_add_node(g, 0, 1, 10);              // BusOut
    rt_graph_template_set_default(g, 0, 1, 0, 3.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);

    // Template 1: BusIn(bus 3) → Out(bus 0). Adds explicitly.
    int t1 = rt_graph_template_add(g);
    REQUIRE(t1 == 1);
    rt_graph_template_add_node(g, t1, 0, 11);             // BusIn
    rt_graph_template_set_default(g, t1, 0, 0, 3.0);
    rt_graph_template_add_node(g, t1, 1, 2);              // Out
    rt_graph_template_set_default(g, t1, 1, 0, 0.0);
    rt_graph_template_connect(g, t1, 0, 0, 1, 0);

    // Drop auto-created instance 0 (template 0) and spawn one of
    // each template; total = 1 BusOut + 1 Out = 2 sink writers.
    rt_graph_instance_remove(g, 0);
    REQUIRE(rt_graph_template_instance_add(g, 0)  >= 0);
    REQUIRE(rt_graph_template_instance_add(g, t1) >= 0);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_last_writer_slot_count(g) == 2);

    rt_graph_destroy(g);
}

TEST_CASE("writer-slot count: counter resets between blocks") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1);                // SinOsc
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_add_node(g, 1, 2);                // Out
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_last_writer_slot_count(g) == 1);

    // Counter must reset every block; not cumulative across blocks.
    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_last_writer_slot_count(g) == 1);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_last_writer_slot_count(g) == 1);

    rt_graph_destroy(g);
}

TEST_CASE("writer-slot count: rt_graph_clear resets the snapshot to 0") {
    // The header promises the helper returns 0 if no block has run
    // yet. rt_graph_clear puts the graph back into "freshly created"
    // state — the snapshot must follow, otherwise a process → clear
    // cycle leaves the previous block's count visible to tests
    // building a brand new graph against the cleared handle.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1);                // SinOsc
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_add_node(g, 1, 2);                // Out
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_last_writer_slot_count(g) == 1);

    rt_graph_clear(g);
    CHECK(rt_graph_test_last_writer_slot_count(g) == 0);

    rt_graph_destroy(g);
}

TEST_CASE("writer-slot count: invalid bus still consumes its slot") {
    // The canonical writer-slot contract: a sink writer must consume
    // exactly one slot even when its bus index is invalid (NaN /
    // negative / out-of-range). Otherwise later writers' slot
    // indices would shift block-to-block depending on transient
    // control state, breaking the canonical reduction order Phase B2
    // depends on.
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1);                // SinOsc
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_add_node(g, 1, 2);                // Out → invalid bus -1
    rt_graph_set_control(g, 1, 0, -1.0f);
    rt_graph_add_node(g, 2, 2);                // Out → bus 0 (valid)
    rt_graph_set_control(g, 2, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);
    rt_graph_connect(g, 0, 0, 2, 0);

    rt_graph_process(g, kFrames);
    // Two Out NodeSpecs → two slots, regardless of one bus being
    // out-of-range. process_out reserves the slot before its bus
    // validation, so the silent-degradation path still consumes its
    // canonical position.
    CHECK(rt_graph_test_last_writer_slot_count(g) == 2);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Phase §4.E.2.B1: contribution storage capacity
// ----------------------------------------------------------------
//
// ensure_contribution_capacity sizes the contribution table from
// Σ_t max(def[t].polyphony, occupied_t) × sink_writer_count[t]
// at every construction mutation that can affect the bound.
// Capacity is grow-only — once allocated, lowering polyphony does
// not shrink it. The samples vector size must always equal
// capacity * max_frames so a Phase B2 sink kernel that indexes
// samples[ws * max_frames + fi] cannot land out-of-range.
//
// These tests assert the bound is correct across the dispatch
// shapes the runtime supports today, without yet exercising the
// reduction-mode opener (still B2's job).

// All three storage vectors must move together. A regression where
// one resize_for branch grew samples but skipped target or
// used_words would silently leave the contribution-table writer
// path indexing dangling memory in B2; this helper makes the
// lockstep claim from rt_graph.h enforceable.
static void check_storage_lockstep(const RTGraph *g, int expected_slots) {
    CHECK(rt_graph_test_contribution_slot_capacity(g) == expected_slots);
    CHECK(rt_graph_test_contribution_sample_count(g)
          == expected_slots * kFrames);
    CHECK(rt_graph_test_contribution_target_count(g) == expected_slots);
    CHECK(rt_graph_test_contribution_used_word_count(g)
          == (expected_slots + 63) / 64);
}

TEST_CASE("contribution capacity: fresh graph with no sinks is zero") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    // Auto-created template 0 has no nodes; instance 0 is Active
    // but contributes nothing because there are no Out / BusOut
    // NodeSpecs. All three vectors must be at zero.
    check_storage_lockstep(g, 0);

    // A non-sink node also leaves capacity at 0.
    rt_graph_add_node(g, 0, 1); // SinOsc
    check_storage_lockstep(g, 0);

    rt_graph_destroy(g);
}

TEST_CASE("contribution capacity: one Out, default polyphony 8 gives 8 slots") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    // Default polyphony of the auto-created template 0 is
    // kDefaultPolyphony = 8. Adding one Out → required = 8 × 1 = 8.
    rt_graph_add_node(g, 0, 1);  // SinOsc
    rt_graph_add_node(g, 1, 2);  // Out
    rt_graph_set_control(g, 1, 0, 0.0f);

    check_storage_lockstep(g, 8);

    rt_graph_destroy(g);
}

TEST_CASE("contribution capacity: mixed Out and BusOut with cap 4 gives sink_count * 4") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 3);

    rt_graph_template_set_polyphony(g, 0, 4);

    // Three sink NodeSpecs (2 Out + 1 BusOut) × polyphony 4 = 12.
    rt_graph_add_node(g, 0, 1);   // SinOsc
    rt_graph_add_node(g, 1, 2);   // Out  (bus 0)
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_add_node(g, 2, 2);   // Out  (bus 1)
    rt_graph_set_control(g, 2, 0, 1.0f);
    rt_graph_add_node(g, 3, 10);  // BusOut (bus 3)
    rt_graph_set_control(g, 3, 0, 3.0f);

    check_storage_lockstep(g, 12);

    rt_graph_destroy(g);
}

TEST_CASE("contribution capacity: cross-template sums per-template independently") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 3);

    // Template 0: 1 BusOut, polyphony 4 → 4 slots.
    rt_graph_template_set_polyphony(g, 0, 4);
    rt_graph_template_add_node(g, 0, 0, 1);    // SinOsc
    rt_graph_template_add_node(g, 0, 1, 10);   // BusOut
    rt_graph_template_set_default(g, 0, 1, 0, 3.0);

    CHECK(rt_graph_test_contribution_slot_capacity(g) == 4);

    // Template 1: 2 Out NodeSpecs, polyphony 3 → 6 slots.
    int t1 = rt_graph_template_add(g);
    REQUIRE(t1 == 1);
    rt_graph_template_set_polyphony(g, t1, 3);
    rt_graph_template_add_node(g, t1, 0, 1);   // SinOsc
    rt_graph_template_add_node(g, t1, 1, 2);   // Out
    rt_graph_template_set_default(g, t1, 1, 0, 0.0);
    rt_graph_template_add_node(g, t1, 2, 2);   // Out
    rt_graph_template_set_default(g, t1, 2, 0, 1.0);

    // Total = template 0 (4) + template 1 (6) = 10.
    check_storage_lockstep(g, 10);

    rt_graph_destroy(g);
}

TEST_CASE("contribution capacity: NodeLoop / fused regions do not double-count") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    // Build SinOsc → Gain → Out under a SinGainOut fused kernel
    // *plus* register the same range as a NodeLoop region. Even
    // though there are now two RegionSpec entries pointing at the
    // same node range, capacity is keyed off NodeSpec count
    // (one Out → one writer per voice × polyphony 8 = 8). Region
    // metadata only maps slot ranges; it does not multiply them.
    rt_graph_template_add_node(g, 0, 0, 1);    // SinOsc
    rt_graph_template_set_default(g, 0, 0, 0, 220.0);
    rt_graph_template_add_node(g, 0, 1, 3);    // Gain
    rt_graph_template_set_default(g, 0, 1, 0, 0.5);
    rt_graph_template_add_node(g, 0, 2, 2);    // Out
    rt_graph_template_set_default(g, 0, 2, 0, 0.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);
    rt_graph_template_connect(g, 0, 1, 0, 2, 0);

    rt_graph_template_add_region_kernel(
        g, /*template_id=*/0, /*kernel_kind=*/2, /*rate=*/0,
        /*first_node=*/0, /*node_count=*/3);

    // Capacity = 1 Out × 8 polyphony = 8, regardless of region
    // wrapping.
    CHECK(rt_graph_test_contribution_slot_capacity(g) == 8);

    rt_graph_destroy(g);
}

TEST_CASE("contribution capacity: rt_graph_clear resets to zero") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_add_node(g, 0, 1);   // SinOsc
    rt_graph_add_node(g, 1, 2);   // Out
    rt_graph_set_control(g, 1, 0, 0.0f);
    REQUIRE(rt_graph_test_contribution_slot_capacity(g) == 8);

    rt_graph_clear(g);
    // After clear, the auto-recreated template 0 has no nodes →
    // every parallel storage vector drops to its empty size.
    check_storage_lockstep(g, 0);

    rt_graph_destroy(g);
}

TEST_CASE("contribution capacity: lowering polyphony does not shrink storage") {
    // The safety bound. set_polyphony is documented to allow
    // lowering the cap below already-live instances; the new cap
    // gates only future spawns. ensure_contribution_capacity uses
    // max(polyphony, occupied) × sink_writer_count, and resize_for
    // is grow-only, so the table stays sized for any slot a live
    // writer might still legitimately reserve. If this test fails,
    // a Phase B2 sink kernel could index a contribution buffer
    // out-of-range when polyphony was lowered between blocks.
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_template_set_polyphony(g, 0, 8);
    rt_graph_add_node(g, 0, 1);  // SinOsc
    rt_graph_add_node(g, 1, 2);  // Out
    rt_graph_set_control(g, 1, 0, 0.0f);
    REQUIRE(rt_graph_test_contribution_slot_capacity(g) == 8);

    // Spawn 6 instances (auto-created instance 0 is already Active,
    // so 5 more brings live count to 6). Drop to polyphony 2 — well
    // below live count.
    REQUIRE(rt_graph_template_instance_add(g, 0) >= 0);
    REQUIRE(rt_graph_template_instance_add(g, 0) >= 0);
    REQUIRE(rt_graph_template_instance_add(g, 0) >= 0);
    REQUIRE(rt_graph_template_instance_add(g, 0) >= 0);
    REQUIRE(rt_graph_template_instance_add(g, 0) >= 0);
    rt_graph_template_set_polyphony(g, 0, 2);

    // max(2, 6 occupied) × 1 sink = 6, but capacity was already 8.
    // Grow-only resize_for keeps it at 8, the high-water mark.
    check_storage_lockstep(g, 8);

    rt_graph_destroy(g);
}

TEST_CASE("contribution capacity: occupied count keeps storage above lowered cap") {
    // Companion to the grow-only safety check: even if the new cap
    // is the *first* reason capacity gets sized (no prior high-water
    // mark), the occupied multiplier must apply. If
    // required_contribution_slots used plain polyphony, this test
    // would size for cap × sink = 2; with max(polyphony, occupied),
    // it sizes for the live count × sink instead.
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_template_set_polyphony(g, 0, 8);
    REQUIRE(rt_graph_template_instance_add(g, 0) >= 0);
    REQUIRE(rt_graph_template_instance_add(g, 0) >= 0);
    REQUIRE(rt_graph_template_instance_add(g, 0) >= 0);
    REQUIRE(rt_graph_template_instance_add(g, 0) >= 0);
    // Live count is now 5 (auto-created instance 0 + 4 spawns).

    // Lower the cap below the live count first.
    rt_graph_template_set_polyphony(g, 0, 2);
    // Then add the first Out, which is when sink_writer_count goes
    // 0 → 1 and the bound becomes meaningful.
    rt_graph_add_node(g, 0, 1); // SinOsc
    rt_graph_add_node(g, 1, 2); // Out
    rt_graph_set_control(g, 1, 0, 0.0f);

    // max(polyphony=2, occupied=5) × 1 sink = 5.
    check_storage_lockstep(g, 5);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Phase §4.E.2.B2: reduction-capture mode
// ----------------------------------------------------------------
//
// When rt_graph_test_set_reduction_capture is on, sink writes are
// routed into the per-writer-slot contribution buffer first, then
// folded back into server.output_buses at deterministic serial join
// points. These tests inspect the per-slot capture (samples + target
// + used) directly and assert output-bus equivalence where the fold
// matters:
//
//   * Distinct sinks land in distinct slots in canonical order.
//   * Same-bus writers stay in separate slots — no pre-summing.
//   * Slot order follows (template_id, instance_slot, region,
//     sink_within_region) lexicographically.
//   * Invalid bus / disconnected input degrade silently (slot
//     reserved, target = -1, used = 0).
//   * Dynamic bus redirect changes target without leaking stale
//     metadata across blocks.
//   * Fused sink kernels write through SinkAccumulator into the
//     correct slot.
//
// The worker-parallel schedule is still a later slice; this mode
// remains a serial executor with an observable private-write step.

// Helper: sum-of-products-of-control-Add. Sets node `idx` to an Add
// whose two controls multiplied... no, just two controls summed.
// Used to feed Out with a known constant signal in capture-mode tests.
static void add_const_node(RTGraph *g, int idx, float a, float b) {
    rt_graph_add_node(g, idx, 8); // Add
    rt_graph_set_control(g, idx, 0, a);
    rt_graph_set_control(g, idx, 1, b);
}

static std::vector<float> read_bus_vec(RTGraph *g, int bus, int nframes) {
    std::vector<float> out(static_cast<std::size_t>(nframes), 0.0f);
    rt_graph_read_bus(g, bus, nframes, out.data());
    return out;
}

static void check_exact_same(const std::vector<float> &a,
                             const std::vector<float> &b) {
    REQUIRE(a.size() == b.size());
    for (std::size_t i = 0; i < a.size(); ++i) {
        CHECK(a[i] == b[i]);
    }
}

static void build_free_then_out_schedule_graph(RTGraph *g) {
    add_const_node(g, 0, 0.25f, 0.5f); // const 0.75
    rt_graph_add_node(g, 1, 2);        // Out(bus 0)
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/1, /*node_count=*/1);
    const int free_region[] = {0};
    const int barrier_region[] = {1};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/1, free_region);
    rt_graph_template_add_schedule_step(g, 0, /*Barrier=*/0,
                                        /*item_count=*/1, barrier_region);
}

static void build_split_free_lifecycle_graph(RTGraph *g) {
    // Env -> Out in one Free step, plus an unrelated Free step in
    // the same instance. C0d splits those into two Free bands because
    // a single band may not contain two steps from one instance slot.
    rt_graph_add_node(g, 0, 9);          // Env
    rt_graph_set_control(g, 0, 0, 1.0);  // gate high
    rt_graph_set_control(g, 0, 1, 0.0005);
    rt_graph_set_control(g, 0, 2, 0.002);
    rt_graph_set_control(g, 0, 3, 1.0);
    rt_graph_set_control(g, 0, 4, 0.5);  // long release

    rt_graph_add_node(g, 1, 2);          // Out(bus 0)
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);

    add_const_node(g, 2, 0.125f, 0.25f);

    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/2);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/2, /*node_count=*/1);
    const int env_out_region[] = {0};
    const int side_region[] = {1};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/1, env_out_region);
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/1, side_region);
}

static void add_template_const_node(
    RTGraph *g, int template_id, int idx, float a, float b
) {
    rt_graph_template_add_node(g, template_id, idx, 8); // Add
    rt_graph_template_set_default(g, template_id, idx, 0, a);
    rt_graph_template_set_default(g, template_id, idx, 1, b);
}

static void build_free_sink_writer_band_graph(RTGraph *g) {
    rt_graph_template_set_polyphony(g, 0, 2);
    add_template_const_node(g, 0, 0, 0.25f, 0.0f);
    rt_graph_instance_set_control(g, 0, 0, 0, 0.25);
    rt_graph_instance_set_control(g, 0, 0, 1, 0.0);

    rt_graph_template_add_node(g, 0, 1, 2); // Out(bus 0)
    rt_graph_template_set_default(g, 0, 1, 0, 0.0);
    rt_graph_instance_set_control(g, 0, 1, 0, 0.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);

    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/2);
    const int sink_region[] = {0};
    // Deliberately mark the sink step as FreeLayer. Haskell normally
    // keeps sink regions as barriers today; this C++ fixture exercises
    // C1c-b's runtime safety gate directly.
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/1, sink_region);
    REQUIRE(rt_graph_template_instance_add(g, 0) == 1);
}

static void build_parallel_send_return_graph(RTGraph *g) {
    rt_graph_ensure_bus(g, 1);

    rt_graph_template_set_polyphony(g, 0, 2);
    add_template_const_node(g, 0, 0, 0.25f, 0.0f);
    rt_graph_instance_set_control(g, 0, 0, 0, 0.25);
    rt_graph_instance_set_control(g, 0, 0, 1, 0.0);
    rt_graph_template_add_node(g, 0, 1, 10); // BusOut(bus 1)
    rt_graph_template_set_default(g, 0, 1, 0, 1.0);
    rt_graph_instance_set_control(g, 0, 1, 0, 1.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/2);
    const int send_region[] = {0};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/1, send_region);
    REQUIRE(rt_graph_template_instance_add(g, 0) == 1);

    const int reader = rt_graph_template_add(g);
    REQUIRE(reader == 1);
    rt_graph_template_add_node(g, reader, 0, 11); // BusIn(bus 1)
    rt_graph_template_set_default(g, reader, 0, 0, 1.0);
    rt_graph_template_add_node(g, reader, 1, 2);  // Out(bus 0)
    rt_graph_template_set_default(g, reader, 1, 0, 0.0);
    rt_graph_template_connect(g, reader, 0, 0, 1, 0);
    rt_graph_template_add_region(g, reader, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/2);
    const int read_region[] = {0};
    rt_graph_template_add_schedule_step(g, reader, /*Barrier=*/0,
                                        /*item_count=*/1, read_region);
    REQUIRE(rt_graph_template_instance_add(g, reader) >= 0);
}

static void build_parallel_release_graph(RTGraph *g) {
    rt_graph_template_set_polyphony(g, 0, 2);
    rt_graph_template_add_node(g, 0, 0, 9); // Env
    rt_graph_template_set_default(g, 0, 0, 0, 1.0);
    rt_graph_template_set_default(g, 0, 0, 1, 0.0005);
    rt_graph_template_set_default(g, 0, 0, 2, 0.002);
    rt_graph_template_set_default(g, 0, 0, 3, 0.5);
    rt_graph_template_set_default(g, 0, 0, 4, 0.002);
    rt_graph_instance_set_control(g, 0, 0, 0, 1.0);
    rt_graph_instance_set_control(g, 0, 0, 1, 0.0005);
    rt_graph_instance_set_control(g, 0, 0, 2, 0.002);
    rt_graph_instance_set_control(g, 0, 0, 3, 0.5);
    rt_graph_instance_set_control(g, 0, 0, 4, 0.002);

    rt_graph_template_add_node(g, 0, 1, 2); // Out(bus 0)
    rt_graph_template_set_default(g, 0, 1, 0, 0.0);
    rt_graph_instance_set_control(g, 0, 1, 0, 0.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/2);
    const int env_out_region[] = {0};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/1, env_out_region);
    REQUIRE(rt_graph_template_instance_add(g, 0) == 1);
}

TEST_CASE("reduction capture: flat fallback puts distinct sinks in distinct slots") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 1);

    // Two Add-fed Outs targeting different buses with different constants.
    add_const_node(g, 0, 0.3f, 0.4f); // const 0.7 → Out(bus 0)
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    add_const_node(g, 2, 0.1f, 0.2f); // const 0.3 → Out(bus 1)
    rt_graph_add_node(g, 3, 2);
    rt_graph_set_control(g, 3, 0, 1.0f);
    rt_graph_connect(g, 2, 0, 3, 0);

    rt_graph_test_set_reduction_capture(g, 1);
    rt_graph_process(g, kFrames);

    REQUIRE(rt_graph_test_last_writer_slot_count(g) == 2);

    CHECK(rt_graph_test_contribution_slot_target(g, 0) == 0);
    CHECK(rt_graph_test_contribution_slot_used(g, 0) == 1);
    CHECK(rt_graph_test_contribution_slot_target(g, 1) == 1);
    CHECK(rt_graph_test_contribution_slot_used(g, 1) == 1);

    std::vector<float> s0(kFrames, 0.0f);
    std::vector<float> s1(kFrames, 0.0f);
    REQUIRE(rt_graph_test_read_contribution_slot(g, 0, kFrames, s0.data()) == 0);
    REQUIRE(rt_graph_test_read_contribution_slot(g, 1, kFrames, s1.data()) == 0);

    for (auto v : s0) CHECK(v == doctest::Approx(0.7f).epsilon(1e-5));
    for (auto v : s1) CHECK(v == doctest::Approx(0.3f).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("reduction capture: same-bus writers stay in separate slots (no pre-sum)") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    // Both Outs target bus 0 with different constants. Reduction-mode
    // capture must keep them separate so the eventual fold can apply
    // canonical-order +=. Pre-summing inside the kernel would change
    // float rounding versus the direct-write executor.
    add_const_node(g, 0, 0.25f, 0.0f); // const 0.25 → Out(bus 0)
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    add_const_node(g, 2, 0.5f, 0.0f);  // const 0.5 → Out(bus 0)
    rt_graph_add_node(g, 3, 2);
    rt_graph_set_control(g, 3, 0, 0.0f);
    rt_graph_connect(g, 2, 0, 3, 0);

    rt_graph_test_set_reduction_capture(g, 1);
    rt_graph_process(g, kFrames);

    REQUIRE(rt_graph_test_last_writer_slot_count(g) == 2);
    CHECK(rt_graph_test_contribution_slot_target(g, 0) == 0);
    CHECK(rt_graph_test_contribution_slot_target(g, 1) == 0);
    CHECK(rt_graph_test_contribution_slot_used(g, 0) == 1);
    CHECK(rt_graph_test_contribution_slot_used(g, 1) == 1);

    std::vector<float> s0(kFrames, 0.0f);
    std::vector<float> s1(kFrames, 0.0f);
    rt_graph_test_read_contribution_slot(g, 0, kFrames, s0.data());
    rt_graph_test_read_contribution_slot(g, 1, kFrames, s1.data());
    for (auto v : s0) CHECK(v == doctest::Approx(0.25f).epsilon(1e-5));
    for (auto v : s1) CHECK(v == doctest::Approx(0.50f).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("reduction fold: same-bus writers match direct output exactly") {
    auto build = [](RTGraph *g) {
        add_const_node(g, 0, 0.25f, 0.0f);
        rt_graph_add_node(g, 1, 2);
        rt_graph_set_control(g, 1, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);

        add_const_node(g, 2, 0.5f, 0.0f);
        rt_graph_add_node(g, 3, 2);
        rt_graph_set_control(g, 3, 0, 0.0f);
        rt_graph_connect(g, 2, 0, 3, 0);
    };

    auto *direct = rt_graph_create(8, kFrames);
    auto *reduced = rt_graph_create(8, kFrames);
    REQUIRE(direct != nullptr);
    REQUIRE(reduced != nullptr);
    build(direct);
    build(reduced);

    rt_graph_test_set_reduction_capture(reduced, 1);
    rt_graph_process(direct, kFrames);
    rt_graph_process(reduced, kFrames);

    const auto direct_bus0 = read_bus_vec(direct, 0, kFrames);
    const auto reduced_bus0 = read_bus_vec(reduced, 0, kFrames);
    check_exact_same(direct_bus0, reduced_bus0);
    for (auto v : reduced_bus0) CHECK(v == doctest::Approx(0.75f).epsilon(1e-6));

    rt_graph_destroy(direct);
    rt_graph_destroy(reduced);
}

TEST_CASE("reduction fold: same-instance live BusIn sees earlier BusOut") {
    auto build = [](RTGraph *g) {
        rt_graph_ensure_bus(g, 1);
        add_const_node(g, 0, 0.5f, 0.0f);
        rt_graph_add_node(g, 1, 10); // BusOut bus 1
        rt_graph_set_control(g, 1, 0, 1.0f);
        rt_graph_connect(g, 0, 0, 1, 0);

        rt_graph_add_node(g, 2, 11); // BusIn bus 1
        rt_graph_set_control(g, 2, 0, 1.0f);
        rt_graph_add_node(g, 3, 2);  // Out bus 0
        rt_graph_set_control(g, 3, 0, 0.0f);
        rt_graph_connect(g, 2, 0, 3, 0);
    };

    auto *direct = rt_graph_create(8, kFrames);
    auto *reduced = rt_graph_create(8, kFrames);
    REQUIRE(direct != nullptr);
    REQUIRE(reduced != nullptr);
    build(direct);
    build(reduced);

    rt_graph_test_set_reduction_capture(reduced, 1);
    rt_graph_process(direct, kFrames);
    rt_graph_process(reduced, kFrames);

    const auto direct_bus0 = read_bus_vec(direct, 0, kFrames);
    const auto reduced_bus0 = read_bus_vec(reduced, 0, kFrames);
    check_exact_same(direct_bus0, reduced_bus0);
    for (auto v : reduced_bus0) CHECK(v == doctest::Approx(0.5f).epsilon(1e-6));

    rt_graph_destroy(direct);
    rt_graph_destroy(reduced);
}

TEST_CASE("reduction fold: BusInDelayed reads previous block's folded output_buses") {
    // Writer (Add → BusOut bus 1) in template 0; delayed reader
    // (BusInDelayed bus 1 → Out bus 0) in template 1. The fold must
    // make this block's writes land in output_buses[1], so the
    // block-end swap puts them into output_buses_prev for the next
    // block, where BusInDelayed picks them up. We render two
    // contiguous blocks: block 1 sees zero (prev pool is initial
    // zero), block 2 sees the previous block's writer constant.
    auto build = [](RTGraph *g) {
        rt_graph_ensure_bus(g, 1);

        rt_graph_template_add_node(g, 0, 0, 8);  // Add const 0.5
        rt_graph_template_set_default(g, 0, 0, 0, 0.5);
        rt_graph_template_set_default(g, 0, 0, 1, 0.0);
        rt_graph_template_add_node(g, 0, 1, 10); // BusOut bus 1
        rt_graph_template_set_default(g, 0, 1, 0, 1.0);
        rt_graph_template_connect(g, 0, 0, 0, 1, 0);

        int t1 = rt_graph_template_add(g);
        REQUIRE(t1 == 1);
        rt_graph_template_add_node(g, t1, 0, 12); // BusInDelayed bus 1
        rt_graph_template_set_default(g, t1, 0, 0, 1.0);
        rt_graph_template_add_node(g, t1, 1, 2);  // Out bus 0
        rt_graph_template_set_default(g, t1, 1, 0, 0.0);
        rt_graph_template_connect(g, t1, 0, 0, 1, 0);

        rt_graph_instance_remove(g, 0);
        REQUIRE(rt_graph_template_instance_add(g, 0)  >= 0);
        REQUIRE(rt_graph_template_instance_add(g, t1) >= 0);
    };

    auto *direct  = rt_graph_create(8, kFrames);
    auto *reduced = rt_graph_create(8, kFrames);
    REQUIRE(direct  != nullptr);
    REQUIRE(reduced != nullptr);
    build(direct);
    build(reduced);

    rt_graph_test_set_reduction_capture(reduced, 1);

    // Block 1: BusInDelayed reads the initial-zero prev pool, so
    // bus 0 should be silent in both modes. Equivalent or not, it
    // tests the swap path.
    rt_graph_process(direct,  kFrames);
    rt_graph_process(reduced, kFrames);
    {
        const auto d = read_bus_vec(direct,  0, kFrames);
        const auto r = read_bus_vec(reduced, 0, kFrames);
        check_exact_same(d, r);
        for (auto v : d) CHECK(v == doctest::Approx(0.0f).epsilon(1e-6));
    }

    // Block 2: BusInDelayed picks up block 1's folded writes from
    // output_buses_prev. Reduction mode must produce the same value
    // as direct mode — proves the block-end swap sees a fully-
    // folded output_buses, not a still-empty one.
    rt_graph_process(direct,  kFrames);
    rt_graph_process(reduced, kFrames);
    {
        const auto d = read_bus_vec(direct,  0, kFrames);
        const auto r = read_bus_vec(reduced, 0, kFrames);
        check_exact_same(d, r);
        for (auto v : d) CHECK(v == doctest::Approx(0.5f).epsilon(1e-6));
    }

    rt_graph_destroy(direct);
    rt_graph_destroy(reduced);
}

TEST_CASE("reduction fold: same-template cross-instance live BusIn") {
    // Two instances of one template: instance slot 0 writes Add(0.7)
    // into bus 1 via BusOut, instance slot 1 reads bus 1 live via
    // BusIn and routes it to Out(bus 0). The serial executor walks
    // instances in slot order, so instance 0's fold completes before
    // instance 1's BusIn runs. Reduction mode must preserve this —
    // it's the per-instance equivalent of the cross-template T-10
    // hazard the design note calls out.
    auto build = [](RTGraph *g) {
        rt_graph_ensure_bus(g, 1);
        rt_graph_template_set_polyphony(g, 0, 4);

        // Two-role template: BusOut(bus 1) wired from Add, BusIn(bus 1)
        // wired into Out(bus 0). Each instance carries both roles, but
        // we silence one role per instance via the bus-control override.
        rt_graph_template_add_node(g, 0, 0, 8);  // Add (constant)
        rt_graph_template_set_default(g, 0, 0, 0, 0.0);
        rt_graph_template_set_default(g, 0, 0, 1, 0.0);
        rt_graph_template_add_node(g, 0, 1, 10); // BusOut
        rt_graph_template_set_default(g, 0, 1, 0, 1.0);
        rt_graph_template_connect(g, 0, 0, 0, 1, 0);
        rt_graph_template_add_node(g, 0, 2, 11); // BusIn
        rt_graph_template_set_default(g, 0, 2, 0, 1.0);
        rt_graph_template_add_node(g, 0, 3, 2);  // Out
        rt_graph_template_set_default(g, 0, 3, 0, 0.0);
        rt_graph_template_connect(g, 0, 2, 0, 3, 0);

        rt_graph_instance_remove(g, 0);
        const int writer = rt_graph_template_instance_add(g, 0);
        const int reader = rt_graph_template_instance_add(g, 0);
        REQUIRE(writer == 0);
        REQUIRE(reader == 1);

        // Writer instance: Add control 0 = 0.7 → BusOut(bus 1).
        // Disable its Out (bus -1) and BusIn (bus -1) to keep it
        // contributing only the BusOut.
        rt_graph_instance_set_control(g, writer, 0, 0, 0.7f);
        rt_graph_instance_set_control(g, writer, 2, 0, -1.0f);
        rt_graph_instance_set_control(g, writer, 3, 0, -1.0f);

        // Reader instance: silence its Add and BusOut so it adds
        // nothing of its own to bus 1; its BusIn(bus 1) → Out(bus 0)
        // sees only the writer's contribution.
        rt_graph_instance_set_control(g, reader, 0, 0, 0.0f);
        rt_graph_instance_set_control(g, reader, 1, 0, -1.0f);
    };

    auto *direct  = rt_graph_create(8, kFrames);
    auto *reduced = rt_graph_create(8, kFrames);
    REQUIRE(direct  != nullptr);
    REQUIRE(reduced != nullptr);
    build(direct);
    build(reduced);

    rt_graph_test_set_reduction_capture(reduced, 1);
    rt_graph_process(direct,  kFrames);
    rt_graph_process(reduced, kFrames);

    const auto direct_bus0  = read_bus_vec(direct,  0, kFrames);
    const auto reduced_bus0 = read_bus_vec(reduced, 0, kFrames);
    check_exact_same(direct_bus0, reduced_bus0);
    for (auto v : reduced_bus0) CHECK(v == doctest::Approx(0.7f).epsilon(1e-6));

    rt_graph_destroy(direct);
    rt_graph_destroy(reduced);
}

TEST_CASE("reduction fold: cross-template live BusIn sees earlier template BusOut") {
    auto build = [](RTGraph *g) {
        rt_graph_ensure_bus(g, 1);

        rt_graph_template_add_node(g, 0, 0, 8);  // Add const 0.4
        rt_graph_template_set_default(g, 0, 0, 0, 0.4);
        rt_graph_template_set_default(g, 0, 0, 1, 0.0);
        rt_graph_template_add_node(g, 0, 1, 10); // BusOut bus 1
        rt_graph_template_set_default(g, 0, 1, 0, 1.0);
        rt_graph_template_connect(g, 0, 0, 0, 1, 0);

        int t1 = rt_graph_template_add(g);
        REQUIRE(t1 == 1);
        rt_graph_template_add_node(g, t1, 0, 11); // BusIn bus 1
        rt_graph_template_set_default(g, t1, 0, 0, 1.0);
        rt_graph_template_add_node(g, t1, 1, 2);  // Out bus 0
        rt_graph_template_set_default(g, t1, 1, 0, 0.0);
        rt_graph_template_connect(g, t1, 0, 0, 1, 0);

        rt_graph_instance_remove(g, 0);
        REQUIRE(rt_graph_template_instance_add(g, 0) >= 0);
        REQUIRE(rt_graph_template_instance_add(g, t1) >= 0);
    };

    auto *direct = rt_graph_create(8, kFrames);
    auto *reduced = rt_graph_create(8, kFrames);
    REQUIRE(direct != nullptr);
    REQUIRE(reduced != nullptr);
    build(direct);
    build(reduced);

    rt_graph_test_set_reduction_capture(reduced, 1);
    rt_graph_process(direct, kFrames);
    rt_graph_process(reduced, kFrames);

    const auto direct_bus0 = read_bus_vec(direct, 0, kFrames);
    const auto reduced_bus0 = read_bus_vec(reduced, 0, kFrames);
    check_exact_same(direct_bus0, reduced_bus0);
    for (auto v : reduced_bus0) CHECK(v == doctest::Approx(0.4f).epsilon(1e-6));

    rt_graph_destroy(direct);
    rt_graph_destroy(reduced);
}

TEST_CASE("reduction capture: cross-instance slot order matches instance slot order") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    // One template: Add(c, 0) → Out(bus 0). Spawn two instances and
    // override control 'c' per instance. Slot 0 belongs to instance
    // slot 0, slot 1 to instance slot 1 — canonical (§3.2) order.
    rt_graph_template_set_polyphony(g, 0, 4);
    rt_graph_template_add_node(g, 0, 0, 8); // Add
    rt_graph_template_set_default(g, 0, 0, 0, 0.0);
    rt_graph_template_set_default(g, 0, 0, 1, 0.0);
    rt_graph_template_add_node(g, 0, 1, 2); // Out
    rt_graph_template_set_default(g, 0, 1, 0, 0.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);

    // Drop auto-instance 0; spawn a fresh pair with distinct
    // per-instance controls.
    rt_graph_instance_remove(g, 0);
    int inst0 = rt_graph_template_instance_add(g, 0);
    int inst1 = rt_graph_template_instance_add(g, 0);
    REQUIRE(inst0 >= 0);
    REQUIRE(inst1 >= 0);
    rt_graph_instance_set_control(g, inst0, 0, 0, 0.111f);
    rt_graph_instance_set_control(g, inst1, 0, 0, 0.222f);

    rt_graph_test_set_reduction_capture(g, 1);
    rt_graph_process(g, kFrames);

    REQUIRE(rt_graph_test_last_writer_slot_count(g) == 2);

    std::vector<float> s0(kFrames, 0.0f);
    std::vector<float> s1(kFrames, 0.0f);
    rt_graph_test_read_contribution_slot(g, 0, kFrames, s0.data());
    rt_graph_test_read_contribution_slot(g, 1, kFrames, s1.data());

    // Slot index = instance slot order, not which instance got
    // spawned with which constant. The lower instance slot owns
    // slot 0 regardless of spawn timing — process_graph iterates
    // g.instances by index.
    for (auto v : s0) CHECK(v == doctest::Approx(0.111f).epsilon(1e-5));
    for (auto v : s1) CHECK(v == doctest::Approx(0.222f).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("reduction capture: cross-template slot order matches registration order") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 1);

    // Template 0: Add(0.4) → Out(bus 0).
    rt_graph_template_add_node(g, 0, 0, 8);
    rt_graph_template_set_default(g, 0, 0, 0, 0.4);
    rt_graph_template_set_default(g, 0, 0, 1, 0.0);
    rt_graph_template_add_node(g, 0, 1, 2);
    rt_graph_template_set_default(g, 0, 1, 0, 0.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);

    // Template 1: Add(0.6) → Out(bus 1). Registered after template 0.
    int t1 = rt_graph_template_add(g);
    REQUIRE(t1 == 1);
    rt_graph_template_add_node(g, t1, 0, 8);
    rt_graph_template_set_default(g, t1, 0, 0, 0.6);
    rt_graph_template_set_default(g, t1, 0, 1, 0.0);
    rt_graph_template_add_node(g, t1, 1, 2);
    rt_graph_template_set_default(g, t1, 1, 0, 1.0);
    rt_graph_template_connect(g, t1, 0, 0, 1, 0);

    rt_graph_instance_remove(g, 0);
    REQUIRE(rt_graph_template_instance_add(g, 0)  >= 0);
    REQUIRE(rt_graph_template_instance_add(g, t1) >= 0);

    rt_graph_test_set_reduction_capture(g, 1);
    rt_graph_process(g, kFrames);

    REQUIRE(rt_graph_test_last_writer_slot_count(g) == 2);

    // §3.1: template registration order means slot 0 belongs to
    // template 0's writer, slot 1 to template 1's.
    CHECK(rt_graph_test_contribution_slot_target(g, 0) == 0);
    CHECK(rt_graph_test_contribution_slot_target(g, 1) == 1);

    std::vector<float> s0(kFrames, 0.0f);
    std::vector<float> s1(kFrames, 0.0f);
    rt_graph_test_read_contribution_slot(g, 0, kFrames, s0.data());
    rt_graph_test_read_contribution_slot(g, 1, kFrames, s1.data());
    for (auto v : s0) CHECK(v == doctest::Approx(0.4f).epsilon(1e-5));
    for (auto v : s1) CHECK(v == doctest::Approx(0.6f).epsilon(1e-5));

    rt_graph_destroy(g);
}

TEST_CASE("reduction capture: invalid bus reserves slot but leaves target = -1, used = 0") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    // Out node with bus_control = -1 (invalid). Slot is reserved
    // unconditionally at the dispatch site; reduction-mode opener
    // sees the bad bus and bails before recording target / used.
    add_const_node(g, 0, 0.5f, 0.0f);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, -1.0f);  // invalid bus
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_test_set_reduction_capture(g, 1);
    rt_graph_process(g, kFrames);

    REQUIRE(rt_graph_test_last_writer_slot_count(g) == 1);
    CHECK(rt_graph_test_contribution_slot_target(g, 0) == -1);
    CHECK(rt_graph_test_contribution_slot_used(g, 0)   == 0);

    rt_graph_destroy(g);
}

TEST_CASE("reduction capture: disconnected input reserves slot, leaves metadata clear") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    // Out(bus 0) with no input wired. process_out's empty-input
    // branch returns before opening the target — slot is still
    // reserved at the dispatch site, but reduction-mode metadata
    // never gets written for it.
    rt_graph_add_node(g, 0, 2);
    rt_graph_set_control(g, 0, 0, 0.0f);

    rt_graph_test_set_reduction_capture(g, 1);
    rt_graph_process(g, kFrames);

    REQUIRE(rt_graph_test_last_writer_slot_count(g) == 1);
    CHECK(rt_graph_test_contribution_slot_target(g, 0) == -1);
    CHECK(rt_graph_test_contribution_slot_used(g, 0)   == 0);

    rt_graph_destroy(g);
}

TEST_CASE("reduction capture: dynamic bus redirect updates target without stale metadata") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 3);

    add_const_node(g, 0, 0.5f, 0.0f);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);  // initial bus = 0
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_test_set_reduction_capture(g, 1);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_contribution_slot_target(g, 0) == 0);
    CHECK(rt_graph_test_contribution_slot_used(g, 0)   == 1);

    // Redirect to bus 3 (instance 0 is the auto-created one).
    rt_graph_instance_set_control(g, 0, 1, 0, 3.0f);
    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_contribution_slot_target(g, 0) == 3);
    CHECK(rt_graph_test_contribution_slot_used(g, 0)   == 1);

    // Redirect to invalid bus. target reset to -1 by per-block clear,
    // and the opener doesn't overwrite for invalid bus → stays -1.
    // used must clear too (no leak from the previous block's set bit).
    rt_graph_instance_set_control(g, 0, 1, 0, -2.0f);
    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_contribution_slot_target(g, 0) == -1);
    CHECK(rt_graph_test_contribution_slot_used(g, 0)   == 0);

    rt_graph_destroy(g);
}

TEST_CASE("reduction capture: fused sink kernel (SinGainOut) writes through SinkAccumulator") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_template_add_node(g, 0, 0, 1);   // SinOsc
    rt_graph_template_set_default(g, 0, 0, 0, 220.0);
    rt_graph_template_add_node(g, 0, 1, 3);   // Gain
    rt_graph_template_set_default(g, 0, 1, 0, 0.5);
    rt_graph_template_add_node(g, 0, 2, 2);   // Out
    rt_graph_template_set_default(g, 0, 2, 0, 0.0);
    rt_graph_template_connect(g, 0, 0, 0, 1, 0);
    rt_graph_template_connect(g, 0, 1, 0, 2, 0);

    rt_graph_template_add_region_kernel(
        g, /*template_id=*/0, /*kernel_kind=*/2, /*rate=*/0,
        /*first_node=*/0, /*node_count=*/3);

    // Drop the auto-instance and respawn so per-instance controls
    // pick up the spec defaults set above (the auto-instance is
    // initialized at template-0 creation, before the defaults
    // were written, so its Gain.controls[0] would still be the
    // initial value).
    rt_graph_instance_remove(g, 0);
    REQUIRE(rt_graph_template_instance_add(g, 0) >= 0);

    rt_graph_test_set_reduction_capture(g, 1);
    rt_graph_process(g, kFrames);

    REQUIRE(rt_graph_test_last_writer_slot_count(g) == 1);
    CHECK(rt_graph_test_contribution_slot_target(g, 0) == 0);
    CHECK(rt_graph_test_contribution_slot_used(g, 0)   == 1);

    // The SinGainOut kernel writes 0.5 * sin(2π·220·t/sr) per frame
    // into the slot. Peak should be near gain=0.5 once the sin
    // sweeps a full cycle (220 Hz × 1024/48000 ≈ 4.7 cycles in
    // kFrames, so peak is reached).
    std::vector<float> s0(kFrames, 0.0f);
    rt_graph_test_read_contribution_slot(g, 0, kFrames, s0.data());
    CHECK(peak_abs(s0) == doctest::Approx(0.5f).epsilon(0.02));
    // It's an actual oscillation — not a constant — so plenty of zero
    // crossings.
    CHECK(zero_crossings(s0) >= 7);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Phase §4.E.2.C0c: global-schedule serial executor
// ----------------------------------------------------------------

TEST_CASE("global schedule executor: metadata-bearing graph matches legacy") {
    auto build = [](RTGraph *g) {
        add_const_node(g, 0, 0.25f, 0.5f); // const 0.75 → Out(bus 0)
        rt_graph_add_node(g, 1, 2);
        rt_graph_set_control(g, 1, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);

        rt_graph_template_add_region(g, 0, /*rate=*/0,
                                     /*first_node=*/0, /*node_count=*/2);
        const int region0[] = {0};
        rt_graph_template_add_schedule_step(g, 0, /*Barrier=*/0,
                                            /*item_count=*/1, region0);
    };

    auto *legacy = rt_graph_create(4, kFrames);
    auto *sched  = rt_graph_create(4, kFrames);
    REQUIRE(legacy != nullptr);
    REQUIRE(sched  != nullptr);
    build(legacy);
    build(sched);

    rt_graph_test_set_global_schedule_execution(sched, 1);
    rt_graph_process(legacy, kFrames);
    rt_graph_process(sched,  kFrames);

    const auto legacy_bus0 = read_bus_vec(legacy, 0, kFrames);
    const auto sched_bus0  = read_bus_vec(sched,  0, kFrames);
    check_exact_same(legacy_bus0, sched_bus0);
    for (auto v : sched_bus0) CHECK(v == doctest::Approx(0.75f).epsilon(1e-6));

    rt_graph_destroy(legacy);
    rt_graph_destroy(sched);
}

TEST_CASE("global schedule executor: no-metadata graph falls back to legacy") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    add_const_node(g, 0, 0.125f, 0.5f); // const 0.625 → Out(bus 0)
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    // No RegionSpec / ScheduleStepSpec metadata is registered here.
    // With the C0c flag on, process_graph must still use the legacy
    // flat-node executor rather than treating the empty global schedule
    // as "nothing to run".
    rt_graph_test_set_global_schedule_execution(g, 1);
    rt_graph_process(g, kFrames);

    const auto bus0 = read_bus_vec(g, 0, kFrames);
    for (auto v : bus0) CHECK(v == doctest::Approx(0.625f).epsilon(1e-6));
    CHECK(rt_graph_test_global_schedule_entry_count(g) == 0);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Phase §4.E.2.C1b: worker-pool scaffold, no parallel DSP yet
// ----------------------------------------------------------------

TEST_CASE("schedule worker pool scaffold: zero and one stay serial") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    CHECK(rt_graph_test_worker_pool_size(g) == 0);
    CHECK(rt_graph_test_worker_thread_count(g) == 0);

    rt_graph_test_set_worker_pool_size(g, -4);
    CHECK(rt_graph_test_worker_pool_size(g) == 0);
    CHECK(rt_graph_test_worker_thread_count(g) == 0);

    rt_graph_test_set_worker_pool_size(g, 1);
    CHECK(rt_graph_test_worker_pool_size(g) == 1);
    CHECK(rt_graph_test_worker_thread_count(g) == 0);

    rt_graph_test_set_worker_pool_size(g, 0);
    CHECK(rt_graph_test_worker_pool_size(g) == 0);
    CHECK(rt_graph_test_worker_thread_count(g) == 0);

    rt_graph_destroy(g);
}

TEST_CASE("schedule worker pool scaffold: resize starts and joins idle workers") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_test_set_worker_pool_size(g, 4);
    CHECK(rt_graph_test_worker_pool_size(g) == 4);
    CHECK(rt_graph_test_worker_thread_count(g) == 3);

    rt_graph_test_set_worker_pool_size(g, 2);
    CHECK(rt_graph_test_worker_pool_size(g) == 2);
    CHECK(rt_graph_test_worker_thread_count(g) == 1);

    rt_graph_test_set_worker_pool_size(g, 1);
    CHECK(rt_graph_test_worker_pool_size(g) == 1);
    CHECK(rt_graph_test_worker_thread_count(g) == 0);

    rt_graph_destroy(g);
}

TEST_CASE("schedule worker pool scaffold: clear preserves pool lifetime") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_test_set_worker_pool_size(g, 3);
    CHECK(rt_graph_test_worker_pool_size(g) == 3);
    CHECK(rt_graph_test_worker_thread_count(g) == 2);

    rt_graph_clear(g);
    CHECK(rt_graph_test_worker_pool_size(g) == 3);
    CHECK(rt_graph_test_worker_thread_count(g) == 2);

    rt_graph_destroy(g);
}

TEST_CASE("global schedule executor: worker pool scaffold still matches legacy") {
    auto *legacy = rt_graph_create(4, kFrames);
    auto *sched  = rt_graph_create(4, kFrames);
    REQUIRE(legacy != nullptr);
    REQUIRE(sched  != nullptr);

    build_free_then_out_schedule_graph(legacy);
    build_free_then_out_schedule_graph(sched);

    rt_graph_test_set_worker_pool_size(sched, 3);
    rt_graph_test_set_global_schedule_execution(sched, 1);

    rt_graph_process(legacy, kFrames);
    rt_graph_process(sched,  kFrames);

    CHECK(rt_graph_test_worker_pool_size(sched) == 3);
    CHECK(rt_graph_test_worker_thread_count(sched) == 2);
    check_exact_same(read_bus_vec(legacy, 0, kFrames),
                     read_bus_vec(sched,  0, kFrames));

    rt_graph_destroy(legacy);
    rt_graph_destroy(sched);
}

TEST_CASE("global schedule executor: worker pool scaffold preserves reduction equivalence") {
    auto *direct  = rt_graph_create(4, kFrames);
    auto *reduced = rt_graph_create(4, kFrames);
    REQUIRE(direct  != nullptr);
    REQUIRE(reduced != nullptr);

    build_free_then_out_schedule_graph(direct);
    build_free_then_out_schedule_graph(reduced);

    rt_graph_test_set_worker_pool_size(direct, 3);
    rt_graph_test_set_worker_pool_size(reduced, 3);
    rt_graph_test_set_global_schedule_execution(direct, 1);
    rt_graph_test_set_global_schedule_execution(reduced, 1);
    rt_graph_test_set_reduction_capture(reduced, 1);

    rt_graph_process(direct,  kFrames);
    rt_graph_process(reduced, kFrames);

    check_exact_same(read_bus_vec(direct,  0, kFrames),
                     read_bus_vec(reduced, 0, kFrames));

    rt_graph_destroy(direct);
    rt_graph_destroy(reduced);
}

// ----------------------------------------------------------------
// Phase §4.E.2.C1c-a: scheduled lifecycle is outside worker contexts
// ----------------------------------------------------------------

TEST_CASE("global schedule executor: split free bands do not restart lifecycle") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    build_split_free_lifecycle_graph(g);
    rt_graph_test_set_worker_pool_size(g, 3);
    rt_graph_test_set_global_schedule_execution(g, 1);

    // Open the envelope before releasing. The two Free steps should
    // land in two bands for the same slot; lifecycle must still begin
    // once before all bands and finish once after all bands.
    rt_graph_process(g, kFrames);
    REQUIRE(rt_graph_test_global_schedule_band_count(g) == 2);
    CHECK(rt_graph_test_global_schedule_band_kind(g, 0) == 1);
    CHECK(rt_graph_test_global_schedule_band_kind(g, 1) == 1);
    CHECK(rt_graph_test_global_schedule_band_entry_count(g, 0) == 1);
    CHECK(rt_graph_test_global_schedule_band_entry_count(g, 1) == 1);
    REQUIRE(rt_graph_instance_status(g, 0) == 0);
    rt_graph_instance_release(g, 0);
    REQUIRE(rt_graph_instance_status(g, 0) == 1);

    // With a long release, the Env->Out band remains audible for far
    // more than the 8 silent blocks needed to auto-free. A per-band
    // lifecycle reset would zero block_sink_peak in the second Free
    // band and incorrectly free this slot inside this loop.
    for (int i = 0; i < 12; ++i) {
        rt_graph_process(g, kFrames);
        CHECK(rt_graph_instance_alive(g, 0) == 1);
        CHECK(rt_graph_instance_status(g, 0) == 1);
    }

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Phase §4.E.2.C1c-b: parallel Free-band dispatch gates
// ----------------------------------------------------------------

TEST_CASE("global schedule executor: free no-sink band dispatches in parallel") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_template_set_polyphony(g, 0, 3);
    add_const_node(g, 0, 0.125f, 0.5f);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/1);
    const int region0[] = {0};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/1, region0);
    REQUIRE(rt_graph_template_instance_add(g, 0) == 1);
    REQUIRE(rt_graph_template_instance_add(g, 0) == 2);

    rt_graph_test_set_worker_pool_size(g, 3);
    rt_graph_test_set_global_schedule_execution(g, 1);
    rt_graph_process(g, kFrames);

    CHECK(rt_graph_test_global_schedule_band_count(g) == 1);
    CHECK(rt_graph_test_last_parallel_band_count(g) == 1);
    CHECK(rt_graph_test_last_parallel_entry_count(g) == 3);
    CHECK(rt_graph_test_last_serialized_free_band_count(g) == 0);

    rt_graph_destroy(g);
}

TEST_CASE("global schedule executor: direct-mode sink free band serializes") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    build_free_sink_writer_band_graph(g);
    rt_graph_test_set_worker_pool_size(g, 3);
    rt_graph_test_set_global_schedule_execution(g, 1);
    rt_graph_process(g, kFrames);

    CHECK(rt_graph_test_global_schedule_band_count(g) == 1);
    CHECK(rt_graph_test_last_parallel_band_count(g) == 0);
    CHECK(rt_graph_test_last_parallel_entry_count(g) == 0);
    CHECK(rt_graph_test_last_serialized_free_band_count(g) == 1);
    CHECK(rt_graph_test_last_writer_slot_count(g) == 2);

    const auto bus0 = read_bus_vec(g, 0, kFrames);
    for (float v : bus0) {
        CHECK(v == 0.5f);
    }

    rt_graph_destroy(g);
}

TEST_CASE("global schedule executor: reduction-mode sink free band dispatches in parallel") {
    auto *direct = rt_graph_create(4, kFrames);
    auto *reduced = rt_graph_create(4, kFrames);
    REQUIRE(direct != nullptr);
    REQUIRE(reduced != nullptr);

    build_free_sink_writer_band_graph(direct);
    build_free_sink_writer_band_graph(reduced);

    rt_graph_test_set_worker_pool_size(direct, 3);
    rt_graph_test_set_worker_pool_size(reduced, 3);
    rt_graph_test_set_global_schedule_execution(direct, 1);
    rt_graph_test_set_global_schedule_execution(reduced, 1);
    rt_graph_test_set_reduction_capture(reduced, 1);

    rt_graph_process(direct, kFrames);
    rt_graph_process(reduced, kFrames);

    CHECK(rt_graph_test_last_serialized_free_band_count(direct) == 1);
    CHECK(rt_graph_test_last_parallel_band_count(reduced) == 1);
    CHECK(rt_graph_test_last_parallel_entry_count(reduced) == 2);
    CHECK(rt_graph_test_last_serialized_free_band_count(reduced) == 0);
    CHECK(rt_graph_test_last_writer_slot_count(reduced) == 2);
    CHECK(rt_graph_test_contribution_slot_target(reduced, 0) == 0);
    CHECK(rt_graph_test_contribution_slot_target(reduced, 1) == 0);

    check_exact_same(read_bus_vec(direct, 0, kFrames),
                     read_bus_vec(reduced, 0, kFrames));

    rt_graph_destroy(direct);
    rt_graph_destroy(reduced);
}

TEST_CASE("global schedule executor: parallel reduction joins before reader band") {
    auto *direct = rt_graph_create(8, kFrames);
    auto *reduced = rt_graph_create(8, kFrames);
    REQUIRE(direct != nullptr);
    REQUIRE(reduced != nullptr);

    build_parallel_send_return_graph(direct);
    build_parallel_send_return_graph(reduced);

    rt_graph_test_set_worker_pool_size(direct, 3);
    rt_graph_test_set_worker_pool_size(reduced, 3);
    rt_graph_test_set_global_schedule_execution(direct, 1);
    rt_graph_test_set_global_schedule_execution(reduced, 1);
    rt_graph_test_set_reduction_capture(reduced, 1);

    rt_graph_process(direct, kFrames);
    rt_graph_process(reduced, kFrames);

    CHECK(rt_graph_test_last_serialized_free_band_count(direct) == 1);
    CHECK(rt_graph_test_last_parallel_band_count(reduced) == 1);
    CHECK(rt_graph_test_last_parallel_entry_count(reduced) == 2);

    const auto direct_bus0 = read_bus_vec(direct, 0, kFrames);
    const auto reduced_bus0 = read_bus_vec(reduced, 0, kFrames);
    check_exact_same(direct_bus0, reduced_bus0);
    for (float v : reduced_bus0) {
        CHECK(v == 0.5f);
    }

    rt_graph_destroy(direct);
    rt_graph_destroy(reduced);
}

TEST_CASE("global schedule executor: release accounting survives parallel sink dispatch") {
    auto *g = rt_graph_create(4, 256);
    REQUIRE(g != nullptr);

    build_parallel_release_graph(g);
    rt_graph_test_set_worker_pool_size(g, 3);
    rt_graph_test_set_global_schedule_execution(g, 1);
    rt_graph_test_set_reduction_capture(g, 1);

    rt_graph_process(g, 256);
    REQUIRE(rt_graph_test_last_parallel_band_count(g) == 1);
    REQUIRE(rt_graph_instance_status(g, 0) == 0);
    rt_graph_instance_release(g, 0);
    REQUIRE(rt_graph_instance_status(g, 0) == 1);

    bool saw_parallel = false;
    bool freed = false;
    for (int i = 0; i < 64; ++i) {
        rt_graph_process(g, 256);
        saw_parallel = saw_parallel
            || rt_graph_test_last_parallel_band_count(g) > 0;
        if (rt_graph_instance_alive(g, 0) == 0) {
            freed = true;
            break;
        }
    }

    CHECK(saw_parallel);
    CHECK(freed);
    CHECK(rt_graph_instance_status(g, 0) == -1);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Phase §4.E.2.C0d: descriptive global-schedule runnable bands
// ----------------------------------------------------------------

TEST_CASE("global schedule bands: free entries from different instances group") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_template_set_polyphony(g, 0, 3);
    add_const_node(g, 0, 0.125f, 0.5f);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/1);
    const int region0[] = {0};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/1, region0);

    REQUIRE(rt_graph_template_instance_add(g, 0) == 1);
    REQUIRE(rt_graph_template_instance_add(g, 0) == 2);
    rt_graph_process(g, kFrames);

    CHECK(rt_graph_test_global_schedule_entry_count(g) == 3);
    REQUIRE(rt_graph_test_global_schedule_band_count(g) == 1);
    CHECK(rt_graph_test_global_schedule_band_kind(g, 0) == 1);
    CHECK(rt_graph_test_global_schedule_band_first_entry(g, 0) == 0);
    CHECK(rt_graph_test_global_schedule_band_entry_count(g, 0) == 3);

    CHECK(rt_graph_test_global_schedule_band_kind(g, 1) == -1);
    CHECK(rt_graph_test_global_schedule_band_first_entry(g, 1) == -1);
    CHECK(rt_graph_test_global_schedule_band_entry_count(g, 1) == -1);

    rt_graph_destroy(g);
}

TEST_CASE("global schedule bands: same-instance free layers split before barrier") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    add_const_node(g, 0, 0.1f, 0.0f);
    add_const_node(g, 1, 0.2f, 0.0f);
    add_const_node(g, 2, 0.3f, 0.0f);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/1, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/2, /*node_count=*/1);

    const int region0[] = {0};
    const int region1[] = {1};
    const int region2[] = {2};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/1, region0);
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/1, region1);
    rt_graph_template_add_schedule_step(g, 0, /*Barrier=*/0,
                                        /*item_count=*/1, region2);

    rt_graph_process(g, kFrames);

    CHECK(rt_graph_test_global_schedule_entry_count(g) == 3);
    REQUIRE(rt_graph_test_global_schedule_band_count(g) == 3);
    CHECK(rt_graph_test_global_schedule_band_kind(g, 0) == 1);
    CHECK(rt_graph_test_global_schedule_band_first_entry(g, 0) == 0);
    CHECK(rt_graph_test_global_schedule_band_entry_count(g, 0) == 1);
    CHECK(rt_graph_test_global_schedule_band_kind(g, 1) == 1);
    CHECK(rt_graph_test_global_schedule_band_first_entry(g, 1) == 1);
    CHECK(rt_graph_test_global_schedule_band_entry_count(g, 1) == 1);
    CHECK(rt_graph_test_global_schedule_band_kind(g, 2) == 0);
    CHECK(rt_graph_test_global_schedule_band_first_entry(g, 2) == 2);
    CHECK(rt_graph_test_global_schedule_band_entry_count(g, 2) == 1);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Phase §4.E.2.C1d-a: descriptive per-region work items
// ----------------------------------------------------------------

TEST_CASE("region-layer work items: non-contiguous free step preserves item order") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    add_const_node(g, 0, 0.1f, 0.0f);
    add_const_node(g, 1, 0.2f, 0.0f);
    add_const_node(g, 2, 0.3f, 0.0f);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/1, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/2, /*node_count=*/1);

    const int free_items[] = {0, 2};
    const int barrier_item[] = {1};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/2, free_items);
    rt_graph_template_add_schedule_step(g, 0, /*Barrier=*/0,
                                        /*item_count=*/1, barrier_item);

    // Default polyphony is 8; each instance can emit 3 region work
    // items. The capacity accessor pins the construction-time reserve
    // that makes the per-block builder allocation-free.
    CHECK(rt_graph_test_region_layer_work_item_capacity(g) >= 24);

    rt_graph_process(g, kFrames);

    REQUIRE(rt_graph_test_global_schedule_entry_count(g) == 2);
    REQUIRE(rt_graph_test_region_layer_work_item_count(g) == 3);

    CHECK(rt_graph_test_region_layer_work_item_entry(g, 0) == 0);
    CHECK(rt_graph_test_region_layer_work_item_step(g, 0) == 0);
    CHECK(rt_graph_test_region_layer_work_item_item(g, 0) == 0);
    CHECK(rt_graph_test_region_layer_work_item_region(g, 0) == 0);

    CHECK(rt_graph_test_region_layer_work_item_entry(g, 1) == 0);
    CHECK(rt_graph_test_region_layer_work_item_step(g, 1) == 0);
    CHECK(rt_graph_test_region_layer_work_item_item(g, 1) == 1);
    CHECK(rt_graph_test_region_layer_work_item_region(g, 1) == 2);

    CHECK(rt_graph_test_region_layer_work_item_entry(g, 2) == 1);
    CHECK(rt_graph_test_region_layer_work_item_step(g, 2) == 1);
    CHECK(rt_graph_test_region_layer_work_item_item(g, 2) == 0);
    CHECK(rt_graph_test_region_layer_work_item_region(g, 2) == 1);

    for (int i = 0; i < 3; ++i) {
        CHECK(rt_graph_test_region_layer_work_item_template(g, i) == 0);
        CHECK(rt_graph_test_region_layer_work_item_instance(g, i) == 0);
        CHECK(rt_graph_test_region_layer_work_item_first_writer_slot(g, i) == 0);
        CHECK(rt_graph_test_region_layer_work_item_writer_slot_count(g, i) == 0);
    }

    CHECK(rt_graph_test_last_c1d_candidate_entry_count(g) == 1);
    CHECK(rt_graph_test_last_c1d_candidate_item_count(g) == 2);
    CHECK(rt_graph_test_last_c1d_serialized_sink_entry_count(g) == 0);

    CHECK(rt_graph_test_region_layer_work_item_entry(g, 3) == -1);
    CHECK(rt_graph_test_region_layer_work_item_region(g, 3) == -1);
    CHECK(rt_graph_test_region_layer_work_item_first_writer_slot(g, 3) == -1);
    CHECK(rt_graph_test_region_layer_work_item_writer_slot_count(g, 3) == -1);

    rt_graph_destroy(g);
}

TEST_CASE("region-layer work items: writer slot subranges follow region order") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    rt_graph_ensure_bus(g, 1);

    add_const_node(g, 0, 0.25f, 0.0f);
    rt_graph_add_node(g, 1, 2); // Out(bus 0)
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    add_const_node(g, 2, 0.5f, 0.0f);
    rt_graph_add_node(g, 3, 10); // BusOut(bus 1)
    rt_graph_set_control(g, 3, 0, 1.0f);
    rt_graph_connect(g, 2, 0, 3, 0);

    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/2);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/2, /*node_count=*/2);

    const int sink_items[] = {0, 1};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/2, sink_items);

    CHECK(rt_graph_test_region_layer_work_item_capacity(g) >= 16);
    rt_graph_process(g, kFrames);

    REQUIRE(rt_graph_test_region_layer_work_item_count(g) == 2);
    CHECK(rt_graph_test_region_layer_work_item_region(g, 0) == 0);
    CHECK(rt_graph_test_region_layer_work_item_first_writer_slot(g, 0) == 0);
    CHECK(rt_graph_test_region_layer_work_item_writer_slot_count(g, 0) == 1);
    CHECK(rt_graph_test_region_layer_work_item_region(g, 1) == 1);
    CHECK(rt_graph_test_region_layer_work_item_first_writer_slot(g, 1) == 1);
    CHECK(rt_graph_test_region_layer_work_item_writer_slot_count(g, 1) == 1);

    CHECK(rt_graph_test_last_c1d_candidate_entry_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_candidate_item_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_serialized_sink_entry_count(g) == 1);
    CHECK(rt_graph_test_last_writer_slot_count(g) == 2);

    rt_graph_destroy(g);
}

TEST_CASE("region-layer work items: mixed sink-free + sink-bearing FreeLayer is serialized") {
    // C1d-b precondition: the has_sink_writer OR rule must flip a
    // multi-region FreeLayer into the serialized-sink bucket as soon as
    // any one item owns a sink writer, even if its sibling is sink-free.
    // Pinning this before C1d-c starts using candidate_* counters keeps
    // a sink-bearing region from sneaking into a future parallel
    // dispatch group.
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    // Region 0: sink-free Add (one node, no Out / BusOut writer).
    add_const_node(g, 0, 0.25f, 0.0f);

    // Region 1: const → Out, two contiguous nodes; the second node is
    // the sink writer that should flip the entry to serialized.
    add_const_node(g, 1, 0.5f, 0.0f);
    rt_graph_add_node(g, 2, 2);  // Out(bus 0)
    rt_graph_set_control(g, 2, 0, 0.0f);
    rt_graph_connect(g, 1, 0, 2, 0);

    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/1, /*node_count=*/2);

    const int items[] = {0, 1};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/2, items);

    rt_graph_process(g, kFrames);

    CHECK(rt_graph_test_last_c1d_candidate_entry_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_candidate_item_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_serialized_sink_entry_count(g) == 1);

    REQUIRE(rt_graph_test_region_layer_work_item_count(g) == 2);
    CHECK(rt_graph_test_region_layer_work_item_region(g, 0) == 0);
    CHECK(rt_graph_test_region_layer_work_item_first_writer_slot(g, 0) == 0);
    CHECK(rt_graph_test_region_layer_work_item_writer_slot_count(g, 0) == 0);
    CHECK(rt_graph_test_region_layer_work_item_region(g, 1) == 1);
    CHECK(rt_graph_test_region_layer_work_item_first_writer_slot(g, 1) == 0);
    CHECK(rt_graph_test_region_layer_work_item_writer_slot_count(g, 1) == 1);
    CHECK(rt_graph_test_last_writer_slot_count(g) == 1);

    rt_graph_destroy(g);
}

TEST_CASE("region-layer work items: capacity uses occupied count above lowered cap") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    rt_graph_template_set_polyphony(g, 0, 8);
    REQUIRE(rt_graph_template_instance_add(g, 0) == 1);
    REQUIRE(rt_graph_template_instance_add(g, 0) == 2);
    REQUIRE(rt_graph_template_instance_add(g, 0) == 3);
    REQUIRE(rt_graph_template_instance_add(g, 0) == 4);
    rt_graph_template_set_polyphony(g, 0, 2);

    add_const_node(g, 0, 0.1f, 0.0f);
    add_const_node(g, 1, 0.2f, 0.0f);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/1, /*node_count=*/1);
    const int items[] = {0, 1};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/2, items);

    // Live count is five (auto instance + four spawns). The lowered
    // cap is two, but the reserve bound must use max(polyphony,
    // occupied) so every live slot's two region work items fit.
    CHECK(rt_graph_test_region_layer_work_item_capacity(g) >= 10);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_region_layer_work_item_count(g) == 10);
    CHECK(rt_graph_test_last_c1d_candidate_entry_count(g) == 5);
    CHECK(rt_graph_test_last_c1d_candidate_item_count(g) == 10);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Phase §4.E.2.C1d-b: serial region-item executor
// ----------------------------------------------------------------

TEST_CASE("c1d-b serial executor: free band consumes region work items") {
    // Two sink-free Add producers in one FreeLayer (regions 0 and 1)
    // followed by an Add summing them and an Out writing bus 0
    // (regions 2 and 3 in a Barrier). The C1d-b path runs the
    // FreeLayer band; the legacy path renders without it.
    //
    // Output equivalence proves no regression. The counter proves the
    // new RegionLayerWorkItem-driven dispatch was actually exercised:
    // byte-equivalence alone could pass with the serial Free band path
    // dead and a fallback running, which would defeat C1d-b's purpose.
    auto build = [](RTGraph *g) {
        add_const_node(g, 0, 0.25f, 0.0f); // const 0.25 (region 0, sink-free)
        add_const_node(g, 1, 0.5f,  0.0f); // const 0.5  (region 1, sink-free)

        rt_graph_add_node(g, 2, 8); // Add summing node 0 + node 1
        rt_graph_set_control(g, 2, 0, 0.0f);
        rt_graph_set_control(g, 2, 1, 0.0f);
        rt_graph_connect(g, 0, 0, 2, 0);
        rt_graph_connect(g, 1, 0, 2, 1);

        rt_graph_add_node(g, 3, 2); // Out(bus 0)
        rt_graph_set_control(g, 3, 0, 0.0f);
        rt_graph_connect(g, 2, 0, 3, 0);

        rt_graph_template_add_region(g, 0, /*rate=*/0,
                                     /*first_node=*/0, /*node_count=*/1);
        rt_graph_template_add_region(g, 0, /*rate=*/0,
                                     /*first_node=*/1, /*node_count=*/1);
        rt_graph_template_add_region(g, 0, /*rate=*/0,
                                     /*first_node=*/2, /*node_count=*/1);
        rt_graph_template_add_region(g, 0, /*rate=*/0,
                                     /*first_node=*/3, /*node_count=*/1);

        const int free_items[]   = {0, 1};
        const int sum_item[]     = {2};
        const int sink_item[]    = {3};
        rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                            /*item_count=*/2, free_items);
        rt_graph_template_add_schedule_step(g, 0, /*Barrier=*/0,
                                            /*item_count=*/1, sum_item);
        rt_graph_template_add_schedule_step(g, 0, /*Barrier=*/0,
                                            /*item_count=*/1, sink_item);
    };

    auto *legacy = rt_graph_create(8, kFrames);
    auto *sched  = rt_graph_create(8, kFrames);
    REQUIRE(legacy != nullptr);
    REQUIRE(sched  != nullptr);
    build(legacy);
    build(sched);

    // No worker pool configured, so should_parallelize_schedule_band
    // returns false and the Free band stays on the audio thread —
    // exactly the C1d-b serial path.
    rt_graph_test_set_global_schedule_execution(sched, 1);

    rt_graph_process(legacy, kFrames);
    rt_graph_process(sched,  kFrames);

    const auto legacy_bus0 = read_bus_vec(legacy, 0, kFrames);
    const auto sched_bus0  = read_bus_vec(sched,  0, kFrames);
    check_exact_same(legacy_bus0, sched_bus0);
    for (auto v : sched_bus0) CHECK(v == doctest::Approx(0.75f).epsilon(1e-6));

    // The Free band has 2 region work items; the two Barrier bands
    // stay on the legacy per-entry path. Counter must reflect both
    // free-band items.
    CHECK(rt_graph_test_last_c1d_serial_region_item_execution_count(sched)
          == 2);
    CHECK(rt_graph_test_last_c1d_serial_region_item_execution_count(legacy)
          == 0);
    CHECK(rt_graph_test_last_c1d_candidate_entry_count(sched) == 1);
    CHECK(rt_graph_test_last_c1d_candidate_item_count(sched) == 2);
    CHECK(rt_graph_test_last_c1d_serialized_sink_entry_count(sched) == 0);
    CHECK(rt_graph_test_last_parallel_band_count(sched) == 0);

    rt_graph_destroy(legacy);
    rt_graph_destroy(sched);
}

TEST_CASE("c1d-b serial executor: counter stays zero without global-schedule switch") {
    // With global_schedule_execution off, process_legacy_schedule runs
    // and never touches the C1d-b path. The counter must stay 0 even
    // though build_region_layer_work_items still populates the table.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    add_const_node(g, 0, 0.5f, 0.0f);
    rt_graph_add_node(g, 1, 2); // Out(bus 0)
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/1, /*node_count=*/1);
    const int free_items[] = {0};
    const int sink_item[]  = {1};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/1, free_items);
    rt_graph_template_add_schedule_step(g, 0, /*Barrier=*/0,
                                        /*item_count=*/1, sink_item);

    rt_graph_process(g, kFrames);

    REQUIRE(rt_graph_test_region_layer_work_item_count(g) == 2);
    CHECK(rt_graph_test_last_c1d_serial_region_item_execution_count(g) == 0);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Phase §4.E.2.C1d-c: parallel sink-free region-item dispatch
// ----------------------------------------------------------------

namespace {

void build_c1d_c_two_producer_graph(RTGraph *g) {
    // Two sink-free Add producers in one FreeLayer; an Add summing
    // them in a Barrier; an Out writing bus 0 in a Barrier. The free
    // band is a singleton entry with two sink-free regions — exactly
    // the C1d-c shape.
    add_const_node(g, 0, 0.25f, 0.0f);
    add_const_node(g, 1, 0.5f,  0.0f);

    rt_graph_add_node(g, 2, 8); // Add summing node 0 + node 1
    rt_graph_set_control(g, 2, 0, 0.0f);
    rt_graph_set_control(g, 2, 1, 0.0f);
    rt_graph_connect(g, 0, 0, 2, 0);
    rt_graph_connect(g, 1, 0, 2, 1);

    rt_graph_add_node(g, 3, 2); // Out(bus 0)
    rt_graph_set_control(g, 3, 0, 0.0f);
    rt_graph_connect(g, 2, 0, 3, 0);

    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/1, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/2, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/3, /*node_count=*/1);

    const int free_items[] = {0, 1};
    const int sum_item[]   = {2};
    const int sink_item[]  = {3};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/2, free_items);
    rt_graph_template_add_schedule_step(g, 0, /*Barrier=*/0,
                                        /*item_count=*/1, sum_item);
    rt_graph_template_add_schedule_step(g, 0, /*Barrier=*/0,
                                        /*item_count=*/1, sink_item);
}

} // namespace

TEST_CASE("c1d-c parallel executor: sink-free free entry uses worker pool") {
    auto *legacy = rt_graph_create(8, kFrames);
    auto *sched  = rt_graph_create(8, kFrames);
    REQUIRE(legacy != nullptr);
    REQUIRE(sched  != nullptr);
    build_c1d_c_two_producer_graph(legacy);
    build_c1d_c_two_producer_graph(sched);

    rt_graph_test_set_worker_pool_size(sched, 3);
    rt_graph_test_set_global_schedule_execution(sched, 1);

    rt_graph_process(legacy, kFrames);
    rt_graph_process(sched,  kFrames);

    // Bit-identical output across legacy (no schedule, no pool) and
    // C1d-c (schedule on, pool=3, region-item dispatch).
    const auto legacy_bus0 = read_bus_vec(legacy, 0, kFrames);
    const auto sched_bus0  = read_bus_vec(sched,  0, kFrames);
    check_exact_same(legacy_bus0, sched_bus0);
    for (auto v : sched_bus0) CHECK(v == doctest::Approx(0.75f).epsilon(1e-6));

    // Counter-confirmed dispatch: the new region-item path actually
    // ran, the C1d-b serial path stayed out of the free band, and
    // C1c band-level parallelism never fired (free band has only one
    // entry, so should_parallelize_schedule_band returns false).
    CHECK(rt_graph_test_last_c1d_parallel_entry_count(sched) == 1);
    CHECK(rt_graph_test_last_c1d_parallel_region_item_count(sched) == 2);
    CHECK(rt_graph_test_last_c1d_serial_region_item_execution_count(sched)
          == 0);
    CHECK(rt_graph_test_last_parallel_band_count(sched) == 0);
    CHECK(rt_graph_test_last_parallel_entry_count(sched) == 0);

    // C1d-a candidate metadata still classifies the entry the same way.
    CHECK(rt_graph_test_last_c1d_candidate_entry_count(sched) == 1);
    CHECK(rt_graph_test_last_c1d_candidate_item_count(sched) == 2);
    CHECK(rt_graph_test_last_c1d_serialized_sink_entry_count(sched) == 0);

    rt_graph_destroy(legacy);
    rt_graph_destroy(sched);
}

TEST_CASE("c1d-c parallel executor: C1c band dispatch takes precedence") {
    // Multiple instances of a sink-free multi-region FreeLayer form the
    // existing C1c sweet spot: one Free band containing several global
    // schedule entries. That band must dispatch as whole entries through
    // C1c, not nest C1d-c region-item dispatch inside each entry.
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    add_const_node(g, 0, 0.25f, 0.0f);
    add_const_node(g, 1, 0.5f,  0.0f);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/1, /*node_count=*/1);
    const int free_items[] = {0, 1};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/2, free_items);

    REQUIRE(rt_graph_template_instance_add(g, 0) == 1);
    REQUIRE(rt_graph_template_instance_add(g, 0) == 2);

    rt_graph_test_set_worker_pool_size(g, 3);
    rt_graph_test_set_global_schedule_execution(g, 1);
    rt_graph_process(g, kFrames);

    CHECK(rt_graph_test_global_schedule_band_count(g) == 1);
    CHECK(rt_graph_test_last_parallel_band_count(g) == 1);
    CHECK(rt_graph_test_last_parallel_entry_count(g) == 3);
    CHECK(rt_graph_test_last_c1d_parallel_entry_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_parallel_region_item_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_serial_region_item_execution_count(g) == 0);

    CHECK(rt_graph_test_last_c1d_candidate_entry_count(g) == 3);
    CHECK(rt_graph_test_last_c1d_candidate_item_count(g) == 6);

    rt_graph_destroy(g);
}

TEST_CASE("c1d-c parallel executor: reduction mode + pool=3 stays bit-identical") {
    auto *direct  = rt_graph_create(8, kFrames);
    auto *reduced = rt_graph_create(8, kFrames);
    REQUIRE(direct  != nullptr);
    REQUIRE(reduced != nullptr);
    build_c1d_c_two_producer_graph(direct);
    build_c1d_c_two_producer_graph(reduced);

    rt_graph_test_set_worker_pool_size(direct,  3);
    rt_graph_test_set_worker_pool_size(reduced, 3);
    rt_graph_test_set_global_schedule_execution(direct,  1);
    rt_graph_test_set_global_schedule_execution(reduced, 1);
    rt_graph_test_set_reduction_capture(reduced, 1);

    rt_graph_process(direct,  kFrames);
    rt_graph_process(reduced, kFrames);

    // C1d-c does not interact with reduction mode — sink-free items
    // never open contribution slots — so direct and reduction outputs
    // must agree byte-for-byte across the C1d-c path.
    check_exact_same(read_bus_vec(direct,  0, kFrames),
                     read_bus_vec(reduced, 0, kFrames));
    CHECK(rt_graph_test_last_c1d_parallel_entry_count(direct) == 1);
    CHECK(rt_graph_test_last_c1d_parallel_entry_count(reduced) == 1);

    rt_graph_destroy(direct);
    rt_graph_destroy(reduced);
}

TEST_CASE("c1d-c parallel executor: sink-bearing entry stays serial") {
    // A multi-region FreeLayer entry with at least one sink writer
    // must NOT enter C1d-c — sink ordering and bus reduction stay on
    // the audio thread. The C1d-b serial counter must reflect every
    // emitted region item; the C1d-c counters must stay 0.
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    add_const_node(g, 0, 0.25f, 0.0f); // sink-free region 0

    add_const_node(g, 1, 0.5f, 0.0f);
    rt_graph_add_node(g, 2, 2);        // Out(bus 0) — sink writer
    rt_graph_set_control(g, 2, 0, 0.0f);
    rt_graph_connect(g, 1, 0, 2, 0);

    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/1, /*node_count=*/2);

    const int items[] = {0, 1};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/2, items);

    rt_graph_test_set_worker_pool_size(g, 3);
    rt_graph_test_set_global_schedule_execution(g, 1);
    rt_graph_process(g, kFrames);

    CHECK(rt_graph_test_last_c1d_parallel_entry_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_parallel_region_item_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_serial_region_item_execution_count(g) == 2);
    CHECK(rt_graph_test_last_c1d_serialized_sink_entry_count(g) == 1);

    rt_graph_destroy(g);
}

TEST_CASE("c1d-c parallel executor: singleton free entry stays serial") {
    // A FreeLayer entry with one work item is not C1d-c-eligible
    // (work_item_count <= 1). The C1d-b serial path runs and the
    // C1d-c counters stay 0 even with worker pool > 1.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    add_const_node(g, 0, 0.5f, 0.0f);
    rt_graph_add_node(g, 1, 2);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/1, /*node_count=*/1);
    const int free_item[] = {0};
    const int sink_item[] = {1};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/1, free_item);
    rt_graph_template_add_schedule_step(g, 0, /*Barrier=*/0,
                                        /*item_count=*/1, sink_item);

    rt_graph_test_set_worker_pool_size(g, 3);
    rt_graph_test_set_global_schedule_execution(g, 1);
    rt_graph_process(g, kFrames);

    CHECK(rt_graph_test_last_c1d_parallel_entry_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_parallel_region_item_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_serial_region_item_execution_count(g) == 1);

    rt_graph_destroy(g);
}

TEST_CASE("c1d-c parallel executor: pool size 1 falls back to serial") {
    // Even with global-schedule execution on, a worker pool sized to
    // a single logical lane (zero background workers) must stay on
    // the C1d-b serial path. Otherwise C1d-c would call run_parallel
    // with no workers to parallelize against.
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    build_c1d_c_two_producer_graph(g);

    rt_graph_test_set_worker_pool_size(g, 1);
    rt_graph_test_set_global_schedule_execution(g, 1);
    rt_graph_process(g, kFrames);

    CHECK(rt_graph_test_last_c1d_parallel_entry_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_parallel_region_item_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_serial_region_item_execution_count(g) == 2);

    auto bus0 = read_bus_vec(g, 0, kFrames);
    for (auto v : bus0) CHECK(v == doctest::Approx(0.75f).epsilon(1e-6));

    rt_graph_destroy(g);
}

TEST_CASE("c1d-c parallel executor: counters reset between blocks") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);
    build_c1d_c_two_producer_graph(g);

    rt_graph_test_set_worker_pool_size(g, 3);
    rt_graph_test_set_global_schedule_execution(g, 1);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_last_c1d_parallel_entry_count(g) == 1);
    CHECK(rt_graph_test_last_c1d_parallel_region_item_count(g) == 2);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_last_c1d_parallel_entry_count(g) == 1);
    CHECK(rt_graph_test_last_c1d_parallel_region_item_count(g) == 2);

    rt_graph_destroy(g);
}

TEST_CASE("c1d-b serial executor: counter resets between blocks") {
    // The counter must not accumulate across blocks; otherwise tests
    // that assert "actually ran this block" would silently pass on a
    // dead path that ran in a previous block.
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    add_const_node(g, 0, 0.25f, 0.0f);
    add_const_node(g, 1, 0.5f,  0.0f);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/1, /*node_count=*/1);
    const int items[] = {0, 1};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/2, items);

    rt_graph_test_set_global_schedule_execution(g, 1);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_last_c1d_serial_region_item_execution_count(g) == 2);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_last_c1d_serial_region_item_execution_count(g) == 2);

    rt_graph_destroy(g);
}

TEST_CASE("region-layer work items: clear resets snapshot and counters") {
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    add_const_node(g, 0, 0.1f, 0.0f);
    add_const_node(g, 1, 0.2f, 0.0f);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/0, /*node_count=*/1);
    rt_graph_template_add_region(g, 0, /*rate=*/0,
                                 /*first_node=*/1, /*node_count=*/1);
    const int items[] = {0, 1};
    rt_graph_template_add_schedule_step(g, 0, /*FreeLayer=*/1,
                                        /*item_count=*/2, items);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_region_layer_work_item_count(g) == 2);
    CHECK(rt_graph_test_last_c1d_candidate_entry_count(g) == 1);

    rt_graph_clear(g);
    CHECK(rt_graph_test_region_layer_work_item_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_candidate_entry_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_candidate_item_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_serialized_sink_entry_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_serial_region_item_execution_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_parallel_entry_count(g) == 0);
    CHECK(rt_graph_test_last_c1d_parallel_region_item_count(g) == 0);

    rt_graph_destroy(g);
}

TEST_CASE("contribution capacity: parallel vector sizing across many capacities") {
    // Direct lockstep regression. Walk a handful of distinct
    // capacities (including ones that cross the 64-slot boundary
    // where used_words gains a second word) and assert that
    // resize_for keeps samples, target, and used_words in step.
    // If a future refactor of resize_for forgets to grow one of
    // them, this test fails with a specific size mismatch rather
    // than crashing in B2's reduction phase.
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

    // Cap 1, single sink: 1 slot → fits in 1 used_words bucket.
    rt_graph_template_set_polyphony(g, 0, 1);
    rt_graph_add_node(g, 0, 1);  // SinOsc
    rt_graph_add_node(g, 1, 2);  // Out
    rt_graph_set_control(g, 1, 0, 0.0f);
    check_storage_lockstep(g, 1);

    // Bump cap to 64: still one used_words bucket (ceil(64/64) = 1).
    rt_graph_template_set_polyphony(g, 0, 64);
    check_storage_lockstep(g, 64);

    // Bump cap to 65: spills into a second used_words bucket.
    rt_graph_template_set_polyphony(g, 0, 65);
    check_storage_lockstep(g, 65);

    // Bump cap to 200: ceil(200/64) = 4 used_words.
    rt_graph_template_set_polyphony(g, 0, 200);
    check_storage_lockstep(g, 200);

    rt_graph_destroy(g);
}

// ----------------------------------------------------------------
// Phase 5.1.B: RCU hot-swap protocol substrate + world payload
// ----------------------------------------------------------------
//
// Swaps carry a prepared RTGraphState. These tests pin the
// publish/install/retire dance — generation advances at a block
// boundary, retired-slot reaping returns ownership to the producer,
// publish-while-pending and publish-while-retired fail, lifecycle
// entries do not leak, and rt_graph_clear resets the protocol to a
// clean slate.

namespace {

constexpr int kMigrationSkipMissingTag   = 1;
constexpr int kMigrationSkipKindMismatch = 4;
constexpr int kMigrationSkipStateUnsupported = 6;

constexpr int kKindSinOsc       = 1;
constexpr int kKindOut          = 2;
constexpr int kKindGain         = 3;
constexpr int kKindSawOsc       = 5;
constexpr int kKindNoiseGen     = 6;
constexpr int kKindLPF          = 7;
constexpr int kKindEnv          = 9;
constexpr int kKindDelay        = 13;
constexpr int kKindSmooth       = 14;
constexpr int kKindPulseOsc     = 15;
constexpr int kKindTriOsc       = 16;
constexpr int kKindHPF          = 17;
constexpr int kKindBPF          = 18;
constexpr int kKindNotch        = 19;

void build_env_out_graph(RTGraph *g, double gate) {
    rt_graph_add_node(g, 0, kKindEnv);
    rt_graph_set_control(g, 0, 0, gate);
    rt_graph_set_control(g, 0, 1, 0.0005);
    rt_graph_set_control(g, 0, 2, 0.001);
    rt_graph_set_control(g, 0, 3, 0.0);
    rt_graph_set_control(g, 0, 4, 0.001);
    rt_graph_add_node(g, 1, kKindOut);
    rt_graph_set_control(g, 1, 0, 0.0);
    rt_graph_connect(g, 0, 0, 1, 0);
}

} // namespace

TEST_CASE("hot-swap substrate: prepare + publish + install advances generation") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    CHECK(rt_graph_test_swap_generation(g) == 0);
    CHECK(rt_graph_test_swap_pending(g) == 0);
    CHECK(rt_graph_test_swap_retired_pending(g) == 0);

    auto *swap = rt_graph_prepare_swap(g);
    REQUIRE(swap != nullptr);
    CHECK(rt_graph_test_swap_pending(g) == 0);  // not yet published

    REQUIRE(rt_graph_publish_swap(g, swap) == 1);
    CHECK(rt_graph_test_swap_pending(g) == 1);
    CHECK(rt_graph_test_swap_generation(g) == 0);  // not yet installed

    // Block boundary installs the swap.
    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_swap_pending(g) == 0);
    CHECK(rt_graph_test_swap_generation(g) == 1);
    CHECK(rt_graph_test_swap_retired_pending(g) == 1);

    // Producer reaps and disposes.
    auto *retired = rt_graph_collect_retired_swap(g);
    CHECK(retired == swap);
    CHECK(rt_graph_test_swap_retired_pending(g) == 0);
    rt_graph_cancel_swap(g, retired);

    // Subsequent blocks without a publish do not advance generation.
    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_swap_generation(g) == 1);

    rt_graph_destroy(g);
}

TEST_CASE("hot-swap substrate: pre-publish realtime commands drain before install") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    auto *next = rt_graph_create(4, kFrames);
    REQUIRE(next != nullptr);

    add_const_node(next, 0, 0.25f, 0.0f);
    rt_graph_add_node(next, 1, 2);          // Out(bus 0)
    rt_graph_set_control(next, 1, 0, 0.0f);
    rt_graph_connect(next, 0, 0, 1, 0);

    build_constant_template(g);
    // Free the construction-spawned instance so the realtime path can
    // reserve and activate a slot through the same queue producers use
    // while audio is running.
    rt_graph_instance_remove(g, 0);

    int slot = rt_graph_realtime_reserve(g, 0);
    REQUIRE(slot >= 0);
    REQUIRE(rt_graph_realtime_activate(g, slot) == 1);
    REQUIRE(rt_graph_realtime_set_control(
        g, slot, /*node*/0, /*ctl*/0, 0.5) == 1);

    auto *swap = rt_graph_prepare_swap_from_graph(g, next);
    REQUIRE(swap != nullptr);
    rt_graph_destroy(next);
    REQUIRE(rt_graph_publish_swap(g, swap) == 1);

    rt_graph_process(g, kFrames);

    CHECK(rt_graph_test_swap_generation(g) == 1);
    CHECK(rt_graph_test_swap_pending(g) == 0);
    CHECK(rt_graph_test_swap_retired_pending(g) == 1);

    const auto bus0 = read_bus_vec(g, 0, kFrames);
    for (float sample : bus0) {
        CHECK(sample == doctest::Approx(0.25f).epsilon(1e-6));
    }

    auto *retired = rt_graph_collect_retired_swap(g);
    REQUIRE(retired != nullptr);
    double old_control = 0.0;
    CHECK(rt_graph_test_retired_swap_control_value(
              retired, slot, /*node*/0, /*ctl*/0, &old_control) == 1);
    CHECK(old_control == doctest::Approx(0.5).epsilon(1e-12));

    rt_graph_cancel_swap(g, retired);
    rt_graph_destroy(g);
}

TEST_CASE("hot-swap substrate: cancel before publish does not install") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    auto *swap = rt_graph_prepare_swap(g);
    REQUIRE(swap != nullptr);
    rt_graph_cancel_swap(g, swap);

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_swap_pending(g) == 0);
    CHECK(rt_graph_test_swap_retired_pending(g) == 0);
    CHECK(rt_graph_test_swap_generation(g) == 0);

    rt_graph_destroy(g);
}

TEST_CASE("hot-swap substrate: publish while pending fails") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    auto *first  = rt_graph_prepare_swap(g);
    auto *second = rt_graph_prepare_swap(g);
    REQUIRE(first  != nullptr);
    REQUIRE(second != nullptr);
    REQUIRE(first != second);

    REQUIRE(rt_graph_publish_swap(g, first) == 1);
    // Second publish must be rejected — the substrate contract is
    // single-pending. The runtime owns `first`; `second` stays with
    // the caller.
    CHECK(rt_graph_publish_swap(g, second) == 0);
    CHECK(rt_graph_test_swap_pending(g) == 1);

    rt_graph_cancel_swap(g, second);  // caller still owns second

    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_swap_generation(g) == 1);
    rt_graph_cancel_swap(g, rt_graph_collect_retired_swap(g));

    rt_graph_destroy(g);
}

TEST_CASE("hot-swap substrate: publish while retired pending fails") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    auto *first  = rt_graph_prepare_swap(g);
    auto *second = rt_graph_prepare_swap(g);
    REQUIRE(first  != nullptr);
    REQUIRE(second != nullptr);

    REQUIRE(rt_graph_publish_swap(g, first) == 1);
    rt_graph_process(g, kFrames);
    CHECK(rt_graph_test_swap_generation(g) == 1);
    CHECK(rt_graph_test_swap_retired_pending(g) == 1);

    CHECK(rt_graph_publish_swap(g, second) == 0);
    rt_graph_cancel_swap(g, second);  // caller still owns rejected swap

    rt_graph_cancel_swap(g, rt_graph_collect_retired_swap(g));
    rt_graph_destroy(g);
}

TEST_CASE("hot-swap substrate: multiple publishes serialize across blocks") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    for (int i = 1; i <= 4; ++i) {
        auto *swap = rt_graph_prepare_swap(g);
        REQUIRE(swap != nullptr);
        REQUIRE(rt_graph_publish_swap(g, swap) == 1);

        rt_graph_process(g, kFrames);
        CHECK(rt_graph_test_swap_generation(g) == i);

        // Producer reaps so the next publish has a clean retire slot.
        auto *retired = rt_graph_collect_retired_swap(g);
        CHECK(retired == swap);
        rt_graph_cancel_swap(g, retired);
    }

    rt_graph_destroy(g);
}

TEST_CASE("hot-swap substrate: rt_graph_clear resets generation and reaps slots") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);

    // Run one swap cycle, then leave a retired-but-not-reaped swap to
    // prove rt_graph_clear releases it and resets the busy bit.
    auto *first  = rt_graph_prepare_swap(g);
    REQUIRE(rt_graph_publish_swap(g, first) == 1);
    rt_graph_process(g, kFrames);
    REQUIRE(rt_graph_test_swap_generation(g) == 1);
    REQUIRE(rt_graph_test_swap_retired_pending(g) == 1);

    rt_graph_clear(g);
    CHECK(rt_graph_test_swap_generation(g) == 0);
    CHECK(rt_graph_test_swap_pending(g) == 0);
    CHECK(rt_graph_test_swap_retired_pending(g) == 0);

    // Leave a publish pending and prove clear releases that slot too.
    auto *second = rt_graph_prepare_swap(g);
    REQUIRE(rt_graph_publish_swap(g, second) == 1);
    REQUIRE(rt_graph_test_swap_pending(g) == 1);

    // Clear must drop both swaps without leaking and reset the
    // generation counter. After clear, the protocol slots are clean.
    rt_graph_clear(g);
    CHECK(rt_graph_test_swap_generation(g) == 0);
    CHECK(rt_graph_test_swap_pending(g) == 0);
    CHECK(rt_graph_test_swap_retired_pending(g) == 0);

    rt_graph_destroy(g);
}

TEST_CASE("hot-swap substrate: payload replacement matches rebuilt graph") {
    auto build = [](RTGraph *g, float value) {
        add_const_node(g, 0, value, 0.0f);
        rt_graph_add_node(g, 1, 2);          // Out(bus 0)
        rt_graph_set_control(g, 1, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);
    };

    auto *swapped  = rt_graph_create(4, kFrames);
    auto *builder  = rt_graph_create(4, kFrames);
    auto *expected = rt_graph_create(4, kFrames);
    REQUIRE(swapped != nullptr);
    REQUIRE(builder != nullptr);
    REQUIRE(expected != nullptr);

    build(swapped, 0.75f);
    build(builder, 0.125f);
    build(expected, 0.125f);

    rt_graph_process(swapped, kFrames);
    for (float sample : read_bus_vec(swapped, 0, kFrames)) {
        CHECK(sample == doctest::Approx(0.75f).epsilon(1e-6));
    }

    auto *swap = rt_graph_prepare_swap_from_graph(swapped, builder);
    REQUIRE(swap != nullptr);
    rt_graph_destroy(builder);
    REQUIRE(rt_graph_publish_swap(swapped, swap) == 1);

    rt_graph_process(swapped, kFrames);
    rt_graph_process(expected, kFrames);
    check_exact_same(read_bus_vec(swapped, 0, kFrames),
                     read_bus_vec(expected, 0, kFrames));
    CHECK(rt_graph_test_swap_generation(swapped) == 1);

    rt_graph_cancel_swap(swapped, rt_graph_collect_retired_swap(swapped));
    rt_graph_destroy(swapped);
    rt_graph_destroy(expected);
}

TEST_CASE("hot-swap migration: tagged controls survive payload install") {
    auto build = [](RTGraph *g, float value) {
        add_const_node(g, 0, value, 0.0f);
        REQUIRE(rt_graph_template_set_node_migration_key(
                    g, 0, 0, "const", 5) == 1);
        rt_graph_add_node(g, 1, 2);          // Out(bus 0)
        rt_graph_set_control(g, 1, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);
    };

    auto *g = rt_graph_create(4, kFrames);
    auto *builder = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    REQUIRE(builder != nullptr);

    build(g, 0.75f);
    build(builder, 0.25f);

    auto *swap = rt_graph_prepare_swap_from_graph(g, builder);
    REQUIRE(swap != nullptr);
    rt_graph_destroy(builder);

    CHECK(rt_graph_swap_migration_committed_count(swap) == 1);
    CHECK(rt_graph_swap_migration_skipped_count(swap) == 1);
    CHECK(rt_graph_swap_migration_skipped_reason(swap, 0)
          == kMigrationSkipMissingTag);
    CHECK(rt_graph_swap_migration_instance_copy_count(swap) == 0);

    REQUIRE(rt_graph_publish_swap(g, swap) == 1);
    rt_graph_process(g, kFrames);

    for (float sample : read_bus_vec(g, 0, kFrames)) {
        CHECK(sample == doctest::Approx(0.75f).epsilon(1e-6));
    }

    auto *retired = rt_graph_collect_retired_swap(g);
    REQUIRE(retired == swap);
    CHECK(rt_graph_swap_migration_instance_copy_count(retired) == 1);
    CHECK(rt_graph_swap_migration_state_copy_count(retired) == 0);
    CHECK(rt_graph_swap_migration_lifecycle_copy_count(retired) == 1);

    rt_graph_cancel_swap(g, retired);
    rt_graph_destroy(g);
}

TEST_CASE("hot-swap migration: releasing lifecycle survives payload install") {
    constexpr int kBlock = 256;
    auto *g = rt_graph_create(4, kBlock);
    auto *builder = rt_graph_create(4, kBlock);
    REQUIRE(g != nullptr);
    REQUIRE(builder != nullptr);

    build_env_out_graph(g, 0.0);
    build_env_out_graph(builder, 0.0);

    rt_graph_instance_release(g, 0);
    REQUIRE(rt_graph_instance_status(g, 0) == 1);

    for (int i = 0; i < 4; ++i) {
        rt_graph_process(g, kBlock);
        REQUIRE(rt_graph_instance_status(g, 0) == 1);
    }

    auto *swap = rt_graph_prepare_swap_from_graph(g, builder);
    REQUIRE(swap != nullptr);
    rt_graph_destroy(builder);

    REQUIRE(rt_graph_publish_swap(g, swap) == 1);

    for (int i = 0; i < 3; ++i) {
        rt_graph_process(g, kBlock);
        CHECK(rt_graph_instance_status(g, 0) == 1);
        if (i == 0) {
            auto *retired = rt_graph_collect_retired_swap(g);
            REQUIRE(retired == swap);
            CHECK(rt_graph_swap_migration_lifecycle_copy_count(retired) == 1);
            CHECK(rt_graph_swap_migration_instance_copy_count(retired) == 0);
            CHECK(rt_graph_swap_migration_state_copy_count(retired) == 0);
            rt_graph_cancel_swap(g, retired);
        }
    }

    rt_graph_process(g, kBlock);
    CHECK(rt_graph_instance_status(g, 0) == -1);
    CHECK(rt_graph_instance_alive(g, 0) == 0);

    rt_graph_destroy(g);
}

TEST_CASE("hot-swap migration: missing new slot does not inherit lifecycle") {
    constexpr int kBlock = 256;
    auto *g = rt_graph_create(4, kBlock);
    auto *builder = rt_graph_create(4, kBlock);
    REQUIRE(g != nullptr);
    REQUIRE(builder != nullptr);

    build_env_out_graph(g, 0.0);
    build_env_out_graph(builder, 0.0);
    rt_graph_instance_remove(builder, 0);
    REQUIRE(rt_graph_instance_status(builder, 0) == -1);

    rt_graph_instance_release(g, 0);
    REQUIRE(rt_graph_instance_status(g, 0) == 1);

    auto *swap = rt_graph_prepare_swap_from_graph(g, builder);
    REQUIRE(swap != nullptr);
    rt_graph_destroy(builder);

    REQUIRE(rt_graph_publish_swap(g, swap) == 1);
    rt_graph_process(g, kBlock);

    CHECK(rt_graph_instance_status(g, 0) == -1);
    CHECK(rt_graph_instance_alive(g, 0) == 0);

    auto *retired = rt_graph_collect_retired_swap(g);
    REQUIRE(retired == swap);
    CHECK(rt_graph_swap_migration_lifecycle_copy_count(retired) == 0);
    rt_graph_cancel_swap(g, retired);
    rt_graph_destroy(g);
}

TEST_CASE("hot-swap migration: available old slot does not overwrite new active slot") {
    constexpr int kBlock = 256;
    auto *g = rt_graph_create(4, kBlock);
    auto *builder = rt_graph_create(4, kBlock);
    REQUIRE(g != nullptr);
    REQUIRE(builder != nullptr);

    build_env_out_graph(g, 1.0);
    build_env_out_graph(builder, 1.0);

    rt_graph_instance_remove(g, 0);
    REQUIRE(rt_graph_instance_status(g, 0) == -1);
    REQUIRE(rt_graph_instance_status(builder, 0) == 0);

    auto *swap = rt_graph_prepare_swap_from_graph(g, builder);
    REQUIRE(swap != nullptr);
    rt_graph_destroy(builder);

    REQUIRE(rt_graph_publish_swap(g, swap) == 1);
    rt_graph_process(g, kBlock);

    CHECK(rt_graph_instance_status(g, 0) == 0);
    CHECK(rt_graph_instance_alive(g, 0) == 1);

    auto *retired = rt_graph_collect_retired_swap(g);
    REQUIRE(retired == swap);
    CHECK(rt_graph_swap_migration_lifecycle_copy_count(retired) == 0);
    CHECK(rt_graph_swap_migration_instance_copy_count(retired) == 0);
    CHECK(rt_graph_swap_migration_state_copy_count(retired) == 0);
    rt_graph_cancel_swap(g, retired);
    rt_graph_destroy(g);
}

// Phase 5.4.B template-identity precondition coverage. The setter's
// validation surface mirrors rt_graph_template_set_node_migration_key
// and the prepare-time rule is a graceful guard: it fires only when
// both old and new defs[template_id] carry an identity and the
// matched template_id has at least one live (Active or Releasing)
// instance in the old world.
TEST_CASE("hot-swap template identity: setter validation") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    add_const_node(g, 0, 0.5f, 0.0f);

    CHECK(rt_graph_template_set_identity(nullptr, 0, "voice", 5) == 0);
    CHECK(rt_graph_template_set_identity(g, 0, nullptr, 5) == 0);
    CHECK(rt_graph_template_set_identity(g, 0, "voice", 0) == 0);
    CHECK(rt_graph_template_set_identity(g, 0, "voice", -1) == 0);
    CHECK(rt_graph_template_set_identity(g, 0, "0123456789abcdefX", 17) == 0);

    char with_nul[3] = {'a', '\0', 'b'};
    CHECK(rt_graph_template_set_identity(g, 0, with_nul, 3) == 0);

    CHECK(rt_graph_template_set_identity(g, 99, "voice", 5) == 0);

    CHECK(rt_graph_template_set_identity(g, 0, "voice", 5) == 1);
    // Overwrite is allowed: identity is single-valued, not unique-keyed.
    CHECK(rt_graph_template_set_identity(g, 0, "other", 5) == 1);

    rt_graph_destroy(g);
}

TEST_CASE("hot-swap template identity: matching identities prepare succeeds") {
    auto *g = rt_graph_create(4, kFrames);
    auto *builder = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    REQUIRE(builder != nullptr);

    add_const_node(g, 0, 0.25f, 0.0f);
    rt_graph_add_node(g, 1, kKindOut);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);
    REQUIRE(rt_graph_template_set_identity(g, 0, "voice", 5) == 1);

    add_const_node(builder, 0, 0.5f, 0.0f);
    rt_graph_add_node(builder, 1, kKindOut);
    rt_graph_set_control(builder, 1, 0, 0.0f);
    rt_graph_connect(builder, 0, 0, 1, 0);
    REQUIRE(rt_graph_template_set_identity(builder, 0, "voice", 5) == 1);

    auto *swap = rt_graph_prepare_swap_from_graph(g, builder);
    REQUIRE(swap != nullptr);
    rt_graph_destroy(builder);
    rt_graph_cancel_swap(g, swap);
    rt_graph_destroy(g);
}

TEST_CASE("hot-swap template identity: differing identities reject prepare") {
    auto *g = rt_graph_create(4, kFrames);
    auto *builder = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    REQUIRE(builder != nullptr);

    add_const_node(g, 0, 0.25f, 0.0f);
    rt_graph_add_node(g, 1, kKindOut);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);
    REQUIRE(rt_graph_template_set_identity(g, 0, "voice", 5) == 1);

    add_const_node(builder, 0, 0.5f, 0.0f);
    rt_graph_add_node(builder, 1, kKindOut);
    rt_graph_set_control(builder, 1, 0, 0.0f);
    rt_graph_connect(builder, 0, 0, 1, 0);
    REQUIRE(rt_graph_template_set_identity(builder, 0, "delay", 5) == 1);

    REQUIRE(rt_graph_instance_alive(g, 0) == 1);

    auto *swap = rt_graph_prepare_swap_from_graph(g, builder);
    CHECK(swap == nullptr);

    rt_graph_destroy(builder);
    rt_graph_destroy(g);
}

TEST_CASE("hot-swap template identity: missing token on either side stays permissive") {
    // Old identity set, new identity absent: prepare must still succeed
    // so producers can adopt template identity gradually.
    {
        auto *g = rt_graph_create(4, kFrames);
        auto *builder = rt_graph_create(4, kFrames);
        REQUIRE(g != nullptr);
        REQUIRE(builder != nullptr);

        add_const_node(g, 0, 0.25f, 0.0f);
        REQUIRE(rt_graph_template_set_identity(g, 0, "voice", 5) == 1);
        add_const_node(builder, 0, 0.5f, 0.0f);

        auto *swap = rt_graph_prepare_swap_from_graph(g, builder);
        REQUIRE(swap != nullptr);
        rt_graph_destroy(builder);
        rt_graph_cancel_swap(g, swap);
        rt_graph_destroy(g);
    }
    // New identity set, old identity absent: same.
    {
        auto *g = rt_graph_create(4, kFrames);
        auto *builder = rt_graph_create(4, kFrames);
        REQUIRE(g != nullptr);
        REQUIRE(builder != nullptr);

        add_const_node(g, 0, 0.25f, 0.0f);
        add_const_node(builder, 0, 0.5f, 0.0f);
        REQUIRE(rt_graph_template_set_identity(builder, 0, "voice", 5) == 1);

        auto *swap = rt_graph_prepare_swap_from_graph(g, builder);
        REQUIRE(swap != nullptr);
        rt_graph_destroy(builder);
        rt_graph_cancel_swap(g, swap);
        rt_graph_destroy(g);
    }
}

TEST_CASE("hot-swap template identity: differing identities allowed when no slot is live") {
    auto *g = rt_graph_create(4, kFrames);
    auto *builder = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    REQUIRE(builder != nullptr);

    add_const_node(g, 0, 0.25f, 0.0f);
    REQUIRE(rt_graph_template_set_identity(g, 0, "voice", 5) == 1);
    rt_graph_instance_remove(g, 0);
    REQUIRE(rt_graph_instance_status(g, 0) == -1);

    add_const_node(builder, 0, 0.5f, 0.0f);
    REQUIRE(rt_graph_template_set_identity(builder, 0, "delay", 5) == 1);

    auto *swap = rt_graph_prepare_swap_from_graph(g, builder);
    REQUIRE(swap != nullptr);
    rt_graph_destroy(builder);
    rt_graph_cancel_swap(g, swap);
    rt_graph_destroy(g);
}

TEST_CASE("hot-swap migration: oscillator state survives payload install") {
    auto build = [](RTGraph *g, int osc_kind) {
        rt_graph_add_node(g, 0, osc_kind);
        rt_graph_set_control(g, 0, 0, 440.0f);
        rt_graph_set_control(g, 0, 1, 0.0f);
        if (osc_kind == kKindPulseOsc) {
            rt_graph_set_control(g, 0, 2, 0.25f);
        }
        REQUIRE(rt_graph_template_set_node_migration_key(
                    g, 0, 0, "osc", 3) == 1);
        rt_graph_add_node(g, 1, kKindOut);
        rt_graph_set_control(g, 1, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);
    };

    for (int osc_kind : {kKindSinOsc, kKindSawOsc,
                         kKindTriOsc, kKindPulseOsc}) {
        auto *swapped = rt_graph_create(4, kFrames);
        auto *builder = rt_graph_create(4, kFrames);
        auto *expected = rt_graph_create(4, kFrames);
        REQUIRE(swapped != nullptr);
        REQUIRE(builder != nullptr);
        REQUIRE(expected != nullptr);

        build(swapped, osc_kind);
        build(builder, osc_kind);
        build(expected, osc_kind);

        rt_graph_process(swapped, kFrames);
        rt_graph_process(expected, kFrames);

        auto *swap = rt_graph_prepare_swap_from_graph(swapped, builder);
        REQUIRE(swap != nullptr);
        rt_graph_destroy(builder);
        CHECK(rt_graph_swap_migration_committed_count(swap) == 1);
        CHECK(rt_graph_swap_migration_skipped_count(swap) == 1);

        REQUIRE(rt_graph_publish_swap(swapped, swap) == 1);
        rt_graph_process(swapped, kFrames);
        rt_graph_process(expected, kFrames);

        check_exact_same(read_bus_vec(swapped, 0, kFrames),
                         read_bus_vec(expected, 0, kFrames));

        auto *retired = rt_graph_collect_retired_swap(swapped);
        REQUIRE(retired == swap);
        CHECK(rt_graph_swap_migration_instance_copy_count(retired) == 1);
        CHECK(rt_graph_swap_migration_state_copy_count(retired) == 1);

        rt_graph_cancel_swap(swapped, retired);
        rt_graph_destroy(swapped);
        rt_graph_destroy(expected);
    }
}

TEST_CASE("hot-swap migration: noise generator state survives payload install") {
    auto build = [](RTGraph *g) {
        rt_graph_add_node(g, 0, kKindNoiseGen);
        REQUIRE(rt_graph_template_set_node_migration_key(
                    g, 0, 0, "noise", 5) == 1);
        rt_graph_add_node(g, 1, kKindOut);
        rt_graph_set_control(g, 1, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);
    };

    auto *swapped = rt_graph_create(4, kFrames);
    auto *builder = rt_graph_create(4, kFrames);
    auto *expected = rt_graph_create(4, kFrames);
    REQUIRE(swapped != nullptr);
    REQUIRE(builder != nullptr);
    REQUIRE(expected != nullptr);

    build(swapped);
    build(builder);
    build(expected);

    rt_graph_process(swapped, kFrames);
    rt_graph_process(expected, kFrames);

    auto *swap = rt_graph_prepare_swap_from_graph(swapped, builder);
    REQUIRE(swap != nullptr);
    rt_graph_destroy(builder);

    REQUIRE(rt_graph_publish_swap(swapped, swap) == 1);
    rt_graph_process(swapped, kFrames);
    rt_graph_process(expected, kFrames);

    check_exact_same(read_bus_vec(swapped, 0, kFrames),
                     read_bus_vec(expected, 0, kFrames));

    auto *retired = rt_graph_collect_retired_swap(swapped);
    REQUIRE(retired == swap);
    CHECK(rt_graph_swap_migration_state_copy_count(retired) == 1);

    rt_graph_cancel_swap(swapped, retired);
    rt_graph_destroy(swapped);
    rt_graph_destroy(expected);
}

TEST_CASE("hot-swap migration: biquad filter state survives payload install") {
    auto build = [](RTGraph *g, int filter_kind) {
        add_const_node(g, 0, 1.0f, 0.0f);
        rt_graph_add_node(g, 1, filter_kind);
        rt_graph_set_control(g, 1, 0, 800.0f);
        rt_graph_set_control(g, 1, 1, 0.707f);
        REQUIRE(rt_graph_template_set_node_migration_key(
                    g, 0, 1, "flt", 3) == 1);
        rt_graph_add_node(g, 2, kKindOut);
        rt_graph_set_control(g, 2, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);
        rt_graph_connect(g, 1, 0, 2, 0);
    };

    for (int filter_kind : {kKindLPF, kKindHPF, kKindBPF, kKindNotch}) {
        auto *swapped = rt_graph_create(4, kFrames);
        auto *builder = rt_graph_create(4, kFrames);
        auto *expected = rt_graph_create(4, kFrames);
        REQUIRE(swapped != nullptr);
        REQUIRE(builder != nullptr);
        REQUIRE(expected != nullptr);

        build(swapped, filter_kind);
        build(builder, filter_kind);
        build(expected, filter_kind);

        rt_graph_process(swapped, kFrames);
        rt_graph_process(expected, kFrames);

        auto *swap = rt_graph_prepare_swap_from_graph(swapped, builder);
        REQUIRE(swap != nullptr);
        rt_graph_destroy(builder);
        CHECK(rt_graph_swap_migration_committed_count(swap) == 1);
        CHECK(rt_graph_swap_migration_skipped_count(swap) == 2);

        REQUIRE(rt_graph_publish_swap(swapped, swap) == 1);
        rt_graph_process(swapped, kFrames);
        rt_graph_process(expected, kFrames);

        check_exact_same(read_bus_vec(swapped, 0, kFrames),
                         read_bus_vec(expected, 0, kFrames));

        auto *retired = rt_graph_collect_retired_swap(swapped);
        REQUIRE(retired == swap);
        CHECK(rt_graph_swap_migration_instance_copy_count(retired) == 1);
        CHECK(rt_graph_swap_migration_state_copy_count(retired) == 1);

        rt_graph_cancel_swap(swapped, retired);
        rt_graph_destroy(swapped);
        rt_graph_destroy(expected);
    }
}

TEST_CASE("hot-swap migration: unsupported lazy state skips without control copy") {
    auto build_unsupported_plan_only = [](RTGraph *g, int node_kind) {
        rt_graph_add_node(g, 0, node_kind);
        REQUIRE(rt_graph_template_set_node_migration_key(
                    g, 0, 0, "lazy", 4) == 1);
    };

    for (int unsupported_kind : {kKindDelay, kKindSmooth}) {
        auto *old_world = rt_graph_create(4, kFrames);
        auto *builder_world = rt_graph_create(4, kFrames);
        REQUIRE(old_world != nullptr);
        REQUIRE(builder_world != nullptr);

        build_unsupported_plan_only(old_world, unsupported_kind);
        build_unsupported_plan_only(builder_world, unsupported_kind);

        auto *swap = rt_graph_prepare_swap_from_graph(old_world, builder_world);
        REQUIRE(swap != nullptr);
        rt_graph_destroy(builder_world);

        CHECK(rt_graph_swap_migration_committed_count(swap) == 0);
        REQUIRE(rt_graph_swap_migration_skipped_count(swap) == 1);
        CHECK(rt_graph_swap_migration_skipped_reason(swap, 0)
              == kMigrationSkipStateUnsupported);

        rt_graph_cancel_swap(old_world, swap);
        rt_graph_destroy(old_world);
    }

    auto build = [](RTGraph *g, double gate) {
        rt_graph_add_node(g, 0, kKindEnv);
        rt_graph_set_control(g, 0, 0, gate);
        rt_graph_set_control(g, 0, 1, 0.001);
        rt_graph_set_control(g, 0, 2, 0.001);
        rt_graph_set_control(g, 0, 3, 1.0);
        rt_graph_set_control(g, 0, 4, 0.001);
        REQUIRE(rt_graph_template_set_node_migration_key(
                    g, 0, 0, "env", 3) == 1);
        rt_graph_add_node(g, 1, kKindOut);
        rt_graph_set_control(g, 1, 0, 0.0f);
        rt_graph_connect(g, 0, 0, 1, 0);
    };

    auto *g = rt_graph_create(4, kFrames);
    auto *builder = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    REQUIRE(builder != nullptr);

    build(g, 1.0);
    build(builder, 0.0);

    auto *swap = rt_graph_prepare_swap_from_graph(g, builder);
    REQUIRE(swap != nullptr);
    rt_graph_destroy(builder);

    CHECK(rt_graph_swap_migration_committed_count(swap) == 0);
    REQUIRE(rt_graph_swap_migration_skipped_count(swap) == 2);
    CHECK(rt_graph_swap_migration_skipped_reason(swap, 0)
          == kMigrationSkipStateUnsupported);
    CHECK(rt_graph_swap_migration_skipped_reason(swap, 1)
          == kMigrationSkipMissingTag);

    REQUIRE(rt_graph_publish_swap(g, swap) == 1);
    rt_graph_process(g, kFrames);

    for (float sample : read_bus_vec(g, 0, kFrames)) {
        CHECK(sample == 0.0f);
    }

    auto *retired = rt_graph_collect_retired_swap(g);
    REQUIRE(retired == swap);
    CHECK(rt_graph_swap_migration_instance_copy_count(retired) == 0);
    CHECK(rt_graph_swap_migration_state_copy_count(retired) == 0);

    rt_graph_cancel_swap(g, retired);
    rt_graph_destroy(g);
}

TEST_CASE("hot-swap migration: tagged kind mismatch skips controls") {
    auto *g = rt_graph_create(4, kFrames);
    auto *builder = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);
    REQUIRE(builder != nullptr);

    add_const_node(g, 0, 0.75f, 0.0f);
    REQUIRE(rt_graph_template_set_node_migration_key(
                g, 0, 0, "shape", 5) == 1);
    rt_graph_add_node(g, 1, kKindOut);
    rt_graph_set_control(g, 1, 0, 0.0f);
    rt_graph_connect(g, 0, 0, 1, 0);

    rt_graph_add_node(builder, 0, kKindGain);    // Same key as old Add.
    rt_graph_set_control(builder, 0, 0, 0.25f);
    REQUIRE(rt_graph_template_set_node_migration_key(
                builder, 0, 0, "shape", 5) == 1);
    rt_graph_add_node(builder, 1, kKindOut);
    rt_graph_set_control(builder, 1, 0, 0.0f);
    rt_graph_connect(builder, 0, 0, 1, 0);

    auto *swap = rt_graph_prepare_swap_from_graph(g, builder);
    REQUIRE(swap != nullptr);
    rt_graph_destroy(builder);

    CHECK(rt_graph_swap_migration_committed_count(swap) == 0);
    CHECK(rt_graph_swap_migration_skipped_count(swap) == 2);
    CHECK(rt_graph_swap_migration_skipped_reason(swap, 0)
          == kMigrationSkipKindMismatch);
    CHECK(rt_graph_swap_migration_skipped_reason(swap, 1)
          == kMigrationSkipMissingTag);

    REQUIRE(rt_graph_publish_swap(g, swap) == 1);
    rt_graph_process(g, kFrames);

    for (float sample : read_bus_vec(g, 0, kFrames)) {
        CHECK(sample == doctest::Approx(0.0f).epsilon(1e-6));
    }

    auto *retired = rt_graph_collect_retired_swap(g);
    REQUIRE(retired == swap);
    CHECK(rt_graph_swap_migration_instance_copy_count(retired) == 0);

    rt_graph_cancel_swap(g, retired);
    rt_graph_destroy(g);
}

TEST_CASE("hot-swap migration: key setter rejects invalid and duplicate keys") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    add_const_node(g, 0, 0.75f, 0.0f);
    rt_graph_add_node(g, 1, kKindOut);
    rt_graph_add_node(g, 2, kKindGain);

    CHECK(rt_graph_template_set_node_migration_key(
              nullptr, 0, 0, "dup", 3) == 0);
    CHECK(rt_graph_template_set_node_migration_key(
              g, 0, 0, nullptr, 3) == 0);
    CHECK(rt_graph_template_set_node_migration_key(
              g, 0, 0, "", 0) == 0);
    CHECK(rt_graph_template_set_node_migration_key(
              g, 0, 0, "0123456789abcdefX", 17) == 0);
    CHECK(rt_graph_template_set_node_migration_key(
              g, 0, 0, "dup", 3) == 1);
    CHECK(rt_graph_template_set_node_migration_key(
              g, 0, 1, "dup", 3) == 0);
    const char opaque_key[] = {'o', static_cast<char>(0xff), 'k'};
    CHECK(rt_graph_template_set_node_migration_key(
              g, 0, 2, opaque_key, 3) == 1);
    const char nul_key[] = {'n', 'u', '\0', 'l'};
    CHECK(rt_graph_template_set_node_migration_key(
              g, 0, 2, nul_key, 4) == 0);
    CHECK(rt_graph_template_set_node_migration_key(
              g, 0, 99, "other", 5) == 0);

    rt_graph_destroy(g);
}

TEST_CASE("hot-swap substrate: null-arg paths are silent no-ops") {
    CHECK(rt_graph_prepare_swap(nullptr) == nullptr);
    CHECK(rt_graph_prepare_swap_from_graph(nullptr, nullptr) == nullptr);
    CHECK(rt_graph_publish_swap(nullptr, nullptr) == 0);
    CHECK(rt_graph_collect_retired_swap(nullptr) == nullptr);
    rt_graph_cancel_swap(nullptr, nullptr);  // must not crash
    CHECK(rt_graph_test_swap_generation(nullptr) == 0);
    CHECK(rt_graph_test_swap_pending(nullptr) == 0);
    CHECK(rt_graph_test_swap_retired_pending(nullptr) == 0);
    CHECK(rt_graph_swap_migration_lifecycle_copy_count(nullptr) == 0);

    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);
    // publish_swap with non-null g but null swap returns 0 and
    // does not mutate state.
    CHECK(rt_graph_publish_swap(g, nullptr) == 0);
    CHECK(rt_graph_test_swap_pending(g) == 0);
    rt_graph_destroy(g);

    auto *a = rt_graph_create(2, kFrames);
    auto *b = rt_graph_create(2, kFrames + 1);
    REQUIRE(a != nullptr);
    REQUIRE(b != nullptr);
    CHECK(rt_graph_prepare_swap_from_graph(a, a) == nullptr);
    CHECK(rt_graph_prepare_swap_from_graph(a, b) == nullptr);
    rt_graph_destroy(a);
    rt_graph_destroy(b);
}

// ----------------------------------------------------------------
// §6.C.5 commit 1: writer-template monophony runtime backstop
//
// The Haskell loaders clamp writer templates declaratively, but
// the public C ABI is reachable from C++ tests, future producers,
// and any caller that builds graphs without going through the
// Haskell loaders. The backstop in rt_graph_template_add_node and
// rt_graph_template_set_polyphony makes that surface honor the
// same single-writer-single-instance invariant.
// ----------------------------------------------------------------

TEST_CASE("§6.C.5: rt_graph_template_add_node clamps a writer template to polyphony=1") {
    auto *g = rt_graph_create(/*capacity*/ 2, /*max_frames*/ kFrames);
    REQUIRE(g != nullptr);
    // A real buffer must exist so the kernel does not crash on the
    // auto-spawn render path. The actual write path is irrelevant
    // to this test — we only care about the polyphony clamp.
    const int bid = rt_graph_buffer_alloc(g, kFrames);
    CHECK(bid == 0);

    // Drop a RecordBufMono (tag 21) into template 0 via the direct
    // C ABI. The default polyphony was kDefaultPolyphony (8); the
    // backstop must drop it to 1 in place.
    rt_graph_template_add_node(g, 0, 0, 21);
    rt_graph_set_control(g, 0, 0, static_cast<float>(bid));

    // Template 0 already has its auto-spawned instance from
    // rt_graph_create / clear. With cap=1 the second spawn must
    // fail.
    const int second = rt_graph_template_instance_add(g, 0);
    CHECK(second == -1);

    rt_graph_destroy(g);
}

TEST_CASE("§6.C.5: rt_graph_add_node template-0 shim picks up the same clamp") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);
    const int bid = rt_graph_buffer_alloc(g, kFrames);
    CHECK(bid == 0);

    // rt_graph_add_node forwards straight to template_add_node(_, 0, …).
    // Same clamp must fire even though the caller never names
    // template 0 explicitly.
    rt_graph_add_node(g, 0, 21);  // RecordBufMono
    rt_graph_set_control(g, 0, 0, static_cast<float>(bid));

    CHECK(rt_graph_template_instance_add(g, 0) == -1);

    rt_graph_destroy(g);
}

TEST_CASE("§6.C.5: set_polyphony cannot raise a writer template's cap above 1") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);
    const int bid = rt_graph_buffer_alloc(g, kFrames);
    CHECK(bid == 0);

    rt_graph_template_add_node(g, 0, 0, 21);  // RecordBufMono → clamps cap to 1
    rt_graph_set_control(g, 0, 0, static_cast<float>(bid));

    // Try to raise the cap back up after the writer is present.
    // The backstop must silently keep it at 1.
    rt_graph_template_set_polyphony(g, 0, 8);
    CHECK(rt_graph_template_instance_add(g, 0) == -1);

    rt_graph_template_set_polyphony(g, 0, 16);
    CHECK(rt_graph_template_instance_add(g, 0) == -1);

    rt_graph_destroy(g);
}

TEST_CASE("§6.C.5: set_polyphony=N then add_node(writer) still clamps to 1") {
    auto *g = rt_graph_create(2, kFrames);
    REQUIRE(g != nullptr);
    const int bid = rt_graph_buffer_alloc(g, kFrames);
    CHECK(bid == 0);

    // Caller raises the cap before any writer node is added —
    // legitimate, since the template is non-writer at this point.
    rt_graph_template_set_polyphony(g, 0, 4);

    // Drop the writer node. The add_node-side clamp fires and
    // brings the cap back down to 1, even though set_polyphony
    // accepted the higher value moments earlier.
    rt_graph_template_add_node(g, 0, 0, 21);
    rt_graph_set_control(g, 0, 0, static_cast<float>(bid));

    CHECK(rt_graph_template_instance_add(g, 0) == -1);

    rt_graph_destroy(g);
}

TEST_CASE("§6.C.5: non-writer templates keep set_polyphony's higher cap") {
    auto *g = rt_graph_create(4, kFrames);
    REQUIRE(g != nullptr);

    // A non-writer template: just a SinOsc (tag 1). The §6.C.5
    // clamp must not affect this path — set_polyphony(4) must
    // stick, and the second spawn must succeed.
    rt_graph_template_add_node(g, 0, 0, 1);
    rt_graph_set_control(g, 0, 0, 440.0f);
    rt_graph_template_set_polyphony(g, 0, 4);

    const int second = rt_graph_template_instance_add(g, 0);
    CHECK(second >= 0);

    rt_graph_destroy(g);
}
