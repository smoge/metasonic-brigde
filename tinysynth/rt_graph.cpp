// ================================================================
// rt_graph.cpp
// Description : runtime DSP engine and realtime audio backend
// ================================================================
//
// On the Haskell side, compilation ends at RuntimeGraph: a dense,
// execution-ordered list of nodes whose inputs already refer to
// concrete runtime indices. On the C++ side, this file turns that
// dense structure into preallocated node state, block processors,
// output buses, and realtime audio stream.
//
//   * Haskell is responsible for graph construction, validation,
//     topological ordering, region analysis, and dense lowering.
//
//   * C++ is responsible for block execution, node-local state,
//     buffer ownership, signal propagation, and audio-device I/O.
//

#include "rt_graph.h"

#include <q_io/audio_device.hpp>
#include <q_io/audio_stream.hpp>

#include <portaudio.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <numbers>
#include <span>
#include <thread>
#include <vector>

namespace q = cycfi::q;

struct RTGraph;

/* Note [Dense runtime model
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The runtime operates entirely on dense indices.

The Haskell compiler performs the decisive symbolic -> dense lowering:

  NodeID    -> NodeIndex
  Port name -> PortIndex

By the time control reaches this file, there is no symbolic lookup,
no map from user-facing names to nodes, and no scheduling work left to
perform.

This matters for both simplicity and realtime safety.

The small wrapper structs below preserve nominal distinctions between
node positions, port positions, and control slots, even though they are
all represented as ints at the machine level.
*/

