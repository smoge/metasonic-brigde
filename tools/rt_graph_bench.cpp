// rt_graph_bench: microbench for §4.B region kernels and §4.E
// schedule-worker dispatch.
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
//   * NoiseLpfGainOut — sink-terminal: kernel covers [NoiseGen, LPF, Gain, Out].
//                       The producer is a 'q::white_noise_gen' PRNG —
//                       both fused and baseline pull one sample per
//                       output sample, so the PRNG cadence matches
//                       across modes and the time delta isolates the
//                       per-node-dispatch vs. fused-loop structural
//                       cost on a real (non-zero) input stream.
//
// For each shape × block_size × voice_count × mode, render N blocks
// and report ns/sample. The "fused" line of each row also reports
// the speedup against its node-loop sibling. A volatile sink reads
// the bus contents after each render so the optimizer cannot dead-
// code-eliminate process_graph.
//
// The second section is the §4.E bench slice: it compares the
// legacy executor, global-schedule serial executor, and worker-pool
// Free-band dispatch at pool sizes 2/3/4. Those rows also report the
// C1c debug counters (parallel bands, parallel entries, serialized
// sink bands) so timing data can be read against the schedule shape.
//
// Build with -O3 / RelWithDebInfo — debug timings are dominated by
// libstdc++ checks and the kernel-vs-loop ratio is noise. The CMake
// target is wired via `just cpp-bench`.

#include "rt_graph.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <sched.h>
#include <string>
#include <sys/utsname.h>
#include <thread>
#include <vector>

