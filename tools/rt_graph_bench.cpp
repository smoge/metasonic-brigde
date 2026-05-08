// rt_graph_bench: microbench for §4.B region kernels.
//
// Compares two compiled forms of the same graph back-to-back:
//   * node-loop : every region tagged RegionKernel::NodeLoop, so
//                 process_instance dispatches members one by one
//                 via dispatch_node.
//   * fused     : the kernel-eligible range carries the matching
//                 RegionKernel tag, so process_instance calls the
//                 hand-written fused kernel directly.
//
// Three shapes:
//   * SawLpfGain    — buffer-terminal: kernel covers [Saw, LPF, Gain];
//                     a separate trailing Out region is per-node in
//                     both modes.
//   * SinGainOut    — sink-terminal:   kernel covers [Sin, Gain, Out].
//   * SawLpfGainOut — sink-terminal:   kernel covers [Saw, LPF, Gain, Out].
//   * BusInLpfGainOut — sink-terminal: kernel covers [BusIn, LPF, Gain, Out].
//                       The bus the BusIn reads has no writer in this
//                       harness, so both fused and baseline read zeros
//                       and do the same arithmetic — the time delta
//                       captures the per-node-dispatch vs. fused-loop
//                       structural cost, not filter-on-real-signal cost.
//
// For each shape × block_size × voice_count × mode, render N blocks
// and report ns/sample. The "fused" line of each row also reports
// the speedup against its node-loop sibling. A volatile sink reads
// the bus contents after each render so the optimizer cannot dead-
// code-eliminate process_graph.
//
// Build with -O3 (Release / RelWithDebInfo) — debug timings are
// dominated by libstdc++ checks and the kernel-vs-loop ratio is
// noise. The CMake target is wired via `just cpp-bench`.

#include "rt_graph.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