namespace {

// Default sample rate used before a realtime device is opened.
// TODO: make this configurable
constexpr float kDefaultSampleRate = 48000.0f;

// ----------------------------------------------------------------
// Strong internal indices
// ----------------------------------------------------------------

struct NodeIndex {
  int value = -1;
};

struct PortIndex {
  int value = -1;
};

struct ControlIndex {
  int value = -1;
};

[[nodiscard]] constexpr bool valid(NodeIndex x) noexcept {
  return x.value >= 0;
}
[[nodiscard]] constexpr bool valid(PortIndex x) noexcept {
  return x.value >= 0;
}
[[nodiscard]] constexpr bool valid(ControlIndex x) noexcept {
  return x.value >= 0;
}

[[nodiscard]] constexpr std::size_t to_size(NodeIndex x) noexcept {
  return static_cast<std::size_t>(x.value);
}
[[nodiscard]] constexpr std::size_t to_size(PortIndex x) noexcept {
  return static_cast<std::size_t>(x.value);
}
[[nodiscard]] constexpr std::size_t to_size(ControlIndex x) noexcept {
  return static_cast<std::size_t>(x.value);
}

/* Note [Runtime node kind tags]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
NodeKind must stay aligned with the integer tags emitted by the Haskell
compiler.

  Haskell (MetaSonic.Types.kindTag)    C++ (NodeKind)
  ---------------------------------    --------------
  kindTag KSinOsc = 1                  SinOsc = 1
  kindTag KOut    = 2                  Out    = 2
  kindTag KGain   = 3                  Gain   = 3

The runtime does not perform any negotiation here.
`rt_graph_add_node` can decode them directly.
*/

enum class NodeKind : int {
  SinOsc = 1,
  Out = 2,
  Gain = 3,
};

/* Note [Input references and control fallback]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Each node input slot can either be connected to another node's output
or left unconnected.

An InputRef is considered connected when its src_node index is valid
(non-negative). The default-constructed sentinel value (-1) represents
an unconnected slot.

This preserves the protocol used by the Haskell side:

  * rnControls carries the default values
  * RFrom edges become rt_graph_connect calls
  * RConst values do not produce connections

At the moment the runtime uses block-latched semantics for connected
control-like inputs. That's temporary, just for demonstration and simplicity,
while leaving open the future step to sample-accurate modulation.
*/

struct InputRef {
  NodeIndex src_node{};
  PortIndex src_port{};
};

// Stateful payload for SinOsc. The oscillator remembers phase across
// blocks and across callback invocations until the graph is cleared or
// destroyed.
struct SinOscState {
  float phase = 0.0f;
  bool phase_initialized = false;
};

/* Note [NodeRuntime layout]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
NodeRuntime is the concrete execution unit owned by RTGraph.

Each node stores:

  * its kind tag
  * its control defaults
  * its incoming edge references
  * output buffers (when applicable), preallocated to max_frames
  * optional per-node state

The runtime chooses a structure-of-vectors style at the node boundary:
controls, inputs, and outputs are each kept in dedicated vectors sized
according to the node kind. This keeps configuration logic local to
configure_node and keeps processing kernels compact.
*/

struct NodeRuntime {
  NodeKind kind = NodeKind::Out;
  std::vector<float> controls;
  std::vector<InputRef> input_refs;
  std::vector<std::vector<float>> outputs;
  SinOscState sinosc{};
};

// View one output buffer as a span over the first nframes samples.
[[nodiscard]] static std::span<float>
output_span(NodeRuntime &node, PortIndex port, int nframes) noexcept {
  return {node.outputs[to_size(port)].data(),
          static_cast<std::size_t>(nframes)};
}

[[nodiscard]] static std::span<const float>
output_span(const NodeRuntime &node, PortIndex port, int nframes) noexcept {
  return {node.outputs[to_size(port)].data(),
          static_cast<std::size_t>(nframes)};
}

// Resolve one connected input to the source node's output span.
// An empty span means the input is unavailable and the caller should
// fall back to the corresponding control value or silence.
[[nodiscard]] static std::span<const float>
resolve_input(const std::vector<NodeRuntime> &nodes, const NodeRuntime &dst,
              PortIndex input_index, int nframes) noexcept {
  if (!valid(input_index)) {
    return {};
  }

  const std::size_t idx = to_size(input_index);
  if (idx >= dst.input_refs.size()) {
    return {};
  }

  const InputRef &ref = dst.input_refs[idx];
  if (!valid(ref.src_node) || !valid(ref.src_port)) {
    return {};
  }

  const std::size_t src_index = to_size(ref.src_node);
  if (src_index >= nodes.size()) {
    return {};
  }

  const NodeRuntime &src = nodes[src_index];
  const std::size_t src_port = to_size(ref.src_port);
  if (src_port >= src.outputs.size()) {
    return {};
  }

  if (src.outputs[src_port].size() < static_cast<std::size_t>(nframes)) {
    return {};
  }

  return output_span(src, ref.src_port, nframes);
}

/* Note [Node configuration and preallocation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
configure_node is part of graph loading, not realtime execution.

Two jobs:

  1. choose the shape of the node: control count, input count,
     output count, and initial state
  2. preallocate every output buffer to max_frames

This separation is important. The architectural invariant is that the
DSP loop performs no allocation. All buffer growth happens here while
loading or reloading the graph.
*/

static void configure_node(NodeRuntime &node, NodeKind kind, int max_frames) {
  node.kind = kind;
  node.controls.clear();
  node.input_refs.clear();
  node.outputs.clear();
  node.sinosc = {};

  switch (kind) {
  case NodeKind::SinOsc:
    node.controls.resize(2, 0.0f); // [freq, initial_phase]
    node.input_refs.resize(2);     // [freq_in, phase_in]
    node.outputs.resize(1);
    break;

  case NodeKind::Out:
    node.controls.resize(1, 0.0f); // [bus]
    node.input_refs.resize(1);     // [signal_in]
    // No outputs — Out accumulates directly into the bus
    break;

  case NodeKind::Gain:
    node.controls.resize(1, 1.0f); // [gain_amount]
    node.input_refs.resize(2);     // [signal_in, gain_in]
    node.outputs.resize(1);
    break;
  }

  for (auto &out : node.outputs) {
    out.resize(static_cast<std::size_t>(max_frames), 0.0f);
  }
}

/* Note [q_io stream wrapper]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
GraphAudioStream is the bridge between the dense runtime and
q_io's PortAudio-backed callback stream.

Its job is (deliberately) narrow:

  * when the audio callback fires, run process_graph for the current
    frame count
  * copy the resulting output buses into q_io's non-interleaved output
    channel spans
  * set a one-way "started" flag once the callback has actually run

Crucially, the callback does not call back into the Haskell side,
take locks, or perform configuration work. The stream is just a realtime
pull wrapper around the already-constructed RTGraph.
*/

struct GraphAudioStream : q::audio_stream {
  GraphAudioStream(RTGraph &graph, q::audio_device const &device,
                   std::size_t output_channels);

  void process(out_channels const &out) override;
  bool wait_started(std::chrono::milliseconds timeout) noexcept;

  RTGraph &graph;
  std::atomic<bool> started{false};
};

} // namespace