namespace {

// ----------------------------------------------------------------
// Constants
// ----------------------------------------------------------------

// NodeKind ints — must match kind_from_int in rt_graph.cpp.
constexpr int kNkSinOsc   = 1;
constexpr int kNkOut      = 2;
constexpr int kNkGain     = 3;
constexpr int kNkSawOsc   = 5;
constexpr int kNkNoiseGen = 6;
constexpr int kNkLPF      = 7;
constexpr int kNkBusOut   = 10;
constexpr int kNkBusIn    = 11;

// Rate ints — value 3 corresponds to SampleRate.
constexpr int kRateSampleRate = 3;

// RegionKernel tags — must match Haskell kernelTag and the
// RegionKernel enum in rt_graph.cpp.
constexpr int kKernelNodeLoop        = 0;
constexpr int kKernelSawLpfGain      = 1;
constexpr int kKernelSinGainOut      = 2;
constexpr int kKernelSawLpfGainOut   = 3;
constexpr int kKernelBusInLpfGainOut = 6;
constexpr int kKernelNoiseLpfGainOut = 7;

constexpr int kSampleRate    = 48000;
constexpr int kCapacity      = 64;
constexpr int kMaxFrames     = 1024;
constexpr int kBenchBus      = 0;
constexpr int kWarmupBlocks  = 64;
constexpr int kRepeatRuns    = 5;
// Three schedule repeats are enough for the current "do not turn on
// by default" decision. Before using this bench to justify default-on
// behavior, increase this count and report spread (stddev or IQR).
constexpr int kScheduleRepeatRuns = 3;
constexpr int kScheduleWarmupBlocks = 32;

constexpr int kScheduleBarrier  = 0;
constexpr int kScheduleFreeLayer = 1;

// Volatile sink to defeat dead-code elimination of the rendered
// audio. Every measurement reads the output bus and accumulates
// into this sink so the compiler cannot collapse the timed region.
volatile float g_sink = 0.0f;

std::string trim_ascii(std::string s) {
  const std::size_t first = s.find_first_not_of(" \t");
  if (first == std::string::npos) {
    return {};
  }
  const std::size_t last = s.find_last_not_of(" \t");
  return s.substr(first, last - first + 1);
}

std::string host_cpu_model() {
  std::ifstream cpuinfo("/proc/cpuinfo");
  std::string line;
  while (std::getline(cpuinfo, line)) {
    const std::size_t colon = line.find(':');
    if (colon == std::string::npos) {
      continue;
    }
    if (trim_ascii(line.substr(0, colon)) == "model name") {
      return trim_ascii(line.substr(colon + 1));
    }
  }
  return "unknown";
}

const char *scheduler_policy_name(int policy) {
  switch (policy) {
    case SCHED_OTHER:
      return "SCHED_OTHER";
    case SCHED_FIFO:
      return "SCHED_FIFO";
    case SCHED_RR:
      return "SCHED_RR";
#ifdef SCHED_BATCH
    case SCHED_BATCH:
      return "SCHED_BATCH";
#endif
#ifdef SCHED_IDLE
    case SCHED_IDLE:
      return "SCHED_IDLE";
#endif
    default:
      return "unknown";
  }
}

void print_bench_reproducibility() {
  struct utsname uts {};
  const bool have_uname = uname(&uts) == 0;
  const int scheduler = sched_getscheduler(0);
  std::printf(
      "# bench_repro: cpu_model=\"%s\", hardware_threads=%u, "
      "os=\"%s %s %s\", scheduler_policy=%s\n",
      host_cpu_model().c_str(),
      std::thread::hardware_concurrency(),
      have_uname ? uts.sysname : "unknown",
      have_uname ? uts.release : "unknown",
      have_uname ? uts.machine : "unknown",
      scheduler_policy_name(scheduler));
}

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

// Build [NoiseGen, LPF, Gain, Out] in template 0 with sample-rate
// defaults. NoiseGen has no inputs and no controls of its own; the
// kernel and per-node baseline both pull from the same q::white_noise_gen
// PRNG instance, so the time delta isolates per-node-dispatch vs.
// fused-loop structural cost on a real (non-zero) input stream.
void build_noise_lpf_gain_out_chain(RTGraph *g) {
  rt_graph_template_add_node(g, 0, 0, kNkNoiseGen);
  rt_graph_template_add_node(g, 0, 1, kNkLPF);
  rt_graph_template_add_node(g, 0, 2, kNkGain);
  rt_graph_template_add_node(g, 0, 3, kNkOut);

  rt_graph_template_connect(g, 0, 0, 0, 1, 0);  // noise -> lpf signal
  rt_graph_template_connect(g, 0, 1, 0, 2, 0);  // lpf   -> gain signal
  rt_graph_template_connect(g, 0, 2, 0, 3, 0);  // gain  -> out signal

  // NoiseGen has no controls. LPF/Gain/Out match the saw-rooted
  // bench shape so cross-row comparisons are apples-to-apples.
  rt_graph_template_set_default(g, 0, 1, 0, 1200.0); // lpf freq
  rt_graph_template_set_default(g, 0, 1, 1, 4.0);    // lpf q
  rt_graph_template_set_default(g, 0, 2, 0, 0.4);    // gain amount
  rt_graph_template_set_default(g, 0, 3, 0, kBenchBus); // out bus
}

// Register a single 4-node region covering the whole template,
// tagged either NoiseLpfGainOut (fused) or NodeLoop (baseline).
void register_noise_lpf_gain_out_regions(RTGraph *g, bool fused) {
  const int kernel_tag = fused ? kKernelNoiseLpfGainOut : kKernelNodeLoop;
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
  { "NoiseLpfGainOut", 4, &build_noise_lpf_gain_out_chain, &register_noise_lpf_gain_out_regions },
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

// ----------------------------------------------------------------
// §4.E schedule-worker bench
// ----------------------------------------------------------------

struct ScheduleModeSpec {
  const char *name;
  bool global_schedule = false;
  bool reduction = false;
  int worker_pool_size = 0;
};

struct ScheduleBenchSpec {
  const char *name;
  void (*build)(RTGraph *, int voices);
};

struct ScheduleBenchResult {
  double ns_per_block = 0.0;
  double ns_per_sample = 0.0;
  int parallel_bands = 0;
  int parallel_entries = 0;
  int serialized_sink_bands = 0;
};

const ScheduleModeSpec kScheduleModes[] = {
  // Canonical speedup baseline. Keep this row first and unique among
  // modes with !global_schedule && !reduction; the schedule rows divide
  // by its ns/block value.
  { "legacy-direct",       false, false, 0 },
  { "sched-serial-direct", true,  false, 1 },
  { "sched-pool2-direct",  true,  false, 2 },
  { "sched-pool3-direct",  true,  false, 3 },
  { "sched-pool4-direct",  true,  false, 4 },
  { "sched-pool2-reduce",  true,  true,  2 },
  { "sched-pool3-reduce",  true,  true,  3 },
  { "sched-pool4-reduce",  true,  true,  4 },
};

constexpr int kScheduleBlockSizes[]  = { 128, 512 };
constexpr int kScheduleVoiceCounts[] = { 2, 8, 32 };

void configure_schedule_mode(RTGraph *g, const ScheduleModeSpec &mode) {
  if (mode.worker_pool_size > 0) {
    rt_graph_test_set_worker_pool_size(g, mode.worker_pool_size);
  }
  if (mode.reduction) {
    rt_graph_test_set_reduction_capture(g, 1);
  }
  if (mode.global_schedule) {
    rt_graph_test_set_global_schedule_execution(g, 1);
  }
}

void add_schedule_step(RTGraph *g, int tid, int kind, int region_ordinal) {
  const int regions[] = { region_ordinal };
  rt_graph_template_add_schedule_step(g, tid, kind, 1, regions);
}

void spawn_exact_voices(RTGraph *g, int template_id, int voices) {
  rt_graph_template_set_polyphony(g, template_id, voices);
  for (int i = 0; i < voices; ++i) {
    rt_graph_template_instance_add(g, template_id);
  }
}

// One sink-free, DSP-heavy FreeLayer per instance. With global
// schedule execution on, all live instances form one Free band and
// are eligible for worker dispatch in both direct and reduction mode.
void build_schedule_free_compute_graph(RTGraph *g, int voices) {
  rt_graph_instance_remove(g, 0);
  rt_graph_template_set_polyphony(g, 0, voices);

  rt_graph_template_add_node(g, 0, 0, kNkSawOsc);
  rt_graph_template_add_node(g, 0, 1, kNkLPF);
  rt_graph_template_add_node(g, 0, 2, kNkGain);
  rt_graph_template_connect(g, 0, 0, 0, 1, 0);
  rt_graph_template_connect(g, 0, 1, 0, 2, 0);
  rt_graph_template_set_default(g, 0, 0, 0, 220.0);
  rt_graph_template_set_default(g, 0, 1, 0, 800.0);
  rt_graph_template_set_default(g, 0, 1, 1, 4.0);
  rt_graph_template_set_default(g, 0, 2, 0, 0.4);
  rt_graph_template_add_region_kernel(g, 0, kKernelSawLpfGain,
                                      kRateSampleRate, 0, 3);
  add_schedule_step(g, 0, kScheduleFreeLayer, 0);

  spawn_exact_voices(g, 0, voices);
}

// Deliberately marks a sink-terminal region as FreeLayer. The
// Haskell scheduler keeps sink regions on the barrier path today;
// this C++-only bench exercises the C1c gate directly:
//   * direct mode serializes the sink Free band;
//   * reduction mode may dispatch it and fold after the join.
void build_schedule_free_sink_graph(RTGraph *g, int voices) {
  rt_graph_instance_remove(g, 0);
  rt_graph_template_set_polyphony(g, 0, voices);

  build_sin_gain_out_chain(g);
  rt_graph_template_add_region_kernel(g, 0, kKernelSinGainOut,
                                      kRateSampleRate, 0, 3);
  add_schedule_step(g, 0, kScheduleFreeLayer, 0);

  spawn_exact_voices(g, 0, voices);
}

// Send/return shape: N sender voices write bus 1 in one Free band;
// a single reader template consumes bus 1 live and writes bus 0 in a
// later Barrier step. Reduction-mode worker dispatch must join and
// fold before the reader barrier runs.
void build_schedule_send_return_graph(RTGraph *g, int voices) {
  rt_graph_instance_remove(g, 0);
  rt_graph_ensure_bus(g, 1);

  rt_graph_template_set_polyphony(g, 0, voices);
  rt_graph_template_add_node(g, 0, 0, kNkSinOsc);
  rt_graph_template_add_node(g, 0, 1, kNkGain);
  rt_graph_template_add_node(g, 0, 2, kNkBusOut);
  rt_graph_template_connect(g, 0, 0, 0, 1, 0);
  rt_graph_template_connect(g, 0, 1, 0, 2, 0);
  rt_graph_template_set_default(g, 0, 0, 0, 220.0);
  rt_graph_template_set_default(g, 0, 1, 0, 0.25);
  rt_graph_template_set_default(g, 0, 2, 0, 1.0);
  rt_graph_template_add_region_kernel(g, 0, kKernelSinGainOut,
                                      kRateSampleRate, 0, 3);
  add_schedule_step(g, 0, kScheduleFreeLayer, 0);
  spawn_exact_voices(g, 0, voices);

  const int reader = rt_graph_template_add(g);
  rt_graph_template_set_polyphony(g, reader, 1);
  rt_graph_template_add_node(g, reader, 0, kNkBusIn);
  rt_graph_template_add_node(g, reader, 1, kNkLPF);
  rt_graph_template_add_node(g, reader, 2, kNkGain);
  rt_graph_template_add_node(g, reader, 3, kNkOut);
  rt_graph_template_connect(g, reader, 0, 0, 1, 0);
  rt_graph_template_connect(g, reader, 1, 0, 2, 0);
  rt_graph_template_connect(g, reader, 2, 0, 3, 0);
  rt_graph_template_set_default(g, reader, 0, 0, 1.0);
  rt_graph_template_set_default(g, reader, 1, 0, 1200.0);
  rt_graph_template_set_default(g, reader, 1, 1, 4.0);
  rt_graph_template_set_default(g, reader, 2, 0, 0.5);
  rt_graph_template_set_default(g, reader, 3, 0, kBenchBus);
  rt_graph_template_add_region_kernel(g, reader, kKernelBusInLpfGainOut,
                                      kRateSampleRate, 0, 4);
  add_schedule_step(g, reader, kScheduleBarrier, 0);
  spawn_exact_voices(g, reader, 1);
}

const ScheduleBenchSpec kScheduleShapes[] = {
  { "FreeCompute", &build_schedule_free_compute_graph },
  { "FreeSink",    &build_schedule_free_sink_graph    },
  { "SendReturn",  &build_schedule_send_return_graph  },
};

RTGraph *build_schedule_graph(
    const ScheduleBenchSpec &shape,
    const ScheduleModeSpec &mode,
    int voices
) {
  RTGraph *g = rt_graph_create(kCapacity, kMaxFrames);
  shape.build(g, voices);
  rt_graph_ensure_bus(g, kBenchBus);
  configure_schedule_mode(g, mode);
  return g;
}

int choose_schedule_iters(int nframes) {
  const int min_blocks = 64;
  const int target_samples = kSampleRate / 10;  // ~100 ms of audio.
  const int iters = target_samples / nframes;
  return iters < min_blocks ? min_blocks : iters;
}

std::int64_t time_schedule_render(
    RTGraph *g, int nframes, int iters, std::vector<float> &scratch
) {
  for (int i = 0; i < kScheduleWarmupBlocks; ++i) {
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

ScheduleBenchResult run_schedule_cell(
    const ScheduleBenchSpec &shape,
    const ScheduleModeSpec &mode,
    int nframes,
    int voices
) {
  std::vector<float> scratch;
  std::vector<double> ns_per_block;
  ns_per_block.reserve(static_cast<std::size_t>(kScheduleRepeatRuns));

  const int iters = choose_schedule_iters(nframes);
  ScheduleBenchResult observed;

  for (int run = 0; run < kScheduleRepeatRuns; ++run) {
    RTGraph *g = build_schedule_graph(shape, mode, voices);
    const std::int64_t ns = time_schedule_render(g, nframes, iters, scratch);
    ns_per_block.push_back(static_cast<double>(ns) /
                           static_cast<double>(iters));

    if (run == kScheduleRepeatRuns - 1) {
      // One untimed block records representative C1c counters for
      // this shape/mode. Reading the counters inside the timed loop
      // would benchmark introspection overhead instead of rendering.
      rt_graph_process(g, nframes);
      observed.parallel_bands =
          rt_graph_test_last_parallel_band_count(g);
      observed.parallel_entries =
          rt_graph_test_last_parallel_entry_count(g);
      observed.serialized_sink_bands =
          rt_graph_test_last_serialized_free_band_count(g);
      drain_into_sink(g, nframes, scratch);
    }

    rt_graph_destroy(g);
  }

  std::sort(ns_per_block.begin(), ns_per_block.end());
  observed.ns_per_block = ns_per_block[ns_per_block.size() / 2];
  observed.ns_per_sample =
      observed.ns_per_block / static_cast<double>(nframes);
  return observed;
}

}  // namespace

int main() {
  print_bench_reproducibility();

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

  std::printf("\n# rt_graph_bench: §4.E schedule-worker microbench\n");
  std::printf("# schedule_warmup_blocks=%d, schedule_repeat_runs=%d\n",
              kScheduleWarmupBlocks, kScheduleRepeatRuns);
  std::printf(
      "# columns: shape,mode,block,voices,ns_per_block,ns_per_sample,"
      "parallel_bands,parallel_entries,serialized_sink_bands,speedup\n");

  for (const auto &shape : kScheduleShapes) {
    for (const int voices : kScheduleVoiceCounts) {
      for (const int nframes : kScheduleBlockSizes) {
        double legacy_ns_per_block = 0.0;
        for (const auto &mode : kScheduleModes) {
          const ScheduleBenchResult result =
              run_schedule_cell(shape, mode, nframes, voices);
          // See kScheduleModes: this captures the canonical legacy
          // baseline once per cell so later rows cannot silently pick
          // a different denominator without changing the mode table
          // contract.
          if (!mode.global_schedule && !mode.reduction) {
            legacy_ns_per_block = result.ns_per_block;
          }
          const double speedup = result.ns_per_block > 0.0
              ? legacy_ns_per_block / result.ns_per_block
              : 0.0;
          std::printf(
              "%-12s,%-20s,%4d,%3d,%12.2f,%9.2f,%3d,%4d,%3d,%5.2fx\n",
              shape.name, mode.name, nframes, voices,
              result.ns_per_block, result.ns_per_sample,
              result.parallel_bands, result.parallel_entries,
              result.serialized_sink_bands, speedup);
        }
      }
    }
  }

  // Print the sink so the linker / optimizer cannot strip the
  // accumulator chain away. Trailing comment line, not a result
  // anyone parses.
  std::printf("# sink_checksum=%g\n", static_cast<double>(g_sink));
  return 0;
}