namespace {

// ----------------------------------------------------------------
// Constants
// ----------------------------------------------------------------

// NodeKind ints — must match kind_from_int in rt_graph.cpp.
constexpr int kNkSinOsc = 1;
constexpr int kNkOut    = 2;
constexpr int kNkGain   = 3;
constexpr int kNkSawOsc = 5;
constexpr int kNkLPF    = 7;
constexpr int kNkBusIn  = 11;

// Rate ints — value 3 corresponds to SampleRate.
constexpr int kRateSampleRate = 3;

// RegionKernel tags — must match Haskell kernelTag and the
// RegionKernel enum in rt_graph.cpp.
constexpr int kKernelNodeLoop        = 0;
constexpr int kKernelSawLpfGain      = 1;
constexpr int kKernelSinGainOut      = 2;
constexpr int kKernelSawLpfGainOut   = 3;
constexpr int kKernelBusInLpfGainOut = 6;

constexpr int kSampleRate    = 48000;
constexpr int kCapacity      = 64;
constexpr int kMaxFrames     = 1024;
constexpr int kBenchBus      = 0;
constexpr int kWarmupBlocks  = 64;
constexpr int kRepeatRuns    = 5;

// Volatile sink to defeat dead-code elimination of the rendered
// audio. Every measurement reads the output bus and accumulates
// into this sink so the compiler cannot collapse the timed region.
volatile float g_sink = 0.0f;

// ----------------------------------------------------------------
// Graph builders
// ----------------------------------------------------------------

// Build [SawOsc, LPF, Gain, Out] in template 0 with sample-rate
// defaults. Used by both node-loop and fused modes for the
// SawLpfGain row.
void build_saw_lpf_gain_chain(RTGraph *g) {
  rt_graph_template_add_node(g, 0, 0, kNkSawOsc);
  rt_graph_template_add_node(g, 0, 1, kNkLPF);
  rt_graph_template_add_node(g, 0, 2, kNkGain);
  rt_graph_template_add_node(g, 0, 3, kNkOut);

  rt_graph_template_connect(g, 0, 0, 0, 1, 0);  // saw -> lpf signal
  rt_graph_template_connect(g, 0, 1, 0, 2, 0);  // lpf -> gain signal
  rt_graph_template_connect(g, 0, 2, 0, 3, 0);  // gain -> out signal

  rt_graph_template_set_default(g, 0, 0, 0, 220.0);   // saw freq
  rt_graph_template_set_default(g, 0, 1, 0, 800.0);   // lpf freq
  rt_graph_template_set_default(g, 0, 1, 1, 4.0);     // lpf q
  rt_graph_template_set_default(g, 0, 2, 0, 0.4);     // gain amount
  rt_graph_template_set_default(g, 0, 3, 0, kBenchBus); // out bus
}

// Build [SinOsc, Gain, Out] in template 0.
void build_sin_gain_out_chain(RTGraph *g) {
  rt_graph_template_add_node(g, 0, 0, kNkSinOsc);
  rt_graph_template_add_node(g, 0, 1, kNkGain);
  rt_graph_template_add_node(g, 0, 2, kNkOut);

  rt_graph_template_connect(g, 0, 0, 0, 1, 0);  // sin -> gain signal
  rt_graph_template_connect(g, 0, 1, 0, 2, 0);  // gain -> out signal

  rt_graph_template_set_default(g, 0, 0, 0, 440.0);   // sin freq
  rt_graph_template_set_default(g, 0, 1, 0, 0.5);     // gain amount
  rt_graph_template_set_default(g, 0, 2, 0, kBenchBus); // out bus
}

// Build [SawOsc, LPF, Gain, Out] (same as SawLpfGain template,
// but the kernel will absorb the Out node).
void build_saw_lpf_gain_out_chain(RTGraph *g) {
  build_saw_lpf_gain_chain(g);
}

// Build [BusIn, LPF, Gain, Out] in template 0 with sample-rate
// defaults. The BusIn reads a bus that nothing in this harness
// writes to, so process_busin (baseline) and the fused kernel
// both read zeros — the time delta we measure is the per-node-
// dispatch vs. fused-loop structural cost on the LPF/Gain/Out
// portion, not filter-on-real-signal cost. See the file header.
void build_busin_lpf_gain_out_chain(RTGraph *g) {
  rt_graph_template_add_node(g, 0, 0, kNkBusIn);
  rt_graph_template_add_node(g, 0, 1, kNkLPF);
  rt_graph_template_add_node(g, 0, 2, kNkGain);
  rt_graph_template_add_node(g, 0, 3, kNkOut);

  rt_graph_template_connect(g, 0, 0, 0, 1, 0);  // busIn -> lpf signal
  rt_graph_template_connect(g, 0, 1, 0, 2, 0);  // lpf   -> gain signal
  rt_graph_template_connect(g, 0, 2, 0, 3, 0);  // gain  -> out signal

  // BusIn reads bus 1 (no writer in this harness → silent input).
  // Bench Bus is bus 0 for the sink terminal.
  rt_graph_template_set_default(g, 0, 0, 0, 1.0);     // busIn bus
  rt_graph_template_set_default(g, 0, 1, 0, 800.0);   // lpf freq
  rt_graph_template_set_default(g, 0, 1, 1, 4.0);     // lpf q
  rt_graph_template_set_default(g, 0, 2, 0, 0.4);     // gain amount
  rt_graph_template_set_default(g, 0, 3, 0, kBenchBus); // out bus

  // Auto-bus-grow only fires on Out node addition, not on BusIn.
  // Without this, busin_bus=1 fails the validation in both
  // process_busin and process_region_busin_lpf_gain_out and the
  // chain silent-no-ops every block — which would let the fused
  // path falsely report 100x+ speedup as the "kernel" early-
  // returns past every sample of work.
  rt_graph_ensure_bus(g, 1);
}

// ----------------------------------------------------------------
// Region registration
// ----------------------------------------------------------------

// Register the regions for a SawLpfGain template:
//   * fused    : kernel region covering [0, 3) + Out region [3, 4)
//   * baseline : NodeLoop region [0, 3) + NodeLoop region [3, 4)
// Region ranges are identical; only the kernel tag of the first
// region differs. This isolates the kernel-vs-per-node-loop
// difference from any region-overlay overhead.
void register_saw_lpf_gain_regions(RTGraph *g, bool fused) {
  const int kernel_tag = fused ? kKernelSawLpfGain : kKernelNodeLoop;
  rt_graph_template_add_region_kernel(g, 0, kernel_tag,
                                      kRateSampleRate, 0, 3);
  rt_graph_template_add_region_kernel(g, 0, kKernelNodeLoop,
                                      kRateSampleRate, 3, 1);
}

// Register a single 3-node region covering the whole template,
// tagged either SinGainOut (fused) or NodeLoop (baseline).
void register_sin_gain_out_regions(RTGraph *g, bool fused) {
  const int kernel_tag = fused ? kKernelSinGainOut : kKernelNodeLoop;
  rt_graph_template_add_region_kernel(g, 0, kernel_tag,
                                      kRateSampleRate, 0, 3);
}

// Register a single 4-node region covering the whole template,
// tagged either SawLpfGainOut (fused) or NodeLoop (baseline).
void register_saw_lpf_gain_out_regions(RTGraph *g, bool fused) {
  const int kernel_tag = fused ? kKernelSawLpfGainOut : kKernelNodeLoop;
  rt_graph_template_add_region_kernel(g, 0, kernel_tag,
                                      kRateSampleRate, 0, 4);
}

// Register a single 4-node region covering the whole template,
// tagged either BusInLpfGainOut (fused) or NodeLoop (baseline).
void register_busin_lpf_gain_out_regions(RTGraph *g, bool fused) {
  const int kernel_tag = fused ? kKernelBusInLpfGainOut : kKernelNodeLoop;
  rt_graph_template_add_region_kernel(g, 0, kernel_tag,
                                      kRateSampleRate, 0, 4);
}

// ----------------------------------------------------------------
// Bench harness
// ----------------------------------------------------------------

struct ShapeSpec {
  const char *name;
  int total_nodes;
  void (*build)(RTGraph *);
  void (*register_regions)(RTGraph *, bool fused);
};

const ShapeSpec kShapes[] = {
  { "SawLpfGain",      4, &build_saw_lpf_gain_chain,       &register_saw_lpf_gain_regions       },
  { "SinGainOut",      3, &build_sin_gain_out_chain,       &register_sin_gain_out_regions       },
  { "SawLpfGainOut",   4, &build_saw_lpf_gain_out_chain,   &register_saw_lpf_gain_out_regions   },
  { "BusInLpfGainOut", 4, &build_busin_lpf_gain_out_chain, &register_busin_lpf_gain_out_regions },
};

constexpr int kBlockSizes[]  = { 64, 128, 512 };
constexpr int kVoiceCounts[] = { 1, 8, 32 };

// Drain the bus into the volatile sink. Prevents the optimizer
// from realizing nothing reads the rendered output.
void drain_into_sink(RTGraph *g, int nframes,
                     std::vector<float> &scratch) {
  scratch.resize(static_cast<std::size_t>(nframes));
  rt_graph_read_bus(g, kBenchBus, nframes, scratch.data());
  float acc = 0.0f;
  for (int i = 0; i < nframes; ++i) acc += scratch[static_cast<std::size_t>(i)];
  g_sink = g_sink + acc;  // volatile read-modify-write; preserves the work
}

// Time `iters` calls of process_graph at the given block size,
// returning total elapsed nanoseconds. The graph is fully built
// (template, voices, regions, bus pool) before the timer starts.
std::int64_t time_render(RTGraph *g, int nframes, int iters,
                         std::vector<float> &scratch) {
  // Warm caches and let any one-shot block-rate latches settle.
  for (int i = 0; i < kWarmupBlocks; ++i) {
    rt_graph_process(g, nframes);
  }
  drain_into_sink(g, nframes, scratch);

  using clock = std::chrono::steady_clock;
  const auto t0 = clock::now();
  for (int i = 0; i < iters; ++i) {
    rt_graph_process(g, nframes);
  }
  const auto t1 = clock::now();

  drain_into_sink(g, nframes, scratch);

  return std::chrono::duration_cast<std::chrono::nanoseconds>(
      t1 - t0).count();
}

// Build a fully-prepared RTGraph for one (shape, mode, voices)
// configuration, matching what the Haskell loader would emit.
//
// rt_graph_create auto-spawns instance 0 of template 0 before the
// template has any nodes, regions, or default controls; leaving
// it alive would inflate the active voice count for this config
// by one and that extra voice would render with whatever zeroed
// controls the auto-spawn captured. Remove it explicitly so the
// `voices` parameter is exact and every live instance inherits
// the post-build defaults.
RTGraph *build_graph(const ShapeSpec &shape, bool fused, int voices) {
  RTGraph *g = rt_graph_create(kCapacity, kMaxFrames);
  rt_graph_instance_remove(g, 0);
  rt_graph_template_set_polyphony(g, 0, voices);
  shape.build(g);
  shape.register_regions(g, fused);
  rt_graph_ensure_bus(g, kBenchBus);
  for (int i = 0; i < voices; ++i) {
    rt_graph_template_instance_add(g, 0);
  }
  return g;
}

// Pick a block count that gives ~50 ms of audio per measurement at
// 48 kHz; that's enough for std::chrono::steady_clock to be stable
// and still keeps the whole bench under a few seconds.
int choose_iters(int nframes) {
  const int target_samples = kSampleRate / 20;  // ~50 ms
  const int iters = target_samples / nframes;
  return iters < 32 ? 32 : iters;
}

// Run a single (shape, mode, block, voices) cell; return the
// median ns over kRepeatRuns.
double run_cell(const ShapeSpec &shape, bool fused,
                int nframes, int voices) {
  std::vector<float> scratch;
  std::vector<double> ns_per_sample;
  ns_per_sample.reserve(static_cast<std::size_t>(kRepeatRuns));

  const int iters = choose_iters(nframes);
  const double total_samples =
      static_cast<double>(iters) *
      static_cast<double>(nframes) *
      static_cast<double>(voices);

  for (int run = 0; run < kRepeatRuns; ++run) {
    RTGraph *g = build_graph(shape, fused, voices);
    const std::int64_t ns = time_render(g, nframes, iters, scratch);
    rt_graph_destroy(g);
    ns_per_sample.push_back(static_cast<double>(ns) / total_samples);
  }
  // Median: sort ascending, pick middle.
  std::sort(ns_per_sample.begin(), ns_per_sample.end());
  return ns_per_sample[ns_per_sample.size() / 2];
}

}  // namespace

int main() {
  std::printf("# rt_graph_bench: §4.B region kernel microbench\n");
  std::printf("# sample_rate=%d, warmup_blocks=%d, repeat_runs=%d\n",
              kSampleRate, kWarmupBlocks, kRepeatRuns);
  std::printf("# columns: shape,mode,block,voices,ns_per_sample,speedup\n");

  for (const auto &shape : kShapes) {
    for (const int voices : kVoiceCounts) {
      for (const int nframes : kBlockSizes) {
        const double base  = run_cell(shape, /*fused=*/false, nframes, voices);
        const double fused = run_cell(shape, /*fused=*/true,  nframes, voices);
        const double speedup = base / fused;
        std::printf("%-14s,node-loop,%4d,%3d,%9.2f,%6s\n",
                    shape.name, nframes, voices, base, "-");
        std::printf("%-14s,fused    ,%4d,%3d,%9.2f,%5.2fx\n",
                    shape.name, nframes, voices, fused, speedup);
      }
    }
  }

  // Print the sink so the linker / optimizer cannot strip the
  // accumulator chain away. Trailing comment line, not a result
  // anyone parses.
  std::printf("# sink_checksum=%g\n", static_cast<double>(g_sink));
  return 0;
}