/* Note [RTGraph ownership]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
RTGraph is the sole owner of runtime state.

Contains:

  * the dense node array
  * the maximum frame size used for all preallocations
  * the currently active sample rate
  * output buses that accumulate the contribution of Out nodes
  * an optional realtime audio stream

The Haskell side sees RTGraph only as an opaque pointer.
All ownership, lifetime, and mutation live here.
*/

struct RTGraph {
  int capacity = 0;
  int max_frames = 0;
  float sample_rate = kDefaultSampleRate;
  std::vector<NodeRuntime> nodes;
  std::vector<std::vector<float>> output_buses;
  std::unique_ptr<GraphAudioStream> audio;
};

namespace {

// Ensure the dense node vector is large enough to hold node_index.
static void ensure_node_slot(RTGraph &g, NodeIndex node_index) {
  if (!valid(node_index)) {
    return;
  }

  const std::size_t idx = to_size(node_index);
  if (g.nodes.size() <= idx) {
    g.nodes.resize(idx + 1);
  }
}

/* Note [Output bus semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Out nodes do not write directly to a hardware device.

Each Out node accumulates its input signal directly into one runtime output bus,
selected by control slot 0.

This gives the runtime a useful intermediate abstraction:

  * multiple Out nodes may sum onto the same bus
  * offline processing can inspect buses without opening audio
  * realtime output can map buses to device channels in a separate step

The bus vectors are preallocated exactly like node outputs, so clearing
and accumulation remain allocation-free inside the DSP loop.
*/

static void ensure_output_bus_count(RTGraph &g, std::size_t count) {
  if (g.output_buses.size() >= count) {
    return;
  }

  const std::size_t old_size = g.output_buses.size();
  g.output_buses.resize(count);
  for (std::size_t i = old_size; i < count; ++i) {
    g.output_buses[i].resize(static_cast<std::size_t>(g.max_frames), 0.0f);
  }
}

// Zero the first nframes of each output bus before one block render.
static void clear_output_buses(RTGraph &g, int nframes) noexcept {
  const std::size_t frames = static_cast<std::size_t>(nframes);
  for (auto &bus : g.output_buses) {
    std::fill_n(bus.begin(), frames, 0.0f);
  }
}

/* Note [SinOsc processing semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
SinOsc currently implements a simple stateful oscillator with block-
latched control inputs.

  * frequency input: if connected, sample 0 overrides control 0
  * phase input: if connected, sample 0 overrides control 1 only while
    the oscillator is being initialized

After initialization, phase advances continuously across blocks. This
keeps the implementation aligned with the original prototype semantics:
phase is an initial condition, not an audio-rate modulation target.
*/

static void process_sinosc(RTGraph &g, std::size_t node_idx,
                           int nframes) noexcept {
  NodeRuntime &node = g.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto freq_in = resolve_input(g.nodes, node, PortIndex{0}, nframes);
  const auto phase_in = resolve_input(g.nodes, node, PortIndex{1}, nframes);

  const float freq = !freq_in.empty() ? freq_in[0] : node.controls[0];
  const float ph0 = !phase_in.empty() ? phase_in[0] : node.controls[1];

  if (!node.sinosc.phase_initialized) {
    node.sinosc.phase = ph0;
    node.sinosc.phase_initialized = true;
  }

  constexpr float kTwoPi = 2.0f * std::numbers::pi_v<float>;
  const float inc = freq / g.sample_rate;

  for (int i = 0; i < nframes; ++i) {
    const std::size_t fi = static_cast<std::size_t>(i);
    out[fi] = std::sin(kTwoPi * node.sinosc.phase);
    node.sinosc.phase += inc;
    if (node.sinosc.phase >= 1.0f || node.sinosc.phase < 0.0f) {
      node.sinosc.phase -= std::floor(node.sinosc.phase);
    }
  }
}

/* Note [Gain processing semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Gain is currently scalar gain with block-latched modulation.

If input port 1 is connected, the kernel reads sample 0 from that input
and uses it as the gain amount for the entire block. If no signal input
is connected, the output is silence.

As with SinOsc, this is a deliberate "simple now, elaborate later" design:
the dataflow shape already supports future sample-accurate gain without
changing the ABI!
*/

static void process_gain(RTGraph &g, std::size_t node_idx,
                         int nframes) noexcept {
  NodeRuntime &node = g.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto sig_in = resolve_input(g.nodes, node, PortIndex{0}, nframes);
  const auto gain_in = resolve_input(g.nodes, node, PortIndex{1}, nframes);

  const float amount = !gain_in.empty() ? gain_in[0] : node.controls[0];

  if (sig_in.empty()) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  for (int i = 0; i < nframes; ++i) {
    const std::size_t fi = static_cast<std::size_t>(i);
    out[fi] = sig_in[fi] * amount;
  }
}

/* Note [Out node processing — direct bus accumulation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Out is a pure sink: it accumulates its input signal into a shared
output bus selected by control slot 0.

Previously, process_out performed two passes over the frame data:

  1. copy the resolved input into the node's local output buffer
  2. accumulate that local buffer into the destination bus

The local buffer was write-only dead storage — Out is a terminal node
for now, and no downstream node ever reads its output port. The new
version eliminates the intermediate copy and accumulates the resolved
input directly into the bus.

If the input is unconnected or the bus index is invalid, the node
contributes nothing. Multiple Out nodes may target the same
bus.

This design also aligns with the (not yet implemented) bus-routing
model: when cross-graph communication arrives, a dedicated BusIn node
will read from the bus, NOT from the Out output port. The bus is the
shared memory abstraction (just like SC3's Out.ar & In.ar
design). Keeping Out as a pure accumulator avoids ambiguity.
*/
static void process_out(RTGraph &g, std::size_t node_idx,
                        int nframes) noexcept {
  NodeRuntime &node = g.nodes[node_idx];
  const auto in = resolve_input(g.nodes, node, PortIndex{0}, nframes);
  if (in.empty())
    return;

  const int bus = static_cast<int>(node.controls[0]);
  if (bus < 0 || static_cast<std::size_t>(bus) >= g.output_buses.size())
    return;

  auto &dst = g.output_buses[static_cast<std::size_t>(bus)];
  for (int i = 0; i < nframes; ++i) {
    dst[static_cast<std::size_t>(i)] += in[static_cast<std::size_t>(i)];
  }
}

/* Note [Execution order invariant]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The runtime processes nodes in storage order.

This is correct because `metasonic` adds nodes in dense execution order,
which itself comes from the validated topological order computed on the
Haskell side. There is therefore no separate scheduler in this file.
The dense node vector is already the "schedule".

That simplicity is by design. Thus the name "tinysynth".
*/

static void process_graph(RTGraph &g, int nframes) noexcept {
  clear_output_buses(g, nframes);

  for (std::size_t i = 0; i < g.nodes.size(); ++i) {
    switch (g.nodes[i].kind) {
    case NodeKind::SinOsc:
      process_sinosc(g, i, nframes);
      break;
    case NodeKind::Out:
      process_out(g, i, nframes);
      break;
    case NodeKind::Gain:
      process_gain(g, i, nframes);
      break;
    }
  }
}

GraphAudioStream::GraphAudioStream(RTGraph &graph_,
                                   q::audio_device const &device,
                                   std::size_t output_channels)
    : q::audio_stream(device, 0, output_channels, device.default_sample_rate(),
                      graph_.max_frames),
      graph(graph_) {}

/* Note [Realtime channel mapping]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The q_io callback receives one non-interleaved output span per hardware
channel.

The runtime maps output buses to those channels as follows:

  * if the graph has multiple buses, bus N feeds channel N when present
  * if the graph has exactly one bus but the device has multiple output
    channels, bus 0 is duplicated to every channel

*/

void GraphAudioStream::process(out_channels const &out) {
  started.store(true, std::memory_order_release);

  // To be defensive, clamp nframes to max_frames here. (PA spec says the
  // callback can receive different sizes, but we can't handle that.)
  const int nframes =
      std::min(static_cast<int>(out.frames.size()), graph.max_frames);
  process_graph(graph, nframes);

  for (std::size_t ch = 0; ch < out.size(); ++ch) {
    auto dst = out[ch];
    std::fill(dst.begin(), dst.end(), 0.0f);

    if (graph.output_buses.empty()) {
      continue;
    }

    const std::size_t bus =
        (graph.output_buses.size() == 1 && out.size() > 1) ? 0 : ch;

    if (bus < graph.output_buses.size()) {
      std::copy_n(graph.output_buses[bus].begin(),
                  static_cast<std::size_t>(nframes), dst.begin());
    }
  }
}

/* Note [Callback readiness signaling]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The runtime exposes rt_graph_wait_started so the Haskell side can wait
until the realtime callback has actually executed.

The audio callback itself cannot safely participate in heavy cross-
language coordination. Instead it performs the smallest possible signal:

  started.store(true)

IMPORTANT:
A separate, non-realtime waiting path polls that flag. This keeps the
callback thread free of locks, I/O, and Haskell RTS interaction.
*/

bool GraphAudioStream::wait_started(
    std::chrono::milliseconds timeout) noexcept {
  if (timeout.count() < 0) {
    while (!started.load(std::memory_order_acquire)) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return true;
  }

  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (std::chrono::steady_clock::now() < deadline) {
    if (started.load(std::memory_order_acquire)) {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }

  return started.load(std::memory_order_acquire);
}

// Stop and release the active realtime stream, if any.
static void stop_audio_stream(RTGraph &g) {
  if (!g.audio) {
    return;
  }

  g.audio->stop();
  g.audio.reset();
}

/* Note [Device selection policy]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
open_audio_stream chooses an output device using a small deterministic
policy.

  1. If the caller supplied a device id, try exactly that device.
  2. Otherwise, prefer the PortAudio default output device.
  3. If that fails, fall back to the first device with enough output
     channels.

The function returns a fully opened q_io stream or nullptr on failure.
It does not start the stream; startup remains the responsibility of the
C ABI entry point.
*/

static std::unique_ptr<GraphAudioStream>
open_audio_stream(RTGraph &g, int requested_output_channels,
                  int requested_device_id) {
  auto devices = q::audio_device::list();
  if (devices.empty()) {
    return {};
  }

  auto try_make =
      [&](q::audio_device const &dev) -> std::unique_ptr<GraphAudioStream> {
    if (static_cast<int>(dev.output_channels()) < requested_output_channels) {
      return {};
    }

    auto stream = std::make_unique<GraphAudioStream>(
        g, dev, static_cast<std::size_t>(requested_output_channels));

    if (!stream->is_valid()) {
      return {};
    }

    return stream;
  };

  if (requested_device_id >= 0) {
    for (auto const &dev : devices) {
      if (dev.id() == requested_device_id) {
        return try_make(dev);
      }
    }
    return {};
  }

  const PaDeviceIndex default_output_id = Pa_GetDefaultOutputDevice();
  if (default_output_id != paNoDevice) {
    for (auto const &dev : devices) {
      if (dev.id() == default_output_id) {
        if (auto stream = try_make(dev)) {
          return stream;
        }
        break;
      }
    }
  }

  for (auto const &dev : devices) {
    if (auto stream = try_make(dev)) {
      return stream;
    }
  }

  return {};
}

} // namespace

// ----------------------------------------------------------------
// C ABI implementation
// ----------------------------------------------------------------

extern "C" {

// Allocate one runtime graph handle. No nodes are configured yet.
RTGraph *rt_graph_create(int capacity, int max_frames) {
  auto *g = new RTGraph{};
  g->capacity = std::max(0, capacity);
  g->max_frames = std::max(0, max_frames);
  if (g->capacity > 0) {
    g->nodes.reserve(static_cast<std::size_t>(g->capacity));
  }
  return g;
}

// Destroy the graph and any active audio stream.
void rt_graph_destroy(RTGraph *g) {
  if (!g) {
    return;
  }
  stop_audio_stream(*g);
  delete g;
}

/* Note [Clear semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~
rt_graph_clear is the graph-reload entry point.

It stops active audio, resets the sample rate to the default placeholder
value, removes all nodes and output buses, and preserves the graph handle
for reuse. This matches the Haskell loading protocol, where a single
RTGraph handle may be repeatedly cleared and repopulated by
loadRuntimeGraph.
*/

void rt_graph_clear(RTGraph *g) {
  if (!g) {
    return;
  }

  stop_audio_stream(*g);
  g->sample_rate = kDefaultSampleRate;
  g->nodes.clear();
  g->output_buses.clear();
  if (g->capacity > 0) {
    g->nodes.reserve(static_cast<std::size_t>(g->capacity));
  }
}

// Add or reconfigure one node at its dense runtime index.
void rt_graph_add_node(RTGraph *g, int node_index, int node_kind) {
  if (!g) {
    return;
  }

  NodeKind kind{};
  switch (node_kind) {
  case 1:
    kind = NodeKind::SinOsc;
    break;
  case 2:
    kind = NodeKind::Out;
    break;
  case 3:
    kind = NodeKind::Gain;
    break;
  default:
    std::fprintf(stderr, "Unknown node kind: %d\n", node_kind);
    return;
  }

  const NodeIndex idx{node_index};
  if (!valid(idx)) {
    return;
  }

  ensure_node_slot(*g, idx);
  configure_node(g->nodes[to_size(idx)], kind, g->max_frames);

  // Out nodes imply at least one runtime output bus exists.
  if (kind == NodeKind::Out) {
    ensure_output_bus_count(*g, 1);
  }
}

// Set one control slot on one node.
void rt_graph_set_control(RTGraph *g, int node_index, int control_index,
                          float value) {
  if (!g) {
    return;
  }

  const NodeIndex ni{node_index};
  const ControlIndex ci{control_index};
  if (!valid(ni) || !valid(ci)) {
    return;
  }

  const std::size_t nidx = to_size(ni);
  if (nidx >= g->nodes.size()) {
    return;
  }

  NodeRuntime &node = g->nodes[nidx];
  const std::size_t cidx = to_size(ci);
  if (cidx >= node.controls.size()) {
    return;
  }

  node.controls[cidx] = value;

  // For Out nodes, control 0 is the destination output bus.
  // Growing the bus array here ensures the DSP loop never has to do it.
  if (node.kind == NodeKind::Out && cidx == 0 && value >= 0.0f) {
    const auto bus = static_cast<std::size_t>(static_cast<int>(value));
    ensure_output_bus_count(*g, bus + 1);
  }
}

// Connect one source output port to one destination input port.
void rt_graph_connect(RTGraph *g, int src_index, int src_port, int dst_index,
                      int dst_port) {
  if (!g) {
    return;
  }

  const NodeIndex src{src_index};
  const PortIndex sp{src_port};
  const NodeIndex dst{dst_index};
  const PortIndex dp{dst_port};
  if (!valid(src) || !valid(sp) || !valid(dst) || !valid(dp)) {
    return;
  }

  const std::size_t sidx = to_size(src);
  const std::size_t didx = to_size(dst);
  const std::size_t dport = to_size(dp);

  if (sidx >= g->nodes.size() || didx >= g->nodes.size()) {
    return;
  }

  NodeRuntime &dst_node = g->nodes[didx];
  if (dport >= dst_node.input_refs.size()) {
    return;
  }

  dst_node.input_refs[dport] = InputRef{src, sp};
}

// Render one block offline into the graph's internal output buses.
void rt_graph_process(RTGraph *g, int nframes) {
  if (!g) {
    return;
  }

  if (nframes < 0 || nframes > g->max_frames) {
    std::fprintf(stderr, "Invalid nframes: %d (max_frames=%d)\n", nframes,
                 g->max_frames);
    return;
  }

  if (g->output_buses.empty()) {
    ensure_output_bus_count(*g, 1);
  }

  process_graph(*g, nframes);
}

/* Note [Realtime startup]
~~~~~~~~~~~~~~~~~~~~~~~~~~
rt_graph_start_audio opens and starts the q_io / PortAudio stream.

output_channels controls the hardware channel count requested from the
stream. If the caller passes a non-positive value, the runtime infers a
channel count from the configured output buses, with a minimum of one.

The function only succeeds once the stream is valid and started. A
separate rt_graph_wait_started call can then wait until the callback has
actually run.
*/

int rt_graph_start_audio(RTGraph *g, int output_channels, int device_id) {
  if (!g) {
    return -100;
  }

  if (g->audio) {
    return 0;
  }

  if (output_channels <= 0) {
    output_channels = std::max(1, static_cast<int>(g->output_buses.size()));
  }

  if (g->output_buses.empty()) {
    ensure_output_bus_count(*g, 1);
  }

  auto stream = open_audio_stream(*g, output_channels, device_id);
  if (!stream) {
    std::fprintf(stderr,
                 "Failed to open audio stream (device_id=%d, outputs=%d)\n",
                 device_id, output_channels);
    return -1;
  }

  g->sample_rate = static_cast<float>(stream->sampling_rate());
  stream->start();
  g->audio = std::move(stream);
  return 0;
}

// Wait for the realtime callback to execute at least once.
int rt_graph_wait_started(RTGraph *g, int timeout_ms) {
  if (!g || !g->audio) {
    return -100;
  }

  const bool ok = g->audio->wait_started(std::chrono::milliseconds(timeout_ms));
  return ok ? 0 : -2;
}

// Stop realtime audio if it is active.
void rt_graph_stop_audio(RTGraph *g) {
  if (!g) {
    return;
  }

  stop_audio_stream(*g);
}

} // extern "C"
