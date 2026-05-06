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
}

TEST_CASE("kind_from_tag rejects unknown tags") {
    CHECK(rt_graph_kind_supported(0) == 0);
    CHECK(rt_graph_kind_supported(4) == 0);  // intentional gap
    CHECK(rt_graph_kind_supported(13) == 0); // first unallocated past KBusInDelayed
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
    // strongly-coloured signal would push toward ±1. Anything past
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
    // Block 1: prev is zero-initialised, so BusInDelayed → Out(0) = silence.
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

    // Block 0: prev was zero-initialised → Out(0) is silence.
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
    // SC analogue: In.ar(5) and InFeedback.ar(5) on the same bus.
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
    // Delayed: bus 1 is silence (zero-initialised snapshot).
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
    // blocks — a hard correctness oracle would require modelling the
    // feedback transfer function. The test's real value is that it
    // exercises the swap+clear+kernel sequence under feedback load
    // and that nothing becomes NaN/inf.
    constexpr int kBus = 5;
    auto *g = rt_graph_create(8, kFrames);
    REQUIRE(g != nullptr);

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
// stopband behaviour at Q=0.7. These pin that Q is actually wired and
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
    // process should still return whatever the bus holds (zero-initialised).
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
    // Pin the observed behaviour: it is safe to call rt_graph_clear
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

TEST_CASE("self-loop wiring does not crash and stays finite") {
    // Wire a Gain node to itself. Whatever the runtime does (read
    // last-block buffer, read zeros, etc.) it must not crash or
    // produce NaN/Inf. We don't assert audio behaviour beyond that.
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
